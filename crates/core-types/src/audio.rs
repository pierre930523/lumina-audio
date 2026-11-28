use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Feature 8: AudioCodec & AudioFormat
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioCodec {
    Flac,
    Alac,
    Wav,
    Aiff,
    Dsf,
    Dsdiff,
    Aac,
    Mp3,
    Opus,
}

impl AudioCodec {
    pub const ALL: [AudioCodec; 9] = [
        Self::Flac,
        Self::Alac,
        Self::Wav,
        Self::Aiff,
        Self::Dsf,
        Self::Dsdiff,
        Self::Aac,
        Self::Mp3,
        Self::Opus,
    ];

    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Flac => "flac",
            Self::Alac => "alac",
            Self::Wav => "wav",
            Self::Aiff => "aiff",
            Self::Dsf => "dsf",
            Self::Dsdiff => "dsdiff",
            Self::Aac => "aac",
            Self::Mp3 => "mp3",
            Self::Opus => "opus",
        }
    }

    pub const fn is_dsd(&self) -> bool {
        matches!(self, Self::Dsf | Self::Dsdiff)
    }

    pub const fn is_lossless(&self) -> bool {
        matches!(
            self,
            Self::Flac | Self::Alac | Self::Wav | Self::Aiff | Self::Dsf | Self::Dsdiff
        )
    }

    pub const fn is_lossy(&self) -> bool {
        !self.is_lossless()
    }

    pub const fn default_file_extension(&self) -> &'static str {
        match self {
            Self::Flac => "flac",
            Self::Alac => "m4a",
            Self::Wav => "wav",
            Self::Aiff => "aiff",
            Self::Dsf => "dsf",
            Self::Dsdiff => "dff",
            Self::Aac => "aac",
            Self::Mp3 => "mp3",
            Self::Opus => "opus",
        }
    }
}

impl fmt::Display for AudioCodec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Flac => write!(f, "FLAC"),
            Self::Alac => write!(f, "ALAC"),
            Self::Wav => write!(f, "WAV"),
            Self::Aiff => write!(f, "AIFF"),
            Self::Dsf => write!(f, "DSF"),
            Self::Dsdiff => write!(f, "DSDIFF"),
            Self::Aac => write!(f, "AAC"),
            Self::Mp3 => write!(f, "MP3"),
            Self::Opus => write!(f, "Opus"),
        }
    }
}

impl FromStr for AudioCodec {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let normalized = s.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "flac" => Ok(Self::Flac),
            "alac" => Ok(Self::Alac),
            "wav" | "wave" => Ok(Self::Wav),
            "aiff" | "aif" => Ok(Self::Aiff),
            "dsf" => Ok(Self::Dsf),
            "dsdiff" | "dff" => Ok(Self::Dsdiff),
            "aac" => Ok(Self::Aac),
            "mp3" => Ok(Self::Mp3),
            "opus" => Ok(Self::Opus),
            _ => Err(ValidationError::UnknownAudioCodec(s.to_string())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AudioFormat {
    pub codec: AudioCodec,
    pub sample_rate_hz: u32,
    pub bit_depth: u8,
    pub channels: u8,
    pub is_dsd: bool,
}

impl AudioFormat {
    pub fn new(
        codec: AudioCodec,
        sample_rate_hz: u32,
        bit_depth: u8,
        channels: u8,
    ) -> Result<Self, ValidationError> {
        if sample_rate_hz == 0 || sample_rate_hz > 50_000_000 {
            return Err(ValidationError::InvalidSampleRate(sample_rate_hz));
        }
        if channels == 0 || channels > 32 {
            return Err(ValidationError::InvalidChannels(channels));
        }

        let is_dsd = codec.is_dsd();
        if is_dsd {
            if bit_depth != 1 {
                return Err(ValidationError::InvalidDsdFormat);
            }
        } else if bit_depth == 0 || bit_depth > 64 {
            return Err(ValidationError::InvalidBitDepth { bit_depth, codec });
        }

        Ok(Self {
            codec,
            sample_rate_hz,
            bit_depth,
            channels,
            is_dsd,
        })
    }

    pub fn pcm(
        codec: AudioCodec,
        sample_rate_hz: u32,
        bit_depth: u8,
        channels: u8,
    ) -> Result<Self, ValidationError> {
        if codec.is_dsd() {
            return Err(ValidationError::InvalidDsdFormat);
        }
        Self::new(codec, sample_rate_hz, bit_depth, channels)
    }

    pub fn dsd(
        codec: AudioCodec,
        sample_rate_hz: u32,
        channels: u8,
    ) -> Result<Self, ValidationError> {
        if !codec.is_dsd() {
            return Err(ValidationError::InvalidDsdFormat);
        }
        Self::new(codec, sample_rate_hz, 1, channels)
    }

    pub fn cd_quality() -> Self {
        Self {
            codec: AudioCodec::Flac,
            sample_rate_hz: 44100,
            bit_depth: 16,
            channels: 2,
            is_dsd: false,
        }
    }

    pub fn is_dsd(&self) -> bool {
        self.is_dsd
    }

    pub fn is_hi_res(&self) -> bool {
        self.is_dsd || self.sample_rate_hz > 48000 || self.bit_depth > 16
    }

    pub fn is_cd_quality(&self) -> bool {
        !self.is_dsd && self.sample_rate_hz == 44100 && self.bit_depth == 16
    }

    pub fn dsd_rate_label(&self) -> Option<&'static str> {
        if !self.is_dsd {
            return None;
        }
        match self.sample_rate_hz {
            2_822_400 | 3_072_000 => Some("DSD64"),
            5_644_800 | 6_144_000 => Some("DSD128"),
            11_289_600 | 12_288_000 => Some("DSD256"),
            22_579_200 | 24_576_000 => Some("DSD512"),
            45_158_400 => Some("DSD1024"),
            _ => Some("DSD"),
        }
    }

    fn formatted_rate(&self) -> String {
        if self.is_dsd {
            format!("{:.2}MHz", self.sample_rate_hz as f64 / 1_000_000.0)
        } else if self.sample_rate_hz.is_multiple_of(1000) {
            format!("{}kHz", self.sample_rate_hz / 1000)
        } else if self.sample_rate_hz.is_multiple_of(100) {
            format!("{:.1}kHz", self.sample_rate_hz as f64 / 1000.0)
        } else {
            format!("{:.2}kHz", self.sample_rate_hz as f64 / 1000.0)
        }
    }
}

impl fmt::Display for AudioFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_dsd {
            let label = self.dsd_rate_label().unwrap_or("DSD");
            let mhz = self.formatted_rate();
            write!(f, "{} {} {} {}ch", self.codec, label, mhz, self.channels)
        } else {
            write!(
                f,
                "{} {}-bit/{} {}ch",
                self.codec,
                self.bit_depth,
                self.formatted_rate(),
                self.channels
            )
        }
    }
}
