use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::str::FromStr;

use crate::{FocusQuery, ValidationError};

fn default_true() -> bool {
    true
}

fn default_backup_max_keep() -> u32 {
    10
}

macro_rules! impl_str_enum {
    ($ty:ty, $field:literal, $msg:literal, { $($variant:ident => $str:literal),+ $(,)? }) => {
        impl $ty {
            #[inline]
            pub const fn as_str(&self) -> &'static str {
                match self {
                    $(Self::$variant => $str,)+
                }
            }
        }

        impl fmt::Display for $ty {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(self.as_str())
            }
        }

        impl FromStr for $ty {
            type Err = ValidationError;

            fn from_str(s: &str) -> Result<Self, Self::Err> {
                match s.trim().to_ascii_lowercase().as_str() {
                    $($str => Ok(Self::$variant),)+
                    _ => Err(ValidationError::EmptyField {
                        field: $field,
                        message: $msg,
                    }),
                }
            }
        }
    };
}

// ============================================================================
// Step 5: Database Backup / Restore & Catalog / Audio Export DTOs
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BackupTriggerMode {
    #[default]
    Manual,
    Scheduled,
    PreRestore,
}

impl_str_enum!(
    BackupTriggerMode,
    "trigger_mode",
    "trigger_mode must be 'manual', 'scheduled', or 'pre_restore'",
    { Manual => "manual", Scheduled => "scheduled", PreRestore => "pre_restore" }
);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BackupScheduleMode {
    #[default]
    Off,
    Daily,
    Weekly,
}

impl_str_enum!(
    BackupScheduleMode,
    "schedule_mode",
    "schedule_mode must be 'off', 'daily', or 'weekly'",
    { Off => "off", Daily => "daily", Weekly => "weekly" }
);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupSettings {
    #[serde(default)]
    pub backup_dir: String,
    #[serde(default)]
    pub schedule_mode: BackupScheduleMode,
    #[serde(default = "default_backup_max_keep")]
    pub max_keep: u32,
    #[serde(default)]
    pub resolved_backup_dir: String,
}

impl Default for BackupSettings {
    fn default() -> Self {
        Self {
            backup_dir: String::new(),
            schedule_mode: BackupScheduleMode::Off,
            max_keep: default_backup_max_keep(),
            resolved_backup_dir: String::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupManifest {
    pub backup_id: String,
    pub created_at: String,
    pub trigger_mode: BackupTriggerMode,
    pub app_version: String,
    pub schema_version: i64,
    pub db_filename: String,
    pub sha256: String,
    #[serde(default)]
    pub size_bytes: u64,
    #[serde(default)]
    pub table_counts: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupHistoryRecord {
    pub id: String,
    pub trigger_mode: BackupTriggerMode,
    pub backup_path: String,
    pub manifest_path: String,
    pub sha256: String,
    #[serde(default)]
    pub size_bytes: u64,
    #[serde(default)]
    pub schema_version: i64,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    pub created_at: String,
    #[serde(default)]
    pub exists_on_disk: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestoreBackupResult {
    pub restored_backup_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_restore_backup_id: Option<String>,
    pub restored_from_path: String,
    #[serde(default)]
    pub schema_version: i64,
    #[serde(default)]
    pub table_counts: BTreeMap<String, i64>,
    #[serde(default = "default_true")]
    pub reload_required: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CatalogExportFormat {
    #[default]
    Csv,
    Json,
}

impl_str_enum!(
    CatalogExportFormat,
    "format",
    "catalog export format must be 'csv' or 'json'",
    { Csv => "csv", Json => "json" }
);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CatalogExportSource {
    FocusQuery { query: FocusQuery },
    StaticPlaylist { playlist_id: String },
    SmartPlaylist { playlist_id: String },
    Albums { album_ids: Vec<String> },
    Tracks { track_ids: Vec<String> },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogExportRequest {
    pub source: CatalogExportSource,
    #[serde(default)]
    pub format: CatalogExportFormat,
    #[serde(default)]
    pub output_path: String,
    #[serde(default = "default_true")]
    pub include_headers: bool,
    #[serde(default = "default_true")]
    pub utf8_bom: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogExportResult {
    pub format: CatalogExportFormat,
    #[serde(default)]
    pub output_path: String,
    #[serde(default)]
    pub row_count: u64,
    #[serde(default)]
    pub size_bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioExportRequest {
    pub source: CatalogExportSource,
    #[serde(alias = "target_dir")]
    pub destination_dir: String,
    #[serde(default = "default_true")]
    pub preserve_structure: bool,
    #[serde(default)]
    pub overwrite_existing: bool,
    #[serde(default = "default_true", alias = "write_m3u8")]
    pub generate_m3u8: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playlist_filename: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioExportStatus {
    Running,
    Completed,
    Cancelled,
    Failed,
}

impl_str_enum!(
    AudioExportStatus,
    "status",
    "audio export status must be 'running', 'completed', 'cancelled', or 'failed'",
    {
        Running => "running",
        Completed => "completed",
        Cancelled => "cancelled",
        Failed => "failed",
    }
);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioExportProgress {
    pub job_id: String,
    pub status: AudioExportStatus,
    pub destination_dir: String,
    #[serde(default)]
    pub total_tracks: u64,
    #[serde(default)]
    pub copied_tracks: u64,
    #[serde(default)]
    pub skipped_tracks: u64,
    #[serde(default)]
    pub failed_tracks: u64,
    #[serde(default)]
    pub bytes_copied: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub m3u8_path: Option<String>,
    #[serde(default)]
    pub errors: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_backup_export_serde_roundtrip() {
        let req = CatalogExportRequest {
            source: CatalogExportSource::FocusQuery {
                query: FocusQuery::default(),
            },
            format: CatalogExportFormat::Csv,
            output_path: "/tmp/out.csv".into(),
            include_headers: true,
            utf8_bom: true,
        };
        let v = serde_json::to_value(&req).unwrap();
        assert_eq!(v["source"]["kind"], "focus_query");
        assert_eq!(v["format"], "csv");
        assert_eq!(
            serde_json::from_value::<CatalogExportRequest>(v).unwrap(),
            req
        );

        let src = CatalogExportSource::StaticPlaylist {
            playlist_id: "pl-1".into(),
        };
        let sv = serde_json::to_value(&src).unwrap();
        assert_eq!(sv["kind"], "static_playlist");
        assert_eq!(sv["playlist_id"], "pl-1");
    }
}
