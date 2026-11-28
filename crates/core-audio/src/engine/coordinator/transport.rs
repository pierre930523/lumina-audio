//! Handlers for Pause, Resume, SeekMs, RetireDeck, and TriggerAutoStandby commands.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread;
use std::time::{Duration, Instant};

use core_types::{DeckState, PlaybackLifecycleState, StreamSourceSpec};
use cpal::traits::StreamTrait;

use crate::engine::session::{
    NativeOutputSession, PipelineSpec, install_fresh_cancel_token, patched_track_meta,
    reopen_origin_decoder, start_output_pipeline,
};
use crate::engine::{AudioPlayer, PlayerOrigin, record_playback_error};
use crate::pipeline::fade::FadeTarget;

use super::CoordinatorState;

pub(super) fn handle_pause(st: &CoordinatorState) {
    if let Some(sess) = &st.active {
        sess.fade_ctrl.request_pause_fade_out();
        let deadline = Instant::now() + Duration::from_millis(25);
        while !sess.fade_ctrl.is_fade_out_done()
            && sess.fade_ctrl.target() == FadeTarget::PauseFadeOut
            && !st.inner.stopped.load(Ordering::Acquire)
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(1));
        }
        if st.inner.paused.load(Ordering::Acquire)
            && sess.fade_ctrl.target() == FadeTarget::PauseFadeOut
        {
            if let Some(stream) = &sess._cpal_stream {
                let _ = stream.pause();
            }
            if let Some(native) = &sess.native_output {
                native.set_paused(true);
            }
        }
    }
}

pub(super) fn handle_resume(st: &mut CoordinatorState) {
    if let Some(sess) = &st.active {
        sess.fade_ctrl.request_play_fade_in();
        if let Some(stream) = &sess._cpal_stream {
            let _ = stream.play();
        }
        if let Some(native) = &sess.native_output {
            native.set_paused(false);
        }
    } else if let Some(rec) = st.saved_recovery.take() {
        st.inner.stopped.store(false, Ordering::SeqCst);
        st.inner.device_lost.store(false, Ordering::SeqCst);
        st.inner.clear_error_state();
        let src_channels = (rec.format.channels as u16).max(1);
        let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
        if let Some(fresh_cancel) = install_fresh_cancel_token(&st.inner)
            && let Ok(mut decoder) =
                reopen_origin_decoder(&st.inner, &rec.origin, None, &fresh_cancel)
        {
            if rec.resume_pos_ms > 0 {
                let _ = decoder.seek(Duration::from_millis(rec.resume_pos_ms));
            }
            let session_id = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
            match start_output_pipeline(
                &st.inner,
                decoder,
                PipelineSpec {
                    session_id,
                    pcm_rate: rec.pcm_rate,
                    out_channels: default_out_channels,
                    path: rec.path.clone(),
                    source_label: rec.source_label.clone(),
                    origin: rec.origin.clone(),
                    track_meta: rec.track_meta.clone(),
                    cancel_token: fresh_cancel,
                    format: rec.format.clone(),
                    duration_ms: rec.duration_ms,
                    start_paused: false,
                },
                &st.cmd_tx,
            ) {
                Ok(sess) => {
                    let new_out_rate =
                        st.inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                    let rescaled_frames =
                        ((rec.resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                    st.inner
                        .frames_rendered
                        .store(rescaled_frames, Ordering::SeqCst);
                    st.inner.paused.store(false, Ordering::SeqCst);
                    st.inner
                        .state_code
                        .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);
                    st.active = Some(sess);
                }
                Err(e) => {
                    st.saved_recovery = Some(rec);
                    st.inner.paused.store(true, Ordering::SeqCst);
                    st.inner.device_lost.store(true, Ordering::SeqCst);
                    if let Ok(mut code_lock) = st.inner.last_error_code.write() {
                        *code_lock = Some("DEVICE_LOST".to_string());
                    }
                    if let Ok(mut err_lock) = st.inner.last_error.write() {
                        *err_lock = Some(format!("Failed to resume output: {e}"));
                    }
                    st.inner
                        .state_code
                        .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
                }
            }
        } else {
            st.saved_recovery = Some(rec);
        }
    }
}

pub(super) fn handle_seek_ms(st: &mut CoordinatorState, was_ended: bool) {
    let req_ms = st.inner.seek_request_ms.load(Ordering::SeqCst);
    let is_paused = st.inner.paused.load(Ordering::SeqCst);
    let is_ended = was_ended
        || st.inner.state_code.load(Ordering::SeqCst) == PlaybackLifecycleState::Ended as i32;

    if let Some(ref mut sess) = st.active {
        let cur_active = st.inner.dual_deck.active_idx();
        if let Ok(mg) = st.inner.dual_deck.deck_meta[cur_active].read()
            && let Some(ref snap) = *mg
        {
            sess.path = snap.path.clone();
            sess.source_label = snap.source_label.clone();
            sess.origin = snap.origin.clone();
            sess.format = snap.format.clone();
            sess.duration_ms = snap.duration_ms;
            sess.pcm_rate = snap.pcm_rate;
            sess.track_meta = patched_track_meta(snap);
            sess.eof_flag = Arc::clone(&st.inner.dual_deck.deck_eof_flags[cur_active]);
        }
        let decode_finished = st.inner.dual_deck.decode_entries[cur_active]
            .lock()
            .ok()
            .and_then(|g| {
                g.as_ref()
                    .and_then(|e| e.join_handle.as_ref().map(|h| h.is_finished()))
            })
            .or_else(|| sess.decode_handle.as_ref().map(|h| h.is_finished()))
            .unwrap_or(true);
        let output_finished = sess
            .virtual_handle
            .as_ref()
            .is_some_and(|h| h.is_finished())
            || matches!(
                sess.native_output,
                Some(NativeOutputSession::VirtualWire(ref h)) if h.is_finished()
            );
        if !is_paused && !is_ended && !decode_finished && !output_finished {
            let deadline = Instant::now() + Duration::from_millis(15);
            while !sess.fade_ctrl.is_fade_out_done()
                && sess.fade_ctrl.target() == FadeTarget::SeekFadeOut
                && !st.inner.stopped.load(Ordering::Acquire)
                && Instant::now() < deadline
            {
                thread::sleep(Duration::from_millis(1));
            }
        }
        if let Some(ref native) = sess.native_output {
            let _ = native.flush();
        }

        if is_ended || decode_finished || output_finished {
            let path = sess.path.clone();
            let source_label = sess.source_label.clone();
            let origin = sess.origin.clone();
            let format = sess.format.clone();
            let duration_ms = sess.duration_ms;
            let pcm_rate = sess.pcm_rate;
            let track_meta = sess.track_meta.clone();
            let src_channels = (format.channels as u16).max(1);
            let default_out_channels = if src_channels == 1 { 2 } else { src_channels };

            if let Some(mut prev) = st.active.take() {
                prev.fade_ctrl.mark_silent();
                let _ = prev.stop_and_join();
            }

            let Some(fresh_cancel) = install_fresh_cancel_token(&st.inner) else {
                st.inner.is_seeking.store(false, Ordering::SeqCst);
                return;
            };
            let refresh_handler = st.inner.stream_refresh_handler();
            match origin.open_decoder_with_refresh(&st.inner, fresh_cancel.clone(), refresh_handler)
            {
                Ok(mut decoder) => {
                    if fresh_cancel.is_cancelled() || st.inner.stopped.load(Ordering::SeqCst) {
                        st.inner.is_seeking.store(false, Ordering::SeqCst);
                        return;
                    }
                    if req_ms >= 0 {
                        let _ = decoder.seek(Duration::from_millis(req_ms as u64));
                    }
                    let session_id = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                    st.inner.seek_request_ms.store(-1, Ordering::SeqCst);

                    match start_output_pipeline(
                        &st.inner,
                        decoder,
                        PipelineSpec {
                            session_id,
                            pcm_rate,
                            out_channels: default_out_channels,
                            path,
                            source_label,
                            origin,
                            track_meta,
                            cancel_token: fresh_cancel,
                            format,
                            duration_ms,
                            start_paused: is_paused,
                        },
                        &st.cmd_tx,
                    ) {
                        Ok(new_sess) => {
                            let new_out_rate =
                                st.inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                            let target_ms = req_ms.max(0) as u128;
                            let rescaled_frames = (target_ms * new_out_rate / 1000) as u64;
                            st.inner
                                .frames_rendered
                                .store(rescaled_frames, Ordering::SeqCst);
                            let paused_now = st.inner.paused.load(Ordering::SeqCst);
                            let target_state = if paused_now {
                                PlaybackLifecycleState::Paused as i32
                            } else {
                                PlaybackLifecycleState::Playing as i32
                            };
                            st.inner.state_code.store(target_state, Ordering::SeqCst);
                            st.inner.is_seeking.store(false, Ordering::SeqCst);
                            st.active = Some(new_sess);
                        }
                        Err(e) => {
                            st.inner.is_seeking.store(false, Ordering::SeqCst);
                            record_playback_error(&st.inner, e.to_string());
                        }
                    }
                }
                Err(e) => {
                    st.inner.is_seeking.store(false, Ordering::SeqCst);
                    if !fresh_cancel.is_cancelled() && !st.inner.stopped.load(Ordering::SeqCst) {
                        record_playback_error(&st.inner, format!("Seek reopen error: {e}"));
                    }
                }
            }
        }
    }
}

pub(super) fn handle_retire_deck(st: &mut CoordinatorState, deck_idx: usize) {
    st.inner
        .dual_deck
        .retire_inactive_deck(deck_idx, &st.inner.reaper);
    let cur_active = st.inner.dual_deck.active_idx();
    if let Some(ref mut sess) = st.active {
        if let Ok(mg) = st.inner.dual_deck.deck_meta[cur_active].read()
            && let Some(ref snap) = *mg
        {
            sess.path = snap.path.clone();
            sess.source_label = snap.source_label.clone();
            sess.origin = snap.origin.clone();
            sess.format = snap.format.clone();
            sess.duration_ms = snap.duration_ms;
            sess.pcm_rate = snap.pcm_rate;
            sess.active_device_id = snap.active_device_id.clone();
            sess.track_meta = patched_track_meta(snap);
            sess.eof_flag = Arc::clone(&st.inner.dual_deck.deck_eof_flags[cur_active]);
        }
        if let Ok(eg) = st.inner.dual_deck.decode_entries[cur_active].lock()
            && let Some(ref entry) = *eg
        {
            sess.cancel_flag = Arc::clone(&entry.cancel_flag);
            sess.cancel_token = entry.cancel_token.clone();
        }
    }
}

pub(super) fn handle_trigger_auto_standby(st: &CoordinatorState) {
    if st.inner.stopped.load(Ordering::Relaxed) {
        return;
    }
    let sb = st.inner.dual_deck.standby_idx();
    if st.inner.dual_deck.deck_state(sb) != DeckState::Idle {
        return;
    }
    let next_opt = st
        .inner
        .queued_next_spec
        .write()
        .ok()
        .and_then(|mut g| g.take());
    st.inner.has_queued_next_spec.store(false, Ordering::SeqCst);
    if let Some((spec, label, track_meta)) = next_opt {
        if matches!(spec, StreamSourceSpec::ExternalBackend { .. }) {
            return;
        }
        let player = AudioPlayer {
            inner: Arc::clone(&st.inner),
            cmd_tx: st.cmd_tx.clone(),
        };
        let _ = player.prepare_standby_internal(
            PlayerOrigin::SourceSpec(spec),
            label,
            false,
            false,
            None,
            None,
            track_meta,
            true,
        );
    }
}
