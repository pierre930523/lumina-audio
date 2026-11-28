use std::collections::BTreeMap;
use std::str::FromStr;
use std::time::Duration;

use reqwest::header::{
    ACCEPT_ENCODING, ACCEPT_RANGES, AUTHORIZATION, CONNECTION, CONTENT_LENGTH, CONTENT_RANGE,
    COOKIE, HOST, HeaderMap, HeaderName, HeaderValue, ORIGIN, PROXY_AUTHORIZATION, RANGE, REFERER,
    USER_AGENT,
};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::runtime::DEFAULT_STREAM_USER_AGENT;
use super::types::{
    ByteStreamSource, HttpRequestSpec, HttpResponseData, StreamError, StreamHttpConfig,
    StreamHttpTransport,
};

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
        map.insert(
            USER_AGENT,
            HeaderValue::from_static(DEFAULT_STREAM_USER_AGENT),
        );
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
    rx: &mut watch::Receiver<Option<Result<T, StreamError>>>,
    cancel: &CancellationToken,
) -> Result<T, StreamError> {
    loop {
        if let Some(res) = rx.borrow().clone() {
            return res;
        }
        if cancel.is_cancelled() {
            // Brief 3 ms grace window so cooperative download tasks finish dropping
            // `InFlightDownloadGuard` and their watch sender, while guaranteeing < 5 ms cancel.
            let _ = tokio::time::timeout(Duration::from_millis(3), async {
                while rx.changed().await.is_ok() {}
            })
            .await;
            return Err(StreamError::Cancelled);
        }
        tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                let _ = tokio::time::timeout(Duration::from_millis(3), async {
                    while rx.changed().await.is_ok() {}
                })
                .await;
                return Err(StreamError::Cancelled);
            }
            changed = rx.changed() => {
                if changed.is_err() {
                    return Err(StreamError::Cancelled);
                }
            }
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
                // Watch sender closed; continue awaiting original request while still honoring cancel.
                return tokio::select! {
                    biased;
                    _ = cancel.cancelled() => Err(StreamError::Cancelled),
                    res = req_fut => res,
                };
            }
        }
    }

    Err(StreamError::Network(
        "HTTP request interrupted by network epoch change".to_string(),
    ))
}
