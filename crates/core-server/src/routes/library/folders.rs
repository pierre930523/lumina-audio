use super::catalog::hydrate_track_item_dtos;
use super::models::TrackItemDto;
use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use core_db::{DbError, FolderRepository, SqlitePool};
use core_types::{FolderContentsResponse, FolderNode};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Deserialize, Default)]
pub struct FolderTrackIdsQuery {
    pub exclude_banned: Option<bool>,
}

/// Track DTO returned inside `FolderContentsResponse`, matching `TrackItemDto` JSON
/// while preserving `album_id` and `artist_id` for direct album/artist navigation.
#[derive(Debug, Serialize, Deserialize)]
pub struct FolderTrackItemDto {
    #[serde(flatten)]
    pub track: TrackItemDto,
    pub album_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_id: Option<String>,
}

fn map_folder_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// Shared helper usable by both REST handlers and `core-ffi`.
pub async fn query_folder_roots(pool: &SqlitePool) -> Result<Vec<FolderNode>, ServerError> {
    FolderRepository::get_folder_roots(pool)
        .await
        .map_err(map_folder_db_err)
}

/// Shared helper usable by both REST handlers and `core-ffi`.
pub async fn query_folder_contents(
    pool: &SqlitePool,
    folder_id: &str,
) -> Result<FolderContentsResponse<FolderTrackItemDto>, ServerError> {
    let raw = FolderRepository::get_folder_contents(pool, folder_id)
        .await
        .map_err(map_folder_db_err)?;

    let link_ids: Vec<(String, Option<String>)> = raw
        .tracks
        .iter()
        .map(|row| (row.alb_id.clone(), row.art_id.clone()))
        .collect();

    let hydrated = hydrate_track_item_dtos(raw.tracks, None, None).await;
    let tracks = hydrated
        .into_iter()
        .zip(link_ids)
        .map(|(track, (album_id, artist_id))| FolderTrackItemDto {
            track,
            album_id,
            artist_id,
        })
        .collect();

    Ok(FolderContentsResponse {
        folder: raw.folder,
        breadcrumbs: raw.breadcrumbs,
        subfolders: raw.subfolders,
        tracks,
    })
}

/// Shared helper usable by both REST handlers and `core-ffi`.
pub async fn query_folder_recursive_track_ids(
    pool: &SqlitePool,
    folder_id: &str,
    exclude_banned: bool,
) -> Result<Vec<String>, ServerError> {
    FolderRepository::get_folder_recursive_track_ids(pool, folder_id, exclude_banned)
        .await
        .map_err(map_folder_db_err)
}

/// `GET /api/v1/library/folders/roots`
pub async fn get_folder_roots(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<FolderNode>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let roots = query_folder_roots(pool).await?;
    Ok(Json(roots))
}

/// `GET /api/v1/library/folders/{id}/contents`
pub async fn get_folder_contents(
    State(state): State<Arc<AppState>>,
    Path(folder_id): Path<String>,
) -> Result<Json<FolderContentsResponse<FolderTrackItemDto>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(format!(
            "Folder {folder_id} not found"
        )));
    };
    let contents = query_folder_contents(pool, &folder_id).await?;
    Ok(Json(contents))
}

/// `GET /api/v1/library/folders/{id}/track-ids?exclude_banned=true|false`
pub async fn get_folder_recursive_track_ids(
    State(state): State<Arc<AppState>>,
    Path(folder_id): Path<String>,
    Query(query): Query<FolderTrackIdsQuery>,
) -> Result<Json<Vec<String>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let exclude_banned = query.exclude_banned.unwrap_or(true);
    let ids = query_folder_recursive_track_ids(pool, &folder_id, exclude_banned).await?;
    Ok(Json(ids))
}
