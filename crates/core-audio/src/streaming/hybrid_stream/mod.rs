use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use bytes::Bytes;
use core_types::StreamKey;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::chunked_proxy::{ChunkedStreamProxy, OverlapVerifyOutcome};
use super::l2_cache::{L2CacheManager, L2DirectHit, L2FileLease};
use super::{ByteStreamSource, StreamError, streaming_runtime};

pub use super::{FormatMismatchCallback, FormatMismatchReason};

#[cfg(test)]
mod tests;

#[derive(Debug, Clone)]
enum HybridVerifyFailure {
    Mismatch(FormatMismatchReason),
    Stream(StreamError),
}

/// [`ByteStreamSource`] splicing an instantaneously served L2 `.head` byte prefix `[0, cached_bytes)`
/// into a background-verified [`ChunkedStreamProxy`] covering `[cached_bytes, total_content_length)`.
pub struct HybridByteStream {
    key: StreamKey,
    head_bytes: Bytes,
    cached_bytes: u64,
    total_content_length: u64,
    remote_proxy: Arc<ChunkedStreamProxy>,
    _lease: L2FileLease,
    cancel: CancellationToken,
    verify_rx: watch::Receiver<Option<Result<(), HybridVerifyFailure>>>,
    mismatch_reason: Arc<Mutex<Option<FormatMismatchReason>>>,
}

impl HybridByteStream {
    /// Constructs a [`HybridByteStream`] from an [`L2DirectHit`] and immediately spawns background
    /// 64-byte overlap verification against `remote_proxy`.
    ///
    /// Reads inside `[0, cached_bytes)` complete in `< 1 ms` with zero network I/O, even if a
    /// mismatch occurs later (preserving smooth Active Deck playback during Standby takeover).
    pub fn new(
        key: StreamKey,
        hit: L2DirectHit,
        remote_proxy: Arc<ChunkedStreamProxy>,
        l2_manager: Arc<L2CacheManager>,
        on_mismatch: Option<FormatMismatchCallback>,
    ) -> Result<Self, StreamError> {
        let total_content_length = hit
            .total_content_length
            .or_else(|| remote_proxy.len())
            .ok_or_else(|| {
                StreamError::Unsupported(
                    "HybridByteStream requires known total_content_length".to_string(),
                )
            })?;

        let head_bytes = hit.head_bytes;
        let cached_bytes = (head_bytes.len() as u64).min(total_content_length);
        let expected_tail = hit.tail_fingerprint;
        let cancel = remote_proxy.cancellation_token();
        let mismatch_reason = Arc::new(Mutex::new(None));
        let notified = Arc::new(AtomicBool::new(false));
        let (verify_tx, verify_rx) = watch::channel(None);

        let rt_handle = streaming_runtime()
            .ok()
            .map(|rt| rt.handle().clone())
            .or_else(|| tokio::runtime::Handle::try_current().ok())
            .ok_or_else(|| StreamError::Io("No Tokio runtime for HybridByteStream".to_string()))?;

        let bg_proxy = Arc::clone(&remote_proxy);
        let bg_key = key.clone();
        let bg_mismatch = Arc::clone(&mismatch_reason);
        let bg_notified = Arc::clone(&notified);
        let bg_l2 = Arc::clone(&l2_manager);
        let bg_cancel = cancel.clone();

        rt_handle.spawn(async move {
            let outcome = tokio::select! {
                biased;
                _ = bg_cancel.cancelled() => Err(StreamError::Cancelled),
                res = bg_proxy.verify_overlap_and_prime_slice(
                    cached_bytes,
                    total_content_length,
                    &expected_tail,
                ) => res,
            };

            match outcome {
                Ok(OverlapVerifyOutcome::Verified) => {
                    let _ = verify_tx.send(Some(Ok(())));
                }
                Ok(OverlapVerifyOutcome::Mismatch(reason)) => {
                    if let Ok(mut guard) = bg_mismatch.lock() {
                        *guard = Some(reason.clone());
                    }
                    // Remove stale L2 entry before notifying so Standby recovery sees a clean cache.
                    let _ = bg_l2.delete_entry(&bg_key).await;
                    if !bg_notified.swap(true, Ordering::SeqCst)
                        && let Some(cb) = on_mismatch
                    {
                        cb(bg_key, reason.clone());
                    }
                    let _ = verify_tx.send(Some(Err(HybridVerifyFailure::Mismatch(reason))));
                }
                Err(err) => {
                    let _ = verify_tx.send(Some(Err(HybridVerifyFailure::Stream(err))));
                }
            }
        });

        Ok(Self {
            key,
            head_bytes,
            cached_bytes,
            total_content_length,
            remote_proxy,
            _lease: hit.lease,
            cancel,
            verify_rx,
            mismatch_reason,
        })
    }

    /// Returns the [`StreamKey`] associated with this hybrid stream.
    pub fn key(&self) -> &StreamKey {
        &self.key
    }

    /// Returns the number of local L2 cached head bytes `[0, cached_bytes)`.
    pub fn cached_bytes(&self) -> u64 {
        self.cached_bytes
    }

    /// Returns the expected total remote byte length.
    pub fn total_content_length(&self) -> u64 {
        self.total_content_length
    }

    /// Returns the detected [`FormatMismatchReason`], if background validation failed due to divergence.
    pub fn mismatch_reason(&self) -> Option<FormatMismatchReason> {
        self.mismatch_reason.lock().ok().and_then(|g| g.clone())
    }

    /// Returns `true` if background 64-byte overlap verification succeeded.
    pub fn is_verified(&self) -> bool {
        matches!(&*self.verify_rx.borrow(), Some(Ok(())))
    }

    /// Waits for background overlap verification to complete (used in tests and diagnostics).
    pub async fn wait_verified(&self) -> Result<(), StreamError> {
        self.await_verification()
            .await
            .map_err(|failure| match failure {
                HybridVerifyFailure::Mismatch(reason) => {
                    StreamError::Io(format!("L2 format mismatch: {reason}"))
                }
                HybridVerifyFailure::Stream(err) => err,
            })
    }

    async fn await_verification(&self) -> Result<(), HybridVerifyFailure> {
        let mut rx = self.verify_rx.clone();
        loop {
            if self.cancel.is_cancelled() {
                return Err(HybridVerifyFailure::Stream(StreamError::Cancelled));
            }
            if let Some(res) = rx.borrow().clone() {
                return res;
            }
            tokio::select! {
                biased;
                _ = self.cancel.cancelled() => {
                    return Err(HybridVerifyFailure::Stream(StreamError::Cancelled));
                }
                changed = rx.changed() => {
                    if changed.is_err() {
                        return Err(HybridVerifyFailure::Stream(StreamError::Cancelled));
                    }
                }
            }
        }
    }
}

#[async_trait]
impl ByteStreamSource for HybridByteStream {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        if buf.is_empty() || offset >= self.total_content_length {
            return Ok(0);
        }

        let max_avail = (self.total_content_length - offset).min(buf.len() as u64) as usize;
        if offset < self.cached_bytes {
            let local_start = offset as usize;
            let local_avail = (self.cached_bytes - offset) as usize;
            let local_copy = local_avail.min(max_avail);
            buf[..local_copy]
                .copy_from_slice(&self.head_bytes[local_start..local_start + local_copy]);

            // Fast path: purely inside local L2 prefix -> 0 network wait, <1 ms.
            if local_copy == max_avail {
                return Ok(local_copy);
            }

            // Boundary-straddling read across `cached_bytes`: wait for verification & splice.
            match self.await_verification().await {
                Ok(()) => match self
                    .remote_proxy
                    .read_at(self.cached_bytes, &mut buf[local_copy..max_avail])
                    .await
                {
                    Ok(remote_n) => return Ok(local_copy + remote_n),
                    Err(StreamError::Cancelled) => return Err(StreamError::Cancelled),
                    Err(_) if self.cancel.is_cancelled() => return Err(StreamError::Cancelled),
                    Err(_) => return Ok(local_copy),
                },
                Err(HybridVerifyFailure::Stream(StreamError::Cancelled)) => {
                    return Err(StreamError::Cancelled);
                }
                Err(_) if self.cancel.is_cancelled() => return Err(StreamError::Cancelled),
                Err(_) => {
                    // Deliver remaining cached prefix cleanly so Active Deck never drops audio.
                    return Ok(local_copy);
                }
            }
        }

        match self.await_verification().await {
            Ok(()) => {
                self.remote_proxy
                    .read_at(offset, &mut buf[..max_avail])
                    .await
            }
            // Signal clean EOF at the end of the cached `.head` prefix on format mismatch so the
            // Active Deck's decoder never raises a fatal decode error while its ring buffer drains
            // through the Standby Deck's `+800ms` micro-crossfade takeover.
            Err(HybridVerifyFailure::Mismatch(_)) => Ok(0),
            Err(HybridVerifyFailure::Stream(err)) => Err(err),
        }
    }

    fn len(&self) -> Option<u64> {
        Some(self.total_content_length)
    }

    fn cancel(&self) {
        self.cancel.cancel();
        self.remote_proxy.cancel();
    }

    fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    fn hint_extension(&self) -> Option<&str> {
        self.remote_proxy.hint_extension()
    }

    fn mime_type(&self) -> Option<&str> {
        self.remote_proxy.mime_type()
    }

    fn reclaim_idle_memory(&self) -> usize {
        self.remote_proxy.reclaim_idle_memory()
    }
}
