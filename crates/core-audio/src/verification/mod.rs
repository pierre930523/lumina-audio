use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use core_types::{
    AudioDecoderInfo, AudioEngineOutputInfo, AudioOutputInfo, AudioSourceInfo,
    AudioVerificationInfo, DeviceTransportKind, OutputMode, UnifiedAudioFormat,
    VerificationStatus,
};
use sha2::{Digest, Sha256};

use crate::dsd::DopFramer;
use crate::pcm::AudioChunk;

/// Wire / hardware container format fed directly to the output backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireSampleFormat {
    Int16Le,
    Int24PackedLe,
    /// Sign-aligned 24-bit integer stored in top 24 bits of 32-bit container (`sample << 8`).
    Int24In32MsbLe,
    Int32Le,
    Float32Le,
    Float64Le,
    /// DoP v1.1 24-bit in 32-bit MSB-aligned frames (`[Marker, DSD0, DSD1, 0]`).
    Dop24In32MsbLe {
        channels: u16,
        is_lsb_first: bool,
    },
    /// Native raw 1-bit packed DSD bytes `[L0, R0, ...]`.
    NativeDsd {
        channels: u16,
    },
}

impl WireSampleFormat {
    pub const fn bytes_per_sample(self) -> usize {
        match self {
            Self::Int16Le => 2,
            Self::Int24PackedLe => 3,
            Self::Int24In32MsbLe
            | Self::Int32Le
            | Self::Float32Le
            | Self::Dop24In32MsbLe { .. } => 4,
            Self::Float64Le => 8,
            Self::NativeDsd { .. } => 1,
        }
    }

    pub const fn container_bits(self) -> u8 {
        match self {
            Self::Int16Le => 16,
            Self::Int24PackedLe => 24,
            Self::Int24In32MsbLe
            | Self::Int32Le
            | Self::Float32Le
            | Self::Dop24In32MsbLe { .. } => 32,
            Self::Float64Le => 64,
            Self::NativeDsd { .. } => 8,
        }
    }

    pub const fn valid_bits(self) -> u8 {
        match self {
            Self::Int16Le => 16,
            Self::Int24PackedLe | Self::Int24In32MsbLe | Self::Dop24In32MsbLe { .. } => 24,
            Self::Int32Le | Self::Float32Le => 32,
            Self::Float64Le => 64,
            Self::NativeDsd { .. } => 1,
        }
    }
}

/// Converts a logical [`AudioChunk`] verbatim into hardware wire bytes for the target [`WireSampleFormat`],
/// assuming matching sample rate, channels, and DSP/volume bypass when bit-perfect.
pub fn pack_chunk_to_wire_bytes(
    chunk: &AudioChunk,
    wire: WireSampleFormat,
    dop_framer: Option<&mut DopFramer>,
) -> Vec<u8> {
    match (chunk, wire) {
        (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int16Le) => {
            let mut out = Vec::with_capacity(samples.len() * 2);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
            out
        }
        // Bit-exact promotion of 16-bit integer into higher integer containers (left-aligned, zero-padded LSBs)
        (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int24In32MsbLe) => {
            let mut out = Vec::with_capacity(samples.len() * 4);
            for &s in samples {
                out.extend_from_slice(&((s as i32) << 16).to_le_bytes());
            }
            out
        }
        (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int32Le) => {
            let mut out = Vec::with_capacity(samples.len() * 4);
            for &s in samples {
                out.extend_from_slice(&((s as i32) << 16).to_le_bytes());
            }
            out
        }
        (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int24PackedLe) => {
            let mut out = Vec::with_capacity(samples.len() * 3);
            for &s in samples {
                let shifted = (s as i32) << 8;
                out.extend_from_slice(&shifted.to_le_bytes()[0..3]);
            }
            out
        }
        (AudioChunk::PcmI24In32 { samples, .. }, WireSampleFormat::Int24In32MsbLe)
        | (AudioChunk::PcmI24In32 { samples, .. }, WireSampleFormat::Int32Le) => {
            let mut out = Vec::with_capacity(samples.len() * 4);
            for &s in samples {
                // `s` is sign-extended 24-bit integer; place in top 24 bits (`s << 8`)
                out.extend_from_slice(&(s << 8).to_le_bytes());
            }
            out
        }
        (AudioChunk::PcmI24In32 { samples, .. }, WireSampleFormat::Int24PackedLe) => {
            let mut out = Vec::with_capacity(samples.len() * 3);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes()[0..3]);
            }
            out
        }
        (AudioChunk::PcmI32 { samples, .. }, WireSampleFormat::Int32Le) => {
            let mut out = Vec::with_capacity(samples.len() * 4);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
            out
        }
        (AudioChunk::PcmF32 { samples, .. }, WireSampleFormat::Float32Le) => {
            let mut out = Vec::with_capacity(samples.len() * 4);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
            out
        }
        (AudioChunk::PcmF64 { samples, .. }, WireSampleFormat::Float64Le) => {
            let mut out = Vec::with_capacity(samples.len() * 8);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
            out
        }
        (
            AudioChunk::DsdBitstream {
                bytes,
                channels,
                is_lsb_first,
                ..
            },
            WireSampleFormat::Dop24In32MsbLe { .. },
        ) => {
            let ch = (*channels as usize).max(1);
            let framer = match dop_framer {
                Some(f) => f,
                None => return Vec::new(),
            };
            if ch == 2 {
                // Byte-interleaved [L0, R0, L1, R1, ...], frame 2 bytes per channel -> 1 PCM stereo frame
                let groups = bytes.len() / 4;
                let mut out = Vec::with_capacity(groups * 8);
                for g in 0..groups {
                    let base = g * 4;
                    let (l_pcm, r_pcm) = framer.frame_stereo_i32(
                        (bytes[base], bytes[base + 2]),
                        (bytes[base + 1], bytes[base + 3]),
                        *is_lsb_first,
                    );
                    out.extend_from_slice(&l_pcm.to_le_bytes());
                    out.extend_from_slice(&r_pcm.to_le_bytes());
                }
                out
            } else {
                // Multi-channel or mono DoP encapsulation
                let groups = bytes.len() / (ch * 2);
                let mut out = Vec::with_capacity(groups * ch * 4);
                for g in 0..groups {
                    let marker = framer.next_marker() as i32;
                    for c in 0..ch {
                        let mut b0 = bytes[g * ch * 2 + c];
                        let mut b1 = bytes[g * ch * 2 + ch + c];
                        if *is_lsb_first {
                            b0 = b0.reverse_bits();
                            b1 = b1.reverse_bits();
                        }
                        let sample = (marker << 24) | ((b0 as i32) << 16) | ((b1 as i32) << 8);
                        out.extend_from_slice(&sample.to_le_bytes());
                    }
                }
                out
            }
        }
        (AudioChunk::DsdBitstream { bytes, .. }, WireSampleFormat::NativeDsd { .. }) => {
            bytes.clone()
        }
        // Fallback through normalized float when DSP or sample format conversion is active
        (chunk, WireSampleFormat::Float32Le) => {
            let floats = chunk.to_f32_interleaved();
            let mut out = Vec::with_capacity(floats.len() * 4);
            for s in floats {
                out.extend_from_slice(&s.to_le_bytes());
            }
            out
        }
        (chunk, WireSampleFormat::Float64Le) => {
            let floats = chunk.to_f64_interleaved();
            let mut out = Vec::with_capacity(floats.len() * 8);
            for s in floats {
                out.extend_from_slice(&s.to_le_bytes());
            }
            out
        }
        (chunk, WireSampleFormat::Int16Le) => {
            let floats = chunk.to_f64_interleaved();
            let mut out = Vec::with_capacity(floats.len() * 2);
            for s in floats {
                let q = (s.clamp(-1.0, 0.999969482421875) * 32768.0).round() as i16;
                out.extend_from_slice(&q.to_le_bytes());
            }
            out
        }
        (chunk, WireSampleFormat::Int24PackedLe) => {
            let floats = chunk.to_f64_interleaved();
            let mut out = Vec::with_capacity(floats.len() * 3);
            for s in floats {
                let q = (s.clamp(-1.0, 0.99999988) * 8_388_608.0).round() as i32;
                out.extend_from_slice(&q.clamp(-8_388_608, 8_388_607).to_le_bytes()[0..3]);
            }
            out
        }
        (chunk, WireSampleFormat::Int24In32MsbLe) | (chunk, WireSampleFormat::Int32Le) => {
            let floats = chunk.to_f64_interleaved();
            let mut out = Vec::with_capacity(floats.len() * 4);
            for s in floats {
                let q = (s.clamp(-1.0, 0.9999999995) * 2_147_483_648.0).round() as i64;
                let clamped = q.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                out.extend_from_slice(&clamped.to_le_bytes());
            }
            out
        }
        _ => Vec::new(),
    }
}

/// Decodes hardware backend wire bytes back into canonical logical sample values
/// (`Int16` as `i16`, `Int24` as sign-extended `i32`, etc.) for exact sample-level comparison
/// against the decoder output.
pub fn unpack_wire_bytes_to_chunk(
    raw: &[u8],
    wire: WireSampleFormat,
    channels: u16,
    sample_rate: u32,
    dop_unframer: Option<&mut DopFramer>,
) -> Result<AudioChunk, String> {
    match wire {
        WireSampleFormat::Int16Le => {
            let samples = raw
                .chunks_exact(2)
                .map(|c| i16::from_le_bytes([c[0], c[1]]))
                .collect();
            Ok(AudioChunk::PcmI16 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Int24PackedLe => {
            let samples = raw
                .chunks_exact(3)
                .map(|c| {
                    let sign_byte = if c[2] & 0x80 != 0 { 0xFF } else { 0x00 };
                    i32::from_le_bytes([c[0], c[1], c[2], sign_byte])
                })
                .collect();
            Ok(AudioChunk::PcmI24In32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Int24In32MsbLe => {
            let samples = raw
                .chunks_exact(4)
                .map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]]) >> 8)
                .collect();
            Ok(AudioChunk::PcmI24In32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Int32Le => {
            let samples = raw
                .chunks_exact(4)
                .map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect();
            Ok(AudioChunk::PcmI32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Float32Le => {
            let samples = raw
                .chunks_exact(4)
                .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect();
            Ok(AudioChunk::PcmF32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Float64Le => {
            let samples = raw
                .chunks_exact(8)
                .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
                .collect();
            Ok(AudioChunk::PcmF64 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Dop24In32MsbLe {
            channels: ch,
            is_lsb_first,
        } => {
            let unframer = dop_unframer.ok_or_else(|| "Missing DoP unframer".to_string())?;
            let ch_usize = ch.max(1) as usize;
            let frame_bytes = ch_usize * 4;
            let mut out = Vec::with_capacity((raw.len() / 4) * 2);
            for frame in raw.chunks_exact(frame_bytes) {
                let expected = unframer.next_marker();
                let mut frame_dsd = vec![[0u8; 2]; ch_usize];
                for c in 0..ch_usize {
                    let word = i32::from_le_bytes(frame[c * 4..(c + 1) * 4].try_into().unwrap());
                    let marker = ((word >> 24) & 0xFF) as u8;
                    if marker != expected {
                        return Err(format!(
                            "DoP marker corruption: expected 0x{expected:02X}, got 0x{marker:02X}"
                        ));
                    }
                    let mut b0 = ((word >> 16) & 0xFF) as u8;
                    let mut b1 = ((word >> 8) & 0xFF) as u8;
                    if is_lsb_first {
                        b0 = b0.reverse_bits();
                        b1 = b1.reverse_bits();
                    }
                    frame_dsd[c] = [b0, b1];
                }
                for pair in &frame_dsd {
                    out.push(pair[0]);
                }
                for pair in &frame_dsd {
                    out.push(pair[1]);
                }
            }
            Ok(AudioChunk::DsdBitstream {
                bytes: out,
                channels: ch,
                sample_rate,
                is_lsb_first,
            })
        }
        WireSampleFormat::NativeDsd { channels: ch } => Ok(AudioChunk::DsdBitstream {
            bytes: raw.to_vec(),
            channels: ch,
            sample_rate,
            is_lsb_first: true,
        }),
    }
}

fn hex_digest(h: &Sha256) -> String {
    let bytes = h.clone().finalize();
    let mut s = String::with_capacity(16);
    for b in &bytes[..8] {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

#[derive(Debug, Clone)]
pub struct VerificationConfig {
    pub source_format: UnifiedAudioFormat,
    pub output_mode: OutputMode,
    pub transport: DeviceTransportKind,
    pub target_rate_hz: u32,
    pub target_channels: u16,
    pub target_valid_bits: u8,
    pub target_container_bits: u8,
    pub buffer_size_frames: u32,
    pub dsp_active: bool,
    pub software_volume_unity: bool,
    pub resampled: bool,
    pub exclusive_unavailable_reason: Option<String>,
}

struct VerificationInner {
    decoder_sha: Sha256,
    processing_sha: Sha256,
    backend_sha: Sha256,
    pending_decoder_bytes: VecDeque<u8>,
    pending_processing_bytes: VecDeque<u8>,
    dop_unframer: DopFramer,
    frames_verified: u64,
    mismatched_samples: u64,
    first_mismatch_detail: Option<String>,
    config: VerificationConfig,
    source_title: Option<String>,
    source_artist: Option<String>,
    source_album: Option<String>,
}

/// Real-time verification engine measuring equality & SHA-256 digests between:
/// 1) Decoder Output -> 2) Pre-Backend Processing Output -> 3) Output Backend Input.
/// Explicitly distinguishes software pipeline verification from hardware DAC pin-out.
#[derive(Clone)]
pub struct AudioVerificationEngine {
    inner: Arc<Mutex<VerificationInner>>,
}

impl AudioVerificationEngine {
    pub fn new(config: VerificationConfig) -> Self {
        Self {
            inner: Arc::new(Mutex::new(VerificationInner {
                decoder_sha: Sha256::new(),
                processing_sha: Sha256::new(),
                backend_sha: Sha256::new(),
                pending_decoder_bytes: VecDeque::with_capacity(65536),
                pending_processing_bytes: VecDeque::with_capacity(65536),
                dop_unframer: DopFramer::new(),
                frames_verified: 0,
                mismatched_samples: 0,
                first_mismatch_detail: None,
                config,
                source_title: None,
                source_artist: None,
                source_album: None,
            })),
        }
    }

    pub fn update_config(&self, config: VerificationConfig) {
        if let Ok(mut g) = self.inner.lock() {
            g.config = config;
        }
    }

    pub fn set_buffer_size_frames(&self, frames: u32) {
        if let Ok(mut g) = self.inner.lock() {
            g.config.buffer_size_frames = frames;
        }
    }

    pub fn set_source_metadata(
        &self,
        title: Option<String>,
        artist: Option<String>,
        album: Option<String>,
    ) {
        if let Ok(mut g) = self.inner.lock() {
            g.source_title = title;
            g.source_artist = artist;
            g.source_album = album;
        }
    }

    pub fn reset_streams(&self) {
        if let Ok(mut g) = self.inner.lock() {
            g.decoder_sha = Sha256::new();
            g.processing_sha = Sha256::new();
            g.backend_sha = Sha256::new();
            g.pending_decoder_bytes.clear();
            g.pending_processing_bytes.clear();
            g.dop_unframer.reset();
            g.frames_verified = 0;
            g.mismatched_samples = 0;
            g.first_mismatch_detail = None;
        }
    }

    /// Stage 1 hook: called immediately after `AudioDecoder::next_chunk()`.
    pub fn record_decoder_output(&self, chunk: &AudioChunk) {
        if chunk.is_empty() {
            return;
        }
        if let Ok(mut g) = self.inner.lock() {
            let mut raw = Vec::new();
            chunk.append_canonical_le_bytes(&mut raw);
            // Bound queue to ~4 MiB if a stalled test only drives Stage 1
            if g.pending_decoder_bytes.len() + raw.len() <= 4 * 1024 * 1024 {
                g.pending_decoder_bytes.extend(raw);
            } else {
                chunk.update_sha256(&mut g.decoder_sha);
            }
        }
    }

    /// Stage 2 hook: called after DSP / software volume / container adaptation (before ring buffer push).
    pub fn record_processed_output(&self, chunk: &AudioChunk) {
        if chunk.is_empty() {
            return;
        }
        if let Ok(mut g) = self.inner.lock() {
            let mut raw = Vec::new();
            chunk.append_canonical_le_bytes(&mut raw);
            if g.pending_processing_bytes.len() + raw.len() <= 4 * 1024 * 1024 {
                g.pending_processing_bytes.extend(raw);
            } else {
                chunk.update_sha256(&mut g.processing_sha);
            }
        }
    }

    /// Stage 3 hook: called directly inside/before `AudioOutputBackend::write_*` on actual hardware wire bytes.
    pub fn record_backend_input_wire(
        &self,
        raw_bytes: &[u8],
        wire: WireSampleFormat,
        channels: u16,
        sample_rate: u32,
    ) {
        if raw_bytes.is_empty() {
            return;
        }
        if let Ok(mut g) = self.inner.lock() {
            let mut unpacked = match wire {
                WireSampleFormat::Dop24In32MsbLe { .. } => {
                    let mut tmp = g.dop_unframer.clone();
                    let res =
                        unpack_wire_bytes_to_chunk(raw_bytes, wire, channels, sample_rate, Some(&mut tmp));
                    g.dop_unframer = tmp;
                    res
                }
                _ => unpack_wire_bytes_to_chunk(raw_bytes, wire, channels, sample_rate, None),
            };

            match &mut unpacked {
                Ok(chunk) => {
                    // Normalize 16-bit/24-bit promoted into larger containers back to logical source
                    // values so SHA-256 compares logical sample integers accurately.
                    let src_bits = g.config.source_format.valid_bits;
                    let norm_chunk = match (src_bits, chunk) {
                        (16, AudioChunk::PcmI24In32 { samples, channels, sample_rate }) => {
                            AudioChunk::PcmI16 {
                                samples: samples.iter().map(|&s| (s >> 8) as i16).collect(),
                                channels: *channels,
                                sample_rate: *sample_rate,
                            }
                        }
                        (16, AudioChunk::PcmI32 { samples, channels, sample_rate }) => {
                            AudioChunk::PcmI16 {
                                samples: samples.iter().map(|&s| (s >> 16) as i16).collect(),
                                channels: *channels,
                                sample_rate: *sample_rate,
                            }
                        }
                        (24, AudioChunk::PcmI32 { samples, channels, sample_rate }) => {
                            AudioChunk::PcmI24In32 {
                                samples: samples.iter().map(|&s| s >> 8).collect(),
                                channels: *channels,
                                sample_rate: *sample_rate,
                            }
                        }
                        (_, c) => c.clone(),
                    };

                    let mut back_bytes = Vec::new();
                    norm_chunk.append_canonical_le_bytes(&mut back_bytes);
                    g.backend_sha.update(&back_bytes);
                    g.frames_verified += norm_chunk.frames() as u64;

                    let n = back_bytes.len();
                    if g.pending_processing_bytes.len() >= n {
                        let proc_slice: Vec<u8> = g.pending_processing_bytes.drain(..n).collect();
                        g.processing_sha.update(&proc_slice);
                    } else if !g.pending_processing_bytes.is_empty() {
                        let proc_slice: Vec<u8> = g.pending_processing_bytes.drain(..).collect();
                        g.processing_sha.update(&proc_slice);
                    }

                    if g.pending_decoder_bytes.len() >= n {
                        let dec_slice: Vec<u8> = g.pending_decoder_bytes.drain(..n).collect();
                        g.decoder_sha.update(&dec_slice);
                        if dec_slice != back_bytes {
                            g.mismatched_samples += 1;
                            if g.first_mismatch_detail.is_none() {
                                g.first_mismatch_detail = Some(format!(
                                    "Sample bytes differ over {n}-byte block at verified frame {}",
                                    g.frames_verified
                                ));
                            }
                        }
                    } else if !g.pending_decoder_bytes.is_empty() {
                        // Resampled / altered sample rate means byte lengths don't track 1:1
                        let dec_slice: Vec<u8> = g.pending_decoder_bytes.drain(..).collect();
                        g.decoder_sha.update(&dec_slice);
                    }
                }
                Err(err) => {
                    g.mismatched_samples += 1;
                    if g.first_mismatch_detail.is_none() {
                        g.first_mismatch_detail = Some(err.clone());
                    }
                }
            }
        }
    }

    /// Evaluates Phase 9 + Phase 10 verification verdict. Never claims `BIT-PERFECT` without
    /// verified hash equality, exact format match, disabled DSP/SW volume, and non-shared output.
    pub fn snapshot(&self, audio_api: &str, device_name: &str) -> AudioEngineOutputInfo {
        let g = self.inner.lock().unwrap();
        let cfg = &g.config;

        let dec_hex = hex_digest(&g.decoder_sha);
        let proc_hex = hex_digest(&g.processing_sha);
        let back_hex = hex_digest(&g.backend_sha);

        let hashes_match =
            g.frames_verified > 0 && g.mismatched_samples == 0 && dec_hex == proc_hex && proc_hex == back_hex;

        let src_is_dsd = cfg.source_format.dsd_rate.is_some();
        let format_match = if src_is_dsd {
            matches!(
                cfg.output_mode,
                OutputMode::AsioNativeDsd | OutputMode::DoPOverWasapiExclusive | OutputMode::DoPOverAsio
            ) && cfg.target_channels == cfg.source_format.channels
        } else {
            cfg.target_rate_hz == cfg.source_format.sample_rate
                && cfg.target_channels == cfg.source_format.channels
                && cfg.target_valid_bits >= cfg.source_format.valid_bits
                && !cfg.resampled
        };

        let status = if src_is_dsd && cfg.output_mode == OutputMode::DsdToPcm {
            VerificationStatus::DsdToPcm
        } else if cfg.exclusive_unavailable_reason.is_some()
            && !cfg.output_mode.is_exclusive_or_asio()
        {
            VerificationStatus::ExclusiveModeUnavailable
        } else if src_is_dsd {
            match cfg.output_mode {
                OutputMode::AsioNativeDsd if g.frames_verified > 0 && hashes_match => {
                    VerificationStatus::DsdNative
                }
                OutputMode::DoPOverWasapiExclusive | OutputMode::DoPOverAsio
                    if g.frames_verified > 0
                        && hashes_match
                        && !cfg.dsp_active
                        && cfg.software_volume_unity
                        && !cfg.resampled =>
                {
                    VerificationStatus::DsdDop
                }
                OutputMode::DsdToPcm | OutputMode::WasapiShared => VerificationStatus::DsdToPcm,
                _ => VerificationStatus::NotVerified,
            }
        } else if g.frames_verified == 0 {
            VerificationStatus::NotVerified
        } else if cfg.output_mode == OutputMode::WasapiShared
            || cfg.dsp_active
            || !cfg.software_volume_unity
            || cfg.resampled
            || !hashes_match
            || !format_match
        {
            VerificationStatus::NotBitPerfect
        } else if matches!(
            cfg.output_mode,
            OutputMode::WasapiExclusive | OutputMode::AsioPcm
        ) {
            VerificationStatus::BitPerfect
        } else {
            VerificationStatus::PcmUnmodified
        };

        let pcm_check = if g.frames_verified == 0 && g.mismatched_samples == 0 {
            "Pending Audio Frames".to_string()
        } else if hashes_match {
            format!("PASS (SHA-256 Match · {} frames)", g.frames_verified)
        } else if let Some(ref detail) = g.first_mismatch_detail {
            format!("MODIFIED ({detail})")
        } else {
            format!(
                "MODIFIED (Dec:{} != Out:{})",
                &dec_hex[..8.min(dec_hex.len())],
                &back_hex[..8.min(back_hex.len())]
            )
        };

        let output_path = format!(
            "{} -> {} -> {} ({})",
            cfg.source_format.codec,
            if cfg.dsp_active { "64-bit DSP" } else { "Bypass" },
            cfg.output_mode.as_str(),
            device_name
        );

        AudioEngineOutputInfo {
            source: AudioSourceInfo {
                codec: cfg.source_format.codec.to_string(),
                sample_rate_hz: cfg.source_format.sample_rate,
                bit_depth: cfg.source_format.valid_bits,
                channels: cfg.source_format.channels,
                channel_layout: cfg.source_format.channel_layout.label(),
                source_format: cfg.source_format.display_summary(),
                title: g.source_title.clone(),
                artist: g.source_artist.clone(),
                album: g.source_album.clone(),
            },
            decoder: AudioDecoderInfo {
                decoder_type: if src_is_dsd {
                    "Raw 1-bit DSD Demuxer".to_string()
                } else {
                    "Symphonia Lossless Integer/Float Decoder".to_string()
                },
                decoded_pcm_format: cfg.source_format.sample_format.as_str().to_string(),
                sample_rate_hz: cfg.source_format.sample_rate,
                container_bits: cfg.source_format.container_bits,
                valid_bits: cfg.source_format.valid_bits,
                integer_preserved: cfg.source_format.sample_format.is_integer(),
            },
            output: AudioOutputInfo {
                selected_device: device_name.to_string(),
                transport_kind: cfg.transport.label_zh().to_string(),
                audio_api: audio_api.to_string(),
                output_mode: cfg.output_mode.as_str().to_string(),
                sample_rate_hz: cfg.target_rate_hz,
                container_bits: cfg.target_container_bits,
                valid_bits: cfg.target_valid_bits,
                channels: cfg.target_channels,
                buffer_size_frames: cfg.buffer_size_frames,
                dsp_status: if cfg.dsp_active { "Enabled" } else { "Bypassed" }.to_string(),
                software_volume_status: if cfg.software_volume_unity {
                    "Disabled (Unity 1.0x)"
                } else {
                    "Active Attenuated"
                }
                .to_string(),
                strict_mode: cfg.output_mode.is_exclusive_or_asio()
                    && !cfg.dsp_active
                    && cfg.software_volume_unity,
                hardware_volume_recommended: cfg.software_volume_unity
                    && cfg.output_mode.is_exclusive_or_asio(),
                degradation_reason: cfg.exclusive_unavailable_reason.clone(),
            },
            verification: AudioVerificationInfo {
                pcm_sample_check: pcm_check,
                sample_hash_match: hashes_match,
                decoder_sha256: dec_hex,
                processing_sha256: proc_hex,
                backend_input_sha256: back_hex,
                format_match,
                output_path,
                verification_level:
                    "Software Pipeline Verified (Decoder → Output Backend Input); Hardware DAC pin output unobservable via OS API"
                        .to_string(),
                status,
                frames_verified: g.frames_verified,
                mismatched_frames: g.mismatched_samples,
            },
        }
    }
}
