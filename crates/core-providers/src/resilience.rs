use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

use crate::error::ProviderError;
use crate::http::{HttpRequest, HttpResponse, HttpTransport};

const MAX_RETRY_AFTER_SECS: u64 = 60;

/// Parse an HTTP `Retry-After` header containing integer seconds, clamped to 60s.
pub fn parse_retry_after(header_value: &str) -> Option<Duration> {
    let secs = header_value.trim().parse::<u64>().ok()?;
    Some(Duration::from_secs(secs.min(MAX_RETRY_AFTER_SECS)))
}

#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub max_retries: usize,
    pub base_delay: Duration,
    pub max_delay: Duration,
    pub jitter_ratio: f64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 3,
            base_delay: Duration::from_millis(200),
            max_delay: Duration::from_secs(10),
            jitter_ratio: 0.2,
        }
    }
}

impl RetryPolicy {
    pub fn backoff_delay(&self, attempt: usize, retry_after: Option<Duration>) -> Duration {
        if let Some(ra) = retry_after {
            return ra.min(self.max_delay);
        }

        let shift = (attempt as u32).min(20);
        let mult = 1u32.checked_shl(shift).unwrap_or(u32::MAX);
        let raw = self.base_delay.saturating_mul(mult).min(self.max_delay);
        if raw.is_zero() {
            return Duration::ZERO;
        }

        let ratio = if self.jitter_ratio.is_finite() {
            self.jitter_ratio.clamp(0.0, 1.0)
        } else {
            0.0
        };
        if ratio == 0.0 {
            return raw;
        }

        let factor = (1.0 + lightweight_jitter_unit() * ratio).max(0.0);
        let secs = (raw.as_secs_f64() * factor).clamp(0.0, self.max_delay.as_secs_f64());
        Duration::from_secs_f64(secs)
    }
}

fn lightweight_jitter_unit() -> f64 {
    static STATE: AtomicU64 = AtomicU64::new(0x9e37_79b9_7f4a_7c15);
    let mut z = STATE.fetch_add(0x9e37_79b9_7f4a_7c15, Ordering::Relaxed);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^= z >> 31;
    let unit = (z >> 11) as f64 / ((1u64 << 53) as f64); // [0.0, 1.0)
    unit * 2.0 - 1.0
}

/// Execute an async operation with exponential backoff retry and fast cancellation.
pub async fn execute_with_retry<T, F, Fut>(
    policy: &RetryPolicy,
    cancel: &CancellationToken,
    mut op: F,
) -> Result<T, ProviderError>
where
    F: FnMut(usize) -> Fut,
    Fut: Future<Output = Result<T, ProviderError>>,
{
    let mut attempt = 0usize;
    loop {
        if cancel.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }

        match op(attempt).await {
            Ok(value) => return Ok(value),
            Err(ProviderError::Cancelled) => return Err(ProviderError::Cancelled),
            Err(err) if err.is_retryable() && attempt < policy.max_retries => {
                let delay = policy.backoff_delay(attempt, err.retry_after());
                attempt += 1;
                if !delay.is_zero() {
                    tokio::select! {
                        biased;
                        _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
                        _ = tokio::time::sleep(delay) => {}
                    }
                }
            }
            Err(err) => return Err(err),
        }
    }
}

/// Send an HTTP request via `HttpTransport`, automatically retrying HTTP 429 and 502/503/504.
pub async fn send_http_with_retry(
    transport: &dyn HttpTransport,
    req: &HttpRequest,
    policy: &RetryPolicy,
    cancel: &CancellationToken,
) -> Result<HttpResponse, ProviderError> {
    execute_with_retry(policy, cancel, |_| async {
        let resp = transport.execute_cancellable(req.clone(), cancel).await?;
        match resp.status {
            429 => {
                let retry_after = resp.header("retry-after").and_then(parse_retry_after);
                Err(ProviderError::rate_limited(
                    format!("HTTP 429 for {} {}", req.method, req.url),
                    retry_after,
                ))
            }
            502..=504 => Err(ProviderError::Network(format!(
                "Transient HTTP {} for {} {}",
                resp.status, req.method, req.url
            ))),
            _ => Ok(resp),
        }
    })
    .await
}

/// Single-flight gate ensuring concurrent callers encountering expired auth perform only one refresh.
#[derive(Debug, Default)]
pub struct SingleFlightRefreshGate {
    lock: Mutex<()>,
    epoch: AtomicU64,
}

impl SingleFlightRefreshGate {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn current_epoch(&self) -> u64 {
        self.epoch.load(Ordering::Acquire)
    }

    /// Coordinate a single credential refresh across concurrent callers.
    ///
    /// Returns `Ok(true)` if this caller performed the refresh and bumped the epoch,
    /// or `Ok(false)` if another caller already refreshed after `observed_epoch`.
    pub async fn refresh_once<F, Fut>(
        &self,
        observed_epoch: u64,
        cancel: &CancellationToken,
        refresh_fn: F,
    ) -> Result<bool, ProviderError>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<(), ProviderError>>,
    {
        if cancel.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }

        let _guard = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
            guard = self.lock.lock() => guard,
        };

        if self.epoch.load(Ordering::Acquire) != observed_epoch {
            return Ok(false);
        }

        if cancel.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }

        tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
            res = refresh_fn() => res?,
        }

        self.epoch.fetch_add(1, Ordering::Release);
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::AtomicUsize;

    use super::*;
    use crate::http::MockHttpTransport;

    #[test]
    fn parse_retry_after_handles_valid_clamp_and_invalid() {
        assert_eq!(parse_retry_after("5"), Some(Duration::from_secs(5)));
        assert_eq!(parse_retry_after("  0 "), Some(Duration::from_secs(0)));
        assert_eq!(parse_retry_after("120"), Some(Duration::from_secs(60)));
        assert_eq!(parse_retry_after(""), None);
        assert_eq!(parse_retry_after("-1"), None);
        assert_eq!(parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT"), None);
    }

    #[tokio::test]
    async fn execute_with_retry_retries_transient_and_respects_cancel() {
        let policy = RetryPolicy {
            max_retries: 3,
            base_delay: Duration::from_millis(5),
            max_delay: Duration::from_millis(50),
            jitter_ratio: 0.0,
        };
        let cancel = CancellationToken::new();
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_cl = Arc::clone(&attempts);

        let result = execute_with_retry(&policy, &cancel, move |attempt| {
            let attempts = Arc::clone(&attempts_cl);
            async move {
                attempts.fetch_add(1, Ordering::SeqCst);
                if attempt < 2 {
                    Err(ProviderError::Network("blip".into()))
                } else {
                    Ok("ok")
                }
            }
        })
        .await
        .expect("should succeed on third attempt");

        assert_eq!(result, "ok");
        assert_eq!(attempts.load(Ordering::SeqCst), 3);

        // Cancel during a long backoff sleep should abort immediately.
        let slow_policy = RetryPolicy {
            max_retries: 2,
            base_delay: Duration::from_secs(30),
            max_delay: Duration::from_secs(30),
            jitter_ratio: 0.0,
        };
        let cancel = CancellationToken::new();
        let cancel_trigger = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            cancel_trigger.cancel();
        });

        let start = tokio::time::Instant::now();
        let err = execute_with_retry(&slow_policy, &cancel, |_| async {
            Err::<(), _>(ProviderError::rate_limited(
                "429",
                Some(Duration::from_secs(30)),
            ))
        })
        .await
        .unwrap_err();
        assert!(err.is_cancelled());
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[tokio::test]
    async fn send_http_with_retry_handles_429_503_and_non_retryable() {
        let transport = MockHttpTransport::new();
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_cl = Arc::clone(&calls);

        transport
            .register_fn("/flaky", move |_req| {
                let n = calls_cl.fetch_add(1, Ordering::SeqCst);
                match n {
                    0 => Ok(HttpResponse {
                        status: 429,
                        headers: vec![("Retry-After".into(), "0".into())],
                        body: "slow down".into(),
                    }),
                    1 => Ok(HttpResponse::error_json(503, "unavailable")),
                    _ => Ok(HttpResponse::ok_json(r#"{"ok":true}"#)),
                }
            })
            .await;

        transport
            .register_exact("/not-found", HttpResponse::error_json(404, "missing"))
            .await;

        let policy = RetryPolicy {
            max_retries: 3,
            base_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(50),
            jitter_ratio: 0.0,
        };
        let cancel = CancellationToken::new();

        let ok_resp = send_http_with_retry(
            &transport,
            &HttpRequest::get("https://example.test/flaky"),
            &policy,
            &cancel,
        )
        .await
        .expect("should recover after 429 and 503");
        assert_eq!(ok_resp.status, 200);
        assert_eq!(calls.load(Ordering::SeqCst), 3);

        let nf_resp = send_http_with_retry(
            &transport,
            &HttpRequest::get("https://example.test/not-found"),
            &policy,
            &cancel,
        )
        .await
        .expect("404 should pass through directly");
        assert_eq!(nf_resp.status, 404);
    }

    #[tokio::test]
    async fn single_flight_refresh_runs_once_for_concurrent_callers() {
        let gate = Arc::new(SingleFlightRefreshGate::new());
        let refresh_count = Arc::new(AtomicUsize::new(0));
        let observed = gate.current_epoch();

        let mut handles = Vec::new();
        for _ in 0..8 {
            let gate = Arc::clone(&gate);
            let refresh_count = Arc::clone(&refresh_count);
            let cancel = CancellationToken::new();
            handles.push(tokio::spawn(async move {
                gate.refresh_once(observed, &cancel, || async {
                    refresh_count.fetch_add(1, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(25)).await;
                    Ok(())
                })
                .await
            }));
        }

        let mut performed = 0usize;
        let mut skipped = 0usize;
        for h in handles {
            match h.await.unwrap().unwrap() {
                true => performed += 1,
                false => skipped += 1,
            }
        }

        assert_eq!(performed, 1);
        assert_eq!(skipped, 7);
        assert_eq!(refresh_count.load(Ordering::SeqCst), 1);
        assert_eq!(gate.current_epoch(), observed + 1);
    }
}
