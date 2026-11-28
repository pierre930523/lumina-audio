use super::models::{
    AlbumSummaryDto, AlbumsQuery, DeduplicateResponse, EnrichLibraryRequest, TrackItemDto,
    TracksQuery,
};
use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use core_db::{CatalogQueryRepository, CatalogTrackRow, SqlitePool};
use core_providers::{
    CreditEnrichmentService, DiscogsClient, DiscogsConfig, EnrichmentConfig, EnrichmentReport,
    LibrarySyncService, MusicBrainzClient, MusicBrainzConfig, SyncResult,
};
use core_types::{AlbumCreditDetail, AlbumDetail, ArtistDetail};
use std::collections::HashSet;
use std::sync::Arc;

/// Persists scanned albums, versions, artists, and tracks idempotently into SQLite via
/// `LibrarySyncService` (using `core_db::deterministic_artist_id`, `DbWriteCoordinator`,
/// 200-track batched `ImmediateTx`, incremental FTS5 sync, and orphan cleanup).
pub async fn persist_sync_result(
    pool: &SqlitePool,
    result: &SyncResult,
) -> Result<(), ServerError> {
    LibrarySyncService::persist_sync_result(pool, result)
        .await
        .map(|_| ())
        .map_err(|e| ServerError::Database(e.to_string()))
}

/// Shared enrichment executor usable by both REST routes and `core-ffi`.
pub async fn execute_credit_enrichment(
    pool: &SqlitePool,
    req: EnrichLibraryRequest,
) -> Result<EnrichmentReport, ServerError> {
    let mb_base = req
        .musicbrainz_base_url
        .clone()
        .filter(|s| !s.trim().is_empty());
    let dg_base = req
        .discogs_base_url
        .clone()
        .filter(|s| !s.trim().is_empty());

    let mut mb_cfg = MusicBrainzConfig::default();
    if let Some(ref base) = mb_base {
        mb_cfg.base_url = base.clone();
        mb_cfg.min_interval_ms = 0; // Fast path for local loopback mock servers
    }
    let mb_client =
        MusicBrainzClient::new(mb_cfg).map_err(|e| ServerError::Internal(e.to_string()))?;

    let mut dg_cfg = DiscogsConfig::default();
    if let Some(ref base) = dg_base {
        dg_cfg.base_url = base.clone();
        dg_cfg.min_interval_ms = 0;
    }
    if req.discogs_token.is_some() {
        dg_cfg.token = req.discogs_token;
    }
    let dg_client = if dg_base.is_some() || dg_cfg.token.is_some() {
        Some(DiscogsClient::new(dg_cfg).map_err(|e| ServerError::Internal(e.to_string()))?)
    } else {
        None
    };

    let mut cfg = EnrichmentConfig::default();
    if let Some(force) = req.force_refresh {
        cfg.force_refresh = force;
    }
    if let Some(max) = req.max_albums_per_run {
        cfg.max_albums_per_run = max;
    }
    if let Some(rebuild) = req.rebuild_search_index {
        cfg.rebuild_search_index = rebuild;
    }

    let svc = CreditEnrichmentService::new(Some(mb_client), dg_client, cfg);
    svc.enrich_library(pool)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))
}

pub(super) async fn hydrate_track_item_dtos(
    rows: Vec<CatalogTrackRow>,
    matched_ids: Option<&HashSet<String>>,
    limit: Option<usize>,
) -> Vec<TrackItemDto> {
    let mut out: Vec<TrackItemDto> = Vec::with_capacity(limit.unwrap_or(rows.len()));
    let mut lrc_check_indices: Vec<(usize, String)> = Vec::new();

    for row in rows {
        if let Some(ids) = matched_ids {
            let matches = ids.contains(&row.id)
                || ids.contains(&row.alb_id)
                || row.art_id.as_ref().is_some_and(|aid| ids.contains(aid));
            if !matches {
                continue;
            }
        }

        let has_emb_lyrics = row
            .embedded_lyrics
            .as_ref()
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false);
        if !has_emb_lyrics && !row.external_track_id.trim().is_empty() {
            lrc_check_indices.push((out.len(), row.external_track_id.clone()));
        }
        let final_cover = row
            .cover_url
            .filter(|s| !s.trim().is_empty())
            .or_else(|| Some(format!("/api/v1/library/artwork/{}", row.id)));
        let final_artist_name = row
            .artist_name
            .filter(|s| !s.trim().is_empty())
            .or_else(|| Some(row.artist.clone()));

        out.push(TrackItemDto {
            id: row.id,
            title: row.title,
            artist: row.artist,
            album: row.album,
            duration_ms: row.duration_ms.max(0) as u64,
            sample_rate_hz: row.sample_rate_hz.max(0) as u32,
            bit_depth: row.bit_depth.clamp(0, u8::MAX as i64) as u8,
            channels: row.channels.clamp(1, u8::MAX as i64) as u8,
            codec: row.codec,
            is_dsd: row.is_dsd != 0,
            file_path: row.external_track_id,
            artist_name: final_artist_name,
            album_artist: row.album_artist,
            genre: row.genre,
            year: row.release_year.map(|y| y as u32),
            track_number: Some(row.track_number as u32),
            disc_number: Some(row.disc_number as u32),
            composer: row.composer,
            cover_url: final_cover,
            artwork_cache_key: row.metadata_hash,
            has_lyrics: has_emb_lyrics,
            preference: row.preference,
            album_group_id: Some(row.alb_id),
            is_hidden: row.is_hidden != 0,
            file_size_bytes: row.file_size.and_then(|s| u64::try_from(s).ok()),
            bitrate_kbps: row
                .bitrate_kbps
                .and_then(|b| u32::try_from(b).ok())
                .filter(|&b| b > 0),
        });

        if let Some(lim) = limit
            && out.len() >= lim
        {
            break;
        }
    }

    if !lrc_check_indices.is_empty() {
        let lrc_hits = tokio::task::spawn_blocking(move || {
            let mut hits = Vec::new();
            for (idx, path) in lrc_check_indices {
                let p = std::path::Path::new(&path);
                if p.with_extension("lrc").is_file() || p.with_extension("LRC").is_file() {
                    hits.push(idx);
                }
            }
            hits
        })
        .await
        .unwrap_or_default();
        for idx in lrc_hits {
            if let Some(dto) = out.get_mut(idx) {
                dto.has_lyrics = true;
            }
        }
    }

    out
}

/// Fetches tracks from SQLite joined with album version, album title, and artist metadata.
pub async fn query_library_tracks(
    pool: &SqlitePool,
    limit: usize,
) -> Result<Vec<TrackItemDto>, ServerError> {
    query_library_tracks_with_options(pool, limit, false).await
}

pub async fn query_library_tracks_with_options(
    pool: &SqlitePool,
    limit: usize,
    include_hidden: bool,
) -> Result<Vec<TrackItemDto>, ServerError> {
    let rows =
        CatalogQueryRepository::list_present_tracks_with_options(pool, limit, include_hidden)
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(hydrate_track_item_dtos(rows, None, None).await)
}

pub async fn query_library_albums_with_options(
    pool: &SqlitePool,
    limit: usize,
    offset: usize,
    include_hidden: bool,
) -> Result<Vec<AlbumSummaryDto>, ServerError> {
    let rows =
        CatalogQueryRepository::list_album_group_summaries(pool, limit, offset, include_hidden)
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;

    Ok(rows.into_iter().map(AlbumSummaryDto::from).collect())
}

pub async fn query_library_albums(
    pool: &SqlitePool,
    limit: usize,
    offset: usize,
) -> Result<Vec<AlbumSummaryDto>, ServerError> {
    query_library_albums_with_options(pool, limit, offset, false).await
}

pub async fn get_albums(
    State(state): State<Arc<AppState>>,
    Query(query): Query<AlbumsQuery>,
) -> Result<Json<Vec<AlbumSummaryDto>>, ServerError> {
    let limit = query.limit.unwrap_or(100);
    let offset = query.offset.unwrap_or(0);

    if let Some(pool) = &state.db_pool {
        let dtos =
            query_library_albums_with_options(pool, limit, offset, query.include_hidden).await?;
        Ok(Json(dtos))
    } else {
        Ok(Json(vec![AlbumSummaryDto {
            id: "alb-001".to_string(),
            group_id: "alb-001".to_string(),
            version_id: Some("ver-001".to_string()),
            primary_version_id: Some("ver-001".to_string()),
            title: "The Dark Side of the Moon".to_string(),
            artist: "Pink Floyd".to_string(),
            year: Some(1973),
            album_artist: Some("Pink Floyd".to_string()),
            cover_url: Some("/api/v1/library/artwork/alb-001".to_string()),
            track_count: 1,
            disc_count: 1,
            version_count: 1,
            hidden_version_count: 0,
            total_version_count: 1,
            is_primary: true,
            is_primary_locked: false,
            is_hidden: false,
            is_manual_group: false,
            quality_score: 0.0,
            edition_label: None,
            provider: Some("local".to_string()),
            codec: Some("flac".to_string()),
            sample_rate_hz: Some(44_100),
            bit_depth: Some(16),
            is_dsd: false,
            preference: 0,
        }]))
    }
}

pub async fn get_album_detail(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<String>,
    Query(query): Query<AlbumsQuery>,
) -> Result<Json<AlbumDetail>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(format!("Album {album_id} not found")));
    };
    let detail = core_db::LibraryRepository::get_album_detail_with_options(
        pool,
        &album_id,
        query.include_hidden,
    )
    .await
    .map_err(|e| ServerError::Database(e.to_string()))?
    .ok_or_else(|| ServerError::NotFound(format!("Album {album_id} not found")))?;
    Ok(Json(detail))
}

pub async fn get_album_credits(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<String>,
) -> Result<Json<Vec<AlbumCreditDetail>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let detail = LibrarySyncService::get_album_detail(pool, &album_id)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?
        .ok_or_else(|| ServerError::NotFound(format!("Album {album_id} not found")))?;
    Ok(Json(detail.credits))
}

pub async fn get_artist_detail(
    State(state): State<Arc<AppState>>,
    Path(artist_id): Path<String>,
) -> Result<Json<ArtistDetail>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(format!(
            "Artist {artist_id} not found"
        )));
    };
    let detail = LibrarySyncService::get_artist_detail(pool, &artist_id)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?
        .ok_or_else(|| ServerError::NotFound(format!("Artist {artist_id} not found")))?;
    Ok(Json(detail))
}

pub async fn post_deduplicate(
    State(state): State<Arc<AppState>>,
) -> Result<Json<DeduplicateResponse>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(DeduplicateResponse { merged_albums: 0 }));
    };
    let merged_albums = LibrarySyncService::deduplicate_library(pool)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(DeduplicateResponse { merged_albums }))
}

pub async fn post_enrich(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<EnrichLibraryRequest>>,
) -> Result<Json<EnrichmentReport>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(EnrichmentReport::default()));
    };
    let mut req = payload.map(|Json(r)| r).unwrap_or_default();
    if req.musicbrainz_base_url.is_none() {
        req.musicbrainz_base_url = Some(state.mb_base_url.read().await.clone());
    }
    if req.discogs_base_url.is_none() {
        req.discogs_base_url = Some(state.discogs_base_url.read().await.clone());
    }
    if req.discogs_token.is_none() {
        req.discogs_token = state.discogs_token.read().await.clone();
    }
    let report = execute_credit_enrichment(pool, req).await?;
    Ok(Json(report))
}

pub async fn get_tracks(
    State(state): State<Arc<AppState>>,
    Query(query): Query<TracksQuery>,
) -> Result<Json<Vec<TrackItemDto>>, ServerError> {
    let limit = query.limit.unwrap_or(200);
    if let Some(pool) = &state.db_pool {
        let tracks = query_library_tracks_with_options(pool, limit, query.include_hidden).await?;
        Ok(Json(tracks))
    } else {
        Ok(Json(Vec::new()))
    }
}
