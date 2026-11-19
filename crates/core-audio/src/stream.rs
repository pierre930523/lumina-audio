use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderName, HeaderValue, ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, RANGE};
use reqwest::{Client, Response, StatusCode};
use symphonia::core::io::MediaSource;

const CHUNK_SIZE: usize = 128 * 1024;
const MAX_CACHED_CHUNKS: usize = 24;
const NON_RANGE_HISTORY_LIMIT: usize = 256 * 1024;
const MAX_PLAYLIST_DEPTH: usize = 4;
const MAX_PLAYLIST_BYTES: usize = 256 * 1024;

static HTTP_RUNTIME: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();
static HTTP_CLIENT: OnceLock<Result<Client, String>> = OnceLock::new();

fn http_runtime() -> std::io::Result<&'static tokio::runtime::Runtime> {
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

fn http_client() -> std::io::Result<&'static Client> {
    let res = HTTP_CLIENT.get_or_init(|| {
        Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(120))
            .build()
            .map_err(|e| e.to_string())
    });
    res.as_ref()
        .map_err(|e| std::io::Error::other(format!("HTTP client init failed: {e}")))
}

/// Runs an async future on the dedicated `HTTP_RUNTIME`, blocking the calling
/// synchronous thread via a bounded channel. Safe from inside Tokio workers,
/// `#[tokio::test]`, and plain OS threads.
fn run_http_future<F, T>(fut: F) -> std::io::Result<T>
where
    F: Future<Output = std::io::Result<T>> + Send + 'static,
    T: Send + 'static,
{
    let rt = http_runtime()?;
    let (tx, rx) = mpsc::sync_channel(1);
    rt.spawn(async move {
        let out = fut.await;
        let _ = tx.send(out);
    });
    rx.recv()
        .map_err(|e| std::io::Error::other(format!("HTTP worker channel closed: {e}")))?
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamOrigin {
    LocalFile(PathBuf),
    Http {
        url: String,
        headers: HashMap<String, String>,
    },
    Synth {
        track_id: String,
        title: String,
        duration_ms: u64,
        sample_rate_hz: u32,
        channels: u16,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct StreamSource {
    pub origin: StreamOrigin,
    pub hint_extension: Option<String>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
}

impl StreamSource {
    pub fn local_file(path: impl Into<PathBuf>) -> Self {
        let pb = path.into();
        let hint_extension = pb
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase());
        Self {
            origin: StreamOrigin::LocalFile(pb),
            hint_extension,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn http(
        url: impl Into<String>,
        headers: HashMap<String, String>,
        hint_extension: Option<String>,
    ) -> Self {
        Self {
            origin: StreamOrigin::Http {
                url: url.into(),
                headers,
            },
            hint_extension: hint_extension.map(|s| s.trim_start_matches('.').to_ascii_lowercase()),
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn synth(
        track_id: impl Into<String>,
        title: impl Into<String>,
        duration_ms: u64,
    ) -> Self {
        let effective_duration_ms = if duration_ms == 0 {
            245_000
        } else {
            duration_ms
        };
        Self {
            origin: StreamOrigin::Synth {
                track_id: track_id.into(),
                title: title.into(),
                duration_ms: effective_duration_ms,
                sample_rate_hz: 48_000,
                channels: 2,
            },
            hint_extension: None,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn with_replay_gain(
        mut self,
        track_db: Option<f64>,
        album_db: Option<f64>,
        track_peak: Option<f64>,
        album_peak: Option<f64>,
    ) -> Self {
        self.replay_gain_track_db = track_db;
        self.replay_gain_album_db = album_db;
        self.replay_gain_track_peak = track_peak;
        self.replay_gain_album_peak = album_peak;
        self
    }

    pub fn display_path(&self) -> PathBuf {
        match &self.origin {
            StreamOrigin::LocalFile(p) => p.clone(),
            StreamOrigin::Http { url, .. } => PathBuf::from(url),
            StreamOrigin::Synth { track_id, .. } => PathBuf::from(format!("synth://{track_id}")),
        }
    }
}

struct RangeCacheState {
    url: String,
    headers: HeaderMap,
    total_len: u64,
    pos: u64,
    chunks: HashMap<u64, Arc<[u8]>>,
    lru: VecDeque<u64>,
}

struct SequentialState {
    url: String,
    headers: HeaderMap,
    total_len: Option<u64>,
    pos: u64,
    stream_pos: u64,
    history: Vec<u8>,
    pending: Vec<u8>,
    pending_start: u64,
    eof: bool,
    response: Option<Response>,
}

enum HttpSourceMode {
    Range(RangeCacheState),
    Sequential(SequentialState),
}

pub struct HttpRangeMediaSource {
    seekable: bool,
    total_len: Option<u64>,
    content_type: Option<String>,
    resolved_url: String,
    inner: Mutex<HttpSourceMode>,
}

impl HttpRangeMediaSource {
    pub fn open(url: &str, headers: &HashMap<String, String>) -> std::io::Result<Self> {
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
            resolve_playlist_url(trimmed, headers)?
        } else {
            trimmed.to_string()
        };

        let mut probe = {
            let url_owned = active_url.clone();
            let headers_clone = header_map.clone();
            run_http_future(async move { probe_http_stream(&url_owned, &headers_clone).await })?
        };

        let probe_ct = match &probe {
            ProbeResult::Range { content_type, .. } => content_type.as_deref(),
            ProbeResult::Sequential { content_type, .. } => content_type.as_deref(),
        };
        if probe_ct.is_some_and(is_playlist_content_type) {
            drop(probe);
            active_url = resolve_playlist_url(&active_url, headers)?;
            let url_owned = active_url.clone();
            let headers_clone = header_map.clone();
            probe = run_http_future(async move { probe_http_stream(&url_owned, &headers_clone).await })?;
        }

        let (seekable, total_len, content_type, mode) = match probe {
            ProbeResult::Range {
                total_len,
                content_type,
            } => (
                true,
                Some(total_len),
                content_type,
                HttpSourceMode::Range(RangeCacheState {
                    url: active_url.clone(),
                    headers: header_map,
                    total_len,
                    pos: 0,
                    chunks: HashMap::new(),
                    lru: VecDeque::new(),
                }),
            ),
            ProbeResult::Sequential {
                total_len,
                content_type,
                response,
            } => (
                false,
                total_len,
                content_type,
                HttpSourceMode::Sequential(SequentialState {
                    url: active_url.clone(),
                    headers: header_map,
                    total_len,
                    pos: 0,
                    stream_pos: 0,
                    history: Vec::new(),
                    pending: Vec::new(),
                    pending_start: 0,
                    eof: false,
                    response,
                }),
            ),
        };

        Ok(Self {
            seekable,
            total_len,
            content_type,
            resolved_url: active_url,
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

pub fn is_playlist_extension(ext: &str) -> bool {
    matches!(
        ext.trim().trim_start_matches('.').to_ascii_lowercase().as_str(),
        "m3u" | "m3u8" | "pls"
    )
}

pub fn is_playlist_url(url: &str) -> bool {
    let without_frag = url.split('#').next().unwrap_or(url);
    let without_query = without_frag.split('?').next().unwrap_or(without_frag);
    let Some(last_seg) = without_query.rsplit('/').next() else {
        return false;
    };
    let Some(dot_idx) = last_seg.rfind('.') else {
        return false;
    };
    is_playlist_extension(&last_seg[dot_idx + 1..])
}

pub fn is_playlist_content_type(content_type: &str) -> bool {
    let lower = content_type.to_ascii_lowercase();
    lower.contains("mpegurl")
        || lower.contains("x-scpls")
        || lower.contains("pls+xml")
        || lower.contains("audio/pls")
}

pub fn looks_like_playlist_magic(magic: &[u8]) -> bool {
    let text = String::from_utf8_lossy(magic);
    let trimmed = text.trim_start_matches('\u{feff}').trim_start();
    let lower = trimmed.to_ascii_lowercase();
    lower.starts_with("#extm3u") || lower.starts_with("[playlist]")
}

pub fn parse_m3u_entries(body: &str) -> Vec<String> {
    body.lines()
        .map(|l| l.trim_matches('\u{feff}').trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect()
}

pub fn parse_pls_entries(body: &str) -> Vec<String> {
    let mut entries = Vec::new();
    for line in body.lines() {
        let trimmed = line.trim_matches('\u{feff}').trim();
        let lower = trimmed.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("file")
            && let Some(eq_idx) = rest.find('=')
        {
            let index_part = rest[..eq_idx].trim();
            if !index_part.is_empty() && index_part.chars().all(|c| c.is_ascii_digit()) {
                let raw_eq = trimmed.find('=').unwrap_or(0);
                let val = trimmed[raw_eq + 1..].trim();
                if !val.is_empty() {
                    entries.push(val.to_string());
                }
            }
        }
    }
    entries
}

pub fn resolve_playlist_url(
    url: &str,
    headers: &HashMap<String, String>,
) -> std::io::Result<String> {
    let header_map = build_header_map(headers)?;
    let start_url = url.trim().to_string();
    run_http_future(async move {
        let client = http_client()?;
        let mut current = start_url;
        let mut visited = HashSet::new();

        for _depth in 0..MAX_PLAYLIST_DEPTH {
            if !visited.insert(current.clone()) {
                return Err(std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!("Playlist redirect/reference cycle detected at {current}"),
                ));
            }

            let resp = client
                .get(&current)
                .headers(header_map.clone())
                .send()
                .await
                .map_err(|e| std::io::Error::other(format!("HTTP playlist GET failed: {e}")))?;

            let status = resp.status();
            if !status.is_success() {
                return Err(map_http_status_err(status, &current));
            }

            let final_url = resp.url().clone();
            let content_type = header_str(resp.headers(), &CONTENT_TYPE);
            let mut body_bytes = Vec::new();
            let mut resp = resp;
            while let Some(chunk) = resp
                .chunk()
                .await
                .map_err(|e| std::io::Error::other(format!("HTTP playlist read failed: {e}")))?
            {
                let remaining = MAX_PLAYLIST_BYTES.saturating_sub(body_bytes.len());
                if remaining == 0 {
                    break;
                }
                let take = remaining.min(chunk.len());
                body_bytes.extend_from_slice(&chunk[..take]);
                if body_bytes.len() >= MAX_PLAYLIST_BYTES {
                    break;
                }
            }

            let body = String::from_utf8_lossy(&body_bytes);
            let is_pls = current.to_ascii_lowercase().contains(".pls")
                || content_type
                    .as_deref()
                    .is_some_and(|ct| ct.to_ascii_lowercase().contains("scpls"))
                || body
                    .trim_start_matches('\u{feff}')
                    .trim_start()
                    .to_ascii_lowercase()
                    .starts_with("[playlist]");

            let entries = if is_pls {
                parse_pls_entries(&body)
            } else {
                parse_m3u_entries(&body)
            };

            let Some(first_entry) = entries.into_iter().next() else {
                return Err(std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!("Playlist at {current} contained no playable stream entries"),
                ));
            };

            let resolved = final_url
                .join(&first_entry)
                .map_err(|e| {
                    std::io::Error::new(
                        ErrorKind::InvalidData,
                        format!("Invalid playlist entry '{first_entry}': {e}"),
                    )
                })?
                .to_string();

            if is_playlist_url(&resolved) {
                current = resolved;
                continue;
            }
            return Ok(resolved);
        }

        Err(std::io::Error::new(
            ErrorKind::InvalidData,
            format!("Exceeded max playlist nesting depth ({MAX_PLAYLIST_DEPTH})"),
        ))
    })
}

impl Read for HttpRangeMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
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
    },
    Sequential {
        total_len: Option<u64>,
        content_type: Option<String>,
        response: Option<Response>,
    },
}

fn build_header_map(headers: &HashMap<String, String>) -> std::io::Result<HeaderMap> {
    let mut map = HeaderMap::new();
    for (k, v) in headers {
        let name = HeaderName::from_str(k.trim()).map_err(|e| {
            std::io::Error::new(
                ErrorKind::InvalidInput,
                format!("Invalid HTTP header name '{k}': {e}"),
            )
        })?;
        let val = HeaderValue::from_str(v).map_err(|e| {
            std::io::Error::new(
                ErrorKind::InvalidInput,
                format!("Invalid HTTP header value for '{k}': {e}"),
            )
        })?;
        map.insert(name, val);
    }
    Ok(map)
}

fn header_str(headers: &HeaderMap, key: &HeaderName) -> Option<String> {
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

fn map_http_status_err(status: StatusCode, url: &str) -> std::io::Error {
    let kind = match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => ErrorKind::PermissionDenied,
        StatusCode::NOT_FOUND | StatusCode::GONE => ErrorKind::NotFound,
        _ => ErrorKind::Other,
    };
    std::io::Error::new(kind, format!("HTTP {} fetching {}", status.as_u16(), url))
}

async fn probe_http_stream(url: &str, headers: &HeaderMap) -> std::io::Result<ProbeResult> {
    let client = http_client()?;

    let mut head_content_type = None;
    let mut head_content_length = None;

    if let Ok(head_resp) = client.head(url).headers(headers.clone()).send().await {
        let status = head_resp.status();
        if status.is_success() {
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
                });
            }
        } else if status == StatusCode::UNAUTHORIZED
            || status == StatusCode::FORBIDDEN
            || status == StatusCode::NOT_FOUND
        {
            return Err(map_http_status_err(status, url));
        }
    }

    // Probe GET with Range: bytes=0-0
    let mut probe_headers = headers.clone();
    probe_headers.insert(RANGE, HeaderValue::from_static("bytes=0-0"));

    let resp = client
        .get(url)
        .headers(probe_headers)
        .send()
        .await
        .map_err(|e| std::io::Error::other(format!("HTTP probe GET failed: {e:?}")))?;

    let status = resp.status();
    if !status.is_success() && status != StatusCode::PARTIAL_CONTENT {
        return Err(map_http_status_err(status, url));
    }

    let resp_headers = resp.headers();
    let content_type = header_str(resp_headers, &CONTENT_TYPE).or(head_content_type);

    if status == StatusCode::PARTIAL_CONTENT {
        if let Some(total_len) = parse_content_range_total(resp_headers).or(head_content_length) {
            return Ok(ProbeResult::Range {
                total_len,
                content_type,
            });
        }
        // Server sent 206 with unknown total ('/*'): fall back to sequential GET without range.
        return Ok(ProbeResult::Sequential {
            total_len: None,
            content_type,
            response: None,
        });
    }

    // 200 OK (non-range server): keep the live response stream for sequential reading.
    let total_len = resp.content_length().or(head_content_length);
    Ok(ProbeResult::Sequential {
        total_len,
        content_type,
        response: Some(resp),
    })
}

impl RangeCacheState {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.total_len {
            return Ok(0);
        }

        let chunk_idx = self.pos / (CHUNK_SIZE as u64);
        let chunk_offset = (self.pos % (CHUNK_SIZE as u64)) as usize;
        let chunk = self.get_or_fetch_chunk(chunk_idx)?;

        if chunk_offset >= chunk.len() {
            return Ok(0);
        }

        let available = &chunk[chunk_offset..];
        let to_copy = available.len().min(buf.len());
        buf[..to_copy].copy_from_slice(&available[..to_copy]);
        self.pos += to_copy as u64;
        Ok(to_copy)
    }

    fn seek(&mut self, style: SeekFrom) -> std::io::Result<u64> {
        let target: i128 = match style {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::Current(delta) => (self.pos as i128) + (delta as i128),
            SeekFrom::End(delta) => (self.total_len as i128) + (delta as i128),
        };
        if target < 0 {
            return Err(std::io::Error::new(
                ErrorKind::InvalidInput,
                "Cannot seek before start of HTTP stream",
            ));
        }
        self.pos = (target as u64).min(self.total_len);
        Ok(self.pos)
    }

    fn get_or_fetch_chunk(&mut self, chunk_idx: u64) -> std::io::Result<Arc<[u8]>> {
        if let Some(existing) = self.chunks.get(&chunk_idx) {
            let arc = Arc::clone(existing);
            self.touch_lru(chunk_idx);
            return Ok(arc);
        }

        let start = chunk_idx * (CHUNK_SIZE as u64);
        let end = ((chunk_idx + 1) * (CHUNK_SIZE as u64) - 1).min(self.total_len.saturating_sub(1));
        let url = self.url.clone();
        let headers = self.headers.clone();

        let bytes = run_http_future(async move {
            let client = http_client()?;
            let mut req_headers = headers;
            let range_val = format!("bytes={start}-{end}");
            req_headers.insert(
                RANGE,
                HeaderValue::from_str(&range_val)
                    .map_err(|e| std::io::Error::new(ErrorKind::InvalidInput, e))?,
            );

            let resp = client
                .get(&url)
                .headers(req_headers)
                .send()
                .await
                .map_err(|e| std::io::Error::other(format!("HTTP range GET failed: {e:?}")))?;

            let status = resp.status();
            if status != StatusCode::PARTIAL_CONTENT && !status.is_success() {
                return Err(map_http_status_err(status, &url));
            }

            let data = resp
                .bytes()
                .await
                .map_err(|e| std::io::Error::other(format!("HTTP body read failed: {e:?}")))?;
            Ok(data.to_vec())
        })?;

        let arc: Arc<[u8]> = Arc::from(bytes);
        if self.chunks.len() >= MAX_CACHED_CHUNKS
            && let Some(evicted) = self.lru.pop_front()
        {
            self.chunks.remove(&evicted);
        }
        self.chunks.insert(chunk_idx, Arc::clone(&arc));
        self.lru.push_back(chunk_idx);
        Ok(arc)
    }

    fn touch_lru(&mut self, chunk_idx: u64) {
        if let Some(pos) = self.lru.iter().position(|&id| id == chunk_idx) {
            self.lru.remove(pos);
            self.lru.push_back(chunk_idx);
        }
    }
}

impl SequentialState {
    fn ensure_response(&mut self) -> std::io::Result<()> {
        if self.response.is_some() || self.eof {
            return Ok(());
        }
        let url = self.url.clone();
        let headers = self.headers.clone();
        let resp = run_http_future(async move {
            let client = http_client()?;
            let resp = client
                .get(&url)
                .headers(headers)
                .send()
                .await
                .map_err(|e| std::io::Error::other(format!("HTTP GET failed: {e}")))?;
            let status = resp.status();
            if !status.is_success() {
                return Err(map_http_status_err(status, &url));
            }
            Ok(resp)
        })?;
        self.response = Some(resp);
        Ok(())
    }

    fn pull_next_chunk(&mut self) -> std::io::Result<bool> {
        if self.eof {
            return Ok(false);
        }
        self.ensure_response()?;
        let mut resp = match self.response.take() {
            Some(r) => r,
            None => {
                self.eof = true;
                return Ok(false);
            }
        };

        let (resp_back, maybe_chunk) = run_http_future(async move {
            let chunk = resp
                .chunk()
                .await
                .map_err(|e| std::io::Error::other(format!("HTTP chunk read failed: {e}")))?;
            Ok((resp, chunk))
        })?;

        match maybe_chunk {
            Some(bytes) => {
                self.response = Some(resp_back);
                self.append_chunk(&bytes);
                Ok(true)
            }
            None => {
                self.eof = true;
                Ok(false)
            }
        }
    }

    fn append_chunk(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        let mut slice = bytes;
        if self.history.len() < NON_RANGE_HISTORY_LIMIT {
            let room = NON_RANGE_HISTORY_LIMIT - self.history.len();
            let take = room.min(slice.len());
            self.history.extend_from_slice(&slice[..take]);
            self.stream_pos += take as u64;
            slice = &slice[take..];
        }
        if !slice.is_empty() {
            if self.pending.is_empty() {
                self.pending_start = self.stream_pos;
            }
            self.pending.extend_from_slice(slice);
            self.stream_pos += slice.len() as u64;
        }
    }

    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            // 1. Serve from retained initial history window if pos falls within it
            if self.pos < self.history.len() as u64 {
                let offset = self.pos as usize;
                let available = &self.history[offset..];
                let n = available.len().min(buf.len());
                buf[..n].copy_from_slice(&available[..n]);
                self.pos += n as u64;
                return Ok(n);
            }

            // 2. Serve from pending tail buffer if pos falls inside it
            let pending_end = self.pending_start + self.pending.len() as u64;
            if self.pos >= self.pending_start && self.pos < pending_end {
                let offset = (self.pos - self.pending_start) as usize;
                let available = &self.pending[offset..];
                let n = available.len().min(buf.len());
                buf[..n].copy_from_slice(&available[..n]);
                self.pos += n as u64;

                // Trim already-consumed bytes from pending once past history
                let consumed = (self.pos - self.pending_start) as usize;
                if consumed > 0 {
                    self.pending.drain(..consumed);
                    self.pending_start = self.pos;
                }
                return Ok(n);
            }

            // 3. Otherwise we need more bytes from the HTTP response (including skipping forward if pos > stream_pos)
            if self.eof {
                return Ok(0);
            }
            if !self.pull_next_chunk()? {
                return Ok(0);
            }
            // Discard pending bytes strictly before self.pos (from forward seek)
            if self.pos > self.pending_start && !self.pending.is_empty() {
                let skip = ((self.pos - self.pending_start) as usize).min(self.pending.len());
                self.pending.drain(..skip);
                self.pending_start += skip as u64;
            }
        }
    }

    fn seek(&mut self, style: SeekFrom) -> std::io::Result<u64> {
        let target: i128 = match style {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::Current(delta) => (self.pos as i128) + (delta as i128),
            SeekFrom::End(delta) => {
                if let Some(len) = self.total_len {
                    (len as i128) + (delta as i128)
                } else {
                    return Err(std::io::Error::new(
                        ErrorKind::Unsupported,
                        "SeekFrom::End unsupported on unseekable HTTP stream without Content-Length",
                    ));
                }
            }
        };

        if target < 0 {
            return Err(std::io::Error::new(
                ErrorKind::InvalidInput,
                "Cannot seek before start of HTTP stream",
            ));
        }

        let target_u64 = target as u64;
        if target_u64 <= self.history.len() as u64 || target_u64 >= self.pos {
            self.pos = target_u64;
            Ok(self.pos)
        } else {
            Err(std::io::Error::new(
                ErrorKind::Unsupported,
                "Backward seek past retained buffer on non-range HTTP stream",
            ))
        }
    }
}
