use std::sync::Arc;
use std::time::Instant;

use core_types::StreamSourceSpec;
use reqwest::Method;

use super::super::{
    FormatMismatchReason, HttpRequestSpec, InFlightDownloadGuard, StreamError,
    execute_with_epoch_watch,
};
use super::recovery::attempt_chunk_refresh_after_403;
use super::{ChunkedStreamProxy, OverlapVerifyOutcome};

impl ChunkedStreamProxy {
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
}
