//! Handlers for `ApplyLatestStart` and `FormatSwitchNext` coordinator commands.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use core_types::{DeckTrackMetadata, PlaybackLifecycleState};
use tokio_util::sync::CancellationToken;

use crate::decoder::pcm::AudioDecoder;
use crate::engine::session::{PipelineSpec, start_output_pipeline, try_hot_swap_active_session};
use crate::engine::{
    PlayerOrigin, TrackReplayGainTags, record_playback_error, record_playback_error_with_code,
};
use crate::error::CoreAudioError;

use super::loop_runner::drain_available_commands;
use super::{
    CoordinatorState, PendingStart, PlayerCommand, enter_opening_with_fsm, mark_faulted_with_fsm,
    mark_running_with_fsm, teardown_active_retiring_with_fsm,
};

pub(super) fn handle_apply_latest_start(st: &mut CoordinatorState) {
    let Some(PendingStart {
        session_id,
        mut decoder,
        path,
        source_label,
        origin,
        track_meta,
        cancel_token,
        ack_tx,
    }) = st.inner.latest_start.lock().ok().and_then(|mut g| g.take())
    else {
        return;
    };
    st.saved_recovery = None;
    if cancel_token.is_cancelled()
        || st.inner.stopped.load(Ordering::SeqCst)
        || st.inner.current_session_id.load(Ordering::Acquire) != session_id
    {
        let _ = ack_tx.send(Ok(()));
        return;
    }

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

    st.inner.duration_ms.store(duration_ms, Ordering::SeqCst);
    let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
    // ApplyLatestStart only dispatches for explicit play/skip requests; never inherit a stale
    // paused flag from a racing/prior session.
    st.inner.paused.store(false, Ordering::SeqCst);
    let start_paused = false;

    let pipeline_spec = PipelineSpec {
        session_id,
        pcm_rate,
        out_channels: default_out_channels,
        path,
        source_label,
        origin,
        track_meta,
        cancel_token: cancel_token.clone(),
        format,
        duration_ms,
        start_paused,
    };

    // Try lock-free zero-reopen hot-swap onto the existing live output session first.
    if let Some(ref mut live_sess) = st.active {
        match try_hot_swap_active_session(&st.inner, live_sess, decoder, &pipeline_spec, &st.cmd_tx)
        {
            Ok(Ok(())) => {
                let _ = ack_tx.send(Ok(()));
                return;
            }
            Ok(Err(returned_decoder)) => {
                decoder = returned_decoder;
            }
            Err(e) => {
                record_playback_error(&st.inner, e.to_string());
                let _ = ack_tx.send(Err(e));
                return;
            }
        }
        // Format/mode/device genuinely changed: enforce explicit FSM teardown +
        // post-release guard delay before reopening.
        teardown_active_retiring_with_fsm(&mut st.fsm, &st.inner, &mut st.active, true, true);
    }

    if cancel_token.is_cancelled()
        || st.inner.stopped.load(Ordering::SeqCst)
        || st.inner.current_session_id.load(Ordering::Acquire) != session_id
    {
        let _ = ack_tx.send(Ok(()));
        return;
    }

    enter_opening_with_fsm(&mut st.fsm, &st.inner);
    match start_output_pipeline(&st.inner, decoder, pipeline_spec, &st.cmd_tx) {
        Ok(sess) => {
            st.active = Some(sess);
            mark_running_with_fsm(&mut st.fsm, &st.inner);
            let _ = ack_tx.send(Ok(()));
        }
        Err(e) => {
            mark_faulted_with_fsm(&mut st.fsm, &st.inner);
            record_playback_error(&st.inner, e.to_string());
            let _ = ack_tx.send(Err(e));
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn handle_format_switch_next(
    st: &mut CoordinatorState,
    cmd_rx: &mpsc::Receiver<PlayerCommand>,
    pending: &mut VecDeque<PlayerCommand>,
    extra_reroute_acks: &mut Vec<mpsc::SyncSender<Result<(), CoreAudioError>>>,
    session_id: u64,
    decoder: Box<dyn AudioDecoder>,
    path: PathBuf,
    source_label: String,
    origin: PlayerOrigin,
    track_meta: Option<DeckTrackMetadata>,
    cancel_token: CancellationToken,
    rg_tags: TrackReplayGainTags,
) {
    if st.inner.current_session_id.load(Ordering::Relaxed) != session_id
        || st.inner.stopped.load(Ordering::Relaxed)
        || cancel_token.is_cancelled()
    {
        return;
    }
    // Wait briefly for trailing frames of Track A to finish draining cleanly,
    // aborting immediately if any new control command arrives (no 600ms head-of-line stall).
    if let Some(ref prev) = st.active {
        let wait_start = Instant::now();
        while prev.eof_flag.load(Ordering::SeqCst)
            && st.inner.state_code.load(Ordering::SeqCst) == PlaybackLifecycleState::Playing as i32
            && !cancel_token.is_cancelled()
            && wait_start.elapsed() < Duration::from_millis(600)
        {
            drain_available_commands(cmd_rx, pending, extra_reroute_acks, &st.inner);
            if !pending.is_empty() {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
    if let Some(ref prev) = st.active {
        prev.fade_ctrl.mark_silent();
    }
    // Do NOT cancel `prev.cancel_token` because `cancel_token` is its child token.
    teardown_active_retiring_with_fsm(&mut st.fsm, &st.inner, &mut st.active, false, true);
    if st.inner.stopped.load(Ordering::SeqCst) || cancel_token.is_cancelled() {
        return;
    }
    {
        let _ep_guard = st
            .inner
            .epoch_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if st.inner.stopped.load(Ordering::SeqCst) {
            return;
        }
        if let Ok(mut guard) = st.inner.active_cancel.write() {
            *guard = cancel_token.clone();
        }
    }

    st.inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
    st.inner.playback_epoch.fetch_add(1, Ordering::SeqCst);
    let effective_rg = rg_tags.with_metadata_fallback(decoder.metadata());
    if let Ok(mut rg_lock) = st.inner.track_replay_gain.write() {
        *rg_lock = effective_rg;
    }
    st.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
    let next_sid = st.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
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
    st.inner.duration_ms.store(duration_ms, Ordering::SeqCst);
    st.inner.frames_rendered.store(0, Ordering::SeqCst);
    st.inner.nonzero_output_frames.store(0, Ordering::SeqCst);
    st.inner
        .state_code
        .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);

    enter_opening_with_fsm(&mut st.fsm, &st.inner);
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
            track_meta,
            cancel_token,
            format,
            duration_ms,
            start_paused: false,
        },
        &st.cmd_tx,
    ) {
        Ok(sess) => {
            st.active = Some(sess);
            mark_running_with_fsm(&mut st.fsm, &st.inner);
        }
        Err(e) => {
            mark_faulted_with_fsm(&mut st.fsm, &st.inner);
            record_playback_error_with_code(
                &st.inner,
                e.to_string(),
                Some("FORMAT_SWITCH_FAILED"),
                None,
            );
        }
    }
}
