use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
use std::path::PathBuf;
use std::str::FromStr;

use core_audio::analyze_local_track;
use core_db::LibraryRepository;
use core_providers::{delete_single_track, reidentify_single_track, rescan_single_track};
use core_server::routes::library::query_library_tracks_with_options;
use core_types::{DeleteTrackRequest, TrackDeleteMode};
use serde::Deserialize;

use super::{ensure_db_pool, resolve_artwork_cache_dir};
use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, set_last_error, string_to_c_char};

#[derive(Debug, Deserialize, Default)]
struct FfiReidentifyRequest {
    #[serde(default)]
    musicbrainz_base_url: Option<String>,
    #[serde(default)]
    discogs_base_url: Option<String>,
    #[serde(default)]
    discogs_token: Option<String>,
}

/// Returns a JSON `TrackFileInfo` payload for `track_id`.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_track_file_info(track_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_track_file_info",
        || {
            if track_id.is_null() {
                set_last_error("track_id is null");
                return Ok(std::ptr::null_mut());
            }
            let tid = unsafe { CStr::from_ptr(track_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let info = engine
                .runtime
                .block_on(LibraryRepository::get_track_file_info(&pool, tid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&info)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Sets per-track `is_hidden` visibility (`is_hidden != 0`) and returns `TrackVisibilityResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_track_hidden(
    track_id: *const c_char,
    is_hidden: c_int,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_set_track_hidden",
        || {
            if track_id.is_null() {
                set_last_error("track_id is null");
                return Ok(std::ptr::null_mut());
            }
            let tid = unsafe { CStr::from_ptr(track_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(LibraryRepository::set_track_hidden(
                    &pool,
                    tid,
                    is_hidden != 0,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Rescans a single local track from disk and returns refreshed `TrackFileInfo` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_rescan_track(track_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_rescan_track", || {
        if track_id.is_null() {
            set_last_error("track_id is null");
            return Ok(std::ptr::null_mut());
        }
        let tid = unsafe { CStr::from_ptr(track_id) }.to_str()?.trim();
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let cache_dir = resolve_artwork_cache_dir(&engine);
        let info = engine
            .runtime
            .block_on(rescan_single_track(&pool, &cache_dir, tid))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&info)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Re-identifies a single track against MusicBrainz/Discogs into `cloud_meta_json` without
/// overwriting manual edits, returning `ReidentifyTrackResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_reidentify_track(
    track_id: *const c_char,
    req_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_reidentify_track",
        || {
            if track_id.is_null() {
                set_last_error("track_id is null");
                return Ok(std::ptr::null_mut());
            }
            let tid = unsafe { CStr::from_ptr(track_id) }.to_str()?.trim();
            let req = if req_json.is_null() {
                FfiReidentifyRequest::default()
            } else {
                let raw = unsafe { CStr::from_ptr(req_json) }.to_str()?.trim();
                if raw.is_empty() {
                    FfiReidentifyRequest::default()
                } else {
                    serde_json::from_str::<FfiReidentifyRequest>(raw)?
                }
            };
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(reidentify_single_track(
                    &pool,
                    tid,
                    req.musicbrainz_base_url.as_deref(),
                    req.discogs_base_url.as_deref(),
                    req.discogs_token.as_deref(),
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&res)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Runs offline integrity, loudness, and waveform peak analysis for a single local track,
/// persists the metrics in SQLite, and returns `TrackAnalysisResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_reanalyze_track(track_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_reanalyze_track",
        || {
            if track_id.is_null() {
                set_last_error("track_id is null");
                return Ok(std::ptr::null_mut());
            }
            let tid = unsafe { CStr::from_ptr(track_id) }.to_str()?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let result = engine.runtime.block_on(async {
                let track = LibraryRepository::find_track_source_by_id(&pool, tid)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?
                    .ok_or_else(|| anyhow::anyhow!("Track '{tid}' not found"))?;
                if !track.provider.as_str().eq_ignore_ascii_case("local") {
                    anyhow::bail!("Audio analysis is only supported for local files");
                }
                let path = PathBuf::from(&track.external_track_id);
                let owned_id = track.id.clone();
                let res =
                    tokio::task::spawn_blocking(move || analyze_local_track(&path, &owned_id))
                        .await
                        .map_err(|e| anyhow::anyhow!("Track analysis panicked: {e}"))?;
                LibraryRepository::save_track_analysis_result(&pool, &res)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                Ok::<_, anyhow::Error>(res)
            })?;
            let json_str = serde_json::to_string(&result)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Deletes a single track from the library (and optionally moves the local file to the OS Trash /
/// Recycle Bin when `mode_json` specifies `move_to_trash`), returning `DeleteTrackResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_delete_track(
    track_id: *const c_char,
    mode_json: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_delete_track", || {
        if track_id.is_null() {
            set_last_error("track_id is null");
            return Ok(std::ptr::null_mut());
        }
        let tid = unsafe { CStr::from_ptr(track_id) }.to_str()?.trim();
        let mode = if mode_json.is_null() {
            TrackDeleteMode::LibraryOnly
        } else {
            let raw = unsafe { CStr::from_ptr(mode_json) }.to_str()?.trim();
            if raw.is_empty() {
                TrackDeleteMode::LibraryOnly
            } else if raw.starts_with('{') {
                serde_json::from_str::<DeleteTrackRequest>(raw)?.mode
            } else {
                TrackDeleteMode::from_str(raw).unwrap_or(TrackDeleteMode::LibraryOnly)
            }
        };
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let cache_dir = resolve_artwork_cache_dir(&engine);
        let res = engine
            .runtime
            .block_on(delete_single_track(&pool, &cache_dir, tid, mode))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&res)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Fetches `AlbumDetail` JSON with explicit `include_hidden` option.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_album_detail_filtered(
    album_id: *const c_char,
    include_hidden: c_int,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_album_detail_filtered",
        || {
            if album_id.is_null() {
                set_last_error("album_id is null");
                return Ok(std::ptr::null_mut());
            }
            let aid = unsafe { CStr::from_ptr(album_id) }.to_str()?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let detail = engine
                .runtime
                .block_on(LibraryRepository::get_album_detail_with_options(
                    &pool,
                    aid,
                    include_hidden != 0,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&detail)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Fetches tracks JSON with explicit `include_hidden` option.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_tracks_filtered(
    limit: c_uint,
    include_hidden: c_int,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_tracks_filtered",
        || {
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let eff_limit = if limit == 0 { 200 } else { limit as usize };
            let tracks = engine
                .runtime
                .block_on(query_library_tracks_with_options(
                    &pool,
                    eff_limit,
                    include_hidden != 0,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&tracks)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
