use std::sync::Arc;

use axum::Json;
use axum::extract::{Path, State};
use core_db::{DbError, SmartPlaylistRepository, SqlitePool};
use core_types::{
    CreateSmartPlaylistRequest, SmartPlaylistDto, SmartPlaylistEvaluationResponse,
    UpdateSmartPlaylistRequest,
};
use serde::Deserialize;
use serde_json::{Value, json};

use super::catalog::hydrate_track_item_dtos;
use super::models::TrackItemDto;
use crate::error::ServerError;
use crate::state::AppState;

#[derive(Debug, Deserialize, Default)]
pub struct DuplicateSmartPlaylistBody {
    #[serde(default)]
    pub name: Option<String>,
}

fn require_pool(state: &AppState) -> Result<&SqlitePool, ServerError> {
    state
        .db_pool
        .as_ref()
        .ok_or_else(|| ServerError::BadRequest("Database not initialized".to_string()))
}

fn map_sp_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// Shared helper usable by both REST handlers and `core-ffi`.
pub async fn evaluate_library_smart_playlist(
    pool: &SqlitePool,
    id: &str,
) -> Result<SmartPlaylistEvaluationResponse<TrackItemDto>, ServerError> {
    let raw = SmartPlaylistRepository::evaluate_smart_playlist_rows(pool, id)
        .await
        .map_err(map_sp_db_err)?;

    let tracks = if raw.tracks.is_empty() {
        Vec::new()
    } else {
        hydrate_track_item_dtos(raw.tracks, None, None).await
    };

    Ok(SmartPlaylistEvaluationResponse {
        playlist: raw.playlist,
        total_matched: raw.total_matched,
        tracks,
    })
}

/// `GET /api/v1/library/smart-playlists`
pub async fn get_smart_playlists(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<SmartPlaylistDto>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let list = SmartPlaylistRepository::list_smart_playlists(pool)
        .await
        .map_err(map_sp_db_err)?;
    Ok(Json(list))
}

/// `POST /api/v1/library/smart-playlists`
pub async fn post_create_smart_playlist(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateSmartPlaylistRequest>,
) -> Result<Json<SmartPlaylistDto>, ServerError> {
    let pool = require_pool(&state)?;
    let created = SmartPlaylistRepository::create_smart_playlist(pool, &req)
        .await
        .map_err(map_sp_db_err)?;
    Ok(Json(created))
}

/// `PUT /api/v1/library/smart-playlists/{id}`
pub async fn put_update_smart_playlist(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(mut req): Json<UpdateSmartPlaylistRequest>,
) -> Result<Json<SmartPlaylistDto>, ServerError> {
    let pool = require_pool(&state)?;
    req.id = id;
    let updated = SmartPlaylistRepository::update_smart_playlist(pool, &req)
        .await
        .map_err(map_sp_db_err)?;
    Ok(Json(updated))
}

/// `DELETE /api/v1/library/smart-playlists/{id}`
pub async fn delete_smart_playlist(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ServerError> {
    let pool = require_pool(&state)?;
    let deleted = SmartPlaylistRepository::delete_smart_playlist(pool, &id)
        .await
        .map_err(map_sp_db_err)?;
    Ok(Json(json!({ "deleted": deleted })))
}

/// `POST /api/v1/library/smart-playlists/{id}/duplicate`
pub async fn post_duplicate_smart_playlist(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    payload: Option<Json<DuplicateSmartPlaylistBody>>,
) -> Result<Json<SmartPlaylistDto>, ServerError> {
    let pool = require_pool(&state)?;
    let new_name = payload.and_then(|Json(b)| b.name);
    let duplicated =
        SmartPlaylistRepository::duplicate_smart_playlist(pool, &id, new_name.as_deref())
            .await
            .map_err(map_sp_db_err)?;
    Ok(Json(duplicated))
}

/// `GET /api/v1/library/smart-playlists/{id}/evaluate`
pub async fn get_evaluate_smart_playlist(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SmartPlaylistEvaluationResponse<TrackItemDto>>, ServerError> {
    let pool = require_pool(&state)?;
    let resp = evaluate_library_smart_playlist(pool, &id).await?;
    Ok(Json(resp))
}
