use crate::engine::{EngineState, get_engine};
use crate::error::{
    LUMINA_ERR_DATABASE, LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_ERR_NULL_POINTER,
    LUMINA_OK, catch_unwind_ffi, set_last_error,
};
use core_audio::streaming::{L2CacheConfig, L2CacheManager};
use core_db::SqliteL2HeadCacheStore;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Lazily initializes a default [`L2CacheManager`] anchored beside `engine.db_path` whenever
/// `engine.db_pool` has been initialized (e.g., after `lumina_library_init`) and attaches it
/// to `engine.player` if present.
pub(crate) fn ensure_default_l2_cache_manager(engine: &EngineState) -> Option<Arc<L2CacheManager>> {
    if let Ok(guard) = engine.l2_cache_manager.read()
        && let Some(ref mgr) = *guard
    {
        let mgr_clone = Arc::clone(mgr);
        drop(guard);
        if let Some(player) = engine.player_clone()
            && player.l2_cache_manager().is_none()
        {
            player.set_l2_cache_manager(Some(Arc::clone(&mgr_clone)));
        }
        return Some(mgr_clone);
    }

    let pool = engine.db_pool.read().ok().and_then(|g| g.clone())?;
    let default_root = engine
        .db_path
        .read()
        .ok()
        .and_then(|g| g.clone())
        .filter(|s| !s.trim().is_empty() && s.trim() != ":memory:")
        .and_then(|s| {
            Path::new(&s)
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .map(|p| p.join("l2_cache"))
        })
        .unwrap_or_else(|| std::env::temp_dir().join("lumina_l2_cache"));

    let new_mgr = {
        let _rt_guard = engine.runtime.enter();
        let store = Arc::new(SqliteL2HeadCacheStore::new(pool));
        Arc::new(L2CacheManager::new(store, L2CacheConfig::new(default_root)).ok()?)
    };

    let chosen = if let Ok(mut guard) = engine.l2_cache_manager.write() {
        if let Some(ref existing) = *guard {
            let existing_clone = Arc::clone(existing);
            drop(guard);
            engine.runtime.spawn(async move {
                let _ = new_mgr.shutdown().await;
            });
            existing_clone
        } else {
            *guard = Some(Arc::clone(&new_mgr));
            new_mgr
        }
    } else {
        new_mgr
    };

    if let Some(player) = engine.player_clone() {
        player.set_l2_cache_manager(Some(Arc::clone(&chosen)));
    }

    Some(chosen)
}

/// Initializes (or reconfigures) the persistent L2 head-chunk cache manager at `root_dir` with
/// explicit `high_watermark_bytes` and `low_watermark_bytes` (or defaults 1024 MiB / 800 MiB when 0).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l2_cache_init(
    root_dir: *const c_char,
    high_watermark_bytes: u64,
    low_watermark_bytes: u64,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_l2_cache_init", || {
        if root_dir.is_null() {
            set_last_error("root_dir is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let dir_str = unsafe { CStr::from_ptr(root_dir) }
            .to_str()
            .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in root_dir: {e}"))?
            .trim();
        if dir_str.is_empty() {
            set_last_error("root_dir must not be empty");
            return Ok(LUMINA_ERR_GENERAL);
        }

        let engine = get_engine();
        let Some(pool) = engine.db_pool.read().ok().and_then(|g| g.clone()) else {
            set_last_error("Library database not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        let mut cfg = L2CacheConfig::new(PathBuf::from(dir_str));
        if high_watermark_bytes > 0 && low_watermark_bytes > 0 {
            cfg = cfg.with_watermarks(high_watermark_bytes, low_watermark_bytes);
        }

        let mgr = {
            let _rt_guard = engine.runtime.enter();
            let store = Arc::new(SqliteL2HeadCacheStore::new(pool));
            match L2CacheManager::new(store, cfg) {
                Ok(m) => Arc::new(m),
                Err(e) => {
                    set_last_error(format!("Failed to initialize L2CacheManager: {e}"));
                    return Ok(LUMINA_ERR_GENERAL);
                }
            }
        };

        let prev = engine
            .l2_cache_manager
            .write()
            .ok()
            .and_then(|mut g| g.replace(Arc::clone(&mgr)));
        if let Some(old_mgr) = prev {
            let _ = engine.runtime.block_on(old_mgr.shutdown());
        }

        if let Some(player) = engine.player_clone() {
            player.set_l2_cache_manager(Some(mgr));
        }

        Ok(LUMINA_OK)
    })
}

/// Writes the total byte footprint currently tracked in `l2_head_chunks` into `*out_bytes`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l2_cache_total_bytes(out_bytes: *mut u64) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_DATABASE, "lumina_l2_cache_total_bytes", || {
        if out_bytes.is_null() {
            set_last_error("out_bytes is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let engine = get_engine();
        let Some(mgr) = ensure_default_l2_cache_manager(&engine) else {
            set_last_error("L2 cache not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        let total = engine
            .runtime
            .block_on(mgr.store().total_cached_bytes())
            .map_err(|e| anyhow::anyhow!("Failed to query L2 total_cached_bytes: {e}"))?;
        unsafe {
            *out_bytes = total;
        }
        Ok(LUMINA_OK)
    })
}

/// Triggers an immediate dual-watermark L2 eviction pass down to `low_watermark_bytes`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l2_cache_evict_now() -> c_int {
    catch_unwind_ffi(LUMINA_ERR_DATABASE, "lumina_l2_cache_evict_now", || {
        let engine = get_engine();
        let Some(mgr) = ensure_default_l2_cache_manager(&engine) else {
            set_last_error("L2 cache not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        engine
            .runtime
            .block_on(mgr.enforce_watermarks())
            .map_err(|e| anyhow::anyhow!("L2 enforce_watermarks failed: {e}"))?;
        Ok(LUMINA_OK)
    })
}

/// Flushes buffered in-memory L2 access timestamps and hit-count deltas to SQLite in one transaction.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l2_cache_flush_access() -> c_int {
    catch_unwind_ffi(LUMINA_ERR_DATABASE, "lumina_l2_cache_flush_access", || {
        let engine = get_engine();
        let Some(mgr) = ensure_default_l2_cache_manager(&engine) else {
            set_last_error("L2 cache not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        engine
            .runtime
            .block_on(mgr.flush_pending_access())
            .map_err(|e| anyhow::anyhow!("L2 flush_pending_access failed: {e}"))?;
        Ok(LUMINA_OK)
    })
}

/// Runs an immediate L2 orphan file and dangling SQLite metadata row sweep.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l2_cache_run_orphan_sweep() -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_DATABASE,
        "lumina_l2_cache_run_orphan_sweep",
        || {
            let engine = get_engine();
            let Some(mgr) = ensure_default_l2_cache_manager(&engine) else {
                set_last_error("L2 cache not initialized");
                return Ok(LUMINA_ERR_NOT_INITIALIZED);
            };

            engine
                .runtime
                .block_on(mgr.run_orphan_sweep())
                .map_err(|e| anyhow::anyhow!("L2 run_orphan_sweep failed: {e}"))?;
            Ok(LUMINA_OK)
        },
    )
}
