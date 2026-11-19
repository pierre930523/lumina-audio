pub mod artwork;
pub mod dsd_meta;
pub mod lyrics;
pub mod mapper;
pub mod metadata;
pub mod riff_meta;
pub mod scanner;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_types::{CanonicalAlbum, ProviderKind, TrackSource};
use tokio::sync::{mpsc::Sender, RwLock};

use crate::error::ProviderError;
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, ScanErrorItem, SyncProgress, SyncResult,
    SyncResultSummary,
};
pub use self::artwork::{ArtworkManager, ArtworkTarget};
pub use self::lyrics::{
    LyricLine, LyricWord, LyricsFormat, LyricsKind, LyricsManager, LyricsResult, LyricsSource,
    LyricsTarget,
};
pub use self::mapper::{
    extract_edition_label, normalize_album_base_title, AlbumMapper, AlbumSyncMetadata,
};
pub use self::metadata::{
    derive_album_and_artist_from_dir, derive_title_and_track_from_filename, ExtractedMetadata,
    MetadataExtractor,
};
pub use self::scanner::{
    find_folder_cover, find_folder_cover_in_files, is_scannable_audio, normalize_path,
    DirectoryScanner, COVER_ART_FILENAMES, SCANNABLE_AUDIO_EXTENSIONS,
};

#[derive(Debug, Clone, Default)]
pub struct LocalProviderConfig {
    pub root_paths: Vec<PathBuf>,
    pub follow_symlinks: bool,
}

pub struct LocalProvider {
    config: LocalProviderConfig,
    cached_albums: Arc<RwLock<Vec<CanonicalAlbum>>>,
    cached_tracks: Arc<RwLock<Vec<TrackSource>>>,
    cached_album_metadata: Arc<RwLock<HashMap<String, AlbumSyncMetadata>>>,
}

impl LocalProvider {
    pub fn new(config: LocalProviderConfig) -> Self {
        Self {
            config,
            cached_albums: Arc::new(RwLock::new(Vec::new())),
            cached_tracks: Arc::new(RwLock::new(Vec::new())),
            cached_album_metadata: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub fn from_root(root: impl Into<PathBuf>) -> Self {
        Self::new(LocalProviderConfig {
            root_paths: vec![root.into()],
            follow_symlinks: false,
        })
    }

    pub fn config(&self) -> &LocalProviderConfig {
        &self.config
    }

    pub async fn sync_library_with_metadata(
        &self,
        progress_tx: Option<Sender<SyncProgress>>,
    ) -> Result<(SyncResult, HashMap<String, AlbumSyncMetadata>), ProviderError> {
        let sync = self.sync_library_with_progress(progress_tx).await?;
        let meta = self.cached_album_metadata.read().await.clone();
        Ok((sync, meta))
    }
}

#[async_trait]
impl MusicProvider for LocalProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Local
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::local()
    }

    async fn is_authenticated(&self) -> bool {
        true
    }

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let q = query.trim().to_ascii_lowercase();
        if q.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }

        let albums = self.cached_albums.read().await;
        let matches: Vec<CanonicalAlbum> = albums
            .iter()
            .filter(|a| {
                a.title.to_ascii_lowercase().contains(&q)
                    || a.artist_name.to_ascii_lowercase().contains(&q)
            })
            .take(limit)
            .cloned()
            .collect();

        Ok(matches)
    }

    async fn resolve_stream(&self, track: &TrackSource) -> Result<ResolvedStream, ProviderError> {
        let path = Path::new(&track.external_track_id);
        if !path.exists() {
            return Err(ProviderError::TrackNotFound(format!(
                "Local track file not found: {}",
                track.external_track_id
            )));
        }

        Ok(ResolvedStream::local_file(
            &track.external_track_id,
            track.format.clone(),
        )
        .with_replay_gain_from_track(track))
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        self.sync_library_with_progress(None).await
    }

    async fn sync_library_with_progress(
        &self,
        progress_tx: Option<Sender<SyncProgress>>,
    ) -> Result<SyncResult, ProviderError> {
        let start_time = Instant::now();

        let mut scanner = DirectoryScanner::new(self.config.follow_symlinks);
        let mut audio_files = Vec::new();

        for root in &self.config.root_paths {
            let found = scanner.scan_directory(root);
            audio_files.extend(found);
        }

        let total_files = audio_files.len();

        if let Some(ref tx) = progress_tx {
            let _ = tx
                .send(SyncProgress::Started {
                    provider: ProviderKind::Local,
                    total_files: Some(total_files),
                })
                .await;
        }

        let mut valid_items = Vec::new();
        let mut errors = Vec::new();

        for (idx, file_path) in audio_files.into_iter().enumerate() {
            let path_str = file_path.to_string_lossy().to_string();

            match MetadataExtractor::extract(&file_path) {
                Ok(meta) => {
                    valid_items.push((file_path, meta));
                    if let Some(ref tx) = progress_tx {
                        let _ = tx
                            .send(SyncProgress::FileScanned {
                                path: path_str,
                                current: idx + 1,
                                total: Some(total_files),
                            })
                            .await;
                    }
                }
                Err(e) => {
                    let err_str = e.to_string();
                    errors.push(ScanErrorItem {
                        path: path_str.clone(),
                        error: err_str.clone(),
                    });
                    if let Some(ref tx) = progress_tx {
                        let _ = tx
                            .send(SyncProgress::Error {
                                path: path_str,
                                reason: err_str,
                            })
                            .await;
                    }
                }
            }
        }

        let successful_count = valid_items.len();
        let failed_count = errors.len();

        let (albums, tracks, album_meta) =
            AlbumMapper::map_scanned_items_with_metadata(valid_items, ProviderKind::Local)?;

        // Update in-memory cache
        {
            let mut cached_albs = self.cached_albums.write().await;
            *cached_albs = albums.clone();
            let mut cached_trks = self.cached_tracks.write().await;
            *cached_trks = tracks.clone();
            let mut cached_meta = self.cached_album_metadata.write().await;
            *cached_meta = album_meta;
        }

        let duration_ms = start_time.elapsed().as_millis() as u64;

        if let Some(ref tx) = progress_tx {
            let _ = tx
                .send(SyncProgress::Completed {
                    summary: SyncResultSummary {
                        provider: ProviderKind::Local,
                        albums_count: albums.len(),
                        tracks_count: tracks.len(),
                        errors_count: failed_count,
                        duration_ms,
                    },
                })
                .await;
        }

        Ok(SyncResult {
            albums,
            tracks,
            scanned_files_count: total_files,
            successful_tracks_count: successful_count,
            failed_files_count: failed_count,
            errors,
        })
    }

    async fn last_sync_album_metadata(&self) -> HashMap<String, AlbumSyncMetadata> {
        self.cached_album_metadata.read().await.clone()
    }
}
