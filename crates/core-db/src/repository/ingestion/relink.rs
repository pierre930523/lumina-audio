use chrono::Utc;
use core_types::FileStatus;
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};
use std::collections::HashSet;
use std::path::PathBuf;
use std::str::FromStr;

use super::IngestionRepository;
use super::models::{RelinkCandidate, RelinkCandidateRow};
use crate::error::Result;
use crate::repository::folders::FolderRepository;
use crate::repository::library::{normalize_local_path_for_compare, path_in_scope};
use crate::repository::tx::ImmediateTx;

impl IngestionRepository {
    pub async fn update_track_fingerprint(
        pool: &SqlitePool,
        track_source_id: &str,
        fingerprint: &str,
        audio_byte_len: u64,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE track_sources SET content_fingerprint = ?, audio_byte_len = ? WHERE id = ?",
        )
        .bind(fingerprint.trim())
        .bind(audio_byte_len.min(i64::MAX as u64) as i64)
        .bind(track_source_id.trim())
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    /// Finds an existing `track_sources` row with matching `(provider_id, fingerprint, audio_byte_len)`
    /// at a different path, preferring rows already marked `missing` or whose old local path no longer exists.
    pub async fn find_relink_candidate_by_fingerprint(
        pool: &SqlitePool,
        provider_id: &str,
        fingerprint: &str,
        audio_byte_len: u64,
        exclude_path: &str,
    ) -> Result<Option<RelinkCandidate>> {
        let rows: Vec<RelinkCandidateRow> = sqlx::query_as(
            "SELECT id, version_id, external_track_id, file_status, canonical_track_id \
             FROM track_sources \
             WHERE provider_id = ? AND content_fingerprint = ? AND audio_byte_len = ? \
             ORDER BY CASE WHEN file_status = 'missing' THEN 0 ELSE 1 END, missing_since DESC",
        )
        .bind(provider_id.trim())
        .bind(fingerprint.trim())
        .bind(audio_byte_len.min(i64::MAX as u64) as i64)
        .fetch_all(pool)
        .await?;

        let exclude_norm = normalize_local_path_for_compare(exclude_path);
        let mut present_local_candidates: Vec<RelinkCandidate> = Vec::new();

        for row in rows {
            if normalize_local_path_for_compare(&row.external_track_id) == exclude_norm {
                continue;
            }
            let status = FileStatus::from_str(&row.file_status).unwrap_or(FileStatus::Present);
            let cand = RelinkCandidate {
                track_source_id: row.id,
                version_id: row.version_id,
                external_track_id: row.external_track_id,
                file_status: status,
                canonical_track_id: row.canonical_track_id,
            };

            if status == FileStatus::Missing {
                return Ok(Some(cand));
            }
            if provider_id.eq_ignore_ascii_case("local") {
                present_local_candidates.push(cand);
            }
        }

        if present_local_candidates.is_empty() {
            return Ok(None);
        }

        let paths: Vec<PathBuf> = present_local_candidates
            .iter()
            .map(|c| PathBuf::from(&c.external_track_id))
            .collect();

        let missing_idx =
            tokio::task::spawn_blocking(move || paths.iter().position(|p| !p.exists()))
                .await
                .ok()
                .flatten();

        Ok(missing_idx.map(|idx| present_local_candidates.swap_remove(idx)))
    }

    /// Relinks a moved or renamed track in-place on an existing SQLite connection.
    pub async fn relink_moved_track_source_tx(
        conn: &mut SqliteConnection,
        track_source_id: &str,
        new_external_track_id: &str,
        new_version_id: &str,
        new_mtime: Option<i64>,
        new_size: Option<i64>,
    ) -> Result<bool> {
        let trimmed_id = track_source_id.trim();
        let trimmed_path = new_external_track_id.trim();

        let existing: Option<(String, Option<String>, String)> = sqlx::query_as(
            "SELECT provider_id, folder_id, file_status FROM track_sources WHERE id = ?",
        )
        .bind(trimmed_id)
        .fetch_optional(&mut *conn)
        .await?;

        let Some((provider_id, old_folder_id, old_status)) = existing else {
            return Ok(false);
        };

        let was_present = old_status == "present";
        let new_folder_id = FolderRepository::sync_track_folder_tx(
            conn,
            &provider_id,
            trimmed_path,
            Some(trimmed_path),
            old_folder_id.as_deref(),
            was_present,
            true,
        )
        .await?;

        let res = sqlx::query(
            "UPDATE track_sources \
             SET external_track_id = ?, \
                 version_id = ?, \
                 file_mtime = COALESCE(?, file_mtime), \
                 file_size = COALESCE(?, file_size), \
                 folder_id = ?, \
                 file_status = 'present', \
                 missing_since = NULL \
             WHERE id = ?",
        )
        .bind(trimmed_path)
        .bind(new_version_id.trim())
        .bind(new_mtime)
        .bind(new_size)
        .bind(&new_folder_id)
        .bind(trimmed_id)
        .execute(&mut *conn)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    /// Relinks a moved or renamed track in-place so `track_sources.id`, `play_history`,
    /// `profile_favorites`, `artwork_overrides`, and `metadata_overrides` stay 100% intact.
    pub async fn relink_moved_track_source(
        pool: &SqlitePool,
        track_source_id: &str,
        new_external_track_id: &str,
        new_version_id: &str,
        new_mtime: Option<i64>,
        new_size: Option<i64>,
    ) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::relink_moved_track_source_tx(
            tx.conn(),
            track_source_id,
            new_external_track_id,
            new_version_id,
            new_mtime,
            new_size,
        )
        .await;
        match res {
            Ok(changed) => {
                tx.commit().await?;
                Ok(changed)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Marks unseen tracks under `root_prefix` as `file_status = 'missing'` (soft-missing)
    /// without hard-deleting them, and restores any seen previously-missing tracks to `'present'`.
    pub async fn mark_missing_local_tracks_under_root(
        pool: &SqlitePool,
        provider_id: &str,
        root_prefix: &str,
        seen_paths: &HashSet<String>,
    ) -> Result<usize> {
        let scope_norm = normalize_local_path_for_compare(root_prefix);
        let seen_norm: HashSet<String> = seen_paths
            .iter()
            .map(|p| normalize_local_path_for_compare(p))
            .collect();

        let trimmed_provider = provider_id.trim();
        let is_local = trimmed_provider.eq_ignore_ascii_case("local");

        // Read and diff BEFORE opening any write transaction to avoid unnecessary write locks.
        let rows: Vec<(String, String, String, Option<String>)> = sqlx::query_as(
            "SELECT id, external_track_id, file_status, folder_id \
             FROM track_sources WHERE provider_id = ?",
        )
        .bind(trimmed_provider)
        .fetch_all(pool)
        .await?;

        let mut to_mark_missing: Vec<(String, String, Option<String>)> = Vec::new();
        let mut to_restore_present: Vec<(String, String, Option<String>)> = Vec::new();

        for (id, ext_path, status, folder_id) in rows {
            let norm = normalize_local_path_for_compare(&ext_path);
            if !path_in_scope(&norm, &scope_norm) {
                continue;
            }
            if seen_norm.contains(&norm) {
                if status != "present" {
                    to_restore_present.push((id, ext_path, folder_id));
                }
            } else if status != "missing" {
                to_mark_missing.push((id, ext_path, folder_id));
            }
        }

        if to_restore_present.is_empty() && to_mark_missing.is_empty() {
            return Ok(0);
        }

        let now = Utc::now().to_rfc3339();

        for chunk in to_restore_present.chunks(250) {
            let mut tx = ImmediateTx::begin(pool).await?;
            let res = async {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "UPDATE track_sources SET file_status = 'present', missing_since = NULL WHERE id IN (",
                );
                let mut sep = qb.separated(", ");
                for (id, _, _) in chunk {
                    sep.push_bind(id);
                }
                sep.push_unseparated(")");
                qb.build().execute(tx.conn()).await?;

                if is_local {
                    for (id, ext_path, old_folder_id) in chunk {
                        let new_folder_id = FolderRepository::sync_track_folder_tx(
                            tx.conn(),
                            trimmed_provider,
                            ext_path,
                            None,
                            old_folder_id.as_deref(),
                            false,
                            true,
                        )
                        .await?;
                        if new_folder_id != *old_folder_id {
                            sqlx::query("UPDATE track_sources SET folder_id = ? WHERE id = ?")
                                .bind(&new_folder_id)
                                .bind(id)
                                .execute(tx.conn())
                                .await?;
                        }
                    }
                }
                Ok::<(), crate::error::DbError>(())
            }
            .await;

            match res {
                Ok(()) => tx.commit().await?,
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(e);
                }
            }
            tokio::task::yield_now().await;
        }

        let mut marked = 0usize;
        for chunk in to_mark_missing.chunks(250) {
            let mut tx = ImmediateTx::begin(pool).await?;
            let res: Result<usize> = async {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "UPDATE track_sources SET file_status = 'missing', missing_since = COALESCE(missing_since, ",
                );
                qb.push_bind(&now);
                qb.push(") WHERE id IN (");
                let mut sep = qb.separated(", ");
                for (id, _, _) in chunk {
                    sep.push_bind(id);
                }
                sep.push_unseparated(")");
                let count = qb.build().execute(tx.conn()).await?.rows_affected() as usize;

                if is_local {
                    for (_, ext_path, old_folder_id) in chunk {
                        let _ = FolderRepository::sync_track_folder_tx(
                            tx.conn(),
                            trimmed_provider,
                            ext_path,
                            None,
                            old_folder_id.as_deref(),
                            true,
                            false,
                        )
                        .await?;
                    }
                }
                Ok(count)
            }
            .await;

            match res {
                Ok(n) => {
                    tx.commit().await?;
                    marked += n;
                }
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(e);
                }
            }
            tokio::task::yield_now().await;
        }

        Ok(marked)
    }
}
