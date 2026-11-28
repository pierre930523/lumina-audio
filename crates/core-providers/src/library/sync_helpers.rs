use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use core_db::{
    CatalogQueryRepository, DbWriteCoordinator, IngestionRepository, LibraryRepository, SqlitePool,
};
use core_types::{SkipReason, TrackSource};

use crate::error::ProviderError;
use crate::local::cleanup::{
    infer_volume_or_mount_root, is_root_accessible, normalize_path_for_compare, path_under_root,
};
use crate::local::pipeline::build_track_file_layer;

use super::{DB_BATCH_TRACKS, SyncPersistReport, db_err};

pub(super) struct RescanSkipRecord {
    pub(super) norm_path: String,
    pub(super) reason: SkipReason,
    pub(super) detail: String,
    pub(super) file_size: Option<u64>,
    pub(super) file_mtime: Option<i64>,
}

pub(super) async fn resolve_online_rescan_roots(
    pool: &SqlitePool,
    dir_or_null: Option<&str>,
) -> Result<Result<Vec<PathBuf>, String>, ProviderError> {
    if let Some(d) = dir_or_null {
        let trimmed = d.trim().to_string();
        let p = PathBuf::from(&trimmed);
        let p_check = p.clone();
        let accessible = tokio::task::spawn_blocking(move || is_root_accessible(&p_check))
            .await
            .unwrap_or(false);
        if !accessible {
            return Ok(Err(format!(
                "Root directory '{trimmed}' is offline or unreachable; skipping rescan without pruning"
            )));
        }
        return Ok(Ok(vec![p]));
    }

    let watched = IngestionRepository::list_watched_roots(pool)
        .await
        .map_err(db_err)?;
    let watched_local: Vec<PathBuf> = watched
        .into_iter()
        .filter(|r| r.provider_id.eq_ignore_ascii_case("local"))
        .map(|r| PathBuf::from(r.root_path))
        .collect();

    let rows = CatalogQueryRepository::list_distinct_external_track_ids(pool, "local")
        .await
        .map_err(db_err)?;
    let watched_norms: Vec<String> = watched_local
        .iter()
        .map(|p| normalize_path_for_compare(&p.to_string_lossy()))
        .collect();

    let mut extra_dirs: HashSet<PathBuf> = HashSet::new();
    for p_str in &rows {
        let norm_fp = normalize_path_for_compare(p_str);
        let covered = watched_norms.iter().any(|r| path_under_root(&norm_fp, r));
        if !covered {
            if let Some(parent) = Path::new(p_str).parent() {
                extra_dirs.insert(parent.to_path_buf());
            }
        }
    }

    let mut all_candidates = watched_local;
    all_candidates.extend(extra_dirs);
    if all_candidates.is_empty() {
        return Ok(Ok(Vec::new()));
    }

    let reachable: Vec<PathBuf> = tokio::task::spawn_blocking(move || {
        all_candidates
            .into_iter()
            .filter(|d| {
                let raw = d.to_string_lossy();
                if let Some(vol) = infer_volume_or_mount_root(&raw) {
                    if !is_root_accessible(Path::new(&vol)) {
                        return false;
                    }
                }
                is_root_accessible(d)
            })
            .collect()
    })
    .await
    .unwrap_or_default();

    if reachable.is_empty() && !rows.is_empty() {
        return Ok(Err(
            "All known local library directories are currently offline; skipping prune".to_string(),
        ));
    }
    Ok(Ok(reachable))
}

pub(super) async fn flush_rescan_skips_chunked(
    pool: &SqlitePool,
    write_coord: &DbWriteCoordinator,
    records: &[RescanSkipRecord],
) {
    for chunk in records.chunks(DB_BATCH_TRACKS) {
        if let Ok((_wg, mut tx)) = write_coord.begin_immediate(pool).await {
            let mut ok = true;
            for rec in chunk {
                if IngestionRepository::record_skipped_file_tx(
                    tx.conn(),
                    "local",
                    &rec.norm_path,
                    rec.reason,
                    &rec.detail,
                    rec.file_size,
                    rec.file_mtime,
                )
                .await
                .is_err()
                {
                    ok = false;
                    break;
                }
            }
            if ok {
                let _ = tx.commit().await;
            } else {
                let _ = tx.rollback().await;
            }
        }
    }
}

pub(super) async fn flush_rescan_clears_chunked(
    pool: &SqlitePool,
    write_coord: &DbWriteCoordinator,
    paths: &[String],
) {
    for chunk in paths.chunks(DB_BATCH_TRACKS) {
        if let Ok((_wg, mut tx)) = write_coord.begin_immediate(pool).await {
            let mut ok = true;
            for p in chunk {
                if IngestionRepository::clear_skipped_for_path_tx(tx.conn(), "local", p)
                    .await
                    .is_err()
                {
                    ok = false;
                    break;
                }
            }
            if ok {
                let _ = tx.commit().await;
            } else {
                let _ = tx.rollback().await;
            }
        }
    }
}

pub(super) async fn clear_deleted_skipped_under_roots(
    pool: &SqlitePool,
    write_coord: &DbWriteCoordinator,
    online_roots: &[PathBuf],
) {
    if online_roots.is_empty() {
        return;
    }
    let Ok(all_skipped) = IngestionRepository::list_skipped_files(pool, true).await else {
        return;
    };
    let root_norms: Vec<String> = online_roots
        .iter()
        .map(|p| normalize_path_for_compare(&p.to_string_lossy()))
        .collect();
    let candidates: Vec<(String, String)> = all_skipped
        .into_iter()
        .filter(|rec| {
            rec.provider_id.eq_ignore_ascii_case("local")
                && root_norms
                    .iter()
                    .any(|r| path_under_root(&normalize_path_for_compare(&rec.file_path), r))
        })
        .map(|rec| (rec.id, rec.file_path))
        .collect();
    if candidates.is_empty() {
        return;
    }
    let missing_ids: Vec<String> = tokio::task::spawn_blocking(move || {
        candidates
            .into_iter()
            .filter(|(_, fp)| {
                matches!(
                    fs::symlink_metadata(Path::new(fp)),
                    Err(e) if e.kind() == ErrorKind::NotFound
                )
            })
            .map(|(id, _)| id)
            .collect()
    })
    .await
    .unwrap_or_default();
    if missing_ids.is_empty() {
        return;
    }
    if let Ok((_wg, mut tx)) = write_coord.begin_immediate(pool).await {
        if IngestionRepository::delete_skipped_by_ids_tx(tx.conn(), &missing_ids)
            .await
            .is_ok()
        {
            let _ = tx.commit().await;
        } else {
            let _ = tx.rollback().await;
        }
    }
}

/// Persists standalone tracks not covered by the main album chunks.
pub(super) async fn persist_remaining_tracks(
    pool: &SqlitePool,
    write_coord: &DbWriteCoordinator,
    remaining_tracks: &[&TrackSource],
    version_id_map: &HashMap<String, String>,
    report: &mut SyncPersistReport,
) -> Result<(), ProviderError> {
    for chunk in remaining_tracks.chunks(DB_BATCH_TRACKS) {
        let (_wg, mut tx) = write_coord.begin_immediate(pool).await.map_err(db_err)?;
        let tx_res: Result<(), ProviderError> = async {
            for track in chunk {
                let mut trk = (*track).clone();
                if let Some(authoritative_ver_id) = version_id_map.get(&track.version_id) {
                    trk.version_id = authoritative_ver_id.clone();
                }
                LibraryRepository::upsert_track_source_preserving_lyrics_tx(tx.conn(), &trk)
                    .await
                    .map_err(db_err)?;
                let saved_id = IngestionRepository::get_track_and_album_by_external_id_tx(
                    tx.conn(),
                    trk.provider.as_str(),
                    &trk.external_track_id,
                )
                .await
                .ok()
                .flatten()
                .map(|(id, _)| id)
                .unwrap_or_else(|| trk.id.clone());
                LibraryRepository::write_track_file_meta_tx(
                    tx.conn(),
                    &saved_id,
                    &build_track_file_layer(&trk, trk.release_year, None),
                )
                .await
                .map_err(db_err)?;
                report.tracks_upserted += 1;
                report.search_index_entries += 1;
            }
            Ok(())
        }
        .await;
        match tx_res {
            Ok(()) => tx.commit().await.map_err(db_err)?,
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        }
        tokio::task::yield_now().await;
    }
    Ok(())
}
