use core_types::{
    AlbumMetadataLayer, CanonicalAlbum, MetadataLayer, MetadataPolicy,
    resolve_effective_album_metadata,
};
use serde_json::{Map, Value};
use sqlx::SqliteConnection;
use std::str::FromStr;

use super::LibraryRepository;
use super::helpers::normalize_match_key;
use crate::error::Result;
use crate::search::{delete_fts_entry_conn, sync_album_fts_conn, sync_artist_fts_conn};

#[derive(Debug, sqlx::FromRow)]
struct AlbumLayerRow {
    title: String,
    sort_title: String,
    primary_artist_id: Option<String>,
    primary_artist_name: Option<String>,
    album_artist: Option<String>,
    release_year: Option<i32>,
    upc: Option<String>,
    musicbrainz_release_group_id: Option<String>,
    editorial_bio: Option<String>,
    cover_url: Option<String>,
    merged_cover_path: Option<String>,
    file_meta_json: Option<String>,
    cloud_meta_json: Option<String>,
    user_edits_json: Option<String>,
    meta_policy: String,
}

impl LibraryRepository {
    /// Recomputes materialized display columns, `primary_artist_id`, `normalized_*`, and
    /// `search_fts` for a `canonical_albums` row from its 3 JSON layers + `meta_policy`.
    pub async fn recompute_album_effective_tx(
        conn: &mut SqliteConnection,
        album_id: &str,
        default_policy: MetadataPolicy,
    ) -> Result<bool> {
        let row: Option<AlbumLayerRow> = sqlx::query_as(
            "SELECT ca.title, ca.sort_title, ca.primary_artist_id, \
                    a.name AS primary_artist_name, ca.album_artist, ca.release_year, \
                    ca.upc, ca.musicbrainz_release_group_id, ca.editorial_bio, \
                    ca.cover_url, ca.merged_cover_path, \
                    ca.file_meta_json, ca.cloud_meta_json, ca.user_edits_json, ca.meta_policy \
             FROM canonical_albums ca \
             LEFT JOIN artists a ON a.id = ca.primary_artist_id \
             WHERE ca.id = ?",
        )
        .bind(album_id)
        .fetch_optional(&mut *conn)
        .await?;

        let Some(row) = row else {
            return Ok(false);
        };

        let file_meta = match AlbumMetadataLayer::from_json_opt(row.file_meta_json.as_deref()) {
            Some(layer) => Some(layer),
            None if row.file_meta_json.is_none() => Some(AlbumMetadataLayer {
                title: Some(row.title.clone()),
                sort_title: Some(row.sort_title.clone()),
                album_artist: row
                    .album_artist
                    .clone()
                    .or_else(|| row.primary_artist_name.clone()),
                release_year: row.release_year,
                upc: row.upc.clone(),
                musicbrainz_release_group_id: row.musicbrainz_release_group_id.clone(),
                editorial_bio: row.editorial_bio.clone(),
                cover_url: row.cover_url.clone(),
                merged_cover_path: row.merged_cover_path.clone(),
            }),
            None => None,
        };
        let cloud_meta = AlbumMetadataLayer::from_json_opt(row.cloud_meta_json.as_deref());
        let user_edits = AlbumMetadataLayer::from_json_opt(row.user_edits_json.as_deref());

        let policy = MetadataPolicy::from_str(&row.meta_policy).unwrap_or(MetadataPolicy::Inherit);
        let eff_policy = policy.resolve_effective(default_policy);
        let resolved = resolve_effective_album_metadata(
            file_meta.as_ref(),
            cloud_meta.as_ref(),
            user_edits.as_ref(),
            eff_policy,
        );

        let eff_title = resolved.title.unwrap_or_else(|| row.title.clone());
        let eff_sort_title = resolved
            .sort_title
            .unwrap_or_else(|| CanonicalAlbum::derive_sort_title(&eff_title));
        let eff_album_artist = resolved.album_artist;

        let (eff_primary_artist_id, eff_artist_name) = if let Some(ref artist_name) =
            eff_album_artist
        {
            let artist =
                Self::upsert_artist_by_mbid_or_name_tx(conn, artist_name, None, None, None).await?;
            (Some(artist.id), Some(artist.name))
        } else {
            (
                row.primary_artist_id.clone(),
                row.primary_artist_name.clone(),
            )
        };

        let safe_mb_rg = if let Some(ref mb) = resolved.musicbrainz_release_group_id {
            let owner: Option<(String,)> = sqlx::query_as(
                "SELECT id FROM canonical_albums \
                 WHERE musicbrainz_release_group_id = ? AND id != ? LIMIT 1",
            )
            .bind(mb)
            .bind(album_id)
            .fetch_optional(&mut *conn)
            .await?;
            if owner.is_some() {
                None
            } else {
                Some(mb.clone())
            }
        } else {
            None
        };

        let eff_cover = resolved.cover_url.or(row
            .cover_url
            .filter(|_| file_meta.is_none() && cloud_meta.is_none() && user_edits.is_none()));
        let eff_merged_cover = resolved.merged_cover_path.or_else(|| eff_cover.clone());
        let norm_title = normalize_match_key(&eff_title);
        let norm_artist = normalize_match_key(eff_artist_name.as_deref().unwrap_or(""));

        sqlx::query(
            "UPDATE canonical_albums SET \
                title = ?, \
                sort_title = ?, \
                primary_artist_id = ?, \
                album_artist = ?, \
                release_year = ?, \
                upc = ?, \
                musicbrainz_release_group_id = ?, \
                editorial_bio = ?, \
                cover_url = ?, \
                merged_cover_path = ?, \
                normalized_title = ?, \
                normalized_artist = ? \
             WHERE id = ?",
        )
        .bind(&eff_title)
        .bind(&eff_sort_title)
        .bind(&eff_primary_artist_id)
        .bind(&eff_album_artist)
        .bind(resolved.release_year)
        .bind(&resolved.upc)
        .bind(&safe_mb_rg)
        .bind(&resolved.editorial_bio)
        .bind(&eff_cover)
        .bind(&eff_merged_cover)
        .bind(&norm_title)
        .bind(&norm_artist)
        .bind(album_id)
        .execute(&mut *conn)
        .await?;

        let has_present: Option<(i32,)> = sqlx::query_as(
            "SELECT 1 FROM album_versions av \
             JOIN track_sources ts ON ts.version_id = av.id \
             WHERE av.canonical_album_id = ? \
               AND av.is_hidden = 0 \
               AND ts.file_status = 'present' LIMIT 1",
        )
        .bind(album_id)
        .fetch_optional(&mut *conn)
        .await?;

        if has_present.is_some() {
            sync_album_fts_conn(
                conn,
                album_id,
                &eff_title,
                eff_artist_name.as_deref(),
                resolved.release_year,
            )
            .await?;
            if let (Some(aid), Some(aname)) = (&eff_primary_artist_id, &eff_artist_name) {
                let bio: Option<(Option<String>,)> =
                    sqlx::query_as("SELECT biography FROM artists WHERE id = ?")
                        .bind(aid)
                        .fetch_optional(&mut *conn)
                        .await?;
                sync_artist_fts_conn(conn, aid, aname, bio.and_then(|(b,)| b).as_deref()).await?;
            }
        } else {
            delete_fts_entry_conn(conn, "album", album_id).await?;
        }

        Ok(true)
    }

    pub(crate) async fn sync_override_field_to_layer_tx(
        conn: &mut SqliteConnection,
        entity_type: &str,
        entity_id: &str,
        field_name: &str,
        value_json: Option<&str>,
        source_layer: MetadataLayer,
    ) -> Result<()> {
        let et = entity_type.trim();
        let eid = entity_id.trim();
        if et != "album" && et != "track" {
            return Ok(());
        }

        let mapped_field = if et == "album" && field_name == "artist_name" {
            "album_artist"
        } else {
            field_name
        };

        let col = match source_layer {
            MetadataLayer::UserEdit => "user_edits_json",
            MetadataLayer::CloudEnrichment => "cloud_meta_json",
            MetadataLayer::FileTag => "file_meta_json",
        };
        let table = if et == "album" {
            "canonical_albums"
        } else {
            "track_sources"
        };

        let select_sql = format!("SELECT {col} FROM {table} WHERE id = ?");
        let existing: Option<(Option<String>,)> = sqlx::query_as(&select_sql)
            .bind(eid)
            .fetch_optional(&mut *conn)
            .await?;
        let Some((current_raw,)) = existing else {
            return Ok(());
        };

        let mut map: Map<String, Value> = current_raw
            .as_deref()
            .and_then(|s| serde_json::from_str::<Value>(s).ok())
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();

        match value_json {
            Some(raw) => {
                let parsed = serde_json::from_str::<Value>(raw)
                    .unwrap_or_else(|_| Value::String(raw.to_string()));
                if parsed.is_null() {
                    map.remove(mapped_field);
                } else {
                    map.insert(mapped_field.to_string(), parsed);
                }
            }
            None => {
                map.remove(mapped_field);
            }
        }

        let next_json = if map.is_empty() {
            None
        } else {
            Some(Value::Object(map).to_string())
        };
        let update_sql = format!("UPDATE {table} SET {col} = ? WHERE id = ?");
        sqlx::query(&update_sql)
            .bind(&next_json)
            .bind(eid)
            .execute(&mut *conn)
            .await?;

        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
        if et == "album" {
            Self::recompute_album_effective_tx(conn, eid, default_policy).await?;
        } else {
            Self::recompute_track_effective_tx(conn, eid, default_policy).await?;
        }
        Ok(())
    }
}
