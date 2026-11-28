use serde::{Deserialize, Serialize};

use crate::ExternalCatalogIngestBatch;

// ============================================================================
// Step 4: Listen Later DTOs (Library References + External Streaming Snapshots)
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListenLaterItemDto {
    pub id: String,
    pub source_kind: String,
    pub entity_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entity_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    pub title: String,
    #[serde(default)]
    pub artist_name: String,
    #[serde(default)]
    pub album_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_count: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata_json: Option<String>,
    #[serde(default)]
    pub note: String,
    pub status: String,
    pub added_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listened_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub promoted_entity_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddListenLaterRequest {
    pub source_kind: String,
    pub entity_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entity_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    pub title: String,
    #[serde(default)]
    pub artist_name: String,
    #[serde(default)]
    pub album_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_count: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata_json: Option<String>,
    #[serde(default)]
    pub note: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateListenLaterStatusRequest {
    #[serde(default)]
    pub id: String,
    pub status: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateListenLaterNoteRequest {
    #[serde(default)]
    pub id: String,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromoteListenLaterRequest {
    pub ingest_batch: ExternalCatalogIngestBatch,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromoteListenLaterResponse {
    pub item: ListenLaterItemDto,
    pub promoted_entity_id: String,
}
