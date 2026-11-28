use std::sync::Arc;

use axum::Json;
use axum::extract::State;
use core_db::{DbError, PreferenceRepository};
use core_types::{SetEntityPreferenceRequest, SetEntityPreferenceResponse};

use crate::error::ServerError;
use crate::state::AppState;

fn require_pool(state: &AppState) -> Result<&core_db::SqlitePool, ServerError> {
    state
        .db_pool
        .as_ref()
        .ok_or_else(|| ServerError::BadRequest("Database not initialized".to_string()))
}

fn map_pref_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// `PUT /api/v1/library/preferences`
pub async fn put_entity_preference(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SetEntityPreferenceRequest>,
) -> Result<Json<SetEntityPreferenceResponse>, ServerError> {
    let pool = require_pool(&state)?;
    let resp = PreferenceRepository::set_entity_preference(
        pool,
        &req.entity_type,
        &req.entity_id,
        req.preference,
    )
    .await
    .map_err(map_pref_db_err)?;
    Ok(Json(resp))
}
