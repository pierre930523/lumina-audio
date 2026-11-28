mod commit;
mod commit_locks;
mod commit_meta;
mod discover;
mod external;
mod probe;
mod rebuild;
mod relink;
mod scanner;
mod skipped_rescan;

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use core_db::{DbWriteCoordinator, IngestionRepository, LibraryRepository, SqlitePool};
use core_types::ScanProgressEvent;
use tokio::sync::{Mutex, broadcast};

use self::probe::PendingSkipRecord;
use crate::error::ProviderError;
use crate::library::db_err;

pub(crate) use self::commit_locks::{
    LiveManualTrackLock, is_album_group_locked_cached, load_live_manual_track_locks_tx,
    lookup_version_manual_group_pool, resolve_primaries_for_albums_tx,
};
pub(crate) use self::commit_meta::{
    build_album_file_layer, build_track_file_layer, persist_album_file_layer_tx,
};
pub(crate) use self::probe::{classify_probe_error, group_files_into_album_batches};

pub(super) const PROGRESS_THROTTLE: Duration = Duration::from_millis(200);
pub(super) const BATCH_COMMIT_SIZE: usize = 200;
pub(super) const SKIPPED_BATCH_CHUNK: usize = BATCH_COMMIT_SIZE;

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
            batch_size: BATCH_COMMIT_SIZE,
            follow_symlinks: false,
        }
    }
}

/// High-throughput, bounded-concurrency ingestion pipeline for local and mounted storage.
///
/// Features:
/// - Offline root guard (never prunes or marks tracks missing when a drive/share is offline)
/// - Bounded worker pool (4-8 workers) with directory-aligned 200-track batching
/// - Single-writer `DbWriteCoordinator` serialization across all SQLite mutations
/// - Tag-independent content fingerprint move/rename auto-relink (preserving history/favorites/overrides)
/// - Structured `skipped_files` quarantine (corrupt, permission, unsupported, garbled)
/// - Chunked SQLite persistence + incremental FTS sync + 200ms-throttled `ScanProgressEvent` stream
#[derive(Clone)]
pub struct IngestionPipeline {
    pool: SqlitePool,
    write_coord: DbWriteCoordinator,
    config: IngestionConfig,
    progress_tx: broadcast::Sender<ScanProgressEvent>,
    scan_lock: Arc<Mutex<()>>,
}

impl IngestionPipeline {
    pub fn new(pool: SqlitePool, config: IngestionConfig) -> Self {
        let write_coord = DbWriteCoordinator::for_pool(&pool);
        Self::with_coordinator(pool, write_coord, config)
    }

    pub fn with_coordinator(
        pool: SqlitePool,
        write_coord: DbWriteCoordinator,
        config: IngestionConfig,
    ) -> Self {
        let (progress_tx, _) = broadcast::channel(512);
        Self {
            pool,
            write_coord,
            config: IngestionConfig {
                max_concurrency: config.max_concurrency.clamp(4, 8),
                batch_size: config.batch_size.clamp(1, 500),
                follow_symlinks: config.follow_symlinks,
            },
            progress_tx,
            scan_lock: Arc::new(Mutex::new(())),
        }
    }

    pub fn with_defaults(pool: SqlitePool) -> Self {
        Self::new(pool, IngestionConfig::default())
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub fn write_coordinator(&self) -> &DbWriteCoordinator {
        &self.write_coord
    }

    pub fn subscribe_progress(&self) -> broadcast::Receiver<ScanProgressEvent> {
        self.progress_tx.subscribe()
    }

    pub fn progress_sender(&self) -> broadcast::Sender<ScanProgressEvent> {
        self.progress_tx.clone()
    }

    pub(super) fn emit(&self, event: &ScanProgressEvent) {
        let _ = self.progress_tx.send(event.clone());
    }

    pub(crate) async fn prune_orphans_under_write_lock(
        &self,
        provider_id_filter: Option<&str>,
    ) -> Result<(), ProviderError> {
        let empty = HashSet::new();
        self.prune_orphans_and_resolve_primaries_under_write_lock(provider_id_filter, &empty)
            .await
    }

    pub(crate) async fn prune_orphans_and_resolve_primaries_under_write_lock(
        &self,
        provider_id_filter: Option<&str>,
        touched_album_ids: &HashSet<String>,
    ) -> Result<(), ProviderError> {
        let invalidated = {
            let (_write_guard, mut tx) = self
                .write_coord
                .begin_immediate(&self.pool)
                .await
                .map_err(db_err)?;
            let res = LibraryRepository::prune_orphan_albums_and_versions_tx(
                tx.conn(),
                provider_id_filter,
            )
            .await
            .map_err(db_err);
            match res {
                Ok(rep) => {
                    resolve_primaries_for_albums_tx(&mut tx, touched_album_ids).await;
                    tx.commit().await.map_err(db_err)?;
                    rep.invalidated_artwork_paths
                }
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(e);
                }
            }
        };
        remove_invalidated_artwork_files(invalidated).await;
        Ok(())
    }

    async fn flush_skipped_records_chunked(
        &self,
        provider_id: &str,
        records: &[PendingSkipRecord],
    ) {
        if records.is_empty() {
            return;
        }
        for chunk in records.chunks(SKIPPED_BATCH_CHUNK) {
            if let Ok((_write_guard, mut tx)) = self.write_coord.begin_immediate(&self.pool).await {
                let mut ok = true;
                for rec in chunk {
                    if IngestionRepository::record_skipped_file_tx(
                        tx.conn(),
                        provider_id,
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
            tokio::task::yield_now().await;
        }
    }

    pub(super) async fn flush_skipped_clears_chunked(&self, provider_id: &str, paths: &[String]) {
        if paths.is_empty() {
            return;
        }
        for chunk in paths.chunks(SKIPPED_BATCH_CHUNK) {
            if let Ok((_write_guard, mut tx)) = self.write_coord.begin_immediate(&self.pool).await {
                let mut ok = true;
                for p in chunk {
                    if IngestionRepository::clear_skipped_for_path_tx(tx.conn(), provider_id, p)
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
            tokio::task::yield_now().await;
        }
    }
}

pub(crate) async fn remove_invalidated_artwork_files(paths: Vec<String>) {
    if paths.is_empty() {
        return;
    }
    let _ = tokio::task::spawn_blocking(move || {
        for path in paths {
            let trimmed = path.trim();
            if !trimmed.is_empty() {
                let _ = std::fs::remove_file(trimmed);
            }
        }
    })
    .await;
}
