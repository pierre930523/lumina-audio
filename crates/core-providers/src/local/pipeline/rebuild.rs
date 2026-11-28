use std::collections::HashSet;
use std::path::{Path, PathBuf};

use core_db::{CatalogQueryRepository, FolderRepository, IngestionRepository, LibraryRepository};
use core_types::{ScanLifecycleState, ScanProgressEvent};
use tracing::warn;
use uuid::Uuid;

use super::discover::discover_root_with_progress;
use super::probe::PendingSkipRecord;
use super::{IngestionPipeline, remove_invalidated_artwork_files};
use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::scanner::normalize_path;

impl IngestionPipeline {
    /// Performs a full non-destructive Force Rebuild of the local library:
    /// 1. Snapshots album-level user bindings (`profile_favorites`, `metadata_overrides(user_edit)`,
    ///    `artwork_overrides`) and clears `mtime/size/hash`, `cloud_enrichment` overrides, bad MBIDs,
    ///    `artwork_cache`, and non-dismissed `skipped_files` (NEVER touching `user_edit`,
    ///    `play_history`, `playlists`, or `profile_favorites`).
    /// 2. Re-scans all watched roots (or parent dirs of existing local tracks if no watched roots
    ///    are registered) with `force_full = true` in 200-track directory-aligned batches,
    ///    preserving every `track_sources.id` in place.
    /// 3. Finalizes atomically under `DbWriteCoordinator`: remaps album-level user bindings,
    ///    re-resolves `playlist_items`, purges missing tracks (preserving play_history tombstones),
    ///    prunes all 0-track versions / empty albums / orphan canonical_tracks / orphan artists,
    ///    and rebuilds `search_fts`.
    pub async fn force_rebuild_library(
        &self,
        dir_or_null: Option<&str>,
        scan_id: Option<String>,
    ) -> Result<ScanProgressEvent, ProviderError> {
        let _scan_guard = self.scan_lock.lock().await;
        let scan_id = scan_id
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let root_label = dir_or_null
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(normalize_path)
            .unwrap_or_else(|| "local".to_string());

        let mut progress = ScanProgressEvent {
            scan_id: scan_id.clone(),
            root_path: root_label.clone(),
            state: ScanLifecycleState::Discovering,
            ..Default::default()
        };
        self.emit(&progress);

        let roots = match self.resolve_rebuild_roots(dir_or_null).await {
            Ok(r) => r,
            Err(err) => {
                progress.state = ScanLifecycleState::Failed;
                progress.message = Some(err.to_string());
                self.emit(&progress);
                return Err(err);
            }
        };

        // Phase 1: Snapshot user album bindings & prepare DB under single-writer ImmediateTx.
        let (snapshot, prep_invalidated_paths) = {
            let (_wg, mut tx) = self
                .write_coord
                .begin_immediate(&self.pool)
                .await
                .map_err(db_err)?;
            let res: Result<_, ProviderError> = async {
                let snap = LibraryRepository::snapshot_album_user_bindings_tx(tx.conn())
                    .await
                    .map_err(db_err)?;
                let prep = LibraryRepository::prepare_force_rebuild_tx(tx.conn())
                    .await
                    .map_err(db_err)?;
                Ok((snap, prep.invalidated_artwork_paths))
            }
            .await;
            match res {
                Ok(out) => {
                    tx.commit().await.map_err(db_err)?;
                    out
                }
                Err(e) => {
                    let _ = tx.rollback().await;
                    progress.state = ScanLifecycleState::Failed;
                    progress.message = Some(e.to_string());
                    self.emit(&progress);
                    return Err(e);
                }
            }
        };
        remove_invalidated_artwork_files(prep_invalidated_paths).await;

        // Phase 2: Discover all files across roots with throttled Discovering progress.
        let follow_symlinks = self.config.follow_symlinks;
        let roots_for_scan = roots.clone();
        let progress_tx = self.progress_sender();
        let scan_id_for_disc = scan_id.clone();
        let root_label_for_disc = root_label.clone();

        let (mut audio_files, playlist_files, discovery_skips) =
            tokio::task::spawn_blocking(move || {
                let mut all_audio = Vec::new();
                let mut all_playlists = Vec::new();
                let mut all_skips = Vec::new();
                for root in &roots_for_scan {
                    let out = discover_root_with_progress(
                        root,
                        follow_symlinks,
                        Some(&progress_tx),
                        &scan_id_for_disc,
                        &root_label_for_disc,
                    );
                    all_audio.extend(out.audio_files);
                    all_playlists.extend(out.playlist_files);
                    for cand in out.skipped_candidates {
                        all_skips.push(PendingSkipRecord {
                            norm_path: normalize_path(&cand.path),
                            reason: cand.reason,
                            detail: cand.detail,
                            file_size: cand.file_size,
                            file_mtime: cand.file_mtime,
                        });
                    }
                }
                (all_audio, all_playlists, all_skips)
            })
            .await
            .map_err(|e| {
                ProviderError::ScanError(format!("Force rebuild discovery panicked: {e}"))
            })?;

        if !discovery_skips.is_empty() {
            progress.skipped += discovery_skips.len() as u64;
            self.flush_skipped_records_chunked("local", &discovery_skips)
                .await;
        }

        audio_files.sort_by_key(|p| normalize_path(p));
        let mut seen_dedup = HashSet::with_capacity(audio_files.len());
        audio_files.retain(|p| seen_dedup.insert(normalize_path(p)));
        let seen_paths: HashSet<String> = audio_files.iter().map(normalize_path).collect();

        // Mark unseen tracks under each scanned root as missing BEFORE forced probing so moved
        // files can still fingerprint-relink in place.
        {
            let _wg = self.write_coord.write_lock().await;
            for root in &roots {
                let norm_root = normalize_path(root);
                let _ = IngestionRepository::mark_missing_local_tracks_under_root(
                    &self.pool,
                    "local",
                    &norm_root,
                    &seen_paths,
                )
                .await
                .map_err(db_err)?;
            }
        }

        let mut active_skipped: HashSet<String> =
            IngestionRepository::list_active_skipped_paths(&self.pool)
                .await
                .unwrap_or_default()
                .into_iter()
                .map(normalize_path)
                .collect();

        progress.total_estimated = Some(audio_files.len() as u64);
        progress.state = ScanLifecycleState::Probing;
        self.emit(&progress);

        let probe_res = self
            .probe_and_persist_files_with_options(
                "local",
                audio_files,
                true,
                &mut active_skipped,
                &mut progress,
            )
            .await;

        if let Err(err) = probe_res {
            let _ = self.prune_orphans_under_write_lock(None).await;
            progress.state = ScanLifecycleState::Failed;
            progress.message = Some(err.to_string());
            self.emit(&progress);
            return Err(err);
        }

        for pl_path in &playlist_files {
            if let Err(e) = self.ingest_playlist_sidecar("local", pl_path).await {
                warn!(
                    "Failed to ingest playlist {:?} during force rebuild: {e}",
                    pl_path
                );
            }
        }

        // Phase 3: Finalize atomically under DbWriteCoordinator (remap album bindings, re-resolve
        // playlist_items, purge missing tracks keeping play_history tombstones, prune all orphans,
        // rebuild search_fts).
        let finalize_invalidated = {
            let (_wg, mut tx) = self
                .write_coord
                .begin_immediate(&self.pool)
                .await
                .map_err(db_err)?;
            let res: Result<_, ProviderError> = async {
                let rep = LibraryRepository::finalize_force_rebuild_tx(tx.conn(), &snapshot)
                    .await
                    .map_err(db_err)?;
                FolderRepository::recompute_all_folder_counts_tx(tx.conn())
                    .await
                    .map_err(db_err)?;
                let _ = FolderRepository::prune_empty_folders_tx(tx.conn())
                    .await
                    .map_err(db_err)?;
                Ok(rep)
            }
            .await;
            match res {
                Ok(rep) => {
                    tx.commit().await.map_err(db_err)?;
                    rep.orphans.invalidated_artwork_paths
                }
                Err(e) => {
                    let _ = tx.rollback().await;
                    progress.state = ScanLifecycleState::Failed;
                    progress.message = Some(e.to_string());
                    self.emit(&progress);
                    return Err(e);
                }
            }
        };
        remove_invalidated_artwork_files(finalize_invalidated).await;

        {
            let _wg = self.write_coord.write_lock().await;
            for root in &roots {
                let norm_root = normalize_path(root);
                let _ = IngestionRepository::touch_root_scan_time(&self.pool, &norm_root).await;
                let _ =
                    IngestionRepository::touch_root_scan_time(&self.pool, &root.to_string_lossy())
                        .await;
            }
        }

        progress.state = ScanLifecycleState::Completed;
        progress.current_path = None;
        self.emit(&progress);
        Ok(progress)
    }

    async fn resolve_rebuild_roots(
        &self,
        dir_or_null: Option<&str>,
    ) -> Result<Vec<PathBuf>, ProviderError> {
        if let Some(dir) = dir_or_null.map(str::trim).filter(|s| !s.is_empty()) {
            let p = PathBuf::from(dir);
            let p_check = p.clone();
            let reachable =
                tokio::task::spawn_blocking(move || p_check.exists() && p_check.is_dir())
                    .await
                    .unwrap_or(false);
            if !reachable {
                return Err(ProviderError::ScanError(format!(
                    "Root directory '{dir}' is offline or unreachable; skipping force rebuild"
                )));
            }
            return Ok(vec![p]);
        }

        let watched = IngestionRepository::list_watched_roots(&self.pool)
            .await
            .map_err(db_err)?;
        let mut all_candidates: Vec<PathBuf> = watched
            .into_iter()
            .filter(|r| r.provider_id.eq_ignore_ascii_case("local"))
            .map(|r| PathBuf::from(r.root_path))
            .collect();

        let track_paths =
            CatalogQueryRepository::list_distinct_external_track_ids(&self.pool, "local")
                .await
                .map_err(db_err)?;
        let mut track_dirs: HashSet<PathBuf> = HashSet::new();
        for p_str in track_paths {
            if let Some(parent) = Path::new(&p_str).parent() {
                track_dirs.insert(parent.to_path_buf());
            }
        }
        all_candidates.extend(track_dirs);
        let candidate_roots = deduplicate_nested_roots(all_candidates);

        if candidate_roots.is_empty() {
            return Ok(Vec::new());
        }

        let candidates_check = candidate_roots.clone();
        let reachable: Vec<PathBuf> = tokio::task::spawn_blocking(move || {
            candidates_check
                .into_iter()
                .filter(|d| d.exists() && d.is_dir())
                .collect()
        })
        .await
        .unwrap_or_default();

        if reachable.is_empty() {
            return Err(ProviderError::ScanError(
                "All known local library directories are currently offline; skipping force rebuild"
                    .to_string(),
            ));
        }
        Ok(reachable)
    }
}

/// Keeps only top-level unique roots when one root is an ancestor of another.
fn deduplicate_nested_roots(mut roots: Vec<PathBuf>) -> Vec<PathBuf> {
    roots.sort_by_key(|p| {
        let norm = normalize_path(p);
        (norm.len(), norm)
    });
    let mut kept: Vec<(String, PathBuf)> = Vec::new();
    for p in roots {
        let norm = normalize_path(&p).trim_end_matches('/').to_string();
        if norm.is_empty() {
            continue;
        }
        let is_child = kept
            .iter()
            .any(|(parent, _)| norm == *parent || norm.starts_with(&format!("{parent}/")));
        if !is_child {
            kept.push((norm, p));
        }
    }
    kept.into_iter().map(|(_, p)| p).collect()
}
