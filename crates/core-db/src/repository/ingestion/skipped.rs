use chrono::Utc;
use core_types::{SkipReason, SkippedFile};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};
use std::collections::HashSet;
use uuid::Uuid;

use super::IngestionRepository;
use super::models::SkippedFileRow;
use crate::error::Result;
use crate::repository::library::{normalize_local_path_for_compare, path_in_scope};

impl IngestionRepository {
    #[allow(clippy::too_many_arguments)]
    pub async fn record_skipped_file_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        file_path: &str,
        reason: SkipReason,
        detail: &str,
        file_size: Option<u64>,
        file_mtime: Option<i64>,
    ) -> Result<SkippedFile> {
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let size_i64 = file_size.map(|s| s.min(i64::MAX as u64) as i64);

        let row: SkippedFileRow = sqlx::query_as(
            "INSERT INTO skipped_files (id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0) \
             ON CONFLICT(provider_id, file_path) DO UPDATE SET \
                reason_code = excluded.reason_code, \
                detail = excluded.detail, \
                file_size = excluded.file_size, \
                file_mtime = excluded.file_mtime, \
                last_seen_at = excluded.last_seen_at, \
                dismissed = CASE \
                    WHEN skipped_files.reason_code != excluded.reason_code \
                      OR skipped_files.file_mtime IS NOT excluded.file_mtime THEN 0 \
                    ELSE skipped_files.dismissed \
                END \
             RETURNING id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed",
        )
        .bind(&id)
        .bind(provider_id.trim())
        .bind(file_path.trim())
        .bind(reason.as_str())
        .bind(detail.trim())
        .bind(size_i64)
        .bind(file_mtime)
        .bind(&now)
        .bind(&now)
        .fetch_one(&mut *conn)
        .await?;

        Ok(row.into())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn record_skipped_file(
        pool: &SqlitePool,
        provider_id: &str,
        file_path: &str,
        reason: SkipReason,
        detail: &str,
        file_size: Option<u64>,
        file_mtime: Option<i64>,
    ) -> Result<SkippedFile> {
        let mut conn = pool.acquire().await?;
        Self::record_skipped_file_tx(
            &mut conn,
            provider_id,
            file_path,
            reason,
            detail,
            file_size,
            file_mtime,
        )
        .await
    }

    pub async fn list_active_skipped_paths(pool: &SqlitePool) -> Result<HashSet<String>> {
        let rows: Vec<(String,)> = sqlx::query_as("SELECT file_path FROM skipped_files")
            .fetch_all(pool)
            .await?;
        Ok(rows.into_iter().map(|(fp,)| fp).collect())
    }

    pub async fn list_skipped_files(
        pool: &SqlitePool,
        include_dismissed: bool,
    ) -> Result<Vec<SkippedFile>> {
        let sql = if include_dismissed {
            "SELECT id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed \
             FROM skipped_files ORDER BY last_seen_at DESC, file_path ASC"
        } else {
            "SELECT id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed \
             FROM skipped_files WHERE dismissed = 0 ORDER BY last_seen_at DESC, file_path ASC"
        };
        let rows: Vec<SkippedFileRow> = sqlx::query_as(sql).fetch_all(pool).await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn dismiss_skipped_file(pool: &SqlitePool, id: &str) -> Result<bool> {
        let res = sqlx::query("UPDATE skipped_files SET dismissed = 1 WHERE id = ?")
            .bind(id.trim())
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn clear_skipped_for_path_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        file_path: &str,
    ) -> Result<bool> {
        let prov = provider_id.trim();
        let trimmed = file_path.trim();
        let res = sqlx::query("DELETE FROM skipped_files WHERE provider_id = ? AND file_path = ?")
            .bind(prov)
            .bind(trimmed)
            .execute(&mut *conn)
            .await?;
        if res.rows_affected() > 0 {
            return Ok(true);
        }

        let target_norm = normalize_local_path_for_compare(trimmed);
        if target_norm.is_empty() {
            return Ok(false);
        }
        let rows: Vec<(String, String)> =
            sqlx::query_as("SELECT id, file_path FROM skipped_files WHERE provider_id = ?")
                .bind(prov)
                .fetch_all(&mut *conn)
                .await?;
        let matching_ids: Vec<String> = rows
            .into_iter()
            .filter(|(_, fp)| normalize_local_path_for_compare(fp) == target_norm)
            .map(|(id, _)| id)
            .collect();
        if matching_ids.is_empty() {
            return Ok(false);
        }
        let deleted = Self::delete_skipped_by_ids_tx(conn, &matching_ids).await?;
        Ok(deleted > 0)
    }

    pub async fn delete_skipped_by_ids_tx(
        conn: &mut SqliteConnection,
        ids: &[String],
    ) -> Result<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        let mut deleted = 0usize;
        for chunk in ids.chunks(500) {
            let mut qb: QueryBuilder<'_, Sqlite> =
                QueryBuilder::new("DELETE FROM skipped_files WHERE id IN (");
            let mut sep = qb.separated(", ");
            for id in chunk {
                sep.push_bind(id);
            }
            sep.push_unseparated(")");
            deleted += qb.build().execute(&mut *conn).await?.rows_affected() as usize;
        }
        Ok(deleted)
    }

    pub async fn delete_skipped_by_ids(pool: &SqlitePool, ids: &[String]) -> Result<usize> {
        let mut conn = pool.acquire().await?;
        Self::delete_skipped_by_ids_tx(&mut conn, ids).await
    }

    pub async fn clear_skipped_for_path(
        pool: &SqlitePool,
        provider_id: &str,
        file_path: &str,
    ) -> Result<bool> {
        let mut conn = pool.acquire().await?;
        Self::clear_skipped_for_path_tx(&mut conn, provider_id, file_path).await
    }

    pub async fn clear_skipped_for_root(
        pool: &SqlitePool,
        provider_id: &str,
        root_prefix: &str,
    ) -> Result<usize> {
        let scope_norm = normalize_local_path_for_compare(root_prefix);
        let rows: Vec<(String, String)> =
            sqlx::query_as("SELECT id, file_path FROM skipped_files WHERE provider_id = ?")
                .bind(provider_id.trim())
                .fetch_all(pool)
                .await?;

        let matching_ids: Vec<String> = rows
            .into_iter()
            .filter(|(_, fp)| path_in_scope(&normalize_local_path_for_compare(fp), &scope_norm))
            .map(|(id, _)| id)
            .collect();

        if matching_ids.is_empty() {
            return Ok(0);
        }

        let mut deleted = 0usize;
        for chunk in matching_ids.chunks(500) {
            let mut qb: QueryBuilder<'_, Sqlite> =
                QueryBuilder::new("DELETE FROM skipped_files WHERE id IN (");
            let mut sep = qb.separated(", ");
            for id in chunk {
                sep.push_bind(id);
            }
            sep.push_unseparated(")");
            deleted += qb.build().execute(pool).await?.rows_affected() as usize;
        }

        Ok(deleted)
    }
}
