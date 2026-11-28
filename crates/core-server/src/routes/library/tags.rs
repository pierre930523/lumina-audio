use std::str::FromStr;
use std::sync::Arc;

use axum::Json;
use axum::extract::{Path, State};
use core_db::DbError;
use core_db::repository::tags::TagRepository;
use core_types::{
    BatchTagItemsRequest, BatchTagItemsResponse, CreateTagRequest, TagEntityType, TagLinkRequest,
    TagSummary, UpdateTagRequest,
};
use serde_json::{Value, json};

use crate::error::ServerError;
use crate::state::AppState;

fn require_pool(state: &AppState) -> Result<&core_db::SqlitePool, ServerError> {
    state
        .db_pool
        .as_ref()
        .ok_or_else(|| ServerError::BadRequest("Database not initialized".to_string()))
}

fn map_tag_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// `GET /api/v1/library/tags`
pub async fn get_tags(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<TagSummary>>, ServerError> {
    let pool = require_pool(&state)?;
    let tags = TagRepository::list_tags(pool)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(tags))
}

/// `POST /api/v1/library/tags`
pub async fn post_create_tag(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateTagRequest>,
) -> Result<Json<TagSummary>, ServerError> {
    let pool = require_pool(&state)?;
    let created = TagRepository::create_tag(pool, &req)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(created))
}

/// `PATCH /api/v1/library/tags/{id}`
pub async fn patch_update_tag(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(mut req): Json<UpdateTagRequest>,
) -> Result<Json<TagSummary>, ServerError> {
    let pool = require_pool(&state)?;
    req.id = id;
    let updated = TagRepository::update_tag(pool, &req)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(updated))
}

/// `DELETE /api/v1/library/tags/{id}`
pub async fn delete_tag(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ServerError> {
    let pool = require_pool(&state)?;
    let deleted = TagRepository::delete_tag(pool, &id)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(json!({ "deleted": deleted })))
}

/// `POST /api/v1/library/tags/links`
pub async fn post_link_tag_parent(
    State(state): State<Arc<AppState>>,
    Json(req): Json<TagLinkRequest>,
) -> Result<Json<Value>, ServerError> {
    let pool = require_pool(&state)?;
    TagRepository::link_tag_parent(pool, &req)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(json!({ "linked": true })))
}

/// `POST /api/v1/library/tags/links/remove`
pub async fn post_unlink_tag_parent(
    State(state): State<Arc<AppState>>,
    Json(req): Json<TagLinkRequest>,
) -> Result<Json<Value>, ServerError> {
    let pool = require_pool(&state)?;
    let unlinked = TagRepository::unlink_tag_parent(pool, &req)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(json!({ "unlinked": unlinked })))
}

/// `POST /api/v1/library/tags/items/batch`
pub async fn post_batch_tag_items(
    State(state): State<Arc<AppState>>,
    Json(req): Json<BatchTagItemsRequest>,
) -> Result<Json<BatchTagItemsResponse>, ServerError> {
    let pool = require_pool(&state)?;
    let resp = TagRepository::batch_update_tag_items(pool, &req)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(resp))
}

/// `GET /api/v1/library/tags/items/{entity_type}/{entity_id}`
pub async fn get_entity_tags(
    State(state): State<Arc<AppState>>,
    Path((entity_type, entity_id)): Path<(String, String)>,
) -> Result<Json<Vec<TagSummary>>, ServerError> {
    let pool = require_pool(&state)?;
    let parsed_type = TagEntityType::from_str(&entity_type)
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    let tags = TagRepository::get_entity_tags(pool, parsed_type, &entity_id)
        .await
        .map_err(map_tag_db_err)?;
    Ok(Json(tags))
}
