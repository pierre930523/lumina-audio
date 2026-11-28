use serde::{Deserialize, Serialize};

use super::{AudioDeviceInfo, LuminaError, PlaybackState, QueueState, ZoneInfo};
use crate::SignalPath;

// ============================================================================
// ProtocolSnapshot & WsServerEvent
// ============================================================================

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct ProtocolSnapshot {
    pub playback: PlaybackState,
    #[serde(default)]
    pub queue: QueueState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal_path: Option<SignalPath>,
    #[serde(default)]
    pub devices: Vec<AudioDeviceInfo>,
    #[serde(default)]
    pub zones: Vec<ZoneInfo>,
    #[serde(default)]
    pub server_time_ms: u64,
    #[serde(default)]
    pub sequence: u64,
}

#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum WsServerEvent {
    Snapshot(ProtocolSnapshot),
    PlaybackStateChanged(PlaybackState),
    QueueStateChanged(QueueState),
    SignalPathUpdated(SignalPath),
    DevicesChanged(Vec<AudioDeviceInfo>),
    ZonesChanged(Vec<ZoneInfo>),
    Error(LuminaError),
}
