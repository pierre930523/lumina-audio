use std::path::PathBuf;
use std::sync::Arc;

use axum::Json;
use axum::extract::{Path, Query, State};
use core_audio::analyze_local_track;
use core_db::{DbError, LibraryRepository};
use core_providers::{delete_single_track, reidentify_single_track, rescan_single_track};
use core_types::{
    DeleteTrackRequest, DeleteTrackResult, ReidentifyTrackResult, SetTrackHiddenRequest,
    TrackAnalysisResult, TrackDeleteMode, TrackFileInfo, TrackVisibilityResult,
};
use serde::Deserialize;

use crate::error::ServerError;
use crate::state::AppState;

#[derive(Debug, Deserialize, Default)]
pub struct ReidentifyTrackRequest {
    pub musicbrainz_base_url: Option<String>,
    pub discogs_base_url: Option<String>,
    pub discogs_token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct DeleteTrackQuery {
    pub mode: Option<TrackDeleteMode>,
}

fn map_track_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// `GET /api/v1/library/tracks/{track_id}/file-info`
pub async fn get_track_file_info(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
) -> Result<Json<TrackFileInfo>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let info = LibraryRepository::get_track_file_info(pool, &track_id)
        .await
        .map_err(map_track_db_err)?
        .ok_or_else(|| ServerError::NotFound(format!("Track '{track_id}' not found")))?;
    Ok(Json(info))
}

/// `PUT /api/v1/library/tracks/{track_id}/hidden`
pub async fn put_track_hidden(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    Json(body): Json<SetTrackHiddenRequest>,
) -> Result<Json<TrackVisibilityResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let res = LibraryRepository::set_track_hidden(pool, &track_id, body.is_hidden)
        .await
        .map_err(map_track_db_err)?;
    Ok(Json(res))
}

/// `POST /api/v1/library/tracks/{track_id}/rescan`
pub async fn post_rescan_track(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
) -> Result<Json<TrackFileInfo>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let info = rescan_single_track(pool, &state.artwork_cache_dir, &track_id)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(info))
}

/// `POST /api/v1/library/tracks/{track_id}/reidentify`
pub async fn post_reidentify_track(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    payload: Option<Json<ReidentifyTrackRequest>>,
) -> Result<Json<ReidentifyTrackResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let req = payload.map(|Json(r)| r).unwrap_or_default();
    let mb_url = req.musicbrainz_base_url.filter(|s| !s.trim().is_empty());
    let mb_default = state.mb_base_url.read().await.clone();
    let mb_eff = mb_url.as_deref().unwrap_or(mb_default.as_str());

    let dg_url_opt = req.discogs_base_url.filter(|s| !s.trim().is_empty());
    let dg_default = state.discogs_base_url.read().await.clone();
    let dg_eff = dg_url_opt.as_deref().or_else(|| {
        if dg_default.trim().is_empty() {
            None
        } else {
            Some(dg_default.as_str())
        }
    });

    let dg_token = match req.discogs_token {
        Some(t) if !t.trim().is_empty() => Some(t),
        _ => state.discogs_token.read().await.clone(),
    };

    let res = reidentify_single_track(pool, &track_id, Some(mb_eff), dg_eff, dg_token.as_deref())
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(res))
}

/// `POST /api/v1/library/tracks/{track_id}/reanalyze`
pub async fn post_reanalyze_track(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
) -> Result<Json<TrackAnalysisResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let track = LibraryRepository::find_track_source_by_id(pool, &track_id)
        .await
        .map_err(map_track_db_err)?
        .ok_or_else(|| ServerError::NotFound(format!("Track '{track_id}' not found")))?;

    if !track.provider.as_str().eq_ignore_ascii_case("local") {
        return Err(ServerError::BadRequest(
            "Audio analysis is only supported for local files".to_string(),
        ));
    }

    let path = PathBuf::from(&track.external_track_id);
    let tid = track.id.clone();
    let result = tokio::task::spawn_blocking(move || analyze_local_track(&path, &tid))
        .await
        .map_err(|e| ServerError::Internal(format!("Track analysis task failed: {e}")))?;

    LibraryRepository::save_track_analysis_result(pool, &result)
        .await
        .map_err(map_track_db_err)?;

    Ok(Json(result))
}

/// `POST /api/v1/library/tracks/{track_id}/delete`
pub async fn post_delete_track(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    payload: Option<Json<DeleteTrackRequest>>,
) -> Result<Json<DeleteTrackResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let mode = payload.map(|Json(r)| r.mode).unwrap_or_default();
    let res = delete_single_track(pool, &state.artwork_cache_dir, &track_id, mode)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(res))
}

/// `DELETE /api/v1/library/tracks/{track_id}`
pub async fn delete_track_endpoint(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    Query(query): Query<DeleteTrackQuery>,
    payload: Option<Json<DeleteTrackRequest>>,
) -> Result<Json<DeleteTrackResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let mode = payload
        .map(|Json(r)| r.mode)
        .or(query.mode)
        .unwrap_or_default();
    let res = delete_single_track(pool, &state.artwork_cache_dir, &track_id, mode)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(res))
}
