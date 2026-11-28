use std::collections::BTreeMap;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use serde::Deserialize;

use crate::error::ProviderError;
use crate::process_guard::BinaryLocator;
use crate::resilience::RetryPolicy;

/// Updated YouTube Music cookie/auth configuration returned by a refresher callback.
#[derive(Debug, Clone, Default)]
pub struct YtMusicAuthUpdate {
    pub cookies_file: Option<PathBuf>,
    pub cookies_from_browser: Option<String>,
}

/// Optional async callback invoked under [`crate::resilience::SingleFlightRefreshGate`] when auth/cookies expire.
pub type YtMusicCredentialRefresher = Arc<
    dyn Fn() -> Pin<Box<dyn Future<Output = Result<YtMusicAuthUpdate, ProviderError>> + Send>>
        + Send
        + Sync,
>;

/// Configuration for [`super::YtMusicProvider`].
///
/// Binary paths are never hardcoded; `yt-dlp`, optional `deno`, and optional `ffmpeg`
/// are always resolved through [`BinaryLocator`].
#[derive(Debug, Clone, Default)]
pub struct YtMusicConfig {
    pub binary_locator: BinaryLocator,
    pub cookies_file: Option<PathBuf>,
    pub cookies_from_browser: Option<String>,
    pub user_agent: Option<String>,
    pub extra_yt_dlp_args: Vec<String>,
    pub retry_policy: RetryPolicy,
}

pub(super) struct SelectedYtAudio {
    pub(super) url: String,
    pub(super) headers: BTreeMap<String, String>,
    pub(super) content_length: Option<u64>,
    pub(super) bitrate_bps: Option<u64>,
    pub(super) ext: Option<String>,
    pub(super) acodec: Option<String>,
    pub(super) mime_type: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct YtDlpThumbnail {
    #[serde(default)]
    pub(super) url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct YtDlpSearchOrPlaylist {
    #[serde(default)]
    pub(super) id: Option<String>,
    #[serde(default)]
    pub(super) title: Option<String>,
    #[serde(default)]
    pub(super) description: Option<String>,
    #[serde(default)]
    pub(super) uploader: Option<String>,
    #[serde(default)]
    pub(super) channel: Option<String>,
    #[serde(default)]
    pub(super) thumbnail: Option<String>,
    #[serde(default)]
    pub(super) thumbnails: Vec<YtDlpThumbnail>,
    #[serde(default)]
    pub(super) entries: Vec<YtDlpFlatEntry>,
}

impl YtDlpSearchOrPlaylist {
    pub(super) fn best_thumbnail(&self) -> Option<String> {
        self.thumbnail
            .clone()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| {
                self.thumbnails
                    .iter()
                    .rev()
                    .find_map(|t| t.url.clone().filter(|s| !s.trim().is_empty()))
            })
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct YtDlpFlatEntry {
    #[serde(default)]
    pub(super) id: Option<String>,
    #[serde(default)]
    pub(super) title: Option<String>,
    #[serde(default)]
    pub(super) album: Option<String>,
    #[serde(default)]
    pub(super) artist: Option<String>,
    #[serde(default)]
    pub(super) uploader: Option<String>,
    #[serde(default)]
    pub(super) channel: Option<String>,
    #[serde(default)]
    pub(super) duration: Option<f64>,
    #[serde(default)]
    pub(super) thumbnail: Option<String>,
    #[serde(default)]
    pub(super) thumbnails: Vec<YtDlpThumbnail>,
}

impl YtDlpFlatEntry {
    pub(super) fn best_thumbnail(&self) -> Option<String> {
        self.thumbnail
            .clone()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| {
                self.thumbnails
                    .iter()
                    .rev()
                    .find_map(|t| t.url.clone().filter(|s| !s.trim().is_empty()))
            })
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct YtDlpInfoJson {
    #[serde(default)]
    pub(super) id: Option<String>,
    #[serde(default)]
    pub(super) title: Option<String>,
    #[serde(default)]
    pub(super) album: Option<String>,
    #[serde(default)]
    pub(super) duration: Option<f64>,
    #[serde(default)]
    pub(super) track_number: Option<u16>,
    #[serde(default)]
    pub(super) disc_number: Option<u16>,
    #[serde(default)]
    pub(super) url: Option<String>,
    #[serde(default)]
    pub(super) ext: Option<String>,
    #[serde(default)]
    pub(super) acodec: Option<String>,
    #[serde(default)]
    pub(super) asr: Option<u32>,
    #[serde(default)]
    pub(super) abr: Option<f64>,
    #[serde(default)]
    pub(super) tbr: Option<f64>,
    #[serde(default)]
    pub(super) filesize: Option<u64>,
    #[serde(default)]
    pub(super) filesize_approx: Option<u64>,
    #[serde(default)]
    pub(super) mime_type: Option<String>,
    #[serde(default)]
    pub(super) http_headers: Option<BTreeMap<String, String>>,
    #[serde(default)]
    pub(super) loudness_db: Option<f64>,
    #[serde(rename = "loudnessDb", default)]
    pub(super) loudness_db_camel: Option<f64>,
    #[serde(default)]
    pub(super) requested_formats: Vec<YtDlpFormatJson>,
    #[serde(default)]
    pub(super) formats: Vec<YtDlpFormatJson>,
}

#[derive(Debug, Deserialize)]
pub(super) struct YtDlpFormatJson {
    #[serde(default)]
    pub(super) url: Option<String>,
    #[serde(default)]
    pub(super) ext: Option<String>,
    #[serde(default)]
    pub(super) acodec: Option<String>,
    #[serde(default)]
    pub(super) vcodec: Option<String>,
    #[serde(default)]
    pub(super) abr: Option<f64>,
    #[serde(default)]
    pub(super) tbr: Option<f64>,
    #[serde(default)]
    pub(super) filesize: Option<u64>,
    #[serde(default)]
    pub(super) filesize_approx: Option<u64>,
    #[serde(default)]
    pub(super) mime_type: Option<String>,
    #[serde(default)]
    pub(super) http_headers: Option<BTreeMap<String, String>>,
}
