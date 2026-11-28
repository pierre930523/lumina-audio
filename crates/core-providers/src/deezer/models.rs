use core_types::AudioCodec;
use serde::{Deserialize, Serialize};

pub const DEEZER_CREDENTIAL_SERVICE: &str = "com.lumina.audio.deezer";
pub const DEEZER_KEY_ARL: &str = "arl_token";

pub const DEFAULT_DEEZER_API_BASE_URL: &str = "https://api.deezer.com";
pub const DEFAULT_DEEZER_GW_BASE_URL: &str = "https://www.deezer.com/ajax/gw-light.php";
pub const DEFAULT_DEEZER_MEDIA_BASE_URL: &str = "https://media.deezer.com/v1/get_url";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeezerUser {
    pub id: u64,
    pub name: String,
    pub offer: String,
    pub can_stream_hq: bool,
    pub can_stream_lossless: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeezerConfig {
    pub arl: Option<String>,
    pub api_base_url: String,
    pub gw_base_url: String,
    pub media_base_url: String,
}

impl Default for DeezerConfig {
    fn default() -> Self {
        Self {
            arl: None,
            api_base_url: DEFAULT_DEEZER_API_BASE_URL.to_string(),
            gw_base_url: DEFAULT_DEEZER_GW_BASE_URL.to_string(),
            media_base_url: DEFAULT_DEEZER_MEDIA_BASE_URL.to_string(),
        }
    }
}

impl DeezerConfig {
    pub fn from_arl(arl: impl Into<String>) -> Self {
        Self {
            arl: Some(arl.into()),
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone)]
pub(super) struct DeezerSession {
    pub(super) arl: String,
    pub(super) sid: Option<String>,
    pub(super) api_token: Option<String>,
    pub(super) license_token: Option<String>,
    pub(super) user: DeezerUser,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerGwResponse<T> {
    #[serde(default)]
    pub(super) error: Option<serde_json::Value>,
    #[serde(default)]
    pub(super) results: Option<T>,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct DeezerUserDataResult {
    #[serde(rename = "USER", default)]
    pub(super) user: Option<DeezerGwUser>,
    #[serde(rename = "checkForm", default)]
    pub(super) check_form: Option<String>,
    #[serde(rename = "OFFER_NAME", default)]
    pub(super) offer_name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerGwUser {
    #[serde(rename = "USER_ID", default)]
    pub(super) user_id: u64,
    #[serde(rename = "BLOG_NAME", default)]
    pub(super) blog_name: Option<String>,
    #[serde(rename = "OPTIONS", default)]
    pub(super) options: Option<DeezerGwOptions>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerGwOptions {
    #[serde(default)]
    pub(super) web_hq: Option<bool>,
    #[serde(default)]
    pub(super) web_lossless: Option<bool>,
    #[serde(default)]
    pub(super) license_token: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct DeezerSongDataResult {
    #[serde(rename = "TRACK_TOKEN", default)]
    pub(super) track_token: Option<String>,
    #[serde(rename = "GAIN", default)]
    pub(super) gain: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerMediaResponse {
    #[serde(default)]
    pub(super) url: Option<String>,
    #[serde(default)]
    pub(super) data: Vec<DeezerMediaDataItem>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerMediaDataItem {
    #[serde(default)]
    pub(super) media: Vec<DeezerMediaItem>,
    #[serde(default)]
    pub(super) errors: Vec<DeezerMediaError>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerMediaItem {
    #[serde(default)]
    pub(super) format: Option<String>,
    #[serde(default)]
    pub(super) exp: Option<u64>,
    #[serde(default)]
    pub(super) cipher: Option<serde_json::Value>,
    #[serde(default)]
    pub(super) sources: Vec<DeezerMediaSource>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerMediaSource {
    pub(super) url: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerMediaError {
    #[serde(default)]
    pub(super) code: Option<i64>,
    #[serde(default)]
    pub(super) message: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerSearchAlbumsResponse {
    #[serde(default)]
    pub(super) data: Vec<DeezerAlbumDto>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerAlbumDto {
    #[serde(deserialize_with = "de_id_str")]
    pub(super) id: String,
    pub(super) title: String,
    #[serde(default)]
    pub(super) artist: Option<DeezerArtistDto>,
    #[serde(default)]
    pub(super) cover_xl: Option<String>,
    #[serde(default)]
    pub(super) cover_big: Option<String>,
    #[serde(default)]
    pub(super) cover_medium: Option<String>,
    #[serde(default)]
    pub(super) release_date: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    pub(super) upc: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerArtistDto {
    pub(super) name: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerTrackDto {
    #[serde(deserialize_with = "de_id_str")]
    pub(super) id: String,
    pub(super) title: String,
    #[serde(default)]
    pub(super) isrc: Option<String>,
    #[serde(default)]
    pub(super) duration: Option<u64>,
    #[serde(default)]
    pub(super) track_position: Option<u16>,
    #[serde(default)]
    pub(super) disk_number: Option<u16>,
    #[serde(default)]
    pub(super) gain: Option<f64>,
    #[serde(default)]
    pub(super) preview: Option<String>,
    #[serde(default)]
    pub(super) album: Option<DeezerTrackAlbumDto>,
}

#[derive(Debug, Deserialize)]
pub(super) struct DeezerTrackAlbumDto {
    #[serde(deserialize_with = "de_id_str")]
    pub(super) id: String,
}

pub(super) struct DeezerMediaResolved {
    pub(super) url: String,
    pub(super) codec: AudioCodec,
    pub(super) hint_ext: &'static str,
    pub(super) mime_type: String,
    pub(super) bitrate_bps: Option<u64>,
    pub(super) gw_gain_db: Option<f64>,
    pub(super) expire_at: Option<u64>,
    pub(super) is_unencrypted: bool,
}

pub(super) enum DeezerQualityPlan {
    Full(Vec<serde_json::Value>),
    PreviewOnly,
}

fn de_id_str<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let val = serde_json::Value::deserialize(deserializer)?;
    match val {
        serde_json::Value::String(s) => Ok(s),
        serde_json::Value::Number(n) => Ok(n.to_string()),
        other => Ok(other.to_string()),
    }
}
