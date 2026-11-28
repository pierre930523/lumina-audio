//! Hardware device hotplug, OS sleep/wake, and output reroute recovery handlers.

use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use core_types::PlaybackLifecycleState;

use crate::backend::DeviceEvent;
use crate::backend::device_manager::AudioDeviceManager;
use crate::engine::session::{
    CLOCK_SRC_UNINIT, PipelineSpec, device_removal_affects_session, install_fresh_cancel_token,
    reopen_origin_decoder, start_output_pipeline,
};
use crate::engine::{
    position_ms_from_inner, record_playback_error, record_playback_error_with_code,
};
use crate::error::CoreAudioError;

use super::loop_runner::notify_reroute_acks;
use super::{
    CoordinatorState, SavedRecoverySession, enter_opening_with_fsm, mark_faulted_with_fsm,
    mark_running_with_fsm, teardown_active_join_with_fsm,
};

pub(super) fn handle_hardware_device_event(st: &mut CoordinatorState, event: DeviceEvent) {
    match event {
        DeviceEvent::DefaultRenderChanged(_) => {
            AudioDeviceManager::invalidate_device_cache();
            st.inner
                .cached_clock_source
                .store(CLOCK_SRC_UNINIT, Ordering::Release);
            let following_default = st
                .inner
                .selected_output
                .read()
                .map(|g| g.0.is_none())
                .unwrap_or(true);
            let state = st.inner.state_code.load(Ordering::SeqCst);
            if following_default
                && st.active.is_some()
                && !st.inner.stopped.load(Ordering::SeqCst)
                && (state == PlaybackLifecycleState::Playing as i32
                    || state == PlaybackLifecycleState::Paused as i32)
            {
                let resume_pos_ms = position_ms_from_inner(&st.inner);
                let is_paused = st.inner.paused.load(Ordering::SeqCst);
                let mut prev = st.active.take().unwrap();
                let path = prev.path.clone();
                let source_label = prev.source_label.clone();
                let prev_origin = prev.origin.clone();
                let format = prev.format.clone();
                let duration_ms = prev.duration_ms;
                let pcm_rate = prev.pcm_rate;
                let prev_track_meta = prev.track_meta.clone();
                let src_channels = (format.channels as u16).max(1);
                let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
                let reused = prev.stop_and_join();

                if let Some(fresh_cancel) = install_fresh_cancel_token(&st.inner)
                    && let Ok(mut decoder) =
                        reopen_origin_decoder(&st.inner, &prev_origin, reused, &fresh_cancel)
                {
                    let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
                    let session_id = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                    match start_output_pipeline(
                        &st.inner,
                        decoder,
                        PipelineSpec {
                            session_id,
                            pcm_rate,
                            out_channels: default_out_channels,
                            path,
                            source_label,
                            origin: prev_origin,
                            track_meta: prev_track_meta,
                            cancel_token: fresh_cancel,
                            format,
                            duration_ms,
                            start_paused: is_paused,
                        },
                        &st.cmd_tx,
                    ) {
                        Ok(sess) => {
                            let new_out_rate =
                                st.inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                            let rescaled_frames =
                                ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                            st.inner
                                .frames_rendered
                                .store(rescaled_frames, Ordering::SeqCst);
                            st.active = Some(sess);
                        }
                        Err(e) => record_playback_error_with_code(
                            &st.inner,
                            format!("Default device reroute failed: {e}"),
                            Some("DEVICE_LOST"),
                            None,
                        ),
                    }
                }
            }
        }
        DeviceEvent::DeviceRemoved(device_id) => {
            AudioDeviceManager::invalidate_device_cache();
            st.inner
                .cached_clock_source
                .store(CLOCK_SRC_UNINIT, Ordering::Release);
            let affects = st
                .active
                .as_ref()
                .is_some_and(|s| device_removal_affects_session(&st.inner, s, &device_id));
            if affects && let Some(mut prev) = st.active.take() {
                let resume_pos_ms = position_ms_from_inner(&st.inner);
                let was_playing = !st.inner.paused.load(Ordering::SeqCst)
                    && st.inner.state_code.load(Ordering::SeqCst)
                        == PlaybackLifecycleState::Playing as i32;
                st.inner.device_lost.store(true, Ordering::SeqCst);
                st.inner.paused.store(true, Ordering::SeqCst);
                if let Ok(mut err_lock) = st.inner.last_error.write() {
                    *err_lock = Some(format!("Audio output device removed: {device_id}"));
                }
                if let Ok(mut code_lock) = st.inner.last_error_code.write() {
                    *code_lock = Some("DEVICE_LOST".to_string());
                }
                if let Ok(mut prov_lock) = st.inner.last_error_provider.write() {
                    *prov_lock = None;
                }
                st.inner
                    .state_code
                    .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
                st.saved_recovery = Some(SavedRecoverySession {
                    path: prev.path.clone(),
                    source_label: prev.source_label.clone(),
                    origin: prev.origin.clone(),
                    format: prev.format.clone(),
                    duration_ms: prev.duration_ms,
                    pcm_rate: prev.pcm_rate,
                    resume_pos_ms,
                    was_playing,
                    from_suspend: false,
                    track_meta: prev.track_meta.clone(),
                });
                prev.fade_ctrl.mark_silent();
                let _ = prev.stop_and_join();
                mark_faulted_with_fsm(&mut st.fsm, &st.inner);
                if let Ok(mut af) = st.inner.active_fade.write() {
                    *af = None;
                }
            }
        }
        DeviceEvent::DeviceAdded(_) => {
            AudioDeviceManager::invalidate_device_cache();
            st.inner
                .cached_clock_source
                .store(CLOCK_SRC_UNINIT, Ordering::Release);
            if !st.inner.headless {
                let _ = AudioDeviceManager::list_devices_with_meta_fresh();
            }
            // Keep saved_recovery intact so RerouteOutput or Resume recovers at saved_pos cleanly.
        }
        DeviceEvent::SystemSuspend => {
            if let Some(mut prev) = st.active.take() {
                let resume_pos_ms = position_ms_from_inner(&st.inner);
                let was_playing = !st.inner.paused.load(Ordering::SeqCst)
                    && st.inner.state_code.load(Ordering::SeqCst)
                        == PlaybackLifecycleState::Playing as i32;
                if was_playing {
                    prev.fade_ctrl.request_pause_fade_out();
                    let deadline = Instant::now() + Duration::from_millis(20);
                    while !prev.fade_ctrl.is_fade_out_done() && Instant::now() < deadline {
                        thread::sleep(Duration::from_millis(1));
                    }
                }
                st.inner.paused.store(true, Ordering::SeqCst);
                st.inner
                    .state_code
                    .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
                st.saved_recovery = Some(SavedRecoverySession {
                    path: prev.path.clone(),
                    source_label: prev.source_label.clone(),
                    origin: prev.origin.clone(),
                    format: prev.format.clone(),
                    duration_ms: prev.duration_ms,
                    pcm_rate: prev.pcm_rate,
                    resume_pos_ms,
                    was_playing,
                    from_suspend: true,
                    track_meta: prev.track_meta.clone(),
                });
                let _ = prev.stop_and_join();
                if let Ok(mut af) = st.inner.active_fade.write() {
                    *af = None;
                }
            }
        }
        DeviceEvent::SystemResume => {
            AudioDeviceManager::invalidate_device_cache();
            st.inner
                .cached_clock_source
                .store(CLOCK_SRC_UNINIT, Ordering::Release);
            if !st.inner.headless {
                let _ = AudioDeviceManager::list_devices_with_meta_fresh();
            }
            if st.active.is_none()
                && !st.inner.stopped.load(Ordering::SeqCst)
                && let Some(rec) = st.saved_recovery.take()
                && rec.from_suspend
            {
                let resume_pos_ms = rec.resume_pos_ms;
                let start_paused = !rec.was_playing;
                let src_channels = (rec.format.channels as u16).max(1);
                let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
                let reopen_result = install_fresh_cancel_token(&st.inner).and_then(|cancel| {
                    reopen_origin_decoder(&st.inner, &rec.origin, None, &cancel)
                        .ok()
                        .map(|dec| (cancel, dec))
                });
                if let Some((fresh_cancel, mut decoder)) = reopen_result {
                    if resume_pos_ms > 0 {
                        let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
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
                            start_paused,
                        },
                        &st.cmd_tx,
                    ) {
                        Ok(sess) => {
                            let new_out_rate =
                                st.inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                            let rescaled_frames =
                                ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                            st.inner
                                .frames_rendered
                                .store(rescaled_frames, Ordering::SeqCst);
                            st.inner.device_lost.store(false, Ordering::SeqCst);
                            st.inner.clear_error_state();
                            st.inner.paused.store(start_paused, Ordering::SeqCst);
                            let target_state = if start_paused {
                                PlaybackLifecycleState::Paused as i32
                            } else {
                                PlaybackLifecycleState::Playing as i32
                            };
                            st.inner.state_code.store(target_state, Ordering::SeqCst);
                            st.active = Some(sess);
                        }
                        Err(e) => {
                            tracing::warn!(
                                "Audio output resume after sleep unavailable (safe pause): {e}"
                            );
                            st.inner.device_lost.store(true, Ordering::SeqCst);
                            st.inner.paused.store(true, Ordering::SeqCst);
                            if let Ok(mut code_lock) = st.inner.last_error_code.write() {
                                *code_lock = Some("DEVICE_LOST".to_string());
                            }
                            if let Ok(mut err_lock) = st.inner.last_error.write() {
                                *err_lock =
                                    Some(format!("Audio device unavailable after wake: {e}"));
                            }
                            st.inner
                                .state_code
                                .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
                            st.saved_recovery = Some(rec);
                        }
                    }
                } else {
                    st.saved_recovery = Some(rec);
                }
            }
        }
    }
}

pub(super) fn handle_reroute_output(
    st: &mut CoordinatorState,
    ack_tx: mpsc::SyncSender<Result<(), CoreAudioError>>,
    extra_reroute_acks: &mut Vec<mpsc::SyncSender<Result<(), CoreAudioError>>>,
    recover_device_lost: bool,
) {
    let state = st.inner.state_code.load(Ordering::SeqCst);
    let was_lost = recover_device_lost || st.inner.device_lost.load(Ordering::Acquire);
    let can_recover_active = st.active.is_some()
        && ((!st.inner.stopped.load(Ordering::SeqCst)
            && (state == PlaybackLifecycleState::Playing as i32
                || state == PlaybackLifecycleState::Paused as i32))
            || (was_lost
                && (state == PlaybackLifecycleState::Paused as i32
                    || state == PlaybackLifecycleState::Error as i32)));
    let can_recover_saved = st.active.is_none()
        && st.saved_recovery.is_some()
        && (was_lost
            || state == PlaybackLifecycleState::Paused as i32
            || state == PlaybackLifecycleState::Error as i32);

    if !can_recover_active && !can_recover_saved {
        notify_reroute_acks(ack_tx, extra_reroute_acks, Ok(()));
        return;
    }

    let (
        path,
        source_label,
        prev_origin,
        format,
        duration_ms,
        pcm_rate,
        resume_pos_ms,
        is_paused,
        reused,
        prev_track_meta,
    ) = if can_recover_active {
        let resume_pos_ms = position_ms_from_inner(&st.inner);
        let is_paused =
            st.inner.paused.load(Ordering::SeqCst) && state != PlaybackLifecycleState::Error as i32;
        let (path, source_label, prev_origin, format, duration_ms, pcm_rate, prev_track_meta) = {
            let prev = st.active.as_ref().unwrap();
            (
                prev.path.clone(),
                prev.source_label.clone(),
                prev.origin.clone(),
                prev.format.clone(),
                prev.duration_ms,
                prev.pcm_rate,
                prev.track_meta.clone(),
            )
        };
        let reused = teardown_active_join_with_fsm(&mut st.fsm, &st.inner, &mut st.active, true);
        (
            path,
            source_label,
            prev_origin,
            format,
            duration_ms,
            pcm_rate,
            resume_pos_ms,
            is_paused,
            reused,
            prev_track_meta,
        )
    } else {
        let rec = st.saved_recovery.take().unwrap();
        let is_paused = st.inner.paused.load(Ordering::SeqCst) && !rec.was_playing;
        (
            rec.path,
            rec.source_label,
            rec.origin,
            rec.format,
            rec.duration_ms,
            rec.pcm_rate,
            rec.resume_pos_ms,
            is_paused,
            None,
            rec.track_meta,
        )
    };

    if was_lost || state == PlaybackLifecycleState::Error as i32 {
        st.inner.stopped.store(false, Ordering::SeqCst);
        st.inner.device_lost.store(false, Ordering::SeqCst);
        st.inner.clear_error_state();
    }

    let src_channels = (format.channels as u16).max(1);
    let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
    let Some(fresh_cancel) = install_fresh_cancel_token(&st.inner) else {
        notify_reroute_acks(ack_tx, extra_reroute_acks, Ok(()));
        return;
    };
    let Ok(mut decoder) = reopen_origin_decoder(&st.inner, &prev_origin, reused, &fresh_cancel)
    else {
        notify_reroute_acks(ack_tx, extra_reroute_acks, Ok(()));
        return;
    };

    let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
    let session_id = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;

    enter_opening_with_fsm(&mut st.fsm, &st.inner);
    match start_output_pipeline(
        &st.inner,
        decoder,
        PipelineSpec {
            session_id,
            pcm_rate,
            out_channels: default_out_channels,
            path: path.clone(),
            source_label: source_label.clone(),
            origin: prev_origin.clone(),
            track_meta: prev_track_meta.clone(),
            cancel_token: fresh_cancel,
            format: format.clone(),
            duration_ms,
            start_paused: is_paused,
        },
        &st.cmd_tx,
    ) {
        Ok(sess) => {
            let new_out_rate = st.inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
            let rescaled_frames = ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
            st.inner
                .frames_rendered
                .store(rescaled_frames, Ordering::SeqCst);
            st.inner.paused.store(is_paused, Ordering::SeqCst);
            let target_state = if is_paused {
                PlaybackLifecycleState::Paused as i32
            } else {
                PlaybackLifecycleState::Playing as i32
            };
            st.inner.state_code.store(target_state, Ordering::SeqCst);
            st.saved_recovery = None;
            st.active = Some(sess);
            mark_running_with_fsm(&mut st.fsm, &st.inner);
            notify_reroute_acks(ack_tx, extra_reroute_acks, Ok(()));
        }
        Err(e) => {
            mark_faulted_with_fsm(&mut st.fsm, &st.inner);
            st.saved_recovery = Some(SavedRecoverySession {
                path,
                source_label,
                origin: prev_origin,
                format,
                duration_ms,
                pcm_rate,
                resume_pos_ms,
                was_playing: !is_paused,
                from_suspend: false,
                track_meta: prev_track_meta,
            });
            record_playback_error(&st.inner, e.to_string());
            notify_reroute_acks(ack_tx, extra_reroute_acks, Err(e));
        }
    }
}
