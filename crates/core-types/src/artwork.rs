use serde::{Deserialize, Serialize};
use std::fmt;

// ============================================================================
// Artwork & Rescan Types
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtworkSourceKind {
    Embedded,
    Cover,
    Folder,
    Front,
    User,
    #[default]
    Placeholder,
}

impl ArtworkSourceKind {
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Embedded => "embedded",
            Self::Cover => "cover",
            Self::Folder => "folder",
            Self::Front => "front",
            Self::User => "user",
            Self::Placeholder => "placeholder",
        }
    }
}

impl fmt::Display for ArtworkSourceKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ArtworkResult {
    #[serde(default)]
    pub found: bool,
    #[serde(default)]
    pub cache_path: Option<String>,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub width: Option<u32>,
    #[serde(default)]
    pub height: Option<u32>,
    #[serde(default)]
    pub source_kind: ArtworkSourceKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_key: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PictureType {
    #[default]
    Other,
    FileIcon,
    OtherFileIcon,
    FrontCover,
    BackCover,
    LeafletPage,
    Media,
    LeadArtist,
    Artist,
    Conductor,
    Band,
    Composer,
    Lyricist,
    RecordingLocation,
    DuringRecording,
    DuringPerformance,
    VideoCapture,
    BrightColouredFish,
    Illustration,
    BandLogotype,
    PublisherLogotype,
}

impl PictureType {
    pub const fn from_apic_byte(code: u8) -> Self {
        match code {
            1 => Self::FileIcon,
            2 => Self::OtherFileIcon,
            3 => Self::FrontCover,
            4 => Self::BackCover,
            5 => Self::LeafletPage,
            6 => Self::Media,
            7 => Self::LeadArtist,
            8 => Self::Artist,
            9 => Self::Conductor,
            10 => Self::Band,
            11 => Self::Composer,
            12 => Self::Lyricist,
            13 => Self::RecordingLocation,
            14 => Self::DuringRecording,
            15 => Self::DuringPerformance,
            16 => Self::VideoCapture,
            17 => Self::BrightColouredFish,
            18 => Self::Illustration,
            19 => Self::BandLogotype,
            20 => Self::PublisherLogotype,
            _ => Self::Other,
        }
    }

    pub const fn is_front_cover(&self) -> bool {
        matches!(self, Self::FrontCover)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtractedPicture {
    pub picture_type: PictureType,
    pub mime_type: String,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RescanReport {
    pub scanned: usize,
    pub updated: usize,
    pub unchanged_cached: usize,
    pub pruned: usize,
    #[serde(default)]
    pub errors: Vec<String>,
}
