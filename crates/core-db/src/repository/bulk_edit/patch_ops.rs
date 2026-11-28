use std::collections::BTreeMap;
use std::str::FromStr;

use core_types::{
    AlbumMetadataLayer, BulkEditEntityType, BulkEditPatch, FieldPatchOp, MetadataPolicy,
    TrackMetadataLayer,
};
use serde_json::Value;

use crate::error::{DbError, Result};

/// Parsed representation of `patch.meta_policy`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ParsedMetaPolicyOp {
    Keep,
    Set(MetadataPolicy),
}

pub(super) fn parse_meta_policy_op(op: &FieldPatchOp<String>) -> Result<ParsedMetaPolicyOp> {
    match op {
        FieldPatchOp::Keep => Ok(ParsedMetaPolicyOp::Keep),
        FieldPatchOp::Clear => Ok(ParsedMetaPolicyOp::Set(MetadataPolicy::Inherit)),
        FieldPatchOp::Set { value } => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                return Ok(ParsedMetaPolicyOp::Set(MetadataPolicy::Inherit));
            }
            let parsed = MetadataPolicy::from_str(trimmed).map_err(|_| {
                DbError::ConstraintViolation(format!(
                    "invalid meta_policy '{value}': expected 'inherit', 'file', or 'cloud'"
                ))
            })?;
            Ok(ParsedMetaPolicyOp::Set(parsed))
        }
    }
}

/// Validates all active (`Set`/`Clear`) field operations in `patch` before opening a transaction.
pub(super) fn validate_patch(
    entity_type: BulkEditEntityType,
    patch: &BulkEditPatch,
) -> Result<ParsedMetaPolicyOp> {
    let policy_op = parse_meta_policy_op(&patch.meta_policy)?;
    if patch.revert_to_file_meta {
        return Ok(policy_op);
    }

    match entity_type {
        BulkEditEntityType::Album => {
            let mut probe = AlbumMetadataLayer::default();
            let _ = apply_album_field_ops(&mut probe, &patch.fields)?;
        }
        BulkEditEntityType::Track => {
            let mut probe = TrackMetadataLayer::default();
            let _ = apply_track_field_ops(&mut probe, &patch.fields)?;
        }
    }

    Ok(policy_op)
}

pub(super) fn has_active_field_ops(fields: &BTreeMap<String, FieldPatchOp<Value>>) -> bool {
    fields.values().any(|op| !matches!(op, FieldPatchOp::Keep))
}

/// Applies ONLY `Set` and `Clear` field operations to an `AlbumMetadataLayer`.
/// Any key absent or set to `FieldPatchOp::Keep` is never touched.
/// Returns the canonical names of fields that were cleared (for legacy override cleanup).
pub(super) fn apply_album_field_ops(
    layer: &mut AlbumMetadataLayer,
    fields: &BTreeMap<String, FieldPatchOp<Value>>,
) -> Result<Vec<&'static str>> {
    let mut cleared = Vec::new();
    for (raw_key, op) in fields {
        if matches!(op, FieldPatchOp::Keep) {
            continue;
        }
        let key = raw_key.trim();
        match key {
            "title" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("title", value)?;
                    if v.is_none() {
                        cleared.push("title");
                    }
                    layer.title = v;
                }
                FieldPatchOp::Clear => {
                    layer.title = None;
                    cleared.push("title");
                }
                FieldPatchOp::Keep => {}
            },
            "sort_title" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("sort_title", value)?;
                    if v.is_none() {
                        cleared.push("sort_title");
                    }
                    layer.sort_title = v;
                }
                FieldPatchOp::Clear => {
                    layer.sort_title = None;
                    cleared.push("sort_title");
                }
                FieldPatchOp::Keep => {}
            },
            "album_artist" | "artist_name" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("album_artist", value)?;
                    if v.is_none() {
                        cleared.push("album_artist");
                        cleared.push("artist_name");
                    }
                    layer.album_artist = v;
                }
                FieldPatchOp::Clear => {
                    layer.album_artist = None;
                    cleared.push("album_artist");
                    cleared.push("artist_name");
                }
                FieldPatchOp::Keep => {}
            },
            "release_year" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_release_year(value)?;
                    if v.is_none() {
                        cleared.push("release_year");
                    }
                    layer.release_year = v;
                }
                FieldPatchOp::Clear => {
                    layer.release_year = None;
                    cleared.push("release_year");
                }
                FieldPatchOp::Keep => {}
            },
            "upc" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("upc", value)?;
                    if v.is_none() {
                        cleared.push("upc");
                    }
                    layer.upc = v;
                }
                FieldPatchOp::Clear => {
                    layer.upc = None;
                    cleared.push("upc");
                }
                FieldPatchOp::Keep => {}
            },
            "musicbrainz_release_group_id" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("musicbrainz_release_group_id", value)?;
                    if v.is_none() {
                        cleared.push("musicbrainz_release_group_id");
                    }
                    layer.musicbrainz_release_group_id = v;
                }
                FieldPatchOp::Clear => {
                    layer.musicbrainz_release_group_id = None;
                    cleared.push("musicbrainz_release_group_id");
                }
                FieldPatchOp::Keep => {}
            },
            "editorial_bio" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("editorial_bio", value)?;
                    if v.is_none() {
                        cleared.push("editorial_bio");
                    }
                    layer.editorial_bio = v;
                }
                FieldPatchOp::Clear => {
                    layer.editorial_bio = None;
                    cleared.push("editorial_bio");
                }
                FieldPatchOp::Keep => {}
            },
            "cover_url" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("cover_url", value)?;
                    if v.is_none() {
                        cleared.push("cover_url");
                    }
                    layer.cover_url = v;
                }
                FieldPatchOp::Clear => {
                    layer.cover_url = None;
                    cleared.push("cover_url");
                }
                FieldPatchOp::Keep => {}
            },
            "merged_cover_path" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_opt_string("merged_cover_path", value)?;
                    if v.is_none() {
                        cleared.push("merged_cover_path");
                    }
                    layer.merged_cover_path = v;
                }
                FieldPatchOp::Clear => {
                    layer.merged_cover_path = None;
                    cleared.push("merged_cover_path");
                }
                FieldPatchOp::Keep => {}
            },
            _ => {
                return Err(DbError::ConstraintViolation(format!(
                    "unsupported album bulk edit field '{key}'"
                )));
            }
        }
    }
    Ok(cleared)
}

/// Applies ONLY `Set` and `Clear` field operations to a `TrackMetadataLayer`.
/// Any key absent or set to `FieldPatchOp::Keep` is never touched.
/// Returns the canonical names of fields that were cleared (for legacy override cleanup).
pub(super) fn apply_track_field_ops(
    layer: &mut TrackMetadataLayer,
    fields: &BTreeMap<String, FieldPatchOp<Value>>,
) -> Result<Vec<&'static str>> {
    let mut cleared = Vec::new();
    for (raw_key, op) in fields {
        if matches!(op, FieldPatchOp::Keep) {
            continue;
        }
        let key = raw_key.trim();
        match key {
            "title" => apply_track_str(&mut layer.title, "title", op, &mut cleared)?,
            "artist_name" => {
                apply_track_str(&mut layer.artist_name, "artist_name", op, &mut cleared)?
            }
            "album_artist" => {
                apply_track_str(&mut layer.album_artist, "album_artist", op, &mut cleared)?
            }
            "album_title" => {
                apply_track_str(&mut layer.album_title, "album_title", op, &mut cleared)?
            }
            "genre" => apply_track_str(&mut layer.genre, "genre", op, &mut cleared)?,
            "composer" => apply_track_str(&mut layer.composer, "composer", op, &mut cleared)?,
            "isrc" => apply_track_str(&mut layer.isrc, "isrc", op, &mut cleared)?,
            "lyrics" => apply_track_str(&mut layer.lyrics, "lyrics", op, &mut cleared)?,
            "release_year" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_release_year(value)?;
                    if v.is_none() {
                        cleared.push("release_year");
                    }
                    layer.release_year = v;
                }
                FieldPatchOp::Clear => {
                    layer.release_year = None;
                    cleared.push("release_year");
                }
                FieldPatchOp::Keep => {}
            },
            "disc_number" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_positive_u16("disc_number", value)?;
                    if v.is_none() {
                        cleared.push("disc_number");
                    }
                    layer.disc_number = v;
                }
                FieldPatchOp::Clear => {
                    layer.disc_number = None;
                    cleared.push("disc_number");
                }
                FieldPatchOp::Keep => {}
            },
            "track_number" => match op {
                FieldPatchOp::Set { value } => {
                    let v = parse_positive_u16("track_number", value)?;
                    if v.is_none() {
                        cleared.push("track_number");
                    }
                    layer.track_number = v;
                }
                FieldPatchOp::Clear => {
                    layer.track_number = None;
                    cleared.push("track_number");
                }
                FieldPatchOp::Keep => {}
            },
            _ => {
                return Err(DbError::ConstraintViolation(format!(
                    "unsupported track bulk edit field '{key}'"
                )));
            }
        }
    }
    Ok(cleared)
}

fn apply_track_str(
    slot: &mut Option<String>,
    field_name: &'static str,
    op: &FieldPatchOp<Value>,
    cleared: &mut Vec<&'static str>,
) -> Result<()> {
    match op {
        FieldPatchOp::Set { value } => {
            let v = parse_opt_string(field_name, value)?;
            if v.is_none() {
                cleared.push(field_name);
            }
            *slot = v;
        }
        FieldPatchOp::Clear => {
            *slot = None;
            cleared.push(field_name);
        }
        FieldPatchOp::Keep => {}
    }
    Ok(())
}

fn parse_opt_string(field: &str, value: &Value) -> Result<Option<String>> {
    match value {
        Value::Null => Ok(None),
        Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(trimmed.to_string()))
            }
        }
        _ => Err(DbError::ConstraintViolation(format!(
            "field '{field}' expects a string value"
        ))),
    }
}

fn parse_release_year(value: &Value) -> Result<Option<i32>> {
    let parsed: Option<i64> = match value {
        Value::Null => None,
        Value::Number(n) => Some(n.as_i64().ok_or_else(|| {
            DbError::ConstraintViolation("field 'release_year' expects an integer".to_string())
        })?),
        Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.parse::<i64>().map_err(|_| {
                    DbError::ConstraintViolation(format!(
                        "field 'release_year' has invalid integer '{trimmed}'"
                    ))
                })?)
            }
        }
        _ => {
            return Err(DbError::ConstraintViolation(
                "field 'release_year' expects an integer".to_string(),
            ));
        }
    };

    match parsed {
        None => Ok(None),
        Some(yr) if (1000..=3000).contains(&yr) => Ok(Some(yr as i32)),
        Some(yr) => Err(DbError::ConstraintViolation(format!(
            "field 'release_year' must be between 1000 and 3000 (got {yr})"
        ))),
    }
}

fn parse_positive_u16(field: &str, value: &Value) -> Result<Option<u16>> {
    let parsed: Option<i64> = match value {
        Value::Null => None,
        Value::Number(n) => Some(n.as_i64().ok_or_else(|| {
            DbError::ConstraintViolation(format!("field '{field}' expects a positive integer"))
        })?),
        Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.parse::<i64>().map_err(|_| {
                    DbError::ConstraintViolation(format!(
                        "field '{field}' has invalid integer '{trimmed}'"
                    ))
                })?)
            }
        }
        _ => {
            return Err(DbError::ConstraintViolation(format!(
                "field '{field}' expects a positive integer"
            )));
        }
    };

    match parsed {
        None => Ok(None),
        Some(v) if v >= 1 && v <= i64::from(u16::MAX) => Ok(Some(v as u16)),
        Some(v) => Err(DbError::ConstraintViolation(format!(
            "field '{field}' must be between 1 and {} (got {v})",
            u16::MAX
        ))),
    }
}
