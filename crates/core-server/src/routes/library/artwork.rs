use super::models::{ArtworkOverrideRequest, ArtworkQuery};
use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use std::sync::Arc;

pub async fn get_artwork(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    Query(query): Query<ArtworkQuery>,
) -> Result<axum::response::Response, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(format!(
            "Artwork not found for {track_id}"
        )));
    };
    let cache_dir = &state.artwork_cache_dir;
    let _ = tokio::fs::create_dir_all(cache_dir).await;
    let max_dim = query.max_dim.unwrap_or(0);
    let res = core_providers::ArtworkManager::resolve_artwork(pool, &track_id, max_dim, cache_dir)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;

    if let Some(ref path_str) = res.cache_path {
        let p = std::path::Path::new(path_str);
        if let Ok(bytes) = tokio::fs::read(p).await {
            let mime = res.mime_type.as_deref().unwrap_or_else(|| {
                if path_str.ends_with(".png") {
                    "image/png"
                } else if path_str.ends_with(".webp") {
                    "image/webp"
                } else {
                    "image/jpeg"
                }
            });
            return Ok(axum::response::Response::builder()
                .header(axum::http::header::CONTENT_TYPE, mime)
                .body(axum::body::Body::from(bytes))
                .unwrap());
        }
    }

    Err(ServerError::NotFound(format!(
        "Artwork not found for {track_id}"
    )))
}

pub async fn post_artwork_override(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    Json(req): Json<ArtworkOverrideRequest>,
) -> Result<axum::http::StatusCode, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(
            "Database not initialized".to_string(),
        ));
    };
    core_providers::ArtworkManager::set_user_cover(pool, &track_id, &req.image_path)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(axum::http::StatusCode::OK)
}

pub async fn delete_artwork_override(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
) -> Result<axum::http::StatusCode, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(
            "Database not initialized".to_string(),
        ));
    };
    core_providers::ArtworkManager::clear_user_cover(pool, &track_id)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}
