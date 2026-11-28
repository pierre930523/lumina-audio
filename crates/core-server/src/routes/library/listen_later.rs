use std::sync::Arc;

use axum::Json;
use axum::extract::{Path, Query, State};
use core_db::{DbError, ListenLaterRepository, SqlitePool};
use core_providers::IngestionPipeline;
use core_types::{
    AddListenLaterRequest, ListenLaterItemDto, PromoteListenLaterRequest,
    PromoteListenLaterResponse, UpdateListenLaterNoteRequest, UpdateListenLaterStatusRequest,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::ServerError;
use crate::state::AppState;

#[derive(Debug, Deserialize, Default)]
pub struct ListenLaterListQuery {
    pub status: Option<String>,
}

fn require_pool(state: &AppState) -> Result<&SqlitePool, ServerError> {
    state
        .db_pool
        .as_ref()
        .ok_or_else(|| ServerError::BadRequest("Database not initialized".to_string()))
}

fn map_ll_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

pub fn normalize_status_filter(raw: Option<&str>) -> Option<&str> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("all"))
}

fn strip_provider_prefix<'a>(raw: &'a str, provider_id: &str) -> &'a str {
    let trimmed = raw.trim();
    for sep in [':', '/'] {
        if let Some((prefix, rest)) = trimmed.split_once(sep)
            && prefix.eq_ignore_ascii_case(provider_id)
            && !rest.trim().is_empty()
        {
            return rest.trim();
        }
    }
    trimmed
}

/// Shared helper usable by both REST handlers and `core-ffi`.
/// Ingests the external catalog batch into the local library, resolves the persisted
/// `canonical_albums.id` or `track_sources.id`, and marks the Listen Later item promoted.
pub async fn promote_listen_later_item(
    pool: &SqlitePool,
    id: &str,
    req: &PromoteListenLaterRequest,
) -> Result<PromoteListenLaterResponse, ServerError> {
    let item = ListenLaterRepository::get_listen_later_item(pool, id)
        .await
        .map_err(map_ll_db_err)?
        .ok_or_else(|| {
            ServerError::NotFound(format!("Listen Later item '{}' not found", id.trim()))
        })?;

    if item.source_kind == "library"
        && let Some(ref existing_entity_id) = item.entity_id
    {
        let updated =
            ListenLaterRepository::mark_listen_later_promoted(pool, &item.id, existing_entity_id)
                .await
                .map_err(map_ll_db_err)?;
        return Ok(PromoteListenLaterResponse {
            promoted_entity_id: existing_entity_id.clone(),
            item: updated,
        });
    }

    if req.ingest_batch.albums.is_empty() {
        return Err(ServerError::BadRequest(
            "Promote request requires a non-empty ingest_batch".to_string(),
        ));
    }

    IngestionPipeline::ingest_external_catalog(pool, &req.ingest_batch)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;

    let batch_provider = req.ingest_batch.provider.as_str().to_string();
    let mut candidates: Vec<(String, String)> = Vec::new();

    if let Some(first_album) = req.ingest_batch.albums.first() {
        if item.entity_type == "track" {
            if let Some(first_track) = first_album.tracks.first() {
                candidates.push((
                    batch_provider.clone(),
                    first_track.external_track_id.clone(),
                ));
            }
        } else {
            candidates.push((
                batch_provider.clone(),
                first_album.external_album_id.clone(),
            ));
        }
    }

    if let (Some(prov), Some(ext)) = (item.provider_id.as_deref(), item.external_id.as_deref()) {
        let stripped = strip_provider_prefix(ext, prov);
        candidates.push((prov.to_string(), ext.to_string()));
        if stripped != ext {
            candidates.push((prov.to_string(), stripped.to_string()));
        }
        if !prov.eq_ignore_ascii_case(&batch_provider) {
            candidates.push((batch_provider.clone(), stripped.to_string()));
        }
    }

    let mut resolved: Option<String> = None;
    for (prov, ext) in candidates {
        if let Some(found) =
            ListenLaterRepository::resolve_promoted_entity_id(pool, &item.entity_type, &prov, &ext)
                .await
                .map_err(map_ll_db_err)?
        {
            resolved = Some(found);
            break;
        }
    }

    let promoted_entity_id = resolved.ok_or_else(|| {
        ServerError::Internal(format!(
            "Failed to resolve promoted {} entity ID after external catalog ingest",
            item.entity_type
        ))
    })?;

    let updated =
        ListenLaterRepository::mark_listen_later_promoted(pool, &item.id, &promoted_entity_id)
            .await
            .map_err(map_ll_db_err)?;

    Ok(PromoteListenLaterResponse {
        item: updated,
        promoted_entity_id,
    })
}

/// `GET /api/v1/library/listen-later?status=pending|listened|all`
pub async fn get_listen_later_items(
    State(state): State<Arc<AppState>>,
    Query(query): Query<ListenLaterListQuery>,
) -> Result<Json<Vec<ListenLaterItemDto>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let status = normalize_status_filter(query.status.as_deref());
    let items = ListenLaterRepository::list_listen_later(pool, status)
        .await
        .map_err(map_ll_db_err)?;
    Ok(Json(items))
}

/// `POST /api/v1/library/listen-later`
pub async fn post_add_listen_later(
    State(state): State<Arc<AppState>>,
    Json(req): Json<AddListenLaterRequest>,
) -> Result<Json<ListenLaterItemDto>, ServerError> {
    let pool = require_pool(&state)?;
    let item = ListenLaterRepository::add_to_listen_later(pool, &req)
        .await
        .map_err(map_ll_db_err)?;
    Ok(Json(item))
}

/// `PUT /api/v1/library/listen-later/{id}/status`
pub async fn put_listen_later_status(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UpdateListenLaterStatusRequest>,
) -> Result<Json<ListenLaterItemDto>, ServerError> {
    let pool = require_pool(&state)?;
    let item = ListenLaterRepository::mark_listen_later_status(pool, &id, &req.status)
        .await
        .map_err(map_ll_db_err)?;
    Ok(Json(item))
}

/// `PUT /api/v1/library/listen-later/{id}/note`
pub async fn put_listen_later_note(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UpdateListenLaterNoteRequest>,
) -> Result<Json<ListenLaterItemDto>, ServerError> {
    let pool = require_pool(&state)?;
    let item = ListenLaterRepository::update_listen_later_note(pool, &id, &req.note)
        .await
        .map_err(map_ll_db_err)?;
    Ok(Json(item))
}

/// `DELETE /api/v1/library/listen-later/{id}`
pub async fn delete_listen_later(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ServerError> {
    let pool = require_pool(&state)?;
    let deleted = ListenLaterRepository::remove_listen_later(pool, &id)
        .await
        .map_err(map_ll_db_err)?;
    Ok(Json(json!({ "deleted": deleted })))
}

/// `POST /api/v1/library/listen-later/{id}/promote`
pub async fn post_promote_listen_later(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<PromoteListenLaterRequest>,
) -> Result<Json<PromoteListenLaterResponse>, ServerError> {
    let pool = require_pool(&state)?;
    let resp = promote_listen_later_item(pool, &id, &req).await?;
    Ok(Json(resp))
}
