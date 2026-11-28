use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex};

use core_types::{L2AccessUpdate, L2CacheKind, L2HeadCacheStore, StreamKey};
use tokio::sync::Mutex as AsyncMutex;
use tokio_util::sync::CancellationToken;

use super::super::StreamError;
use super::lease::{L2EvictionReport, L2OrphanSweepReport};
use super::path::{
    L2CacheConfig, build_l2_rel_path, path_to_rel_string, rel_path_to_abs, remove_file_if_exists,
    store_err_to_stream,
};

#[derive(Clone)]
pub(super) struct SharedL2State {
    pub(super) store: Arc<dyn L2HeadCacheStore>,
    pub(super) config: L2CacheConfig,
    pub(super) active_leases: Arc<Mutex<HashMap<StreamKey, usize>>>,
    pub(super) pending_access: Arc<Mutex<HashMap<StreamKey, L2AccessUpdate>>>,
    pub(super) eviction_lock: Arc<AsyncMutex<()>>,
    pub(super) cancel: CancellationToken,
}

impl SharedL2State {
    pub(super) fn is_in_use(&self, key: &StreamKey) -> bool {
        self.active_leases
            .lock()
            .map(|map| map.get(key).copied().unwrap_or(0) > 0)
            .unwrap_or(false)
    }

    pub(super) fn clear_pending_access(&self, key: &StreamKey) {
        if let Ok(mut pending) = self.pending_access.lock() {
            pending.remove(key);
        }
    }
}

pub(super) async fn enforce_watermarks_inner(
    state: &SharedL2State,
) -> Result<L2EvictionReport, StreamError> {
    let _guard = state.eviction_lock.lock().await;
    let mut total_bytes = state
        .store
        .total_cached_bytes()
        .await
        .map_err(store_err_to_stream)?;

    if total_bytes <= state.config.high_watermark_bytes {
        return Ok(L2EvictionReport {
            evicted_entries: 0,
            freed_bytes: 0,
            skipped_in_use: 0,
            remaining_bytes: total_bytes,
        });
    }

    let candidates = state
        .store
        .list_eviction_candidates(1024)
        .await
        .map_err(store_err_to_stream)?;

    let mut evicted_entries = 0u64;
    let mut freed_bytes = 0u64;
    let mut skipped_in_use = 0u64;

    for candidate in candidates {
        if total_bytes <= state.config.low_watermark_bytes {
            break;
        }
        let key = candidate.stream_key();
        if state.is_in_use(&key) {
            skipped_in_use += 1;
            continue;
        }

        // Delete metadata first so a crash never leaves a dangling index pointing to missing bytes.
        let deleted = state
            .store
            .delete(&key)
            .await
            .map_err(store_err_to_stream)?;
        state.clear_pending_access(&key);

        let abs_path = rel_path_to_abs(&state.config.root_dir, &candidate.file_rel_path);
        let _ = remove_file_if_exists(abs_path).await?;

        if deleted {
            let bytes = candidate.cached_bytes.max(0) as u64;
            total_bytes = total_bytes.saturating_sub(bytes);
            evicted_entries += 1;
            freed_bytes = freed_bytes.saturating_add(bytes);
        }
    }

    let remaining_bytes = state
        .store
        .total_cached_bytes()
        .await
        .map_err(store_err_to_stream)?;

    Ok(L2EvictionReport {
        evicted_entries,
        freed_bytes,
        skipped_in_use,
        remaining_bytes,
    })
}

pub(super) async fn flush_pending_access_inner(state: &SharedL2State) -> Result<u64, StreamError> {
    let updates: Vec<L2AccessUpdate> = {
        let mut pending = state
            .pending_access
            .lock()
            .map_err(|_| StreamError::Io("L2 pending_access lock poisoned".to_string()))?;
        if pending.is_empty() {
            return Ok(0);
        }
        pending.drain().map(|(_, v)| v).collect()
    };

    match state.store.batch_update_access(&updates).await {
        Ok(affected) => Ok(affected),
        Err(err) => {
            if let Ok(mut pending) = state.pending_access.lock() {
                for update in updates {
                    pending
                        .entry(update.key.clone())
                        .and_modify(|cur| {
                            cur.last_accessed_at =
                                cur.last_accessed_at.max(update.last_accessed_at);
                            cur.access_delta = cur.access_delta.saturating_add(update.access_delta);
                        })
                        .or_insert(update);
                }
            }
            Err(store_err_to_stream(err))
        }
    }
}

pub(super) async fn run_orphan_sweep_inner(
    state: &SharedL2State,
) -> Result<L2OrphanSweepReport, StreamError> {
    let records = state
        .store
        .list_all_records()
        .await
        .map_err(store_err_to_stream)?;

    let known_rel_paths: HashSet<String> =
        records.iter().map(|r| r.file_rel_path.clone()).collect();

    let leased_rel_paths: HashSet<String> = {
        let guard = state
            .active_leases
            .lock()
            .map_err(|_| StreamError::Io("L2 active_leases lock poisoned".to_string()))?;
        let mut paths = HashSet::with_capacity(guard.len() * 2);
        for key in guard.keys() {
            paths.insert(build_l2_rel_path(key, L2CacheKind::DirectHead));
            paths.insert(build_l2_rel_path(key, L2CacheKind::DashInitSegs));
        }
        paths
    };

    let root_dir = state.config.root_dir.clone();
    let (deleted_tmp_files, deleted_orphan_files) = tokio::task::spawn_blocking(move || {
        sweep_disk_files(&root_dir, &known_rel_paths, &leased_rel_paths)
    })
    .await
    .map_err(|e| StreamError::Io(format!("L2 orphan sweep task panicked: {e}")))??;

    let mut removed_dangling_rows = 0u64;
    for rec in records {
        let abs_path = rel_path_to_abs(&state.config.root_dir, &rec.file_rel_path);
        let exists = tokio::task::spawn_blocking(move || abs_path.is_file())
            .await
            .unwrap_or(false);
        if !exists
            && state
                .store
                .delete(&rec.stream_key())
                .await
                .map_err(store_err_to_stream)?
        {
            removed_dangling_rows += 1;
        }
    }

    Ok(L2OrphanSweepReport {
        deleted_tmp_files,
        deleted_orphan_files,
        removed_dangling_rows,
    })
}

fn sweep_disk_files(
    root_dir: &Path,
    known_rel_paths: &HashSet<String>,
    leased_rel_paths: &HashSet<String>,
) -> Result<(u64, u64), StreamError> {
    let l2_dir = root_dir.join("cache").join("l2");
    if !l2_dir.exists() {
        return Ok((0, 0));
    }

    let mut deleted_tmp = 0u64;
    let mut deleted_orphans = 0u64;
    let mut dirs = vec![l2_dir];

    while let Some(dir) = dirs.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if meta.is_dir() {
                dirs.push(path);
                continue;
            }
            if !meta.is_file() {
                continue;
            }
            let file_name = entry.file_name().to_string_lossy().into_owned();
            if file_name.contains(".tmp.") || file_name.ends_with(".tmp") {
                if let Some(rel) = path_to_rel_string(root_dir, &path) {
                    let base_rel = rel
                        .split_once(".tmp")
                        .map(|(prefix, _)| prefix.to_string())
                        .unwrap_or(rel);
                    if leased_rel_paths.contains(&base_rel) {
                        continue;
                    }
                }
                if fs::remove_file(&path).is_ok() {
                    deleted_tmp += 1;
                }
                continue;
            }
            if file_name.ends_with(".head")
                && let Some(rel) = path_to_rel_string(root_dir, &path)
                && !known_rel_paths.contains(&rel)
                && !leased_rel_paths.contains(&rel)
                && fs::remove_file(&path).is_ok()
            {
                deleted_orphans += 1;
            }
        }
    }

    Ok((deleted_tmp, deleted_orphans))
}
