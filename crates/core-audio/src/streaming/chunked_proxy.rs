use std::collections::{BTreeMap, VecDeque};
use std::ops::Bound;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use core_types::{NormalizedLoudness, StreamKey, StreamSourceSpec};
use reqwest::header::HeaderMap;
use reqwest::{Client, Method};
use tokio::sync::{Mutex as AsyncMutex, watch};
use tokio_util::sync::CancellationToken;

use super::{
    ByteStreamSource, DEFAULT_REFRESH_403_BACKOFFS, FormatMismatchReason, HttpRequestSpec,
    InFlightDownloadGuard, ReqwestStreamTransport, StreamError, StreamHttpConfig,
    StreamHttpTransport, StreamRefreshHandler, StreamRefreshOutcome, StreamRefreshRequest,
    accepts_byte_ranges, await_watch_result, build_sanitized_headers, execute_with_epoch_watch,
    header_map_to_btree, normalize_mime_base, same_trusted_redirect_scope, streaming_runtime,
    strip_sensitive_cross_origin_headers, subscribe_network_epoch,
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

const UNSET_FIRST_CHUNK_MS: u64 = u64::MAX;
const THROUGHPUT_LOG_INTERVAL_MS: u64 = 5_000;

/// Read-only streaming latency and throughput telemetry snapshot for [`ChunkedStreamProxy`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ChunkedProxyMetrics {
    pub first_chunk_ms: Option<u64>,
    pub download_kbps: u64,
    pub total_downloaded_bytes: u64,
}

struct ChunkTelemetry {
    created_at: Instant,
    first_chunk_ms: AtomicU64,
    total_downloaded_bytes: AtomicU64,
    total_download_us: AtomicU64,
    first_chunk_logged: AtomicBool,
    last_log_ms: AtomicU64,
}

impl ChunkTelemetry {
    fn new() -> Self {
        Self {
            created_at: Instant::now(),
            first_chunk_ms: AtomicU64::new(UNSET_FIRST_CHUNK_MS),
            total_downloaded_bytes: AtomicU64::new(0),
            total_download_us: AtomicU64::new(0),
            first_chunk_logged: AtomicBool::new(false),
            last_log_ms: AtomicU64::new(0),
        }
    }

    /// Records a completed HTTP chunk download strictly on a non-audio network worker thread.
    fn record_download(
        &self,
        provider_id: &str,
        track_id: &str,
        start: u64,
        bytes_len: usize,
        chunk_elapsed: Duration,
    ) {
        if bytes_len == 0 {
            return;
        }
        let chunk_us = (chunk_elapsed.as_micros() as u64).max(1);
        let total_bytes = self
            .total_downloaded_bytes
            .fetch_add(bytes_len as u64, Ordering::Relaxed)
            .saturating_add(bytes_len as u64);
        let total_us = self
            .total_download_us
            .fetch_add(chunk_us, Ordering::Relaxed)
            .saturating_add(chunk_us);

        let download_kbps = ((total_bytes as u128).saturating_mul(8_000) / (total_us.max(1) as u128)) as u64;
        let chunk_kbps = ((bytes_len as u128).saturating_mul(8_000) / (chunk_us as u128)) as u64;
        let since_open_ms = self.created_at.elapsed().as_millis() as u64;

        if !self.first_chunk_logged.swap(true, Ordering::AcqRel) {
            self.first_chunk_ms.store(since_open_ms, Ordering::Release);
            self.last_log_ms.store(since_open_ms, Ordering::Relaxed);
            tracing::info!(
                provider = provider_id,
                track = track_id,
                start,
                bytes = bytes_len,
                first_chunk_ms = since_open_ms,
                download_kbps,
                chunk_kbps,
                "ChunkedStreamProxy first chunk received"
            );
            eprintln!(
                "[LuminaStream] first_chunk provider={provider_id} track={track_id} first_chunk_ms={since_open_ms} bytes={bytes_len} download_kbps={download_kbps}"
            );
        } else {
            let prev_ms = self.last_log_ms.load(Ordering::Relaxed);
            if since_open_ms.saturating_sub(prev_ms) >= THROUGHPUT_LOG_INTERVAL_MS
                && self
                    .last_log_ms
                    .compare_exchange(prev_ms, since_open_ms, Ordering::Relaxed, Ordering::Relaxed)
                    .is_ok()
            {
                tracing::info!(
                    provider = provider_id,
                    track = track_id,
                    total_bytes,
                    download_kbps,
                    chunk_kbps,
                    "ChunkedStreamProxy throughput update"
                );
                eprintln!(
                    "[LuminaStream] throughput provider={provider_id} track={track_id} total_bytes={total_bytes} download_kbps={download_kbps} chunk_kbps={chunk_kbps}"
                );
            }
        }
    }

    fn snapshot(&self) -> ChunkedProxyMetrics {
        let fc = self.first_chunk_ms.load(Ordering::Acquire);
        let first_chunk_ms = (fc != UNSET_FIRST_CHUNK_MS).then_some(fc);
        let total_bytes = self.total_downloaded_bytes.load(Ordering::Relaxed);
        let total_us = self.total_download_us.load(Ordering::Relaxed);
        let download_kbps = if total_us > 0 {
            ((total_bytes as u128).saturating_mul(8_000) / (total_us as u128)) as u64
        } else {
            0
        };
        ChunkedProxyMetrics {
            first_chunk_ms,
            download_kbps,
            total_downloaded_bytes: total_bytes,
        }
    }
}

struct FetchedRange {
    requested: Bytes,
    full_body_200: Option<Bytes>,
    raw_downloaded_bytes: usize,
}

type InFlightChunkRx = watch::Receiver<Option<Result<Bytes, StreamError>>>;

#[derive(Debug)]
struct RangeLruCache {
    max_bytes: usize,
    total_bytes: usize,
    /// Non-overlapping byte spans keyed by `start_offset`.
    entries: BTreeMap<u64, Bytes>,
    /// LRU recency order of `start_offset` keys (front = oldest, back = MRU).
    lru: VecDeque<u64>,
}

impl RangeLruCache {
    fn new(max_bytes: usize) -> Self {
        Self {
            max_bytes: max_bytes.max(1),
            total_bytes: 0,
            entries: BTreeMap::new(),
            lru: VecDeque::new(),
        }
    }

    fn touch(&mut self, start: u64) {
        if let Some(pos) = self.lru.iter().position(|&k| k == start) {
            self.lru.remove(pos);
            self.lru.push_back(start);
        }
    }

    fn get_covering(&mut self, offset: u64) -> Option<(u64, Bytes)> {
        let (&start, data) = self.entries.range(..=offset).next_back()?;
        if offset >= start.saturating_add(data.len() as u64) {
            return None;
        }
        let cloned = data.clone();
        self.touch(start);
        Some((start, cloned))
    }

    fn covering_bounds(&self, offset: u64) -> Option<(u64, u64)> {
        let (&start, data) = self.entries.range(..=offset).next_back()?;
        let end = start.saturating_add(data.len() as u64);
        (offset < end).then_some((start, end))
    }

    fn has_contiguous_predecessor(&self, offset: u64) -> bool {
        if offset == 0 {
            return false;
        }
        self.entries
            .range(..offset)
            .next_back()
            .is_some_and(|(&start, data)| start.saturating_add(data.len() as u64) == offset)
    }

    fn next_start_after(&self, offset: u64) -> Option<u64> {
        self.entries
            .range((Bound::Excluded(offset), Bound::Unbounded))
            .next()
            .map(|(&s, _)| s)
    }

    fn insert(&mut self, start: u64, bytes: Bytes) {
        if bytes.is_empty() {
            return;
        }
        let new_end = start.saturating_add(bytes.len() as u64);

        // Remove any existing spans overlapping [start, new_end) to maintain strict non-overlap.
        let mut overlapping = Vec::new();
        if let Some((&prev_s, prev_b)) = self.entries.range(..start).next_back()
            && prev_s.saturating_add(prev_b.len() as u64) > start
        {
            overlapping.push(prev_s);
        }
        for (&s, _) in self.entries.range(start..new_end) {
            overlapping.push(s);
        }
        for k in overlapping {
            if let Some(old) = self.entries.remove(&k) {
                self.total_bytes = self.total_bytes.saturating_sub(old.len());
                if let Some(pos) = self.lru.iter().position(|&id| id == k) {
                    self.lru.remove(pos);
                }
            }
        }

        self.total_bytes = self.total_bytes.saturating_add(bytes.len());
        self.entries.insert(start, bytes);
        self.lru.push_back(start);

        while self.total_bytes > self.max_bytes && self.entries.len() > 1 {
            let Some(evicted_key) = self.lru.pop_front() else {
                break;
            };
            if let Some(evicted_bytes) = self.entries.remove(&evicted_key) {
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes.len());
            }
        }
    }

    fn retain_only_covering(&mut self, offset: Option<u64>) -> usize {
        let before = self.total_bytes;
        let keep_key = offset.and_then(|off| {
            self.entries
                .range(..=off)
                .next_back()
                .filter(|(start, data)| off < start.saturating_add(data.len() as u64))
                .map(|(&start, _)| start)
                .or_else(|| {
                    let prev = off.saturating_sub(1);
                    self.entries
                        .range(..=prev)
                        .next_back()
                        .filter(|(start, data)| prev < start.saturating_add(data.len() as u64))
                        .map(|(&start, _)| start)
                })
        });
        if let Some(k) = keep_key {
            if let Some(bytes) = self.entries.remove(&k) {
                self.entries.clear();
                self.lru.clear();
                self.total_bytes = bytes.len();
                self.entries.insert(k, bytes);
                self.lru.push_back(k);
            }
        } else {
            self.entries.clear();
            self.lru.clear();
            self.total_bytes = 0;
        }
        before.saturating_sub(self.total_bytes)
    }
}

struct InFlightRange {
    id: u64,
    start: u64,
    end: u64,
    allow_refresh: bool,
    rx: InFlightChunkRx,
}

#[derive(Clone)]
struct ChunkRefreshContext {
    key: Option<StreamKey>,
    expected_kind: String,
    bitrate_bps: Option<u64>,
    hint_extension: Option<String>,
    mime_type: Option<String>,
    loudness: Option<NormalizedLoudness>,
    album_loudness: Option<NormalizedLoudness>,
    content_length: Arc<Mutex<Option<u64>>>,
    url_slot: Arc<RwLock<String>>,
    headers_slot: Arc<RwLock<HeaderMap>>,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    refresh_lock: Arc<AsyncMutex<()>>,
    backoffs: [Duration; 2],
    has_delivered_bytes: Arc<AtomicBool>,
}

impl ChunkRefreshContext {
    fn provider_id(&self) -> String {
        self.key
            .as_ref()
            .map(|k| k.provider_id.clone())
            .unwrap_or_else(|| "unknown".to_string())
    }

    fn track_id(&self) -> String {
        self.key
            .as_ref()
            .map(|k| k.track_id.clone())
            .unwrap_or_else(|| "unknown".to_string())
    }

    fn current_url(&self) -> String {
        self.url_slot
            .read()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    fn current_headers(&self) -> HeaderMap {
        self.headers_slot
            .read()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    fn known_content_length(&self) -> Option<u64> {
        self.content_length.lock().ok().and_then(|g| *g)
    }

    fn update_redirected_url(&self, from_url: &str, final_url: String) {
        if final_url == from_url {
            return;
        }
        let strip_auth = match (reqwest::Url::parse(from_url), reqwest::Url::parse(&final_url)) {
            (Ok(a), Ok(b)) => !same_trusted_redirect_scope(&a, &b),
            _ => false,
        };
        if let Ok(mut g) = self.url_slot.write()
            && *g == from_url
        {
            *g = final_url;
            if strip_auth && let Ok(mut hdrs) = self.headers_slot.write() {
                strip_sensitive_cross_origin_headers(&mut hdrs);
            }
        }
    }

    fn synthesize_format_changed_spec(&self, actual_len: u64) -> StreamSourceSpec {
        let key = self
            .key
            .clone()
            .unwrap_or_else(|| StreamKey::new("unknown", "unknown", "default"));
        StreamSourceSpec::DirectRange {
            key,
            url: self.current_url(),
            headers: header_map_to_btree(&self.current_headers()),
            content_length: Some(actual_len),
            bitrate_bps: self.bitrate_bps,
            mime_type: self.mime_type.clone(),
            hint_extension: self.hint_extension.clone(),
            expire_at: None,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness: self.loudness,
            album_loudness: self.album_loudness,
        }
    }

    fn check_and_apply_refreshed_spec(
        &self,
        new_spec: StreamSourceSpec,
    ) -> Result<StreamSourceSpec, StreamError> {
        let (new_kind, new_url, new_headers, new_len, new_mime, new_ext) = match &new_spec {
            StreamSourceSpec::DirectRange {
                url,
                headers,
                content_length,
                mime_type,
                hint_extension,
                ..
            } => (
                "direct_range",
                url.clone(),
                headers.clone(),
                *content_length,
                mime_type.clone(),
                hint_extension.clone(),
            ),
            StreamSourceSpec::EncryptedRange {
                url,
                headers,
                content_length,
                mime_type,
                hint_extension,
                ..
            } => (
                "encrypted_range",
                url.clone(),
                headers.clone(),
                *content_length,
                mime_type.clone(),
                hint_extension.clone(),
            ),
            _ => return Err(StreamError::FormatChanged(Box::new(new_spec))),
        };

        if !self.expected_kind.is_empty() && new_kind != self.expected_kind {
            return Err(StreamError::FormatChanged(Box::new(new_spec)));
        }
        if let (Some(cur_mime), Some(next_mime)) = (&self.mime_type, &new_mime)
            && normalize_mime_base(cur_mime) != normalize_mime_base(next_mime)
        {
            return Err(StreamError::FormatChanged(Box::new(new_spec)));
        }
        if let (Some(cur_ext), Some(next_ext)) = (&self.hint_extension, &new_ext) {
            let norm_next = next_ext.trim().trim_start_matches('.').to_ascii_lowercase();
            if !norm_next.is_empty() && cur_ext != &norm_next {
                return Err(StreamError::FormatChanged(Box::new(new_spec)));
            }
        }
        if let (Some(expected_len), Some(actual_len)) = (self.known_content_length(), new_len)
            && expected_len != actual_len
        {
            return Err(StreamError::FormatChanged(Box::new(new_spec)));
        }

        let sanitized_headers = build_sanitized_headers(&new_headers)?;
        if let Ok(mut url_guard) = self.url_slot.write() {
            *url_guard = new_url;
        }
        if let Ok(mut hdr_guard) = self.headers_slot.write() {
            *hdr_guard = sanitized_headers;
        }
        Ok(new_spec)
    }
}

fn spec_with_content_length(mut spec: StreamSourceSpec, actual_len: u64) -> StreamSourceSpec {
    match &mut spec {
        StreamSourceSpec::DirectRange { content_length, .. }
        | StreamSourceSpec::EncryptedRange { content_length, .. } => {
            *content_length = Some(actual_len);
        }
        _ => {}
    }
    spec
}

async fn attempt_chunk_refresh_after_403(
    ctx: &ChunkRefreshContext,
    failed_url: &str,
    status_code: u16,
    is_initial_probe: bool,
    refresh_attempts: &mut u8,
    cancel: &CancellationToken,
) -> Result<Option<StreamSourceSpec>, StreamError> {
    let (Some(handler), Some(key)) = (&ctx.refresh_handler, &ctx.key) else {
        tracing::warn!(
            provider = %ctx.provider_id(),
            track = %ctx.track_id(),
            status = status_code,
            initial_probe = is_initial_probe,
            "ChunkedStreamProxy received HTTP {status_code} with no refresh handler"
        );
        eprintln!(
            "[LuminaStream] http_{status_code} no_refresh_handler provider={} track={} initial_probe={is_initial_probe}",
            ctx.provider_id(),
            ctx.track_id()
        );
        return Err(StreamError::HttpStatus(status_code));
    };

    // Fast CAS before lock acquisition
    if ctx.current_url() != failed_url {
        return Ok(None);
    }

    let _guard = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Err(StreamError::Cancelled),
        g = ctx.refresh_lock.lock() => g,
    };

    // Serialized CAS after acquiring refresh_lock
    if ctx.current_url() != failed_url {
        return Ok(None);
    }

    if *refresh_attempts >= 2 {
        tracing::warn!(
            provider = %key.provider_id,
            track = %key.track_id,
            status = status_code,
            initial_probe = is_initial_probe,
            "ChunkedStreamProxy exhausted HTTP {status_code} refresh retries"
        );
        eprintln!(
            "[LuminaStream] http_{status_code} refresh_exhausted provider={} track={} initial_probe={is_initial_probe}",
            key.provider_id,
            key.track_id
        );
        return Err(StreamError::HttpStatus(status_code));
    }
    let delay = ctx.backoffs[*refresh_attempts as usize];
    *refresh_attempts += 1;
    let attempt = *refresh_attempts;

    tracing::warn!(
        provider = %key.provider_id,
        track = %key.track_id,
        status = status_code,
        attempt,
        initial_probe = is_initial_probe,
        "ChunkedStreamProxy triggering HTTP {status_code} refresh"
    );
    eprintln!(
        "[LuminaStream] http_{status_code} refresh attempt={attempt} provider={} track={} initial_probe={is_initial_probe}",
        key.provider_id,
        key.track_id
    );

    if !delay.is_zero() {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(StreamError::Cancelled),
            _ = tokio::time::sleep(delay) => {}
        }
    }

    // Re-check CAS after backoff sleep in case URL changed out-of-band
    if ctx.current_url() != failed_url {
        return Ok(None);
    }

    let req = StreamRefreshRequest {
        provider_id: key.provider_id.clone(),
        track_id: key.track_id.clone(),
        quality_key: key.quality_key.clone(),
        failed_url: failed_url.to_string(),
        status_code,
        attempt,
        expected_content_length: ctx.known_content_length(),
        expected_mime_type: ctx.mime_type.clone(),
        expected_kind: Some(ctx.expected_kind.clone()),
        is_initial_probe,
    };

    match handler.refresh_after_403(req, cancel).await {
        Ok(StreamRefreshOutcome::Refreshed(new_spec)) => {
            let applied = ctx.check_and_apply_refreshed_spec(new_spec)?;
            Ok(Some(applied))
        }
        Ok(StreamRefreshOutcome::FormatChanged(new_spec, _reason)) => {
            Err(StreamError::FormatChanged(Box::new(new_spec)))
        }
        Ok(StreamRefreshOutcome::AuthRequired { provider_id, .. }) => {
            Err(StreamError::AuthRequired {
                provider_id,
                status: 401,
            })
        }
        Err(err @ (StreamError::Cancelled | StreamError::AuthRequired { .. } | StreamError::FormatChanged(_))) => {
            Err(err)
        }
        Err(err) => {
            if *refresh_attempts >= 2 {
                Err(err)
            } else {
                Ok(None)
            }
        }
    }
}

struct ProxyState {
    cache: RangeLruCache,
    in_flight: Vec<InFlightRange>,
    next_flight_id: u64,
    last_read_end: Option<u64>,
}

struct ChunkFlightCleanup {
    flight_id: u64,
    state: Arc<Mutex<ProxyState>>,
    tx: watch::Sender<Option<Result<Bytes, StreamError>>>,
    completed: bool,
}

impl Drop for ChunkFlightCleanup {
    fn drop(&mut self) {
        if let Ok(mut st) = self.state.lock() {
            st.in_flight.retain(|f| f.id != self.flight_id);
        }
        if !self.completed {
            let _ = self.tx.send(Some(Err(StreamError::Cancelled)));
        }
    }
}

/// Adaptive HTTP/2 `Range` proxy using 128 KiB startup/seek chunks, 512 KiB sequential
/// read-ahead chunks (or Deezer `6144`-byte stripe-aligned equivalents), a byte-capped RAM LRU
/// cache for fast backward seeks, single-flight coalescing, strict EOF clamping, and instant
/// cancellation.
pub struct ChunkedStreamProxy {
    url: Arc<RwLock<String>>,
    headers: Arc<RwLock<HeaderMap>>,
    key: Option<StreamKey>,
    expected_kind: String,
    bitrate_bps: Option<u64>,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    refresh_lock: Arc<AsyncMutex<()>>,
    refresh_backoffs: [Duration; 2],
    epoch_rx: watch::Receiver<u64>,
    needs_network_epoch_reset: bool,
    initial_chunk_size: usize,
    chunk_size: usize,
    alignment: usize,
    prefetch_ahead: usize,
    content_length: Arc<Mutex<Option<u64>>>,
    probe_lock: AsyncMutex<()>,
    hint_extension: Option<String>,
    mime_type: Option<String>,
    loudness: Option<NormalizedLoudness>,
    album_loudness: Option<NormalizedLoudness>,
    cancel: CancellationToken,
    transport: Arc<dyn StreamHttpTransport>,
    config: StreamHttpConfig,
    state: Arc<Mutex<ProxyState>>,
    active_downloads: Arc<AtomicUsize>,
    has_delivered_bytes: Arc<AtomicBool>,
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
            mime_type: mime_type.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
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
        if self.alignment > 1 && self.initial_chunk_size % self.alignment != 0 {
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
        self.url
            .read()
            .map(|g| g.clone())
            .unwrap_or_default()
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

    /// Verifies a cached L2 head prefix against the remote origin using a single `Range` fetch
    /// overlapping the trailing 64 bytes at `[cached_bytes - 64, cached_bytes + initial_chunk_size - 1]`,
    /// strips the 64-byte overlap, primes `st.cache` at `cached_bytes`, and triggers read-ahead.
    pub async fn verify_overlap_and_prime_at(
        &self,
        cached_bytes: u64,
        expected_total_len: u64,
        expected_tail_64: &[u8; 64],
    ) -> Result<OverlapVerifyOutcome, StreamError> {
        self.verify_overlap_and_prime_slice(cached_bytes, expected_total_len, expected_tail_64)
            .await
    }

    /// Variant of [`Self::verify_overlap_and_prime_at`] accepting any tail fingerprint slice up to
    /// 64 bytes (supporting edge-case streams shorter than 64 bytes).
    pub async fn verify_overlap_and_prime_slice(
        &self,
        cached_bytes: u64,
        expected_total_len: u64,
        expected_tail: &[u8],
    ) -> Result<OverlapVerifyOutcome, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        if expected_total_len == 0 && cached_bytes == 0 {
            return Ok(OverlapVerifyOutcome::Verified);
        }
        if cached_bytes > expected_total_len {
            return Ok(OverlapVerifyOutcome::Mismatch(
                FormatMismatchReason::ContentLengthChanged {
                    expected: expected_total_len,
                    actual: cached_bytes,
                },
            ));
        }

        let overlap_len = cached_bytes.min(64) as usize;
        if overlap_len == 0 {
            return Ok(OverlapVerifyOutcome::Verified);
        }
        if expected_tail.len() < overlap_len {
            return Ok(OverlapVerifyOutcome::Mismatch(
                FormatMismatchReason::TailFingerprintMismatch,
            ));
        }
        let expected_overlap = &expected_tail[expected_tail.len() - overlap_len..];

        let req_start = cached_bytes - overlap_len as u64;
        let desired_end = cached_bytes
            .saturating_add(self.initial_chunk_size as u64)
            .saturating_sub(1);
        let req_end = desired_end.min(expected_total_len.saturating_sub(1));

        let refresh_ctx = self.refresh_context();
        let mut epoch_rx = self.epoch_rx.clone();
        let mut refresh_attempts: u8 = 0;
        let mut cas_retries: u8 = 0;

        let _dl_guard = InFlightDownloadGuard::new(Some(Arc::clone(&self.active_downloads)));

        loop {
            let req_url = refresh_ctx.current_url();
            let req_headers = refresh_ctx.current_headers();
            let req = HttpRequestSpec {
                method: Method::GET,
                url: req_url.clone(),
                headers: req_headers,
                range: Some((req_start, req_end)),
            };

            let fetch_started = Instant::now();
            let resp = execute_with_epoch_watch(
                self.transport.as_ref(),
                req,
                true,
                &self.config,
                &self.cancel,
                &mut epoch_rx,
            )
            .await?;
            let fetch_elapsed = fetch_started.elapsed();

            if resp.status == 401 {
                return Err(StreamError::AuthRequired {
                    provider_id: refresh_ctx.provider_id(),
                    status: 401,
                });
            }

            if resp.status == 403 || resp.status == 410 {
                match attempt_chunk_refresh_after_403(
                    &refresh_ctx,
                    &req_url,
                    resp.status,
                    false,
                    &mut refresh_attempts,
                    &self.cancel,
                )
                .await
                {
                    Ok(Some(_)) => continue,
                    Ok(None) => {
                        cas_retries += 1;
                        if cas_retries > 4 {
                            return Err(StreamError::HttpStatus(resp.status));
                        }
                        continue;
                    }
                    Err(StreamError::FormatChanged(new_spec)) => {
                        let actual = match *new_spec {
                            StreamSourceSpec::DirectRange { content_length, .. }
                            | StreamSourceSpec::EncryptedRange { content_length, .. } => {
                                content_length
                            }
                            _ => None,
                        };
                        if let Some(actual_len) = actual
                            && actual_len != expected_total_len
                        {
                            return Ok(OverlapVerifyOutcome::Mismatch(
                                FormatMismatchReason::ContentLengthChanged {
                                    expected: expected_total_len,
                                    actual: actual_len,
                                },
                            ));
                        }
                        return Ok(OverlapVerifyOutcome::Mismatch(
                            FormatMismatchReason::TailFingerprintMismatch,
                        ));
                    }
                    Err(err) => return Err(err),
                }
            }

            if resp.status == 416 {
                if let Some(actual_len) = resp.content_range_total
                    && actual_len != expected_total_len
                {
                    return Ok(OverlapVerifyOutcome::Mismatch(
                        FormatMismatchReason::ContentLengthChanged {
                            expected: expected_total_len,
                            actual: actual_len,
                        },
                    ));
                }
                return Err(StreamError::HttpStatus(416));
            }

            if !(200..300).contains(&resp.status) {
                return Err(StreamError::HttpStatus(resp.status));
            }

            let resp_total = resp.content_range_total.or_else(|| {
                if resp.status == 200 {
                    resp.content_length.or(Some(resp.body.len() as u64))
                } else {
                    None
                }
            });
            if let Some(actual_len) = resp_total
                && actual_len != expected_total_len
            {
                return Ok(OverlapVerifyOutcome::Mismatch(
                    FormatMismatchReason::ContentLengthChanged {
                        expected: expected_total_len,
                        actual: actual_len,
                    },
                ));
            }

            refresh_ctx.update_redirected_url(&req_url, resp.final_url);
            self.telemetry.record_download(
                &refresh_ctx.provider_id(),
                &refresh_ctx.track_id(),
                req_start,
                resp.body.len(),
                fetch_elapsed,
            );

            let expected_req_len = (req_end - req_start + 1) as usize;
            let fetched = if resp.status == 200 && req_start > 0 {
                let s = req_start as usize;
                if resp.body.len() < s + overlap_len {
                    return Ok(OverlapVerifyOutcome::Mismatch(
                        FormatMismatchReason::TailFingerprintMismatch,
                    ));
                }
                let slice_end = (s + expected_req_len).min(resp.body.len());
                resp.body.slice(s..slice_end)
            } else if resp.body.len() > expected_req_len {
                resp.body.slice(..expected_req_len)
            } else {
                resp.body
            };

            if fetched.len() < overlap_len || &fetched[..overlap_len] != expected_overlap {
                return Ok(OverlapVerifyOutcome::Mismatch(
                    FormatMismatchReason::TailFingerprintMismatch,
                ));
            }

            if let Ok(mut guard) = self.content_length.lock() {
                *guard = Some(expected_total_len);
            }

            let prime_slice = fetched.slice(overlap_len..);
            drop(_dl_guard);

            {
                let mut st = self
                    .state
                    .lock()
                    .map_err(|_| StreamError::Io("chunk proxy state lock poisoned".to_string()))?;
                if !prime_slice.is_empty() {
                    st.cache.insert(cached_bytes, prime_slice.clone());
                }
                st.last_read_end = Some(cached_bytes);

                let prime_end = cached_bytes.saturating_add(prime_slice.len() as u64);
                if prime_end < expected_total_len && !self.cancel.is_cancelled() {
                    self.schedule_read_ahead_from_locked(&mut st, prime_end, expected_total_len);
                }
            }

            return Ok(OverlapVerifyOutcome::Verified);
        }
    }

    /// Captures `[0, target_bytes.min(total_len))` from the RAM LRU cache (fetching any missing
    /// sub-ranges if evicted or not yet downloaded) without altering the decoder read cursor.
    pub async fn capture_prefix_bytes(&self, target_bytes: u64) -> Result<Vec<u8>, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        let total_len = self.ensure_content_length().await?;
        let goal = target_bytes.min(total_len) as usize;
        if goal == 0 {
            return Ok(Vec::new());
        }

        let mut out = vec![0u8; goal];
        let mut cursor = 0u64;
        while (cursor as usize) < goal {
            let (span_start, chunk) = self
                .get_or_fetch_span_covering(cursor, total_len, false)
                .await?;
            let in_chunk = cursor.saturating_sub(span_start) as usize;
            if in_chunk >= chunk.len() {
                break;
            }
            let avail = &chunk[in_chunk..];
            let needed = goal - (cursor as usize);
            let to_copy = avail.len().min(needed);
            out[cursor as usize..cursor as usize + to_copy].copy_from_slice(&avail[..to_copy]);
            cursor += to_copy as u64;
        }
        out.truncate(cursor as usize);
        Ok(out)
    }

    fn refresh_context(&self) -> ChunkRefreshContext {
        ChunkRefreshContext {
            key: self.key.clone(),
            expected_kind: self.expected_kind.clone(),
            bitrate_bps: self.bitrate_bps,
            hint_extension: self.hint_extension.clone(),
            mime_type: self.mime_type.clone(),
            loudness: self.loudness,
            album_loudness: self.album_loudness,
            content_length: Arc::clone(&self.content_length),
            url_slot: Arc::clone(&self.url),
            headers_slot: Arc::clone(&self.headers),
            refresh_handler: self.refresh_handler.clone(),
            refresh_lock: Arc::clone(&self.refresh_lock),
            backoffs: self.refresh_backoffs,
            has_delivered_bytes: Arc::clone(&self.has_delivered_bytes),
        }
    }

    async fn ensure_content_length(&self) -> Result<u64, StreamError> {
        if let Ok(guard) = self.content_length.lock()
            && let Some(len) = *guard
        {
            return Ok(len);
        }

        let _probe_guard = self.probe_lock.lock().await;
        if let Ok(guard) = self.content_length.lock()
            && let Some(len) = *guard
        {
            return Ok(len);
        }
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }

        let rt = streaming_runtime()?;
        let transport = Arc::clone(&self.transport);
        let config = self.config;
        let cancel = self.cancel.clone();
        let active_downloads = Arc::clone(&self.active_downloads);
        let refresh_ctx = self.refresh_context();
        let mut epoch_rx = self.epoch_rx.clone();

        let (tx, mut rx) = watch::channel(None);
        rt.spawn(async move {
            let dl_guard = InFlightDownloadGuard::new(Some(active_downloads));
            let res = probe_content_length(
                transport.as_ref(),
                &refresh_ctx,
                &config,
                &cancel,
                &mut epoch_rx,
            )
            .await;
            drop(dl_guard);
            let _ = tx.send(Some(res));
        });

        let total_len = await_watch_result(&mut rx).await?;
        if let Ok(mut guard) = self.content_length.lock() {
            *guard = Some(total_len);
        }
        Ok(total_len)
    }

    fn spawn_range_fetch_locked(
        &self,
        st: &mut ProxyState,
        start: u64,
        end: u64,
        allow_refresh: bool,
    ) -> Result<InFlightChunkRx, StreamError> {
        let (tx, rx) = watch::channel(None);
        let flight_id = st.next_flight_id;
        st.next_flight_id = st.next_flight_id.wrapping_add(1).max(1);
        st.in_flight.push(InFlightRange {
            id: flight_id,
            start,
            end,
            allow_refresh,
            rx: rx.clone(),
        });

        let rt = streaming_runtime()?;
        let transport = Arc::clone(&self.transport);
        let config = self.config;
        let cancel = self.cancel.clone();
        let state = Arc::clone(&self.state);
        let active_downloads = Arc::clone(&self.active_downloads);
        let refresh_ctx = self.refresh_context();
        let telemetry = Arc::clone(&self.telemetry);
        let mut epoch_rx = self.epoch_rx.clone();

        let dl_guard = InFlightDownloadGuard::new(Some(active_downloads));
        rt.spawn(async move {
            let mut cleanup = ChunkFlightCleanup {
                flight_id,
                state: Arc::clone(&state),
                tx,
                completed: false,
            };

            let fetch_started = Instant::now();
            let fetched_res = fetch_range_chunk(
                transport.as_ref(),
                &refresh_ctx,
                start,
                end,
                allow_refresh,
                &config,
                &cancel,
                &mut epoch_rx,
            )
            .await;

            let res: Result<Bytes, StreamError> = match fetched_res {
                Ok(fetched) => {
                    telemetry.record_download(
                        &refresh_ctx.provider_id(),
                        &refresh_ctx.track_id(),
                        start,
                        fetched.raw_downloaded_bytes,
                        fetch_started.elapsed(),
                    );
                    if let Ok(mut st) = state.lock() {
                        if let Some(full_body) = fetched.full_body_200 {
                            let cap = st.cache.max_bytes;
                            if full_body.len() <= cap {
                                st.cache.insert(0, full_body);
                            } else {
                                let s = (start as usize).min(full_body.len());
                                let cache_end = s.saturating_add(cap).min(full_body.len());
                                if cache_end > s {
                                    st.cache.insert(start, full_body.slice(s..cache_end));
                                }
                            }
                        } else {
                            st.cache.insert(start, fetched.requested.clone());
                        }
                    }
                    Ok(fetched.requested)
                }
                Err(err) => Err(err),
            };

            // Drop the in-flight counter guard before notifying waiters so assertions on
            // `active_in_flight_downloads() == 0` right after cancellation/read return are race-free.
            drop(dl_guard);
            if let Ok(mut st) = cleanup.state.lock() {
                st.in_flight.retain(|f| f.id != flight_id);
            }
            let _ = cleanup.tx.send(Some(res));
            cleanup.completed = true;
        });

        Ok(rx)
    }

    fn plan_aligned_end(&self, st: &ProxyState, start: u64, desired_len: usize, total_len: u64) -> u64 {
        let mut end = start
            .saturating_add((desired_len as u64).saturating_sub(1))
            .min(total_len.saturating_sub(1));

        if let Some(next_cached) = st.cache.next_start_after(start)
            && next_cached <= end
        {
            end = next_cached.saturating_sub(1);
        }
        for f in &st.in_flight {
            if f.start > start && f.start <= end {
                end = f.start.saturating_sub(1);
            }
        }
        end.max(start)
    }

    async fn get_or_fetch_span_covering(
        &self,
        offset: u64,
        total_len: u64,
        was_sequential_call: bool,
    ) -> Result<(u64, Bytes), StreamError> {
        loop {
            if self.cancel.is_cancelled() {
                return Err(StreamError::Cancelled);
            }

            let (start, joined_bg_prefetch, mut rx) = {
                let mut st = self
                    .state
                    .lock()
                    .map_err(|_| StreamError::Io("chunk proxy state lock poisoned".to_string()))?;

                if let Some(hit) = st.cache.get_covering(offset) {
                    return Ok(hit);
                }

                if let Some(existing) = st
                    .in_flight
                    .iter()
                    .find(|f| f.start <= offset && offset <= f.end)
                {
                    (existing.start, !existing.allow_refresh, existing.rx.clone())
                } else {
                    let align = self.alignment as u64;
                    let start = (offset / align) * align;
                    let is_sequential = start > 0
                        && (st.cache.has_contiguous_predecessor(start)
                            || (was_sequential_call && st.last_read_end == Some(offset)));
                    let desired_len = if is_sequential {
                        self.chunk_size
                    } else {
                        self.initial_chunk_size
                    };
                    let end = self.plan_aligned_end(&st, start, desired_len, total_len);
                    let rx = self.spawn_range_fetch_locked(&mut st, start, end, true)?;
                    (start, false, rx)
                }
            };

            match await_watch_result(&mut rx).await {
                Ok(bytes) => return Ok((start, bytes)),
                Err(StreamError::HttpStatus(403 | 410)) if joined_bg_prefetch => {
                    // Background read-ahead silently aborted on 403/410 without consuming retries;
                    // escalate into a foreground fetch that executes in-place 403/410 self-healing.
                    continue;
                }
                Err(err) => return Err(err),
            }
        }
    }

    fn schedule_read_ahead_from_locked(
        &self,
        st: &mut ProxyState,
        start_from: u64,
        total_len: u64,
    ) {
        if self.cancel.is_cancelled() || self.prefetch_ahead == 0 || start_from >= total_len {
            return;
        }
        let align = self.alignment.max(1) as u64;
        // Keep prefetched chunks within the RAM LRU budget so read-ahead never evicts the active span.
        let max_by_cache = (st.cache.max_bytes / self.chunk_size.max(1))
            .saturating_sub(1)
            .max(1);
        let target_chunks = self.prefetch_ahead.min(max_by_cache);

        let mut next_start = (start_from / align) * align;
        for _ in 0..target_chunks {
            if next_start >= total_len || self.cancel.is_cancelled() {
                break;
            }
            if let Some((_, cached_end)) = st.cache.covering_bounds(next_start) {
                next_start = if align <= 1 {
                    cached_end
                } else {
                    cached_end.div_ceil(align).saturating_mul(align)
                };
                continue;
            }
            if let Some(in_flight_end) = st
                .in_flight
                .iter()
                .find(|f| f.start <= next_start && next_start <= f.end)
                .map(|f| f.end.saturating_add(1))
            {
                next_start = if align <= 1 {
                    in_flight_end
                } else {
                    in_flight_end.div_ceil(align).saturating_mul(align)
                };
                continue;
            }
            let end = self.plan_aligned_end(st, next_start, self.chunk_size, total_len);
            if self
                .spawn_range_fetch_locked(st, next_start, end, false)
                .is_err()
            {
                break;
            }
            let after = end.saturating_add(1);
            next_start = if align <= 1 {
                after
            } else {
                after.div_ceil(align).saturating_mul(align)
            };
        }
    }

    fn maybe_schedule_read_ahead(&self, span_start: u64, span_len: usize, cursor: u64, total_len: u64) {
        if self.cancel.is_cancelled() || span_len == 0 || self.prefetch_ahead == 0 {
            return;
        }
        let span_end = span_start.saturating_add(span_len as u64);
        if span_end >= total_len {
            return;
        }
        // Only read ahead once sequential playback advances to or past the midpoint of the current span.
        let midpoint = span_start.saturating_add((span_len as u64) / 2);
        if cursor < midpoint {
            return;
        }

        let Ok(mut st) = self.state.lock() else {
            return;
        };
        self.schedule_read_ahead_from_locked(&mut st, span_end, total_len);
    }
}

async fn probe_content_length(
    transport: &dyn StreamHttpTransport,
    ctx: &ChunkRefreshContext,
    config: &StreamHttpConfig,
    cancel: &CancellationToken,
    epoch_rx: &mut watch::Receiver<u64>,
) -> Result<u64, StreamError> {
    if cancel.is_cancelled() {
        return Err(StreamError::Cancelled);
    }

    let mut head_len: Option<u64> = None;
    let mut head_err: Option<StreamError> = None;

    let initial_url = ctx.current_url();
    let initial_headers = ctx.current_headers();
    let head_req = HttpRequestSpec {
        method: Method::HEAD,
        url: initial_url.clone(),
        headers: initial_headers,
        range: None,
    };
    match execute_with_epoch_watch(transport, head_req, false, config, cancel, epoch_rx).await {
        Ok(resp) => {
            if (200..300).contains(&resp.status) {
                ctx.update_redirected_url(&initial_url, resp.final_url);
                if accepts_byte_ranges(&resp.headers)
                    && let Some(len) = resp.content_length
                {
                    return Ok(len);
                }
                head_len = resp.content_length;
            } else if resp.status == 401 {
                return Err(StreamError::AuthRequired {
                    provider_id: ctx.provider_id(),
                    status: 401,
                });
            } else if resp.status == 404 {
                return Err(StreamError::HttpStatus(404));
            } else {
                head_err = Some(StreamError::HttpStatus(resp.status));
            }
        }
        Err(StreamError::Cancelled) => return Err(StreamError::Cancelled),
        Err(StreamError::Timeout) => return Err(StreamError::Timeout),
        Err(err) => {
            head_err = Some(err);
        }
    }

    let mut refresh_attempts: u8 = 0;
    let mut cas_retries: u8 = 0;

    loop {
        let probe_url = ctx.current_url();
        let probe_headers = ctx.current_headers();
        let get_req = HttpRequestSpec {
            method: Method::GET,
            url: probe_url.clone(),
            headers: probe_headers,
            range: Some((0, 0)),
        };
        let resp = match execute_with_epoch_watch(
            transport,
            get_req,
            false,
            config,
            cancel,
            epoch_rx,
        )
        .await
        {
            Ok(r) => r,
            Err(StreamError::Cancelled) => return Err(StreamError::Cancelled),
            Err(StreamError::Timeout) => return Err(StreamError::Timeout),
            Err(err) => return Err(head_err.unwrap_or(err)),
        };

        if resp.status == 401 {
            return Err(StreamError::AuthRequired {
                provider_id: ctx.provider_id(),
                status: 401,
            });
        }

        if resp.status == 403 || resp.status == 410 {
            let is_initial_probe = !ctx.has_delivered_bytes.load(Ordering::Acquire);
            let refreshed = attempt_chunk_refresh_after_403(
                ctx,
                &probe_url,
                resp.status,
                is_initial_probe,
                &mut refresh_attempts,
                cancel,
            )
            .await?;
            if refreshed.is_none() {
                cas_retries += 1;
                if cas_retries > 4 {
                    return Err(StreamError::HttpStatus(resp.status));
                }
            }
            head_err = None;
            continue;
        }

        if resp.status == 416 {
            if resp.content_range_total == Some(0) {
                return Ok(0);
            }
            return Err(StreamError::HttpStatus(416));
        }
        if !(200..300).contains(&resp.status) {
            return Err(StreamError::HttpStatus(resp.status));
        }

        ctx.update_redirected_url(&probe_url, resp.final_url);

        if resp.status == 206 {
            if let Some(total) = resp.content_range_total.or(head_len) {
                return Ok(total);
            }
            // A 206 response to `Range: bytes=0-0` with unknown total (`/*`) has
            // `Content-Length: 1` (the single-byte slice), NEVER the total stream length.
            return Err(StreamError::Unsupported(
                "HTTP 206 response did not provide Content-Range total length".to_string(),
            ));
        }

        if let Some(total) = resp.content_length.or(head_len) {
            return Ok(total);
        }

        return Err(StreamError::Unsupported(
            "HTTP server did not provide Content-Length or Content-Range total".to_string(),
        ));
    }
}

#[allow(clippy::too_many_arguments)]
async fn fetch_range_chunk(
    transport: &dyn StreamHttpTransport,
    ctx: &ChunkRefreshContext,
    start: u64,
    end: u64,
    allow_refresh: bool,
    config: &StreamHttpConfig,
    cancel: &CancellationToken,
    epoch_rx: &mut watch::Receiver<u64>,
) -> Result<FetchedRange, StreamError> {
    let mut refresh_attempts: u8 = 0;
    let mut cas_retries: u8 = 0;
    let mut last_refreshed_spec: Option<StreamSourceSpec> = None;

    loop {
        let req_url = ctx.current_url();
        let req_headers = ctx.current_headers();
        let req = HttpRequestSpec {
            method: Method::GET,
            url: req_url.clone(),
            headers: req_headers,
            range: Some((start, end)),
        };

        let resp =
            execute_with_epoch_watch(transport, req, true, config, cancel, epoch_rx).await?;

        if resp.status == 401 {
            return Err(StreamError::AuthRequired {
                provider_id: ctx.provider_id(),
                status: 401,
            });
        }

        if resp.status == 403 || resp.status == 410 {
            if !allow_refresh {
                return Err(StreamError::HttpStatus(resp.status));
            }
            let is_initial_probe =
                start == 0 && !ctx.has_delivered_bytes.load(Ordering::Acquire);
            match attempt_chunk_refresh_after_403(
                ctx,
                &req_url,
                resp.status,
                is_initial_probe,
                &mut refresh_attempts,
                cancel,
            )
            .await?
            {
                Some(spec) => {
                    last_refreshed_spec = Some(spec);
                    continue;
                }
                None => {
                    cas_retries += 1;
                    if cas_retries > 4 {
                        return Err(StreamError::HttpStatus(resp.status));
                    }
                    continue;
                }
            }
        }

        if !(200..300).contains(&resp.status) {
            return Err(StreamError::HttpStatus(resp.status));
        }

        // Verify resumed Content-Range total matches previously known content_length
        let resp_total = resp.content_range_total.or_else(|| {
            if resp.status == 200 {
                resp.content_length
            } else {
                None
            }
        });
        if let Some(actual_len) = resp_total {
            match ctx.known_content_length() {
                Some(expected_len) if expected_len != actual_len => {
                    let changed_spec = match last_refreshed_spec.take() {
                        Some(spec) => spec_with_content_length(spec, actual_len),
                        None => ctx.synthesize_format_changed_spec(actual_len),
                    };
                    return Err(StreamError::FormatChanged(Box::new(changed_spec)));
                }
                None => {
                    if let Ok(mut guard) = ctx.content_length.lock() {
                        *guard = Some(actual_len);
                    }
                }
                _ => {}
            }
        }

        ctx.update_redirected_url(&req_url, resp.final_url);

        let expected_len = (end - start + 1) as usize;
        let raw_downloaded_bytes = resp.body.len();
        if resp.status == 200 {
            let s = start as usize;
            let requested = if raw_downloaded_bytes <= s {
                Bytes::new()
            } else {
                let slice_end = s.saturating_add(expected_len).min(raw_downloaded_bytes);
                resp.body.slice(s..slice_end)
            };
            let full_body_200 =
                (raw_downloaded_bytes > expected_len || start > 0).then_some(resp.body);
            return Ok(FetchedRange {
                requested,
                full_body_200,
                raw_downloaded_bytes,
            });
        }

        let requested = if raw_downloaded_bytes > expected_len {
            resp.body.slice(..expected_len)
        } else {
            resp.body
        };
        return Ok(FetchedRange {
            requested,
            full_body_200: None,
            raw_downloaded_bytes,
        });
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
            if was_sequential_call
                && let Some((span_start, span_len)) = last_span
            {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::streaming::active_in_flight_downloads;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    fn make_pattern_bytes(len: usize) -> Vec<u8> {
        (0..len)
            .map(|i| ((i * 31 + (i >> 8) * 17) & 0xFF) as u8)
            .collect()
    }

    struct MockRangeServer {
        addr: std::net::SocketAddr,
        ranges_seen: Arc<Mutex<Vec<String>>>,
        head_count: Arc<AtomicUsize>,
        delay_per_get: Duration,
        stall_body: bool,
    }

    async fn spawn_mock_range_server(
        payload: Arc<Vec<u8>>,
        delay_per_get: Duration,
        stall_body: bool,
        reject_head: bool,
    ) -> MockRangeServer {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let ranges_seen = Arc::new(Mutex::new(Vec::new()));
        let head_count = Arc::new(AtomicUsize::new(0));

        let ranges_clone = Arc::clone(&ranges_seen);
        let head_clone = Arc::clone(&head_count);
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let payload = Arc::clone(&payload);
                let ranges_seen = Arc::clone(&ranges_clone);
                let head_count = Arc::clone(&head_clone);
                tokio::spawn(async move {
                    let mut req_buf = Vec::with_capacity(2048);
                    let mut tmp = [0u8; 512];
                    loop {
                        req_buf.clear();
                        let header_end = loop {
                            if let Some(pos) = req_buf.windows(4).position(|w| w == b"\r\n\r\n") {
                                break pos + 4;
                            }
                            match socket.read(&mut tmp).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => req_buf.extend_from_slice(&tmp[..n]),
                            }
                        };
                        let req_str = String::from_utf8_lossy(&req_buf[..header_end]).into_owned();
                        let first_line = req_str.lines().next().unwrap_or("");
                        let method = first_line.split_whitespace().next().unwrap_or("GET");
                        let range_hdr = req_str
                            .lines()
                            .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                            .and_then(|l| l.split_once(':'))
                            .map(|(_, v)| v.trim().to_string());

                        if method == "HEAD" {
                            head_count.fetch_add(1, Ordering::SeqCst);
                            let resp = if reject_head {
                                "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n"
                                    .to_string()
                            } else {
                                format!(
                                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nContent-Type: audio/flac\r\n\r\n",
                                    payload.len()
                                )
                            };
                            if socket.write_all(resp.as_bytes()).await.is_err()
                                || socket.flush().await.is_err()
                            {
                                return;
                            }
                            continue;
                        }

                        if !delay_per_get.is_zero() {
                            tokio::time::sleep(delay_per_get).await;
                        }

                        if let Some(ref range_val) = range_hdr {
                            ranges_seen.lock().unwrap().push(range_val.clone());
                            if let Some(spec) = range_val.strip_prefix("bytes=")
                                && let Some((s, e)) = spec.split_once('-')
                                && let (Ok(start), Ok(end)) =
                                    (s.parse::<usize>(), e.parse::<usize>())
                            {
                                if start >= payload.len() || end >= payload.len() || start > end {
                                    let resp = format!(
                                        "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\n\r\n",
                                        payload.len()
                                    );
                                    if socket.write_all(resp.as_bytes()).await.is_err()
                                        || socket.flush().await.is_err()
                                    {
                                        return;
                                    }
                                    continue;
                                }
                                let slice = &payload[start..=end];
                                let hdr = format!(
                                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nAccept-Ranges: bytes\r\n\r\n",
                                    slice.len(),
                                    payload.len()
                                );
                                if socket.write_all(hdr.as_bytes()).await.is_err() {
                                    return;
                                }
                                if stall_body {
                                    if !slice.is_empty() {
                                        let _ =
                                            socket.write_all(&slice[..1.min(slice.len())]).await;
                                        let _ = socket.flush().await;
                                    }
                                    tokio::time::sleep(Duration::from_secs(5)).await;
                                    return;
                                }
                                if socket.write_all(slice).await.is_err()
                                    || socket.flush().await.is_err()
                                {
                                    return;
                                }
                                continue;
                            }
                        }

                        let hdr = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                            payload.len()
                        );
                        if socket.write_all(hdr.as_bytes()).await.is_err()
                            || socket.write_all(&payload).await.is_err()
                            || socket.flush().await.is_err()
                        {
                            return;
                        }
                    }
                });
            }
        });

        MockRangeServer {
            addr,
            ranges_seen,
            head_count,
            delay_per_get,
            stall_body,
        }
    }

    #[tokio::test]
    async fn test_chunked_proxy_adaptive_128k_startup_512k_sequential_and_last_chunk_clamp() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        // 128 KiB initial + 512 KiB sequential + 12_345 byte tail
        let total = DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE + 12_345;
        let payload = Arc::new(make_pattern_bytes(total));
        let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, false).await;

        let url = format!("http://{}/track.flac", server.addr);
        let proxy = ChunkedStreamProxy::new(
            url,
            &BTreeMap::new(),
            None,
            Some("flac".to_string()),
            Some("audio/flac".to_string()),
        )
        .unwrap();

        // 1. Startup fetch uses 128 KiB (0..=131071).
        let mut head_buf = vec![0u8; 64];
        assert_eq!(proxy.read_at(0, &mut head_buf).await.unwrap(), 64);
        assert_eq!(&head_buf[..], &payload[..64]);
        assert_eq!(proxy.len(), Some(total as u64));
        assert_eq!(server.head_count.load(Ordering::SeqCst), 1);

        // 2. Sequential continuation across 128 KiB boundary uses 512 KiB (131072..=655359).
        let mut seq_buf = vec![0u8; 64];
        assert_eq!(
            proxy.read_at(DEFAULT_INITIAL_CHUNK_SIZE as u64, &mut seq_buf).await.unwrap(),
            64
        );
        assert_eq!(
            &seq_buf[..],
            &payload[DEFAULT_INITIAL_CHUNK_SIZE..DEFAULT_INITIAL_CHUNK_SIZE + 64]
        );

        // 3. Continuation into tail clamps cleanly to total - 1 (no HTTP 416).
        let tail_start = DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE;
        let mut tail_buf = vec![0u8; 32_768];
        let n = proxy.read_at((tail_start - 16) as u64, &mut tail_buf).await.unwrap();
        assert_eq!(n, 16 + 12_345);
        assert_eq!(&tail_buf[..n], &payload[tail_start - 16..]);

        // 4. Reading at or past EOF returns 0 without issuing an HTTP request.
        let ranges_before_eof = server.ranges_seen.lock().unwrap().len();
        assert_eq!(proxy.read_at(total as u64, &mut head_buf).await.unwrap(), 0);
        assert_eq!(proxy.read_at(total as u64 + 500, &mut head_buf).await.unwrap(), 0);
        let ranges = server.ranges_seen.lock().unwrap().clone();
        assert_eq!(ranges.len(), ranges_before_eof);

        let expected_last_end = total - 1;
        assert_eq!(
            ranges,
            vec![
                "bytes=0-131071".to_string(),
                "bytes=131072-655359".to_string(),
                format!("bytes=655360-{expected_last_end}"),
            ]
        );
    }

    #[tokio::test]
    async fn test_chunked_proxy_seek_128k_first_chunk_and_backward_seek_lru_hit() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let total = 2 * 1024 * 1024;
        let payload = Arc::new(make_pattern_bytes(total));
        let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, false).await;

        let url = format!("http://{}/seek.flac", server.addr);
        let proxy = ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(total as u64), None, None)
            .unwrap();

        // Startup at 0 -> 128 KiB
        let mut buf = vec![0u8; 256];
        assert_eq!(proxy.read_at(0, &mut buf).await.unwrap(), 256);
        assert_eq!(&buf[..], &payload[0..256]);

        // Discontinuous forward seek to 1 MiB -> first chunk after seek is 128 KiB
        let seek_off = 1024 * 1024usize;
        assert_eq!(proxy.read_at(seek_off as u64, &mut buf).await.unwrap(), 256);
        assert_eq!(&buf[..], &payload[seek_off..seek_off + 256]);

        // Sequential continuation after seek -> 512 KiB
        let next_off = seek_off + DEFAULT_INITIAL_CHUNK_SIZE;
        assert_eq!(proxy.read_at(next_off as u64, &mut buf).await.unwrap(), 256);
        assert_eq!(&buf[..], &payload[next_off..next_off + 256]);

        let ranges_before_back = server.ranges_seen.lock().unwrap().clone();
        assert_eq!(
            ranges_before_back,
            vec![
                "bytes=0-131071".to_string(),
                "bytes=1048576-1179647".to_string(),
                "bytes=1179648-1703935".to_string(),
            ]
        );

        // Short backward seek into previously cached spans -> ZERO HTTP requests!
        assert_eq!(proxy.read_at(seek_off as u64 + 4096, &mut buf).await.unwrap(), 256);
        assert_eq!(&buf[..], &payload[seek_off + 4096..seek_off + 4096 + 256]);
        assert_eq!(proxy.read_at(1024, &mut buf).await.unwrap(), 256);
        assert_eq!(&buf[..], &payload[1024..1280]);

        let ranges_after_back = server.ranges_seen.lock().unwrap().clone();
        assert_eq!(
            ranges_after_back.len(),
            ranges_before_back.len(),
            "backward seeks inside RAM LRU cache must issue zero HTTP requests"
        );
    }

    #[tokio::test]
    async fn test_chunked_proxy_deezer_6144_alignment_129024_and_522240_and_lru_eviction() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let total = 2 * 1024 * 1024 + 137; // intentionally unaligned tail
        let payload = Arc::new(make_pattern_bytes(total));
        let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, false).await;

        let url = format!("http://{}/deezer.bin", server.addr);
        let proxy = ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(total as u64), None, None)
            .unwrap()
            .with_initial_chunk_size(DEEZER_INITIAL_CHUNK_SIZE)
            .with_chunk_size(DEEZER_ALIGNED_CHUNK_SIZE)
            .with_range_alignment(6144)
            .with_max_cache_bytes(DEEZER_INITIAL_CHUNK_SIZE + DEEZER_ALIGNED_CHUNK_SIZE);

        let mut buf = vec![0u8; 512];
        // Startup -> 129,024 bytes (0..=129023)
        assert_eq!(proxy.read_at(0, &mut buf).await.unwrap(), 512);
        assert_eq!(&buf[..], &payload[0..512]);

        // Sequential -> 522,240 bytes (129024..=651263)
        assert_eq!(
            proxy.read_at(DEEZER_INITIAL_CHUNK_SIZE as u64, &mut buf).await.unwrap(),
            512
        );
        assert_eq!(
            &buf[..],
            &payload[DEEZER_INITIAL_CHUNK_SIZE..DEEZER_INITIAL_CHUNK_SIZE + 512]
        );

        // Unaligned seek offset (1_000_000) -> snapped down to 6144 boundary (995_328), span 129,024 B
        assert_eq!(proxy.read_at(1_000_000, &mut buf).await.unwrap(), 512);
        assert_eq!(&buf[..], &payload[1_000_000..1_000_512]);

        let ranges = server.ranges_seen.lock().unwrap().clone();
        assert_eq!(
            ranges,
            vec![
                "bytes=0-129023".to_string(),
                "bytes=129024-651263".to_string(),
                "bytes=995328-1124351".to_string(),
            ]
        );
        for r in &ranges {
            let (s, e) = r.strip_prefix("bytes=").unwrap().split_once('-').unwrap();
            let start = s.parse::<usize>().unwrap();
            let end = e.parse::<usize>().unwrap();
            assert_eq!(start % 6144, 0);
            assert!((end + 1) % 6144 == 0 || end + 1 == total);
        }

        // Byte cap evicted the oldest entry (offset 0) when 995328 was inserted
        assert!(proxy.cached_bytes() <= DEEZER_INITIAL_CHUNK_SIZE + DEEZER_ALIGNED_CHUNK_SIZE);
    }

    #[tokio::test]
    async fn test_chunked_proxy_probe_falls_back_from_405_head_to_range_zero() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let payload = Arc::new(make_pattern_bytes(4096));
        let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, true).await;
        let url = format!("http://{}/stream", server.addr);
        let proxy = ChunkedStreamProxy::new(url, &BTreeMap::new(), None, None, None).unwrap();

        let mut out = vec![0u8; 512];
        let n = proxy.read_at(1024, &mut out).await.unwrap();
        assert_eq!(n, 512);
        assert_eq!(&out[..], &payload[1024..1536]);
        assert_eq!(proxy.len(), Some(4096));

        let ranges = server.ranges_seen.lock().unwrap().clone();
        assert_eq!(ranges, vec!["bytes=0-0".to_string(), "bytes=1024-4095".to_string()]);
    }

    #[tokio::test]
    async fn test_chunked_proxy_single_flight_coalescing_and_ram_lru() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let payload = Arc::new(make_pattern_bytes(600_000));
        let server =
            spawn_mock_range_server(Arc::clone(&payload), Duration::from_millis(25), false, false)
                .await;
        let url = format!("http://{}/coalesce.flac", server.addr);
        let proxy = Arc::new(
            ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(600_000), None, None).unwrap(),
        );

        let (r1, r2, r3) = tokio::join!(
            async {
                let mut b = vec![0u8; 128];
                let n = proxy.read_at(0, &mut b).await.unwrap();
                (n, b)
            },
            async {
                let mut b = vec![0u8; 128];
                let n = proxy.read_at(100, &mut b).await.unwrap();
                (n, b)
            },
            async {
                let mut b = vec![0u8; 128];
                let n = proxy.read_at(200, &mut b).await.unwrap();
                (n, b)
            }
        );

        assert_eq!(r1.0, 128);
        assert_eq!(&r1.1[..], &payload[0..128]);
        assert_eq!(&r2.1[..], &payload[100..228]);
        assert_eq!(&r3.1[..], &payload[200..328]);

        let ranges = server.ranges_seen.lock().unwrap().clone();
        assert_eq!(ranges.len(), 1, "concurrent reads of chunk 0 must coalesce");
    }

    #[tokio::test]
    async fn test_chunked_proxy_read_timeout() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let payload = Arc::new(make_pattern_bytes(1024));
        let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, true, false).await;
        assert!(server.stall_body);
        assert!(server.delay_per_get.is_zero());

        let url = format!("http://{}/stall.flac", server.addr);
        let proxy = ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(1024), None, None)
            .unwrap()
            .with_http_config(StreamHttpConfig {
                connect_timeout: Duration::from_millis(200),
                request_timeout: Duration::from_millis(200),
                read_timeout: Duration::from_millis(90),
                max_redirects: 4,
            });

        let mut buf = vec![0u8; 512];
        let err = proxy.read_at(0, &mut buf).await.unwrap_err();
        assert_eq!(err, StreamError::Timeout);
        assert_eq!(proxy.active_downloads(), 0);
    }

    #[tokio::test]
    async fn test_chunked_proxy_cancel_aborts_immediately_and_clears_in_flight() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let payload = Arc::new(make_pattern_bytes(4096));
        let server =
            spawn_mock_range_server(Arc::clone(&payload), Duration::from_secs(5), false, false)
                .await;

        let url = format!("http://{}/slow.flac", server.addr);
        let proxy = Arc::new(
            ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(4096), None, None).unwrap(),
        );

        let proxy_clone = Arc::clone(&proxy);
        let read_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 64];
            proxy_clone.read_at(0, &mut buf).await
        });

        tokio::time::sleep(Duration::from_millis(40)).await;
        assert_eq!(proxy.active_downloads(), 1);
        assert!(active_in_flight_downloads() >= 1);

        let start = std::time::Instant::now();
        proxy.cancel();
        let res = read_task.await.unwrap();
        assert_eq!(res.unwrap_err(), StreamError::Cancelled);
        assert!(start.elapsed() < Duration::from_millis(500));
        assert_eq!(proxy.active_downloads(), 0);
        // Yield once so any sibling tests finish dropping guards if run concurrently, then check per-source + global.
        tokio::task::yield_now().await;
        assert_eq!(active_in_flight_downloads(), 0);
    }

    #[tokio::test]
    async fn test_probe_206_without_content_range_total_never_truncates_to_one_byte() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;

        struct UnknownTotal206Transport {
            head_len: Option<u64>,
        }

        #[async_trait]
        impl StreamHttpTransport for UnknownTotal206Transport {
            async fn execute(
                &self,
                req: HttpRequestSpec,
                _read_body: bool,
                _config: &StreamHttpConfig,
                _cancel: &CancellationToken,
            ) -> Result<crate::streaming::HttpResponseData, StreamError> {
                if req.method == Method::HEAD {
                    return Ok(crate::streaming::HttpResponseData {
                        status: if self.head_len.is_some() { 200 } else { 405 },
                        final_url: req.url,
                        headers: HeaderMap::new(), // deliberately omits Accept-Ranges to force GET 0-0
                        content_length: self.head_len,
                        content_range_total: None,
                        body: Bytes::new(),
                    });
                }
                if req.range == Some((0, 0)) {
                    return Ok(crate::streaming::HttpResponseData {
                        status: 206,
                        final_url: req.url,
                        headers: HeaderMap::new(),
                        content_length: Some(1), // 1-byte range length, NOT total!
                        content_range_total: None,
                        body: Bytes::new(),
                    });
                }
                let (s, e) = req.range.unwrap_or((0, 15));
                let len = (e - s + 1) as usize;
                Ok(crate::streaming::HttpResponseData {
                    status: 206,
                    final_url: req.url,
                    headers: HeaderMap::new(),
                    content_length: Some(len as u64),
                    content_range_total: self.head_len,
                    body: Bytes::from(vec![0xABu8; len]),
                })
            }
        }

        // Case 1: HEAD 405 + GET 0-0 returns 206 with Content-Range: bytes 0-0/* and Content-Length: 1
        // Must return Unsupported instead of falsely clamping total length to 1 byte!
        let proxy_err = ChunkedStreamProxy::with_transport(
            "https://podcast.example.com/unknown-total.mp3",
            &BTreeMap::new(),
            None,
            Some("mp3".to_string()),
            Some("audio/mpeg".to_string()),
            Arc::new(UnknownTotal206Transport { head_len: None }),
        )
        .unwrap();
        let mut buf = [0u8; 32];
        let err = proxy_err.read_at(0, &mut buf).await.unwrap_err();
        assert!(matches!(err, StreamError::Unsupported(_)), "got {err:?}");
        assert_eq!(proxy_err.len(), None);

        // Case 2: HEAD provided Content-Length=4096 (without Accept-Ranges) + GET 0-0 returns 206 /*
        // Must preserve head_len=4096 rather than overwriting with 1!
        let proxy_ok = ChunkedStreamProxy::with_transport(
            "https://podcast.example.com/head-len.mp3",
            &BTreeMap::new(),
            None,
            Some("mp3".to_string()),
            Some("audio/mpeg".to_string()),
            Arc::new(UnknownTotal206Transport {
                head_len: Some(4096),
            }),
        )
        .unwrap();
        let n = proxy_ok.read_at(0, &mut buf).await.unwrap();
        assert_eq!(n, 32);
        assert_eq!(proxy_ok.len(), Some(4096));
    }

    #[tokio::test]
    async fn test_non_range_200_ok_caches_full_body_without_redownloading() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let payload = Arc::new(make_pattern_bytes(300_000));
        let get_count = Arc::new(AtomicUsize::new(0));

        struct Always200Transport {
            payload: Arc<Vec<u8>>,
            get_count: Arc<AtomicUsize>,
        }

        #[async_trait]
        impl StreamHttpTransport for Always200Transport {
            async fn execute(
                &self,
                req: HttpRequestSpec,
                _read_body: bool,
                _config: &StreamHttpConfig,
                _cancel: &CancellationToken,
            ) -> Result<crate::streaming::HttpResponseData, StreamError> {
                self.get_count.fetch_add(1, Ordering::SeqCst);
                Ok(crate::streaming::HttpResponseData {
                    status: 200,
                    final_url: req.url,
                    headers: HeaderMap::new(),
                    content_length: Some(self.payload.len() as u64),
                    content_range_total: None,
                    body: Bytes::copy_from_slice(&self.payload),
                })
            }
        }

        let proxy = ChunkedStreamProxy::with_transport(
            "https://rss.example.com/no-range.mp3",
            &BTreeMap::new(),
            Some(payload.len() as u64),
            Some("mp3".to_string()),
            Some("audio/mpeg".to_string()),
            Arc::new(Always200Transport {
                payload: Arc::clone(&payload),
                get_count: Arc::clone(&get_count),
            }),
        )
        .unwrap()
        .with_initial_chunk_size(64 * 1024)
        .with_chunk_size(64 * 1024);

        let mut b1 = [0u8; 256];
        let mut b2 = [0u8; 256];
        let mut b3 = [0u8; 256];
        assert_eq!(proxy.read_at(0, &mut b1).await.unwrap(), 256);
        assert_eq!(&b1[..], &payload[0..256]);
        assert_eq!(proxy.read_at(100_000, &mut b2).await.unwrap(), 256);
        assert_eq!(&b2[..], &payload[100_000..100_256]);
        assert_eq!(proxy.read_at(250_000, &mut b3).await.unwrap(), 256);
        assert_eq!(&b3[..], &payload[250_000..250_256]);

        assert_eq!(
            get_count.load(Ordering::SeqCst),
            1,
            "200 OK full response must be cached once and never re-downloaded per chunk"
        );
    }

    #[tokio::test]
    async fn test_chunked_proxy_3_chunk_async_prefetch_and_metrics() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        // 128 KiB initial + 4 * 512 KiB sequential chunks
        let total = DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE * 4;
        let payload = Arc::new(make_pattern_bytes(total));
        let server = spawn_mock_range_server(
            Arc::clone(&payload),
            Duration::from_millis(5),
            false,
            false,
        )
        .await;

        let url = format!("http://{}/prefetch3.webm", server.addr);
        let proxy = ChunkedStreamProxy::new(
            url,
            &BTreeMap::new(),
            Some(total as u64),
            Some("webm".to_string()),
            Some("audio/webm".to_string()),
        )
        .unwrap()
        .with_stream_key(StreamKey::new("youtube_music", "ytm-prefetch-test", "251"));
        assert_eq!(proxy.prefetch_ahead(), DEFAULT_CHUNK_PREFETCH_AHEAD);
        assert_eq!(proxy.metrics().first_chunk_ms, None);

        // Two sequential reads advancing past chunk 0 midpoint (64 KiB) trigger 3-chunk async prefetch!
        let mut first = vec![0u8; 32 * 1024];
        let mut second = vec![0u8; 40 * 1024];
        assert_eq!(proxy.read_at(0, &mut first).await.unwrap(), first.len());
        assert_eq!(
            proxy.read_at(first.len() as u64, &mut second).await.unwrap(),
            second.len()
        );
        assert_eq!(&first[..], &payload[..first.len()]);
        assert_eq!(&second[..], &payload[first.len()..first.len() + second.len()]);

        // Wait for all 3 background prefetch tasks to complete.
        for _ in 0..80 {
            if proxy.active_downloads() == 0 && proxy.cached_bytes() >= DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE * 3 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }

        let ranges = server.ranges_seen.lock().unwrap().clone();
        assert!(
            ranges.contains(&"bytes=0-131071".to_string())
                && ranges.contains(&"bytes=131072-655359".to_string())
                && ranges.contains(&"bytes=655360-1179647".to_string())
                && ranges.contains(&"bytes=1179648-1703935".to_string()),
            "Expected initial 128 KiB + 3x 512 KiB async prefetched ranges, got {ranges:?}"
        );
        assert!(
            !ranges.iter().any(|r| r.starts_with("bytes=1703936-")),
            "Must stay bounded to 3 chunks ahead, got {ranges:?}"
        );

        let metrics = proxy.metrics();
        assert!(metrics.first_chunk_ms.is_some(), "first_chunk_ms must be populated");
        assert!(metrics.download_kbps > 0, "download_kbps must be > 0");
        assert!(
            metrics.total_downloaded_bytes >= (DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE * 3) as u64,
            "total_downloaded_bytes={}",
            metrics.total_downloaded_bytes
        );
    }

    #[tokio::test]
    async fn synthesize_format_changed_spec_preserves_loudness_and_bitrate() {
        let track_loudness = NormalizedLoudness::new(-6.5, 0.92);
        let album_loudness = NormalizedLoudness::new(-5.0, 0.98);
        let proxy = ChunkedStreamProxy::new(
            "https://example.com/audio.webm",
            &BTreeMap::new(),
            Some(1024),
            Some("webm".to_string()),
            Some("audio/webm".to_string()),
        )
        .unwrap()
        .with_stream_key(StreamKey::new("youtube_music", "track-1", "251"))
        .with_spec_metadata(Some(160_000), Some(track_loudness), Some(album_loudness));

        let spec = proxy.refresh_context().synthesize_format_changed_spec(2048);
        let StreamSourceSpec::DirectRange {
            content_length,
            bitrate_bps,
            loudness,
            album_loudness: alb,
            ..
        } = spec
        else {
            panic!("expected DirectRange variant");
        };
        assert_eq!(content_length, Some(2048));
        assert_eq!(bitrate_bps, Some(160_000));
        assert_eq!(loudness, Some(track_loudness));
        assert_eq!(alb, Some(album_loudness));
    }
}
