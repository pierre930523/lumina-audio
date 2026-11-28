use core_types::{FocusEntity, FocusFacet, FocusFacetBucket, FocusQuery};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};

use super::facets::{push_base_cte, push_base_tracks_join};
use crate::error::Result;

pub(super) async fn facet_play_status(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<Vec<FocusFacetBucket>> {
    let profile_id = query
        .profile_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::PlayStatus), false);
    qb.push("SELECT CASE WHEN ");
    match query.entity {
        FocusEntity::Tracks => {
            qb.push(
                "EXISTS (SELECT 1 FROM play_history ph WHERE ph.track_source_id = base.entity_id",
            );
            if let Some(pid) = profile_id {
                qb.push(" AND ph.profile_id = ");
                qb.push_bind(pid.to_string());
            }
            qb.push(")");
        }
        FocusEntity::Albums if query.include_hidden => {
            qb.push(
                "EXISTS (SELECT 1 FROM track_sources ts \
                 JOIN play_history ph ON ph.track_source_id = ts.id \
                 WHERE ts.version_id = base.version_id AND ts.file_status = 'present'",
            );
            if let Some(pid) = profile_id {
                qb.push(" AND ph.profile_id = ");
                qb.push_bind(pid.to_string());
            }
            qb.push(")");
        }
        FocusEntity::Albums => {
            qb.push(
                "EXISTS (SELECT 1 FROM album_versions av \
                 JOIN track_sources ts ON ts.version_id = av.id AND ts.file_status = 'present' \
                 JOIN play_history ph ON ph.track_source_id = ts.id \
                 WHERE av.canonical_album_id = base.album_id AND av.is_hidden = 0",
            );
            if let Some(pid) = profile_id {
                qb.push(" AND ph.profile_id = ");
                qb.push_bind(pid.to_string());
            }
            qb.push(")");
        }
    }
    qb.push(
        " THEN 'played' ELSE 'unplayed' END AS status, COUNT(*) AS cnt FROM base GROUP BY status",
    );

    let rows: Vec<(String, i64)> = qb.build_query_as().fetch_all(pool).await?;
    let mut out: Vec<FocusFacetBucket> = rows
        .into_iter()
        .filter(|(_, c)| *c > 0)
        .map(|(st, c)| FocusFacetBucket {
            label: if st == "played" {
                "Played".into()
            } else {
                "Unplayed".into()
            },
            value: st,
            count: c as u64,
        })
        .collect();
    out.sort_by(|a, b| a.value.cmp(&b.value));
    Ok(out)
}

pub(super) async fn facet_genre(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Genre), false);
    qb.push(
        "SELECT LOWER(TRIM(ts.genre)) AS key, MIN(TRIM(ts.genre)) AS label, \
         COUNT(DISTINCT base.entity_id) AS cnt FROM base ",
    );
    push_base_tracks_join(&mut qb, query);
    qb.push(
        "WHERE ts.genre IS NOT NULL AND TRIM(ts.genre) != '' \
         GROUP BY key ORDER BY cnt DESC, label ASC",
    );

    let rows: Vec<(String, String, i64)> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .filter(|(_, _, c)| *c > 0)
        .map(|(k, l, c)| FocusFacetBucket {
            value: k,
            label: l,
            count: c as u64,
        })
        .collect())
}

pub(super) async fn facet_label(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Label), false);
    qb.push(
        "SELECT LOWER(COALESCE(NULLIF(TRIM(ca_l.record_label), ''), NULLIF(TRIM(ts.record_label), ''))) AS key, \
                MIN(COALESCE(NULLIF(TRIM(ca_l.record_label), ''), NULLIF(TRIM(ts.record_label), ''))) AS label, \
                COUNT(DISTINCT base.entity_id) AS cnt \
         FROM base \
         JOIN canonical_albums ca_l ON ca_l.id = base.album_id ",
    );
    push_base_tracks_join(&mut qb, query);
    qb.push(
        "WHERE COALESCE(NULLIF(TRIM(ca_l.record_label), ''), NULLIF(TRIM(ts.record_label), '')) IS NOT NULL \
         GROUP BY key ORDER BY cnt DESC, label ASC",
    );

    let rows: Vec<(String, String, i64)> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .filter(|(_, _, c)| *c > 0)
        .map(|(k, l, c)| FocusFacetBucket {
            value: k,
            label: l,
            count: c as u64,
        })
        .collect())
}

pub(super) async fn facet_tag(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Tag), true);
    qb.push(
        ", tag_ancestors(ancestor_id, descendant_id) AS ( \
            SELECT id, id FROM tags \
            UNION \
            SELECT tl.parent_tag_id, ta.descendant_id \
            FROM tag_links tl \
            JOIN tag_ancestors ta ON tl.child_tag_id = ta.ancestor_id \
         ) \
         SELECT t.id, t.name, COUNT(DISTINCT base.entity_id) AS cnt \
         FROM tags t \
         JOIN tag_ancestors ta ON ta.ancestor_id = t.id \
         JOIN tag_items ti ON ti.tag_id = ta.descendant_id \
         JOIN base ON (",
    );
    match query.entity {
        FocusEntity::Albums => {
            qb.push(
                "(ti.entity_type = 'album_group' AND ti.entity_id = base.album_id) \
                 OR (base.artist_id IS NOT NULL AND ti.entity_type = 'artist' AND ti.entity_id = base.artist_id)",
            );
        }
        FocusEntity::Tracks => {
            qb.push(
                "(ti.entity_type = 'track' AND ti.entity_id = base.entity_id) \
                 OR (ti.entity_type = 'album_group' AND ti.entity_id = base.album_id) \
                 OR (base.artist_id IS NOT NULL AND ti.entity_type = 'artist' AND ti.entity_id = base.artist_id)",
            );
        }
    }
    qb.push(") GROUP BY t.id, t.name ORDER BY cnt DESC, t.name ASC");

    let rows: Vec<(String, String, i64)> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows
        .into_iter()
        .filter(|(_, _, c)| *c > 0)
        .map(|(id, name, c)| FocusFacetBucket {
            value: id,
            label: name,
            count: c as u64,
        })
        .collect())
}

pub(super) async fn facet_inspector(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Inspector), false);

    qb.push(
        "SELECT \
            COALESCE(SUM(CASE WHEN ( \
                SELECT COUNT(DISTINCT av_d.id) \
                FROM album_versions av_d \
                JOIN track_sources ts_d ON ts_d.version_id = av_d.id AND ts_d.file_status = 'present' \
                WHERE av_d.canonical_album_id = base.album_id \
            ) > 1 THEN 1 ELSE 0 END), 0), \
            COALESCE(SUM(CASE WHEN ( \
                (ca_i.merged_cover_path IS NULL OR TRIM(ca_i.merged_cover_path) = '') \
                AND (ca_i.cover_url IS NULL OR TRIM(ca_i.cover_url) = '') \
                AND NOT EXISTS (SELECT 1 FROM artwork_cache ac_i WHERE ac_i.album_id = ca_i.id) \
                AND NOT EXISTS (SELECT 1 FROM artwork_overrides ao_i WHERE ao_i.target_kind = 'album' AND ao_i.target_id = ca_i.id) \
            ) THEN 1 ELSE 0 END), 0), \
            COALESCE(SUM(CASE WHEN (",
    );
    match query.entity {
        FocusEntity::Albums => {
            qb.push(
                "(ca_i.user_edits_json IS NOT NULL AND TRIM(ca_i.user_edits_json) NOT IN ('', '{}', 'null')) \
                 OR ca_i.is_primary_locked = 1 \
                 OR EXISTS (SELECT 1 FROM album_versions av_m WHERE av_m.canonical_album_id = ca_i.id AND av_m.manual_group_id IS NOT NULL) \
                 OR EXISTS ( \
                     SELECT 1 FROM album_versions av_m \
                     JOIN track_sources ts_m ON ts_m.version_id = av_m.id AND ts_m.file_status = 'present' \
                     WHERE av_m.canonical_album_id = ca_i.id \
                       AND ((ts_m.user_edits_json IS NOT NULL AND TRIM(ts_m.user_edits_json) NOT IN ('', '{}', 'null')) \
                            OR ts_m.manual_version_id IS NOT NULL \
                            OR ts_m.manual_disc_number IS NOT NULL) \
                 )",
            );
        }
        FocusEntity::Tracks => {
            qb.push(
                "(trk_i.user_edits_json IS NOT NULL AND TRIM(trk_i.user_edits_json) NOT IN ('', '{}', 'null')) \
                 OR trk_i.manual_version_id IS NOT NULL \
                 OR trk_i.manual_disc_number IS NOT NULL \
                 OR (ca_i.user_edits_json IS NOT NULL AND TRIM(ca_i.user_edits_json) NOT IN ('', '{}', 'null')) \
                 OR ca_i.is_primary_locked = 1 \
                 OR ver_i.manual_group_id IS NOT NULL",
            );
        }
    }
    qb.push(
        ") THEN 1 ELSE 0 END), 0) FROM base JOIN canonical_albums ca_i ON ca_i.id = base.album_id ",
    );
    if query.entity == FocusEntity::Tracks {
        qb.push(
            "JOIN track_sources trk_i ON trk_i.id = base.entity_id \
             JOIN album_versions ver_i ON ver_i.id = trk_i.version_id ",
        );
    }

    let (dups, no_cover, manual): (i64, i64, i64) = qb.build_query_as().fetch_one(pool).await?;
    Ok([
        ("has_duplicates", "Has Duplicates", dups),
        ("missing_cover", "Missing Cover", no_cover),
        ("has_manual_edits", "Manual Edits", manual),
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

pub(super) async fn facet_preference(
    pool: &SqlitePool,
    query: &FocusQuery,
) -> Result<Vec<FocusFacetBucket>> {
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new("");
    push_base_cte(&mut qb, query, Some(FocusFacet::Preference), false);
    qb.push("SELECT preference, COUNT(*) AS cnt FROM base GROUP BY preference");

    let rows: Vec<(i32, i64)> = qb.build_query_as().fetch_all(pool).await?;
    let mut fav = 0i64;
    let mut neutral = 0i64;
    let mut banned = 0i64;
    for (pref, cnt) in rows {
        match pref {
            1 => fav += cnt,
            0 => neutral += cnt,
            -1 => banned += cnt,
            _ => {}
        }
    }

    Ok([
        ("favorite", "Favorite", fav),
        ("neutral", "Neutral", neutral),
        ("banned", "Banned", banned),
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
