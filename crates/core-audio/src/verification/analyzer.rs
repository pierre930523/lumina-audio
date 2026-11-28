use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use core_types::{
    AudioDecoderInfo, AudioEngineOutputInfo, AudioOutputInfo, AudioSourceInfo,
    AudioVerificationInfo, DeviceTransportKind, OutputMode, UnifiedAudioFormat, VerificationStatus,
};
use sha2::{Digest, Sha256};

use super::tap::{
    RtWireTapConsumer, VerificationInner, VerificationTapProducer, drain_rt_tap_locked,
    ingest_backend_wire_locked,
};
use super::wire_format::WireSampleFormat;
use crate::buffer::SpscRingBuffer;
use crate::dsd::DopFramer;
use crate::pcm::AudioChunk;

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

/// Real-time verification engine measuring equality & SHA-256 digests between:
/// 1) Decoder Output -> 2) Pre-Backend Processing Output -> 3) Output Backend Input.
///
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
                rt_tap: None,
            })),
        }
    }

    /// Attaches a lock-free SPSC Stage-3 wire tap for real-time audio callbacks.
    /// Must be called on a non-RT setup thread before starting the audio callback.
    pub fn attach_rt_tap(
        &self,
        wire: WireSampleFormat,
        channels: u16,
        sample_rate: u32,
        capacity_bytes: usize,
    ) -> VerificationTapProducer {
        let ch = channels.max(1);
        let bpf = wire.bytes_per_sample().max(1) * (ch as usize);
        let cap = capacity_bytes.clamp(65_536, 4 * 1024 * 1024);
        let (producer, consumer) = SpscRingBuffer::<u8>::new(cap);
        let control = producer.control();
        let scratch_len = (16_384 / bpf).max(1) * bpf;
        if let Ok(mut g) = self.inner.lock() {
            g.rt_tap = Some(RtWireTapConsumer {
                consumer,
                control,
                wire,
                channels: ch,
                sample_rate,
                bytes_per_frame: bpf,
                drain_scratch: vec![0u8; scratch_len],
            });
        }
        VerificationTapProducer {
            producer,
            bytes_per_frame: bpf,
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
            if let Some(ref mut tap) = g.rt_tap {
                tap.control.request_flush();
                let _ = tap.consumer.flush_and_ack();
            }
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

    /// Stage 1 hook: called immediately after `AudioDecoder::next_chunk()` (non-RT decode thread).
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
            drain_rt_tap_locked(&mut g);
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
            drain_rt_tap_locked(&mut g);
        }
    }

    /// Stage 3 direct hook for non-RT unit tests / offline verification pipelines.
    /// Real-time audio callbacks MUST use [`Self::attach_rt_tap`] -> [`VerificationTapProducer::push_wire`].
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
            ingest_backend_wire_locked(&mut g, raw_bytes, wire, channels, sample_rate);
        }
    }

    /// Evaluates Phase 9 + Phase 10 verification verdict. Never claims `BIT-PERFECT` without
    /// verified hash equality, exact format match, disabled DSP/SW volume, and non-shared output.
    pub fn snapshot(&self, audio_api: &str, device_name: &str) -> AudioEngineOutputInfo {
        let mut g = self.inner.lock().unwrap();
        drain_rt_tap_locked(&mut g);
        let cfg = &g.config;

        let dec_hex = hex_digest(&g.decoder_sha);
        let proc_hex = hex_digest(&g.processing_sha);
        let back_hex = hex_digest(&g.backend_sha);

        let hashes_match = g.frames_verified > 0
            && g.mismatched_samples == 0
            && dec_hex == proc_hex
            && proc_hex == back_hex;

        let src_is_dsd = cfg.source_format.dsd_rate.is_some();
        let format_match = if src_is_dsd {
            matches!(
                cfg.output_mode,
                OutputMode::AsioNativeDsd
                    | OutputMode::DoPOverWasapiExclusive
                    | OutputMode::DoPOverAsio
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
            || cfg.source_format.codec.is_lossy()
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
            if cfg.dsp_active {
                "64-bit DSP"
            } else {
                "Bypass"
            },
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
