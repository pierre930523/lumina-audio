use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use async_trait::async_trait;
use core_types::{NormalizedLoudness, StreamKey};
use reqwest::Client;
use reqwest::header::HeaderMap;
use tokio::sync::{Mutex as AsyncMutex, watch};
use tokio_util::sync::CancellationToken;

use super::{
    ByteStreamSource, DEFAULT_REFRESH_403_BACKOFFS, FormatMismatchReason, ReqwestStreamTransport,
    StreamError, StreamHttpConfig, StreamHttpTransport, StreamRefreshHandler,
    build_sanitized_headers, subscribe_network_epoch,
};

/// Outcome of validating an L2 cached tail overlap against the remote range origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OverlapVerifyOutcome {
    Verified,
    Mismatch(FormatMismatchReason),
}

/// Default startup & post-seek first HTTP/2 Range chunk size: 128 KiB.
pub const DEFAULT_INITIAL_CHUNK_SIZE: usize = 128 * 1024;

/// Default steady-state / sequential read-ahead HTTP/2 Range chunk size: 512 KiB.
pub const DEFAULT_CHUNK_SIZE: usize = 512 * 1024;

/// Deezer 6144-byte stripe-aligned startup/seek chunk size (`21 * 6144 = 129_024` bytes).
pub const DEEZER_INITIAL_CHUNK_SIZE: usize = 21 * 6144;

/// Deezer 6144-byte stripe-aligned steady-state chunk size (`85 * 6144 = 522_240` bytes).
pub const DEEZER_ALIGNED_CHUNK_SIZE: usize = 85 * 6144;

/// Legacy default chunk-count hint (retained for API compatibility).
pub const DEFAULT_MAX_CACHED_CHUNKS: usize = 8;

/// Default in-memory RAM LRU byte cap for cached byte-range spans: 16 MiB.
pub const DEFAULT_MAX_CACHE_BYTES: usize = 16 * 1024 * 1024;

/// Default number of sequential 512 KiB chunks prefetched asynchronously ahead of playback (1.5 MiB).
pub const DEFAULT_CHUNK_PREFETCH_AHEAD: usize = 3;

pub(super) const UNSET_FIRST_CHUNK_MS: u64 = u64::MAX;
pub(super) const THROUGHPUT_LOG_INTERVAL_MS: u64 = 5_000;

/// Read-only streaming latency and throughput telemetry snapshot for [`ChunkedStreamProxy`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ChunkedProxyMetrics {
    pub first_chunk_ms: Option<u64>,
    pub download_kbps: u64,
    pub total_downloaded_bytes: u64,
}

mod cache;
mod fetcher;
mod overlap;
mod recovery;
mod transport_io;

#[cfg(test)]
mod tests_range;
#[cfg(test)]
mod tests_resilience;

use cache::{ProxyState, RangeLruCache};
use transport_io::ChunkTelemetry;

pub struct ChunkedStreamProxy {
    pub(super) url: Arc<RwLock<String>>,
    pub(super) headers: Arc<RwLock<HeaderMap>>,
    pub(super) key: Option<StreamKey>,
    pub(super) expected_kind: String,
    pub(super) bitrate_bps: Option<u64>,
    pub(super) refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    pub(super) refresh_lock: Arc<AsyncMutex<()>>,
    pub(super) refresh_backoffs: [Duration; 2],
    pub(super) epoch_rx: watch::Receiver<u64>,
    pub(super) needs_network_epoch_reset: bool,
    pub(super) initial_chunk_size: usize,
    pub(super) chunk_size: usize,
    pub(super) alignment: usize,
    pub(super) prefetch_ahead: usize,
    pub(super) content_length: Arc<Mutex<Option<u64>>>,
    pub(super) probe_lock: AsyncMutex<()>,
    pub(super) hint_extension: Option<String>,
    pub(super) mime_type: Option<String>,
    pub(super) loudness: Option<NormalizedLoudness>,
    pub(super) album_loudness: Option<NormalizedLoudness>,
    pub(super) cancel: CancellationToken,
    pub(super) transport: Arc<dyn StreamHttpTransport>,
    pub(super) config: StreamHttpConfig,
    state: Arc<Mutex<ProxyState>>,
    pub(super) active_downloads: Arc<AtomicUsize>,
    pub(super) has_delivered_bytes: Arc<AtomicBool>,
    telemetry: Arc<ChunkTelemetry>,
}

impl ChunkedStreamProxy {
    /// Creates a new `ChunkedStreamProxy` using the shared HTTP/2 transport with 128 KiB initial/seek
    /// chunks, 512 KiB sequential read-ahead chunks, and a 16 MiB RAM LRU cache.
    pub fn new(
        url: impl Into<String>,
        headers: &BTreeMap<String, String>,
        content_length: Option<u64>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
    ) -> Result<Self, StreamError> {
        let transport = Arc::new(ReqwestStreamTransport::shared()?);
        Self::with_transport(
            url,
            headers,
            content_length,
            hint_extension,
            mime_type,
            transport,
        )
    }

    /// Creates a new `ChunkedStreamProxy` with a custom `reqwest::Client`.
    pub fn with_client(
        url: impl Into<String>,
        headers: &BTreeMap<String, String>,
        content_length: Option<u64>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
        client: Client,
    ) -> Result<Self, StreamError> {
        Self::with_transport(
            url,
            headers,
            content_length,
            hint_extension,
            mime_type,
            Arc::new(ReqwestStreamTransport::from_client(client)),
        )
    }

    /// Creates a new `ChunkedStreamProxy` backed by an injectable [`StreamHttpTransport`].
    pub fn with_transport(
        url: impl Into<String>,
        headers: &BTreeMap<String, String>,
        content_length: Option<u64>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
        transport: Arc<dyn StreamHttpTransport>,
    ) -> Result<Self, StreamError> {
        let header_map = build_sanitized_headers(headers)?;
        Ok(Self {
            url: Arc::new(RwLock::new(url.into())),
            headers: Arc::new(RwLock::new(header_map)),
            key: None,
            expected_kind: "direct_range".to_string(),
            bitrate_bps: None,
            refresh_handler: None,
            refresh_lock: Arc::new(AsyncMutex::new(())),
            refresh_backoffs: DEFAULT_REFRESH_403_BACKOFFS,
            epoch_rx: subscribe_network_epoch(),
            needs_network_epoch_reset: false,
            initial_chunk_size: DEFAULT_INITIAL_CHUNK_SIZE,
            chunk_size: DEFAULT_CHUNK_SIZE,
            alignment: 1,
            prefetch_ahead: DEFAULT_CHUNK_PREFETCH_AHEAD,
            content_length: Arc::new(Mutex::new(content_length)),
            probe_lock: AsyncMutex::new(()),
            hint_extension: hint_extension
                .map(|s| s.trim().trim_start_matches('.').to_ascii_lowercase())
                .filter(|s| !s.is_empty()),
            mime_type: mime_type
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
            loudness: None,
            album_loudness: None,
            cancel: CancellationToken::new(),
            transport,
            config: StreamHttpConfig::default(),
            state: Arc::new(Mutex::new(ProxyState {
                cache: RangeLruCache::new(DEFAULT_MAX_CACHE_BYTES),
                in_flight: Vec::new(),
                next_flight_id: 1,
                last_read_end: None,
            })),
            active_downloads: Arc::new(AtomicUsize::new(0)),
            has_delivered_bytes: Arc::new(AtomicBool::new(false)),
            telemetry: Arc::new(ChunkTelemetry::new()),
        })
    }

    /// Attaches stream identity, injectable 403/410 self-healing callback, and network-epoch
    /// reset capability metadata.
    pub fn with_refresh_context(
        mut self,
        key: StreamKey,
        handler: Arc<dyn StreamRefreshHandler>,
        needs_network_epoch_reset: bool,
    ) -> Self {
        self.key = Some(key);
        self.refresh_handler = Some(handler);
        self.needs_network_epoch_reset = needs_network_epoch_reset;
        self
    }

    /// Attaches a [`StreamKey`] without a refresh handler (preserves `provider_id` on HTTP 401).
    pub fn with_stream_key(mut self, key: StreamKey) -> Self {
        self.key = Some(key);
        self
    }

    /// Sets expected `StreamSourceSpec` wire kind (`"direct_range"` or `"encrypted_range"`).
    pub fn with_expected_kind(mut self, kind: impl Into<String>) -> Self {
        self.expected_kind = kind.into();
        self
    }

    /// Attaches source bitrate and normalized loudness metadata so synthesized
    /// format-change reload specs preserve gain normalization across refreshes.
    pub fn with_spec_metadata(
        mut self,
        bitrate_bps: Option<u64>,
        loudness: Option<NormalizedLoudness>,
        album_loudness: Option<NormalizedLoudness>,
    ) -> Self {
        self.bitrate_bps = bitrate_bps;
        self.loudness = loudness;
        self.album_loudness = album_loudness;
        self
    }

    /// Overrides the 2-attempt 403/410 retry backoff delays (defaults to `[300ms, 1000ms]`).
    pub fn with_refresh_backoffs(mut self, backoffs: [Duration; 2]) -> Self {
        self.refresh_backoffs = backoffs;
        self
    }

    /// Binds a custom network epoch receiver (useful for isolated deterministic tests).
    pub fn with_network_epoch_rx(mut self, rx: watch::Receiver<u64>) -> Self {
        self.epoch_rx = rx;
        self
    }

    /// Overrides the steady-state / read-ahead HTTP `Range` chunk size in bytes.
    /// Also clamps `initial_chunk_size` if it exceeds the new `chunk_size`, and automatically
    /// enables 6144-byte Deezer stripe alignment (`129,024` B first chunk) when configured with
    /// [`DEEZER_ALIGNED_CHUNK_SIZE`].
    pub fn with_chunk_size(mut self, chunk_size: usize) -> Self {
        self.chunk_size = chunk_size.max(1);
        if self.chunk_size == DEEZER_ALIGNED_CHUNK_SIZE {
            if self.alignment == 1 {
                self.alignment = 6144;
            }
            if self.initial_chunk_size == DEFAULT_INITIAL_CHUNK_SIZE {
                self.initial_chunk_size = DEEZER_INITIAL_CHUNK_SIZE;
            }
        }
        if self.initial_chunk_size > self.chunk_size {
            self.initial_chunk_size = self.chunk_size;
        }
        self
    }

    /// Overrides the startup and post-seek first HTTP `Range` chunk size in bytes.
    pub fn with_initial_chunk_size(mut self, initial_chunk_size: usize) -> Self {
        self.initial_chunk_size = initial_chunk_size.max(1);
        self
    }

    /// Sets byte-boundary alignment for all HTTP `Range` requests (e.g. `6144` for Deezer stripes).
    pub fn with_range_alignment(mut self, alignment: usize) -> Self {
        self.alignment = alignment.max(1);
        if self.alignment > 1 && !self.initial_chunk_size.is_multiple_of(self.alignment) {
            self.initial_chunk_size = (self.initial_chunk_size / self.alignment)
                .max(1)
                .saturating_mul(self.alignment);
        }
        self
    }

    /// Overrides the in-memory RAM LRU cache byte budget.
    pub fn with_max_cache_bytes(self, max_bytes: usize) -> Self {
        if let Ok(mut st) = self.state.lock() {
            st.cache = RangeLruCache::new(max_bytes);
        }
        self
    }

    /// Overrides the RAM LRU capacity expressed as a multiple of `chunk_size`.
    pub fn with_max_cached_chunks(self, max_chunks: usize) -> Self {
        let bytes = max_chunks.max(1).saturating_mul(self.chunk_size);
        self.with_max_cache_bytes(bytes)
    }

    /// Overrides HTTP timeouts and redirect limits.
    pub fn with_http_config(mut self, config: StreamHttpConfig) -> Self {
        self.config = config;
        self
    }

    /// Binds an external [`CancellationToken`] for upstream lifecycle coordination.
    pub fn with_cancellation_token(mut self, token: CancellationToken) -> Self {
        self.cancel = token;
        self
    }

    /// Overrides the number of sequential chunks prefetched asynchronously ahead of playback.
    pub fn with_prefetch_ahead(mut self, ahead: usize) -> Self {
        self.prefetch_ahead = ahead;
        self
    }

    /// Returns the configured steady-state HTTP `Range` chunk size in bytes.
    pub fn chunk_size(&self) -> usize {
        self.chunk_size
    }

    /// Returns the configured startup/seek first-chunk size in bytes.
    pub fn initial_chunk_size(&self) -> usize {
        self.initial_chunk_size
    }

    /// Returns the configured HTTP `Range` byte alignment (`1` by default, `6144` for Deezer).
    pub fn range_alignment(&self) -> usize {
        self.alignment
    }

    /// Returns the configured number of sequential chunks prefetched asynchronously ahead.
    pub fn prefetch_ahead(&self) -> usize {
        self.prefetch_ahead
    }

    /// Returns a read-only snapshot of first-chunk latency and rolling download throughput metrics.
    pub fn metrics(&self) -> ChunkedProxyMetrics {
        self.telemetry.snapshot()
    }

    /// Returns total bytes currently resident in the RAM LRU cache.
    pub fn cached_bytes(&self) -> usize {
        self.state
            .lock()
            .map(|st| st.cache.total_bytes)
            .unwrap_or(0)
    }

    /// Returns the number of currently active in-flight HTTP downloads for this proxy instance.
    pub fn active_downloads(&self) -> usize {
        self.active_downloads.load(Ordering::SeqCst)
    }

    /// Returns the active URL currently targeted by this proxy.
    pub fn current_url(&self) -> String {
        self.url.read().map(|g| g.clone()).unwrap_or_default()
    }

    /// Returns whether this proxy's provider requires network-epoch resets.
    pub fn needs_network_epoch_reset(&self) -> bool {
        self.needs_network_epoch_reset
    }

    /// Returns a cloned handle to the underlying [`StreamHttpTransport`].
    pub fn transport(&self) -> Arc<dyn StreamHttpTransport> {
        Arc::clone(&self.transport)
    }

    /// Returns a reference to the underlying [`StreamHttpTransport`] for test verification.
    pub fn test_transport(&self) -> &Arc<dyn StreamHttpTransport> {
        &self.transport
    }

    /// Returns the active [`StreamHttpConfig`].
    pub fn http_config(&self) -> StreamHttpConfig {
        self.config
    }
}

#[async_trait]
impl ByteStreamSource for ChunkedStreamProxy {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        if buf.is_empty() {
            return Ok(0);
        }

        let total_len = self.ensure_content_length().await?;
        if offset >= total_len {
            return Ok(0);
        }

        let was_sequential_call = self
            .state
            .lock()
            .ok()
            .is_some_and(|st| st.last_read_end == Some(offset));

        let mut cursor = offset;
        let mut written = 0usize;
        let mut last_span: Option<(u64, usize)> = None;

        while written < buf.len() && cursor < total_len {
            let (span_start, chunk) = self
                .get_or_fetch_span_covering(cursor, total_len, was_sequential_call)
                .await?;
            let in_chunk_offset = cursor.saturating_sub(span_start) as usize;

            if in_chunk_offset >= chunk.len() {
                break;
            }

            let available = &chunk[in_chunk_offset..];
            let to_copy = available.len().min(buf.len() - written);
            buf[written..written + to_copy].copy_from_slice(&available[..to_copy]);
            written += to_copy;
            cursor += to_copy as u64;
            last_span = Some((span_start, chunk.len()));
        }

        if written > 0 {
            self.has_delivered_bytes.store(true, Ordering::Release);
            if let Ok(mut st) = self.state.lock() {
                st.last_read_end = Some(cursor);
            }
            if was_sequential_call && let Some((span_start, span_len)) = last_span {
                self.maybe_schedule_read_ahead(span_start, span_len, cursor, total_len);
            }
        }

        Ok(written)
    }

    fn len(&self) -> Option<u64> {
        self.content_length.lock().ok().and_then(|g| *g)
    }

    fn cancel(&self) {
        self.cancel.cancel();
    }

    fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    fn hint_extension(&self) -> Option<&str> {
        self.hint_extension.as_deref()
    }

    fn mime_type(&self) -> Option<&str> {
        self.mime_type.as_deref()
    }

    fn reclaim_idle_memory(&self) -> usize {
        self.state
            .lock()
            .map(|mut st| {
                let keep = st.last_read_end;
                st.cache.retain_only_covering(keep)
            })
            .unwrap_or(0)
    }
}
