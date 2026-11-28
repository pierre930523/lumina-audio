use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, string_to_c_char};
use core_server::routes::library::focus::{query_library_focus, query_library_focus_facets};
use core_server::routes::library::models::{AlbumSummaryDto, TrackItemDto};
use core_types::{
    FocusEntity, FocusFacetsResponse, FocusQuery, FocusQueryRequest, FocusQueryResponse,
};
use std::ffi::CStr;
use std::os::raw::c_char;

/// Executes a multi-dimensional Focus query (`FocusQueryRequest` JSON) and returns
/// `FocusQueryResponse<AlbumSummaryDto, TrackItemDto>` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_focus_query(request_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_focus_query", || {
        let req = if request_json.is_null() {
            FocusQueryRequest::default()
        } else {
            let raw = unsafe { CStr::from_ptr(request_json) }.to_str()?.trim();
            if raw.is_empty() {
                FocusQueryRequest::default()
            } else {
                serde_json::from_str::<FocusQueryRequest>(raw)?
            }
        };

        let engine = get_engine();
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            let clamped = req.limit.clamp(1, 500);
            let empty: FocusQueryResponse<AlbumSummaryDto, TrackItemDto> = match req.query.entity {
                FocusEntity::Albums => {
                    FocusQueryResponse::for_albums(0, clamped, req.offset, Vec::new())
                }
                FocusEntity::Tracks => {
                    FocusQueryResponse::for_tracks(0, clamped, req.offset, Vec::new())
                }
            };
            let json_str = serde_json::to_string(&empty)?;
            return Ok(string_to_c_char(&json_str));
        };

        let resp = engine
            .runtime
            .block_on(query_library_focus(&pool, &req))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&resp)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Computes live disjunctive cross-filtering facet counts (`FocusQuery` JSON) and returns
/// `FocusFacetsResponse` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_focus_facets(query_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_focus_facets", || {
        let query = if query_json.is_null() {
            FocusQuery::default()
        } else {
            let raw = unsafe { CStr::from_ptr(query_json) }.to_str()?.trim();
            if raw.is_empty() {
                FocusQuery::default()
            } else {
                serde_json::from_str::<FocusQuery>(raw)?
            }
        };

        let engine = get_engine();
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            let json_str = serde_json::to_string(&FocusFacetsResponse::default())?;
            return Ok(string_to_c_char(&json_str));
        };

        let resp = engine
            .runtime
            .block_on(query_library_focus_facets(&pool, &query))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&resp)?;
        Ok(string_to_c_char(&json_str))
    })
}
