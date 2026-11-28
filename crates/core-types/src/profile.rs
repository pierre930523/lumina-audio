use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

use crate::ValidationError;

// ============================================================================
// Output & Profile Types
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputBackendKind {
    WindowsAsio,
    WindowsWasapiExclusive,
    WindowsWasapiShared,
    MacOsCoreAudioHog,
    MobileDirect,
    NetworkDlna,
    NetworkAirPlay,
}

impl OutputBackendKind {
    pub const ALL: [OutputBackendKind; 7] = [
        Self::WindowsAsio,
        Self::WindowsWasapiExclusive,
        Self::WindowsWasapiShared,
        Self::MacOsCoreAudioHog,
        Self::MobileDirect,
        Self::NetworkDlna,
        Self::NetworkAirPlay,
    ];

    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::WindowsAsio => "windows_asio",
            Self::WindowsWasapiExclusive => "windows_wasapi_exclusive",
            Self::WindowsWasapiShared => "windows_wasapi_shared",
            Self::MacOsCoreAudioHog => "macos_core_audio_hog",
            Self::MobileDirect => "mobile_direct",
            Self::NetworkDlna => "network_dlna",
            Self::NetworkAirPlay => "network_airplay",
        }
    }

    pub const fn is_bit_perfect_capable(&self) -> bool {
        matches!(
            self,
            Self::WindowsAsio
                | Self::WindowsWasapiExclusive
                | Self::MacOsCoreAudioHog
                | Self::MobileDirect
        )
    }

    pub const fn is_exclusive(&self) -> bool {
        matches!(
            self,
            Self::WindowsAsio | Self::WindowsWasapiExclusive | Self::MacOsCoreAudioHog
        )
    }

    pub const fn is_network(&self) -> bool {
        matches!(self, Self::NetworkDlna | Self::NetworkAirPlay)
    }
}

impl fmt::Display for OutputBackendKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for OutputBackendKind {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let normalized = s.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "windows_asio" | "asio" => Ok(Self::WindowsAsio),
            "windows_wasapi_exclusive" | "wasapi_exclusive" => Ok(Self::WindowsWasapiExclusive),
            "windows_wasapi_shared" | "wasapi_shared" | "wasapi" => Ok(Self::WindowsWasapiShared),
            "macos_core_audio_hog" | "core_audio_hog" | "hog" => Ok(Self::MacOsCoreAudioHog),
            "mobile_direct" => Ok(Self::MobileDirect),
            "network_dlna" | "dlna" => Ok(Self::NetworkDlna),
            "network_airplay" | "airplay" => Ok(Self::NetworkAirPlay),
            _ => Err(ValidationError::UnknownOutputBackend(s.to_string())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioZone {
    pub id: String,
    pub name: String,
    pub backend: OutputBackendKind,
    pub exclusive_mode: bool,
    pub dsp_bypass: bool,
}

impl AudioZone {
    pub fn new(
        name: impl Into<String>,
        backend: OutputBackendKind,
    ) -> Result<Self, ValidationError> {
        let n = name.into();
        if n.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "name",
                message: "zone name cannot be empty",
            });
        }
        let exclusive_mode = backend.is_exclusive();
        Ok(Self {
            id: Uuid::new_v4().to_string(),
            name: n.trim().to_string(),
            backend,
            exclusive_mode,
            dsp_bypass: false,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub avatar_color: String,
    pub is_default: bool,
}

impl Profile {
    pub fn new(
        name: impl Into<String>,
        avatar_color: impl Into<String>,
        is_default: bool,
    ) -> Result<Self, ValidationError> {
        let n = name.into();
        let color = avatar_color.into();
        if n.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "name",
                message: "profile name cannot be empty",
            });
        }
        Self::validate_hex_color(&color)?;

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            name: n.trim().to_string(),
            avatar_color: color.trim().to_uppercase(),
            is_default,
        })
    }

    pub fn default_profile() -> Self {
        Self {
            id: "default".to_string(),
            name: "Primary".to_string(),
            avatar_color: "#007AFF".to_string(),
            is_default: true,
        }
    }

    fn validate_hex_color(color: &str) -> Result<(), ValidationError> {
        let trimmed = color.trim();
        if !trimmed.starts_with('#') {
            return Err(ValidationError::InvalidHexColor(color.to_string()));
        }
        let hex_digits = &trimmed[1..];
        if (hex_digits.len() == 6 || hex_digits.len() == 8)
            && hex_digits.chars().all(|c| c.is_ascii_hexdigit())
        {
            Ok(())
        } else {
            Err(ValidationError::InvalidHexColor(color.to_string()))
        }
    }
}

// ============================================================================
// Shared DSP & Device DTOs
// ============================================================================

fn default_true() -> bool {
    true
}

fn default_q_factor() -> f64 {
    std::f64::consts::FRAC_1_SQRT_2
}

fn default_crossfeed_cutoff_hz() -> f64 {
    700.0
}

fn default_crossfeed_feed_db() -> f64 {
    -6.0
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PeqFilterKind {
    #[default]
    Peaking,
    LowShelf,
    HighShelf,
    LowPass,
    HighPass,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PeqBandConfig {
    #[serde(default)]
    pub filter_type: PeqFilterKind,
    pub frequency_hz: f64,
    pub gain_db: f64,
    #[serde(default = "default_q_factor")]
    pub q_factor: f64,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

impl Default for PeqBandConfig {
    fn default() -> Self {
        Self {
            filter_type: PeqFilterKind::Peaking,
            frequency_hz: 1000.0,
            gain_db: 0.0,
            q_factor: default_q_factor(),
            enabled: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CrossfeedConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_crossfeed_cutoff_hz")]
    pub cutoff_hz: f64,
    #[serde(default = "default_crossfeed_feed_db")]
    pub feed_level_db: f64,
}

impl Default for CrossfeedConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            cutoff_hz: default_crossfeed_cutoff_hz(),
            feed_level_db: default_crossfeed_feed_db(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReplayGainMode {
    #[default]
    Off,
    Track,
    Album,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReplayGainConfig {
    #[serde(default)]
    pub mode: ReplayGainMode,
    #[serde(default)]
    pub preamp_db: f64,
    #[serde(default = "default_true")]
    pub prevent_clipping: bool,
}

impl Default for ReplayGainConfig {
    fn default() -> Self {
        Self {
            mode: ReplayGainMode::Off,
            preamp_db: 0.0,
            prevent_clipping: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct DspPipelineConfig {
    #[serde(default)]
    pub bypass: bool,
    #[serde(default)]
    pub peq_bands: Vec<PeqBandConfig>,
    #[serde(default)]
    pub crossfeed: CrossfeedConfig,
    #[serde(default)]
    pub replay_gain: ReplayGainConfig,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioDeviceDescription {
    pub id: String,
    pub name: String,
    pub backend: OutputBackendKind,
    pub is_default: bool,
    pub is_exclusive: bool,
    pub supported_sample_rates: Vec<u32>,
    pub supported_bit_depths: Vec<u8>,
    pub supports_native_dsd: bool,
}
