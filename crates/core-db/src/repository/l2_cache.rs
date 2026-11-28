use async_trait::async_trait;
pub use core_types::{L2AccessUpdate, L2CacheStoreError, L2HeadCacheStore, L2HeadChunkRecord};
use core_types::{L2CacheKind, StreamKey};
use sqlx::{Row, SqlitePool};

use crate::error::{DbError, Result};

const L2_SELECT_COLUMNS: &str = "provider_id, track_id, quality_key, cache_kind, file_rel_path, \
    cached_bytes, total_content_length, tail_fingerprint, pin_level, last_accessed_at, \
    access_count, created_at";

fn db_error_to_store_error(err: DbError) -> L2CacheStoreError {
    match err {
        DbError::ConstraintViolation(msg) => L2CacheStoreError::ConstraintViolation(msg),
        other => L2CacheStoreError::Storage(other.to_string()),
    }
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
        record.validate().map_err(|err| match err {
            L2CacheStoreError::ConstraintViolation(msg) | L2CacheStoreError::Storage(msg) => {
                DbError::ConstraintViolation(msg)
            }
        })
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
    pub async fn batch_update_access(pool: &SqlitePool, updates: &[L2AccessUpdate]) -> Result<u64> {
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

        let mut tx = crate::repository::tx::ImmediateTx::begin(pool).await?;
        let res: Result<u64> = async {
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
                .execute(tx.conn())
                .await?
                .rows_affected();
                total_updated = total_updated.saturating_add(affected);
            }
            Ok(total_updated)
        }
        .await;

        match res {
            Ok(total_updated) => {
                tx.commit().await?;
                Ok(total_updated)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
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

/// SQLite-backed implementation of [`L2HeadCacheStore`] delegating to [`L2HeadCacheRepository`].
#[derive(Debug, Clone)]
pub struct SqliteL2HeadCacheStore {
    pool: SqlitePool,
}

impl SqliteL2HeadCacheStore {
    /// Creates a new [`SqliteL2HeadCacheStore`] backed by `pool`.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Returns a reference to the underlying [`SqlitePool`].
    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}

#[async_trait]
impl L2HeadCacheStore for SqliteL2HeadCacheStore {
    async fn upsert(
        &self,
        record: &L2HeadChunkRecord,
    ) -> std::result::Result<(), L2CacheStoreError> {
        L2HeadCacheRepository::upsert(&self.pool, record)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn get(
        &self,
        key: &StreamKey,
    ) -> std::result::Result<Option<L2HeadChunkRecord>, L2CacheStoreError> {
        L2HeadCacheRepository::get(&self.pool, key)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn delete(&self, key: &StreamKey) -> std::result::Result<bool, L2CacheStoreError> {
        L2HeadCacheRepository::delete(&self.pool, key)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn delete_by_rel_path(
        &self,
        rel_path: &str,
    ) -> std::result::Result<u64, L2CacheStoreError> {
        L2HeadCacheRepository::delete_by_rel_path(&self.pool, rel_path)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn clear_provider(
        &self,
        provider_id: &str,
    ) -> std::result::Result<u64, L2CacheStoreError> {
        L2HeadCacheRepository::clear_provider(&self.pool, provider_id)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn total_cached_bytes(&self) -> std::result::Result<u64, L2CacheStoreError> {
        L2HeadCacheRepository::total_cached_bytes(&self.pool)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn list_eviction_candidates(
        &self,
        limit: u32,
    ) -> std::result::Result<Vec<L2HeadChunkRecord>, L2CacheStoreError> {
        L2HeadCacheRepository::list_eviction_candidates(&self.pool, limit)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn batch_update_access(
        &self,
        updates: &[L2AccessUpdate],
    ) -> std::result::Result<u64, L2CacheStoreError> {
        L2HeadCacheRepository::batch_update_access(&self.pool, updates)
            .await
            .map_err(db_error_to_store_error)
    }

    async fn list_all_records(
        &self,
    ) -> std::result::Result<Vec<L2HeadChunkRecord>, L2CacheStoreError> {
        L2HeadCacheRepository::list_all_records(&self.pool)
            .await
            .map_err(db_error_to_store_error)
    }
}
