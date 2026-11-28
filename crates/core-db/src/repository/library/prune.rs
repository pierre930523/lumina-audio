use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};
use std::collections::HashSet;

use super::LibraryRepository;
use super::helpers::{normalize_local_path_for_compare, path_in_scope};
use super::models::{PruneLocalTracksReport, PruneOrphansReport, PurgeMissingReport};
use super::prune_helpers::{
    delete_album_batch_with_refs_tx, delete_in_chunks_tx, delete_track_batch_with_refs_tx,
    prune_orphan_artists_and_stale_fts_tx,
};
use crate::error::Result;
use crate::repository::tx::ImmediateTx;

impl LibraryRepository {
    pub async fn prune_missing_local_tracks(
        pool: &SqlitePool,
        scope_dir: Option<&str>,
        existing_paths: &HashSet<String>,
    ) -> Result<PruneLocalTracksReport> {
        let scope_norm = scope_dir
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(normalize_local_path_for_compare);
        let existing_norm: HashSet<String> = existing_paths
            .iter()
            .map(|p| normalize_local_path_for_compare(p))
            .collect();

        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<PruneLocalTracksReport> = async {
            let local_tracks: Vec<(String, String, String)> = sqlx::query_as(
                "SELECT id, version_id, external_track_id FROM track_sources WHERE provider_id = 'local'",
            )
            .fetch_all(tx.conn())
            .await?;

            let mut missing_track_ids = Vec::new();
            let mut affected_version_ids: HashSet<String> = HashSet::new();

            for (id, version_id, external_track_id) in local_tracks {
                let norm = normalize_local_path_for_compare(&external_track_id);
                if let Some(ref scope) = scope_norm
                    && !path_in_scope(&norm, scope)
                {
                    continue;
                }
                if !existing_norm.contains(&norm) {
                    missing_track_ids.push(id);
                    affected_version_ids.insert(version_id);
                }
            }

            if missing_track_ids.is_empty() {
                return Ok(PruneLocalTracksReport::default());
            }

            let mut invalidated_artwork_paths = Vec::new();
            let mut seen_paths: HashSet<String> = HashSet::new();

            delete_track_batch_with_refs_tx(
                tx.conn(),
                &missing_track_ids,
                &mut seen_paths,
                &mut invalidated_artwork_paths,
            )
            .await?;

            sqlx::query(
                "DELETE FROM canonical_tracks \
                 WHERE NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.canonical_track_id = canonical_tracks.id)",
            )
            .execute(tx.conn())
            .await?;

            let affected_ver_vec: Vec<String> = affected_version_ids.into_iter().collect();
            let mut orphaned_version_ids = Vec::new();
            let mut candidate_album_ids: HashSet<String> = HashSet::new();

            for chunk in affected_ver_vec.chunks(500) {
                let mut qb_ver: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "SELECT av.id, av.canonical_album_id FROM album_versions av \
                     WHERE av.id IN (",
                );
                let mut sep_ver = qb_ver.separated(", ");
                for vid in chunk {
                    sep_ver.push_bind(vid);
                }
                sep_ver.push_unseparated(
                    ") AND NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.version_id = av.id)",
                );
                let rows: Vec<(String, String)> =
                    qb_ver.build_query_as().fetch_all(tx.conn()).await?;
                for (vid, alb_id) in rows {
                    orphaned_version_ids.push(vid);
                    candidate_album_ids.insert(alb_id);
                }
            }

            delete_in_chunks_tx(
                tx.conn(),
                "DELETE FROM album_versions WHERE id IN (",
                &orphaned_version_ids,
            )
            .await?;

            let candidate_alb_vec: Vec<String> = candidate_album_ids.into_iter().collect();
            let mut orphaned_album_ids = Vec::new();

            for chunk in candidate_alb_vec.chunks(500) {
                let mut qb_alb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "SELECT ca.id FROM canonical_albums ca WHERE ca.id IN (",
                );
                let mut sep_alb = qb_alb.separated(", ");
                for aid in chunk {
                    sep_alb.push_bind(aid);
                }
                sep_alb.push_unseparated(
                    ") AND NOT EXISTS (SELECT 1 FROM album_versions av WHERE av.canonical_album_id = ca.id)",
                );
                let rows: Vec<(String,)> = qb_alb.build_query_as().fetch_all(tx.conn()).await?;
                for (aid,) in rows {
                    orphaned_album_ids.push(aid);
                }
            }

            delete_album_batch_with_refs_tx(
                tx.conn(),
                &orphaned_album_ids,
                &mut seen_paths,
                &mut invalidated_artwork_paths,
            )
            .await?;

            let artists_pruned = prune_orphan_artists_and_stale_fts_tx(tx.conn()).await?;

            Ok(PruneLocalTracksReport {
                tracks_pruned: missing_track_ids.len(),
                versions_pruned: orphaned_version_ids.len(),
                albums_pruned: orphaned_album_ids.len(),
                artists_pruned,
                invalidated_artwork_paths,
            })
        }
        .await;

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

    /// Composable transactional orphan cleanup: prunes 0-track `album_versions` (optionally
    /// scoped to `provider_id_filter`), orphaned `canonical_tracks`, 0-version `canonical_albums`,
    /// orphan `artists`, and stale `search_fts` rows for missing tracks / empty albums / orphan artists.
    pub async fn prune_orphan_albums_and_versions_tx(
        conn: &mut SqliteConnection,
        provider_id_filter: Option<&str>,
    ) -> Result<PruneOrphansReport> {
        let clean_provider = provider_id_filter.map(str::trim).filter(|s| !s.is_empty());

        let orphan_version_rows: Vec<(String,)> = sqlx::query_as(
            "SELECT av.id FROM album_versions av \
             WHERE (? IS NULL OR av.provider_id = ?) \
               AND NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.version_id = av.id)",
        )
        .bind(clean_provider)
        .bind(clean_provider)
        .fetch_all(&mut *conn)
        .await?;

        let orphan_version_ids: Vec<String> =
            orphan_version_rows.into_iter().map(|(id,)| id).collect();
        delete_in_chunks_tx(
            conn,
            "DELETE FROM album_versions WHERE id IN (",
            &orphan_version_ids,
        )
        .await?;

        let canonical_tracks_pruned = sqlx::query(
            "DELETE FROM canonical_tracks \
             WHERE NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.canonical_track_id = canonical_tracks.id)",
        )
        .execute(&mut *conn)
        .await?
        .rows_affected() as usize;

        let orphan_album_rows: Vec<(String,)> = sqlx::query_as(
            "SELECT ca.id FROM canonical_albums ca \
             WHERE NOT EXISTS (SELECT 1 FROM album_versions av WHERE av.canonical_album_id = ca.id)",
        )
        .fetch_all(&mut *conn)
        .await?;

        let orphan_album_ids: Vec<String> = orphan_album_rows.into_iter().map(|(id,)| id).collect();
        let mut invalidated_artwork_paths = Vec::new();
        let mut seen_paths: HashSet<String> = HashSet::new();

        delete_album_batch_with_refs_tx(
            conn,
            &orphan_album_ids,
            &mut seen_paths,
            &mut invalidated_artwork_paths,
        )
        .await?;

        let artists_pruned = prune_orphan_artists_and_stale_fts_tx(conn).await?;

        Ok(PruneOrphansReport {
            versions_pruned: orphan_version_ids.len(),
            albums_pruned: orphan_album_ids.len(),
            canonical_tracks_pruned,
            artists_pruned,
            invalidated_artwork_paths,
        })
    }

    /// Transactionally prunes 0-track `album_versions` (optionally scoped to `provider_id_filter`),
    /// orphaned `canonical_tracks`, 0-version `canonical_albums`, orphan `artists`, and stale FTS entries.
    pub async fn prune_orphan_albums_and_versions(
        pool: &SqlitePool,
        provider_id_filter: Option<&str>,
    ) -> Result<PruneOrphansReport> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::prune_orphan_albums_and_versions_tx(tx.conn(), provider_id_filter).await;

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

    /// Purges `track_sources` rows marked `file_status = 'missing'` (optionally scoped to
    /// `provider_id_filter`) and then runs full orphan cleanup (`album_versions`, `canonical_albums`,
    /// `canonical_tracks`, `artists`, and stale `search_fts`).
    ///
    /// When `preserve_play_history` is `true`, missing tracks referenced by `play_history` are
    /// retained as hidden `'missing'` tombstones (so `play_history`'s `ON DELETE CASCADE` FK
    /// never wipes user listening history), while remaining invisible to all present-filtered queries.
    pub async fn purge_missing_local_tracks_tx(
        conn: &mut SqliteConnection,
        provider_id_filter: Option<&str>,
        preserve_play_history: bool,
    ) -> Result<PurgeMissingReport> {
        let clean_provider = provider_id_filter.map(str::trim).filter(|s| !s.is_empty());

        let missing_rows: Vec<(String, i32)> = sqlx::query_as(
            "SELECT ts.id, \
                    CASE WHEN EXISTS (SELECT 1 FROM play_history ph WHERE ph.track_source_id = ts.id) THEN 1 ELSE 0 END AS has_history \
             FROM track_sources ts \
             WHERE ts.file_status = 'missing' \
               AND (? IS NULL OR ts.provider_id = ?)",
        )
        .bind(clean_provider)
        .bind(clean_provider)
        .fetch_all(&mut *conn)
        .await?;

        let mut deletable_ids = Vec::new();
        let mut tombstones_kept = 0usize;
        for (id, has_history) in missing_rows {
            if preserve_play_history && has_history != 0 {
                tombstones_kept += 1;
            } else {
                deletable_ids.push(id);
            }
        }

        let mut invalidated_artwork_paths = Vec::new();
        let mut seen_paths: HashSet<String> = HashSet::new();

        delete_track_batch_with_refs_tx(
            conn,
            &deletable_ids,
            &mut seen_paths,
            &mut invalidated_artwork_paths,
        )
        .await?;

        let orphans = Self::prune_orphan_albums_and_versions_tx(conn, clean_provider).await?;
        for path in &orphans.invalidated_artwork_paths {
            if seen_paths.insert(path.clone()) {
                invalidated_artwork_paths.push(path.clone());
            }
        }

        Ok(PurgeMissingReport {
            missing_tracks_purged: deletable_ids.len(),
            play_history_tombstones_kept: tombstones_kept,
            orphans,
            invalidated_artwork_paths,
        })
    }

    pub async fn purge_missing_local_tracks(
        pool: &SqlitePool,
        provider_id_filter: Option<&str>,
        preserve_play_history: bool,
    ) -> Result<PurgeMissingReport> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::purge_missing_local_tracks_tx(
            tx.conn(),
            provider_id_filter,
            preserve_play_history,
        )
        .await;
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

    pub async fn delete_canonical_album(pool: &SqlitePool, id: &str) -> Result<()> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<()> = async {
            let track_rows: Vec<(String,)> = sqlx::query_as(
                "SELECT ts.id FROM track_sources ts \
                 JOIN album_versions av ON ts.version_id = av.id \
                 WHERE av.canonical_album_id = ?",
            )
            .bind(id)
            .fetch_all(tx.conn())
            .await?;
            let track_ids: Vec<String> = track_rows.into_iter().map(|(tid,)| tid).collect();

            let mut seen_paths = HashSet::new();
            let mut invalidated = Vec::new();
            if !track_ids.is_empty() {
                delete_in_chunks_tx(
                    tx.conn(),
                    "DELETE FROM artwork_overrides WHERE target_kind = 'track' AND target_id IN (",
                    &track_ids,
                )
                .await?;
                delete_in_chunks_tx(
                    tx.conn(),
                    "DELETE FROM metadata_overrides WHERE entity_type = 'track' AND entity_id IN (",
                    &track_ids,
                )
                .await?;
                delete_in_chunks_tx(
                    tx.conn(),
                    "DELETE FROM search_fts WHERE entity_type = 'track' AND entity_id IN (",
                    &track_ids,
                )
                .await?;
                delete_in_chunks_tx(
                    tx.conn(),
                    "DELETE FROM profile_favorites WHERE item_type = 'track' AND item_id IN (",
                    &track_ids,
                )
                .await?;
                delete_in_chunks_tx(
                    tx.conn(),
                    "DELETE FROM tag_items WHERE entity_type = 'track' AND entity_id IN (",
                    &track_ids,
                )
                .await?;
            }

            sqlx::query(
                "DELETE FROM tag_items WHERE entity_type = 'album_group' AND entity_id = ?",
            )
            .bind(id)
            .execute(tx.conn())
            .await?;

            delete_album_batch_with_refs_tx(
                tx.conn(),
                &[id.to_string()],
                &mut seen_paths,
                &mut invalidated,
            )
            .await?;

            sqlx::query(
                "DELETE FROM canonical_tracks \
                 WHERE NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.canonical_track_id = canonical_tracks.id)",
            )
            .execute(tx.conn())
            .await?;

            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(())
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
