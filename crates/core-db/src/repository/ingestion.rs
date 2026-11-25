use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::str::FromStr;

use chrono::Utc;
use core_types::{
    AlbumVersion, AudioFormat, CanonicalAlbum, CanonicalTrack, FileStatus, MetadataLayer,
    MetadataOverride, SkipReason, SkippedFile, SourceReference, TrackSource, WatchMode,
    WatchedRoot,
};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};
use uuid::Uuid;

use super::library::{
    normalize_local_path_for_compare, normalize_match_key, parse_audio_codec, parse_provider_kind,
    path_in_scope, Artist, LibraryRepository,
};
use super::tx::ImmediateTx;
use crate::error::Result;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RelinkCandidate {
    pub track_source_id: String,
    pub version_id: String,
    pub external_track_id: String,
    pub file_status: FileStatus,
    pub canonical_track_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SidecarPlaylistEntry {
    pub raw_entry: String,
    pub resolved_track_source_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SidecarPlaylist {
    pub id: String,
    pub provider_id: String,
    pub source_path: String,
    pub name: String,
    pub track_count: u32,
    pub updated_at: String,
}

#[derive(Debug, sqlx::FromRow)]
struct WatchedRootRow {
    id: String,
    provider_id: String,
    root_path: String,
    watch_mode: String,
    poll_interval_sec: i64,
    is_online: i32,
    last_scan_at: Option<String>,
    updated_at: String,
}

impl From<WatchedRootRow> for WatchedRoot {
    fn from(r: WatchedRootRow) -> Self {
        Self {
            id: r.id,
            provider_id: r.provider_id,
            root_path: r.root_path,
            watch_mode: WatchMode::from_str(&r.watch_mode).unwrap_or(WatchMode::NativeOs),
            poll_interval_sec: r.poll_interval_sec.max(0) as u32,
            is_online: r.is_online != 0,
            last_scan_at: r.last_scan_at,
            updated_at: r.updated_at,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
struct SkippedFileRow {
    id: String,
    provider_id: String,
    file_path: String,
    reason_code: String,
    detail: String,
    file_size: Option<i64>,
    file_mtime: Option<i64>,
    first_seen_at: String,
    last_seen_at: String,
    dismissed: i32,
}

impl From<SkippedFileRow> for SkippedFile {
    fn from(r: SkippedFileRow) -> Self {
        Self {
            id: r.id,
            provider_id: r.provider_id,
            file_path: r.file_path,
            reason: SkipReason::from_str(&r.reason_code).unwrap_or(SkipReason::IoError),
            detail: r.detail,
            file_size: r.file_size.and_then(|v| u64::try_from(v).ok()),
            file_mtime: r.file_mtime,
            first_seen_at: r.first_seen_at,
            last_seen_at: r.last_seen_at,
            dismissed: r.dismissed != 0,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
struct MetadataOverrideRow {
    entity_type: String,
    entity_id: String,
    field_name: String,
    value_json: String,
    source_layer: String,
    updated_at: String,
}

impl From<MetadataOverrideRow> for MetadataOverride {
    fn from(r: MetadataOverrideRow) -> Self {
        Self {
            entity_type: r.entity_type,
            entity_id: r.entity_id,
            field_name: r.field_name,
            value_json: r.value_json,
            source_layer: MetadataLayer::from_str(&r.source_layer)
                .unwrap_or(MetadataLayer::UserEdit),
            updated_at: r.updated_at,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
struct RelinkCandidateRow {
    id: String,
    version_id: String,
    external_track_id: String,
    file_status: String,
    canonical_track_id: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct CanonicalTrackRow {
    id: String,
    canonical_album_id: String,
    title: String,
    sort_title: String,
    artist_name: String,
    album_artist: Option<String>,
    disc_number: i64,
    track_number: i64,
    duration_ms: i64,
    isrc: Option<String>,
    musicbrainz_recording_id: Option<String>,
    genre: Option<String>,
    composer: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct SourceReferenceRow {
    id: String,
    provider_id: String,
    external_track_id: String,
    codec: String,
    sample_rate_hz: i64,
    bit_depth: i64,
    channels: i64,
    is_dsd: i32,
    file_status: String,
    content_fingerprint: Option<String>,
    audio_byte_len: Option<i64>,
}

#[derive(Debug, sqlx::FromRow)]
struct AlbumVersionTocRow {
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
struct PlaylistRow {
    id: String,
    provider_id: String,
    source_path: String,
    name: String,
    track_count: i64,
    updated_at: String,
}

impl From<PlaylistRow> for SidecarPlaylist {
    fn from(r: PlaylistRow) -> Self {
        Self {
            id: r.id,
            provider_id: r.provider_id,
            source_path: r.source_path,
            name: r.name,
            track_count: r.track_count.max(0) as u32,
            updated_at: r.updated_at,
        }
    }
}

pub struct IngestionRepository;

impl IngestionRepository {
    // -------------------------------------------------------------------------
    // 1. Watched Roots CRUD
    // -------------------------------------------------------------------------

    pub async fn upsert_watched_root(
        pool: &SqlitePool,
        provider_id: &str,
        root_path: &str,
        watch_mode: WatchMode,
        poll_interval_sec: u32,
    ) -> Result<WatchedRoot> {
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let trimmed_path = root_path.trim();

        let row: WatchedRootRow = sqlx::query_as(
            "INSERT INTO watched_roots (id, provider_id, root_path, watch_mode, poll_interval_sec, is_online, updated_at) \
             VALUES (?, ?, ?, ?, ?, 1, ?) \
             ON CONFLICT(root_path) DO UPDATE SET \
                provider_id = excluded.provider_id, \
                watch_mode = excluded.watch_mode, \
                poll_interval_sec = excluded.poll_interval_sec, \
                updated_at = excluded.updated_at \
             RETURNING id, provider_id, root_path, watch_mode, poll_interval_sec, is_online, last_scan_at, updated_at",
        )
        .bind(&id)
        .bind(provider_id.trim())
        .bind(trimmed_path)
        .bind(watch_mode.as_str())
        .bind(poll_interval_sec as i64)
        .bind(&now)
        .fetch_one(pool)
        .await?;

        Ok(row.into())
    }

    pub async fn remove_watched_root(pool: &SqlitePool, id_or_path: &str) -> Result<bool> {
        let key = id_or_path.trim();
        let res = sqlx::query("DELETE FROM watched_roots WHERE id = ? OR root_path = ?")
            .bind(key)
            .bind(key)
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn list_watched_roots(pool: &SqlitePool) -> Result<Vec<WatchedRoot>> {
        let rows: Vec<WatchedRootRow> = sqlx::query_as(
            "SELECT id, provider_id, root_path, watch_mode, poll_interval_sec, is_online, last_scan_at, updated_at \
             FROM watched_roots ORDER BY root_path ASC",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn set_root_online_status(
        pool: &SqlitePool,
        id_or_path: &str,
        is_online: bool,
    ) -> Result<bool> {
        let key = id_or_path.trim();
        let now = Utc::now().to_rfc3339();
        let res = sqlx::query(
            "UPDATE watched_roots SET is_online = ?, updated_at = ? WHERE id = ? OR root_path = ?",
        )
        .bind(if is_online { 1i32 } else { 0i32 })
        .bind(&now)
        .bind(key)
        .bind(key)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn touch_root_scan_time(pool: &SqlitePool, id_or_path: &str) -> Result<bool> {
        let key = id_or_path.trim();
        let now = Utc::now().to_rfc3339();
        let res = sqlx::query(
            "UPDATE watched_roots SET last_scan_at = ?, updated_at = ? WHERE id = ? OR root_path = ?",
        )
        .bind(&now)
        .bind(&now)
        .bind(key)
        .bind(key)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    // -------------------------------------------------------------------------
    // 2. Skipped Files Quarantine
    // -------------------------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    pub async fn record_skipped_file(
        pool: &SqlitePool,
        provider_id: &str,
        file_path: &str,
        reason: SkipReason,
        detail: &str,
        file_size: Option<u64>,
        file_mtime: Option<i64>,
    ) -> Result<SkippedFile> {
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let size_i64 = file_size.map(|s| s.min(i64::MAX as u64) as i64);

        let row: SkippedFileRow = sqlx::query_as(
            "INSERT INTO skipped_files (id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0) \
             ON CONFLICT(provider_id, file_path) DO UPDATE SET \
                reason_code = excluded.reason_code, \
                detail = excluded.detail, \
                file_size = excluded.file_size, \
                file_mtime = excluded.file_mtime, \
                last_seen_at = excluded.last_seen_at, \
                dismissed = CASE \
                    WHEN skipped_files.reason_code != excluded.reason_code \
                      OR skipped_files.file_mtime IS NOT excluded.file_mtime THEN 0 \
                    ELSE skipped_files.dismissed \
                END \
             RETURNING id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed",
        )
        .bind(&id)
        .bind(provider_id.trim())
        .bind(file_path.trim())
        .bind(reason.as_str())
        .bind(detail.trim())
        .bind(size_i64)
        .bind(file_mtime)
        .bind(&now)
        .bind(&now)
        .fetch_one(pool)
        .await?;

        Ok(row.into())
    }

    pub async fn list_skipped_files(
        pool: &SqlitePool,
        include_dismissed: bool,
    ) -> Result<Vec<SkippedFile>> {
        let sql = if include_dismissed {
            "SELECT id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed \
             FROM skipped_files ORDER BY last_seen_at DESC, file_path ASC"
        } else {
            "SELECT id, provider_id, file_path, reason_code, detail, file_size, file_mtime, first_seen_at, last_seen_at, dismissed \
             FROM skipped_files WHERE dismissed = 0 ORDER BY last_seen_at DESC, file_path ASC"
        };
        let rows: Vec<SkippedFileRow> = sqlx::query_as(sql).fetch_all(pool).await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn dismiss_skipped_file(pool: &SqlitePool, id: &str) -> Result<bool> {
        let res = sqlx::query("UPDATE skipped_files SET dismissed = 1 WHERE id = ?")
            .bind(id.trim())
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn clear_skipped_for_path(
        pool: &SqlitePool,
        provider_id: &str,
        file_path: &str,
    ) -> Result<bool> {
        let res =
            sqlx::query("DELETE FROM skipped_files WHERE provider_id = ? AND file_path = ?")
                .bind(provider_id.trim())
                .bind(file_path.trim())
                .execute(pool)
                .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn clear_skipped_for_root(
        pool: &SqlitePool,
        provider_id: &str,
        root_prefix: &str,
    ) -> Result<usize> {
        let scope_norm = normalize_local_path_for_compare(root_prefix);
        let rows: Vec<(String, String)> =
            sqlx::query_as("SELECT id, file_path FROM skipped_files WHERE provider_id = ?")
                .bind(provider_id.trim())
                .fetch_all(pool)
                .await?;

        let matching_ids: Vec<String> = rows
            .into_iter()
            .filter(|(_, fp)| path_in_scope(&normalize_local_path_for_compare(fp), &scope_norm))
            .map(|(id, _)| id)
            .collect();

        if matching_ids.is_empty() {
            return Ok(0);
        }

        let mut deleted = 0usize;
        for chunk in matching_ids.chunks(500) {
            let mut qb: QueryBuilder<'_, Sqlite> =
                QueryBuilder::new("DELETE FROM skipped_files WHERE id IN (");
            let mut sep = qb.separated(", ");
            for id in chunk {
                sep.push_bind(id);
            }
            sep.push_unseparated(")");
            deleted += qb.build().execute(pool).await?.rows_affected() as usize;
        }

        Ok(deleted)
    }

    // -------------------------------------------------------------------------
    // 3. Non-Destructive Layered Metadata Overrides
    // -------------------------------------------------------------------------

    /// Sets a metadata override while strictly enforcing layer precedence:
    /// `FileTag (0) < CloudEnrichment (1) < UserEdit (2)`.
    ///
    /// Returns `Ok(true)` if written, or `Ok(false)` if blocked by an existing higher-precedence layer.
    pub async fn set_metadata_override(
        pool: &SqlitePool,
        entity_type: &str,
        entity_id: &str,
        field_name: &str,
        value_json: &str,
        source_layer: MetadataLayer,
    ) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let et = entity_type.trim();
        let eid = entity_id.trim();
        let fname = field_name.trim();
        let now = Utc::now().to_rfc3339();

        let res: Result<bool> = async {
            let existing: Option<(String,)> = sqlx::query_as(
                "SELECT source_layer FROM metadata_overrides \
                 WHERE entity_type = ? AND entity_id = ? AND field_name = ?",
            )
            .bind(et)
            .bind(eid)
            .bind(fname)
            .fetch_optional(tx.conn())
            .await?;

            if let Some((existing_str,)) = existing {
                let existing_layer =
                    MetadataLayer::from_str(&existing_str).unwrap_or(MetadataLayer::UserEdit);
                if source_layer < existing_layer {
                    return Ok(false);
                }
            }

            sqlx::query(
                "INSERT INTO metadata_overrides (entity_type, entity_id, field_name, value_json, source_layer, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(entity_type, entity_id, field_name) DO UPDATE SET \
                    value_json = excluded.value_json, \
                    source_layer = excluded.source_layer, \
                    updated_at = excluded.updated_at",
            )
            .bind(et)
            .bind(eid)
            .bind(fname)
            .bind(value_json)
            .bind(source_layer.as_str())
            .bind(&now)
            .execute(tx.conn())
            .await?;

            Ok(true)
        }
        .await;

        match res {
            Ok(written) => {
                tx.commit().await?;
                Ok(written)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn clear_metadata_override(
        pool: &SqlitePool,
        entity_type: &str,
        entity_id: &str,
        field_name: &str,
    ) -> Result<bool> {
        let res = sqlx::query(
            "DELETE FROM metadata_overrides WHERE entity_type = ? AND entity_id = ? AND field_name = ?",
        )
        .bind(entity_type.trim())
        .bind(entity_id.trim())
        .bind(field_name.trim())
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn get_overrides_for_entity(
        pool: &SqlitePool,
        entity_type: &str,
        entity_id: &str,
    ) -> Result<Vec<MetadataOverride>> {
        let rows: Vec<MetadataOverrideRow> = sqlx::query_as(
            "SELECT entity_type, entity_id, field_name, value_json, source_layer, updated_at \
             FROM metadata_overrides WHERE entity_type = ? AND entity_id = ? \
             ORDER BY field_name ASC",
        )
        .bind(entity_type.trim())
        .bind(entity_id.trim())
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn get_overrides_batch(
        pool: &SqlitePool,
        entity_type: &str,
        entity_ids: &[String],
    ) -> Result<HashMap<String, Vec<MetadataOverride>>> {
        let mut grouped: HashMap<String, Vec<MetadataOverride>> = HashMap::new();
        if entity_ids.is_empty() {
            return Ok(grouped);
        }

        let et = entity_type.trim();
        for chunk in entity_ids.chunks(500) {
            let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                "SELECT entity_type, entity_id, field_name, value_json, source_layer, updated_at \
                 FROM metadata_overrides WHERE entity_type = ",
            );
            qb.push_bind(et);
            qb.push(" AND entity_id IN (");
            let mut sep = qb.separated(", ");
            for id in chunk {
                sep.push_bind(id);
            }
            sep.push_unseparated(")");

            let rows: Vec<MetadataOverrideRow> = qb.build_query_as().fetch_all(pool).await?;
            for row in rows {
                let ov: MetadataOverride = row.into();
                grouped.entry(ov.entity_id.clone()).or_default().push(ov);
            }
        }

        Ok(grouped)
    }

    pub fn apply_track_overrides(track: &mut TrackSource, overrides: &[MetadataOverride]) {
        if overrides.is_empty() {
            return;
        }
        let mut sorted: Vec<&MetadataOverride> = overrides.iter().collect();
        sorted.sort_by_key(|o| o.source_layer);

        for ov in sorted {
            match ov.field_name.as_str() {
                "title" => {
                    if let Some(s) = decode_json_string(&ov.value_json)
                        && !s.trim().is_empty()
                    {
                        track.title = s;
                    }
                }
                "artist_name" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        track.artist_name = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "album_artist" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        track.album_artist = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "genre" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        track.genre = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "composer" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        track.composer = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "isrc" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        track.isrc = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "cover_url" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        track.cover_url = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "disc_number" => {
                    if let Some(n) = decode_json_i64(&ov.value_json)
                        && (1..=i64::from(u16::MAX)).contains(&n)
                    {
                        track.disc_number = n as u16;
                    }
                }
                "track_number" => {
                    if let Some(n) = decode_json_i64(&ov.value_json)
                        && (1..=i64::from(u16::MAX)).contains(&n)
                    {
                        track.track_number = n as u16;
                    }
                }
                _ => {}
            }
        }
    }

    pub fn apply_album_overrides(album: &mut CanonicalAlbum, overrides: &[MetadataOverride]) {
        if overrides.is_empty() {
            return;
        }
        let mut sorted: Vec<&MetadataOverride> = overrides.iter().collect();
        sorted.sort_by_key(|o| o.source_layer);

        let mut explicit_sort_title: Option<String> = None;

        for ov in sorted {
            match ov.field_name.as_str() {
                "title" => {
                    if let Some(s) = decode_json_string(&ov.value_json)
                        && !s.trim().is_empty()
                    {
                        album.title = s;
                        album.sort_title = CanonicalAlbum::derive_sort_title(&album.title);
                    }
                }
                "sort_title" => {
                    if let Some(s) = decode_json_string(&ov.value_json)
                        && !s.trim().is_empty()
                    {
                        explicit_sort_title = Some(s);
                    }
                }
                "artist_name" => {
                    if let Some(s) = decode_json_string(&ov.value_json)
                        && !s.trim().is_empty()
                    {
                        album.artist_name = s;
                    }
                }
                "album_artist" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        album.album_artist = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "release_year" => {
                    let trimmed = ov.value_json.trim();
                    if trimmed == "null" {
                        album.release_year = None;
                    } else if let Some(yr) = decode_json_i64(trimmed)
                        && (1000..=3000).contains(&yr)
                    {
                        album.release_year = Some(yr as i32);
                    }
                }
                "cover_url" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        album.cover_url = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "musicbrainz_release_group_id" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        album.musicbrainz_release_group_id = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                _ => {}
            }
        }

        if let Some(st) = explicit_sort_title {
            album.sort_title = st;
        }
    }

    pub fn apply_artist_overrides(artist: &mut Artist, overrides: &[MetadataOverride]) {
        if overrides.is_empty() {
            return;
        }
        let mut sorted: Vec<&MetadataOverride> = overrides.iter().collect();
        sorted.sort_by_key(|o| o.source_layer);

        for ov in sorted {
            match ov.field_name.as_str() {
                "name" => {
                    if let Some(s) = decode_json_string(&ov.value_json)
                        && !s.trim().is_empty()
                    {
                        artist.name = s;
                    }
                }
                "sort_name" => {
                    if let Some(s) = decode_json_string(&ov.value_json)
                        && !s.trim().is_empty()
                    {
                        artist.sort_name = s;
                    }
                }
                "biography" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        artist.biography = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "image_path" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        artist.image_path = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                "musicbrainz_id" => {
                    if let Some(opt) = decode_json_opt_string(&ov.value_json) {
                        artist.musicbrainz_id = opt.filter(|s| !s.trim().is_empty());
                    }
                }
                _ => {}
            }
        }
    }

    pub async fn apply_track_overrides_batch(
        pool: &SqlitePool,
        tracks: &mut [TrackSource],
    ) -> Result<()> {
        if tracks.is_empty() {
            return Ok(());
        }
        let ids: Vec<String> = tracks.iter().map(|t| t.id.clone()).collect();
        let map = Self::get_overrides_batch(pool, "track", &ids).await?;
        if map.is_empty() {
            return Ok(());
        }
        for track in tracks.iter_mut() {
            if let Some(ovs) = map.get(&track.id) {
                Self::apply_track_overrides(track, ovs);
            }
        }
        Ok(())
    }

    pub async fn apply_album_overrides_batch(
        pool: &SqlitePool,
        albums: &mut [CanonicalAlbum],
    ) -> Result<()> {
        if albums.is_empty() {
            return Ok(());
        }
        let ids: Vec<String> = albums.iter().map(|a| a.id.clone()).collect();
        let map = Self::get_overrides_batch(pool, "album", &ids).await?;
        if map.is_empty() {
            return Ok(());
        }
        for album in albums.iter_mut() {
            if let Some(ovs) = map.get(&album.id) {
                Self::apply_album_overrides(album, ovs);
            }
        }
        Ok(())
    }

    pub async fn apply_artist_overrides_batch(
        pool: &SqlitePool,
        artists: &mut [Artist],
    ) -> Result<()> {
        if artists.is_empty() {
            return Ok(());
        }
        let ids: Vec<String> = artists.iter().map(|a| a.id.clone()).collect();
        let map = Self::get_overrides_batch(pool, "artist", &ids).await?;
        if map.is_empty() {
            return Ok(());
        }
        for artist in artists.iter_mut() {
            if let Some(ovs) = map.get(&artist.id) {
                Self::apply_artist_overrides(artist, ovs);
            }
        }
        Ok(())
    }

    // -------------------------------------------------------------------------
    // 4. Content Fingerprint Move/Rename Relink & Soft-Missing
    // -------------------------------------------------------------------------

    pub async fn update_track_fingerprint(
        pool: &SqlitePool,
        track_source_id: &str,
        fingerprint: &str,
        audio_byte_len: u64,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE track_sources SET content_fingerprint = ?, audio_byte_len = ? WHERE id = ?",
        )
        .bind(fingerprint.trim())
        .bind(audio_byte_len.min(i64::MAX as u64) as i64)
        .bind(track_source_id.trim())
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    /// Finds an existing `track_sources` row with matching `(provider_id, fingerprint, audio_byte_len)`
    /// at a different path, preferring rows already marked `missing` or whose old local path no longer exists.
    pub async fn find_relink_candidate_by_fingerprint(
        pool: &SqlitePool,
        provider_id: &str,
        fingerprint: &str,
        audio_byte_len: u64,
        exclude_path: &str,
    ) -> Result<Option<RelinkCandidate>> {
        let rows: Vec<RelinkCandidateRow> = sqlx::query_as(
            "SELECT id, version_id, external_track_id, file_status, canonical_track_id \
             FROM track_sources \
             WHERE provider_id = ? AND content_fingerprint = ? AND audio_byte_len = ? \
             ORDER BY CASE WHEN file_status = 'missing' THEN 0 ELSE 1 END, missing_since DESC",
        )
        .bind(provider_id.trim())
        .bind(fingerprint.trim())
        .bind(audio_byte_len.min(i64::MAX as u64) as i64)
        .fetch_all(pool)
        .await?;

        let exclude_norm = normalize_local_path_for_compare(exclude_path);
        let mut fallback_missing_on_disk: Option<RelinkCandidate> = None;

        for row in rows {
            if normalize_local_path_for_compare(&row.external_track_id) == exclude_norm {
                continue;
            }
            let status = FileStatus::from_str(&row.file_status).unwrap_or(FileStatus::Present);
            let cand = RelinkCandidate {
                track_source_id: row.id,
                version_id: row.version_id,
                external_track_id: row.external_track_id,
                file_status: status,
                canonical_track_id: row.canonical_track_id,
            };

            if status == FileStatus::Missing {
                return Ok(Some(cand));
            }
            if fallback_missing_on_disk.is_none()
                && provider_id.eq_ignore_ascii_case("local")
                && !Path::new(&cand.external_track_id).exists()
            {
                fallback_missing_on_disk = Some(cand);
            }
        }

        Ok(fallback_missing_on_disk)
    }

    /// Relinks a moved or renamed track in-place so `track_sources.id`, `play_history`,
    /// `profile_favorites`, `artwork_overrides`, and `metadata_overrides` stay 100% intact.
    pub async fn relink_moved_track_source(
        pool: &SqlitePool,
        track_source_id: &str,
        new_external_track_id: &str,
        new_version_id: &str,
        new_mtime: Option<i64>,
        new_size: Option<i64>,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE track_sources \
             SET external_track_id = ?, \
                 version_id = ?, \
                 file_mtime = COALESCE(?, file_mtime), \
                 file_size = COALESCE(?, file_size), \
                 file_status = 'present', \
                 missing_since = NULL \
             WHERE id = ?",
        )
        .bind(new_external_track_id.trim())
        .bind(new_version_id.trim())
        .bind(new_mtime)
        .bind(new_size)
        .bind(track_source_id.trim())
        .execute(pool)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    /// Marks unseen tracks under `root_prefix` as `file_status = 'missing'` (soft-missing)
    /// without hard-deleting them, and restores any seen previously-missing tracks to `'present'`.
    pub async fn mark_missing_local_tracks_under_root(
        pool: &SqlitePool,
        provider_id: &str,
        root_prefix: &str,
        seen_paths: &HashSet<String>,
    ) -> Result<usize> {
        let scope_norm = normalize_local_path_for_compare(root_prefix);
        let seen_norm: HashSet<String> = seen_paths
            .iter()
            .map(|p| normalize_local_path_for_compare(p))
            .collect();
        let now = Utc::now().to_rfc3339();

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<usize> = async {
            let rows: Vec<(String, String, String)> = sqlx::query_as(
                "SELECT id, external_track_id, file_status FROM track_sources WHERE provider_id = ?",
            )
            .bind(provider_id.trim())
            .fetch_all(tx.conn())
            .await?;

            let mut to_mark_missing = Vec::new();
            let mut to_restore_present = Vec::new();

            for (id, ext_path, status) in rows {
                let norm = normalize_local_path_for_compare(&ext_path);
                if !path_in_scope(&norm, &scope_norm) {
                    continue;
                }
                if seen_norm.contains(&norm) {
                    if status != "present" {
                        to_restore_present.push(id);
                    }
                } else if status != "missing" {
                    to_mark_missing.push(id);
                }
            }

            for chunk in to_restore_present.chunks(500) {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "UPDATE track_sources SET file_status = 'present', missing_since = NULL WHERE id IN (",
                );
                let mut sep = qb.separated(", ");
                for id in chunk {
                    sep.push_bind(id);
                }
                sep.push_unseparated(")");
                qb.build().execute(tx.conn()).await?;
            }

            let mut marked = 0usize;
            for chunk in to_mark_missing.chunks(500) {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "UPDATE track_sources SET file_status = 'missing', missing_since = COALESCE(missing_since, ",
                );
                qb.push_bind(&now);
                qb.push(") WHERE id IN (");
                let mut sep = qb.separated(", ");
                for id in chunk {
                    sep.push_bind(id);
                }
                sep.push_unseparated(")");
                marked += qb.build().execute(tx.conn()).await?.rows_affected() as usize;
            }

            Ok(marked)
        }
        .await;

        match res {
            Ok(marked) => {
                tx.commit().await?;
                Ok(marked)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    // -------------------------------------------------------------------------
    // 5. Canonical Tracks & Multi-Artist Links
    // -------------------------------------------------------------------------

    pub async fn upsert_canonical_track_for_source(
        pool: &SqlitePool,
        track_source_id: &str,
        canonical_album_id: &str,
        track: &TrackSource,
        artist_names: &[String],
    ) -> Result<CanonicalTrack> {
        let now = Utc::now().to_rfc3339();
        let primary_artist = artist_names
            .first()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .or_else(|| track.artist_name.as_deref().map(str::trim).filter(|s| !s.is_empty()))
            .or_else(|| track.album_artist.as_deref().map(str::trim).filter(|s| !s.is_empty()))
            .unwrap_or("Unknown Artist")
            .to_string();

        // 1. Existing link on track_sources
        let existing_link: Option<(Option<String>,)> =
            sqlx::query_as("SELECT canonical_track_id FROM track_sources WHERE id = ?")
                .bind(track_source_id)
                .fetch_optional(pool)
                .await?;
        let mut canonical_track_id = existing_link.and_then(|(cid,)| cid);

        // 2. Match by ISRC within album
        if canonical_track_id.is_none()
            && let Some(ref isrc) = track.isrc
        {
            let clean_isrc = isrc.trim();
            if !clean_isrc.is_empty() {
                let row: Option<(String,)> = sqlx::query_as(
                    "SELECT id FROM canonical_tracks \
                     WHERE canonical_album_id = ? AND isrc = ? LIMIT 1",
                )
                .bind(canonical_album_id)
                .bind(clean_isrc)
                .fetch_optional(pool)
                .await?;
                canonical_track_id = row.map(|(id,)| id);
            }
        }

        // 3. Match by (canonical_album_id, disc_number, track_number) + normalized title
        if canonical_track_id.is_none() {
            let norm_target = normalize_match_key(&track.title);
            let candidates: Vec<(String, String)> = sqlx::query_as(
                "SELECT id, title FROM canonical_tracks \
                 WHERE canonical_album_id = ? AND disc_number = ? AND track_number = ?",
            )
            .bind(canonical_album_id)
            .bind(track.disc_number as i64)
            .bind(track.track_number as i64)
            .fetch_all(pool)
            .await?;

            for (cid, existing_title) in candidates {
                if normalize_match_key(&existing_title) == norm_target {
                    canonical_track_id = Some(cid);
                    break;
                }
            }
        }

        let resolved_id = if let Some(cid) = canonical_track_id {
            sqlx::query(
                "UPDATE canonical_tracks SET \
                    isrc = COALESCE(isrc, ?), \
                    genre = COALESCE(genre, ?), \
                    composer = COALESCE(composer, ?), \
                    album_artist = COALESCE(album_artist, ?), \
                    updated_at = ? \
                 WHERE id = ?",
            )
            .bind(&track.isrc)
            .bind(&track.genre)
            .bind(&track.composer)
            .bind(&track.album_artist)
            .bind(&now)
            .bind(&cid)
            .execute(pool)
            .await?;
            cid
        } else {
            let new_id = Uuid::new_v4().to_string();
            let sort_title = CanonicalAlbum::derive_sort_title(&track.title);
            sqlx::query(
                "INSERT INTO canonical_tracks (id, canonical_album_id, title, sort_title, artist_name, \
                 album_artist, disc_number, track_number, duration_ms, isrc, genre, composer, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&new_id)
            .bind(canonical_album_id)
            .bind(&track.title)
            .bind(&sort_title)
            .bind(&primary_artist)
            .bind(&track.album_artist)
            .bind(track.disc_number as i64)
            .bind(track.track_number as i64)
            .bind(track.duration_ms as i64)
            .bind(&track.isrc)
            .bind(&track.genre)
            .bind(&track.composer)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await?;
            new_id
        };

        sqlx::query("UPDATE track_sources SET canonical_track_id = ? WHERE id = ?")
            .bind(&resolved_id)
            .bind(track_source_id)
            .execute(pool)
            .await?;

        let names_to_link: Vec<String> = if artist_names.is_empty() {
            vec![primary_artist]
        } else {
            artist_names.to_vec()
        };
        let _ = Self::link_track_artists(pool, &resolved_id, &names_to_link, "performer").await?;

        Ok(Self::get_canonical_track_with_sources(pool, &resolved_id)
            .await?
            .expect("canonical_track just inserted/updated must exist"))
    }

    pub async fn link_track_artists(
        pool: &SqlitePool,
        canonical_track_id: &str,
        artist_names: &[String],
        role: &str,
    ) -> Result<Vec<Artist>> {
        let mut linked = Vec::new();
        let clean_role = if role.trim().is_empty() {
            "performer"
        } else {
            role.trim()
        };

        for (pos, raw_name) in artist_names.iter().enumerate() {
            let trimmed = raw_name.trim();
            if trimmed.is_empty() {
                continue;
            }
            let artist = LibraryRepository::upsert_artist_by_mbid_or_name(
                pool, trimmed, None, None, None,
            )
            .await?;

            sqlx::query(
                "INSERT INTO track_artists (canonical_track_id, artist_id, role, position) \
                 VALUES (?, ?, ?, ?) \
                 ON CONFLICT(canonical_track_id, artist_id, role) DO UPDATE SET \
                    position = excluded.position",
            )
            .bind(canonical_track_id)
            .bind(&artist.id)
            .bind(clean_role)
            .bind(pos as i64)
            .execute(pool)
            .await?;

            linked.push(artist);
        }

        Ok(linked)
    }

    pub async fn get_canonical_track_with_sources(
        pool: &SqlitePool,
        canonical_track_id: &str,
    ) -> Result<Option<CanonicalTrack>> {
        let row: Option<CanonicalTrackRow> = sqlx::query_as(
            "SELECT id, canonical_album_id, title, sort_title, artist_name, album_artist, \
             disc_number, track_number, duration_ms, isrc, musicbrainz_recording_id, genre, composer \
             FROM canonical_tracks WHERE id = ?",
        )
        .bind(canonical_track_id)
        .fetch_optional(pool)
        .await?;

        let Some(row) = row else {
            return Ok(None);
        };

        let artist_rows: Vec<(String,)> = sqlx::query_as(
            "SELECT a.name FROM track_artists ta \
             JOIN artists a ON a.id = ta.artist_id \
             WHERE ta.canonical_track_id = ? \
             ORDER BY ta.position ASC, a.name ASC",
        )
        .bind(&row.id)
        .fetch_all(pool)
        .await?;

        let artist_names: Vec<String> = artist_rows.into_iter().map(|(n,)| n).collect();
        let sources = Self::get_sources_for_canonical_track(pool, &row.id).await?;

        Ok(Some(CanonicalTrack {
            id: row.id,
            canonical_album_id: row.canonical_album_id,
            title: row.title,
            sort_title: row.sort_title,
            artist_name: row.artist_name,
            album_artist: row.album_artist,
            artist_names,
            disc_number: row.disc_number.max(1) as u32,
            track_number: row.track_number.max(1) as u32,
            duration_ms: row.duration_ms.max(0) as u64,
            isrc: row.isrc,
            musicbrainz_recording_id: row.musicbrainz_recording_id,
            genre: row.genre,
            composer: row.composer,
            sources,
        }))
    }

    pub async fn get_sources_for_canonical_track(
        pool: &SqlitePool,
        canonical_track_id: &str,
    ) -> Result<Vec<SourceReference>> {
        let rows: Vec<SourceReferenceRow> = sqlx::query_as(
            "SELECT id, provider_id, external_track_id, codec, sample_rate_hz, bit_depth, \
             channels, is_dsd, file_status, content_fingerprint, audio_byte_len \
             FROM track_sources \
             WHERE canonical_track_id = ? \
             ORDER BY sample_rate_hz DESC, bit_depth DESC, provider_id ASC",
        )
        .bind(canonical_track_id)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| SourceReference {
                source_id: r.id,
                provider: parse_provider_kind(&r.provider_id),
                external_id: r.external_track_id,
                codec: parse_audio_codec(&r.codec),
                sample_rate_hz: r.sample_rate_hz.max(0) as u32,
                bit_depth: if r.bit_depth > 0 {
                    Some(r.bit_depth.min(i64::from(u16::MAX)) as u16)
                } else {
                    None
                },
                bitrate_kbps: None,
                channels: Some(r.channels.clamp(1, i64::from(u8::MAX)) as u8),
                is_dsd: r.is_dsd != 0,
                file_status: FileStatus::from_str(&r.file_status).unwrap_or(FileStatus::Present),
                content_fingerprint: r.content_fingerprint,
                audio_byte_len: r.audio_byte_len.and_then(|v| u64::try_from(v).ok()),
            })
            .collect())
    }

    // -------------------------------------------------------------------------
    // 6. Version TOC Signature
    // -------------------------------------------------------------------------

    pub async fn update_album_version_toc(
        pool: &SqlitePool,
        version_id: &str,
        toc_signature: &str,
        disc_count: u32,
        track_count: u32,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE album_versions SET toc_signature = ?, disc_count = ?, track_count = ? WHERE id = ?",
        )
        .bind(toc_signature.trim())
        .bind(disc_count.max(1) as i64)
        .bind(track_count as i64)
        .bind(version_id.trim())
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn find_versions_by_toc(
        pool: &SqlitePool,
        toc_signature: &str,
    ) -> Result<Vec<AlbumVersion>> {
        let rows: Vec<AlbumVersionTocRow> = sqlx::query_as(
            "SELECT id, canonical_album_id, provider_id, external_album_id, codec, \
             sample_rate_hz, bit_depth, channels, is_dsd, edition_label \
             FROM album_versions WHERE toc_signature = ?",
        )
        .bind(toc_signature.trim())
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| AlbumVersion {
                id: r.id,
                canonical_album_id: r.canonical_album_id,
                provider: parse_provider_kind(&r.provider_id),
                external_album_id: r.external_album_id,
                format: AudioFormat {
                    codec: parse_audio_codec(&r.codec),
                    sample_rate_hz: r.sample_rate_hz as u32,
                    bit_depth: r.bit_depth as u8,
                    channels: r.channels as u8,
                    is_dsd: r.is_dsd == 1,
                },
                edition_label: r.edition_label,
            })
            .collect())
    }

    // -------------------------------------------------------------------------
    // 7. Sidecar Playlists (.m3u / .m3u8)
    // -------------------------------------------------------------------------

    pub async fn upsert_sidecar_playlist(
        pool: &SqlitePool,
        provider_id: &str,
        source_path: &str,
        name: &str,
        entries: &[SidecarPlaylistEntry],
    ) -> Result<SidecarPlaylist> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let track_count = entries.len() as i64;

        let res: Result<SidecarPlaylist> = async {
            let row: PlaylistRow = sqlx::query_as(
                "INSERT INTO playlists (id, provider_id, source_path, name, track_count, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(source_path) DO UPDATE SET \
                    provider_id = excluded.provider_id, \
                    name = excluded.name, \
                    track_count = excluded.track_count, \
                    updated_at = excluded.updated_at \
                 RETURNING id, provider_id, source_path, name, track_count, updated_at",
            )
            .bind(&id)
            .bind(provider_id.trim())
            .bind(source_path.trim())
            .bind(name.trim())
            .bind(track_count)
            .bind(&now)
            .fetch_one(tx.conn())
            .await?;

            sqlx::query("DELETE FROM playlist_items WHERE playlist_id = ?")
                .bind(&row.id)
                .execute(tx.conn())
                .await?;

            for (pos, entry) in entries.iter().enumerate() {
                sqlx::query(
                    "INSERT INTO playlist_items (playlist_id, position, raw_entry, resolved_track_source_id) \
                     VALUES (?, ?, ?, ?)",
                )
                .bind(&row.id)
                .bind(pos as i64)
                .bind(&entry.raw_entry)
                .bind(&entry.resolved_track_source_id)
                .execute(tx.conn())
                .await?;
            }

            Ok(row.into())
        }
        .await;

        match res {
            Ok(playlist) => {
                tx.commit().await?;
                Ok(playlist)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn list_sidecar_playlists(pool: &SqlitePool) -> Result<Vec<SidecarPlaylist>> {
        let rows: Vec<PlaylistRow> = sqlx::query_as(
            "SELECT id, provider_id, source_path, name, track_count, updated_at \
             FROM playlists ORDER BY name ASC",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }
}

// ============================================================================
// Minimal JSON Scalar Decoders for metadata_overrides.value_json
// ============================================================================

fn decode_json_opt_string(raw: &str) -> Option<Option<String>> {
    let trimmed = raw.trim();
    if trimmed == "null" {
        return Some(None);
    }
    decode_json_string(trimmed).map(Some)
}

fn decode_json_string(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed == "null" {
        return None;
    }
    if trimmed.len() >= 2 && trimmed.starts_with('"') && trimmed.ends_with('"') {
        unescape_json_str(&trimmed[1..trimmed.len() - 1])
    } else if !trimmed.is_empty() {
        Some(trimmed.to_string())
    } else {
        None
    }
}

fn decode_json_i64(raw: &str) -> Option<i64> {
    let trimmed = raw.trim();
    if let Ok(n) = trimmed.parse::<i64>() {
        return Some(n);
    }
    decode_json_string(trimmed).and_then(|s| s.trim().parse::<i64>().ok())
}

fn unescape_json_str(inner: &str) -> Option<String> {
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        match chars.next()? {
            '"' => out.push('"'),
            '\\' => out.push('\\'),
            '/' => out.push('/'),
            'b' => out.push('\u{0008}'),
            'f' => out.push('\u{000C}'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'u' => {
                let code = parse_hex4(&mut chars)?;
                if (0xD800..=0xDBFF).contains(&code) {
                    if chars.next() == Some('\\') && chars.next() == Some('u') {
                        let low = parse_hex4(&mut chars)?;
                        if (0xDC00..=0xDFFF).contains(&low) {
                            let combined = 0x10000
                                + (((u32::from(code) - 0xD800) << 10)
                                    | (u32::from(low) - 0xDC00));
                            if let Some(c) = char::from_u32(combined) {
                                out.push(c);
                            }
                        }
                    }
                } else if let Some(c) = char::from_u32(u32::from(code)) {
                    out.push(c);
                }
            }
            other => out.push(other),
        }
    }
    Some(out)
}

fn parse_hex4(chars: &mut std::str::Chars<'_>) -> Option<u16> {
    let mut val = 0u16;
    for _ in 0..4 {
        let d = chars.next()?.to_digit(16)? as u16;
        val = (val << 4) | d;
    }
    Some(val)
}
