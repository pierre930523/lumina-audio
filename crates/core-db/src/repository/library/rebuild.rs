use std::collections::{HashMap, HashSet};
use std::path::Path;

use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};

use super::LibraryRepository;
use super::helpers::normalize_local_path_for_compare;
use super::models::{
    AlbumUserBindingsSnapshot, ForceRebuildFinalizeReport, ForceRebuildPrepareReport,
};
use super::rebuild_grouping::{
    restore_album_grouping_bindings_tx, snapshot_album_grouping_bindings_tx,
};
use super::rebuild_step4::{
    remap_listen_later_album_id_tx, restore_album_preference_tx, snapshot_album_preferences_tx,
};
use crate::error::Result;
use crate::repository::tx::ImmediateTx;
use crate::search::rebuild_search_index_conn;

impl LibraryRepository {
    /// Snapshots `old_canonical_album_id -> Vec<track_source_id>` for every album referenced
    /// by album-level user data (`profile_favorites`, `metadata_overrides(user_edit)`, and
    /// `artwork_overrides`) so Force Rebuild can remap those bindings if album grouping changes.
    pub async fn snapshot_album_user_bindings_tx(
        conn: &mut SqliteConnection,
    ) -> Result<AlbumUserBindingsSnapshot> {
        let album_rows: Vec<(String,)> = sqlx::query_as(
            "SELECT DISTINCT album_id FROM ( \
                 SELECT item_id AS album_id FROM profile_favorites WHERE item_type = 'album' \
                 UNION \
                 SELECT entity_id AS album_id FROM metadata_overrides \
                     WHERE entity_type = 'album' AND source_layer = 'user_edit' \
                 UNION \
                 SELECT target_id AS album_id FROM artwork_overrides WHERE target_kind = 'album' \
                 UNION \
                 SELECT entity_id AS album_id FROM tag_items WHERE entity_type = 'album_group' \
                 UNION \
                 SELECT id AS album_id FROM canonical_albums \
                     WHERE (user_edits_json IS NOT NULL AND TRIM(user_edits_json) NOT IN ('', '{}', 'null')) \
                        OR meta_policy != 'inherit' \
                        OR preference != 0 \
                 UNION \
                 SELECT entity_id AS album_id FROM listen_later_items \
                     WHERE source_kind = 'library' AND entity_type = 'album' AND entity_id IS NOT NULL \
             )",
        )
        .fetch_all(&mut *conn)
        .await?;

        let mut album_tracks: HashMap<String, Vec<String>> = HashMap::new();
        let mut album_user_layers: HashMap<String, (Option<String>, String)> = HashMap::new();
        let grouping = snapshot_album_grouping_bindings_tx(conn).await?;
        if album_rows.is_empty() {
            return Ok(AlbumUserBindingsSnapshot {
                album_tracks,
                album_user_layers,
                album_preferences: HashMap::new(),
                grouping,
            });
        }

        let album_ids: Vec<String> = album_rows.into_iter().map(|(id,)| id).collect();
        let album_preferences = snapshot_album_preferences_tx(conn, &album_ids).await?;
        for chunk in album_ids.chunks(500) {
            let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                "SELECT av.canonical_album_id, ts.id \
                 FROM album_versions av \
                 JOIN track_sources ts ON ts.version_id = av.id \
                 WHERE av.canonical_album_id IN (",
            );
            let mut sep = qb.separated(", ");
            for aid in chunk {
                sep.push_bind(aid);
            }
            sep.push_unseparated(") ORDER BY av.canonical_album_id ASC, ts.id ASC");

            let rows: Vec<(String, String)> = qb.build_query_as().fetch_all(&mut *conn).await?;
            for (aid, tid) in rows {
                album_tracks.entry(aid).or_default().push(tid);
            }

            let mut qb_lay: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                "SELECT id, user_edits_json, meta_policy FROM canonical_albums WHERE id IN (",
            );
            let mut sep_lay = qb_lay.separated(", ");
            for aid in chunk {
                sep_lay.push_bind(aid);
            }
            sep_lay.push_unseparated(")");
            let layer_rows: Vec<(String, Option<String>, String)> =
                qb_lay.build_query_as().fetch_all(&mut *conn).await?;
            for (aid, user_edits, policy) in layer_rows {
                if user_edits.is_some() || policy != "inherit" {
                    album_user_layers.insert(aid, (user_edits, policy));
                }
            }
        }

        Ok(AlbumUserBindingsSnapshot {
            album_tracks,
            album_user_layers,
            album_preferences,
            grouping,
        })
    }

    pub async fn snapshot_album_user_bindings(
        pool: &SqlitePool,
    ) -> Result<AlbumUserBindingsSnapshot> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::snapshot_album_user_bindings_tx(tx.conn()).await;
        match res {
            Ok(snap) => {
                tx.commit().await?;
                Ok(snap)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Prepares the database for a non-destructive Force Rebuild without deleting `track_sources`,
    /// `play_history`, `playlists`, `profile_favorites`, `metadata_overrides(user_edit)`, or `artwork_overrides`:
    /// - Resets `file_mtime`, `file_size`, `metadata_hash` on local `track_sources`
    /// - Clears `cloud_enrichment` rows in `metadata_overrides` (preserving `user_edit`)
    /// - Clears `artwork_cache` (returning invalidated cache paths for disk cleanup)
    /// - Clears non-dismissed `skipped_files`
    /// - Clears unverified enrichment fields (`musicbrainz_release_group_id`, `editorial_bio`, `enriched_at`)
    ///   on local-only `canonical_albums` (unless pinned by a `user_edit` override).
    pub async fn prepare_force_rebuild_tx(
        conn: &mut SqliteConnection,
    ) -> Result<ForceRebuildPrepareReport> {
        let tracks_cache_reset = sqlx::query(
            "UPDATE track_sources \
             SET file_mtime = NULL, file_size = NULL, metadata_hash = NULL, cloud_meta_json = NULL \
             WHERE provider_id = 'local'",
        )
        .execute(&mut *conn)
        .await?
        .rows_affected() as usize;

        let cloud_overrides_cleared =
            sqlx::query("DELETE FROM metadata_overrides WHERE source_layer = 'cloud_enrichment'")
                .execute(&mut *conn)
                .await?
                .rows_affected() as usize;

        let cache_rows: Vec<(String,)> = sqlx::query_as("SELECT cache_path FROM artwork_cache")
            .fetch_all(&mut *conn)
            .await?;
        let invalidated_artwork_paths: Vec<String> = cache_rows.into_iter().map(|(p,)| p).collect();
        let artwork_cache_cleared = sqlx::query("DELETE FROM artwork_cache")
            .execute(&mut *conn)
            .await?
            .rows_affected() as usize;

        let skipped_files_cleared = sqlx::query("DELETE FROM skipped_files WHERE dismissed = 0")
            .execute(&mut *conn)
            .await?
            .rows_affected() as usize;

        let albums_enrichment_cleared = sqlx::query(
            "UPDATE canonical_albums \
             SET musicbrainz_release_group_id = NULL, \
                 editorial_bio = NULL, \
                 enriched_at = NULL, \
                 cloud_meta_json = NULL \
             WHERE NOT EXISTS ( \
                 SELECT 1 FROM album_versions av \
                 WHERE av.canonical_album_id = canonical_albums.id \
                   AND av.provider_id != 'local' \
             ) \
             AND NOT EXISTS ( \
                 SELECT 1 FROM metadata_overrides mo \
                 WHERE mo.entity_type = 'album' \
                   AND mo.entity_id = canonical_albums.id \
                   AND mo.field_name = 'musicbrainz_release_group_id' \
                   AND mo.source_layer = 'user_edit' \
             )",
        )
        .execute(&mut *conn)
        .await?
        .rows_affected() as usize;

        Ok(ForceRebuildPrepareReport {
            tracks_cache_reset,
            cloud_overrides_cleared,
            artwork_cache_cleared,
            skipped_files_cleared,
            albums_enrichment_cleared,
            invalidated_artwork_paths,
        })
    }

    pub async fn prepare_force_rebuild(pool: &SqlitePool) -> Result<ForceRebuildPrepareReport> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::prepare_force_rebuild_tx(tx.conn()).await;
        match res {
            Ok(report) => {
                tx.commit().await?;
                Ok(report)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Finalizes a Force Rebuild atomically inside a transaction:
    /// 1. Remaps album-level `profile_favorites`, `metadata_overrides(user_edit)`, and
    ///    `artwork_overrides` from `old_album_id` to the new majority `canonical_album_id`
    ///    of their preserved `track_source_id`s (conflict-safe via `INSERT OR IGNORE`).
    /// 2. Re-resolves `playlist_items.resolved_track_source_id` against present tracks.
    /// 3. Purges missing local tracks without `play_history` (keeping play_history intact)
    ///    and runs full orphan cleanup (`album_versions`, `canonical_albums`, `canonical_tracks`,
    ///    `artists`, and stale `search_fts`).
    /// 4. Rebuilds `search_fts` cleanly within the same transaction.
    pub async fn finalize_force_rebuild_tx(
        conn: &mut SqliteConnection,
        snapshot: &AlbumUserBindingsSnapshot,
    ) -> Result<ForceRebuildFinalizeReport> {
        let mut report = ForceRebuildFinalizeReport::default();

        // 1. Remap album-level user bindings using majority track ownership
        let mut old_ids: Vec<&String> = snapshot.album_tracks.keys().collect();
        old_ids.sort();
        for old_album_id in old_ids {
            let track_ids = &snapshot.album_tracks[old_album_id];
            if track_ids.is_empty() {
                continue;
            }
            let Some(new_album_id) = resolve_majority_album_id_tx(conn, track_ids).await? else {
                continue;
            };
            if &new_album_id == old_album_id {
                continue;
            }

            let fav_moved = sqlx::query(
                "INSERT OR IGNORE INTO profile_favorites (profile_id, item_type, item_id, created_at) \
                 SELECT profile_id, item_type, ?, created_at FROM profile_favorites \
                 WHERE item_type = 'album' AND item_id = ?",
            )
            .bind(&new_album_id)
            .bind(old_album_id)
            .execute(&mut *conn)
            .await?
            .rows_affected() as usize;
            sqlx::query("DELETE FROM profile_favorites WHERE item_type = 'album' AND item_id = ?")
                .bind(old_album_id)
                .execute(&mut *conn)
                .await?;
            report.favorites_remapped += fav_moved;

            let mo_moved = sqlx::query(
                "INSERT OR IGNORE INTO metadata_overrides \
                    (entity_type, entity_id, field_name, value_json, source_layer, updated_at) \
                 SELECT entity_type, ?, field_name, value_json, source_layer, updated_at \
                 FROM metadata_overrides \
                 WHERE entity_type = 'album' AND entity_id = ? AND source_layer = 'user_edit'",
            )
            .bind(&new_album_id)
            .bind(old_album_id)
            .execute(&mut *conn)
            .await?
            .rows_affected() as usize;
            sqlx::query(
                "DELETE FROM metadata_overrides \
                 WHERE entity_type = 'album' AND entity_id = ? AND source_layer = 'user_edit'",
            )
            .bind(old_album_id)
            .execute(&mut *conn)
            .await?;
            report.metadata_overrides_remapped += mo_moved;

            let ao_moved = sqlx::query(
                "INSERT OR IGNORE INTO artwork_overrides (target_kind, target_id, image_path, updated_at) \
                 SELECT target_kind, ?, image_path, updated_at FROM artwork_overrides \
                 WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(&new_album_id)
            .bind(old_album_id)
            .execute(&mut *conn)
            .await?
            .rows_affected() as usize;
            sqlx::query(
                "DELETE FROM artwork_overrides WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(old_album_id)
            .execute(&mut *conn)
            .await?;
            report.artwork_overrides_remapped += ao_moved;

            sqlx::query(
                "INSERT OR IGNORE INTO tag_items (tag_id, entity_type, entity_id, created_at) \
                 SELECT tag_id, entity_type, ?, created_at FROM tag_items \
                 WHERE entity_type = 'album_group' AND entity_id = ?",
            )
            .bind(&new_album_id)
            .bind(old_album_id)
            .execute(&mut *conn)
            .await?;
            sqlx::query(
                "DELETE FROM tag_items WHERE entity_type = 'album_group' AND entity_id = ?",
            )
            .bind(old_album_id)
            .execute(&mut *conn)
            .await?;

            remap_listen_later_album_id_tx(conn, &new_album_id, old_album_id).await?;
            if let Some(&pref) = snapshot.album_preferences.get(old_album_id) {
                restore_album_preference_tx(conn, &new_album_id, pref).await?;
            }

            if let Some((user_edits, policy)) = snapshot.album_user_layers.get(old_album_id) {
                sqlx::query(
                    "UPDATE canonical_albums SET \
                        user_edits_json = COALESCE(user_edits_json, ?), \
                        meta_policy = CASE WHEN meta_policy = 'inherit' THEN ? ELSE meta_policy END \
                     WHERE id = ?",
                )
                .bind(user_edits)
                .bind(policy)
                .bind(&new_album_id)
                .execute(&mut *conn)
                .await?;
                let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
                let _ =
                    Self::recompute_album_effective_tx(conn, &new_album_id, default_policy).await?;
            }
        }

        // 2. Re-resolve playlist_items against present track_sources
        report.playlist_items_resolved = reresolve_playlist_items_tx(conn).await?;

        // 3. Purge missing local tracks (preserving play_history) + full orphan cleanup
        let purge = Self::purge_missing_local_tracks_tx(conn, Some("local"), true).await?;
        let mut orphans = purge.orphans;
        let unscoped = Self::prune_orphan_albums_and_versions_tx(conn, None).await?;
        orphans.versions_pruned += unscoped.versions_pruned;
        orphans.albums_pruned += unscoped.albums_pruned;
        orphans.canonical_tracks_pruned += unscoped.canonical_tracks_pruned;
        orphans.artists_pruned += unscoped.artists_pruned;
        let mut seen: HashSet<String> = orphans.invalidated_artwork_paths.iter().cloned().collect();
        for p in unscoped.invalidated_artwork_paths {
            if seen.insert(p.clone()) {
                orphans.invalidated_artwork_paths.push(p);
            }
        }
        report.missing_tracks_purged = purge.missing_tracks_purged;
        report.play_history_tombstones_kept = purge.play_history_tombstones_kept;
        report.orphans = orphans;

        // 3b. Restore Step 2 grouping/primary/hidden/track locks & resolve primary versions
        let _ = restore_album_grouping_bindings_tx(conn, &snapshot.grouping).await?;

        // 4. Rebuild search_fts atomically inside the same transaction
        report.search_index_entries = rebuild_search_index_conn(conn).await?;

        Ok(report)
    }

    pub async fn finalize_force_rebuild(
        pool: &SqlitePool,
        snapshot: &AlbumUserBindingsSnapshot,
    ) -> Result<ForceRebuildFinalizeReport> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::finalize_force_rebuild_tx(tx.conn(), snapshot).await;
        match res {
            Ok(report) => {
                tx.commit().await?;
                Ok(report)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}

async fn resolve_majority_album_id_tx(
    conn: &mut SqliteConnection,
    track_ids: &[String],
) -> Result<Option<String>> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for chunk in track_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.file_status = 'present' AND ts.id IN (",
        );
        let mut sep = qb.separated(", ");
        for tid in chunk {
            sep.push_bind(tid);
        }
        sep.push_unseparated(")");

        let rows: Vec<(String,)> = qb.build_query_as().fetch_all(&mut *conn).await?;
        for (aid,) in rows {
            *counts.entry(aid).or_insert(0) += 1;
        }
    }

    Ok(counts
        .into_iter()
        .max_by(|(id_a, cnt_a), (id_b, cnt_b)| cnt_a.cmp(cnt_b).then_with(|| id_b.cmp(id_a)))
        .map(|(aid, _)| aid))
}

async fn reresolve_playlist_items_tx(conn: &mut SqliteConnection) -> Result<usize> {
    let items: Vec<(String, i64, String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT pi.playlist_id, pi.position, p.provider_id, p.source_path, pi.raw_entry, \
                pi.resolved_track_source_id \
         FROM playlist_items pi \
         JOIN playlists p ON p.id = pi.playlist_id \
         LEFT JOIN track_sources ts ON ts.id = pi.resolved_track_source_id AND ts.file_status = 'present' \
         WHERE ts.id IS NULL",
    )
    .fetch_all(&mut *conn)
    .await?;

    if items.is_empty() {
        return Ok(0);
    }

    let present_tracks: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT id, provider_id, external_track_id FROM track_sources WHERE file_status = 'present'",
    )
    .fetch_all(&mut *conn)
    .await?;

    let mut track_by_key: HashMap<(String, String), String> =
        HashMap::with_capacity(present_tracks.len());
    for (tid, prov, ext_id) in present_tracks {
        track_by_key.insert((prov, normalize_local_path_for_compare(&ext_id)), tid);
    }

    let mut resolved_count = 0usize;
    for (playlist_id, position, provider_id, source_path, raw_entry, current_resolved) in items {
        let trimmed = raw_entry.trim();
        if trimmed.is_empty() {
            continue;
        }
        let raw_path = Path::new(trimmed);
        let candidate_str = if raw_path.is_absolute()
            || trimmed.starts_with('/')
            || trimmed.starts_with('\\')
            || trimmed.as_bytes().get(1) == Some(&b':')
        {
            trimmed.to_string()
        } else if let Some(parent) = Path::new(&source_path).parent() {
            parent.join(trimmed).to_string_lossy().to_string()
        } else {
            trimmed.to_string()
        };

        let norm = normalize_local_path_for_compare(&candidate_str);
        if let Some(new_tid) = track_by_key.get(&(provider_id, norm))
            && current_resolved.as_deref() != Some(new_tid.as_str())
        {
            sqlx::query(
                "UPDATE playlist_items SET resolved_track_source_id = ? \
                 WHERE playlist_id = ? AND position = ?",
            )
            .bind(new_tid)
            .bind(&playlist_id)
            .bind(position)
            .execute(&mut *conn)
            .await?;
            resolved_count += 1;
        }
    }

    Ok(resolved_count)
}
