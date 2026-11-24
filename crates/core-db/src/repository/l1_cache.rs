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

    pub async fn load_unexpired(
        pool: &SqlitePool,
        now_sec: i64,
    ) -> Result<Vec<L1StreamUrlRecord>> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{open_database, open_test_database};

    fn sample_record(
        provider_id: &str,
        track_id: &str,
        quality_key: &str,
        expire_at: i64,
    ) -> L1StreamUrlRecord {
        L1StreamUrlRecord {
            provider_id: provider_id.to_string(),
            track_id: track_id.to_string(),
            quality_key: quality_key.to_string(),
            stream_type: "direct_range".to_string(),
            url_or_manifest: format!("https://cdn.example.com/{provider_id}/{track_id}"),
            headers_json: r#"{"User-Agent":"Lumina/2.0"}"#.to_string(),
            mime_type: Some("audio/webm; codecs=\"opus\"".to_string()),
            bitrate_bps: Some(160_000),
            content_length: Some(5_200_000),
            init_range_end: Some(740),
            index_range_start: Some(741),
            index_range_end: Some(1105),
            expire_at,
            network_epoch: 1,
            updated_at: 1_700_000_000,
            extra_json: Some(r#"{"hint_extension":"webm"}"#.to_string()),
        }
    }

    #[tokio::test]
    async fn test_l1_cache_sqlite_wal_normal_and_persistence() {
        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("l1_cache_test.db");

        {
            let pool = open_database(&db_path).await.unwrap();

            let journal_mode: String = sqlx::query_scalar("PRAGMA journal_mode;")
                .fetch_one(&pool)
                .await
                .unwrap();
            assert_eq!(journal_mode.to_ascii_lowercase(), "wal");

            // SQLite PRAGMA synchronous: 0=OFF, 1=NORMAL, 2=FULL, 3=EXTRA
            let sync_mode: i64 = sqlx::query_scalar("PRAGMA synchronous;")
                .fetch_one(&pool)
                .await
                .unwrap();
            assert_eq!(sync_mode, 1);

            let rec = sample_record("youtube_music", "dQw4w9WgXcQ", "default", 2_000_000_000);
            L1StreamCacheRepository::upsert(&pool, &rec).await.unwrap();
            pool.close().await;
        }

        // Reopen DB (simulate cold restart) and verify full record round-trip
        let pool2 = open_database(&db_path).await.unwrap();
        let loaded = L1StreamCacheRepository::load_unexpired(&pool2, 1_900_000_000)
            .await
            .unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].provider_id, "youtube_music");
        assert_eq!(loaded[0].track_id, "dQw4w9WgXcQ");
        assert_eq!(loaded[0].init_range_end, Some(740));
        assert_eq!(loaded[0].index_range_start, Some(741));
        assert_eq!(loaded[0].index_range_end, Some(1105));
        assert_eq!(loaded[0].network_epoch, 1);
        assert_eq!(
            loaded[0].extra_json.as_deref(),
            Some(r#"{"hint_extension":"webm"}"#)
        );
    }

    #[tokio::test]
    async fn test_l1_cache_upsert_overwrite_expiry_prune_and_delete() {
        let pool = open_test_database().await.unwrap();

        let rec1 = sample_record("qobuz", "101", "27", 1_800_000_100);
        let rec_expired = sample_record("qobuz", "102", "27", 1_700_000_000);
        let rec_other_q = sample_record("qobuz", "101", "6", 1_800_000_200);
        let rec_tidal = sample_record("tidal", "202", "HI_RES_LOSSLESS", 1_800_000_300);

        L1StreamCacheRepository::upsert(&pool, &rec1).await.unwrap();
        L1StreamCacheRepository::upsert(&pool, &rec_expired)
            .await
            .unwrap();
        L1StreamCacheRepository::upsert(&pool, &rec_other_q)
            .await
            .unwrap();
        L1StreamCacheRepository::upsert(&pool, &rec_tidal)
            .await
            .unwrap();

        // Upsert PK overwrite updates url, bitrate, and expire_at
        let mut updated = rec1.clone();
        updated.url_or_manifest = "https://cdn.example.com/qobuz/101-fresh".to_string();
        updated.bitrate_bps = Some(4_608_000);
        updated.expire_at = 1_800_000_999;
        L1StreamCacheRepository::upsert(&pool, &updated)
            .await
            .unwrap();

        let fetched = L1StreamCacheRepository::get(&pool, "qobuz", "101", "27")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            fetched.url_or_manifest,
            "https://cdn.example.com/qobuz/101-fresh"
        );
        assert_eq!(fetched.bitrate_bps, Some(4_608_000));
        assert_eq!(fetched.expire_at, 1_800_000_999);

        // Unexpired filtering excludes rec_expired
        let unexpired = L1StreamCacheRepository::load_unexpired(&pool, 1_750_000_000)
            .await
            .unwrap();
        assert_eq!(unexpired.len(), 3);
        assert!(unexpired.iter().all(|r| r.track_id != "102"));

        // Prune expired removes exactly 1 row
        let pruned = L1StreamCacheRepository::prune_expired(&pool, 1_750_000_000)
            .await
            .unwrap();
        assert_eq!(pruned, 1);

        // Exact key delete removes only (qobuz, 101, 27), leaving (qobuz, 101, 6)
        let del1 = L1StreamCacheRepository::delete(&pool, "qobuz", "101", Some("27"))
            .await
            .unwrap();
        assert_eq!(del1, 1);
        assert!(
            L1StreamCacheRepository::get(&pool, "qobuz", "101", "27")
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            L1StreamCacheRepository::get(&pool, "qobuz", "101", "6")
                .await
                .unwrap()
                .is_some()
        );

        // Track-wide delete (quality_key = None) removes remaining qualities for (qobuz, 101)
        let del_all = L1StreamCacheRepository::delete(&pool, "qobuz", "101", None)
            .await
            .unwrap();
        assert_eq!(del_all, 1);

        // clear_provider removes remaining tidal rows
        let cleared = L1StreamCacheRepository::clear_provider(&pool, "tidal")
            .await
            .unwrap();
        assert_eq!(cleared, 1);
        assert!(
            L1StreamCacheRepository::load_unexpired(&pool, 0)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn test_l1_cache_prune_stale_network_epoch_and_wal_checkpoint_truncate() {
        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("l1_epoch_wal_test.db");
        let pool = open_database(&db_path).await.unwrap();

        let mut ytm_stale = sample_record("youtube_music", "vid1", "default", 2_000_000_000);
        ytm_stale.network_epoch = 1;
        let mut ytm_fresh = sample_record("youtube_music", "vid2", "default", 2_000_000_000);
        ytm_fresh.network_epoch = 2;
        let mut qobuz_old_epoch = sample_record("qobuz", "q1", "27", 2_000_000_000);
        qobuz_old_epoch.network_epoch = 1;

        L1StreamCacheRepository::upsert(&pool, &ytm_stale)
            .await
            .unwrap();
        L1StreamCacheRepository::upsert(&pool, &ytm_fresh)
            .await
            .unwrap();
        L1StreamCacheRepository::upsert(&pool, &qobuz_old_epoch)
            .await
            .unwrap();

        let pruned = L1StreamCacheRepository::prune_stale_network_epoch(
            &pool,
            &["youtube_music"],
            2,
        )
        .await
        .unwrap();
        assert_eq!(pruned, 1, "only stale youtube_music row should be pruned");

        assert!(
            L1StreamCacheRepository::get(&pool, "youtube_music", "vid1", "default")
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            L1StreamCacheRepository::get(&pool, "youtube_music", "vid2", "default")
                .await
                .unwrap()
                .is_some()
        );
        assert!(
            L1StreamCacheRepository::get(&pool, "qobuz", "q1", "27")
                .await
                .unwrap()
                .is_some(),
            "qobuz row must be preserved across network_epoch prune"
        );

        L1StreamCacheRepository::wal_checkpoint_truncate(&pool)
            .await
            .unwrap();
        pool.close().await;
    }
}
