use std::time::{Duration, Instant};

use tokio::sync::Mutex;

use crate::error::ProviderError;

/// Async token-spacing rate limiter with HTTP 429/503 Retry-After backoff support.
pub struct RateLimiter {
    min_interval: Duration,
    last_request: Mutex<Option<Instant>>,
}

impl RateLimiter {
    pub fn new(min_interval: Duration) -> Self {
        Self {
            min_interval,
            last_request: Mutex::new(None),
        }
    }

    pub fn min_interval(&self) -> Duration {
        self.min_interval
    }

    pub async fn acquire(&self) {
        if self.min_interval.is_zero() {
            return;
        }
        let mut last = self.last_request.lock().await;
        if let Some(prev) = *last {
            let next_allowed = prev + self.min_interval;
            let now = Instant::now();
            if now < next_allowed {
                tokio::time::sleep(next_allowed - now).await;
            }
        }
        *last = Some(Instant::now());
    }
}

pub fn parse_retry_after(headers: &reqwest::header::HeaderMap, default_secs: u64) -> Duration {
    let raw = headers
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .map(str::trim);

    let secs = raw
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(default_secs)
        .min(30);
    Duration::from_secs(secs)
}

pub async fn execute_with_backoff<F, Fut>(
    limiter: &RateLimiter,
    max_retries: u8,
    mut make_request: F,
) -> Result<(u16, String), ProviderError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<reqwest::Response, reqwest::Error>>,
{
    let mut attempt: u8 = 0;
    loop {
        limiter.acquire().await;
        let resp = make_request()
            .await
            .map_err(|e| ProviderError::Network(format!("HTTP request failed: {e}")))?;

        let status = resp.status().as_u16();
        if (status == 429 || status == 503) && attempt < max_retries {
            let wait = parse_retry_after(resp.headers(), 1 << attempt.min(4));
            attempt += 1;
            if !wait.is_zero() {
                tokio::time::sleep(wait).await;
            }
            continue;
        }

        let body = resp
            .text()
            .await
            .map_err(|e| ProviderError::Network(format!("Failed reading HTTP body: {e}")))?;

        if status == 429 {
            return Err(ProviderError::rate_limited(
                format!("Upstream API rate limited (HTTP 429): {body}"),
                None,
            ));
        }

        return Ok((status, body));
    }
}
