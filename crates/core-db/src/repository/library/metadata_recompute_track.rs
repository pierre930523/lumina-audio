use chrono::Utc;
use core_types::{
    AlbumMetadataLayer, CanonicalAlbum, MetadataPolicy, TrackMetadataLayer,
    resolve_effective_track_metadata,
};
use sqlx::SqliteConnection;
use std::str::FromStr;
use uuid::Uuid;

use super::LibraryRepository;
use super::helpers::normalize_match_key;
use crate::error::Result;
use crate::repository::ingestion::IngestionRepository;
use crate::search::{
    delete_fts_entry_conn, sync_album_fts_conn, sync_single_album_fts_visibility_conn,
    sync_track_fts_conn,
};

#[derive(Debug, sqlx::FromRow)]
struct TrackLayerRow {
    version_id: String,
    provider_id: String,
    title: String,
    artist_name: Option<String>,
    album_artist: Option<String>,
    disc_number: i64,
    track_number: i64,
    sample_rate_hz: i64,
    bit_depth: i64,
    channels: i64,
    is_dsd: i32,
    codec: String,
    isrc: Option<String>,
    genre: Option<String>,
    composer: Option<String>,
    release_year: Option<i32>,
    embedded_lyrics: Option<String>,
    is_hidden: i32,
    canonical_track_id: Option<String>,
    file_status: String,
    manual_version_id: Option<String>,
    manual_disc_number: Option<i64>,
    file_meta_json: Option<String>,
    cloud_meta_json: Option<String>,
    user_edits_json: Option<String>,
    meta_policy: String,
    canonical_album_id: String,
    current_album_title: String,
    current_album_file_meta_json: Option<String>,
    current_album_cloud_meta_json: Option<String>,
}

impl LibraryRepository {
    /// Recomputes materialized display columns on `track_sources`, syncs `canonical_tracks` +
    /// `track_artists`, reassigns target `canonical_albums`/`album_versions` if `album_title`
    /// changed, and syncs `search_fts`.
    pub async fn recompute_track_effective_tx(
        conn: &mut SqliteConnection,
        track_id: &str,
        default_policy: MetadataPolicy,
    ) -> Result<bool> {
        let row: Option<TrackLayerRow> = sqlx::query_as(
            "SELECT ts.version_id, ts.provider_id, ts.title, ts.artist_name, ts.album_artist, \
                    ts.disc_number, ts.track_number, ts.sample_rate_hz, ts.bit_depth, \
                    ts.channels, ts.is_dsd, ts.codec, ts.isrc, ts.genre, ts.composer, \
                    ts.release_year, ts.embedded_lyrics, ts.is_hidden, \
                    ts.canonical_track_id, ts.file_status, \
                    ts.manual_version_id, ts.manual_disc_number, \
                    ts.file_meta_json, ts.cloud_meta_json, ts.user_edits_json, ts.meta_policy, \
                    av.canonical_album_id, ca.title AS current_album_title, \
                    ca.file_meta_json AS current_album_file_meta_json, \
                    ca.cloud_meta_json AS current_album_cloud_meta_json \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE ts.id = ?",
        )
        .bind(track_id)
        .fetch_optional(&mut *conn)
        .await?;

        let Some(row) = row else {
            return Ok(false);
        };

        let file_meta = match TrackMetadataLayer::from_json_opt(row.file_meta_json.as_deref()) {
            Some(layer) => Some(layer),
            None if row.file_meta_json.is_none() => Some(TrackMetadataLayer {
                title: Some(row.title.clone()),
                artist_name: row.artist_name.clone(),
                album_artist: row.album_artist.clone(),
                album_title: Some(row.current_album_title.clone()),
                disc_number: u16::try_from(row.disc_number).ok().filter(|&n| n > 0),
                track_number: u16::try_from(row.track_number).ok().filter(|&n| n > 0),
                release_year: row.release_year,
                genre: row.genre.clone(),
                composer: row.composer.clone(),
                isrc: row.isrc.clone(),
                lyrics: row.embedded_lyrics.clone(),
            }),
            None => None,
        };
        let cloud_meta = TrackMetadataLayer::from_json_opt(row.cloud_meta_json.as_deref());
        let user_edits = TrackMetadataLayer::from_json_opt(row.user_edits_json.as_deref());

        let policy = MetadataPolicy::from_str(&row.meta_policy).unwrap_or(MetadataPolicy::Inherit);
        let eff_policy = policy.resolve_effective(default_policy);
        let resolved = resolve_effective_track_metadata(
            file_meta.as_ref(),
            cloud_meta.as_ref(),
            user_edits.as_ref(),
            eff_policy,
        );

        let eff_title = resolved.title.unwrap_or_else(|| row.title.clone());
        let eff_artist_name = resolved.artist_name;
        let eff_album_artist = resolved.album_artist;
        let eff_disc = user_edits
            .as_ref()
            .and_then(|u| u.disc_number)
            .filter(|&d| d > 0)
            .map(i64::from)
            .or_else(|| row.manual_disc_number.filter(|&d| d > 0))
            .or_else(|| resolved.disc_number.map(i64::from))
            .unwrap_or(row.disc_number.max(1));
        let eff_track = resolved
            .track_number
            .map(i64::from)
            .unwrap_or(row.track_number.max(1));

        let mut target_version_id = row.version_id.clone();
        let mut target_album_id = row.canonical_album_id.clone();
        let mut target_album_title = row.current_album_title.clone();

        if row.manual_version_id.is_none()
            && let Some(ref new_album_title) = resolved.album_title
            && new_album_title.trim() != row.current_album_title.trim()
        {
            let explicit_track_album_edit = user_edits
                .as_ref()
                .and_then(|u| u.album_title.as_deref())
                .map(str::trim)
                .is_some_and(|s| !s.is_empty());
            let matches_parent_layer_title = !explicit_track_album_edit
                && [
                    AlbumMetadataLayer::from_json_opt(row.current_album_file_meta_json.as_deref())
                        .and_then(|l| l.title),
                    AlbumMetadataLayer::from_json_opt(row.current_album_cloud_meta_json.as_deref())
                        .and_then(|l| l.title),
                ]
                .into_iter()
                .flatten()
                .any(|parent_title| parent_title.trim() == new_album_title.trim());

            if !matches_parent_layer_title {
                let album_artist_for_target = eff_album_artist
                    .as_deref()
                    .or(eff_artist_name.as_deref())
                    .unwrap_or("Unknown Artist");
                let (new_aid, new_vid) = resolve_or_create_target_album_version_tx(
                    conn,
                    new_album_title,
                    album_artist_for_target,
                    &row,
                )
                .await?;
                target_album_id = new_aid;
                target_version_id = new_vid;
                target_album_title = new_album_title.clone();
            }
        }

        sqlx::query(
            "UPDATE track_sources SET \
                version_id = ?, \
                title = ?, \
                artist_name = ?, \
                album_artist = ?, \
                disc_number = ?, \
                track_number = ?, \
                release_year = ?, \
                genre = ?, \
                composer = ?, \
                isrc = ?, \
                embedded_lyrics = ? \
             WHERE id = ?",
        )
        .bind(&target_version_id)
        .bind(&eff_title)
        .bind(&eff_artist_name)
        .bind(&eff_album_artist)
        .bind(eff_disc)
        .bind(eff_track)
        .bind(resolved.release_year)
        .bind(&resolved.genre)
        .bind(&resolved.composer)
        .bind(&resolved.isrc)
        .bind(&resolved.lyrics)
        .bind(track_id)
        .execute(&mut *conn)
        .await?;

        if let Some(ref ct_id) = row.canonical_track_id {
            let now = Utc::now().to_rfc3339();
            let primary_artist = eff_artist_name
                .as_deref()
                .or(eff_album_artist.as_deref())
                .unwrap_or("Unknown Artist");
            let sort_title = CanonicalAlbum::derive_sort_title(&eff_title);
            sqlx::query(
                "UPDATE canonical_tracks SET \
                    canonical_album_id = ?, \
                    title = ?, \
                    sort_title = ?, \
                    artist_name = ?, \
                    album_artist = ?, \
                    disc_number = ?, \
                    track_number = ?, \
                    genre = ?, \
                    composer = ?, \
                    isrc = ?, \
                    updated_at = ? \
                 WHERE id = ?",
            )
            .bind(&target_album_id)
            .bind(&eff_title)
            .bind(&sort_title)
            .bind(primary_artist)
            .bind(&eff_album_artist)
            .bind(eff_disc)
            .bind(eff_track)
            .bind(&resolved.genre)
            .bind(&resolved.composer)
            .bind(&resolved.isrc)
            .bind(&now)
            .bind(ct_id)
            .execute(&mut *conn)
            .await?;

            if let Some(ref aname) = eff_artist_name {
                let _ = IngestionRepository::link_track_artists_tx(
                    conn,
                    ct_id,
                    std::slice::from_ref(aname),
                    "performer",
                )
                .await?;
            }
        }

        if row.file_status == "present" && row.is_hidden == 0 {
            sync_track_fts_conn(
                conn,
                track_id,
                &eff_title,
                eff_artist_name.as_deref(),
                Some(&target_album_title),
            )
            .await?;
            if target_album_id != row.canonical_album_id {
                sync_album_fts_conn(
                    conn,
                    &target_album_id,
                    &target_album_title,
                    eff_album_artist.as_deref().or(eff_artist_name.as_deref()),
                    None,
                )
                .await?;
            }
        } else {
            delete_fts_entry_conn(conn, "track", track_id).await?;
        }
        sync_single_album_fts_visibility_conn(conn, &row.canonical_album_id).await?;

        Ok(true)
    }
}

async fn resolve_or_create_target_album_version_tx(
    conn: &mut SqliteConnection,
    album_title: &str,
    album_artist: &str,
    track: &TrackLayerRow,
) -> Result<(String, String)> {
    let artist =
        LibraryRepository::upsert_artist_by_mbid_or_name_tx(conn, album_artist, None, None, None)
            .await?;
    let norm_title = normalize_match_key(album_title);
    let norm_artist = normalize_match_key(&artist.name);

    let existing_album: Option<(String,)> = sqlx::query_as(
        "SELECT id FROM canonical_albums \
         WHERE normalized_title = ? AND normalized_artist = ? \
         ORDER BY created_at ASC LIMIT 1",
    )
    .bind(&norm_title)
    .bind(&norm_artist)
    .fetch_optional(&mut *conn)
    .await?;

    let album_id = if let Some((id,)) = existing_album {
        id
    } else {
        let new_id = Uuid::new_v4().to_string();
        let sort_title = CanonicalAlbum::derive_sort_title(album_title);
        let now = Utc::now().to_rfc3339();
        let file_meta = AlbumMetadataLayer {
            title: Some(album_title.to_string()),
            sort_title: Some(sort_title.clone()),
            album_artist: Some(artist.name.clone()),
            ..Default::default()
        };
        let file_meta_json = file_meta.to_json_opt();

        sqlx::query(
            "INSERT INTO canonical_albums (id, title, sort_title, primary_artist_id, album_artist, \
             normalized_title, normalized_artist, created_at, file_meta_json) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&new_id)
        .bind(album_title)
        .bind(&sort_title)
        .bind(&artist.id)
        .bind(&artist.name)
        .bind(&norm_title)
        .bind(&norm_artist)
        .bind(&now)
        .bind(&file_meta_json)
        .execute(&mut *conn)
        .await?;
        new_id
    };

    let existing_ver: Option<(String,)> = sqlx::query_as(
        "SELECT id FROM album_versions \
         WHERE canonical_album_id = ? AND provider_id = ? AND codec = ? \
           AND sample_rate_hz = ? AND bit_depth = ? AND channels = ? AND is_dsd = ? \
         LIMIT 1",
    )
    .bind(&album_id)
    .bind(&track.provider_id)
    .bind(&track.codec)
    .bind(track.sample_rate_hz)
    .bind(track.bit_depth)
    .bind(track.channels)
    .bind(track.is_dsd)
    .fetch_optional(&mut *conn)
    .await?;

    if let Some((vid,)) = existing_ver {
        return Ok((album_id, vid));
    }

    let ext_album_id = format!(
        "meta:{}:{}:{}:{}:{}:{}:{}",
        album_id,
        track.provider_id,
        track.codec,
        track.sample_rate_hz,
        track.bit_depth,
        track.channels,
        track.is_dsd
    );
    let new_ver_id = Uuid::new_v4().to_string();
    let (persisted_ver_id,): (String,) = sqlx::query_as(
        "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, \
         codec, sample_rate_hz, bit_depth, channels, is_dsd) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) \
         ON CONFLICT(provider_id, external_album_id) DO UPDATE SET \
            canonical_album_id = excluded.canonical_album_id \
         RETURNING id",
    )
    .bind(&new_ver_id)
    .bind(&album_id)
    .bind(&track.provider_id)
    .bind(&ext_album_id)
    .bind(&track.codec)
    .bind(track.sample_rate_hz)
    .bind(track.bit_depth)
    .bind(track.channels)
    .bind(track.is_dsd)
    .fetch_one(&mut *conn)
    .await?;

    Ok((album_id, persisted_ver_id))
}
