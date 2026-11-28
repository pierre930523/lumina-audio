use std::future::Future;
use std::io::ErrorKind;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock, RwLock, mpsc};
use std::time::Duration;

use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::header::{HeaderMap, HeaderValue, LOCATION, USER_AGENT};
use reqwest::redirect::Policy;
use reqwest::{Client, Method, Response};
use tokio_util::sync::CancellationToken;

pub(super) const MAX_HTTP_REDIRECTS: usize = 10;

static HTTP_RUNTIME: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();
static HTTP_CLIENT: RwLock<Option<Client>> = RwLock::new(None);

/// Forces DNS lookups to IPv4 addresses only so outbound stream sockets match
/// `yt-dlp --force-ipv4` (`ip=` lock on `googlevideo.com` URLs).
struct Ipv4OnlyDnsResolver;

impl Resolve for Ipv4OnlyDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_string();
        Box::pin(async move {
            let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0))
                .await?
                .filter(SocketAddr::is_ipv4)
                .collect();
            if addrs.is_empty() {
                return Err(Box::new(std::io::Error::new(
                    ErrorKind::AddrNotAvailable,
                    format!("No IPv4 address resolved for '{host}'"),
                ))
                    as Box<dyn std::error::Error + Send + Sync>);
            }
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

pub(super) fn http_runtime() -> std::io::Result<&'static tokio::runtime::Runtime> {
    let res = HTTP_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("lumina-audio-http")
            .enable_all()
            .build()
            .map_err(|e| e.to_string())
    });
    res.as_ref()
        .map_err(|e| std::io::Error::other(format!("HTTP runtime init failed: {e}")))
}

fn build_http_client() -> std::io::Result<Client> {
    Client::builder()
        .connect_timeout(Duration::from_secs(8))
        .pool_idle_timeout(Duration::from_secs(30))
        .local_address(IpAddr::V4(Ipv4Addr::UNSPECIFIED))
        .dns_resolver(Arc::new(Ipv4OnlyDnsResolver))
        // Handle redirects manually so caller headers (Referer, Cookie, User-Agent,
        // Accept, Accept-Language, Range) are never stripped or overwritten on hops.
        .referer(false)
        .redirect(Policy::none())
        .build()
        .map_err(|e| std::io::Error::other(format!("HTTP client init failed: {e}")))
}

pub(super) fn http_client() -> std::io::Result<Client> {
    if let Ok(guard) = HTTP_CLIENT.read()
        && let Some(ref client) = *guard
    {
        return Ok(client.clone());
    }
    let mut guard = HTTP_CLIENT
        .write()
        .map_err(|_| std::io::Error::other("HTTP client lock poisoned"))?;
    if let Some(ref client) = *guard {
        return Ok(client.clone());
    }
    let client = build_http_client()?;
    *guard = Some(client.clone());
    Ok(client)
}

/// Drops the legacy HTTP keep-alive connection pool so subsequent requests open fresh sockets.
pub fn reset_http_client() {
    let old = HTTP_CLIENT.write().ok().and_then(|mut guard| guard.take());
    drop(old);
}

fn is_stale_pooled_send_error(err: &reqwest::Error) -> bool {
    err.is_request() && !err.is_connect() && !err.is_timeout()
}

pub(super) async fn send_following_redirects(
    client: &Client,
    method: Method,
    url: &str,
    headers: &HeaderMap,
    timeout: Option<Duration>,
) -> std::io::Result<Response> {
    let mut current_url = reqwest::Url::parse(url).map_err(|e| {
        std::io::Error::new(
            ErrorKind::InvalidInput,
            format!("Invalid HTTP URL '{url}': {e}"),
        )
    })?;
    let mut active_headers = headers.clone();
    if !active_headers.contains_key(USER_AGENT) {
        active_headers.insert(
            USER_AGENT,
            HeaderValue::from_static(crate::streaming::DEFAULT_STREAM_USER_AGENT),
        );
    }

    for _hop in 0..=MAX_HTTP_REDIRECTS {
        let mut retried_stale = false;
        let resp = loop {
            let req = client
                .request(method.clone(), current_url.clone())
                .headers(active_headers.clone());
            // Bound only connection + response headers so reqwest does not abort long-lived
            // sequential audio response bodies once streaming starts.
            let send_res = if let Some(t) = timeout {
                tokio::time::timeout(t, req.send())
                    .await
                    .map_err(|_| timeout_io_error(t))?
            } else {
                req.send().await
            };
            match send_res {
                Ok(r) => break r,
                Err(e) if !retried_stale && is_stale_pooled_send_error(&e) => {
                    retried_stale = true;
                    continue;
                }
                Err(e) => {
                    return Err(std::io::Error::other(format!(
                        "HTTP {method} failed: {e:?}"
                    )));
                }
            }
        };

        let status = resp.status();
        if status.is_redirection()
            && let Some(loc_val) = resp.headers().get(LOCATION)
        {
            let loc_str = loc_val.to_str().map_err(|e| {
                std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!("Invalid redirect Location header from {current_url}: {e}"),
                )
            })?;
            let next_url = current_url.join(loc_str).map_err(|e| {
                std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!("Invalid redirect Location '{loc_str}' from {current_url}: {e}"),
                )
            })?;
            if next_url.scheme() != "http" && next_url.scheme() != "https" {
                return Err(std::io::Error::new(
                    ErrorKind::InvalidInput,
                    format!("Unsupported redirect URL scheme: {next_url}"),
                ));
            }
            if !crate::streaming::same_trusted_redirect_scope(&current_url, &next_url) {
                crate::streaming::strip_sensitive_cross_origin_headers(&mut active_headers);
            }
            current_url = next_url;
            continue;
        }

        return Ok(resp);
    }

    Err(std::io::Error::other(format!(
        "Too many HTTP redirects (>{MAX_HTTP_REDIRECTS}) fetching {url}"
    )))
}

pub(super) fn is_cancelled(cancel: &Option<Arc<AtomicBool>>) -> bool {
    cancel
        .as_ref()
        .is_some_and(|flag| flag.load(Ordering::SeqCst))
}

pub(super) fn is_token_cancelled(cancel: &Option<CancellationToken>) -> bool {
    cancel.as_ref().is_some_and(CancellationToken::is_cancelled)
}

pub(super) fn cancelled_io_error() -> std::io::Error {
    std::io::Error::new(ErrorKind::Interrupted, "HTTP stream open cancelled")
}

pub(super) fn timeout_io_error(timeout: Duration) -> std::io::Error {
    std::io::Error::new(
        ErrorKind::TimedOut,
        format!("HTTP stream open timed out after {}ms", timeout.as_millis()),
    )
}

/// Runs an async future on `HTTP_RUNTIME` with bounded timeout and instant (<1ms) event-driven
/// `CancellationToken` interruption.
pub(super) fn run_http_future_cancellable_token<F, T>(
    fut: F,
    cancel: Option<CancellationToken>,
    timeout: Duration,
) -> std::io::Result<T>
where
    F: Future<Output = std::io::Result<T>> + Send + 'static,
    T: Send + 'static,
{
    if is_token_cancelled(&cancel) {
        return Err(cancelled_io_error());
    }
    let rt = http_runtime()?;
    let (tx, rx) = mpsc::sync_channel(1);
    rt.spawn(async move {
        let deadline = tokio::time::sleep(timeout);
        tokio::pin!(deadline);
        tokio::pin!(fut);

        let out = if let Some(token) = cancel {
            tokio::select! {
                biased;
                _ = token.cancelled() => Err(cancelled_io_error()),
                res = &mut fut => res,
                _ = &mut deadline => Err(timeout_io_error(timeout)),
            }
        } else {
            tokio::select! {
                res = &mut fut => res,
                _ = &mut deadline => Err(timeout_io_error(timeout)),
            }
        };
        let _ = tx.send(out);
    });
    rx.recv()
        .map_err(|e| std::io::Error::other(format!("HTTP worker channel closed: {e}")))?
}

/// Runs an async future on `HTTP_RUNTIME` with bounded timeout and cooperative cancellation.
pub(super) fn run_http_future_cancellable<F, T>(
    fut: F,
    cancel: Option<Arc<AtomicBool>>,
    timeout: Duration,
) -> std::io::Result<T>
where
    F: Future<Output = std::io::Result<T>> + Send + 'static,
    T: Send + 'static,
{
    if is_cancelled(&cancel) {
        return Err(cancelled_io_error());
    }
    let rt = http_runtime()?;
    let (tx, rx) = mpsc::sync_channel(1);
    rt.spawn(async move {
        let deadline = tokio::time::sleep(timeout);
        tokio::pin!(deadline);
        tokio::pin!(fut);

        let out = if let Some(flag) = cancel {
            loop {
                if flag.load(Ordering::SeqCst) {
                    break Err(cancelled_io_error());
                }
                tokio::select! {
                    biased;
                    res = &mut fut => break res,
                    _ = &mut deadline => break Err(timeout_io_error(timeout)),
                    _ = tokio::time::sleep(Duration::from_millis(2)) => {}
                }
            }
        } else {
            tokio::select! {
                res = &mut fut => res,
                _ = &mut deadline => Err(timeout_io_error(timeout)),
            }
        };
        let _ = tx.send(out);
    });
    rx.recv()
        .map_err(|e| std::io::Error::other(format!("HTTP worker channel closed: {e}")))?
}
