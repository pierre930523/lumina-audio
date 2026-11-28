use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::{AudioFormat, MetadataPolicy, TrackMetadataLayer, ValidationError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackDeleteMode {
    #[default]
    LibraryOnly,
    MoveToTrash,
}

impl TrackDeleteMode {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::LibraryOnly => "library_only",
            Self::MoveToTrash => "move_to_trash",
        }
    }
}

impl fmt::Display for TrackDeleteMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for TrackDeleteMode {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "library_only" | "library" => Ok(Self::LibraryOnly),
            "move_to_trash" | "trash" | "recycle_bin" => Ok(Self::MoveToTrash),
            _ => Err(ValidationError::EmptyField {
                field: "mode",
                message: "delete track mode must be 'library_only' or 'move_to_trash'",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackCorruptionStatus {
    #[default]
    Unchecked,
    Ok,
    Corrupt,
    Unreadable,
}

impl TrackCorruptionStatus {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Unchecked => "unchecked",
            Self::Ok => "ok",
            Self::Corrupt => "corrupt",
            Self::Unreadable => "unreadable",
        }
    }
}

impl FromStr for TrackCorruptionStatus {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "unchecked" => Ok(Self::Unchecked),
            "ok" => Ok(Self::Ok),
            "corrupt" => Ok(Self::Corrupt),
            "unreadable" => Ok(Self::Unreadable),
            _ => Err(ValidationError::EmptyField {
                field: "corruption_status",
                message: "invalid corruption_status",
            }),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TrackAnalysisResult {
    pub track_id: String,
    #[serde(default)]
    pub corruption_status: TrackCorruptionStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analysis_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub integrated_lufs: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub true_peak_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_peak: Option<f64>,
    #[serde(default)]
    pub waveform_peaks: Vec<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analyzed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackFileInfo {
    pub track_id: String,
    pub version_id: String,
    pub album_group_id: String,
    pub provider_id: String,
    pub file_path: String,
    pub is_local_file: bool,
    pub container_format: String,
    pub format: AudioFormat,
    pub duration_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_size_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_mtime: Option<i64>,
    #[serde(default)]
    pub is_hidden: bool,
    #[serde(default)]
    pub preference: i32,
    #[serde(default)]
    pub corruption_status: TrackCorruptionStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analysis_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub integrated_lufs: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub true_peak_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_peak: Option<f64>,
    #[serde(default)]
    pub waveform_peaks: Vec<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analyzed_at: Option<String>,
    #[serde(default)]
    pub meta_policy: MetadataPolicy,
    #[serde(default)]
    pub effective_policy: MetadataPolicy,
    #[serde(default)]
    pub has_user_edits: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_layer: Option<TrackMetadataLayer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloud_layer: Option<TrackMetadataLayer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_edits_layer: Option<TrackMetadataLayer>,
    #[serde(default)]
    pub effective_layer: TrackMetadataLayer,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_lyrics_source: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetTrackHiddenRequest {
    pub is_hidden: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackVisibilityResult {
    pub track_id: String,
    pub is_hidden: bool,
    #[serde(default)]
    pub affected_album_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ReidentifyTrackResult {
    pub track_id: String,
    pub matched: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_recording_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_info: Option<TrackFileInfo>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeleteTrackRequest {
    #[serde(default)]
    pub mode: TrackDeleteMode,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeleteTrackResult {
    pub track_id: String,
    #[serde(default)]
    pub mode: TrackDeleteMode,
    #[serde(default)]
    pub deleted_from_library: bool,
    #[serde(default)]
    pub moved_to_trash: bool,
    #[serde(default)]
    pub vacated_album_ids: Vec<String>,
    #[serde(default)]
    pub orphans_pruned: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
}
