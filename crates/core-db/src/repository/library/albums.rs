use chrono::Utc;
use core_types::{AlbumVersion, AudioFormat, CanonicalAlbum, MetadataPolicy};
use sqlx::{SqliteConnection, SqlitePool};
use std::str::FromStr;

use super::LibraryRepository;
use super::helpers::{normalize_match_key, parse_audio_codec, parse_provider_kind};
use super::models::{AlbumVersionRow, CanonicalAlbumRow};
use crate::error::Result;
use crate::repository::ingestion::IngestionRepository;
use crate::repository::tx::ImmediateTx;

impl LibraryRepository {
    pub async fn insert_canonical_album_tx(
        conn: &mut SqliteConnection,
        album: &CanonicalAlbum,
        primary_artist_id: Option<&str>,
    ) -> Result<CanonicalAlbum> {
        let created_at = Utc::now().to_rfc3339();
        let norm_title = normalize_match_key(&album.title);
        let artist_name_for_norm = if let Some(aid) = primary_artist_id {
            let row: Option<(String,)> = sqlx::query_as("SELECT name FROM artists WHERE id = ?")
                .bind(aid)
                .fetch_optional(&mut *conn)
                .await?;
            row.map(|(n,)| n)
                .unwrap_or_else(|| album.artist_name.clone())
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
        .execute(&mut *conn)
        .await?;

        for ver in &album.versions {
            Self::insert_album_version_tx(conn, ver).await?;
        }

        Ok(album.clone())
    }

    pub async fn insert_canonical_album(
        pool: &SqlitePool,
        album: &CanonicalAlbum,
        primary_artist_id: Option<&str>,
    ) -> Result<CanonicalAlbum> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::insert_canonical_album_tx(tx.conn(), album, primary_artist_id).await;
        match res {
            Ok(saved) => {
                tx.commit().await?;
                Ok(saved)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn update_canonical_album_metadata_tx(
        conn: &mut SqliteConnection,
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
        .execute(&mut *conn)
        .await?;

        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn update_canonical_album_core_tx(
        conn: &mut SqliteConnection,
        album_id: &str,
        title: &str,
        sort_title: &str,
        primary_artist_id: Option<&str>,
        album_artist: Option<&str>,
        release_year: Option<i32>,
        upc: Option<&str>,
        mb_rg_id: Option<&str>,
        cover_url: Option<&str>,
    ) -> Result<()> {
        let norm_title = normalize_match_key(title);
        let artist_name_for_norm = if let Some(aid) = primary_artist_id {
            let row: Option<(String,)> = sqlx::query_as("SELECT name FROM artists WHERE id = ?")
                .bind(aid)
                .fetch_optional(&mut *conn)
                .await?;
            row.map(|(n,)| n)
                .or_else(|| album_artist.map(str::to_string))
                .unwrap_or_default()
        } else {
            album_artist.map(str::to_string).unwrap_or_default()
        };
        let norm_artist = normalize_match_key(&artist_name_for_norm);
        let clean_upc = upc.map(str::trim).filter(|s| !s.is_empty());
        let clean_mb = mb_rg_id.map(str::trim).filter(|s| !s.is_empty());
        let clean_cover = cover_url.map(str::trim).filter(|s| !s.is_empty());

        let safe_mb = if let Some(mb) = clean_mb {
            let owner: Option<(String,)> = sqlx::query_as(
                "SELECT id FROM canonical_albums \
                 WHERE musicbrainz_release_group_id = ? AND id != ? LIMIT 1",
            )
            .bind(mb)
            .bind(album_id)
            .fetch_optional(&mut *conn)
            .await?;
            if owner.is_some() { None } else { Some(mb) }
        } else {
            None
        };

        sqlx::query(
            "UPDATE canonical_albums SET \
                title = ?, \
                sort_title = ?, \
                primary_artist_id = COALESCE(?, primary_artist_id), \
                album_artist = ?, \
                release_year = ?, \
                normalized_title = ?, \
                normalized_artist = COALESCE(NULLIF(?, ''), normalized_artist), \
                upc = COALESCE(?, upc), \
                musicbrainz_release_group_id = COALESCE(?, musicbrainz_release_group_id), \
                cover_url = COALESCE(?, cover_url), \
                merged_cover_path = COALESCE(?, merged_cover_path) \
             WHERE id = ?",
        )
        .bind(title)
        .bind(sort_title)
        .bind(primary_artist_id)
        .bind(album_artist)
        .bind(release_year)
        .bind(&norm_title)
        .bind(&norm_artist)
        .bind(clean_upc)
        .bind(safe_mb)
        .bind(clean_cover)
        .bind(clean_cover)
        .bind(album_id)
        .execute(&mut *conn)
        .await?;

        Ok(())
    }

    pub async fn update_canonical_album_metadata(
        pool: &SqlitePool,
        album_id: &str,
        upc: Option<&str>,
        mb_rg_id: Option<&str>,
        editorial_bio: Option<&str>,
        cover_url: Option<&str>,
    ) -> Result<()> {
        let mut conn = pool.acquire().await?;
        Self::update_canonical_album_metadata_tx(
            &mut conn,
            album_id,
            upc,
            mb_rg_id,
            editorial_bio,
            cover_url,
        )
        .await
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

    pub async fn insert_album_version_tx(
        conn: &mut SqliteConnection,
        version: &AlbumVersion,
    ) -> Result<String> {
        let provider_str = version.provider.as_str();
        let codec_str = version.format.codec.as_str();

        let (persisted_id,): (String,) = sqlx::query_as(
            "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, \
             codec, sample_rate_hz, bit_depth, channels, is_dsd, edition_label) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(provider_id, external_album_id) DO UPDATE SET \
                canonical_album_id = CASE \
                    WHEN album_versions.manual_group_id IS NOT NULL \
                         AND EXISTS (SELECT 1 FROM canonical_albums ca WHERE ca.id = album_versions.manual_group_id) \
                    THEN album_versions.manual_group_id \
                    ELSE excluded.canonical_album_id \
                END, \
                codec = excluded.codec, \
                sample_rate_hz = excluded.sample_rate_hz, \
                bit_depth = excluded.bit_depth, \
                channels = excluded.channels, \
                is_dsd = excluded.is_dsd, \
                edition_label = excluded.edition_label \
             RETURNING id",
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
        .fetch_one(&mut *conn)
        .await?;

        Ok(persisted_id)
    }

    pub async fn insert_album_version(
        pool: &SqlitePool,
        version: &AlbumVersion,
    ) -> Result<AlbumVersion> {
        let mut conn = pool.acquire().await?;
        let _ = Self::insert_album_version_tx(&mut conn, version).await?;
        Ok(version.clone())
    }

    fn row_to_canonical_album(
        row: CanonicalAlbumRow,
        versions: Vec<AlbumVersion>,
    ) -> CanonicalAlbum {
        CanonicalAlbum {
            id: row.id,
            title: row.title,
            sort_title: row.sort_title,
            artist_name: row.artist_name.unwrap_or_default(),
            album_artist: row.album_artist,
            release_year: row.release_year,
            musicbrainz_release_group_id: row.musicbrainz_release_group_id,
            cover_url: row.cover_url,
            versions,
            meta_policy: MetadataPolicy::from_str(&row.meta_policy)
                .unwrap_or(MetadataPolicy::Inherit),
            has_user_edits: row.has_user_edits != 0,
            primary_version_id: row.primary_version_id,
            is_primary_locked: row.is_primary_locked != 0,
            preference: row.preference,
        }
    }

    pub(super) async fn hydrate_canonical_albums(
        pool: &SqlitePool,
        rows: Vec<CanonicalAlbumRow>,
    ) -> Result<Vec<CanonicalAlbum>> {
        let mut albums = Vec::with_capacity(rows.len());
        for row in rows {
            let versions = Self::list_versions_for_album(pool, &row.id).await?;
            albums.push(Self::row_to_canonical_album(row, versions));
        }
        IngestionRepository::apply_album_overrides_batch(pool, &mut albums).await?;
        Ok(albums)
    }

    pub(super) async fn hydrate_canonical_albums_raw(
        pool: &SqlitePool,
        rows: Vec<CanonicalAlbumRow>,
    ) -> Result<Vec<CanonicalAlbum>> {
        let mut albums = Vec::with_capacity(rows.len());
        for row in rows {
            let versions = Self::list_all_versions_for_album_raw(pool, &row.id).await?;
            albums.push(Self::row_to_canonical_album(row, versions));
        }
        IngestionRepository::apply_album_overrides_batch(pool, &mut albums).await?;
        Ok(albums)
    }

    fn map_album_version_rows(rows: Vec<AlbumVersionRow>) -> Vec<AlbumVersion> {
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
                is_primary: row.is_primary != 0,
                is_hidden: row.is_hidden != 0,
                quality_score: row.quality_score,
                manual_group_id: row.manual_group_id,
                disc_count: row.disc_count.max(1) as u32,
                track_count: row.track_count.max(0) as u32,
                has_manual_tracks: row.has_manual_tracks != 0,
            });
        }
        versions
    }

    pub(super) async fn list_all_versions_for_album_raw(
        pool: &SqlitePool,
        canonical_album_id: &str,
    ) -> Result<Vec<AlbumVersion>> {
        let rows: Vec<AlbumVersionRow> = sqlx::query_as(
            "SELECT av.id, av.canonical_album_id, av.provider_id, av.external_album_id, av.codec, \
             av.sample_rate_hz, av.bit_depth, av.channels, av.is_dsd, av.edition_label, \
             CASE WHEN ca.primary_version_id = av.id THEN 1 ELSE 0 END AS is_primary, \
             av.is_hidden, av.quality_score, av.manual_group_id, av.disc_count, \
             COALESCE(av.track_count, (SELECT COUNT(*) FROM track_sources ts WHERE ts.version_id = av.id AND ts.file_status = 'present')) AS track_count, \
             CASE WHEN EXISTS (SELECT 1 FROM track_sources ts WHERE ts.version_id = av.id AND ts.manual_version_id IS NOT NULL) THEN 1 ELSE 0 END AS has_manual_tracks \
             FROM album_versions av \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE av.canonical_album_id = ? \
             ORDER BY is_primary DESC, av.is_hidden ASC, av.quality_score DESC, av.sample_rate_hz DESC, av.bit_depth DESC, av.id ASC",
        )
        .bind(canonical_album_id)
        .fetch_all(pool)
        .await?;

        Ok(Self::map_album_version_rows(rows))
    }

    /// Lists versions for an album that contain at least one `file_status = 'present'` track,
    /// ordered primary-first, visible-first, then highest quality score.
    pub async fn list_versions_for_album(
        pool: &SqlitePool,
        canonical_album_id: &str,
    ) -> Result<Vec<AlbumVersion>> {
        let rows: Vec<AlbumVersionRow> = sqlx::query_as(
            "SELECT av.id, av.canonical_album_id, av.provider_id, av.external_album_id, av.codec, \
             av.sample_rate_hz, av.bit_depth, av.channels, av.is_dsd, av.edition_label, \
             CASE WHEN ca.primary_version_id = av.id THEN 1 ELSE 0 END AS is_primary, \
             av.is_hidden, av.quality_score, av.manual_group_id, av.disc_count, \
             (SELECT COUNT(*) FROM track_sources ts WHERE ts.version_id = av.id AND ts.file_status = 'present') AS track_count, \
             CASE WHEN EXISTS (SELECT 1 FROM track_sources ts WHERE ts.version_id = av.id AND ts.manual_version_id IS NOT NULL) THEN 1 ELSE 0 END AS has_manual_tracks \
             FROM album_versions av \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE av.canonical_album_id = ? \
               AND EXISTS ( \
                   SELECT 1 FROM track_sources ts \
                   WHERE ts.version_id = av.id AND ts.file_status = 'present' \
               ) \
             ORDER BY is_primary DESC, av.is_hidden ASC, av.quality_score DESC, av.sample_rate_hz DESC, av.bit_depth DESC, av.id ASC",
        )
        .bind(canonical_album_id)
        .fetch_all(pool)
        .await?;

        Ok(Self::map_album_version_rows(rows))
    }
}
