use chrono::Utc;
use core_types::{AlbumMetadataLayer, LayeredMetadata, MetadataPolicy, TrackMetadataLayer};
use sqlx::{SqliteConnection, SqlitePool};
use std::str::FromStr;

use super::LibraryRepository;
use crate::error::{DbError, Result};
use crate::repository::tx::ImmediateTx;
use crate::search::rebuild_search_index_conn;

pub const DEFAULT_METADATA_POLICY_PREF_KEY: &str = "default_metadata_policy";

impl LibraryRepository {
    // -------------------------------------------------------------------------
    // Global default_metadata_policy Preference
    // -------------------------------------------------------------------------

    pub async fn get_default_metadata_policy_tx(
        conn: &mut SqliteConnection,
    ) -> Result<MetadataPolicy> {
        let row: Option<(String,)> =
            sqlx::query_as("SELECT value FROM app_preferences WHERE key = ?")
                .bind(DEFAULT_METADATA_POLICY_PREF_KEY)
                .fetch_optional(&mut *conn)
                .await?;
        let parsed = row
            .and_then(|(v,)| MetadataPolicy::from_str(&v).ok())
            .unwrap_or(MetadataPolicy::File);
        Ok(match parsed {
            MetadataPolicy::Cloud => MetadataPolicy::Cloud,
            MetadataPolicy::File | MetadataPolicy::Inherit => MetadataPolicy::File,
        })
    }

    pub async fn get_default_metadata_policy(pool: &SqlitePool) -> Result<MetadataPolicy> {
        let mut conn = pool.acquire().await?;
        Self::get_default_metadata_policy_tx(&mut conn).await
    }

    /// Updates global `default_metadata_policy` (`'file'` or `'cloud'`), recomputes all
    /// `canonical_albums` and `track_sources` with `meta_policy = 'inherit'`, and syncs
    /// `search_fts` atomically inside the caller's transaction.
    pub async fn set_default_metadata_policy_tx(
        conn: &mut SqliteConnection,
        policy: MetadataPolicy,
    ) -> Result<usize> {
        if !policy.is_concrete() {
            return Err(DbError::ConstraintViolation(
                "default_metadata_policy must be 'file' or 'cloud'".to_string(),
            ));
        }
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO app_preferences (key, value, updated_at) VALUES (?, ?, ?) \
             ON CONFLICT(key) DO UPDATE SET \
                value = excluded.value, \
                updated_at = excluded.updated_at",
        )
        .bind(DEFAULT_METADATA_POLICY_PREF_KEY)
        .bind(policy.as_str())
        .bind(&now)
        .execute(&mut *conn)
        .await?;

        let album_ids: Vec<(String,)> =
            sqlx::query_as("SELECT id FROM canonical_albums WHERE meta_policy = 'inherit'")
                .fetch_all(&mut *conn)
                .await?;
        let mut recomputed = 0usize;
        for (album_id,) in album_ids {
            if Self::recompute_album_effective_tx(conn, &album_id, policy).await? {
                recomputed += 1;
            }
        }

        let track_ids: Vec<(String,)> =
            sqlx::query_as("SELECT id FROM track_sources WHERE meta_policy = 'inherit'")
                .fetch_all(&mut *conn)
                .await?;
        for (track_id,) in track_ids {
            if Self::recompute_track_effective_tx(conn, &track_id, policy).await? {
                recomputed += 1;
            }
        }

        rebuild_search_index_conn(conn).await?;
        Ok(recomputed)
    }

    pub async fn set_default_metadata_policy(
        pool: &SqlitePool,
        policy: MetadataPolicy,
    ) -> Result<usize> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::set_default_metadata_policy_tx(tx.conn(), policy).await;
        match res {
            Ok(n) => {
                tx.commit().await?;
                Ok(n)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Isolated Layer Writers (Scanner -> file_meta, Enrichment -> cloud_meta, User -> user_edits)
    // -------------------------------------------------------------------------

    /// Writes ONLY `canonical_albums.file_meta_json` and recomputes materialized effective columns.
    pub async fn write_album_file_meta_tx(
        conn: &mut SqliteConnection,
        album_id: &str,
        file_meta: &AlbumMetadataLayer,
    ) -> Result<bool> {
        let json = file_meta.to_json_opt();
        let res = sqlx::query("UPDATE canonical_albums SET file_meta_json = ? WHERE id = ?")
            .bind(&json)
            .bind(album_id.trim())
            .execute(&mut *conn)
            .await?;
        if res.rows_affected() == 0 {
            return Ok(false);
        }
        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
        Self::recompute_album_effective_tx(conn, album_id.trim(), default_policy).await
    }

    /// Writes ONLY `track_sources.file_meta_json` and recomputes materialized effective columns.
    pub async fn write_track_file_meta_tx(
        conn: &mut SqliteConnection,
        track_id: &str,
        file_meta: &TrackMetadataLayer,
    ) -> Result<bool> {
        let json = file_meta.to_json_opt();
        let res = sqlx::query("UPDATE track_sources SET file_meta_json = ? WHERE id = ?")
            .bind(&json)
            .bind(track_id.trim())
            .execute(&mut *conn)
            .await?;
        if res.rows_affected() == 0 {
            return Ok(false);
        }
        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
        Self::recompute_track_effective_tx(conn, track_id.trim(), default_policy).await
    }

    /// Merges into ONLY `canonical_albums.cloud_meta_json` and recomputes effective columns.
    pub async fn write_album_cloud_meta_tx(
        conn: &mut SqliteConnection,
        album_id: &str,
        patch: &AlbumMetadataLayer,
    ) -> Result<bool> {
        let existing: Option<(Option<String>,)> =
            sqlx::query_as("SELECT cloud_meta_json FROM canonical_albums WHERE id = ?")
                .bind(album_id.trim())
                .fetch_optional(&mut *conn)
                .await?;
        let Some((current_raw,)) = existing else {
            return Ok(false);
        };
        let mut merged =
            AlbumMetadataLayer::from_json_opt(current_raw.as_deref()).unwrap_or_default();
        merged.merge_from(patch);
        let json = merged.to_json_opt();
        sqlx::query("UPDATE canonical_albums SET cloud_meta_json = ? WHERE id = ?")
            .bind(&json)
            .bind(album_id.trim())
            .execute(&mut *conn)
            .await?;
        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
        Self::recompute_album_effective_tx(conn, album_id.trim(), default_policy).await
    }

    /// Merges into ONLY `track_sources.cloud_meta_json` and recomputes effective columns.
    pub async fn write_track_cloud_meta_tx(
        conn: &mut SqliteConnection,
        track_id: &str,
        patch: &TrackMetadataLayer,
    ) -> Result<bool> {
        let existing: Option<(Option<String>,)> =
            sqlx::query_as("SELECT cloud_meta_json FROM track_sources WHERE id = ?")
                .bind(track_id.trim())
                .fetch_optional(&mut *conn)
                .await?;
        let Some((current_raw,)) = existing else {
            return Ok(false);
        };
        let mut merged =
            TrackMetadataLayer::from_json_opt(current_raw.as_deref()).unwrap_or_default();
        merged.merge_from(patch);
        let json = merged.to_json_opt();
        sqlx::query("UPDATE track_sources SET cloud_meta_json = ? WHERE id = ?")
            .bind(&json)
            .bind(track_id.trim())
            .execute(&mut *conn)
            .await?;
        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
        Self::recompute_track_effective_tx(conn, track_id.trim(), default_policy).await
    }

    /// Writes ONLY `user_edits_json` (merges JSON patch onto existing user edits) for `'album'` or `'track'`
    /// and recomputes materialized effective columns. Passing `"{}"` or empty clears user edits.
    pub async fn set_entity_user_edits_tx(
        conn: &mut SqliteConnection,
        entity_type: &str,
        entity_id: &str,
        edits_json: &str,
    ) -> Result<bool> {
        let et = entity_type.trim();
        let eid = entity_id.trim();
        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;

        match et {
            "album" => {
                let existing: Option<(Option<String>,)> =
                    sqlx::query_as("SELECT user_edits_json FROM canonical_albums WHERE id = ?")
                        .bind(eid)
                        .fetch_optional(&mut *conn)
                        .await?;
                let Some((current_raw,)) = existing else {
                    return Ok(false);
                };
                let patch: AlbumMetadataLayer = parse_layer_json(edits_json)?;
                let mut merged =
                    AlbumMetadataLayer::from_json_opt(current_raw.as_deref()).unwrap_or_default();
                merged.merge_from(&patch);
                let json = merged.to_json_opt();
                sqlx::query("UPDATE canonical_albums SET user_edits_json = ? WHERE id = ?")
                    .bind(&json)
                    .bind(eid)
                    .execute(&mut *conn)
                    .await?;
                Self::recompute_album_effective_tx(conn, eid, default_policy).await
            }
            "track" => {
                let existing: Option<(Option<String>,)> =
                    sqlx::query_as("SELECT user_edits_json FROM track_sources WHERE id = ?")
                        .bind(eid)
                        .fetch_optional(&mut *conn)
                        .await?;
                let Some((current_raw,)) = existing else {
                    return Ok(false);
                };
                let patch: TrackMetadataLayer = parse_layer_json(edits_json)?;
                let mut merged =
                    TrackMetadataLayer::from_json_opt(current_raw.as_deref()).unwrap_or_default();
                merged.merge_from(&patch);
                let json = merged.to_json_opt();
                sqlx::query("UPDATE track_sources SET user_edits_json = ? WHERE id = ?")
                    .bind(&json)
                    .bind(eid)
                    .execute(&mut *conn)
                    .await?;
                Self::recompute_track_effective_tx(conn, eid, default_policy).await
            }
            _ => Err(DbError::ConstraintViolation(format!(
                "unsupported entity_type for user_edits: '{et}'"
            ))),
        }
    }

    pub async fn set_entity_user_edits(
        pool: &SqlitePool,
        entity_type: &str,
        entity_id: &str,
        edits_json: &str,
    ) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res =
            Self::set_entity_user_edits_tx(tx.conn(), entity_type, entity_id, edits_json).await;
        match res {
            Ok(updated) => {
                tx.commit().await?;
                Ok(updated)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Sets `meta_policy` (`'inherit' | 'file' | 'cloud'`) on `'album'` or `'track'`
    /// and immediately recomputes effective columns + `search_fts`.
    pub async fn set_entity_meta_policy_tx(
        conn: &mut SqliteConnection,
        entity_type: &str,
        entity_id: &str,
        policy: MetadataPolicy,
    ) -> Result<bool> {
        let et = entity_type.trim();
        let eid = entity_id.trim();
        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;

        match et {
            "album" => {
                let res = sqlx::query("UPDATE canonical_albums SET meta_policy = ? WHERE id = ?")
                    .bind(policy.as_str())
                    .bind(eid)
                    .execute(&mut *conn)
                    .await?;
                if res.rows_affected() == 0 {
                    return Ok(false);
                }
                Self::recompute_album_effective_tx(conn, eid, default_policy).await
            }
            "track" => {
                let res = sqlx::query("UPDATE track_sources SET meta_policy = ? WHERE id = ?")
                    .bind(policy.as_str())
                    .bind(eid)
                    .execute(&mut *conn)
                    .await?;
                if res.rows_affected() == 0 {
                    return Ok(false);
                }
                Self::recompute_track_effective_tx(conn, eid, default_policy).await
            }
            _ => Err(DbError::ConstraintViolation(format!(
                "unsupported entity_type for meta_policy: '{et}'"
            ))),
        }
    }

    pub async fn set_entity_meta_policy(
        pool: &SqlitePool,
        entity_type: &str,
        entity_id: &str,
        policy: MetadataPolicy,
    ) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::set_entity_meta_policy_tx(tx.conn(), entity_type, entity_id, policy).await;
        match res {
            Ok(updated) => {
                tx.commit().await?;
                Ok(updated)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Clears `user_edits_json` and legacy `metadata_overrides` (`user_edit` rows) for an entity,
    /// then recomputes effective columns + `search_fts`.
    pub async fn revert_entity_to_file_meta_tx(
        conn: &mut SqliteConnection,
        entity_type: &str,
        entity_id: &str,
    ) -> Result<bool> {
        let et = entity_type.trim();
        let eid = entity_id.trim();
        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;

        sqlx::query(
            "DELETE FROM metadata_overrides \
             WHERE entity_type = ? AND entity_id = ? AND source_layer = 'user_edit'",
        )
        .bind(et)
        .bind(eid)
        .execute(&mut *conn)
        .await?;

        match et {
            "album" => {
                let res =
                    sqlx::query("UPDATE canonical_albums SET user_edits_json = NULL WHERE id = ?")
                        .bind(eid)
                        .execute(&mut *conn)
                        .await?;
                if res.rows_affected() == 0 {
                    return Ok(false);
                }
                Self::recompute_album_effective_tx(conn, eid, default_policy).await
            }
            "track" => {
                let res =
                    sqlx::query("UPDATE track_sources SET user_edits_json = NULL WHERE id = ?")
                        .bind(eid)
                        .execute(&mut *conn)
                        .await?;
                if res.rows_affected() == 0 {
                    return Ok(false);
                }
                Self::recompute_track_effective_tx(conn, eid, default_policy).await
            }
            _ => Err(DbError::ConstraintViolation(format!(
                "unsupported entity_type for revert_entity_to_file_meta: '{et}'"
            ))),
        }
    }

    pub async fn revert_entity_to_file_meta(
        pool: &SqlitePool,
        entity_type: &str,
        entity_id: &str,
    ) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::revert_entity_to_file_meta_tx(tx.conn(), entity_type, entity_id).await;
        match res {
            Ok(updated) => {
                tx.commit().await?;
                Ok(updated)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}

fn parse_layer_json<T: serde::de::DeserializeOwned + Default>(raw: &str) -> Result<T> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed == "{}" || trimmed == "null" {
        return Ok(T::default());
    }
    serde_json::from_str(trimmed)
        .map_err(|e| DbError::ConstraintViolation(format!("invalid metadata layer json: {e}")))
}
