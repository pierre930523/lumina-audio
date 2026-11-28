use serde::{Deserialize, Serialize};

// ============================================================================
// Step 4: Dynamic Bookmarks DTOs
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BookmarkDto {
    pub id: String,
    pub name: String,
    pub target_route: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_query_json: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view_state_json: Option<String>,
    #[serde(default)]
    pub sort_order: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateBookmarkRequest {
    pub name: String,
    pub target_route: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_query_json: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view_state_json: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateBookmarkRequest {
    #[serde(default)]
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_route: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_query_json: Option<String>,
    #[serde(default)]
    pub clear_focus_query: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view_state_json: Option<String>,
    #[serde(default)]
    pub clear_view_state: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReorderBookmarksRequest {
    #[serde(default)]
    pub ordered_ids: Vec<String>,
}
