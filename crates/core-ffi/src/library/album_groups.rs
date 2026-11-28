use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, set_last_error, string_to_c_char};
use core_db::LibraryRepository;
use core_server::routes::library::query_library_albums_with_options;
use core_types::{
    AlbumListOptions, GroupAlternateVersionsRequest, MergeAlbumVersionsRequest,
    SplitAlbumVersionRequest,
};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

/// Lists album summaries with Step 2 options (`AlbumListOptions { limit, offset, include_hidden }`).
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_albums_with_options(
    options_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_albums_with_options",
        || {
            let opts = if options_json.is_null() {
                AlbumListOptions::default()
            } else {
                let raw = unsafe { CStr::from_ptr(options_json) }.to_str()?.trim();
                if raw.is_empty() {
                    AlbumListOptions::default()
                } else {
                    serde_json::from_str::<AlbumListOptions>(raw)?
                }
            };
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let max_items = if opts.limit == 0 {
                100
            } else {
                opts.limit as usize
            };
            let dtos = engine
                .runtime
                .block_on(query_library_albums_with_options(
                    &pool,
                    max_items,
                    opts.offset as usize,
                    opts.include_hidden,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&dtos)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Pins `version_id` as the locked primary version of `group_id` and returns `AlbumVersionOpResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_primary_version(
    group_id: *const c_char,
    version_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_set_primary_version",
        || {
            if group_id.is_null() || version_id.is_null() {
                set_last_error("null pointer passed to lumina_library_set_primary_version");
                return Ok(std::ptr::null_mut());
            }
            let gid = unsafe { CStr::from_ptr(group_id) }.to_str()?.trim();
            let vid = unsafe { CStr::from_ptr(version_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::set_primary_version(&pool, gid, vid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Clears `is_primary_locked` on `group_id` and auto-resolves the best primary version.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_reset_primary_version(group_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_reset_primary_version",
        || {
            if group_id.is_null() {
                set_last_error("group_id is null");
                return Ok(std::ptr::null_mut());
            }
            let gid = unsafe { CStr::from_ptr(group_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::reset_primary_version(&pool, gid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Merges multiple `album_versions` into a single target multi-disc version (`MergeAlbumVersionsRequest`).
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_merge_album_versions(payload_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_merge_album_versions",
        || {
            if payload_json.is_null() {
                set_last_error("payload_json is null");
                return Ok(std::ptr::null_mut());
            }
            let raw = unsafe { CStr::from_ptr(payload_json) }.to_str()?;
            let req: MergeAlbumVersionsRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::merge_album_versions(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Splits an `album_versions` row into track groups (`SplitAlbumVersionRequest`).
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_split_album_version(payload_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_split_album_version",
        || {
            if payload_json.is_null() {
                set_last_error("payload_json is null");
                return Ok(std::ptr::null_mut());
            }
            let raw = unsafe { CStr::from_ptr(payload_json) }.to_str()?;
            let req: SplitAlbumVersionRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::split_album_version(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Groups multiple versions into one album group as alternate versions (`GroupAlternateVersionsRequest`).
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_group_alternate_versions(
    payload_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_group_alternate_versions",
        || {
            if payload_json.is_null() {
                set_last_error("payload_json is null");
                return Ok(std::ptr::null_mut());
            }
            let raw = unsafe { CStr::from_ptr(payload_json) }.to_str()?;
            let req: GroupAlternateVersionsRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::group_as_alternate_versions(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Detaches `version_id` into its own standalone album group locked against auto-merge.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_ungroup_version(version_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_ungroup_version",
        || {
            if version_id.is_null() {
                set_last_error("version_id is null");
                return Ok(std::ptr::null_mut());
            }
            let vid = unsafe { CStr::from_ptr(version_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::ungroup_version(&pool, vid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Hides or unhides `version_id` (`is_hidden != 0`), auto-reselecting primary when needed.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_version_hidden(
    version_id: *const c_char,
    is_hidden: c_int,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_set_version_hidden",
        || {
            if version_id.is_null() {
                set_last_error("version_id is null");
                return Ok(std::ptr::null_mut());
            }
            let vid = unsafe { CStr::from_ptr(version_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::set_version_hidden(
                    &pool,
                    vid,
                    is_hidden != 0,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Clears manual grouping/version/disc locks on `version_id` and its tracks.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_reset_album_grouping(version_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_reset_album_grouping",
        || {
            if version_id.is_null() {
                set_last_error("version_id is null");
                return Ok(std::ptr::null_mut());
            }
            let vid = unsafe { CStr::from_ptr(version_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::reset_album_grouping(&pool, vid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
