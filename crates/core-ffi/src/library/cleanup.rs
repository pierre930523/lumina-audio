use super::ingestion::ensure_ingestion;
use super::{ensure_db_pool, resolve_artwork_cache_dir};
use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, string_to_c_char};
use core_db::DbWriteCoordinator;
use core_providers::{execute_library_cleanup, preview_library_cleanup};
use core_types::LibraryCleanupOptions;
use std::ffi::CStr;
use std::os::raw::c_char;

/// Batch-rescans all non-dismissed skipped files and returns JSON `BatchRescanSkippedResult`.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_rescan_all_skipped_files() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_rescan_all_skipped_files",
        || {
            let engine = get_engine();
            let (pipeline, _) = ensure_ingestion(&engine)?;
            let report = engine
                .runtime
                .block_on(pipeline.rescan_all_skipped_files())
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&report)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Returns read-only `LibraryCleanupPreview` JSON without mutating SQLite or disk.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_preview_cleanup() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_preview_cleanup",
        || {
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let cache_dir = resolve_artwork_cache_dir(&engine);
            let preview = engine
                .runtime
                .block_on(preview_library_cleanup(&pool, &cache_dir))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&preview)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Executes Library Cleanup atomically with offline-root safety guards and returns
/// `LibraryCleanupResult` JSON. Passing null or empty `options_json` uses default options.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_execute_cleanup(options_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_execute_cleanup",
        || {
            let options = if options_json.is_null() {
                LibraryCleanupOptions::default()
            } else {
                let raw = unsafe { CStr::from_ptr(options_json) }.to_str()?.trim();
                if raw.is_empty() {
                    LibraryCleanupOptions::default()
                } else {
                    serde_json::from_str::<LibraryCleanupOptions>(raw)?
                }
            };

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let cache_dir = resolve_artwork_cache_dir(&engine);
            let coord = DbWriteCoordinator::for_pool(&pool);
            let result = engine
                .runtime
                .block_on(execute_library_cleanup(&pool, &coord, &cache_dir, &options))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&result)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
