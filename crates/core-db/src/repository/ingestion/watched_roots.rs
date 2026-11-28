use chrono::Utc;
use core_types::{WatchMode, WatchedRoot};
use sqlx::SqlitePool;
use uuid::Uuid;

use super::IngestionRepository;
use super::models::WatchedRootRow;
use crate::error::Result;

impl IngestionRepository {
    pub async fn upsert_watched_root(
        pool: &SqlitePool,
        provider_id: &str,
        root_path: &str,
        watch_mode: WatchMode,
        poll_interval_sec: u32,
    ) -> Result<WatchedRoot> {
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let trimmed_path = root_path.trim();

        let row: WatchedRootRow = sqlx::query_as(
            "INSERT INTO watched_roots (id, provider_id, root_path, watch_mode, poll_interval_sec, is_online, updated_at) \
             VALUES (?, ?, ?, ?, ?, 1, ?) \
             ON CONFLICT(root_path) DO UPDATE SET \
                provider_id = excluded.provider_id, \
                watch_mode = excluded.watch_mode, \
                poll_interval_sec = excluded.poll_interval_sec, \
                updated_at = excluded.updated_at \
             RETURNING id, provider_id, root_path, watch_mode, poll_interval_sec, is_online, last_scan_at, updated_at",
        )
        .bind(&id)
        .bind(provider_id.trim())
        .bind(trimmed_path)
        .bind(watch_mode.as_str())
        .bind(poll_interval_sec as i64)
        .bind(&now)
        .fetch_one(pool)
        .await?;

        Ok(row.into())
    }

    pub async fn remove_watched_root(pool: &SqlitePool, id_or_path: &str) -> Result<bool> {
        let key = id_or_path.trim();
        let res = sqlx::query("DELETE FROM watched_roots WHERE id = ? OR root_path = ?")
            .bind(key)
            .bind(key)
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn list_watched_roots(pool: &SqlitePool) -> Result<Vec<WatchedRoot>> {
        let rows: Vec<WatchedRootRow> = sqlx::query_as(
            "SELECT id, provider_id, root_path, watch_mode, poll_interval_sec, is_online, last_scan_at, updated_at \
             FROM watched_roots ORDER BY root_path ASC",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn set_root_online_status(
        pool: &SqlitePool,
        id_or_path: &str,
        is_online: bool,
    ) -> Result<bool> {
        let key = id_or_path.trim();
        let now = Utc::now().to_rfc3339();
        let res = sqlx::query(
            "UPDATE watched_roots SET is_online = ?, updated_at = ? WHERE id = ? OR root_path = ?",
        )
        .bind(if is_online { 1i32 } else { 0i32 })
        .bind(&now)
        .bind(key)
        .bind(key)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn touch_root_scan_time(pool: &SqlitePool, id_or_path: &str) -> Result<bool> {
        let key = id_or_path.trim();
        let now = Utc::now().to_rfc3339();
        let res = sqlx::query(
            "UPDATE watched_roots SET last_scan_at = ?, updated_at = ? WHERE id = ? OR root_path = ?",
        )
        .bind(&now)
        .bind(&now)
        .bind(key)
        .bind(key)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }
}
