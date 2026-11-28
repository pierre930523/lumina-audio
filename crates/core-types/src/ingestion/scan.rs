use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Skipped Files Quarantine
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipReason {
    CorruptHeader,
    PermissionDenied,
    UnsupportedFormat,
    UnsplitCueOrIso,
    GarbledTags,
    IoError,
}

impl SkipReason {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::CorruptHeader => "corrupt_header",
            Self::PermissionDenied => "permission_denied",
            Self::UnsupportedFormat => "unsupported_format",
            Self::UnsplitCueOrIso => "unsplit_cue_or_iso",
            Self::GarbledTags => "garbled_tags",
            Self::IoError => "io_error",
        }
    }
}

impl fmt::Display for SkipReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for SkipReason {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "corrupt_header" => Ok(Self::CorruptHeader),
            "permission_denied" => Ok(Self::PermissionDenied),
            "unsupported_format" => Ok(Self::UnsupportedFormat),
            "unsplit_cue_or_iso" => Ok(Self::UnsplitCueOrIso),
            "garbled_tags" => Ok(Self::GarbledTags),
            "io_error" => Ok(Self::IoError),
            _ => Err(ValidationError::EmptyField {
                field: "reason",
                message: "unknown skip reason",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkippedFile {
    pub id: String,
    pub provider_id: String,
    pub file_path: String,
    pub reason: SkipReason,
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_size: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_mtime: Option<i64>,
    pub first_seen_at: String,
    pub last_seen_at: String,
    #[serde(default)]
    pub dismissed: bool,
}

// ============================================================================
// Scan Progress & Watched Roots
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanLifecycleState {
    #[default]
    Idle,
    Discovering,
    Probing,
    Persisting,
    Watching,
    Completed,
    Failed,
}

impl ScanLifecycleState {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Discovering => "discovering",
            Self::Probing => "probing",
            Self::Persisting => "persisting",
            Self::Watching => "watching",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }
}

impl fmt::Display for ScanLifecycleState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ScanProgressEvent {
    pub scan_id: String,
    pub root_path: String,
    pub state: ScanLifecycleState,
    #[serde(default)]
    pub scanned: u64,
    #[serde(default)]
    pub added: u64,
    #[serde(default)]
    pub updated: u64,
    #[serde(default)]
    pub unchanged: u64,
    #[serde(default)]
    pub skipped: u64,
    #[serde(default)]
    pub pruned: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_estimated: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WatchMode {
    #[default]
    NativeOs,
    NasPolling,
    Manual,
}

impl WatchMode {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::NativeOs => "native_os",
            Self::NasPolling => "nas_polling",
            Self::Manual => "manual",
        }
    }
}

impl fmt::Display for WatchMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for WatchMode {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "native_os" | "native" => Ok(Self::NativeOs),
            "nas_polling" | "poll" | "polling" => Ok(Self::NasPolling),
            "manual" => Ok(Self::Manual),
            _ => Err(ValidationError::EmptyField {
                field: "watch_mode",
                message: "unknown watch mode",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WatchedRoot {
    pub id: String,
    pub provider_id: String,
    pub root_path: String,
    pub watch_mode: WatchMode,
    pub poll_interval_sec: u32,
    pub is_online: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_scan_at: Option<String>,
    pub updated_at: String,
}
