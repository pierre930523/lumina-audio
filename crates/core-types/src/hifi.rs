use serde::{Deserialize, Serialize};

use crate::{AudioCodec, AudioFormat, OutputBackendKind};

/// Raw PCM or DSD sample encoding representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SampleFormatKind {
    Int16,
    Int24Packed,
    Int24In32,
    Int32,
    Float32,
    Float64,
    DsdU8,
}

impl SampleFormatKind {
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Int16 => "PCM S16LE",
            Self::Int24Packed => "PCM S24LE",
            Self::Int24In32 => "PCM S24LE in 32-bit",
            Self::Int32 => "PCM S32LE",
            Self::Float32 => "PCM F32LE",
            Self::Float64 => "PCM F64LE",
            Self::DsdU8 => "DSD 1-bit",
        }
    }

    pub const fn container_bits(&self) -> u8 {
        match self {
            Self::Int16 => 16,
            Self::Int24Packed => 24,
            Self::Int24In32 | Self::Int32 | Self::Float32 => 32,
            Self::Float64 => 64,
            Self::DsdU8 => 8,
        }
    }

    pub const fn valid_bits(&self) -> u8 {
        match self {
            Self::Int16 => 16,
            Self::Int24Packed | Self::Int24In32 => 24,
            Self::Int32 | Self::Float32 => 32,
            Self::Float64 => 64,
            Self::DsdU8 => 1,
        }
    }

    pub const fn is_integer(&self) -> bool {
        matches!(
            self,
            Self::Int16 | Self::Int24Packed | Self::Int24In32 | Self::Int32
        )
    }
}

/// Speaker / channel arrangement matching Windows WAVEFORMATEXTENSIBLE masks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelLayout {
    Mono,
    Stereo,
    Surround21,
    Quad,
    Surround51,
    Surround71,
    CustomMask(u32),
}

impl ChannelLayout {
    pub const fn from_channels(channels: u16) -> Self {
        match channels {
            1 => Self::Mono,
            2 => Self::Stereo,
            3 => Self::Surround21,
            4 => Self::Quad,
            6 => Self::Surround51,
            8 => Self::Surround71,
            n => Self::CustomMask(match 1u32.checked_shl(n as u32) {
                Some(v) => v.wrapping_sub(1),
                None => u32::MAX,
            }),
        }
    }

    pub const fn speaker_mask(&self) -> u32 {
        match *self {
            Self::Mono => 0x0000_0004,       // SPEAKER_FRONT_CENTER
            Self::Stereo => 0x0000_0003,     // FL | FR
            Self::Surround21 => 0x0000_000B, // FL | FR | LFE
            Self::Quad => 0x0000_0033,       // FL | FR | BL | BR
            Self::Surround51 => 0x0000_003F, // FL | FR | FC | LFE | BL | BR
            Self::Surround71 => 0x0000_063F, // 5.1 + SL | SR
            Self::CustomMask(m) => m,
        }
    }

    pub fn label(&self) -> String {
        match self {
            Self::Mono => "Mono (1.0)".to_string(),
            Self::Stereo => "Stereo (L/R)".to_string(),
            Self::Surround21 => "2.1".to_string(),
            Self::Quad => "Quadraphonic (4.0)".to_string(),
            Self::Surround51 => "5.1 Surround".to_string(),
            Self::Surround71 => "7.1 Surround".to_string(),
            Self::CustomMask(m) => format!("Mask 0x{m:X}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Endianness {
    Little,
    Big,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Interleaving {
    Interleaved,
    Planar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DsdRate {
    Dsd64,
    Dsd128,
    Dsd256,
    Dsd512,
    Custom(u32),
}

impl DsdRate {
    pub const fn from_bit_clock_hz(hz: u32) -> Self {
        match hz {
            2_822_400 | 3_072_000 => Self::Dsd64,
            5_644_800 | 6_144_000 => Self::Dsd128,
            11_289_600 | 12_288_000 => Self::Dsd256,
            22_579_200 | 24_576_000 => Self::Dsd512,
            other => Self::Custom(other),
        }
    }

    pub const fn bit_clock_hz(&self) -> u32 {
        match *self {
            Self::Dsd64 => 2_822_400,
            Self::Dsd128 => 5_644_800,
            Self::Dsd256 => 11_289_600,
            Self::Dsd512 => 22_579_200,
            Self::Custom(hz) => hz,
        }
    }

    /// Required 24-bit PCM carrier rate for DoP v1.1 (`bit_clock / 16`).
    pub const fn dop_carrier_rate_hz(&self) -> Option<u32> {
        match *self {
            Self::Dsd64 => Some(176_400),
            Self::Dsd128 => Some(352_800),
            Self::Dsd256 => Some(705_600),
            Self::Dsd512 => Some(1_411_200),
            Self::Custom(hz) => {
                if hz >= 1_411_200 && hz.is_multiple_of(16) {
                    Some(hz / 16)
                } else {
                    None
                }
            }
        }
    }

    pub fn label(&self) -> String {
        match *self {
            Self::Dsd64 => "DSD64 (2.8224 MHz)".to_string(),
            Self::Dsd128 => "DSD128 (5.6448 MHz)".to_string(),
            Self::Dsd256 => "DSD256 (11.2896 MHz)".to_string(),
            Self::Dsd512 => "DSD512 (22.5792 MHz)".to_string(),
            Self::Custom(hz) => format!("DSD ({hz} Hz)"),
        }
    }
}

/// Unified format descriptor capturing full container, precision, layout, and DSD rate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnifiedAudioFormat {
    pub codec: AudioCodec,
    pub sample_rate: u32,
    pub channels: u16,
    pub channel_layout: ChannelLayout,
    pub sample_format: SampleFormatKind,
    pub container_bits: u8,
    pub valid_bits: u8,
    pub endianness: Endianness,
    pub interleaving: Interleaving,
    pub dsd_rate: Option<DsdRate>,
}

impl UnifiedAudioFormat {
    pub fn from_audio_format(fmt: &AudioFormat) -> Self {
        let ch = (fmt.channels as u16).max(1);
        if fmt.is_dsd {
            let rate = DsdRate::from_bit_clock_hz(fmt.sample_rate_hz);
            Self {
                codec: fmt.codec,
                sample_rate: fmt.sample_rate_hz,
                channels: ch,
                channel_layout: ChannelLayout::from_channels(ch),
                sample_format: SampleFormatKind::DsdU8,
                container_bits: 8,
                valid_bits: 1,
                endianness: Endianness::Little,
                interleaving: Interleaving::Interleaved,
                dsd_rate: Some(rate),
            }
        } else {
            let (sample_format, container_bits) = match fmt.bit_depth {
                d if d <= 16 => (SampleFormatKind::Int16, 16),
                24 => (SampleFormatKind::Int24Packed, 24),
                _ => (SampleFormatKind::Int32, 32),
            };
            Self {
                codec: fmt.codec,
                sample_rate: fmt.sample_rate_hz,
                channels: ch,
                channel_layout: ChannelLayout::from_channels(ch),
                sample_format,
                container_bits,
                valid_bits: fmt.bit_depth,
                endianness: Endianness::Little,
                interleaving: Interleaving::Interleaved,
                dsd_rate: None,
            }
        }
    }

    pub fn display_summary(&self) -> String {
        if let Some(dsd) = self.dsd_rate {
            format!("{} {}ch {}", self.codec, self.channels, dsd.label())
        } else {
            format!(
                "{} {} Hz / {}-bit (valid {}-bit) {}ch",
                self.codec, self.sample_rate, self.container_bits, self.valid_bits, self.channels
            )
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceTransportKind {
    UsbDac,
    Internal,
    Headphones,
    Speakers,
    Bluetooth,
    Asio,
    Virtual,
    Network,
}

impl DeviceTransportKind {
    pub const fn label_zh(&self) -> &'static str {
        match self {
            Self::UsbDac => "USB DAC",
            Self::Internal => "內建音效卡",
            Self::Headphones => "耳機",
            Self::Speakers => "喇叭",
            Self::Bluetooth => "藍牙音訊",
            Self::Asio => "ASIO 驅動",
            Self::Virtual => "虛擬 DAC",
            Self::Network => "網路音區",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputMode {
    WasapiExclusive,
    WasapiShared,
    AsioPcm,
    AsioNativeDsd,
    DoPOverWasapiExclusive,
    DoPOverAsio,
    DsdToPcm,
    VirtualMock,
}

impl OutputMode {
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::WasapiExclusive => "WASAPI Exclusive",
            Self::WasapiShared => "WASAPI Shared",
            Self::AsioPcm => "ASIO Native PCM",
            Self::AsioNativeDsd => "ASIO Native DSD",
            Self::DoPOverWasapiExclusive => "DoP over WASAPI Exclusive",
            Self::DoPOverAsio => "DoP over ASIO",
            Self::DsdToPcm => "DSD-to-PCM Conversion",
            Self::VirtualMock => "Virtual Exclusive Pipeline",
        }
    }

    pub const fn is_exclusive_or_asio(&self) -> bool {
        matches!(
            self,
            Self::WasapiExclusive
                | Self::AsioPcm
                | Self::AsioNativeDsd
                | Self::DoPOverWasapiExclusive
                | Self::DoPOverAsio
                | Self::VirtualMock
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DsdOutputMode {
    #[default]
    Auto,
    NativeDsd,
    DoP,
    DsdToPcm,
}

/// Exact verification status tokens mandated for the Output Information Panel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum VerificationStatus {
    #[serde(rename = "BIT-PERFECT")]
    BitPerfect,
    #[serde(rename = "PCM UNMODIFIED")]
    PcmUnmodified,
    #[serde(rename = "NOT BIT-PERFECT")]
    NotBitPerfect,
    #[serde(rename = "NOT VERIFIED")]
    NotVerified,
    #[serde(rename = "EXCLUSIVE MODE UNAVAILABLE")]
    ExclusiveModeUnavailable,
    #[serde(rename = "DSD NATIVE")]
    DsdNative,
    #[serde(rename = "DSD DoP")]
    DsdDop,
    #[serde(rename = "DSD TO PCM")]
    DsdToPcm,
}

impl VerificationStatus {
    pub const fn as_token(&self) -> &'static str {
        match self {
            Self::BitPerfect => "BIT-PERFECT",
            Self::PcmUnmodified => "PCM UNMODIFIED",
            Self::NotBitPerfect => "NOT BIT-PERFECT",
            Self::NotVerified => "NOT VERIFIED",
            Self::ExclusiveModeUnavailable => "EXCLUSIVE MODE UNAVAILABLE",
            Self::DsdNative => "DSD NATIVE",
            Self::DsdDop => "DSD DoP",
            Self::DsdToPcm => "DSD TO PCM",
        }
    }
}

/// Rich capability profile reported per physical/driver audio device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioDeviceCapabilities {
    pub device_id: String,
    pub name: String,
    pub backend: OutputBackendKind,
    pub transport: DeviceTransportKind,
    pub is_default: bool,
    pub is_exclusive: bool,
    pub supported_sample_rates: Vec<u32>,
    pub supported_bit_depths: Vec<u8>,
    pub supported_container_bits: Vec<u8>,
    pub supported_channels: Vec<u16>,
    pub supported_output_modes: Vec<OutputMode>,
    pub supports_native_dsd: bool,
    pub supports_dop: bool,
    #[serde(default)]
    pub supports_float32: bool,
    pub max_dsd_rate: Option<DsdRate>,
    pub asio_available: bool,
    pub asio_driver_name: Option<String>,
    pub exclusive_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub probe_note: Option<String>,
}

/// Playback engine policy controlling Bit-Perfect Strict Mode and DSD behavior.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaybackEnginePolicy {
    pub strict_bit_perfect: bool,
    pub allow_shared_fallback: bool,
    pub dsd_output_mode: DsdOutputMode,
    pub preferred_buffer_frames: u32,
}

impl Default for PlaybackEnginePolicy {
    fn default() -> Self {
        Self {
            strict_bit_perfect: false,
            allow_shared_fallback: true,
            dsd_output_mode: DsdOutputMode::Auto,
            preferred_buffer_frames: 512,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AudioSourceInfo {
    pub codec: String,
    pub sample_rate_hz: u32,
    pub bit_depth: u8,
    pub channels: u16,
    pub channel_layout: String,
    pub source_format: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AudioDecoderInfo {
    pub decoder_type: String,
    pub decoded_pcm_format: String,
    pub sample_rate_hz: u32,
    pub container_bits: u8,
    pub valid_bits: u8,
    pub integer_preserved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AudioOutputInfo {
    pub selected_device: String,
    pub transport_kind: String,
    pub audio_api: String,
    pub output_mode: String,
    pub sample_rate_hz: u32,
    pub container_bits: u8,
    pub valid_bits: u8,
    pub channels: u16,
    pub buffer_size_frames: u32,
    pub dsp_status: String,
    pub software_volume_status: String,
    pub strict_mode: bool,
    pub hardware_volume_recommended: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub degradation_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioVerificationInfo {
    pub pcm_sample_check: String,
    pub sample_hash_match: bool,
    pub decoder_sha256: String,
    pub processing_sha256: String,
    pub backend_input_sha256: String,
    pub format_match: bool,
    pub output_path: String,
    pub verification_level: String,
    pub status: VerificationStatus,
    pub frames_verified: u64,
    pub mismatched_frames: u64,
}

impl Default for AudioVerificationInfo {
    fn default() -> Self {
        Self {
            pcm_sample_check: "Not Started".to_string(),
            sample_hash_match: false,
            decoder_sha256: String::new(),
            processing_sha256: String::new(),
            backend_input_sha256: String::new(),
            format_match: false,
            output_path: "Idle".to_string(),
            verification_level: "Software Verification Only (Decoder → Output Backend Input)"
                .to_string(),
            status: VerificationStatus::NotVerified,
            frames_verified: 0,
            mismatched_frames: 0,
        }
    }
}

/// Full Phase 10 Audio Output Information snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AudioEngineOutputInfo {
    pub source: AudioSourceInfo,
    pub decoder: AudioDecoderInfo,
    pub output: AudioOutputInfo,
    pub verification: AudioVerificationInfo,
}
