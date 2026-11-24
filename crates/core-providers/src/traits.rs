use std::collections::HashMap;
use std::path::Path;
use async_trait::async_trait;
use core_types::{
    AudioFormat, CanonicalAlbum, ProviderKind, StreamKey, StreamProviderCapabilities,
    StreamSourceSpec, TrackSource,
};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc::Sender;

use crate::error::ProviderError;
use crate::local::AlbumSyncMetadata;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderCapabilities {
    pub supports_token_login: bool,
    pub supports_oauth: bool,
    pub supports_word_lyrics: bool,
    pub supports_hi_res: bool,
    pub supports_filesystem_scan: bool,
    pub supports_catalog_search: bool,
    pub supports_stream_resolution: bool,
    pub supports_favorites_sync: bool,
    #[serde(default)]
    pub streaming: StreamProviderCapabilities,
}

impl ProviderCapabilities {
    pub fn local() -> Self {
        Self {
            supports_token_login: false,
            supports_oauth: false,
            supports_word_lyrics: true,
            supports_hi_res: true,
            supports_filesystem_scan: true,
            supports_catalog_search: false,
            supports_stream_resolution: true,
            supports_favorites_sync: false,
            streaming: StreamProviderCapabilities::local(),
        }
    }

    pub fn smb() -> Self {
        Self {
            supports_token_login: true,
            supports_oauth: false,
            supports_word_lyrics: true,
            supports_hi_res: true,
            supports_filesystem_scan: true,
            supports_catalog_search: false,
            supports_stream_resolution: true,
            supports_favorites_sync: false,
            streaming: StreamProviderCapabilities::default(),
        }
    }

    pub fn webdav() -> Self {
        Self {
            supports_token_login: true,
            supports_oauth: false,
            supports_word_lyrics: true,
            supports_hi_res: true,
            supports_filesystem_scan: true,
            supports_catalog_search: false,
            supports_stream_resolution: true,
            supports_favorites_sync: false,
            streaming: StreamProviderCapabilities::default(),
        }
    }

    pub fn qobuz() -> Self {
        Self {
            supports_token_login: true,
            supports_oauth: false,
            supports_word_lyrics: true,
            supports_hi_res: true,
            supports_filesystem_scan: false,
            supports_catalog_search: true,
            supports_stream_resolution: true,
            supports_favorites_sync: true,
            streaming: StreamProviderCapabilities::qobuz(),
        }
    }

    pub fn tidal() -> Self {
        Self {
            supports_token_login: false,
            supports_oauth: true,
            supports_word_lyrics: false,
            supports_hi_res: true,
            supports_filesystem_scan: false,
            supports_catalog_search: true,
            supports_stream_resolution: true,
            supports_favorites_sync: true,
            streaming: StreamProviderCapabilities::tidal(),
        }
    }

    pub fn deezer() -> Self {
        Self {
            supports_token_login: true,
            supports_oauth: false,
            supports_word_lyrics: true,
            supports_hi_res: false,
            supports_filesystem_scan: false,
            supports_catalog_search: true,
            supports_stream_resolution: true,
            supports_favorites_sync: true,
            streaming: StreamProviderCapabilities::deezer(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResolvedStream {
    pub url_or_path: String,
    pub format: AudioFormat,
    pub headers: Vec<(String, String)>,
    pub hint_extension: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_album_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_peak: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_album_peak: Option<f64>,
}

impl ResolvedStream {
    pub fn local_file(path: impl Into<String>, format: AudioFormat) -> Self {
        let p = path.into();
        let hint = Path::new(&p)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_string());
        Self {
            url_or_path: p,
            format,
            headers: Vec::new(),
            hint_extension: hint,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn http_stream(
        url: impl Into<String>,
        format: AudioFormat,
        headers: Vec<(String, String)>,
        hint: Option<String>,
    ) -> Self {
        Self {
            url_or_path: url.into(),
            format,
            headers,
            hint_extension: hint,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn with_replay_gain(
        mut self,
        track_db: Option<f64>,
        album_db: Option<f64>,
        track_peak: Option<f64>,
        album_peak: Option<f64>,
    ) -> Self {
        self.replay_gain_track_db = track_db;
        self.replay_gain_album_db = album_db;
        self.replay_gain_track_peak = track_peak;
        self.replay_gain_album_peak = album_peak;
        self
    }

    pub fn with_replay_gain_from_track(mut self, track: &TrackSource) -> Self {
        if self.replay_gain_track_db.is_none() {
            self.replay_gain_track_db = track.replay_gain_track_db;
        }
        if self.replay_gain_album_db.is_none() {
            self.replay_gain_album_db = track.replay_gain_album_db;
        }
        if self.replay_gain_track_peak.is_none() {
            self.replay_gain_track_peak = track.replay_gain_track_peak;
        }
        if self.replay_gain_album_peak.is_none() {
            self.replay_gain_album_peak = track.replay_gain_album_peak;
        }
        self
    }

    pub fn is_local_file(&self) -> bool {
        self.headers.is_empty()
            && !self.url_or_path.starts_with("http://")
            && !self.url_or_path.starts_with("https://")
            && !self.url_or_path.starts_with("smb://")
            && !self.url_or_path.starts_with("dav://")
            && !self.url_or_path.starts_with("davs://")
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ScanErrorItem {
    pub path: String,
    pub error: String,
}

#[derive(Debug, Clone, Default)]
pub struct SyncResult {
    pub albums: Vec<CanonicalAlbum>,
    pub tracks: Vec<TrackSource>,
    pub scanned_files_count: usize,
    pub successful_tracks_count: usize,
    pub failed_files_count: usize,
    pub errors: Vec<ScanErrorItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncResultSummary {
    pub provider: ProviderKind,
    pub albums_count: usize,
    pub tracks_count: usize,
    pub errors_count: usize,
    pub duration_ms: u64,
}

#[derive(Debug, Clone)]
pub enum SyncProgress {
    Started {
        provider: ProviderKind,
        total_files: Option<usize>,
    },
    FileScanned {
        path: String,
        current: usize,
        total: Option<usize>,
    },
    AlbumDiscovered {
        title: String,
        artist: String,
    },
    Error {
        path: String,
        reason: String,
    },
    Completed {
        summary: SyncResultSummary,
    },
}

/// Unified provider contract for Local, SMB/WebDAV, Qobuz, Tidal, and Deezer.
#[async_trait]
pub trait MusicProvider: Send + Sync {
    fn kind(&self) -> ProviderKind;
    fn capabilities(&self) -> ProviderCapabilities;

    async fn is_authenticated(&self) -> bool;
    async fn search(&self, query: &str, limit: usize) -> Result<Vec<CanonicalAlbum>, ProviderError>;
    async fn resolve_stream(&self, track: &TrackSource) -> Result<ResolvedStream, ProviderError>;

    async fn sync_library(&self) -> Result<SyncResult, ProviderError>;

    async fn sync_library_with_progress(
        &self,
        progress_tx: Option<Sender<SyncProgress>>,
    ) -> Result<SyncResult, ProviderError> {
        let _ = progress_tx;
        self.sync_library().await
    }

    async fn get_album(&self, external_album_id: &str) -> Result<CanonicalAlbum, ProviderError> {
        Err(ProviderError::AlbumNotFound(format!(
            "Album '{external_album_id}' not found on provider '{}'",
            self.kind()
        )))
    }

    async fn get_track(&self, external_track_id: &str) -> Result<TrackSource, ProviderError> {
        Err(ProviderError::TrackNotFound(format!(
            "Track '{external_track_id}' not found on provider '{}'",
            self.kind()
        )))
    }

    async fn get_lyrics(&self, track: &TrackSource) -> Result<Option<String>, ProviderError> {
        let _ = track;
        Ok(None)
    }

    async fn last_sync_album_metadata(&self) -> HashMap<String, AlbumSyncMetadata> {
        HashMap::new()
    }
}

/// Additive stream resolution contract keyed by composite [`StreamKey`].
#[async_trait]
pub trait StreamResolver: Send + Sync {
    fn provider_id(&self) -> &'static str;
    fn capabilities(&self) -> StreamProviderCapabilities;
    async fn resolve_source(&self, key: &StreamKey) -> Result<StreamSourceSpec, ProviderError>;
}

pub(crate) fn validate_stream_key(expected_provider: &str, key: &StreamKey) -> Result<(), ProviderError> {
    if !key.provider_id.eq_ignore_ascii_case(expected_provider) {
        return Err(ProviderError::UnsupportedFormat(format!(
            "Cannot resolve '{}' stream key on '{}' resolver",
            key.provider_id, expected_provider
        )));
    }
    if key.track_id.trim().is_empty() {
        return Err(ProviderError::track_not_found(expected_provider, &key.track_id));
    }
    Ok(())
}

pub(crate) fn extract_expire_at_from_url(raw_url: &str) -> Option<u64> {
    let parsed = url::Url::parse(raw_url).ok()?;
    for (k, v) in parsed.query_pairs() {
        if k.eq_ignore_ascii_case("expire")
            || k.eq_ignore_ascii_case("expires")
            || k.eq_ignore_ascii_case("exp")
        {
            if let Ok(ts) = v.trim().parse::<u64>() {
                if ts >= 1_000_000_000 {
                    return Some(ts);
                }
            }
        }
    }
    None
}
