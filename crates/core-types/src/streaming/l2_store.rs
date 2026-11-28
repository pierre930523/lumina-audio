use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::fmt;

use super::{StreamKey, StreamProviderCapabilities};

pub const L2_MIN_TARGET_BYTES: u64 = 524_288;
pub const L2_MAX_TARGET_BYTES: u64 = 4_194_304;
pub const L2_DEEZER_STRIPE_ALIGNMENT: u64 = 6_144;
pub const L2_TAIL_FINGERPRINT_LEN: usize = 64;
pub const L2_DEFAULT_HIGH_WATERMARK_BYTES: u64 = 1024 * 1024 * 1024;
pub const L2_DEFAULT_LOW_WATERMARK_BYTES: u64 = 800 * 1024 * 1024;

/// Storage layout format for an L2 head-chunk entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum L2CacheKind {
    DirectHead,
    DashInitSegs,
}

impl L2CacheKind {
    /// Returns the canonical snake-case string representation for SQLite storage.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::DirectHead => "direct_head",
            Self::DashInitSegs => "dash_init_segs",
        }
    }

    /// Parses a canonical cache kind string (`"direct_head"` or `"dash_init_segs"`).
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "direct_head" => Some(Self::DirectHead),
            "dash_init_segs" => Some(Self::DashInitSegs),
            _ => None,
        }
    }
}

impl fmt::Display for L2CacheKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Persistent metadata record for an L2 head-chunk entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct L2HeadChunkRecord {
    pub provider_id: String,
    pub track_id: String,
    pub quality_key: String,
    pub cache_kind: String,
    pub file_rel_path: String,
    pub cached_bytes: i64,
    pub total_content_length: Option<i64>,
    pub tail_fingerprint: Vec<u8>,
    pub pin_level: i64,
    pub last_accessed_at: i64,
    pub access_count: i64,
    pub created_at: i64,
}

impl L2HeadChunkRecord {
    /// Returns the composite [`StreamKey`] identifying this cached chunk.
    pub fn stream_key(&self) -> StreamKey {
        StreamKey::new(&self.provider_id, &self.track_id, &self.quality_key)
    }

    /// Validates provider eligibility, non-empty key/path fields, `cache_kind`,
    /// `tail_fingerprint` length, and non-negative byte/access counters.
    pub fn validate(&self) -> Result<L2CacheKind, L2CacheStoreError> {
        if self.provider_id.trim().is_empty()
            || self.track_id.trim().is_empty()
            || self.quality_key.trim().is_empty()
            || self.file_rel_path.trim().is_empty()
        {
            return Err(L2CacheStoreError::ConstraintViolation(
                "L2 cache record requires non-empty provider_id, track_id, quality_key, and file_rel_path"
                    .to_string(),
            ));
        }

        if !StreamProviderCapabilities::for_provider(&self.provider_id).supports_l2_head_cache {
            return Err(L2CacheStoreError::ConstraintViolation(format!(
                "provider '{}' does not support L2 head cache",
                self.provider_id
            )));
        }

        let cache_kind = L2CacheKind::parse(&self.cache_kind).ok_or_else(|| {
            L2CacheStoreError::ConstraintViolation(format!(
                "invalid L2 cache_kind '{}'",
                self.cache_kind
            ))
        })?;

        if self.tail_fingerprint.is_empty() || self.tail_fingerprint.len() > L2_TAIL_FINGERPRINT_LEN
        {
            return Err(L2CacheStoreError::ConstraintViolation(format!(
                "tail_fingerprint length must be in 1..={L2_TAIL_FINGERPRINT_LEN}, got {}",
                self.tail_fingerprint.len()
            )));
        }

        if self.cached_bytes < 0 {
            return Err(L2CacheStoreError::ConstraintViolation(
                "cached_bytes must be non-negative".to_string(),
            ));
        }

        if self.total_content_length.is_some_and(|len| len < 0) {
            return Err(L2CacheStoreError::ConstraintViolation(
                "total_content_length must be non-negative".to_string(),
            ));
        }

        if self.access_count < 0 {
            return Err(L2CacheStoreError::ConstraintViolation(
                "access_count must be non-negative".to_string(),
            ));
        }

        Ok(cache_kind)
    }
}

/// Deferred access-timestamp and hit-count update flushed in a single batch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct L2AccessUpdate {
    pub key: StreamKey,
    pub last_accessed_at: i64,
    pub access_delta: i64,
}

/// Error returned by [`L2HeadCacheStore`] implementations.
#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum L2CacheStoreError {
    #[error("L2 cache constraint violation: {0}")]
    ConstraintViolation(String),
    #[error("L2 cache storage error: {0}")]
    Storage(String),
}

/// Abstract persistence port for L2 head-chunk metadata, decoupling `core-audio` from SQLite.
#[async_trait]
pub trait L2HeadCacheStore: Send + Sync {
    async fn upsert(&self, record: &L2HeadChunkRecord) -> Result<(), L2CacheStoreError>;
    async fn get(&self, key: &StreamKey) -> Result<Option<L2HeadChunkRecord>, L2CacheStoreError>;
    async fn delete(&self, key: &StreamKey) -> Result<bool, L2CacheStoreError>;
    async fn delete_by_rel_path(&self, rel_path: &str) -> Result<u64, L2CacheStoreError>;
    async fn clear_provider(&self, provider_id: &str) -> Result<u64, L2CacheStoreError>;
    async fn total_cached_bytes(&self) -> Result<u64, L2CacheStoreError>;
    async fn list_eviction_candidates(
        &self,
        limit: u32,
    ) -> Result<Vec<L2HeadChunkRecord>, L2CacheStoreError>;
    async fn batch_update_access(
        &self,
        updates: &[L2AccessUpdate],
    ) -> Result<u64, L2CacheStoreError>;
    async fn list_all_records(&self) -> Result<Vec<L2HeadChunkRecord>, L2CacheStoreError>;
}

/// Computes the dynamic ~8-second L2 head-chunk byte budget for a stream.
///
/// The raw budget is derived from `(bitrate_bps / 8) * 8`, clamped to
/// `[L2_MIN_TARGET_BYTES, L2_MAX_TARGET_BYTES]`. For Deezer (or when
/// `force_deezer_alignment` is set), the budget is rounded up to a 6,144-byte
/// Blowfish stripe boundary within `[528_384, 4_190_208]`, then capped at
/// `total_content_length` when known.
pub fn compute_l2_target_bytes(
    provider_id: &str,
    bitrate_bps: Option<u64>,
    total_content_length: Option<u64>,
    force_deezer_alignment: bool,
) -> u64 {
    let mut target = (bitrate_bps.unwrap_or(L2_MIN_TARGET_BYTES) / 8)
        .saturating_mul(8)
        .clamp(L2_MIN_TARGET_BYTES, L2_MAX_TARGET_BYTES);

    if force_deezer_alignment || provider_id.trim().eq_ignore_ascii_case("deezer") {
        let blocks = target
            .div_ceil(L2_DEEZER_STRIPE_ALIGNMENT)
            .clamp(86, L2_MAX_TARGET_BYTES / L2_DEEZER_STRIPE_ALIGNMENT);
        target = blocks * L2_DEEZER_STRIPE_ALIGNMENT;
    }

    if let Some(total) = total_content_length {
        target = target.min(total);
    }

    target
}
