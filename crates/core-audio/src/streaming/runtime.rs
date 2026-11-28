use std::io::ErrorKind;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Duration;

use reqwest::Client;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::redirect::Policy;
use tokio::runtime::Runtime;
use tokio::sync::watch;

use super::types::{DEFAULT_CONNECT_TIMEOUT, StreamError};

/// Standard desktop browser `User-Agent` fallback used when a stream spec omits `User-Agent`
/// (prevents HTTP 403 rejections from external podcast RSS CDNs and strict edge proxies).
pub const DEFAULT_STREAM_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// Default cancellable retry backoff delays for HTTP 403/410 in-place self-healing (max 2 retries).
pub const DEFAULT_REFRESH_403_BACKOFFS: [Duration; 2] =
    [Duration::from_millis(300), Duration::from_millis(1000)];

static STREAMING_RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
static SHARED_HTTP_CLIENT: RwLock<Option<Client>> = RwLock::new(None);
static ACTIVE_IN_FLIGHT_DOWNLOADS: AtomicUsize = AtomicUsize::new(0);
static GLOBAL_NETWORK_EPOCH: AtomicU64 = AtomicU64::new(1);
static NETWORK_EPOCH_TX: OnceLock<watch::Sender<u64>> = OnceLock::new();
static SHARED_HTTP_CLIENT_GEN: AtomicU64 = AtomicU64::new(0);

#[cfg(test)]
pub(crate) static GLOBAL_DL_TEST_GUARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

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
pub(super) struct Ipv4OnlyDnsResolver;

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
                ))
                    as Box<dyn std::error::Error + Send + Sync>);
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
