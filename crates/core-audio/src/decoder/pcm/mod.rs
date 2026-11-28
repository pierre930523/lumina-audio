pub mod decoder;
pub mod opus;
pub mod synth;

pub use decoder::SymphoniaDecoder;
pub use opus::{OpusSymphoniaDecoder, register_opus_codec};
pub use synth::SynthAudioDecoder;

use crate::error::DecoderError;
use core_types::{AudioFormat, NormalizedLoudness, SampleFormatKind, UnifiedAudioFormat};
use sha2::{Digest, Sha256};
use std::time::Duration;

/// Tags extracted from the audio container (ID3v2, VorbisComment, RIFF INFO, etc.).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DecodedTrackMetadata {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub track_number: Option<u32>,
    pub replaygain_track_db: Option<f64>,
    pub replaygain_album_db: Option<f64>,
    pub replaygain_track_peak: Option<f32>,
    pub replaygain_album_peak: Option<f32>,
    pub r128_track_gain: Option<i16>,
    pub r128_album_gain: Option<i16>,
}

impl DecodedTrackMetadata {
    /// Converts container ReplayGain 2.0 or EBU R128 track gain tags into a unified
    /// `-14.0 LUFS` [`NormalizedLoudness`] adjustment.
    pub fn track_normalized_loudness(&self) -> Option<NormalizedLoudness> {
        if let Some(gain) = self.replaygain_track_db {
            return Some(NormalizedLoudness::from_replay_gain(
                gain as f32,
                self.replaygain_track_peak,
            ));
        }
        self.r128_track_gain.map(NormalizedLoudness::from_r128_q78)
    }

    /// Converts container ReplayGain 2.0 or EBU R128 album gain tags into a unified
    /// `-14.0 LUFS` [`NormalizedLoudness`] adjustment.
    pub fn album_normalized_loudness(&self) -> Option<NormalizedLoudness> {
        if let Some(gain) = self.replaygain_album_db {
            return Some(NormalizedLoudness::from_replay_gain(
                gain as f32,
                self.replaygain_album_peak,
            ));
        }
        self.r128_album_gain.map(NormalizedLoudness::from_r128_q78)
    }
}

/// Lossless sample-format-preserving audio chunk produced by decoders and verified across stages.
/// Integer PCM tracks (FLAC/WAV/ALAC 16/24/32-bit) stay integer without forced float conversion;
/// DSD tracks stay 1-bit packed bytes.
#[derive(Debug, Clone, PartialEq)]
pub enum AudioChunk {
    /// Interleaved signed 16-bit integer PCM: `[L0, R0, L1, R1, ...]`
    PcmI16 {
        samples: Vec<i16>,
        channels: u16,
        sample_rate: u32,
    },
    /// Interleaved signed 24-bit integer PCM stored sign-extended in `i32` (`[-8_388_608, 8_388_607]`).
    PcmI24In32 {
        samples: Vec<i32>,
        channels: u16,
        sample_rate: u32,
    },
    /// Interleaved signed 32-bit integer PCM.
    PcmI32 {
        samples: Vec<i32>,
        channels: u16,
        sample_rate: u32,
    },
    /// Interleaved 32-bit IEEE float PCM: `[L0, R0, L1, R1, ...]`
    PcmF32 {
        samples: Vec<f32>,
        channels: u16,
        sample_rate: u32,
    },
    /// Interleaved 64-bit IEEE float PCM: `[L0, R0, L1, R1, ...]`
    PcmF64 {
        samples: Vec<f64>,
        channels: u16,
        sample_rate: u32,
    },
    /// Byte-interleaved packed 1-bit DSD bitstream `[L_byte0, R_byte0, ...]`
    DsdBitstream {
        bytes: Vec<u8>,
        channels: u16,
        sample_rate: u32,
        is_lsb_first: bool,
    },
}

impl AudioChunk {
    pub fn channels(&self) -> u16 {
        match self {
            Self::PcmI16 { channels, .. }
            | Self::PcmI24In32 { channels, .. }
            | Self::PcmI32 { channels, .. }
            | Self::PcmF32 { channels, .. }
            | Self::PcmF64 { channels, .. }
            | Self::DsdBitstream { channels, .. } => *channels,
        }
    }

    pub fn sample_rate(&self) -> u32 {
        match self {
            Self::PcmI16 { sample_rate, .. }
            | Self::PcmI24In32 { sample_rate, .. }
            | Self::PcmI32 { sample_rate, .. }
            | Self::PcmF32 { sample_rate, .. }
            | Self::PcmF64 { sample_rate, .. }
            | Self::DsdBitstream { sample_rate, .. } => *sample_rate,
        }
    }

    pub fn sample_format_kind(&self) -> SampleFormatKind {
        match self {
            Self::PcmI16 { .. } => SampleFormatKind::Int16,
            Self::PcmI24In32 { .. } => SampleFormatKind::Int24In32,
            Self::PcmI32 { .. } => SampleFormatKind::Int32,
            Self::PcmF32 { .. } => SampleFormatKind::Float32,
            Self::PcmF64 { .. } => SampleFormatKind::Float64,
            Self::DsdBitstream { .. } => SampleFormatKind::DsdU8,
        }
    }

    pub fn valid_bits(&self) -> u8 {
        self.sample_format_kind().valid_bits()
    }

    pub fn frames(&self) -> usize {
        let ch = self.channels().max(1) as usize;
        match self {
            Self::PcmI16 { samples, .. } => samples.len() / ch,
            Self::PcmI24In32 { samples, .. } | Self::PcmI32 { samples, .. } => samples.len() / ch,
            Self::PcmF32 { samples, .. } => samples.len() / ch,
            Self::PcmF64 { samples, .. } => samples.len() / ch,
            Self::DsdBitstream { bytes, .. } => (bytes.len() * 8) / ch,
        }
    }

    pub fn is_empty(&self) -> bool {
        match self {
            Self::PcmI16 { samples, .. } => samples.is_empty(),
            Self::PcmI24In32 { samples, .. } | Self::PcmI32 { samples, .. } => samples.is_empty(),
            Self::PcmF32 { samples, .. } => samples.is_empty(),
            Self::PcmF64 { samples, .. } => samples.is_empty(),
            Self::DsdBitstream { bytes, .. } => bytes.is_empty(),
        }
    }

    /// Converts to `f64` ONLY when DSP/SRC/non-native fallback explicitly needs float.
    pub fn to_f64_interleaved(&self) -> Vec<f64> {
        match self {
            Self::PcmI16 { samples, .. } => samples.iter().map(|&s| s as f64 / 32768.0).collect(),
            Self::PcmI24In32 { samples, .. } => {
                samples.iter().map(|&s| s as f64 / 8_388_608.0).collect()
            }
            Self::PcmI32 { samples, .. } => samples
                .iter()
                .map(|&s| s as f64 / 2_147_483_648.0)
                .collect(),
            Self::PcmF32 { samples, .. } => samples.iter().map(|&s| s as f64).collect(),
            Self::PcmF64 { samples, .. } => samples.clone(),
            Self::DsdBitstream { .. } => Vec::new(),
        }
    }

    pub fn to_f32_interleaved(&self) -> Vec<f32> {
        match self {
            Self::PcmI16 { samples, .. } => samples.iter().map(|&s| s as f32 / 32768.0).collect(),
            Self::PcmI24In32 { samples, .. } => samples
                .iter()
                .map(|&s| (s as f64 / 8_388_608.0) as f32)
                .collect(),
            Self::PcmI32 { samples, .. } => samples
                .iter()
                .map(|&s| (s as f64 / 2_147_483_648.0) as f32)
                .collect(),
            Self::PcmF32 { samples, .. } => samples.clone(),
            Self::PcmF64 { samples, .. } => samples.iter().map(|&s| s as f32).collect(),
            Self::DsdBitstream { .. } => Vec::new(),
        }
    }

    /// Appends canonical little-endian logical sample bytes to `out` for exact verification.
    pub fn append_canonical_le_bytes(&self, out: &mut Vec<u8>) {
        match self {
            Self::PcmI16 { samples, .. } => {
                out.reserve(samples.len() * 2);
                for &s in samples {
                    out.extend_from_slice(&s.to_le_bytes());
                }
            }
            Self::PcmI24In32 { samples, .. } | Self::PcmI32 { samples, .. } => {
                out.reserve(samples.len() * 4);
                for &s in samples {
                    out.extend_from_slice(&s.to_le_bytes());
                }
            }
            Self::PcmF32 { samples, .. } => {
                out.reserve(samples.len() * 4);
                for &s in samples {
                    out.extend_from_slice(&s.to_bits().to_le_bytes());
                }
            }
            Self::PcmF64 { samples, .. } => {
                out.reserve(samples.len() * 8);
                for &s in samples {
                    out.extend_from_slice(&s.to_bits().to_le_bytes());
                }
            }
            Self::DsdBitstream { bytes, .. } => {
                out.extend_from_slice(bytes);
            }
        }
    }

    /// Feeds canonical little-endian logical sample bytes into SHA-256 for bit-exact verification.
    pub fn update_sha256(&self, hasher: &mut Sha256) {
        let mut buf = Vec::new();
        self.append_canonical_le_bytes(&mut buf);
        hasher.update(&buf);
    }
}

pub trait AudioDecoder: Send {
    fn format(&self) -> &AudioFormat;
    fn unified_format(&self) -> UnifiedAudioFormat {
        UnifiedAudioFormat::from_audio_format(self.format())
    }
    fn metadata(&self) -> Option<&DecodedTrackMetadata> {
        None
    }
    fn decoder_name(&self) -> &'static str {
        "Lumina AudioDecoder"
    }
    fn duration(&self) -> Option<Duration>;
    fn total_frames(&self) -> Option<u64>;
    fn next_chunk(&mut self) -> Result<Option<AudioChunk>, DecoderError>;
    fn seek(&mut self, time: Duration) -> Result<(), DecoderError>;
    /// Reclaims cached streaming/decoder buffers after extended idle pause. Returns bytes freed.
    fn reclaim_idle_memory(&mut self) -> usize {
        0
    }
}
