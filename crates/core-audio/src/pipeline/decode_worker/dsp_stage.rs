//! Wire decode-stage DSP, format-mismatch detection, and 64-bit float conversion.

use std::sync::atomic::Ordering;

use core_types::{AudioFormat, UnifiedAudioFormat};

use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::AudioChunk;
use crate::dsp::{DspPipeline, LookaheadLimiter, adapt_channels_f64_into};
use crate::engine::{
    PlayerInner, default_shared_dsp_config, to_internal_replay_gain, to_parametric_bands,
};
use crate::verification::{
    AudioVerificationEngine, VerificationConfig, WireFormatStamp, WirePacker, WireSampleFormat,
};

pub(crate) fn apply_live_dsp_for_deck(d: &mut DspPipeline, inner: &PlayerInner, deck_idx: usize) {
    let cfg = inner
        .dsp_config
        .read()
        .map(|g| g.clone())
        .unwrap_or_else(|_| default_shared_dsp_config());
    let rg_tags = inner.dual_deck.deck_meta[deck_idx & 1]
        .read()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.rg_tags.clone()))
        .unwrap_or_else(|| {
            inner
                .track_replay_gain
                .read()
                .map(|g| g.clone())
                .unwrap_or_default()
        });

    let bypassed = inner.dsp_bypassed.load(Ordering::Relaxed) || cfg.bypass;
    d.set_bypass(bypassed);
    let _ = d.set_peq_bands(to_parametric_bands(&cfg.peq_bands));
    d.set_crossfeed_enabled(cfg.crossfeed.enabled);
    d.set_replay_gain(to_internal_replay_gain(&cfg.replay_gain, &rg_tags));
    d.set_limiter_enabled(true);
}

pub(crate) fn check_wire_chunk_format_mismatch(
    chunk: &AudioChunk,
    curr_unified: &UnifiedAudioFormat,
    curr_neg: &NegotiatedFormat,
) -> Option<(u64, AudioFormat)> {
    let is_dsd_wire = matches!(
        curr_neg.wire_format,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    );
    let chunk_is_dsd = matches!(chunk, AudioChunk::DsdBitstream { .. });
    let expected_chunk_rate = if is_dsd_wire {
        curr_unified.sample_rate
    } else {
        curr_neg.target_sample_rate
    };
    let rate_mismatch = chunk.sample_rate() != expected_chunk_rate;
    let ch_mismatch = chunk.channels() != curr_neg.target_channels;
    let kind_mismatch = chunk_is_dsd != is_dsd_wire;
    let bits_mismatch = !chunk_is_dsd
        && curr_unified.codec.is_lossless()
        && chunk.valid_bits() > curr_unified.valid_bits
        && chunk.valid_bits() > curr_neg.valid_bits;

    if rate_mismatch || ch_mismatch || kind_mismatch || bits_mismatch {
        let new_wire = match chunk {
            AudioChunk::PcmI16 { .. } => WireSampleFormat::Int16Le,
            AudioChunk::PcmI24In32 { .. } => WireSampleFormat::Int24In32MsbLe,
            AudioChunk::PcmI32 { .. } => WireSampleFormat::Int32Le,
            AudioChunk::PcmF32 { .. } => WireSampleFormat::Float32Le,
            AudioChunk::PcmF64 { .. } => WireSampleFormat::Float64Le,
            AudioChunk::DsdBitstream { channels, .. } => WireSampleFormat::NativeDsd {
                channels: *channels,
            },
        };
        let new_stamp =
            WireFormatStamp::from_wire(chunk.sample_rate(), chunk.channels(), new_wire).0;
        let new_fmt = AudioFormat {
            codec: curr_unified.codec,
            sample_rate_hz: chunk.sample_rate(),
            bit_depth: if chunk_is_dsd { 1 } else { chunk.valid_bits() },
            channels: chunk.channels().min(u8::MAX as u16) as u8,
            is_dsd: chunk_is_dsd,
        };
        return Some((new_stamp, new_fmt));
    }
    None
}

/// Converts any [`AudioChunk`] into interleaved 64-bit float PCM inside caller-owned `out`,
/// reusing `out`'s existing heap allocation.
pub(super) fn fill_chunk_as_f64_into(chunk: &AudioChunk, out: &mut Vec<f64>) {
    out.clear();
    match chunk {
        AudioChunk::PcmI16 { samples, .. } => {
            out.reserve(samples.len());
            for &s in samples {
                out.push((s as f64) / 32768.0);
            }
        }
        AudioChunk::PcmI24In32 { samples, .. } => {
            out.reserve(samples.len());
            for &s in samples {
                out.push((s as f64) / 8_388_608.0);
            }
        }
        AudioChunk::PcmI32 { samples, .. } => {
            out.reserve(samples.len());
            for &s in samples {
                out.push((s as f64) / 2_147_483_648.0);
            }
        }
        AudioChunk::PcmF32 { samples, .. } => {
            out.reserve(samples.len());
            for &s in samples {
                out.push(s as f64);
            }
        }
        AudioChunk::PcmF64 { samples, .. } => {
            out.extend_from_slice(samples);
        }
        AudioChunk::DsdBitstream { .. } => {}
    }
}

pub(super) struct WireDspState {
    pub(super) packer: WirePacker,
    f64_scratch: Vec<f64>,
    ch_scratch: Vec<f64>,
    safe_f32_scratch: Vec<f32>,
    pub(super) dsp: Option<DspPipeline>,
    dsp_rate: u32,
    dsp_channels: usize,
    applied_gen: u64,
    ver_cfg: VerificationConfig,
    last_ver_dsp_active: bool,
}

impl WireDspState {
    pub(super) fn new(ver_cfg: VerificationConfig) -> Self {
        let last_ver_dsp_active = ver_cfg.dsp_active;
        Self {
            packer: WirePacker::new(),
            f64_scratch: Vec::with_capacity(8192),
            ch_scratch: Vec::with_capacity(8192),
            safe_f32_scratch: Vec::with_capacity(8192),
            dsp: None,
            dsp_rate: 0,
            dsp_channels: 0,
            applied_gen: 0,
            ver_cfg,
            last_ver_dsp_active,
        }
    }

    pub(super) fn reset_for_seek(&mut self) {
        self.packer.reset();
        if let Some(ref mut d) = self.dsp {
            d.reset();
        }
    }

    pub(super) fn pack_chunk(
        &mut self,
        chunk: &AudioChunk,
        curr_neg: &NegotiatedFormat,
        inner: &PlayerInner,
        verification: &AudioVerificationEngine,
        deck_idx: usize,
    ) -> &[u8] {
        let is_dsd_wire = matches!(
            curr_neg.wire_format,
            WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
        );
        // Lock-free atomic snapshot of Bit-Perfect & DSP bypass state (zero per-chunk RwLock).
        let strict_bp = inner.strict_bit_perfect.load(Ordering::Relaxed);
        let dsp_bypassed = inner.dsp_bypassed.load(Ordering::Relaxed);

        if !strict_bp && !dsp_bypassed && !is_dsd_wire {
            let rate = curr_neg.target_sample_rate.max(8_000);
            let ch = curr_neg.target_channels.max(1) as usize;
            let mut recreated = false;
            if self.dsp.is_none() || self.dsp_rate != rate || self.dsp_channels != ch {
                self.dsp = DspPipeline::new(rate as f64, ch).ok();
                self.dsp_rate = rate;
                self.dsp_channels = ch;
                recreated = true;
            }
            let current_gen = inner.dsp_generation.load(Ordering::Acquire);
            let mut active_now = false;
            if let Some(ref mut d) = self.dsp {
                if recreated || current_gen != self.applied_gen {
                    apply_live_dsp_for_deck(d, inner, deck_idx);
                    self.applied_gen = current_gen;
                }
                if d.is_dsp_active() {
                    active_now = true;
                    fill_chunk_as_f64_into(chunk, &mut self.f64_scratch);
                    if chunk.channels() != curr_neg.target_channels {
                        adapt_channels_f64_into(
                            &self.f64_scratch,
                            chunk.channels(),
                            curr_neg.target_channels,
                            &mut self.ch_scratch,
                        );
                        std::mem::swap(&mut self.f64_scratch, &mut self.ch_scratch);
                    }
                    d.process_interleaved(&mut self.f64_scratch);
                }
            }
            if active_now != self.last_ver_dsp_active {
                self.ver_cfg.dsp_active = active_now;
                verification.update_config(self.ver_cfg.clone());
                self.last_ver_dsp_active = active_now;
            }
            if active_now {
                let samples = std::mem::take(&mut self.f64_scratch);
                let processed_chunk = AudioChunk::PcmF64 {
                    samples,
                    channels: curr_neg.target_channels,
                    sample_rate: curr_neg.target_sample_rate,
                };
                verification.record_processed_output(&processed_chunk);
                let packed = self.packer.pack(&processed_chunk, curr_neg.wire_format);
                if let AudioChunk::PcmF64 { samples, .. } = processed_chunk {
                    self.f64_scratch = samples;
                }
                packed
            } else if let AudioChunk::PcmF32 {
                ref samples,
                channels,
                sample_rate,
            } = *chunk
            {
                // Lossy floating-point streams (AAC/Opus/MP3/Vorbis) can emit inter-sample
                // peaks slightly exceeding +/-1.0 or non-finite values; sanitize and softly
                // limit above 0.98 while keeping lossless integer/DSD chunks bit-exact.
                let needs_safety = samples.iter().any(|&s| !s.is_finite() || s.abs() > 0.98);
                if needs_safety {
                    self.safe_f32_scratch.clear();
                    self.safe_f32_scratch.reserve(samples.len());
                    for &s in samples {
                        let v = if s.is_finite() { s as f64 } else { 0.0 };
                        self.safe_f32_scratch
                            .push(LookaheadLimiter::soft_clip(v, 0.98).clamp(-1.0, 1.0) as f32);
                    }
                    let safe_vec = std::mem::take(&mut self.safe_f32_scratch);
                    let safe_chunk = AudioChunk::PcmF32 {
                        samples: safe_vec,
                        channels,
                        sample_rate,
                    };
                    verification.record_processed_output(&safe_chunk);
                    let packed = self.packer.pack(&safe_chunk, curr_neg.wire_format);
                    if let AudioChunk::PcmF32 { samples, .. } = safe_chunk {
                        self.safe_f32_scratch = samples;
                    }
                    packed
                } else {
                    verification.record_processed_output(chunk);
                    self.packer.pack(chunk, curr_neg.wire_format)
                }
            } else {
                verification.record_processed_output(chunk);
                self.packer.pack(chunk, curr_neg.wire_format)
            }
        } else {
            if self.last_ver_dsp_active {
                self.ver_cfg.dsp_active = false;
                verification.update_config(self.ver_cfg.clone());
                self.last_ver_dsp_active = false;
            }
            verification.record_processed_output(chunk);
            self.packer.pack(chunk, curr_neg.wire_format)
        }
    }
}
