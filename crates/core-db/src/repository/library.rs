use super::tx::ImmediateTx;
use crate::error::{DbError, Result};
use chrono::Utc;
use core_types::{
    AlbumCreditDetail, AlbumDetail, AlbumVersion, AlbumVersionDetail, ArtistDetail, AudioCodec,
    AudioFormat, CanonicalAlbum, ProviderKind, TrackSource,
};
use sha2::{Digest, Sha256};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub sort_name: String,
    pub musicbrainz_id: Option<String>,
    pub biography: Option<String>,
    pub image_path: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AlbumCredit {
    pub id: Option<i64>,
    pub canonical_album_id: String,
    pub artist_id: String,
    pub role: String,
    pub artist_name: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ProfileFavorite {
    pub profile_id: String,
    pub item_type: String,
    pub item_id: String,
    pub created_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PlayHistoryEntry {
    pub id: i64,
    pub profile_id: String,
    pub track_source_id: String,
    pub played_at: String,
    pub duration_listened_ms: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct PairedClient {
    pub id: String,
    pub device_name: String,
    pub platform: String,
    pub token_hash: String,
    pub created_at: String,
    pub last_seen_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct TrackFileCacheInfo {
    pub track_id: String,
    pub version_id: String,
    pub external_track_id: String,
    pub file_mtime: Option<i64>,
    pub file_size: Option<i64>,
    pub metadata_hash: Option<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PruneLocalTracksReport {
    pub tracks_pruned: usize,
    pub versions_pruned: usize,
    pub albums_pruned: usize,
    pub invalidated_artwork_paths: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct ArtworkCacheEntry {
    pub cache_key: String,
    pub track_id: Option<String>,
    pub album_id: Option<String>,
    pub source_kind: String,
    pub mime_type: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub max_dim: i64,
    pub cache_path: String,
    pub source_mtime: Option<i64>,
    pub updated_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct ArtworkOverride {
    pub target_kind: String,
    pub target_id: String,
    pub image_path: String,
    pub updated_at: String,
}

#[derive(Debug, sqlx::FromRow)]
struct ArtistRow {
    id: String,
    name: String,
    sort_name: String,
    musicbrainz_id: Option<String>,
    biography: Option<String>,
    image_path: Option<String>,
}

impl From<ArtistRow> for Artist {
    fn from(row: ArtistRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            sort_name: row.sort_name,
            musicbrainz_id: row.musicbrainz_id,
            biography: row.biography,
            image_path: row.image_path,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
struct CanonicalAlbumRow {
    id: String,
    title: String,
    sort_title: String,
    artist_name: Option<String>,
    album_artist: Option<String>,
    release_year: Option<i32>,
    musicbrainz_release_group_id: Option<String>,
    cover_url: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct AlbumVersionRow {
    id: String,
    canonical_album_id: String,
    provider_id: String,
    external_album_id: String,
    codec: String,
    sample_rate_hz: i64,
    bit_depth: i64,
    channels: i64,
    is_dsd: i32,
    edition_label: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct TrackSourceRow {
    id: String,
    version_id: String,
    provider_id: String,
    external_track_id: String,
    title: String,
    disc_number: i64,
    track_number: i64,
    duration_ms: i64,
    sample_rate_hz: i64,
    bit_depth: i64,
    codec: String,
    isrc: Option<String>,
    replay_gain_track_db: Option<f64>,
    replay_gain_album_db: Option<f64>,
    replay_gain_track_peak: Option<f64>,
    replay_gain_album_peak: Option<f64>,
    artist_name: Option<String>,
    album_artist: Option<String>,
    genre: Option<String>,
    composer: Option<String>,
    channels: i64,
    is_dsd: i32,
    has_lyrics: i32,
}

#[derive(Debug, sqlx::FromRow)]
struct AlbumCreditRow {
    id: i64,
    canonical_album_id: String,
    artist_id: String,
    role: String,
    artist_name: String,
}

#[derive(Debug, sqlx::FromRow)]
struct ArtistCreditDetailRow {
    artist_id: String,
    artist_name: String,
    role: String,
    album_id: String,
    album_title: String,
}

#[derive(Debug, sqlx::FromRow)]
struct ProfileFavoriteRow {
    profile_id: String,
    item_type: String,
    item_id: String,
    created_at: String,
}

#[derive(Debug, sqlx::FromRow)]
struct PlayHistoryRow {
    id: i64,
    profile_id: String,
    track_source_id: String,
    played_at: String,
    duration_listened_ms: i64,
}

#[derive(Debug, sqlx::FromRow)]
struct DedupAlbumCandidateRow {
    id: String,
    title: String,
    artist_name: Option<String>,
    normalized_title: Option<String>,
    normalized_artist: Option<String>,
    upc: Option<String>,
    musicbrainz_release_group_id: Option<String>,
    cover_url: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct MergeAlbumSourceRow {
    primary_artist_id: Option<String>,
    album_artist: Option<String>,
    release_year: Option<i32>,
    upc: Option<String>,
    musicbrainz_release_group_id: Option<String>,
    editorial_bio: Option<String>,
    cover_url: Option<String>,
    merged_cover_path: Option<String>,
    normalized_title: Option<String>,
    normalized_artist: Option<String>,
    enriched_at: Option<String>,
}

pub fn deterministic_artist_id(name: &str) -> String {
    let normalized: String = name
        .nfc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();

    let mut hasher = Sha256::new();
    hasher.update(normalized.as_bytes());
    let digest = hasher.finalize();

    let mut hex32 = String::with_capacity(32);
    for byte in &digest[..16] {
        let _ = write!(&mut hex32, "{byte:02x}");
    }
    format!("art:{hex32}")
}

pub(crate) fn normalize_local_path_for_compare(path: &str) -> String {
    let mut s = path.trim().replace('\\', "/");
    if s.get(..8)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("//?/UNC/"))
    {
        s = format!("//{}", &s[8..]);
    } else if let Some(rest) = s.strip_prefix("//?/") {
        s = rest.to_string();
    }
    while s.len() > 1 && s.ends_with('/') {
        let is_windows_drive_root = s.len() == 3 && s.as_bytes()[1] == b':';
        if is_windows_drive_root {
            break;
        }
        s.pop();
    }
    let is_windows_style = cfg!(windows)
        || s.as_bytes().get(1) == Some(&b':')
        || s.starts_with("//");
    if is_windows_style {
        s.to_lowercase()
    } else {
        s
    }
}

pub(crate) fn path_in_scope(track_norm: &str, scope_norm: &str) -> bool {
    if scope_norm.is_empty() {
        return true;
    }
    if scope_norm == "/" || scope_norm.ends_with(":/") {
        return track_norm.starts_with(scope_norm);
    }
    track_norm == scope_norm
        || (track_norm.starts_with(scope_norm)
            && track_norm.as_bytes().get(scope_norm.len()) == Some(&b'/'))
}

pub fn normalize_match_key(input: &str) -> String {
    input
        .split(|c: char| !c.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_lowercase())
        .collect::<Vec<_>>()
        .join(" ")
}

pub(crate) fn parse_provider_kind(raw: &str) -> ProviderKind {
    match raw {
        "local" => ProviderKind::Local,
        "smb" => ProviderKind::Smb,
        "web_dav" | "webdav" => ProviderKind::WebDav,
        "qobuz" => ProviderKind::Qobuz,
        "tidal" => ProviderKind::Tidal,
        "deezer" => ProviderKind::Deezer,
        "apple_music" | "applemusic" => ProviderKind::AppleMusic,
        "youtube_music" | "youtubemusic" | "ytm" => ProviderKind::YouTubeMusic,
        _ => ProviderKind::Local,
    }
}

pub(crate) fn parse_audio_codec(raw: &str) -> AudioCodec {
    match raw {
        "flac" => AudioCodec::Flac,
        "alac" => AudioCodec::Alac,
        "wav" => AudioCodec::Wav,
        "aiff" => AudioCodec::Aiff,
        "dsf" => AudioCodec::Dsf,
        "dsdiff" => AudioCodec::Dsdiff,
        "aac" => AudioCodec::Aac,
        "mp3" => AudioCodec::Mp3,
        "opus" => AudioCodec::Opus,
        _ => AudioCodec::Flac,
    }
}

pub struct LibraryRepository;

impl LibraryRepository {
    pub fn deterministic_artist_id(name: &str) -> String {
        deterministic_artist_id(name)
    }

    // -------------------------------------------------------------------------
    // 1. Artists
    // -------------------------------------------------------------------------

    pub async fn insert_artist(pool: &SqlitePool, artist: &Artist) -> Result<Artist> {
        sqlx::query(
            "INSERT INTO artists (id, name, sort_name, musicbrainz_id, biography, image_path) \
             VALUES (?, ?, ?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET \
                name = excluded.name, \
                sort_name = excluded.sort_name, \
                musicbrainz_id = excluded.musicbrainz_id, \
                biography = excluded.biography, \
                image_path = excluded.image_path",
        )
        .bind(&artist.id)
        .bind(&artist.name)
        .bind(&artist.sort_name)
        .bind(&artist.musicbrainz_id)
        .bind(&artist.biography)
        .bind(&artist.image_path)
        .execute(pool)
        .await?;

        Ok(artist.clone())
    }

    pub async fn find_artist_by_id(pool: &SqlitePool, id: &str) -> Result<Option<Artist>> {
        let row: Option<ArtistRow> = sqlx::query_as(
            "SELECT id, name, sort_name, musicbrainz_id, biography, image_path FROM artists WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?;

        match row.map(Artist::from) {
            Some(mut artist) => {
                let ovs = super::ingestion::IngestionRepository::get_overrides_for_entity(
                    pool, "artist", &artist.id,
                )
                .await?;
                super::ingestion::IngestionRepository::apply_artist_overrides(&mut artist, &ovs);
                Ok(Some(artist))
            }
            None => Ok(None),
        }
    }

    pub async fn search_artists_by_name(
        pool: &SqlitePool,
        name_query: &str,
    ) -> Result<Vec<Artist>> {
        let pattern = format!("%{}%", name_query);
        let rows: Vec<ArtistRow> = sqlx::query_as(
            "SELECT id, name, sort_name, musicbrainz_id, biography, image_path FROM artists \
             WHERE name LIKE ? ORDER BY sort_name ASC",
        )
        .bind(pattern)
        .fetch_all(pool)
        .await?;

        let mut artists: Vec<Artist> = rows.into_iter().map(Artist::from).collect();
        super::ingestion::IngestionRepository::apply_artist_overrides_batch(pool, &mut artists)
            .await?;
        Ok(artists)
    }

    pub async fn list_artists(
        pool: &SqlitePool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Artist>> {
        let rows: Vec<ArtistRow> = sqlx::query_as(
            "SELECT id, name, sort_name, musicbrainz_id, biography, image_path \
             FROM artists ORDER BY sort_name ASC, name ASC LIMIT ? OFFSET ?",
        )
        .bind(limit as i64)
        .bind(offset as i64)
        .fetch_all(pool)
        .await?;

        let mut artists: Vec<Artist> = rows.into_iter().map(Artist::from).collect();
        super::ingestion::IngestionRepository::apply_artist_overrides_batch(pool, &mut artists)
            .await?;
        Ok(artists)
    }

    pub async fn upsert_artist_by_mbid_or_name(
        pool: &SqlitePool,
        name: &str,
        musicbrainz_id: Option<&str>,
        biography: Option<&str>,
        image_path: Option<&str>,
    ) -> Result<Artist> {
        let trimmed_name = name.trim();
        let det_id = deterministic_artist_id(trimmed_name);
        let clean_mbid = musicbrainz_id.map(str::trim).filter(|s| !s.is_empty());
        let clean_bio = biography.map(str::trim).filter(|s| !s.is_empty());
        let clean_img = image_path.map(str::trim).filter(|s| !s.is_empty());

        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Artist> = async {
            let mut existing: Option<ArtistRow> = if let Some(mbid) = clean_mbid {
                sqlx::query_as(
                    "SELECT id, name, sort_name, musicbrainz_id, biography, image_path \
                     FROM artists WHERE musicbrainz_id = ? LIMIT 1",
                )
                .bind(mbid)
                .fetch_optional(tx.conn())
                .await?
            } else {
                None
            };

            if existing.is_none() {
                existing = sqlx::query_as(
                    "SELECT id, name, sort_name, musicbrainz_id, biography, image_path \
                     FROM artists WHERE id = ? LIMIT 1",
                )
                .bind(&det_id)
                .fetch_optional(tx.conn())
                .await?;
            }

            if existing.is_none() {
                existing = sqlx::query_as(
                    "SELECT id, name, sort_name, musicbrainz_id, biography, image_path \
                     FROM artists WHERE LOWER(name) = LOWER(?) LIMIT 1",
                )
                .bind(trimmed_name)
                .fetch_optional(tx.conn())
                .await?;
            }

            if let Some(found) = existing {
                let now = Utc::now().to_rfc3339();
                let updated_mbid = clean_mbid
                    .map(str::to_string)
                    .or(found.musicbrainz_id.clone());
                let updated_bio = clean_bio.map(str::to_string).or(found.biography.clone());
                let updated_img = clean_img.map(str::to_string).or(found.image_path.clone());
                let mark_enriched =
                    clean_mbid.is_some() || clean_bio.is_some() || clean_img.is_some();

                sqlx::query(
                    "UPDATE artists SET \
                        musicbrainz_id = ?, \
                        biography = ?, \
                        image_path = ?, \
                        enriched_at = CASE WHEN ? THEN ? ELSE enriched_at END \
                     WHERE id = ?",
                )
                .bind(&updated_mbid)
                .bind(&updated_bio)
                .bind(&updated_img)
                .bind(mark_enriched)
                .bind(&now)
                .bind(&found.id)
                .execute(tx.conn())
                .await?;

                Ok(Artist {
                    id: found.id,
                    name: found.name,
                    sort_name: found.sort_name,
                    musicbrainz_id: updated_mbid,
                    biography: updated_bio,
                    image_path: updated_img,
                })
            } else {
                let artist = Artist {
                    id: det_id,
                    name: trimmed_name.to_string(),
                    sort_name: CanonicalAlbum::derive_sort_title(trimmed_name),
                    musicbrainz_id: clean_mbid.map(str::to_string),
                    biography: clean_bio.map(str::to_string),
                    image_path: clean_img.map(str::to_string),
                };
                let enriched_at =
                    if clean_mbid.is_some() || clean_bio.is_some() || clean_img.is_some() {
                        Some(Utc::now().to_rfc3339())
                    } else {
                        None
                    };

                sqlx::query(
                    "INSERT INTO artists (id, name, sort_name, musicbrainz_id, biography, image_path, enriched_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&artist.id)
                .bind(&artist.name)
                .bind(&artist.sort_name)
                .bind(&artist.musicbrainz_id)
                .bind(&artist.biography)
                .bind(&artist.image_path)
                .bind(&enriched_at)
                .execute(tx.conn())
                .await?;

                Ok(artist)
            }
        }
        .await;

        match res {
            Ok(artist) => {
                tx.commit().await?;
                Ok(artist)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn delete_artist(pool: &SqlitePool, id: &str) -> Result<()> {
        sqlx::query("DELETE FROM artists WHERE id = ?")
            .bind(id)
            .execute(pool)
            .await?;
        Ok(())
    }

    // -------------------------------------------------------------------------
    // 2. Canonical Albums & Album Versions
    // -------------------------------------------------------------------------

    pub async fn insert_canonical_album(
        pool: &SqlitePool,
        album: &CanonicalAlbum,
        primary_artist_id: Option<&str>,
    ) -> Result<CanonicalAlbum> {
        let created_at = Utc::now().to_rfc3339();
        let norm_title = normalize_match_key(&album.title);
        let artist_name_for_norm = if let Some(aid) = primary_artist_id {
            let row: Option<(String,)> =
                sqlx::query_as("SELECT name FROM artists WHERE id = ?")
                    .bind(aid)
                    .fetch_optional(pool)
                    .await?;
            row.map(|(n,)| n).unwrap_or_else(|| album.artist_name.clone())
        } else {
            album.artist_name.clone()
        };
        let norm_artist = normalize_match_key(&artist_name_for_norm);

        sqlx::query(
            "INSERT INTO canonical_albums (id, title, sort_title, primary_artist_id, album_artist, release_year, \
             musicbrainz_release_group_id, cover_url, merged_cover_path, normalized_title, normalized_artist, created_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET \
                title = excluded.title, \
                sort_title = excluded.sort_title, \
                primary_artist_id = excluded.primary_artist_id, \
                album_artist = excluded.album_artist, \
                release_year = excluded.release_year, \
                musicbrainz_release_group_id = excluded.musicbrainz_release_group_id, \
                cover_url = excluded.cover_url, \
                merged_cover_path = excluded.merged_cover_path, \
                normalized_title = excluded.normalized_title, \
                normalized_artist = excluded.normalized_artist",
        )
        .bind(&album.id)
        .bind(&album.title)
        .bind(&album.sort_title)
        .bind(primary_artist_id)
        .bind(&album.album_artist)
        .bind(album.release_year)
        .bind(&album.musicbrainz_release_group_id)
        .bind(&album.cover_url)
        .bind(&album.cover_url)
        .bind(&norm_title)
        .bind(&norm_artist)
        .bind(&created_at)
        .execute(pool)
        .await?;

        // Insert versions if provided
        for ver in &album.versions {
            Self::insert_album_version(pool, ver).await?;
        }

        Ok(album.clone())
    }

    pub async fn update_canonical_album_metadata(
        pool: &SqlitePool,
        album_id: &str,
        upc: Option<&str>,
        mb_rg_id: Option<&str>,
        editorial_bio: Option<&str>,
        cover_url: Option<&str>,
    ) -> Result<()> {
        let clean_upc = upc.map(str::trim).filter(|s| !s.is_empty());
        let clean_mb = mb_rg_id.map(str::trim).filter(|s| !s.is_empty());
        let clean_bio = editorial_bio.map(str::trim).filter(|s| !s.is_empty());
        let clean_cover = cover_url.map(str::trim).filter(|s| !s.is_empty());

        sqlx::query(
            "UPDATE canonical_albums SET \
                upc = COALESCE(?, upc), \
                musicbrainz_release_group_id = COALESCE(?, musicbrainz_release_group_id), \
                editorial_bio = COALESCE(?, editorial_bio), \
                cover_url = COALESCE(?, cover_url), \
                merged_cover_path = COALESCE(?, merged_cover_path) \
             WHERE id = ?",
        )
        .bind(clean_upc)
        .bind(clean_mb)
        .bind(clean_bio)
        .bind(clean_cover)
        .bind(clean_cover)
        .bind(album_id)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn mark_album_enriched(pool: &SqlitePool, album_id: &str) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query("UPDATE canonical_albums SET enriched_at = ? WHERE id = ?")
            .bind(now)
            .bind(album_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn insert_album_version(
        pool: &SqlitePool,
        version: &AlbumVersion,
    ) -> Result<AlbumVersion> {
        let provider_str = version.provider.as_str();
        let codec_str = version.format.codec.as_str();

        sqlx::query(
            "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, \
             codec, sample_rate_hz, bit_depth, channels, is_dsd, edition_label) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(provider_id, external_album_id) DO UPDATE SET \
                canonical_album_id = excluded.canonical_album_id, \
                codec = excluded.codec, \
                sample_rate_hz = excluded.sample_rate_hz, \
                bit_depth = excluded.bit_depth, \
                channels = excluded.channels, \
                is_dsd = excluded.is_dsd, \
                edition_label = excluded.edition_label",
        )
        .bind(&version.id)
        .bind(&version.canonical_album_id)
        .bind(provider_str)
        .bind(&version.external_album_id)
        .bind(codec_str)
        .bind(version.format.sample_rate_hz as i64)
        .bind(version.format.bit_depth as i64)
        .bind(version.format.channels as i64)
        .bind(if version.format.is_dsd { 1 } else { 0 })
        .bind(&version.edition_label)
        .execute(pool)
        .await?;

        Ok(version.clone())
    }

    async fn hydrate_canonical_albums(
        pool: &SqlitePool,
        rows: Vec<CanonicalAlbumRow>,
    ) -> Result<Vec<CanonicalAlbum>> {
        let mut albums = Vec::with_capacity(rows.len());
        for row in rows {
            let versions = Self::list_versions_for_album(pool, &row.id).await?;
            albums.push(CanonicalAlbum {
                id: row.id,
                title: row.title,
                sort_title: row.sort_title,
                artist_name: row.artist_name.unwrap_or_default(),
                album_artist: row.album_artist,
                release_year: row.release_year,
                musicbrainz_release_group_id: row.musicbrainz_release_group_id,
                cover_url: row.cover_url,
                versions,
            });
        }
        super::ingestion::IngestionRepository::apply_album_overrides_batch(pool, &mut albums)
            .await?;
        Ok(albums)
    }

    pub async fn find_canonical_album_by_id(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<CanonicalAlbum>> {
        let row: Option<CanonicalAlbumRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ca.sort_title, COALESCE(ar.name, '') AS artist_name, ca.album_artist, \
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => {
                let mut albums = Self::hydrate_canonical_albums(pool, vec![r]).await?;
                Ok(albums.pop())
            }
            None => Ok(None),
        }
    }

    pub async fn find_canonical_albums_by_artist(
        pool: &SqlitePool,
        artist_id: &str,
    ) -> Result<Vec<CanonicalAlbum>> {
        let rows: Vec<CanonicalAlbumRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ca.sort_title, COALESCE(ar.name, '') AS artist_name, ca.album_artist, \
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.primary_artist_id = ? \
             ORDER BY ca.release_year ASC, ca.sort_title ASC",
        )
        .bind(artist_id)
        .fetch_all(pool)
        .await?;

        Self::hydrate_canonical_albums(pool, rows).await
    }

    pub async fn list_canonical_albums(
        pool: &SqlitePool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<CanonicalAlbum>> {
        let rows: Vec<CanonicalAlbumRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ca.sort_title, COALESCE(ar.name, '') AS artist_name, ca.album_artist, \
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             ORDER BY ca.sort_title ASC, ca.title ASC LIMIT ? OFFSET ?",
        )
        .bind(limit as i64)
        .bind(offset as i64)
        .fetch_all(pool)
        .await?;

        Self::hydrate_canonical_albums(pool, rows).await
    }

    pub async fn find_canonical_album_by_mb_release_group(
        pool: &SqlitePool,
        mb_rg_id: &str,
    ) -> Result<Option<CanonicalAlbum>> {
        let trimmed = mb_rg_id.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }
        let row: Option<CanonicalAlbumRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ca.sort_title, COALESCE(ar.name, '') AS artist_name, ca.album_artist, \
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.musicbrainz_release_group_id = ? LIMIT 1",
        )
        .bind(trimmed)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => Ok(Self::hydrate_canonical_albums(pool, vec![r]).await?.pop()),
            None => Ok(None),
        }
    }

    pub async fn find_canonical_album_by_upc(
        pool: &SqlitePool,
        upc: &str,
    ) -> Result<Option<CanonicalAlbum>> {
        let trimmed = upc.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }
        let row: Option<CanonicalAlbumRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ca.sort_title, COALESCE(ar.name, '') AS artist_name, ca.album_artist, \
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.upc = ? LIMIT 1",
        )
        .bind(trimmed)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => Ok(Self::hydrate_canonical_albums(pool, vec![r]).await?.pop()),
            None => Ok(None),
        }
    }

    pub async fn find_canonical_albums_by_normalized_key(
        pool: &SqlitePool,
        title: &str,
        artist_name: &str,
    ) -> Result<Vec<CanonicalAlbum>> {
        let norm_title = normalize_match_key(title);
        let norm_artist = normalize_match_key(artist_name);
        if norm_title.is_empty() || norm_artist.is_empty() {
            return Ok(Vec::new());
        }

        let rows: Vec<CanonicalAlbumRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ca.sort_title, COALESCE(ar.name, '') AS artist_name, ca.album_artist, \
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE (ca.normalized_title = ? AND ca.normalized_artist = ?) \
                OR (ca.normalized_title IS NULL AND LOWER(TRIM(ca.title)) = ? AND LOWER(TRIM(COALESCE(ar.name, ''))) = ?) \
             ORDER BY ca.created_at ASC, ca.id ASC",
        )
        .bind(&norm_title)
        .bind(&norm_artist)
        .bind(title.trim().to_lowercase())
        .bind(artist_name.trim().to_lowercase())
        .fetch_all(pool)
        .await?;

        Self::hydrate_canonical_albums(pool, rows).await
    }

    pub async fn find_canonical_album_ids_by_isrcs(
        pool: &SqlitePool,
        isrcs: &[String],
    ) -> Result<Vec<String>> {
        let mut cleaned: Vec<String> = isrcs
            .iter()
            .map(|s| s.chars().filter(|c| *c != '-').collect::<String>().trim().to_ascii_uppercase())
            .filter(|s| !s.is_empty())
            .collect();
        cleaned.sort();
        cleaned.dedup();

        if cleaned.is_empty() {
            return Ok(Vec::new());
        }

        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT DISTINCT av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE UPPER(REPLACE(ts.isrc, '-', '')) IN (",
        );
        let mut separated = qb.separated(", ");
        for isrc in &cleaned {
            separated.push_bind(isrc);
        }
        separated.push_unseparated(") ORDER BY av.canonical_album_id ASC");

        let rows: Vec<(String,)> = qb.build_query_as().fetch_all(pool).await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }

    pub async fn find_canonical_album_match(
        pool: &SqlitePool,
        title: &str,
        artist_name: &str,
        upc: Option<&str>,
        mb_rg_id: Option<&str>,
        track_isrcs: &[String],
    ) -> Result<Option<CanonicalAlbum>> {
        if let Some(mb) = mb_rg_id
            && let Some(album) = Self::find_canonical_album_by_mb_release_group(pool, mb).await?
        {
            return Ok(Some(album));
        }

        if let Some(u) = upc
            && let Some(album) = Self::find_canonical_album_by_upc(pool, u).await?
        {
            return Ok(Some(album));
        }

        if !track_isrcs.is_empty() {
            let ids = Self::find_canonical_album_ids_by_isrcs(pool, track_isrcs).await?;
            if let Some(first_id) = ids.first()
                && let Some(album) = Self::find_canonical_album_by_id(pool, first_id).await?
            {
                return Ok(Some(album));
            }
        }

        let by_norm = Self::find_canonical_albums_by_normalized_key(pool, title, artist_name).await?;
        Ok(by_norm.into_iter().next())
    }

    pub async fn merge_canonical_albums(
        pool: &SqlitePool,
        target_album_id: &str,
        source_album_id: &str,
    ) -> Result<bool> {
        if target_album_id == source_album_id {
            return Ok(false);
        }

        let mut tx = ImmediateTx::begin(pool).await?;

        let target_exists: Option<(i32,)> =
            sqlx::query_as("SELECT 1 FROM canonical_albums WHERE id = ?")
                .bind(target_album_id)
                .fetch_optional(tx.conn())
                .await?;
        let source_row: Option<MergeAlbumSourceRow> = sqlx::query_as(
            "SELECT primary_artist_id, album_artist, release_year, upc, musicbrainz_release_group_id, \
             editorial_bio, cover_url, merged_cover_path, normalized_title, normalized_artist, enriched_at \
             FROM canonical_albums WHERE id = ?",
        )
        .bind(source_album_id)
        .fetch_optional(tx.conn())
        .await?;

        let (Some(_), Some(src)) = (target_exists, source_row) else {
            tx.rollback().await?;
            return Ok(false);
        };

        let res: Result<()> = async {
            // Clear source's UNIQUE musicbrainz_release_group_id first so COALESCE onto target cannot collide.
            sqlx::query(
                "UPDATE canonical_albums SET musicbrainz_release_group_id = NULL WHERE id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "UPDATE canonical_albums SET \
                    primary_artist_id = COALESCE(primary_artist_id, ?), \
                    album_artist = COALESCE(album_artist, ?), \
                    release_year = COALESCE(release_year, ?), \
                    upc = COALESCE(upc, ?), \
                    musicbrainz_release_group_id = COALESCE(musicbrainz_release_group_id, ?), \
                    editorial_bio = COALESCE(editorial_bio, ?), \
                    cover_url = COALESCE(cover_url, ?), \
                    merged_cover_path = COALESCE(merged_cover_path, ?), \
                    normalized_title = COALESCE(normalized_title, ?), \
                    normalized_artist = COALESCE(normalized_artist, ?), \
                    enriched_at = COALESCE(enriched_at, ?) \
                 WHERE id = ?",
            )
            .bind(&src.primary_artist_id)
            .bind(&src.album_artist)
            .bind(src.release_year)
            .bind(&src.upc)
            .bind(&src.musicbrainz_release_group_id)
            .bind(&src.editorial_bio)
            .bind(&src.cover_url)
            .bind(&src.merged_cover_path)
            .bind(&src.normalized_title)
            .bind(&src.normalized_artist)
            .bind(&src.enriched_at)
            .bind(target_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query("UPDATE album_versions SET canonical_album_id = ? WHERE canonical_album_id = ?")
                .bind(target_album_id)
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            sqlx::query(
                "INSERT OR IGNORE INTO album_credits (canonical_album_id, artist_id, role) \
                 SELECT ?, artist_id, role FROM album_credits WHERE canonical_album_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query("DELETE FROM album_credits WHERE canonical_album_id = ?")
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            sqlx::query(
                "INSERT OR IGNORE INTO profile_favorites (profile_id, item_type, item_id, created_at) \
                 SELECT profile_id, item_type, ?, created_at FROM profile_favorites \
                 WHERE item_type = 'album' AND item_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "DELETE FROM profile_favorites WHERE item_type = 'album' AND item_id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            let migrated = sqlx::query(
                "INSERT OR IGNORE INTO artwork_overrides (target_kind, target_id, image_path, updated_at) \
                 SELECT target_kind, ?, image_path, updated_at FROM artwork_overrides \
                 WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            if migrated.rows_affected() > 0 {
                sqlx::query("DELETE FROM artwork_cache WHERE album_id = ?")
                    .bind(target_album_id)
                    .execute(tx.conn())
                    .await?;
            }

            sqlx::query(
                "DELETE FROM artwork_overrides WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query("DELETE FROM search_fts WHERE entity_type = 'album' AND entity_id = ?")
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            sqlx::query("DELETE FROM canonical_albums WHERE id = ?")
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(true)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn deduplicate_canonical_albums(pool: &SqlitePool) -> Result<usize> {
        let rows: Vec<DedupAlbumCandidateRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ar.name AS artist_name, ca.normalized_title, \
             ca.normalized_artist, ca.upc, ca.musicbrainz_release_group_id, \
             COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             ORDER BY ca.created_at ASC, ca.id ASC",
        )
        .fetch_all(pool)
        .await?;

        if rows.len() < 2 {
            return Ok(0);
        }

        let n = rows.len();
        let mut idx_by_id = HashMap::with_capacity(n);
        for (i, r) in rows.iter().enumerate() {
            idx_by_id.insert(r.id.as_str(), i);
        }

        let mut parent: Vec<usize> = (0..n).collect();
        fn find(parent: &mut [usize], mut x: usize) -> usize {
            while parent[x] != x {
                parent[x] = parent[parent[x]];
                x = parent[x];
            }
            x
        }
        fn union(parent: &mut [usize], a: usize, b: usize) {
            let ra = find(parent, a);
            let rb = find(parent, b);
            if ra != rb {
                parent[rb] = ra;
            }
        }

        let mut by_mb: HashMap<String, usize> = HashMap::new();
        let mut by_upc: HashMap<String, usize> = HashMap::new();
        let mut by_norm: HashMap<(String, String), usize> = HashMap::new();

        for (i, r) in rows.iter().enumerate() {
            if let Some(mb) = r.musicbrainz_release_group_id.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                let key = mb.to_ascii_lowercase();
                if let Some(&prev) = by_mb.get(&key) {
                    union(&mut parent, prev, i);
                } else {
                    by_mb.insert(key, i);
                }
            }
            if let Some(upc) = r.upc.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                let key = upc.to_string();
                if let Some(&prev) = by_upc.get(&key) {
                    union(&mut parent, prev, i);
                } else {
                    by_upc.insert(key, i);
                }
            }

            let nt = r
                .normalized_title
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| normalize_match_key(&r.title));
            let na = r
                .normalized_artist
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| normalize_match_key(r.artist_name.as_deref().unwrap_or("")));

            if !nt.is_empty() && !na.is_empty() {
                let key = (nt, na);
                if let Some(&prev) = by_norm.get(&key) {
                    union(&mut parent, prev, i);
                } else {
                    by_norm.insert(key, i);
                }
            }
        }

        let isrc_rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT av.canonical_album_id, UPPER(REPLACE(ts.isrc, '-', '')) \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE ts.isrc IS NOT NULL AND TRIM(ts.isrc) != ''",
        )
        .fetch_all(pool)
        .await?;

        let mut by_isrc: HashMap<String, usize> = HashMap::new();
        for (alb_id, isrc) in isrc_rows {
            if let Some(&idx) = idx_by_id.get(alb_id.as_str()) {
                if let Some(&prev) = by_isrc.get(&isrc) {
                    union(&mut parent, prev, idx);
                } else {
                    by_isrc.insert(isrc, idx);
                }
            }
        }

        let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
        for i in 0..n {
            let root = find(&mut parent, i);
            groups.entry(root).or_default().push(i);
        }

        let mut merged_count = 0usize;
        for (_, mut members) in groups {
            if members.len() < 2 {
                continue;
            }
            // Prefer the richest album as target, breaking ties by row order (earliest created_at).
            members.sort_by_key(|&idx| {
                let r = &rows[idx];
                let score = usize::from(r.musicbrainz_release_group_id.is_some()) * 4
                    + usize::from(r.upc.is_some()) * 2
                    + usize::from(r.cover_url.is_some());
                (std::cmp::Reverse(score), idx)
            });

            let target_id = &rows[members[0]].id;
            for &src_idx in &members[1..] {
                let src_id = &rows[src_idx].id;
                if Self::merge_canonical_albums(pool, target_id, src_id).await? {
                    merged_count += 1;
                }
            }
        }

        Ok(merged_count)
    }

    pub async fn get_album_detail(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Option<AlbumDetail>> {
        let Some(album) = Self::find_canonical_album_by_id(pool, album_id).await? else {
            return Ok(None);
        };

        let mut versions = Vec::with_capacity(album.versions.len());
        for ver in &album.versions {
            let tracks = Self::find_track_sources_by_version(pool, &ver.id).await?;
            versions.push(AlbumVersionDetail {
                version: ver.clone(),
                tracks,
            });
        }

        let credits_raw = Self::list_credits_for_album(pool, &album.id).await?;
        let credits = credits_raw
            .into_iter()
            .map(|c| AlbumCreditDetail {
                artist_id: c.artist_id,
                artist_name: c.artist_name.unwrap_or_default(),
                role: c.role,
                album_id: Some(album.id.clone()),
                album_title: Some(album.title.clone()),
            })
            .collect();

        Ok(Some(AlbumDetail {
            album,
            versions,
            credits,
        }))
    }

    pub async fn get_artist_detail(
        pool: &SqlitePool,
        artist_id: &str,
    ) -> Result<Option<ArtistDetail>> {
        let Some(artist) = Self::find_artist_by_id(pool, artist_id).await? else {
            return Ok(None);
        };

        let primary_albums = Self::find_canonical_albums_by_artist(pool, &artist.id).await?;
        let credits = Self::list_credits_for_artist(pool, &artist.id).await?;

        let mut seen_album_ids: HashSet<String> =
            primary_albums.iter().map(|a| a.id.clone()).collect();
        let mut albums = primary_albums;

        for credit in &credits {
            if let Some(ref alb_id) = credit.album_id
                && seen_album_ids.insert(alb_id.clone())
                && let Some(alb) = Self::find_canonical_album_by_id(pool, alb_id).await?
            {
                albums.push(alb);
            }
        }

        Ok(Some(ArtistDetail {
            id: artist.id,
            name: artist.name,
            sort_name: artist.sort_name,
            musicbrainz_id: artist.musicbrainz_id,
            biography: artist.biography,
            image_path: artist.image_path,
            albums,
            credits,
        }))
    }

    pub async fn list_versions_for_album(
        pool: &SqlitePool,
        canonical_album_id: &str,
    ) -> Result<Vec<AlbumVersion>> {
        let rows: Vec<AlbumVersionRow> = sqlx::query_as(
            "SELECT id, canonical_album_id, provider_id, external_album_id, codec, \
             sample_rate_hz, bit_depth, channels, is_dsd, edition_label \
             FROM album_versions WHERE canonical_album_id = ?",
        )
        .bind(canonical_album_id)
        .fetch_all(pool)
        .await?;

        let mut versions = Vec::with_capacity(rows.len());
        for row in rows {
            let provider = parse_provider_kind(&row.provider_id);
            let codec = parse_audio_codec(&row.codec);

            versions.push(AlbumVersion {
                id: row.id,
                canonical_album_id: row.canonical_album_id,
                provider,
                external_album_id: row.external_album_id,
                format: AudioFormat {
                    codec,
                    sample_rate_hz: row.sample_rate_hz as u32,
                    bit_depth: row.bit_depth as u8,
                    channels: row.channels as u8,
                    is_dsd: row.is_dsd == 1,
                },
                edition_label: row.edition_label,
            });
        }

        Ok(versions)
    }

    pub async fn delete_canonical_album(pool: &SqlitePool, id: &str) -> Result<()> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<()> = async {
            let track_rows: Vec<(String,)> = sqlx::query_as(
                "SELECT ts.id FROM track_sources ts \
                 JOIN album_versions av ON ts.version_id = av.id \
                 WHERE av.canonical_album_id = ?",
            )
            .bind(id)
            .fetch_all(tx.conn())
            .await?;
            let track_ids: Vec<String> = track_rows.into_iter().map(|(tid,)| tid).collect();

            for chunk in track_ids.chunks(500) {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM artwork_overrides WHERE target_kind = 'track' AND target_id IN (",
                );
                let mut sep = qb.separated(", ");
                for tid in chunk {
                    sep.push_bind(tid);
                }
                sep.push_unseparated(")");
                qb.build().execute(tx.conn()).await?;

                let mut qb_fts: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM search_fts WHERE entity_type = 'track' AND entity_id IN (",
                );
                let mut sep_fts = qb_fts.separated(", ");
                for tid in chunk {
                    sep_fts.push_bind(tid);
                }
                sep_fts.push_unseparated(")");
                qb_fts.build().execute(tx.conn()).await?;

                let mut qb_fav: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM profile_favorites WHERE item_type = 'track' AND item_id IN (",
                );
                let mut sep_fav = qb_fav.separated(", ");
                for tid in chunk {
                    sep_fav.push_bind(tid);
                }
                sep_fav.push_unseparated(")");
                qb_fav.build().execute(tx.conn()).await?;
            }

            sqlx::query(
                "DELETE FROM artwork_overrides WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(id)
            .execute(tx.conn())
            .await?;

            sqlx::query("DELETE FROM search_fts WHERE entity_type = 'album' AND entity_id = ?")
                .bind(id)
                .execute(tx.conn())
                .await?;

            sqlx::query(
                "DELETE FROM profile_favorites WHERE item_type = 'album' AND item_id = ?",
            )
            .bind(id)
            .execute(tx.conn())
            .await?;

            sqlx::query("DELETE FROM canonical_albums WHERE id = ?")
                .bind(id)
                .execute(tx.conn())
                .await?;

            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(())
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    // -------------------------------------------------------------------------
    // 3. Track Sources, File Cache & Local Pruning
    // -------------------------------------------------------------------------

    pub async fn insert_track_source(
        pool: &SqlitePool,
        track: &TrackSource,
    ) -> Result<TrackSource> {
        let provider_str = track.provider.as_str();
        let codec_str = track.format.codec.as_str();
        let channels = track.format.channels.max(1) as i64;
        let is_dsd = if track.format.is_dsd || track.format.codec.is_dsd() {
            1i32
        } else {
            0i32
        };

        let (persisted_id, has_lyrics): (String, i32) = sqlx::query_as(
            "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, \
             disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(provider_id, external_track_id) DO UPDATE SET \
                version_id = excluded.version_id, \
                title = excluded.title, \
                disc_number = excluded.disc_number, \
                track_number = excluded.track_number, \
                duration_ms = excluded.duration_ms, \
                sample_rate_hz = excluded.sample_rate_hz, \
                bit_depth = excluded.bit_depth, \
                codec = excluded.codec, \
                isrc = excluded.isrc, \
                replay_gain_track_db = excluded.replay_gain_track_db, \
                replay_gain_album_db = excluded.replay_gain_album_db, \
                replay_gain_track_peak = excluded.replay_gain_track_peak, \
                replay_gain_album_peak = excluded.replay_gain_album_peak, \
                artist_name = excluded.artist_name, \
                album_artist = excluded.album_artist, \
                genre = excluded.genre, \
                composer = excluded.composer, \
                channels = excluded.channels, \
                is_dsd = excluded.is_dsd \
             RETURNING id, CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics",
        )
        .bind(&track.id)
        .bind(&track.version_id)
        .bind(provider_str)
        .bind(&track.external_track_id)
        .bind(&track.title)
        .bind(track.disc_number as i64)
        .bind(track.track_number as i64)
        .bind(track.duration_ms as i64)
        .bind(track.format.sample_rate_hz as i64)
        .bind(track.format.bit_depth as i64)
        .bind(codec_str)
        .bind(&track.isrc)
        .bind(track.replay_gain_track_db)
        .bind(track.replay_gain_album_db)
        .bind(track.replay_gain_track_peak)
        .bind(track.replay_gain_album_peak)
        .bind(&track.artist_name)
        .bind(&track.album_artist)
        .bind(&track.genre)
        .bind(&track.composer)
        .bind(channels)
        .bind(is_dsd)
        .fetch_one(pool)
        .await?;

        let mut persisted = track.clone();
        persisted.id = persisted_id;
        persisted.has_lyrics = has_lyrics != 0;
        Ok(persisted)
    }

    pub async fn upsert_track_source_with_cache(
        pool: &SqlitePool,
        track: &TrackSource,
        embedded_lyrics: Option<&str>,
        file_mtime: Option<i64>,
        file_size: Option<i64>,
        metadata_hash: Option<&str>,
    ) -> Result<TrackSource> {
        let provider_str = track.provider.as_str();
        let codec_str = track.format.codec.as_str();
        let channels = track.format.channels.max(1) as i64;
        let is_dsd = if track.format.is_dsd || track.format.codec.is_dsd() {
            1i32
        } else {
            0i32
        };

        let (persisted_id,): (String,) = sqlx::query_as(
            "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, \
             disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             embedded_lyrics, file_mtime, file_size, metadata_hash) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(provider_id, external_track_id) DO UPDATE SET \
                version_id = excluded.version_id, \
                title = excluded.title, \
                disc_number = excluded.disc_number, \
                track_number = excluded.track_number, \
                duration_ms = excluded.duration_ms, \
                sample_rate_hz = excluded.sample_rate_hz, \
                bit_depth = excluded.bit_depth, \
                codec = excluded.codec, \
                isrc = excluded.isrc, \
                replay_gain_track_db = excluded.replay_gain_track_db, \
                replay_gain_album_db = excluded.replay_gain_album_db, \
                replay_gain_track_peak = excluded.replay_gain_track_peak, \
                replay_gain_album_peak = excluded.replay_gain_album_peak, \
                artist_name = excluded.artist_name, \
                album_artist = excluded.album_artist, \
                genre = excluded.genre, \
                composer = excluded.composer, \
                channels = excluded.channels, \
                is_dsd = excluded.is_dsd, \
                embedded_lyrics = excluded.embedded_lyrics, \
                file_mtime = excluded.file_mtime, \
                file_size = excluded.file_size, \
                metadata_hash = excluded.metadata_hash, \
                file_status = 'present', \
                missing_since = NULL \
             RETURNING id",
        )
        .bind(&track.id)
        .bind(&track.version_id)
        .bind(provider_str)
        .bind(&track.external_track_id)
        .bind(&track.title)
        .bind(track.disc_number as i64)
        .bind(track.track_number as i64)
        .bind(track.duration_ms as i64)
        .bind(track.format.sample_rate_hz as i64)
        .bind(track.format.bit_depth as i64)
        .bind(codec_str)
        .bind(&track.isrc)
        .bind(track.replay_gain_track_db)
        .bind(track.replay_gain_album_db)
        .bind(track.replay_gain_track_peak)
        .bind(track.replay_gain_album_peak)
        .bind(&track.artist_name)
        .bind(&track.album_artist)
        .bind(&track.genre)
        .bind(&track.composer)
        .bind(channels)
        .bind(is_dsd)
        .bind(embedded_lyrics)
        .bind(file_mtime)
        .bind(file_size)
        .bind(metadata_hash)
        .fetch_one(pool)
        .await?;

        let mut persisted = track.clone();
        persisted.id = persisted_id;
        persisted.has_lyrics = embedded_lyrics.is_some_and(|s| !s.trim().is_empty());
        Ok(persisted)
    }

    /// High-throughput batch track insertion wrapped in an immediate transaction.
    pub async fn insert_track_sources_batch(
        pool: &SqlitePool,
        tracks: &[TrackSource],
    ) -> Result<()> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<()> = async {
            for track in tracks {
                let provider_str = track.provider.as_str();
                let codec_str = track.format.codec.as_str();
                let channels = track.format.channels.max(1) as i64;
                let is_dsd = if track.format.is_dsd || track.format.codec.is_dsd() {
                    1i32
                } else {
                    0i32
                };

                sqlx::query(
                    "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, \
                     disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
                     replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
                     artist_name, album_artist, genre, composer, channels, is_dsd) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&track.id)
                .bind(&track.version_id)
                .bind(provider_str)
                .bind(&track.external_track_id)
                .bind(&track.title)
                .bind(track.disc_number as i64)
                .bind(track.track_number as i64)
                .bind(track.duration_ms as i64)
                .bind(track.format.sample_rate_hz as i64)
                .bind(track.format.bit_depth as i64)
                .bind(codec_str)
                .bind(&track.isrc)
                .bind(track.replay_gain_track_db)
                .bind(track.replay_gain_album_db)
                .bind(track.replay_gain_track_peak)
                .bind(track.replay_gain_album_peak)
                .bind(&track.artist_name)
                .bind(&track.album_artist)
                .bind(&track.genre)
                .bind(&track.composer)
                .bind(channels)
                .bind(is_dsd)
                .execute(tx.conn())
                .await?;
            }
            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(())
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn get_track_embedded_lyrics(
        pool: &SqlitePool,
        track_id: &str,
    ) -> Result<Option<String>> {
        let row: Option<(Option<String>,)> =
            sqlx::query_as("SELECT embedded_lyrics FROM track_sources WHERE id = ?")
                .bind(track_id)
                .fetch_optional(pool)
                .await?;

        Ok(row.and_then(|(lyrics,)| lyrics))
    }

    pub async fn get_track_file_cache_info(
        pool: &SqlitePool,
        provider_id: &str,
        external_track_id: &str,
    ) -> Result<Option<TrackFileCacheInfo>> {
        let row: Option<TrackFileCacheInfo> = sqlx::query_as(
            "SELECT id AS track_id, version_id, external_track_id, file_mtime, file_size, metadata_hash \
             FROM track_sources WHERE provider_id = ? AND external_track_id = ? LIMIT 1",
        )
        .bind(provider_id)
        .bind(external_track_id)
        .fetch_optional(pool)
        .await?;

        Ok(row)
    }

    pub async fn list_track_file_cache_info(
        pool: &SqlitePool,
        provider_id: &str,
    ) -> Result<Vec<TrackFileCacheInfo>> {
        let rows: Vec<TrackFileCacheInfo> = sqlx::query_as(
            "SELECT id AS track_id, version_id, external_track_id, file_mtime, file_size, metadata_hash \
             FROM track_sources WHERE provider_id = ?",
        )
        .bind(provider_id)
        .fetch_all(pool)
        .await?;

        Ok(rows)
    }

    pub async fn update_track_file_cache_info(
        pool: &SqlitePool,
        track_id: &str,
        file_mtime: Option<i64>,
        file_size: Option<i64>,
        metadata_hash: Option<&str>,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE track_sources SET file_mtime = ?, file_size = ?, metadata_hash = ? WHERE id = ?",
        )
        .bind(file_mtime)
        .bind(file_size)
        .bind(metadata_hash)
        .bind(track_id)
        .execute(pool)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    pub async fn prune_missing_local_tracks(
        pool: &SqlitePool,
        scope_dir: Option<&str>,
        existing_paths: &HashSet<String>,
    ) -> Result<PruneLocalTracksReport> {
        let scope_norm = scope_dir
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(normalize_local_path_for_compare);
        let existing_norm: HashSet<String> = existing_paths
            .iter()
            .map(|p| normalize_local_path_for_compare(p))
            .collect();

        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<PruneLocalTracksReport> = async {
            let local_tracks: Vec<(String, String, String)> = sqlx::query_as(
                "SELECT id, version_id, external_track_id FROM track_sources WHERE provider_id = 'local'",
            )
            .fetch_all(tx.conn())
            .await?;

            let mut missing_track_ids = Vec::new();
            let mut affected_version_ids: HashSet<String> = HashSet::new();

            for (id, version_id, external_track_id) in local_tracks {
                let norm = normalize_local_path_for_compare(&external_track_id);
                if let Some(ref scope) = scope_norm
                    && !path_in_scope(&norm, scope)
                {
                    continue;
                }
                if !existing_norm.contains(&norm) {
                    missing_track_ids.push(id);
                    affected_version_ids.insert(version_id);
                }
            }

            if missing_track_ids.is_empty() {
                return Ok(PruneLocalTracksReport::default());
            }

            let mut invalidated_artwork_paths = Vec::new();
            let mut seen_paths: HashSet<String> = HashSet::new();

            for chunk in missing_track_ids.chunks(500) {
                let mut qb_cache: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("SELECT cache_path FROM artwork_cache WHERE track_id IN (");
                let mut sep_cache = qb_cache.separated(", ");
                for tid in chunk {
                    sep_cache.push_bind(tid);
                }
                sep_cache.push_unseparated(")");
                let cache_rows: Vec<(String,)> =
                    qb_cache.build_query_as().fetch_all(tx.conn()).await?;
                for (path,) in cache_rows {
                    if seen_paths.insert(path.clone()) {
                        invalidated_artwork_paths.push(path);
                    }
                }

                let mut qb_ov: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM artwork_overrides WHERE target_kind = 'track' AND target_id IN (",
                );
                let mut sep_ov = qb_ov.separated(", ");
                for tid in chunk {
                    sep_ov.push_bind(tid);
                }
                sep_ov.push_unseparated(")");
                qb_ov.build().execute(tx.conn()).await?;

                let mut qb_del_cache: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("DELETE FROM artwork_cache WHERE track_id IN (");
                let mut sep_del_cache = qb_del_cache.separated(", ");
                for tid in chunk {
                    sep_del_cache.push_bind(tid);
                }
                sep_del_cache.push_unseparated(")");
                qb_del_cache.build().execute(tx.conn()).await?;

                let mut qb_fts: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM search_fts WHERE entity_type = 'track' AND entity_id IN (",
                );
                let mut sep_fts = qb_fts.separated(", ");
                for tid in chunk {
                    sep_fts.push_bind(tid);
                }
                sep_fts.push_unseparated(")");
                qb_fts.build().execute(tx.conn()).await?;

                let mut qb_fav: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM profile_favorites WHERE item_type = 'track' AND item_id IN (",
                );
                let mut sep_fav = qb_fav.separated(", ");
                for tid in chunk {
                    sep_fav.push_bind(tid);
                }
                sep_fav.push_unseparated(")");
                qb_fav.build().execute(tx.conn()).await?;

                let mut qb_trk: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("DELETE FROM track_sources WHERE id IN (");
                let mut sep_trk = qb_trk.separated(", ");
                for tid in chunk {
                    sep_trk.push_bind(tid);
                }
                sep_trk.push_unseparated(")");
                qb_trk.build().execute(tx.conn()).await?;
            }

            let affected_ver_vec: Vec<String> = affected_version_ids.into_iter().collect();
            let mut orphaned_version_ids = Vec::new();
            let mut candidate_album_ids: HashSet<String> = HashSet::new();

            for chunk in affected_ver_vec.chunks(500) {
                let mut qb_ver: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "SELECT av.id, av.canonical_album_id FROM album_versions av \
                     WHERE av.id IN (",
                );
                let mut sep_ver = qb_ver.separated(", ");
                for vid in chunk {
                    sep_ver.push_bind(vid);
                }
                sep_ver.push_unseparated(
                    ") AND NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.version_id = av.id)",
                );
                let rows: Vec<(String, String)> =
                    qb_ver.build_query_as().fetch_all(tx.conn()).await?;
                for (vid, alb_id) in rows {
                    orphaned_version_ids.push(vid);
                    candidate_album_ids.insert(alb_id);
                }
            }

            for chunk in orphaned_version_ids.chunks(500) {
                let mut qb_del_ver: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("DELETE FROM album_versions WHERE id IN (");
                let mut sep_del_ver = qb_del_ver.separated(", ");
                for vid in chunk {
                    sep_del_ver.push_bind(vid);
                }
                sep_del_ver.push_unseparated(")");
                qb_del_ver.build().execute(tx.conn()).await?;
            }

            let candidate_alb_vec: Vec<String> = candidate_album_ids.into_iter().collect();
            let mut orphaned_album_ids = Vec::new();

            for chunk in candidate_alb_vec.chunks(500) {
                let mut qb_alb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "SELECT ca.id FROM canonical_albums ca WHERE ca.id IN (",
                );
                let mut sep_alb = qb_alb.separated(", ");
                for aid in chunk {
                    sep_alb.push_bind(aid);
                }
                sep_alb.push_unseparated(
                    ") AND NOT EXISTS (SELECT 1 FROM album_versions av WHERE av.canonical_album_id = ca.id)",
                );
                let rows: Vec<(String,)> = qb_alb.build_query_as().fetch_all(tx.conn()).await?;
                for (aid,) in rows {
                    orphaned_album_ids.push(aid);
                }
            }

            for chunk in orphaned_album_ids.chunks(500) {
                let mut qb_cache: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("SELECT cache_path FROM artwork_cache WHERE album_id IN (");
                let mut sep_cache = qb_cache.separated(", ");
                for aid in chunk {
                    sep_cache.push_bind(aid);
                }
                sep_cache.push_unseparated(")");
                let cache_rows: Vec<(String,)> =
                    qb_cache.build_query_as().fetch_all(tx.conn()).await?;
                for (path,) in cache_rows {
                    if seen_paths.insert(path.clone()) {
                        invalidated_artwork_paths.push(path);
                    }
                }

                let mut qb_ov: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM artwork_overrides WHERE target_kind = 'album' AND target_id IN (",
                );
                let mut sep_ov = qb_ov.separated(", ");
                for aid in chunk {
                    sep_ov.push_bind(aid);
                }
                sep_ov.push_unseparated(")");
                qb_ov.build().execute(tx.conn()).await?;

                let mut qb_del_cache: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("DELETE FROM artwork_cache WHERE album_id IN (");
                let mut sep_del_cache = qb_del_cache.separated(", ");
                for aid in chunk {
                    sep_del_cache.push_bind(aid);
                }
                sep_del_cache.push_unseparated(")");
                qb_del_cache.build().execute(tx.conn()).await?;

                let mut qb_fts: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM search_fts WHERE entity_type = 'album' AND entity_id IN (",
                );
                let mut sep_fts = qb_fts.separated(", ");
                for aid in chunk {
                    sep_fts.push_bind(aid);
                }
                sep_fts.push_unseparated(")");
                qb_fts.build().execute(tx.conn()).await?;

                let mut qb_fav: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "DELETE FROM profile_favorites WHERE item_type = 'album' AND item_id IN (",
                );
                let mut sep_fav = qb_fav.separated(", ");
                for aid in chunk {
                    sep_fav.push_bind(aid);
                }
                sep_fav.push_unseparated(")");
                qb_fav.build().execute(tx.conn()).await?;

                let mut qb_alb: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("DELETE FROM canonical_albums WHERE id IN (");
                let mut sep_alb = qb_alb.separated(", ");
                for aid in chunk {
                    sep_alb.push_bind(aid);
                }
                sep_alb.push_unseparated(")");
                qb_alb.build().execute(tx.conn()).await?;
            }

            Ok(PruneLocalTracksReport {
                tracks_pruned: missing_track_ids.len(),
                versions_pruned: orphaned_version_ids.len(),
                albums_pruned: orphaned_album_ids.len(),
                invalidated_artwork_paths,
            })
        }
        .await;

        match res {
            Ok(report) => {
                tx.commit().await?;
                Ok(report)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn update_track_source_replay_gain(
        pool: &SqlitePool,
        track_id: &str,
        track_db: Option<f64>,
        album_db: Option<f64>,
        track_peak: Option<f64>,
        album_peak: Option<f64>,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE track_sources SET \
                replay_gain_track_db = ?, \
                replay_gain_album_db = ?, \
                replay_gain_track_peak = ?, \
                replay_gain_album_peak = ? \
             WHERE id = ?",
        )
        .bind(track_db)
        .bind(album_db)
        .bind(track_peak)
        .bind(album_peak)
        .bind(track_id)
        .execute(pool)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    pub async fn find_track_sources_by_version(
        pool: &SqlitePool,
        version_id: &str,
    ) -> Result<Vec<TrackSource>> {
        let rows: Vec<TrackSourceRow> = sqlx::query_as(
            "SELECT id, version_id, provider_id, external_track_id, title, disc_number, \
             track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics \
             FROM track_sources WHERE version_id = ? \
             ORDER BY disc_number ASC, track_number ASC, external_track_id ASC, title ASC",
        )
        .bind(version_id)
        .fetch_all(pool)
        .await?;

        let mut tracks = Self::map_track_rows(rows)?;
        super::ingestion::IngestionRepository::apply_track_overrides_batch(pool, &mut tracks)
            .await?;
        Ok(tracks)
    }

    pub async fn find_track_sources_by_isrc(
        pool: &SqlitePool,
        isrc: &str,
    ) -> Result<Vec<TrackSource>> {
        let rows: Vec<TrackSourceRow> = sqlx::query_as(
            "SELECT id, version_id, provider_id, external_track_id, title, disc_number, \
             track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics \
             FROM track_sources WHERE isrc = ?",
        )
        .bind(isrc)
        .fetch_all(pool)
        .await?;

        let mut tracks = Self::map_track_rows(rows)?;
        super::ingestion::IngestionRepository::apply_track_overrides_batch(pool, &mut tracks)
            .await?;
        Ok(tracks)
    }

    pub async fn find_track_source_by_id(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<TrackSource>> {
        let row: Option<TrackSourceRow> = sqlx::query_as(
            "SELECT id, version_id, provider_id, external_track_id, title, disc_number, \
             track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics \
             FROM track_sources WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => {
                let mut list = Self::map_track_rows(vec![r])?;
                super::ingestion::IngestionRepository::apply_track_overrides_batch(pool, &mut list)
                    .await?;
                Ok(list.into_iter().next())
            }
            None => Ok(None),
        }
    }

    fn map_track_rows(rows: Vec<TrackSourceRow>) -> Result<Vec<TrackSource>> {
        let mut tracks = Vec::with_capacity(rows.len());
        for row in rows {
            let provider = parse_provider_kind(&row.provider_id);
            let codec = parse_audio_codec(&row.codec);
            let is_dsd = row.is_dsd != 0 || matches!(codec, AudioCodec::Dsf | AudioCodec::Dsdiff);
            let channels = row.channels.clamp(1, u8::MAX as i64) as u8;

            tracks.push(TrackSource {
                id: row.id,
                version_id: row.version_id,
                provider,
                external_track_id: row.external_track_id,
                title: row.title,
                disc_number: row.disc_number as u16,
                track_number: row.track_number as u16,
                duration_ms: row.duration_ms as u64,
                format: AudioFormat {
                    codec,
                    sample_rate_hz: row.sample_rate_hz as u32,
                    bit_depth: row.bit_depth as u8,
                    channels,
                    is_dsd,
                },
                isrc: row.isrc,
                replay_gain_track_db: row.replay_gain_track_db,
                replay_gain_album_db: row.replay_gain_album_db,
                replay_gain_track_peak: row.replay_gain_track_peak,
                replay_gain_album_peak: row.replay_gain_album_peak,
                artist_name: row.artist_name,
                album_artist: row.album_artist,
                genre: row.genre,
                composer: row.composer,
                cover_url: None,
                artwork_cache_key: None,
                has_lyrics: row.has_lyrics != 0,
            });
        }
        Ok(tracks)
    }

    // -------------------------------------------------------------------------
    // 4. Album Credits
    // -------------------------------------------------------------------------

    pub async fn insert_album_credit(
        pool: &SqlitePool,
        album_id: &str,
        artist_id: &str,
        role: &str,
    ) -> Result<i64> {
        Self::upsert_album_credit(pool, album_id, artist_id, role).await
    }

    pub async fn upsert_album_credit(
        pool: &SqlitePool,
        album_id: &str,
        artist_id: &str,
        role: &str,
    ) -> Result<i64> {
        let trimmed_role = role.trim();
        let res = sqlx::query(
            "INSERT INTO album_credits (canonical_album_id, artist_id, role) \
             VALUES (?, ?, ?) \
             ON CONFLICT(canonical_album_id, artist_id, role) DO NOTHING",
        )
        .bind(album_id)
        .bind(artist_id)
        .bind(trimmed_role)
        .execute(pool)
        .await?;

        if res.rows_affected() > 0 {
            return Ok(res.last_insert_rowid());
        }

        let existing: (i64,) = sqlx::query_as(
            "SELECT id FROM album_credits \
             WHERE canonical_album_id = ? AND artist_id = ? AND role = ? LIMIT 1",
        )
        .bind(album_id)
        .bind(artist_id)
        .bind(trimmed_role)
        .fetch_one(pool)
        .await?;

        Ok(existing.0)
    }

    pub async fn list_credits_for_album(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Vec<AlbumCredit>> {
        let rows: Vec<AlbumCreditRow> = sqlx::query_as(
            "SELECT c.id, c.canonical_album_id, c.artist_id, c.role, a.name AS artist_name \
             FROM album_credits c \
             JOIN artists a ON c.artist_id = a.id \
             WHERE c.canonical_album_id = ?",
        )
        .bind(album_id)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| AlbumCredit {
                id: Some(r.id),
                canonical_album_id: r.canonical_album_id,
                artist_id: r.artist_id,
                role: r.role,
                artist_name: Some(r.artist_name),
            })
            .collect())
    }

    pub async fn list_credits_for_artist(
        pool: &SqlitePool,
        artist_id: &str,
    ) -> Result<Vec<AlbumCreditDetail>> {
        let rows: Vec<ArtistCreditDetailRow> = sqlx::query_as(
            "SELECT c.artist_id, a.name AS artist_name, c.role, \
             ca.id AS album_id, ca.title AS album_title \
             FROM album_credits c \
             JOIN artists a ON c.artist_id = a.id \
             JOIN canonical_albums ca ON c.canonical_album_id = ca.id \
             WHERE c.artist_id = ? \
             ORDER BY ca.release_year ASC, ca.sort_title ASC, c.role ASC",
        )
        .bind(artist_id)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| AlbumCreditDetail {
                artist_id: r.artist_id,
                artist_name: r.artist_name,
                role: r.role,
                album_id: Some(r.album_id),
                album_title: Some(r.album_title),
            })
            .collect())
    }

    // -------------------------------------------------------------------------
    // 5. Profile Favorites
    // -------------------------------------------------------------------------

    pub async fn add_favorite(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: &str,
        item_id: &str,
    ) -> Result<()> {
        let created_at = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT OR IGNORE INTO profile_favorites (profile_id, item_type, item_id, created_at) \
             VALUES (?, ?, ?, ?)",
        )
        .bind(profile_id)
        .bind(item_type)
        .bind(item_id)
        .bind(created_at)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn remove_favorite(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: &str,
        item_id: &str,
    ) -> Result<bool> {
        let res = sqlx::query(
            "DELETE FROM profile_favorites WHERE profile_id = ? AND item_type = ? AND item_id = ?",
        )
        .bind(profile_id)
        .bind(item_type)
        .bind(item_id)
        .execute(pool)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    pub async fn is_favorite(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: &str,
        item_id: &str,
    ) -> Result<bool> {
        let row: Option<(i32,)> = sqlx::query_as(
            "SELECT 1 FROM profile_favorites WHERE profile_id = ? AND item_type = ? AND item_id = ?",
        )
        .bind(profile_id)
        .bind(item_type)
        .bind(item_id)
        .fetch_optional(pool)
        .await?;

        Ok(row.is_some())
    }

    pub async fn list_favorites_for_profile(
        pool: &SqlitePool,
        profile_id: &str,
        item_type: Option<&str>,
    ) -> Result<Vec<ProfileFavorite>> {
        let rows: Vec<ProfileFavoriteRow> = match item_type {
            Some(t) => {
                sqlx::query_as(
                    "SELECT profile_id, item_type, item_id, created_at FROM profile_favorites \
                     WHERE profile_id = ? AND item_type = ? ORDER BY created_at DESC",
                )
                .bind(profile_id)
                .bind(t)
                .fetch_all(pool)
                .await?
            }
            None => {
                sqlx::query_as(
                    "SELECT profile_id, item_type, item_id, created_at FROM profile_favorites \
                     WHERE profile_id = ? ORDER BY created_at DESC",
                )
                .bind(profile_id)
                .fetch_all(pool)
                .await?
            }
        };

        Ok(rows
            .into_iter()
            .map(|r| ProfileFavorite {
                profile_id: r.profile_id,
                item_type: r.item_type,
                item_id: r.item_id,
                created_at: r.created_at,
            })
            .collect())
    }

    // -------------------------------------------------------------------------
    // 6. Play History
    // -------------------------------------------------------------------------

    pub async fn record_play(
        pool: &SqlitePool,
        profile_id: &str,
        track_source_id: &str,
        duration_listened_ms: u64,
    ) -> Result<i64> {
        let played_at = Utc::now().to_rfc3339();
        let res = sqlx::query(
            "INSERT INTO play_history (profile_id, track_source_id, played_at, duration_listened_ms) \
             VALUES (?, ?, ?, ?)",
        )
        .bind(profile_id)
        .bind(track_source_id)
        .bind(played_at)
        .bind(duration_listened_ms as i64)
        .execute(pool)
        .await?;

        Ok(res.last_insert_rowid())
    }

    pub async fn get_recent_history(
        pool: &SqlitePool,
        profile_id: &str,
        limit: u32,
    ) -> Result<Vec<PlayHistoryEntry>> {
        let rows: Vec<PlayHistoryRow> = sqlx::query_as(
            "SELECT id, profile_id, track_source_id, played_at, duration_listened_ms \
             FROM play_history WHERE profile_id = ? \
             ORDER BY played_at DESC, id DESC LIMIT ?",
        )
        .bind(profile_id)
        .bind(limit as i64)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| PlayHistoryEntry {
                id: r.id,
                profile_id: r.profile_id,
                track_source_id: r.track_source_id,
                played_at: r.played_at,
                duration_listened_ms: r.duration_listened_ms as u64,
            })
            .collect())
    }

    // -------------------------------------------------------------------------
    // 7. Paired Clients & App Preferences
    // -------------------------------------------------------------------------

    pub async fn insert_paired_client(
        pool: &SqlitePool,
        client: &PairedClient,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO paired_clients (id, device_name, platform, token_hash, created_at, last_seen_at) \
             VALUES (?, ?, ?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET \
                device_name = excluded.device_name, \
                platform = excluded.platform, \
                token_hash = excluded.token_hash, \
                last_seen_at = excluded.last_seen_at",
        )
        .bind(&client.id)
        .bind(&client.device_name)
        .bind(&client.platform)
        .bind(&client.token_hash)
        .bind(&client.created_at)
        .bind(&client.last_seen_at)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn list_paired_clients(pool: &SqlitePool) -> Result<Vec<PairedClient>> {
        let rows: Vec<PairedClient> = sqlx::query_as(
            "SELECT id, device_name, platform, token_hash, created_at, last_seen_at \
             FROM paired_clients ORDER BY last_seen_at DESC, created_at DESC",
        )
        .fetch_all(pool)
        .await?;

        Ok(rows)
    }

    pub async fn list_paired_token_hashes(pool: &SqlitePool) -> Result<Vec<String>> {
        let rows: Vec<(String,)> =
            sqlx::query_as("SELECT token_hash FROM paired_clients ORDER BY created_at DESC")
                .fetch_all(pool)
                .await?;

        Ok(rows.into_iter().map(|(h,)| h).collect())
    }

    pub async fn touch_paired_client_by_hash(
        pool: &SqlitePool,
        token_hash: &str,
    ) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query("UPDATE paired_clients SET last_seen_at = ? WHERE token_hash = ?")
            .bind(now)
            .bind(token_hash)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn delete_paired_client(pool: &SqlitePool, id: &str) -> Result<bool> {
        let res = sqlx::query("DELETE FROM paired_clients WHERE id = ?")
            .bind(id)
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn get_preference(pool: &SqlitePool, key: &str) -> Result<Option<String>> {
        let row: Option<(String,)> =
            sqlx::query_as("SELECT value FROM app_preferences WHERE key = ?")
                .bind(key)
                .fetch_optional(pool)
                .await?;
        Ok(row.map(|(v,)| v))
    }

    pub async fn set_preference(pool: &SqlitePool, key: &str, value: &str) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO app_preferences (key, value, updated_at) VALUES (?, ?, ?) \
             ON CONFLICT(key) DO UPDATE SET \
                value = excluded.value, \
                updated_at = excluded.updated_at",
        )
        .bind(key)
        .bind(value)
        .bind(now)
        .execute(pool)
        .await?;
        Ok(())
    }

    // -------------------------------------------------------------------------
    // 8. Artwork Cache & User Overrides
    // -------------------------------------------------------------------------

    pub async fn get_artwork_cache(
        pool: &SqlitePool,
        cache_key: &str,
    ) -> Result<Option<ArtworkCacheEntry>> {
        let row: Option<ArtworkCacheEntry> = sqlx::query_as(
            "SELECT cache_key, track_id, album_id, source_kind, mime_type, width, height, \
             max_dim, cache_path, source_mtime, updated_at \
             FROM artwork_cache WHERE cache_key = ?",
        )
        .bind(cache_key)
        .fetch_optional(pool)
        .await?;

        Ok(row)
    }

    pub async fn upsert_artwork_cache(
        pool: &SqlitePool,
        entry: &ArtworkCacheEntry,
    ) -> Result<()> {
        let updated_at = if entry.updated_at.trim().is_empty() {
            Utc::now().to_rfc3339()
        } else {
            entry.updated_at.clone()
        };

        sqlx::query(
            "INSERT INTO artwork_cache (cache_key, track_id, album_id, source_kind, mime_type, \
             width, height, max_dim, cache_path, source_mtime, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(cache_key) DO UPDATE SET \
                track_id = excluded.track_id, \
                album_id = excluded.album_id, \
                source_kind = excluded.source_kind, \
                mime_type = excluded.mime_type, \
                width = excluded.width, \
                height = excluded.height, \
                max_dim = excluded.max_dim, \
                cache_path = excluded.cache_path, \
                source_mtime = excluded.source_mtime, \
                updated_at = excluded.updated_at",
        )
        .bind(&entry.cache_key)
        .bind(&entry.track_id)
        .bind(&entry.album_id)
        .bind(&entry.source_kind)
        .bind(&entry.mime_type)
        .bind(entry.width)
        .bind(entry.height)
        .bind(entry.max_dim)
        .bind(&entry.cache_path)
        .bind(entry.source_mtime)
        .bind(updated_at)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn delete_artwork_cache(pool: &SqlitePool, cache_key: &str) -> Result<bool> {
        let res = sqlx::query("DELETE FROM artwork_cache WHERE cache_key = ?")
            .bind(cache_key)
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn invalidate_artwork_cache_for_track(
        pool: &SqlitePool,
        track_id: &str,
    ) -> Result<Vec<String>> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Vec<String>> = async {
            let rows: Vec<(String,)> =
                sqlx::query_as("SELECT cache_path FROM artwork_cache WHERE track_id = ?")
                    .bind(track_id)
                    .fetch_all(tx.conn())
                    .await?;

            sqlx::query("DELETE FROM artwork_cache WHERE track_id = ?")
                .bind(track_id)
                .execute(tx.conn())
                .await?;

            Ok(rows.into_iter().map(|(p,)| p).collect())
        }
        .await;

        match res {
            Ok(paths) => {
                tx.commit().await?;
                Ok(paths)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn invalidate_artwork_cache_for_album(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Vec<String>> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Vec<String>> = async {
            let rows: Vec<(String,)> =
                sqlx::query_as("SELECT cache_path FROM artwork_cache WHERE album_id = ?")
                    .bind(album_id)
                    .fetch_all(tx.conn())
                    .await?;

            sqlx::query("DELETE FROM artwork_cache WHERE album_id = ?")
                .bind(album_id)
                .execute(tx.conn())
                .await?;

            Ok(rows.into_iter().map(|(p,)| p).collect())
        }
        .await;

        match res {
            Ok(paths) => {
                tx.commit().await?;
                Ok(paths)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn clear_artwork_cache(pool: &SqlitePool) -> Result<Vec<String>> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<Vec<String>> = async {
            let rows: Vec<(String,)> = sqlx::query_as("SELECT cache_path FROM artwork_cache")
                .fetch_all(tx.conn())
                .await?;

            sqlx::query("DELETE FROM artwork_cache")
                .execute(tx.conn())
                .await?;

            Ok(rows.into_iter().map(|(p,)| p).collect())
        }
        .await;

        match res {
            Ok(paths) => {
                tx.commit().await?;
                Ok(paths)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn set_artwork_override(
        pool: &SqlitePool,
        target_kind: &str,
        target_id: &str,
        image_path: &str,
    ) -> Result<()> {
        if target_kind != "track" && target_kind != "album" {
            return Err(DbError::ConstraintViolation(format!(
                "invalid artwork override target_kind: '{target_kind}'"
            )));
        }
        let clean_target_id = target_id.trim();
        if clean_target_id.is_empty() {
            return Err(DbError::ConstraintViolation(
                "artwork override target_id cannot be empty".to_string(),
            ));
        }
        let clean_image_path = image_path.trim();
        if clean_image_path.is_empty() {
            return Err(DbError::ConstraintViolation(
                "artwork override image_path cannot be empty".to_string(),
            ));
        }

        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO artwork_overrides (target_kind, target_id, image_path, updated_at) \
             VALUES (?, ?, ?, ?) \
             ON CONFLICT(target_kind, target_id) DO UPDATE SET \
                image_path = excluded.image_path, \
                updated_at = excluded.updated_at",
        )
        .bind(target_kind)
        .bind(clean_target_id)
        .bind(clean_image_path)
        .bind(now)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn get_artwork_override(
        pool: &SqlitePool,
        target_kind: &str,
        target_id: &str,
    ) -> Result<Option<ArtworkOverride>> {
        let row: Option<ArtworkOverride> = sqlx::query_as(
            "SELECT target_kind, target_id, image_path, updated_at \
             FROM artwork_overrides WHERE target_kind = ? AND target_id = ?",
        )
        .bind(target_kind)
        .bind(target_id)
        .fetch_optional(pool)
        .await?;

        Ok(row)
    }

    pub async fn clear_artwork_override(
        pool: &SqlitePool,
        target_kind: &str,
        target_id: &str,
    ) -> Result<bool> {
        let res = sqlx::query(
            "DELETE FROM artwork_overrides WHERE target_kind = ? AND target_id = ?",
        )
        .bind(target_kind)
        .bind(target_id)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_local_path_for_compare;

    #[test]
    fn test_normalize_local_path_for_compare_extended_unc() {
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\UNC\nas\music\01.flac"),
            normalize_local_path_for_compare(r"\\nas\music\01.flac")
        );
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\unc\NAS\Music\01.flac"),
            "//nas/music/01.flac"
        );
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\Unc\nas\music\"),
            "//nas/music"
        );
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\D:\Music\01.flac"),
            normalize_local_path_for_compare(r"d:/music/01.flac")
        );
    }
}
