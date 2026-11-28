use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use core_db::{DbError, LibraryRepository};
use core_types::{
    AlbumVersionOpResult, GroupAlternateVersionsRequest, MergeAlbumVersionsRequest,
    SplitAlbumVersionRequest, SplitTargetMode, SplitTrackGroup,
};
use serde::Deserialize;
use std::sync::Arc;

#[derive(Debug, Deserialize)]
pub struct PutPrimaryVersionBody {
    pub version_id: String,
}

#[derive(Debug, Deserialize)]
pub struct PutVersionHiddenBody {
    pub is_hidden: bool,
}

#[derive(Debug, Deserialize)]
pub struct SplitVersionRouteBody {
    #[serde(default)]
    pub version_id: Option<String>,
    pub track_groups: Vec<SplitTrackGroup>,
    #[serde(default)]
    pub target_mode: SplitTargetMode,
}

fn map_version_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// `PUT /api/v1/library/albums/{group_id}/primary-version`
pub async fn put_primary_version(
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<String>,
    Json(body): Json<PutPrimaryVersionBody>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let result = LibraryRepository::set_primary_version(pool, &group_id, &body.version_id)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}

/// `DELETE /api/v1/library/albums/{group_id}/primary-version`
pub async fn delete_primary_version(
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<String>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let result = LibraryRepository::reset_primary_version(pool, &group_id)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}

/// `POST /api/v1/library/versions/merge`
pub async fn post_merge_album_versions(
    State(state): State<Arc<AppState>>,
    Json(req): Json<MergeAlbumVersionsRequest>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let result = LibraryRepository::merge_album_versions(pool, &req)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}

/// `POST /api/v1/library/versions/{version_id}/split`
pub async fn post_split_album_version(
    State(state): State<Arc<AppState>>,
    Path(version_id): Path<String>,
    Json(body): Json<SplitVersionRouteBody>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let effective_version_id = body
        .version_id
        .filter(|v| !v.trim().is_empty())
        .unwrap_or(version_id);
    let req = SplitAlbumVersionRequest {
        version_id: effective_version_id,
        track_groups: body.track_groups,
        target_mode: body.target_mode,
    };
    let result = LibraryRepository::split_album_version(pool, &req)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}

/// `POST /api/v1/library/versions/group`
pub async fn post_group_alternate_versions(
    State(state): State<Arc<AppState>>,
    Json(req): Json<GroupAlternateVersionsRequest>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let result = LibraryRepository::group_as_alternate_versions(pool, &req)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}

/// `POST /api/v1/library/versions/{version_id}/ungroup`
pub async fn post_ungroup_version(
    State(state): State<Arc<AppState>>,
    Path(version_id): Path<String>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let result = LibraryRepository::ungroup_version(pool, &version_id)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}

/// `PUT /api/v1/library/versions/{version_id}/hidden`
pub async fn put_version_hidden(
    State(state): State<Arc<AppState>>,
    Path(version_id): Path<String>,
    Json(body): Json<PutVersionHiddenBody>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let result = LibraryRepository::set_version_hidden(pool, &version_id, body.is_hidden)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}

/// `POST /api/v1/library/versions/{version_id}/reset-grouping`
pub async fn post_reset_album_grouping(
    State(state): State<Arc<AppState>>,
    Path(version_id): Path<String>,
) -> Result<Json<AlbumVersionOpResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let result = LibraryRepository::reset_album_grouping(pool, &version_id)
        .await
        .map_err(map_version_db_err)?;
    Ok(Json(result))
}
