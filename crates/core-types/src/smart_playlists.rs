use serde::{Deserialize, Serialize};

fn default_true() -> bool {
    true
}

// ============================================================================
// Step 4: Unified Smart Playlists DTOs (FocusQuery-backed)
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SmartPlaylistDto {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub focus_query_json: String,
    #[serde(default = "default_true")]
    pub exclude_banned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit_count: Option<u32>,
    #[serde(default = "default_true")]
    pub is_pinned: bool,
    #[serde(default)]
    pub sort_order: i64,
    #[serde(default)]
    pub is_system_seed: bool,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateSmartPlaylistRequest {
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub focus_query_json: String,
    #[serde(default = "default_true")]
    pub exclude_banned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit_count: Option<u32>,
    #[serde(default = "default_true")]
    pub is_pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateSmartPlaylistRequest {
    #[serde(default)]
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_query_json: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude_banned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit_count: Option<u32>,
    #[serde(default)]
    pub clear_limit: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_pinned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SmartPlaylistEvaluationResponse<T> {
    pub playlist: SmartPlaylistDto,
    pub total_matched: u64,
    #[serde(default)]
    pub tracks: Vec<T>,
}

impl<T> SmartPlaylistEvaluationResponse<T> {
    pub fn map_tracks<T2>(self, f: impl FnMut(T) -> T2) -> SmartPlaylistEvaluationResponse<T2> {
        SmartPlaylistEvaluationResponse {
            playlist: self.playlist,
            total_matched: self.total_matched,
            tracks: self.tracks.into_iter().map(f).collect(),
        }
    }
}
