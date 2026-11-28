use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::{AudioCodec, ProviderKind, ValidationError};

// ============================================================================
// Layered Metadata Precedence & Non-Destructive Overrides
// ============================================================================

/// Precedence order: `CloudEnrichment < FileTag < UserEdit`.
///
/// Local embedded file tags (`FileTag`) are authoritative over online enrichment
/// (`CloudEnrichment`) for core identity fields (`title`, `artist`, `album_artist`,
/// `album`, `track_number`, `disc_number`). Only explicit `UserEdit` overrides `FileTag`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetadataLayer {
    CloudEnrichment = 0,
    FileTag = 1,
    UserEdit = 2,
}

impl MetadataLayer {
    /// Core identity fields where local file tags are strictly authoritative over online enrichment.
    pub const CORE_IDENTITY_FIELDS: &'static [&'static str] = &[
        "title",
        "artist",
        "artist_name",
        "album_artist",
        "album",
        "track_number",
        "disc_number",
    ];

    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::CloudEnrichment => "cloud_enrichment",
            Self::FileTag => "file_tag",
            Self::UserEdit => "user_edit",
        }
    }

    #[inline]
    pub const fn rank(&self) -> u8 {
        *self as u8
    }

    /// Returns `true` if `field_name` is a core identity field protected from online enrichment overwrites.
    pub fn is_core_identity_field(field_name: &str) -> bool {
        let lower = field_name.trim().to_ascii_lowercase();
        Self::CORE_IDENTITY_FIELDS.contains(&lower.as_str())
    }

    /// Returns `true` if `self` is permitted to overwrite an existing value from `existing` for `field_name`.
    pub fn can_override(&self, existing: Self, field_name: &str) -> bool {
        if matches!(self, Self::UserEdit) {
            return true;
        }
        if matches!(self, Self::CloudEnrichment)
            && Self::is_core_identity_field(field_name)
            && existing >= Self::FileTag
        {
            return false;
        }
        *self >= existing
    }
}

impl fmt::Display for MetadataLayer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for MetadataLayer {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "file_tag" | "file" => Ok(Self::FileTag),
            "cloud_enrichment" | "cloud" => Ok(Self::CloudEnrichment),
            "user_edit" | "user" => Ok(Self::UserEdit),
            _ => Err(ValidationError::EmptyField {
                field: "source_layer",
                message: "unknown metadata layer",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MetadataOverride {
    pub entity_type: String,
    pub entity_id: String,
    pub field_name: String,
    pub value_json: String,
    pub source_layer: MetadataLayer,
    pub updated_at: String,
}

// ============================================================================
// Canonical Track, Artist & SourceReference
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileStatus {
    #[default]
    Present,
    Missing,
    Quarantined,
}

impl FileStatus {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Present => "present",
            Self::Missing => "missing",
            Self::Quarantined => "quarantined",
        }
    }
}

impl fmt::Display for FileStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for FileStatus {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "present" => Ok(Self::Present),
            "missing" => Ok(Self::Missing),
            "quarantined" => Ok(Self::Quarantined),
            _ => Err(ValidationError::EmptyField {
                field: "file_status",
                message: "unknown file status",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceReference {
    pub source_id: String,
    pub provider: ProviderKind,
    pub external_id: String,
    pub codec: AudioCodec,
    pub sample_rate_hz: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<u8>,
    #[serde(default)]
    pub is_dsd: bool,
    #[serde(default)]
    pub file_status: FileStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_fingerprint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_byte_len: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalTrack {
    pub id: String,
    pub canonical_album_id: String,
    pub title: String,
    pub sort_title: String,
    pub artist_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default)]
    pub artist_names: Vec<String>,
    pub disc_number: u32,
    pub track_number: u32,
    pub duration_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_recording_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default)]
    pub sources: Vec<SourceReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalArtist {
    pub id: String,
    pub name: String,
    pub sort_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub biography: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}
