use crate::error::ServerError;
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::Json;
use core_db::{rebuild_search_index, search_library_with_limit, Artist, LibraryRepository};
use core_providers::{
    CreditEnrichmentService, DiscogsClient, DiscogsConfig, EnrichmentConfig, EnrichmentReport,
    LibrarySyncService, LocalProvider, MusicBrainzClient, MusicBrainzConfig, MusicProvider,
    SyncResult,
};
use core_types::{AlbumCreditDetail, AlbumDetail, ArtistDetail, CanonicalAlbum};
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub q: Option<String>,
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct TracksQuery {
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, Default)]
pub struct AlbumsQuery {
    pub limit: Option<usize>,
    pub offset: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct ScanLibraryRequest {
    pub path: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct EnrichLibraryRequest {
    pub musicbrainz_base_url: Option<String>,
    pub discogs_base_url: Option<String>,
    pub discogs_token: Option<String>,
    pub force_refresh: Option<bool>,
    pub max_albums_per_run: Option<usize>,
    pub rebuild_search_index: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DeduplicateResponse {
    pub merged_albums: usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ScanLibraryResponse {
    pub scanned_files: usize,
    pub albums_count: usize,
    pub tracks_count: usize,
    pub errors_count: usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AlbumSummaryDto {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub year: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TrackItemDto {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u64,
    pub sample_rate_hz: u32,
    pub bit_depth: u8,
    pub channels: u8,
    pub codec: String,
    pub is_dsd: bool,
    pub file_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disc_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork_cache_key: Option<String>,
    #[serde(default)]
    pub has_lyrics: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SearchResultDto {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub item_type: String,
}

type AlbumRow = (
    String,
    String,
    String,
    Option<i64>,
    Option<String>,
    Option<String>,
);

/// Persists scanned albums, versions, artists, and tracks idempotently into SQLite and rebuilds FTS5.
pub async fn persist_sync_result(
    pool: &SqlitePool,
    result: &SyncResult,
) -> Result<(), ServerError> {
    let mut version_id_map: HashMap<String, String> = HashMap::new();

    for album in &result.albums {
        let artist_id = format!(
            "art:{}",
            album
                .artist_name
                .trim()
                .to_ascii_lowercase()
                .replace(|c: char| !c.is_ascii_alphanumeric(), "_")
        );
        let artist = Artist {
            id: artist_id.clone(),
            name: album.artist_name.clone(),
            sort_name: CanonicalAlbum::derive_sort_title(&album.artist_name),
            musicbrainz_id: None,
            biography: None,
            image_path: None,
        };
        LibraryRepository::insert_artist(pool, &artist)
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;

        // Check if any version of this album already exists in SQLite so re-scans remain FK-safe
        let mut resolved_album_id: Option<String> = None;
        for ver in &album.versions {
            let existing: Option<(String, String)> = sqlx::query_as(
                "SELECT id, canonical_album_id FROM album_versions WHERE provider_id = ? AND external_album_id = ?",
            )
            .bind(ver.provider.as_str())
            .bind(&ver.external_album_id)
            .fetch_optional(pool)
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;

            if let Some((ex_ver_id, ex_alb_id)) = existing {
                resolved_album_id = Some(ex_alb_id);
                version_id_map.insert(ver.id.clone(), ex_ver_id);
            }
        }

        let target_album_id = resolved_album_id.unwrap_or_else(|| album.id.clone());
        let mut album_to_insert = album.clone();
        album_to_insert.id = target_album_id.clone();

        for ver in &mut album_to_insert.versions {
            let mapped_ver_id = version_id_map
                .get(&ver.id)
                .cloned()
                .unwrap_or_else(|| ver.id.clone());
            version_id_map
                .entry(ver.id.clone())
                .or_insert_with(|| mapped_ver_id.clone());
            ver.id = mapped_ver_id;
            ver.canonical_album_id = target_album_id.clone();
        }

        LibraryRepository::insert_canonical_album(pool, &album_to_insert, Some(&artist_id))
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;
    }

    for track in &result.tracks {
        let mut trk = track.clone();
        if let Some(mapped_ver) = version_id_map.get(&track.version_id) {
            trk.version_id = mapped_ver.clone();
        }
        LibraryRepository::insert_track_source(pool, &trk)
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;
    }

    rebuild_search_index(pool)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;

    Ok(())
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
    let dg_base = req.discogs_base_url.clone().filter(|s| !s.trim().is_empty());

    let mut mb_cfg = MusicBrainzConfig::default();
    if let Some(ref base) = mb_base {
        mb_cfg.base_url = base.clone();
        mb_cfg.min_interval_ms = 0; // Fast path for local loopback mock servers
    }
    let mb_client = MusicBrainzClient::new(mb_cfg)
        .map_err(|e| ServerError::Internal(e.to_string()))?;

    let mut dg_cfg = DiscogsConfig::default();
    if let Some(ref base) = dg_base {
        dg_cfg.base_url = base.clone();
        dg_cfg.min_interval_ms = 0;
    }
    if req.discogs_token.is_some() {
        dg_cfg.token = req.discogs_token;
    }
    let dg_client = if dg_base.is_some() || dg_cfg.token.is_some() {
        Some(
            DiscogsClient::new(dg_cfg)
                .map_err(|e| ServerError::Internal(e.to_string()))?,
        )
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

/// Fetches tracks from SQLite joined with album version, album title, and artist metadata.
pub async fn query_library_tracks(
    pool: &SqlitePool,
    limit: usize,
) -> Result<Vec<TrackItemDto>, ServerError> {
    let rows = sqlx::query(
        "SELECT trk.id, trk.title, COALESCE(NULLIF(trk.artist_name, ''), COALESCE(art.name, 'Unknown Artist')) AS artist, \
         COALESCE(alb.title, 'Unknown Album') AS album, trk.duration_ms, trk.sample_rate_hz, \
         trk.bit_depth, trk.channels, trk.codec, trk.is_dsd, trk.external_track_id, \
         trk.artist_name, COALESCE(trk.album_artist, alb.album_artist) AS album_artist, trk.genre, \
         alb.release_year, trk.track_number, trk.disc_number, trk.composer, \
         alb.cover_url, trk.metadata_hash, trk.embedded_lyrics \
         FROM track_sources trk \
         JOIN album_versions ver ON ver.id = trk.version_id \
         JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
         LEFT JOIN artists art ON art.id = alb.primary_artist_id \
         ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.external_track_id ASC, trk.title ASC \
         LIMIT ?",
    )
    .bind(limit.max(1) as i64)
    .fetch_all(pool)
    .await
    .map_err(|e| ServerError::Database(e.to_string()))?;

    Ok(rows
        .into_iter()
        .map(|row| {
            let id: String = row.get("id");
            let title: String = row.get("title");
            let artist: String = row.get("artist");
            let album: String = row.get("album");
            let dur: i64 = row.get("duration_ms");
            let sr: i64 = row.get("sample_rate_hz");
            let bd: i64 = row.get("bit_depth");
            let ch: i64 = row.get("channels");
            let codec: String = row.get("codec");
            let is_dsd: i32 = row.get("is_dsd");
            let path: String = row.get("external_track_id");
            let artist_name: Option<String> = row.get("artist_name");
            let album_artist: Option<String> = row.get("album_artist");
            let genre: Option<String> = row.get("genre");
            let release_year: Option<i64> = row.get("release_year");
            let track_number: i64 = row.get("track_number");
            let disc_number: i64 = row.get("disc_number");
            let composer: Option<String> = row.get("composer");
            let cover_url: Option<String> = row.get("cover_url");
            let metadata_hash: Option<String> = row.get("metadata_hash");
            let embedded_lyrics: Option<String> = row.get("embedded_lyrics");

            let has_emb_lyrics = embedded_lyrics
                .as_ref()
                .map(|s| !s.trim().is_empty())
                .unwrap_or(false);
            let p = std::path::Path::new(&path);
            let has_lrc_file = p.with_extension("lrc").is_file()
                || p.with_extension("LRC").is_file();
            let has_lyrics = has_emb_lyrics || has_lrc_file;
            let final_cover = cover_url
                .filter(|s| !s.trim().is_empty())
                .or_else(|| Some(format!("/api/v1/library/artwork/{}", id)));
            let final_artist_name = artist_name
                .filter(|s| !s.trim().is_empty())
                .or_else(|| Some(artist.clone()));

            TrackItemDto {
                id,
                title,
                artist,
                album,
                duration_ms: dur.max(0) as u64,
                sample_rate_hz: sr.max(0) as u32,
                bit_depth: bd.clamp(0, u8::MAX as i64) as u8,
                channels: ch.clamp(1, u8::MAX as i64) as u8,
                codec,
                is_dsd: is_dsd != 0,
                file_path: path,
                artist_name: final_artist_name,
                album_artist,
                genre,
                year: release_year.map(|y| y as u32),
                track_number: Some(track_number as u32),
                disc_number: Some(disc_number as u32),
                composer,
                cover_url: final_cover,
                artwork_cache_key: metadata_hash,
                has_lyrics,
            }
        })
        .collect())
}

/// Searches FTS5 and resolves matching track, album, or artist hits into playable track DTOs.
pub async fn search_enriched_tracks(
    pool: &SqlitePool,
    query: &str,
    limit: usize,
) -> Result<Vec<TrackItemDto>, ServerError> {
    let hits = search_library_with_limit(pool, query, (limit.max(1) * 4) as u32)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    if hits.is_empty() {
        return Ok(Vec::new());
    }

    let matched_ids: std::collections::HashSet<String> =
        hits.into_iter().map(|h| h.entity_id).collect();

    let rows = sqlx::query(
        "SELECT trk.id, trk.title, COALESCE(NULLIF(trk.artist_name, ''), COALESCE(art.name, 'Unknown Artist')) AS artist, \
         COALESCE(alb.title, 'Unknown Album') AS album, trk.duration_ms, trk.sample_rate_hz, \
         trk.bit_depth, trk.channels, trk.codec, trk.is_dsd, trk.external_track_id, \
         trk.artist_name, COALESCE(trk.album_artist, alb.album_artist) AS album_artist, trk.genre, \
         alb.release_year, trk.track_number, trk.disc_number, trk.composer, \
         alb.cover_url, trk.metadata_hash, trk.embedded_lyrics, \
         alb.id AS alb_id, art.id AS art_id \
         FROM track_sources trk \
         JOIN album_versions ver ON ver.id = trk.version_id \
         JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
         LEFT JOIN artists art ON art.id = alb.primary_artist_id \
         ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.external_track_id ASC, trk.title ASC",
    )
    .fetch_all(pool)
    .await
    .map_err(|e| ServerError::Database(e.to_string()))?;

    let mut out = Vec::new();
    for row in rows {
        let id: String = row.get("id");
        let alb_id: String = row.get("alb_id");
        let art_id: Option<String> = row.get("art_id");

        let matches = matched_ids.contains(&id)
            || matched_ids.contains(&alb_id)
            || art_id.as_ref().is_some_and(|aid| matched_ids.contains(aid));
        if matches {
            let title: String = row.get("title");
            let artist: String = row.get("artist");
            let album: String = row.get("album");
            let dur: i64 = row.get("duration_ms");
            let sr: i64 = row.get("sample_rate_hz");
            let bd: i64 = row.get("bit_depth");
            let ch: i64 = row.get("channels");
            let codec: String = row.get("codec");
            let is_dsd: i32 = row.get("is_dsd");
            let path: String = row.get("external_track_id");
            let artist_name: Option<String> = row.get("artist_name");
            let album_artist: Option<String> = row.get("album_artist");
            let genre: Option<String> = row.get("genre");
            let release_year: Option<i64> = row.get("release_year");
            let track_number: i64 = row.get("track_number");
            let disc_number: i64 = row.get("disc_number");
            let composer: Option<String> = row.get("composer");
            let cover_url: Option<String> = row.get("cover_url");
            let metadata_hash: Option<String> = row.get("metadata_hash");
            let embedded_lyrics: Option<String> = row.get("embedded_lyrics");

            let has_emb_lyrics = embedded_lyrics
                .as_ref()
                .map(|s| !s.trim().is_empty())
                .unwrap_or(false);
            let p = std::path::Path::new(&path);
            let has_lrc_file = p.with_extension("lrc").is_file()
                || p.with_extension("LRC").is_file();
            let has_lyrics = has_emb_lyrics || has_lrc_file;
            let final_cover = cover_url
                .filter(|s| !s.trim().is_empty())
                .or_else(|| Some(format!("/api/v1/library/artwork/{}", id)));
            let final_artist_name = artist_name
                .filter(|s| !s.trim().is_empty())
                .or_else(|| Some(artist.clone()));

            out.push(TrackItemDto {
                id,
                title,
                artist,
                album,
                duration_ms: dur.max(0) as u64,
                sample_rate_hz: sr.max(0) as u32,
                bit_depth: bd.clamp(0, u8::MAX as i64) as u8,
                channels: ch.clamp(1, u8::MAX as i64) as u8,
                codec,
                is_dsd: is_dsd != 0,
                file_path: path,
                artist_name: final_artist_name,
                album_artist,
                genre,
                year: release_year.map(|y| y as u32),
                track_number: Some(track_number as u32),
                disc_number: Some(disc_number as u32),
                composer,
                cover_url: final_cover,
                artwork_cache_key: metadata_hash,
                has_lyrics,
            });
            if out.len() >= limit.max(1) {
                break;
            }
        }
    }

    Ok(out)
}

pub async fn query_library_albums(
    pool: &SqlitePool,
    limit: usize,
    offset: usize,
) -> Result<Vec<AlbumSummaryDto>, ServerError> {
    let rows: Vec<AlbumRow> = sqlx::query_as(
        "SELECT ca.id, ca.title, COALESCE(ar.name, 'Unknown Artist'), ca.release_year, \
         ca.album_artist, ca.cover_url \
         FROM canonical_albums ca \
         LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
         ORDER BY ca.sort_title LIMIT ? OFFSET ?",
    )
    .bind(limit.clamp(1, 500) as i64)
    .bind(offset as i64)
    .fetch_all(pool)
    .await
    .map_err(|e| ServerError::Database(e.to_string()))?;

    Ok(rows
        .into_iter()
        .map(|(id, title, artist, year, album_artist, cover_url)| AlbumSummaryDto {
            cover_url: cover_url.filter(|s| !s.trim().is_empty()).or_else(|| Some(format!("/api/v1/library/artwork/{}", id))),
            id,
            title,
            artist,
            year: year.map(|y| y as u32),
            album_artist,
        })
        .collect())
}

pub async fn get_albums(
    State(state): State<Arc<AppState>>,
    Query(query): Query<AlbumsQuery>,
) -> Result<Json<Vec<AlbumSummaryDto>>, ServerError> {
    let limit = query.limit.unwrap_or(100);
    let offset = query.offset.unwrap_or(0);

    if let Some(pool) = &state.db_pool {
        let dtos = query_library_albums(pool, limit, offset).await?;
        Ok(Json(dtos))
    } else {
        Ok(Json(vec![AlbumSummaryDto {
            id: "alb-001".to_string(),
            title: "The Dark Side of the Moon".to_string(),
            artist: "Pink Floyd".to_string(),
            year: Some(1973),
            album_artist: Some("Pink Floyd".to_string()),
            cover_url: Some("/api/v1/library/artwork/alb-001".to_string()),
        }]))
    }
}

pub async fn get_album_detail(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<String>,
) -> Result<Json<AlbumDetail>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(format!("Album {album_id} not found")));
    };
    let detail = LibrarySyncService::get_album_detail(pool, &album_id)
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
        let tracks = query_library_tracks(pool, limit).await?;
        Ok(Json(tracks))
    } else {
        Ok(Json(Vec::new()))
    }
}

pub async fn post_scan_library(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ScanLibraryRequest>,
) -> Result<Json<ScanLibraryResponse>, ServerError> {
    let provider = LocalProvider::from_root(&req.path);
    let sync = provider
        .sync_library()
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;

    if let Some(pool) = &state.db_pool {
        persist_sync_result(pool, &sync).await?;
    }

    Ok(Json(ScanLibraryResponse {
        scanned_files: sync.scanned_files_count,
        albums_count: sync.albums.len(),
        tracks_count: sync.tracks.len(),
        errors_count: sync.errors.len(),
    }))
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

#[derive(Debug, Deserialize, Default)]
pub struct ArtworkQuery {
    pub max_dim: Option<u32>,
}

pub async fn get_artwork(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    Query(query): Query<ArtworkQuery>,
) -> Result<axum::response::Response, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound(format!(
            "Artwork not found for {track_id}"
        )));
    };
    let cache_dir = std::env::temp_dir().join("lumina_artwork_cache");
    let _ = std::fs::create_dir_all(&cache_dir);
    let max_dim = query.max_dim.unwrap_or(0);
    let res =
        core_providers::ArtworkManager::resolve_artwork(pool, &track_id, max_dim, &cache_dir)
            .await
            .map_err(|e| ServerError::Internal(e.to_string()))?;

    if let Some(ref path_str) = res.cache_path {
        let p = std::path::Path::new(path_str);
        if p.is_file() {
            if let Ok(bytes) = std::fs::read(p) {
                let mime = res.mime_type.as_deref().unwrap_or_else(|| {
                    if path_str.ends_with(".png") {
                        "image/png"
                    } else if path_str.ends_with(".webp") {
                        "image/webp"
                    } else {
                        "image/jpeg"
                    }
                });
                return Ok(axum::response::Response::builder()
                    .header(axum::http::header::CONTENT_TYPE, mime)
                    .body(axum::body::Body::from(bytes))
                    .unwrap());
            }
        }
    }

    Err(ServerError::NotFound(format!(
        "Artwork not found for {track_id}"
    )))
}

#[derive(Debug, Deserialize)]
pub struct ArtworkOverrideRequest {
    pub image_path: String,
}

pub async fn post_artwork_override(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
    Json(req): Json<ArtworkOverrideRequest>,
) -> Result<axum::http::StatusCode, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound("Database not initialized".to_string()));
    };
    core_providers::ArtworkManager::set_user_cover(pool, &track_id, &req.image_path)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(axum::http::StatusCode::OK)
}

pub async fn delete_artwork_override(
    State(state): State<Arc<AppState>>,
    Path(track_id): Path<String>,
) -> Result<axum::http::StatusCode, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::NotFound("Database not initialized".to_string()));
    };
    core_providers::ArtworkManager::clear_user_cover(pool, &track_id)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize, Default)]
pub struct RescanRequest {
    pub dir_path: Option<String>,
    pub force: Option<bool>,
}

pub async fn post_rescan_library(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<RescanRequest>>,
) -> Result<Json<core_types::RescanReport>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(core_types::RescanReport::default()));
    };
    let req = payload.map(|Json(r)| r).unwrap_or_default();
    let force = req.force.unwrap_or(false);
    let report = LibrarySyncService::rescan_tags(pool, req.dir_path.as_deref(), force)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(report))
}
