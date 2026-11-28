use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use core_types::StreamSourceSpec;
use reqwest::Method;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::super::{
    HttpRequestSpec, StreamError, StreamHttpConfig, StreamHttpTransport, accepts_byte_ranges,
    execute_with_epoch_watch,
};
use super::cache::FetchedRange;
use super::recovery::{
    ChunkRefreshContext, attempt_chunk_refresh_after_403, spec_with_content_length,
};
use super::{ChunkedProxyMetrics, THROUGHPUT_LOG_INTERVAL_MS, UNSET_FIRST_CHUNK_MS};

pub(super) struct ChunkTelemetry {
    pub(super) created_at: Instant,
    pub(super) first_chunk_ms: AtomicU64,
    pub(super) total_downloaded_bytes: AtomicU64,
    pub(super) total_download_us: AtomicU64,
    pub(super) first_chunk_logged: AtomicBool,
    pub(super) last_log_ms: AtomicU64,
}

impl ChunkTelemetry {
    pub(super) fn new() -> Self {
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
    pub(super) fn record_download(
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

        let download_kbps =
            ((total_bytes as u128).saturating_mul(8_000) / (total_us.max(1) as u128)) as u64;
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

    pub(super) fn snapshot(&self) -> ChunkedProxyMetrics {
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

pub(super) async fn probe_content_length(
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
        let resp =
            match execute_with_epoch_watch(transport, get_req, false, config, cancel, epoch_rx)
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
pub(super) async fn fetch_range_chunk(
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

        let resp = execute_with_epoch_watch(transport, req, true, config, cancel, epoch_rx).await?;

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
            let is_initial_probe = start == 0 && !ctx.has_delivered_bytes.load(Ordering::Acquire);
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
        let resp_total = resp.content_range_total.or(if resp.status == 200 {
            resp.content_length
        } else {
            None
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
