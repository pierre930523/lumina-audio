use std::sync::Arc;

use axum::Json;
use axum::extract::{Path, State};
use core_db::{DbError, PlaylistImproverRepository, SqlitePool};
use core_types::{
    AddStaticPlaylistTracksRequest, ApplyPlaylistImprovementsRequest,
    ApplyPlaylistImprovementsResult, CreateStaticPlaylistRequest, PlaylistImprovementReport,
    PlaylistSnapshotRecord, RevertPlaylistSnapshotResult, StaticPlaylistDetail,
    StaticPlaylistSummary,
};
use serde_json::{Value, json};

use crate::error::ServerError;
use crate::state::AppState;

fn require_pool(state: &AppState) -> Result<&SqlitePool, ServerError> {
    state
        .db_pool
        .as_ref()
        .ok_or_else(|| ServerError::BadRequest("Database not initialized".to_string()))
}

fn map_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// `GET /api/v1/library/playlists`
pub async fn get_static_playlists(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<StaticPlaylistSummary>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let list = PlaylistImproverRepository::list_static_playlists(pool)
        .await
        .map_err(map_db_err)?;
    Ok(Json(list))
}

/// `POST /api/v1/library/playlists`
pub async fn post_create_static_playlist(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateStaticPlaylistRequest>,
) -> Result<Json<StaticPlaylistDetail>, ServerError> {
    let pool = require_pool(&state)?;
    let detail = PlaylistImproverRepository::create_static_playlist(pool, &req)
        .await
        .map_err(map_db_err)?;
    Ok(Json(detail))
}

/// `GET /api/v1/library/playlists/{id}`
pub async fn get_static_playlist_detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<StaticPlaylistDetail>, ServerError> {
    let pool = require_pool(&state)?;
    let detail = PlaylistImproverRepository::get_static_playlist_detail(pool, &id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(detail))
}

/// `DELETE /api/v1/library/playlists/{id}`
pub async fn delete_static_playlist(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ServerError> {
    let pool = require_pool(&state)?;
    let deleted = PlaylistImproverRepository::delete_static_playlist(pool, &id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(json!({ "deleted": deleted })))
}

/// `POST /api/v1/library/playlists/{id}/tracks`
pub async fn post_add_tracks_to_static_playlist(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<AddStaticPlaylistTracksRequest>,
) -> Result<Json<StaticPlaylistDetail>, ServerError> {
    let pool = require_pool(&state)?;
    let detail = PlaylistImproverRepository::add_tracks_to_static_playlist(pool, &id, &req)
        .await
        .map_err(map_db_err)?;
    Ok(Json(detail))
}

/// `GET /api/v1/library/playlists/{id}/improvements`
pub async fn get_playlist_improvements(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<PlaylistImprovementReport>, ServerError> {
    let pool = require_pool(&state)?;
    let report = PlaylistImproverRepository::analyze_playlist_improvements(pool, &id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(report))
}

/// `POST /api/v1/library/playlists/{id}/improvements/apply`
pub async fn post_apply_playlist_improvements(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ApplyPlaylistImprovementsRequest>,
) -> Result<Json<ApplyPlaylistImprovementsResult>, ServerError> {
    let pool = require_pool(&state)?;
    let result = PlaylistImproverRepository::apply_playlist_improvements_request(pool, &id, &req)
        .await
        .map_err(map_db_err)?;
    Ok(Json(result))
}

/// `GET /api/v1/library/playlists/{id}/snapshots`
pub async fn get_playlist_snapshots(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Vec<PlaylistSnapshotRecord>>, ServerError> {
    let pool = require_pool(&state)?;
    let snapshots = PlaylistImproverRepository::list_playlist_snapshots(pool, &id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(snapshots))
}

/// `POST /api/v1/library/playlists/snapshots/{snapshot_id}/revert`
pub async fn post_revert_playlist_snapshot(
    State(state): State<Arc<AppState>>,
    Path(snapshot_id): Path<String>,
) -> Result<Json<RevertPlaylistSnapshotResult>, ServerError> {
    let pool = require_pool(&state)?;
    let result = PlaylistImproverRepository::revert_playlist_snapshot(pool, &snapshot_id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(result))
}
