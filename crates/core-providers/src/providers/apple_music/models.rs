use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::error::ProviderError;

pub const DEFAULT_APPLE_MUSIC_BASE_URL: &str = "https://api.music.apple.com/v1";
pub const DEFAULT_APPLE_MUSIC_STOREFRONT: &str = "us";

/// Updated Apple Music credentials produced by a credential refresher callback.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AppleMusicCredentials {
    pub developer_token: Option<String>,
    pub music_user_token: Option<String>,
}

/// Async callback used to refresh Apple Music developer/user tokens on HTTP 401.
pub type AppleMusicCredentialRefresher = Arc<
    dyn Fn() -> Pin<Box<dyn Future<Output = Result<AppleMusicCredentials, ProviderError>> + Send>>
        + Send
        + Sync,
>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppleMusicConfig {
    pub developer_token: Option<String>,
    pub music_user_token: Option<String>,
    pub storefront: String,
    pub base_url: String,
}

impl Default for AppleMusicConfig {
    fn default() -> Self {
        Self {
            developer_token: None,
            music_user_token: None,
            storefront: DEFAULT_APPLE_MUSIC_STOREFRONT.to_string(),
            base_url: DEFAULT_APPLE_MUSIC_BASE_URL.to_string(),
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct AppleDataListResponse<T> {
    #[serde(default = "Vec::new")]
    pub(super) data: Vec<T>,
}

#[derive(Debug, Deserialize)]
pub(super) struct AppleSearchResponse {
    #[serde(default)]
    pub(super) results: Option<AppleSearchResults>,
}

#[derive(Debug, Deserialize)]
pub(super) struct AppleSearchResults {
    #[serde(default)]
    pub(super) albums: Option<AppleDataListResponse<AppleAlbumResource>>,
}

#[derive(Debug, Deserialize)]
pub(super) struct AppleAlbumResource {
    pub(super) id: String,
    #[serde(default)]
    pub(super) attributes: Option<AppleAlbumAttributes>,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct AppleAlbumAttributes {
    #[serde(default)]
    pub(super) name: Option<String>,
    #[serde(rename = "artistName", default)]
    pub(super) artist_name: Option<String>,
    #[serde(rename = "releaseDate", default)]
    pub(super) release_date: Option<String>,
    #[serde(default)]
    pub(super) artwork: Option<AppleArtwork>,
}

#[derive(Debug, Deserialize)]
pub(super) struct AppleSongResource {
    pub(super) id: String,
    #[serde(default)]
    pub(super) attributes: Option<AppleSongAttributes>,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct AppleSongAttributes {
    #[serde(default)]
    pub(super) name: Option<String>,
    #[serde(rename = "albumName", default)]
    pub(super) album_name: Option<String>,
    #[serde(rename = "discNumber", default)]
    pub(super) disc_number: Option<u16>,
    #[serde(rename = "trackNumber", default)]
    pub(super) track_number: Option<u16>,
    #[serde(rename = "durationInMillis", default)]
    pub(super) duration_in_millis: Option<u64>,
    #[serde(default)]
    pub(super) isrc: Option<String>,
    #[serde(default)]
    pub(super) url: Option<String>,
    #[serde(default)]
    pub(super) previews: Vec<ApplePreview>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ApplePreview {
    #[serde(default)]
    pub(super) url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ApplePlaylistResource {
    pub(super) id: String,
    #[serde(default)]
    pub(super) attributes: Option<ApplePlaylistAttributes>,
    #[serde(default)]
    pub(super) relationships: Option<ApplePlaylistRelationships>,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct ApplePlaylistAttributes {
    #[serde(default)]
    pub(super) name: Option<String>,
    #[serde(rename = "curatorName", default)]
    pub(super) curator_name: Option<String>,
    #[serde(default)]
    pub(super) description: Option<AppleEditorialNotes>,
    #[serde(default)]
    pub(super) artwork: Option<AppleArtwork>,
}

#[derive(Debug, Deserialize)]
pub(super) struct AppleEditorialNotes {
    #[serde(default)]
    pub(super) standard: Option<String>,
    #[serde(default)]
    pub(super) short: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ApplePlaylistRelationships {
    #[serde(default)]
    pub(super) tracks: Option<AppleDataListResponse<AppleSongResource>>,
}

#[derive(Debug, Deserialize)]
pub(super) struct AppleArtwork {
    #[serde(default)]
    pub(super) url: Option<String>,
}

impl AppleArtwork {
    pub(super) fn formatted_url(&self, size: u32) -> Option<String> {
        let raw = self.url.as_deref()?.trim();
        if raw.is_empty() {
            return None;
        }
        let s = size.to_string();
        Some(raw.replace("{w}", &s).replace("{h}", &s))
    }
}
