use core_types::{FolderBreadcrumb, FolderContentsResponse, FolderNode};
use sqlx::SqlitePool;

use super::FolderRepository;
use crate::error::{DbError, Result};
use crate::repository::CatalogTrackRow;

#[derive(Debug, Clone, sqlx::FromRow)]
struct FolderNodeRow {
    id: String,
    root_id: Option<String>,
    parent_id: Option<String>,
    name: String,
    norm_path: String,
    display_path: String,
    depth: i64,
    direct_track_count: i64,
    recursive_track_count: i64,
    is_online: i32,
}

impl From<FolderNodeRow> for FolderNode {
    fn from(r: FolderNodeRow) -> Self {
        Self {
            id: r.id,
            root_id: r.root_id,
            parent_id: r.parent_id,
            name: r.name,
            norm_path: r.norm_path,
            display_path: r.display_path,
            depth: r.depth.max(0) as u32,
            direct_track_count: r.direct_track_count.max(0) as u64,
            recursive_track_count: r.recursive_track_count.max(0) as u64,
            is_online: r.is_online != 0,
        }
    }
}

#[derive(Debug, Clone, sqlx::FromRow)]
struct BreadcrumbRow {
    id: String,
    name: String,
    display_path: String,
}

impl From<BreadcrumbRow> for FolderBreadcrumb {
    fn from(r: BreadcrumbRow) -> Self {
        Self {
            id: r.id,
            name: r.name,
            display_path: r.display_path,
        }
    }
}

impl FolderRepository {
    /// Returns top-level root folder nodes (`parent_id IS NULL` and either non-empty
    /// or linked to a registered watched root), joined with `watched_roots.is_online`.
    pub async fn get_folder_roots(pool: &SqlitePool) -> Result<Vec<FolderNode>> {
        let rows: Vec<FolderNodeRow> = sqlx::query_as(
            "SELECT f.id, f.root_id, f.parent_id, f.name, f.norm_path, f.display_path, \
                    f.depth, f.direct_track_count, f.recursive_track_count, \
                    COALESCE(wr.is_online, 1) AS is_online \
             FROM library_folders f \
             LEFT JOIN watched_roots wr ON wr.id = f.root_id \
             WHERE f.parent_id IS NULL \
               AND (f.recursive_track_count > 0 OR f.root_id IS NOT NULL) \
             ORDER BY LOWER(f.name) ASC, f.name ASC, f.norm_path ASC",
        )
        .fetch_all(pool)
        .await?;

        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// Fetches a folder node along with its root-to-current breadcrumbs,
    /// non-empty direct subfolders, and direct visible present tracks.
    pub async fn get_folder_contents(
        pool: &SqlitePool,
        folder_id: &str,
    ) -> Result<FolderContentsResponse<CatalogTrackRow>> {
        Self::get_folder_contents_with_options(pool, folder_id, false).await
    }

    pub async fn get_folder_contents_with_options(
        pool: &SqlitePool,
        folder_id: &str,
        include_hidden: bool,
    ) -> Result<FolderContentsResponse<CatalogTrackRow>> {
        let folder_row: FolderNodeRow = sqlx::query_as(
            "SELECT f.id, f.root_id, f.parent_id, f.name, f.norm_path, f.display_path, \
                    f.depth, f.direct_track_count, f.recursive_track_count, \
                    COALESCE(wr.is_online, 1) AS is_online \
             FROM library_folders f \
             LEFT JOIN watched_roots wr ON wr.id = f.root_id \
             WHERE f.id = ?",
        )
        .bind(folder_id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| DbError::NotFound(format!("Folder not found: '{folder_id}'")))?;

        let breadcrumb_rows: Vec<BreadcrumbRow> = sqlx::query_as(
            "WITH RECURSIVE chain(id, parent_id, name, display_path, level) AS ( \
                SELECT id, parent_id, name, display_path, 0 \
                FROM library_folders \
                WHERE id = ? \
                UNION ALL \
                SELECT f.id, f.parent_id, f.name, f.display_path, c.level + 1 \
                FROM library_folders f \
                JOIN chain c ON f.id = c.parent_id \
             ) \
             SELECT id, name, display_path \
             FROM chain \
             ORDER BY level DESC",
        )
        .bind(folder_id)
        .fetch_all(pool)
        .await?;

        let subfolder_rows: Vec<FolderNodeRow> = sqlx::query_as(
            "SELECT f.id, f.root_id, f.parent_id, f.name, f.norm_path, f.display_path, \
                    f.depth, f.direct_track_count, f.recursive_track_count, \
                    COALESCE(wr.is_online, 1) AS is_online \
             FROM library_folders f \
             LEFT JOIN watched_roots wr ON wr.id = f.root_id \
             WHERE f.parent_id = ? \
               AND f.recursive_track_count > 0 \
             ORDER BY LOWER(f.name) ASC, f.name ASC, f.norm_path ASC",
        )
        .bind(folder_id)
        .fetch_all(pool)
        .await?;

        let tracks_sql = if include_hidden {
            format!(
                "{} WHERE trk.folder_id = ? AND trk.file_status = 'present' \
                 ORDER BY trk.disc_number ASC, trk.track_number ASC, trk.title ASC, trk.external_track_id ASC",
                crate::repository::catalog_queries::CATALOG_TRACK_SELECT
            )
        } else {
            format!(
                "{} WHERE trk.folder_id = ? AND trk.file_status = 'present' AND ver.is_hidden = 0 AND trk.is_hidden = 0 \
                 ORDER BY trk.disc_number ASC, trk.track_number ASC, trk.title ASC, trk.external_track_id ASC",
                crate::repository::catalog_queries::CATALOG_TRACK_SELECT
            )
        };
        let tracks: Vec<CatalogTrackRow> = sqlx::query_as(&tracks_sql)
            .bind(folder_id)
            .fetch_all(pool)
            .await?;

        Ok(FolderContentsResponse {
            folder: folder_row.into(),
            breadcrumbs: breadcrumb_rows.into_iter().map(Into::into).collect(),
            subfolders: subfolder_rows.into_iter().map(Into::into).collect(),
            tracks,
        })
    }

    /// Recursively collects all present local `track_sources.id` values under `folder_id`
    /// and all of its descendant folders in deterministic folder + disc/track/title order.
    /// When `exclude_banned` is true, omits tracks with `preference = -1`.
    pub async fn get_folder_recursive_track_ids(
        pool: &SqlitePool,
        folder_id: &str,
        exclude_banned: bool,
    ) -> Result<Vec<String>> {
        let exists: Option<(i32,)> =
            sqlx::query_as("SELECT 1 FROM library_folders WHERE id = ? LIMIT 1")
                .bind(folder_id)
                .fetch_optional(pool)
                .await?;
        if exists.is_none() {
            return Err(DbError::NotFound(format!(
                "Folder not found: '{folder_id}'"
            )));
        }

        let sql = if exclude_banned {
            "WITH RECURSIVE subtree(id, depth, norm_path) AS ( \
                SELECT id, depth, norm_path \
                FROM library_folders \
                WHERE id = ? \
                UNION ALL \
                SELECT f.id, f.depth, f.norm_path \
                FROM library_folders f \
                JOIN subtree s ON f.parent_id = s.id \
             ) \
             SELECT ts.id \
             FROM track_sources ts \
             JOIN subtree s ON ts.folder_id = s.id \
             WHERE ts.provider_id = 'local' \
               AND ts.file_status = 'present' \
               AND ts.is_hidden = 0 \
               AND ts.preference != -1 \
             ORDER BY s.norm_path ASC, ts.disc_number ASC, ts.track_number ASC, ts.title ASC, ts.external_track_id ASC"
        } else {
            "WITH RECURSIVE subtree(id, depth, norm_path) AS ( \
                SELECT id, depth, norm_path \
                FROM library_folders \
                WHERE id = ? \
                UNION ALL \
                SELECT f.id, f.depth, f.norm_path \
                FROM library_folders f \
                JOIN subtree s ON f.parent_id = s.id \
             ) \
             SELECT ts.id \
             FROM track_sources ts \
             JOIN subtree s ON ts.folder_id = s.id \
             WHERE ts.provider_id = 'local' \
               AND ts.file_status = 'present' \
               AND ts.is_hidden = 0 \
             ORDER BY s.norm_path ASC, ts.disc_number ASC, ts.track_number ASC, ts.title ASC, ts.external_track_id ASC"
        };

        let rows: Vec<(String,)> = sqlx::query_as(sql).bind(folder_id).fetch_all(pool).await?;

        Ok(rows.into_iter().map(|(id,)| id).collect())
    }
}
