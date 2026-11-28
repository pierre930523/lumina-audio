use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, set_last_error, string_to_c_char};
use core_server::routes::library::folders::{
    query_folder_contents, query_folder_recursive_track_ids, query_folder_roots,
};
use std::ffi::CStr;
use std::os::raw::c_char;

/// Returns JSON array of top-level `FolderNode` roots.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_folder_roots() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_folder_roots",
        || {
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let roots = engine
                .runtime
                .block_on(query_folder_roots(&pool))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&roots)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Returns JSON `FolderContentsResponse` for `folder_id`.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_folder_contents(folder_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_folder_contents",
        || {
            if folder_id.is_null() {
                set_last_error("folder_id is null");
                return Ok(std::ptr::null_mut());
            }
            let fid = unsafe { CStr::from_ptr(folder_id) }.to_str()?.trim();
            if fid.is_empty() {
                set_last_error("folder_id is empty");
                return Ok(std::ptr::null_mut());
            }
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                set_last_error("Database not initialized");
                return Ok(std::ptr::null_mut());
            };
            let contents = engine
                .runtime
                .block_on(query_folder_contents(&pool, fid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&contents)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Returns JSON array of all present local track IDs recursively under `folder_id`.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_folder_recursive_track_ids(
    folder_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_folder_recursive_track_ids",
        || {
            if folder_id.is_null() {
                set_last_error("folder_id is null");
                return Ok(std::ptr::null_mut());
            }
            let fid = unsafe { CStr::from_ptr(folder_id) }.to_str()?.trim();
            if fid.is_empty() {
                set_last_error("folder_id is empty");
                return Ok(std::ptr::null_mut());
            }
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let ids = engine
                .runtime
                .block_on(query_folder_recursive_track_ids(&pool, fid, true))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&ids)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
