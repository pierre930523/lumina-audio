use std::collections::{HashMap, VecDeque};
use std::io::{ErrorKind, SeekFrom};
use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderValue, RANGE};
use reqwest::{Method, Response, StatusCode};
use tokio_util::sync::CancellationToken;

use super::dns::{
    http_client, run_http_future_cancellable_token, send_following_redirects, timeout_io_error,
};
use super::http_range::map_http_status_err;

const CHUNK_SIZE: usize = 128 * 1024;
const MAX_CACHED_CHUNKS: usize = 24;
const NON_RANGE_HISTORY_LIMIT: usize = 256 * 1024;

pub(super) struct RangeCacheState {
    pub(super) url: String,
    pub(super) headers: HeaderMap,
    pub(super) total_len: u64,
    pub(super) pos: u64,
    pub(super) chunks: HashMap<u64, Arc<[u8]>>,
    pub(super) lru: VecDeque<u64>,
    pub(super) cancel: Option<CancellationToken>,
}

pub(super) struct SequentialState {
    pub(super) url: String,
    pub(super) headers: HeaderMap,
    pub(super) total_len: Option<u64>,
    pub(super) pos: u64,
    pub(super) stream_pos: u64,
    pub(super) history: Vec<u8>,
    pub(super) pending: Vec<u8>,
    pub(super) pending_start: u64,
    pub(super) eof: bool,
    pub(super) response: Option<Response>,
    pub(super) cancel: Option<CancellationToken>,
}

pub(super) enum HttpSourceMode {
    Range(RangeCacheState),
    Sequential(SequentialState),
}

impl RangeCacheState {
    pub(super) fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
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

    pub(super) fn seek(&mut self, style: SeekFrom) -> std::io::Result<u64> {
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

        let (final_url, bytes) = run_http_future_cancellable_token(
            async move {
                let client = http_client()?;
                let mut req_headers = headers;
                let range_val = format!("bytes={start}-{end}");
                req_headers.insert(
                    RANGE,
                    HeaderValue::from_str(&range_val)
                        .map_err(|e| std::io::Error::new(ErrorKind::InvalidInput, e))?,
                );

                let resp = send_following_redirects(
                    &client,
                    Method::GET,
                    &url,
                    &req_headers,
                    Some(Duration::from_secs(20)),
                )
                .await?;

                let resp_url = resp.url().to_string();
                let status = resp.status();
                if status != StatusCode::PARTIAL_CONTENT && !status.is_success() {
                    return Err(map_http_status_err(status, &resp_url));
                }

                let body_timeout = Duration::from_secs(30);
                let data = tokio::time::timeout(body_timeout, resp.bytes())
                    .await
                    .map_err(|_| timeout_io_error(body_timeout))?
                    .map_err(|e| std::io::Error::other(format!("HTTP body read failed: {e:?}")))?;
                Ok((resp_url, data.to_vec()))
            },
            self.cancel.clone(),
            Duration::from_secs(50),
        )?;
        if final_url != self.url {
            self.url = final_url;
        }

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
        let connect_timeout = Duration::from_secs(15);
        let resp = run_http_future_cancellable_token(
            async move {
                let client = http_client()?;
                let resp = send_following_redirects(
                    &client,
                    Method::GET,
                    &url,
                    &headers,
                    Some(connect_timeout),
                )
                .await?;
                let status = resp.status();
                if !status.is_success() {
                    return Err(map_http_status_err(status, resp.url().as_str()));
                }
                Ok(resp)
            },
            self.cancel.clone(),
            connect_timeout,
        )?;
        self.url = resp.url().to_string();
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

        let chunk_timeout = Duration::from_secs(30);
        let (resp_back, maybe_chunk) = run_http_future_cancellable_token(
            async move {
                let chunk = tokio::time::timeout(chunk_timeout, resp.chunk())
                    .await
                    .map_err(|_| timeout_io_error(chunk_timeout))?
                    .map_err(|e| std::io::Error::other(format!("HTTP chunk read failed: {e}")))?;
                Ok((resp, chunk))
            },
            self.cancel.clone(),
            chunk_timeout,
        )?;

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

    pub(super) fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
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

    pub(super) fn seek(&mut self, style: SeekFrom) -> std::io::Result<u64> {
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
