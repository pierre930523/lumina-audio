use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Step 5: Tri-State Bulk Metadata Editor DTOs
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BulkEditEntityType {
    Album,
    Track,
}

impl BulkEditEntityType {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Album => "album",
            Self::Track => "track",
        }
    }
}

impl fmt::Display for BulkEditEntityType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for BulkEditEntityType {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "album" => Ok(Self::Album),
            "track" => Ok(Self::Track),
            _ => Err(ValidationError::EmptyField {
                field: "entity_type",
                message: "bulk edit entity_type must be 'album' or 'track'",
            }),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TriStateFieldValue<T> {
    #[default]
    Empty,
    Common {
        value: T,
    },
    Mixed {
        distinct_count: usize,
        #[serde(default)]
        sample_values: Vec<T>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TagSelectionState {
    #[default]
    None,
    Some,
    All,
}

impl TagSelectionState {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Some => "some",
            Self::All => "all",
        }
    }
}

impl fmt::Display for TagSelectionState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for TagSelectionState {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "none" => Ok(Self::None),
            "some" => Ok(Self::Some),
            "all" => Ok(Self::All),
            _ => Err(ValidationError::EmptyField {
                field: "state",
                message: "tag selection state must be 'none', 'some', or 'all'",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BulkTagSummaryItem {
    pub tag_id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default)]
    pub state: TagSelectionState,
    #[serde(default)]
    pub assigned_count: usize,
    #[serde(default)]
    pub total_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BulkEditSummary {
    pub entity_type: BulkEditEntityType,
    #[serde(default)]
    pub selected_count: usize,
    #[serde(default)]
    pub fields: BTreeMap<String, TriStateFieldValue<serde_json::Value>>,
    #[serde(default)]
    pub meta_policy: TriStateFieldValue<String>,
    #[serde(default)]
    pub tags: Vec<BulkTagSummaryItem>,
    #[serde(default)]
    pub has_user_edits_count: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum FieldPatchOp<T> {
    #[default]
    Keep,
    Set {
        value: T,
    },
    Clear,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct BulkEditPatch {
    #[serde(default)]
    pub fields: BTreeMap<String, FieldPatchOp<serde_json::Value>>,
    #[serde(default)]
    pub meta_policy: FieldPatchOp<String>,
    #[serde(default)]
    pub add_tag_ids: Vec<String>,
    #[serde(default)]
    pub remove_tag_ids: Vec<String>,
    #[serde(default)]
    pub revert_to_file_meta: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BulkEditResult {
    pub entity_type: BulkEditEntityType,
    #[serde(default)]
    pub updated_count: usize,
    #[serde(default)]
    pub reverted_count: usize,
    #[serde(default)]
    pub tags_added: u64,
    #[serde(default)]
    pub tags_removed: u64,
    #[serde(default)]
    pub recomputed_groups: usize,
    #[serde(default)]
    pub pruned_orphan_versions: usize,
    #[serde(default)]
    pub pruned_orphan_albums: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bulk_edit_tri_state_and_patch_serde() {
        let mut fields = BTreeMap::new();
        fields.insert(
            "genre".into(),
            TriStateFieldValue::Common {
                value: serde_json::json!("Jazz"),
            },
        );
        fields.insert(
            "release_year".into(),
            TriStateFieldValue::Mixed {
                distinct_count: 2,
                sample_values: vec![serde_json::json!(1959), serde_json::json!(1964)],
            },
        );
        fields.insert("upc".into(), TriStateFieldValue::Empty);

        let summary = BulkEditSummary {
            entity_type: BulkEditEntityType::Album,
            selected_count: 3,
            fields,
            meta_policy: TriStateFieldValue::Common {
                value: "file".into(),
            },
            tags: vec![BulkTagSummaryItem {
                tag_id: "t-1".into(),
                name: "Audiophile".into(),
                color: None,
                state: TagSelectionState::Some,
                assigned_count: 2,
                total_count: 3,
            }],
            has_user_edits_count: 1,
        };
        let encoded = serde_json::to_value(&summary).unwrap();
        assert_eq!(encoded["entity_type"], "album");
        assert_eq!(encoded["fields"]["genre"]["state"], "common");
        assert_eq!(encoded["fields"]["release_year"]["state"], "mixed");
        assert_eq!(encoded["fields"]["upc"]["state"], "empty");
        assert_eq!(encoded["tags"][0]["state"], "some");
        assert_eq!(
            serde_json::from_value::<BulkEditSummary>(encoded).unwrap(),
            summary
        );

        let patch: BulkEditPatch = serde_json::from_str(
            r#"{"fields":{"genre":{"op":"set","value":"Classical"},"upc":{"op":"clear"}}}"#,
        )
        .unwrap();
        assert_eq!(patch.meta_policy, FieldPatchOp::Keep);
        assert_eq!(
            patch.fields.get("genre"),
            Some(&FieldPatchOp::Set {
                value: serde_json::json!("Classical")
            })
        );
        assert_eq!(patch.fields.get("upc"), Some(&FieldPatchOp::Clear));
        assert!(!patch.revert_to_file_meta);
    }
}
