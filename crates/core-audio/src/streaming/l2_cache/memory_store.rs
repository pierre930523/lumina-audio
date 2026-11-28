use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use core_types::{
    L2AccessUpdate, L2CacheStoreError, L2HeadCacheStore, L2HeadChunkRecord, StreamKey,
};

/// In-memory implementation of [`L2HeadCacheStore`] matching SQLite validation and eviction ordering.
#[derive(Debug, Default)]
pub struct InMemoryL2HeadCacheStore {
    records: Mutex<HashMap<StreamKey, L2HeadChunkRecord>>,
}

impl InMemoryL2HeadCacheStore {
    /// Creates an empty [`InMemoryL2HeadCacheStore`].
    pub fn new() -> Self {
        Self {
            records: Mutex::new(HashMap::new()),
        }
    }

    fn lock_records(
        &self,
    ) -> Result<std::sync::MutexGuard<'_, HashMap<StreamKey, L2HeadChunkRecord>>, L2CacheStoreError>
    {
        self.records
            .lock()
            .map_err(|_| L2CacheStoreError::Storage("in-memory L2 store lock poisoned".to_string()))
    }
}

#[async_trait]
impl L2HeadCacheStore for InMemoryL2HeadCacheStore {
    async fn upsert(&self, record: &L2HeadChunkRecord) -> Result<(), L2CacheStoreError> {
        let cache_kind = record.validate()?;
        let mut normalized = record.clone();
        normalized.cache_kind = cache_kind.as_str().to_string();
        let key = normalized.stream_key();
        self.lock_records()?.insert(key, normalized);
        Ok(())
    }

    async fn get(&self, key: &StreamKey) -> Result<Option<L2HeadChunkRecord>, L2CacheStoreError> {
        Ok(self.lock_records()?.get(key).cloned())
    }

    async fn delete(&self, key: &StreamKey) -> Result<bool, L2CacheStoreError> {
        Ok(self.lock_records()?.remove(key).is_some())
    }

    async fn delete_by_rel_path(&self, rel_path: &str) -> Result<u64, L2CacheStoreError> {
        let mut map = self.lock_records()?;
        let before = map.len();
        map.retain(|_, rec| rec.file_rel_path != rel_path);
        Ok((before - map.len()) as u64)
    }

    async fn clear_provider(&self, provider_id: &str) -> Result<u64, L2CacheStoreError> {
        let mut map = self.lock_records()?;
        let before = map.len();
        map.retain(|_, rec| rec.provider_id != provider_id);
        Ok((before - map.len()) as u64)
    }

    async fn total_cached_bytes(&self) -> Result<u64, L2CacheStoreError> {
        let total: i64 = self
            .lock_records()?
            .values()
            .map(|rec| rec.cached_bytes)
            .sum();
        Ok(total.max(0) as u64)
    }

    async fn list_eviction_candidates(
        &self,
        limit: u32,
    ) -> Result<Vec<L2HeadChunkRecord>, L2CacheStoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let mut items: Vec<L2HeadChunkRecord> = self.lock_records()?.values().cloned().collect();
        items.sort_by(|a, b| {
            (
                a.pin_level,
                a.last_accessed_at,
                a.created_at,
                &a.provider_id,
                &a.track_id,
                &a.quality_key,
            )
                .cmp(&(
                    b.pin_level,
                    b.last_accessed_at,
                    b.created_at,
                    &b.provider_id,
                    &b.track_id,
                    &b.quality_key,
                ))
        });
        items.truncate(limit as usize);
        Ok(items)
    }

    async fn batch_update_access(
        &self,
        updates: &[L2AccessUpdate],
    ) -> Result<u64, L2CacheStoreError> {
        if updates.is_empty() {
            return Ok(0);
        }
        for update in updates {
            if update.access_delta < 0 {
                return Err(L2CacheStoreError::ConstraintViolation(
                    "L2 access_delta must be non-negative".to_string(),
                ));
            }
        }
        let mut map = self.lock_records()?;
        let mut updated = 0u64;
        for update in updates {
            if let Some(rec) = map.get_mut(&update.key) {
                rec.last_accessed_at = rec.last_accessed_at.max(update.last_accessed_at);
                rec.access_count = rec.access_count.saturating_add(update.access_delta);
                updated = updated.saturating_add(1);
            }
        }
        Ok(updated)
    }

    async fn list_all_records(&self) -> Result<Vec<L2HeadChunkRecord>, L2CacheStoreError> {
        let mut items: Vec<L2HeadChunkRecord> = self.lock_records()?.values().cloned().collect();
        items.sort_by(|a, b| {
            (&a.provider_id, &a.track_id, &a.quality_key).cmp(&(
                &b.provider_id,
                &b.track_id,
                &b.quality_key,
            ))
        });
        Ok(items)
    }
}
