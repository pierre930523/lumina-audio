use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use core_db::{LibraryRepository, TrackFileCacheInfo};
use core_types::{ContentFingerprint, ScanLifecycleState, ScanProgressEvent, SkipReason};
use tokio::sync::mpsc;

use super::{IngestionPipeline, PROGRESS_THROTTLE, SKIPPED_BATCH_CHUNK};
use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::fingerprint::compute_content_fingerprint;
use crate::local::mapper::effective_album_dir;
use crate::local::metadata::{
    ExtractOptions, ExtractedMetadata, detect_garbled_tags, parse_audio_metadata,
};
use crate::local::scanner::{is_scannable_audio, normalize_path};

pub(super) struct ProbedTrackItem {
    pub(super) path: PathBuf,
    pub(super) norm_path: String,
    pub(super) meta: ExtractedMetadata,
    pub(super) fingerprint: ContentFingerprint,
    pub(super) file_mtime: i64,
    pub(super) file_size: i64,
    pub(super) garbled_reason: Option<String>,
}

pub(super) struct PendingSkipRecord {
    pub(super) norm_path: String,
    pub(super) reason: SkipReason,
    pub(super) detail: String,
    pub(super) file_size: Option<u64>,
    pub(super) file_mtime: Option<i64>,
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

/// Groups audio files by `effective_album_dir` BEFORE packing into batches of roughly
/// `target_batch_size` tracks, guaranteeing a single album (including multi-disc `CD1`/`CD2`
/// subfolders) is NEVER split across batch or `AlbumMapper` boundaries.
pub(crate) fn group_files_into_album_batches(
    audio_files: Vec<PathBuf>,
    target_batch_size: usize,
) -> Vec<Vec<PathBuf>> {
    let target = target_batch_size.max(1);
    let mut by_dir: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();
    for path in audio_files {
        let dir_key = effective_album_dir(&path)
            .map(normalize_path)
            .unwrap_or_else(|| normalize_path(&path));
        by_dir.entry(dir_key).or_default().push(path);
    }

    let mut batches: Vec<Vec<PathBuf>> = Vec::new();
    let mut current: Vec<PathBuf> = Vec::with_capacity(target);

    for (_, mut dir_files) in by_dir {
        dir_files.sort_by_key(|p| normalize_path(p));
        if !current.is_empty() && current.len() + dir_files.len() > target {
            batches.push(std::mem::take(&mut current));
        }
        current.extend(dir_files);
        if current.len() >= target {
            batches.push(std::mem::take(&mut current));
        }
    }

    if !current.is_empty() {
        batches.push(current);
    }
    batches
}

impl IngestionPipeline {
    pub(super) async fn probe_and_persist_files(
        &self,
        provider_id: &str,
        audio_files: Vec<PathBuf>,
        active_skipped: &mut HashSet<String>,
        progress: &mut ScanProgressEvent,
    ) -> Result<HashSet<String>, ProviderError> {
        self.probe_and_persist_files_with_options(
            provider_id,
            audio_files,
            false,
            active_skipped,
            progress,
        )
        .await
    }

    pub(super) async fn probe_and_persist_files_with_options(
        &self,
        provider_id: &str,
        audio_files: Vec<PathBuf>,
        force_full: bool,
        active_skipped: &mut HashSet<String>,
        progress: &mut ScanProgressEvent,
    ) -> Result<HashSet<String>, ProviderError> {
        let existing_rows = LibraryRepository::list_track_file_cache_info(&self.pool, provider_id)
            .await
            .map_err(db_err)?;
        let existing_cache: Arc<HashMap<String, TrackFileCacheInfo>> = Arc::new(
            existing_rows
                .into_iter()
                .map(|r| (normalize_path(&r.external_track_id), r))
                .collect(),
        );

        let dir_batches = group_files_into_album_batches(audio_files, self.config.batch_size);
        let max_workers = self.config.max_concurrency.clamp(4, 8);
        let mut pending_skips: Vec<PendingSkipRecord> = Vec::new();
        let mut pending_skipped_clears: Vec<String> = Vec::new();
        let mut touched_album_ids: HashSet<String> = HashSet::new();
        let mut last_emit = Instant::now();

        for batch_paths in dir_batches {
            let (tx, mut rx) = mpsc::channel::<ProbeMessage>(256);
            let existing_for_producer = existing_cache.clone();

            // Strictly bounded JoinSet: at most `max_workers` (4-8) live tasks at any time.
            let producer = tokio::spawn(async move {
                let mut join_set = tokio::task::JoinSet::new();
                for path in batch_paths {
                    while join_set.len() >= max_workers {
                        let _ = join_set.join_next().await;
                    }
                    let tx_item = tx.clone();
                    let cache_ref = existing_for_producer.clone();

                    join_set.spawn(async move {
                        let msg = tokio::task::spawn_blocking(move || {
                            probe_single_file(path, &cache_ref, force_full)
                        })
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

            let mut ready_batch: Vec<ProbedTrackItem> = Vec::new();

            while let Some(msg) = rx.recv().await {
                progress.scanned += 1;

                match msg {
                    ProbeMessage::Unchanged(norm_path) => {
                        progress.unchanged += 1;
                        progress.current_path = Some(norm_path.clone());
                        if active_skipped.remove(&norm_path) {
                            pending_skipped_clears.push(norm_path);
                            if pending_skipped_clears.len() >= SKIPPED_BATCH_CHUNK {
                                let to_clear = std::mem::take(&mut pending_skipped_clears);
                                self.flush_skipped_clears_chunked(provider_id, &to_clear)
                                    .await;
                            }
                        }
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
                            pending_skips.push(PendingSkipRecord {
                                norm_path,
                                reason,
                                detail,
                                file_size,
                                file_mtime,
                            });
                            if pending_skips.len() >= SKIPPED_BATCH_CHUNK {
                                let to_record = std::mem::take(&mut pending_skips);
                                self.flush_skipped_records_chunked(provider_id, &to_record)
                                    .await;
                            }
                        }
                    }
                    ProbeMessage::Ready(item) => {
                        progress.current_path = Some(item.norm_path.clone());
                        ready_batch.push(*item);
                    }
                }

                if last_emit.elapsed() >= PROGRESS_THROTTLE {
                    self.emit(progress);
                    last_emit = Instant::now();
                }
            }

            let _ = producer.await;

            if !ready_batch.is_empty() {
                progress.state = ScanLifecycleState::Persisting;
                if last_emit.elapsed() >= PROGRESS_THROTTLE {
                    self.emit(progress);
                    last_emit = Instant::now();
                }
                let batch_touched = self
                    .persist_probed_batch(
                        provider_id,
                        ready_batch,
                        &existing_cache,
                        active_skipped,
                        progress,
                    )
                    .await?;
                touched_album_ids.extend(batch_touched);
                progress.state = ScanLifecycleState::Probing;
            }
        }

        if !pending_skips.is_empty() {
            self.flush_skipped_records_chunked(provider_id, &pending_skips)
                .await;
        }
        if !pending_skipped_clears.is_empty() {
            self.flush_skipped_clears_chunked(provider_id, &pending_skipped_clears)
                .await;
        }

        Ok(touched_album_ids)
    }
}

fn probe_single_file(
    path: PathBuf,
    existing_cache: &HashMap<String, TrackFileCacheInfo>,
    force_full: bool,
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

    if !force_full {
        if let Some(cached) = existing_cache.get(&norm_path) {
            if cached.file_mtime == Some(cur_mtime) && cached.file_size == Some(cur_size) {
                return ProbeMessage::Unchanged(norm_path);
            }
        }
    }

    let meta = match parse_audio_metadata(
        &path,
        ExtractOptions {
            include_pictures: false,
        },
    ) {
        Ok(m) => m,
        Err(e) => {
            let reason = classify_probe_error(&path, &e);
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

pub(crate) fn classify_probe_error(path: &std::path::Path, err: &ProviderError) -> SkipReason {
    match err {
        ProviderError::Io(io_err) if io_err.kind() == ErrorKind::PermissionDenied => {
            SkipReason::PermissionDenied
        }
        ProviderError::Io(_) => SkipReason::IoError,
        ProviderError::UnsupportedFormat(msg) => {
            let lower = msg.to_ascii_lowercase();
            if !is_scannable_audio(path)
                || lower.contains("unsupported codec")
                || lower.contains("unsupported container")
                || lower.contains("unsupported audio format")
            {
                SkipReason::UnsupportedFormat
            } else {
                SkipReason::CorruptHeader
            }
        }
        _ => SkipReason::CorruptHeader,
    }
}
