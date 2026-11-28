use std::io::ErrorKind;
use std::sync::Arc;

use axum::Json;
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE};
use axum::response::Response;
use core_db::{AlbumAssetRepository, DbError, SqlitePool};
use core_providers::ProviderError;
use core_types::AlbumAssetsResponse;

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

fn map_provider_err(err: ProviderError) -> ServerError {
    match err {
        ProviderError::Io(ref io_err) if io_err.kind() == ErrorKind::NotFound => {
            ServerError::NotFound(err.to_string())
        }
        ProviderError::TrackNotFound(msg) => ServerError::NotFound(msg),
        ProviderError::InvalidConfig(msg) => ServerError::BadRequest(msg),
        other => ServerError::Internal(other.to_string()),
    }
}

/// `GET /api/v1/library/albums/{id}/assets`
pub async fn get_album_assets(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<AlbumAssetsResponse>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(AlbumAssetsResponse {
            album_version_id: id,
            pdfs: Vec::new(),
            images: Vec::new(),
            total_count: 0,
        }));
    };
    let resp = AlbumAssetRepository::get_album_assets(pool, &id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(resp))
}

/// `GET /api/v1/library/assets/{asset_id}/content`
pub async fn get_album_asset_content(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
) -> Result<Response, ServerError> {
    let pool = require_pool(&state)?;
    let (mime_type, _display_name, bytes) = core_providers::read_album_asset_bytes(pool, &asset_id)
        .await
        .map_err(map_provider_err)?;

    Response::builder()
        .header(CONTENT_TYPE, mime_type)
        .header(CACHE_CONTROL, "private, max-age=3600")
        .body(Body::from(bytes))
        .map_err(|e| ServerError::Internal(format!("Failed to build asset response: {e}")))
}
