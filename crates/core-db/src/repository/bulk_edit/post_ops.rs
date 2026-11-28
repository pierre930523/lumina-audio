use std::collections::HashSet;

use chrono::Utc;
use core_types::{BulkEditEntityType, BulkEditPatch};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection};

use super::{dedup_non_empty_ids, tag_entity_type_str};
use crate::error::{DbError, Result};
use crate::repository::LibraryRepository;
use crate::search::{delete_fts_entry_conn, sync_single_album_fts_visibility_conn};

pub(super) async fn apply_custom_tags_tx(
    conn: &mut SqliteConnection,
    entity_type: BulkEditEntityType,
    valid_ids: &[String],
    patch: &BulkEditPatch,
) -> Result<(u64, u64)> {
    if valid_ids.is_empty() {
        return Ok((0, 0));
    }

    let add_tag_ids = dedup_non_empty_ids(&patch.add_tag_ids);
    let remove_tag_ids = dedup_non_empty_ids(&patch.remove_tag_ids);
    let tag_entity = tag_entity_type_str(entity_type);

    let mut tags_added = 0u64;
    if !add_tag_ids.is_empty() {
        for tag_id in &add_tag_ids {
            let exists: Option<(i64,)> = sqlx::query_as("SELECT 1 FROM tags WHERE id = ? LIMIT 1")
                .bind(tag_id)
                .fetch_optional(&mut *conn)
                .await?;
            if exists.is_none() {
                return Err(DbError::NotFound(format!("Tag '{tag_id}' not found")));
            }
        }
        let now = Utc::now().to_rfc3339();
        for tag_id in &add_tag_ids {
            for entity_id in valid_ids {
                tags_added += sqlx::query(
                    "INSERT OR IGNORE INTO tag_items (tag_id, entity_type, entity_id, created_at) \
                     VALUES (?, ?, ?, ?)",
                )
                .bind(tag_id)
                .bind(tag_entity)
                .bind(entity_id)
                .bind(&now)
                .execute(&mut *conn)
                .await?
                .rows_affected();
            }
        }
    }

    let mut tags_removed = 0u64;
    if !remove_tag_ids.is_empty() {
        for tag_id in &remove_tag_ids {
            for chunk in valid_ids.chunks(500) {
                let mut qb: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("DELETE FROM tag_items WHERE tag_id = ");
                qb.push_bind(tag_id)
                    .push(" AND entity_type = ")
                    .push_bind(tag_entity)
                    .push(" AND entity_id IN (");
                let mut sep = qb.separated(", ");
                for entity_id in chunk {
                    sep.push_bind(entity_id);
                }
                sep.push_unseparated(")");
                tags_removed += qb.build().execute(&mut *conn).await?.rows_affected();
            }
        }
    }

    Ok((tags_added, tags_removed))
}

pub(super) async fn prune_vacated_orphans_tx(
    conn: &mut SqliteConnection,
    vacated_version_ids: &HashSet<String>,
    vacated_album_ids: &HashSet<String>,
) -> Result<(usize, usize)> {
    if vacated_version_ids.is_empty() && vacated_album_ids.is_empty() {
        return Ok((0, 0));
    }

    let mut candidate_albums: HashSet<String> = vacated_album_ids.clone();
    let mut pruned_versions = 0usize;

    let mut sorted_vers: Vec<&String> = vacated_version_ids.iter().collect();
    sorted_vers.sort();
    for vid in sorted_vers {
        let row: Option<(String, i64)> = sqlx::query_as(
            "SELECT av.canonical_album_id, \
                    (SELECT COUNT(*) FROM track_sources ts WHERE ts.version_id = av.id) \
             FROM album_versions av WHERE av.id = ?",
        )
        .bind(vid)
        .fetch_optional(&mut *conn)
        .await?;

        if let Some((album_id, track_count)) = row
            && track_count == 0
        {
            candidate_albums.insert(album_id);
            let done = sqlx::query("DELETE FROM album_versions WHERE id = ?")
                .bind(vid)
                .execute(&mut *conn)
                .await?;
            pruned_versions += done.rows_affected() as usize;
        }
    }

    sqlx::query(
        "DELETE FROM canonical_tracks \
         WHERE NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.canonical_track_id = canonical_tracks.id)",
    )
    .execute(&mut *conn)
    .await?;

    let mut pruned_albums = 0usize;
    let mut sorted_albums: Vec<&String> = candidate_albums.iter().collect();
    sorted_albums.sort();
    for aid in sorted_albums {
        let ver_count: Option<(i64,)> = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM album_versions av WHERE av.canonical_album_id = ca.id) \
             FROM canonical_albums ca WHERE ca.id = ?",
        )
        .bind(aid)
        .fetch_optional(&mut *conn)
        .await?;

        if let Some((0,)) = ver_count {
            sqlx::query(
                "DELETE FROM artwork_overrides WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(aid)
            .execute(&mut *conn)
            .await?;
            sqlx::query(
                "DELETE FROM metadata_overrides WHERE entity_type = 'album' AND entity_id = ?",
            )
            .bind(aid)
            .execute(&mut *conn)
            .await?;
            sqlx::query("DELETE FROM artwork_cache WHERE album_id = ?")
                .bind(aid)
                .execute(&mut *conn)
                .await?;
            delete_fts_entry_conn(conn, "album", aid).await?;
            sqlx::query("DELETE FROM profile_favorites WHERE item_type = 'album' AND item_id = ?")
                .bind(aid)
                .execute(&mut *conn)
                .await?;
            sqlx::query(
                "DELETE FROM tag_items WHERE entity_type = 'album_group' AND entity_id = ?",
            )
            .bind(aid)
            .execute(&mut *conn)
            .await?;
            let done = sqlx::query("DELETE FROM canonical_albums WHERE id = ?")
                .bind(aid)
                .execute(&mut *conn)
                .await?;
            pruned_albums += done.rows_affected() as usize;
        }
    }

    Ok((pruned_versions, pruned_albums))
}

pub(super) async fn recompute_affected_groups_tx(
    conn: &mut SqliteConnection,
    affected_groups: &HashSet<String>,
) -> Result<usize> {
    let mut sorted_groups: Vec<&String> = affected_groups.iter().collect();
    sorted_groups.sort();

    let mut recomputed = 0usize;
    for gid in sorted_groups {
        let exists: Option<(String,)> =
            sqlx::query_as("SELECT id FROM canonical_albums WHERE id = ?")
                .bind(gid)
                .fetch_optional(&mut *conn)
                .await?;
        if exists.is_some() {
            let _ = LibraryRepository::resolve_primary_version_tx(conn, gid).await?;
            sync_single_album_fts_visibility_conn(conn, gid).await?;
            recomputed += 1;
        }
    }

    Ok(recomputed)
}
