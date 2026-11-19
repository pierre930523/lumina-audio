use super::tx::ImmediateTx;
use crate::error::{DbError, ProfileError, Result};
use chrono::Utc;
use core_types::Profile;
use sqlx::SqlitePool;
use uuid::Uuid;

pub struct ProfileRepository;

impl ProfileRepository {
    /// Creates a new profile.
    /// If it is the first profile in the database, it automatically becomes the default.
    /// If `profile.is_default` is true, previous default profiles are unset atomically in a transaction.
    pub async fn create_profile(pool: &SqlitePool, profile: &Profile) -> Result<Profile> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Profile> = async {
            let id = if profile.id.trim().is_empty() {
                Uuid::new_v4().to_string()
            } else {
                profile.id.clone()
            };

            let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM profiles")
                .fetch_one(tx.conn())
                .await?;

            let is_default = if count.0 == 0 {
                true
            } else {
                profile.is_default
            };

            if is_default {
                sqlx::query("UPDATE profiles SET is_default = 0 WHERE is_default = 1")
                    .execute(tx.conn())
                    .await?;
            }

            let created_at = Utc::now().to_rfc3339();

            sqlx::query(
                "INSERT INTO profiles (id, name, avatar_color, is_default, created_at) VALUES (?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(&profile.name)
            .bind(&profile.avatar_color)
            .bind(if is_default { 1 } else { 0 })
            .bind(&created_at)
            .execute(tx.conn())
            .await?;

            Ok(Profile {
                id,
                name: profile.name.clone(),
                avatar_color: profile.avatar_color.clone(),
                is_default,
            })
        }
        .await;

        match res {
            Ok(created) => {
                tx.commit().await?;
                Ok(created)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Fetches a profile by ID. Returns Ok(None) if not found.
    pub async fn get_profile(pool: &SqlitePool, id: &str) -> Result<Option<Profile>> {
        let row: Option<(String, String, String, i32)> =
            sqlx::query_as("SELECT id, name, avatar_color, is_default FROM profiles WHERE id = ?")
                .bind(id)
                .fetch_optional(pool)
                .await?;

        Ok(row.map(|(id, name, avatar_color, is_default)| Profile {
            id,
            name,
            avatar_color,
            is_default: is_default == 1,
        }))
    }

    /// Retrieves the current default profile.
    pub async fn get_default_profile(pool: &SqlitePool) -> Result<Profile> {
        let row: Option<(String, String, String, i32)> = sqlx::query_as(
            "SELECT id, name, avatar_color, is_default FROM profiles WHERE is_default = 1 LIMIT 1",
        )
        .fetch_optional(pool)
        .await?;

        match row {
            Some((id, name, avatar_color, is_default)) => Ok(Profile {
                id,
                name,
                avatar_color,
                is_default: is_default == 1,
            }),
            None => Err(DbError::NotFound("Default profile not found".to_string())),
        }
    }

    /// Lists all profiles, ordered with default first, then alphabetically by name.
    pub async fn list_profiles(pool: &SqlitePool) -> Result<Vec<Profile>> {
        let rows: Vec<(String, String, String, i32)> = sqlx::query_as(
            "SELECT id, name, avatar_color, is_default FROM profiles ORDER BY is_default DESC, name ASC",
        )
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|(id, name, avatar_color, is_default)| Profile {
                id,
                name,
                avatar_color,
                is_default: is_default == 1,
            })
            .collect())
    }

    /// Updates profile name, avatar_color, and is_default status.
    /// CRITICAL: Reject unsetting is_default if this profile is currently default.
    pub async fn update_profile(pool: &SqlitePool, profile: &Profile) -> Result<Profile> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Profile> = async {
            let current: Option<(i32,)> =
                sqlx::query_as("SELECT is_default FROM profiles WHERE id = ?")
                    .bind(&profile.id)
                    .fetch_optional(tx.conn())
                    .await?;

            let current_is_default = match current {
                Some((is_def,)) => is_def == 1,
                None => return Err(DbError::Profile(ProfileError::NotFound(profile.id.clone()))),
            };

            // CRITICAL INVARIANT: Cannot unset is_default on the current default profile
            if current_is_default && !profile.is_default {
                return Err(DbError::Profile(ProfileError::CannotUnsetDefaultProfile));
            }

            if profile.is_default && !current_is_default {
                // Unset previous default
                sqlx::query("UPDATE profiles SET is_default = 0 WHERE is_default = 1")
                    .execute(tx.conn())
                    .await?;
            }

            sqlx::query(
                "UPDATE profiles SET name = ?, avatar_color = ?, is_default = ? WHERE id = ?",
            )
            .bind(&profile.name)
            .bind(&profile.avatar_color)
            .bind(if profile.is_default { 1 } else { 0 })
            .bind(&profile.id)
            .execute(tx.conn())
            .await?;

            Ok(profile.clone())
        }
        .await;

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

    /// Deletes a profile by ID.
    /// CRITICAL: Fails if profile is default or is the last profile in the system.
    pub async fn delete_profile(pool: &SqlitePool, id: &str) -> Result<()> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<()> = async {
            let row: Option<(i32,)> = sqlx::query_as("SELECT is_default FROM profiles WHERE id = ?")
                .bind(id)
                .fetch_optional(tx.conn())
                .await?;

            let is_default = match row {
                Some((is_def,)) => is_def == 1,
                None => return Err(DbError::Profile(ProfileError::NotFound(id.to_string()))),
            };

            let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM profiles")
                .fetch_one(tx.conn())
                .await?;

            // CRITICAL INVARIANT: Cannot delete last remaining profile
            if count.0 <= 1 {
                return Err(DbError::Profile(ProfileError::CannotDeleteLastProfile));
            }

            // CRITICAL INVARIANT: Cannot delete default profile
            if is_default {
                return Err(DbError::Profile(ProfileError::CannotDeleteDefault(
                    id.to_string(),
                )));
            }

            sqlx::query("DELETE FROM profiles WHERE id = ?")
                .bind(id)
                .execute(tx.conn())
                .await?;

            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(())
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
