use std::ffi::CStr;
use std::os::raw::c_char;

use core_db::SmartPlaylistRepository;
use core_server::routes::library::smart_playlists::evaluate_library_smart_playlist;
use core_types::{CreateSmartPlaylistRequest, UpdateSmartPlaylistRequest};
use serde_json::json;

use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, string_to_c_char};

fn read_c_str<'a>(ptr: *const c_char, name: &str) -> anyhow::Result<&'a str> {
    if ptr.is_null() {
        anyhow::bail!("{name} is null");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

/// Lists all smart playlists (pinned first, ordered by `sort_order`) as JSON array.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_list_smart_playlists() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_list_smart_playlists",
        || {
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let list = engine
                .runtime
                .block_on(SmartPlaylistRepository::list_smart_playlists(&pool))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&list)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Creates a smart playlist from `CreateSmartPlaylistRequest` JSON and returns `SmartPlaylistDto` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_create_smart_playlist(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_create_smart_playlist",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: CreateSmartPlaylistRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let created = engine
                .runtime
                .block_on(SmartPlaylistRepository::create_smart_playlist(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&created)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Updates smart playlist `id` from `UpdateSmartPlaylistRequest` JSON and returns `SmartPlaylistDto` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_update_smart_playlist(
    id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_update_smart_playlist",
        || {
            let sp_id = read_c_str(id, "id")?.trim();
            let raw = read_c_str(req_json, "req_json")?;
            let mut req: UpdateSmartPlaylistRequest = serde_json::from_str(raw)?;
            req.id = sp_id.to_string();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let updated = engine
                .runtime
                .block_on(SmartPlaylistRepository::update_smart_playlist(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&updated)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Deletes smart playlist `id` and returns `{"deleted": bool}` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_delete_smart_playlist(id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_delete_smart_playlist",
        || {
            let sp_id = read_c_str(id, "id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let deleted = engine
                .runtime
                .block_on(SmartPlaylistRepository::delete_smart_playlist(&pool, sp_id))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&json!({ "deleted": deleted }))?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Duplicates smart playlist `id` and returns the new `SmartPlaylistDto` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_duplicate_smart_playlist(id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_duplicate_smart_playlist",
        || {
            let sp_id = read_c_str(id, "id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let duplicated = engine
                .runtime
                .block_on(SmartPlaylistRepository::duplicate_smart_playlist(
                    &pool, sp_id, None,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&duplicated)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Evaluates smart playlist `id` via FocusQuery and returns `SmartPlaylistEvaluationResponse<TrackItemDto>` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_evaluate_smart_playlist(id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_evaluate_smart_playlist",
        || {
            let sp_id = read_c_str(id, "id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let evaluated = engine
                .runtime
                .block_on(evaluate_library_smart_playlist(&pool, sp_id))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&evaluated)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
