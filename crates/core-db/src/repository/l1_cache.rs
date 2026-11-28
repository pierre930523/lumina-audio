use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};

use crate::error::Result;

fn default_headers_json() -> String {
    "{}".to_string()
}

fn default_network_epoch() -> i64 {
    1
}

/// Persistent row in the `l1_stream_urls` SQLite table.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct L1StreamUrlRecord {
    pub provider_id: String,
    pub track_id: String,
    pub quality_key: String,
    pub stream_type: String,
    pub url_or_manifest: String,
    #[serde(default = "default_headers_json")]
    pub headers_json: String,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub bitrate_bps: Option<i64>,
    #[serde(default)]
    pub content_length: Option<i64>,
    #[serde(default)]
    pub init_range_end: Option<i64>,
    #[serde(default)]
    pub index_range_start: Option<i64>,
    #[serde(default)]
    pub index_range_end: Option<i64>,
    pub expire_at: i64,
    #[serde(default = "default_network_epoch")]
    pub network_epoch: i64,
    pub updated_at: i64,
    #[serde(default)]
    pub extra_json: Option<String>,
}

pub struct L1StreamCacheRepository;

impl L1StreamCacheRepository {
    fn row_to_record(row: &sqlx::sqlite::SqliteRow) -> L1StreamUrlRecord {
        L1StreamUrlRecord {
            provider_id: row.get("provider_id"),
            track_id: row.get("track_id"),
            quality_key: row.get("quality_key"),
            stream_type: row.get("stream_type"),
            url_or_manifest: row.get("url_or_manifest"),
            headers_json: row.get("headers_json"),
            mime_type: row.get("mime_type"),
            bitrate_bps: row.get("bitrate_bps"),
            content_length: row.get("content_length"),
            init_range_end: row.get("init_range_end"),
            index_range_start: row.get("index_range_start"),
            index_range_end: row.get("index_range_end"),
            expire_at: row.get("expire_at"),
            network_epoch: row.get("network_epoch"),
            updated_at: row.get("updated_at"),
            extra_json: row.get("extra_json"),
        }
    }

    pub async fn upsert(pool: &SqlitePool, record: &L1StreamUrlRecord) -> Result<()> {
        let headers_json = if record.headers_json.trim().is_empty() {
            "{}"
        } else {
            record.headers_json.as_str()
        };

        sqlx::query(
            r#"
            INSERT INTO l1_stream_urls (
                provider_id,
                track_id,
                quality_key,
                stream_type,
                url_or_manifest,
                headers_json,
                mime_type,
                bitrate_bps,
                content_length,
                init_range_end,
                index_range_start,
                index_range_end,
                expire_at,
                network_epoch,
                updated_at,
                extra_json
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            ON CONFLICT(provider_id, track_id, quality_key) DO UPDATE SET
                stream_type = excluded.stream_type,
                url_or_manifest = excluded.url_or_manifest,
                headers_json = excluded.headers_json,
                mime_type = excluded.mime_type,
                bitrate_bps = excluded.bitrate_bps,
                content_length = excluded.content_length,
                init_range_end = excluded.init_range_end,
                index_range_start = excluded.index_range_start,
                index_range_end = excluded.index_range_end,
                expire_at = excluded.expire_at,
                network_epoch = excluded.network_epoch,
                updated_at = excluded.updated_at,
                extra_json = excluded.extra_json
            "#,
        )
        .bind(&record.provider_id)
        .bind(&record.track_id)
        .bind(&record.quality_key)
        .bind(&record.stream_type)
        .bind(&record.url_or_manifest)
        .bind(headers_json)
        .bind(&record.mime_type)
        .bind(record.bitrate_bps)
        .bind(record.content_length)
        .bind(record.init_range_end)
        .bind(record.index_range_start)
        .bind(record.index_range_end)
        .bind(record.expire_at)
        .bind(record.network_epoch)
        .bind(record.updated_at)
        .bind(&record.extra_json)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn get(
        pool: &SqlitePool,
        provider_id: &str,
        track_id: &str,
        quality_key: &str,
    ) -> Result<Option<L1StreamUrlRecord>> {
        let row = sqlx::query(
            r#"
            SELECT
                provider_id,
                track_id,
                quality_key,
                stream_type,
                url_or_manifest,
                headers_json,
                mime_type,
                bitrate_bps,
                content_length,
                init_range_end,
                index_range_start,
                index_range_end,
                expire_at,
                network_epoch,
                updated_at,
                extra_json
            FROM l1_stream_urls
            WHERE provider_id = ?1 AND track_id = ?2 AND quality_key = ?3
            "#,
        )
        .bind(provider_id)
        .bind(track_id)
        .bind(quality_key)
        .fetch_optional(pool)
        .await?;

        Ok(row.as_ref().map(Self::row_to_record))
    }

    pub async fn load_unexpired(pool: &SqlitePool, now_sec: i64) -> Result<Vec<L1StreamUrlRecord>> {
        let rows = sqlx::query(
            r#"
            SELECT
                provider_id,
                track_id,
                quality_key,
                stream_type,
                url_or_manifest,
                headers_json,
                mime_type,
                bitrate_bps,
                content_length,
                init_range_end,
                index_range_start,
                index_range_end,
                expire_at,
                network_epoch,
                updated_at,
                extra_json
            FROM l1_stream_urls
            WHERE expire_at > ?1
            ORDER BY updated_at DESC
            "#,
        )
        .bind(now_sec)
        .fetch_all(pool)
        .await?;

        Ok(rows.iter().map(Self::row_to_record).collect())
    }

    pub async fn delete(
        pool: &SqlitePool,
        provider_id: &str,
        track_id: &str,
        quality_key: Option<&str>,
    ) -> Result<u64> {
        let affected = match quality_key.map(str::trim).filter(|q| !q.is_empty()) {
            Some(q) => {
                sqlx::query(
                    "DELETE FROM l1_stream_urls WHERE provider_id = ?1 AND track_id = ?2 AND quality_key = ?3",
                )
                .bind(provider_id)
                .bind(track_id)
                .bind(q)
                .execute(pool)
                .await?
                .rows_affected()
            }
            None => {
                sqlx::query(
                    "DELETE FROM l1_stream_urls WHERE provider_id = ?1 AND track_id = ?2",
                )
                .bind(provider_id)
                .bind(track_id)
                .execute(pool)
                .await?
                .rows_affected()
            }
        };
        Ok(affected)
    }

    pub async fn prune_expired(pool: &SqlitePool, now_sec: i64) -> Result<u64> {
        let affected = sqlx::query("DELETE FROM l1_stream_urls WHERE expire_at <= ?1")
            .bind(now_sec)
            .execute(pool)
            .await?
            .rows_affected();
        Ok(affected)
    }

    pub async fn clear_provider(pool: &SqlitePool, provider_id: &str) -> Result<u64> {
        let affected = sqlx::query("DELETE FROM l1_stream_urls WHERE provider_id = ?1")
            .bind(provider_id)
            .execute(pool)
            .await?
            .rows_affected();
        Ok(affected)
    }

    /// Removes stale L1 rows belonging to `provider_ids` whose `network_epoch < current_epoch`.
    /// Providers not listed (e.g. Qobuz/Tidal/Deezer where `needs_network_epoch_reset == false`)
    /// are left untouched.
    pub async fn prune_stale_network_epoch(
        pool: &SqlitePool,
        provider_ids: &[&str],
        current_epoch: i64,
    ) -> Result<u64> {
        let mut total_deleted = 0u64;
        for &raw_pid in provider_ids {
            let pid = raw_pid.trim();
            if pid.is_empty() {
                continue;
            }
            let affected = sqlx::query(
                "DELETE FROM l1_stream_urls WHERE provider_id = ?1 AND network_epoch < ?2",
            )
            .bind(pid)
            .bind(current_epoch)
            .execute(pool)
            .await?
            .rows_affected();
            total_deleted = total_deleted.saturating_add(affected);
        }
        Ok(total_deleted)
    }

    /// Forces a SQLite WAL truncate checkpoint to flush pending frames into the main DB file
    /// prior to clean application shutdown.
    pub async fn wal_checkpoint_truncate(pool: &SqlitePool) -> Result<()> {
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE);")
            .execute(pool)
            .await?;
        Ok(())
    }
}
