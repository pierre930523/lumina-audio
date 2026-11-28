use chrono::Utc;
use sqlx::SqlitePool;

use super::LibraryRepository;
use super::models::{
    PairedClient, PlayHistoryEntry, PlayHistoryRow, ProfileFavorite, ProfileFavoriteRow,
};
use crate::error::Result;
use crate::repository::pairing::PairingRepository;

impl LibraryRepository {
    // -------------------------------------------------------------------------
    // Profile Favorites
    // -------------------------------------------------------------------------

    pub async fn add_favorite(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: &str,
        item_id: &str,
    ) -> Result<()> {
        let created_at = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT OR IGNORE INTO profile_favorites (profile_id, item_type, item_id, created_at) \
             VALUES (?, ?, ?, ?)",
        )
        .bind(profile_id)
        .bind(item_type)
        .bind(item_id)
        .bind(created_at)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn remove_favorite(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: &str,
        item_id: &str,
    ) -> Result<bool> {
        let res = sqlx::query(
            "DELETE FROM profile_favorites WHERE profile_id = ? AND item_type = ? AND item_id = ?",
        )
        .bind(profile_id)
        .bind(item_type)
        .bind(item_id)
        .execute(pool)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    pub async fn is_favorite(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: &str,
        item_id: &str,
    ) -> Result<bool> {
        let row: Option<(i32,)> = sqlx::query_as(
            "SELECT 1 FROM profile_favorites WHERE profile_id = ? AND item_type = ? AND item_id = ?",
        )
        .bind(profile_id)
        .bind(item_type)
        .bind(item_id)
        .fetch_optional(pool)
        .await?;

        Ok(row.is_some())
    }

    pub async fn list_favorites_for_profile(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: Option<&str>,
    ) -> Result<Vec<ProfileFavorite>> {
        let rows: Vec<ProfileFavoriteRow> = match item_type {
            Some(t) => {
                sqlx::query_as(
                    "SELECT profile_id, item_type, item_id, created_at FROM profile_favorites \
                     WHERE profile_id = ? AND item_type = ? ORDER BY created_at DESC",
                )
                .bind(profile_id)
                .bind(t)
                .fetch_all(pool)
                .await?
            }
            None => {
                sqlx::query_as(
                    "SELECT profile_id, item_type, item_id, created_at FROM profile_favorites \
                     WHERE profile_id = ? ORDER BY created_at DESC",
                )
                .bind(profile_id)
                .fetch_all(pool)
                .await?
            }
        };

        Ok(rows
            .into_iter()
            .map(|r| ProfileFavorite {
                profile_id: r.profile_id,
                item_type: r.item_type,
                item_id: r.item_id,
                created_at: r.created_at,
            })
            .collect())
    }

    // -------------------------------------------------------------------------
    // Play History
    // -------------------------------------------------------------------------

    pub async fn record_play(
        pool: &SqlitePool,
        profile_id: &str,
        track_source_id: &str,
        duration_listened_ms: u64,
    ) -> Result<i64> {
        let played_at = Utc::now().to_rfc3339();
        let res = sqlx::query(
            "INSERT INTO play_history (profile_id, track_source_id, played_at, duration_listened_ms) \
             VALUES (?, ?, ?, ?)",
        )
        .bind(profile_id)
        .bind(track_source_id)
        .bind(played_at)
        .bind(duration_listened_ms as i64)
        .execute(pool)
        .await?;

        Ok(res.last_insert_rowid())
    }

    pub async fn get_recent_history(
        pool: &SqlitePool,
        profile_id: &str,
        limit: u32,
    ) -> Result<Vec<PlayHistoryEntry>> {
        let rows: Vec<PlayHistoryRow> = sqlx::query_as(
            "SELECT id, profile_id, track_source_id, played_at, duration_listened_ms \
             FROM play_history WHERE profile_id = ? \
             ORDER BY played_at DESC, id DESC LIMIT ?",
        )
        .bind(profile_id)
        .bind(limit as i64)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| PlayHistoryEntry {
                id: r.id,
                profile_id: r.profile_id,
                track_source_id: r.track_source_id,
                played_at: r.played_at,
                duration_listened_ms: r.duration_listened_ms as u64,
            })
            .collect())
    }

    // -------------------------------------------------------------------------
    // Paired Clients & App Preferences
    // -------------------------------------------------------------------------

    pub async fn insert_paired_client(pool: &SqlitePool, client: &PairedClient) -> Result<()> {
        PairingRepository::insert_paired_client(pool, client).await
    }

    pub async fn list_paired_clients(pool: &SqlitePool) -> Result<Vec<PairedClient>> {
        PairingRepository::list_paired_clients(pool).await
    }

    pub async fn list_paired_token_hashes(pool: &SqlitePool) -> Result<Vec<String>> {
        PairingRepository::list_paired_token_hashes(pool).await
    }

    pub async fn touch_paired_client_by_hash(pool: &SqlitePool, token_hash: &str) -> Result<()> {
        PairingRepository::touch_paired_client_by_hash(pool, token_hash).await
    }

    pub async fn delete_paired_client(pool: &SqlitePool, id: &str) -> Result<bool> {
        PairingRepository::delete_paired_client(pool, id).await
    }

    pub async fn get_preference(pool: &SqlitePool, key: &str) -> Result<Option<String>> {
        let row: Option<(String,)> =
            sqlx::query_as("SELECT value FROM app_preferences WHERE key = ?")
                .bind(key)
                .fetch_optional(pool)
                .await?;
        Ok(row.map(|(v,)| v))
    }

    pub async fn set_preference(pool: &SqlitePool, key: &str, value: &str) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO app_preferences (key, value, updated_at) VALUES (?, ?, ?) \
             ON CONFLICT(key) DO UPDATE SET \
                value = excluded.value, \
                updated_at = excluded.updated_at",
        )
        .bind(key)
        .bind(value)
        .bind(now)
        .execute(pool)
        .await?;
        Ok(())
    }

    pub async fn delete_preference(pool: &SqlitePool, key: &str) -> Result<bool> {
        let res = sqlx::query("DELETE FROM app_preferences WHERE key = ?")
            .bind(key)
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }
}
