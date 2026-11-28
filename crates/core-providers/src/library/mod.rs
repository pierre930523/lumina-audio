mod dedup;
pub(crate) mod match_policy;
mod persist;
mod sync;
mod sync_helpers;

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use core_db::{LibraryRepository, SqlitePool};
use core_types::{AlbumDetail, ArtistDetail, CanonicalAlbum, ScanProgressEvent, TrackSource};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::error::ProviderError;
use crate::local::AlbumSyncMetadata;
use crate::traits::SyncResult;

pub(super) const DB_BATCH_TRACKS: usize = 200;
pub(super) const PROGRESS_THROTTLE: Duration = Duration::from_millis(200);

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SyncPersistReport {
    pub albums_inserted: usize,
    pub albums_matched: usize,
    pub albums_merged: usize,
    pub versions_upserted: usize,
    pub tracks_upserted: usize,
    pub search_index_entries: usize,
}

pub(super) struct AlbumEntry<'a> {
    pub(super) album: &'a CanonicalAlbum,
    pub(super) versions: Vec<(&'a core_types::AlbumVersion, Vec<(usize, &'a TrackSource)>)>,
    pub(super) track_count: usize,
}

pub(super) struct ResolvedChunkAlbum<'a> {
    pub(super) entry: &'a AlbumEntry<'a>,
    pub(super) primary_id: Option<String>,
    pub(super) is_group_locked: bool,
    pub(super) upc: Option<String>,
    pub(super) mb_rg_id: Option<String>,
    pub(super) base_title: String,
    pub(super) is_unknown: bool,
    pub(super) is_compilation: bool,
    pub(super) isrcs: HashSet<String>,
    pub(super) max_version_tracks: usize,
}

pub struct LibrarySyncService;

impl LibrarySyncService {
    pub async fn persist_sync_result(
        pool: &SqlitePool,
        result: &SyncResult,
    ) -> Result<SyncPersistReport, ProviderError> {
        Self::persist_sync_result_with_metadata(pool, result, &HashMap::new()).await
    }

    pub async fn persist_sync_result_with_metadata(
        pool: &SqlitePool,
        result: &SyncResult,
        album_meta: &HashMap<String, AlbumSyncMetadata>,
    ) -> Result<SyncPersistReport, ProviderError> {
        Self::persist_provider_albums(pool, &result.albums, &result.tracks, album_meta).await
    }

    pub async fn persist_provider_albums(
        pool: &SqlitePool,
        albums: &[CanonicalAlbum],
        tracks: &[TrackSource],
        album_meta: &HashMap<String, AlbumSyncMetadata>,
    ) -> Result<SyncPersistReport, ProviderError> {
        let (report, _) =
            persist::persist_provider_albums_inner(pool, albums, tracks, album_meta, true).await?;
        Ok(report)
    }

    /// Deduplicates existing canonical albums in SQLite across MBID, UPC, verified ISRC overlap
    /// (`>= 60%` + compatible track count), and normalized title+artist (including edition stripping),
    /// while protecting `"Unknown Album"` / `"Unknown Artist"` and compilation vs studio albums
    /// from false merges.
    pub async fn deduplicate_library(pool: &SqlitePool) -> Result<usize, ProviderError> {
        dedup::deduplicate_library(pool).await
    }

    pub async fn list_canonical_albums(
        pool: &SqlitePool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        LibraryRepository::list_canonical_albums(pool, limit, offset)
            .await
            .map_err(db_err)
    }

    pub async fn get_album_detail(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Option<AlbumDetail>, ProviderError> {
        LibraryRepository::get_album_detail(pool, album_id)
            .await
            .map_err(db_err)
    }

    pub async fn get_artist_detail(
        pool: &SqlitePool,
        artist_id: &str,
    ) -> Result<Option<ArtistDetail>, ProviderError> {
        LibraryRepository::get_artist_detail(pool, artist_id)
            .await
            .map_err(db_err)
    }

    pub async fn rescan_tags(
        pool: &SqlitePool,
        dir_or_null: Option<&str>,
        force: bool,
    ) -> Result<core_types::RescanReport, ProviderError> {
        Self::rescan_tags_with_progress(pool, dir_or_null, force, None, None).await
    }

    pub async fn rescan_tags_with_progress(
        pool: &SqlitePool,
        dir_or_null: Option<&str>,
        force: bool,
        progress_tx: Option<&broadcast::Sender<ScanProgressEvent>>,
        scan_id: Option<String>,
    ) -> Result<core_types::RescanReport, ProviderError> {
        sync::rescan_tags_with_progress(pool, dir_or_null, force, progress_tx, scan_id).await
    }
}

pub(crate) fn db_err(e: impl std::fmt::Display) -> ProviderError {
    ProviderError::Other(format!("Database error: {e}"))
}
