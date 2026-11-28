use super::catalog::hydrate_track_item_dtos;
use super::models::{SearchQuery, SearchResultDto, TrackItemDto};
use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Query, State};
use core_db::{CatalogQueryRepository, SqlitePool, search_library_with_limit};
use std::sync::Arc;

/// Searches FTS5 and resolves matching track, album, or artist hits into playable track DTOs
/// via targeted SQL `IN (...)` queries (never loading the full track table into memory).
pub async fn search_enriched_tracks(
    pool: &SqlitePool,
    query: &str,
    limit: usize,
) -> Result<Vec<TrackItemDto>, ServerError> {
    let max_rows = limit.max(1);
    let hits = search_library_with_limit(pool, query, (max_rows * 4) as u32)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    if hits.is_empty() {
        return Ok(Vec::new());
    }

    let mut track_ids: Vec<String> = Vec::new();
    let mut album_ids: Vec<String> = Vec::new();
    let mut artist_ids: Vec<String> = Vec::new();
    for hit in hits {
        match hit.entity_type.as_str() {
            "track" => track_ids.push(hit.entity_id),
            "album" => album_ids.push(hit.entity_id),
            "artist" => artist_ids.push(hit.entity_id),
            _ => {}
        }
    }

    let rows = CatalogQueryRepository::list_present_tracks_matching_entities(
        pool,
        &track_ids,
        &album_ids,
        &artist_ids,
        max_rows,
    )
    .await
    .map_err(|e| ServerError::Database(e.to_string()))?;

    Ok(hydrate_track_item_dtos(rows, None, Some(max_rows)).await)
}

pub async fn search_library(
    State(state): State<Arc<AppState>>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<Vec<SearchResultDto>>, ServerError> {
    let q = query.q.unwrap_or_default().trim().to_string();
    if q.is_empty() {
        return Ok(Json(Vec::new()));
    }

    if let Some(pool) = &state.db_pool {
        let limit = query.limit.unwrap_or(20) as u32;
        let matches = search_library_with_limit(pool, &q, limit)
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;

        let results = matches
            .into_iter()
            .map(|r| SearchResultDto {
                id: r.entity_id,
                title: r.title,
                artist: r.subtitle.unwrap_or_default(),
                item_type: r.entity_type,
            })
            .collect();
        Ok(Json(results))
    } else {
        Ok(Json(vec![SearchResultDto {
            id: "trk-001".to_string(),
            title: format!("Match for '{}'", q),
            artist: "Pink Floyd".to_string(),
            item_type: "track".to_string(),
        }]))
    }
}
