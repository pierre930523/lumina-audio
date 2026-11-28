use std::collections::HashSet;

use core_types::{
    AlbumMetadataLayer, BulkEditEntityType, BulkEditPatch, BulkEditResult, TrackMetadataLayer,
};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};

use super::patch_ops::{
    ParsedMetaPolicyOp, apply_album_field_ops, apply_track_field_ops, has_active_field_ops,
    validate_patch,
};
use super::post_ops::{
    apply_custom_tags_tx, prune_vacated_orphans_tx, recompute_affected_groups_tx,
};
use super::validate_entity_ids;
use crate::error::Result;
use crate::repository::LibraryRepository;
use crate::write_coordinator::DbWriteCoordinator;

#[derive(Debug, sqlx::FromRow)]
struct AlbumEditTargetRow {
    id: String,
    user_edits_json: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct TrackEditTargetRow {
    id: String,
    version_id: String,
    canonical_album_id: String,
    user_edits_json: Option<String>,
}

pub(super) async fn apply_bulk_edit_impl(
    pool: &SqlitePool,
    entity_type: BulkEditEntityType,
    entity_ids: &[String],
    patch: &BulkEditPatch,
) -> Result<BulkEditResult> {
    let ids = validate_entity_ids(entity_ids)?;
    let policy_op = validate_patch(entity_type, patch)?;

    let coord = DbWriteCoordinator::for_pool(pool);
    let (_guard, mut tx) = coord.begin_immediate(pool).await?;
    let res = apply_bulk_edit_tx(tx.conn(), entity_type, &ids, patch, policy_op).await;
    match res {
        Ok(result) => {
            tx.commit().await?;
            Ok(result)
        }
        Err(err) => {
            let _ = tx.rollback().await;
            Err(err)
        }
    }
}

async fn apply_bulk_edit_tx(
    conn: &mut SqliteConnection,
    entity_type: BulkEditEntityType,
    entity_ids: &[String],
    patch: &BulkEditPatch,
    policy_op: ParsedMetaPolicyOp,
) -> Result<BulkEditResult> {
    let default_policy = LibraryRepository::get_default_metadata_policy_tx(conn).await?;
    let has_field_ops = has_active_field_ops(&patch.fields);
    let mutates_metadata = patch.revert_to_file_meta
        || has_field_ops
        || !matches!(policy_op, ParsedMetaPolicyOp::Keep);

    let mut updated_count = 0usize;
    let mut reverted_count = 0usize;
    let mut affected_groups: HashSet<String> = HashSet::new();
    let mut vacated_version_ids: HashSet<String> = HashSet::new();
    let mut vacated_album_ids: HashSet<String> = HashSet::new();

    let valid_ids = match entity_type {
        BulkEditEntityType::Album => {
            let targets = load_album_targets_tx(conn, entity_ids).await?;
            let valid: Vec<String> = targets.iter().map(|r| r.id.clone()).collect();
            for target in targets {
                affected_groups.insert(target.id.clone());
                if !mutates_metadata {
                    continue;
                }
                if let ParsedMetaPolicyOp::Set(policy) = policy_op {
                    sqlx::query("UPDATE canonical_albums SET meta_policy = ? WHERE id = ?")
                        .bind(policy.as_str())
                        .bind(&target.id)
                        .execute(&mut *conn)
                        .await?;
                }
                if patch.revert_to_file_meta {
                    if LibraryRepository::revert_entity_to_file_meta_tx(conn, "album", &target.id)
                        .await?
                    {
                        reverted_count += 1;
                        updated_count += 1;
                    }
                } else {
                    if has_field_ops {
                        let mut layer =
                            AlbumMetadataLayer::from_json_opt(target.user_edits_json.as_deref())
                                .unwrap_or_default();
                        let cleared = apply_album_field_ops(&mut layer, &patch.fields)?;
                        delete_cleared_legacy_overrides_tx(conn, "album", &target.id, &cleared)
                            .await?;
                        let next_json = layer.to_json_opt();
                        sqlx::query("UPDATE canonical_albums SET user_edits_json = ? WHERE id = ?")
                            .bind(&next_json)
                            .bind(&target.id)
                            .execute(&mut *conn)
                            .await?;
                    }
                    if LibraryRepository::recompute_album_effective_tx(
                        conn,
                        &target.id,
                        default_policy,
                    )
                    .await?
                    {
                        updated_count += 1;
                    }
                }
            }
            valid
        }
        BulkEditEntityType::Track => {
            let targets = load_track_targets_tx(conn, entity_ids).await?;
            let valid: Vec<String> = targets.iter().map(|r| r.id.clone()).collect();
            for target in targets {
                affected_groups.insert(target.canonical_album_id.clone());
                if !mutates_metadata {
                    continue;
                }
                if let ParsedMetaPolicyOp::Set(policy) = policy_op {
                    sqlx::query("UPDATE track_sources SET meta_policy = ? WHERE id = ?")
                        .bind(policy.as_str())
                        .bind(&target.id)
                        .execute(&mut *conn)
                        .await?;
                }
                if patch.revert_to_file_meta {
                    if LibraryRepository::revert_entity_to_file_meta_tx(conn, "track", &target.id)
                        .await?
                    {
                        reverted_count += 1;
                        updated_count += 1;
                    }
                } else {
                    if has_field_ops {
                        let mut layer =
                            TrackMetadataLayer::from_json_opt(target.user_edits_json.as_deref())
                                .unwrap_or_default();
                        let cleared = apply_track_field_ops(&mut layer, &patch.fields)?;
                        delete_cleared_legacy_overrides_tx(conn, "track", &target.id, &cleared)
                            .await?;
                        let next_json = layer.to_json_opt();
                        sqlx::query("UPDATE track_sources SET user_edits_json = ? WHERE id = ?")
                            .bind(&next_json)
                            .bind(&target.id)
                            .execute(&mut *conn)
                            .await?;
                    }
                    if LibraryRepository::recompute_track_effective_tx(
                        conn,
                        &target.id,
                        default_policy,
                    )
                    .await?
                    {
                        updated_count += 1;
                    }
                }

                let new_loc: Option<(String, String)> = sqlx::query_as(
                    "SELECT ts.version_id, av.canonical_album_id \
                     FROM track_sources ts \
                     JOIN album_versions av ON av.id = ts.version_id \
                     WHERE ts.id = ?",
                )
                .bind(&target.id)
                .fetch_optional(&mut *conn)
                .await?;
                if let Some((new_ver_id, new_album_id)) = new_loc {
                    affected_groups.insert(new_album_id.clone());
                    if new_ver_id != target.version_id {
                        vacated_version_ids.insert(target.version_id);
                    }
                    if new_album_id != target.canonical_album_id {
                        vacated_album_ids.insert(target.canonical_album_id);
                    }
                }
            }
            valid
        }
    };

    let (tags_added, tags_removed) =
        apply_custom_tags_tx(conn, entity_type, &valid_ids, patch).await?;

    let (pruned_orphan_versions, pruned_orphan_albums) =
        prune_vacated_orphans_tx(conn, &vacated_version_ids, &vacated_album_ids).await?;

    let recomputed_groups = if mutates_metadata {
        recompute_affected_groups_tx(conn, &affected_groups).await?
    } else {
        0
    };

    Ok(BulkEditResult {
        entity_type,
        updated_count,
        reverted_count,
        tags_added,
        tags_removed,
        recomputed_groups,
        pruned_orphan_versions,
        pruned_orphan_albums,
    })
}

async fn load_album_targets_tx(
    conn: &mut SqliteConnection,
    entity_ids: &[String],
) -> Result<Vec<AlbumEditTargetRow>> {
    let mut rows = Vec::with_capacity(entity_ids.len());
    for chunk in entity_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> =
            QueryBuilder::new("SELECT id, user_edits_json FROM canonical_albums WHERE id IN (");
        let mut sep = qb.separated(", ");
        for id in chunk {
            sep.push_bind(id);
        }
        sep.push_unseparated(") ORDER BY id ASC");
        rows.extend(
            qb.build_query_as::<AlbumEditTargetRow>()
                .fetch_all(&mut *conn)
                .await?,
        );
    }
    rows.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(rows)
}

async fn load_track_targets_tx(
    conn: &mut SqliteConnection,
    entity_ids: &[String],
) -> Result<Vec<TrackEditTargetRow>> {
    let mut rows = Vec::with_capacity(entity_ids.len());
    for chunk in entity_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT ts.id, ts.version_id, av.canonical_album_id, ts.user_edits_json \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.id IN (",
        );
        let mut sep = qb.separated(", ");
        for id in chunk {
            sep.push_bind(id);
        }
        sep.push_unseparated(") ORDER BY ts.id ASC");
        rows.extend(
            qb.build_query_as::<TrackEditTargetRow>()
                .fetch_all(&mut *conn)
                .await?,
        );
    }
    rows.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(rows)
}

async fn delete_cleared_legacy_overrides_tx(
    conn: &mut SqliteConnection,
    entity_type: &str,
    entity_id: &str,
    cleared_fields: &[&str],
) -> Result<()> {
    for field in cleared_fields {
        sqlx::query(
            "DELETE FROM metadata_overrides \
             WHERE entity_type = ? AND entity_id = ? AND field_name = ? \
               AND source_layer = 'user_edit'",
        )
        .bind(entity_type)
        .bind(entity_id)
        .bind(*field)
        .execute(&mut *conn)
        .await?;
    }
    Ok(())
}
