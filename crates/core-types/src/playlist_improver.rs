use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Step 5: Static Playlists & Playlist Improver DTOs
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StaticPlaylistSummary {
    pub id: String,
    pub provider_id: String,
    pub source_path: String,
    pub name: String,
    #[serde(default)]
    pub track_count: u64,
    #[serde(default)]
    pub resolved_count: u64,
    #[serde(default)]
    pub unresolved_count: u64,
    #[serde(default)]
    pub snapshot_count: u64,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistTrackSummary {
    pub track_id: String,
    pub version_id: String,
    pub canonical_album_id: String,
    pub title: String,
    #[serde(default)]
    pub artist_name: String,
    #[serde(default)]
    pub album_title: String,
    pub provider_id: String,
    pub codec: String,
    pub sample_rate_hz: u32,
    pub bit_depth: u16,
    #[serde(default)]
    pub is_dsd: bool,
    pub duration_ms: u64,
    #[serde(default)]
    pub quality_score: f64,
    #[serde(default)]
    pub file_status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StaticPlaylistItemView {
    pub position: i64,
    pub raw_entry: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_track_source_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<PlaylistTrackSummary>,
    #[serde(default)]
    pub is_missing: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StaticPlaylistDetail {
    pub playlist: StaticPlaylistSummary,
    #[serde(default)]
    pub items: Vec<StaticPlaylistItemView>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateStaticPlaylistRequest {
    pub name: String,
    #[serde(default)]
    pub track_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddStaticPlaylistTracksRequest {
    #[serde(default)]
    pub track_ids: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaylistImprovementKind {
    Duplicate,
    Repair,
    Upgrade,
}

impl PlaylistImprovementKind {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Duplicate => "duplicate",
            Self::Repair => "repair",
            Self::Upgrade => "upgrade",
        }
    }
}

impl fmt::Display for PlaylistImprovementKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for PlaylistImprovementKind {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "duplicate" => Ok(Self::Duplicate),
            "repair" => Ok(Self::Repair),
            "upgrade" => Ok(Self::Upgrade),
            _ => Err(ValidationError::EmptyField {
                field: "kind",
                message: "playlist improvement kind must be 'duplicate', 'repair', or 'upgrade'",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistImprovementSuggestion {
    pub suggestion_id: String,
    pub kind: PlaylistImprovementKind,
    pub position: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duplicate_of_position: Option<i64>,
    pub raw_entry: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_track: Option<PlaylistTrackSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate_track: Option<PlaylistTrackSummary>,
    pub reason: String,
    #[serde(default)]
    pub confidence: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistImprovementReport {
    pub playlist_id: String,
    pub playlist_name: String,
    #[serde(default)]
    pub total_items: u64,
    #[serde(default)]
    pub duplicate_count: u64,
    #[serde(default)]
    pub repair_count: u64,
    #[serde(default)]
    pub upgrade_count: u64,
    #[serde(default)]
    pub suggestions: Vec<PlaylistImprovementSuggestion>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApplyPlaylistImprovementsRequest {
    #[serde(default)]
    pub suggestion_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub apply_kinds: Option<Vec<PlaylistImprovementKind>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApplyPlaylistImprovementsResult {
    pub playlist_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot_id: Option<String>,
    #[serde(default)]
    pub duplicates_removed: u64,
    #[serde(default)]
    pub tracks_repaired: u64,
    #[serde(default)]
    pub tracks_upgraded: u64,
    #[serde(default)]
    pub final_track_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistSnapshotRecord {
    pub id: String,
    pub playlist_id: String,
    pub reason: String,
    #[serde(default)]
    pub track_count: u64,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevertPlaylistSnapshotResult {
    pub playlist_id: String,
    pub snapshot_id: String,
    #[serde(default)]
    pub restored_track_count: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_playlist_improver_json_roundtrip() {
        let req = ApplyPlaylistImprovementsRequest {
            suggestion_ids: vec!["s-1".into()],
            apply_kinds: Some(vec![
                PlaylistImprovementKind::Duplicate,
                PlaylistImprovementKind::Repair,
                PlaylistImprovementKind::Upgrade,
            ]),
            reason: Some("manual_improver".into()),
        };
        let v = serde_json::to_value(&req).unwrap();
        assert_eq!(v["apply_kinds"][0], "duplicate");
        assert_eq!(v["apply_kinds"][1], "repair");
        assert_eq!(v["apply_kinds"][2], "upgrade");
        let decoded: ApplyPlaylistImprovementsRequest = serde_json::from_value(v).unwrap();
        assert_eq!(decoded, req);
    }
}
