use crate::engine::{get_engine, EngineState};
use crate::error::{
    catch_unwind_ffi, set_last_error, string_to_c_char, LUMINA_ERR_DATABASE, LUMINA_ERR_GENERAL,
    LUMINA_ERR_NULL_POINTER, LUMINA_OK,
};
use core_db::{open_database, open_test_database, IngestionRepository, SqlitePool};
use core_providers::{IngestionPipeline, LibrarySyncService, StorageWatcherManager};
use core_server::routes::library::{
    count_albums_under_root, execute_credit_enrichment, invalidate_dir_mtime_cache,
    query_library_albums, query_library_tracks, retry_skipped_file_by_id, search_enriched_tracks,
    EnrichLibraryRequest,
};
use core_types::{ExternalCatalogIngestBatch, MetadataLayer, ScanProgressEvent, WatchMode};
use serde_json::json;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
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

pub(crate) fn ensure_db_pool(engine: &EngineState) -> anyhow::Result<SqlitePool> {
    if let Ok(guard) = engine.db_pool.read()
        && let Some(ref pool) = *guard
    {
        return Ok(pool.clone());
    }

    let pool = engine.runtime.block_on(open_test_database())?;
    if let Ok(mut guard) = engine.db_pool.write() {
        *guard = Some(pool.clone());
    }
    Ok(pool)
}

fn ensure_ingestion(engine: &EngineState) -> anyhow::Result<(IngestionPipeline, StorageWatcherManager)> {
    let existing_pipeline = engine.ingestion_pipeline.read().ok().and_then(|g| g.clone());
    let existing_watcher = engine.watcher_manager.read().ok().and_then(|g| g.clone());
    if let (Some(p), Some(w)) = (existing_pipeline, existing_watcher) {
        return Ok((p, w));
    }
    let pool = ensure_db_pool(engine)?;
    Ok(engine.init_ingestion_for_pool(pool))
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_init(db_path: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_library_init", || {
        if db_path.is_null() {
            set_last_error("db_path is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }

        let c_str = unsafe { CStr::from_ptr(db_path) };
        let path_str = c_str.to_str().map_err(|e| anyhow::anyhow!(e))?;
        let engine = get_engine();

        let pool = match engine.runtime.block_on(open_database(Path::new(path_str))) {
            Ok(p) => p,
            Err(e) => {
                set_last_error(format!("Failed to open database {}: {}", path_str, e));
                return Ok(LUMINA_ERR_DATABASE);
            }
        };

        if let Ok(mut lock) = engine.db_path.write() {
            *lock = Some(path_str.to_string());
        }
        if let Ok(mut lock) = engine.db_pool.write() {
            *lock = Some(pool.clone());
        }
        let _ = engine.init_ingestion_for_pool(pool);

        Ok(LUMINA_OK)
    })
}

/// Scans `dir_path` recursively via `IngestionPipeline` and returns a JSON scan summary
/// preserving (`scanned_files`, `albums_count`, `tracks_count`, `errors_count`).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_scan_dir(dir_path: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_scan_dir", || {
        if dir_path.is_null() {
            set_last_error("dir_path is null");
            return Ok(std::ptr::null_mut());
        }

        let c_str = unsafe { CStr::from_ptr(dir_path) };
        let path_str = c_str.to_str().map_err(|e| anyhow::anyhow!(e))?.trim();
        if path_str.is_empty() {
            set_last_error("dir_path is empty");
            return Ok(std::ptr::null_mut());
        }

        let engine = get_engine();
        let (pipeline, _) = ensure_ingestion(&engine)?;
        let pool = pipeline.pool().clone();

        let (ev, albums_count) = engine.runtime.block_on(async {
            let ev = pipeline
                .scan_root(Path::new(path_str), "local")
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let albums_count = count_albums_under_root(&pool, path_str).await;
            Ok::<_, anyhow::Error>((ev, albums_count))
        })?;

        let summary = json!({
            "scanned_files": ev.scanned,
            "albums_count": albums_count,
            "tracks_count": ev.added + ev.updated + ev.unchanged,
            "errors_count": ev.skipped,
            "added": ev.added,
            "updated": ev.updated,
            "unchanged": ev.unchanged,
            "skipped": ev.skipped,
            "scan_id": ev.scan_id,
        });
        let json_str = serde_json::to_string(&summary)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Returns a JSON array of tracks stored in the SQLite library.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_tracks(limit: c_uint) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_get_tracks", || {
        let engine = get_engine();
        let max_items = if limit == 0 { 200 } else { limit as usize };

        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            return Ok(string_to_c_char("[]"));
        };

        let tracks = engine
            .runtime
            .block_on(query_library_tracks(&pool, max_items))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&tracks)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_search(
    query: *const c_char,
    limit: c_uint,
) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_search", || {
        if query.is_null() {
            return Ok(string_to_c_char("[]"));
        }

        let c_str = unsafe { CStr::from_ptr(query) };
        let q = c_str.to_str().unwrap_or("").trim();
        if q.is_empty() {
            return Ok(string_to_c_char("[]"));
        }

        let max_items = if limit == 0 { 20 } else { limit as usize };
        let engine = get_engine();

        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        if let Some(pool) = maybe_pool {
            let tracks = engine
                .runtime
                .block_on(search_enriched_tracks(&pool, q, max_items))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&tracks)?;
            return Ok(string_to_c_char(&json_str));
        }

        // Fallback when library DB has not yet been initialized
        let sample_tracks = [
            json!({
                "id": "trk-001",
                "title": "Time",
                "artist": "Pink Floyd",
                "album": "The Dark Side of the Moon",
                "duration_ms": 425000,
                "format": "FLAC 96kHz 24-bit",
                "quality": "lossless"
            }),
            json!({
                "id": "trk-002",
                "title": "Money",
                "artist": "Pink Floyd",
                "album": "The Dark Side of the Moon",
                "duration_ms": 382000,
                "format": "FLAC 96kHz 24-bit",
                "quality": "lossless"
            }),
            json!({
                "id": "trk-003",
                "title": "Comfortably Numb",
                "artist": "Pink Floyd",
                "album": "The Wall",
                "duration_ms": 384000,
                "format": "FLAC 96kHz 24-bit",
                "quality": "lossless"
            }),
        ];

        let query_lower = q.to_lowercase();
        let filtered: Vec<&serde_json::Value> = sample_tracks
            .iter()
            .filter(|t| {
                let title = t["title"].as_str().unwrap_or("").to_lowercase();
                let artist = t["artist"].as_str().unwrap_or("").to_lowercase();
                title.contains(&query_lower) || artist.contains(&query_lower)
            })
            .take(max_items)
            .collect();

        let json_str = serde_json::to_string(&filtered)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_albums(limit: c_uint) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_get_albums", || {
        let engine = get_engine();
        let max_items = if limit == 0 { 100 } else { limit as usize };
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            return Ok(string_to_c_char("[]"));
        };

        let dtos = engine
            .runtime
            .block_on(query_library_albums(&pool, max_items, 0))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&dtos)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_album_detail(album_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_album_detail",
        || {
            if album_id.is_null() {
                set_last_error("album_id is null");
                return Ok(std::ptr::null_mut());
            }
            let aid = unsafe { CStr::from_ptr(album_id).to_str()? };
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let detail = engine
                .runtime
                .block_on(LibrarySyncService::get_album_detail(&pool, aid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&detail)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_artist_detail(artist_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_artist_detail",
        || {
            if artist_id.is_null() {
                set_last_error("artist_id is null");
                return Ok(std::ptr::null_mut());
            }
            let aid = unsafe { CStr::from_ptr(artist_id).to_str()? };
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let detail = engine
                .runtime
                .block_on(LibrarySyncService::get_artist_detail(&pool, aid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&detail)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_enrich_credits(config_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_enrich_credits",
        || {
            let req = if config_json.is_null() {
                EnrichLibraryRequest::default()
            } else {
                let raw = unsafe { CStr::from_ptr(config_json).to_str()? };
                if raw.trim().is_empty() {
                    EnrichLibraryRequest::default()
                } else {
                    serde_json::from_str::<EnrichLibraryRequest>(raw)?
                }
            };
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let report = engine
                .runtime
                .block_on(execute_credit_enrichment(&pool, req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&report)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_deduplicate() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_deduplicate", || {
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let merged = engine
            .runtime
            .block_on(LibrarySyncService::deduplicate_library(&pool))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&json!({ "merged_albums": merged }))?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_artwork_get(target_json: *const c_char, max_dim: u32) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_artwork_get", || {
        if target_json.is_null() {
            set_last_error("target_json is null");
            return Ok(std::ptr::null_mut());
        }
        let target_str = unsafe { CStr::from_ptr(target_json) }.to_str()?.trim();
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;

        let cache_dir = if let Ok(guard) = engine.db_path.read()
            && let Some(ref db_path) = *guard
            && let Some(parent) = Path::new(db_path).parent()
        {
            let dir = parent.join("artwork_cache");
            let _ = std::fs::create_dir_all(&dir);
            dir
        } else {
            let dir = std::env::temp_dir().join("lumina_artwork_cache");
            let _ = std::fs::create_dir_all(&dir);
            dir
        };

        let res = engine
            .runtime
            .block_on(core_providers::ArtworkManager::resolve_artwork(
                &pool,
                target_str,
                max_dim,
                &cache_dir,
            ))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let json_str = serde_json::to_string(&res)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_artwork_set_user_cover(
    target_json: *const c_char,
    image_path: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        crate::error::LUMINA_ERR_GENERAL,
        "lumina_artwork_set_user_cover",
        || {
            if target_json.is_null() || image_path.is_null() {
                set_last_error("null pointer passed to lumina_artwork_set_user_cover");
                return Ok(crate::error::LUMINA_ERR_NULL_POINTER);
            }
            let target_str = unsafe { CStr::from_ptr(target_json) }.to_str()?.trim();
            let img_path = unsafe { CStr::from_ptr(image_path) }.to_str()?.trim();

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;

            engine
                .runtime
                .block_on(core_providers::ArtworkManager::set_user_cover(
                    &pool,
                    target_str,
                    img_path,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;

            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_artwork_clear_user_cover(target_json: *const c_char) -> c_int {
    catch_unwind_ffi(
        crate::error::LUMINA_ERR_GENERAL,
        "lumina_artwork_clear_user_cover",
        || {
            if target_json.is_null() {
                set_last_error("null pointer passed to lumina_artwork_clear_user_cover");
                return Ok(crate::error::LUMINA_ERR_NULL_POINTER);
            }
            let target_str = unsafe { CStr::from_ptr(target_json) }.to_str()?.trim();

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;

            engine
                .runtime
                .block_on(core_providers::ArtworkManager::clear_user_cover(
                    &pool,
                    target_str,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;

            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_rescan_tags(
    dir_or_null: *const c_char,
    force: c_int,
) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_rescan_tags", || {
        let dir_opt = if dir_or_null.is_null() {
            None
        } else {
            let s = unsafe { CStr::from_ptr(dir_or_null) }.to_str()?.trim();
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        };

        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;

        let report = engine
            .runtime
            .block_on(LibrarySyncService::rescan_tags(
                &pool,
                dir_opt,
                force != 0,
            ))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let json_str = serde_json::to_string(&report)?;
        Ok(string_to_c_char(&json_str))
    })
}

// ---------------------------------------------------------------------------
// Layer 1 Ingestion Pipeline — FFI C-ABI Bindings
// ---------------------------------------------------------------------------

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
pub extern "C" fn lumina_library_scan_start(
    dir_path: *const c_char,
    force: c_int,
) -> *mut c_char {
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
        let force_flag = force != 0;

        engine.runtime.spawn(async move {
            if force_flag {
                invalidate_dir_mtime_cache(&pool, &path_str).await;
            }
            let _ = pipeline.scan_root(Path::new(&path_str), "local").await;
        });

        let json_str = serde_json::to_string(&json!({ "scan_id": scan_id }))?;
        Ok(string_to_c_char(&json_str))
    })
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
            let updated = engine
                .runtime
                .block_on(IngestionRepository::dismiss_skipped_file(&pool, id))
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

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_metadata_override(
    entity_type: *const c_char,
    entity_id: *const c_char,
    field_name: *const c_char,
    value_json: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_set_metadata_override",
        || {
            if entity_type.is_null()
                || entity_id.is_null()
                || field_name.is_null()
                || value_json.is_null()
            {
                set_last_error("null pointer passed to lumina_library_set_metadata_override");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let et = unsafe { CStr::from_ptr(entity_type) }.to_str()?.trim();
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();
            let field = unsafe { CStr::from_ptr(field_name) }.to_str()?.trim();
            let val = unsafe { CStr::from_ptr(value_json) }.to_str()?;

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            engine
                .runtime
                .block_on(IngestionRepository::set_metadata_override(
                    &pool,
                    et,
                    eid,
                    field,
                    val,
                    MetadataLayer::UserEdit,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_clear_metadata_override(
    entity_type: *const c_char,
    entity_id: *const c_char,
    field_name: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_clear_metadata_override",
        || {
            if entity_type.is_null() || entity_id.is_null() || field_name.is_null() {
                set_last_error("null pointer passed to lumina_library_clear_metadata_override");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let et = unsafe { CStr::from_ptr(entity_type) }.to_str()?.trim();
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();
            let field = unsafe { CStr::from_ptr(field_name) }.to_str()?.trim();

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let _ = engine
                .runtime
                .block_on(IngestionRepository::clear_metadata_override(
                    &pool, et, eid, field,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_metadata_overrides(
    entity_type: *const c_char,
    entity_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_metadata_overrides",
        || {
            if entity_type.is_null() || entity_id.is_null() {
                set_last_error("null pointer passed to lumina_library_get_metadata_overrides");
                return Ok(std::ptr::null_mut());
            }
            let et = unsafe { CStr::from_ptr(entity_type) }.to_str()?.trim();
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let overrides = engine
                .runtime
                .block_on(IngestionRepository::get_overrides_for_entity(&pool, et, eid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&overrides)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_ingest_external_catalog(batch_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_ingest_external_catalog",
        || {
            if batch_json.is_null() {
                set_last_error("batch_json is null");
                return Ok(std::ptr::null_mut());
            }
            let raw = unsafe { CStr::from_ptr(batch_json) }.to_str()?;
            let batch: ExternalCatalogIngestBatch = serde_json::from_str(raw)?;

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let rep = engine
                .runtime
                .block_on(IngestionPipeline::ingest_external_catalog(&pool, &batch))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let summary = json!({
                "albums_ingested": rep.albums_inserted + rep.albums_matched,
                "tracks_ingested": rep.tracks_upserted,
                "albums_inserted": rep.albums_inserted,
                "albums_matched": rep.albums_matched,
                "versions_upserted": rep.versions_upserted,
            });
            let json_str = serde_json::to_string(&summary)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
