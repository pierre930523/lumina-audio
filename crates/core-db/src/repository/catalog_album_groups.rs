use core_types::AlbumGroupSummaryRow;
use sqlx::SqlitePool;

use crate::error::Result;
use crate::repository::CatalogQueryRepository;

#[derive(Debug, sqlx::FromRow)]
struct GroupSummaryDbRow {
    id: String,
    group_id: String,
    version_id: Option<String>,
    primary_version_id: Option<String>,
    title: String,
    artist: String,
    release_year: Option<i32>,
    album_artist: Option<String>,
    cover_url: Option<String>,
    track_count: i64,
    disc_count: i64,
    version_count: i64,
    hidden_version_count: i64,
    is_primary: i32,
    is_primary_locked: i32,
    is_hidden: i32,
    is_manual_group: i32,
    quality_score: f64,
    edition_label: Option<String>,
    provider: Option<String>,
    codec: Option<String>,
    sample_rate_hz: Option<i64>,
    bit_depth: Option<i64>,
    is_dsd: i32,
    preference: i32,
}

impl From<GroupSummaryDbRow> for AlbumGroupSummaryRow {
    fn from(r: GroupSummaryDbRow) -> Self {
        Self {
            id: r.id,
            group_id: r.group_id,
            version_id: r.version_id,
            primary_version_id: r.primary_version_id,
            title: r.title,
            artist: r.artist,
            release_year: r.release_year,
            album_artist: r.album_artist,
            cover_url: r.cover_url,
            track_count: r.track_count.max(0) as u32,
            disc_count: r.disc_count.max(1) as u32,
            version_count: r.version_count.max(0) as u32,
            hidden_version_count: r.hidden_version_count.max(0) as u32,
            is_primary: r.is_primary != 0,
            is_primary_locked: r.is_primary_locked != 0,
            is_hidden: r.is_hidden != 0,
            is_manual_group: r.is_manual_group != 0,
            quality_score: r.quality_score,
            edition_label: r.edition_label,
            provider: r.provider,
            codec: r.codec,
            sample_rate_hz: r.sample_rate_hz.and_then(|v| u32::try_from(v).ok()),
            bit_depth: r.bit_depth.and_then(|v| u8::try_from(v).ok()),
            is_dsd: r.is_dsd != 0,
            preference: r.preference,
        }
    }
}

impl CatalogQueryRepository {
    /// Lists album summaries for the main library grid/list.
    ///
    /// - When `include_hidden == false`: returns 1 row per `canonical_albums` group that has
    ///   at least one visible (`is_hidden = 0`) version with present tracks, using its primary
    ///   version details plus group version counts.
    /// - When `include_hidden == true`: returns 1 row per present `album_versions` (both visible
    ///   and hidden), ordered by album `sort_title`, primary first, visible first, `quality_score DESC`.
    pub async fn list_album_group_summaries(
        pool: &SqlitePool,
        limit: usize,
        offset: usize,
        include_hidden: bool,
    ) -> Result<Vec<AlbumGroupSummaryRow>> {
        let clamped_limit = limit.clamp(1, 500) as i64;
        let offset_i64 = offset as i64;

        let rows: Vec<GroupSummaryDbRow> = if !include_hidden {
            sqlx::query_as(
                "WITH present_versions AS ( \
                    SELECT av.id, av.canonical_album_id, av.provider_id, av.codec, \
                           av.sample_rate_hz, av.bit_depth, av.is_dsd, av.edition_label, \
                           av.is_hidden, av.quality_score, av.manual_group_id, av.disc_count, \
                           COUNT(ts.id) AS present_tracks \
                    FROM album_versions av \
                    JOIN track_sources ts ON ts.version_id = av.id AND ts.file_status = 'present' AND ts.is_hidden = 0 \
                    GROUP BY av.id \
                 ), \
                 group_stats AS ( \
                    SELECT canonical_album_id, \
                           COUNT(*) AS version_count, \
                           SUM(CASE WHEN is_hidden = 1 THEN 1 ELSE 0 END) AS hidden_version_count, \
                           SUM(CASE WHEN is_hidden = 0 THEN 1 ELSE 0 END) AS visible_version_count, \
                           MAX(CASE WHEN manual_group_id IS NOT NULL THEN 1 ELSE 0 END) AS is_manual_group \
                    FROM present_versions \
                    GROUP BY canonical_album_id \
                 ), \
                 ranked_visible AS ( \
                    SELECT pv.*, \
                           ROW_NUMBER() OVER ( \
                               PARTITION BY pv.canonical_album_id \
                               ORDER BY CASE WHEN ca.primary_version_id = pv.id THEN 0 ELSE 1 END, \
                                        pv.quality_score DESC, \
                                        pv.present_tracks DESC, \
                                        CASE WHEN LOWER(pv.provider_id) = 'local' THEN 0 ELSE 1 END, \
                                        pv.sample_rate_hz DESC, \
                                        pv.bit_depth DESC, \
                                        pv.id ASC \
                           ) AS rn \
                    FROM present_versions pv \
                    JOIN canonical_albums ca ON ca.id = pv.canonical_album_id \
                    WHERE pv.is_hidden = 0 \
                 ) \
                 SELECT ca.id AS id, \
                        ca.id AS group_id, \
                        rv.id AS version_id, \
                        rv.id AS primary_version_id, \
                        ca.title, \
                        COALESCE(ar.name, 'Unknown Artist') AS artist, \
                        ca.release_year, \
                        ca.album_artist, \
                        COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
                        rv.present_tracks AS track_count, \
                        rv.disc_count, \
                        gs.version_count, \
                        gs.hidden_version_count, \
                        1 AS is_primary, \
                        ca.is_primary_locked, \
                        0 AS is_hidden, \
                        gs.is_manual_group, \
                        rv.quality_score, \
                        rv.edition_label, \
                        rv.provider_id AS provider, \
                        rv.codec, \
                        rv.sample_rate_hz, \
                        rv.bit_depth, \
                        rv.is_dsd, \
                        ca.preference \
                 FROM canonical_albums ca \
                 LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
                 JOIN group_stats gs ON gs.canonical_album_id = ca.id AND gs.visible_version_count > 0 \
                 JOIN ranked_visible rv ON rv.canonical_album_id = ca.id AND rv.rn = 1 \
                 ORDER BY ca.sort_title ASC, ca.title ASC, ca.id ASC \
                 LIMIT ? OFFSET ?",
            )
            .bind(clamped_limit)
            .bind(offset_i64)
            .fetch_all(pool)
            .await?
        } else {
            sqlx::query_as(
                "WITH present_versions AS ( \
                    SELECT av.id, av.canonical_album_id, av.provider_id, av.codec, \
                           av.sample_rate_hz, av.bit_depth, av.is_dsd, av.edition_label, \
                           av.is_hidden, av.quality_score, av.manual_group_id, av.disc_count, \
                           COUNT(ts.id) AS present_tracks \
                    FROM album_versions av \
                    JOIN track_sources ts ON ts.version_id = av.id AND ts.file_status = 'present' \
                    GROUP BY av.id \
                 ), \
                 group_stats AS ( \
                    SELECT canonical_album_id, \
                           COUNT(*) AS version_count, \
                           SUM(CASE WHEN is_hidden = 1 THEN 1 ELSE 0 END) AS hidden_version_count \
                    FROM present_versions \
                    GROUP BY canonical_album_id \
                 ) \
                 SELECT ca.id AS id, \
                        ca.id AS group_id, \
                        pv.id AS version_id, \
                        ca.primary_version_id, \
                        ca.title, \
                        COALESCE(ar.name, 'Unknown Artist') AS artist, \
                        ca.release_year, \
                        ca.album_artist, \
                        COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
                        pv.present_tracks AS track_count, \
                        pv.disc_count, \
                        gs.version_count, \
                        gs.hidden_version_count, \
                        CASE WHEN ca.primary_version_id = pv.id THEN 1 ELSE 0 END AS is_primary, \
                        ca.is_primary_locked, \
                        pv.is_hidden, \
                        CASE WHEN pv.manual_group_id IS NOT NULL THEN 1 ELSE 0 END AS is_manual_group, \
                        pv.quality_score, \
                        pv.edition_label, \
                        pv.provider_id AS provider, \
                        pv.codec, \
                        pv.sample_rate_hz, \
                        pv.bit_depth, \
                        pv.is_dsd, \
                        ca.preference \
                 FROM present_versions pv \
                 JOIN canonical_albums ca ON ca.id = pv.canonical_album_id \
                 JOIN group_stats gs ON gs.canonical_album_id = ca.id \
                 LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
                 ORDER BY ca.sort_title ASC, \
                          ca.title ASC, \
                          CASE WHEN ca.primary_version_id = pv.id THEN 0 ELSE 1 END, \
                          pv.is_hidden ASC, \
                          pv.quality_score DESC, \
                          pv.id ASC \
                 LIMIT ? OFFSET ?",
            )
            .bind(clamped_limit)
            .bind(offset_i64)
            .fetch_all(pool)
            .await?
        };

        Ok(rows.into_iter().map(Into::into).collect())
    }
}
