use core_types::{AlbumGroupSummaryRow, FocusQuery, FocusSort, FocusSortDirection, FocusSortField};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};

use super::compiler::{FocusCompileScope, compile_focus_query_to_sql};
use crate::error::Result;

#[derive(Debug, sqlx::FromRow)]
struct FocusAlbumDbRow {
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

impl From<FocusAlbumDbRow> for AlbumGroupSummaryRow {
    fn from(r: FocusAlbumDbRow) -> Self {
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

const ALBUM_BASE_CTES_VISIBLE: &str = "\
WITH present_versions AS ( \
    SELECT av.rowid AS ver_rowid, av.id, av.canonical_album_id, av.provider_id, av.codec, \
           av.sample_rate_hz, av.bit_depth, av.is_dsd, av.edition_label, \
           av.is_hidden, av.quality_score, av.manual_group_id, av.disc_count, \
           COUNT(ts.id) AS present_tracks, \
           COALESCE(SUM(ts.duration_ms), 0) AS total_duration_ms \
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
) ";

const ALBUM_BASE_CTES_ALL: &str = "\
WITH present_versions AS ( \
    SELECT av.rowid AS ver_rowid, av.id, av.canonical_album_id, av.provider_id, av.codec, \
           av.sample_rate_hz, av.bit_depth, av.is_dsd, av.edition_label, \
           av.is_hidden, av.quality_score, av.manual_group_id, av.disc_count, \
           COUNT(ts.id) AS present_tracks, \
           COALESCE(SUM(ts.duration_ms), 0) AS total_duration_ms \
    FROM album_versions av \
    JOIN track_sources ts ON ts.version_id = av.id AND ts.file_status = 'present' AND ts.is_hidden = 0 \
    GROUP BY av.id \
), \
group_stats AS ( \
    SELECT canonical_album_id, \
           COUNT(*) AS version_count, \
           SUM(CASE WHEN is_hidden = 1 THEN 1 ELSE 0 END) AS hidden_version_count \
    FROM present_versions \
    GROUP BY canonical_album_id \
) ";

pub(super) async fn query_focus_albums(
    pool: &SqlitePool,
    query: &FocusQuery,
    limit: u32,
    offset: u32,
) -> Result<(u64, Vec<AlbumGroupSummaryRow>)> {
    let scope = FocusCompileScope::for_albums(query.include_hidden);

    // 1. Total count
    let mut count_qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(if !query.include_hidden {
        ALBUM_BASE_CTES_VISIBLE
    } else {
        ALBUM_BASE_CTES_ALL
    });
    if !query.include_hidden {
        count_qb.push(
            "SELECT COUNT(*) \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
             JOIN group_stats gs ON gs.canonical_album_id = ca.id AND gs.visible_version_count > 0 \
             JOIN ranked_visible rv ON rv.canonical_album_id = ca.id AND rv.rn = 1 \
             WHERE 1 = 1",
        );
    } else {
        count_qb.push(
            "SELECT COUNT(*) \
             FROM present_versions pv \
             JOIN canonical_albums ca ON ca.id = pv.canonical_album_id \
             JOIN group_stats gs ON gs.canonical_album_id = ca.id \
             LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
             WHERE 1 = 1",
        );
    }
    compile_focus_query_to_sql(&mut count_qb, query, scope, None);
    let (total_i64,): (i64,) = count_qb.build_query_as().fetch_one(pool).await?;
    let total_count = total_i64.max(0) as u64;

    if total_count == 0 {
        return Ok((0, Vec::new()));
    }

    // 2. Paginated rows
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(if !query.include_hidden {
        ALBUM_BASE_CTES_VISIBLE
    } else {
        ALBUM_BASE_CTES_ALL
    });
    if !query.include_hidden {
        qb.push(
            "SELECT ca.id AS id, ca.id AS group_id, rv.id AS version_id, rv.id AS primary_version_id, \
                    ca.title, COALESCE(ar.name, 'Unknown Artist') AS artist, ca.release_year, \
                    ca.album_artist, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
                    rv.present_tracks AS track_count, rv.disc_count, gs.version_count, \
                    gs.hidden_version_count, 1 AS is_primary, ca.is_primary_locked, \
                    0 AS is_hidden, gs.is_manual_group, rv.quality_score, rv.edition_label, \
                    rv.provider_id AS provider, rv.codec, rv.sample_rate_hz, rv.bit_depth, rv.is_dsd, \
                    ca.preference \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
             JOIN group_stats gs ON gs.canonical_album_id = ca.id AND gs.visible_version_count > 0 \
             JOIN ranked_visible rv ON rv.canonical_album_id = ca.id AND rv.rn = 1 \
             WHERE 1 = 1",
        );
    } else {
        qb.push(
            "SELECT ca.id AS id, ca.id AS group_id, pv.id AS version_id, ca.primary_version_id, \
                    ca.title, COALESCE(ar.name, 'Unknown Artist') AS artist, ca.release_year, \
                    ca.album_artist, COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url, \
                    pv.present_tracks AS track_count, pv.disc_count, gs.version_count, \
                    gs.hidden_version_count, \
                    CASE WHEN ca.primary_version_id = pv.id THEN 1 ELSE 0 END AS is_primary, \
                    ca.is_primary_locked, pv.is_hidden, \
                    CASE WHEN pv.manual_group_id IS NOT NULL THEN 1 ELSE 0 END AS is_manual_group, \
                    pv.quality_score, pv.edition_label, pv.provider_id AS provider, pv.codec, \
                    pv.sample_rate_hz, pv.bit_depth, pv.is_dsd, ca.preference \
             FROM present_versions pv \
             JOIN canonical_albums ca ON ca.id = pv.canonical_album_id \
             JOIN group_stats gs ON gs.canonical_album_id = ca.id \
             LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
             WHERE 1 = 1",
        );
    }
    compile_focus_query_to_sql(&mut qb, query, scope, None);
    push_album_order_by(&mut qb, query.sort, query.include_hidden);
    qb.push(" LIMIT ");
    qb.push_bind(limit as i64);
    qb.push(" OFFSET ");
    qb.push_bind(offset as i64);

    let rows: Vec<FocusAlbumDbRow> = qb.build_query_as().fetch_all(pool).await?;
    Ok((total_count, rows.into_iter().map(Into::into).collect()))
}

fn push_album_order_by(
    qb: &mut QueryBuilder<'_, Sqlite>,
    sort: Option<FocusSort>,
    include_hidden: bool,
) {
    let sort = sort.unwrap_or_default();
    let dir = match sort.direction {
        FocusSortDirection::Asc => "ASC",
        FocusSortDirection::Desc => "DESC",
    };
    let ver = if include_hidden { "pv" } else { "rv" };
    let tie_id = if include_hidden { "pv.id" } else { "ca.id" };

    qb.push(" ORDER BY ");
    match sort.field {
        FocusSortField::Title => {
            qb.push(format!("ca.sort_title {dir}, ca.title {dir}, {tie_id} ASC"));
        }
        FocusSortField::Artist => {
            qb.push(format!(
                "LOWER(COALESCE(NULLIF(TRIM(ca.album_artist), ''), ar.name, '')) {dir}, ca.sort_title ASC, {tie_id} ASC"
            ));
        }
        FocusSortField::ReleaseYear => {
            qb.push(format!(
                "CASE WHEN ca.release_year IS NULL THEN 1 ELSE 0 END ASC, ca.release_year {dir}, ca.sort_title ASC, {tie_id} ASC"
            ));
        }
        FocusSortField::AddedAt => {
            qb.push(format!(
                "ca.created_at {dir}, ca.sort_title ASC, {tie_id} ASC"
            ));
        }
        FocusSortField::SampleRate => {
            qb.push(format!(
                "{ver}.sample_rate_hz {dir}, {ver}.bit_depth {dir}, ca.sort_title ASC, {tie_id} ASC"
            ));
        }
        FocusSortField::Duration => {
            qb.push(format!(
                "{ver}.total_duration_ms {dir}, ca.sort_title ASC, {tie_id} ASC"
            ));
        }
        FocusSortField::Random => {
            let norm_seed = sort.seed.unwrap_or(0).rem_euclid(1_000_000_007);
            let rowid_expr = if include_hidden {
                "pv.ver_rowid"
            } else {
                "ca.rowid"
            };
            qb.push(format!("((({rowid_expr} + "));
            qb.push_bind(norm_seed);
            qb.push(format!(
                ") * 1103515245 + 12345) & 2147483647) {dir}, {tie_id} ASC"
            ));
        }
    }
}
