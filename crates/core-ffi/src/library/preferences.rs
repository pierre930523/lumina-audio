use std::ffi::CStr;
use std::os::raw::c_char;

use core_db::PreferenceRepository;
use core_types::SetEntityPreferenceRequest;

use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, string_to_c_char};

fn read_c_str<'a>(ptr: *const c_char, name: &str) -> anyhow::Result<&'a str> {
    if ptr.is_null() {
        anyhow::bail!("{name} is null");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

/// Sets tri-state preference (`-1`, `0`, `1`) for `track`, `album_group`, or `artist`.
/// Returns `SetEntityPreferenceResponse` JSON. Caller must free with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_entity_preference(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_set_entity_preference",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: SetEntityPreferenceRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let resp = engine
                .runtime
                .block_on(PreferenceRepository::set_entity_preference(
                    &pool,
                    &req.entity_type,
                    &req.entity_id,
                    req.preference,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&resp)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
