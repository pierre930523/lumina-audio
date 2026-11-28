use std::sync::Arc;
use std::time::Instant;

use bytes::Bytes;
use tokio::sync::watch;

use super::super::{InFlightDownloadGuard, StreamError, await_watch_result, streaming_runtime};
use super::ChunkedStreamProxy;
use super::cache::{ChunkFlightCleanup, InFlightChunkRx, InFlightRange, ProxyState};
use super::recovery::ChunkRefreshContext;
use super::transport_io::{fetch_range_chunk, probe_content_length};

impl ChunkedStreamProxy {
    pub(super) fn refresh_context(&self) -> ChunkRefreshContext {
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

    pub(super) async fn ensure_content_length(&self) -> Result<u64, StreamError> {
        if let Ok(guard) = self.content_length.lock()
            && let Some(len) = *guard
        {
            return Ok(len);
        }

        let _probe_guard = tokio::select! {
            biased;
            _ = self.cancel.cancelled() => return Err(StreamError::Cancelled),
            g = self.probe_lock.lock() => g,
        };
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

        let total_len = await_watch_result(&mut rx, &self.cancel).await?;
        if let Ok(mut guard) = self.content_length.lock() {
            *guard = Some(total_len);
        }
        Ok(total_len)
    }

    pub(super) fn spawn_range_fetch_locked(
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

    pub(super) fn plan_aligned_end(
        &self,
        st: &ProxyState,
        start: u64,
        desired_len: usize,
        total_len: u64,
    ) -> u64 {
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

    pub(super) async fn get_or_fetch_span_covering(
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

            match await_watch_result(&mut rx, &self.cancel).await {
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

    pub(super) fn schedule_read_ahead_from_locked(
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

    pub(super) fn maybe_schedule_read_ahead(
        &self,
        span_start: u64,
        span_len: usize,
        cursor: u64,
        total_len: u64,
    ) {
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
