use core_types::{
    AlbumVersionOpResult, MergeAlbumVersionsRequest, SplitAlbumVersionRequest, SplitTargetMode,
};
use sqlx::{SqliteConnection, SqlitePool};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use super::LibraryRepository;
use super::version_ops_helpers::{
    clone_canonical_album_tx, derive_representative_format_tx, finalize_groups_tx,
    load_version_meta_tx, migrate_album_group_refs_tx, migrate_canonical_tracks_for_track_ids_tx,
};
use crate::error::{DbError, Result};
use crate::write_coordinator::DbWriteCoordinator;

impl LibraryRepository {
    /// Merges tracks from `source_version_ids` into `target_version_id` as a single multi-disc
    /// version, stamping `manual_version_id` & `manual_disc_number`, migrating album references,
    /// and pruning emptied source versions/groups atomically.
    pub async fn merge_album_versions_tx(
        conn: &mut SqliteConnection,
        req: &MergeAlbumVersionsRequest,
    ) -> Result<AlbumVersionOpResult> {
        let target_id = req.target_version_id.trim();
        if target_id.is_empty() {
            return Err(DbError::ConstraintViolation(
                "target_version_id cannot be empty".to_string(),
            ));
        }

        let mut source_ids: Vec<String> = Vec::new();
        let mut seen_src = HashSet::new();
        for raw in &req.source_version_ids {
            let trimmed = raw.trim();
            if !trimmed.is_empty() && trimmed != target_id && seen_src.insert(trimmed.to_string()) {
                source_ids.push(trimmed.to_string());
            }
        }
        if source_ids.is_empty() {
            return Err(DbError::ConstraintViolation(
                "merge requires at least one distinct source_version_id".to_string(),
            ));
        }

        let target_meta = load_version_meta_tx(conn, target_id).await?;
        let mut source_metas = Vec::with_capacity(source_ids.len());
        for sid in &source_ids {
            source_metas.push(load_version_meta_tx(conn, sid).await?);
        }

        let mut explicit_starts: HashMap<&str, u32> = HashMap::new();
        for entry in &req.disc_mapping {
            let vid = entry.version_id.trim();
            if !vid.is_empty() {
                explicit_starts.insert(vid, entry.disc_start.max(1));
            }
        }

        let mut ordered_versions: Vec<&str> = Vec::with_capacity(1 + source_ids.len());
        ordered_versions.push(target_id);
        for sid in &source_ids {
            ordered_versions.push(sid.as_str());
        }

        let mut tracks_per_ver: HashMap<String, Vec<(String, u32, Option<String>)>> =
            HashMap::new();
        let mut disc_range_per_ver: HashMap<String, (u32, u32)> = HashMap::new();
        for vid in &ordered_versions {
            let rows: Vec<(String, i64, Option<String>)> = sqlx::query_as(
                "SELECT id, COALESCE(manual_disc_number, disc_number), canonical_track_id \
                 FROM track_sources WHERE version_id = ? \
                 ORDER BY COALESCE(manual_disc_number, disc_number) ASC, track_number ASC, id ASC",
            )
            .bind(vid)
            .fetch_all(&mut *conn)
            .await?;

            let mut min_d = u32::MAX;
            let mut max_d = 0u32;
            let mut list = Vec::with_capacity(rows.len());
            for (tid, disc, ctid) in rows {
                let d = u32::try_from(disc.max(1)).unwrap_or(1);
                min_d = min_d.min(d);
                max_d = max_d.max(d);
                list.push((tid, d, ctid));
            }
            if min_d == u32::MAX {
                min_d = 1;
                max_d = 1;
            }
            disc_range_per_ver.insert((*vid).to_string(), (min_d, max_d));
            tracks_per_ver.insert((*vid).to_string(), list);
        }

        let mut next_disc = 1u32;
        let mut moved_tracks = 0usize;
        let mut all_moved_track_ids = Vec::new();

        for (idx, vid) in ordered_versions.iter().enumerate() {
            let (min_d, max_d) = disc_range_per_ver[*vid];
            let span = (max_d.saturating_sub(min_d) + 1).max(1);
            let start =
                explicit_starts
                    .get(*vid)
                    .copied()
                    .unwrap_or(if idx == 0 { 1 } else { next_disc });
            next_disc = next_disc.max(start + span);

            let is_source = idx > 0;
            if let Some(tracks) = tracks_per_ver.get(*vid) {
                for (tid, orig_disc, ctid) in tracks {
                    let new_disc = start + orig_disc.saturating_sub(min_d);
                    sqlx::query(
                        "UPDATE track_sources \
                         SET version_id = ?, manual_version_id = ?, manual_disc_number = ?, disc_number = ? \
                         WHERE id = ?",
                    )
                    .bind(target_id)
                    .bind(target_id)
                    .bind(i64::from(new_disc))
                    .bind(i64::from(new_disc))
                    .bind(tid)
                    .execute(&mut *conn)
                    .await?;

                    if let Some(ct_id) = ctid {
                        sqlx::query("UPDATE canonical_tracks SET disc_number = ? WHERE id = ?")
                            .bind(i64::from(new_disc))
                            .bind(ct_id)
                            .execute(&mut *conn)
                            .await?;
                    }
                    if is_source {
                        moved_tracks += 1;
                        all_moved_track_ids.push(tid.clone());
                    }
                }
            }
        }

        migrate_canonical_tracks_for_track_ids_tx(
            conn,
            &all_moved_track_ids,
            &target_meta.canonical_album_id,
        )
        .await?;

        let clean_label = req
            .new_edition_label
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if let Some(label) = clean_label {
            sqlx::query(
                "UPDATE album_versions SET manual_group_id = ?, edition_label = ? WHERE id = ?",
            )
            .bind(&target_meta.canonical_album_id)
            .bind(label)
            .bind(target_id)
            .execute(&mut *conn)
            .await?;
        } else {
            sqlx::query("UPDATE album_versions SET manual_group_id = ? WHERE id = ?")
                .bind(&target_meta.canonical_album_id)
                .bind(target_id)
                .execute(&mut *conn)
                .await?;
        }

        let mut affected_groups: HashSet<String> = HashSet::new();
        affected_groups.insert(target_meta.canonical_album_id.clone());
        for sm in &source_metas {
            affected_groups.insert(sm.canonical_album_id.clone());
            if sm.canonical_album_id != target_meta.canonical_album_id {
                migrate_album_group_refs_tx(
                    conn,
                    &target_meta.canonical_album_id,
                    &sm.canonical_album_id,
                )
                .await?;
            }
        }

        let pruned = Self::prune_orphan_albums_and_versions_tx(conn, None).await?;
        let (surviving_groups, primary) =
            finalize_groups_tx(conn, &affected_groups, &target_meta.canonical_album_id).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: surviving_groups,
            affected_version_ids: vec![target_id.to_string()],
            primary_version_id: primary,
            moved_tracks,
            pruned_versions: pruned.versions_pruned,
            pruned_albums: pruned.albums_pruned,
        })
    }

    pub async fn merge_album_versions(
        pool: &SqlitePool,
        req: &MergeAlbumVersionsRequest,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::merge_album_versions_tx(tx.conn(), req).await;
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

    /// Splits selected track groups out of `req.version_id` into new `album_versions` in either
    /// the same album group (`SameGroup`) or newly cloned groups (`NewGroup`), immediately pruning
    /// emptied versions/groups.
    pub async fn split_album_version_tx(
        conn: &mut SqliteConnection,
        req: &SplitAlbumVersionRequest,
    ) -> Result<AlbumVersionOpResult> {
        let src_ver = load_version_meta_tx(conn, &req.version_id).await?;
        if req.track_groups.is_empty() {
            return Err(DbError::ConstraintViolation(
                "split requires at least one track_group".to_string(),
            ));
        }

        let current_rows: Vec<(String,)> =
            sqlx::query_as("SELECT id FROM track_sources WHERE version_id = ?")
                .bind(&src_ver.id)
                .fetch_all(&mut *conn)
                .await?;
        let version_tracks: HashSet<String> = current_rows.into_iter().map(|(id,)| id).collect();

        let mut seen_moved: HashSet<String> = HashSet::new();
        for group in &req.track_groups {
            if group.track_ids.is_empty() {
                return Err(DbError::ConstraintViolation(
                    "split track_group cannot be empty".to_string(),
                ));
            }
            for raw_tid in &group.track_ids {
                let tid = raw_tid.trim();
                if tid.is_empty() || !version_tracks.contains(tid) {
                    return Err(DbError::ConstraintViolation(format!(
                        "track '{tid}' does not belong to version '{}'",
                        src_ver.id
                    )));
                }
                if !seen_moved.insert(tid.to_string()) {
                    return Err(DbError::ConstraintViolation(format!(
                        "duplicate track_id '{tid}' in split request"
                    )));
                }
            }
        }

        let remaining_tracks: Vec<String> = version_tracks
            .iter()
            .filter(|id| !seen_moved.contains(*id))
            .cloned()
            .collect();

        if !remaining_tracks.is_empty() {
            sqlx::query("UPDATE album_versions SET manual_group_id = ? WHERE id = ?")
                .bind(&src_ver.canonical_album_id)
                .bind(&src_ver.id)
                .execute(&mut *conn)
                .await?;
            for tid in &remaining_tracks {
                sqlx::query("UPDATE track_sources SET manual_version_id = ? WHERE id = ?")
                    .bind(&src_ver.id)
                    .bind(tid)
                    .execute(&mut *conn)
                    .await?;
            }
        }

        let mut affected_groups: HashSet<String> = HashSet::new();
        affected_groups.insert(src_ver.canonical_album_id.clone());
        let mut affected_versions = Vec::new();
        if !remaining_tracks.is_empty() {
            affected_versions.push(src_ver.id.clone());
        }

        let mut moved_tracks = 0usize;
        for group in &req.track_groups {
            let dest_group_id = match req.target_mode {
                SplitTargetMode::SameGroup => src_ver.canonical_album_id.clone(),
                SplitTargetMode::NewGroup => {
                    clone_canonical_album_tx(
                        conn,
                        &src_ver.canonical_album_id,
                        group.title.as_deref(),
                    )
                    .await?
                }
            };
            affected_groups.insert(dest_group_id.clone());

            let clean_tids: Vec<String> = group
                .track_ids
                .iter()
                .map(|s| s.trim().to_string())
                .collect();
            let (codec, sr, bd, ch, is_dsd) = derive_representative_format_tx(
                conn,
                &clean_tids,
                (
                    &src_ver.codec,
                    src_ver.sample_rate_hz,
                    src_ver.bit_depth,
                    src_ver.channels,
                    src_ver.is_dsd,
                ),
            )
            .await?;

            let new_ver_id = Uuid::new_v4().to_string();
            let ext_id = format!("manual_split:{new_ver_id}");
            let edition = group
                .edition_label
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or_else(|| src_ver.edition_label.clone());

            sqlx::query(
                "INSERT INTO album_versions ( \
                    id, canonical_album_id, provider_id, external_album_id, \
                    codec, sample_rate_hz, bit_depth, channels, is_dsd, edition_label, \
                    is_hidden, manual_group_id \
                 ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)",
            )
            .bind(&new_ver_id)
            .bind(&dest_group_id)
            .bind(&src_ver.provider_id)
            .bind(&ext_id)
            .bind(&codec)
            .bind(sr)
            .bind(bd)
            .bind(ch)
            .bind(is_dsd)
            .bind(&edition)
            .bind(&dest_group_id)
            .execute(&mut *conn)
            .await?;

            for tid in &clean_tids {
                sqlx::query(
                    "UPDATE track_sources SET version_id = ?, manual_version_id = ? WHERE id = ?",
                )
                .bind(&new_ver_id)
                .bind(&new_ver_id)
                .bind(tid)
                .execute(&mut *conn)
                .await?;
                moved_tracks += 1;
            }

            if dest_group_id != src_ver.canonical_album_id {
                migrate_canonical_tracks_for_track_ids_tx(conn, &clean_tids, &dest_group_id)
                    .await?;
            }
            affected_versions.push(new_ver_id);
        }

        let pruned = Self::prune_orphan_albums_and_versions_tx(conn, None).await?;
        let preferred_group = if remaining_tracks.is_empty() {
            affected_groups
                .iter()
                .find(|g| *g != &src_ver.canonical_album_id)
                .cloned()
                .unwrap_or_else(|| src_ver.canonical_album_id.clone())
        } else {
            src_ver.canonical_album_id.clone()
        };
        let (surviving_groups, primary) =
            finalize_groups_tx(conn, &affected_groups, &preferred_group).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: surviving_groups,
            affected_version_ids: affected_versions,
            primary_version_id: primary,
            moved_tracks,
            pruned_versions: pruned.versions_pruned,
            pruned_albums: pruned.albums_pruned,
        })
    }

    pub async fn split_album_version(
        pool: &SqlitePool,
        req: &SplitAlbumVersionRequest,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::split_album_version_tx(tx.conn(), req).await;
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
