use serde::{Deserialize, Serialize};
use std::fmt;

use super::{AudioDeviceInfo, LuminaError};
use crate::{AudioFormat, DeckTrackMetadata};

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

// ============================================================================
// PlaybackLifecycleState & RepeatMode
// ============================================================================

/// Canonical playback engine lifecycle state shared across FFI, REST/WS, and UI.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackLifecycleState {
    Uninitialized = 0,
    #[default]
    Stopped = 1,
    Playing = 2,
    Paused = 3,
    Error = 4,
    Loading = 5,
    Seeking = 6,
    Buffering = 7,
    Ended = 8,
}

impl PlaybackLifecycleState {
    #[inline]
    pub const fn as_i32(self) -> i32 {
        self as i32
    }

    #[inline]
    pub const fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::Uninitialized,
            1 => Self::Stopped,
            2 => Self::Playing,
            3 => Self::Paused,
            4 => Self::Error,
            5 => Self::Loading,
            6 => Self::Seeking,
            7 => Self::Buffering,
            8 => Self::Ended,
            _ => Self::Error,
        }
    }

    /// TitleCase state name used by legacy `state_name` fields in FFI/REST payloads.
    #[inline]
    pub const fn as_legacy_state_name(self) -> &'static str {
        match self {
            Self::Uninitialized => "Uninitialized",
            Self::Stopped => "Stopped",
            Self::Playing => "Playing",
            Self::Paused => "Paused",
            Self::Error => "Error",
            Self::Loading => "Loading",
            Self::Seeking => "Seeking",
            Self::Buffering => "Buffering",
            Self::Ended => "Ended",
        }
    }

    /// Backwards-compatible alias for [`Self::as_legacy_state_name`] used by `core-audio`.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        self.as_legacy_state_name()
    }

    /// Canonical `snake_case` wire token matching serde JSON serialization.
    #[inline]
    pub const fn as_snake_str(self) -> &'static str {
        match self {
            Self::Uninitialized => "uninitialized",
            Self::Stopped => "stopped",
            Self::Playing => "playing",
            Self::Paused => "paused",
            Self::Error => "error",
            Self::Loading => "loading",
            Self::Seeking => "seeking",
            Self::Buffering => "buffering",
            Self::Ended => "ended",
        }
    }
}

impl fmt::Display for PlaybackLifecycleState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_snake_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    #[default]
    Off,
    All,
    One,
}

impl RepeatMode {
    #[inline]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::All => "all",
            Self::One => "one",
        }
    }
}

impl fmt::Display for RepeatMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

// ============================================================================
// AudioQualityInfo & TrackMetadata
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct AudioQualityInfo {
    #[serde(default)]
    pub codec: String,
    #[serde(default)]
    pub sample_rate_hz: u32,
    #[serde(default)]
    pub bit_depth: u16,
    #[serde(default)]
    pub channels: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
    #[serde(default)]
    pub output_mode: String,
    #[serde(default)]
    pub is_dsd: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dsd_rate: Option<String>,
    #[serde(default)]
    pub bit_perfect: bool,
}

impl AudioQualityInfo {
    pub fn from_audio_format(
        fmt: &AudioFormat,
        output_mode: impl Into<String>,
        bit_perfect: bool,
    ) -> Self {
        Self {
            codec: fmt.codec.to_string(),
            sample_rate_hz: fmt.sample_rate_hz,
            bit_depth: fmt.bit_depth as u16,
            channels: fmt.channels as u16,
            bitrate_kbps: None,
            output_mode: output_mode.into(),
            is_dsd: fmt.is_dsd,
            dsd_rate: fmt.dsd_rate_label().map(str::to_string),
            bit_perfect,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct TrackMetadata {
    pub track_id: String,
    #[serde(default)]
    pub provider_id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disc_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uri: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_quality: Option<AudioQualityInfo>,
}

impl From<DeckTrackMetadata> for TrackMetadata {
    fn from(d: DeckTrackMetadata) -> Self {
        Self {
            track_id: d.track_id,
            provider_id: d.provider_id,
            title: d.title,
            artist: d.artist,
            album: d.album,
            album_id: None,
            artist_id: None,
            cover_url: d.cover_url,
            duration_ms: d.duration_ms,
            track_number: None,
            disc_number: None,
            isrc: None,
            uri: None,
            audio_quality: None,
        }
    }
}

impl From<&DeckTrackMetadata> for TrackMetadata {
    fn from(d: &DeckTrackMetadata) -> Self {
        d.clone().into()
    }
}

impl From<TrackMetadata> for DeckTrackMetadata {
    fn from(t: TrackMetadata) -> Self {
        Self {
            track_id: t.track_id,
            provider_id: t.provider_id,
            title: t.title,
            artist: t.artist,
            album: t.album,
            cover_url: t.cover_url,
            duration_ms: t.duration_ms,
        }
    }
}

impl From<&TrackMetadata> for DeckTrackMetadata {
    fn from(t: &TrackMetadata) -> Self {
        Self {
            track_id: t.track_id.clone(),
            provider_id: t.provider_id.clone(),
            title: t.title.clone(),
            artist: t.artist.clone(),
            album: t.album.clone(),
            cover_url: t.cover_url.clone(),
            duration_ms: t.duration_ms,
        }
    }
}

// ============================================================================
// PlaybackState
// ============================================================================

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaybackState {
    #[serde(default)]
    pub status: PlaybackLifecycleState,
    #[serde(default = "default_stopped_code")]
    pub state_code: i32,
    #[serde(default = "default_stopped_name")]
    pub state_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<TrackMetadata>,
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
    #[serde(default)]
    pub swap_generation: u64,
    #[serde(default)]
    pub playback_epoch: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<LuminaError>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error_provider: Option<String>,
}

impl Default for PlaybackState {
    fn default() -> Self {
        Self {
            status: PlaybackLifecycleState::Stopped,
            state_code: default_stopped_code(),
            state_name: default_stopped_name(),
            track: None,
            position_ms: 0,
            duration_ms: 0,
            timestamp_ms: 0,
            volume: default_unit_volume(),
            is_muted: false,
            repeat_mode: RepeatMode::Off,
            shuffle: false,
            audio_quality: None,
            active_device: None,
            active_zone_id: None,
            clock_source: default_clock_source(),
            seek_epoch: 0,
            is_seeking: false,
            dsp_bypassed: false,
            strict_bit_perfect: false,
            device_lost: false,
            swap_generation: 0,
            playback_epoch: 0,
            error: None,
            track_id: None,
            current_track_id: None,
            last_error: None,
            last_error_code: None,
            last_error_provider: None,
        }
    }
}

impl PlaybackState {
    /// Updates `status`, `state_code`, and `state_name` consistently.
    pub fn with_status(mut self, status: PlaybackLifecycleState) -> Self {
        self.status = status;
        self.state_code = status.as_i32();
        self.state_name = status.as_legacy_state_name().to_string();
        self
    }

    /// Populates both structured `error` and legacy `last_error*` fields consistently.
    pub fn with_error(mut self, err: LuminaError) -> Self {
        self.last_error = Some(err.message.clone());
        self.last_error_code = Some(err.code.as_str().to_string());
        self.last_error_provider = err.provider.clone();
        self.error = Some(err);
        self
    }
}
