use crate::error::Result;
use crate::repository::library::normalize_local_path_for_compare;
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct CatalogTrackRow {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: i64,
    pub sample_rate_hz: i64,
    pub bit_depth: i64,
    pub channels: i64,
    pub codec: String,
    pub is_dsd: i32,
    pub external_track_id: String,
    pub artist_name: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub release_year: Option<i64>,
    pub track_number: i64,
    pub disc_number: i64,
    pub composer: Option<String>,
    pub cover_url: Option<String>,
    pub metadata_hash: Option<String>,
    pub embedded_lyrics: Option<String>,
    pub alb_id: String,
    pub art_id: Option<String>,
    pub preference: i32,
    #[sqlx(default)]
    pub is_hidden: i32,
    #[sqlx(default)]
    pub file_size: Option<i64>,
    #[sqlx(default)]
    pub bitrate_kbps: Option<i64>,
}

pub(crate) const CATALOG_TRACK_SELECT: &str = "SELECT trk.id, trk.title, \
            COALESCE(NULLIF(trk.artist_name, ''), COALESCE(art.name, 'Unknown Artist')) AS artist, \
            COALESCE(alb.title, 'Unknown Album') AS album, trk.duration_ms, trk.sample_rate_hz, \
            trk.bit_depth, trk.channels, trk.codec, trk.is_dsd, trk.external_track_id, \
            trk.artist_name, COALESCE(trk.album_artist, alb.album_artist) AS album_artist, trk.genre, \
            COALESCE(trk.release_year, alb.release_year) AS release_year, \
            trk.track_number, trk.disc_number, trk.composer, \
            alb.cover_url, trk.metadata_hash, trk.embedded_lyrics, \
            alb.id AS alb_id, art.id AS art_id, trk.preference, \
            trk.is_hidden, trk.file_size, \
            COALESCE(trk.bitrate_kbps, CASE WHEN trk.file_size > 0 AND trk.duration_ms > 0 THEN CAST(((trk.file_size * 8) / trk.duration_ms) AS INTEGER) ELSE NULL END) AS bitrate_kbps \
     FROM track_sources trk \
     JOIN album_versions ver ON ver.id = trk.version_id \
     JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
     LEFT JOIN artists art ON art.id = alb.primary_artist_id";

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct CatalogAlbumSummaryRow {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub release_year: Option<i64>,
    pub album_artist: Option<String>,
    pub cover_url: Option<String>,
    pub track_count: i64,
}

pub struct CatalogQueryRepository;

impl CatalogQueryRepository {
    pub async fn find_album_version_by_external_id(
        pool: &SqlitePool,
        provider_id: &str,
        external_album_id: &str,
    ) -> Result<Option<(String, String)>> {
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT id, canonical_album_id FROM album_versions WHERE provider_id = ? AND external_album_id = ?",
        )
        .bind(provider_id)
        .bind(external_album_id)
        .fetch_optional(pool)
        .await?;
        Ok(row)
    }

    pub async fn list_present_tracks(
        pool: &SqlitePool,
        limit: usize,
    ) -> Result<Vec<CatalogTrackRow>> {
        Self::list_present_tracks_with_options(pool, limit, false).await
    }

    pub async fn list_present_tracks_with_options(
        pool: &SqlitePool,
        limit: usize,
        include_hidden: bool,
    ) -> Result<Vec<CatalogTrackRow>> {
        let sql = if include_hidden {
            format!(
                "{CATALOG_TRACK_SELECT} \
                 WHERE trk.file_status = 'present' \
                 ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.external_track_id ASC, trk.title ASC \
                 LIMIT ?"
            )
        } else {
            format!(
                "{CATALOG_TRACK_SELECT} \
                 WHERE trk.file_status = 'present' AND ver.is_hidden = 0 AND trk.is_hidden = 0 \
                 ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.external_track_id ASC, trk.title ASC \
                 LIMIT ?"
            )
        };
        let rows: Vec<CatalogTrackRow> = sqlx::query_as(&sql)
            .bind(limit.max(1) as i64)
            .fetch_all(pool)
            .await?;
        Ok(rows)
    }

    pub async fn list_all_present_tracks(pool: &SqlitePool) -> Result<Vec<CatalogTrackRow>> {
        let sql = format!(
            "{CATALOG_TRACK_SELECT} \
             WHERE trk.file_status = 'present' AND ver.is_hidden = 0 AND trk.is_hidden = 0 \
             ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.external_track_id ASC, trk.title ASC"
        );
        let rows: Vec<CatalogTrackRow> = sqlx::query_as(&sql).fetch_all(pool).await?;
        Ok(rows)
    }

    pub async fn list_album_summaries(
        pool: &SqlitePool,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<CatalogAlbumSummaryRow>> {
        let rows: Vec<CatalogAlbumSummaryRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, COALESCE(ar.name, 'Unknown Artist') AS artist, ca.release_year, \
             ca.album_artist, ca.cover_url, COUNT(ts.id) AS track_count \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             INNER JOIN album_versions av ON av.canonical_album_id = ca.id \
             INNER JOIN track_sources ts ON ts.version_id = av.id AND ts.file_status = 'present' \
             GROUP BY ca.id \
             HAVING COUNT(ts.id) > 0 \
             ORDER BY ca.sort_title LIMIT ? OFFSET ?",
        )
        .bind(limit.clamp(1, 500) as i64)
        .bind(offset as i64)
        .fetch_all(pool)
        .await?;
        Ok(rows)
    }

    pub async fn count_albums_under_local_root(
        pool: &SqlitePool,
        root_path: &str,
    ) -> Result<usize> {
        let norm = root_path
            .trim()
            .replace('\\', "/")
            .trim_end_matches('/')
            .to_string();
        let like_pat = format!("{norm}/%");
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT av.canonical_album_id) \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.provider_id = 'local' \
               AND ts.file_status = 'present' \
               AND (ts.external_track_id = ? OR ts.external_track_id LIKE ?)",
        )
        .bind(&norm)
        .bind(&like_pat)
        .fetch_one(pool)
        .await?;

        if count > 0 {
            return Ok(count as usize);
        }

        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT av.canonical_album_id) \
             FROM album_versions av \
             INNER JOIN track_sources ts ON ts.version_id = av.id AND ts.file_status = 'present'",
        )
        .fetch_one(pool)
        .await?;

        Ok(total.max(0) as usize)
    }

    pub async fn invalidate_local_dir_mtime_cache(pool: &SqlitePool, dir_path: &str) -> Result<()> {
        let norm = normalize_local_path_for_compare(dir_path);
        if norm.is_empty() {
            return Ok(());
        }
        let norm_lower = norm.to_lowercase();
        let like_pat = if norm_lower.ends_with('/') {
            format!("{norm_lower}%")
        } else {
            format!("{norm_lower}/%")
        };
        sqlx::query(
            "UPDATE track_sources SET file_mtime = NULL, file_size = NULL \
             WHERE provider_id = 'local' \
               AND (LOWER(REPLACE(external_track_id, '\\', '/')) = ? \
                    OR LOWER(REPLACE(external_track_id, '\\', '/')) LIKE ?)",
        )
        .bind(&norm_lower)
        .bind(&like_pat)
        .execute(pool)
        .await?;
        Ok(())
    }

    pub async fn get_album_mb_and_cover_tx(
        conn: &mut SqliteConnection,
        album_id: &str,
    ) -> Result<Option<(Option<String>, Option<String>)>> {
        let row: Option<(Option<String>, Option<String>)> = sqlx::query_as(
            "SELECT musicbrainz_release_group_id, COALESCE(cover_url, merged_cover_path) \
             FROM canonical_albums WHERE id = ?",
        )
        .bind(album_id)
        .fetch_optional(&mut *conn)
        .await?;
        Ok(row)
    }

    /// Returns `true` when incoming album metadata should overwrite core `canonical_albums` fields:
    /// always `true` for `local` scans/rebuilds, or when re-syncing the same non-local provider
    /// on an album that has no `local` version. Cross-provider merges only enrich missing metadata.
    pub async fn should_overwrite_album_core_tx(
        conn: &mut SqliteConnection,
        album_id: &str,
        incoming_provider_id: &str,
    ) -> Result<bool> {
        if incoming_provider_id == "local" {
            return Ok(true);
        }
        let (has_local, has_same): (i64, i64) = sqlx::query_as(
            "SELECT \
                 COALESCE(MAX(CASE WHEN provider_id = 'local' THEN 1 ELSE 0 END), 0), \
                 COALESCE(MAX(CASE WHEN provider_id = ? THEN 1 ELSE 0 END), 0) \
             FROM album_versions WHERE canonical_album_id = ?",
        )
        .bind(incoming_provider_id)
        .bind(album_id)
        .fetch_one(&mut *conn)
        .await?;
        Ok(has_local == 0 && has_same > 0)
    }

    pub async fn list_album_upcs(pool: &SqlitePool) -> Result<Vec<(String, String)>> {
        let rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT id, upc FROM canonical_albums WHERE upc IS NOT NULL AND TRIM(upc) != ''",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows)
    }

    pub async fn list_distinct_external_track_ids(
        pool: &SqlitePool,
        provider_id: &str,
    ) -> Result<Vec<String>> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT DISTINCT external_track_id FROM track_sources WHERE provider_id = ?",
        )
        .bind(provider_id)
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }

    pub async fn count_track_sources_for_provider(
        pool: &SqlitePool,
        provider_id: &str,
    ) -> Result<i64> {
        let (count,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM track_sources WHERE provider_id = ?")
                .bind(provider_id)
                .fetch_one(pool)
                .await?;
        Ok(count)
    }

    pub async fn list_external_track_ids_for_album(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Vec<String>> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT ts.external_track_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE av.canonical_album_id = ? \
             ORDER BY CASE WHEN ca.primary_version_id = av.id THEN 0 ELSE 1 END, \
                      av.is_hidden ASC, av.quality_score DESC, \
                      CASE WHEN av.provider_id = 'local' THEN 0 ELSE 1 END, \
                      ts.disc_number ASC, ts.track_number ASC, ts.external_track_id ASC",
        )
        .bind(album_id)
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(|(p,)| p).collect())
    }

    pub async fn get_first_external_track_id_for_album(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Option<String>> {
        let row: Option<(String,)> = sqlx::query_as(
            "SELECT ts.external_track_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE av.canonical_album_id = ? \
             ORDER BY CASE WHEN ca.primary_version_id = av.id THEN 0 ELSE 1 END, \
                      av.is_hidden ASC, av.quality_score DESC, \
                      CASE WHEN av.provider_id = 'local' THEN 0 ELSE 1 END, \
                      ts.disc_number ASC, ts.track_number ASC, ts.external_track_id ASC \
             LIMIT 1",
        )
        .bind(album_id)
        .fetch_optional(pool)
        .await?;
        Ok(row.map(|(p,)| p))
    }

    pub async fn get_album_cover_path(pool: &SqlitePool, album_id: &str) -> Result<Option<String>> {
        let row: Option<(Option<String>,)> = sqlx::query_as(
            "SELECT COALESCE(cover_url, merged_cover_path) FROM canonical_albums WHERE id = ? LIMIT 1",
        )
        .bind(album_id)
        .fetch_optional(pool)
        .await?;
        Ok(row.and_then(|(c,)| c))
    }

    pub async fn get_track_path_and_album_by_id(
        pool: &SqlitePool,
        track_id: &str,
    ) -> Result<Option<(String, String)>> {
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT ts.external_track_id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE ts.id = ? LIMIT 1",
        )
        .bind(track_id)
        .fetch_optional(pool)
        .await?;
        Ok(row)
    }

    pub async fn canonical_album_exists(pool: &SqlitePool, album_id: &str) -> Result<bool> {
        let row: Option<(String,)> =
            sqlx::query_as("SELECT id FROM canonical_albums WHERE id = ? LIMIT 1")
                .bind(album_id)
                .fetch_optional(pool)
                .await?;
        Ok(row.is_some())
    }

    pub async fn get_track_id_and_album_by_normalized_path(
        pool: &SqlitePool,
        normalized_path: &str,
    ) -> Result<Option<(String, String)>> {
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT ts.id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE LOWER(REPLACE(ts.external_track_id, '\\', '/')) = LOWER(?) LIMIT 1",
        )
        .bind(normalized_path)
        .fetch_optional(pool)
        .await?;
        Ok(row)
    }

    pub async fn list_unenriched_album_titles(pool: &SqlitePool) -> Result<Vec<String>> {
        let rows: Vec<(String,)> =
            sqlx::query_as("SELECT title FROM canonical_albums WHERE enriched_at IS NULL")
                .fetch_all(pool)
                .await?;
        Ok(rows.into_iter().map(|(t,)| t).collect())
    }

    pub async fn get_album_enriched_at(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Option<String>> {
        let (enriched_at,): (Option<String>,) =
            sqlx::query_as("SELECT enriched_at FROM canonical_albums WHERE id = ?")
                .bind(album_id)
                .fetch_one(pool)
                .await?;
        Ok(enriched_at)
    }

    /// Fetches only present tracks matching `ids` via chunked SQL `IN (...)` clauses
    /// instead of scanning the entire `track_sources` table.
    pub async fn list_present_tracks_by_ids(
        pool: &SqlitePool,
        ids: &[String],
    ) -> Result<Vec<CatalogTrackRow>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let mut out = Vec::with_capacity(ids.len());
        for chunk in ids.chunks(500) {
            let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(format!(
                "{CATALOG_TRACK_SELECT} WHERE trk.file_status = 'present' AND trk.id IN ("
            ));
            let mut sep = qb.separated(", ");
            for id in chunk {
                sep.push_bind(id);
            }
            sep.push_unseparated(
                ") ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.external_track_id ASC, trk.title ASC",
            );
            let rows: Vec<CatalogTrackRow> = qb.build_query_as().fetch_all(pool).await?;
            out.extend(rows);
        }
        Ok(out)
    }

    /// Fetches present tracks matching any FTS-resolved track, album, or artist IDs
    /// directly in SQL with `LIMIT`, eliminating full-library scans during search.
    pub async fn list_present_tracks_matching_entities(
        pool: &SqlitePool,
        track_ids: &[String],
        album_ids: &[String],
        artist_ids: &[String],
        limit: usize,
    ) -> Result<Vec<CatalogTrackRow>> {
        if track_ids.is_empty() && album_ids.is_empty() && artist_ids.is_empty() {
            return Ok(Vec::new());
        }
        let max_rows = limit.max(1) as i64;
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(format!(
            "{CATALOG_TRACK_SELECT} WHERE trk.file_status = 'present' AND ver.is_hidden = 0 AND trk.is_hidden = 0 AND ("
        ));
        let mut has_clause = false;
        if !track_ids.is_empty() {
            qb.push("trk.id IN (");
            let mut sep = qb.separated(", ");
            for id in track_ids.iter().take(300) {
                sep.push_bind(id);
            }
            sep.push_unseparated(")");
            has_clause = true;
        }
        if !album_ids.is_empty() {
            if has_clause {
                qb.push(" OR ");
            }
            qb.push("alb.id IN (");
            let mut sep = qb.separated(", ");
            for id in album_ids.iter().take(300) {
                sep.push_bind(id);
            }
            sep.push_unseparated(")");
            has_clause = true;
        }
        if !artist_ids.is_empty() {
            if has_clause {
                qb.push(" OR ");
            }
            qb.push("art.id IN (");
            let mut sep = qb.separated(", ");
            for id in artist_ids.iter().take(300) {
                sep.push_bind(id);
            }
            sep.push_unseparated(")");
        }
        qb.push(
            ") ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.external_track_id ASC, trk.title ASC LIMIT ",
        );
        qb.push_bind(max_rows);
        let rows: Vec<CatalogTrackRow> = qb.build_query_as().fetch_all(pool).await?;
        Ok(rows)
    }
}
