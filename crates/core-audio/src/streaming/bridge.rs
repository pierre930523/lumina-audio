use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};

use symphonia::core::io::MediaSource;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::{ByteStreamSource, SegmentedSeekTarget, StreamError, streaming_runtime};

const BRIDGE_CHANNEL_CAPACITY: usize = 4;

enum BridgeCommand {
    ReadAt {
        offset: u64,
        len: usize,
        reply: std_mpsc::SyncSender<Result<Vec<u8>, StreamError>>,
    },
    SeekTimeMs {
        target_ms: u64,
        reply: std_mpsc::SyncSender<Result<Option<SegmentedSeekTarget>, StreamError>>,
    },
}

fn reply_cancelled(cmd: BridgeCommand) {
    match cmd {
        BridgeCommand::ReadAt { reply, .. } => {
            let _ = reply.try_send(Err(StreamError::Cancelled));
        }
        BridgeCommand::SeekTimeMs { reply, .. } => {
            let _ = reply.try_send(Err(StreamError::Cancelled));
        }
    }
}

async fn run_bridge_worker(
    source: Arc<dyn ByteStreamSource>,
    mut rx: mpsc::Receiver<BridgeCommand>,
    cancel: CancellationToken,
) {
    loop {
        let cmd = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                rx.close();
                while let Ok(pending) = rx.try_recv() {
                    reply_cancelled(pending);
                }
                break;
            }
            maybe_cmd = rx.recv() => match maybe_cmd {
                Some(c) => c,
                None => break,
            }
        };

        let is_cancelled = match cmd {
            BridgeCommand::ReadAt { offset, len, reply } => {
                let mut buf = vec![0u8; len];
                let res = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => Err(StreamError::Cancelled),
                    r = source.read_at(offset, &mut buf) => r.map(|n| {
                        buf.truncate(n);
                        buf
                    }),
                };
                let aborted = matches!(res, Err(StreamError::Cancelled)) && cancel.is_cancelled();
                let _ = reply.try_send(res);
                aborted
            }
            BridgeCommand::SeekTimeMs { target_ms, reply } => {
                let res = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => Err(StreamError::Cancelled),
                    r = source.seek_to_time_ms(target_ms) => r,
                };
                let aborted = matches!(res, Err(StreamError::Cancelled)) && cancel.is_cancelled();
                let _ = reply.try_send(res);
                aborted
            }
        };

        if is_cancelled {
            rx.close();
            while let Ok(pending) = rx.try_recv() {
                reply_cancelled(pending);
            }
            break;
        }
    }
}

/// Synchronous `Read + Seek + MediaSource` bridge connecting an OS decode thread to an async
/// [`ByteStreamSource`] worker spawned on [`streaming_runtime`](super::streaming_runtime) over a
/// bounded `tokio::sync::mpsc::channel(4)` without ever calling `block_on`.
pub struct BlockingStreamBridge {
    source: Arc<dyn ByteStreamSource>,
    cmd_tx: mpsc::Sender<BridgeCommand>,
    cancel: CancellationToken,
    pos: u64,
    last_stream_error: Arc<Mutex<Option<StreamError>>>,
}

impl BlockingStreamBridge {
    /// Spawns the async worker task on `STREAMING_RUNTIME` and returns a synchronous bridge.
    pub fn new(source: Arc<dyn ByteStreamSource>) -> Result<Self, StreamError> {
        let rt = streaming_runtime()?;
        let cancel = source.cancellation_token();
        let (cmd_tx, cmd_rx) = mpsc::channel(BRIDGE_CHANNEL_CAPACITY);

        let worker_source = Arc::clone(&source);
        let worker_cancel = cancel.clone();
        rt.spawn(async move {
            run_bridge_worker(worker_source, cmd_rx, worker_cancel).await;
        });

        Ok(Self {
            source,
            cmd_tx,
            cancel,
            pos: 0,
            last_stream_error: Arc::new(Mutex::new(None)),
        })
    }

    /// Returns and clears the most recent typed [`StreamError`] observed during bridge I/O
    /// (allowing downstream decoders to distinguish `AuthRequired` and `FormatChanged`).
    pub fn take_last_stream_error(&self) -> Option<StreamError> {
        self.last_stream_error
            .lock()
            .ok()
            .and_then(|mut g| g.take())
    }

    /// Peeks the most recent typed [`StreamError`] without clearing it.
    pub fn last_stream_error(&self) -> Option<StreamError> {
        self.last_stream_error.lock().ok().and_then(|g| g.clone())
    }

    /// Reclaims excess cached RAM chunks/segments from the underlying [`ByteStreamSource`].
    pub fn reclaim_idle_memory(&self) -> usize {
        self.source.reclaim_idle_memory()
    }

    fn record_stream_error(&self, err: &StreamError) {
        if let Ok(mut g) = self.last_stream_error.lock() {
            *g = Some(err.clone());
        }
    }

    fn clear_stream_error(&self) {
        if let Ok(mut g) = self.last_stream_error.lock() {
            *g = None;
        }
    }

    /// Returns the current virtual byte cursor position.
    pub fn position(&self) -> u64 {
        self.pos
    }

    /// Resets the current virtual byte cursor position (used after timeline seeks or resets).
    pub fn reset_position(&mut self, pos: u64) {
        self.pos = match self.source.len() {
            Some(len) => pos.min(len),
            None => pos,
        };
    }

    /// Delegates a timeline seek to the underlying [`ByteStreamSource`] and resets `position` to
    /// `target.virtual_offset` when a segmented window reset occurs.
    pub fn seek_to_time_ms(
        &mut self,
        target_ms: u64,
    ) -> Result<Option<SegmentedSeekTarget>, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }

        let (reply_tx, reply_rx) = std_mpsc::sync_channel(1);
        let cmd = BridgeCommand::SeekTimeMs {
            target_ms,
            reply: reply_tx,
        };
        if self.cmd_tx.blocking_send(cmd).is_err() {
            return Err(StreamError::Cancelled);
        }
        let target = match reply_rx.recv().map_err(|_| StreamError::Cancelled)? {
            Ok(t) => {
                self.clear_stream_error();
                t
            }
            Err(e) => {
                self.record_stream_error(&e);
                return Err(e);
            }
        };
        if let Some(ref t) = target {
            self.pos = t.virtual_offset;
        }
        Ok(target)
    }

    /// Cancels the underlying stream source and terminates any pending bridge I/O immediately.
    pub fn cancel(&self) {
        self.source.cancel();
    }

    /// Returns the optional extension hint from the underlying stream source.
    pub fn hint_extension(&self) -> Option<&str> {
        self.source.hint_extension()
    }

    /// Returns the optional MIME type from the underlying stream source.
    pub fn mime_type(&self) -> Option<&str> {
        self.source.mime_type()
    }
}

impl Read for BlockingStreamBridge {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled.to_io_error());
        }
        if buf.is_empty() {
            return Ok(0);
        }

        self.clear_stream_error();
        let (reply_tx, reply_rx) = std_mpsc::sync_channel(1);
        let cmd = BridgeCommand::ReadAt {
            offset: self.pos,
            len: buf.len(),
            reply: reply_tx,
        };
        if self.cmd_tx.blocking_send(cmd).is_err() {
            return Err(StreamError::Cancelled.to_io_error());
        }

        let data = match reply_rx
            .recv()
            .map_err(|_| StreamError::Cancelled.to_io_error())?
        {
            Ok(d) => d,
            Err(e) => {
                self.record_stream_error(&e);
                return Err(e.to_io_error());
            }
        };

        let n = data.len().min(buf.len());
        buf[..n].copy_from_slice(&data[..n]);
        self.pos = self.pos.saturating_add(n as u64);
        Ok(n)
    }
}

impl Seek for BlockingStreamBridge {
    fn seek(&mut self, style: SeekFrom) -> std::io::Result<u64> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled.to_io_error());
        }

        let total_len = self.source.len();
        let target: i128 = match style {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::Current(delta) => (self.pos as i128) + (delta as i128),
            SeekFrom::End(delta) => match total_len {
                Some(len) => (len as i128) + (delta as i128),
                None => {
                    return Err(std::io::Error::new(
                        ErrorKind::Unsupported,
                        "SeekFrom::End unsupported when stream length is unknown",
                    ));
                }
            },
        };

        if target < 0 {
            return Err(std::io::Error::new(
                ErrorKind::InvalidInput,
                "Cannot seek before start of stream",
            ));
        }

        let target_u64 = target as u64;
        self.pos = match total_len {
            Some(len) => target_u64.min(len),
            None => target_u64,
        };
        Ok(self.pos)
    }
}

impl MediaSource for BlockingStreamBridge {
    fn is_seekable(&self) -> bool {
        self.source.len().is_some()
    }

    fn byte_len(&self) -> Option<u64> {
        self.source.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::time::{Duration, Instant};

    struct TestAsyncSource {
        data: Vec<u8>,
        delay: Duration,
        force_timeout: bool,
        cancel: CancellationToken,
    }

    #[async_trait]
    impl ByteStreamSource for TestAsyncSource {
        async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
            if self.force_timeout {
                return Err(StreamError::Timeout);
            }
            if !self.delay.is_zero() {
                tokio::select! {
                    _ = self.cancel.cancelled() => return Err(StreamError::Cancelled),
                    _ = tokio::time::sleep(self.delay) => {}
                }
            }
            let start = offset as usize;
            if start >= self.data.len() {
                return Ok(0);
            }
            let n = (self.data.len() - start).min(buf.len());
            buf[..n].copy_from_slice(&self.data[start..start + n]);
            Ok(n)
        }

        fn len(&self) -> Option<u64> {
            Some(self.data.len() as u64)
        }

        fn cancel(&self) {
            self.cancel.cancel();
        }

        fn cancellation_token(&self) -> CancellationToken {
            self.cancel.clone()
        }

        fn hint_extension(&self) -> Option<&str> {
            Some("flac")
        }

        fn mime_type(&self) -> Option<&str> {
            Some("audio/flac")
        }

        async fn seek_to_time_ms(
            &self,
            target_ms: u64,
        ) -> Result<Option<SegmentedSeekTarget>, StreamError> {
            Ok(Some(SegmentedSeekTarget {
                virtual_offset: 0,
                segment_index: (target_ms / 2000) as usize,
                segment_start_ms: (target_ms / 2000) * 2000,
            }))
        }
    }

    #[test]
    fn test_blocking_bridge_read_seek_and_timeline_reset_on_os_thread() {
        let payload: Vec<u8> = (0..8192).map(|i| (i & 0xFF) as u8).collect();
        let src = Arc::new(TestAsyncSource {
            data: payload.clone(),
            delay: Duration::ZERO,
            force_timeout: false,
            cancel: CancellationToken::new(),
        });

        let mut bridge = BlockingStreamBridge::new(src).unwrap();
        assert!(bridge.is_seekable());
        assert_eq!(bridge.byte_len(), Some(8192));

        let mut buf = [0u8; 256];
        let n = bridge.read(&mut buf).unwrap();
        assert_eq!(n, 256);
        assert_eq!(&buf[..], &payload[..256]);
        assert_eq!(bridge.position(), 256);

        assert_eq!(bridge.seek(SeekFrom::Start(4096)).unwrap(), 4096);
        let n2 = bridge.read(&mut buf).unwrap();
        assert_eq!(n2, 256);
        assert_eq!(&buf[..], &payload[4096..4352]);

        assert_eq!(bridge.seek(SeekFrom::End(-100)).unwrap(), 8092);
        let mut tail = [0u8; 256];
        assert_eq!(bridge.read(&mut tail).unwrap(), 100);
        assert_eq!(&tail[..100], &payload[8092..]);
        assert_eq!(bridge.read(&mut tail).unwrap(), 0);

        // Timeline seek resets virtual position to 0.
        let target = bridge.seek_to_time_ms(5000).unwrap().unwrap();
        assert_eq!(target.segment_index, 2);
        assert_eq!(bridge.position(), 0);

        bridge.reset_position(128);
        assert_eq!(bridge.position(), 128);
    }

    #[test]
    fn test_blocking_bridge_instant_cancel_and_timeout_without_deadlock() {
        let src = Arc::new(TestAsyncSource {
            data: vec![7u8; 4096],
            delay: Duration::from_secs(10),
            force_timeout: false,
            cancel: CancellationToken::new(),
        });
        let mut bridge =
            BlockingStreamBridge::new(Arc::clone(&src) as Arc<dyn ByteStreamSource>).unwrap();

        let cancel_handle = src.cancellation_token();
        let starter = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(40));
            cancel_handle.cancel();
        });

        let started = Instant::now();
        let mut buf = [0u8; 64];
        let err = bridge.read(&mut buf).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::Interrupted);
        assert!(started.elapsed() < Duration::from_millis(500));
        starter.join().unwrap();

        // Subsequent seek or read on cancelled bridge fails immediately with Interrupted.
        assert_eq!(
            bridge.seek(SeekFrom::Start(0)).unwrap_err().kind(),
            ErrorKind::Interrupted
        );

        // Timeout maps cleanly to ErrorKind::TimedOut.
        let timeout_src = Arc::new(TestAsyncSource {
            data: vec![7u8; 64],
            delay: Duration::ZERO,
            force_timeout: true,
            cancel: CancellationToken::new(),
        });
        let mut timeout_bridge = BlockingStreamBridge::new(timeout_src).unwrap();
        let err_to = timeout_bridge.read(&mut buf).unwrap_err();
        assert_eq!(err_to.kind(), ErrorKind::TimedOut);
    }
}
