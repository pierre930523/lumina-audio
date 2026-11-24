use core_types::{L2CacheKind, StreamKey, StreamProviderCapabilities, L2_TAIL_FINGERPRINT_LEN};
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};

use crate::error::{DbError, Result};

const L2_SELECT_COLUMNS: &str = "provider_id, track_id, quality_key, cache_kind, file_rel_path, \
    cached_bytes, total_content_length, tail_fingerprint, pin_level, last_accessed_at, \
    access_count, created_at";

/// Persistent row in the `l2_head_chunks` SQLite table.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, sqlx::FromRow)]
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
}

/// Deferred access-timestamp and hit-count update flushed in a single SQLite transaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct L2AccessUpdate {
    pub key: StreamKey,
    pub last_accessed_at: i64,
    pub access_delta: i64,
}

/// Repository managing `l2_head_chunks` metadata and eviction queries.
pub struct L2HeadCacheRepository;

impl L2HeadCacheRepository {
    fn row_to_record(row: &sqlx::sqlite::SqliteRow) -> L2HeadChunkRecord {
        L2HeadChunkRecord {
            provider_id: row.get("provider_id"),
            track_id: row.get("track_id"),
            quality_key: row.get("quality_key"),
            cache_kind: row.get("cache_kind"),
            file_rel_path: row.get("file_rel_path"),
            cached_bytes: row.get("cached_bytes"),
            total_content_length: row.get("total_content_length"),
            tail_fingerprint: row.get("tail_fingerprint"),
            pin_level: row.get("pin_level"),
            last_accessed_at: row.get("last_accessed_at"),
            access_count: row.get("access_count"),
            created_at: row.get("created_at"),
        }
    }

    fn validate_record(record: &L2HeadChunkRecord) -> Result<L2CacheKind> {
        if record.provider_id.trim().is_empty()
            || record.track_id.trim().is_empty()
            || record.quality_key.trim().is_empty()
            || record.file_rel_path.trim().is_empty()
        {
            return Err(DbError::ConstraintViolation(
                "L2 cache record requires non-empty provider_id, track_id, quality_key, and file_rel_path"
                    .to_string(),
            ));
        }

        if !StreamProviderCapabilities::for_provider(&record.provider_id).supports_l2_head_cache {
            return Err(DbError::ConstraintViolation(format!(
                "provider '{}' does not support L2 head cache",
                record.provider_id
            )));
        }

        let cache_kind = L2CacheKind::parse(&record.cache_kind).ok_or_else(|| {
            DbError::ConstraintViolation(format!("invalid L2 cache_kind '{}'", record.cache_kind))
        })?;

        if record.tail_fingerprint.is_empty()
            || record.tail_fingerprint.len() > L2_TAIL_FINGERPRINT_LEN
        {
            return Err(DbError::ConstraintViolation(format!(
                "tail_fingerprint length must be in 1..={L2_TAIL_FINGERPRINT_LEN}, got {}",
                record.tail_fingerprint.len()
            )));
        }

        if record.cached_bytes < 0 {
            return Err(DbError::ConstraintViolation(
                "cached_bytes must be non-negative".to_string(),
            ));
        }

        if record.total_content_length.is_some_and(|len| len < 0) {
            return Err(DbError::ConstraintViolation(
                "total_content_length must be non-negative".to_string(),
            ));
        }

        if record.access_count < 0 {
            return Err(DbError::ConstraintViolation(
                "access_count must be non-negative".to_string(),
            ));
        }

        Ok(cache_kind)
    }

    /// Inserts or replaces an L2 head-chunk record after validating provider eligibility,
    /// `cache_kind`, and `tail_fingerprint`.
    pub async fn upsert(pool: &SqlitePool, record: &L2HeadChunkRecord) -> Result<()> {
        let cache_kind = Self::validate_record(record)?;

        sqlx::query(
            r#"
            INSERT INTO l2_head_chunks (
                provider_id,
                track_id,
                quality_key,
                cache_kind,
                file_rel_path,
                cached_bytes,
                total_content_length,
                tail_fingerprint,
                pin_level,
                last_accessed_at,
                access_count,
                created_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(provider_id, track_id, quality_key) DO UPDATE SET
                cache_kind = excluded.cache_kind,
                file_rel_path = excluded.file_rel_path,
                cached_bytes = excluded.cached_bytes,
                total_content_length = excluded.total_content_length,
                tail_fingerprint = excluded.tail_fingerprint,
                pin_level = excluded.pin_level,
                last_accessed_at = excluded.last_accessed_at,
                access_count = excluded.access_count,
                created_at = excluded.created_at
            "#,
        )
        .bind(&record.provider_id)
        .bind(&record.track_id)
        .bind(&record.quality_key)
        .bind(cache_kind.as_str())
        .bind(&record.file_rel_path)
        .bind(record.cached_bytes)
        .bind(record.total_content_length)
        .bind(&record.tail_fingerprint)
        .bind(record.pin_level)
        .bind(record.last_accessed_at)
        .bind(record.access_count)
        .bind(record.created_at)
        .execute(pool)
        .await?;

        Ok(())
    }

    /// Fetches a single L2 head-chunk record by composite [`StreamKey`].
    pub async fn get(pool: &SqlitePool, key: &StreamKey) -> Result<Option<L2HeadChunkRecord>> {
        let query = format!(
            "SELECT {L2_SELECT_COLUMNS} FROM l2_head_chunks \
             WHERE provider_id = ?1 AND track_id = ?2 AND quality_key = ?3"
        );
        let row = sqlx::query(&query)
            .bind(&key.provider_id)
            .bind(&key.track_id)
            .bind(&key.quality_key)
            .fetch_optional(pool)
            .await?;

        Ok(row.as_ref().map(Self::row_to_record))
    }

    /// Deletes a single L2 head-chunk record by composite [`StreamKey`], returning `true` if deleted.
    pub async fn delete(pool: &SqlitePool, key: &StreamKey) -> Result<bool> {
        let affected = sqlx::query(
            "DELETE FROM l2_head_chunks WHERE provider_id = ?1 AND track_id = ?2 AND quality_key = ?3",
        )
        .bind(&key.provider_id)
        .bind(&key.track_id)
        .bind(&key.quality_key)
        .execute(pool)
        .await?
        .rows_affected();

        Ok(affected > 0)
    }

    /// Deletes L2 head-chunk records matching a relative file path, returning affected row count.
    pub async fn delete_by_rel_path(pool: &SqlitePool, rel_path: &str) -> Result<u64> {
        let affected = sqlx::query("DELETE FROM l2_head_chunks WHERE file_rel_path = ?1")
            .bind(rel_path)
            .execute(pool)
            .await?
            .rows_affected();

        Ok(affected)
    }

    /// Deletes all L2 head-chunk records belonging to `provider_id`.
    pub async fn clear_provider(pool: &SqlitePool, provider_id: &str) -> Result<u64> {
        let affected = sqlx::query("DELETE FROM l2_head_chunks WHERE provider_id = ?1")
            .bind(provider_id)
            .execute(pool)
            .await?
            .rows_affected();

        Ok(affected)
    }

    /// Returns the total byte footprint tracked in `l2_head_chunks`.
    pub async fn total_cached_bytes(pool: &SqlitePool) -> Result<u64> {
        let total: i64 =
            sqlx::query_scalar("SELECT COALESCE(SUM(cached_bytes), 0) FROM l2_head_chunks")
                .fetch_one(pool)
                .await?;
        Ok(total.max(0) as u64)
    }

    /// Lists up to `limit` eviction candidates ordered by `(pin_level ASC, last_accessed_at ASC, created_at ASC)`.
    pub async fn list_eviction_candidates(
        pool: &SqlitePool,
        limit: u32,
    ) -> Result<Vec<L2HeadChunkRecord>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let query = format!(
            "SELECT {L2_SELECT_COLUMNS} FROM l2_head_chunks \
             ORDER BY pin_level ASC, last_accessed_at ASC, created_at ASC \
             LIMIT ?1"
        );
        let rows = sqlx::query(&query)
            .bind(i64::from(limit))
            .fetch_all(pool)
            .await?;

        Ok(rows.iter().map(Self::row_to_record).collect())
    }

    /// Flushes a batch of access timestamp and hit-count updates in a single SQLite transaction.
    pub async fn batch_update_access(
        pool: &SqlitePool,
        updates: &[L2AccessUpdate],
    ) -> Result<u64> {
        if updates.is_empty() {
            return Ok(0);
        }

        for update in updates {
            if update.access_delta < 0 {
                return Err(DbError::ConstraintViolation(
                    "L2 access_delta must be non-negative".to_string(),
                ));
            }
        }

        let mut tx = pool.begin().await?;
        let mut total_updated = 0u64;
        for update in updates {
            let affected = sqlx::query(
                r#"
                UPDATE l2_head_chunks
                SET
                    last_accessed_at = MAX(last_accessed_at, ?1),
                    access_count = access_count + ?2
                WHERE provider_id = ?3 AND track_id = ?4 AND quality_key = ?5
                "#,
            )
            .bind(update.last_accessed_at)
            .bind(update.access_delta)
            .bind(&update.key.provider_id)
            .bind(&update.key.track_id)
            .bind(&update.key.quality_key)
            .execute(&mut *tx)
            .await?
            .rows_affected();
            total_updated = total_updated.saturating_add(affected);
        }
        tx.commit().await?;

        Ok(total_updated)
    }

    /// Lists all L2 head-chunk records ordered deterministically by primary key.
    pub async fn list_all_records(pool: &SqlitePool) -> Result<Vec<L2HeadChunkRecord>> {
        let query = format!(
            "SELECT {L2_SELECT_COLUMNS} FROM l2_head_chunks \
             ORDER BY provider_id ASC, track_id ASC, quality_key ASC"
        );
        let rows = sqlx::query(&query).fetch_all(pool).await?;

        Ok(rows.iter().map(Self::row_to_record).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::open_test_database;

    fn sample_record(
        provider_id: &str,
        track_id: &str,
        quality_key: &str,
        cached_bytes: i64,
        pin_level: i64,
        last_accessed_at: i64,
        created_at: i64,
    ) -> L2HeadChunkRecord {
        L2HeadChunkRecord {
            provider_id: provider_id.to_string(),
            track_id: track_id.to_string(),
            quality_key: quality_key.to_string(),
            cache_kind: "direct_head".to_string(),
            file_rel_path: format!("{provider_id}/{track_id}_{quality_key}.l2"),
            cached_bytes,
            total_content_length: Some(30_000_000),
            tail_fingerprint: vec![0xAB; L2_TAIL_FINGERPRINT_LEN],
            pin_level,
            last_accessed_at,
            access_count: 1,
            created_at,
        }
    }

    #[tokio::test]
    async fn test_migration_0005_schema_and_upsert_get_delete() {
        let pool = open_test_database().await.unwrap();

        let table_exists: Option<String> = sqlx::query_scalar(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'l2_head_chunks'",
        )
        .fetch_optional(&pool)
        .await
        .unwrap();
        assert_eq!(table_exists.as_deref(), Some("l2_head_chunks"));

        let index_exists: Option<String> = sqlx::query_scalar(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_l2_head_chunks_eviction'",
        )
        .fetch_optional(&pool)
        .await
        .unwrap();
        assert_eq!(index_exists.as_deref(), Some("idx_l2_head_chunks_eviction"));

        let rec = sample_record("qobuz", "101", "27", 1_411_200, 0, 1_700_000_100, 1_700_000_000);
        L2HeadCacheRepository::upsert(&pool, &rec).await.unwrap();

        let key = rec.stream_key();
        let loaded = L2HeadCacheRepository::get(&pool, &key)
            .await
            .unwrap()
            .expect("record should exist");
        assert_eq!(loaded, rec);
        assert_eq!(L2HeadCacheRepository::total_cached_bytes(&pool).await.unwrap(), 1_411_200);

        // Overwrite via upsert
        let mut updated = rec.clone();
        updated.cache_kind = "dash_init_segs".to_string();
        updated.cached_bytes = 2_097_152;
        updated.tail_fingerprint = vec![0xCD; 32];
        L2HeadCacheRepository::upsert(&pool, &updated).await.unwrap();

        let reloaded = L2HeadCacheRepository::get(&pool, &key)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(reloaded.cache_kind, "dash_init_segs");
        assert_eq!(reloaded.cached_bytes, 2_097_152);
        assert_eq!(reloaded.tail_fingerprint, vec![0xCD; 32]);
        assert_eq!(L2HeadCacheRepository::total_cached_bytes(&pool).await.unwrap(), 2_097_152);

        // Delete by key
        assert!(L2HeadCacheRepository::delete(&pool, &key).await.unwrap());
        assert!(!L2HeadCacheRepository::delete(&pool, &key).await.unwrap());
        assert!(L2HeadCacheRepository::get(&pool, &key).await.unwrap().is_none());
        assert_eq!(L2HeadCacheRepository::total_cached_bytes(&pool).await.unwrap(), 0);
    }

    #[tokio::test]
    async fn test_l2_cache_rejects_apple_music_local_and_invalid_fields() {
        let pool = open_test_database().await.unwrap();

        for disallowed in ["apple_music", "local", "unknown_provider"] {
            let rec = sample_record(disallowed, "t1", "default", 524_288, 0, 100, 100);
            let err = L2HeadCacheRepository::upsert(&pool, &rec).await.unwrap_err();
            assert!(
                matches!(err, DbError::ConstraintViolation(_)),
                "expected ConstraintViolation for {disallowed}, got {err:?}"
            );
        }

        let mut bad_kind = sample_record("qobuz", "t2", "27", 524_288, 0, 100, 100);
        bad_kind.cache_kind = "raw_blob".to_string();
        assert!(matches!(
            L2HeadCacheRepository::upsert(&pool, &bad_kind).await.unwrap_err(),
            DbError::ConstraintViolation(_)
        ));

        let mut empty_fp = sample_record("tidal", "t3", "LOSSLESS", 524_288, 0, 100, 100);
        empty_fp.tail_fingerprint.clear();
        assert!(matches!(
            L2HeadCacheRepository::upsert(&pool, &empty_fp).await.unwrap_err(),
            DbError::ConstraintViolation(_)
        ));

        let mut long_fp = sample_record("deezer", "t4", "FLAC", 528_384, 0, 100, 100);
        long_fp.tail_fingerprint = vec![0x11; L2_TAIL_FINGERPRINT_LEN + 1];
        assert!(matches!(
            L2HeadCacheRepository::upsert(&pool, &long_fp).await.unwrap_err(),
            DbError::ConstraintViolation(_)
        ));

        assert!(
            L2HeadCacheRepository::list_all_records(&pool)
                .await
                .unwrap()
                .is_empty(),
            "rejected records must not persist"
        );
    }

    #[tokio::test]
    async fn test_l2_cache_eviction_order_rel_path_clear_and_batch_update() {
        let pool = open_test_database().await.unwrap();

        let r_pinned_old = sample_record("qobuz", "pinned", "27", 1_000_000, 1, 10, 10);
        let r_unpinned_oldest = sample_record("ytm", "old", "default", 524_288, 0, 50, 20);
        let r_unpinned_tie_earlier = sample_record("tidal", "tie1", "HI_RES", 2_000_000, 0, 100, 15);
        let r_unpinned_tie_later = sample_record("deezer", "tie2", "FLAC", 1_413_120, 0, 100, 25);
        let r_unpinned_recent = sample_record("qobuz", "new", "27", 4_194_304, 0, 300, 30);

        for rec in [
            &r_pinned_old,
            &r_unpinned_oldest,
            &r_unpinned_tie_later,
            &r_unpinned_tie_earlier,
            &r_unpinned_recent,
        ] {
            L2HeadCacheRepository::upsert(&pool, rec).await.unwrap();
        }

        let candidates = L2HeadCacheRepository::list_eviction_candidates(&pool, 10)
            .await
            .unwrap();
        let ordered_ids: Vec<&str> = candidates.iter().map(|r| r.track_id.as_str()).collect();
        assert_eq!(
            ordered_ids,
            vec!["old", "tie1", "tie2", "new", "pinned"],
            "eviction order must sort by pin_level ASC, last_accessed_at ASC, created_at ASC"
        );
        assert_eq!(
            L2HeadCacheRepository::list_eviction_candidates(&pool, 2)
                .await
                .unwrap()
                .len(),
            2
        );
        assert!(
            L2HeadCacheRepository::list_eviction_candidates(&pool, 0)
                .await
                .unwrap()
                .is_empty()
        );

        // Batch update in a single transaction: advance "old" and test monotonic MAX(last_accessed_at, ?)
        let updates = vec![
            L2AccessUpdate {
                key: r_unpinned_oldest.stream_key(),
                last_accessed_at: 500,
                access_delta: 3,
            },
            L2AccessUpdate {
                key: r_unpinned_recent.stream_key(),
                last_accessed_at: 150, // older than existing 300 => MAX keeps 300
                access_delta: 2,
            },
            L2AccessUpdate {
                key: StreamKey::new("qobuz", "nonexistent", "27"),
                last_accessed_at: 999,
                access_delta: 1,
            },
        ];
        let affected = L2HeadCacheRepository::batch_update_access(&pool, &updates)
            .await
            .unwrap();
        assert_eq!(affected, 2);

        let updated_old = L2HeadCacheRepository::get(&pool, &r_unpinned_oldest.stream_key())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated_old.last_accessed_at, 500);
        assert_eq!(updated_old.access_count, 4);

        let updated_recent = L2HeadCacheRepository::get(&pool, &r_unpinned_recent.stream_key())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated_recent.last_accessed_at, 300);
        assert_eq!(updated_recent.access_count, 3);

        // delete_by_rel_path & clear_provider
        assert_eq!(
            L2HeadCacheRepository::delete_by_rel_path(&pool, &r_unpinned_tie_earlier.file_rel_path)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            L2HeadCacheRepository::clear_provider(&pool, "qobuz")
                .await
                .unwrap(),
            2
        );

        let remaining = L2HeadCacheRepository::list_all_records(&pool).await.unwrap();
        let rem_ids: Vec<&str> = remaining.iter().map(|r| r.track_id.as_str()).collect();
        assert_eq!(rem_ids, vec!["tie2", "old"]);
        assert_eq!(
            L2HeadCacheRepository::total_cached_bytes(&pool).await.unwrap(),
            (1_413_120 + 524_288) as u64
        );
    }
}
