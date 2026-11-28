use core_types::{AlbumVersionOpResult, GroupAlternateVersionsRequest};
use sqlx::{SqliteConnection, SqlitePool};
use std::collections::HashSet;

use super::LibraryRepository;
use super::version_ops_helpers::{
    clone_canonical_album_tx, finalize_groups_tx, load_version_meta_tx,
    migrate_album_group_refs_tx, migrate_canonical_tracks_for_track_ids_tx,
};
use crate::error::{DbError, Result};
use crate::search::sync_single_album_fts_visibility_conn;
use crate::write_coordinator::DbWriteCoordinator;

impl LibraryRepository {
    /// Groups multiple versions into one `canonical_albums` group as alternate versions,
    /// stamping `manual_group_id`, migrating credits/favorites/artwork, and pruning empty groups.
    pub async fn group_as_alternate_versions_tx(
        conn: &mut SqliteConnection,
        req: &GroupAlternateVersionsRequest,
    ) -> Result<AlbumVersionOpResult> {
        let mut version_ids = Vec::new();
        let mut seen = HashSet::new();
        for raw in &req.version_ids {
            let trimmed = raw.trim();
            if !trimmed.is_empty() && seen.insert(trimmed.to_string()) {
                version_ids.push(trimmed.to_string());
            }
        }
        if version_ids.is_empty() {
            return Err(DbError::ConstraintViolation(
                "group_as_alternate_versions requires at least one version_id".to_string(),
            ));
        }

        let mut metas = Vec::with_capacity(version_ids.len());
        for vid in &version_ids {
            metas.push(load_version_meta_tx(conn, vid).await?);
        }

        let target_group_id = if let Some(ref tg) = req.target_group_id {
            let trimmed = tg.trim();
            if trimmed.is_empty() {
                metas[0].canonical_album_id.clone()
            } else {
                let exists: Option<(String,)> =
                    sqlx::query_as("SELECT id FROM canonical_albums WHERE id = ?")
                        .bind(trimmed)
                        .fetch_optional(&mut *conn)
                        .await?;
                if exists.is_none() {
                    return Err(DbError::NotFound(format!(
                        "target canonical_album '{trimmed}' not found"
                    )));
                }
                trimmed.to_string()
            }
        } else if let Some(ref pv) = req.primary_version_id
            && let Some(m) = metas.iter().find(|m| m.id == pv.trim())
        {
            m.canonical_album_id.clone()
        } else {
            metas[0].canonical_album_id.clone()
        };

        let mut affected_groups: HashSet<String> = HashSet::new();
        affected_groups.insert(target_group_id.clone());

        for meta in &metas {
            affected_groups.insert(meta.canonical_album_id.clone());
            sqlx::query(
                "UPDATE album_versions SET canonical_album_id = ?, manual_group_id = ? WHERE id = ?",
            )
            .bind(&target_group_id)
            .bind(&target_group_id)
            .bind(&meta.id)
            .execute(&mut *conn)
            .await?;

            if meta.canonical_album_id != target_group_id {
                let tids: Vec<(String,)> =
                    sqlx::query_as("SELECT id FROM track_sources WHERE version_id = ?")
                        .bind(&meta.id)
                        .fetch_all(&mut *conn)
                        .await?;
                let tid_vec: Vec<String> = tids.into_iter().map(|(id,)| id).collect();
                migrate_canonical_tracks_for_track_ids_tx(conn, &tid_vec, &target_group_id).await?;
                migrate_album_group_refs_tx(conn, &target_group_id, &meta.canonical_album_id)
                    .await?;
            }
        }

        let pruned = Self::prune_orphan_albums_and_versions_tx(conn, None).await?;

        if let Some(ref pv) = req.primary_version_id {
            let pv_trimmed = pv.trim();
            if !pv_trimmed.is_empty() {
                let _ = Self::set_primary_version_tx(conn, &target_group_id, pv_trimmed).await?;
            }
        }

        let (surviving_groups, primary) =
            finalize_groups_tx(conn, &affected_groups, &target_group_id).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: surviving_groups,
            affected_version_ids: version_ids,
            primary_version_id: primary,
            moved_tracks: 0,
            pruned_versions: pruned.versions_pruned,
            pruned_albums: pruned.albums_pruned,
        })
    }

    pub async fn group_as_alternate_versions(
        pool: &SqlitePool,
        req: &GroupAlternateVersionsRequest,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::group_as_alternate_versions_tx(tx.conn(), req).await;
        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Detaches `version_id` into its own standalone album group (or locks it in-place if it is
    /// already the sole version), preventing future rescans or auto-dedup from re-merging it.
    pub async fn ungroup_version_tx(
        conn: &mut SqliteConnection,
        version_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let meta = load_version_meta_tx(conn, version_id).await?;
        let (ver_count,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM album_versions WHERE canonical_album_id = ?")
                .bind(&meta.canonical_album_id)
                .fetch_one(&mut *conn)
                .await?;

        if ver_count <= 1 {
            sqlx::query("UPDATE album_versions SET manual_group_id = ? WHERE id = ?")
                .bind(&meta.canonical_album_id)
                .bind(&meta.id)
                .execute(&mut *conn)
                .await?;
            let primary = Self::resolve_primary_version_tx(conn, &meta.canonical_album_id).await?;
            sync_single_album_fts_visibility_conn(conn, &meta.canonical_album_id).await?;
            return Ok(AlbumVersionOpResult {
                affected_group_ids: vec![meta.canonical_album_id],
                affected_version_ids: vec![meta.id],
                primary_version_id: primary,
                ..Default::default()
            });
        }

        let new_group_id = clone_canonical_album_tx(conn, &meta.canonical_album_id, None).await?;
        sqlx::query(
            "UPDATE album_versions SET canonical_album_id = ?, manual_group_id = ? WHERE id = ?",
        )
        .bind(&new_group_id)
        .bind(&new_group_id)
        .bind(&meta.id)
        .execute(&mut *conn)
        .await?;

        sqlx::query(
            "UPDATE canonical_albums \
             SET primary_version_id = NULL, is_primary_locked = 0 \
             WHERE id = ? AND primary_version_id = ?",
        )
        .bind(&meta.canonical_album_id)
        .bind(&meta.id)
        .execute(&mut *conn)
        .await?;

        let tids: Vec<(String,)> =
            sqlx::query_as("SELECT id FROM track_sources WHERE version_id = ?")
                .bind(&meta.id)
                .fetch_all(&mut *conn)
                .await?;
        let tid_vec: Vec<String> = tids.into_iter().map(|(id,)| id).collect();
        migrate_canonical_tracks_for_track_ids_tx(conn, &tid_vec, &new_group_id).await?;

        let pruned = Self::prune_orphan_albums_and_versions_tx(conn, None).await?;
        let mut affected = HashSet::new();
        affected.insert(meta.canonical_album_id.clone());
        affected.insert(new_group_id.clone());
        let (surviving_groups, primary) =
            finalize_groups_tx(conn, &affected, &new_group_id).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: surviving_groups,
            affected_version_ids: vec![meta.id],
            primary_version_id: primary,
            moved_tracks: tid_vec.len(),
            pruned_versions: pruned.versions_pruned,
            pruned_albums: pruned.albums_pruned,
        })
    }

    pub async fn ungroup_version(
        pool: &SqlitePool,
        version_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::ungroup_version_tx(tx.conn(), version_id).await;
        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Clears `manual_group_id` on `version_id` and `manual_version_id`/`manual_disc_number`
    /// on its tracks, restores effective `disc_number`, and re-resolves primary version.
    pub async fn reset_album_grouping_tx(
        conn: &mut SqliteConnection,
        version_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let meta = load_version_meta_tx(conn, version_id).await?;

        sqlx::query("UPDATE album_versions SET manual_group_id = NULL WHERE id = ?")
            .bind(&meta.id)
            .execute(&mut *conn)
            .await?;

        let track_rows: Vec<(String,)> =
            sqlx::query_as("SELECT id FROM track_sources WHERE version_id = ?")
                .bind(&meta.id)
                .fetch_all(&mut *conn)
                .await?;

        sqlx::query(
            "UPDATE track_sources SET manual_version_id = NULL, manual_disc_number = NULL WHERE version_id = ?",
        )
        .bind(&meta.id)
        .execute(&mut *conn)
        .await?;

        let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
        for (tid,) in &track_rows {
            let _ = Self::recompute_track_effective_tx(conn, tid, default_policy).await?;
        }

        let primary = Self::resolve_primary_version_tx(conn, &meta.canonical_album_id).await?;
        sync_single_album_fts_visibility_conn(conn, &meta.canonical_album_id).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: vec![meta.canonical_album_id],
            affected_version_ids: vec![meta.id],
            primary_version_id: primary,
            ..Default::default()
        })
    }

    pub async fn reset_album_grouping(
        pool: &SqlitePool,
        version_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::reset_album_grouping_tx(tx.conn(), version_id).await;
        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
