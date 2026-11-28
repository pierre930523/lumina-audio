use chrono::Utc;
use core_types::SetEntityPreferenceResponse;
use sqlx::SqlitePool;

use crate::error::{DbError, Result};
use crate::repository::tx::ImmediateTx;

pub struct PreferenceRepository;

impl PreferenceRepository {
    /// Sets the tri-state preference (`-1` banned, `0` neutral, `1` favorite) on a
    /// `track`, `album_group`, or `artist`, and keeps the default profile's legacy
    /// `profile_favorites` table in sync (`album_group` -> `'album'`).
    pub async fn set_entity_preference(
        pool: &SqlitePool,
        entity_type: &str,
        entity_id: &str,
        preference: i32,
    ) -> Result<SetEntityPreferenceResponse> {
        let normalized_type = entity_type.trim().to_ascii_lowercase();
        let eid = entity_id.trim();
        if eid.is_empty() {
            return Err(DbError::ConstraintViolation(
                "entity_id must not be empty".into(),
            ));
        }
        if !matches!(preference, -1..=1) {
            return Err(DbError::ConstraintViolation(format!(
                "preference must be -1, 0, or 1 (got {preference})"
            )));
        }

        let (update_sql, fav_item_type) = match normalized_type.as_str() {
            "track" => (
                "UPDATE track_sources SET preference = ? WHERE id = ?",
                "track",
            ),
            "album_group" => (
                "UPDATE canonical_albums SET preference = ? WHERE id = ?",
                "album",
            ),
            "artist" => ("UPDATE artists SET preference = ? WHERE id = ?", "artist"),
            _ => {
                return Err(DbError::ConstraintViolation(format!(
                    "entity_type must be 'track', 'album_group', or 'artist' (got '{entity_type}')"
                )));
            }
        };

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<SetEntityPreferenceResponse> = async {
            let done = sqlx::query(update_sql)
                .bind(preference)
                .bind(eid)
                .execute(tx.conn())
                .await?;

            if done.rows_affected() == 0 {
                return Err(DbError::NotFound(format!(
                    "{normalized_type} '{eid}' not found"
                )));
            }

            // Sync default profile's legacy `profile_favorites` when a profile exists
            let default_profile: Option<(String,)> = sqlx::query_as(
                "SELECT id FROM profiles ORDER BY is_default DESC, created_at ASC LIMIT 1",
            )
            .fetch_optional(tx.conn())
            .await?;

            if let Some((profile_id,)) = default_profile {
                if preference == 1 {
                    let now = Utc::now().to_rfc3339();
                    sqlx::query(
                        "INSERT OR IGNORE INTO profile_favorites \
                             (profile_id, item_type, item_id, created_at) \
                         VALUES (?, ?, ?, ?)",
                    )
                    .bind(&profile_id)
                    .bind(fav_item_type)
                    .bind(eid)
                    .bind(&now)
                    .execute(tx.conn())
                    .await?;
                } else {
                    sqlx::query(
                        "DELETE FROM profile_favorites \
                         WHERE profile_id = ? AND item_type = ? AND item_id = ?",
                    )
                    .bind(&profile_id)
                    .bind(fav_item_type)
                    .bind(eid)
                    .execute(tx.conn())
                    .await?;
                }
            }

            Ok(SetEntityPreferenceResponse {
                entity_type: normalized_type,
                entity_id: eid.to_string(),
                preference,
            })
        }
        .await;

        match res {
            Ok(resp) => {
                tx.commit().await?;
                Ok(resp)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }
}
