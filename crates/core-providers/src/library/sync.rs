use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use core_db::{
    DbWriteCoordinator, FolderRepository, IngestionRepository, LibraryRepository, SqlitePool,
    TrackFileCacheInfo,
};
use core_types::{ScanLifecycleState, ScanProgressEvent, SkipReason};
use tokio::sync::broadcast;

use crate::error::ProviderError;
use crate::local::metadata::parse_audio_metadata;
use crate::local::pipeline::{
    classify_probe_error, group_files_into_album_batches, remove_invalidated_artwork_files,
    resolve_primaries_for_albums_tx,
};
use crate::local::{
    AlbumMapper, DirectoryScanner, ExtractOptions, ExtractedMetadata, ScanSkippedCandidate,
    normalize_path,
};

use super::persist::persist_provider_albums_inner;
use super::sync_helpers::{
    RescanSkipRecord, clear_deleted_skipped_under_roots, flush_rescan_clears_chunked,
    flush_rescan_skips_chunked, resolve_online_rescan_roots,
};
use super::{DB_BATCH_TRACKS, PROGRESS_THROTTLE, db_err};

const MAX_RESCAN_WORKERS: usize = 6;

enum RescanProbeOutcome {
    Unchanged(String),
    Updated {
        path: PathBuf,
        norm_path: String,
        meta: Box<ExtractedMetadata>,
        mtime: i64,
        size: i64,
    },
    Error(RescanSkipRecord),
}

pub(super) async fn rescan_tags_with_progress(
    pool: &SqlitePool,
    dir_or_null: Option<&str>,
    force: bool,
    progress_tx: Option<&broadcast::Sender<ScanProgressEvent>>,
    scan_id: Option<String>,
) -> Result<core_types::RescanReport, ProviderError> {
    let write_coord = DbWriteCoordinator::for_pool(pool);
    let mut report = core_types::RescanReport::default();
    let effective_scan_id = scan_id
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let root_label = dir_or_null
        .map(|d| normalize_path(d.trim()))
        .unwrap_or_else(|| "local".to_string());
    let mut progress = ScanProgressEvent {
        scan_id: effective_scan_id,
        root_path: root_label,
        state: ScanLifecycleState::Discovering,
        ..Default::default()
    };
    if let Some(tx) = progress_tx {
        let _ = tx.send(progress.clone());
    }

    let roots = match resolve_online_rescan_roots(pool, dir_or_null).await? {
        Ok(r) => r,
        Err(offline_msg) => {
            report.errors.push(offline_msg.clone());
            if let Some(tx) = progress_tx {
                progress.state = ScanLifecycleState::Failed;
                progress.message = Some(offline_msg);
                let _ = tx.send(progress);
            }
            return Ok(report);
        }
    };

    let roots_for_scan = roots.clone();
    let (mut audio_files, discovery_skips) = tokio::task::spawn_blocking(move || {
        let mut scanner = DirectoryScanner::new(false);
        let mut files = Vec::new();
        let mut skips: Vec<ScanSkippedCandidate> = Vec::new();
        for r in &roots_for_scan {
            let out = scanner.scan_detailed(r);
            files.extend(out.audio_files);
            skips.extend(out.skipped_candidates);
        }
        (files, skips)
    })
    .await
    .map_err(|e| ProviderError::ScanError(format!("Rescan directory walk panicked: {e}")))?;

    if !discovery_skips.is_empty() {
        let records: Vec<RescanSkipRecord> = discovery_skips
            .into_iter()
            .map(|c| RescanSkipRecord {
                norm_path: normalize_path(&c.path),
                reason: c.reason,
                detail: c.detail,
                file_size: c.file_size,
                file_mtime: c.file_mtime,
            })
            .collect();
        progress.skipped += records.len() as u64;
        flush_rescan_skips_chunked(pool, &write_coord, &records).await;
    }

    let mut seen = HashSet::new();
    audio_files.retain(|p| seen.insert(normalize_path(p)));
    let existing_paths: HashSet<String> = audio_files.iter().map(normalize_path).collect();

    // 1. Prune missing local tracks STRICTLY per reachable root (NEVER prune offline roots!).
    let mut prune_invalidated: Vec<String> = Vec::new();
    {
        let _wg = write_coord.write_lock().await;
        for root in &roots {
            let root_str = root.to_string_lossy();
            let prune_rep = LibraryRepository::prune_missing_local_tracks(
                pool,
                Some(root_str.as_ref()),
                &existing_paths,
            )
            .await
            .map_err(db_err)?;
            report.pruned += prune_rep.tracks_pruned;
            prune_invalidated.extend(prune_rep.invalidated_artwork_paths);
        }
    }
    remove_invalidated_artwork_files(prune_invalidated).await;

    let existing_rows = LibraryRepository::list_track_file_cache_info(pool, "local")
        .await
        .map_err(db_err)?;
    let existing_cache: Arc<HashMap<String, TrackFileCacheInfo>> = Arc::new(
        existing_rows
            .into_iter()
            .map(|r| (normalize_path(&r.external_track_id), r))
            .collect(),
    );
    let mut active_skipped: HashSet<String> = IngestionRepository::list_active_skipped_paths(pool)
        .await
        .unwrap_or_default()
        .into_iter()
        .map(normalize_path)
        .collect();

    progress.total_estimated = Some(audio_files.len() as u64);
    progress.state = ScanLifecycleState::Probing;
    if let Some(tx) = progress_tx {
        let _ = tx.send(progress.clone());
    }

    let dir_batches = group_files_into_album_batches(audio_files, DB_BATCH_TRACKS);
    let mut last_emit = Instant::now();
    let mut pending_skips: Vec<RescanSkipRecord> = Vec::new();
    let mut pending_clears: Vec<String> = Vec::new();
    let mut touched_album_ids: HashSet<String> = HashSet::new();

    for batch_paths in dir_batches {
        let (probe_tx, mut probe_rx) = tokio::sync::mpsc::channel::<RescanProbeOutcome>(256);
        let cache_for_workers = existing_cache.clone();

        let producer = tokio::spawn(async move {
            let mut join_set = tokio::task::JoinSet::new();
            for file_path in batch_paths {
                while join_set.len() >= MAX_RESCAN_WORKERS {
                    let _ = join_set.join_next().await;
                }
                let tx_item = probe_tx.clone();
                let cache_ref = cache_for_workers.clone();
                join_set.spawn(async move {
                    let outcome = tokio::task::spawn_blocking(move || {
                        probe_rescan_file(file_path, &cache_ref, force)
                    })
                    .await
                    .unwrap_or_else(|e| {
                        RescanProbeOutcome::Error(RescanSkipRecord {
                            norm_path: String::new(),
                            reason: SkipReason::IoError,
                            detail: format!("Rescan worker panicked: {e}"),
                            file_size: None,
                            file_mtime: None,
                        })
                    });
                    let _ = tx_item.send(outcome).await;
                });
            }
            while join_set.join_next().await.is_some() {}
        });

        let mut chunk_to_persist: Vec<(PathBuf, ExtractedMetadata, i64, i64)> = Vec::new();
        while let Some(outcome) = probe_rx.recv().await {
            report.scanned += 1;
            progress.scanned += 1;
            match outcome {
                RescanProbeOutcome::Unchanged(norm_path) => {
                    report.unchanged_cached += 1;
                    progress.unchanged += 1;
                    progress.current_path = Some(norm_path.clone());
                    if active_skipped.remove(&norm_path) {
                        pending_clears.push(norm_path);
                    }
                }
                RescanProbeOutcome::Updated {
                    path,
                    norm_path,
                    meta,
                    mtime,
                    size,
                } => {
                    progress.current_path = Some(norm_path.clone());
                    if active_skipped.remove(&norm_path) {
                        pending_clears.push(norm_path);
                    }
                    chunk_to_persist.push((path, *meta, mtime, size));
                }
                RescanProbeOutcome::Error(rec) => {
                    report.errors.push(rec.detail.clone());
                    progress.skipped += 1;
                    if !rec.norm_path.is_empty() {
                        pending_skips.push(rec);
                    }
                }
            }
            if let Some(tx) = progress_tx {
                if last_emit.elapsed() >= PROGRESS_THROTTLE {
                    let _ = tx.send(progress.clone());
                    last_emit = Instant::now();
                }
            }
        }
        let _ = producer.await;

        if !chunk_to_persist.is_empty() {
            progress.state = ScanLifecycleState::Persisting;
            if let Some(tx) = progress_tx {
                if last_emit.elapsed() >= PROGRESS_THROTTLE {
                    let _ = tx.send(progress.clone());
                    last_emit = Instant::now();
                }
            }

            let to_map: Vec<(PathBuf, ExtractedMetadata)> = chunk_to_persist
                .iter()
                .map(|(p, m, _, _)| (p.clone(), m.clone()))
                .collect();

            let (albums, tracks, album_meta) = tokio::task::spawn_blocking(move || {
                AlbumMapper::map_scanned_items_with_metadata(
                    to_map,
                    core_types::ProviderKind::Local,
                )
            })
            .await
            .map_err(|e| ProviderError::ScanError(format!("AlbumMapper worker panicked: {e}")))??;

            let (persist_rep, batch_touched) =
                persist_provider_albums_inner(pool, &albums, &tracks, &album_meta, false).await?;
            touched_album_ids.extend(batch_touched);
            report.updated += persist_rep.tracks_upserted;
            progress.updated += persist_rep.tracks_upserted as u64;

            for cache_chunk in chunk_to_persist.chunks(DB_BATCH_TRACKS) {
                let (_wg, mut tx) = write_coord.begin_immediate(pool).await.map_err(db_err)?;
                let tx_res: Result<(), ProviderError> = async {
                    for (p, meta, mt, sz) in cache_chunk {
                        let norm = normalize_path(p);
                        LibraryRepository::update_track_source_cache_and_lyrics_tx(
                            tx.conn(),
                            "local",
                            &norm,
                            *mt,
                            *sz,
                            meta.embedded_lyrics.as_deref(),
                        )
                        .await
                        .map_err(db_err)?;
                        if let Some((tid, aid)) =
                            IngestionRepository::get_track_and_album_by_external_id_tx(
                                tx.conn(),
                                "local",
                                &norm,
                            )
                            .await
                            .map_err(db_err)?
                        {
                            let clean_label = meta
                                .record_label
                                .as_deref()
                                .map(str::trim)
                                .filter(|s| !s.is_empty());
                            LibraryRepository::update_track_record_label_tx(
                                tx.conn(),
                                &tid,
                                clean_label,
                            )
                            .await
                            .map_err(db_err)?;
                            if clean_label.is_some() {
                                LibraryRepository::update_album_record_label_tx(
                                    tx.conn(),
                                    &aid,
                                    clean_label,
                                )
                                .await
                                .map_err(db_err)?;
                            }
                        }
                        let display_path = p.to_string_lossy();
                        let _ = FolderRepository::sync_track_folder_tx(
                            tx.conn(),
                            "local",
                            &norm,
                            Some(display_path.as_ref()),
                            None,
                            false,
                            false,
                        )
                        .await
                        .map_err(db_err)?;
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
            progress.state = ScanLifecycleState::Probing;
        }
    }

    if !pending_skips.is_empty() {
        flush_rescan_skips_chunked(pool, &write_coord, &pending_skips).await;
    }
    if !pending_clears.is_empty() {
        flush_rescan_clears_chunked(pool, &write_coord, &pending_clears).await;
    }
    clear_deleted_skipped_under_roots(pool, &write_coord, &roots).await;

    let orphan_invalidated = {
        let (_wg, mut tx) = write_coord.begin_immediate(pool).await.map_err(db_err)?;
        let orphan_res: Result<_, ProviderError> = async {
            let rep =
                LibraryRepository::prune_orphan_albums_and_versions_tx(tx.conn(), Some("local"))
                    .await
                    .map_err(db_err)?;
            resolve_primaries_for_albums_tx(&mut tx, &touched_album_ids).await;
            FolderRepository::recompute_all_folder_counts_tx(tx.conn())
                .await
                .map_err(db_err)?;
            let _ = FolderRepository::prune_empty_folders_tx(tx.conn())
                .await
                .map_err(db_err)?;
            Ok(rep)
        }
        .await;
        match orphan_res {
            Ok(rep) => {
                tx.commit().await.map_err(db_err)?;
                rep.invalidated_artwork_paths
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        }
    };
    remove_invalidated_artwork_files(orphan_invalidated).await;

    if let Some(tx) = progress_tx {
        progress.state = ScanLifecycleState::Completed;
        progress.current_path = None;
        let _ = tx.send(progress);
    }
    Ok(report)
}

fn probe_rescan_file(
    file_path: PathBuf,
    cache_ref: &HashMap<String, TrackFileCacheInfo>,
    force: bool,
) -> RescanProbeOutcome {
    let norm_path = normalize_path(&file_path);
    let (file_size_opt, file_mtime_opt) = match fs::metadata(&file_path) {
        Ok(m) => {
            let mt = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            (Some(m.len()), Some(mt))
        }
        Err(e) => {
            let reason = if e.kind() == ErrorKind::PermissionDenied {
                SkipReason::PermissionDenied
            } else {
                SkipReason::IoError
            };
            return RescanProbeOutcome::Error(RescanSkipRecord {
                norm_path: norm_path.clone(),
                reason,
                detail: format!("Failed to read metadata for {norm_path}: {e}"),
                file_size: None,
                file_mtime: None,
            });
        }
    };

    let cur_size = file_size_opt.unwrap_or(0) as i64;
    let cur_mtime = file_mtime_opt.unwrap_or(0);

    let cached_info = cache_ref.get(&norm_path);
    let needs_update = force
        || cached_info.is_none()
        || cached_info.and_then(|c| c.file_mtime) != Some(cur_mtime)
        || cached_info.and_then(|c| c.file_size) != Some(cur_size);

    if !needs_update {
        return RescanProbeOutcome::Unchanged(norm_path);
    }

    match parse_audio_metadata(
        &file_path,
        ExtractOptions {
            include_pictures: false,
        },
    ) {
        Ok(meta) => RescanProbeOutcome::Updated {
            path: file_path,
            norm_path,
            meta: Box::new(meta),
            mtime: cur_mtime,
            size: cur_size,
        },
        Err(e) => RescanProbeOutcome::Error(RescanSkipRecord {
            norm_path: norm_path.clone(),
            reason: classify_probe_error(&file_path, &e),
            detail: format!("Failed to extract metadata for {norm_path}: {e}"),
            file_size: file_size_opt,
            file_mtime: file_mtime_opt,
        }),
    }
}
