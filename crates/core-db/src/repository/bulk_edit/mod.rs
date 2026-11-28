mod apply;
mod patch_ops;
mod post_ops;
mod summary;

use std::collections::HashSet;

use core_types::{
    BulkEditEntityType, BulkEditPatch, BulkEditResult, BulkEditSummary, TagEntityType,
};
use sqlx::SqlitePool;

use crate::error::{DbError, Result};

/// Non-destructive tri-state bulk metadata editor repository (Library Step 5).
///
/// Reads effective field values + custom tags into a tri-state summary and applies
/// partial patches atomically inside a single `DbWriteCoordinator` `BEGIN IMMEDIATE`
/// transaction, modifying ONLY `user_edits_json` / `meta_policy` / `tag_items`
/// while preserving `file_meta_json`, `cloud_meta_json`, and untouched `<Mixed>` fields.
pub struct BulkEditRepository;

impl BulkEditRepository {
    /// Computes tri-state field values, `meta_policy`, user-edit count, and tri-state
    /// custom tag assignments for the selected albums or tracks.
    pub async fn get_bulk_edit_summary(
        pool: &SqlitePool,
        entity_type: BulkEditEntityType,
        entity_ids: &[String],
    ) -> Result<BulkEditSummary> {
        summary::get_bulk_edit_summary_impl(pool, entity_type, entity_ids).await
    }

    /// Applies a partial bulk metadata + custom tag patch atomically inside a single
    /// `DbWriteCoordinator` `BEGIN IMMEDIATE` transaction, recomputes affected album
    /// groups, and prunes emptied orphan versions/albums.
    pub async fn apply_bulk_edit(
        pool: &SqlitePool,
        entity_type: BulkEditEntityType,
        entity_ids: &[String],
        patch: &BulkEditPatch,
    ) -> Result<BulkEditResult> {
        apply::apply_bulk_edit_impl(pool, entity_type, entity_ids, patch).await
    }
}

pub(super) fn dedup_non_empty_ids(raw_ids: &[String]) -> Vec<String> {
    let mut seen = HashSet::with_capacity(raw_ids.len());
    raw_ids
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty() && seen.insert((*s).to_string()))
        .map(str::to_string)
        .collect()
}

pub(super) fn validate_entity_ids(raw_ids: &[String]) -> Result<Vec<String>> {
    let ids = dedup_non_empty_ids(raw_ids);
    if ids.is_empty() {
        return Err(DbError::ConstraintViolation(
            "entity_ids must contain at least one non-empty ID".to_string(),
        ));
    }
    Ok(ids)
}

#[inline]
pub(super) const fn tag_entity_type_str(entity_type: BulkEditEntityType) -> &'static str {
    match entity_type {
        BulkEditEntityType::Album => TagEntityType::AlbumGroup.as_str(),
        BulkEditEntityType::Track => TagEntityType::Track.as_str(),
    }
}
