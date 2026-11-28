//! RT-safe PCM fade-out, skip fade, crossfade, and active pop helpers for `DualDeckPcmFeeder`.

use std::sync::atomic::Ordering;

use core_types::DeckState;

use crate::pipeline::fade::{AudioFadeControl, FadeDirection, FadeTarget};
use crate::verification::WireSampleFormat;

use super::pcm_feeder::{DualDeckPcmFeeder, PcmRenderOutcome};
use super::sanitize_and_clamp_f32;
use super::transition::RtTransitionKind;

impl DualDeckPcmFeeder {
    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn render_fade_out(
        &mut self,
        out_f32: &mut [f32],
        fade_ctrl: &AudioFadeControl,
        fade_target: FadeTarget,
        cur: usize,
        ch: usize,
        total_samples: usize,
        vol: f32,
        max_pos: f32,
    ) -> PcmRenderOutcome {
        let stale_slot = self.slot_ptrs[cur].is_null()
            || (fade_target == FadeTarget::SkipSilence
                && unsafe { (*self.slot_ptrs[cur]).deck_gen } != self.dual.deck_gen_for(cur));
        if !self.fade.fade_out_enabled() || self.fade.gain() <= 0.0 || stale_slot {
            self.fade.set_zero();
            fade_ctrl.mark_fade_out_done();
            if fade_target == FadeTarget::SeekFadeOut && !self.slot_ptrs[cur].is_null() {
                let wm = unsafe { (*self.slot_ptrs[cur]).watermark_samples };
                self.buffering_gate = wm > 0;
            }
            out_f32.fill(0.0);
            return PcmRenderOutcome::FadeOut;
        }
        let active = unsafe { &mut *self.slot_ptrs[cur] };
        let aligned = active
            .consumer
            .pop_slice_aligned(&mut out_f32[..total_samples], ch);
        if aligned == 0 {
            self.fade.set_zero();
            fade_ctrl.mark_fade_out_done();
            if fade_target == FadeTarget::SeekFadeOut {
                self.buffering_gate = active.watermark_samples > 0;
            }
            out_f32.fill(0.0);
            return PcmRenderOutcome::FadeOut;
        }
        let frames = aligned / ch;
        let mut written = 0usize;
        for f in 0..frames {
            let g = self.fade.step_frame(FadeDirection::Down);
            for c in 0..ch {
                let idx = f * ch + c;
                out_f32[idx] = sanitize_and_clamp_f32(out_f32[idx] * vol * g, max_pos);
            }
            written = (f + 1) * ch;
            if self.fade.gain() <= 0.0 {
                break;
            }
        }
        if written < out_f32.len() {
            out_f32[written..].fill(0.0);
        }
        if self.fade.gain() <= 0.0 || aligned < total_samples {
            self.fade.set_zero();
            fade_ctrl.mark_fade_out_done();
            if fade_target == FadeTarget::SeekFadeOut {
                self.buffering_gate = active.watermark_samples > 0;
            }
        }
        PcmRenderOutcome::FadeOut
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn render_skip_fade(
        &mut self,
        out_f32: &mut [f32],
        wire_scratch: &mut [u8],
        fade_ctrl: &AudioFadeControl,
        cur: usize,
        skip_seq: u64,
        target: usize,
        ch: usize,
        total_samples: usize,
        written: &mut usize,
        vol: f32,
        max_pos: f32,
    ) -> Option<PcmRenderOutcome> {
        let active = unsafe { &mut *self.slot_ptrs[cur] };
        let rem_fade_samples = self.skip_fade.remaining_down_frames().max(1) * ch;
        let want = (total_samples - *written).min(rem_fade_samples);
        let aligned = active
            .consumer
            .pop_slice_aligned(&mut out_f32[*written..*written + want], ch);
        let mut faded_samples = 0usize;
        if aligned > 0 {
            let frames = aligned / ch;
            let mut has_nz = false;
            for f in 0..frames {
                let g = self.skip_fade.step_frame(FadeDirection::Down);
                for c in 0..ch {
                    let idx = *written + f * ch + c;
                    let scaled = sanitize_and_clamp_f32(out_f32[idx] * vol * g, max_pos);
                    if scaled.abs() > 1e-6 {
                        has_nz = true;
                    }
                    out_f32[idx] = scaled;
                    let b = scaled.to_le_bytes();
                    let woff = (f * ch + c) * 4;
                    wire_scratch[woff..woff + 4].copy_from_slice(&b);
                }
                faded_samples = (f + 1) * ch;
                if self.skip_fade.gain() <= 0.0 {
                    break;
                }
            }
            if faded_samples > 0 {
                if let Some(ref mut tap) = active.ver_tap {
                    tap.push_wire(&wire_scratch[..faded_samples * 4]);
                }
                if let Some(tap) = crate::visualizer::try_global_tap() {
                    tap.feed_wire(
                        &wire_scratch[..faded_samples * 4],
                        WireSampleFormat::Float32Le,
                        ch as u16,
                        self.out_rate,
                    );
                }
                let f_cnt = (faded_samples / ch) as u64;
                self.inner
                    .frames_rendered
                    .fetch_add(f_cnt, Ordering::Relaxed);
                self.inner.rt_telemetry.add_frames_rt(f_cnt);
                if has_nz {
                    self.inner
                        .nonzero_output_frames
                        .fetch_add(f_cnt, Ordering::Relaxed);
                }
                fade_ctrl.mark_audible();
            }
            *written += faded_samples;
        }
        if self.skip_fade.gain() <= 0.0 || aligned < want {
            self.active_skip_seq = None;
            if skip_seq != u64::MAX
                && self.dual.standby_compatible[target].load(Ordering::Acquire)
                && !self.slot_ptrs[target].is_null()
            {
                self.flip_to_standby(cur, target, RtTransitionKind::ManualSkipFlip, 0);
                self.dual
                    .manual_zero_latency_switches
                    .fetch_add(1, Ordering::Release);
                self.dual
                    .skip_handled_seq
                    .store(skip_seq, Ordering::Release);
                self.fade.set_unity();
                None
            } else {
                if *written < out_f32.len() {
                    out_f32[*written..].fill(0.0);
                }
                let kind = if skip_seq == u64::MAX {
                    self.dual.mismatch_armed.store(false, Ordering::Release);
                    RtTransitionKind::MismatchDrain
                } else {
                    self.dual
                        .skip_handled_seq
                        .store(skip_seq, Ordering::Release);
                    RtTransitionKind::ManualSkipDrain
                };
                self.dual.deck_states[cur].store(DeckState::Draining as u8, Ordering::Release);
                self.drain_notified = true;
                let tgen = self.dual.deck_gen_for(target);
                self.dual.push_rt_event(kind, cur as u8, target as u8, tgen);
                Some(PcmRenderOutcome::Draining)
            }
        } else {
            Some(PcmRenderOutcome::Rendered)
        }
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn start_mismatch_crossfade(
        &mut self,
        read_active: bool,
        cur_now: usize,
        other_now: usize,
        out_f32: &mut [f32],
        wire_scratch: &mut [u8],
        ch: usize,
        total_samples: usize,
        written: &mut usize,
        vol: f32,
        max_pos: f32,
    ) {
        self.crossfade_active = true;
        self.crossfade_pos = 0;
        self.crossfade_target_deck = other_now;
        self.crossfade_resume_frame = self.dual.mismatch_resume_frame.load(Ordering::Acquire);
        self.run_pcm_crossfade(
            read_active,
            cur_now,
            other_now,
            out_f32,
            wire_scratch,
            None,
            ch,
            total_samples,
            written,
            vol,
            max_pos,
        );
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn run_pcm_crossfade(
        &mut self,
        read_active: bool,
        cur_deck: usize,
        target_deck: usize,
        out_f32: &mut [f32],
        wire_scratch: &mut [u8],
        fade_ctrl: Option<&AudioFadeControl>,
        ch: usize,
        total_samples: usize,
        written: &mut usize,
        vol: f32,
        max_pos: f32,
    ) {
        let (active, standby) = unsafe {
            (
                &mut *self.slot_ptrs[cur_deck],
                &mut *self.slot_ptrs[target_deck],
            )
        };
        let mut stack_a = [0.0f32; crate::backend::cpal_shared::CPAL_RT_CHUNK_SAMPLES];
        let mut stack_b = [0.0f32; crate::backend::cpal_shared::CPAL_RT_CHUNK_SAMPLES];
        while self.crossfade_active && *written < total_samples {
            let rem_cf = self.crossfade_frames.saturating_sub(self.crossfade_pos);
            if rem_cf == 0 {
                self.crossfade_active = false;
                break;
            }
            let max_chunk_frames = (stack_b.len() / ch)
                .min((total_samples - *written) / ch)
                .min(wire_scratch.len() / (ch * 4));
            let cf_frames = rem_cf.min(max_chunk_frames);
            if cf_frames == 0 {
                break;
            }
            let cf_want = cf_frames * ch;
            if read_active {
                let aa = active
                    .consumer
                    .pop_slice_aligned(&mut stack_a[..cf_want], ch);
                if aa < cf_want {
                    stack_a[aa..cf_want].fill(0.0);
                }
            }
            let ab = standby
                .consumer
                .pop_slice_aligned(&mut stack_b[..cf_want], ch);
            if ab < cf_want {
                stack_b[ab..cf_want].fill(0.0);
            }
            let mut has_nz = false;
            for f in 0..cf_frames {
                self.crossfade_pos += 1;
                let t = (self.crossfade_pos as f32 / self.crossfade_frames.max(1) as f32)
                    .clamp(0.0, 1.0);
                let ga = if read_active { 1.0 - t } else { 0.0 };
                let gb = t;
                for c in 0..ch {
                    let sidx = f * ch + c;
                    let mixed = sanitize_and_clamp_f32(
                        (stack_a[sidx] * ga + stack_b[sidx] * gb) * vol,
                        max_pos,
                    );
                    if mixed.abs() > 1e-6 {
                        has_nz = true;
                    }
                    out_f32[*written + sidx] = mixed;
                    let woff = sidx * 4;
                    wire_scratch[woff..woff + 4].copy_from_slice(&mixed.to_le_bytes());
                }
            }
            if let Some(ref mut tap) = standby.ver_tap {
                tap.push_wire(&wire_scratch[..cf_want * 4]);
            }
            if let Some(tap) = crate::visualizer::try_global_tap() {
                tap.feed_wire(
                    &wire_scratch[..cf_want * 4],
                    WireSampleFormat::Float32Le,
                    ch as u16,
                    self.out_rate,
                );
            }
            if has_nz {
                self.inner
                    .nonzero_output_frames
                    .fetch_add(cf_frames as u64, Ordering::Relaxed);
            }
            if let Some(fc) = fade_ctrl {
                fc.mark_audible();
            }
            *written += cf_want;
            if self.crossfade_pos >= self.crossfade_frames {
                self.crossfade_active = false;
                self.dual.mismatch_armed.store(false, Ordering::Release);
                self.flip_to_standby(
                    cur_deck,
                    target_deck,
                    RtTransitionKind::MismatchCrossfadeFlip,
                    self.crossfade_resume_frame,
                );
                self.dual
                    .format_mismatch_recoveries
                    .fetch_add(1, Ordering::Release);
                self.fade.set_unity();
            }
        }
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn pop_and_process_pcm(
        &mut self,
        cur_now: usize,
        dst: &mut [f32],
        wire_scratch: &mut [u8],
        fade_ctrl: &AudioFadeControl,
        ch: usize,
        vol: f32,
        max_pos: f32,
        written: &mut usize,
    ) -> usize {
        let active = unsafe { &mut *self.slot_ptrs[cur_now] };
        let al = active.consumer.pop_slice_aligned(dst, ch);
        if al > 0 {
            let frames = al / ch;
            let mut has_nz = false;
            for f in 0..frames {
                let g = if self.fade.gain() < 1.0 {
                    self.fade.step_frame(FadeDirection::Up)
                } else {
                    1.0
                };
                for c in 0..ch {
                    let idx = f * ch + c;
                    let scaled = sanitize_and_clamp_f32(dst[idx] * vol * g, max_pos);
                    if scaled.abs() > 1e-6 {
                        has_nz = true;
                    }
                    dst[idx] = scaled;
                    let woff = idx * 4;
                    wire_scratch[woff..woff + 4].copy_from_slice(&scaled.to_le_bytes());
                }
            }
            if let Some(ref mut tap) = active.ver_tap {
                tap.push_wire(&wire_scratch[..al * 4]);
            }
            if let Some(tap) = crate::visualizer::try_global_tap() {
                tap.feed_wire(
                    &wire_scratch[..al * 4],
                    WireSampleFormat::Float32Le,
                    ch as u16,
                    self.out_rate,
                );
            }
            fade_ctrl.mark_audible();
            let f_cnt = frames as u64;
            self.inner
                .frames_rendered
                .fetch_add(f_cnt, Ordering::Relaxed);
            self.inner.rt_telemetry.add_frames_rt(f_cnt);
            if has_nz {
                self.inner
                    .nonzero_output_frames
                    .fetch_add(f_cnt, Ordering::Relaxed);
            }
            *written += al;
        }
        al
    }

    #[inline]
    pub(super) fn trigger_mismatch_drain(
        &mut self,
        out_f32: &mut [f32],
        written: usize,
        cur_now: usize,
        other_now: usize,
    ) -> PcmRenderOutcome {
        if written < out_f32.len() {
            out_f32[written..].fill(0.0);
        }
        self.dual.mismatch_armed.store(false, Ordering::Release);
        self.dual.deck_states[cur_now].store(DeckState::Draining as u8, Ordering::Release);
        self.drain_notified = true;
        let tgen = self.dual.deck_gen_for(other_now);
        self.dual.push_rt_event(
            RtTransitionKind::MismatchDrain,
            cur_now as u8,
            other_now as u8,
            tgen,
        );
        PcmRenderOutcome::Draining
    }
}
