use core_types::{FocusQuery, FocusSort, FocusSortDirection, FocusSortField};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};

use super::compiler::{FocusCompileScope, compile_focus_query_to_sql};
use crate::error::Result;
use crate::repository::CatalogTrackRow;

pub(super) async fn query_focus_tracks(
    pool: &SqlitePool,
    query: &FocusQuery,
    limit: u32,
    offset: u32,
) -> Result<(u64, Vec<CatalogTrackRow>)> {
    let scope = FocusCompileScope::for_tracks(query.include_hidden);

    // 1. Total count
    let mut count_qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
        "SELECT COUNT(*) \
         FROM track_sources trk \
         JOIN album_versions ver ON ver.id = trk.version_id \
         JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
         LEFT JOIN artists art ON art.id = alb.primary_artist_id \
         WHERE trk.file_status = 'present'",
    );
    if !query.include_hidden {
        count_qb.push(" AND ver.is_hidden = 0 AND trk.is_hidden = 0");
    }
    compile_focus_query_to_sql(&mut count_qb, query, scope, None);
    let (total_i64,): (i64,) = count_qb.build_query_as().fetch_one(pool).await?;
    let total_count = total_i64.max(0) as u64;

    if total_count == 0 {
        return Ok((0, Vec::new()));
    }

    // 2. Paginated rows matching CatalogTrackRow
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
        "SELECT trk.id, trk.title, \
                COALESCE(NULLIF(trk.artist_name, ''), COALESCE(art.name, 'Unknown Artist')) AS artist, \
                COALESCE(alb.title, 'Unknown Album') AS album, trk.duration_ms, trk.sample_rate_hz, \
                trk.bit_depth, trk.channels, trk.codec, trk.is_dsd, trk.external_track_id, \
                trk.artist_name, COALESCE(trk.album_artist, alb.album_artist) AS album_artist, trk.genre, \
                COALESCE(trk.release_year, alb.release_year) AS release_year, trk.track_number, trk.disc_number, trk.composer, \
                COALESCE(alb.cover_url, alb.merged_cover_path) AS cover_url, \
                trk.metadata_hash, trk.embedded_lyrics, \
                alb.id AS alb_id, art.id AS art_id, trk.preference, \
                trk.is_hidden, trk.file_size, \
                COALESCE(trk.bitrate_kbps, CASE WHEN trk.file_size > 0 AND trk.duration_ms > 0 THEN CAST(((trk.file_size * 8) / trk.duration_ms) AS INTEGER) ELSE NULL END) AS bitrate_kbps \
         FROM track_sources trk \
         JOIN album_versions ver ON ver.id = trk.version_id \
         JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
         LEFT JOIN artists art ON art.id = alb.primary_artist_id \
         WHERE trk.file_status = 'present'",
    );
    if !query.include_hidden {
        qb.push(" AND ver.is_hidden = 0 AND trk.is_hidden = 0");
    }
    compile_focus_query_to_sql(&mut qb, query, scope, None);
    push_track_order_by(&mut qb, query.sort);
    qb.push(" LIMIT ");
    qb.push_bind(limit as i64);
    qb.push(" OFFSET ");
    qb.push_bind(offset as i64);

    let rows: Vec<CatalogTrackRow> = qb.build_query_as().fetch_all(pool).await?;
    Ok((total_count, rows))
}

pub(crate) fn push_track_order_by(qb: &mut QueryBuilder<'_, Sqlite>, sort: Option<FocusSort>) {
    let sort = sort.unwrap_or_default();
    let dir = match sort.direction {
        FocusSortDirection::Asc => "ASC",
        FocusSortDirection::Desc => "DESC",
    };

    qb.push(" ORDER BY ");
    match sort.field {
        FocusSortField::Title => {
            qb.push(format!(
                "LOWER(trk.title) {dir}, alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.id ASC"
            ));
        }
        FocusSortField::Artist => {
            qb.push(format!(
                "LOWER(COALESCE(NULLIF(trk.artist_name, ''), art.name, '')) {dir}, alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.id ASC"
            ));
        }
        FocusSortField::ReleaseYear => {
            qb.push(format!(
                "CASE WHEN alb.release_year IS NULL THEN 1 ELSE 0 END ASC, alb.release_year {dir}, alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.id ASC"
            ));
        }
        FocusSortField::AddedAt => {
            qb.push(format!(
                "COALESCE(trk.added_at, alb.created_at) {dir}, trk.id ASC"
            ));
        }
        FocusSortField::SampleRate => {
            qb.push(format!(
                "trk.sample_rate_hz {dir}, trk.bit_depth {dir}, trk.id ASC"
            ));
        }
        FocusSortField::Duration => {
            qb.push(format!("trk.duration_ms {dir}, trk.id ASC"));
        }
        FocusSortField::Random => {
            let norm_seed = sort.seed.unwrap_or(0).rem_euclid(1_000_000_007);
            qb.push("(((trk.rowid + ");
            qb.push_bind(norm_seed);
            qb.push(format!(
                ") * 1103515245 + 12345) & 2147483647) {dir}, trk.id ASC"
            ));
        }
    }
}
