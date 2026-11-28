use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

use core_db::PlaylistImproverRepository;
use core_types::{
    AddStaticPlaylistTracksRequest, ApplyPlaylistImprovementsRequest, CreateStaticPlaylistRequest,
};

use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
    string_to_c_char,
};

fn read_c_str<'a>(ptr: *const c_char, name: &str) -> anyhow::Result<&'a str> {
    if ptr.is_null() {
        anyhow::bail!("{name} is null");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

/// Lists all static playlists as a JSON array of `StaticPlaylistSummary`.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_list_static_playlists() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_list_static_playlists",
        || {
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let list = engine
                .runtime
                .block_on(PlaylistImproverRepository::list_static_playlists(&pool))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&list)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Creates a static playlist from `CreateStaticPlaylistRequest` JSON and returns `StaticPlaylistDetail` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_create_static_playlist(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_create_static_playlist",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: CreateStaticPlaylistRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let detail = engine
                .runtime
                .block_on(PlaylistImproverRepository::create_static_playlist(
                    &pool, &req,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&detail)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Fetches a static playlist detail as `StaticPlaylistDetail` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_static_playlist_detail(
    playlist_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_static_playlist_detail",
        || {
            let pid = read_c_str(playlist_id, "playlist_id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let detail = engine
                .runtime
                .block_on(PlaylistImproverRepository::get_static_playlist_detail(
                    &pool, pid,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&detail)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Deletes a static playlist by ID. Returns `LUMINA_OK` (0) if deleted.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_delete_static_playlist(playlist_id: *const c_char) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_delete_static_playlist",
        || {
            if playlist_id.is_null() {
                set_last_error("playlist_id is null");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let pid = unsafe { CStr::from_ptr(playlist_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let deleted = engine
                .runtime
                .block_on(PlaylistImproverRepository::delete_static_playlist(
                    &pool, pid,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if deleted {
                Ok(LUMINA_OK)
            } else {
                set_last_error(format!("Static playlist '{pid}' not found"));
                Ok(LUMINA_ERR_GENERAL)
            }
        },
    )
}

/// Appends tracks to a static playlist and returns the updated `StaticPlaylistDetail` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_add_tracks_to_static_playlist(
    playlist_id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_add_tracks_to_static_playlist",
        || {
            let pid = read_c_str(playlist_id, "playlist_id")?.trim();
            let raw = read_c_str(req_json, "req_json")?;
            let req: AddStaticPlaylistTracksRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let detail = engine
                .runtime
                .block_on(PlaylistImproverRepository::add_tracks_to_static_playlist(
                    &pool, pid, &req,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&detail)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Runs read-only Playlist Improver analysis and returns `PlaylistImprovementReport` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_analyze_playlist_improvements(
    playlist_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_analyze_playlist_improvements",
        || {
            let pid = read_c_str(playlist_id, "playlist_id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let report = engine
                .runtime
                .block_on(PlaylistImproverRepository::analyze_playlist_improvements(
                    &pool, pid,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&report)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Atomically snapshots and applies selected playlist improvements, returning `ApplyPlaylistImprovementsResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_apply_playlist_improvements(
    playlist_id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_apply_playlist_improvements",
        || {
            let pid = read_c_str(playlist_id, "playlist_id")?.trim();
            let raw = read_c_str(req_json, "req_json")?;
            let req: ApplyPlaylistImprovementsRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let result = engine
                .runtime
                .block_on(
                    PlaylistImproverRepository::apply_playlist_improvements_request(
                        &pool, pid, &req,
                    ),
                )
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&result)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Lists undo snapshots for a static playlist as a JSON array of `PlaylistSnapshotRecord`.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_list_playlist_snapshots(
    playlist_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_list_playlist_snapshots",
        || {
            let pid = read_c_str(playlist_id, "playlist_id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let snapshots = engine
                .runtime
                .block_on(PlaylistImproverRepository::list_playlist_snapshots(
                    &pool, pid,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&snapshots)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Reverts a static playlist to a saved snapshot and returns `RevertPlaylistSnapshotResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_revert_playlist_snapshot(
    snapshot_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_revert_playlist_snapshot",
        || {
            let sid = read_c_str(snapshot_id, "snapshot_id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let result = engine
                .runtime
                .block_on(PlaylistImproverRepository::revert_playlist_snapshot(
                    &pool, sid,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&result)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
