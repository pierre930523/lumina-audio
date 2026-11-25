use core_types::DeckTrackMetadata;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum WsMessage {
    #[serde(rename = "PlaybackStateChanged")]
    PlaybackStateChanged { payload: PlaybackStatePayload },

    #[serde(rename = "SignalPathUpdated")]
    SignalPathUpdated { payload: SignalPathPayload },

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

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PlaybackStatePayload {
    pub status: String,
    pub track_id: Option<String>,
    pub position_ms: u64,
    pub duration_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<DeckTrackMetadata>,
    #[serde(default)]
    pub swap_generation: u64,
    #[serde(default)]
    pub playback_epoch: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SignalPathPayload {
    pub quality: String,
    pub nodes: Vec<SignalPathNodeDto>,
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
    }

    #[test]
    fn test_ws_error_response_format() {
        let err = WsErrorResponse::new("Invalid JSON text frame");
        let json_str = serde_json::to_string(&err).unwrap();
        assert_eq!(json_str, "{\"status\":\"error\",\"error\":\"Invalid JSON text frame\"}");
    }
}
