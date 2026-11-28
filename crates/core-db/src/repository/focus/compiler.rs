use chrono::{Duration, Utc};
use core_types::{
    FocusEntity, FocusFacet, FocusPredicate, FocusPredicateMode, FocusQuery, FocusValue,
};
use sqlx::{QueryBuilder, Sqlite};
use std::collections::BTreeMap;

use super::compiler_meta::{
    push_genre_pred, push_inspector_pred, push_label_pred, push_play_status_pred,
    push_preference_pred, push_tag_pred,
};

/// Describes the SQL table aliases exposed by the caller's outer query so
/// `compile_focus_query_to_sql` can emit parameterized `WHERE` clauses cleanly.
#[derive(Debug, Clone, Copy)]
pub struct FocusCompileScope {
    pub entity: FocusEntity,
    pub include_hidden: bool,
    /// When `entity == Albums` and `include_hidden == true`, points to the specific
    /// `album_versions` alias (e.g. `"pv"`). Otherwise `None` (group-level over `ca`).
    pub version_alias: Option<&'static str>,
}

impl FocusCompileScope {
    pub fn for_albums(include_hidden: bool) -> Self {
        Self {
            entity: FocusEntity::Albums,
            include_hidden,
            version_alias: if include_hidden { Some("pv") } else { None },
        }
    }

    pub fn for_tracks(include_hidden: bool) -> Self {
        Self {
            entity: FocusEntity::Tracks,
            include_hidden,
            version_alias: None,
        }
    }
}

/// Appends parameterized `AND (...)` predicates for `query` onto `qb`.
///
/// Boolean rules:
/// - Cross-facet: `AND`
/// - Same-facet `Include`: `OR`
/// - Any `Exclude`: `AND NOT (...)` (using `NOT EXISTS` for multi-valued relations)
/// - When `omit_includes_for == Some(facet)`, `Include` predicates for that facet are omitted
///   (while all other facets + all `Exclude` predicates stay active) for disjunctive cross-filtering.
pub fn compile_focus_query_to_sql<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    query: &'a FocusQuery,
    scope: FocusCompileScope,
    omit_includes_for: Option<FocusFacet>,
) {
    let profile_id = query
        .profile_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let mut grouped: BTreeMap<usize, (Vec<&'a FocusPredicate>, Vec<&'a FocusPredicate>)> =
        BTreeMap::new();

    for pred in &query.predicates {
        let key = facet_order_key(pred.facet);
        let entry = grouped.entry(key).or_default();
        match pred.mode {
            FocusPredicateMode::Include => {
                if omit_includes_for != Some(pred.facet) {
                    entry.0.push(pred);
                }
            }
            FocusPredicateMode::Exclude => entry.1.push(pred),
        }
    }

    for (_, (includes, excludes)) in grouped {
        if !includes.is_empty() {
            qb.push(" AND (");
            for (idx, pred) in includes.iter().enumerate() {
                if idx > 0 {
                    qb.push(" OR ");
                }
                push_single_predicate(qb, pred, scope, profile_id);
            }
            qb.push(")");
        }

        for exc in excludes {
            qb.push(" AND NOT (");
            push_single_predicate(qb, exc, scope, profile_id);
            qb.push(")");
        }
    }
}

fn facet_order_key(facet: FocusFacet) -> usize {
    FocusFacet::ALL
        .iter()
        .position(|f| *f == facet)
        .unwrap_or(0)
}

fn push_single_predicate<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    pred: &'a FocusPredicate,
    scope: FocusCompileScope,
    profile_id: Option<&'a str>,
) {
    match pred.facet {
        FocusFacet::Format => push_format_pred(qb, &pred.value, scope),
        FocusFacet::BitDepth => push_int_col_pred(qb, &pred.value, scope, "bit_depth"),
        FocusFacet::SampleRate => push_int_col_pred(qb, &pred.value, scope, "sample_rate_hz"),
        FocusFacet::Channels => push_channels_pred(qb, &pred.value, scope),
        FocusFacet::Source => push_source_pred(qb, &pred.value, scope),
        FocusFacet::ReleaseYear => push_release_year_pred(qb, &pred.value, scope),
        FocusFacet::AddedAt => push_added_at_pred(qb, &pred.value, scope),
        FocusFacet::PlayStatus => push_play_status_pred(qb, &pred.value, scope, profile_id),
        FocusFacet::Genre => push_genre_pred(qb, &pred.value, scope),
        FocusFacet::Label => push_label_pred(qb, &pred.value, scope),
        FocusFacet::Tag => push_tag_pred(qb, &pred.value, scope),
        FocusFacet::Inspector => push_inspector_pred(qb, &pred.value, scope),
        FocusFacet::Preference => push_preference_pred(qb, &pred.value, scope),
    }
}

pub(super) fn push_album_tracks_exists<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    scope: FocusCompileScope,
    extra_join: Option<&'static str>,
    push_cond: impl FnOnce(&mut QueryBuilder<'a, Sqlite>, &'static str),
) {
    qb.push(
        "EXISTS (SELECT 1 FROM album_versions av_f \
         JOIN track_sources ts_f ON ts_f.version_id = av_f.id AND ts_f.file_status = 'present'",
    );
    if let Some(j) = extra_join {
        qb.push(" ");
        qb.push(j);
    }
    if let Some(ver_alias) = scope.version_alias {
        qb.push(" WHERE av_f.id = ");
        qb.push(ver_alias);
        qb.push(".id AND (");
    } else {
        qb.push(" WHERE av_f.canonical_album_id = ca.id");
        if !scope.include_hidden {
            qb.push(" AND av_f.is_hidden = 0");
        }
        qb.push(" AND (");
    }
    push_cond(qb, "ts_f");
    qb.push("))");
}

pub(super) fn push_false(qb: &mut QueryBuilder<'_, Sqlite>) {
    qb.push("1 = 0");
}

fn push_format_cond<'a>(qb: &mut QueryBuilder<'a, Sqlite>, val: &FocusValue, ts: &'static str) {
    let FocusValue::String { value } = val else {
        return push_false(qb);
    };
    let raw = value.trim().to_ascii_lowercase();
    if raw.is_empty() {
        return push_false(qb);
    }
    let dsd = format!("({ts}.is_dsd = 1 OR LOWER({ts}.codec) IN ('dsf', 'dsdiff', 'dsd'))");
    let lossless =
        "('flac','alac','wav','aiff','aif','ape','wv','wavpack','pcm','dsf','dsdiff','dsd')";
    match raw.as_str() {
        "dsd" => {
            qb.push(dsd);
        }
        "dsd64" => {
            qb.push(format!("({dsd} AND {ts}.sample_rate_hz < 5644800)"));
        }
        "dsd128" => {
            qb.push(format!(
                "({dsd} AND {ts}.sample_rate_hz >= 5644800 AND {ts}.sample_rate_hz < 11289600)"
            ));
        }
        "dsd256" => {
            qb.push(format!(
                "({dsd} AND {ts}.sample_rate_hz >= 11289600 AND {ts}.sample_rate_hz < 22579200)"
            ));
        }
        "dsd512" => {
            qb.push(format!("({dsd} AND {ts}.sample_rate_hz >= 22579200)"));
        }
        "lossless" => {
            qb.push(format!(
                "({ts}.is_dsd = 1 OR LOWER({ts}.codec) IN {lossless})"
            ));
        }
        "lossy" => {
            qb.push(format!(
                "({ts}.is_dsd = 0 AND LOWER({ts}.codec) NOT IN {lossless})"
            ));
        }
        "hires" | "hi_res" => {
            qb.push(format!(
                "({ts}.is_dsd = 1 OR (LOWER({ts}.codec) IN ('flac','alac','wav','aiff','aif','ape','wv','wavpack','pcm') AND ({ts}.bit_depth >= 24 OR {ts}.sample_rate_hz > 48000)))"
            ));
        }
        _ => {
            qb.push(format!("LOWER({ts}.codec) = "));
            qb.push_bind(raw);
        }
    }
}

fn push_format_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    match scope.entity {
        FocusEntity::Albums => {
            push_album_tracks_exists(qb, scope, None, |q, ts| push_format_cond(q, val, ts));
        }
        FocusEntity::Tracks => push_format_cond(qb, val, "trk"),
    }
}

fn push_int_expr<'a>(qb: &mut QueryBuilder<'a, Sqlite>, val: &FocusValue, col_expr: &str) {
    match val {
        FocusValue::Int { value } => {
            qb.push(format!("COALESCE({col_expr} = "));
            qb.push_bind(*value);
            qb.push(", 0)");
        }
        FocusValue::String { value } => match value.trim().parse::<i64>() {
            Ok(parsed) => {
                qb.push(format!("COALESCE({col_expr} = "));
                qb.push_bind(parsed);
                qb.push(", 0)");
            }
            Err(_) => push_false(qb),
        },
        FocusValue::IntRange { min, max } => match (min, max) {
            (Some(lo), Some(hi)) => {
                qb.push(format!("COALESCE(({col_expr} >= "));
                qb.push_bind(*lo);
                qb.push(format!(" AND {col_expr} <= "));
                qb.push_bind(*hi);
                qb.push("), 0)");
            }
            (Some(lo), None) => {
                qb.push(format!("COALESCE({col_expr} >= "));
                qb.push_bind(*lo);
                qb.push(", 0)");
            }
            (None, Some(hi)) => {
                qb.push(format!("COALESCE({col_expr} <= "));
                qb.push_bind(*hi);
                qb.push(", 0)");
            }
            (None, None) => {
                qb.push(format!("({col_expr} IS NOT NULL)"));
            }
        },
        FocusValue::DateRange { .. } => push_false(qb),
    }
}

fn push_int_col_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
    col: &'static str,
) {
    match scope.entity {
        FocusEntity::Albums => push_album_tracks_exists(qb, scope, None, |q, ts| {
            push_int_expr(q, val, &format!("{ts}.{col}"));
        }),
        FocusEntity::Tracks => push_int_expr(qb, val, &format!("trk.{col}")),
    }
}

fn push_channels_cond<'a>(qb: &mut QueryBuilder<'a, Sqlite>, val: &FocusValue, ts: &'static str) {
    if let FocusValue::String { value } = val {
        match value.trim().to_ascii_lowercase().as_str() {
            "mono" => {
                qb.push(format!("{ts}.channels = 1"));
                return;
            }
            "stereo" => {
                qb.push(format!("{ts}.channels = 2"));
                return;
            }
            "multichannel" | "surround" => {
                qb.push(format!("{ts}.channels > 2"));
                return;
            }
            _ => {}
        }
    }
    push_int_expr(qb, val, &format!("{ts}.channels"));
}

fn push_channels_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    match scope.entity {
        FocusEntity::Albums => {
            push_album_tracks_exists(qb, scope, None, |q, ts| push_channels_cond(q, val, ts));
        }
        FocusEntity::Tracks => push_channels_cond(qb, val, "trk"),
    }
}

fn push_source_cond<'a>(qb: &mut QueryBuilder<'a, Sqlite>, raw: &str, ts: &'static str) {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return push_false(qb);
    }
    if let Some(root_id) = trimmed
        .strip_prefix("root:")
        .or_else(|| trimmed.strip_prefix("ROOT:"))
    {
        let rid = root_id.trim().to_string();
        if rid.is_empty() {
            return push_false(qb);
        }
        qb.push(format!(
            "EXISTS (SELECT 1 FROM library_folders lf_s WHERE lf_s.id = {ts}.folder_id AND lf_s.root_id = "
        ));
        qb.push_bind(rid);
        qb.push(")");
        return;
    }

    let lower = trimmed.to_ascii_lowercase();
    match lower.as_str() {
        "ytmusic" | "youtube_music" | "ytm" => {
            qb.push(format!(
                "LOWER({ts}.provider_id) IN ('ytmusic', 'youtube_music', 'ytm')"
            ));
        }
        "webdav" | "web_dav" => {
            qb.push(format!("LOWER({ts}.provider_id) IN ('webdav', 'web_dav')"));
        }
        "apple_music" | "applemusic" => {
            qb.push(format!(
                "LOWER({ts}.provider_id) IN ('apple_music', 'applemusic')"
            ));
        }
        _ => {
            qb.push(format!("LOWER({ts}.provider_id) = "));
            qb.push_bind(lower);
        }
    }
}

fn push_source_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let FocusValue::String { value } = val else {
        return push_false(qb);
    };
    match scope.entity {
        FocusEntity::Albums => {
            push_album_tracks_exists(qb, scope, None, |q, ts| push_source_cond(q, value, ts));
        }
        FocusEntity::Tracks => push_source_cond(qb, value, "trk"),
    }
}

fn push_release_year_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let col = match scope.entity {
        FocusEntity::Albums => "ca.release_year",
        FocusEntity::Tracks => "alb.release_year",
    };
    if let FocusValue::String { value } = val {
        let t = value.trim().to_ascii_lowercase();
        if let Some(dec_str) = t.strip_suffix('s')
            && let Ok(dec) = dec_str.parse::<i64>()
        {
            let range = FocusValue::IntRange {
                min: Some(dec),
                max: Some(dec + 9),
            };
            push_int_expr(qb, &range, col);
            return;
        }
    }
    push_int_expr(qb, val, col);
}

fn push_added_at_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let expr = match scope.entity {
        FocusEntity::Albums => "ca.created_at",
        FocusEntity::Tracks => "COALESCE(trk.added_at, alb.created_at)",
    };

    match val {
        FocusValue::DateRange { from, to } => {
            let from_clean = from.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let to_clean = to.as_deref().map(str::trim).filter(|s| !s.is_empty());
            match (from_clean, to_clean) {
                (Some(f), Some(t)) => {
                    qb.push(format!("COALESCE(({expr} >= "));
                    qb.push_bind(f.to_string());
                    qb.push(format!(" AND {expr} <= "));
                    qb.push_bind(normalize_date_upper_bound(t));
                    qb.push("), 0)");
                }
                (Some(f), None) => {
                    qb.push(format!("COALESCE({expr} >= "));
                    qb.push_bind(f.to_string());
                    qb.push(", 0)");
                }
                (None, Some(t)) => {
                    qb.push(format!("COALESCE({expr} <= "));
                    qb.push_bind(normalize_date_upper_bound(t));
                    qb.push(", 0)");
                }
                (None, None) => {
                    qb.push(format!("({expr} IS NOT NULL)"));
                }
            }
        }
        FocusValue::String { value } => {
            let days = match value.trim().to_ascii_lowercase().as_str() {
                "7d" | "last_7_days" => Some(7),
                "30d" | "last_30_days" => Some(30),
                "90d" | "last_90_days" => Some(90),
                "365d" | "1y" | "last_year" => Some(365),
                _ => None,
            };
            if let Some(d) = days {
                let cutoff = (Utc::now() - Duration::days(d)).to_rfc3339();
                qb.push(format!("COALESCE({expr} >= "));
                qb.push_bind(cutoff);
                qb.push(", 0)");
            } else {
                push_false(qb);
            }
        }
        _ => push_false(qb),
    }
}

fn normalize_date_upper_bound(raw: &str) -> String {
    if raw.len() == 10 && !raw.contains('T') && !raw.contains(' ') {
        format!("{raw}T23:59:59.999999Z")
    } else {
        raw.to_string()
    }
}
