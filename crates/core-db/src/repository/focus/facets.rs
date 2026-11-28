use chrono::{Duration, Utc};
use core_types::{
    FocusEntity, FocusFacet, FocusFacetBucket, FocusFacetsResponse, FocusIntRangeBounds, FocusQuery,
};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};
use std::collections::BTreeMap;

use super::compiler::{FocusCompileScope, compile_focus_query_to_sql};
use super::facets_meta::{
    facet_genre, facet_inspector, facet_label, facet_play_status, facet_preference, facet_tag,
};
use crate::error::Result;

/// Computes live disjunctive cross-filtering facet counts and year range bounds.
pub(super) async fn compute_focus_facets(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<FocusFacetsResponse> {
    let total_matched = count_base(pool, query, None).await?;
    let mut facets: BTreeMap<String, Vec<FocusFacetBucket>> = BTreeMap::new();

    facets.insert(
        FocusFacet::Format.as_str().into(),
        facet_format(pool, query).await?,
    );
    facets.insert(
        FocusFacet::BitDepth.as_str().into(),
        facet_bit_depth(pool, query).await?,
    );
    facets.insert(
        FocusFacet::SampleRate.as_str().into(),
        facet_sample_rate(pool, query).await?,
    );
    facets.insert(
        FocusFacet::Channels.as_str().into(),
        facet_channels(pool, query).await?,
    );
    facets.insert(
        FocusFacet::Source.as_str().into(),
        facet_source(pool, query).await?,
    );
    let (year_buckets, year_range) = facet_release_year(pool, query).await?;
    facets.insert(FocusFacet::ReleaseYear.as_str().into(), year_buckets);
    facets.insert(
        FocusFacet::AddedAt.as_str().into(),
        facet_added_at(pool, query).await?,
    );
    facets.insert(
        FocusFacet::PlayStatus.as_str().into(),
        facet_play_status(pool, query).await?,
    );
    facets.insert(
        FocusFacet::Genre.as_str().into(),
        facet_genre(pool, query).await?,
    );
    facets.insert(
        FocusFacet::Label.as_str().into(),
        facet_label(pool, query).await?,
    );
    facets.insert(
        FocusFacet::Tag.as_str().into(),
        facet_tag(pool, query).await?,
    );
    facets.insert(
        FocusFacet::Inspector.as_str().into(),
        facet_inspector(pool, query).await?,
    );
    facets.insert(
        FocusFacet::Preference.as_str().into(),
        facet_preference(pool, query).await?,
    );

    Ok(FocusFacetsResponse {
        total_matched,
        facets,
        year_range,
    })
}

/// Pushes a CTE `base(entity_id, album_id, artist_id, version_id, release_year, added_at, preference)`.
pub(super) fn push_base_cte<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    query: &'a FocusQuery,
    omit: Option<FocusFacet>,
    include_recursive_keyword: bool,
) {
    qb.push(if include_recursive_keyword {
        "WITH RECURSIVE "
    } else {
        "WITH "
    });

    match query.entity {
        FocusEntity::Albums if !query.include_hidden => {
            let scope = FocusCompileScope::for_albums(false);
            qb.push(
                "base AS ( \
                    SELECT ca.id AS entity_id, ca.id AS album_id, ca.primary_artist_id AS artist_id, \
                           NULL AS version_id, ca.release_year, ca.created_at AS added_at, \
                           ca.preference AS preference \
                    FROM canonical_albums ca \
                    LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
                    WHERE EXISTS ( \
                        SELECT 1 FROM album_versions av0 \
                        JOIN track_sources ts0 ON ts0.version_id = av0.id AND ts0.file_status = 'present' AND ts0.is_hidden = 0 \
                        WHERE av0.canonical_album_id = ca.id AND av0.is_hidden = 0 \
                    )",
            );
            compile_focus_query_to_sql(qb, query, scope, omit);
            qb.push(") ");
        }
        FocusEntity::Albums => {
            let scope = FocusCompileScope::for_albums(true);
            qb.push(
                "base AS ( \
                    SELECT pv.id AS entity_id, ca.id AS album_id, ca.primary_artist_id AS artist_id, \
                           pv.id AS version_id, ca.release_year, ca.created_at AS added_at, \
                           ca.preference AS preference \
                    FROM album_versions pv \
                    JOIN canonical_albums ca ON ca.id = pv.canonical_album_id \
                    LEFT JOIN artists ar ON ar.id = ca.primary_artist_id \
                    WHERE EXISTS ( \
                        SELECT 1 FROM track_sources ts0 \
                        WHERE ts0.version_id = pv.id AND ts0.file_status = 'present' \
                    )",
            );
            compile_focus_query_to_sql(qb, query, scope, omit);
            qb.push(") ");
        }
        FocusEntity::Tracks => {
            let scope = FocusCompileScope::for_tracks(query.include_hidden);
            qb.push(
                "base AS ( \
                    SELECT trk.id AS entity_id, alb.id AS album_id, alb.primary_artist_id AS artist_id, \
                           ver.id AS version_id, alb.release_year, \
                           COALESCE(trk.added_at, alb.created_at) AS added_at, \
                           trk.preference AS preference \
                    FROM track_sources trk \
                    JOIN album_versions ver ON ver.id = trk.version_id \
                    JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
                    LEFT JOIN artists art ON art.id = alb.primary_artist_id \
                    WHERE trk.file_status = 'present'",
            );
            if !query.include_hidden {
                qb.push(" AND ver.is_hidden = 0 AND trk.is_hidden = 0");
            }
            compile_focus_query_to_sql(qb, query, scope, omit);
            qb.push(") ");
        }
    }
}

pub(super) fn push_base_tracks_join(qb: &mut QueryBuilder<'_, Sqlite>, query: &FocusQuery) {
    match query.entity {
        FocusEntity::Tracks => {
            qb.push("JOIN track_sources ts ON ts.id = base.entity_id ");
        }
        FocusEntity::Albums if query.include_hidden => {
            qb.push(
                "JOIN track_sources ts ON ts.version_id = base.version_id AND ts.file_status = 'present' ",
            );
        }
        FocusEntity::Albums => {
            qb.push(
                "JOIN album_versions av ON av.canonical_album_id = base.album_id AND av.is_hidden = 0 \
                 JOIN track_sources ts ON ts.version_id = av.id AND ts.file_status = 'present' AND ts.is_hidden = 0 ",
            );
        }
    }
}

async fn count_base(
    pool: &SqlitePool,
    query: &FocusQuery,
    omit: Option<FocusFacet>,
) -> Result<u64> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, omit, false);
    qb.push("SELECT COUNT(*) FROM base");
    let (cnt,): (i64,) = qb.build_query_as().fetch_one(pool).await?;
    Ok(cnt.max(0) as u64)
}

async fn facet_format(pool: &SqlitePool, query: &FocusQuery) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Format), false);
    qb.push(
        "SELECT CASE \
            WHEN ts.is_dsd = 1 OR LOWER(ts.codec) IN ('dsf', 'dsdiff', 'dsd') THEN \
                CASE \
                    WHEN ts.sample_rate_hz >= 22579200 THEN 'dsd512' \
                    WHEN ts.sample_rate_hz >= 11289600 THEN 'dsd256' \
                    WHEN ts.sample_rate_hz >= 5644800 THEN 'dsd128' \
                    ELSE 'dsd64' \
                END \
            ELSE LOWER(ts.codec) \
         END AS fmt, COUNT(DISTINCT base.entity_id) AS cnt FROM base ",
    );
    push_base_tracks_join(&mut qb, query);
    qb.push("GROUP BY fmt ORDER BY cnt DESC, fmt ASC");

    let rows: Vec<(String, i64)> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .filter(|(k, c)| !k.is_empty() && *c > 0)
        .map(|(k, c)| FocusFacetBucket {
            label: k.to_ascii_uppercase(),
            value: k,
            count: c as u64,
        })
        .collect())
}

async fn facet_bit_depth(pool: &SqlitePool, query: &FocusQuery) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::BitDepth), false);
    qb.push("SELECT ts.bit_depth, COUNT(DISTINCT base.entity_id) AS cnt FROM base ");
    push_base_tracks_join(&mut qb, query);
    qb.push("WHERE ts.bit_depth > 0 GROUP BY ts.bit_depth ORDER BY ts.bit_depth ASC");

    let rows: Vec<(i64, i64)> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .filter(|(_, c)| *c > 0)
        .map(|(bd, c)| FocusFacetBucket {
            value: bd.to_string(),
            label: if bd == 1 {
                "1-bit (DSD)".into()
            } else {
                format!("{bd}-bit")
            },
            count: c as u64,
        })
        .collect())
}

async fn facet_sample_rate(pool: &SqlitePool, query: &FocusQuery) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::SampleRate), false);
    qb.push("SELECT ts.sample_rate_hz, COUNT(DISTINCT base.entity_id) AS cnt FROM base ");
    push_base_tracks_join(&mut qb, query);
    qb.push(
        "WHERE ts.sample_rate_hz > 0 GROUP BY ts.sample_rate_hz ORDER BY ts.sample_rate_hz ASC",
    );

    let rows: Vec<(i64, i64)> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .filter(|(_, c)| *c > 0)
        .map(|(sr, c)| FocusFacetBucket {
            value: sr.to_string(),
            label: format_sample_rate_label(sr),
            count: c as u64,
        })
        .collect())
}

fn format_sample_rate_label(sr: i64) -> String {
    if sr >= 1_000_000 {
        format!("{:.1} MHz", sr as f64 / 1_000_000.0)
    } else if sr % 1000 == 0 {
        format!("{} kHz", sr / 1000)
    } else {
        format!("{:.1} kHz", sr as f64 / 1000.0)
    }
}

async fn facet_channels(pool: &SqlitePool, query: &FocusQuery) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Channels), false);
    qb.push("SELECT ts.channels, COUNT(DISTINCT base.entity_id) AS cnt FROM base ");
    push_base_tracks_join(&mut qb, query);
    qb.push("WHERE ts.channels > 0 GROUP BY ts.channels ORDER BY ts.channels ASC");

    let rows: Vec<(i64, i64)> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .filter(|(_, c)| *c > 0)
        .map(|(ch, c)| FocusFacetBucket {
            value: ch.to_string(),
            label: match ch {
                1 => "Mono (1.0)".into(),
                2 => "Stereo (2.0)".into(),
                6 => "5.1 Surround".into(),
                8 => "7.1 Surround".into(),
                n => format!("{n} ch"),
            },
            count: c as u64,
        })
        .collect())
}

async fn facet_source(pool: &SqlitePool, query: &FocusQuery) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Source), false);
    qb.push(
        "SELECT LOWER(ts.provider_id) AS prov, COUNT(DISTINCT base.entity_id) AS cnt FROM base ",
    );
    push_base_tracks_join(&mut qb, query);
    qb.push("GROUP BY prov ORDER BY cnt DESC, prov ASC");

    let rows: Vec<(String, i64)> = qb.build_query_as().fetch_all(pool).await?;
    let mut buckets: Vec<FocusFacetBucket> = rows
        .into_iter()
        .filter(|(p, c)| !p.is_empty() && *c > 0)
        .map(|(p, c)| FocusFacetBucket {
            label: format_provider_label(&p),
            value: p,
            count: c as u64,
        })
        .collect();

    let mut rqb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut rqb, query, Some(FocusFacet::Source), false);
    rqb.push("SELECT wr.id, wr.root_path, COUNT(DISTINCT base.entity_id) AS cnt FROM base ");
    push_base_tracks_join(&mut rqb, query);
    rqb.push(
        "JOIN library_folders lf ON lf.id = ts.folder_id \
         JOIN watched_roots wr ON wr.id = lf.root_id \
         GROUP BY wr.id, wr.root_path ORDER BY cnt DESC, wr.root_path ASC",
    );
    let root_rows: Vec<(String, String, i64)> = rqb.build_query_as().fetch_all(pool).await?;
    for (rid, rpath, c) in root_rows {
        if c > 0 {
            buckets.push(FocusFacetBucket {
                value: format!("root:{rid}"),
                label: rpath,
                count: c as u64,
            });
        }
    }
    Ok(buckets)
}

fn format_provider_label(raw: &str) -> String {
    match raw {
        "local" => "Local".into(),
        "smb" => "SMB".into(),
        "web_dav" | "webdav" => "WebDAV".into(),
        "qobuz" => "Qobuz".into(),
        "tidal" => "Tidal".into(),
        "deezer" => "Deezer".into(),
        "apple_music" | "applemusic" => "Apple Music".into(),
        "youtube_music" | "ytmusic" | "ytm" => "YouTube Music".into(),
        other => other.into(),
    }
}

async fn facet_release_year(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<(Vec<FocusFacetBucket>, FocusIntRangeBounds)> {
    let mut rqb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut rqb, query, Some(FocusFacet::ReleaseYear), false);
    rqb.push(
        "SELECT MIN(release_year), MAX(release_year) FROM base WHERE release_year IS NOT NULL",
    );
    let (min_yr, max_yr): (Option<i32>, Option<i32>) = rqb.build_query_as().fetch_one(pool).await?;

    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::ReleaseYear), false);
    qb.push(
        "SELECT (release_year / 10) * 10 AS decade, COUNT(*) AS cnt \
         FROM base WHERE release_year IS NOT NULL GROUP BY decade ORDER BY decade DESC",
    );
    let rows: Vec<(i64, i64)> = qb.build_query_as().fetch_all(pool).await?;
    let buckets = rows
        .into_iter()
        .filter(|(_, c)| *c > 0)
        .map(|(dec, c)| FocusFacetBucket {
            value: format!("{dec}s"),
            label: format!("{dec}s"),
            count: c as u64,
        })
        .collect();

    Ok((
        buckets,
        FocusIntRangeBounds {
            min: min_yr,
            max: max_yr,
        },
    ))
}

async fn facet_added_at(pool: &SqlitePool, query: &FocusQuery) -> Result<Vec<FocusFacetBucket>> {
    let now = Utc::now();
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::AddedAt), false);
    qb.push("SELECT ");
    for (idx, days) in [7, 30, 90, 365].into_iter().enumerate() {
        if idx > 0 {
            qb.push(", ");
        }
        qb.push("COALESCE(SUM(CASE WHEN added_at >= ");
        qb.push_bind((now - Duration::days(days)).to_rfc3339());
        qb.push(" THEN 1 ELSE 0 END), 0)");
    }
    qb.push(" FROM base");

    let (c7, c30, c90, c365): (i64, i64, i64, i64) = qb.build_query_as().fetch_one(pool).await?;
    Ok([
        ("7d", "Last 7 Days", c7),
        ("30d", "Last 30 Days", c30),
        ("90d", "Last 90 Days", c90),
        ("365d", "Last Year", c365),
    ]
    .into_iter()
    .filter(|(_, _, cnt)| *cnt > 0)
    .map(|(val, label, cnt)| FocusFacetBucket {
        value: val.into(),
        label: label.into(),
        count: cnt as u64,
    })
    .collect())
}
