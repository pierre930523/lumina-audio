//! Handlers for `ReopenForFormatChange` and `HotReloadSpec` coordinator commands.

use std::sync::atomic::Ordering;
use std::time::Duration;

use core_types::{AudioFormat, PlaybackLifecycleState, StreamSourceSpec};

use crate::decoder::source_opener::{
    open_decoder_for_source_spec_with_l2, source_spec_default_label,
};
use crate::engine::dsp_helpers::build_mismatch_callback;
use crate::engine::session::{
    PipelineSpec, install_fresh_cancel_token, reopen_origin_decoder, start_output_pipeline,
};
use crate::engine::types::build_l2_play_gate_probe;
use crate::engine::{PlayerOrigin, record_playback_error_with_code};
use crate::error::{CoreAudioError, DecoderError};

use super::{
    CoordinatorState, mark_faulted_with_fsm, mark_running_with_fsm, teardown_active_join_with_fsm,
    teardown_active_retiring_with_fsm,
};

pub(super) fn handle_reopen_for_format_change(
    st: &mut CoordinatorState,
    session_id: u64,
    new_format: AudioFormat,
    resume_pos_ms: u64,
) {
    if st.inner.current_session_id.load(Ordering::Relaxed) != session_id
        || st.inner.stopped.load(Ordering::Relaxed)
    {
        return;
    }
    let Some(ref prev) = st.active else {
        return;
    };
    let is_paused = st.inner.paused.load(Ordering::SeqCst);
    let path = prev.path.clone();
    let source_label = prev.source_label.clone();
    let origin = prev.origin.clone();
    let prev_track_meta = prev.track_meta.clone();
    prev.fade_ctrl.mark_silent();
    let reused = teardown_active_join_with_fsm(&mut st.fsm, &st.inner, &mut st.active, true);

    let Some(fresh_cancel) = install_fresh_cancel_token(&st.inner) else {
        return;
    };
    let mut decoder = match reopen_origin_decoder(&st.inner, &origin, reused, &fresh_cancel) {
        Ok(d) => d,
        Err(e) => {
            record_playback_error_with_code(
                &st.inner,
                format!("Format change reopen error: {e}"),
                Some("FORMAT_SWITCH_FAILED"),
                None,
            );
            return;
        }
    };
    if resume_pos_ms > 0 {
        let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
    }

    st.inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
    st.inner
        .format_mismatch_flag
        .store(false, Ordering::Release);
    let mut format = decoder.format().clone();
    // Honor detected mid-stream format overrides (e.g. SBR/PS rate or channel switch)
    // when the container header still reports the pre-change parameters.
    if new_format.sample_rate_hz >= 8_000 && new_format.sample_rate_hz != format.sample_rate_hz {
        format.sample_rate_hz = new_format.sample_rate_hz;
    }
    if new_format.channels > 0 && new_format.channels != format.channels {
        format.channels = new_format.channels;
    }
    if new_format.bit_depth > 0 && new_format.bit_depth != format.bit_depth {
        format.bit_depth = new_format.bit_depth;
    }
    format.is_dsd = new_format.is_dsd;
    let duration_ms = decoder
        .duration()
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let pcm_rate = if format.is_dsd {
        (format.sample_rate_hz / 8).max(44_100)
    } else {
        format.sample_rate_hz.max(8_000)
    };
    let src_channels = (format.channels as u16).max(1);
    let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
    let next_sid = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
    st.inner.duration_ms.store(duration_ms, Ordering::SeqCst);

    match start_output_pipeline(
        &st.inner,
        decoder,
        PipelineSpec {
            session_id: next_sid,
            pcm_rate,
            out_channels: default_out_channels,
            path,
            source_label,
            origin,
            track_meta: prev_track_meta,
            cancel_token: fresh_cancel,
            format,
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
            let target_state = if is_paused {
                PlaybackLifecycleState::Paused as i32
            } else {
                PlaybackLifecycleState::Playing as i32
            };
            st.inner.state_code.store(target_state, Ordering::SeqCst);
            st.active = Some(sess);
            mark_running_with_fsm(&mut st.fsm, &st.inner);
        }
        Err(e) => {
            mark_faulted_with_fsm(&mut st.fsm, &st.inner);
            record_playback_error_with_code(
                &st.inner,
                format!("Format change output reopen failed: {e}"),
                Some("FORMAT_SWITCH_FAILED"),
                None,
            );
        }
    }
}

pub(super) fn handle_hot_reload_spec(
    st: &mut CoordinatorState,
    session_id: u64,
    new_spec: StreamSourceSpec,
    resume_ms: u64,
) {
    if st.inner.current_session_id.load(Ordering::Relaxed) != session_id
        || st.inner.stopped.load(Ordering::Relaxed)
    {
        return;
    }
    let is_paused = st.inner.paused.load(Ordering::SeqCst);
    let source_label = st
        .active
        .as_ref()
        .map(|s| s.source_label.clone())
        .unwrap_or_else(|| source_spec_default_label(&new_spec));
    let prev_track_meta = st
        .active
        .as_ref()
        .and_then(|s| s.track_meta.clone())
        .or_else(|| {
            st.inner
                .active_track_metadata
                .read()
                .ok()
                .and_then(|g| g.clone())
        });
    if let Some(ref prev) = st.active {
        prev.fade_ctrl.mark_silent();
    }
    teardown_active_retiring_with_fsm(&mut st.fsm, &st.inner, &mut st.active, true, true);

    let Some(fresh_cancel) = install_fresh_cancel_token(&st.inner) else {
        return;
    };
    if let Ok(mut spec_lock) = st.inner.active_source_spec.write() {
        *spec_lock = Some(new_spec.clone());
    }
    let refresh_handler = st.inner.stream_refresh_handler();
    let mut decoder = match open_decoder_for_source_spec_with_l2(
        &new_spec,
        fresh_cancel.clone(),
        refresh_handler,
        st.inner.l2_cache_manager(),
        false,
        build_mismatch_callback(&st.inner, &new_spec),
        Some(build_l2_play_gate_probe(&st.inner)),
    ) {
        Ok(d) => d,
        Err(CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
            provider_id,
            status,
        })) => {
            record_playback_error_with_code(
                &st.inner,
                format!("Authentication required for {provider_id} (HTTP {status})"),
                Some("AUTH_REQUIRED"),
                Some(provider_id),
            );
            return;
        }
        Err(e) => {
            if !fresh_cancel.is_cancelled() && !st.inner.stopped.load(Ordering::SeqCst) {
                record_playback_error_with_code(
                    &st.inner,
                    format!("Stream hot-reload failed: {e}"),
                    Some("FORMAT_SWITCH_FAILED"),
                    None,
                );
            }
            return;
        }
    };
    if fresh_cancel.is_cancelled() || st.inner.stopped.load(Ordering::SeqCst) {
        return;
    }
    if resume_ms > 0 {
        let _ = decoder.seek(Duration::from_millis(resume_ms));
    }

    let new_origin = PlayerOrigin::SourceSpec(new_spec);
    let new_path = new_origin.display_path();
    if let Ok(mut rg_lock) = st.inner.track_replay_gain.write() {
        *rg_lock = new_origin
            .replay_gain_tags()
            .with_metadata_fallback(decoder.metadata());
    }
    st.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
    st.inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
    st.inner
        .format_mismatch_flag
        .store(false, Ordering::Release);
    st.inner.clear_error_state();

    let format = decoder.format().clone();
    let duration_ms = decoder
        .duration()
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let pcm_rate = if format.is_dsd {
        (format.sample_rate_hz / 8).max(44_100)
    } else {
        format.sample_rate_hz.max(8_000)
    };
    let src_channels = (format.channels as u16).max(1);
    let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
    let next_sid = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
    st.inner.duration_ms.store(duration_ms, Ordering::SeqCst);

    match start_output_pipeline(
        &st.inner,
        decoder,
        PipelineSpec {
            session_id: next_sid,
            pcm_rate,
            out_channels: default_out_channels,
            path: new_path,
            source_label,
            origin: new_origin,
            track_meta: prev_track_meta,
            cancel_token: fresh_cancel,
            format,
            duration_ms,
            start_paused: is_paused,
        },
        &st.cmd_tx,
    ) {
        Ok(sess) => {
            let new_out_rate = st.inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
            let rescaled_frames = ((resume_ms as u128) * new_out_rate / 1000) as u64;
            st.inner
                .frames_rendered
                .store(rescaled_frames, Ordering::SeqCst);
            let target_state = if is_paused {
                PlaybackLifecycleState::Paused as i32
            } else {
                PlaybackLifecycleState::Playing as i32
            };
            st.inner.state_code.store(target_state, Ordering::SeqCst);
            st.active = Some(sess);
        }
        Err(e) => record_playback_error_with_code(
            &st.inner,
            format!("Hot-reload output reopen failed: {e}"),
            Some("FORMAT_SWITCH_FAILED"),
            None,
        ),
    }
}
