mod paths;
mod queries;

use chrono::Utc;
use sqlx::{SqliteConnection, SqlitePool};
use std::collections::HashMap;

pub use paths::{folder_id_for_norm_path, normalize_folder_path};

use paths::{WatchedRootInfo, build_folder_chain, clean_display_path, extract_parent_dir};

use crate::error::Result;
use crate::repository::tx::ImmediateTx;

pub struct FolderRepository;

impl FolderRepository {
    async fn load_local_watched_roots_tx(
        conn: &mut SqliteConnection,
    ) -> Result<Vec<WatchedRootInfo>> {
        let rows: Vec<(String, String)> =
            sqlx::query_as("SELECT id, root_path FROM watched_roots WHERE provider_id = 'local'")
                .fetch_all(&mut *conn)
                .await?;

        Ok(rows
            .into_iter()
            .filter_map(|(id, root_path)| {
                let norm_path = normalize_folder_path(&root_path);
                if norm_path.is_empty() {
                    return None;
                }
                let display_path = clean_display_path(&root_path);
                Some(WatchedRootInfo {
                    id,
                    norm_path,
                    display_path,
                })
            })
            .collect())
    }

    async fn upsert_folder_node_tx(
        conn: &mut SqliteConnection,
        seg: &paths::FolderSegment,
        parent_id: Option<&str>,
        update_display: bool,
        now: &str,
    ) -> Result<String> {
        let flag = if update_display { 1i32 } else { 0i32 };
        let (persisted_id,): (String,) = sqlx::query_as(
            "INSERT INTO library_folders \
             (id, root_id, parent_id, name, norm_path, display_path, depth, \
              direct_track_count, recursive_track_count, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?) \
             ON CONFLICT(norm_path) DO UPDATE SET \
                root_id = COALESCE(excluded.root_id, library_folders.root_id), \
                name = CASE WHEN ? != 0 THEN excluded.name ELSE library_folders.name END, \
                display_path = CASE WHEN ? != 0 THEN excluded.display_path ELSE library_folders.display_path END, \
                updated_at = excluded.updated_at \
             RETURNING id",
        )
        .bind(&seg.id)
        .bind(&seg.root_id)
        .bind(parent_id)
        .bind(&seg.name)
        .bind(&seg.norm_path)
        .bind(&seg.display_path)
        .bind(seg.depth)
        .bind(now)
        .bind(flag)
        .bind(flag)
        .fetch_one(&mut *conn)
        .await?;

        Ok(persisted_id)
    }

    async fn ensure_folder_chain_tx(
        conn: &mut SqliteConnection,
        dir_norm: &str,
        dir_display: &str,
        roots: &[WatchedRootInfo],
        update_display: bool,
        cache: Option<&mut HashMap<String, String>>,
    ) -> Result<String> {
        if let Some(ref map) = cache
            && let Some(cached_id) = map.get(dir_norm)
        {
            return Ok(cached_id.clone());
        }

        let chain = build_folder_chain(dir_norm, dir_display, roots);
        let now = Utc::now().to_rfc3339();
        let mut prev_id: Option<String> = None;

        if let Some(map) = cache {
            for seg in &chain {
                if let Some(existing_id) = map.get(&seg.norm_path) {
                    prev_id = Some(existing_id.clone());
                    continue;
                }
                let persisted_id = Self::upsert_folder_node_tx(
                    conn,
                    seg,
                    prev_id.as_deref(),
                    update_display,
                    &now,
                )
                .await?;
                map.insert(seg.norm_path.clone(), persisted_id.clone());
                prev_id = Some(persisted_id);
            }
        } else {
            for seg in &chain {
                let persisted_id = Self::upsert_folder_node_tx(
                    conn,
                    seg,
                    prev_id.as_deref(),
                    update_display,
                    &now,
                )
                .await?;
                prev_id = Some(persisted_id);
            }
        }

        Ok(prev_id.unwrap_or_else(|| folder_id_for_norm_path(dir_norm)))
    }

    async fn adjust_folder_chain_counts_tx(
        conn: &mut SqliteConnection,
        folder_id: &str,
        delta: i64,
    ) -> Result<()> {
        if delta == 0 {
            return Ok(());
        }
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "WITH RECURSIVE ancestors(id) AS ( \
                SELECT id FROM library_folders WHERE id = ? \
                UNION ALL \
                SELECT f.parent_id \
                FROM library_folders f \
                JOIN ancestors a ON f.id = a.id \
                WHERE f.parent_id IS NOT NULL \
             ) \
             UPDATE library_folders \
             SET direct_track_count = CASE \
                    WHEN id = ? THEN MAX(0, direct_track_count + ?) \
                    ELSE direct_track_count \
                 END, \
                 recursive_track_count = MAX(0, recursive_track_count + ?), \
                 updated_at = ? \
             WHERE id IN (SELECT id FROM ancestors)",
        )
        .bind(folder_id)
        .bind(folder_id)
        .bind(delta)
        .bind(delta)
        .bind(&now)
        .execute(&mut *conn)
        .await?;
        Ok(())
    }

    /// Synchronizes `library_folders` nodes and incremental track counts when a local track
    /// is inserted, moved, marked missing, or restored to present.
    ///
    /// Returns `Ok(Some(folder_id))` for local tracks with a valid parent directory, or `Ok(None)`
    /// for non-local providers / paths without a parent directory.
    #[allow(clippy::too_many_arguments)]
    pub async fn sync_track_folder_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        external_track_id: &str,
        display_file_path: Option<&str>,
        old_folder_id: Option<&str>,
        was_present: bool,
        is_present: bool,
    ) -> Result<Option<String>> {
        if !provider_id.eq_ignore_ascii_case("local") {
            return Ok(None);
        }

        let source_path = display_file_path.unwrap_or(external_track_id);
        let Some((dir_norm, dir_display)) = extract_parent_dir(source_path) else {
            if was_present && let Some(old_id) = old_folder_id {
                Self::adjust_folder_chain_counts_tx(conn, old_id, -1).await?;
            }
            return Ok(None);
        };

        let roots = Self::load_local_watched_roots_tx(conn).await?;
        let new_folder_id = Self::ensure_folder_chain_tx(
            conn,
            &dir_norm,
            &dir_display,
            &roots,
            display_file_path.is_some(),
            None,
        )
        .await?;

        match (was_present, is_present) {
            (false, false) => {}
            (false, true) => {
                Self::adjust_folder_chain_counts_tx(conn, &new_folder_id, 1).await?;
            }
            (true, false) => {
                if let Some(old_id) = old_folder_id {
                    Self::adjust_folder_chain_counts_tx(conn, old_id, -1).await?;
                }
            }
            (true, true) => {
                if old_folder_id != Some(new_folder_id.as_str()) {
                    if let Some(old_id) = old_folder_id {
                        Self::adjust_folder_chain_counts_tx(conn, old_id, -1).await?;
                    }
                    Self::adjust_folder_chain_counts_tx(conn, &new_folder_id, 1).await?;
                }
            }
        }

        Ok(Some(new_folder_id))
    }

    /// Recomputes exact `direct_track_count` and `recursive_track_count` for all
    /// `library_folders` rows from present local `track_sources`.
    pub async fn recompute_all_folder_counts_tx(conn: &mut SqliteConnection) -> Result<()> {
        let direct_rows: Vec<(String, i64)> = sqlx::query_as(
            "SELECT folder_id, COUNT(*) \
             FROM track_sources \
             WHERE provider_id = 'local' \
               AND file_status = 'present' \
               AND folder_id IS NOT NULL \
             GROUP BY folder_id",
        )
        .fetch_all(&mut *conn)
        .await?;

        let direct_map: HashMap<String, i64> = direct_rows.into_iter().collect();

        let folders: Vec<(String, Option<String>, i64, i64)> = sqlx::query_as(
            "SELECT id, parent_id, direct_track_count, recursive_track_count FROM library_folders",
        )
        .fetch_all(&mut *conn)
        .await?;

        let parent_map: HashMap<&str, Option<&str>> = folders
            .iter()
            .map(|(id, parent, _, _)| (id.as_str(), parent.as_deref()))
            .collect();

        let mut recursive_map: HashMap<&str, i64> = HashMap::with_capacity(folders.len());
        for (id, _, _, _) in &folders {
            let direct = direct_map.get(id.as_str()).copied().unwrap_or(0);
            if direct == 0 {
                continue;
            }
            let mut cur = Some(id.as_str());
            let mut hops = 0usize;
            while let Some(node_id) = cur {
                if hops > 128 {
                    break;
                }
                *recursive_map.entry(node_id).or_insert(0) += direct;
                cur = parent_map.get(node_id).copied().flatten();
                hops += 1;
            }
        }

        let now = Utc::now().to_rfc3339();
        for (id, _, old_direct, old_recursive) in &folders {
            let new_direct = direct_map.get(id.as_str()).copied().unwrap_or(0);
            let new_recursive = recursive_map.get(id.as_str()).copied().unwrap_or(0);
            if new_direct != *old_direct || new_recursive != *old_recursive {
                sqlx::query(
                    "UPDATE library_folders \
                     SET direct_track_count = ?, recursive_track_count = ?, updated_at = ? \
                     WHERE id = ?",
                )
                .bind(new_direct)
                .bind(new_recursive)
                .bind(&now)
                .bind(id)
                .execute(&mut *conn)
                .await?;
            }
        }

        Ok(())
    }

    /// Removes all empty folder nodes (`recursive_track_count <= 0`) and returns the
    /// total number of removed rows (including cascaded descendants).
    pub async fn prune_empty_folders_tx(conn: &mut SqliteConnection) -> Result<u64> {
        let (empty_count,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM library_folders WHERE recursive_track_count <= 0")
                .fetch_one(&mut *conn)
                .await?;

        if empty_count <= 0 {
            return Ok(0);
        }

        // Delete deepest folders first so FK cascade ordering is explicit and deterministic.
        sqlx::query(
            "DELETE FROM library_folders \
             WHERE id IN ( \
                 SELECT id FROM library_folders \
                 WHERE recursive_track_count <= 0 \
                 ORDER BY depth DESC \
             )",
        )
        .execute(&mut *conn)
        .await?;

        Ok(empty_count as u64)
    }

    /// One-time lazy backfill for legacy local tracks whose `folder_id` is `NULL`.
    /// Performs an O(1) indexed `EXISTS` check first and returns `Ok(0)` immediately if clean.
    pub async fn backfill_library_folders_if_needed(pool: &SqlitePool) -> Result<u64> {
        let (needs_backfill,): (i32,) = sqlx::query_as(
            "SELECT EXISTS( \
                 SELECT 1 FROM track_sources \
                 WHERE provider_id = 'local' \
                   AND file_status = 'present' \
                   AND folder_id IS NULL \
             )",
        )
        .fetch_one(pool)
        .await?;

        if needs_backfill == 0 {
            return Ok(0);
        }

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<u64> = async {
            let roots = Self::load_local_watched_roots_tx(tx.conn()).await?;
            let tracks: Vec<(String, String)> = sqlx::query_as(
                "SELECT id, external_track_id \
                 FROM track_sources \
                 WHERE provider_id = 'local' \
                   AND file_status = 'present' \
                   AND folder_id IS NULL",
            )
            .fetch_all(tx.conn())
            .await?;

            let mut cache: HashMap<String, String> = HashMap::new();
            let mut updated = 0u64;

            for (track_id, ext_path) in tracks {
                let Some((dir_norm, dir_display)) = extract_parent_dir(&ext_path) else {
                    continue;
                };
                let folder_id = Self::ensure_folder_chain_tx(
                    tx.conn(),
                    &dir_norm,
                    &dir_display,
                    &roots,
                    false,
                    Some(&mut cache),
                )
                .await?;

                sqlx::query("UPDATE track_sources SET folder_id = ? WHERE id = ?")
                    .bind(&folder_id)
                    .bind(&track_id)
                    .execute(tx.conn())
                    .await?;
                updated += 1;
            }

            Self::recompute_all_folder_counts_tx(tx.conn()).await?;
            Ok(updated)
        }
        .await;

        match res {
            Ok(count) => {
                tx.commit().await?;
                Ok(count)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
