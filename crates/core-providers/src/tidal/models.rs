use serde::{Deserialize, Serialize};

pub const TIDAL_CREDENTIAL_SERVICE: &str = "com.lumina.audio.tidal";
pub const TIDAL_KEY_OAUTH: &str = "oauth_tokens";

pub const DEFAULT_TIDAL_CLIENT_ID: &str = "lumina_desktop_client";
pub const DEFAULT_TIDAL_REDIRECT_URI: &str = "http://localhost:9888/callback";
pub const DEFAULT_TIDAL_AUTH_BASE_URL: &str = "https://login.tidal.com";
pub const DEFAULT_TIDAL_API_BASE_URL: &str = "https://api.tidal.com/v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TidalPkceSession {
    pub verifier: String,
    pub challenge: String,
    pub auth_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TidalTokenResponse {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: String,
    #[serde(default = "default_token_type")]
    pub token_type: String,
    #[serde(default = "default_expires_in")]
    pub expires_in: u64,
    #[serde(default)]
    pub user_id: u64,
    #[serde(default)]
    pub issued_at: u64,
}

fn default_token_type() -> String {
    "Bearer".to_string()
}

fn default_expires_in() -> u64 {
    3600
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TidalConfig {
    pub client_id: String,
    #[serde(default)]
    pub client_secret: Option<String>,
    pub redirect_uri: String,
    pub auth_base_url: String,
    pub api_base_url: String,
    pub scopes: String,
    pub country_code: String,
    pub audio_quality: String,
}

impl Default for TidalConfig {
    fn default() -> Self {
        Self {
            client_id: DEFAULT_TIDAL_CLIENT_ID.to_string(),
            client_secret: None,
            redirect_uri: DEFAULT_TIDAL_REDIRECT_URI.to_string(),
            auth_base_url: DEFAULT_TIDAL_AUTH_BASE_URL.to_string(),
            api_base_url: DEFAULT_TIDAL_API_BASE_URL.to_string(),
            scopes: "r_usr w_usr".to_string(),
            country_code: "US".to_string(),
            audio_quality: "HI_RES_LOSSLESS".to_string(),
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalOAuthRawResponse {
    pub(super) access_token: String,
    #[serde(default)]
    pub(super) refresh_token: Option<String>,
    #[serde(default)]
    pub(super) token_type: Option<String>,
    #[serde(default)]
    pub(super) expires_in: Option<u64>,
    #[serde(default)]
    pub(super) user_id: Option<u64>,
    #[serde(default)]
    pub(super) user: Option<TidalOAuthUser>,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalOAuthUser {
    #[serde(rename = "userId", default)]
    pub(super) user_id: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalSearchAlbumsResponse {
    #[serde(default)]
    pub(super) items: Vec<TidalAlbumItem>,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalAlbumItem {
    #[serde(deserialize_with = "de_val_string")]
    pub(super) id: String,
    pub(super) title: String,
    #[serde(default)]
    pub(super) artist: Option<TidalArtistRef>,
    #[serde(default)]
    pub(super) artists: Vec<TidalArtistRef>,
    #[serde(rename = "releaseDate", default)]
    pub(super) release_date: Option<String>,
    #[serde(default)]
    pub(super) cover: Option<String>,
    #[serde(rename = "audioQuality", default)]
    pub(super) audio_quality: Option<String>,
    #[serde(default)]
    pub(super) version: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    pub(super) upc: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalArtistRef {
    pub(super) name: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalTrackItem {
    #[serde(deserialize_with = "de_val_string")]
    pub(super) id: String,
    pub(super) title: String,
    #[serde(rename = "trackNumber", default)]
    pub(super) track_number: Option<u16>,
    #[serde(rename = "volumeNumber", default)]
    pub(super) volume_number: Option<u16>,
    #[serde(default)]
    pub(super) duration: Option<u64>,
    #[serde(default)]
    pub(super) isrc: Option<String>,
    #[serde(rename = "audioQuality", default)]
    pub(super) audio_quality: Option<String>,
    #[serde(default)]
    pub(super) album: Option<TidalAlbumIdRef>,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalAlbumIdRef {
    #[serde(deserialize_with = "de_val_string")]
    pub(super) id: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalPlaybackInfo {
    #[serde(rename = "audioQuality", default)]
    pub(super) audio_quality: Option<String>,
    #[serde(rename = "bitDepth", default)]
    pub(super) bit_depth: Option<u8>,
    #[serde(rename = "sampleRate", default)]
    pub(super) sample_rate: Option<u32>,
    #[serde(rename = "manifestMimeType", default)]
    pub(super) manifest_mime_type: Option<String>,
    #[serde(default)]
    pub(super) manifest: Option<String>,
    #[serde(default)]
    pub(super) url: Option<String>,
    #[serde(default)]
    pub(super) urls: Vec<String>,
    #[serde(rename = "encryptionType", default)]
    pub(super) encryption_type: Option<String>,
    #[serde(rename = "trackReplayGain", default)]
    pub(super) track_replay_gain: Option<f64>,
    #[serde(rename = "albumReplayGain", default)]
    pub(super) album_replay_gain: Option<f64>,
    #[serde(rename = "trackPeakAmplitude", default)]
    pub(super) track_peak_amplitude: Option<f64>,
    #[serde(rename = "albumPeakAmplitude", default)]
    pub(super) album_peak_amplitude: Option<f64>,
}

#[derive(Debug, Deserialize)]
pub(super) struct TidalBtsManifest {
    #[serde(rename = "mimeType", default)]
    pub(super) mime_type: Option<String>,
    #[serde(default)]
    pub(super) codecs: Option<String>,
    #[serde(default)]
    pub(super) urls: Vec<String>,
    #[serde(rename = "encryptionType", default)]
    pub(super) encryption_type: Option<String>,
}

pub(super) struct TidalBtsDecoded {
    pub(super) stream_url: String,
    pub(super) codec_override: Option<core_types::AudioCodec>,
    pub(super) hint_ext: Option<String>,
    pub(super) mime_type: Option<String>,
}

fn de_val_string<'de, D>(deserializer: D) -> Result<String, D::Error>
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
