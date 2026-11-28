use chrono::Utc;
use core_types::{CanonicalAlbum, MetadataLayer, MetadataOverride, TrackSource};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};
use std::collections::HashMap;
use std::str::FromStr;

use super::IngestionRepository;
use super::json_scalars::{decode_json_i64, decode_json_opt_string, decode_json_string};
use super::models::MetadataOverrideRow;
use crate::error::Result;
use crate::repository::library::{Artist, LibraryRepository};
use crate::repository::tx::ImmediateTx;

impl IngestionRepository {
    /// Sets a metadata override while strictly enforcing layer precedence:
    /// `CloudEnrichment (0) < FileTag (1) < UserEdit (2)`.
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
                if !source_layer.can_override(existing_layer, fname) {
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

            LibraryRepository::sync_override_field_to_layer_tx(
                tx.conn(),
                et,
                eid,
                fname,
                Some(value_json),
                source_layer,
            )
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
        let mut tx = ImmediateTx::begin(pool).await?;
        let et = entity_type.trim();
        let eid = entity_id.trim();
        let fname = field_name.trim();

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

            let del = sqlx::query(
                "DELETE FROM metadata_overrides WHERE entity_type = ? AND entity_id = ? AND field_name = ?",
            )
            .bind(et)
            .bind(eid)
            .bind(fname)
            .execute(tx.conn())
            .await?;

            let layer = existing
                .and_then(|(s,)| MetadataLayer::from_str(&s).ok())
                .unwrap_or(MetadataLayer::UserEdit);
            LibraryRepository::sync_override_field_to_layer_tx(
                tx.conn(),
                et,
                eid,
                fname,
                None,
                layer,
            )
            .await?;

            Ok(del.rows_affected() > 0)
        }
        .await;

        match res {
            Ok(removed) => {
                tx.commit().await?;
                Ok(removed)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
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
}
