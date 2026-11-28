//! RT-safe float-PCM render loop, ring watermark gating, and skip/mismatch arming.

use std::sync::atomic::Ordering;

use core_types::{DeckState, PlaybackLifecycleState};

use crate::pipeline::fade::{
    AudioFadeControl, FadeTarget, LinearFadeState, MICRO_FADE_MS, MISMATCH_CROSSFADE_MS,
    fade_out_f32_tail_guarded,
};

use super::pcm_feeder::{DualDeckPcmFeeder, PcmRenderOutcome};
use super::transition::RtTransitionKind;

impl DualDeckPcmFeeder {
    pub(crate) fn render_f32(
        &mut self,
        out_f32: &mut [f32],
        wire_scratch: &mut [u8],
        fade_ctrl: &AudioFadeControl,
        max_pos: f32,
    ) -> PcmRenderOutcome {
        self.poll_inbox();

        let ch = self.out_channels.max(1);
        let total_samples = (out_f32.len() / ch) * ch;
        if total_samples == 0 {
            out_f32.fill(0.0);
            return PcmRenderOutcome::Silent;
        }
        let vol = f32::from_bits(self.inner.volume_bits.load(Ordering::Relaxed));
        let cur = self.dual.active_idx();
        let other = 1 - cur;

        let fade_target = fade_ctrl.target();
        if matches!(
            fade_target,
            FadeTarget::PauseFadeOut
                | FadeTarget::StopFadeOut
                | FadeTarget::SeekFadeOut
                | FadeTarget::SkipSilence
        ) {
            return self.render_fade_out(
                out_f32,
                fade_ctrl,
                fade_target,
                cur,
                ch,
                total_samples,
                vol,
                max_pos,
            );
        }

        if self.inner.stopped.load(Ordering::Relaxed)
            || self.inner.paused.load(Ordering::Relaxed)
            || self.inner.current_session_id.load(Ordering::Relaxed)
                != self.active_session_id.load(Ordering::Acquire)
            || self.slot_ptrs[cur].is_null()
        {
            out_f32.fill(0.0);
            return PcmRenderOutcome::Silent;
        }

        if self.drain_notified
            || self.dual.deck_states[cur].load(Ordering::Acquire) == DeckState::Draining as u8
        {
            out_f32.fill(0.0);
            return PcmRenderOutcome::Draining;
        }

        if !self.check_ring_and_watermark(cur, ch) {
            out_f32.fill(0.0);
            return PcmRenderOutcome::Silent;
        }

        self.arm_skip_or_mismatch(cur, other);

        let mut written = 0usize;

        // 1. Active manual skip / rapid drain fade-out
        if let Some((skip_seq, target)) = self.active_skip_seq
            && let Some(outcome) = self.render_skip_fade(
                out_f32,
                wire_scratch,
                fade_ctrl,
                cur,
                skip_seq,
                target,
                ch,
                total_samples,
                &mut written,
                vol,
                max_pos,
            )
        {
            return outcome;
        }

        // 2. Active 5 ms micro-crossfade for FormatMismatch recovery
        if self.crossfade_active {
            let cur_now = self.dual.active_idx();
            let target = self.crossfade_target_deck;
            if cur_now != target
                && !self.slot_ptrs[cur_now].is_null()
                && !self.slot_ptrs[target].is_null()
            {
                self.run_pcm_crossfade(
                    true,
                    cur_now,
                    target,
                    out_f32,
                    wire_scratch,
                    Some(fade_ctrl),
                    ch,
                    total_samples,
                    &mut written,
                    vol,
                    max_pos,
                );
                if written >= total_samples {
                    return PcmRenderOutcome::Rendered;
                }
            } else {
                self.crossfade_active = false;
            }
        }

        // 3. Normal Active playback + inline Gapless / FormatMismatch alignment / Cross-rate drain
        loop {
            if written >= total_samples {
                break;
            }
            let cur_now = self.dual.active_idx();
            let other_now = 1 - cur_now;
            if self.slot_ptrs[cur_now].is_null() {
                out_f32[written..].fill(0.0);
                return PcmRenderOutcome::Silent;
            }
            let mut want = total_samples - written;
            let mut hit_mismatch_boundary = false;
            if !self.crossfade_active && self.dual.mismatch_armed.load(Ordering::Acquire) {
                let m_target =
                    (self.dual.mismatch_target_deck.load(Ordering::Acquire) & 1) as usize;
                if m_target == other_now
                    && self.dual.deck_states[other_now].load(Ordering::Acquire)
                        == DeckState::StandbyReady as u8
                {
                    let cur_frame = self.inner.frames_rendered.load(Ordering::Relaxed);
                    let align_frame = self.dual.mismatch_align_frame.load(Ordering::Acquire);
                    if cur_frame >= align_frame {
                        want = 0;
                        hit_mismatch_boundary = true;
                    } else {
                        let rem_until = (align_frame - cur_frame) as usize * ch;
                        if rem_until < want {
                            want = rem_until;
                            hit_mismatch_boundary = true;
                        }
                    }
                }
            }

            let aligned = if want > 0 {
                self.pop_and_process_pcm(
                    cur_now,
                    &mut out_f32[written..written + want],
                    wire_scratch,
                    fade_ctrl,
                    ch,
                    vol,
                    max_pos,
                    &mut written,
                )
            } else {
                0
            };

            if hit_mismatch_boundary && aligned == want {
                if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                    && !self.slot_ptrs[other_now].is_null()
                {
                    self.start_mismatch_crossfade(
                        true,
                        cur_now,
                        other_now,
                        out_f32,
                        wire_scratch,
                        ch,
                        total_samples,
                        &mut written,
                        vol,
                        max_pos,
                    );
                    continue;
                } else {
                    return self.trigger_mismatch_drain(out_f32, written, cur_now, other_now);
                }
            }

            if aligned < want {
                let active_avail = unsafe { (*self.slot_ptrs[cur_now]).consumer.available_read() };
                if self.dual.deck_eof_flags[cur_now].load(Ordering::SeqCst) && active_avail < ch {
                    if self.dual.mismatch_armed.load(Ordering::Acquire)
                        && self.dual.deck_states[other_now].load(Ordering::Acquire)
                            == DeckState::StandbyReady as u8
                    {
                        if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                            && !self.slot_ptrs[other_now].is_null()
                        {
                            self.start_mismatch_crossfade(
                                false,
                                cur_now,
                                other_now,
                                out_f32,
                                wire_scratch,
                                ch,
                                total_samples,
                                &mut written,
                                vol,
                                max_pos,
                            );
                            continue;
                        } else {
                            return self
                                .trigger_mismatch_drain(out_f32, written, cur_now, other_now);
                        }
                    }

                    if self.dual.deck_states[other_now].load(Ordering::Acquire)
                        == DeckState::StandbyReady as u8
                    {
                        if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                            && !self.slot_ptrs[other_now].is_null()
                        {
                            self.flip_to_standby(
                                cur_now,
                                other_now,
                                RtTransitionKind::GaplessFlip,
                                0,
                            );
                            self.inner
                                .gapless_transitions
                                .fetch_add(1, Ordering::Release);
                            self.fade.set_unity();
                            self.buffering_gate = false;
                            continue;
                        } else {
                            if written < out_f32.len() {
                                out_f32[written..].fill(0.0);
                            }
                            self.dual.deck_states[cur_now]
                                .store(DeckState::Draining as u8, Ordering::Release);
                            self.drain_notified = true;
                            let tgen = self.dual.deck_gen_for(other_now);
                            self.dual.push_rt_event(
                                RtTransitionKind::CrossRateDrain,
                                cur_now as u8,
                                other_now as u8,
                                tgen,
                            );
                            return PcmRenderOutcome::Draining;
                        }
                    }

                    if written < out_f32.len() {
                        out_f32[written..].fill(0.0);
                    }
                    fade_ctrl.mark_silent();
                    self.dual.deck_states[cur_now].store(DeckState::Idle as u8, Ordering::Release);
                    let _ = self.inner.state_code.compare_exchange(
                        PlaybackLifecycleState::Playing as i32,
                        PlaybackLifecycleState::Ended as i32,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                    return PcmRenderOutcome::Ended;
                } else {
                    self.inner
                        .ring_buffer_underrun_count
                        .fetch_add(1, Ordering::Relaxed);
                    self.inner.rt_telemetry.record_xrun_rt();
                    if aligned > 0 {
                        let tail_start = written.saturating_sub(aligned);
                        fade_out_f32_tail_guarded(
                            &mut out_f32[tail_start..written],
                            ch,
                            128,
                            self.inner.strict_bit_perfect.load(Ordering::Relaxed),
                        );
                    }
                    if written < out_f32.len() {
                        out_f32[written..].fill(0.0);
                    }
                    let wm = unsafe { (*self.slot_ptrs[cur_now]).watermark_samples };
                    if wm > 0 {
                        self.buffering_gate = true;
                        self.fade.reset_for_play_start();
                    }
                    break;
                }
            }
        }

        if written < out_f32.len() {
            out_f32[written..].fill(0.0);
        }
        PcmRenderOutcome::Rendered
    }

    #[inline]
    fn check_ring_and_watermark(&mut self, cur: usize, ch: usize) -> bool {
        let active = unsafe { &mut *self.slot_ptrs[cur] };
        let req_ep = active.consumer.requested_epoch();
        if req_ep != active.last_ring_epoch {
            if active.consumer.has_pending_flush() && active.consumer.try_flush_and_ack().is_none()
            {
                return false;
            }
            active.last_ring_epoch = active.consumer.epoch();
            self.buffering_gate = active.watermark_samples > 0;
            self.fade.reset_for_play_start();
        }

        let avail_before = active.consumer.available_read();
        let frames_avail = (avail_before / ch) as u64;
        let rate_u64 = self.out_rate.max(8_000) as u64;
        let bms = (frames_avail * 1000) / rate_u64;
        self.inner.buffered_ms.store(bms, Ordering::Relaxed);
        self.dual.deck_buffered_ms[cur].store(bms, Ordering::Relaxed);

        if self.buffering_gate {
            if avail_before >= active.watermark_samples
                || self.dual.deck_eof_flags[cur].load(Ordering::Acquire)
                || self.dual.skip_request_seq.load(Ordering::Acquire)
                    != self.dual.skip_handled_seq.load(Ordering::Acquire)
            {
                self.buffering_gate = false;
            } else {
                return false;
            }
        }
        true
    }

    #[inline]
    fn arm_skip_or_mismatch(&mut self, _cur: usize, other: usize) {
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
                    ((self.out_rate.max(8_000) as u64 * fade_ms) / 1000).clamp(32, 4096);
                self.skip_fade = LinearFadeState::with_frames(fade_frames, false, true, false);
                self.skip_fade.set_gain(self.fade.gain().max(0.01));
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
                let cur_frame = self.inner.frames_rendered.load(Ordering::Relaxed);
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
                            ((self.out_rate.max(8_000) as u64 * MISMATCH_CROSSFADE_MS) / 1000)
                                .clamp(32, 2048);
                        self.skip_fade =
                            LinearFadeState::with_frames(rapid_frames, false, true, false);
                        self.skip_fade.set_gain(self.fade.gain().max(0.01));
                        self.active_skip_seq = Some((u64::MAX, target));
                    }
                }
            }
        }
    }
}
