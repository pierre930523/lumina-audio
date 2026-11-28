use super::catalog::hydrate_track_item_dtos;
use super::models::{AlbumSummaryDto, TrackItemDto};
use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::State;
use core_db::{SqlitePool, repository::focus::FocusRepository};
use core_types::{
    FocusEntity, FocusFacetsResponse, FocusQuery, FocusQueryRequest, FocusQueryResponse,
};
use std::sync::Arc;

/// Shared Focus query executor usable by both REST routes and `core-ffi`.
pub async fn query_library_focus(
    pool: &SqlitePool,
    req: &FocusQueryRequest,
) -> Result<FocusQueryResponse<AlbumSummaryDto, TrackItemDto>, ServerError> {
    let raw = FocusRepository::query_focus_entities(pool, req)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;

    let albums: Vec<AlbumSummaryDto> = raw.albums.into_iter().map(AlbumSummaryDto::from).collect();
    let tracks: Vec<TrackItemDto> = if raw.tracks.is_empty() {
        Vec::new()
    } else {
        hydrate_track_item_dtos(raw.tracks, None, None).await
    };

    Ok(FocusQueryResponse {
        entity: raw.entity,
        total_count: raw.total_count,
        limit: raw.limit,
        offset: raw.offset,
        albums,
        tracks,
    })
}

/// Shared Focus facets executor usable by both REST routes and `core-ffi`.
pub async fn query_library_focus_facets(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<FocusFacetsResponse, ServerError> {
    FocusRepository::get_focus_facets(pool, query)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))
}

/// `POST /api/v1/library/focus/query`
pub async fn focus_query(
    State(state): State<Arc<AppState>>,
    Json(req): Json<FocusQueryRequest>,
) -> Result<Json<FocusQueryResponse<AlbumSummaryDto, TrackItemDto>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        let clamped_limit = req.limit.clamp(1, 500);
        return Ok(Json(match req.query.entity {
            FocusEntity::Albums => {
                FocusQueryResponse::for_albums(0, clamped_limit, req.offset, Vec::new())
            }
            FocusEntity::Tracks => {
                FocusQueryResponse::for_tracks(0, clamped_limit, req.offset, Vec::new())
            }
        }));
    };

    let response = query_library_focus(pool, &req).await?;
    Ok(Json(response))
}

/// `POST /api/v1/library/focus/facets`
pub async fn focus_facets(
    State(state): State<Arc<AppState>>,
    Json(query): Json<FocusQuery>,
) -> Result<Json<FocusFacetsResponse>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(FocusFacetsResponse::default()));
    };

    let response = query_library_focus_facets(pool, &query).await?;
    Ok(Json(response))
}
