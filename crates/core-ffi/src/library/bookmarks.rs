use std::ffi::CStr;
use std::os::raw::c_char;

use core_db::BookmarkRepository;
use core_types::{CreateBookmarkRequest, ReorderBookmarksRequest, UpdateBookmarkRequest};
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

/// Lists all dynamic bookmarks ordered by `sort_order` as JSON array.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_list_bookmarks() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_list_bookmarks",
        || {
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let list = engine
                .runtime
                .block_on(BookmarkRepository::list_bookmarks(&pool))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&list)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Creates a dynamic bookmark from `CreateBookmarkRequest` JSON and returns `BookmarkDto` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_create_bookmark(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_create_bookmark",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: CreateBookmarkRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let created = engine
                .runtime
                .block_on(BookmarkRepository::create_bookmark(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&created)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Updates bookmark `id` from `UpdateBookmarkRequest` JSON and returns `BookmarkDto` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_update_bookmark(
    id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_update_bookmark",
        || {
            let bid = read_c_str(id, "id")?.trim();
            let raw = read_c_str(req_json, "req_json")?;
            let mut req: UpdateBookmarkRequest = serde_json::from_str(raw)?;
            req.id = bid.to_string();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let updated = engine
                .runtime
                .block_on(BookmarkRepository::update_bookmark(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&updated)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Deletes bookmark `id` and returns `{"deleted": bool}` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_delete_bookmark(id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_delete_bookmark",
        || {
            let bid = read_c_str(id, "id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let deleted = engine
                .runtime
                .block_on(BookmarkRepository::delete_bookmark(&pool, bid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&json!({ "deleted": deleted }))?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Reorders bookmarks from `ReorderBookmarksRequest` JSON and returns ordered `Vec<BookmarkDto>` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_reorder_bookmarks(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_reorder_bookmarks",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: ReorderBookmarksRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let reordered = engine
                .runtime
                .block_on(BookmarkRepository::reorder_bookmarks(
                    &pool,
                    &req.ordered_ids,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&reordered)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
