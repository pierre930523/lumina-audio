use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzLoginResponse {
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub user: Option<QobuzUser>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub code: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzUser {
    #[serde(default)]
    pub id: Option<serde_json::Value>,
    #[serde(default)]
    pub user_auth_token: Option<String>,
    #[serde(default)]
    pub credential: Option<QobuzCredential>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzCredential {
    #[serde(default)]
    pub parameters: Option<QobuzParameters>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzParameters {
    #[serde(default)]
    pub hires: Option<bool>,
    #[serde(default)]
    pub max_streaming_quality: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzSearchResponse {
    #[serde(default)]
    pub albums: Option<QobuzAlbumsContainer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzAlbumsContainer {
    #[serde(default)]
    pub total: Option<usize>,
    #[serde(default)]
    pub items: Option<Vec<QobuzAlbumItem>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzImage {
    #[serde(default)]
    pub large: Option<String>,
    #[serde(default)]
    pub small: Option<String>,
    #[serde(default)]
    pub thumbnail: Option<String>,
}

impl QobuzImage {
    pub fn best_url(&self) -> Option<String> {
        self.large
            .as_ref()
            .or(self.small.as_ref())
            .or(self.thumbnail.as_ref())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzTracksContainer {
    #[serde(default)]
    pub items: Option<Vec<QobuzTrackItem>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzAlbumItem {
    #[serde(deserialize_with = "de_id_to_string")]
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artist: Option<QobuzArtist>,
    #[serde(default)]
    pub maximum_sampling_rate: Option<serde_json::Value>,
    #[serde(default)]
    pub maximum_bit_depth: Option<u8>,
    #[serde(default)]
    pub upc: Option<String>,
    #[serde(default)]
    pub release_date_original: Option<String>,
    #[serde(default)]
    pub released_at: Option<i64>,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub image: Option<QobuzImage>,
    #[serde(default)]
    pub tracks: Option<QobuzTracksContainer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzTrackItem {
    #[serde(deserialize_with = "de_id_to_string")]
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub track_number: Option<u16>,
    #[serde(default)]
    pub media_number: Option<u16>,
    #[serde(default)]
    pub duration: Option<u64>,
    #[serde(default)]
    pub isrc: Option<String>,
    #[serde(default)]
    pub maximum_sampling_rate: Option<serde_json::Value>,
    #[serde(default)]
    pub maximum_bit_depth: Option<u8>,
    #[serde(default)]
    pub album: Option<Box<QobuzAlbumItem>>,
    #[serde(default)]
    pub performer: Option<QobuzArtist>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzArtist {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzStreamResponse {
    #[serde(default)]
    pub track_id: Option<serde_json::Value>,
    #[serde(default)]
    pub format_id: Option<u32>,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub sampling_rate: Option<serde_json::Value>,
    #[serde(default)]
    pub bit_depth: Option<u8>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub duration: Option<u64>,
    #[serde(default)]
    pub restrictions: Option<Vec<String>>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub code: Option<u16>,
}

fn de_id_to_string<'de, D>(deserializer: D) -> Result<String, D::Error>
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

pub fn normalize_sample_rate(val: &serde_json::Value) -> u32 {
    let float_val = match val {
        serde_json::Value::Number(num) => num.as_f64().unwrap_or(44.1),
        serde_json::Value::String(s) => s.parse::<f64>().unwrap_or(44.1),
        _ => 44.1,
    };

    let hz = if float_val < 1000.0 {
        float_val * 1000.0
    } else {
        float_val
    };

    hz.round() as u32
}

pub fn resolve_qobuz_format_id(format_id: u32) -> (u32, u8) {
    match format_id {
        27 => (192000, 24),
        7 => (96000, 24),
        6 => (44100, 16),
        5 => (44100, 16),
        _ => (44100, 16),
    }
}
