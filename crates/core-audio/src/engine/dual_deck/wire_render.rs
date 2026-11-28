//! RT-safe wire-period rendering (`pop_wire_period`).

use std::sync::atomic::Ordering;

use core_types::DeckState;

use crate::pipeline::fade::{AudioFadeControl, LinearFadeState, fade_out_wire_tail_guarded};
use crate::pipeline::ring_buffer::UnderrunGuard;
use crate::verification::WireSampleFormat;

use super::transition::RtTransitionKind;
use super::wire_feeder::{DualDeckWireFeeder, DualDeckWireOutcome, fill_wire_silence};

impl DualDeckWireFeeder {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn pop_wire_period(
        &mut self,
        out: &mut [u8],
        bpf: usize,
        fade: &mut LinearFadeState,
        fade_ctrl: Option<&AudioFadeControl>,
        dop_phase: &mut bool,
        buffering_gate: &mut bool,
    ) -> DualDeckWireOutcome {
        if let Some(wm) = self.poll_inbox() {
            *buffering_gate = wm > 0;
            fade.reset_for_play_start();
            *dop_phase = false;
        }

        let needed = (out.len() / bpf.max(1)) * bpf.max(1);
        if needed == 0 || bpf == 0 {
            return DualDeckWireOutcome::Underrun;
        }
        let cur = self.dual.active_idx();
        let other = 1 - cur;
        if self.slot_ptrs[cur].is_null() {
            fill_wire_silence(out, self.wire, self.out_channels, dop_phase);
            return DualDeckWireOutcome::Underrun;
        }
        if self.drain_notified
            || self.dual.deck_states[cur].load(Ordering::Acquire) == DeckState::Draining as u8
        {
            fill_wire_silence(out, self.wire, self.out_channels, dop_phase);
            return DualDeckWireOutcome::CrossRateDraining;
        }

        self.arm_wire_skip_or_mismatch(other, fade);

        let is_dsd = matches!(self.wire, WireSampleFormat::NativeDsd { .. });
        let mut written = 0usize;

        // 1. Active manual skip / rapid drain fade-out
        if let Some((skip_seq, target)) = self.active_skip_seq
            && let Some(outcome) = self.render_wire_skip(
                out,
                bpf,
                needed,
                cur,
                skip_seq,
                target,
                is_dsd,
                fade,
                fade_ctrl,
                dop_phase,
                buffering_gate,
                &mut written,
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
                self.run_wire_crossfade(
                    true,
                    cur_now,
                    target,
                    out,
                    bpf,
                    needed,
                    is_dsd,
                    fade,
                    fade_ctrl,
                    &mut written,
                );
                if written >= needed {
                    return DualDeckWireOutcome::Rendered {
                        valid_bytes: written,
                    };
                }
            } else {
                self.crossfade_active = false;
            }
        }

        // 3. Normal Active playback + inline Gapless / FormatMismatch alignment / Cross-rate drain
        loop {
            if written >= needed {
                break;
            }
            let cur_now = self.dual.active_idx();
            let other_now = 1 - cur_now;
            if self.slot_ptrs[cur_now].is_null() {
                break;
            }
            let mut want = needed - written;
            let mut hit_mismatch_boundary = false;
            if !self.crossfade_active && self.dual.mismatch_armed.load(Ordering::Acquire) {
                let m_target =
                    (self.dual.mismatch_target_deck.load(Ordering::Acquire) & 1) as usize;
                if m_target == other_now
                    && self.dual.deck_states[other_now].load(Ordering::Acquire)
                        == DeckState::StandbyReady as u8
                {
                    let cur_frame = self.frames_rendered.load(Ordering::Relaxed);
                    let align_frame = self.dual.mismatch_align_frame.load(Ordering::Acquire);
                    let frame_units = if is_dsd { 8 } else { 1 };
                    if cur_frame >= align_frame {
                        want = 0;
                        hit_mismatch_boundary = true;
                    } else {
                        let rem_bytes = (((align_frame - cur_frame) as usize) / frame_units) * bpf;
                        if rem_bytes < want {
                            want = rem_bytes;
                            hit_mismatch_boundary = true;
                        }
                    }
                }
            }

            let aligned = if want > 0 {
                self.pop_active_wire_chunk(
                    cur_now,
                    &mut out[written..written + want],
                    bpf,
                    is_dsd,
                    fade,
                    fade_ctrl,
                    dop_phase,
                    &mut written,
                )
            } else {
                0
            };

            if hit_mismatch_boundary && aligned == want {
                if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                    && !self.slot_ptrs[other_now].is_null()
                {
                    self.start_wire_mismatch_crossfade(
                        true,
                        cur_now,
                        other_now,
                        out,
                        bpf,
                        needed,
                        is_dsd,
                        fade,
                        &mut written,
                    );
                    continue;
                } else {
                    return self
                        .trigger_wire_mismatch_drain(out, written, cur_now, other_now, dop_phase);
                }
            }

            if aligned < want {
                let avail_rem = unsafe { (*self.slot_ptrs[cur_now]).consumer.available_read() };
                if self.dual.deck_eof_flags[cur_now].load(Ordering::SeqCst) && avail_rem < bpf {
                    if self.dual.mismatch_armed.load(Ordering::Acquire)
                        && self.dual.deck_states[other_now].load(Ordering::Acquire)
                            == DeckState::StandbyReady as u8
                    {
                        if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                            && !self.slot_ptrs[other_now].is_null()
                        {
                            self.start_wire_mismatch_crossfade(
                                false,
                                cur_now,
                                other_now,
                                out,
                                bpf,
                                needed,
                                is_dsd,
                                fade,
                                &mut written,
                            );
                            continue;
                        } else {
                            return self.trigger_wire_mismatch_drain(
                                out, written, cur_now, other_now, dop_phase,
                            );
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
                            self.gapless_transitions.fetch_add(1, Ordering::Release);
                            fade.set_unity();
                            *buffering_gate = false;
                            continue;
                        } else {
                            fill_wire_silence(
                                &mut out[written..],
                                self.wire,
                                self.out_channels,
                                dop_phase,
                            );
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
                            return if written > 0 {
                                DualDeckWireOutcome::Rendered {
                                    valid_bytes: written,
                                }
                            } else {
                                DualDeckWireOutcome::CrossRateDraining
                            };
                        }
                    }

                    fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
                    return if written > 0 {
                        DualDeckWireOutcome::Rendered {
                            valid_bytes: written,
                        }
                    } else {
                        self.dual.deck_states[cur_now]
                            .store(DeckState::Idle as u8, Ordering::Release);
                        DualDeckWireOutcome::EofEmpty
                    };
                }
                self.underrun_count.fetch_add(1, Ordering::Relaxed);
                let strict_bp = self.strict_bit_perfect.load(Ordering::Relaxed);
                if written == 0 {
                    self.telemetry.record_xrun_rt();
                    if self.active_watermark_bytes() > 0 {
                        *buffering_gate = true;
                        fade.reset_for_play_start();
                    }
                    return DualDeckWireOutcome::Underrun;
                }
                if aligned > 0 {
                    let tail_start = written.saturating_sub(aligned);
                    fade_out_wire_tail_guarded(
                        &mut out[tail_start..written],
                        self.wire,
                        self.out_channels,
                        128,
                        strict_bp,
                    );
                }
                UnderrunGuard::handle_wire_underrun(
                    out,
                    written,
                    self.wire,
                    self.out_channels,
                    true, // tail already handled above
                    dop_phase,
                    Some(&self.telemetry),
                );
                if self.active_watermark_bytes() > 0 {
                    *buffering_gate = true;
                    fade.reset_for_play_start();
                }
                break;
            }
        }
        if written < out.len() {
            fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
        }
        DualDeckWireOutcome::Rendered {
            valid_bytes: written,
        }
    }
}
