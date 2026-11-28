use chrono::Utc;
use core_types::CanonicalAlbum;
use sqlx::{SqliteConnection, SqlitePool};
use unicode_normalization::UnicodeNormalization;

use super::LibraryRepository;
use super::helpers::deterministic_artist_id;
use super::models::{Artist, ArtistRow};
use crate::error::Result;
use crate::repository::ingestion::IngestionRepository;
use crate::repository::tx::ImmediateTx;

impl LibraryRepository {
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
            "SELECT id, name, sort_name, musicbrainz_id, biography, image_path, preference FROM artists WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?;

        match row.map(Artist::from) {
            Some(mut artist) => {
                let ovs = IngestionRepository::get_overrides_for_entity(pool, "artist", &artist.id)
                    .await?;
                IngestionRepository::apply_artist_overrides(&mut artist, &ovs);
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
            "SELECT a.id, a.name, a.sort_name, a.musicbrainz_id, a.biography, a.image_path, a.preference \
             FROM artists a \
             WHERE a.name LIKE ? \
               AND ( \
                   EXISTS ( \
                       SELECT 1 FROM canonical_albums ca \
                       JOIN album_versions av ON av.canonical_album_id = ca.id \
                       JOIN track_sources ts ON ts.version_id = av.id \
                       WHERE ca.primary_artist_id = a.id AND ts.file_status = 'present' \
                   ) \
                   OR EXISTS ( \
                       SELECT 1 FROM track_artists ta \
                       JOIN track_sources ts ON ts.canonical_track_id = ta.canonical_track_id \
                       WHERE ta.artist_id = a.id AND ts.file_status = 'present' \
                   ) \
                   OR EXISTS ( \
                       SELECT 1 FROM album_credits ac \
                       JOIN album_versions av ON av.canonical_album_id = ac.canonical_album_id \
                       JOIN track_sources ts ON ts.version_id = av.id \
                       WHERE ac.artist_id = a.id AND ts.file_status = 'present' \
                   ) \
               ) \
             ORDER BY a.sort_name ASC",
        )
        .bind(pattern)
        .fetch_all(pool)
        .await?;

        let mut artists: Vec<Artist> = rows.into_iter().map(Artist::from).collect();
        IngestionRepository::apply_artist_overrides_batch(pool, &mut artists).await?;
        Ok(artists)
    }

    pub async fn list_artists(pool: &SqlitePool, limit: u32, offset: u32) -> Result<Vec<Artist>> {
        let rows: Vec<ArtistRow> = sqlx::query_as(
            "SELECT a.id, a.name, a.sort_name, a.musicbrainz_id, a.biography, a.image_path, a.preference \
             FROM artists a \
             WHERE EXISTS ( \
                   SELECT 1 FROM canonical_albums ca \
                   JOIN album_versions av ON av.canonical_album_id = ca.id \
                   JOIN track_sources ts ON ts.version_id = av.id \
                   WHERE ca.primary_artist_id = a.id AND ts.file_status = 'present' \
               ) \
               OR EXISTS ( \
                   SELECT 1 FROM track_artists ta \
                   JOIN track_sources ts ON ts.canonical_track_id = ta.canonical_track_id \
                   WHERE ta.artist_id = a.id AND ts.file_status = 'present' \
               ) \
               OR EXISTS ( \
                   SELECT 1 FROM album_credits ac \
                   JOIN album_versions av ON av.canonical_album_id = ac.canonical_album_id \
                   JOIN track_sources ts ON ts.version_id = av.id \
                   WHERE ac.artist_id = a.id AND ts.file_status = 'present' \
               ) \
             ORDER BY a.sort_name ASC, a.name ASC LIMIT ? OFFSET ?",
        )
        .bind(limit as i64)
        .bind(offset as i64)
        .fetch_all(pool)
        .await?;

        let mut artists: Vec<Artist> = rows.into_iter().map(Artist::from).collect();
        IngestionRepository::apply_artist_overrides_batch(pool, &mut artists).await?;
        Ok(artists)
    }

    pub async fn upsert_artist_by_mbid_or_name_tx(
        conn: &mut SqliteConnection,
        name: &str,
        musicbrainz_id: Option<&str>,
        biography: Option<&str>,
        image_path: Option<&str>,
    ) -> Result<Artist> {
        let trimmed_name: String = name.trim().nfc().collect();
        let det_id = deterministic_artist_id(&trimmed_name);
        let clean_mbid = musicbrainz_id.map(str::trim).filter(|s| !s.is_empty());
        let clean_bio = biography.map(str::trim).filter(|s| !s.is_empty());
        let clean_img = image_path.map(str::trim).filter(|s| !s.is_empty());

        let mut matched_by_mbid = false;
        let mut existing: Option<ArtistRow> = if let Some(mbid) = clean_mbid {
            let row: Option<ArtistRow> = sqlx::query_as(
                "SELECT id, name, sort_name, musicbrainz_id, biography, image_path, preference \
                 FROM artists WHERE musicbrainz_id = ? LIMIT 1",
            )
            .bind(mbid)
            .fetch_optional(&mut *conn)
            .await?;
            if row.is_some() {
                matched_by_mbid = true;
            }
            row
        } else {
            None
        };

        if existing.is_none() {
            existing = sqlx::query_as(
                "SELECT id, name, sort_name, musicbrainz_id, biography, image_path, preference \
                 FROM artists WHERE id = ? LIMIT 1",
            )
            .bind(&det_id)
            .fetch_optional(&mut *conn)
            .await?;
        }

        if existing.is_none() {
            existing = sqlx::query_as(
                "SELECT id, name, sort_name, musicbrainz_id, biography, image_path, preference \
                 FROM artists WHERE LOWER(name) = LOWER(?) LIMIT 1",
            )
            .bind(&trimmed_name)
            .fetch_optional(&mut *conn)
            .await?;
        }

        if let Some(found) = existing {
            let now = Utc::now().to_rfc3339();
            // Guard UNIQUE(musicbrainz_id): never overwrite with an MBID already owned by another artist row.
            let safe_mbid = if let Some(mbid) = clean_mbid {
                if found.musicbrainz_id.as_deref() == Some(mbid) {
                    Some(mbid.to_string())
                } else {
                    let owner: Option<(String,)> = sqlx::query_as(
                        "SELECT id FROM artists WHERE musicbrainz_id = ? AND id != ? LIMIT 1",
                    )
                    .bind(mbid)
                    .bind(&found.id)
                    .fetch_optional(&mut *conn)
                    .await?;
                    if owner.is_some() {
                        found.musicbrainz_id.clone()
                    } else {
                        Some(mbid.to_string())
                    }
                }
            } else {
                found.musicbrainz_id.clone()
            };
            let should_update_name = !trimmed_name.is_empty()
                && found.name != trimmed_name
                && (!matched_by_mbid
                    || found.name.nfc().collect::<String>().to_lowercase()
                        == trimmed_name.to_lowercase());
            let (updated_name, updated_sort_name) = if should_update_name {
                (
                    trimmed_name.clone(),
                    CanonicalAlbum::derive_sort_title(&trimmed_name),
                )
            } else {
                (found.name.clone(), found.sort_name.clone())
            };
            let updated_mbid = safe_mbid;
            let updated_bio = clean_bio.map(str::to_string).or(found.biography.clone());
            let updated_img = clean_img.map(str::to_string).or(found.image_path.clone());
            let mark_enriched = clean_mbid.is_some() || clean_bio.is_some() || clean_img.is_some();

            sqlx::query(
                "UPDATE artists SET \
                    name = ?, \
                    sort_name = ?, \
                    musicbrainz_id = ?, \
                    biography = ?, \
                    image_path = ?, \
                    enriched_at = CASE WHEN ? THEN ? ELSE enriched_at END \
                 WHERE id = ?",
            )
            .bind(&updated_name)
            .bind(&updated_sort_name)
            .bind(&updated_mbid)
            .bind(&updated_bio)
            .bind(&updated_img)
            .bind(mark_enriched)
            .bind(&now)
            .bind(&found.id)
            .execute(&mut *conn)
            .await?;

            Ok(Artist {
                id: found.id,
                name: updated_name,
                sort_name: updated_sort_name,
                musicbrainz_id: updated_mbid,
                biography: updated_bio,
                image_path: updated_img,
                preference: found.preference,
            })
        } else {
            let artist = Artist {
                id: det_id,
                name: trimmed_name.clone(),
                sort_name: CanonicalAlbum::derive_sort_title(&trimmed_name),
                musicbrainz_id: clean_mbid.map(str::to_string),
                biography: clean_bio.map(str::to_string),
                image_path: clean_img.map(str::to_string),
                preference: 0,
            };
            let enriched_at = if clean_mbid.is_some() || clean_bio.is_some() || clean_img.is_some()
            {
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
            .execute(&mut *conn)
            .await?;

            Ok(artist)
        }
    }

    pub async fn upsert_artist_by_mbid_or_name(
        pool: &SqlitePool,
        name: &str,
        musicbrainz_id: Option<&str>,
        biography: Option<&str>,
        image_path: Option<&str>,
    ) -> Result<Artist> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res = Self::upsert_artist_by_mbid_or_name_tx(
            tx.conn(),
            name,
            musicbrainz_id,
            biography,
            image_path,
        )
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
}
