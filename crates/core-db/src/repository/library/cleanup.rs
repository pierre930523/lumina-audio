use core_types::{LibraryCleanupOptions, LibraryCleanupPreview, LibraryCleanupResult};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};
use std::collections::{HashMap, HashSet};

use super::LibraryRepository;
use super::helpers::normalize_local_path_for_compare;
use super::prune_helpers::{
    delete_album_batch_with_refs_tx, delete_in_chunks_tx, delete_track_batch_with_refs_tx,
    prune_orphan_artists_and_stale_fts_tx,
};
use crate::error::Result;
use crate::repository::folders::FolderRepository;
use crate::repository::tx::ImmediateTx;

impl LibraryRepository {
    /// Lists all local `track_sources` rows as `(track_id, external_track_id, file_status)`
    /// so higher layers can verify live root accessibility and file existence outside DB locks.
    pub async fn list_local_track_paths_for_cleanup(
        pool: &SqlitePool,
    ) -> Result<Vec<(String, String, String)>> {
        let rows: Vec<(String, String, String)> = sqlx::query_as(
            "SELECT id, external_track_id, file_status \
             FROM track_sources WHERE provider_id = 'local'",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows)
    }

    /// Collects all normalized local artwork paths referenced by `artwork_cache`,
    /// `artwork_overrides`, `canonical_albums.merged_cover_path`, `canonical_albums.cover_url`,
    /// and `artists.image_path`.
    pub async fn collect_referenced_artwork_paths_tx(
        conn: &mut SqliteConnection,
    ) -> Result<HashSet<String>> {
        let mut refs = HashSet::new();

        let queries = [
            "SELECT cache_path FROM artwork_cache WHERE cache_path IS NOT NULL AND TRIM(cache_path) != ''",
            "SELECT image_path FROM artwork_overrides WHERE image_path IS NOT NULL AND TRIM(image_path) != ''",
            "SELECT merged_cover_path FROM canonical_albums WHERE merged_cover_path IS NOT NULL AND TRIM(merged_cover_path) != ''",
            "SELECT cover_url FROM canonical_albums WHERE cover_url IS NOT NULL AND TRIM(cover_url) != ''",
            "SELECT image_path FROM artists WHERE image_path IS NOT NULL AND TRIM(image_path) != ''",
        ];

        for sql in queries {
            let rows: Vec<(String,)> = sqlx::query_as(sql).fetch_all(&mut *conn).await?;
            for (path,) in rows {
                let norm = normalize_local_path_for_compare(&path);
                if !norm.is_empty() {
                    refs.insert(norm);
                }
            }
        }

        Ok(refs)
    }

    pub async fn collect_referenced_artwork_paths(pool: &SqlitePool) -> Result<HashSet<String>> {
        let mut conn = pool.acquire().await?;
        Self::collect_referenced_artwork_paths_tx(&mut conn).await
    }

    /// Read-only preview of Library Cleanup counts, computing exact cascading counts for
    /// empty `album_versions`, empty `canonical_albums`, and orphan `artists` that would
    /// result after deleting `missing_track_ids` (without mutating the database).
    pub async fn preview_library_cleanup_db(
        pool: &SqlitePool,
        missing_track_ids: &[String],
        orphan_artwork_files: usize,
        orphan_artwork_bytes: u64,
        offline_roots: Vec<String>,
        online_roots_checked: Vec<String>,
    ) -> Result<LibraryCleanupPreview> {
        let track_rows: Vec<(String, String, Option<String>)> =
            sqlx::query_as("SELECT id, version_id, canonical_track_id FROM track_sources")
                .fetch_all(pool)
                .await?;

        let requested_missing: HashSet<&str> =
            missing_track_ids.iter().map(String::as_str).collect();
        let mut existing_missing: HashSet<&str> = HashSet::new();
        let mut surviving_tracks_per_version: HashMap<&str, usize> = HashMap::new();
        let mut surviving_canonical_tracks: HashSet<&str> = HashSet::new();

        for (tid, vid, ctid) in &track_rows {
            if requested_missing.contains(tid.as_str()) {
                existing_missing.insert(tid.as_str());
            } else {
                *surviving_tracks_per_version
                    .entry(vid.as_str())
                    .or_insert(0) += 1;
                if let Some(ct) = ctid.as_deref() {
                    surviving_canonical_tracks.insert(ct);
                }
            }
        }

        let version_rows: Vec<(String, String)> =
            sqlx::query_as("SELECT id, canonical_album_id FROM album_versions")
                .fetch_all(pool)
                .await?;

        let mut empty_version_ids: HashSet<&str> = HashSet::new();
        let mut surviving_versions_per_album: HashMap<&str, usize> = HashMap::new();
        for (vid, aid) in &version_rows {
            if surviving_tracks_per_version
                .get(vid.as_str())
                .copied()
                .unwrap_or(0)
                == 0
            {
                empty_version_ids.insert(vid.as_str());
            } else {
                *surviving_versions_per_album
                    .entry(aid.as_str())
                    .or_insert(0) += 1;
            }
        }

        let album_rows: Vec<(String, Option<String>)> =
            sqlx::query_as("SELECT id, primary_artist_id FROM canonical_albums")
                .fetch_all(pool)
                .await?;

        let mut empty_album_ids: HashSet<&str> = HashSet::new();
        let mut surviving_referenced_artists: HashSet<&str> = HashSet::new();
        for (aid, primary_artist_id) in &album_rows {
            if surviving_versions_per_album
                .get(aid.as_str())
                .copied()
                .unwrap_or(0)
                == 0
            {
                empty_album_ids.insert(aid.as_str());
            } else if let Some(artist_id) = primary_artist_id.as_deref() {
                surviving_referenced_artists.insert(artist_id);
            }
        }

        let credit_rows: Vec<(String, String)> =
            sqlx::query_as("SELECT canonical_album_id, artist_id FROM album_credits")
                .fetch_all(pool)
                .await?;
        for (aid, artist_id) in &credit_rows {
            if !empty_album_ids.contains(aid.as_str()) {
                surviving_referenced_artists.insert(artist_id.as_str());
            }
        }

        let track_artist_rows: Vec<(String, String)> =
            sqlx::query_as("SELECT canonical_track_id, artist_id FROM track_artists")
                .fetch_all(pool)
                .await?;
        for (ctid, artist_id) in &track_artist_rows {
            if surviving_canonical_tracks.contains(ctid.as_str()) {
                surviving_referenced_artists.insert(artist_id.as_str());
            }
        }

        let all_artists: Vec<(String,)> = sqlx::query_as("SELECT id FROM artists")
            .fetch_all(pool)
            .await?;
        let orphan_artists_count = all_artists
            .iter()
            .filter(|(id,)| !surviving_referenced_artists.contains(id.as_str()))
            .count();

        Ok(LibraryCleanupPreview {
            missing_tracks_count: existing_missing.len(),
            empty_album_versions_count: empty_version_ids.len(),
            empty_albums_count: empty_album_ids.len(),
            orphan_artists_count,
            orphan_artwork_files_count: orphan_artwork_files,
            orphan_artwork_bytes,
            offline_roots,
            online_roots_checked,
        })
    }

    /// Executes library cleanup atomically inside a single transaction.
    ///
    /// Returns `(LibraryCleanupResult, surviving_referenced_artwork_paths)` so the caller can
    /// safely unlink unreferenced disk cache files AFTER committing the transaction.
    pub async fn execute_library_cleanup_tx(
        conn: &mut SqliteConnection,
        options: &LibraryCleanupOptions,
        verified_missing_track_ids: &[String],
        skipped_offline_roots: Vec<String>,
    ) -> Result<(LibraryCleanupResult, HashSet<String>)> {
        let mut result = LibraryCleanupResult {
            skipped_offline_roots,
            ..Default::default()
        };
        let mut invalidated_artwork_paths = Vec::new();
        let mut seen_paths: HashSet<String> = HashSet::new();

        // 1. Delete verified missing track_sources (mounted/accessible roots ONLY)
        if options.remove_missing_tracks && !verified_missing_track_ids.is_empty() {
            let mut existing_ids = Vec::new();
            for chunk in verified_missing_track_ids.chunks(500) {
                let mut qb: QueryBuilder<'_, Sqlite> =
                    QueryBuilder::new("SELECT id FROM track_sources WHERE id IN (");
                let mut sep = qb.separated(", ");
                for id in chunk {
                    sep.push_bind(id);
                }
                sep.push_unseparated(")");
                let rows: Vec<(String,)> = qb.build_query_as().fetch_all(&mut *conn).await?;
                existing_ids.extend(rows.into_iter().map(|(id,)| id));
            }
            if !existing_ids.is_empty() {
                delete_track_batch_with_refs_tx(
                    conn,
                    &existing_ids,
                    &mut seen_paths,
                    &mut invalidated_artwork_paths,
                )
                .await?;
                result.removed_tracks = existing_ids.len();
            }
        }

        // 2. Delete 0-track album_versions, orphan canonical_tracks, and 0-version canonical_albums
        if options.remove_empty_albums {
            let empty_ver_rows: Vec<(String,)> = sqlx::query_as(
                "SELECT av.id FROM album_versions av \
                 WHERE NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.version_id = av.id)",
            )
            .fetch_all(&mut *conn)
            .await?;
            let empty_ver_ids: Vec<String> = empty_ver_rows.into_iter().map(|(id,)| id).collect();
            if !empty_ver_ids.is_empty() {
                delete_in_chunks_tx(
                    conn,
                    "DELETE FROM album_versions WHERE id IN (",
                    &empty_ver_ids,
                )
                .await?;
                result.removed_album_versions = empty_ver_ids.len();
            }

            sqlx::query(
                "DELETE FROM canonical_tracks \
                 WHERE NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.canonical_track_id = canonical_tracks.id)",
            )
            .execute(&mut *conn)
            .await?;

            let empty_alb_rows: Vec<(String,)> = sqlx::query_as(
                "SELECT ca.id FROM canonical_albums ca \
                 WHERE NOT EXISTS (SELECT 1 FROM album_versions av WHERE av.canonical_album_id = ca.id)",
            )
            .fetch_all(&mut *conn)
            .await?;
            let empty_alb_ids: Vec<String> = empty_alb_rows.into_iter().map(|(id,)| id).collect();
            if !empty_alb_ids.is_empty() {
                delete_album_batch_with_refs_tx(
                    conn,
                    &empty_alb_ids,
                    &mut seen_paths,
                    &mut invalidated_artwork_paths,
                )
                .await?;
                result.removed_albums = empty_alb_ids.len();
            }
        }

        // 3. Delete orphan artists & stale search_fts entries
        if options.remove_orphan_artists {
            result.removed_artists = prune_orphan_artists_and_stale_fts_tx(conn).await?;
        }

        // 4. Delete dangling artwork_cache rows
        if options.remove_orphan_artwork_cache {
            sqlx::query(
                "DELETE FROM artwork_cache \
                 WHERE (track_id IS NULL AND album_id IS NULL) \
                    OR (track_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM track_sources ts WHERE ts.id = artwork_cache.track_id)) \
                    OR (album_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM canonical_albums ca WHERE ca.id = artwork_cache.album_id))",
            )
            .execute(&mut *conn)
            .await?;
        }

        // 5. Recompute folder counts and prune empty library_folders nodes
        FolderRepository::recompute_all_folder_counts_tx(conn).await?;
        let _ = FolderRepository::prune_empty_folders_tx(conn).await?;

        let surviving_refs = Self::collect_referenced_artwork_paths_tx(conn).await?;
        Ok((result, surviving_refs))
    }

    pub async fn execute_library_cleanup(
        pool: &SqlitePool,
        options: &LibraryCleanupOptions,
        verified_missing_track_ids: &[String],
        skipped_offline_roots: Vec<String>,
    ) -> Result<(LibraryCleanupResult, HashSet<String>)> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::execute_library_cleanup_tx(
            tx.conn(),
            options,
            verified_missing_track_ids,
            skipped_offline_roots,
        )
        .await;
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
