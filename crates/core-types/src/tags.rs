use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Step 3: Custom Nested Tags DTOs
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TagEntityType {
    AlbumGroup,
    Track,
    Artist,
}

impl TagEntityType {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::AlbumGroup => "album_group",
            Self::Track => "track",
            Self::Artist => "artist",
        }
    }
}

impl fmt::Display for TagEntityType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for TagEntityType {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "album_group" => Ok(Self::AlbumGroup),
            "track" => Ok(Self::Track),
            "artist" => Ok(Self::Artist),
            _ => Err(ValidationError::EmptyField {
                field: "entity_type",
                message: "tag entity_type must be 'album_group', 'track', or 'artist'",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TagBatchOp {
    #[default]
    Add,
    Remove,
}

impl TagBatchOp {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Add => "add",
            Self::Remove => "remove",
        }
    }
}

impl fmt::Display for TagBatchOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for TagBatchOp {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "add" => Ok(Self::Add),
            "remove" => Ok(Self::Remove),
            _ => Err(ValidationError::EmptyField {
                field: "op",
                message: "tag batch op must be 'add' or 'remove'",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TagSummary {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default)]
    pub parent_ids: Vec<String>,
    #[serde(default)]
    pub child_ids: Vec<String>,
    #[serde(default)]
    pub direct_item_count: u64,
    #[serde(default)]
    pub recursive_item_count: u64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateTagRequest {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateTagRequest {
    #[serde(default)]
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default)]
    pub clear_color: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TagLinkRequest {
    pub parent_tag_id: String,
    pub child_tag_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BatchTagItemsRequest {
    pub tag_ids: Vec<String>,
    pub entity_type: TagEntityType,
    pub entity_ids: Vec<String>,
    #[serde(default)]
    pub op: TagBatchOp,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BatchTagItemsResponse {
    pub affected: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tag_json_contract_roundtrip() {
        let summary = TagSummary {
            id: "tag-1".into(),
            name: "Late Night".into(),
            color: Some("#7C4DFF".into()),
            parent_ids: vec!["tag-root".into()],
            child_ids: vec!["tag-sub".into()],
            direct_item_count: 3,
            recursive_item_count: 11,
            created_at: "2026-11-27T00:00:00Z".into(),
            updated_at: "2026-11-27T00:00:00Z".into(),
        };
        let encoded = serde_json::to_string(&summary).unwrap();
        let decoded: TagSummary = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded, summary);

        let batch = BatchTagItemsRequest {
            tag_ids: vec!["tag-1".into()],
            entity_type: TagEntityType::AlbumGroup,
            entity_ids: vec!["alb-1".into(), "alb-2".into()],
            op: TagBatchOp::Remove,
        };
        let v = serde_json::to_value(&batch).unwrap();
        assert_eq!(v["entity_type"], "album_group");
        assert_eq!(v["op"], "remove");
        assert_eq!(
            serde_json::from_value::<BatchTagItemsRequest>(v).unwrap(),
            batch
        );

        let update: UpdateTagRequest =
            serde_json::from_str(r#"{"id":"tag-1","clear_color":true}"#).unwrap();
        assert_eq!(update.id, "tag-1");
        assert!(update.name.is_none());
        assert!(update.color.is_none());
        assert!(update.clear_color);
    }
}
