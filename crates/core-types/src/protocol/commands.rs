use serde::{Deserialize, Serialize};

use super::{RepeatMode, TrackMetadata};
use crate::OutputBackendKind;

fn default_true_bool() -> bool {
    true
}

// ============================================================================
// PlaybackCommand
// ============================================================================

#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum PlaybackCommand {
    Play {
        track: TrackMetadata,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        start_position_ms: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        playback_epoch: Option<u64>,
    },
    Pause,
    Resume,
    Stop,
    Seek {
        position_ms: u64,
    },
    Next,
    Previous,
    SetVolume {
        volume: f32,
    },
    SetMute {
        muted: bool,
    },
    SetRepeatMode {
        mode: RepeatMode,
    },
    SetShuffle {
        enabled: bool,
    },
    SetOutputDevice {
        device_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        backend: Option<OutputBackendKind>,
    },
    SetActiveZone {
        zone_id: String,
    },
    LoadQueue {
        items: Vec<TrackMetadata>,
        #[serde(default)]
        start_index: usize,
        #[serde(default = "default_true_bool")]
        auto_play: bool,
    },
    Enqueue {
        items: Vec<TrackMetadata>,
        #[serde(default)]
        play_next: bool,
    },
    RemoveQueueItem {
        index: usize,
    },
    ReorderQueue {
        from_index: usize,
        to_index: usize,
    },
    ClearQueue,
    ClearUpcomingQueue,
    ReconnectDevice,
}
