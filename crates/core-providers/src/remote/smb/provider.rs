use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_types::{AudioFormat, CanonicalAlbum, ProviderKind, TrackSource};
use tokio::sync::{RwLock, mpsc::Sender};

use super::super::uri::make_basic_auth;
use super::{SMB_CREDENTIAL_SERVICE, SmbConfig, SmbTransport, UncSmbTransport};
use crate::error::ProviderError;
use crate::local::{
    AlbumMapper, AlbumSyncMetadata, ExtractedMetadata, MetadataExtractor,
    derive_album_and_artist_from_dir, derive_title_and_track_from_filename, normalize_path,
};
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, ScanErrorItem, SyncProgress, SyncResult,
    SyncResultSummary,
};

pub struct SmbProvider {
    config: SmbConfig,
    transport: Arc<dyn SmbTransport>,
    credential_store: Option<Arc<dyn CredentialStore>>,
    online: Arc<RwLock<bool>>,
    cached_albums: Arc<RwLock<Vec<CanonicalAlbum>>>,
    cached_tracks: Arc<RwLock<Vec<TrackSource>>>,
    cached_album_metadata: Arc<RwLock<HashMap<String, AlbumSyncMetadata>>>,
}

impl SmbProvider {
    pub fn new(config: SmbConfig, credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::with_transport(config, Arc::new(UncSmbTransport), credential_store)
    }

    pub fn with_transport(
        config: SmbConfig,
        transport: Arc<dyn SmbTransport>,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self {
            config,
            transport,
            credential_store,
            online: Arc::new(RwLock::new(true)),
            cached_albums: Arc::new(RwLock::new(Vec::new())),
            cached_tracks: Arc::new(RwLock::new(Vec::new())),
            cached_album_metadata: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn set_online(&self, online: bool) {
        let mut w = self.online.write().await;
        *w = online;
    }

    pub async fn is_online(&self) -> bool {
        *self.online.read().await
    }

    pub fn config(&self) -> &SmbConfig {
        &self.config
    }

    async fn get_auth_header(&self) -> Option<(String, String)> {
        if let (Some(u), Some(p)) = (&self.config.uri.username, &self.config.uri.password) {
            return Some(("Authorization".to_string(), make_basic_auth(u, p)));
        }

        if let Some(ref store) = self.credential_store {
            let key = format!("{}:{}", self.config.uri.host, self.config.uri.share_name);
            if let Ok(Some(secret)) = store.get_secret(SMB_CREDENTIAL_SERVICE, &key).await {
                if let Some(colon) = secret.find(':') {
                    let u = &secret[..colon];
                    let p = &secret[colon + 1..];
                    return Some(("Authorization".to_string(), make_basic_auth(u, p)));
                } else {
                    let u = self.config.uri.username.as_deref().unwrap_or("guest");
                    return Some(("Authorization".to_string(), make_basic_auth(u, &secret)));
                }
            }
        }

        None
    }
}

#[async_trait]
impl MusicProvider for SmbProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Smb
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::smb()
    }

    async fn is_authenticated(&self) -> bool {
        if self.config.uri.is_authenticated {
            return true;
        }

        if let Some(ref store) = self.credential_store {
            let key = format!("{}:{}", self.config.uri.host, self.config.uri.share_name);
            if let Ok(Some(secret)) = store.get_secret(SMB_CREDENTIAL_SERVICE, &key).await {
                return !secret.trim().is_empty();
            }
        }

        false
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
        Ok(albums
            .iter()
            .filter(|a| {
                a.title.to_ascii_lowercase().contains(&q)
                    || a.artist_name.to_ascii_lowercase().contains(&q)
            })
            .take(limit)
            .cloned()
            .collect())
    }

    async fn resolve_stream(&self, track: &TrackSource) -> Result<ResolvedStream, ProviderError> {
        if !self.is_online().await {
            return Err(ProviderError::StreamResolutionFailed(format!(
                "SMB share '{}/{}' is offline",
                self.config.uri.host, self.config.uri.share_name
            )));
        }

        if let Some(local_target) = self
            .transport
            .resolve_stream_target(&self.config, &track.external_track_id)
            .await?
        {
            return Ok(ResolvedStream::local_file(
                local_target.to_string_lossy().into_owned(),
                track.format.clone(),
            )
            .with_replay_gain_from_track(track));
        }

        let smb_url = if track.external_track_id.starts_with("smb://")
            || track.external_track_id.starts_with(r"\\")
        {
            track.external_track_id.clone()
        } else {
            let host = self.config.uri.formatted_host();
            let port_part = if self.config.uri.port != 445 && self.config.uri.port != 0 {
                format!(":{}", self.config.uri.port)
            } else {
                String::new()
            };
            format!(
                "smb://{host}{port_part}/{}/{}",
                self.config.uri.share_name,
                track.external_track_id.trim_start_matches('/')
            )
        };

        let mut headers = Vec::new();
        if let Some(auth_hdr) = self.get_auth_header().await {
            headers.push(auth_hdr);
        }

        Ok(ResolvedStream {
            url_or_path: smb_url,
            format: track.format.clone(),
            headers,
            hint_extension: None,
            replay_gain_track_db: track.replay_gain_track_db,
            replay_gain_album_db: track.replay_gain_album_db,
            replay_gain_track_peak: track.replay_gain_track_peak,
            replay_gain_album_peak: track.replay_gain_album_peak,
        })
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        self.sync_library_with_progress(None).await
    }

    async fn sync_library_with_progress(
        &self,
        progress_tx: Option<Sender<SyncProgress>>,
    ) -> Result<SyncResult, ProviderError> {
        if !self.is_online().await {
            return Err(ProviderError::StreamResolutionFailed(
                "SMB share is offline".into(),
            ));
        }

        let start = Instant::now();
        let entries = self.transport.list_entries(&self.config).await?;
        let total = entries.len();

        if let Some(ref tx) = progress_tx {
            let _ = tx
                .send(SyncProgress::Started {
                    provider: ProviderKind::Smb,
                    total_files: Some(total),
                })
                .await;
        }

        let mut valid_items: Vec<(PathBuf, ExtractedMetadata)> = Vec::new();
        let mut errors: Vec<ScanErrorItem> = Vec::new();
        let mut rel_by_norm_path: HashMap<String, String> = HashMap::new();
        let mut local_norm_paths: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        let mut last_progress_emit = Instant::now();

        for (idx, entry) in entries.into_iter().enumerate() {
            if entry.local_path.is_none() {
                let rel_path = Path::new(&entry.relative_path);
                if crate::local::ignore::should_ignore_path(rel_path)
                    || !crate::local::scanner::is_scannable_audio(rel_path)
                {
                    continue;
                }
            }

            let virtual_path = entry
                .local_path
                .clone()
                .unwrap_or_else(|| PathBuf::from(&entry.relative_path));
            let norm_vpath = normalize_path(&virtual_path);
            if entry.local_path.is_some() {
                local_norm_paths.insert(norm_vpath.clone());
            }
            rel_by_norm_path.insert(norm_vpath, entry.relative_path.clone());

            let meta_res = if let Some(meta) = entry.metadata {
                Ok(meta)
            } else if let Some(local) = entry.local_path.clone() {
                tokio::task::spawn_blocking(move || {
                    MetadataExtractor::extract_with_options(
                        &local,
                        crate::local::ExtractOptions {
                            include_pictures: false,
                        },
                    )
                })
                .await
                .map_err(|e| {
                    ProviderError::ScanError(format!("SMB metadata probe panicked: {e}"))
                })?
            } else {
                let (title, track_number) =
                    derive_title_and_track_from_filename(Path::new(&entry.relative_path));
                let (album, artist) =
                    derive_album_and_artist_from_dir(Path::new(&entry.relative_path));
                Ok(ExtractedMetadata {
                    title,
                    artist,
                    album,
                    track_number,
                    format: AudioFormat::cd_quality(),
                    ..Default::default()
                })
            };

            match meta_res {
                Ok(meta) => {
                    valid_items.push((virtual_path, meta));
                    if let Some(ref tx) = progress_tx {
                        if last_progress_emit.elapsed() >= std::time::Duration::from_millis(200)
                            || idx + 1 == total
                        {
                            let _ = tx
                                .send(SyncProgress::FileScanned {
                                    path: entry.relative_path,
                                    current: idx + 1,
                                    total: Some(total),
                                })
                                .await;
                            last_progress_emit = Instant::now();
                        }
                    }
                }
                Err(e) => {
                    let reason = e.to_string();
                    errors.push(ScanErrorItem {
                        path: entry.relative_path.clone(),
                        error: reason.clone(),
                    });
                    if let Some(ref tx) = progress_tx {
                        let _ = tx
                            .send(SyncProgress::Error {
                                path: entry.relative_path,
                                reason,
                            })
                            .await;
                    }
                }
            }
        }

        let successful = valid_items.len();
        let failed = errors.len();
        let (albums, mut tracks, album_meta) = tokio::task::spawn_blocking(move || {
            AlbumMapper::map_scanned_items_with_metadata(valid_items, ProviderKind::Smb)
        })
        .await
        .map_err(|e| ProviderError::ScanError(format!("SMB AlbumMapper panicked: {e}")))??;

        // Normalize external_track_id to relative path when no local_path exists on MockSmbTransport
        for trk in &mut tracks {
            if !local_norm_paths.contains(&trk.external_track_id) {
                if let Some(rel) = rel_by_norm_path.get(&trk.external_track_id) {
                    trk.external_track_id = rel.clone();
                }
            }
        }

        *self.cached_albums.write().await = albums.clone();
        *self.cached_tracks.write().await = tracks.clone();
        *self.cached_album_metadata.write().await = album_meta;

        let duration_ms = start.elapsed().as_millis() as u64;
        if let Some(ref tx) = progress_tx {
            let _ = tx
                .send(SyncProgress::Completed {
                    summary: SyncResultSummary {
                        provider: ProviderKind::Smb,
                        albums_count: albums.len(),
                        tracks_count: tracks.len(),
                        errors_count: failed,
                        duration_ms,
                    },
                })
                .await;
        }

        Ok(SyncResult {
            albums,
            tracks,
            scanned_files_count: total,
            successful_tracks_count: successful,
            failed_files_count: failed,
            errors,
        })
    }

    async fn last_sync_album_metadata(&self) -> HashMap<String, AlbumSyncMetadata> {
        self.cached_album_metadata.read().await.clone()
    }
}
