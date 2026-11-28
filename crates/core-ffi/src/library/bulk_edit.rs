use std::ffi::CStr;
use std::os::raw::c_char;

use core_db::BulkEditRepository;
use core_types::{BulkEditEntityType, BulkEditPatch};
use serde::Deserialize;

use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, string_to_c_char};

#[derive(Debug, Deserialize)]
struct FfiBulkEditSummaryPayload {
    entity_type: BulkEditEntityType,
    #[serde(default)]
    entity_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct FfiBulkEditApplyPayload {
    entity_type: BulkEditEntityType,
    #[serde(default)]
    entity_ids: Vec<String>,
    #[serde(default)]
    patch: BulkEditPatch,
}

fn read_c_str<'a>(ptr: *const c_char, name: &str) -> anyhow::Result<&'a str> {
    if ptr.is_null() {
        anyhow::bail!("{name} is null");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

/// Computes a tri-state `BulkEditSummary` JSON for selected albums or tracks.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_bulk_edit_summary(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_bulk_edit_summary",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: FfiBulkEditSummaryPayload = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let summary = engine
                .runtime
                .block_on(BulkEditRepository::get_bulk_edit_summary(
                    &pool,
                    req.entity_type,
                    &req.entity_ids,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&summary)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Atomically applies a non-destructive `BulkEditPatch` and returns `BulkEditResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_apply_bulk_edit(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_apply_bulk_edit",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: FfiBulkEditApplyPayload = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let result = engine
                .runtime
                .block_on(BulkEditRepository::apply_bulk_edit(
                    &pool,
                    req.entity_type,
                    &req.entity_ids,
                    &req.patch,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&result)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
