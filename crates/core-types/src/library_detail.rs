use serde::{Deserialize, Serialize};

use crate::{AlbumVersion, CanonicalAlbum, MetadataPolicy, TrackSource};

// ============================================================================
// Library Detail DTOs
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumCreditDetail {
    pub artist_id: String,
    pub artist_name: String,
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AlbumVersionDetail {
    pub version: AlbumVersion,
    #[serde(default)]
    pub tracks: Vec<TrackSource>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AlbumDetail {
    pub album: CanonicalAlbum,
    #[serde(default)]
    pub versions: Vec<AlbumVersionDetail>,
    #[serde(default)]
    pub credits: Vec<AlbumCreditDetail>,
    #[serde(default)]
    pub meta_policy: MetadataPolicy,
    #[serde(default)]
    pub has_user_edits: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_version_id: Option<String>,
    #[serde(default)]
    pub is_primary_locked: bool,
    #[serde(default)]
    pub hidden_version_count: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtistDetail {
    pub id: String,
    pub name: String,
    pub sort_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub biography: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_path: Option<String>,
    #[serde(default)]
    pub preference: i32,
    #[serde(default)]
    pub albums: Vec<CanonicalAlbum>,
    #[serde(default)]
    pub credits: Vec<AlbumCreditDetail>,
}
