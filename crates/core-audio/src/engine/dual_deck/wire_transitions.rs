//! RT-safe wire skip/mismatch triggers, micro-crossfades, and active chunk pop helpers.

use std::sync::atomic::Ordering;

use core_types::DeckState;

use crate::pipeline::fade::{
    AudioFadeControl, FadeDirection, LinearFadeState, MICRO_FADE_MS, MISMATCH_CROSSFADE_MS,
    apply_fade_ramp_to_wire_bytes_guarded, crossfade_wire_bytes_guarded,
};
use crate::verification::WireSampleFormat;

use super::transition::RtTransitionKind;
use super::wire_feeder::{
    DualDeckWireFeeder, DualDeckWireOutcome, fill_wire_silence, wire_bytes_have_nonzero,
};

impl DualDeckWireFeeder {
    #[inline]
    pub(super) fn arm_wire_skip_or_mismatch(&mut self, other: usize, fade: &LinearFadeState) {
        let req_seq = self.dual.skip_request_seq.load(Ordering::Acquire);
        let handled_seq = self.dual.skip_handled_seq.load(Ordering::Acquire);
        if self.active_skip_seq.is_none() && req_seq != handled_seq {
            let target = (self.dual.skip_target_deck.load(Ordering::Acquire) & 1) as usize;
            if target == other
                && self.dual.deck_states[other].load(Ordering::Acquire)
                    == DeckState::StandbyReady as u8
            {
                let compat = self.dual.standby_compatible[other].load(Ordering::Acquire)
                    && !self.slot_ptrs[other].is_null();
                let fade_ms = if compat {
                    MICRO_FADE_MS
                } else {
                    MISMATCH_CROSSFADE_MS
                };
                let fade_frames =
                    ((self.clock_rate.max(8_000) as u64 * fade_ms) / 1000).clamp(32, 4096);
                let can_fade = !self.strict_bit_perfect.load(Ordering::Relaxed)
                    && !matches!(
                        self.wire,
                        WireSampleFormat::NativeDsd { .. }
                            | WireSampleFormat::Dop24In32MsbLe { .. }
                    );
                self.skip_fade = LinearFadeState::with_frames(fade_frames, false, can_fade, false);
                self.skip_fade.set_gain(fade.gain().max(0.01));
                self.active_skip_seq = Some((req_seq, target));
            }
        }

        if !self.crossfade_active
            && self.active_skip_seq.is_none()
            && self.dual.mismatch_armed.load(Ordering::Acquire)
        {
            let target = (self.dual.mismatch_target_deck.load(Ordering::Acquire) & 1) as usize;
            if target == other
                && self.dual.deck_states[other].load(Ordering::Acquire)
                    == DeckState::StandbyReady as u8
            {
                let cur_frame = self.frames_rendered.load(Ordering::Relaxed);
                let align_frame = self.dual.mismatch_align_frame.load(Ordering::Acquire);
                if cur_frame >= align_frame {
                    if self.dual.standby_compatible[other].load(Ordering::Acquire)
                        && !self.slot_ptrs[other].is_null()
                    {
                        self.crossfade_active = true;
                        self.crossfade_pos = 0;
                        self.crossfade_target_deck = target;
                        self.crossfade_resume_frame =
                            self.dual.mismatch_resume_frame.load(Ordering::Acquire);
                    } else {
                        let rapid_frames =
                            ((self.clock_rate.max(8_000) as u64 * MISMATCH_CROSSFADE_MS) / 1000)
                                .clamp(32, 2048);
                        self.skip_fade =
                            LinearFadeState::with_frames(rapid_frames, false, true, false);
                        self.skip_fade.set_gain(fade.gain().max(0.01));
                        self.active_skip_seq = Some((u64::MAX, target));
                    }
                }
            }
        }
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn render_wire_skip(
        &mut self,
        out: &mut [u8],
        bpf: usize,
        needed: usize,
        cur: usize,
        skip_seq: u64,
        target: usize,
        is_dsd: bool,
        fade: &mut LinearFadeState,
        fade_ctrl: Option<&AudioFadeControl>,
        dop_phase: &mut bool,
        buffering_gate: &mut bool,
        written: &mut usize,
    ) -> Option<DualDeckWireOutcome> {
        let active = unsafe { &mut *self.slot_ptrs[cur] };
        let rem_fade_bytes = if self.skip_fade.fade_out_enabled() {
            self.skip_fade.remaining_down_frames().max(1) * bpf
        } else {
            0
        };
        let want = (needed - *written).min(rem_fade_bytes);
        let aligned = if want > 0 {
            active
                .consumer
                .pop_slice_aligned(&mut out[*written..*written + want], bpf)
        } else {
            0
        };
        if aligned > 0 {
            let strict_bp = self.strict_bit_perfect.load(Ordering::Relaxed);
            apply_fade_ramp_to_wire_bytes_guarded(
                &mut out[*written..*written + aligned],
                self.wire,
                self.out_channels,
                &mut self.skip_fade,
                FadeDirection::Down,
                strict_bp,
            );
            if matches!(self.wire, WireSampleFormat::Dop24In32MsbLe { .. }) {
                *dop_phase = out[*written + aligned - 1] == 0x05;
            }
            active.ver_tap.push_wire(&out[*written..*written + aligned]);
            if let Some(tap) = crate::visualizer::try_global_tap() {
                tap.feed_wire(
                    &out[*written..*written + aligned],
                    self.wire,
                    self.out_channels as u16,
                    self.out_rate,
                );
            }
            let f_cnt = if is_dsd {
                ((aligned / bpf) * 8) as u64
            } else {
                (aligned / bpf) as u64
            };
            self.frames_rendered.fetch_add(f_cnt, Ordering::Relaxed);
            if wire_bytes_have_nonzero(&out[*written..*written + aligned], self.wire) {
                self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
            }
            if let Some(fc) = fade_ctrl {
                fc.mark_audible();
            }
            *written += aligned;
        }
        if !self.skip_fade.fade_out_enabled() || self.skip_fade.gain() <= 0.0 || aligned < want {
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
                fade.set_unity();
                *buffering_gate = false;
                None
            } else {
                fill_wire_silence(
                    &mut out[*written..],
                    self.wire,
                    self.out_channels,
                    dop_phase,
                );
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
                Some(if *written > 0 {
                    DualDeckWireOutcome::Rendered {
                        valid_bytes: *written,
                    }
                } else {
                    DualDeckWireOutcome::CrossRateDraining
                })
            }
        } else {
            fill_wire_silence(
                &mut out[*written..],
                self.wire,
                self.out_channels,
                dop_phase,
            );
            Some(DualDeckWireOutcome::Rendered {
                valid_bytes: *written,
            })
        }
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn start_wire_mismatch_crossfade(
        &mut self,
        read_active: bool,
        cur_now: usize,
        other_now: usize,
        out: &mut [u8],
        bpf: usize,
        needed: usize,
        is_dsd: bool,
        fade: &mut LinearFadeState,
        written: &mut usize,
    ) {
        self.crossfade_active = true;
        self.crossfade_pos = 0;
        self.crossfade_target_deck = other_now;
        self.crossfade_resume_frame = self.dual.mismatch_resume_frame.load(Ordering::Acquire);
        self.run_wire_crossfade(
            read_active,
            cur_now,
            other_now,
            out,
            bpf,
            needed,
            is_dsd,
            fade,
            None,
            written,
        );
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn run_wire_crossfade(
        &mut self,
        read_active: bool,
        cur_deck: usize,
        target_deck: usize,
        out: &mut [u8],
        bpf: usize,
        needed: usize,
        is_dsd: bool,
        fade: &mut LinearFadeState,
        fade_ctrl: Option<&AudioFadeControl>,
        written: &mut usize,
    ) {
        let (active, standby) = unsafe {
            (
                &mut *self.slot_ptrs[cur_deck],
                &mut *self.slot_ptrs[target_deck],
            )
        };
        let mut stack_a = [0u8; 8192];
        let mut stack_b = [0u8; 8192];
        while self.crossfade_active && *written < needed {
            let rem_cf = self.crossfade_frames.saturating_sub(self.crossfade_pos);
            if rem_cf == 0 {
                self.crossfade_active = false;
                break;
            }
            let max_bytes = (stack_b.len() / bpf) * bpf;
            let cf_raw = (rem_cf * bpf).min(needed - *written).min(max_bytes);
            let cf_aligned = (cf_raw / bpf) * bpf;
            if cf_aligned == 0 {
                break;
            }
            let aa = if read_active {
                active
                    .consumer
                    .pop_slice_aligned(&mut stack_a[..cf_aligned], bpf)
            } else {
                0
            };
            let ab = standby
                .consumer
                .pop_slice_aligned(&mut stack_b[..cf_aligned], bpf);
            if ab == 0 {
                break;
            }
            let mixed_bytes = crossfade_wire_bytes_guarded(
                &stack_a[..aa],
                &stack_b[..ab],
                &mut out[*written..*written + ab],
                self.wire,
                self.out_channels,
                &mut self.crossfade_pos,
                self.crossfade_frames,
                self.strict_bit_perfect.load(Ordering::Relaxed),
            );
            if mixed_bytes > 0 {
                standby
                    .ver_tap
                    .push_wire(&out[*written..*written + mixed_bytes]);
                if let Some(tap) = crate::visualizer::try_global_tap() {
                    tap.feed_wire(
                        &out[*written..*written + mixed_bytes],
                        self.wire,
                        self.out_channels as u16,
                        self.out_rate,
                    );
                }
                let f_cnt = if is_dsd {
                    ((mixed_bytes / bpf) * 8) as u64
                } else {
                    (mixed_bytes / bpf) as u64
                };
                if wire_bytes_have_nonzero(&out[*written..*written + mixed_bytes], self.wire) {
                    self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
                }
                if let Some(fc) = fade_ctrl {
                    fc.mark_audible();
                }
                *written += mixed_bytes;
            }
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
                fade.set_unity();
            }
        }
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn pop_active_wire_chunk(
        &mut self,
        cur_now: usize,
        dst: &mut [u8],
        bpf: usize,
        is_dsd: bool,
        fade: &mut LinearFadeState,
        fade_ctrl: Option<&AudioFadeControl>,
        dop_phase: &mut bool,
        written: &mut usize,
    ) -> usize {
        let active = unsafe { &mut *self.slot_ptrs[cur_now] };
        let al = active.consumer.pop_slice_aligned(dst, bpf);
        if al > 0 {
            let strict_bp = self.strict_bit_perfect.load(Ordering::Relaxed);
            if !strict_bp && fade.gain() < 1.0 {
                apply_fade_ramp_to_wire_bytes_guarded(
                    &mut dst[..al],
                    self.wire,
                    self.out_channels,
                    fade,
                    FadeDirection::Up,
                    false,
                );
            }
            if let Some(fc) = fade_ctrl {
                fc.mark_audible();
            }
            if matches!(self.wire, WireSampleFormat::Dop24In32MsbLe { .. }) {
                *dop_phase = dst[al - 1] == 0x05;
            }
            active.ver_tap.push_wire(&dst[..al]);
            if let Some(tap) = crate::visualizer::try_global_tap() {
                tap.feed_wire(
                    &dst[..al],
                    self.wire,
                    self.out_channels as u16,
                    self.out_rate,
                );
            }
            let f_cnt = if is_dsd {
                ((al / bpf) * 8) as u64
            } else {
                (al / bpf) as u64
            };
            self.frames_rendered.fetch_add(f_cnt, Ordering::Relaxed);
            self.telemetry.add_frames_rt(f_cnt);
            if wire_bytes_have_nonzero(&dst[..al], self.wire) {
                self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
            }
            *written += al;
        }
        al
    }

    #[inline]
    pub(super) fn trigger_wire_mismatch_drain(
        &mut self,
        out: &mut [u8],
        written: usize,
        cur_now: usize,
        other_now: usize,
        dop_phase: &mut bool,
    ) -> DualDeckWireOutcome {
        fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
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
        if written > 0 {
            DualDeckWireOutcome::Rendered {
                valid_bytes: written,
            }
        } else {
            DualDeckWireOutcome::CrossRateDraining
        }
    }
}
