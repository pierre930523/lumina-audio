use chrono::Utc;
use sqlx::SqlitePool;

use super::LibraryRepository;
use super::models::{ArtworkCacheEntry, ArtworkOverride};
use crate::error::{DbError, Result};
use crate::repository::tx::ImmediateTx;

impl LibraryRepository {
    pub async fn get_artwork_cache(
        pool: &SqlitePool,
        cache_key: &str,
    ) -> Result<Option<ArtworkCacheEntry>> {
        let row: Option<ArtworkCacheEntry> = sqlx::query_as(
            "SELECT cache_key, track_id, album_id, source_kind, mime_type, width, height, \
             max_dim, cache_path, source_mtime, updated_at \
             FROM artwork_cache WHERE cache_key = ?",
        )
        .bind(cache_key)
        .fetch_optional(pool)
        .await?;

        Ok(row)
    }

    pub async fn upsert_artwork_cache(pool: &SqlitePool, entry: &ArtworkCacheEntry) -> Result<()> {
        let updated_at = if entry.updated_at.trim().is_empty() {
            Utc::now().to_rfc3339()
        } else {
            entry.updated_at.clone()
        };

        sqlx::query(
            "INSERT INTO artwork_cache (cache_key, track_id, album_id, source_kind, mime_type, \
             width, height, max_dim, cache_path, source_mtime, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(cache_key) DO UPDATE SET \
                track_id = excluded.track_id, \
                album_id = excluded.album_id, \
                source_kind = excluded.source_kind, \
                mime_type = excluded.mime_type, \
                width = excluded.width, \
                height = excluded.height, \
                max_dim = excluded.max_dim, \
                cache_path = excluded.cache_path, \
                source_mtime = excluded.source_mtime, \
                updated_at = excluded.updated_at",
        )
        .bind(&entry.cache_key)
        .bind(&entry.track_id)
        .bind(&entry.album_id)
        .bind(&entry.source_kind)
        .bind(&entry.mime_type)
        .bind(entry.width)
        .bind(entry.height)
        .bind(entry.max_dim)
        .bind(&entry.cache_path)
        .bind(entry.source_mtime)
        .bind(updated_at)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn delete_artwork_cache(pool: &SqlitePool, cache_key: &str) -> Result<bool> {
        let res = sqlx::query("DELETE FROM artwork_cache WHERE cache_key = ?")
            .bind(cache_key)
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn invalidate_artwork_cache_for_track(
        pool: &SqlitePool,
        track_id: &str,
    ) -> Result<Vec<String>> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Vec<String>> = async {
            let rows: Vec<(String,)> =
                sqlx::query_as("SELECT cache_path FROM artwork_cache WHERE track_id = ?")
                    .bind(track_id)
                    .fetch_all(tx.conn())
                    .await?;

            sqlx::query("DELETE FROM artwork_cache WHERE track_id = ?")
                .bind(track_id)
                .execute(tx.conn())
                .await?;

            Ok(rows.into_iter().map(|(p,)| p).collect())
        }
        .await;

        match res {
            Ok(paths) => {
                tx.commit().await?;
                Ok(paths)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn invalidate_artwork_cache_for_album(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Vec<String>> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Vec<String>> = async {
            let rows: Vec<(String,)> =
                sqlx::query_as("SELECT cache_path FROM artwork_cache WHERE album_id = ?")
                    .bind(album_id)
                    .fetch_all(tx.conn())
                    .await?;

            sqlx::query("DELETE FROM artwork_cache WHERE album_id = ?")
                .bind(album_id)
                .execute(tx.conn())
                .await?;

            Ok(rows.into_iter().map(|(p,)| p).collect())
        }
        .await;

        match res {
            Ok(paths) => {
                tx.commit().await?;
                Ok(paths)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn clear_artwork_cache(pool: &SqlitePool) -> Result<Vec<String>> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Vec<String>> = async {
            let rows: Vec<(String,)> = sqlx::query_as("SELECT cache_path FROM artwork_cache")
                .fetch_all(tx.conn())
                .await?;

            sqlx::query("DELETE FROM artwork_cache")
                .execute(tx.conn())
                .await?;

            Ok(rows.into_iter().map(|(p,)| p).collect())
        }
        .await;

        match res {
            Ok(paths) => {
                tx.commit().await?;
                Ok(paths)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn set_artwork_override(
        pool: &SqlitePool,
        target_kind: &str,
        target_id: &str,
        image_path: &str,
    ) -> Result<()> {
        if target_kind != "track" && target_kind != "album" {
            return Err(DbError::ConstraintViolation(format!(
                "invalid artwork override target_kind: '{target_kind}'"
            )));
        }
        let clean_target_id = target_id.trim();
        if clean_target_id.is_empty() {
            return Err(DbError::ConstraintViolation(
                "artwork override target_id cannot be empty".to_string(),
            ));
        }
        let clean_image_path = image_path.trim();
        if clean_image_path.is_empty() {
            return Err(DbError::ConstraintViolation(
                "artwork override image_path cannot be empty".to_string(),
            ));
        }

        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO artwork_overrides (target_kind, target_id, image_path, updated_at) \
             VALUES (?, ?, ?, ?) \
             ON CONFLICT(target_kind, target_id) DO UPDATE SET \
                image_path = excluded.image_path, \
                updated_at = excluded.updated_at",
        )
        .bind(target_kind)
        .bind(clean_target_id)
        .bind(clean_image_path)
        .bind(now)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn get_artwork_override(
        pool: &SqlitePool,
        target_kind: &str,
        target_id: &str,
    ) -> Result<Option<ArtworkOverride>> {
        let row: Option<ArtworkOverride> = sqlx::query_as(
            "SELECT target_kind, target_id, image_path, updated_at \
             FROM artwork_overrides WHERE target_kind = ? AND target_id = ?",
        )
        .bind(target_kind)
        .bind(target_id)
        .fetch_optional(pool)
        .await?;

        Ok(row)
    }

    pub async fn clear_artwork_override(
        pool: &SqlitePool,
        target_kind: &str,
        target_id: &str,
    ) -> Result<bool> {
        let res =
            sqlx::query("DELETE FROM artwork_overrides WHERE target_kind = ? AND target_id = ?")
                .bind(target_kind)
                .bind(target_id)
                .execute(pool)
                .await?;
        Ok(res.rows_affected() > 0)
    }
}
