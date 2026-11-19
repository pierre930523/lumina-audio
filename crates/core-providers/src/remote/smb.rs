use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_types::{AudioFormat, CanonicalAlbum, ProviderKind, TrackSource};
use tokio::sync::{mpsc::Sender, RwLock};

use super::uri::{make_basic_auth, RemoteShareUri};
use crate::error::ProviderError;
use crate::local::{
    derive_album_and_artist_from_dir, derive_title_and_track_from_filename, normalize_path,
    AlbumMapper, AlbumSyncMetadata, DirectoryScanner, ExtractedMetadata, MetadataExtractor,
};
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, ScanErrorItem, SyncProgress, SyncResult,
    SyncResultSummary,
};

pub const SMB_CREDENTIAL_SERVICE: &str = "com.lumina.audio.smb";

#[derive(Debug, Clone)]
pub struct SmbConfig {
    pub uri: RemoteShareUri,
    pub domain: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SmbEntry {
    pub relative_path: String,
    pub local_path: Option<PathBuf>,
    pub metadata: Option<ExtractedMetadata>,
}

#[async_trait]
pub trait SmbTransport: Send + Sync {
    async fn list_entries(&self, config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError>;

    async fn resolve_stream_target(
        &self,
        config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError>;
}

/// Pure-Rust Windows UNC transport (`\\host\share\...`), requiring zero native C SMB libraries.
#[derive(Debug, Default, Clone)]
pub struct UncSmbTransport;

impl UncSmbTransport {
    pub fn unc_root(config: &SmbConfig) -> PathBuf {
        let host = config.uri.host.trim();
        let share = config.uri.share_name.trim_matches(['/', '\\']);
        let rel = config
            .uri
            .relative_path
            .trim_matches(['/', '\\'])
            .replace('/', "\\");
        let base = if share.is_empty() {
            format!(r"\\{host}")
        } else if rel.is_empty() {
            format!(r"\\{host}\{share}")
        } else {
            format!(r"\\{host}\{share}\{rel}")
        };
        PathBuf::from(base)
    }
}

#[async_trait]
impl SmbTransport for UncSmbTransport {
    async fn list_entries(&self, config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError> {
        #[cfg(windows)]
        {
            let root = Self::unc_root(config);
            if !root.exists() {
                return Err(ProviderError::ScanError(format!(
                    "SMB UNC path '{}' does not exist or is unreachable",
                    root.display()
                )));
            }
            let mut scanner = DirectoryScanner::new(false);
            let files = scanner.scan_directory(&root);
            let entries = files
                .into_iter()
                .map(|p| {
                    let rel = p
                        .strip_prefix(&root)
                        .map(|r| r.to_string_lossy().replace('\\', "/"))
                        .unwrap_or_else(|_| p.to_string_lossy().replace('\\', "/"));
                    SmbEntry {
                        relative_path: rel,
                        local_path: Some(p),
                        metadata: None,
                    }
                })
                .collect();
            Ok(entries)
        }
        #[cfg(not(windows))]
        {
            let _ = config;
            Err(ProviderError::ScanError(
                "UNC SMB scanning requires Windows or a mounted FilesystemSmbTransport root"
                    .to_string(),
            ))
        }
    }

    async fn resolve_stream_target(
        &self,
        _config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError> {
        if external_track_id.starts_with("smb://") {
            return Ok(None);
        }
        let p = PathBuf::from(external_track_id);
        if p.exists() {
            Ok(Some(p))
        } else {
            Ok(None)
        }
    }
}

/// Pure-Rust filesystem-backed SMB transport for mounted shares or integration tests.
#[derive(Debug, Clone)]
pub struct FilesystemSmbTransport {
    mounted_root: PathBuf,
}

impl FilesystemSmbTransport {
    pub fn new(mounted_root: impl Into<PathBuf>) -> Self {
        Self {
            mounted_root: mounted_root.into(),
        }
    }

    fn effective_root(&self, config: &SmbConfig) -> PathBuf {
        let rel = config.uri.relative_path.trim_matches(['/', '\\']);
        if rel.is_empty() {
            self.mounted_root.clone()
        } else {
            let candidate = self.mounted_root.join(rel);
            if candidate.exists() {
                candidate
            } else {
                self.mounted_root.clone()
            }
        }
    }
}

#[async_trait]
impl SmbTransport for FilesystemSmbTransport {
    async fn list_entries(&self, config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError> {
        let root = self.effective_root(config);
        if !root.exists() {
            return Err(ProviderError::ScanError(format!(
                "Mounted SMB root '{}' does not exist",
                root.display()
            )));
        }
        let mut scanner = DirectoryScanner::new(false);
        let files = scanner.scan_directory(&root);
        let entries = files
            .into_iter()
            .map(|p| {
                let rel = p
                    .strip_prefix(&self.mounted_root)
                    .map(|r| r.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_else(|_| p.to_string_lossy().replace('\\', "/"));
                SmbEntry {
                    relative_path: rel,
                    local_path: Some(p),
                    metadata: None,
                }
            })
            .collect();
        Ok(entries)
    }

    async fn resolve_stream_target(
        &self,
        _config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError> {
        let direct = PathBuf::from(external_track_id);
        if direct.exists() {
            return Ok(Some(direct));
        }
        let trimmed = external_track_id.trim_start_matches(['/', '\\']);
        let joined = self.mounted_root.join(trimmed);
        if joined.exists() {
            Ok(Some(joined))
        } else {
            Ok(None)
        }
    }
}

/// In-memory mock SMB transport for deterministic tests.
#[derive(Default)]
pub struct MockSmbTransport {
    entries: RwLock<Vec<SmbEntry>>,
    resolved_targets: RwLock<HashMap<String, PathBuf>>,
}

impl MockSmbTransport {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn add_entry(&self, entry: SmbEntry) {
        self.entries.write().await.push(entry);
    }

    pub async fn register_target(&self, external_track_id: impl Into<String>, path: PathBuf) {
        self.resolved_targets
            .write()
            .await
            .insert(external_track_id.into(), path);
    }
}

#[async_trait]
impl SmbTransport for MockSmbTransport {
    async fn list_entries(&self, _config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError> {
        Ok(self.entries.read().await.clone())
    }

    async fn resolve_stream_target(
        &self,
        _config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError> {
        Ok(self.resolved_targets.read().await.get(external_track_id).cloned())
    }
}

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

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<CanonicalAlbum>, ProviderError> {
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

        for (idx, entry) in entries.into_iter().enumerate() {
            let virtual_path = entry
                .local_path
                .clone()
                .unwrap_or_else(|| PathBuf::from(&entry.relative_path));
            rel_by_norm_path.insert(normalize_path(&virtual_path), entry.relative_path.clone());

            let meta_res = if let Some(meta) = entry.metadata {
                Ok(meta)
            } else if let Some(ref local) = entry.local_path {
                MetadataExtractor::extract(local)
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
                        let _ = tx
                            .send(SyncProgress::FileScanned {
                                path: entry.relative_path,
                                current: idx + 1,
                                total: Some(total),
                            })
                            .await;
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
        let (albums, mut tracks, album_meta) =
            AlbumMapper::map_scanned_items_with_metadata(valid_items, ProviderKind::Smb)?;

        // Normalize external_track_id to relative path when no local_path exists on MockSmbTransport
        for trk in &mut tracks {
            if !Path::new(&trk.external_track_id).exists() {
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
