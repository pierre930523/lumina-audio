use chrono::Utc;
use core_types::{
    AddStaticPlaylistTracksRequest, CreateStaticPlaylistRequest, StaticPlaylistDetail,
    StaticPlaylistItemView, StaticPlaylistSummary,
};
use sqlx::SqlitePool;
use uuid::Uuid;

use super::PlaylistImproverRepository;
use super::helpers::DiskCheckMode;
use super::queries::load_playlist_items_conn;
use crate::error::{DbError, Result};
use crate::write_coordinator::DbWriteCoordinator;

#[derive(Debug, sqlx::FromRow)]
struct PlaylistSummaryDbRow {
    id: String,
    provider_id: String,
    source_path: String,
    name: String,
    track_count: i64,
    resolved_count: i64,
    unresolved_count: i64,
    snapshot_count: i64,
    updated_at: String,
}

impl From<PlaylistSummaryDbRow> for StaticPlaylistSummary {
    fn from(r: PlaylistSummaryDbRow) -> Self {
        Self {
            id: r.id,
            provider_id: r.provider_id,
            source_path: r.source_path,
            name: r.name,
            track_count: r.track_count.max(0) as u64,
            resolved_count: r.resolved_count.max(0) as u64,
            unresolved_count: r.unresolved_count.max(0) as u64,
            snapshot_count: r.snapshot_count.max(0) as u64,
            updated_at: r.updated_at,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
struct PlaylistHeaderRow {
    id: String,
    provider_id: String,
    source_path: String,
    name: String,
    updated_at: String,
    snapshot_count: i64,
}

impl PlaylistImproverRepository {
    /// Lists all static/sidecar playlists with live item counts, health counts, and snapshot counts.
    pub async fn list_static_playlists(pool: &SqlitePool) -> Result<Vec<StaticPlaylistSummary>> {
        let rows: Vec<PlaylistSummaryDbRow> = sqlx::query_as(
            "SELECT p.id, p.provider_id, p.source_path, p.name, \
                    COUNT(pi.position) AS track_count, \
                    SUM(CASE WHEN ts.id IS NOT NULL AND ts.file_status = 'present' THEN 1 ELSE 0 END) AS resolved_count, \
                    SUM(CASE WHEN pi.position IS NOT NULL AND (ts.id IS NULL OR ts.file_status != 'present') THEN 1 ELSE 0 END) AS unresolved_count, \
                    (SELECT COUNT(*) FROM playlist_snapshots ps WHERE ps.playlist_id = p.id) AS snapshot_count, \
                    p.updated_at \
             FROM playlists p \
             LEFT JOIN playlist_items pi ON pi.playlist_id = p.id \
             LEFT JOIN track_sources ts ON ts.id = pi.resolved_track_source_id \
             GROUP BY p.id \
             ORDER BY p.updated_at DESC, p.name ASC, p.id ASC",
        )
        .fetch_all(pool)
        .await?;

        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// Loads a static playlist and all its ordered items with joined track metadata and health status.
    pub async fn get_static_playlist_detail(
        pool: &SqlitePool,
        playlist_id: &str,
    ) -> Result<StaticPlaylistDetail> {
        let pid = playlist_id.trim();
        let mut conn = pool.acquire().await?;

        let header: PlaylistHeaderRow = sqlx::query_as(
            "SELECT p.id, p.provider_id, p.source_path, p.name, p.updated_at, \
                    (SELECT COUNT(*) FROM playlist_snapshots ps WHERE ps.playlist_id = p.id) AS snapshot_count \
             FROM playlists p WHERE p.id = ?",
        )
        .bind(pid)
        .fetch_optional(&mut *conn)
        .await?
        .ok_or_else(|| DbError::NotFound(format!("Static playlist '{pid}' not found")))?;

        let loaded = load_playlist_items_conn(&mut conn, &header.id, DiskCheckMode::Smart).await?;
        let mut items = Vec::with_capacity(loaded.len());
        let mut resolved_count = 0u64;
        let mut unresolved_count = 0u64;

        for item in loaded {
            let is_missing = !item.is_healthy;
            if is_missing {
                unresolved_count += 1;
            } else {
                resolved_count += 1;
            }
            items.push(StaticPlaylistItemView {
                position: item.position,
                raw_entry: item.raw_entry,
                resolved_track_source_id: item.resolved_track_source_id,
                track: item.track.map(|t| t.summary),
                is_missing,
            });
        }

        let summary = StaticPlaylistSummary {
            id: header.id,
            provider_id: header.provider_id,
            source_path: header.source_path,
            name: header.name,
            track_count: items.len() as u64,
            resolved_count,
            unresolved_count,
            snapshot_count: header.snapshot_count.max(0) as u64,
            updated_at: header.updated_at,
        };

        Ok(StaticPlaylistDetail {
            playlist: summary,
            items,
        })
    }

    /// Creates a new user-owned static playlist and optionally seeds initial tracks.
    pub async fn create_static_playlist(
        pool: &SqlitePool,
        req: &CreateStaticPlaylistRequest,
    ) -> Result<StaticPlaylistDetail> {
        let name = req.name.trim();
        if name.is_empty() {
            return Err(DbError::ConstraintViolation(
                "Static playlist name must not be empty".into(),
            ));
        }

        let id = Uuid::new_v4().to_string();
        let source_path = format!("lumina://playlist/{id}");
        let now = Utc::now().to_rfc3339();

        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;

        let res: Result<()> = async {
            sqlx::query(
                "INSERT INTO playlists (id, provider_id, source_path, name, track_count, updated_at) \
                 VALUES (?, 'user', ?, ?, 0, ?)",
            )
            .bind(&id)
            .bind(&source_path)
            .bind(name)
            .bind(&now)
            .execute(tx.conn())
            .await?;

            let mut inserted = 0i64;
            for raw_track_id in &req.track_ids {
                let tid = raw_track_id.trim();
                if tid.is_empty() {
                    continue;
                }
                let row: Option<(String, String)> = sqlx::query_as(
                    "SELECT id, external_track_id FROM track_sources WHERE id = ?",
                )
                .bind(tid)
                .fetch_optional(tx.conn())
                .await?;
                let Some((resolved_id, ext_id)) = row else {
                    return Err(DbError::NotFound(format!("Track source '{tid}' not found")));
                };

                sqlx::query(
                    "INSERT INTO playlist_items (playlist_id, position, raw_entry, resolved_track_source_id) \
                     VALUES (?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(inserted)
                .bind(&ext_id)
                .bind(&resolved_id)
                .execute(tx.conn())
                .await?;
                inserted += 1;
            }

            if inserted > 0 {
                sqlx::query("UPDATE playlists SET track_count = ? WHERE id = ?")
                    .bind(inserted)
                    .bind(&id)
                    .execute(tx.conn())
                    .await?;
            }
            Ok(())
        }
        .await;

        match res {
            Ok(()) => tx.commit().await?,
            Err(err) => {
                let _ = tx.rollback().await;
                return Err(err);
            }
        }

        Self::get_static_playlist_detail(pool, &id).await
    }

    /// Appends tracks at `max_position + 1` and updates `track_count` and `updated_at`.
    pub async fn add_tracks_to_static_playlist(
        pool: &SqlitePool,
        playlist_id: &str,
        req: &AddStaticPlaylistTracksRequest,
    ) -> Result<StaticPlaylistDetail> {
        let pid = playlist_id.trim();
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;

        let res: Result<()> = async {
            let exists: Option<(String,)> =
                sqlx::query_as("SELECT id FROM playlists WHERE id = ?")
                    .bind(pid)
                    .fetch_optional(tx.conn())
                    .await?;
            if exists.is_none() {
                return Err(DbError::NotFound(format!(
                    "Static playlist '{pid}' not found"
                )));
            }

            let (mut next_pos,): (i64,) = sqlx::query_as(
                "SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_items WHERE playlist_id = ?",
            )
            .bind(pid)
            .fetch_one(tx.conn())
            .await?;

            for raw_track_id in &req.track_ids {
                let tid = raw_track_id.trim();
                if tid.is_empty() {
                    continue;
                }
                let row: Option<(String, String)> = sqlx::query_as(
                    "SELECT id, external_track_id FROM track_sources WHERE id = ?",
                )
                .bind(tid)
                .fetch_optional(tx.conn())
                .await?;
                let Some((resolved_id, ext_id)) = row else {
                    return Err(DbError::NotFound(format!("Track source '{tid}' not found")));
                };

                sqlx::query(
                    "INSERT INTO playlist_items (playlist_id, position, raw_entry, resolved_track_source_id) \
                     VALUES (?, ?, ?, ?)",
                )
                .bind(pid)
                .bind(next_pos)
                .bind(&ext_id)
                .bind(&resolved_id)
                .execute(tx.conn())
                .await?;
                next_pos += 1;
            }

            let (total_count,): (i64,) =
                sqlx::query_as("SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ?")
                    .bind(pid)
                    .fetch_one(tx.conn())
                    .await?;
            let now = Utc::now().to_rfc3339();
            sqlx::query("UPDATE playlists SET track_count = ?, updated_at = ? WHERE id = ?")
                .bind(total_count)
                .bind(&now)
                .bind(pid)
                .execute(tx.conn())
                .await?;

            Ok(())
        }
        .await;

        match res {
            Ok(()) => tx.commit().await?,
            Err(err) => {
                let _ = tx.rollback().await;
                return Err(err);
            }
        }

        Self::get_static_playlist_detail(pool, pid).await
    }

    /// Deletes a static playlist (cascading its items and snapshots).
    pub async fn delete_static_playlist(pool: &SqlitePool, playlist_id: &str) -> Result<bool> {
        let pid = playlist_id.trim();
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;

        let res = sqlx::query("DELETE FROM playlists WHERE id = ?")
            .bind(pid)
            .execute(tx.conn())
            .await
            .map(|r| r.rows_affected() > 0)
            .map_err(DbError::from);

        match res {
            Ok(deleted) => {
                tx.commit().await?;
                Ok(deleted)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }
}
