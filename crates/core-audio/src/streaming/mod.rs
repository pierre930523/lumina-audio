pub mod bridge;
pub mod chunked_proxy;
pub mod decrypting_stream;
pub mod hybrid_segmented_stream;
pub mod hybrid_stream;
pub mod l2_cache;
pub mod segmented_proxy;

pub use bridge::BlockingStreamBridge;
pub use chunked_proxy::{
    ChunkedProxyMetrics, ChunkedStreamProxy, DEEZER_ALIGNED_CHUNK_SIZE, DEEZER_INITIAL_CHUNK_SIZE,
    DEFAULT_CHUNK_PREFETCH_AHEAD, DEFAULT_CHUNK_SIZE, DEFAULT_INITIAL_CHUNK_SIZE,
    DEFAULT_MAX_CACHE_BYTES, DEFAULT_MAX_CACHED_CHUNKS, OverlapVerifyOutcome,
};
pub use decrypting_stream::{
    DecryptingByteStream, DEFAULT_DEEZER_BLOCK_SIZE, DEFAULT_DEEZER_STRIDE,
};
pub use hybrid_segmented_stream::{HybridSegmentedConfig, HybridSegmentedStream};
pub use hybrid_stream::HybridByteStream;
pub use l2_cache::{
    DashL2Package, DashL2SegmentEntry, L2CacheConfig, L2CacheManager, L2DashHit, L2DirectHit,
    L2EvictionReport, L2FileLease, L2OrphanSweepReport, L2_DASH_MAGIC, MAX_DASH_L2_SEGMENTS,
    build_l2_rel_path, should_admit_to_l2,
};
pub use segmented_proxy::{
    DashSegment, ParsedDashManifest, SegmentedStreamProxy, DEFAULT_MAX_CACHED_SEGMENTS,
    DEFAULT_MAX_SEGMENT_CACHE_BYTES, DEFAULT_PREFETCH_AHEAD, validate_dash_package_compatibility,
};

use std::collections::BTreeMap;
use std::io::ErrorKind;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Duration;

use async_trait::async_trait;
use bytes::{Bytes, BytesMut};
use core_types::{StreamKey, StreamSourceSpec};
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::header::{
    ACCEPT_ENCODING, ACCEPT_RANGES, AUTHORIZATION, CONNECTION, CONTENT_LENGTH, CONTENT_RANGE,
    COOKIE, HOST, HeaderMap, HeaderName, HeaderValue, LOCATION, ORIGIN, PROXY_AUTHORIZATION, RANGE,
    REFERER, USER_AGENT,
};
use reqwest::redirect::Policy;
use reqwest::{Client, Method};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::runtime::Runtime;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

const MAX_HTTP_REDIRECTS: usize = 15;
const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const DEFAULT_READ_TIMEOUT: Duration = Duration::from_secs(15);

/// Standard desktop browser `User-Agent` fallback used when a stream spec omits `User-Agent`
/// (prevents HTTP 403 rejections from external podcast RSS CDNs and strict edge proxies).
pub const DEFAULT_STREAM_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// Default cancellable retry backoff delays for HTTP 403/410 in-place self-healing (max 2 retries).
pub const DEFAULT_REFRESH_403_BACKOFFS: [Duration; 2] = [
    Duration::from_millis(300),
    Duration::from_millis(1000),
];

static STREAMING_RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
static SHARED_HTTP_CLIENT: RwLock<Option<Client>> = RwLock::new(None);
static ACTIVE_IN_FLIGHT_DOWNLOADS: AtomicUsize = AtomicUsize::new(0);
static GLOBAL_NETWORK_EPOCH: AtomicU64 = AtomicU64::new(1);
static NETWORK_EPOCH_TX: OnceLock<watch::Sender<u64>> = OnceLock::new();

#[cfg(test)]
pub(crate) static GLOBAL_DL_TEST_GUARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Error type for streaming proxies, manifest parsing, decryption, and blocking bridge I/O.
#[derive(Debug, Clone, PartialEq, Error)]
pub enum StreamError {
    #[error("stream operation cancelled")]
    Cancelled,
    #[error("stream operation timed out")]
    Timeout,
    #[error("authentication required for provider '{provider_id}' (HTTP {status})")]
    AuthRequired { provider_id: String, status: u16 },
    #[error("stream format changed during refresh")]
    FormatChanged(Box<StreamSourceSpec>),
    #[error("HTTP {0} error")]
    HttpStatus(u16),
    #[error("network error: {0}")]
    Network(String),
    #[error("DRM-restricted stream: {0}")]
    DrmRestricted(String),
    #[error("invalid manifest: {0}")]
    InvalidManifest(String),
    #[error("unsupported stream feature: {0}")]
    Unsupported(String),
    #[error("I/O error: {0}")]
    Io(String),
}

impl StreamError {
    /// Converts this `StreamError` into an idiomatic `std::io::Error` preserving cancellation,
    /// timeout, and permission semantics for downstream demuxers.
    pub fn to_io_error(&self) -> std::io::Error {
        let kind = match self {
            Self::Cancelled => ErrorKind::Interrupted,
            Self::Timeout => ErrorKind::TimedOut,
            Self::AuthRequired { .. } | Self::HttpStatus(401 | 403) | Self::DrmRestricted(_) => {
                ErrorKind::PermissionDenied
            }
            Self::FormatChanged(_) | Self::InvalidManifest(_) => ErrorKind::InvalidData,
            Self::HttpStatus(404 | 410) => ErrorKind::NotFound,
            Self::Unsupported(_) => ErrorKind::Unsupported,
            Self::HttpStatus(_) | Self::Network(_) | Self::Io(_) => ErrorKind::Other,
        };
        std::io::Error::new(kind, self.to_string())
    }
}

/// Request payload dispatched when a streaming proxy encounters HTTP 403 or 410 and needs
/// a refreshed URL/manifest via `ResolverFacade.refresh_after_403`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamRefreshRequest {
    pub provider_id: String,
    pub track_id: String,
    pub quality_key: String,
    pub failed_url: String,
    pub status_code: u16,
    pub attempt: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_content_length: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_mime_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_kind: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_initial_probe: bool,
}

/// Outcome returned by [`StreamRefreshHandler::refresh_after_403`].
#[derive(Debug, Clone, PartialEq)]
pub enum StreamRefreshOutcome {
    Refreshed(StreamSourceSpec),
    FormatChanged(StreamSourceSpec, String),
    AuthRequired {
        provider_id: String,
        message: String,
    },
}

/// Injectable async hook invoked by streaming proxies on HTTP 403 / 410 (never on 401).
#[async_trait]
pub trait StreamRefreshHandler: Send + Sync {
    async fn refresh_after_403(
        &self,
        req: StreamRefreshRequest,
        cancel: &CancellationToken,
    ) -> Result<StreamRefreshOutcome, StreamError>;
}

impl From<StreamError> for std::io::Error {
    fn from(err: StreamError) -> Self {
        err.to_io_error()
    }
}

impl From<std::io::Error> for StreamError {
    fn from(err: std::io::Error) -> Self {
        match err.kind() {
            ErrorKind::Interrupted => Self::Cancelled,
            ErrorKind::TimedOut => Self::Timeout,
            _ => Self::Io(err.to_string()),
        }
    }
}

/// Logical window target returned when seeking a segmented manifest stream by presentation time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SegmentedSeekTarget {
    pub virtual_offset: u64,
    pub segment_index: usize,
    pub segment_start_ms: u64,
}

/// Reason an L2 cached head stream diverged from the fresh remote stream during overlap/manifest validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FormatMismatchReason {
    ContentLengthChanged { expected: u64, actual: u64 },
    TailFingerprintMismatch,
    DashSpecMismatch { detail: String },
}

impl std::fmt::Display for FormatMismatchReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ContentLengthChanged { expected, actual } => {
                write!(f, "content length changed (expected {expected}, got {actual})")
            }
            Self::TailFingerprintMismatch => {
                write!(f, "64-byte L2 overlap tail fingerprint mismatch")
            }
            Self::DashSpecMismatch { detail } => {
                write!(f, "DASH L2 manifest compatibility mismatch: {detail}")
            }
        }
    }
}

/// Callback invoked once when a hybrid L2 stream detects a remote format or fingerprint mismatch.
pub type FormatMismatchCallback = Arc<dyn Fn(StreamKey, FormatMismatchReason) + Send + Sync>;

/// Random-access asynchronous byte stream abstraction implemented by HTTP proxies and stream
/// decorators.
#[async_trait]
pub trait ByteStreamSource: Send + Sync {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError>;

    fn len(&self) -> Option<u64>;

    fn is_empty(&self) -> bool {
        self.len() == Some(0)
    }

    fn cancel(&self);

    fn cancellation_token(&self) -> CancellationToken;

    fn hint_extension(&self) -> Option<&str>;

    fn mime_type(&self) -> Option<&str>;

    async fn seek_to_time_ms(
        &self,
        _target_ms: u64,
    ) -> Result<Option<SegmentedSeekTarget>, StreamError> {
        Ok(None)
    }

    /// Reclaims excess cached RAM chunks/segments while idle/paused, returning bytes freed.
    fn reclaim_idle_memory(&self) -> usize {
        0
    }
}

/// Returns the current global network epoch (starts at `1`, incremented atomically on real NIC/route/VPN changes).
pub fn current_network_epoch() -> u64 {
    GLOBAL_NETWORK_EPOCH.load(Ordering::SeqCst)
}

fn network_epoch_sender() -> &'static watch::Sender<u64> {
    NETWORK_EPOCH_TX.get_or_init(|| {
        let (tx, _rx) = watch::channel(GLOBAL_NETWORK_EPOCH.load(Ordering::SeqCst));
        tx
    })
}

/// Subscribes to live notifications whenever the global network epoch advances.
pub fn subscribe_network_epoch() -> watch::Receiver<u64> {
    network_epoch_sender().subscribe()
}

/// Atomically increments `GLOBAL_NETWORK_EPOCH` without waking `watch` subscribers yet.
/// Used by `NetworkMonitor` so Step 3 (HTTP pool reset) completes before Step 4 wakes active streams.
pub(crate) fn increment_network_epoch_atomic() -> u64 {
    GLOBAL_NETWORK_EPOCH
        .fetch_add(1, Ordering::SeqCst)
        .saturating_add(1)
}

/// Broadcasts `epoch` to all `subscribe_network_epoch()` watchers.
pub(crate) fn broadcast_network_epoch(epoch: u64) {
    network_epoch_sender().send_if_modified(|cur| {
        if epoch > *cur {
            *cur = epoch;
            true
        } else {
            false
        }
    });
}

/// Atomically increments the global network epoch and broadcasts the new value to all subscribers.
pub fn advance_network_epoch() -> u64 {
    let next = increment_network_epoch_atomic();
    broadcast_network_epoch(next);
    next
}

/// Returns the total number of active background/in-flight HTTP download tasks across streaming
/// proxies.
pub fn active_in_flight_downloads() -> usize {
    ACTIVE_IN_FLIGHT_DOWNLOADS.load(Ordering::SeqCst)
}

/// RAII drop guard tracking active network download tasks globally and optionally per source.
#[derive(Debug)]
pub struct InFlightDownloadGuard {
    per_source: Option<Arc<AtomicUsize>>,
}

impl InFlightDownloadGuard {
    /// Increments the global counter (and optional per-source counter) until dropped.
    pub fn new(per_source: Option<Arc<AtomicUsize>>) -> Self {
        ACTIVE_IN_FLIGHT_DOWNLOADS.fetch_add(1, Ordering::SeqCst);
        if let Some(ref counter) = per_source {
            counter.fetch_add(1, Ordering::SeqCst);
        }
        Self { per_source }
    }
}

impl Drop for InFlightDownloadGuard {
    fn drop(&mut self) {
        ACTIVE_IN_FLIGHT_DOWNLOADS.fetch_sub(1, Ordering::SeqCst);
        if let Some(ref counter) = self.per_source {
            counter.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

/// Returns the dedicated multi-thread Tokio runtime (`"lumina-stream-net"`) used for all
/// streaming network I/O and background prefetch tasks.
pub fn streaming_runtime() -> Result<&'static Runtime, StreamError> {
    let res = STREAMING_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .thread_name("lumina-stream-net")
            .enable_all()
            .build()
            .map_err(|e| e.to_string())
    });
    res.as_ref()
        .map_err(|e| StreamError::Io(format!("streaming runtime init failed: {e}")))
}

/// Forces DNS lookups to IPv4 addresses only so outbound stream sockets strictly match
/// IPv4-locked signed CDN URLs (e.g. `yt-dlp --force-ipv4` and IPv4 InnerTube `ip=` locks).
struct Ipv4OnlyDnsResolver;

impl Resolve for Ipv4OnlyDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_string();
        Box::pin(async move {
            let ipv4: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0))
                .await?
                .filter(SocketAddr::is_ipv4)
                .collect();
            if ipv4.is_empty() {
                return Err(Box::new(std::io::Error::new(
                    ErrorKind::AddrNotAvailable,
                    format!("No IPv4 address resolved for '{host}'"),
                )) as Box<dyn std::error::Error + Send + Sync>);
            }
            Ok(Box::new(ipv4.into_iter()) as Addrs)
        })
    }
}

/// Builds a shared HTTP/2 keep-alive `reqwest::Client` configured for audio range streaming.
pub fn build_streaming_http_client(connect_timeout: Duration) -> Result<Client, StreamError> {
    Client::builder()
        .http2_adaptive_window(true)
        .pool_max_idle_per_host(8)
        .pool_idle_timeout(Duration::from_secs(90))
        .connect_timeout(connect_timeout)
        .local_address(IpAddr::V4(Ipv4Addr::UNSPECIFIED))
        .dns_resolver(Arc::new(Ipv4OnlyDnsResolver))
        // Handle redirects manually so caller headers (Referer, Cookie, User-Agent,
        // Authorization, Range) are preserved identically across CDN hops.
        .referer(false)
        .redirect(Policy::none())
        .build()
        .map_err(|e| StreamError::Network(format!("HTTP client init failed: {e}")))
}

static SHARED_HTTP_CLIENT_GEN: AtomicU64 = AtomicU64::new(0);

/// Returns the lazily initialized process-wide shared HTTP/2 keep-alive `reqwest::Client`.
pub fn shared_http_client() -> Result<Client, StreamError> {
    if let Ok(guard) = SHARED_HTTP_CLIENT.read()
        && let Some(ref client) = *guard
    {
        return Ok(client.clone());
    }
    let mut guard = SHARED_HTTP_CLIENT
        .write()
        .map_err(|_| StreamError::Network("shared HTTP client lock poisoned".to_string()))?;
    if let Some(ref client) = *guard {
        return Ok(client.clone());
    }
    let client = build_streaming_http_client(DEFAULT_CONNECT_TIMEOUT)?;
    *guard = Some(client.clone());
    SHARED_HTTP_CLIENT_GEN.fetch_add(1, Ordering::SeqCst);
    Ok(client)
}

/// Drops the current shared HTTP/2 keep-alive connection pool and rebuilds a fresh `reqwest::Client`.
pub fn reset_shared_http_client() -> Result<(), StreamError> {
    let fresh = build_streaming_http_client(DEFAULT_CONNECT_TIMEOUT)?;
    let old = {
        let mut guard = SHARED_HTTP_CLIENT
            .write()
            .map_err(|_| StreamError::Network("shared HTTP client lock poisoned".to_string()))?;
        let prev = guard.replace(fresh);
        SHARED_HTTP_CLIENT_GEN.fetch_add(1, Ordering::SeqCst);
        prev
    };
    drop(old);
    Ok(())
}

/// Drops the shared HTTP/2 pool without eagerly rebuilding when no streaming downloads are active.
pub fn drop_idle_http_connections() -> bool {
    if active_in_flight_downloads() > 0 {
        return false;
    }
    let old = SHARED_HTTP_CLIENT
        .write()
        .ok()
        .and_then(|mut guard| guard.take());
    if old.is_some() {
        SHARED_HTTP_CLIENT_GEN.fetch_add(1, Ordering::SeqCst);
    }
    drop(old);
    crate::stream::reset_http_client();
    true
}

/// Monotonic generation counter incremented whenever the shared HTTP client is built or reset.
pub fn shared_http_client_generation() -> u64 {
    SHARED_HTTP_CLIENT_GEN.load(Ordering::SeqCst)
}

/// Spawns a non-blocking background warmup task onto [`streaming_runtime`] that sends lightweight
/// HTTP/2 `HEAD` requests to YouTube's `/generate_204` endpoints via [`shared_http_client`] with
/// a 4-second timeout to pre-warm TLS + HTTP/2 connection pools. All errors are swallowed.
pub fn spawn_http2_warmup() {
    let Ok(rt) = streaming_runtime() else {
        return;
    };
    let Ok(client) = shared_http_client() else {
        return;
    };
    rt.spawn(async move {
        const WARMUP_URLS: [&str; 2] = [
            "https://www.youtube.com/generate_204",
            "https://music.youtube.com/generate_204",
        ];
        const WARMUP_TIMEOUT: Duration = Duration::from_secs(4);
        let futs = WARMUP_URLS.into_iter().map(|url| {
            let client = client.clone();
            async move {
                let _ = tokio::time::timeout(WARMUP_TIMEOUT, client.head(url).send()).await;
            }
        });
        let _ = futures_util::future::join_all(futs).await;
    });
}

/// Per-proxy timeout and redirect limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamHttpConfig {
    pub connect_timeout: Duration,
    pub request_timeout: Duration,
    pub read_timeout: Duration,
    pub max_redirects: usize,
}

impl Default for StreamHttpConfig {
    fn default() -> Self {
        Self {
            connect_timeout: DEFAULT_CONNECT_TIMEOUT,
            request_timeout: DEFAULT_REQUEST_TIMEOUT,
            read_timeout: DEFAULT_READ_TIMEOUT,
            max_redirects: MAX_HTTP_REDIRECTS,
        }
    }
}

/// Request specification executed by [`StreamHttpTransport`].
#[derive(Debug, Clone)]
pub struct HttpRequestSpec {
    pub method: Method,
    pub url: String,
    pub headers: HeaderMap,
    pub range: Option<(u64, u64)>,
}

/// Buffered HTTP response metadata and payload returned by [`StreamHttpTransport`].
#[derive(Debug, Clone)]
pub struct HttpResponseData {
    pub status: u16,
    pub final_url: String,
    pub headers: HeaderMap,
    pub content_length: Option<u64>,
    pub content_range_total: Option<u64>,
    pub body: Bytes,
}

/// Injectable async HTTP transport abstraction enabling deterministic local server or mock tests.
#[async_trait]
pub trait StreamHttpTransport: Send + Sync {
    async fn execute(
        &self,
        req: HttpRequestSpec,
        read_body: bool,
        config: &StreamHttpConfig,
        cancel: &CancellationToken,
    ) -> Result<HttpResponseData, StreamError>;
}

#[derive(Debug, Clone)]
enum TransportClient {
    Shared,
    Custom(Client),
}

/// Default [`StreamHttpTransport`] backed by `reqwest::Client` with HTTP/2 adaptive window,
/// connection pooling, manual header-preserving redirects, and strict timeout/cancellation hooks.
#[derive(Debug, Clone)]
pub struct ReqwestStreamTransport {
    client: TransportClient,
}

impl ReqwestStreamTransport {
    /// Returns a transport using the shared process-wide HTTP/2 keep-alive `reqwest::Client`.
    /// Each request reads the latest shared client so pool resets take effect immediately.
    pub fn shared() -> Result<Self, StreamError> {
        let _ = shared_http_client()?;
        Ok(Self {
            client: TransportClient::Shared,
        })
    }

    /// Creates a transport wrapping a caller-supplied `reqwest::Client`.
    pub fn from_client(client: Client) -> Self {
        Self {
            client: TransportClient::Custom(client),
        }
    }

    fn resolve_client(&self) -> Result<Client, StreamError> {
        match &self.client {
            TransportClient::Shared => shared_http_client(),
            TransportClient::Custom(c) => Ok(c.clone()),
        }
    }
}

fn is_stale_pooled_send_error(err: &reqwest::Error) -> bool {
    err.is_request() && !err.is_connect() && !err.is_timeout()
}

/// Converts string key/value caller headers into a sanitized `HeaderMap`, stripping hop-by-hop
/// or protocol-prohibited headers (`Host`, `Content-Length`, `Connection`, `Accept-Encoding`,
/// caller `Range`), skipping empty or non-ASCII/invalid optional headers with a warning, and
/// attaching a standard browser `User-Agent` fallback if omitted.
pub fn build_sanitized_headers(
    headers: &BTreeMap<String, String>,
) -> Result<HeaderMap, StreamError> {
    let mut map = HeaderMap::new();
    for (k, v) in headers {
        let trimmed_k = k.trim();
        if trimmed_k.is_empty() {
            continue;
        }
        let name = match HeaderName::from_str(trimmed_k) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!("Skipping invalid HTTP header name '{k}': {e}");
                continue;
            }
        };
        if name == HOST
            || name == CONTENT_LENGTH
            || name == CONNECTION
            || name == ACCEPT_ENCODING
            || name == RANGE
        {
            continue;
        }
        let trimmed_v = v.trim();
        if trimmed_v.is_empty() {
            continue;
        }
        if !trimmed_v.is_ascii() {
            tracing::warn!("Skipping non-ASCII HTTP header value for '{k}'");
            continue;
        }
        let val = match HeaderValue::from_str(trimmed_v) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("Skipping invalid HTTP header value for '{k}': {e}");
                continue;
            }
        };
        map.insert(name, val);
    }
    if !map.contains_key(USER_AGENT) {
        map.insert(USER_AGENT, HeaderValue::from_static(DEFAULT_STREAM_USER_AGENT));
    }
    Ok(map)
}

fn is_google_media_host(host: &str) -> bool {
    let h = host.to_ascii_lowercase();
    h == "googlevideo.com"
        || h.ends_with(".googlevideo.com")
        || h == "gvt1.com"
        || h.ends_with(".gvt1.com")
        || h == "youtube.com"
        || h.ends_with(".youtube.com")
        || h == "googleusercontent.com"
        || h.ends_with(".googleusercontent.com")
        || h == "ytimg.com"
        || h.ends_with(".ytimg.com")
}

/// Returns `true` when redirecting from `from` to `to` stays within the same origin or within the
/// Google/YouTube CDN domain family so provider-specific headers may be forwarded safely.
pub(crate) fn same_trusted_redirect_scope(from: &reqwest::Url, to: &reqwest::Url) -> bool {
    if from.origin() == to.origin() {
        return true;
    }
    match (from.host_str(), to.host_str()) {
        (Some(a), Some(b)) => is_google_media_host(a) && is_google_media_host(b),
        _ => false,
    }
}

/// Strips authentication cookies/tokens and YouTube-specific auth/origin headers before following
/// a redirect to an unrelated origin, while preserving `User-Agent`, `Accept`, `Accept-Language`,
/// and `Range`.
pub(crate) fn strip_sensitive_cross_origin_headers(headers: &mut HeaderMap) {
    headers.remove(AUTHORIZATION);
    headers.remove(PROXY_AUTHORIZATION);
    headers.remove(COOKIE);

    let to_remove: Vec<HeaderName> = headers
        .keys()
        .filter(|name| {
            let s = name.as_str();
            s.starts_with("x-goog-") || s.starts_with("x-youtube-") || s == "x-origin"
        })
        .cloned()
        .collect();
    for name in to_remove {
        headers.remove(name);
    }

    for hdr in [ORIGIN, REFERER] {
        let is_youtube_origin = headers
            .get(&hdr)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_ascii_lowercase())
            .is_some_and(|s| s.contains("youtube.com") || s.contains("googlevideo.com"));
        if is_youtube_origin {
            headers.remove(&hdr);
        }
    }
}

pub(crate) fn header_str(headers: &HeaderMap, key: &HeaderName) -> Option<String> {
    headers
        .get(key)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
}

pub(crate) fn parse_content_length(headers: &HeaderMap) -> Option<u64> {
    header_str(headers, &CONTENT_LENGTH).and_then(|s| s.parse::<u64>().ok())
}

pub(crate) fn parse_content_range_total(headers: &HeaderMap) -> Option<u64> {
    let val = header_str(headers, &CONTENT_RANGE)?;
    let slash_idx = val.rfind('/')?;
    let total_part = val[slash_idx + 1..].trim();
    if total_part == "*" {
        return None;
    }
    total_part.parse::<u64>().ok()
}

pub(crate) fn accepts_byte_ranges(headers: &HeaderMap) -> bool {
    header_str(headers, &ACCEPT_RANGES)
        .map(|v| v.eq_ignore_ascii_case("bytes"))
        .unwrap_or(false)
}

pub(crate) async fn await_watch_result<T: Clone>(
    rx: &mut tokio::sync::watch::Receiver<Option<Result<T, StreamError>>>,
) -> Result<T, StreamError> {
    loop {
        if let Some(res) = rx.borrow().clone() {
            return res;
        }
        if rx.changed().await.is_err() {
            return Err(StreamError::Cancelled);
        }
    }
}

/// Reads up to `buf.len()` bytes sequentially from `source` starting at `offset`, looping past
/// partial reads until `buf` is full or `source` returns `0` (EOF).
pub async fn read_all_at(
    source: &dyn ByteStreamSource,
    offset: u64,
    buf: &mut [u8],
) -> Result<usize, StreamError> {
    let mut total_read = 0usize;
    while total_read < buf.len() {
        let n = source
            .read_at(offset + total_read as u64, &mut buf[total_read..])
            .await?;
        if n == 0 {
            break;
        }
        total_read += n;
    }
    Ok(total_read)
}

pub(crate) fn header_map_to_btree(headers: &HeaderMap) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for (k, v) in headers {
        if let Ok(val) = v.to_str() {
            out.insert(k.as_str().to_string(), val.to_string());
        }
    }
    out
}

pub(crate) fn normalize_mime_base(mime: &str) -> String {
    mime.split(';')
        .next()
        .unwrap_or(mime)
        .trim()
        .to_ascii_lowercase()
}

/// Executes an HTTP request while watching `epoch_rx` for network interface/route switches.
/// If the network epoch advances mid-request (e.g. half-open TCP socket after VPN/hotspot switch),
/// the stalled request future is dropped immediately and retried up to `MAX_EPOCH_RETRIES` times
/// on the freshly rebuilt HTTP client pool.
pub(crate) async fn execute_with_epoch_watch(
    transport: &dyn StreamHttpTransport,
    req: HttpRequestSpec,
    read_body: bool,
    config: &StreamHttpConfig,
    cancel: &CancellationToken,
    epoch_rx: &mut watch::Receiver<u64>,
) -> Result<HttpResponseData, StreamError> {
    const MAX_EPOCH_RETRIES: usize = 2;
    let _ = *epoch_rx.borrow_and_update();

    for attempt in 0..=MAX_EPOCH_RETRIES {
        if cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        let req_clone = req.clone();
        let mut req_fut = transport.execute(req_clone, read_body, config, cancel);
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(StreamError::Cancelled),
            res = &mut req_fut => return res,
            changed = epoch_rx.changed() => {
                if changed.is_ok() {
                    let _ = *epoch_rx.borrow_and_update();
                    if attempt < MAX_EPOCH_RETRIES {
                        continue;
                    }
                    return Err(StreamError::Network(
                        "HTTP request interrupted repeatedly by network epoch change".to_string(),
                    ));
                }
                // Watch sender closed; continue awaiting original request.
                return req_fut.await;
            }
        }
    }

    Err(StreamError::Network(
        "HTTP request interrupted by network epoch change".to_string(),
    ))
}

#[async_trait]
impl StreamHttpTransport for ReqwestStreamTransport {
    async fn execute(
        &self,
        req: HttpRequestSpec,
        read_body: bool,
        config: &StreamHttpConfig,
        cancel: &CancellationToken,
    ) -> Result<HttpResponseData, StreamError> {
        if cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }

        let mut current_url = reqwest::Url::parse(&req.url).map_err(|e| {
            StreamError::Network(format!("Invalid HTTP URL '{}': {e}", req.url))
        })?;
        if current_url.scheme() != "http" && current_url.scheme() != "https" {
            return Err(StreamError::Unsupported(format!(
                "Unsupported stream URL scheme: {current_url}"
            )));
        }

        let mut req_headers = HeaderMap::new();
        for (name, value) in &req.headers {
            if *name == HOST
                || *name == CONTENT_LENGTH
                || *name == CONNECTION
                || *name == ACCEPT_ENCODING
                || *name == RANGE
            {
                continue;
            }
            req_headers.insert(name.clone(), value.clone());
        }
        if !req_headers.contains_key(USER_AGENT) {
            req_headers.insert(USER_AGENT, HeaderValue::from_static(DEFAULT_STREAM_USER_AGENT));
        }
        if let Some((start, end)) = req.range {
            let range_val = format!("bytes={start}-{end}");
            let hv = HeaderValue::from_str(&range_val)
                .map_err(|e| StreamError::Io(format!("Invalid Range header '{range_val}': {e}")))?;
            req_headers.insert(RANGE, hv);
        }

        let mut method = req.method;
        for _hop in 0..=config.max_redirects {
            let mut retried_stale = false;
            let resp = loop {
                let client = self.resolve_client()?;
                let builder = client
                    .request(method.clone(), current_url.clone())
                    .headers(req_headers.clone());

                let send_res = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                    timed = tokio::time::timeout(config.request_timeout, builder.send()) => {
                        match timed {
                            Ok(res) => res,
                            Err(_) => return Err(StreamError::Timeout),
                        }
                    }
                };

                match send_res {
                    Ok(r) => break r,
                    Err(e) if !retried_stale && is_stale_pooled_send_error(&e) => {
                        retried_stale = true;
                        continue;
                    }
                    Err(e) if e.is_timeout() => return Err(StreamError::Timeout),
                    Err(e) => {
                        return Err(StreamError::Network(format!(
                            "HTTP {method} failed for {current_url}: {e:?}"
                        )));
                    }
                }
            };

            let status = resp.status();
            if status.is_redirection()
                && let Some(loc_val) = resp.headers().get(LOCATION)
            {
                let loc_str = loc_val.to_str().map_err(|e| {
                    StreamError::Network(format!(
                        "Invalid redirect Location header from {current_url}: {e}"
                    ))
                })?;
                let next_url = current_url.join(loc_str).map_err(|e| {
                    StreamError::Network(format!(
                        "Invalid redirect Location '{loc_str}' from {current_url}: {e}"
                    ))
                })?;
                if next_url.scheme() != "http" && next_url.scheme() != "https" {
                    return Err(StreamError::Unsupported(format!(
                        "Unsupported redirect URL scheme: {next_url}"
                    )));
                }
                if !same_trusted_redirect_scope(&current_url, &next_url) {
                    strip_sensitive_cross_origin_headers(&mut req_headers);
                }
                if status == reqwest::StatusCode::SEE_OTHER && method != Method::HEAD {
                    method = Method::GET;
                }
                current_url = next_url;
                continue;
            }

            let final_url = resp.url().to_string();
            let resp_headers = resp.headers().clone();
            let content_length = parse_content_length(&resp_headers).or(resp.content_length());
            let content_range_total = parse_content_range_total(&resp_headers);

            if !read_body {
                drop(resp);
                return Ok(HttpResponseData {
                    status: status.as_u16(),
                    final_url,
                    headers: resp_headers,
                    content_length,
                    content_range_total,
                    body: Bytes::new(),
                });
            }

            let mut out = BytesMut::new();
            let mut resp = resp;
            loop {
                let maybe_chunk = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                    timed = tokio::time::timeout(config.read_timeout, resp.chunk()) => {
                        match timed {
                            Ok(Ok(c)) => c,
                            Ok(Err(e)) if e.is_timeout() => return Err(StreamError::Timeout),
                            Ok(Err(e)) => {
                                return Err(StreamError::Network(format!(
                                    "HTTP body chunk failed for {final_url}: {e:?}"
                                )));
                            }
                            Err(_) => return Err(StreamError::Timeout),
                        }
                    }
                };
                match maybe_chunk {
                    Some(chunk) => out.extend_from_slice(&chunk),
                    None => break,
                }
            }

            return Ok(HttpResponseData {
                status: status.as_u16(),
                final_url,
                headers: resp_headers,
                content_length,
                content_range_total,
                body: out.freeze(),
            });
        }

        Err(StreamError::Network(format!(
            "Too many HTTP redirects (>{}) fetching {}",
            config.max_redirects, req.url
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cbc::Encryptor;
    use cipher::BlockModeEncrypt;
    use cipher::KeyIvInit;
    use cipher::inout::InOutBuf;
    use std::io::{Read, Seek, SeekFrom};
    use std::sync::Mutex;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn test_manual_redirect_preserves_caller_headers_and_range() {
        let _guard = GLOBAL_DL_TEST_GUARD.lock().await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let seen_headers = Arc::new(Mutex::new(Vec::<String>::new()));
        let seen_clone = Arc::clone(&seen_headers);

        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let seen_headers = Arc::clone(&seen_clone);
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
                        let req = String::from_utf8_lossy(&req_buf[..header_end]).into_owned();
                        let path = req
                            .lines()
                            .next()
                            .and_then(|l| l.split_whitespace().nth(1))
                            .unwrap_or("/");
                        seen_headers.lock().unwrap().push(req.clone());

                        let resp = if path == "/hop1" {
                            format!(
                                "HTTP/1.1 302 Found\r\nLocation: http://{addr}/final\r\nContent-Length: 0\r\n\r\n"
                            )
                            .into_bytes()
                        } else {
                            let body = b"REDIRECT_OK";
                            format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes 0-10/11\r\n\r\n",
                                body.len()
                            )
                            .into_bytes()
                            .into_iter()
                            .chain(body.iter().copied())
                            .collect()
                        };
                        if socket.write_all(&resp).await.is_err() || socket.flush().await.is_err() {
                            return;
                        }
                    }
                });
            }
        });

        let mut custom = BTreeMap::new();
        custom.insert("Authorization".to_string(), "Bearer secret-tok".to_string());
        custom.insert("Referer".to_string(), "https://music.example.com/".to_string());
        custom.insert("User-Agent".to_string(), "LuminaTest/1.0".to_string());
        let headers = build_sanitized_headers(&custom).unwrap();

        let transport = ReqwestStreamTransport::shared().unwrap();
        let req = HttpRequestSpec {
            method: Method::GET,
            url: format!("http://{addr}/hop1"),
            headers,
            range: Some((0, 10)),
        };
        let cancel = CancellationToken::new();
        let resp = transport
            .execute(req, true, &StreamHttpConfig::default(), &cancel)
            .await
            .unwrap();

        assert_eq!(resp.status, 206);
        assert_eq!(resp.final_url, format!("http://{addr}/final"));
        assert_eq!(&resp.body[..], b"REDIRECT_OK");

        let recorded = seen_headers.lock().unwrap();
        assert_eq!(recorded.len(), 2);
        let hop2_lower = recorded[1].to_ascii_lowercase();
        assert!(hop2_lower.contains("authorization: bearer secret-tok"));
        assert!(hop2_lower.contains("referer: https://music.example.com/"));
        assert!(hop2_lower.contains("user-agent: luminatest/1.0"));
        assert!(hop2_lower.contains("range: bytes=0-10"));
    }

    #[tokio::test]
    async fn test_end_to_end_chunked_deezer_decrypt_and_blocking_bridge() {
        let _guard = GLOBAL_DL_TEST_GUARD.lock().await;
        let total = 6144 * 2 + 1234;
        let plaintext: Vec<u8> = (0..total).map(|i| ((i * 29 + 7) & 0xFF) as u8).collect();
        let key = decrypting_stream::derive_deezer_blowfish_key("123456789");

        let mut encrypted = plaintext.clone();
        for (idx, block) in encrypted
            .chunks_mut(DEFAULT_DEEZER_BLOCK_SIZE)
            .enumerate()
        {
            if block.len() == DEFAULT_DEEZER_BLOCK_SIZE && idx % DEFAULT_DEEZER_STRIDE == 0 {
                let mut enc = Encryptor::<blowfish::Blowfish>::new_from_slices(
                    &key,
                    &decrypting_stream::DEEZER_BLOWFISH_IV,
                )
                .unwrap();
                let (blocks, _) = InOutBuf::from(block).into_chunks();
                enc.encrypt_blocks_inout(blocks);
            }
        }
        let wire = Arc::new(encrypted);

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let wire = Arc::clone(&wire);
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
                        let req = String::from_utf8_lossy(&req_buf[..header_end]).into_owned();
                        let range = req
                            .lines()
                            .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                            .and_then(|l| l.split_once(':'))
                            .and_then(|(_, v)| v.trim().strip_prefix("bytes="))
                            .and_then(|s| s.split_once('-'))
                            .and_then(|(a, b)| Some((a.parse::<usize>().ok()?, b.parse::<usize>().ok()?)));
                        let (s, e) = range.unwrap_or((0, wire.len() - 1));
                        let slice = &wire[s..=e.min(wire.len() - 1)];
                        let hdr = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {s}-{e}/{}\r\n\r\n",
                            slice.len(),
                            wire.len()
                        );
                        if socket.write_all(hdr.as_bytes()).await.is_err()
                            || socket.write_all(slice).await.is_err()
                            || socket.flush().await.is_err()
                        {
                            return;
                        }
                    }
                });
            }
        });

        let proxy = Arc::new(
            ChunkedStreamProxy::new(
                format!("http://{addr}/deezer.flac"),
                &BTreeMap::new(),
                Some(total as u64),
                Some("flac".to_string()),
                Some("audio/flac".to_string()),
            )
            .unwrap()
            .with_chunk_size(DEEZER_ALIGNED_CHUNK_SIZE),
        );
        let decrypting =
            Arc::new(DecryptingByteStream::new(proxy, "123456789").unwrap());
        let mut bridge = BlockingStreamBridge::new(decrypting).unwrap();

        let expected = plaintext.clone();
        tokio::task::spawn_blocking(move || {
            let mut full = vec![0u8; total];
            let mut off = 0;
            while off < total {
                let n = bridge.read(&mut full[off..]).unwrap();
                assert!(n > 0);
                off += n;
            }
            assert_eq!(full, expected);

            bridge.seek(SeekFrom::Start(6144 + 333)).unwrap();
            let mut slice = [0u8; 3000];
            let n = bridge.read(&mut slice).unwrap();
            assert_eq!(n, 3000);
            assert_eq!(&slice[..], &expected[6144 + 333..6144 + 333 + 3000]);
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn test_streaming_http_client_strict_ipv4_dns_and_local_bind() {
        let resolver = Ipv4OnlyDnsResolver;
        let name: Name = "localhost".parse().unwrap();
        let addrs: Vec<SocketAddr> = resolver.resolve(name).await.unwrap().collect();
        assert!(!addrs.is_empty(), "localhost must resolve to at least one IPv4 address");
        assert!(
            addrs.iter().all(SocketAddr::is_ipv4),
            "Ipv4OnlyDnsResolver must return IPv4 addresses only, got {addrs:?}"
        );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut socket, _)) = listener.accept().await {
                let mut tmp = [0u8; 512];
                let _ = socket.read(&mut tmp).await;
                let _ = socket
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                    .await;
                let _ = socket.flush().await;
            }
        });

        let client = build_streaming_http_client(Duration::from_secs(2)).unwrap();
        let resp = client
            .get(format!("http://{addr}/ping"))
            .send()
            .await
            .expect("IPv4 loopback request must succeed");
        assert_eq!(resp.status().as_u16(), 200);

        // Local IPv4 socket binding must reject IPv6 targets rather than silently switching IP family.
        let v6_res = client.get("http://[::1]:1/ping").send().await;
        assert!(
            v6_res.is_err(),
            "IPv4-bound streaming client must not connect to IPv6 addresses"
        );
    }

    #[test]
    fn test_build_sanitized_headers_and_google_redirect_scope() {
        let mut raw = BTreeMap::new();
        raw.insert("User-Agent".to_string(), "CustomUA/1.0".to_string());
        raw.insert("Cookie".to_string(), "SID=abc".to_string());
        raw.insert("Origin".to_string(), "https://music.youtube.com".to_string());
        raw.insert("Referer".to_string(), "https://music.youtube.com/".to_string());
        raw.insert("Authorization".to_string(), "Bearer tok".to_string());
        raw.insert("Accept-Encoding".to_string(), "gzip, deflate, br".to_string());
        raw.insert("Range".to_string(), "bytes=0-100".to_string());
        raw.insert("X-Empty".to_string(), "   ".to_string());
        raw.insert("Bad Header Name".to_string(), "val".to_string());
        raw.insert("X-Non-Ascii".to_string(), "caf\u{00e9}".to_string());
        raw.insert("X-Ctl-Inject".to_string(), "ok\r\nEvil: 1".to_string());

        let sanitized = build_sanitized_headers(&raw).unwrap();
        assert_eq!(
            sanitized.get(USER_AGENT).and_then(|v| v.to_str().ok()),
            Some("CustomUA/1.0")
        );
        assert_eq!(
            sanitized.get(COOKIE).and_then(|v| v.to_str().ok()),
            Some("SID=abc")
        );
        assert_eq!(
            sanitized.get(ORIGIN).and_then(|v| v.to_str().ok()),
            Some("https://music.youtube.com")
        );
        assert_eq!(
            sanitized.get(REFERER).and_then(|v| v.to_str().ok()),
            Some("https://music.youtube.com/")
        );
        assert_eq!(
            sanitized.get(AUTHORIZATION).and_then(|v| v.to_str().ok()),
            Some("Bearer tok")
        );
        assert!(!sanitized.contains_key(ACCEPT_ENCODING));
        assert!(!sanitized.contains_key(RANGE));
        assert!(!sanitized.contains_key("x-empty"));
        assert!(!sanitized.contains_key("x-non-ascii"));
        assert!(!sanitized.contains_key("x-ctl-inject"));

        let mut empty_ua = BTreeMap::new();
        empty_ua.insert("User-Agent".to_string(), "   ".to_string());
        empty_ua.insert("Cookie".to_string(), "".to_string());
        let fallback = build_sanitized_headers(&empty_ua).unwrap();
        assert_eq!(
            fallback.get(USER_AGENT).and_then(|v| v.to_str().ok()),
            Some(DEFAULT_STREAM_USER_AGENT)
        );
        assert!(!fallback.contains_key(COOKIE));

        let from = reqwest::Url::parse("https://rr1---sn-a.googlevideo.com/videoplayback").unwrap();
        let to_gvt = reqwest::Url::parse("https://r2---sn-b.gvt1.com/videoplayback").unwrap();
        let to_ext = reqwest::Url::parse("https://cdn.megaphone.fm/episode.mp3").unwrap();
        assert!(same_trusted_redirect_scope(&from, &to_gvt));
        assert!(!same_trusted_redirect_scope(&from, &to_ext));
        assert_eq!(StreamHttpConfig::default().max_redirects, 15);
    }
}
