//! Gapless transition, format-switch handoff, and decode error handling.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::Duration;

use core_types::{AudioDeviceCapabilities, UnifiedAudioFormat};
use tokio_util::sync::CancellationToken;

use crate::backend::device_manager::{AudioFormatManager, NegotiatedFormat};
use crate::decoder::pcm::AudioDecoder;
use crate::decoder::source_opener::open_decoder_for_stream_with_token;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::{
    PlayerInner, PlayerOrigin, TrackReplayGainTags, position_ms_from_inner, record_playback_error,
    record_playback_error_with_code,
};
use crate::error::DecoderError;
use crate::verification::AudioVerificationEngine;

pub(super) struct GaplessTransition {
    pub(super) decoder: Box<dyn AudioDecoder>,
    pub(super) path: PathBuf,
    pub(super) label: String,
    pub(super) unified: UnifiedAudioFormat,
    pub(super) negotiated: NegotiatedFormat,
}

pub(super) enum NextTrackOutcome {
    NoneOrFailed,
    Gapless(GaplessTransition),
    ReturnDecoder,
    Abort,
}

#[allow(clippy::too_many_arguments)]
pub(super) fn try_open_gapless_or_switch(
    curr_unified: &UnifiedAudioFormat,
    curr_neg: &NegotiatedFormat,
    curr_caps: &AudioDeviceCapabilities,
    inner: &PlayerInner,
    verification: Option<&AudioVerificationEngine>,
    clear_ver_meta_if_none: bool,
    cancel_flag: &AtomicBool,
    cancel_token: &CancellationToken,
    eof_flag: &AtomicBool,
    session_id: u64,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
) -> NextTrackOutcome {
    let Some((next_stream, next_label)) = inner.queued_next.write().ok().and_then(|mut g| g.take())
    else {
        return NextTrackOutcome::NoneOrFailed;
    };

    let next_path = next_stream.display_path();
    let next_cancel = cancel_token.child_token();
    let Ok(next_dec) = open_decoder_for_stream_with_token(
        &next_stream,
        next_cancel.clone(),
        Duration::from_secs(10),
    ) else {
        return NextTrackOutcome::NoneOrFailed;
    };

    if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
        return NextTrackOutcome::ReturnDecoder;
    }
    if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
        return NextTrackOutcome::Abort;
    }

    let next_rg =
        TrackReplayGainTags::from_stream(&next_stream).with_metadata_fallback(next_dec.metadata());
    let next_unified = next_dec.unified_format();
    let policy = inner.policy.read().map(|g| g.clone()).unwrap_or_default();
    if let Some(next_neg) = AudioFormatManager::can_gapless_transition(
        curr_unified,
        curr_neg,
        &next_unified,
        curr_caps,
        &policy,
    ) {
        let next_dur = next_dec
            .duration()
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        inner.duration_ms.store(next_dur, Ordering::SeqCst);
        inner.frames_rendered.store(0, Ordering::SeqCst);
        inner.nonzero_output_frames.store(0, Ordering::SeqCst);
        inner.seek_epoch.fetch_add(1, Ordering::SeqCst);
        inner.playback_epoch.fetch_add(1, Ordering::SeqCst);
        if let Some(v) = verification {
            v.reset_streams();
        }
        inner.gapless_transitions.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
            *rg_lock = next_rg;
        }
        inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut meta_lock) = inner.active_meta.write()
            && let Some(ref mut meta) = *meta_lock
        {
            meta.path = next_path.clone();
            meta.source_label = next_label.clone();
            meta.format = next_dec.format().clone();
            meta.duration_ms = next_dur;
            meta.track_meta = None;
        }
        if let Ok(mut tm_lock) = inner.active_track_metadata.write() {
            *tm_lock = None;
        }
        if let Some(v) = verification {
            if let Some(m) = next_dec.metadata() {
                v.set_source_metadata(m.title.clone(), m.artist.clone(), m.album.clone());
            } else if clear_ver_meta_if_none {
                v.set_source_metadata(None, None, None);
            }
        }
        return NextTrackOutcome::Gapless(GaplessTransition {
            decoder: next_dec,
            path: next_path,
            label: next_label,
            unified: next_unified,
            negotiated: next_neg,
        });
    }

    // Format changed: drain Track A, then re-open output backend for Track B
    eof_flag.store(true, Ordering::SeqCst);
    let _ = cmd_tx.send(PlayerCommand::FormatSwitchNext {
        session_id,
        decoder: next_dec,
        path: next_path,
        source_label: next_label,
        origin: PlayerOrigin::Legacy(next_stream),
        track_meta: None,
        cancel_token: next_cancel,
        rg_tags: next_rg,
    });
    NextTrackOutcome::Abort
}

#[allow(clippy::too_many_arguments)]
pub(super) fn handle_decode_error(
    err: DecoderError,
    inner: &PlayerInner,
    cancel_flag: &AtomicBool,
    cancel_token: &CancellationToken,
    eof_flag: &AtomicBool,
    session_id: u64,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
    log_label: &str,
) -> bool {
    if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
        return true;
    }
    if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
        return false;
    }
    match err {
        DecoderError::StreamFormatChanged(new_spec) => {
            let resume_ms = position_ms_from_inner(inner);
            let _ = cmd_tx.send(PlayerCommand::HotReloadSpec {
                session_id,
                new_spec: *new_spec,
                resume_ms,
            });
            false
        }
        DecoderError::StreamAuthRequired {
            provider_id,
            status,
        } => {
            record_playback_error_with_code(
                inner,
                format!("Authentication required for {provider_id} (HTTP {status})"),
                Some("AUTH_REQUIRED"),
                Some(provider_id),
            );
            eof_flag.store(true, Ordering::SeqCst);
            false
        }
        other => {
            tracing::error!("{log_label}: {other}");
            record_playback_error(inner, format!("Decode error: {other}"));
            eof_flag.store(true, Ordering::SeqCst);
            false
        }
    }
}
