use core_types::{
    AlbumCreditDetail, AlbumDetail, AlbumVersionDetail, ArtistDetail, CanonicalAlbum,
};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};
use std::collections::HashSet;

use super::LibraryRepository;
use super::helpers::normalize_match_key;
use super::models::CanonicalAlbumRow;
use crate::error::Result;

impl LibraryRepository {
    pub async fn find_canonical_album_by_id(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<CanonicalAlbum>> {
        let row: Option<CanonicalAlbumRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ca.sort_title, COALESCE(ar.name, '') AS artist_name, ca.album_artist, \
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
             ca.meta_policy, \
             CASE WHEN ca.user_edits_json IS NOT NULL AND TRIM(ca.user_edits_json) NOT IN ('', '{}', 'null') THEN 1 ELSE 0 END AS has_user_edits, \
             ca.primary_version_id, ca.is_primary_locked, ca.preference \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => {
                let mut albums = Self::hydrate_canonical_albums_raw(pool, vec![r]).await?;
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
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
             ca.meta_policy, \
             CASE WHEN ca.user_edits_json IS NOT NULL AND TRIM(ca.user_edits_json) NOT IN ('', '{}', 'null') THEN 1 ELSE 0 END AS has_user_edits, \
             ca.primary_version_id, ca.is_primary_locked, ca.preference \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.primary_artist_id = ? \
               AND EXISTS ( \
                   SELECT 1 FROM album_versions av \
                   JOIN track_sources ts ON ts.version_id = av.id \
                   WHERE av.canonical_album_id = ca.id AND ts.file_status = 'present' \
               ) \
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
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
             ca.meta_policy, \
             CASE WHEN ca.user_edits_json IS NOT NULL AND TRIM(ca.user_edits_json) NOT IN ('', '{}', 'null') THEN 1 ELSE 0 END AS has_user_edits, \
             ca.primary_version_id, ca.is_primary_locked, ca.preference \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE EXISTS ( \
                 SELECT 1 FROM album_versions av \
                 JOIN track_sources ts ON ts.version_id = av.id \
                 WHERE av.canonical_album_id = ca.id AND ts.file_status = 'present' \
             ) \
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
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
             ca.meta_policy, \
             CASE WHEN ca.user_edits_json IS NOT NULL AND TRIM(ca.user_edits_json) NOT IN ('', '{}', 'null') THEN 1 ELSE 0 END AS has_user_edits, \
             ca.primary_version_id, ca.is_primary_locked, ca.preference \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.musicbrainz_release_group_id = ? LIMIT 1",
        )
        .bind(trimmed)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => Ok(Self::hydrate_canonical_albums_raw(pool, vec![r])
                .await?
                .pop()),
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
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
             ca.meta_policy, \
             CASE WHEN ca.user_edits_json IS NOT NULL AND TRIM(ca.user_edits_json) NOT IN ('', '{}', 'null') THEN 1 ELSE 0 END AS has_user_edits, \
             ca.primary_version_id, ca.is_primary_locked, ca.preference \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE ca.upc = ? LIMIT 1",
        )
        .bind(trimmed)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => Ok(Self::hydrate_canonical_albums_raw(pool, vec![r])
                .await?
                .pop()),
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
             ca.release_year, ca.musicbrainz_release_group_id, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
             ca.meta_policy, \
             CASE WHEN ca.user_edits_json IS NOT NULL AND TRIM(ca.user_edits_json) NOT IN ('', '{}', 'null') THEN 1 ELSE 0 END AS has_user_edits, \
             ca.primary_version_id, ca.is_primary_locked, ca.preference \
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

        Self::hydrate_canonical_albums_raw(pool, rows).await
    }

    pub async fn find_canonical_album_ids_by_isrcs(
        pool: &SqlitePool,
        isrcs: &[String],
    ) -> Result<Vec<String>> {
        let mut exact_candidates: Vec<String> = Vec::with_capacity(isrcs.len() * 2);
        let mut cleaned: Vec<String> = Vec::with_capacity(isrcs.len());
        for raw in isrcs {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                continue;
            }
            exact_candidates.push(trimmed.to_string());
            let norm = trimmed
                .chars()
                .filter(|c| *c != '-')
                .collect::<String>()
                .to_ascii_uppercase();
            if !norm.is_empty() {
                exact_candidates.push(norm.clone());
                cleaned.push(norm);
            }
        }
        exact_candidates.sort();
        exact_candidates.dedup();
        cleaned.sort();
        cleaned.dedup();

        if cleaned.is_empty() {
            return Ok(Vec::new());
        }

        let mut matched_ids: Vec<String> = Vec::new();
        for chunk in exact_candidates.chunks(400) {
            let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                "SELECT DISTINCT av.canonical_album_id \
                 FROM track_sources ts \
                 JOIN album_versions av ON ts.version_id = av.id \
                 WHERE ts.isrc IN (",
            );
            let mut separated = qb.separated(", ");
            for isrc in chunk {
                separated.push_bind(isrc);
            }
            separated.push_unseparated(")");

            let rows: Vec<(String,)> = qb.build_query_as().fetch_all(pool).await?;
            matched_ids.extend(rows.into_iter().map(|(id,)| id));
        }

        if !matched_ids.is_empty() {
            matched_ids.sort();
            matched_ids.dedup();
            return Ok(matched_ids);
        }

        for chunk in cleaned.chunks(400) {
            let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                "SELECT DISTINCT av.canonical_album_id \
                 FROM track_sources ts \
                 JOIN album_versions av ON ts.version_id = av.id \
                 WHERE ts.isrc IS NOT NULL AND UPPER(REPLACE(ts.isrc, '-', '')) IN (",
            );
            let mut separated = qb.separated(", ");
            for isrc in chunk {
                separated.push_bind(isrc);
            }
            separated.push_unseparated(")");

            let rows: Vec<(String,)> = qb.build_query_as().fetch_all(pool).await?;
            matched_ids.extend(rows.into_iter().map(|(id,)| id));
        }

        matched_ids.sort();
        matched_ids.dedup();
        Ok(matched_ids)
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

        let by_norm =
            Self::find_canonical_albums_by_normalized_key(pool, title, artist_name).await?;
        Ok(by_norm.into_iter().next())
    }

    pub async fn get_album_detail(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Option<AlbumDetail>> {
        Self::get_album_detail_with_options(pool, album_id, false).await
    }

    pub async fn get_album_detail_with_options(
        pool: &SqlitePool,
        album_id: &str,
        include_hidden: bool,
    ) -> Result<Option<AlbumDetail>> {
        let Some(mut album) = Self::find_canonical_album_by_id(pool, album_id).await? else {
            return Ok(None);
        };

        let mut versions = Vec::with_capacity(album.versions.len());
        let mut non_empty_version_ids: HashSet<String> = HashSet::new();
        for ver in &album.versions {
            let tracks =
                Self::find_track_sources_by_version_with_options(pool, &ver.id, include_hidden)
                    .await?;
            if !tracks.is_empty() {
                non_empty_version_ids.insert(ver.id.clone());
                versions.push(AlbumVersionDetail {
                    version: ver.clone(),
                    tracks,
                });
            }
        }
        album
            .versions
            .retain(|v| non_empty_version_ids.contains(&v.id));

        if versions.is_empty() {
            return Ok(None);
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

        let meta_policy = album.meta_policy;
        let has_user_edits = album.has_user_edits;
        let primary_version_id = album
            .primary_version_id
            .clone()
            .filter(|pid| non_empty_version_ids.contains(pid))
            .or_else(|| versions.first().map(|v| v.version.id.clone()));
        let is_primary_locked = album.is_primary_locked;
        let hidden_version_count = versions.iter().filter(|v| v.version.is_hidden).count() as u32;
        Ok(Some(AlbumDetail {
            album,
            versions,
            credits,
            meta_policy,
            has_user_edits,
            primary_version_id,
            is_primary_locked,
            hidden_version_count,
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

        if !albums.is_empty() {
            let mut present_album_ids: HashSet<String> = HashSet::new();
            let mut present_version_ids: HashSet<String> = HashSet::new();
            let album_ids: Vec<String> = albums.iter().map(|a| a.id.clone()).collect();
            for chunk in album_ids.chunks(500) {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "SELECT DISTINCT av.canonical_album_id, av.id \
                     FROM album_versions av \
                     JOIN track_sources ts ON ts.version_id = av.id \
                     WHERE ts.file_status = 'present' AND av.canonical_album_id IN (",
                );
                let mut sep = qb.separated(", ");
                for aid in chunk {
                    sep.push_bind(aid);
                }
                sep.push_unseparated(")");
                let rows: Vec<(String, String)> = qb.build_query_as().fetch_all(pool).await?;
                for (aid, vid) in rows {
                    present_album_ids.insert(aid);
                    present_version_ids.insert(vid);
                }
            }
            albums.retain(|a| present_album_ids.contains(&a.id));
            for alb in &mut albums {
                alb.versions.retain(|v| present_version_ids.contains(&v.id));
            }
        }

        Ok(Some(ArtistDetail {
            id: artist.id,
            name: artist.name,
            sort_name: artist.sort_name,
            musicbrainz_id: artist.musicbrainz_id,
            biography: artist.biography,
            image_path: artist.image_path,
            preference: artist.preference,
            albums,
            credits,
        }))
    }
}
