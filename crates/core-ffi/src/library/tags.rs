use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::str::FromStr;

use core_db::repository::tags::TagRepository;
use core_types::{
    BatchTagItemsRequest, CreateTagRequest, TagEntityType, TagLinkRequest, UpdateTagRequest,
};

use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{LUMINA_ERR_GENERAL, LUMINA_OK, catch_unwind_ffi, string_to_c_char};

fn read_c_str<'a>(ptr: *const c_char, name: &str) -> anyhow::Result<&'a str> {
    if ptr.is_null() {
        anyhow::bail!("{name} is null");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

/// Lists all custom tags with DAG links and direct/recursive item counts as JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_list_tags() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_list_tags", || {
        let engine = get_engine();
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            return Ok(string_to_c_char("[]"));
        };
        let tags = engine
            .runtime
            .block_on(TagRepository::list_tags(&pool))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&tags)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Creates a tag from `CreateTagRequest` JSON and returns `TagSummary` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_create_tag(payload_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_create_tag", || {
        let raw = read_c_str(payload_json, "payload_json")?;
        let req: CreateTagRequest = serde_json::from_str(raw)?;
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let created = engine
            .runtime
            .block_on(TagRepository::create_tag(&pool, &req))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&created)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Updates a tag from `UpdateTagRequest` JSON and returns `TagSummary` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_update_tag(payload_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_update_tag", || {
        let raw = read_c_str(payload_json, "payload_json")?;
        let req: UpdateTagRequest = serde_json::from_str(raw)?;
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let updated = engine
            .runtime
            .block_on(TagRepository::update_tag(&pool, &req))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&updated)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Deletes a tag by ID (cascading links and items). Returns `0` on ok, `-1` on error.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_delete_tag(tag_id: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_library_delete_tag", || {
        let id = read_c_str(tag_id, "tag_id")?.trim();
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let _ = engine
            .runtime
            .block_on(TagRepository::delete_tag(&pool, id))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(LUMINA_OK)
    })
}

/// Links a parent tag to a child tag (`TagLinkRequest` JSON) with DAG cycle detection.
/// Returns `0` on ok, `-1` on error (preserving `"TagCycleDetected"` in last error).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_link_tag_parent(payload_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_library_link_tag_parent", || {
        let raw = read_c_str(payload_json, "payload_json")?;
        let req: TagLinkRequest = serde_json::from_str(raw)?;
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        engine
            .runtime
            .block_on(TagRepository::link_tag_parent(&pool, &req))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(LUMINA_OK)
    })
}

/// Unlinks a parent-child tag edge (`TagLinkRequest` JSON). Returns `0` on ok, `-1` on error.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_unlink_tag_parent(payload_json: *const c_char) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_unlink_tag_parent",
        || {
            let raw = read_c_str(payload_json, "payload_json")?;
            let req: TagLinkRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let _ = engine
                .runtime
                .block_on(TagRepository::unlink_tag_parent(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        },
    )
}

/// Batch adds or removes tag associations (`BatchTagItemsRequest` JSON).
/// Returns `BatchTagItemsResponse` JSON. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_batch_tag_items(payload_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_batch_tag_items",
        || {
            let raw = read_c_str(payload_json, "payload_json")?;
            let req: BatchTagItemsRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let resp = engine
                .runtime
                .block_on(TagRepository::batch_update_tag_items(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&resp)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Lists all tags attached to `(entity_type, entity_id)` as `Vec<TagSummary>` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_entity_tags(
    entity_type: *const c_char,
    entity_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_entity_tags",
        || {
            let et_raw = read_c_str(entity_type, "entity_type")?;
            let eid = read_c_str(entity_id, "entity_id")?.trim();
            let parsed_type =
                TagEntityType::from_str(et_raw).map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let tags = engine
                .runtime
                .block_on(TagRepository::get_entity_tags(&pool, parsed_type, eid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&tags)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
