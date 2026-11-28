use serde::{Deserialize, Serialize};

use super::PlaybackLifecycleState;
use crate::{AudioDeviceCapabilities, AudioDeviceDescription, OutputBackendKind};

fn default_unit_volume() -> f32 {
    1.0
}

fn default_stereo_channels() -> u16 {
    2
}

// ============================================================================
// AudioDeviceInfo
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioDeviceInfo {
    pub id: String,
    pub name: String,
    pub backend: OutputBackendKind,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default)]
    pub is_active: bool,
    #[serde(default)]
    pub supports_exclusive: bool,
    #[serde(default)]
    pub supports_dsd: bool,
    #[serde(default)]
    pub supports_dop: bool,
    #[serde(default)]
    pub supported_sample_rates: Vec<u32>,
    #[serde(default = "default_stereo_channels")]
    pub max_channels: u16,
    #[serde(default)]
    pub is_hdmi: bool,
    #[serde(default)]
    pub buffer_size_supported: bool,
    #[serde(default)]
    pub min_buffer_frames: u32,
    #[serde(default)]
    pub max_buffer_frames: u32,
    #[serde(default)]
    pub default_buffer_frames: u32,
    #[serde(default)]
    pub buffer_granularity: u32,
}

impl Default for AudioDeviceInfo {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            backend: OutputBackendKind::WindowsWasapiShared,
            is_default: false,
            is_active: false,
            supports_exclusive: false,
            supports_dsd: false,
            supports_dop: false,
            supported_sample_rates: Vec::new(),
            max_channels: default_stereo_channels(),
            is_hdmi: false,
            buffer_size_supported: false,
            min_buffer_frames: 0,
            max_buffer_frames: 0,
            default_buffer_frames: 0,
            buffer_granularity: 0,
        }
    }
}

impl From<AudioDeviceDescription> for AudioDeviceInfo {
    fn from(d: AudioDeviceDescription) -> Self {
        Self {
            id: d.id,
            name: d.name,
            backend: d.backend,
            is_default: d.is_default,
            is_active: false,
            supports_exclusive: d.is_exclusive || d.backend.is_exclusive(),
            supports_dsd: d.supports_native_dsd,
            supports_dop: false,
            supported_sample_rates: d.supported_sample_rates,
            max_channels: default_stereo_channels(),
            is_hdmi: false,
            buffer_size_supported: false,
            min_buffer_frames: 0,
            max_buffer_frames: 0,
            default_buffer_frames: 0,
            buffer_granularity: 0,
        }
    }
}

impl From<&AudioDeviceDescription> for AudioDeviceInfo {
    fn from(d: &AudioDeviceDescription) -> Self {
        d.clone().into()
    }
}

impl From<&AudioDeviceCapabilities> for AudioDeviceInfo {
    fn from(cap: &AudioDeviceCapabilities) -> Self {
        Self {
            id: cap.device_id.clone(),
            name: cap.name.clone(),
            backend: cap.backend,
            is_default: cap.is_default,
            is_active: false,
            supports_exclusive: cap.exclusive_available || cap.is_exclusive,
            supports_dsd: cap.supports_native_dsd,
            supports_dop: cap.supports_dop,
            supported_sample_rates: cap.supported_sample_rates.clone(),
            max_channels: cap
                .supported_channels
                .iter()
                .copied()
                .max()
                .unwrap_or_else(default_stereo_channels),
            is_hdmi: false,
            buffer_size_supported: false,
            min_buffer_frames: 0,
            max_buffer_frames: 0,
            default_buffer_frames: 0,
            buffer_granularity: 0,
        }
    }
}

// ============================================================================
// ZoneInfo (promoted from core-server::zones::ZoneInfo)
// ============================================================================

/// Canonical multi-room audio zone descriptor shared across `core-server`, `core-ffi`, and Flutter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ZoneInfo {
    pub id: String,
    pub name: String,
    pub backend: String,
    #[serde(default)]
    pub device_id: Option<String>,
    #[serde(default)]
    pub endpoint_url: Option<String>,
    #[serde(default)]
    pub control_url: Option<String>,
    #[serde(default)]
    pub rendering_url: Option<String>,
    #[serde(default)]
    pub clock_sync_addr: Option<String>,
    #[serde(default)]
    pub group_id: Option<String>,
    #[serde(default)]
    pub exclusive_mode: bool,
    #[serde(default)]
    pub dsp_bypass: bool,
    #[serde(default = "default_unit_volume")]
    pub volume: f32,
    #[serde(default)]
    pub is_active: bool,
    #[serde(default)]
    pub clock_offset_us: Option<i64>,
    #[serde(default)]
    pub rtt_us: Option<i64>,
    #[serde(default)]
    pub drift_ppm: Option<f64>,
    #[serde(default)]
    pub is_muted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playback_status: Option<PlaybackLifecycleState>,
}

impl Default for ZoneInfo {
    fn default() -> Self {
        Self {
            id: "zone-local".to_string(),
            name: "Local DAC".to_string(),
            backend: OutputBackendKind::WindowsWasapiShared.as_str().to_string(),
            device_id: None,
            endpoint_url: None,
            control_url: None,
            rendering_url: None,
            clock_sync_addr: None,
            group_id: None,
            exclusive_mode: false,
            dsp_bypass: false,
            volume: default_unit_volume(),
            is_active: true,
            clock_offset_us: Some(0),
            rtt_us: Some(0),
            drift_ppm: Some(0.0),
            is_muted: false,
            active_device_id: None,
            playback_status: None,
        }
    }
}
