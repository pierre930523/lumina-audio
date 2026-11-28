use std::collections::HashSet;
use std::path::{Path, PathBuf};

use core_db::{FolderRepository, IngestionRepository, LibraryRepository, SidecarPlaylistEntry};
use core_types::{ScanLifecycleState, ScanProgressEvent};
use tracing::warn;
use uuid::Uuid;

use super::discover::discover_root_with_progress;
use super::probe::PendingSkipRecord;
use super::{IngestionPipeline, SKIPPED_BATCH_CHUNK};
use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::cleanup::is_root_accessible;
use crate::local::ignore::{
    classify_unsupported_container, is_playlist_sidecar, should_ignore_relative_path,
};
use crate::local::playlist::parse_m3u_file;
use crate::local::scanner::{is_scannable_audio, normalize_path, read_size_mtime};

impl IngestionPipeline {
    /// Scans an entire root directory incrementally with offline-root protection,
    /// move/rename auto-relink, quarantine, multi-disc grouping, TOC signatures, and playlists.
    pub async fn scan_root(
        &self,
        root: &Path,
        provider_id: &str,
    ) -> Result<ScanProgressEvent, ProviderError> {
        self.scan_root_with_id(root, provider_id, None).await
    }

    /// Like `scan_root`, accepting an optional caller-supplied `scan_id` so async callers
    /// can correlate `ScanProgressEvent`s with their scan handle.
    pub async fn scan_root_with_id(
        &self,
        root: &Path,
        provider_id: &str,
        scan_id: Option<String>,
    ) -> Result<ScanProgressEvent, ProviderError> {
        let _scan_guard = self.scan_lock.lock().await;
        let scan_id = scan_id
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let norm_root = normalize_path(root);
        let mut progress = ScanProgressEvent {
            scan_id: scan_id.clone(),
            root_path: norm_root.clone(),
            state: ScanLifecycleState::Discovering,
            ..Default::default()
        };
        self.emit(&progress);

        // Offline root guard: NEVER prune or mark missing if the volume/share is unreachable.
        let root_buf = root.to_path_buf();
        let is_reachable = tokio::task::spawn_blocking(move || is_root_accessible(&root_buf))
            .await
            .unwrap_or(false);
        if !is_reachable {
            {
                let _wg = self.write_coord.write_lock().await;
                let _ = IngestionRepository::set_root_online_status(&self.pool, &norm_root, false)
                    .await;
                let _ = IngestionRepository::set_root_online_status(
                    &self.pool,
                    &root.to_string_lossy(),
                    false,
                )
                .await;
            }
            progress.state = ScanLifecycleState::Failed;
            progress.message = Some(format!(
                "Root directory '{}' is offline or unreachable; skipping scan without pruning",
                root.display()
            ));
            self.emit(&progress);
            return Err(ProviderError::ScanError(
                progress.message.clone().unwrap_or_default(),
            ));
        }

        {
            let _wg = self.write_coord.write_lock().await;
            let _ = IngestionRepository::set_root_online_status(&self.pool, &norm_root, true).await;
            let _ = IngestionRepository::set_root_online_status(
                &self.pool,
                &root.to_string_lossy(),
                true,
            )
            .await;
        }

        let follow_symlinks = self.config.follow_symlinks;
        let root_for_scan = root.to_path_buf();
        let progress_tx = self.progress_sender();
        let scan_id_for_disc = scan_id.clone();
        let root_label_for_disc = norm_root.clone();
        let scan_out = tokio::task::spawn_blocking(move || {
            discover_root_with_progress(
                &root_for_scan,
                follow_symlinks,
                Some(&progress_tx),
                &scan_id_for_disc,
                &root_label_for_disc,
            )
        })
        .await
        .map_err(|e| ProviderError::ScanError(format!("Directory scan worker panicked: {e}")))?;

        // Quarantine discovery-phase skipped candidates in chunked ImmediateTx batches
        if !scan_out.skipped_candidates.is_empty() {
            let discovery_skips: Vec<PendingSkipRecord> = scan_out
                .skipped_candidates
                .iter()
                .map(|cand| PendingSkipRecord {
                    norm_path: normalize_path(&cand.path),
                    reason: cand.reason,
                    detail: cand.detail.clone(),
                    file_size: cand.file_size,
                    file_mtime: cand.file_mtime,
                })
                .collect();
            progress.skipped += discovery_skips.len() as u64;
            self.flush_skipped_records_chunked(provider_id, &discovery_skips)
                .await;
        }

        let mut audio_files = scan_out.audio_files;
        audio_files.sort_by_key(|p| normalize_path(p));
        let mut seen_dedup = HashSet::with_capacity(audio_files.len());
        audio_files.retain(|p| seen_dedup.insert(normalize_path(p)));

        let seen_paths: HashSet<String> = audio_files.iter().map(normalize_path).collect();

        // Soft-mark unseen tracks under this root as 'missing' BEFORE probing so moved/renamed files
        // are immediately eligible for fingerprint relink without deleting history/favorites/overrides.
        {
            let _wg = self.write_coord.write_lock().await;
            let _ = IngestionRepository::mark_missing_local_tracks_under_root(
                &self.pool,
                provider_id,
                &norm_root,
                &seen_paths,
            )
            .await
            .map_err(db_err)?;
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
            .probe_and_persist_files(provider_id, audio_files, &mut active_skipped, &mut progress)
            .await;

        // Auto-clear skipped_files records for files deleted from disk under this online root.
        self.clear_deleted_skipped_under_root(provider_id, &norm_root)
            .await;

        // Unconditional orphan cleanup (0-track versions, empty albums, orphan canonical_tracks & artists)
        // followed by primary version resolution for all touched album groups.
        let touched_albums = match &probe_res {
            Ok(set) => set.clone(),
            Err(_) => HashSet::new(),
        };
        let prune_res = self
            .prune_orphans_and_resolve_primaries_under_write_lock(
                Some(provider_id),
                &touched_albums,
            )
            .await;
        probe_res?;
        prune_res?;

        // Parse & persist sibling .m3u / .m3u8 sidecars
        for pl_path in &scan_out.playlist_files {
            if let Err(e) = self.ingest_playlist_sidecar(provider_id, pl_path).await {
                warn!("Failed to ingest playlist {:?}: {e}", pl_path);
            }
        }

        {
            let _wg = self.write_coord.write_lock().await;
            let _ = IngestionRepository::touch_root_scan_time(&self.pool, &norm_root).await;
            let _ = IngestionRepository::touch_root_scan_time(&self.pool, &root.to_string_lossy())
                .await;
        }

        progress.state = ScanLifecycleState::Completed;
        progress.current_path = None;
        self.emit(&progress);
        Ok(progress)
    }

    /// Incrementally processes a coalesced batch of changed paths from the filesystem watcher
    /// (creations, modifications, renames, deletions) without rescanning the whole root.
    pub async fn process_changed_paths(
        &self,
        root: &Path,
        provider_id: &str,
        changed_paths: &[PathBuf],
    ) -> Result<ScanProgressEvent, ProviderError> {
        let _scan_guard = self.scan_lock.lock().await;
        let scan_id = Uuid::new_v4().to_string();
        let norm_root = normalize_path(root);
        let mut progress = ScanProgressEvent {
            scan_id: scan_id.clone(),
            root_path: norm_root.clone(),
            state: ScanLifecycleState::Discovering,
            ..Default::default()
        };

        let root_buf = root.to_path_buf();
        let is_reachable = tokio::task::spawn_blocking(move || is_root_accessible(&root_buf))
            .await
            .unwrap_or(false);
        if !is_reachable {
            {
                let _wg = self.write_coord.write_lock().await;
                let _ = IngestionRepository::set_root_online_status(&self.pool, &norm_root, false)
                    .await;
            }
            progress.state = ScanLifecycleState::Failed;
            progress.message = Some("Watched root is offline".to_string());
            self.emit(&progress);
            return Err(ProviderError::ScanError("Watched root is offline".into()));
        }

        let follow = self.config.follow_symlinks;
        let root_owned = root.to_path_buf();
        let paths_owned = changed_paths.to_vec();
        let (mut existing_audio, playlists, deleted_norm_paths, discovery_skips) =
            tokio::task::spawn_blocking(move || {
                let mut existing_audio = Vec::new();
                let mut playlists = Vec::new();
                let mut deleted_norm_paths = Vec::new();
                let mut skips = Vec::new();

                for path in &paths_owned {
                    if should_ignore_relative_path(path, &root_owned) {
                        continue;
                    }
                    if path.is_dir() {
                        let sub = discover_root_with_progress(path, follow, None, "", "");
                        for cand in sub.skipped_candidates {
                            skips.push(PendingSkipRecord {
                                norm_path: normalize_path(&cand.path),
                                reason: cand.reason,
                                detail: cand.detail,
                                file_size: cand.file_size,
                                file_mtime: cand.file_mtime,
                            });
                        }
                        existing_audio.extend(sub.audio_files);
                        playlists.extend(sub.playlist_files);
                    } else if path.is_file() {
                        if is_scannable_audio(path) {
                            existing_audio.push(path.clone());
                        } else if is_playlist_sidecar(path) {
                            playlists.push(path.clone());
                        } else if let Some(reason) = classify_unsupported_container(path) {
                            let (sz, mt) = read_size_mtime(path);
                            skips.push(PendingSkipRecord {
                                norm_path: normalize_path(path),
                                reason,
                                detail: "Unsupported audio container".to_string(),
                                file_size: sz,
                                file_mtime: mt,
                            });
                        }
                    } else {
                        deleted_norm_paths.push(normalize_path(path));
                    }
                }
                (existing_audio, playlists, deleted_norm_paths, skips)
            })
            .await
            .map_err(|e| ProviderError::ScanError(format!("Changed-path scan panicked: {e}")))?;

        if !discovery_skips.is_empty() {
            progress.skipped += discovery_skips.len() as u64;
            self.flush_skipped_records_chunked(provider_id, &discovery_skips)
                .await;
        }

        // Soft-mark deleted paths as missing first in chunked ImmediateTx under write coordinator
        if !deleted_norm_paths.is_empty() {
            let now = chrono::Utc::now().to_rfc3339();
            for chunk in deleted_norm_paths.chunks(SKIPPED_BATCH_CHUNK) {
                if let Ok((_wg, mut tx)) = self.write_coord.begin_immediate(&self.pool).await {
                    let mut ok = true;
                    for norm in chunk {
                        if IngestionRepository::mark_track_source_missing_tx(
                            tx.conn(),
                            provider_id,
                            norm,
                            &now,
                        )
                        .await
                        .is_err()
                        {
                            ok = false;
                            break;
                        }
                        if IngestionRepository::clear_skipped_for_path_tx(
                            tx.conn(),
                            provider_id,
                            norm,
                        )
                        .await
                        .is_err()
                        {
                            ok = false;
                            break;
                        }
                    }
                    if ok && provider_id.eq_ignore_ascii_case("local") {
                        if FolderRepository::recompute_all_folder_counts_tx(tx.conn())
                            .await
                            .is_err()
                        {
                            ok = false;
                        }
                    }
                    if ok {
                        let _ = tx.commit().await;
                    } else {
                        let _ = tx.rollback().await;
                    }
                }
                tokio::task::yield_now().await;
            }
        }

        existing_audio.sort_by_key(|p| normalize_path(p));
        let mut dedup = HashSet::new();
        existing_audio.retain(|p| dedup.insert(normalize_path(p)));

        let mut active_skipped: HashSet<String> =
            IngestionRepository::list_active_skipped_paths(&self.pool)
                .await
                .unwrap_or_default()
                .into_iter()
                .map(normalize_path)
                .collect();

        progress.total_estimated = Some(existing_audio.len() as u64);
        progress.state = ScanLifecycleState::Probing;
        self.emit(&progress);

        let probe_res = self
            .probe_and_persist_files(
                provider_id,
                existing_audio,
                &mut active_skipped,
                &mut progress,
            )
            .await;

        let touched_albums = match &probe_res {
            Ok(set) => set.clone(),
            Err(_) => HashSet::new(),
        };
        let prune_res = self
            .prune_orphans_and_resolve_primaries_under_write_lock(
                Some(provider_id),
                &touched_albums,
            )
            .await;
        probe_res?;
        prune_res?;

        for pl_path in &playlists {
            let _ = self.ingest_playlist_sidecar(provider_id, pl_path).await;
        }

        {
            let _wg = self.write_coord.write_lock().await;
            let _ = IngestionRepository::touch_root_scan_time(&self.pool, &norm_root).await;
        }
        progress.state = ScanLifecycleState::Completed;
        progress.current_path = None;
        self.emit(&progress);
        Ok(progress)
    }

    pub(super) async fn ingest_playlist_sidecar(
        &self,
        provider_id: &str,
        playlist_path: &Path,
    ) -> Result<(), ProviderError> {
        let p = playlist_path.to_path_buf();
        let parsed = tokio::task::spawn_blocking(move || parse_m3u_file(&p))
            .await
            .map_err(|e| ProviderError::ScanError(format!("Playlist parse panicked: {e}")))??;

        let mut entries = Vec::with_capacity(parsed.entries.len());
        for entry in parsed.entries {
            let resolved_track_source_id = if let Some(ref resolved) = entry.resolved_path {
                let norm = normalize_path(resolved);
                LibraryRepository::get_track_file_cache_info(&self.pool, provider_id, &norm)
                    .await
                    .ok()
                    .flatten()
                    .map(|info| info.track_id)
            } else {
                None
            };
            entries.push(SidecarPlaylistEntry {
                raw_entry: entry.raw_entry,
                resolved_track_source_id,
            });
        }

        let _wg = self.write_coord.write_lock().await;
        IngestionRepository::upsert_sidecar_playlist(
            &self.pool,
            provider_id,
            &parsed.source_path,
            &parsed.name,
            &entries,
        )
        .await
        .map_err(db_err)?;
        Ok(())
    }
}
