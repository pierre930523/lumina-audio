use std::sync::Arc;

use axum::Json;
use axum::extract::State;
use core_db::{BulkEditRepository, DbError, SqlitePool};
use core_types::{BulkEditEntityType, BulkEditPatch, BulkEditResult, BulkEditSummary};
use serde::Deserialize;

use crate::error::ServerError;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct BulkEditSummaryRequest {
    pub entity_type: BulkEditEntityType,
    #[serde(default)]
    pub entity_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct BulkEditApplyRequest {
    pub entity_type: BulkEditEntityType,
    #[serde(default)]
    pub entity_ids: Vec<String>,
    #[serde(default)]
    pub patch: BulkEditPatch,
}

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

/// `POST /api/v1/library/bulk-edit/summary`
pub async fn post_bulk_edit_summary(
    State(state): State<Arc<AppState>>,
    Json(req): Json<BulkEditSummaryRequest>,
) -> Result<Json<BulkEditSummary>, ServerError> {
    let pool = require_pool(&state)?;
    let summary = BulkEditRepository::get_bulk_edit_summary(pool, req.entity_type, &req.entity_ids)
        .await
        .map_err(map_db_err)?;
    Ok(Json(summary))
}

/// `POST /api/v1/library/bulk-edit/apply`
pub async fn post_bulk_edit_apply(
    State(state): State<Arc<AppState>>,
    Json(req): Json<BulkEditApplyRequest>,
) -> Result<Json<BulkEditResult>, ServerError> {
    let pool = require_pool(&state)?;
    let result =
        BulkEditRepository::apply_bulk_edit(pool, req.entity_type, &req.entity_ids, &req.patch)
            .await
            .map_err(map_db_err)?;
    Ok(Json(result))
}
