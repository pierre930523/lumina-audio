use std::io::{IoSliceMut, Read, Seek, SeekFrom};
use std::sync::{Arc, Mutex};

use symphonia::core::io::MediaSource;

use crate::error::DecoderError;
use crate::streaming::{BlockingStreamBridge, StreamError};

pub(super) struct SharedBridgeMediaSource(pub(super) Arc<Mutex<BlockingStreamBridge>>);

impl Read for SharedBridgeMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let mut guard = self
            .0
            .lock()
            .map_err(|_| std::io::Error::other("BlockingStreamBridge lock poisoned"))?;
        guard.read(buf)
    }
}

impl Seek for SharedBridgeMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let mut guard = self
            .0
            .lock()
            .map_err(|_| std::io::Error::other("BlockingStreamBridge lock poisoned"))?;
        guard.seek(pos)
    }
}

impl MediaSource for SharedBridgeMediaSource {
    fn is_seekable(&self) -> bool {
        self.0
            .lock()
            .map(|guard| guard.is_seekable())
            .unwrap_or(false)
    }

    fn byte_len(&self) -> Option<u64> {
        self.0.lock().ok().and_then(|guard| guard.byte_len())
    }
}

pub(super) struct GenericSource<R> {
    inner: R,
    byte_len: Option<u64>,
}

impl<R: Read + Seek> GenericSource<R> {
    pub(super) fn new(mut inner: R) -> Self {
        let byte_len = inner.stream_position().ok().and_then(|pos| {
            let end = inner.seek(SeekFrom::End(0)).ok();
            let _ = inner.seek(SeekFrom::Start(pos));
            end
        });
        Self { inner, byte_len }
    }
}

impl<R: Read> Read for GenericSource<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl<R: Seek> Seek for GenericSource<R> {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        self.inner.seek(pos)
    }
}

impl<R: Read + Seek + Send + Sync + 'static> MediaSource for GenericSource<R> {
    fn is_seekable(&self) -> bool {
        true
    }
    fn byte_len(&self) -> Option<u64> {
        self.byte_len
    }
}

/// Preserves underlying non-EOF I/O errors (such as `HTTP 403`) across Symphonia's
/// `Probe::next` / `MediaSourceStream` loops that otherwise downgrade `Err` into
/// `UnexpectedEof` or `no suitable format reader found`.
pub(super) struct ErrorTrackingMediaSource {
    pub(super) inner: Box<dyn MediaSource>,
    pub(super) last_io_error: Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
}

impl ErrorTrackingMediaSource {
    fn record_error(&self, err: &std::io::Error) {
        if err.kind() == std::io::ErrorKind::UnexpectedEof {
            return;
        }
        if let Ok(mut guard) = self.last_io_error.lock()
            && guard.is_none()
        {
            *guard = Some((err.kind(), err.to_string()));
        }
    }
}

impl Read for ErrorTrackingMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let res = self.inner.read(buf);
        if let Err(ref e) = res {
            self.record_error(e);
        }
        res
    }

    fn read_vectored(&mut self, bufs: &mut [IoSliceMut<'_>]) -> std::io::Result<usize> {
        let res = self.inner.read_vectored(bufs);
        if let Err(ref e) = res {
            self.record_error(e);
        }
        res
    }
}

impl Seek for ErrorTrackingMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let res = self.inner.seek(pos);
        if let Err(ref e) = res {
            self.record_error(e);
        }
        res
    }
}

impl MediaSource for ErrorTrackingMediaSource {
    fn is_seekable(&self) -> bool {
        self.inner.is_seekable()
    }

    fn byte_len(&self) -> Option<u64> {
        self.inner.byte_len()
    }
}

pub(super) fn clear_tracked_io_error(slot: &Arc<Mutex<Option<(std::io::ErrorKind, String)>>>) {
    if let Ok(mut guard) = slot.lock() {
        *guard = None;
    }
}

pub(super) fn take_tracked_io_error(
    slot: &Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
) -> Option<(std::io::ErrorKind, String)> {
    slot.lock().ok().and_then(|mut g| g.take())
}

pub(super) fn format_with_tracked_io_error(
    base: impl std::fmt::Display,
    slot: &Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
) -> String {
    let base_str = base.to_string();
    match take_tracked_io_error(slot) {
        Some((_, io_err)) if !base_str.contains(&io_err) => format!("{io_err} ({base_str})"),
        _ => base_str,
    }
}

pub(super) fn map_typed_stream_error(err: StreamError) -> Option<DecoderError> {
    match err {
        StreamError::AuthRequired {
            provider_id,
            status,
        } => Some(DecoderError::StreamAuthRequired {
            provider_id,
            status,
        }),
        StreamError::FormatChanged(spec) => Some(DecoderError::StreamFormatChanged(spec)),
        _ => None,
    }
}

pub(super) fn take_typed_bridge_error(
    bridge: Option<&Arc<Mutex<BlockingStreamBridge>>>,
) -> Option<DecoderError> {
    bridge
        .and_then(|b| b.lock().ok())
        .and_then(|guard| guard.take_last_stream_error())
        .and_then(map_typed_stream_error)
}
