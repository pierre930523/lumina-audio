use chrono::Utc;
use core_types::{
    AudioFormat, DeleteTrackResult, TrackAnalysisResult, TrackDeleteMode, TrackMetadataLayer,
    TrackVisibilityResult,
};
use sqlx::{SqliteConnection, SqlitePool};
use std::collections::HashSet;

use super::LibraryRepository;
use super::prune_helpers::{
    delete_album_batch_with_refs_tx, delete_in_chunks_tx, delete_track_batch_with_refs_tx,
    prune_orphan_artists_and_stale_fts_tx,
};
use crate::error::{DbError, Result};
use crate::repository::folders::FolderRepository;
use crate::repository::tx::ImmediateTx;
use crate::search::{
    delete_fts_entry_conn, sync_single_album_fts_visibility_conn, sync_track_fts_conn,
};

#[derive(Debug, sqlx::FromRow)]
struct TrackFtsVisibilityRow {
    title: String,
    artist_name: Option<String>,
    album_title: Option<String>,
    file_status: String,
    is_hidden: i32,
}

impl LibraryRepository {
    /// Syncs a single track's `search_fts` entry based on `file_status` and `is_hidden`.
    pub async fn sync_single_track_fts_visibility_conn(
        conn: &mut SqliteConnection,
        track_id: &str,
    ) -> Result<()> {
        let row: Option<TrackFtsVisibilityRow> = sqlx::query_as(
            "SELECT ts.title, COALESCE(NULLIF(ts.artist_name, ''), art.name) AS artist_name, \
                    ca.title AS album_title, ts.file_status, ts.is_hidden \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             LEFT JOIN artists art ON art.id = ca.primary_artist_id \
             WHERE ts.id = ?",
        )
        .bind(track_id)
        .fetch_optional(&mut *conn)
        .await?;

        match row {
            Some(r) if r.file_status == "present" && r.is_hidden == 0 => {
                sync_track_fts_conn(
                    conn,
                    track_id,
                    &r.title,
                    r.artist_name.as_deref(),
                    r.album_title.as_deref(),
                )
                .await
            }
            _ => delete_fts_entry_conn(conn, "track", track_id).await,
        }
    }

    /// Sets per-track `is_hidden` visibility and syncs track + album FTS entries.
    pub async fn set_track_hidden(
        pool: &SqlitePool,
        track_id: &str,
        is_hidden: bool,
    ) -> Result<TrackVisibilityResult> {
        let tid = track_id.trim();
        let mut tx = ImmediateTx::begin(pool).await?;

        let row: Option<(String,)> = sqlx::query_as(
            "SELECT av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.id = ?",
        )
        .bind(tid)
        .fetch_optional(tx.conn())
        .await?;

        let Some((album_id,)) = row else {
            let _ = tx.rollback().await;
            return Err(DbError::NotFound(format!("Track '{tid}' not found")));
        };

        let res: Result<()> = async {
            sqlx::query("UPDATE track_sources SET is_hidden = ? WHERE id = ?")
                .bind(if is_hidden { 1i32 } else { 0i32 })
                .bind(tid)
                .execute(tx.conn())
                .await?;
            Self::sync_single_track_fts_visibility_conn(tx.conn(), tid).await?;
            sync_single_album_fts_visibility_conn(tx.conn(), &album_id).await?;
            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(TrackVisibilityResult {
                    track_id: tid.to_string(),
                    is_hidden,
                    affected_album_ids: vec![album_id],
                })
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Updates a single track's technical properties and `file_meta_json` after rescan,
    /// clears stale `artwork_cache` entries for the track & its album, and recomputes effective
    /// fields without clobbering `user_edits_json` or `cloud_meta_json`.
    #[allow(clippy::too_many_arguments)]
    pub async fn apply_single_track_rescan(
        pool: &SqlitePool,
        track_id: &str,
        file_meta: &TrackMetadataLayer,
        format: &AudioFormat,
        duration_ms: u64,
        bitrate_kbps: Option<u32>,
        file_mtime: Option<i64>,
        file_size: Option<i64>,
        metadata_hash: Option<&str>,
        replay_gain_track_db: Option<f64>,
        replay_gain_album_db: Option<f64>,
        replay_gain_track_peak: Option<f64>,
        replay_gain_album_peak: Option<f64>,
    ) -> Result<(Vec<String>, Vec<String>)> {
        let tid = track_id.trim();
        let mut tx = ImmediateTx::begin(pool).await?;

        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT ts.version_id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.id = ?",
        )
        .bind(tid)
        .fetch_optional(tx.conn())
        .await?;

        let Some((_, old_album_id)) = row else {
            let _ = tx.rollback().await;
            return Err(DbError::NotFound(format!("Track '{tid}' not found")));
        };

        let mut invalidated_artwork_paths = Vec::new();
        let res: Result<Vec<String>> = async {
            let cache_rows: Vec<(String,)> = sqlx::query_as(
                "SELECT cache_path FROM artwork_cache WHERE track_id = ? OR album_id = ?",
            )
            .bind(tid)
            .bind(&old_album_id)
            .fetch_all(tx.conn())
            .await?;
            invalidated_artwork_paths.extend(cache_rows.into_iter().map(|(p,)| p));
            sqlx::query("DELETE FROM artwork_cache WHERE track_id = ? OR album_id = ?")
                .bind(tid)
                .bind(&old_album_id)
                .execute(tx.conn())
                .await?;

            let file_meta_json = file_meta.to_json_opt();
            let is_dsd = if format.is_dsd || format.codec.is_dsd() {
                1i32
            } else {
                0i32
            };
            sqlx::query(
                "UPDATE track_sources SET \
                    duration_ms = ?, \
                    sample_rate_hz = ?, \
                    bit_depth = ?, \
                    channels = ?, \
                    codec = ?, \
                    is_dsd = ?, \
                    bitrate_kbps = COALESCE(?, bitrate_kbps), \
                    file_mtime = COALESCE(?, file_mtime), \
                    file_size = COALESCE(?, file_size), \
                    metadata_hash = COALESCE(?, metadata_hash), \
                    replay_gain_track_db = COALESCE(?, replay_gain_track_db), \
                    replay_gain_album_db = COALESCE(?, replay_gain_album_db), \
                    replay_gain_track_peak = COALESCE(?, replay_gain_track_peak), \
                    replay_gain_album_peak = COALESCE(?, replay_gain_album_peak), \
                    file_status = 'present', \
                    missing_since = NULL, \
                    file_meta_json = ? \
                 WHERE id = ?",
            )
            .bind(duration_ms.max(1) as i64)
            .bind(format.sample_rate_hz as i64)
            .bind(format.bit_depth as i64)
            .bind(format.channels.max(1) as i64)
            .bind(format.codec.as_str())
            .bind(is_dsd)
            .bind(bitrate_kbps.map(i64::from))
            .bind(file_mtime)
            .bind(file_size)
            .bind(metadata_hash)
            .bind(replay_gain_track_db)
            .bind(replay_gain_album_db)
            .bind(replay_gain_track_peak)
            .bind(replay_gain_album_peak)
            .bind(&file_meta_json)
            .bind(tid)
            .execute(tx.conn())
            .await?;

            let default_policy = Self::get_default_metadata_policy_tx(tx.conn()).await?;
            Self::recompute_track_effective_tx(tx.conn(), tid, default_policy).await?;

            let new_loc: Option<(String,)> = sqlx::query_as(
                "SELECT av.canonical_album_id FROM track_sources ts \
                 JOIN album_versions av ON av.id = ts.version_id WHERE ts.id = ?",
            )
            .bind(tid)
            .fetch_optional(tx.conn())
            .await?;
            let mut albums = vec![old_album_id];
            if let Some((new_aid,)) = new_loc
                && !albums.contains(&new_aid)
            {
                albums.push(new_aid);
            }
            for aid in &albums {
                sync_single_album_fts_visibility_conn(tx.conn(), aid).await?;
            }
            Ok(albums)
        }
        .await;

        match res {
            Ok(albums) => {
                tx.commit().await?;
                Ok((albums, invalidated_artwork_paths))
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Persists offline corruption, loudness, and waveform peak analysis for a track.
    pub async fn save_track_analysis_result(
        pool: &SqlitePool,
        result: &TrackAnalysisResult,
    ) -> Result<()> {
        let tid = result.track_id.trim();
        let peaks_json = if result.waveform_peaks.is_empty() {
            None
        } else {
            Some(serde_json::to_string(&result.waveform_peaks).map_err(|e| {
                DbError::ConstraintViolation(format!("failed to serialize waveform_peaks: {e}"))
            })?)
        };
        let now = result
            .analyzed_at
            .clone()
            .unwrap_or_else(|| Utc::now().to_rfc3339());

        let mut tx = ImmediateTx::begin(pool).await?;
        let res = sqlx::query(
            "UPDATE track_sources SET \
                corruption_status = ?, \
                analysis_error = ?, \
                integrated_lufs = ?, \
                true_peak_db = ?, \
                replay_gain_track_db = COALESCE(?, replay_gain_track_db), \
                replay_gain_track_peak = COALESCE(?, replay_gain_track_peak), \
                waveform_peaks_json = ?, \
                bitrate_kbps = COALESCE(?, bitrate_kbps), \
                analyzed_at = ? \
             WHERE id = ?",
        )
        .bind(result.corruption_status.as_str())
        .bind(&result.analysis_error)
        .bind(result.integrated_lufs)
        .bind(result.true_peak_db)
        .bind(result.replay_gain_track_db)
        .bind(result.replay_gain_track_peak)
        .bind(&peaks_json)
        .bind(result.bitrate_kbps.map(i64::from))
        .bind(&now)
        .bind(tid)
        .execute(tx.conn())
        .await?;

        if res.rows_affected() == 0 {
            let _ = tx.rollback().await;
            return Err(DbError::NotFound(format!("Track '{tid}' not found")));
        }
        tx.commit().await?;
        Ok(())
    }

    /// Deletes a single track from the SQLite library, cascading orphan version/album/
    /// canonical_track/artist cleanup and recomputing folder track counts.
    ///
    /// Returns `(DeleteTrackResult, external_track_id, is_local, invalidated_artwork_paths)`.
    pub async fn delete_track_from_library(
        pool: &SqlitePool,
        track_id: &str,
        mode: TrackDeleteMode,
    ) -> Result<(DeleteTrackResult, String, bool, Vec<String>)> {
        let tid = track_id.trim();
        let mut tx = ImmediateTx::begin(pool).await?;

        let info: Option<(String, String, String, String)> = sqlx::query_as(
            "SELECT ts.version_id, ts.provider_id, ts.external_track_id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.id = ?",
        )
        .bind(tid)
        .fetch_optional(tx.conn())
        .await?;

        let Some((ver_id, provider_id, external_track_id, album_id)) = info else {
            let _ = tx.rollback().await;
            return Err(DbError::NotFound(format!("Track '{tid}' not found")));
        };

        let is_local = provider_id.eq_ignore_ascii_case("local");
        let mut seen_paths = HashSet::new();
        let mut invalidated_artwork_paths = Vec::new();
        let mut orphans_pruned = 0u64;

        let res: Result<()> = async {
            let track_ids = vec![tid.to_string()];
            delete_track_batch_with_refs_tx(
                tx.conn(),
                &track_ids,
                &mut seen_paths,
                &mut invalidated_artwork_paths,
            )
            .await?;

            sqlx::query(
                "DELETE FROM canonical_tracks \
                 WHERE NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.canonical_track_id = canonical_tracks.id)",
            )
            .execute(tx.conn())
            .await?;

            let (remaining_in_ver,): (i64,) =
                sqlx::query_as("SELECT COUNT(*) FROM track_sources WHERE version_id = ?")
                    .bind(&ver_id)
                    .fetch_one(tx.conn())
                    .await?;
            if remaining_in_ver == 0 {
                delete_in_chunks_tx(
                    tx.conn(),
                    "DELETE FROM album_versions WHERE id IN (",
                    std::slice::from_ref(&ver_id),
                )
                .await?;
                orphans_pruned += 1;

                let (remaining_vers,): (i64,) = sqlx::query_as(
                    "SELECT COUNT(*) FROM album_versions WHERE canonical_album_id = ?",
                )
                .bind(&album_id)
                .fetch_one(tx.conn())
                .await?;
                if remaining_vers == 0 {
                    delete_album_batch_with_refs_tx(
                        tx.conn(),
                        std::slice::from_ref(&album_id),
                        &mut seen_paths,
                        &mut invalidated_artwork_paths,
                    )
                    .await?;
                    orphans_pruned += 1;
                } else {
                    sync_single_album_fts_visibility_conn(tx.conn(), &album_id).await?;
                }
            } else {
                sync_single_album_fts_visibility_conn(tx.conn(), &album_id).await?;
            }

            let pruned_artists = prune_orphan_artists_and_stale_fts_tx(tx.conn()).await?;
            orphans_pruned += pruned_artists as u64;

            FolderRepository::recompute_all_folder_counts_tx(tx.conn()).await?;
            let _ = FolderRepository::prune_empty_folders_tx(tx.conn()).await?;
            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                let result = DeleteTrackResult {
                    track_id: tid.to_string(),
                    mode,
                    deleted_from_library: true,
                    moved_to_trash: false,
                    vacated_album_ids: vec![album_id],
                    orphans_pruned,
                    warning: None,
                };
                Ok((
                    result,
                    external_track_id,
                    is_local,
                    invalidated_artwork_paths,
                ))
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
