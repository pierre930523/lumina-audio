pub mod ape_meta;
pub mod artwork;
pub mod cleanup;
pub mod dsd_meta;
pub mod encoding;
pub mod fingerprint;
pub mod ignore;
pub mod lyrics;
pub mod mapper;
pub mod metadata;
pub mod pipeline;
pub mod playlist;
pub mod riff_meta;
pub mod scanner;
pub mod tag_debug;
pub mod track_ops;
pub mod watcher;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use core_types::{
    CanonicalAlbum, ProviderKind, StreamKey, StreamProviderCapabilities, StreamSourceSpec,
    TrackSource,
};
use tokio::sync::{RwLock, mpsc::Sender};

pub use self::artwork::{
    ArtworkManager, ArtworkTarget, DiscoveredEmbeddedAsset, DiscoveredFileAsset,
    classify_asset_role, extract_embedded_asset_descriptors, index_assets_for_album_version,
    read_album_asset_bytes, resolve_safe_asset_file_path, scan_album_dir_assets,
};
pub use self::cleanup::{execute_library_cleanup, is_root_accessible, preview_library_cleanup};
pub use self::encoding::DetectedEncoding;
pub use self::fingerprint::compute_content_fingerprint;
pub use self::ignore::{
    classify_unsupported_container, is_playlist_sidecar, should_ignore_name, should_ignore_path,
};
pub use self::lyrics::{
    LyricLine, LyricWord, LyricsFormat, LyricsKind, LyricsManager, LyricsResult, LyricsSource,
    LyricsTarget,
};
pub use self::mapper::{
    AlbumKey, AlbumMapper, AlbumSyncMetadata, VersionSyncMetadata, compute_album_key,
    effective_album_dir, extract_edition_label, normalize_album_base_title,
    strip_disc_suffix_from_album,
};
pub use self::metadata::{
    ExtractOptions, ExtractedMetadata, MetadataExtractor, derive_album_and_artist_from_dir,
    derive_title_and_track_from_filename, detect_garbled_tags, extract_disc_number_from_dir_name,
    split_artists,
};
pub use self::pipeline::{IngestionConfig, IngestionPipeline};
pub use self::playlist::{ParsedPlaylist, ParsedPlaylistEntry, parse_m3u_content, parse_m3u_file};
pub use self::scanner::{
    COVER_ART_FILENAMES, DetailedScanOutput, DirectoryScanner, SCANNABLE_AUDIO_EXTENSIONS,
    ScanSkippedCandidate, find_folder_cover, find_folder_cover_in_files, is_scannable_audio,
    normalize_path,
};
pub use self::tag_debug::{
    ParsedMetadataSummary, RawTagField, TagBlockInspection, TagInspectionReport,
    format_tag_inspection_report, inspect_audio_tags,
};
pub use self::track_ops::{
    delete_single_track, move_file_to_os_trash, reidentify_single_track, rescan_single_track,
};
pub use self::watcher::StorageWatcherManager;
use crate::error::ProviderError;
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, ScanErrorItem, StreamResolver,
    SyncProgress, SyncResult, SyncResultSummary, validate_stream_key,
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

    async fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
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

        Ok(
            ResolvedStream::local_file(&track.external_track_id, track.format.clone())
                .with_replay_gain_from_track(track),
        )
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        self.sync_library_with_progress(None).await
    }

    async fn sync_library_with_progress(
        &self,
        progress_tx: Option<Sender<SyncProgress>>,
    ) -> Result<SyncResult, ProviderError> {
        let start_time = Instant::now();
        let root_paths = self.config.root_paths.clone();
        let follow_symlinks = self.config.follow_symlinks;
        let progress_tx_blocking = progress_tx.clone();

        let (total_files, successful_count, failed_count, errors, albums, tracks, album_meta) =
            tokio::task::spawn_blocking(move || -> Result<_, ProviderError> {
                let mut scanner = DirectoryScanner::new(follow_symlinks);
                let mut audio_files = Vec::new();
                for root in &root_paths {
                    audio_files.extend(scanner.scan_directory(root));
                }

                let total_files = audio_files.len();
                if let Some(ref tx) = progress_tx_blocking {
                    let _ = tx.blocking_send(SyncProgress::Started {
                        provider: ProviderKind::Local,
                        total_files: Some(total_files),
                    });
                }

                let mut valid_items = Vec::with_capacity(total_files);
                let mut errors = Vec::new();
                let throttle = Duration::from_millis(200);
                let mut last_emit: Option<Instant> = None;

                for (idx, file_path) in audio_files.into_iter().enumerate() {
                    let path_str = file_path.to_string_lossy().to_string();

                    match MetadataExtractor::extract_with_options(
                        &file_path,
                        ExtractOptions {
                            include_pictures: false,
                        },
                    ) {
                        Ok(meta) => {
                            valid_items.push((file_path, meta));
                            if let Some(ref tx) = progress_tx_blocking {
                                let now = Instant::now();
                                let is_last = idx + 1 == total_files;
                                let should_emit = is_last
                                    || last_emit
                                        .is_none_or(|prev| now.duration_since(prev) >= throttle);
                                if should_emit {
                                    let _ = tx.blocking_send(SyncProgress::FileScanned {
                                        path: path_str,
                                        current: idx + 1,
                                        total: Some(total_files),
                                    });
                                    last_emit = Some(now);
                                }
                            }
                        }
                        Err(e) => {
                            let err_str = e.to_string();
                            errors.push(ScanErrorItem {
                                path: path_str.clone(),
                                error: err_str.clone(),
                            });
                            if let Some(ref tx) = progress_tx_blocking {
                                let _ = tx.blocking_send(SyncProgress::Error {
                                    path: path_str,
                                    reason: err_str,
                                });
                            }
                        }
                    }
                }

                let successful_count = valid_items.len();
                let failed_count = errors.len();

                let (albums, tracks, album_meta) =
                    AlbumMapper::map_scanned_items_with_metadata(valid_items, ProviderKind::Local)?;

                Ok((
                    total_files,
                    successful_count,
                    failed_count,
                    errors,
                    albums,
                    tracks,
                    album_meta,
                ))
            })
            .await
            .map_err(|e| ProviderError::ScanError(format!("Local sync worker panicked: {e}")))??;

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

#[async_trait]
impl StreamResolver for LocalProvider {
    fn provider_id(&self) -> &'static str {
        "local"
    }

    fn capabilities(&self) -> StreamProviderCapabilities {
        StreamProviderCapabilities::local()
    }

    async fn resolve_source(&self, key: &StreamKey) -> Result<StreamSourceSpec, ProviderError> {
        validate_stream_key("local", key)?;

        let resolved_path = {
            let cached = self.cached_tracks.read().await;
            cached
                .iter()
                .find(|t| t.id == key.track_id || t.external_track_id == key.track_id)
                .map(|t| t.external_track_id.clone())
                .unwrap_or_else(|| key.track_id.clone())
        };

        let path = Path::new(&resolved_path);
        if !path.exists() || !path.is_file() {
            return Err(ProviderError::track_not_found("local", &key.track_id));
        }

        Ok(StreamSourceSpec::LocalFile {
            key: key.clone(),
            path: resolved_path,
            loudness: None,
            album_loudness: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_local_stream_resolver_resolves_file_and_rejects_missing() {
        let dir = tempdir().unwrap();
        let wav_path = dir.path().join("01 - Test Track.wav");

        // Write a minimal valid 44-byte RIFF/WAVE header so sync_library can scan it.
        let mut f = std::fs::File::create(&wav_path).unwrap();
        let data_size: u32 = 4;
        let riff_size: u32 = 36 + data_size;
        f.write_all(b"RIFF").unwrap();
        f.write_all(&riff_size.to_le_bytes()).unwrap();
        f.write_all(b"WAVEfmt ").unwrap();
        f.write_all(&16u32.to_le_bytes()).unwrap(); // fmt chunk size
        f.write_all(&1u16.to_le_bytes()).unwrap(); // PCM
        f.write_all(&2u16.to_le_bytes()).unwrap(); // 2 channels
        f.write_all(&44100u32.to_le_bytes()).unwrap(); // sample rate
        f.write_all(&(44100u32 * 4).to_le_bytes()).unwrap(); // byte rate
        f.write_all(&4u16.to_le_bytes()).unwrap(); // block align
        f.write_all(&16u16.to_le_bytes()).unwrap(); // bits per sample
        f.write_all(b"data").unwrap();
        f.write_all(&data_size.to_le_bytes()).unwrap();
        f.write_all(&[0u8; 4]).unwrap();
        f.flush().unwrap();

        let provider = LocalProvider::from_root(dir.path());
        assert_eq!(StreamResolver::provider_id(&provider), "local");
        assert_eq!(
            StreamResolver::capabilities(&provider),
            StreamProviderCapabilities::local()
        );

        let path_str = wav_path.to_string_lossy().to_string();
        let direct_key = StreamKey::new("local", &path_str, "native");
        let direct_spec = provider.resolve_source(&direct_key).await.unwrap();
        assert_eq!(
            direct_spec,
            StreamSourceSpec::LocalFile {
                key: direct_key,
                path: path_str.clone(),
                loudness: None,
                album_loudness: None,
            }
        );

        // Scan library and verify resolution via TrackSource.id
        let sync = provider.sync_library().await.unwrap();
        assert_eq!(sync.tracks.len(), 1);
        let track_id = sync.tracks[0].id.clone();
        let scanned_key = StreamKey::new("local", &track_id, "native");
        let scanned_spec = provider.resolve_source(&scanned_key).await.unwrap();
        match scanned_spec {
            StreamSourceSpec::LocalFile { key, path, .. } => {
                assert_eq!(key, scanned_key);
                assert!(Path::new(&path).is_file());
            }
            other => panic!("expected LocalFile, got {other:?}"),
        }

        // Missing file -> TrackNotFound
        let missing_err = provider
            .resolve_source(&StreamKey::new(
                "local",
                dir.path().join("missing.flac").to_string_lossy().as_ref(),
                "native",
            ))
            .await
            .unwrap_err();
        assert!(matches!(missing_err, ProviderError::TrackNotFound(_)));
    }
}
