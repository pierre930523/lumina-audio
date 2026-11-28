use core_types::{FocusEntity, FocusValue};
use sqlx::{QueryBuilder, Sqlite};

use super::compiler::{FocusCompileScope, push_album_tracks_exists, push_false};

pub(super) fn push_play_status_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
    profile_id: Option<&'a str>,
) {
    let FocusValue::String { value } = val else {
        return push_false(qb);
    };
    let want_played = match value.trim().to_ascii_lowercase().as_str() {
        "played" => true,
        "unplayed" => false,
        _ => return push_false(qb),
    };

    if !want_played {
        qb.push("NOT (");
    }
    match scope.entity {
        FocusEntity::Albums => {
            push_album_tracks_exists(
                qb,
                scope,
                Some("JOIN play_history ph_f ON ph_f.track_source_id = ts_f.id"),
                |q, _| {
                    if let Some(pid) = profile_id {
                        q.push("ph_f.profile_id = ");
                        q.push_bind(pid.to_string());
                    } else {
                        q.push("1 = 1");
                    }
                },
            );
        }
        FocusEntity::Tracks => {
            qb.push("EXISTS (SELECT 1 FROM play_history ph_f WHERE ph_f.track_source_id = trk.id");
            if let Some(pid) = profile_id {
                qb.push(" AND ph_f.profile_id = ");
                qb.push_bind(pid.to_string());
            }
            qb.push(")");
        }
    }
    if !want_played {
        qb.push(")");
    }
}

pub(super) fn push_genre_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let FocusValue::String { value } = val else {
        return push_false(qb);
    };
    let lower = value.trim().to_lowercase();
    if lower.is_empty() {
        return push_false(qb);
    }
    match scope.entity {
        FocusEntity::Albums => push_album_tracks_exists(qb, scope, None, |q, ts| {
            q.push(format!(
                "{ts}.genre IS NOT NULL AND LOWER(TRIM({ts}.genre)) = "
            ));
            q.push_bind(lower);
        }),
        FocusEntity::Tracks => {
            qb.push("COALESCE(trk.genre IS NOT NULL AND LOWER(TRIM(trk.genre)) = ");
            qb.push_bind(lower);
            qb.push(", 0)");
        }
    }
}

pub(super) fn push_label_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let FocusValue::String { value } = val else {
        return push_false(qb);
    };
    let lower = value.trim().to_lowercase();
    if lower.is_empty() {
        return push_false(qb);
    }
    match scope.entity {
        FocusEntity::Albums => push_album_tracks_exists(qb, scope, None, |q, ts| {
            q.push(format!(
                "LOWER(COALESCE(NULLIF(TRIM(ca.record_label), ''), NULLIF(TRIM({ts}.record_label), ''))) = "
            ));
            q.push_bind(lower);
        }),
        FocusEntity::Tracks => {
            qb.push(
                "COALESCE(LOWER(COALESCE(NULLIF(TRIM(alb.record_label), ''), NULLIF(TRIM(trk.record_label), ''))) = ",
            );
            qb.push_bind(lower);
            qb.push(", 0)");
        }
    }
}

pub(super) fn push_tag_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let FocusValue::String { value } = val else {
        return push_false(qb);
    };
    let tag_id = value.trim().to_string();
    if tag_id.is_empty() {
        return push_false(qb);
    }

    qb.push(
        "EXISTS (WITH RECURSIVE tag_tree(id) AS ( \
            SELECT id FROM tags WHERE id = ",
    );
    qb.push_bind(tag_id);
    qb.push(
        " UNION \
            SELECT tl.child_tag_id FROM tag_links tl JOIN tag_tree tt ON tl.parent_tag_id = tt.id \
         ) SELECT 1 FROM tag_items ti JOIN tag_tree tt ON tt.id = ti.tag_id WHERE ",
    );
    match scope.entity {
        FocusEntity::Albums => {
            qb.push(
                "(ti.entity_type = 'album_group' AND ti.entity_id = ca.id) \
                 OR (ca.primary_artist_id IS NOT NULL AND ti.entity_type = 'artist' AND ti.entity_id = ca.primary_artist_id)",
            );
        }
        FocusEntity::Tracks => {
            qb.push(
                "(ti.entity_type = 'track' AND ti.entity_id = trk.id) \
                 OR (ti.entity_type = 'album_group' AND ti.entity_id = alb.id) \
                 OR (alb.primary_artist_id IS NOT NULL AND ti.entity_type = 'artist' AND ti.entity_id = alb.primary_artist_id)",
            );
        }
    }
    qb.push(")");
}

pub(super) fn push_inspector_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let FocusValue::String { value } = val else {
        return push_false(qb);
    };
    let alb = match scope.entity {
        FocusEntity::Albums => "ca",
        FocusEntity::Tracks => "alb",
    };
    match value.trim().to_ascii_lowercase().as_str() {
        "has_duplicates" => {
            qb.push(format!(
                "(SELECT COUNT(DISTINCT av_d.id) \
                  FROM album_versions av_d \
                  JOIN track_sources ts_d ON ts_d.version_id = av_d.id AND ts_d.file_status = 'present' \
                  WHERE av_d.canonical_album_id = {alb}.id) > 1"
            ));
        }
        "missing_cover" => {
            qb.push(format!(
                "(({alb}.merged_cover_path IS NULL OR TRIM({alb}.merged_cover_path) = '') \
                  AND ({alb}.cover_url IS NULL OR TRIM({alb}.cover_url) = '') \
                  AND NOT EXISTS (SELECT 1 FROM artwork_cache ac_m WHERE ac_m.album_id = {alb}.id) \
                  AND NOT EXISTS (SELECT 1 FROM artwork_overrides ao_m WHERE ao_m.target_kind = 'album' AND ao_m.target_id = {alb}.id))"
            ));
        }
        "has_manual_edits" => match scope.entity {
            FocusEntity::Albums => {
                qb.push(
                    "((ca.user_edits_json IS NOT NULL AND TRIM(ca.user_edits_json) NOT IN ('', '{}', 'null')) \
                      OR ca.is_primary_locked = 1 \
                      OR EXISTS (SELECT 1 FROM album_versions av_m WHERE av_m.canonical_album_id = ca.id AND av_m.manual_group_id IS NOT NULL) \
                      OR EXISTS ( \
                          SELECT 1 FROM album_versions av_m \
                          JOIN track_sources ts_m ON ts_m.version_id = av_m.id AND ts_m.file_status = 'present' \
                          WHERE av_m.canonical_album_id = ca.id \
                            AND ((ts_m.user_edits_json IS NOT NULL AND TRIM(ts_m.user_edits_json) NOT IN ('', '{}', 'null')) \
                                 OR ts_m.manual_version_id IS NOT NULL \
                                 OR ts_m.manual_disc_number IS NOT NULL) \
                      ))",
                );
            }
            FocusEntity::Tracks => {
                qb.push(
                    "((trk.user_edits_json IS NOT NULL AND TRIM(trk.user_edits_json) NOT IN ('', '{}', 'null')) \
                      OR trk.manual_version_id IS NOT NULL \
                      OR trk.manual_disc_number IS NOT NULL \
                      OR (alb.user_edits_json IS NOT NULL AND TRIM(alb.user_edits_json) NOT IN ('', '{}', 'null')) \
                      OR alb.is_primary_locked = 1 \
                      OR ver.manual_group_id IS NOT NULL)",
                );
            }
        },
        _ => push_false(qb),
    }
}

pub(crate) fn parse_preference_value(val: &FocusValue) -> Option<i32> {
    match val {
        FocusValue::Int { value } => match *value {
            -1 => Some(-1),
            0 => Some(0),
            1 => Some(1),
            _ => None,
        },
        FocusValue::String { value } => match value.trim().to_ascii_lowercase().as_str() {
            "favorite" | "loved" | "1" => Some(1),
            "neutral" | "0" => Some(0),
            "banned" | "blocked" | "-1" => Some(-1),
            _ => None,
        },
        _ => None,
    }
}

pub(super) fn push_preference_pred<'a>(
    qb: &mut QueryBuilder<'a, Sqlite>,
    val: &FocusValue,
    scope: FocusCompileScope,
) {
    let Some(pref) = parse_preference_value(val) else {
        return push_false(qb);
    };
    let col = match scope.entity {
        FocusEntity::Albums => "ca.preference",
        FocusEntity::Tracks => "trk.preference",
    };
    qb.push(format!("COALESCE({col} = "));
    qb.push_bind(pref);
    qb.push(", 0)");
}
