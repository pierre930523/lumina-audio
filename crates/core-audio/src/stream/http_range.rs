use std::collections::{HashMap, VecDeque};
use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use reqwest::header::{
    ACCEPT_RANGES, CONNECTION, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, HOST, HeaderMap,
    HeaderName, HeaderValue, RANGE, USER_AGENT,
};
use reqwest::{Method, Response, StatusCode};
use symphonia::core::io::MediaSource;
use tokio_util::sync::CancellationToken;

use super::dns::{
    cancelled_io_error, http_client, http_runtime, is_cancelled, is_token_cancelled,
    run_http_future_cancellable_token, send_following_redirects,
};
use super::playlist::{
    is_playlist_content_type, is_playlist_url, resolve_playlist_url_with_token_opt,
};
use super::range_modes::{HttpSourceMode, RangeCacheState, SequentialState};

pub struct HttpRangeMediaSource {
    seekable: bool,
    total_len: Option<u64>,
    content_type: Option<String>,
    resolved_url: String,
    cancel: Option<CancellationToken>,
    owned_cancel_guard: Option<CancellationToken>,
    inner: Mutex<HttpSourceMode>,
}

impl Drop for HttpRangeMediaSource {
    fn drop(&mut self) {
        if let Some(ref guard) = self.owned_cancel_guard {
            guard.cancel();
        }
    }
}

impl HttpRangeMediaSource {
    pub fn open(url: &str, headers: &HashMap<String, String>) -> std::io::Result<Self> {
        Self::open_with_token_opt(url, headers, None, None, Duration::from_secs(10))
    }

    pub fn open_with_token(
        url: &str,
        headers: &HashMap<String, String>,
        cancel: CancellationToken,
        timeout: Duration,
    ) -> std::io::Result<Self> {
        Self::open_with_token_opt(url, headers, Some(cancel), None, timeout)
    }

    pub fn open_with_cancel(
        url: &str,
        headers: &HashMap<String, String>,
        cancel: Option<Arc<AtomicBool>>,
        timeout: Duration,
    ) -> std::io::Result<Self> {
        if is_cancelled(&cancel) {
            return Err(cancelled_io_error());
        }
        let owned_token = cancel.map(|flag| {
            let tok = CancellationToken::new();
            if flag.load(Ordering::SeqCst) {
                tok.cancel();
            } else if let Ok(rt) = http_runtime() {
                let bg = tok.clone();
                rt.spawn(async move {
                    while !bg.is_cancelled() {
                        if flag.load(Ordering::SeqCst) {
                            bg.cancel();
                            break;
                        }
                        tokio::time::sleep(Duration::from_millis(2)).await;
                    }
                });
            }
            tok
        });
        let res = Self::open_with_token_opt(
            url,
            headers,
            owned_token.clone(),
            owned_token.clone(),
            timeout,
        );
        if res.is_err()
            && let Some(ref tok) = owned_token
        {
            tok.cancel();
        }
        res
    }

    fn open_with_token_opt(
        url: &str,
        headers: &HashMap<String, String>,
        cancel: Option<CancellationToken>,
        owned_cancel_guard: Option<CancellationToken>,
        timeout: Duration,
    ) -> std::io::Result<Self> {
        if is_token_cancelled(&cancel) {
            return Err(cancelled_io_error());
        }
        let deadline = Instant::now() + timeout;
        let remaining_timeout = || {
            let rem = deadline.saturating_duration_since(Instant::now());
            if rem.is_zero() {
                Duration::from_millis(1)
            } else {
                rem
            }
        };

        let trimmed = url.trim();
        let lower = trimmed.to_ascii_lowercase();
        if !lower.starts_with("http://") && !lower.starts_with("https://") {
            return Err(std::io::Error::new(
                ErrorKind::InvalidInput,
                format!("Unsupported stream URL scheme: {url}"),
            ));
        }

        let header_map = build_header_map(headers)?;
        let mut active_url = if is_playlist_url(trimmed) {
            resolve_playlist_url_with_token_opt(
                trimmed,
                headers,
                cancel.clone(),
                remaining_timeout(),
            )?
        } else {
            trimmed.to_string()
        };

        if is_token_cancelled(&cancel) {
            return Err(cancelled_io_error());
        }

        let mut probe = {
            let url_owned = active_url.clone();
            let headers_clone = header_map.clone();
            let step_timeout = remaining_timeout();
            run_http_future_cancellable_token(
                async move { probe_http_stream(&url_owned, &headers_clone, step_timeout).await },
                cancel.clone(),
                step_timeout,
            )?
        };

        let probe_ct = match &probe {
            ProbeResult::Range { content_type, .. } => content_type.as_deref(),
            ProbeResult::Sequential { content_type, .. } => content_type.as_deref(),
        };
        if probe_ct.is_some_and(is_playlist_content_type) {
            drop(probe);
            if is_token_cancelled(&cancel) {
                return Err(cancelled_io_error());
            }
            active_url = resolve_playlist_url_with_token_opt(
                &active_url,
                headers,
                cancel.clone(),
                remaining_timeout(),
            )?;
            if is_token_cancelled(&cancel) {
                return Err(cancelled_io_error());
            }
            let url_owned = active_url.clone();
            let headers_clone = header_map.clone();
            let step_timeout = remaining_timeout();
            probe = run_http_future_cancellable_token(
                async move { probe_http_stream(&url_owned, &headers_clone, step_timeout).await },
                cancel.clone(),
                step_timeout,
            )?;
        }

        let (seekable, total_len, content_type, final_url, mode) = match probe {
            ProbeResult::Range {
                total_len,
                content_type,
                resolved_url,
            } => (
                true,
                Some(total_len),
                content_type,
                resolved_url.clone(),
                HttpSourceMode::Range(RangeCacheState {
                    url: resolved_url,
                    headers: header_map,
                    total_len,
                    pos: 0,
                    chunks: HashMap::new(),
                    lru: VecDeque::new(),
                    cancel: cancel.clone(),
                }),
            ),
            ProbeResult::Sequential {
                total_len,
                content_type,
                resolved_url,
                response,
            } => (
                false,
                total_len,
                content_type,
                resolved_url.clone(),
                HttpSourceMode::Sequential(SequentialState {
                    url: resolved_url,
                    headers: header_map,
                    total_len,
                    pos: 0,
                    stream_pos: 0,
                    history: Vec::new(),
                    pending: Vec::new(),
                    pending_start: 0,
                    eof: false,
                    response,
                    cancel: cancel.clone(),
                }),
            ),
        };

        Ok(Self {
            seekable,
            total_len,
            content_type,
            resolved_url: final_url,
            cancel,
            owned_cancel_guard,
            inner: Mutex::new(mode),
        })
    }

    pub fn content_type(&self) -> Option<&str> {
        self.content_type.as_deref()
    }

    pub fn resolved_url(&self) -> &str {
        &self.resolved_url
    }

    /// Reads up to `len` initial bytes for magic-header detection and rewinds to position 0.
    pub fn read_magic_prefix(&mut self, len: usize) -> std::io::Result<Vec<u8>> {
        let mut out = vec![0u8; len];
        let mut filled = 0;
        while filled < len {
            let n = self.read(&mut out[filled..])?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        out.truncate(filled);
        self.seek(SeekFrom::Start(0))?;
        Ok(out)
    }
}

impl Read for HttpRangeMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if is_token_cancelled(&self.cancel) {
            return Err(cancelled_io_error());
        }
        if buf.is_empty() {
            return Ok(0);
        }
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| std::io::Error::other("HTTP stream lock poisoned"))?;
        match &mut *guard {
            HttpSourceMode::Range(state) => state.read(buf),
            HttpSourceMode::Sequential(state) => state.read(buf),
        }
    }
}

impl Seek for HttpRangeMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        if is_token_cancelled(&self.cancel) {
            return Err(cancelled_io_error());
        }
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| std::io::Error::other("HTTP stream lock poisoned"))?;
        match &mut *guard {
            HttpSourceMode::Range(state) => state.seek(pos),
            HttpSourceMode::Sequential(state) => state.seek(pos),
        }
    }
}

impl MediaSource for HttpRangeMediaSource {
    fn is_seekable(&self) -> bool {
        self.seekable
    }

    fn byte_len(&self) -> Option<u64> {
        self.total_len
    }
}

enum ProbeResult {
    Range {
        total_len: u64,
        content_type: Option<String>,
        resolved_url: String,
    },
    Sequential {
        total_len: Option<u64>,
        content_type: Option<String>,
        resolved_url: String,
        response: Option<Response>,
    },
}

pub(super) fn build_header_map(headers: &HashMap<String, String>) -> std::io::Result<HeaderMap> {
    let mut map = HeaderMap::new();
    for (k, v) in headers {
        let trimmed_k = k.trim();
        if trimmed_k.is_empty() {
            continue;
        }
        let name = HeaderName::from_str(trimmed_k).map_err(|e| {
            std::io::Error::new(
                ErrorKind::InvalidInput,
                format!("Invalid HTTP header name '{k}': {e}"),
            )
        })?;
        if name == HOST || name == CONTENT_LENGTH {
            continue;
        }
        let trimmed_v = v.trim();
        if name == USER_AGENT && trimmed_v.is_empty() {
            continue;
        }
        let val = HeaderValue::from_str(trimmed_v).map_err(|e| {
            std::io::Error::new(
                ErrorKind::InvalidInput,
                format!("Invalid HTTP header value for '{k}': {e}"),
            )
        })?;
        map.insert(name, val);
    }
    if !map.contains_key(USER_AGENT) {
        map.insert(
            USER_AGENT,
            HeaderValue::from_static(crate::streaming::DEFAULT_STREAM_USER_AGENT),
        );
    }
    Ok(map)
}

pub(super) fn header_str(headers: &HeaderMap, key: &HeaderName) -> Option<String> {
    headers
        .get(key)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
}

fn parse_content_length(headers: &HeaderMap) -> Option<u64> {
    header_str(headers, &CONTENT_LENGTH).and_then(|s| s.parse::<u64>().ok())
}

fn parse_content_range_total(headers: &HeaderMap) -> Option<u64> {
    let val = header_str(headers, &CONTENT_RANGE)?;
    let slash_idx = val.rfind('/')?;
    let total_part = val[slash_idx + 1..].trim();
    if total_part == "*" {
        return None;
    }
    total_part.parse::<u64>().ok()
}

pub(super) fn map_http_status_err(status: StatusCode, url: &str) -> std::io::Error {
    let kind = match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => ErrorKind::PermissionDenied,
        StatusCode::NOT_FOUND | StatusCode::GONE => ErrorKind::NotFound,
        _ => ErrorKind::Other,
    };
    std::io::Error::new(kind, format!("HTTP {} fetching {}", status.as_u16(), url))
}

async fn probe_http_stream(
    url: &str,
    headers: &HeaderMap,
    timeout: Duration,
) -> std::io::Result<ProbeResult> {
    let client = http_client()?;

    let mut head_content_type = None;
    let mut head_content_length = None;
    let mut probe_url = url.to_string();
    let mut head_forbidden_err: Option<std::io::Error> = None;

    let mut head_headers = headers.clone();
    // Prevent servers like googlevideo.com that drop sockets after HEAD from
    // poisoning reqwest's idle connection pool for the subsequent Range GET.
    head_headers.insert(CONNECTION, HeaderValue::from_static("close"));

    if let Ok(head_resp) = send_following_redirects(
        &client,
        Method::HEAD,
        url,
        &head_headers,
        Some(timeout.min(Duration::from_secs(4))),
    )
    .await
    {
        let status = head_resp.status();
        if status.is_success() {
            probe_url = head_resp.url().to_string();
            let resp_headers = head_resp.headers();
            head_content_type = header_str(resp_headers, &CONTENT_TYPE);
            head_content_length = parse_content_length(resp_headers);
            let accepts_ranges = header_str(resp_headers, &ACCEPT_RANGES)
                .map(|v| v.eq_ignore_ascii_case("bytes"))
                .unwrap_or(false);

            if accepts_ranges && let Some(len) = head_content_length {
                return Ok(ProbeResult::Range {
                    total_len: len,
                    content_type: head_content_type,
                    resolved_url: probe_url,
                });
            }
        } else if status == StatusCode::UNAUTHORIZED || status == StatusCode::NOT_FOUND {
            return Err(map_http_status_err(status, head_resp.url().as_str()));
        } else if status == StatusCode::FORBIDDEN {
            // Some signed GET-only CDNs reject HEAD with 403 while permitting GET;
            // still preserve the 403 error if the subsequent GET fails to connect.
            head_forbidden_err = Some(map_http_status_err(status, head_resp.url().as_str()));
        }
    }

    // Probe GET with Range: bytes=0-0
    let mut probe_headers = headers.clone();
    probe_headers.insert(RANGE, HeaderValue::from_static("bytes=0-0"));

    let resp = match send_following_redirects(
        &client,
        Method::GET,
        &probe_url,
        &probe_headers,
        Some(timeout),
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return Err(head_forbidden_err.unwrap_or(e));
        }
    };

    let final_url = resp.url().to_string();
    let status = resp.status();
    if !status.is_success() && status != StatusCode::PARTIAL_CONTENT {
        return Err(map_http_status_err(status, &final_url));
    }

    let resp_headers = resp.headers();
    let content_type = header_str(resp_headers, &CONTENT_TYPE).or(head_content_type);

    if status == StatusCode::PARTIAL_CONTENT {
        if let Some(total_len) = parse_content_range_total(resp_headers).or(head_content_length) {
            return Ok(ProbeResult::Range {
                total_len,
                content_type,
                resolved_url: final_url,
            });
        }
        // Server sent 206 with unknown total ('/*'): fall back to sequential GET without range.
        return Ok(ProbeResult::Sequential {
            total_len: None,
            content_type,
            resolved_url: final_url,
            response: None,
        });
    }

    // 200 OK (non-range server): keep the live response stream for sequential reading.
    let total_len = resp.content_length().or(head_content_length);
    Ok(ProbeResult::Sequential {
        total_len,
        content_type,
        resolved_url: final_url,
        response: Some(resp),
    })
}
