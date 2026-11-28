use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{
    LUMINA_ERR_DATABASE, LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi,
    set_last_error, string_to_c_char,
};
use core_db::open_database;
use core_providers::LibrarySyncService;
use core_server::routes::library::{
    EnrichLibraryRequest, count_albums_under_root, execute_credit_enrichment, query_library_albums,
    query_library_tracks, search_enriched_tracks,
};
use serde_json::json;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
use std::path::Path;

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
        crate::engine::ensure_backup_scheduler(&engine);

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
        let (pipeline, _) = super::ingestion::ensure_ingestion(&engine)?;
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
pub extern "C" fn lumina_library_search(query: *const c_char, limit: c_uint) -> *mut c_char {
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

        let cache_dir = super::resolve_artwork_cache_dir(&engine);

        let res = engine
            .runtime
            .block_on(core_providers::ArtworkManager::resolve_artwork(
                &pool, target_str, max_dim, &cache_dir,
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
                    &pool, target_str, img_path,
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
                    &pool, target_str,
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
            if s.is_empty() { None } else { Some(s) }
        };

        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;

        let report = engine
            .runtime
            .block_on(LibrarySyncService::rescan_tags(&pool, dir_opt, force != 0))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let json_str = serde_json::to_string(&report)?;
        Ok(string_to_c_char(&json_str))
    })
}
