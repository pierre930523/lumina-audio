//! Resolved stream URL cache with expiry awareness, bounded LRU eviction,
//! optional persistent storage, HTTP 403/410 refresh, and single-flight coalescing.

mod cache;
mod lru;
mod store;

pub use cache::StreamUrlCache;
pub use store::{CoreDbStreamCacheStore, StreamCacheStore};

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use core_types::{StreamKey, StreamSourceSpec};
use serde::{Deserialize, Serialize};

use crate::error::ProviderError;
use crate::traits::extract_expire_at_from_url;

/// Injectable epoch-seconds clock used for deterministic TTL tests.
pub type ClockFn = Arc<dyn Fn() -> u64 + Send + Sync>;

/// Returns the current Unix timestamp in seconds.
pub fn system_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Returns whether an upstream HTTP error status warrants invalidating and
/// re-resolving a cached stream URL (`403 Forbidden` or `410 Gone`).
#[inline]
pub fn should_refresh_for_http_status(status_code: u16) -> bool {
    matches!(status_code, 403 | 410)
}

/// Cached resolved stream specification with raw and safety-margined expiry timestamps.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CachedStreamEntry {
    pub key: StreamKey,
    pub spec: StreamSourceSpec,
    /// Upstream expiration timestamp in Unix epoch seconds (before safety margin).
    pub raw_expire_at: u64,
    /// Effective expiration timestamp (`raw_expire_at.saturating_sub(safety_margin_secs)`).
    pub effective_expire_at: u64,
    /// Unix epoch seconds when this entry was cached.
    pub cached_at: u64,
}

impl CachedStreamEntry {
    /// Returns `true` if this entry is still valid at `now_epoch_secs`.
    #[inline]
    pub fn is_valid_at(&self, now_epoch_secs: u64) -> bool {
        self.effective_expire_at > now_epoch_secs
    }

    /// Returns the remaining valid TTL in seconds at `now_epoch_secs`.
    #[inline]
    pub fn remaining_ttl_secs(&self, now_epoch_secs: u64) -> u64 {
        self.effective_expire_at.saturating_sub(now_epoch_secs)
    }
}

/// Configuration for [`StreamUrlCache`].
#[derive(Debug, Clone)]
pub struct StreamCacheConfig {
    pub max_entries: usize,
    pub default_safety_margin: Duration,
    pub default_ttls: HashMap<String, Duration>,
    pub fallback_ttl: Duration,
}

impl Default for StreamCacheConfig {
    fn default() -> Self {
        let mut default_ttls = HashMap::new();
        default_ttls.insert("youtube_music".to_string(), Duration::from_secs(5 * 3600));
        default_ttls.insert("qobuz".to_string(), Duration::from_secs(15 * 60));
        default_ttls.insert("tidal".to_string(), Duration::from_secs(30 * 60));
        default_ttls.insert("deezer".to_string(), Duration::from_secs(15 * 60));
        default_ttls.insert("apple_music".to_string(), Duration::from_secs(10 * 60));

        Self {
            max_entries: 512,
            default_safety_margin: Duration::from_secs(300),
            default_ttls,
            fallback_ttl: Duration::from_secs(10 * 60),
        }
    }
}

impl StreamCacheConfig {
    /// Returns the default TTL for `provider_id` when a stream carries no explicit expiry.
    pub fn default_ttl_for(&self, provider_id: &str) -> Duration {
        let normalized = provider_id.trim().to_ascii_lowercase();
        let canonical = match normalized.as_str() {
            "ytm" => "youtube_music",
            other => other,
        };
        self.default_ttls
            .get(canonical)
            .copied()
            .unwrap_or(self.fallback_ttl)
    }
}

/// Extracts an explicit raw expiration epoch timestamp from a [`StreamSourceSpec`],
/// checking `spec.expire_at` first and falling back to URL query parameters
/// (`expire`, `expires`, `exp`) on the spec's primary URL.
pub fn extract_raw_expire_at(spec: &StreamSourceSpec) -> Option<u64> {
    let (explicit_expire, primary_url) = match spec {
        StreamSourceSpec::DirectRange { url, expire_at, .. } => (*expire_at, Some(url.as_str())),
        StreamSourceSpec::EncryptedRange { url, expire_at, .. } => (*expire_at, Some(url.as_str())),
        StreamSourceSpec::SegmentedManifest {
            manifest_url_or_xml,
            expire_at,
            ..
        } => (*expire_at, Some(manifest_url_or_xml.as_str())),
        StreamSourceSpec::ExternalBackend { preview_url, .. } => (None, preview_url.as_deref()),
        StreamSourceSpec::LocalFile { .. } => (None, None),
    };

    explicit_expire
        .filter(|&ts| ts > 0)
        .or_else(|| primary_url.and_then(extract_expire_at_from_url))
}

pub(super) fn clone_provider_error(err: &ProviderError) -> ProviderError {
    match err {
        ProviderError::Unauthenticated(m) => ProviderError::Unauthenticated(m.clone()),
        ProviderError::AuthenticationFailed(m) => ProviderError::AuthenticationFailed(m.clone()),
        ProviderError::AuthExpired(m) => ProviderError::AuthExpired(m.clone()),
        ProviderError::TrackNotFound(m) => ProviderError::TrackNotFound(m.clone()),
        ProviderError::AlbumNotFound(m) => ProviderError::AlbumNotFound(m.clone()),
        ProviderError::StreamResolutionFailed(m) => {
            ProviderError::StreamResolutionFailed(m.clone())
        }
        ProviderError::UnsupportedFormat(m) => ProviderError::UnsupportedFormat(m.clone()),
        ProviderError::ScanError(m) => ProviderError::ScanError(m.clone()),
        ProviderError::Io(e) => ProviderError::Io(std::io::Error::new(e.kind(), e.to_string())),
        ProviderError::Network(m) => ProviderError::Network(m.clone()),
        ProviderError::RateLimited {
            message,
            retry_after,
        } => ProviderError::RateLimited {
            message: message.clone(),
            retry_after: *retry_after,
        },
        ProviderError::InvalidConfig(m) => ProviderError::InvalidConfig(m.clone()),
        ProviderError::Credential(e) => ProviderError::Other(format!("Credential error: {e}")),
        ProviderError::Validation(e) => ProviderError::Other(format!("Validation error: {e}")),
        ProviderError::DrmRestricted(m) => ProviderError::DrmRestricted(m.clone()),
        ProviderError::RegionRestricted(m) => ProviderError::RegionRestricted(m.clone()),
        ProviderError::RegionBlocked(m) => ProviderError::RegionBlocked(m.clone()),
        ProviderError::TrackUnavailable(m) => ProviderError::TrackUnavailable(m.clone()),
        ProviderError::BinaryMissing { binary, searched } => ProviderError::BinaryMissing {
            binary: binary.clone(),
            searched: searched.clone(),
        },
        ProviderError::ProcessFailed {
            binary,
            exit_code,
            stderr,
        } => ProviderError::ProcessFailed {
            binary: binary.clone(),
            exit_code: *exit_code,
            stderr: stderr.clone(),
        },
        ProviderError::Cancelled => ProviderError::Cancelled,
        ProviderError::Other(m) => ProviderError::Other(m.clone()),
    }
}
