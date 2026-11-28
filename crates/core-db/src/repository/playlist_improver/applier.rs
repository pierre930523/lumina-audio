use std::collections::{HashMap, HashSet};

use chrono::Utc;
use core_types::{
    ApplyPlaylistImprovementsRequest, ApplyPlaylistImprovementsResult, PlaylistImprovementKind,
    PlaylistImprovementSuggestion, PlaylistSnapshotRecord, RevertPlaylistSnapshotResult,
};
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;
use uuid::Uuid;

use super::PlaylistImproverRepository;
use super::analyzer::analyze_playlist_conn;
use super::helpers::DiskCheckMode;
use crate::error::{DbError, Result};
use crate::write_coordinator::DbWriteCoordinator;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
struct SnapshotItem {
    position: i64,
    raw_entry: String,
    resolved_track_source_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SnapshotPayload {
    version: u32,
    playlist_id: String,
    items: Vec<SnapshotItem>,
}

#[derive(Debug, sqlx::FromRow)]
struct SnapshotDbRow {
    id: String,
    playlist_id: String,
    reason: String,
    track_count: i64,
    created_at: String,
}

impl From<SnapshotDbRow> for PlaylistSnapshotRecord {
    fn from(r: SnapshotDbRow) -> Self {
        Self {
            id: r.id,
            playlist_id: r.playlist_id,
            reason: r.reason,
            track_count: r.track_count.max(0) as u64,
            created_at: r.created_at,
        }
    }
}

fn filter_selected_suggestions<'a>(
    suggestions: &'a [PlaylistImprovementSuggestion],
    req: &ApplyPlaylistImprovementsRequest,
) -> Vec<&'a PlaylistImprovementSuggestion> {
    let selected_ids: HashSet<&str> = req
        .suggestion_ids
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    let allowed_kinds: Option<HashSet<PlaylistImprovementKind>> = req
        .apply_kinds
        .as_ref()
        .filter(|kinds| !kinds.is_empty())
        .map(|kinds| kinds.iter().copied().collect());

    if !selected_ids.is_empty() {
        suggestions
            .iter()
            .filter(|s| {
                selected_ids.contains(s.suggestion_id.as_str())
                    && allowed_kinds
                        .as_ref()
                        .is_none_or(|kinds| kinds.contains(&s.kind))
            })
            .collect()
    } else if let Some(ref kinds) = allowed_kinds {
        suggestions
            .iter()
            .filter(|s| kinds.contains(&s.kind))
            .collect()
    } else {
        Vec::new()
    }
}

impl PlaylistImproverRepository {
    /// Atomically snapshots the playlist and applies the selected `suggestion_ids` inside one
    /// `ImmediateTx`, preserving original playback order for all surviving/replaced items.
    pub async fn apply_playlist_improvements(
        pool: &SqlitePool,
        playlist_id: &str,
        selected_action_ids: &[String],
    ) -> Result<ApplyPlaylistImprovementsResult> {
        let req = ApplyPlaylistImprovementsRequest {
            suggestion_ids: selected_action_ids.to_vec(),
            apply_kinds: None,
            reason: None,
        };
        Self::apply_playlist_improvements_request(pool, playlist_id, &req).await
    }

    /// Atomically snapshots the playlist and applies improvements matching `req` (`suggestion_ids`
    /// and/or `apply_kinds`) inside a single `ImmediateTx`.
    pub async fn apply_playlist_improvements_request(
        pool: &SqlitePool,
        playlist_id: &str,
        req: &ApplyPlaylistImprovementsRequest,
    ) -> Result<ApplyPlaylistImprovementsResult> {
        let pid = playlist_id.trim();
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;

        let res: Result<ApplyPlaylistImprovementsResult> = async {
            let report = analyze_playlist_conn(tx.conn(), pid, DiskCheckMode::Smart).await?;
            let selected = filter_selected_suggestions(&report.suggestions, req);

            if selected.is_empty() {
                return Ok(ApplyPlaylistImprovementsResult {
                    playlist_id: report.playlist_id,
                    snapshot_id: None,
                    duplicates_removed: 0,
                    tracks_repaired: 0,
                    tracks_upgraded: 0,
                    final_track_count: report.total_items,
                });
            }

            let current_items: Vec<SnapshotItem> = sqlx::query_as(
                "SELECT position, raw_entry, resolved_track_source_id \
                 FROM playlist_items \
                 WHERE playlist_id = ? \
                 ORDER BY position ASC",
            )
            .bind(&report.playlist_id)
            .fetch_all(tx.conn())
            .await?;

            // 1. Persist pre-mutation undo snapshot
            let snapshot_id = Uuid::new_v4().to_string();
            let now = Utc::now().to_rfc3339();
            let reason = req
                .reason
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("improver");
            let payload = SnapshotPayload {
                version: 1,
                playlist_id: report.playlist_id.clone(),
                items: current_items.clone(),
            };
            let snapshot_json = serde_json::to_string(&payload).map_err(|e| {
                DbError::ConstraintViolation(format!("Failed to serialize playlist snapshot: {e}"))
            })?;

            sqlx::query(
                "INSERT INTO playlist_snapshots \
                    (id, playlist_id, snapshot_json, reason, track_count, created_at) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(&snapshot_id)
            .bind(&report.playlist_id)
            .bind(&snapshot_json)
            .bind(reason)
            .bind(current_items.len() as i64)
            .bind(&now)
            .execute(tx.conn())
            .await?;

            // 2. Partition selected actions by position
            let mut removals: HashSet<i64> = HashSet::new();
            let mut replacements: HashMap<i64, (PlaylistImprovementKind, String, String)> =
                HashMap::new();

            for suggestion in selected {
                match suggestion.kind {
                    PlaylistImprovementKind::Duplicate => {
                        removals.insert(suggestion.position);
                    }
                    PlaylistImprovementKind::Repair | PlaylistImprovementKind::Upgrade => {
                        if let Some(ref cand) = suggestion.candidate_track {
                            let ext_row: Option<(String,)> = sqlx::query_as(
                                "SELECT external_track_id FROM track_sources WHERE id = ?",
                            )
                            .bind(&cand.track_id)
                            .fetch_optional(tx.conn())
                            .await?;
                            if let Some((ext_id,)) = ext_row {
                                replacements.insert(
                                    suggestion.position,
                                    (suggestion.kind, cand.track_id.clone(), ext_id),
                                );
                            }
                        }
                    }
                }
            }

            // 3. Apply in-place replacements and removals while preserving playback order
            let mut duplicates_removed = 0u64;
            let mut tracks_repaired = 0u64;
            let mut tracks_upgraded = 0u64;
            let mut next_items: Vec<(String, Option<String>)> =
                Vec::with_capacity(current_items.len());

            for item in current_items {
                if removals.contains(&item.position) {
                    duplicates_removed += 1;
                    continue;
                }
                if let Some((kind, cand_id, cand_raw)) = replacements.get(&item.position) {
                    next_items.push((cand_raw.clone(), Some(cand_id.clone())));
                    match kind {
                        PlaylistImprovementKind::Repair => tracks_repaired += 1,
                        PlaylistImprovementKind::Upgrade => tracks_upgraded += 1,
                        PlaylistImprovementKind::Duplicate => {}
                    }
                } else {
                    next_items.push((item.raw_entry, item.resolved_track_source_id));
                }
            }

            // 4. Re-index surviving items contiguously (0..N-1) and update playlist metadata
            sqlx::query("DELETE FROM playlist_items WHERE playlist_id = ?")
                .bind(&report.playlist_id)
                .execute(tx.conn())
                .await?;

            for (pos, (raw_entry, resolved_id)) in next_items.iter().enumerate() {
                sqlx::query(
                    "INSERT INTO playlist_items \
                        (playlist_id, position, raw_entry, resolved_track_source_id) \
                     VALUES (?, ?, ?, ?)",
                )
                .bind(&report.playlist_id)
                .bind(pos as i64)
                .bind(raw_entry)
                .bind(resolved_id)
                .execute(tx.conn())
                .await?;
            }

            sqlx::query("UPDATE playlists SET track_count = ?, updated_at = ? WHERE id = ?")
                .bind(next_items.len() as i64)
                .bind(&now)
                .bind(&report.playlist_id)
                .execute(tx.conn())
                .await?;

            Ok(ApplyPlaylistImprovementsResult {
                playlist_id: report.playlist_id,
                snapshot_id: Some(snapshot_id),
                duplicates_removed,
                tracks_repaired,
                tracks_upgraded,
                final_track_count: next_items.len() as u64,
            })
        }
        .await;

        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    /// Lists undo snapshots for a playlist, ordered newest first.
    pub async fn list_playlist_snapshots(
        pool: &SqlitePool,
        playlist_id: &str,
    ) -> Result<Vec<PlaylistSnapshotRecord>> {
        let pid = playlist_id.trim();
        let rows: Vec<SnapshotDbRow> = sqlx::query_as(
            "SELECT id, playlist_id, reason, track_count, created_at \
             FROM playlist_snapshots \
             WHERE playlist_id = ? \
             ORDER BY created_at DESC, rowid DESC",
        )
        .bind(pid)
        .fetch_all(pool)
        .await?;

        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// Atomically restores a playlist's items and exact original positions from a saved snapshot.
    pub async fn revert_playlist_snapshot(
        pool: &SqlitePool,
        snapshot_id: &str,
    ) -> Result<RevertPlaylistSnapshotResult> {
        let sid = snapshot_id.trim();
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;

        let res: Result<RevertPlaylistSnapshotResult> = async {
            let row: Option<(String, String)> = sqlx::query_as(
                "SELECT playlist_id, snapshot_json FROM playlist_snapshots WHERE id = ?",
            )
            .bind(sid)
            .fetch_optional(tx.conn())
            .await?;

            let Some((playlist_id, snapshot_json)) = row else {
                return Err(DbError::NotFound(format!(
                    "Playlist snapshot '{sid}' not found"
                )));
            };

            let exists: Option<(String,)> = sqlx::query_as("SELECT id FROM playlists WHERE id = ?")
                .bind(&playlist_id)
                .fetch_optional(tx.conn())
                .await?;
            if exists.is_none() {
                return Err(DbError::NotFound(format!(
                    "Static playlist '{playlist_id}' not found"
                )));
            }

            let mut payload: SnapshotPayload =
                serde_json::from_str(&snapshot_json).map_err(|e| {
                    DbError::ConstraintViolation(format!(
                        "Corrupted playlist snapshot '{sid}': {e}"
                    ))
                })?;
            payload.items.sort_by_key(|item| item.position);

            sqlx::query("DELETE FROM playlist_items WHERE playlist_id = ?")
                .bind(&playlist_id)
                .execute(tx.conn())
                .await?;

            for item in &payload.items {
                let resolved_id = match item.resolved_track_source_id.as_deref() {
                    Some(tid) => {
                        let found: Option<(String,)> =
                            sqlx::query_as("SELECT id FROM track_sources WHERE id = ?")
                                .bind(tid)
                                .fetch_optional(tx.conn())
                                .await?;
                        found.map(|(id,)| id)
                    }
                    None => None,
                };

                sqlx::query(
                    "INSERT INTO playlist_items \
                        (playlist_id, position, raw_entry, resolved_track_source_id) \
                     VALUES (?, ?, ?, ?)",
                )
                .bind(&playlist_id)
                .bind(item.position)
                .bind(&item.raw_entry)
                .bind(&resolved_id)
                .execute(tx.conn())
                .await?;
            }

            let restored_count = payload.items.len() as u64;
            let now = Utc::now().to_rfc3339();
            sqlx::query("UPDATE playlists SET track_count = ?, updated_at = ? WHERE id = ?")
                .bind(restored_count as i64)
                .bind(&now)
                .bind(&playlist_id)
                .execute(tx.conn())
                .await?;

            Ok(RevertPlaylistSnapshotResult {
                playlist_id,
                snapshot_id: sid.to_string(),
                restored_track_count: restored_count,
            })
        }
        .await;

        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }
}
