use std::collections::BTreeMap;
use std::time::Duration;

use async_trait::async_trait;
use core_db::{L1StreamCacheRepository, L1StreamUrlRecord, SqlitePool};
use core_types::{StreamKey, StreamSourceSpec};

use super::CachedStreamEntry;

/// Optional persistent backing store for [`super::StreamUrlCache`].
#[async_trait]
pub trait StreamCacheStore: Send + Sync {
    async fn get(&self, key: &StreamKey) -> Option<CachedStreamEntry>;
    async fn put(&self, entry: &CachedStreamEntry);
    async fn delete(&self, key: &StreamKey);
    async fn clear_provider(&self, provider_id: &str);
}

/// SQLite-backed [`StreamCacheStore`] delegating to [`core_db::L1StreamCacheRepository`].
///
/// All database errors are treated as non-fatal and logged via `tracing::warn!`.
#[derive(Clone)]
pub struct CoreDbStreamCacheStore {
    pool: SqlitePool,
    safety_margin_secs: u64,
}

impl CoreDbStreamCacheStore {
    /// Creates a store using the default 300-second safety margin for fallback records.
    pub fn new(pool: SqlitePool) -> Self {
        Self {
            pool,
            safety_margin_secs: 300,
        }
    }

    /// Creates a store with an explicit safety margin for reconstructing legacy rows.
    pub fn with_safety_margin(pool: SqlitePool, safety_margin: Duration) -> Self {
        Self {
            pool,
            safety_margin_secs: safety_margin.as_secs(),
        }
    }

    fn entry_to_record(entry: &CachedStreamEntry) -> L1StreamUrlRecord {
        let (
            stream_type,
            url_or_manifest,
            headers_json,
            mime_type,
            bitrate_bps,
            content_length,
            init_range_end,
            index_range_start,
            index_range_end,
        ) = match &entry.spec {
            StreamSourceSpec::DirectRange {
                url,
                headers,
                content_length,
                bitrate_bps,
                mime_type,
                init_range_end,
                index_range_start,
                index_range_end,
                ..
            } => (
                "direct_range",
                url.clone(),
                serde_json::to_string(headers).unwrap_or_else(|_| "{}".to_string()),
                mime_type.clone(),
                bitrate_bps.and_then(|v| i64::try_from(v).ok()),
                content_length.and_then(|v| i64::try_from(v).ok()),
                init_range_end.and_then(|v| i64::try_from(v).ok()),
                index_range_start.and_then(|v| i64::try_from(v).ok()),
                index_range_end.and_then(|v| i64::try_from(v).ok()),
            ),
            StreamSourceSpec::SegmentedManifest {
                manifest_url_or_xml,
                headers,
                bitrate_bps,
                mime_type,
                ..
            } => (
                "segmented_manifest",
                manifest_url_or_xml.clone(),
                serde_json::to_string(headers).unwrap_or_else(|_| "{}".to_string()),
                mime_type.clone(),
                bitrate_bps.and_then(|v| i64::try_from(v).ok()),
                None,
                None,
                None,
                None,
            ),
            StreamSourceSpec::EncryptedRange {
                url,
                headers,
                content_length,
                bitrate_bps,
                mime_type,
                ..
            } => (
                "encrypted_range",
                url.clone(),
                serde_json::to_string(headers).unwrap_or_else(|_| "{}".to_string()),
                mime_type.clone(),
                bitrate_bps.and_then(|v| i64::try_from(v).ok()),
                content_length.and_then(|v| i64::try_from(v).ok()),
                None,
                None,
                None,
            ),
            StreamSourceSpec::LocalFile { path, .. } => (
                "local_file",
                path.clone(),
                "{}".to_string(),
                None,
                None,
                None,
                None,
                None,
                None,
            ),
            StreamSourceSpec::ExternalBackend { track_uri, .. } => (
                "external_backend",
                track_uri.clone(),
                "{}".to_string(),
                None,
                None,
                None,
                None,
                None,
                None,
            ),
        };

        let extra_json = serde_json::to_string(entry).ok();

        L1StreamUrlRecord {
            provider_id: entry.key.provider_id.clone(),
            track_id: entry.key.track_id.clone(),
            quality_key: entry.key.quality_key.clone(),
            stream_type: stream_type.to_string(),
            url_or_manifest,
            headers_json,
            mime_type,
            bitrate_bps,
            content_length,
            init_range_end,
            index_range_start,
            index_range_end,
            expire_at: i64::try_from(entry.raw_expire_at).unwrap_or(i64::MAX),
            network_epoch: 1,
            updated_at: i64::try_from(entry.cached_at).unwrap_or(0),
            extra_json,
        }
    }

    fn record_to_entry(&self, record: L1StreamUrlRecord) -> Option<CachedStreamEntry> {
        if let Some(extra) = record.extra_json.as_deref()
            && let Ok(entry) = serde_json::from_str::<CachedStreamEntry>(extra)
        {
            return Some(entry);
        }

        // Fallback for legacy direct_range rows written without serialized CachedStreamEntry.
        if record.stream_type != "direct_range" {
            return None;
        }

        let key = StreamKey::new(record.provider_id, record.track_id, record.quality_key);
        let headers: BTreeMap<String, String> =
            serde_json::from_str(&record.headers_json).unwrap_or_default();
        let raw_expire_at = u64::try_from(record.expire_at).ok()?;
        let cached_at = u64::try_from(record.updated_at).unwrap_or(0);

        let spec = StreamSourceSpec::DirectRange {
            key: key.clone(),
            url: record.url_or_manifest,
            headers,
            content_length: record.content_length.and_then(|v| u64::try_from(v).ok()),
            bitrate_bps: record.bitrate_bps.and_then(|v| u64::try_from(v).ok()),
            mime_type: record.mime_type,
            hint_extension: None,
            expire_at: Some(raw_expire_at),
            init_range_end: record.init_range_end.and_then(|v| u64::try_from(v).ok()),
            index_range_start: record.index_range_start.and_then(|v| u64::try_from(v).ok()),
            index_range_end: record.index_range_end.and_then(|v| u64::try_from(v).ok()),
            loudness: None,
            album_loudness: None,
        };

        Some(CachedStreamEntry {
            key,
            spec,
            raw_expire_at,
            effective_expire_at: raw_expire_at.saturating_sub(self.safety_margin_secs),
            cached_at,
        })
    }
}

#[async_trait]
impl StreamCacheStore for CoreDbStreamCacheStore {
    async fn get(&self, key: &StreamKey) -> Option<CachedStreamEntry> {
        match L1StreamCacheRepository::get(
            &self.pool,
            &key.provider_id,
            &key.track_id,
            &key.quality_key,
        )
        .await
        {
            Ok(Some(record)) => self.record_to_entry(record),
            Ok(None) => None,
            Err(err) => {
                tracing::warn!(%key, error = %err, "Failed to read stream cache entry from SQLite");
                None
            }
        }
    }

    async fn put(&self, entry: &CachedStreamEntry) {
        let record = Self::entry_to_record(entry);
        if let Err(err) = L1StreamCacheRepository::upsert(&self.pool, &record).await {
            tracing::warn!(key = %entry.key, error = %err, "Failed to persist stream cache entry to SQLite");
        }
    }

    async fn delete(&self, key: &StreamKey) {
        if let Err(err) = L1StreamCacheRepository::delete(
            &self.pool,
            &key.provider_id,
            &key.track_id,
            Some(&key.quality_key),
        )
        .await
        {
            tracing::warn!(%key, error = %err, "Failed to delete stream cache entry from SQLite");
        }
    }

    async fn clear_provider(&self, provider_id: &str) {
        if let Err(err) = L1StreamCacheRepository::clear_provider(&self.pool, provider_id).await {
            tracing::warn!(provider_id, error = %err, "Failed to clear provider stream cache from SQLite");
        }
    }
}
