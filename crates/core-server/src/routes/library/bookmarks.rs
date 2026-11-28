use std::sync::Arc;

use axum::Json;
use axum::extract::{Path, State};
use core_db::{BookmarkRepository, DbError};
use core_types::{
    BookmarkDto, CreateBookmarkRequest, ReorderBookmarksRequest, UpdateBookmarkRequest,
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

fn map_bookmark_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// `GET /api/v1/library/bookmarks`
pub async fn get_bookmarks(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<BookmarkDto>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let list = BookmarkRepository::list_bookmarks(pool)
        .await
        .map_err(map_bookmark_db_err)?;
    Ok(Json(list))
}

/// `POST /api/v1/library/bookmarks`
pub async fn post_create_bookmark(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateBookmarkRequest>,
) -> Result<Json<BookmarkDto>, ServerError> {
    let pool = require_pool(&state)?;
    let created = BookmarkRepository::create_bookmark(pool, &req)
        .await
        .map_err(map_bookmark_db_err)?;
    Ok(Json(created))
}

/// `PUT /api/v1/library/bookmarks/{id}`
pub async fn put_update_bookmark(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(mut req): Json<UpdateBookmarkRequest>,
) -> Result<Json<BookmarkDto>, ServerError> {
    let pool = require_pool(&state)?;
    req.id = id;
    let updated = BookmarkRepository::update_bookmark(pool, &req)
        .await
        .map_err(map_bookmark_db_err)?;
    Ok(Json(updated))
}

/// `DELETE /api/v1/library/bookmarks/{id}`
pub async fn delete_bookmark(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ServerError> {
    let pool = require_pool(&state)?;
    let deleted = BookmarkRepository::delete_bookmark(pool, &id)
        .await
        .map_err(map_bookmark_db_err)?;
    Ok(Json(json!({ "deleted": deleted })))
}

/// `POST /api/v1/library/bookmarks/reorder`
pub async fn post_reorder_bookmarks(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ReorderBookmarksRequest>,
) -> Result<Json<Vec<BookmarkDto>>, ServerError> {
    let pool = require_pool(&state)?;
    let list = BookmarkRepository::reorder_bookmarks(pool, &req.ordered_ids)
        .await
        .map_err(map_bookmark_db_err)?;
    Ok(Json(list))
}
