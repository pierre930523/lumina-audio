use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
    string_to_c_char,
};
use core_db::{DbWriteCoordinator, LibraryRepository};
use core_types::MetadataPolicy;
use serde_json::json;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::str::FromStr;

fn validate_layered_entity_type(et: &str) -> anyhow::Result<&str> {
    let trimmed = et.trim();
    match trimmed {
        "album" | "track" => Ok(trimmed),
        _ => anyhow::bail!("Invalid entity_type '{trimmed}'; expected 'album' or 'track'"),
    }
}

/// Returns JSON `{"policy":"file"|"cloud"}`. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_settings_get_default_metadata_policy() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_settings_get_default_metadata_policy",
        || {
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let policy = engine
                .runtime
                .block_on(LibraryRepository::get_default_metadata_policy(&pool))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&json!({ "policy": policy.as_str() }))?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Sets global `default_metadata_policy` (`"file"` or `"cloud"`), recomputing all
/// `'inherit'` albums/tracks and FTS5 atomically.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_settings_set_default_metadata_policy(policy: *const c_char) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_settings_set_default_metadata_policy",
        || {
            if policy.is_null() {
                set_last_error("policy is null");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let raw = unsafe { CStr::from_ptr(policy) }.to_str()?.trim();
            let parsed =
                MetadataPolicy::from_str(raw).map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if !parsed.is_concrete() {
                set_last_error("default_metadata_policy must be 'file' or 'cloud'");
                return Ok(LUMINA_ERR_GENERAL);
            }

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let coord = DbWriteCoordinator::for_pool(&pool);
            engine
                .runtime
                .block_on(async {
                    let _wg = coord.write_lock().await;
                    LibraryRepository::set_default_metadata_policy(&pool, parsed).await
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        },
    )
}

/// Sets per-entity `meta_policy` (`"inherit"|"file"|"cloud"`) for `"album"` or `"track"`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_entity_meta_policy(
    entity_type: *const c_char,
    entity_id: *const c_char,
    policy: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_set_entity_meta_policy",
        || {
            if entity_type.is_null() || entity_id.is_null() || policy.is_null() {
                set_last_error("null pointer passed to lumina_library_set_entity_meta_policy");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let et =
                validate_layered_entity_type(unsafe { CStr::from_ptr(entity_type) }.to_str()?)?;
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();
            let raw_policy = unsafe { CStr::from_ptr(policy) }.to_str()?.trim();
            let parsed =
                MetadataPolicy::from_str(raw_policy).map_err(|e| anyhow::anyhow!(e.to_string()))?;

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let coord = DbWriteCoordinator::for_pool(&pool);
            let updated = engine
                .runtime
                .block_on(async {
                    let _wg = coord.write_lock().await;
                    LibraryRepository::set_entity_meta_policy(&pool, et, eid, parsed).await
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if updated {
                Ok(LUMINA_OK)
            } else {
                set_last_error(format!("{et} '{eid}' not found"));
                Ok(LUMINA_ERR_GENERAL)
            }
        },
    )
}

/// Writes ONLY `user_edits_json` for `"album"` or `"track"` and recomputes effective fields.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_entity_user_edits(
    entity_type: *const c_char,
    entity_id: *const c_char,
    edits_json: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_set_entity_user_edits",
        || {
            if entity_type.is_null() || entity_id.is_null() || edits_json.is_null() {
                set_last_error("null pointer passed to lumina_library_set_entity_user_edits");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let et =
                validate_layered_entity_type(unsafe { CStr::from_ptr(entity_type) }.to_str()?)?;
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();
            let raw_json = unsafe { CStr::from_ptr(edits_json) }.to_str()?;

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let coord = DbWriteCoordinator::for_pool(&pool);
            let updated = engine
                .runtime
                .block_on(async {
                    let _wg = coord.write_lock().await;
                    LibraryRepository::set_entity_user_edits(&pool, et, eid, raw_json).await
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if updated {
                Ok(LUMINA_OK)
            } else {
                set_last_error(format!("{et} '{eid}' not found"));
                Ok(LUMINA_ERR_GENERAL)
            }
        },
    )
}

/// Clears `user_edits_json` (and legacy `user_edit` overrides) for `"album"` or `"track"` and
/// recomputes effective columns from file/cloud layers.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_revert_entity_to_file_meta(
    entity_type: *const c_char,
    entity_id: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_revert_entity_to_file_meta",
        || {
            if entity_type.is_null() || entity_id.is_null() {
                set_last_error("null pointer passed to lumina_library_revert_entity_to_file_meta");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let et =
                validate_layered_entity_type(unsafe { CStr::from_ptr(entity_type) }.to_str()?)?;
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let coord = DbWriteCoordinator::for_pool(&pool);
            let updated = engine
                .runtime
                .block_on(async {
                    let _wg = coord.write_lock().await;
                    LibraryRepository::revert_entity_to_file_meta(&pool, et, eid).await
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if updated {
                Ok(LUMINA_OK)
            } else {
                set_last_error(format!("{et} '{eid}' not found"));
                Ok(LUMINA_ERR_GENERAL)
            }
        },
    )
}
