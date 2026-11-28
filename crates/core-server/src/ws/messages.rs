use core_types::{
    AudioDeviceInfo, AudioQualityInfo, LuminaError, PlaybackLifecycleState, PlaybackState,
    ProtocolSnapshot, QueueState, RepeatMode, SignalPath, SignalQuality, TrackMetadata,
    WsServerEvent, ZoneInfo,
};
use serde::{Deserialize, Serialize};

fn default_stopped_status() -> String {
    PlaybackLifecycleState::Stopped.as_snake_str().to_string()
}

fn default_stopped_code() -> i32 {
    PlaybackLifecycleState::Stopped.as_i32()
}

fn default_stopped_name() -> String {
    PlaybackLifecycleState::Stopped
        .as_legacy_state_name()
        .to_string()
}

fn default_unit_volume() -> f32 {
    1.0
}

fn default_clock_source() -> String {
    "stream_frames".to_string()
}

#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum WsMessage {
    #[serde(rename = "Snapshot")]
    Snapshot { payload: ProtocolSnapshot },

    #[serde(rename = "PlaybackStateChanged")]
    PlaybackStateChanged { payload: PlaybackStatePayload },

    #[serde(rename = "QueueStateChanged")]
    QueueStateChanged { payload: QueueState },

    #[serde(rename = "SignalPathUpdated")]
    SignalPathUpdated { payload: SignalPathPayload },

    #[serde(rename = "DevicesChanged")]
    DevicesChanged { payload: Vec<AudioDeviceInfo> },

    #[serde(rename = "ZonesChanged")]
    ZonesChanged { payload: Vec<ZoneInfo> },

    #[serde(rename = "LibraryReloaded")]
    LibraryReloaded { payload: serde_json::Value },

    #[serde(rename = "Error")]
    Error { payload: LuminaError },

    #[serde(rename = "state_changed")]
    StateChanged {
        #[serde(flatten)]
        extra: serde_json::Value,
    },

    #[serde(rename = "event")]
    Event {
        event: String,
        payload: serde_json::Value,
    },
}

impl From<WsServerEvent> for WsMessage {
    fn from(ev: WsServerEvent) -> Self {
        match ev {
            WsServerEvent::Snapshot(payload) => Self::Snapshot { payload },
            WsServerEvent::PlaybackStateChanged(pb) => Self::PlaybackStateChanged {
                payload: PlaybackStatePayload::from(pb),
            },
            WsServerEvent::QueueStateChanged(payload) => Self::QueueStateChanged { payload },
            WsServerEvent::SignalPathUpdated(sp) => Self::SignalPathUpdated {
                payload: SignalPathPayload::from(&sp),
            },
            WsServerEvent::DevicesChanged(payload) => Self::DevicesChanged { payload },
            WsServerEvent::ZonesChanged(payload) => Self::ZonesChanged { payload },
            WsServerEvent::Error(payload) => Self::Error { payload },
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackStatePayload {
    #[serde(default = "default_stopped_status")]
    pub status: String,
    #[serde(default = "default_stopped_code")]
    pub state_code: i32,
    #[serde(default = "default_stopped_name")]
    pub state_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_track_id: Option<String>,
    #[serde(default)]
    pub position_ms: u64,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub timestamp_ms: u64,
    #[serde(default = "default_unit_volume")]
    pub volume: f32,
    #[serde(default)]
    pub is_muted: bool,
    #[serde(default)]
    pub repeat_mode: RepeatMode,
    #[serde(default)]
    pub shuffle: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_quality: Option<AudioQualityInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_device: Option<AudioDeviceInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_zone_id: Option<String>,
    #[serde(default = "default_clock_source")]
    pub clock_source: String,
    #[serde(default)]
    pub seek_epoch: u64,
    #[serde(default)]
    pub is_seeking: bool,
    #[serde(default)]
    pub dsp_bypassed: bool,
    #[serde(default)]
    pub strict_bit_perfect: bool,
    #[serde(default)]
    pub device_lost: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<TrackMetadata>,
    #[serde(default)]
    pub swap_generation: u64,
    #[serde(default)]
    pub playback_epoch: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<LuminaError>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error_provider: Option<String>,
}

impl Default for PlaybackStatePayload {
    fn default() -> Self {
        Self::from(PlaybackState::default())
    }
}

impl From<PlaybackState> for PlaybackStatePayload {
    fn from(pb: PlaybackState) -> Self {
        Self {
            status: pb.status.as_snake_str().to_string(),
            state_code: pb.state_code,
            state_name: pb.state_name,
            track_id: pb.track_id,
            current_track_id: pb.current_track_id,
            position_ms: pb.position_ms,
            duration_ms: pb.duration_ms,
            timestamp_ms: pb.timestamp_ms,
            volume: pb.volume,
            is_muted: pb.is_muted,
            repeat_mode: pb.repeat_mode,
            shuffle: pb.shuffle,
            audio_quality: pb.audio_quality,
            active_device: pb.active_device,
            active_zone_id: pb.active_zone_id,
            clock_source: pb.clock_source,
            seek_epoch: pb.seek_epoch,
            is_seeking: pb.is_seeking,
            dsp_bypassed: pb.dsp_bypassed,
            strict_bit_perfect: pb.strict_bit_perfect,
            device_lost: pb.device_lost,
            track: pb.track,
            swap_generation: pb.swap_generation,
            playback_epoch: pb.playback_epoch,
            error: pb.error,
            last_error: pb.last_error,
            last_error_code: pb.last_error_code,
            last_error_provider: pb.last_error_provider,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalPathPayload {
    pub overall: SignalQuality,
    pub quality: String,
    pub nodes: Vec<SignalPathNodeDto>,
}

impl Default for SignalPathPayload {
    fn default() -> Self {
        Self {
            overall: SignalQuality::HighQuality,
            quality: SignalQuality::HighQuality.as_str().to_string(),
            nodes: Vec::new(),
        }
    }
}

impl From<&SignalPath> for SignalPathPayload {
    fn from(path: &SignalPath) -> Self {
        Self {
            overall: path.overall,
            quality: path.overall.as_str().to_string(),
            nodes: path
                .nodes
                .iter()
                .map(|n| SignalPathNodeDto {
                    stage: n.stage.clone(),
                    detail: n.detail.clone(),
                    quality: n.quality.as_str().to_string(),
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalPathNodeDto {
    pub stage: String,
    pub detail: String,
    pub quality: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsErrorResponse {
    pub status: String,
    pub error: String,
}

impl WsErrorResponse {
    pub fn new(msg: &str) -> Self {
        Self {
            status: "error".to_string(),
            error: msg.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ws_playback_state_message_json() {
        let msg = WsMessage::PlaybackStateChanged {
            payload: PlaybackStatePayload {
                status: "playing".to_string(),
                track_id: Some("trk-001".to_string()),
                position_ms: 12500,
                duration_ms: 163000,
                ..Default::default()
            },
        };

        let json_str = serde_json::to_string(&msg).unwrap();
        assert!(json_str.contains("\"type\":\"PlaybackStateChanged\""));
        assert!(json_str.contains("\"status\":\"playing\""));
        assert!(json_str.contains("\"track_id\":\"trk-001\""));
        assert!(json_str.contains("\"position_ms\":12500"));
        assert!(json_str.contains("\"duration_ms\":163000"));

        // Must round-trip into canonical WsServerEvent::PlaybackStateChanged
        let parsed: WsServerEvent = serde_json::from_str(&json_str).unwrap();
        match parsed {
            WsServerEvent::PlaybackStateChanged(pb) => {
                assert_eq!(pb.status, PlaybackLifecycleState::Playing);
                assert_eq!(pb.track_id.as_deref(), Some("trk-001"));
                assert_eq!(pb.position_ms, 12500);
                assert_eq!(pb.duration_ms, 163000);
            }
            other => panic!("Expected PlaybackStateChanged, got {other:?}"),
        }
    }

    #[test]
    fn test_ws_error_response_format() {
        let err = WsErrorResponse::new("Invalid JSON text frame");
        let json_str = serde_json::to_string(&err).unwrap();
        assert_eq!(
            json_str,
            "{\"status\":\"error\",\"error\":\"Invalid JSON text frame\"}"
        );
    }
}
