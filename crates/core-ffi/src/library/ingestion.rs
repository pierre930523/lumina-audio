use super::ensure_db_pool;
use crate::engine::{EngineState, get_engine};
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
    string_to_c_char,
};
use core_db::{DbWriteCoordinator, IngestionRepository};
use core_providers::{IngestionPipeline, LibrarySyncService, StorageWatcherManager};
use core_server::routes::library::{invalidate_dir_mtime_cache, retry_skipped_file_by_id};
use core_types::{ScanProgressEvent, WatchMode};
use serde_json::json;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::Path;
use std::str::FromStr;
use std::sync::RwLock;

pub type ScanProgressCallback = extern "C" fn(*const c_char);

static SCAN_PROGRESS_CB: RwLock<Option<ScanProgressCallback>> = RwLock::new(None);

pub(crate) fn dispatch_scan_progress_event(event: &ScanProgressEvent) {
    let Ok(guard) = SCAN_PROGRESS_CB.read() else {
        return;
    };
    let Some(cb) = *guard else {
        return;
    };
    if let Ok(json_str) = serde_json::to_string(event) {
        let ptr = string_to_c_char(&json_str);
        if !ptr.is_null() {
            cb(ptr as *const c_char);
        }
    }
}

pub(crate) fn ensure_ingestion(
    engine: &EngineState,
) -> anyhow::Result<(IngestionPipeline, StorageWatcherManager)> {
    let existing_pipeline = engine
        .ingestion_pipeline
        .read()
        .ok()
        .and_then(|g| g.clone());
    let existing_watcher = engine.watcher_manager.read().ok().and_then(|g| g.clone());
    if let (Some(p), Some(w)) = (existing_pipeline, existing_watcher) {
        return Ok((p, w));
    }
    let pool = ensure_db_pool(engine)?;
    Ok(engine.init_ingestion_for_pool(pool))
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_scan_progress_callback(
    cb: Option<ScanProgressCallback>,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_set_scan_progress_callback",
        || {
            let mut guard = SCAN_PROGRESS_CB
                .write()
                .map_err(|_| anyhow::anyhow!("SCAN_PROGRESS_CB lock poisoned"))?;
            *guard = cb;
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_scan_start(dir_path: *const c_char, force: c_int) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_scan_start", || {
        if dir_path.is_null() {
            set_last_error("dir_path is null");
            return Ok(std::ptr::null_mut());
        }
        let path_str = unsafe { CStr::from_ptr(dir_path) }
            .to_str()?
            .trim()
            .to_string();
        if path_str.is_empty() {
            set_last_error("dir_path is empty");
            return Ok(std::ptr::null_mut());
        }

        let engine = get_engine();
        let (pipeline, _) = ensure_ingestion(&engine)?;
        let pool = pipeline.pool().clone();
        let scan_id = uuid::Uuid::new_v4().to_string();
        let scan_id_task = scan_id.clone();
        let force_flag = force != 0;

        engine.runtime.spawn(async move {
            if force_flag {
                invalidate_dir_mtime_cache(&pool, &path_str).await;
            }
            let _ = pipeline
                .scan_root_with_id(Path::new(&path_str), "local", Some(scan_id_task))
                .await;
        });

        let json_str = serde_json::to_string(&json!({ "scan_id": scan_id }))?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_rescan_start(
    dir_or_null: *const c_char,
    force: c_int,
) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_rescan_start", || {
        let dir_opt = if dir_or_null.is_null() {
            None
        } else {
            let s = unsafe { CStr::from_ptr(dir_or_null) }.to_str()?.trim();
            if s.is_empty() {
                None
            } else {
                Some(s.to_string())
            }
        };

        let engine = get_engine();
        let (pipeline, _) = ensure_ingestion(&engine)?;
        let pool = pipeline.pool().clone();
        let progress_tx = pipeline.progress_sender();
        let scan_id = uuid::Uuid::new_v4().to_string();
        let scan_id_task = scan_id.clone();
        let force_flag = force != 0;

        engine.runtime.spawn(async move {
            let res = LibrarySyncService::rescan_tags_with_progress(
                &pool,
                dir_opt.as_deref(),
                force_flag,
                Some(&progress_tx),
                Some(scan_id_task.clone()),
            )
            .await;
            if let Err(err) = res {
                let _ = progress_tx.send(ScanProgressEvent {
                    scan_id: scan_id_task,
                    root_path: dir_opt.unwrap_or_else(|| "local".to_string()),
                    state: core_types::ScanLifecycleState::Failed,
                    message: Some(err.to_string()),
                    ..Default::default()
                });
            }
        });

        let json_str = serde_json::to_string(&json!({ "scan_id": scan_id }))?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_force_rebuild_start(
    dir_or_null: *const c_char,
    _force: c_int,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_force_rebuild_start",
        || {
            let dir_opt = if dir_or_null.is_null() {
                None
            } else {
                let s = unsafe { CStr::from_ptr(dir_or_null) }.to_str()?.trim();
                if s.is_empty() {
                    None
                } else {
                    Some(s.to_string())
                }
            };

            let engine = get_engine();
            let (pipeline, _) = ensure_ingestion(&engine)?;
            let scan_id = uuid::Uuid::new_v4().to_string();
            let scan_id_task = scan_id.clone();

            engine.runtime.spawn(async move {
                let _ = pipeline
                    .force_rebuild_library(dir_opt.as_deref(), Some(scan_id_task))
                    .await;
            });

            let json_str = serde_json::to_string(&json!({ "scan_id": scan_id }))?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_watch_add(
    root_path: *const c_char,
    watch_mode: *const c_char,
    poll_interval_sec: u32,
) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_watch_add", || {
        if root_path.is_null() {
            set_last_error("root_path is null");
            return Ok(std::ptr::null_mut());
        }
        let path_str = unsafe { CStr::from_ptr(root_path) }.to_str()?.trim();
        if path_str.is_empty() {
            set_last_error("root_path is empty");
            return Ok(std::ptr::null_mut());
        }
        let mode = if watch_mode.is_null() {
            WatchMode::NativeOs
        } else {
            let m = unsafe { CStr::from_ptr(watch_mode) }.to_str()?.trim();
            if m.is_empty() {
                WatchMode::NativeOs
            } else {
                WatchMode::from_str(m).map_err(|e| anyhow::anyhow!(e.to_string()))?
            }
        };

        let engine = get_engine();
        let (_, watcher) = ensure_ingestion(&engine)?;
        let interval = if poll_interval_sec == 0 {
            300
        } else {
            poll_interval_sec
        };
        let stored = engine
            .runtime
            .block_on(watcher.add_root("local", Path::new(path_str), mode, interval))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&stored)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_watch_remove(root_path: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_library_watch_remove", || {
        if root_path.is_null() {
            set_last_error("root_path is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let target = unsafe { CStr::from_ptr(root_path) }.to_str()?.trim();
        if target.is_empty() {
            set_last_error("root_path is empty");
            return Ok(LUMINA_ERR_GENERAL);
        }
        let engine = get_engine();
        let (_, watcher) = ensure_ingestion(&engine)?;
        let _removed = engine
            .runtime
            .block_on(
                core_server::routes::library::remove_watched_root_by_id_or_path(&watcher, target),
            )
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_watch_list() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_watch_list", || {
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let roots = engine
            .runtime
            .block_on(IngestionRepository::list_watched_roots(&pool))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&roots)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_skipped_files(include_dismissed: c_int) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_skipped_files",
        || {
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let skipped = engine
                .runtime
                .block_on(IngestionRepository::list_skipped_files(
                    &pool,
                    include_dismissed != 0,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&skipped)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_dismiss_skipped_file(skipped_id: *const c_char) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_dismiss_skipped_file",
        || {
            if skipped_id.is_null() {
                set_last_error("skipped_id is null");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let id = unsafe { CStr::from_ptr(skipped_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let coord = DbWriteCoordinator::for_pool(&pool);
            let updated = engine
                .runtime
                .block_on(async {
                    let _wg = coord.write_lock().await;
                    IngestionRepository::dismiss_skipped_file(&pool, id).await
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if updated {
                Ok(LUMINA_OK)
            } else {
                set_last_error(format!("Skipped file '{id}' not found"));
                Ok(LUMINA_ERR_GENERAL)
            }
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_retry_skipped_file(skipped_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_retry_skipped_file",
        || {
            if skipped_id.is_null() {
                set_last_error("skipped_id is null");
                return Ok(std::ptr::null_mut());
            }
            let id = unsafe { CStr::from_ptr(skipped_id) }.to_str()?.trim();
            let engine = get_engine();
            let (pipeline, _) = ensure_ingestion(&engine)?;
            let resp = engine
                .runtime
                .block_on(retry_skipped_file_by_id(&pipeline, id))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&resp)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
