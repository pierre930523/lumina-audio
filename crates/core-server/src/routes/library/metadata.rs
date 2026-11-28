use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use core_db::{DbWriteCoordinator, LibraryRepository};
use core_types::MetadataPolicy;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use std::sync::Arc;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetadataPolicyPayload {
    pub policy: String,
}

fn validate_layered_entity_type(entity_type: &str) -> Result<&str, ServerError> {
    let trimmed = entity_type.trim();
    match trimmed {
        "album" | "track" => Ok(trimmed),
        _ => Err(ServerError::BadRequest(format!(
            "Invalid entity_type '{trimmed}'; expected 'album' or 'track'"
        ))),
    }
}

/// `GET /api/v1/library/settings/metadata-policy`
pub async fn get_default_metadata_policy(
    State(state): State<Arc<AppState>>,
) -> Result<Json<MetadataPolicyPayload>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(MetadataPolicyPayload {
            policy: MetadataPolicy::File.as_str().to_string(),
        }));
    };
    let policy = LibraryRepository::get_default_metadata_policy(pool)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(MetadataPolicyPayload {
        policy: policy.as_str().to_string(),
    }))
}

/// `PUT /api/v1/library/settings/metadata-policy`
pub async fn put_default_metadata_policy(
    State(state): State<Arc<AppState>>,
    Json(req): Json<MetadataPolicyPayload>,
) -> Result<Json<MetadataPolicyPayload>, ServerError> {
    let parsed = MetadataPolicy::from_str(&req.policy)
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    if !parsed.is_concrete() {
        return Err(ServerError::BadRequest(
            "default_metadata_policy must be 'file' or 'cloud'".to_string(),
        ));
    }
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    LibraryRepository::set_default_metadata_policy(pool, parsed)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(MetadataPolicyPayload {
        policy: parsed.as_str().to_string(),
    }))
}

/// `PUT /api/v1/library/metadata/{entity_type}/{entity_id}/policy`
pub async fn put_entity_meta_policy(
    State(state): State<Arc<AppState>>,
    Path((entity_type, entity_id)): Path<(String, String)>,
    Json(req): Json<MetadataPolicyPayload>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let entity_type = validate_layered_entity_type(&entity_type)?;
    let parsed = MetadataPolicy::from_str(&req.policy)
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    let updated = LibraryRepository::set_entity_meta_policy(pool, entity_type, &entity_id, parsed)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    if !updated {
        return Err(ServerError::NotFound(format!(
            "{entity_type} '{entity_id}' not found"
        )));
    }
    Ok(Json(serde_json::json!({
        "ok": true,
        "policy": parsed.as_str(),
    })))
}

/// `PUT /api/v1/library/metadata/{entity_type}/{entity_id}/user-edits`
pub async fn put_entity_user_edits(
    State(state): State<Arc<AppState>>,
    Path((entity_type, entity_id)): Path<(String, String)>,
    Json(edits): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let entity_type = validate_layered_entity_type(&entity_type)?;
    if !edits.is_object() {
        return Err(ServerError::BadRequest(
            "user-edits body must be a JSON object".to_string(),
        ));
    }
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let raw = serde_json::to_string(&edits)
        .map_err(|e| ServerError::BadRequest(format!("invalid user-edits json: {e}")))?;
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    let updated = LibraryRepository::set_entity_user_edits(pool, entity_type, &entity_id, &raw)
        .await
        .map_err(|e| match e {
            core_db::DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
            other => ServerError::Database(other.to_string()),
        })?;
    if !updated {
        return Err(ServerError::NotFound(format!(
            "{entity_type} '{entity_id}' not found"
        )));
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

/// `POST /api/v1/library/metadata/{entity_type}/{entity_id}/revert`
pub async fn post_revert_entity_to_file_meta(
    State(state): State<Arc<AppState>>,
    Path((entity_type, entity_id)): Path<(String, String)>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let entity_type = validate_layered_entity_type(&entity_type)?;
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    let updated = LibraryRepository::revert_entity_to_file_meta(pool, entity_type, &entity_id)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    if !updated {
        return Err(ServerError::NotFound(format!(
            "{entity_type} '{entity_id}' not found"
        )));
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}
