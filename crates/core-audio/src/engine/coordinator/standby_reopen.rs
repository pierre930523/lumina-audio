//! Handler for `ReopenOntoStandby` cross-format dual-deck promotion.

use std::sync::atomic::Ordering;
use std::time::Duration;

use core_types::{DeckState, PlaybackLifecycleState};

use crate::engine::record_playback_error_with_code;
use crate::engine::session::{
    PipelineSpec, install_fresh_cancel_token, reopen_origin_decoder, start_output_pipeline,
    start_output_pipeline_from_standby,
};

use super::{
    CoordinatorState, enter_opening_with_fsm, mark_running_with_fsm,
    teardown_active_retiring_with_fsm,
};

pub(super) fn handle_reopen_onto_standby(
    st: &mut CoordinatorState,
    from_deck: usize,
    to_deck: usize,
    to_deck_gen: u64,
    is_manual_skip: bool,
    is_mismatch_recovery: bool,
) {
    let from_i = from_deck & 1;
    let to_i = to_deck & 1;
    if st.inner.stopped.load(Ordering::SeqCst)
        || (st.inner.dual_deck.deck_gen_for(to_i) & 0xFF_FFFF_FFFF)
            != (to_deck_gen & 0xFF_FFFF_FFFF)
        || st.inner.dual_deck.deck_state(to_i) != DeckState::StandbyReady
    {
        st.inner.dual_deck.notify_flip_done();
        return;
    }
    let is_paused = if is_manual_skip {
        st.inner.paused.store(false, Ordering::SeqCst);
        false
    } else {
        st.inner.paused.load(Ordering::SeqCst)
    };
    if let Some(ref prev) = st.active {
        prev.fade_ctrl.mark_silent();
    }
    teardown_active_retiring_with_fsm(&mut st.fsm, &st.inner, &mut st.active, true, true);
    st.inner
        .dual_deck
        .cancel_and_retire_deck(from_i, &st.inner.reaper);

    let resume_frame = if is_mismatch_recovery {
        st.inner
            .dual_deck
            .mismatch_resume_frame
            .load(Ordering::Acquire)
    } else {
        0
    };
    st.inner
        .dual_deck
        .mismatch_armed
        .store(false, Ordering::SeqCst);
    st.inner
        .dual_deck
        .active_deck_idx
        .store(to_i as u8, Ordering::SeqCst);
    st.inner.dual_deck.deck_states[to_i].store(DeckState::Playing as u8, Ordering::SeqCst);
    st.inner.dual_deck.deck_states[from_i].store(DeckState::Idle as u8, Ordering::SeqCst);
    st.inner.dual_deck.set_deck_key(from_i, None);
    st.inner
        .dual_deck
        .standby_buffered_ms
        .store(0, Ordering::Relaxed);
    st.inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
    if is_manual_skip {
        st.inner
            .dual_deck
            .manual_zero_latency_switches
            .fetch_add(1, Ordering::SeqCst);
    } else if is_mismatch_recovery {
        st.inner
            .dual_deck
            .format_mismatch_recoveries
            .fetch_add(1, Ordering::SeqCst);
    } else {
        st.inner.gapless_transitions.fetch_add(1, Ordering::SeqCst);
    }

    let next_sid = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
    st.inner
        .frames_rendered
        .store(resume_frame, Ordering::SeqCst);
    st.inner.nonzero_output_frames.store(0, Ordering::SeqCst);
    st.inner.state_code.store(
        if is_paused {
            PlaybackLifecycleState::Paused as i32
        } else {
            PlaybackLifecycleState::Playing as i32
        },
        Ordering::SeqCst,
    );

    let standby_snap_backup = st.inner.dual_deck.deck_meta[to_i]
        .read()
        .ok()
        .and_then(|g| g.clone());
    let standby_track_meta_backup = st.inner.dual_deck.deck_track_meta[to_i]
        .read()
        .ok()
        .and_then(|g| g.clone())
        .or_else(|| {
            standby_snap_backup
                .as_ref()
                .and_then(|s| s.track_meta.clone())
        })
        .or_else(|| {
            if is_mismatch_recovery {
                st.inner
                    .active_track_metadata
                    .read()
                    .ok()
                    .and_then(|g| g.clone())
            } else {
                None
            }
        });

    let mut reopen_succeeded = false;
    enter_opening_with_fsm(&mut st.fsm, &st.inner);
    match start_output_pipeline_from_standby(&st.inner, to_i, next_sid, is_paused) {
        Ok(mut sess) => {
            let dec_dur = sess.duration_ms;
            let committed_meta = standby_track_meta_backup
                .clone()
                .or_else(|| sess.track_meta.clone())
                .map(|mut m| {
                    if dec_dur > 0 {
                        m.duration_ms = dec_dur;
                    }
                    m
                });
            if !is_mismatch_recovery {
                st.inner
                    .dual_deck
                    .set_deck_track_meta(to_i, committed_meta.clone());
                if let Ok(mut tm_lock) = st.inner.active_track_metadata.write() {
                    *tm_lock = committed_meta.clone();
                }
                if let Ok(mut am_lock) = st.inner.active_meta.write()
                    && let Some(ref mut am) = *am_lock
                {
                    am.track_meta = committed_meta.clone();
                }
                if let Ok(mut mg) = st.inner.dual_deck.deck_meta[to_i].write()
                    && let Some(ref mut snap) = *mg
                {
                    snap.track_meta = committed_meta.clone();
                }
                sess.track_meta = committed_meta;
                if from_i != to_i {
                    st.inner.dual_deck.set_deck_track_meta(from_i, None);
                }
            } else if sess.track_meta.is_none()
                && let Some(ref prev_tm) = committed_meta
            {
                st.inner
                    .dual_deck
                    .set_deck_track_meta(to_i, Some(prev_tm.clone()));
                if let Ok(mut tm_lock) = st.inner.active_track_metadata.write() {
                    *tm_lock = Some(prev_tm.clone());
                }
                if let Ok(mut am_lock) = st.inner.active_meta.write()
                    && let Some(ref mut am) = *am_lock
                {
                    am.track_meta = Some(prev_tm.clone());
                }
                sess.track_meta = Some(prev_tm.clone());
            }
            st.inner
                .dual_deck
                .committed_deck_gen
                .store(st.inner.dual_deck.deck_gen_for(to_i), Ordering::Release);
            st.active = Some(sess);
            mark_running_with_fsm(&mut st.fsm, &st.inner);
            reopen_succeeded = true;
        }
        Err(e) => {
            tracing::warn!(
                "Standby output reopen failed ({e}); falling back to clean decoder reopen"
            );
            let mut fallback_ok = false;
            if let Some(snap) = standby_snap_backup {
                let preserved_track_meta = snap.track_meta.clone().or(standby_track_meta_backup);
                let reused = st.inner.dual_deck.cancel_and_join_deck(to_i);
                if let Some(fresh_cancel) = install_fresh_cancel_token(&st.inner) {
                    match reopen_origin_decoder(&st.inner, &snap.origin, reused, &fresh_cancel) {
                        Ok(mut dec) => {
                            let resume_ms =
                                if is_mismatch_recovery && resume_frame > 0 && snap.out_rate > 0 {
                                    ((resume_frame as u128) * 1000 / (snap.out_rate as u128)) as u64
                                } else {
                                    0
                                };
                            if resume_ms > 0 {
                                let _ = dec.seek(Duration::from_millis(resume_ms));
                            }
                            let fmt = dec.format().clone();
                            let dur_ms = dec
                                .duration()
                                .map(|d| d.as_millis() as u64)
                                .unwrap_or(snap.duration_ms);
                            let pcm_rate = if fmt.is_dsd {
                                (fmt.sample_rate_hz / 8).max(44_100)
                            } else {
                                fmt.sample_rate_hz.max(8_000)
                            };
                            let src_ch = (fmt.channels as u16).max(1);
                            let default_out_ch = if src_ch == 1 { 2 } else { src_ch };
                            st.inner.duration_ms.store(dur_ms, Ordering::SeqCst);
                            if let Ok(mut rg_lock) = st.inner.track_replay_gain.write() {
                                *rg_lock = snap.rg_tags.clone();
                            }
                            st.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
                            match start_output_pipeline(
                                &st.inner,
                                dec,
                                PipelineSpec {
                                    session_id: next_sid,
                                    pcm_rate,
                                    out_channels: default_out_ch,
                                    path: snap.path,
                                    source_label: snap.source_label,
                                    origin: snap.origin,
                                    track_meta: preserved_track_meta,
                                    cancel_token: fresh_cancel,
                                    format: fmt,
                                    duration_ms: dur_ms,
                                    start_paused: is_paused,
                                },
                                &st.cmd_tx,
                            ) {
                                Ok(sess) => {
                                    if !is_mismatch_recovery && from_i != to_i {
                                        st.inner.dual_deck.set_deck_track_meta(from_i, None);
                                    }
                                    st.active = Some(sess);
                                    fallback_ok = true;
                                    reopen_succeeded = true;
                                }
                                Err(fb_err) => {
                                    record_playback_error_with_code(
                                        &st.inner,
                                        fb_err.to_string(),
                                        Some("FORMAT_SWITCH_FAILED"),
                                        None,
                                    );
                                }
                            }
                        }
                        Err(reopen_err) => {
                            record_playback_error_with_code(
                                &st.inner,
                                format!("Standby fallback reopen failed: {reopen_err}"),
                                Some("FORMAT_SWITCH_FAILED"),
                                None,
                            );
                        }
                    }
                }
            }
            if !fallback_ok {
                record_playback_error_with_code(
                    &st.inner,
                    e.to_string(),
                    Some("FORMAT_SWITCH_FAILED"),
                    None,
                );
            }
        }
    }
    if reopen_succeeded && !is_mismatch_recovery {
        st.inner
            .dual_deck
            .swap_generation
            .fetch_add(1, Ordering::Release);
        st.inner.playback_epoch.fetch_add(1, Ordering::Release);
    }
    st.inner.dual_deck.notify_flip_done();
}
