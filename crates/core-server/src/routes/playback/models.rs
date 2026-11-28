use core_audio::StreamSource;
use core_types::{
    DeckTrackMetadata, PeqBandConfig, PlaybackState, StreamSourceSpec, TrackMetadata,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub(super) const SERVER_RAPID_WINDOW_MS: u64 = 300;
pub(super) const SERVER_DEBOUNCE_MS: u64 = 130;

#[derive(Debug, Deserialize, Default)]
pub struct PlaybackCommandRequest {
    pub track_id: Option<String>,
    pub file_path: Option<String>,
    pub stream_url: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub source: Option<String>,
    pub hint_extension: Option<String>,
    #[serde(default, alias = "epoch")]
    pub playback_epoch: Option<u64>,
    #[serde(default)]
    pub source_spec: Option<StreamSourceSpec>,
    #[serde(default)]
    pub track: Option<DeckTrackMetadata>,
    #[serde(default)]
    pub debounced: bool,
}

#[derive(Debug, Deserialize)]
pub struct SeekRequest {
    pub position_ms: u64,
}

#[derive(Debug, Deserialize)]
pub struct VolumeRequest {
    pub volume: f32,
}

#[derive(Debug, Deserialize)]
pub struct AutoEqImportRequest {
    pub text: String,
    pub apply: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct AutoEqImportResponse {
    pub peq_bands: Vec<PeqBandConfig>,
    pub applied: bool,
}

#[derive(Debug, Deserialize)]
pub struct SelectAudioDeviceRequest {
    pub device_id: Option<String>,
    pub backend: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PlaybackActionResponse {
    pub status: String,
    #[serde(default)]
    pub playback_epoch: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackStateResponse {
    #[serde(flatten)]
    pub state: PlaybackState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_track: Option<TrackMetadata>,
    #[serde(default)]
    pub epoch: u64,
}

pub(super) enum ServerResolvedCandidate {
    SourceSpec {
        spec: StreamSourceSpec,
        label: String,
    },
    Legacy {
        stream: StreamSource,
        label: String,
    },
}
