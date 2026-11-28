use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use core_providers::{LyricsManager, LyricsResult, LyricsTarget};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Deserialize)]
pub struct LyricsOverrideRequest {
    pub file_path: String,
}

#[derive(Debug, Serialize)]
pub struct LyricsActionResponse {
    pub status: String,
}

pub async fn get_lyrics(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
) -> Result<Json<LyricsResult>, ServerError> {
    let target = LyricsTarget {
        track_id: Some(track_id),
        file_path: None,
    };
    let res = LyricsManager::get_lyrics(&target, state.db_pool.as_ref()).await;
    Ok(Json(res))
}

pub async fn post_lyrics_override(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    Json(req): Json<LyricsOverrideRequest>,
) -> Result<StatusCode, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let target = LyricsTarget {
        track_id: Some(track_id),
        file_path: None,
    };
    LyricsManager::set_user_override(&target, &req.file_path, pool)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(StatusCode::OK)
}

pub async fn delete_lyrics_override(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
) -> Result<StatusCode, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let target = LyricsTarget {
        track_id: Some(track_id),
        file_path: None,
    };
    LyricsManager::clear_user_override(&target, pool)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(StatusCode::NO_CONTENT)
}
