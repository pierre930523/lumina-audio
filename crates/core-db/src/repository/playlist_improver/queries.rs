use sqlx::SqliteConnection;

use super::helpers::{AnalyzedTrack, DiskCheckMode, TrackJoinedRow, is_track_healthy};
use crate::error::Result;

#[derive(Debug, sqlx::FromRow)]
struct PlaylistItemJoinedRow {
    position: i64,
    raw_entry: String,
    resolved_track_source_id: Option<String>,
    track_id: Option<String>,
    version_id: Option<String>,
    canonical_album_id: Option<String>,
    canonical_track_id: Option<String>,
    external_track_id: Option<String>,
    title: Option<String>,
    artist_name: Option<String>,
    album_title: Option<String>,
    provider_id: Option<String>,
    codec: Option<String>,
    sample_rate_hz: Option<i64>,
    bit_depth: Option<i64>,
    is_dsd: Option<i32>,
    duration_ms: Option<i64>,
    quality_score: Option<f64>,
    file_status: Option<String>,
    isrc: Option<String>,
    disc_number: Option<i64>,
    track_number: Option<i64>,
    is_hidden: Option<i32>,
}

pub(crate) struct LoadedPlaylistItem {
    pub position: i64,
    pub raw_entry: String,
    pub resolved_track_source_id: Option<String>,
    pub track: Option<AnalyzedTrack>,
    pub is_healthy: bool,
}

impl PlaylistItemJoinedRow {
    fn into_loaded_item(self, mode: DiskCheckMode) -> LoadedPlaylistItem {
        let track = match (
            self.track_id,
            self.version_id,
            self.canonical_album_id,
            self.external_track_id,
            self.title,
            self.provider_id,
            self.codec,
            self.file_status,
        ) {
            (
                Some(track_id),
                Some(version_id),
                Some(canonical_album_id),
                Some(external_track_id),
                Some(title),
                Some(provider_id),
                Some(codec),
                Some(file_status),
            ) => Some(AnalyzedTrack::from_joined_row(TrackJoinedRow {
                track_id,
                version_id,
                canonical_album_id,
                canonical_track_id: self.canonical_track_id,
                external_track_id,
                title,
                artist_name: self.artist_name.unwrap_or_default(),
                album_title: self.album_title.unwrap_or_default(),
                provider_id,
                codec,
                sample_rate_hz: self.sample_rate_hz.unwrap_or(0),
                bit_depth: self.bit_depth.unwrap_or(0),
                is_dsd: self.is_dsd.unwrap_or(0),
                duration_ms: self.duration_ms.unwrap_or(0),
                quality_score: self.quality_score.unwrap_or(0.0),
                file_status,
                isrc: self.isrc,
                disc_number: self.disc_number.unwrap_or(1),
                track_number: self.track_number.unwrap_or(0),
                is_hidden: self.is_hidden.unwrap_or(0),
            })),
            _ => None,
        };
        let is_healthy = track.as_ref().is_some_and(|t| is_track_healthy(t, mode));
        LoadedPlaylistItem {
            position: self.position,
            raw_entry: self.raw_entry,
            resolved_track_source_id: self.resolved_track_source_id,
            track,
            is_healthy,
        }
    }
}

pub(crate) async fn load_playlist_items_conn(
    conn: &mut SqliteConnection,
    playlist_id: &str,
    mode: DiskCheckMode,
) -> Result<Vec<LoadedPlaylistItem>> {
    let rows: Vec<PlaylistItemJoinedRow> = sqlx::query_as(
        "SELECT pi.position, pi.raw_entry, pi.resolved_track_source_id, \
                ts.id AS track_id, ts.version_id, av.canonical_album_id, \
                ts.canonical_track_id, ts.external_track_id, ts.title, \
                COALESCE( \
                    NULLIF(TRIM(ts.artist_name), ''), \
                    NULLIF(TRIM(ts.album_artist), ''), \
                    NULLIF(TRIM(ca.album_artist), ''), \
                    NULLIF(TRIM(ar.name), ''), \
                    '' \
                ) AS artist_name, \
                COALESCE(ca.title, '') AS album_title, \
                ts.provider_id, ts.codec, ts.sample_rate_hz, ts.bit_depth, \
                CASE WHEN ts.is_dsd != 0 OR COALESCE(av.is_dsd, 0) != 0 THEN 1 ELSE 0 END AS is_dsd, \
                ts.duration_ms, av.quality_score, ts.file_status, ts.isrc, \
                ts.disc_number, ts.track_number, av.is_hidden \
         FROM playlist_items pi \
         LEFT JOIN track_sources ts ON ts.id = pi.resolved_track_source_id \
         LEFT JOIN album_versions av ON av.id = ts.version_id \
         LEFT JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
         LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
         WHERE pi.playlist_id = ? \
         ORDER BY pi.position ASC",
    )
    .bind(playlist_id)
    .fetch_all(&mut *conn)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| row.into_loaded_item(mode))
        .collect())
}

pub(crate) async fn load_healthy_library_tracks_conn(
    conn: &mut SqliteConnection,
    mode: DiskCheckMode,
) -> Result<Vec<AnalyzedTrack>> {
    let rows: Vec<TrackJoinedRow> = sqlx::query_as(
        "SELECT ts.id AS track_id, ts.version_id, av.canonical_album_id, \
                ts.canonical_track_id, ts.external_track_id, ts.title, \
                COALESCE( \
                    NULLIF(TRIM(ts.artist_name), ''), \
                    NULLIF(TRIM(ts.album_artist), ''), \
                    NULLIF(TRIM(ca.album_artist), ''), \
                    NULLIF(TRIM(ar.name), ''), \
                    '' \
                ) AS artist_name, \
                COALESCE(ca.title, '') AS album_title, \
                ts.provider_id, ts.codec, ts.sample_rate_hz, ts.bit_depth, \
                CASE WHEN ts.is_dsd != 0 OR av.is_dsd != 0 THEN 1 ELSE 0 END AS is_dsd, \
                ts.duration_ms, av.quality_score, ts.file_status, ts.isrc, \
                ts.disc_number, ts.track_number, av.is_hidden \
         FROM track_sources ts \
         JOIN album_versions av ON av.id = ts.version_id \
         JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
         LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
         WHERE ts.file_status = 'present'",
    )
    .fetch_all(&mut *conn)
    .await?;

    Ok(rows
        .into_iter()
        .map(AnalyzedTrack::from_joined_row)
        .filter(|t| is_track_healthy(t, mode))
        .collect())
}
