mod client;
mod xml;

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_types::{AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, TrackSource};
use tokio::sync::{RwLock, mpsc::Sender};

use super::uri::RemoteShareUri;
use crate::error::ProviderError;
use crate::http::{HttpTransport, ReqwestHttpTransport};
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, SyncProgress, SyncResult,
};

pub const WEBDAV_CREDENTIAL_SERVICE: &str = "com.lumina.audio.webdav";

#[derive(Debug, Clone)]
pub struct WebDavConfig {
    pub uri: RemoteShareUri,
}

pub type WebDavEntryMetaMap = HashMap<String, (Option<String>, Option<u64>)>;

pub struct WebDavProvider {
    pub(super) config: WebDavConfig,
    pub(super) transport: Arc<dyn HttpTransport>,
    pub(super) credential_store: Option<Arc<dyn CredentialStore>>,
    pub(super) online: Arc<RwLock<bool>>,
    pub(super) cached_albums: Arc<RwLock<Vec<CanonicalAlbum>>>,
    pub(super) cached_tracks: Arc<RwLock<Vec<TrackSource>>>,
    pub(super) cached_entry_metadata: Arc<RwLock<WebDavEntryMetaMap>>,
}

impl WebDavProvider {
    pub fn new(config: WebDavConfig, credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::with_transport(
            config,
            Arc::new(ReqwestHttpTransport::new()),
            credential_store,
        )
    }

    pub fn with_transport(
        config: WebDavConfig,
        transport: Arc<dyn HttpTransport>,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self {
            config,
            transport,
            credential_store,
            online: Arc::new(RwLock::new(true)),
            cached_albums: Arc::new(RwLock::new(Vec::new())),
            cached_tracks: Arc::new(RwLock::new(Vec::new())),
            cached_entry_metadata: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn last_entry_metadata(&self) -> HashMap<String, (Option<String>, Option<u64>)> {
        self.cached_entry_metadata.read().await.clone()
    }

    pub async fn set_online(&self, online: bool) {
        let mut w = self.online.write().await;
        *w = online;
    }

    pub async fn is_online(&self) -> bool {
        *self.online.read().await
    }

    pub fn config(&self) -> &WebDavConfig {
        &self.config
    }
}

#[async_trait]
impl MusicProvider for WebDavProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::WebDav
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::webdav()
    }

    async fn is_authenticated(&self) -> bool {
        if self.config.uri.is_authenticated {
            return true;
        }

        if let Some(ref store) = self.credential_store {
            let key = format!("{}:{}", self.config.uri.host, self.config.uri.port);
            if let Ok(Some(secret)) = store.get_secret(WEBDAV_CREDENTIAL_SERVICE, &key).await {
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
                "WebDAV server '{}:{}' is offline",
                self.config.uri.host, self.config.uri.port
            )));
        }

        let base_path = self.root_rel_prefix_decoded();
        let track_rel = track.external_track_id.trim_start_matches('/');

        let stream_url = if track.external_track_id.starts_with("http://")
            || track.external_track_id.starts_with("https://")
        {
            track.external_track_id.clone()
        } else if base_path.is_empty() {
            self.url_for_dav_path(track_rel)
        } else {
            self.url_for_dav_path(&format!("{base_path}/{track_rel}"))
        };

        let mut headers = Vec::new();
        if let Some(auth_hdr) = self.get_auth_header().await {
            headers.push(auth_hdr);
        }

        let hint = Path::new(track_rel)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase());

        Ok(
            ResolvedStream::http_stream(stream_url, track.format.clone(), headers, hint)
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
        self.sync_library_impl(progress_tx).await
    }
}

pub(super) fn infer_format_from_ext(path: &Path) -> AudioFormat {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "dsf" => AudioFormat::dsd(AudioCodec::Dsf, 2_822_400, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "dff" => AudioFormat::dsd(AudioCodec::Dsdiff, 2_822_400, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "mp3" => AudioFormat::pcm(AudioCodec::Mp3, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "aac" => AudioFormat::pcm(AudioCodec::Aac, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "m4a" | "alac" => AudioFormat::pcm(AudioCodec::Alac, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "wav" | "wave" => AudioFormat::pcm(AudioCodec::Wav, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "aiff" | "aif" => AudioFormat::pcm(AudioCodec::Aiff, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "ogg" | "opus" => AudioFormat::pcm(AudioCodec::Opus, 48000, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        _ => AudioFormat::cd_quality(),
    }
}
