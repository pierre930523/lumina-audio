use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::State;
use core_db::DbWriteCoordinator;
use core_providers::{IngestionPipeline, execute_library_cleanup, preview_library_cleanup};
use core_types::{
    BatchRescanSkippedResult, LibraryCleanupOptions, LibraryCleanupPreview, LibraryCleanupResult,
};
use std::sync::Arc;

/// `POST /api/v1/library/skipped/rescan-all`
pub async fn post_rescan_all_skipped_files(
    State(state): State<Arc<AppState>>,
) -> Result<Json<BatchRescanSkippedResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    state.ensure_scan_progress_relay();
    let pipeline = state
        .ingestion_pipeline
        .clone()
        .unwrap_or_else(|| IngestionPipeline::with_defaults(pool.clone()));
    let result = pipeline
        .rescan_all_skipped_files()
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(result))
}

/// `GET /api/v1/library/cleanup/preview`
pub async fn get_library_cleanup_preview(
    State(state): State<Arc<AppState>>,
) -> Result<Json<LibraryCleanupPreview>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let preview = preview_library_cleanup(pool, &state.artwork_cache_dir)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(preview))
}

/// `POST /api/v1/library/cleanup/execute`
pub async fn post_library_cleanup_execute(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<LibraryCleanupOptions>>,
) -> Result<Json<LibraryCleanupResult>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let options = payload.map(|Json(o)| o).unwrap_or_default();
    let coord = DbWriteCoordinator::for_pool(pool);
    let result = execute_library_cleanup(pool, &coord, &state.artwork_cache_dir, &options)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(result))
}
