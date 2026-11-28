//! Off-RT dual-deck relay loop handling RT transition events, retired payloads, and auto-standby.

use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use core_types::{DeckState, PlaybackLifecycleState};

use crate::engine::coordinator::PlayerCommand;
use crate::engine::dual_deck::RtTransitionKind;
use crate::engine::{PlayerInner, position_ms_from_inner};
use crate::pipeline::fade::AUTO_PREDECODE_REMAINING_MS;

use super::types::commit_deck_metadata_to_inner;

pub(crate) fn relay_loop(
    weak_inner: std::sync::Weak<PlayerInner>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
) {
    let mut last_auto_reopen: Option<(usize, u64)> = None;
    let mut last_relay_signal: u64 = 0;
    loop {
        let Some(inner) = weak_inner.upgrade() else {
            break;
        };
        if inner.dual_deck.relay_stop.load(Ordering::Acquire) {
            break;
        }
        inner.dual_deck.drain_retired_payloads();

        if inner.cpal_stream_error_flag.swap(false, Ordering::AcqRel) {
            tracing::warn!("cpal output stream error signalled on audio callback (device lost)");
            if let Ok(mut code_guard) = inner.last_error_code.write()
                && code_guard.is_none()
            {
                *code_guard = Some("DEVICE_LOST".to_string());
            }
            if let Ok(mut guard) = inner.last_error.write()
                && guard.is_none()
            {
                *guard = Some("Audio output stream error (device lost or invalidated)".to_string());
            }
        }

        while let Some(evt) = inner.dual_deck.pop_rt_event() {
            let from_idx = (evt.from_deck & 1) as usize;
            let to_idx = (evt.to_deck & 1) as usize;
            match evt.kind {
                RtTransitionKind::GaplessFlip
                | RtTransitionKind::ManualSkipFlip
                | RtTransitionKind::MismatchCrossfadeFlip => {
                    if (inner.dual_deck.deck_gen_for(to_idx) & 0xFF_FFFF_FFFF)
                        == (evt.to_deck_gen & 0xFF_FFFF_FFFF)
                    {
                        let existing_tm = if evt.kind == RtTransitionKind::MismatchCrossfadeFlip {
                            inner
                                .active_track_metadata
                                .read()
                                .ok()
                                .and_then(|g| g.clone())
                        } else {
                            None
                        };
                        if let Ok(mg) = inner.dual_deck.deck_meta[to_idx].read()
                            && let Some(ref snap) = *mg
                        {
                            commit_deck_metadata_to_inner(&inner, snap);
                            if evt.kind == RtTransitionKind::MismatchCrossfadeFlip
                                && snap.track_meta.is_none()
                                && let Some(prev_tm) = existing_tm
                                && let Ok(mut tm_lock) = inner.active_track_metadata.write()
                            {
                                *tm_lock = Some(prev_tm);
                            }
                        }
                        if evt.kind != RtTransitionKind::MismatchCrossfadeFlip {
                            inner.dual_deck.set_deck_track_meta(from_idx, None);
                        }
                        inner.dual_deck.set_deck_key(from_idx, None);
                        inner
                            .dual_deck
                            .committed_deck_gen
                            .store(inner.dual_deck.deck_gen_for(to_idx), Ordering::Release);
                        inner.dual_deck.promote_decode_thread(to_idx);
                    }
                    inner.dual_deck.notify_flip_done();
                    let _ = cmd_tx.send(PlayerCommand::RetireDeck {
                        deck_idx: from_idx,
                        deck_gen: evt.to_deck_gen,
                    });
                }
                RtTransitionKind::CrossRateDrain
                | RtTransitionKind::ManualSkipDrain
                | RtTransitionKind::MismatchDrain => {
                    let _ = cmd_tx.send(PlayerCommand::ReopenOntoStandby {
                        from_deck: from_idx,
                        to_deck: to_idx,
                        to_deck_gen: evt.to_deck_gen,
                        is_manual_skip: evt.kind == RtTransitionKind::ManualSkipDrain,
                        is_mismatch_recovery: evt.kind == RtTransitionKind::MismatchDrain,
                    });
                }
            }
        }

        // Hardware Exclusive / ASIO EOF Standby Promotion (when uses_dual_feeder == false)
        if !inner.stopped.load(Ordering::Acquire)
            && inner.state_code.load(Ordering::Acquire) == PlaybackLifecycleState::Ended as i32
        {
            let uses_dual_feeder = inner
                .dual_deck
                .active_profile
                .read()
                .ok()
                .and_then(|g| g.as_ref().map(|p| p.uses_dual_feeder))
                .unwrap_or(true);
            if !uses_dual_feeder {
                let active_idx = inner.dual_deck.active_idx();
                let sb = inner.dual_deck.standby_idx();
                let sb_gen = inner.dual_deck.deck_gen_for(sb);
                if let Some((prev_sb, prev_gen)) = last_auto_reopen
                    && (prev_sb != sb || prev_gen != sb_gen)
                {
                    last_auto_reopen = None;
                }
                if inner.dual_deck.deck_state(sb) == DeckState::StandbyReady
                    && !inner.dual_deck.standby_is_mismatch_recovery[sb].load(Ordering::Acquire)
                    && last_auto_reopen != Some((sb, sb_gen))
                {
                    last_auto_reopen = Some((sb, sb_gen));
                    let _ = cmd_tx.send(PlayerCommand::ReopenOntoStandby {
                        from_deck: active_idx,
                        to_deck: sb,
                        to_deck_gen: sb_gen,
                        is_manual_skip: false,
                        is_mismatch_recovery: false,
                    });
                }
            } else {
                last_auto_reopen = None;
            }
        } else {
            last_auto_reopen = None;
        }

        if inner.has_queued_next_spec.load(Ordering::Acquire)
            && !inner.stopped.load(Ordering::Relaxed)
            && inner.state_code.load(Ordering::Relaxed) == PlaybackLifecycleState::Playing as i32
        {
            let sb = inner.dual_deck.standby_idx();
            if inner.dual_deck.deck_state(sb) == DeckState::Idle {
                let dur = inner.duration_ms.load(Ordering::Relaxed);
                let pos = position_ms_from_inner(&inner);
                let should_trigger = if dur > 0 {
                    dur.saturating_sub(pos) <= AUTO_PREDECODE_REMAINING_MS
                        || (pos.saturating_mul(100) / dur) >= 75
                } else {
                    true
                };
                if should_trigger {
                    let _ = cmd_tx.send(PlayerCommand::TriggerAutoStandby);
                }
            }
        }

        let active_playing = !inner.stopped.load(Ordering::Relaxed);
        let sig = inner.dual_deck.relay_signal.load(Ordering::Acquire);
        drop(inner);
        // RT-4: RT callbacks only bump `relay_signal` atomically (zero OS syscalls);
        // poll quickly (2 ms) while active or if a signal arrived, else sleep 15 ms.
        let wait = if sig != last_relay_signal {
            last_relay_signal = sig;
            Duration::ZERO
        } else if active_playing {
            Duration::from_millis(2)
        } else {
            Duration::from_millis(15)
        };
        if !wait.is_zero() {
            thread::park_timeout(wait);
        }
    }
}
