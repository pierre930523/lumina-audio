use serde::{Deserialize, Serialize};

use crate::{AudioCodec, ProviderKind};

fn default_one_u16() -> u16 {
    1
}

fn default_one_u32() -> u32 {
    1
}

// ============================================================================
// External Streaming Catalog Ingest DTOs (Metadata-Only, Zero Stream URLs)
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalTrackIngest {
    pub external_track_id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default = "default_one_u16")]
    pub disc_number: u16,
    #[serde(default = "default_one_u16")]
    pub track_number: u16,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<AudioCodec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample_rate_hz: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalAlbumIngest {
    pub external_album_id: String,
    pub title: String,
    pub artist_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_year: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition_label: Option<String>,
    #[serde(default = "default_one_u32")]
    pub disc_count: u32,
    #[serde(default)]
    pub tracks: Vec<ExternalTrackIngest>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalCatalogIngestBatch {
    pub provider: ProviderKind,
    #[serde(default)]
    pub albums: Vec<ExternalAlbumIngest>,
}
