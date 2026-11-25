use std::collections::{HashMap, HashSet};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use core_db::{
    normalize_match_key, sync_album_fts, sync_artist_fts, sync_track_fts, IngestionRepository,
    LibraryRepository, SidecarPlaylistEntry, SqlitePool, TrackFileCacheInfo,
};
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ContentFingerprint,
    ExternalCatalogIngestBatch, ProviderKind, ScanLifecycleState, ScanProgressEvent, SkipReason,
    TocSignature, TrackSource,
};
use tokio::sync::{broadcast, mpsc, Semaphore};
use tracing::warn;
use uuid::Uuid;

use super::fingerprint::compute_content_fingerprint;
use super::ignore::{
    classify_unsupported_container, is_playlist_sidecar, should_ignore_relative_path,
};
use super::mapper::{extract_edition_label, AlbumMapper, AlbumSyncMetadata, VersionSyncMetadata};
use super::metadata::{
    detect_garbled_tags, split_artists, ExtractOptions, ExtractedMetadata, MetadataExtractor,
};
use super::playlist::parse_m3u_file;
use super::scanner::{is_scannable_audio, normalize_path, read_size_mtime, DirectoryScanner};
use crate::error::ProviderError;
use crate::library::{db_err, LibrarySyncService, SyncPersistReport};

#[derive(Debug, Clone)]
pub struct IngestionConfig {
    pub max_concurrency: usize,
    pub batch_size: usize,
    pub follow_symlinks: bool,
}

impl Default for IngestionConfig {
    fn default() -> Self {
        Self {
            max_concurrency: 4,
            batch_size: 100,
            follow_symlinks: false,
        }
    }
}

struct ProbedTrackItem {
    path: PathBuf,
    norm_path: String,
    meta: ExtractedMetadata,
    fingerprint: ContentFingerprint,
    file_mtime: i64,
    file_size: i64,
    garbled_reason: Option<String>,
}

enum ProbeMessage {
    Ready(Box<ProbedTrackItem>),
    Skipped {
        norm_path: String,
        reason: SkipReason,
        detail: String,
        file_size: Option<u64>,
        file_mtime: Option<i64>,
    },
    Unchanged(String),
}

/// High-throughput, bounded-concurrency ingestion pipeline for local and mounted storage.
///
/// Features:
/// - Offline root guard (never prunes or marks tracks missing when a drive/share is offline)
/// - Bounded `Semaphore` + `spawn_blocking` worker pool with backpressure (`mpsc::channel(256)`)
/// - Tag-independent content fingerprint move/rename auto-relink (preserving history/favorites/overrides)
/// - Structured `skipped_files` quarantine (corrupt, permission, unsupported, garbled)
/// - Chunked SQLite persistence + incremental FTS sync + broadcast `ScanProgressEvent` stream
#[derive(Clone)]
pub struct IngestionPipeline {
    pool: SqlitePool,
    config: IngestionConfig,
    progress_tx: broadcast::Sender<ScanProgressEvent>,
}

impl IngestionPipeline {
    pub fn new(pool: SqlitePool, config: IngestionConfig) -> Self {
        let (progress_tx, _) = broadcast::channel(512);
        Self {
            pool,
            config: IngestionConfig {
                max_concurrency: config.max_concurrency.clamp(2, 8),
                batch_size: config.batch_size.clamp(1, 500),
                follow_symlinks: config.follow_symlinks,
            },
            progress_tx,
        }
    }

    pub fn with_defaults(pool: SqlitePool) -> Self {
        Self::new(pool, IngestionConfig::default())
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub fn subscribe_progress(&self) -> broadcast::Receiver<ScanProgressEvent> {
        self.progress_tx.subscribe()
    }

    pub fn progress_sender(&self) -> broadcast::Sender<ScanProgressEvent> {
        self.progress_tx.clone()
    }

    fn emit(&self, event: &ScanProgressEvent) {
        let _ = self.progress_tx.send(event.clone());
    }

    /// Scans an entire root directory incrementally with offline-root protection,
    /// move/rename auto-relink, quarantine, multi-disc grouping, TOC signatures, and playlists.
    pub async fn scan_root(
        &self,
        root: &Path,
        provider_id: &str,
    ) -> Result<ScanProgressEvent, ProviderError> {
        let scan_id = Uuid::new_v4().to_string();
        let norm_root = normalize_path(root);
        let mut progress = ScanProgressEvent {
            scan_id,
            root_path: norm_root.clone(),
            state: ScanLifecycleState::Discovering,
            ..Default::default()
        };
        self.emit(&progress);

        // Offline root guard: NEVER prune or mark missing if the volume/share is unreachable.
        let root_buf = root.to_path_buf();
        let is_reachable = tokio::task::spawn_blocking(move || root_buf.exists() && root_buf.is_dir())
            .await
            .unwrap_or(false);
        if !is_reachable {
            let _ = IngestionRepository::set_root_online_status(&self.pool, &norm_root, false).await;
            let _ = IngestionRepository::set_root_online_status(
                &self.pool,
                &root.to_string_lossy(),
                false,
            )
            .await;
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

        let _ = IngestionRepository::set_root_online_status(&self.pool, &norm_root, true).await;
        let _ = IngestionRepository::set_root_online_status(
            &self.pool,
            &root.to_string_lossy(),
            true,
        )
        .await;

        let follow_symlinks = self.config.follow_symlinks;
        let root_for_scan = root.to_path_buf();
        let scan_out = tokio::task::spawn_blocking(move || {
            let mut scanner = DirectoryScanner::new(follow_symlinks);
            scanner.scan_detailed(&root_for_scan)
        })
        .await
        .map_err(|e| ProviderError::ScanError(format!("Directory scan worker panicked: {e}")))?;

        // Quarantine discovery-phase skipped candidates (permission errors, .cue/.iso, unsupported)
        for cand in &scan_out.skipped_candidates {
            let norm = normalize_path(&cand.path);
            let _ = IngestionRepository::record_skipped_file(
                &self.pool,
                provider_id,
                &norm,
                cand.reason,
                &cand.detail,
                cand.file_size,
                cand.file_mtime,
            )
            .await;
            progress.skipped += 1;
        }

        let mut audio_files = scan_out.audio_files;
        // Sort by normalized path so tracks of the same album/multi-disc folder land in the same batch.
        audio_files.sort_by_key(|p| normalize_path(p));
        let mut seen_dedup = HashSet::with_capacity(audio_files.len());
        audio_files.retain(|p| seen_dedup.insert(normalize_path(p)));

        let seen_paths: HashSet<String> = audio_files.iter().map(normalize_path).collect();

        // Soft-mark unseen tracks under this root as 'missing' BEFORE probing so moved/renamed files
        // are immediately eligible for fingerprint relink without deleting history/favorites/overrides.
        let _ = IngestionRepository::mark_missing_local_tracks_under_root(
            &self.pool,
            provider_id,
            &norm_root,
            &seen_paths,
        )
        .await
        .map_err(db_err)?;

        progress.total_estimated = Some(audio_files.len() as u64);
        progress.state = ScanLifecycleState::Probing;
        self.emit(&progress);

        self.probe_and_persist_files(provider_id, audio_files, &mut progress)
            .await?;

        // Parse & persist sibling .m3u / .m3u8 sidecars
        for pl_path in &scan_out.playlist_files {
            if let Err(e) = self.ingest_playlist_sidecar(provider_id, pl_path).await {
                warn!("Failed to ingest playlist {:?}: {e}", pl_path);
            }
        }

        let _ = IngestionRepository::touch_root_scan_time(&self.pool, &norm_root).await;
        let _ = IngestionRepository::touch_root_scan_time(
            &self.pool,
            &root.to_string_lossy(),
        )
        .await;

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
        let scan_id = Uuid::new_v4().to_string();
        let norm_root = normalize_path(root);
        let mut progress = ScanProgressEvent {
            scan_id,
            root_path: norm_root.clone(),
            state: ScanLifecycleState::Discovering,
            ..Default::default()
        };

        let root_buf = root.to_path_buf();
        let is_reachable = tokio::task::spawn_blocking(move || root_buf.exists() && root_buf.is_dir())
            .await
            .unwrap_or(false);
        if !is_reachable {
            let _ = IngestionRepository::set_root_online_status(&self.pool, &norm_root, false).await;
            progress.state = ScanLifecycleState::Failed;
            progress.message = Some("Watched root is offline".to_string());
            self.emit(&progress);
            return Err(ProviderError::ScanError("Watched root is offline".into()));
        }

        let mut existing_audio = Vec::new();
        let mut playlists = Vec::new();
        let mut deleted_norm_paths = Vec::new();

        for path in changed_paths {
            if should_ignore_relative_path(path, root) {
                continue;
            }
            if path.is_dir() {
                let follow = self.config.follow_symlinks;
                let dir_clone = path.clone();
                if let Ok(sub) = tokio::task::spawn_blocking(move || {
                    DirectoryScanner::new(follow).scan_detailed(&dir_clone)
                })
                .await
                {
                    for cand in sub.skipped_candidates {
                        let norm = normalize_path(&cand.path);
                        let _ = IngestionRepository::record_skipped_file(
                            &self.pool,
                            provider_id,
                            &norm,
                            cand.reason,
                            &cand.detail,
                            cand.file_size,
                            cand.file_mtime,
                        )
                        .await;
                        progress.skipped += 1;
                    }
                    existing_audio.extend(sub.audio_files);
                    playlists.extend(sub.playlist_files);
                }
            } else if path.is_file() {
                if is_scannable_audio(path) {
                    existing_audio.push(path.clone());
                } else if is_playlist_sidecar(path) {
                    playlists.push(path.clone());
                } else if let Some(reason) = classify_unsupported_container(path) {
                    let (sz, mt) = read_size_mtime(path);
                    let norm = normalize_path(path);
                    let _ = IngestionRepository::record_skipped_file(
                        &self.pool,
                        provider_id,
                        &norm,
                        reason,
                        "Unsupported audio container",
                        sz,
                        mt,
                    )
                    .await;
                    progress.skipped += 1;
                }
            } else {
                deleted_norm_paths.push(normalize_path(path));
            }
        }

        // Soft-mark deleted paths as missing first so renamed target paths can relink immediately
        let now = chrono::Utc::now().to_rfc3339();
        for norm in &deleted_norm_paths {
            let _ = sqlx::query(
                "UPDATE track_sources SET file_status = 'missing', missing_since = COALESCE(missing_since, ?) \
                 WHERE provider_id = ? AND external_track_id = ?",
            )
            .bind(&now)
            .bind(provider_id)
            .bind(norm)
            .execute(&self.pool)
            .await;
        }

        existing_audio.sort_by_key(|p| normalize_path(p));
        let mut dedup = HashSet::new();
        existing_audio.retain(|p| dedup.insert(normalize_path(p)));

        progress.total_estimated = Some(existing_audio.len() as u64);
        progress.state = ScanLifecycleState::Probing;
        self.emit(&progress);

        self.probe_and_persist_files(provider_id, existing_audio, &mut progress)
            .await?;

        for pl_path in &playlists {
            let _ = self.ingest_playlist_sidecar(provider_id, pl_path).await;
        }

        let _ = IngestionRepository::touch_root_scan_time(&self.pool, &norm_root).await;
        progress.state = ScanLifecycleState::Completed;
        progress.current_path = None;
        self.emit(&progress);
        Ok(progress)
    }

    async fn probe_and_persist_files(
        &self,
        provider_id: &str,
        audio_files: Vec<PathBuf>,
        progress: &mut ScanProgressEvent,
    ) -> Result<(), ProviderError> {
        let existing_rows = LibraryRepository::list_track_file_cache_info(&self.pool, provider_id)
            .await
            .map_err(db_err)?;
        let existing_cache: Arc<HashMap<String, TrackFileCacheInfo>> = Arc::new(
            existing_rows
                .into_iter()
                .map(|r| (normalize_path(&r.external_track_id), r))
                .collect(),
        );

        let (tx, mut rx) = mpsc::channel::<ProbeMessage>(256);
        let sem = Arc::new(Semaphore::new(self.config.max_concurrency));
        let existing_for_producer = existing_cache.clone();

        let producer = tokio::spawn(async move {
            let mut join_set = tokio::task::JoinSet::new();
            for path in audio_files {
                let Ok(permit) = sem.clone().acquire_owned().await else {
                    break;
                };
                let tx_item = tx.clone();
                let cache_ref = existing_for_producer.clone();

                join_set.spawn(async move {
                    let _permit = permit;
                    let msg = tokio::task::spawn_blocking(move || probe_single_file(path, &cache_ref))
                        .await
                        .unwrap_or_else(|e| ProbeMessage::Skipped {
                            norm_path: String::new(),
                            reason: SkipReason::IoError,
                            detail: format!("Probe worker panicked: {e}"),
                            file_size: None,
                            file_mtime: None,
                        });
                    let _ = tx_item.send(msg).await;
                });
            }
            while join_set.join_next().await.is_some() {}
        });

        let mut pending_batch: Vec<ProbedTrackItem> = Vec::with_capacity(self.config.batch_size);
        let mut since_last_emit = 0u64;

        while let Some(msg) = rx.recv().await {
            progress.scanned += 1;
            since_last_emit += 1;

            match msg {
                ProbeMessage::Unchanged(norm_path) => {
                    progress.unchanged += 1;
                    progress.current_path = Some(norm_path.clone());
                    let _ = IngestionRepository::clear_skipped_for_path(
                        &self.pool,
                        provider_id,
                        &norm_path,
                    )
                    .await;
                }
                ProbeMessage::Skipped {
                    norm_path,
                    reason,
                    detail,
                    file_size,
                    file_mtime,
                } => {
                    progress.skipped += 1;
                    progress.current_path = Some(norm_path.clone());
                    if !norm_path.is_empty() {
                        let _ = IngestionRepository::record_skipped_file(
                            &self.pool,
                            provider_id,
                            &norm_path,
                            reason,
                            &detail,
                            file_size,
                            file_mtime,
                        )
                        .await;
                    }
                }
                ProbeMessage::Ready(item) => {
                    progress.current_path = Some(item.norm_path.clone());
                    pending_batch.push(*item);
                    if pending_batch.len() >= self.config.batch_size {
                        progress.state = ScanLifecycleState::Persisting;
                        self.emit(progress);
                        let batch = std::mem::take(&mut pending_batch);
                        self.persist_probed_batch(provider_id, batch, &existing_cache, progress)
                            .await?;
                        progress.state = ScanLifecycleState::Probing;
                    }
                }
            }

            if since_last_emit >= 16 {
                self.emit(progress);
                since_last_emit = 0;
            }
        }

        let _ = producer.await;

        if !pending_batch.is_empty() {
            progress.state = ScanLifecycleState::Persisting;
            self.emit(progress);
            self.persist_probed_batch(provider_id, pending_batch, &existing_cache, progress)
                .await?;
        }

        Ok(())
    }

    async fn persist_probed_batch(
        &self,
        provider_id: &str,
        batch: Vec<ProbedTrackItem>,
        existing_cache: &HashMap<String, TrackFileCacheInfo>,
        progress: &mut ScanProgressEvent,
    ) -> Result<(), ProviderError> {
        if batch.is_empty() {
            return Ok(());
        }

        let provider_kind = provider_id
            .parse::<ProviderKind>()
            .unwrap_or(ProviderKind::Local);

        let mut item_by_norm: HashMap<String, ProbedTrackItem> = HashMap::with_capacity(batch.len());
        let mut to_map: Vec<(PathBuf, ExtractedMetadata)> = Vec::with_capacity(batch.len());
        for item in batch {
            to_map.push((item.path.clone(), item.meta.clone()));
            item_by_norm.insert(item.norm_path.clone(), item);
        }

        let (albums, tracks, album_meta) =
            AlbumMapper::map_scanned_items_with_metadata(to_map, provider_kind)?;

        let mut tracks_by_version: HashMap<&str, Vec<&TrackSource>> = HashMap::new();
        for trk in &tracks {
            tracks_by_version
                .entry(trk.version_id.as_str())
                .or_default()
                .push(trk);
        }

        let mut fts_artists: Vec<(String, String, Option<String>)> = Vec::new();
        let mut fts_albums: Vec<(String, String, Option<String>, Option<i32>)> = Vec::new();
        let mut fts_tracks: Vec<(String, String, Option<String>, Option<String>)> = Vec::new();
        let mut touched_version_ids: HashSet<String> = HashSet::new();

        for album in &albums {
            let artist_name = if album.artist_name.trim().is_empty() {
                "Unknown Artist"
            } else {
                album.artist_name.trim()
            };
            let artist = LibraryRepository::upsert_artist_by_mbid_or_name(
                &self.pool,
                artist_name,
                None,
                None,
                None,
            )
            .await
            .map_err(db_err)?;
            fts_artists.push((artist.id.clone(), artist.name.clone(), artist.biography.clone()));

            let target_album_id = self
                .resolve_or_insert_canonical_album(album, &artist.id, &tracks_by_version, &album_meta)
                .await?;
            fts_albums.push((
                target_album_id.clone(),
                album.title.clone(),
                Some(artist.name.clone()),
                album.release_year,
            ));

            let existing_versions =
                LibraryRepository::list_versions_for_album(&self.pool, &target_album_id)
                    .await
                    .map_err(db_err)?;

            for ver in &album.versions {
                let mut ver_to_save = ver.clone();
                ver_to_save.canonical_album_id = target_album_id.clone();
                if let Some(matched) = existing_versions
                    .iter()
                    .find(|v| v.provider == ver.provider && v.external_album_id == ver.external_album_id)
                {
                    ver_to_save.id = matched.id.clone();
                }

                LibraryRepository::insert_album_version(&self.pool, &ver_to_save)
                    .await
                    .map_err(db_err)?;

                let authoritative_ver_id =
                    LibraryRepository::list_versions_for_album(&self.pool, &target_album_id)
                        .await
                        .map_err(db_err)?
                        .into_iter()
                        .find(|v| {
                            v.provider == ver.provider
                                && v.external_album_id == ver.external_album_id
                        })
                        .map(|v| v.id)
                        .unwrap_or_else(|| ver_to_save.id.clone());

                touched_version_ids.insert(authoritative_ver_id.clone());

                if let Some(ver_tracks) = tracks_by_version.get(ver.id.as_str()) {
                    for track in ver_tracks {
                        let mut trk = (*track).clone();
                        trk.version_id = authoritative_ver_id.clone();
                        let norm_path = normalize_path(&trk.external_track_id);
                        let Some(probed) = item_by_norm.get(&norm_path) else {
                            continue;
                        };

                        if let Some(ref garbled) = probed.garbled_reason {
                            let _ = IngestionRepository::record_skipped_file(
                                &self.pool,
                                provider_id,
                                &norm_path,
                                SkipReason::GarbledTags,
                                garbled,
                                Some(probed.file_size.max(0) as u64),
                                Some(probed.file_mtime),
                            )
                            .await;
                            progress.skipped += 1;
                        } else {
                            let _ = IngestionRepository::clear_skipped_for_path(
                                &self.pool,
                                provider_id,
                                &norm_path,
                            )
                            .await;
                        }

                        let already_at_path = existing_cache.contains_key(&norm_path);
                        let mut persisted_id: Option<String> = None;

                        if !already_at_path {
                            if let Ok(Some(cand)) =
                                IngestionRepository::find_relink_candidate_by_fingerprint(
                                    &self.pool,
                                    provider_id,
                                    &probed.fingerprint.hash_hex,
                                    probed.fingerprint.audio_byte_len,
                                    &norm_path,
                                )
                                .await
                            {
                                if IngestionRepository::relink_moved_track_source(
                                    &self.pool,
                                    &cand.track_source_id,
                                    &norm_path,
                                    &authoritative_ver_id,
                                    Some(probed.file_mtime),
                                    Some(probed.file_size),
                                )
                                .await
                                .map_err(db_err)?
                                {
                                    // Refresh non-destructive base tag fields on the relinked row
                                    let _ = LibraryRepository::upsert_track_source_with_cache(
                                        &self.pool,
                                        &trk,
                                        probed.meta.embedded_lyrics.as_deref(),
                                        Some(probed.file_mtime),
                                        Some(probed.file_size),
                                        Some(&probed.fingerprint.hash_hex),
                                    )
                                    .await
                                    .map_err(db_err)?;
                                    let _ = IngestionRepository::update_track_fingerprint(
                                        &self.pool,
                                        &cand.track_source_id,
                                        &probed.fingerprint.hash_hex,
                                        probed.fingerprint.audio_byte_len,
                                    )
                                    .await;
                                    persisted_id = Some(cand.track_source_id);
                                    progress.updated += 1;
                                }
                            }
                        }

                        let final_track_id = if let Some(pid) = persisted_id {
                            pid
                        } else {
                            let saved = LibraryRepository::upsert_track_source_with_cache(
                                &self.pool,
                                &trk,
                                probed.meta.embedded_lyrics.as_deref(),
                                Some(probed.file_mtime),
                                Some(probed.file_size),
                                Some(&probed.fingerprint.hash_hex),
                            )
                            .await
                            .map_err(db_err)?;
                            let _ = IngestionRepository::update_track_fingerprint(
                                &self.pool,
                                &saved.id,
                                &probed.fingerprint.hash_hex,
                                probed.fingerprint.audio_byte_len,
                            )
                            .await;
                            if already_at_path {
                                progress.updated += 1;
                            } else {
                                progress.added += 1;
                            }
                            saved.id
                        };

                        let artists_list = if probed.meta.artists.is_empty() {
                            split_artists(&probed.meta.artist)
                        } else {
                            probed.meta.artists.clone()
                        };
                        let _ = IngestionRepository::upsert_canonical_track_for_source(
                            &self.pool,
                            &final_track_id,
                            &target_album_id,
                            &trk,
                            &artists_list,
                        )
                        .await;

                        fts_tracks.push((
                            final_track_id,
                            trk.title.clone(),
                            trk.artist_name.clone().or_else(|| Some(artist.name.clone())),
                            Some(album.title.clone()),
                        ));
                    }
                }
            }
        }

        // Recompute accurate TOC signature across all persisted tracks for each touched version
        for ver_id in touched_version_ids {
            if let Ok(ver_tracks) = LibraryRepository::find_track_sources_by_version(&self.pool, &ver_id).await {
                if !ver_tracks.is_empty() {
                    let max_disc = ver_tracks.iter().map(|t| u32::from(t.disc_number)).max().unwrap_or(1);
                    let distinct_discs: HashSet<u16> = ver_tracks.iter().map(|t| t.disc_number).collect();
                    let disc_count = max_disc.max(distinct_discs.len() as u32).max(1);
                    let durations: Vec<u64> = ver_tracks.iter().map(|t| t.duration_ms).collect();
                    let toc = TocSignature::from_durations(disc_count, durations);
                    let _ = IngestionRepository::update_album_version_toc(
                        &self.pool,
                        &ver_id,
                        &toc.digest,
                        disc_count,
                        toc.track_count,
                    )
                    .await;
                }
            }
        }

        // Incremental FTS5 synchronization in a single transaction (no full index wipe!)
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        let fts_res: core_db::Result<()> = async {
            let mut seen_art = HashSet::new();
            for (aid, name, bio) in &fts_artists {
                if seen_art.insert(aid.as_str()) {
                    sync_artist_fts(&mut tx, aid, name, bio.as_deref()).await?;
                }
            }
            let mut seen_alb = HashSet::new();
            for (alb_id, title, art_name, yr) in &fts_albums {
                if seen_alb.insert(alb_id.as_str()) {
                    sync_album_fts(&mut tx, alb_id, title, art_name.as_deref(), *yr).await?;
                }
            }
            for (tid, title, art_name, alb_title) in &fts_tracks {
                sync_track_fts(
                    &mut tx,
                    tid,
                    title,
                    art_name.as_deref(),
                    alb_title.as_deref(),
                )
                .await?;
            }
            Ok(())
        }
        .await;

        match fts_res {
            Ok(()) => tx.commit().await.map_err(db_err)?,
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(db_err(e));
            }
        }

        Ok(())
    }

    async fn resolve_or_insert_canonical_album(
        &self,
        album: &CanonicalAlbum,
        artist_id: &str,
        tracks_by_version: &HashMap<&str, Vec<&TrackSource>>,
        album_meta: &HashMap<String, AlbumSyncMetadata>,
    ) -> Result<String, ProviderError> {
        let artist_name = if album.artist_name.trim().is_empty() {
            "Unknown Artist"
        } else {
            album.artist_name.trim()
        };

        let mut album_isrcs: Vec<String> = Vec::new();
        for ver in &album.versions {
            if let Some(ver_tracks) = tracks_by_version.get(ver.id.as_str()) {
                for t in ver_tracks {
                    if let Some(ref isrc) = t.isrc {
                        let clean = isrc.trim();
                        if !clean.is_empty() {
                            album_isrcs.push(clean.to_string());
                        }
                    }
                }
            }
        }

        let upc = album_meta
            .get(&album.id)
            .and_then(|m| m.upc.as_deref())
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let mb_rg_id = album
            .musicbrainz_release_group_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());

        let (base_title, _) = extract_edition_label(&album.title);
        let norm_title = normalize_match_key(&base_title);
        let norm_artist = normalize_match_key(artist_name);
        let is_unknown = norm_title.is_empty()
            || norm_artist.is_empty()
            || norm_title == "unknown album"
            || norm_artist == "unknown artist";

        let mut candidate_ids: Vec<String> = Vec::new();
        let mut seen_candidates: HashSet<String> = HashSet::new();

        if let Some(rg) = mb_rg_id {
            if let Some(found) =
                LibraryRepository::find_canonical_album_by_mb_release_group(&self.pool, rg)
                    .await
                    .map_err(db_err)?
            {
                if seen_candidates.insert(found.id.clone()) {
                    candidate_ids.push(found.id);
                }
            }
        }
        if let Some(u) = upc {
            if let Some(found) = LibraryRepository::find_canonical_album_by_upc(&self.pool, u)
                .await
                .map_err(db_err)?
            {
                if seen_candidates.insert(found.id.clone()) {
                    candidate_ids.push(found.id);
                }
            }
        }
        if !album_isrcs.is_empty() {
            for id in LibraryRepository::find_canonical_album_ids_by_isrcs(&self.pool, &album_isrcs)
                .await
                .map_err(db_err)?
            {
                if seen_candidates.insert(id.clone()) {
                    candidate_ids.push(id);
                }
            }
        }
        if !is_unknown {
            for found in LibraryRepository::find_canonical_albums_by_normalized_key(
                &self.pool,
                &base_title,
                artist_name,
            )
            .await
            .map_err(db_err)?
            {
                if seen_candidates.insert(found.id.clone()) {
                    candidate_ids.push(found.id);
                }
            }
        }

        if let Some(primary_id) = candidate_ids.first().cloned() {
            for secondary_id in candidate_ids.iter().skip(1) {
                let _ = LibraryRepository::merge_canonical_albums(
                    &self.pool,
                    &primary_id,
                    secondary_id,
                )
                .await
                .map_err(db_err)?;
            }
            let existing = LibraryRepository::find_canonical_album_by_id(&self.pool, &primary_id)
                .await
                .map_err(db_err)?;
            let mb_to_set = match (&existing, mb_rg_id) {
                (Some(ex), Some(rg)) if ex.musicbrainz_release_group_id.is_none() => Some(rg),
                _ => None,
            };
            let cover_to_set = match (&existing, album.cover_url.as_deref()) {
                (Some(ex), Some(c)) if ex.cover_url.is_none() && !c.trim().is_empty() => Some(c),
                _ => None,
            };
            if upc.is_some() || mb_to_set.is_some() || cover_to_set.is_some() {
                LibraryRepository::update_canonical_album_metadata(
                    &self.pool,
                    &primary_id,
                    upc,
                    mb_to_set,
                    None,
                    cover_to_set,
                )
                .await
                .map_err(db_err)?;
            }
            Ok(primary_id)
        } else {
            let mut shell = album.clone();
            shell.versions = Vec::new();
            if !is_unknown && base_title != shell.title {
                shell.title = base_title.clone();
                shell.sort_title = CanonicalAlbum::derive_sort_title(&base_title);
            }
            LibraryRepository::insert_canonical_album(&self.pool, &shell, Some(artist_id))
                .await
                .map_err(db_err)?;
            if upc.is_some() {
                LibraryRepository::update_canonical_album_metadata(
                    &self.pool,
                    &shell.id,
                    upc,
                    None,
                    None,
                    None,
                )
                .await
                .map_err(db_err)?;
            }
            Ok(shell.id)
        }
    }

    async fn ingest_playlist_sidecar(
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

    /// Canonical ingestion handoff for external streaming catalogs (metadata + platform IDs only,
    /// zero stream URLs). Merges versions across local & streaming while preserving `metadata_overrides`.
    pub async fn ingest_external_catalog(
        pool: &SqlitePool,
        batch: &ExternalCatalogIngestBatch,
    ) -> Result<SyncPersistReport, ProviderError> {
        let mut albums: Vec<CanonicalAlbum> = Vec::with_capacity(batch.albums.len());
        let mut tracks: Vec<TrackSource> = Vec::new();
        let mut album_meta: HashMap<String, AlbumSyncMetadata> = HashMap::new();
        let mut track_artists_by_ext: HashMap<String, Vec<String>> = HashMap::new();

        for ext_alb in &batch.albums {
            let title = if ext_alb.title.trim().is_empty() {
                "Unknown Album"
            } else {
                ext_alb.title.trim()
            };
            let artist = if ext_alb.artist_name.trim().is_empty() {
                "Unknown Artist"
            } else {
                ext_alb.artist_name.trim()
            };

            let (base_title, extracted_edition) = extract_edition_label(title);
            let mut album = CanonicalAlbum::new(
                if base_title.is_empty() {
                    title
                } else {
                    &base_title
                },
                artist,
            )?;
            if let Some(ref aa) = ext_alb.album_artist {
                album = album.with_album_artist(aa);
            }
            if let Some(yr) = ext_alb.release_year {
                if let Ok(a) = album.clone().with_release_year(yr) {
                    album = a;
                }
            }
            if let Some(ref cover) = ext_alb.cover_url {
                if !cover.trim().is_empty() {
                    album = album.with_cover_url(cover);
                }
            }

            let rep_format = ext_alb
                .tracks
                .first()
                .map(|t| {
                    let codec = t.codec.unwrap_or(AudioCodec::Flac);
                    let sr = t.sample_rate_hz.unwrap_or(44_100).max(8_000);
                    let bd = t.bit_depth.unwrap_or(16).clamp(8, 32);
                    if codec.is_dsd() {
                        AudioFormat::dsd(codec, sr, 2).unwrap_or_else(|_| AudioFormat::cd_quality())
                    } else {
                        AudioFormat::pcm(codec, sr, bd, 2)
                            .unwrap_or_else(|_| AudioFormat::cd_quality())
                    }
                })
                .unwrap_or_else(AudioFormat::cd_quality);

            let mut version = AlbumVersion::new(
                &album.id,
                batch.provider,
                &ext_alb.external_album_id,
                rep_format,
            )?;
            if let Some(ed) = ext_alb
                .edition_label
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or(extracted_edition)
            {
                version = version.with_edition_label(ed);
            }

            let mut sorted_tracks = ext_alb.tracks.clone();
            sorted_tracks.sort_by_key(|t| (t.disc_number, t.track_number));

            let mut durations: Vec<u64> = Vec::with_capacity(sorted_tracks.len());
            let mut max_disc: u32 = ext_alb.disc_count.max(1);

            for ext_trk in sorted_tracks {
                let codec = ext_trk.codec.unwrap_or(AudioCodec::Flac);
                let sr = ext_trk.sample_rate_hz.unwrap_or(44_100).max(8_000);
                let bd = ext_trk.bit_depth.unwrap_or(16).clamp(8, 32);
                let fmt = if codec.is_dsd() {
                    AudioFormat::dsd(codec, sr, 2).unwrap_or_else(|_| AudioFormat::cd_quality())
                } else {
                    AudioFormat::pcm(codec, sr, bd, 2).unwrap_or_else(|_| AudioFormat::cd_quality())
                };

                let disc = ext_trk.disc_number.max(1);
                let trk_num = ext_trk.track_number.max(1);
                let dur = ext_trk.duration_ms.max(1);
                max_disc = max_disc.max(u32::from(disc));

                let mut trk = TrackSource::new(
                    &version.id,
                    batch.provider,
                    &ext_trk.external_track_id,
                    if ext_trk.title.trim().is_empty() {
                        "Unknown Title"
                    } else {
                        ext_trk.title.trim()
                    },
                    disc,
                    trk_num,
                    dur,
                    fmt,
                )?;
                let trk_artist = ext_trk
                    .artist_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or(artist);
                trk = trk.with_artist_name(trk_artist);
                track_artists_by_ext.insert(
                    ext_trk.external_track_id.clone(),
                    split_artists(trk_artist),
                );
                if let Some(ref aa) = ext_trk.album_artist {
                    trk = trk.with_album_artist(aa);
                }
                if let Some(ref g) = ext_trk.genre {
                    trk = trk.with_genre(g);
                }
                if let Some(ref c) = ext_trk.composer {
                    trk = trk.with_composer(c);
                }
                if let Some(ref isrc) = ext_trk.isrc {
                    if let Ok(t) = trk.clone().with_isrc(isrc) {
                        trk = t;
                    }
                }
                durations.push(dur);
                tracks.push(trk);
            }

            let toc = if !durations.is_empty() {
                Some(TocSignature::from_durations(max_disc, durations))
            } else {
                None
            };
            let track_count = ext_alb.tracks.len() as u32;
            let mut vmap = HashMap::new();
            vmap.insert(
                version.id.clone(),
                VersionSyncMetadata {
                    toc_signature: toc.clone(),
                    disc_count: max_disc,
                    track_count,
                },
            );
            album_meta.insert(
                album.id.clone(),
                AlbumSyncMetadata {
                    upc: ext_alb.upc.clone(),
                    toc_signature: toc,
                    disc_count: max_disc,
                    track_count,
                    version_metadata: vmap,
                },
            );

            album.add_version(version);
            albums.push(album);
        }

        let report =
            LibrarySyncService::persist_provider_albums(pool, &albums, &tracks, &album_meta).await?;

        // Link persisted streaming TrackSources into canonical_tracks & track_artists
        let provider_str = batch.provider.as_str();
        for trk in &tracks {
            if let Ok(Some(info)) = LibraryRepository::get_track_file_cache_info(
                pool,
                provider_str,
                &trk.external_track_id,
            )
            .await
            {
                let alb_row: Option<(String,)> = sqlx::query_as(
                    "SELECT canonical_album_id FROM album_versions WHERE id = ? LIMIT 1",
                )
                .bind(&info.version_id)
                .fetch_optional(pool)
                .await
                .unwrap_or(None);
                if let Some((canonical_album_id,)) = alb_row {
                    let artists = track_artists_by_ext
                        .get(&trk.external_track_id)
                        .cloned()
                        .unwrap_or_default();
                    let _ = IngestionRepository::upsert_canonical_track_for_source(
                        pool,
                        &info.track_id,
                        &canonical_album_id,
                        trk,
                        &artists,
                    )
                    .await;
                }
            }
        }

        Ok(report)
    }
}

fn probe_single_file(
    path: PathBuf,
    existing_cache: &HashMap<String, TrackFileCacheInfo>,
) -> ProbeMessage {
    let norm_path = normalize_path(&path);
    let (file_size_opt, file_mtime_opt) = match std::fs::metadata(&path) {
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
            return ProbeMessage::Skipped {
                norm_path,
                reason,
                detail: format!("Failed to stat audio file: {e}"),
                file_size: None,
                file_mtime: None,
            };
        }
    };

    let cur_size = file_size_opt.unwrap_or(0) as i64;
    let cur_mtime = file_mtime_opt.unwrap_or(0);

    if let Some(cached) = existing_cache.get(&norm_path) {
        if cached.file_mtime == Some(cur_mtime) && cached.file_size == Some(cur_size) {
            return ProbeMessage::Unchanged(norm_path);
        }
    }

    let meta = match MetadataExtractor::extract_with_options(
        &path,
        ExtractOptions {
            include_pictures: false,
        },
    ) {
        Ok(m) => m,
        Err(e) => {
            let reason = match &e {
                ProviderError::Io(io_err) if io_err.kind() == ErrorKind::PermissionDenied => {
                    SkipReason::PermissionDenied
                }
                ProviderError::Io(_) => SkipReason::IoError,
                ProviderError::UnsupportedFormat(_) => SkipReason::CorruptHeader,
                _ => SkipReason::CorruptHeader,
            };
            return ProbeMessage::Skipped {
                norm_path,
                reason,
                detail: e.to_string(),
                file_size: file_size_opt,
                file_mtime: file_mtime_opt,
            };
        }
    };

    let fingerprint = match compute_content_fingerprint(&path) {
        Ok(fp) => fp,
        Err(e) => {
            let reason = if e.kind() == ErrorKind::PermissionDenied {
                SkipReason::PermissionDenied
            } else {
                SkipReason::IoError
            };
            return ProbeMessage::Skipped {
                norm_path,
                reason,
                detail: format!("Failed to compute content fingerprint: {e}"),
                file_size: file_size_opt,
                file_mtime: file_mtime_opt,
            };
        }
    };

    let garbled_reason = detect_garbled_tags(&meta);

    ProbeMessage::Ready(Box::new(ProbedTrackItem {
        path,
        norm_path,
        meta,
        fingerprint,
        file_mtime: cur_mtime,
        file_size: cur_size,
        garbled_reason,
    }))
}
