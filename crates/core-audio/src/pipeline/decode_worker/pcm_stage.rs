//! Float-PCM decode-stage DSP, resampling, soft clipping, and SPSC ring pushing.

use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use tokio_util::sync::CancellationToken;

use crate::decoder::dsd::DsdStereoDecimator;
use crate::decoder::pcm::AudioChunk;
use crate::dsp::{DspPipeline, LookaheadLimiter, StreamingSincResampler, adapt_channels_f64_into};
use crate::engine::PlayerInner;
use crate::engine::session::StandbyDeckGate;
use crate::pipeline::ring_buffer::Producer;
use crate::verification::AudioVerificationEngine;

use super::dsp_stage::{apply_live_dsp_for_deck, fill_chunk_as_f64_into};

pub(super) struct PcmDspState {
    pub(super) dsd_decimator: DsdStereoDecimator,
    f64_scratch: Vec<f64>,
    ch_scratch: Vec<f64>,
    pub(super) resampled_scratch: Vec<f64>,
    pub(super) f32_scratch: Vec<f32>,
    pub(super) dsp: Option<DspPipeline>,
    dsp_rate: u32,
    dsp_channels: usize,
    pub(super) resampler: StreamingSincResampler,
    applied_gen: u64,
}

impl PcmDspState {
    pub(super) fn new(
        initial_pcm_rate: u32,
        out_rate: u32,
        out_channels: u16,
        inner: &PlayerInner,
        deck_idx: usize,
    ) -> Self {
        let dsp_channels = out_channels.max(1) as usize;
        let dsp_rate = initial_pcm_rate.max(8_000);
        let mut dsp = DspPipeline::new(dsp_rate as f64, dsp_channels).ok();
        let resampler = StreamingSincResampler::new(dsp_rate, out_rate.max(8_000), dsp_channels);
        let applied_gen = inner.dsp_generation.load(Ordering::Acquire);
        if let Some(ref mut d) = dsp {
            apply_live_dsp_for_deck(d, inner, deck_idx);
        }
        Self {
            dsd_decimator: DsdStereoDecimator::new(),
            f64_scratch: Vec::with_capacity(8192),
            ch_scratch: Vec::with_capacity(8192),
            resampled_scratch: Vec::with_capacity(8192),
            f32_scratch: Vec::with_capacity(8192),
            dsp,
            dsp_rate,
            dsp_channels,
            resampler,
            applied_gen,
        }
    }

    pub(super) fn reset_for_seek(&mut self) {
        self.dsd_decimator.reset();
        self.resampler.reset();
        if let Some(ref mut d) = self.dsp {
            d.reset();
        }
    }

    pub(super) fn process_chunk(
        &mut self,
        chunk: &AudioChunk,
        out_rate: u32,
        out_channels: u16,
        inner: &PlayerInner,
        verification: Option<&AudioVerificationEngine>,
        deck_idx: usize,
    ) {
        let (chunk_channels, chunk_pcm_rate) = match chunk {
            AudioChunk::PcmI16 {
                channels,
                sample_rate,
                ..
            }
            | AudioChunk::PcmI24In32 {
                channels,
                sample_rate,
                ..
            }
            | AudioChunk::PcmI32 {
                channels,
                sample_rate,
                ..
            }
            | AudioChunk::PcmF64 {
                channels,
                sample_rate,
                ..
            }
            | AudioChunk::PcmF32 {
                channels,
                sample_rate,
                ..
            } => {
                fill_chunk_as_f64_into(chunk, &mut self.f64_scratch);
                ((*channels).max(1), (*sample_rate).max(8_000))
            }
            AudioChunk::DsdBitstream {
                bytes,
                channels,
                sample_rate,
                is_lsb_first,
            } => {
                self.f64_scratch.clear();
                if *channels <= 1 {
                    self.f64_scratch.reserve(bytes.len() * 2);
                    for &b in bytes {
                        let v = self.dsd_decimator.left.translate_byte(b, *is_lsb_first);
                        self.f64_scratch.push(v);
                        self.f64_scratch.push(v);
                    }
                } else {
                    let pairs = bytes.len() / 2;
                    self.f64_scratch.reserve(pairs * 2);
                    for i in 0..pairs {
                        let (l, r) = self.dsd_decimator.translate_stereo_bytes(
                            bytes[i * 2],
                            bytes[i * 2 + 1],
                            *is_lsb_first,
                        );
                        self.f64_scratch.push(l);
                        self.f64_scratch.push(r);
                    }
                }
                (2, (*sample_rate / 8).max(44_100))
            }
        };

        adapt_channels_f64_into(
            &self.f64_scratch,
            chunk_channels,
            out_channels,
            &mut self.ch_scratch,
        );

        let mut recreated_dsp = false;
        if self.dsp.is_none()
            || self.dsp_rate != chunk_pcm_rate
            || self.dsp_channels != out_channels as usize
        {
            self.dsp_rate = chunk_pcm_rate;
            self.dsp_channels = out_channels as usize;
            self.dsp = DspPipeline::new(self.dsp_rate as f64, self.dsp_channels).ok();
            recreated_dsp = true;
        }

        let dsp_bypassed = inner.dsp_bypassed.load(Ordering::Relaxed);
        let current_gen = inner.dsp_generation.load(Ordering::Acquire);
        if let Some(ref mut d) = self.dsp {
            if recreated_dsp || current_gen != self.applied_gen {
                apply_live_dsp_for_deck(d, inner, deck_idx);
                self.applied_gen = current_gen;
            }
            d.set_bypass(dsp_bypassed);
            d.process_interleaved(&mut self.ch_scratch);
        }

        self.resampler
            .ensure_config(chunk_pcm_rate, out_rate.max(8_000), out_channels as usize);
        let final_f64: &[f64] = if self.resampler.is_passthrough() {
            &self.ch_scratch
        } else {
            self.resampler
                .process_into(&self.ch_scratch, &mut self.resampled_scratch);
            &self.resampled_scratch
        };

        write_f64_slice_to_f32(
            final_f64,
            dsp_bypassed,
            out_rate,
            out_channels,
            verification,
            &mut self.f32_scratch,
        );
    }

    pub(super) fn flush_resampler_tail(
        &mut self,
        out_rate: u32,
        out_channels: u16,
        inner: &PlayerInner,
        verification: Option<&AudioVerificationEngine>,
    ) -> bool {
        self.resampler.flush_into(&mut self.resampled_scratch);
        if self.resampled_scratch.is_empty() {
            return false;
        }
        let dsp_bypassed = inner.dsp_bypassed.load(Ordering::Relaxed);
        write_f64_slice_to_f32(
            &self.resampled_scratch,
            dsp_bypassed,
            out_rate,
            out_channels,
            verification,
            &mut self.f32_scratch,
        );
        true
    }
}

fn write_f64_slice_to_f32(
    src: &[f64],
    dsp_bypassed: bool,
    out_rate: u32,
    out_channels: u16,
    verification: Option<&AudioVerificationEngine>,
    out_f32: &mut Vec<f32>,
) {
    out_f32.clear();
    out_f32.reserve(src.len());
    if dsp_bypassed {
        // BP-1: when DSP is bypassed, never apply soft-clip compression to peaks > 0.98.
        for &s in src {
            let finite = if s.is_finite() { s } else { 0.0 };
            out_f32.push(finite.clamp(-1.0, 1.0) as f32);
        }
    } else {
        for &s in src {
            let finite = if s.is_finite() { s } else { 0.0 };
            out_f32.push(LookaheadLimiter::soft_clip(finite, 0.98).clamp(-1.0, 1.0) as f32);
        }
    }
    if let Some(v) = verification {
        v.record_processed_output(&AudioChunk::PcmF32 {
            samples: out_f32.clone(),
            channels: out_channels,
            sample_rate: out_rate,
        });
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn push_slice_to_ring<T: Copy>(
    data: &[T],
    align: usize,
    clock_rate: u64,
    producer: &mut Producer<T>,
    inner: &PlayerInner,
    cancel_flag: &AtomicBool,
    cancel_token: &CancellationToken,
    deck_idx: usize,
    deck_gen: u64,
    standby_gate: &Option<StandbyDeckGate>,
    check_format_mismatch: bool,
) -> bool {
    let mut offset = 0;
    while offset < data.len()
        && !cancel_flag.load(Ordering::Relaxed)
        && !cancel_token.is_cancelled()
        && inner.dual_deck.deck_gen_for(deck_idx) == deck_gen
        && !inner.stopped.load(Ordering::Relaxed)
        && !inner.device_lost.load(Ordering::Acquire)
        && (!check_format_mismatch
            || standby_gate.is_some()
            || !inner.format_mismatch_flag.load(Ordering::Acquire))
    {
        if standby_gate.is_none() {
            if inner.dual_deck.active_idx() != deck_idx {
                return false;
            }
            if inner.seek_request_ms.load(Ordering::Relaxed) >= 0 {
                break;
            }
        }
        let pushed = producer.push_slice_aligned(&data[offset..], align);
        offset += pushed;
        if pushed > 0 {
            let buffered = producer
                .capacity()
                .saturating_sub(producer.available_write());
            let bms = ((buffered / align) as u64 * 1000) / clock_rate;
            inner.dual_deck.deck_buffered_ms[deck_idx].store(bms, Ordering::Relaxed);
            if standby_gate.is_some() {
                inner
                    .dual_deck
                    .standby_buffered_ms
                    .store(bms, Ordering::Relaxed);
            } else {
                inner.buffered_ms.store(bms, Ordering::Relaxed);
            }
        }
        if offset < data.len() {
            thread::sleep(Duration::from_millis(1));
        }
    }
    true
}
