use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use core_types::{
    L2_MAX_TARGET_BYTES, L2_TAIL_FINGERPRINT_LEN, L2AccessUpdate, L2CacheKind, L2HeadCacheStore,
    L2HeadChunkRecord, StreamKey, StreamProviderCapabilities,
};
use tokio::sync::Mutex as AsyncMutex;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use super::super::{StreamError, streaming_runtime};
use super::dash_package::DashL2Package;
use super::eviction::{
    SharedL2State, enforce_watermarks_inner, flush_pending_access_inner, run_orphan_sweep_inner,
};
use super::lease::{L2DashHit, L2DirectHit, L2EvictionReport, L2FileLease, L2OrphanSweepReport};
use super::path::{
    L2CacheConfig, build_l2_rel_path, read_file_bytes, rel_path_to_abs, remove_file_if_exists,
    store_err_to_stream, unix_timestamp_secs, write_file_atomic,
};

/// Disk + metadata-store L2 head-chunk cache manager with atomic `.tmp -> rename` writes, batched
/// access-timestamp flushing, dual-watermark eviction, lease protection, and orphan sweeping.
pub struct L2CacheManager {
    state: SharedL2State,
    bg_handles: Mutex<Vec<JoinHandle<()>>>,
}

impl L2CacheManager {
    /// Initializes the L2 cache manager and starts background access-flush and delayed orphan-sweep
    /// tasks when a Tokio runtime is available.
    pub fn new(
        store: Arc<dyn L2HeadCacheStore>,
        mut config: L2CacheConfig,
    ) -> Result<Self, StreamError> {
        config.low_watermark_bytes = config.low_watermark_bytes.min(config.high_watermark_bytes);
        fs::create_dir_all(&config.root_dir)?;

        let state = SharedL2State {
            store,
            config,
            active_leases: Arc::new(Mutex::new(HashMap::new())),
            pending_access: Arc::new(Mutex::new(HashMap::new())),
            eviction_lock: Arc::new(AsyncMutex::new(())),
            cancel: CancellationToken::new(),
        };

        let mut handles = Vec::new();
        let rt_handle = tokio::runtime::Handle::try_current()
            .ok()
            .or_else(|| streaming_runtime().ok().map(|rt| rt.handle().clone()));

        if let Some(handle) = rt_handle {
            let flush_state = state.clone();
            let flush_interval = flush_state.config.access_flush_interval;
            if !flush_interval.is_zero() {
                handles.push(handle.spawn(async move {
                    loop {
                        tokio::select! {
                            biased;
                            _ = flush_state.cancel.cancelled() => break,
                            _ = tokio::time::sleep(flush_interval) => {
                                let _ = flush_pending_access_inner(&flush_state).await;
                            }
                        }
                    }
                }));
            }

            let sweep_state = state.clone();
            let sweep_delay = sweep_state.config.orphan_sweep_delay;
            handles.push(handle.spawn(async move {
                if !sweep_delay.is_zero() {
                    tokio::select! {
                        biased;
                        _ = sweep_state.cancel.cancelled() => return,
                        _ = tokio::time::sleep(sweep_delay) => {}
                    }
                }
                if !sweep_state.cancel.is_cancelled() {
                    let _ = run_orphan_sweep_inner(&sweep_state).await;
                }
            }));
        }

        Ok(Self {
            state,
            bg_handles: Mutex::new(handles),
        })
    }

    /// Returns a reference to the active [`L2CacheConfig`].
    pub fn config(&self) -> &L2CacheConfig {
        &self.state.config
    }

    /// Returns a reference to the backing [`L2HeadCacheStore`].
    pub fn store(&self) -> &Arc<dyn L2HeadCacheStore> {
        &self.state.store
    }

    /// Resolves a relative L2 path into an absolute filesystem path under `config.root_dir`.
    pub fn resolve_rel_path(&self, rel_path: &str) -> PathBuf {
        rel_path_to_abs(&self.state.config.root_dir, rel_path)
    }

    /// Acquires an RAII [`L2FileLease`] protecting `key` from eviction and orphan deletion.
    pub fn acquire_lease(&self, key: &StreamKey) -> L2FileLease {
        if let Ok(mut map) = self.state.active_leases.lock() {
            *map.entry(key.clone()).or_insert(0) += 1;
        }
        L2FileLease {
            key: key.clone(),
            leases: Arc::clone(&self.state.active_leases),
        }
    }

    /// Returns `true` if one or more active [`L2FileLease`] guards currently hold `key`.
    pub fn is_in_use(&self, key: &StreamKey) -> bool {
        self.state.is_in_use(key)
    }

    /// Atomically persists a raw direct (or Deezer encrypted) head buffer to disk and SQLite,
    /// enforcing high/low watermarks afterward.
    pub async fn store_direct_head(
        &self,
        key: &StreamKey,
        data: &[u8],
        total_content_length: Option<u64>,
        pin_level: i64,
    ) -> Result<Option<L2HeadChunkRecord>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }
        if data.is_empty() {
            return Ok(None);
        }
        if data.len() as u64 > L2_MAX_TARGET_BYTES {
            return Err(StreamError::Unsupported(format!(
                "L2 direct head chunk size {} exceeds {} byte cap",
                data.len(),
                L2_MAX_TARGET_BYTES
            )));
        }

        let _write_lease = self.acquire_lease(key);
        let fp_len = data.len().min(L2_TAIL_FINGERPRINT_LEN);
        let tail_fingerprint = data[data.len() - fp_len..].to_vec();
        let bytes = Bytes::copy_from_slice(data);
        let cached_bytes = bytes.len() as i64;
        let rel_path = build_l2_rel_path(key, L2CacheKind::DirectHead);
        let abs_path = self.resolve_rel_path(&rel_path);

        write_file_atomic(abs_path.clone(), bytes).await?;

        let now = unix_timestamp_secs();
        let record = L2HeadChunkRecord {
            provider_id: key.provider_id.clone(),
            track_id: key.track_id.clone(),
            quality_key: key.quality_key.clone(),
            cache_kind: L2CacheKind::DirectHead.as_str().to_string(),
            file_rel_path: rel_path,
            cached_bytes,
            total_content_length: total_content_length.map(|v| v as i64),
            tail_fingerprint,
            pin_level,
            last_accessed_at: now,
            access_count: 1,
            created_at: now,
        };

        if let Err(err) = self.state.store.upsert(&record).await {
            let _ = remove_file_if_exists(abs_path).await;
            return Err(store_err_to_stream(err));
        }

        self.state.clear_pending_access(key);
        drop(_write_lease);
        let _ = self.enforce_watermarks().await?;
        Ok(Some(record))
    }

    /// Atomically persists a [`DashL2Package`] (`init` + up to 2 segments, capped at `4 MiB`)
    /// to disk and metadata store, enforcing high/low watermarks afterward.
    pub async fn store_dash_head(
        &self,
        key: &StreamKey,
        pkg: &DashL2Package,
        pin_level: i64,
    ) -> Result<Option<L2HeadChunkRecord>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }
        if pkg.init_bytes.is_empty() && pkg.segments.is_empty() {
            return Ok(None);
        }

        let _write_lease = self.acquire_lease(key);
        let encoded = pkg.encode()?;
        let tail_fingerprint = pkg.tail_fingerprint().to_vec();
        let cached_bytes = encoded.len() as i64;
        let rel_path = build_l2_rel_path(key, L2CacheKind::DashInitSegs);
        let abs_path = self.resolve_rel_path(&rel_path);

        write_file_atomic(abs_path.clone(), Bytes::from(encoded)).await?;

        let now = unix_timestamp_secs();
        let record = L2HeadChunkRecord {
            provider_id: key.provider_id.clone(),
            track_id: key.track_id.clone(),
            quality_key: key.quality_key.clone(),
            cache_kind: L2CacheKind::DashInitSegs.as_str().to_string(),
            file_rel_path: rel_path,
            cached_bytes,
            total_content_length: None,
            tail_fingerprint,
            pin_level,
            last_accessed_at: now,
            access_count: 1,
            created_at: now,
        };

        if let Err(err) = self.state.store.upsert(&record).await {
            let _ = remove_file_if_exists(abs_path).await;
            return Err(store_err_to_stream(err));
        }

        self.state.clear_pending_access(key);
        drop(_write_lease);
        let _ = self.enforce_watermarks().await?;
        Ok(Some(record))
    }

    /// Looks up a cached direct head chunk, acquiring an [`L2FileLease`] before reading disk bytes,
    /// verifying size and tail fingerprint, and queuing access stats in memory without writing the store.
    pub async fn lookup_direct_head(
        &self,
        key: &StreamKey,
    ) -> Result<Option<L2DirectHit>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }

        let lease = self.acquire_lease(key);
        let Some(record) = self
            .state
            .store
            .get(key)
            .await
            .map_err(store_err_to_stream)?
        else {
            return Ok(None);
        };

        if L2CacheKind::parse(&record.cache_kind) != Some(L2CacheKind::DirectHead) {
            return Ok(None);
        }

        let abs_path = self.resolve_rel_path(&record.file_rel_path);
        let raw_bytes = match read_file_bytes(abs_path.clone()).await {
            Ok(Some(b)) => b,
            Ok(None) => {
                let _ = self.state.store.delete(key).await;
                return Ok(None);
            }
            Err(e) => return Err(e),
        };

        let expected_len = record.cached_bytes.max(0) as usize;
        let fp = &record.tail_fingerprint;
        let tail_ok = raw_bytes.len() == expected_len
            && !fp.is_empty()
            && raw_bytes.len() >= fp.len()
            && &raw_bytes[raw_bytes.len() - fp.len()..] == fp.as_slice();

        if !tail_ok {
            let _ = self.state.store.delete(key).await;
            let _ = remove_file_if_exists(abs_path).await;
            return Ok(None);
        }

        self.record_pending_access(key);
        let total_content_length = record
            .total_content_length
            .and_then(|v| u64::try_from(v).ok());
        let tail_fingerprint = record.tail_fingerprint.clone();

        Ok(Some(L2DirectHit {
            record,
            head_bytes: raw_bytes,
            total_content_length,
            tail_fingerprint,
            lease,
        }))
    }

    /// Looks up a cached DASH head package, acquiring an [`L2FileLease`] before reading disk bytes,
    /// decoding & verifying the integrity fingerprint, and queuing access stats in memory.
    pub async fn lookup_dash_head(
        &self,
        key: &StreamKey,
    ) -> Result<Option<L2DashHit>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }

        let lease = self.acquire_lease(key);
        let Some(record) = self
            .state
            .store
            .get(key)
            .await
            .map_err(store_err_to_stream)?
        else {
            return Ok(None);
        };

        if L2CacheKind::parse(&record.cache_kind) != Some(L2CacheKind::DashInitSegs) {
            return Ok(None);
        }

        let abs_path = self.resolve_rel_path(&record.file_rel_path);
        let raw_bytes = match read_file_bytes(abs_path.clone()).await {
            Ok(Some(b)) => b,
            Ok(None) => {
                let _ = self.state.store.delete(key).await;
                return Ok(None);
            }
            Err(e) => return Err(e),
        };

        let expected_len = record.cached_bytes.max(0) as usize;
        let decoded = if raw_bytes.len() == expected_len {
            DashL2Package::decode(&raw_bytes).ok()
        } else {
            None
        };

        let Some(package) = decoded else {
            let _ = self.state.store.delete(key).await;
            let _ = remove_file_if_exists(abs_path).await;
            return Ok(None);
        };

        let tail_fingerprint = package.tail_fingerprint();
        if tail_fingerprint.as_slice() != record.tail_fingerprint.as_slice() {
            let _ = self.state.store.delete(key).await;
            let _ = remove_file_if_exists(abs_path).await;
            return Ok(None);
        }

        self.record_pending_access(key);
        Ok(Some(L2DashHit {
            record,
            package,
            tail_fingerprint,
            lease,
        }))
    }

    /// Deletes the metadata record (first) and backing `.head`/`.dash.head` file on disk.
    pub async fn delete_entry(&self, key: &StreamKey) -> Result<bool, StreamError> {
        self.state.clear_pending_access(key);
        let existing = self
            .state
            .store
            .get(key)
            .await
            .map_err(store_err_to_stream)?;
        let deleted_row = self
            .state
            .store
            .delete(key)
            .await
            .map_err(store_err_to_stream)?;

        let mut removed_file = false;
        if let Some(rec) = existing {
            removed_file = remove_file_if_exists(self.resolve_rel_path(&rec.file_rel_path)).await?;
        } else {
            for kind in [L2CacheKind::DirectHead, L2CacheKind::DashInitSegs] {
                let rel = build_l2_rel_path(key, kind);
                if remove_file_if_exists(self.resolve_rel_path(&rel)).await? {
                    removed_file = true;
                }
            }
        }
        Ok(deleted_row || removed_file)
    }

    /// Flushes all buffered in-memory access timestamp/count increments in a single batch.
    pub async fn flush_pending_access(&self) -> Result<u64, StreamError> {
        flush_pending_access_inner(&self.state).await
    }

    /// Enforces the dual-watermark policy: when total bytes exceed `high_watermark_bytes`, evicts
    /// unleased entries ordered by `(pin_level ASC, last_accessed_at ASC, created_at ASC)` down to
    /// `low_watermark_bytes` (deleting metadata records before unlinking disk files).
    pub async fn enforce_watermarks(&self) -> Result<L2EvictionReport, StreamError> {
        enforce_watermarks_inner(&self.state).await
    }

    /// Sweeps stale `.tmp` files, unreferenced `.head`/`.dash.head` files, and dangling metadata rows.
    pub async fn run_orphan_sweep(&self) -> Result<L2OrphanSweepReport, StreamError> {
        run_orphan_sweep_inner(&self.state).await
    }

    /// Cancels background tasks and flushes all pending access updates to the metadata store.
    pub async fn shutdown(&self) -> Result<(), StreamError> {
        self.state.cancel.cancel();
        let handles = {
            self.bg_handles
                .lock()
                .map(|mut g| std::mem::take(&mut *g))
                .unwrap_or_default()
        };
        for handle in handles {
            let _ = handle.await;
        }
        let _ = self.flush_pending_access().await?;
        Ok(())
    }

    fn record_pending_access(&self, key: &StreamKey) {
        let now = unix_timestamp_secs();
        if let Ok(mut pending) = self.state.pending_access.lock() {
            pending
                .entry(key.clone())
                .and_modify(|update| {
                    update.last_accessed_at = update.last_accessed_at.max(now);
                    update.access_delta = update.access_delta.saturating_add(1);
                })
                .or_insert(L2AccessUpdate {
                    key: key.clone(),
                    last_accessed_at: now,
                    access_delta: 1,
                });
        }
    }
}

impl Drop for L2CacheManager {
    fn drop(&mut self) {
        self.state.cancel.cancel();
    }
}
