use std::ffi::CStr;
use std::os::raw::c_char;

use core_db::ListenLaterRepository;
use core_server::routes::library::listen_later::{
    normalize_status_filter, promote_listen_later_item,
};
use core_types::{
    AddListenLaterRequest, PromoteListenLaterRequest, UpdateListenLaterNoteRequest,
    UpdateListenLaterStatusRequest,
};
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

/// Lists Listen Later items filtered by optional `status_nullable` (`null`/`""`/`"all"`/`"pending"`/`"listened"`).
/// Returns `Vec<ListenLaterItemDto>` JSON. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_list_listen_later(status_nullable: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_list_listen_later",
        || {
            let raw_status = if status_nullable.is_null() {
                None
            } else {
                Some(unsafe { CStr::from_ptr(status_nullable) }.to_str()?)
            };
            let status = normalize_status_filter(raw_status);
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let list = engine
                .runtime
                .block_on(ListenLaterRepository::list_listen_later(&pool, status))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&list)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Adds a library or external streaming item to Listen Later (`AddListenLaterRequest` JSON).
/// Returns `ListenLaterItemDto` JSON. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_add_listen_later(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_add_listen_later",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: AddListenLaterRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let item = engine
                .runtime
                .block_on(ListenLaterRepository::add_to_listen_later(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&item)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Marks Listen Later item `id` status (`UpdateListenLaterStatusRequest` JSON).
/// Returns `ListenLaterItemDto` JSON. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_mark_listen_later_status(
    id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_mark_listen_later_status",
        || {
            let item_id = read_c_str(id, "id")?.trim();
            let raw = read_c_str(req_json, "req_json")?;
            let req: UpdateListenLaterStatusRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let item = engine
                .runtime
                .block_on(ListenLaterRepository::mark_listen_later_status(
                    &pool,
                    item_id,
                    &req.status,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&item)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Updates Listen Later item `id` note (`UpdateListenLaterNoteRequest` JSON).
/// Returns `ListenLaterItemDto` JSON. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_update_listen_later_note(
    id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_update_listen_later_note",
        || {
            let item_id = read_c_str(id, "id")?.trim();
            let raw = read_c_str(req_json, "req_json")?;
            let req: UpdateListenLaterNoteRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let item = engine
                .runtime
                .block_on(ListenLaterRepository::update_listen_later_note(
                    &pool, item_id, &req.note,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&item)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Removes Listen Later item `id` and returns `{"deleted": bool}` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_remove_listen_later(id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_remove_listen_later",
        || {
            let item_id = read_c_str(id, "id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let deleted = engine
                .runtime
                .block_on(ListenLaterRepository::remove_listen_later(&pool, item_id))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&json!({ "deleted": deleted }))?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Promotes external Listen Later item `id` into the local library (`PromoteListenLaterRequest` JSON).
/// Returns `PromoteListenLaterResponse` JSON. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_promote_listen_later(
    id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_promote_listen_later",
        || {
            let item_id = read_c_str(id, "id")?.trim();
            let raw = read_c_str(req_json, "req_json")?;
            let req: PromoteListenLaterRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let resp = engine
                .runtime
                .block_on(promote_listen_later_item(&pool, item_id, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&resp)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
