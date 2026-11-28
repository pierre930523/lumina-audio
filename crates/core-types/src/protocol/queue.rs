use serde::{Deserialize, Serialize};

use super::{RepeatMode, TrackMetadata};

// ============================================================================
// QueueItem & QueueState
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct QueueItem {
    pub item_id: String,
    pub track: TrackMetadata,
    #[serde(default)]
    pub is_user_queued: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct QueueState {
    #[serde(default)]
    pub items: Vec<QueueItem>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_index: Option<usize>,
    #[serde(default)]
    pub repeat_mode: RepeatMode,
    #[serde(default)]
    pub shuffle: bool,
    #[serde(default)]
    pub queue_epoch: u64,
    #[serde(default)]
    pub timestamp_ms: u64,
}
