//! Seek coordination, idle pause reclamation, and EOF waiting helpers for decode workers.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use core_types::PlaybackLifecycleState;
use tokio_util::sync::CancellationToken;

use crate::decoder::pcm::AudioDecoder;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::{
    DEFAULT_IDLE_RECLAIM_THRESHOLD, PlayerInner, record_playback_error,
    record_playback_error_with_code,
};
use crate::error::DecoderError;
use crate::pipeline::fade::AudioFadeControl;
use crate::pipeline::ring_buffer::Producer;
use crate::streaming::drop_idle_http_connections;

/// Seek inside a running decode thread: drop everything already queued in the ring
/// (the output side discards pre-flush data on its next pop), move the decoder, and
/// re-pin the playback clock to the target so frames popped before the flush don't skew it.
#[allow(dead_code)]
pub(crate) fn flush_ring_and_seek<T: Copy>(
    decoder: &mut dyn AudioDecoder,
    producer: &mut Producer<T>,
    inner: &PlayerInner,
    target_ms: u64,
) {
    producer.request_flush();
    producer.sync_epoch();
    if let Err(e) = decoder.seek(Duration::from_millis(target_ms)) {
        tracing::warn!("Decoder seek to {target_ms} ms failed: {e}");
    }
    let rate = inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
    inner
        .frames_rendered
        .store(((target_ms as u128) * rate / 1000) as u64, Ordering::SeqCst);
}

pub(crate) fn maybe_reclaim_idle_memory(
    inner: &PlayerInner,
    decoder: &mut dyn AudioDecoder,
    paused_since: &mut Option<Instant>,
    idle_reclaimed: &mut bool,
) {
    if inner.paused.load(Ordering::Relaxed) {
        let started = *paused_since.get_or_insert_with(Instant::now);
        if !*idle_reclaimed {
            let threshold = inner
                .idle_reclaim_threshold
                .read()
                .map(|g| *g)
                .unwrap_or(DEFAULT_IDLE_RECLAIM_THRESHOLD);
            if started.elapsed() >= threshold {
                let freed = decoder.reclaim_idle_memory();
                drop_idle_http_connections();
                *idle_reclaimed = true;
                inner.idle_reclaim_count.fetch_add(1, Ordering::Relaxed);
                tracing::info!("Idle pause memory reclamation executed (freed {freed} bytes)");
            }
        }
    } else {
        *paused_since = None;
        *idle_reclaimed = false;
    }
}

/// Called when the decoder hits end of stream. The buffered tail may still be playing, so
/// keep the thread (and decoder) alive until a seek, a queued next track, cancel or stop.
/// Returns `true` if decoding should continue (seek or queued track), `false` to exit.
pub(crate) fn wait_at_eof(
    inner: &PlayerInner,
    decoder: &mut dyn AudioDecoder,
    cancel_flag: &AtomicBool,
    cancel_token: &CancellationToken,
    eof_flag: &AtomicBool,
    paused_since: &mut Option<Instant>,
    idle_reclaimed: &mut bool,
) -> bool {
    eof_flag.store(true, Ordering::SeqCst);
    loop {
        if cancel_flag.load(Ordering::Relaxed)
            || cancel_token.is_cancelled()
            || inner.stopped.load(Ordering::Relaxed)
            || inner.device_lost.load(Ordering::Acquire)
        {
            return false;
        }
        // Output finished draining the tail: the coordinator owns any later seek (it
        // restarts the pipeline), so this thread is done.
        let state = inner.state_code.load(Ordering::SeqCst);
        if state != PlaybackLifecycleState::Playing as i32
            && state != PlaybackLifecycleState::Paused as i32
            && state != PlaybackLifecycleState::Seeking as i32
        {
            return false;
        }
        maybe_reclaim_idle_memory(inner, decoder, paused_since, idle_reclaimed);
        let has_next = inner
            .queued_next
            .read()
            .map(|g| g.is_some())
            .unwrap_or(false);
        if inner.seek_request_ms.load(Ordering::SeqCst) >= 0 || has_next {
            eof_flag.store(false, Ordering::SeqCst);
            return true;
        }
        thread::sleep(Duration::from_millis(2));
    }
}

pub(crate) fn is_fatal_seek_io_error(err: &DecoderError) -> bool {
    match err {
        DecoderError::Io(io_err) => io_err.kind() != std::io::ErrorKind::Unsupported,
        _ => {
            let msg = err.to_string();
            msg.contains("HTTP ")
                && !msg.contains("unsupported on unseekable HTTP stream")
                && !msg.contains("Backward seek past retained buffer on non-range HTTP stream")
        }
    }
}

pub(super) enum SeekOutcome {
    Done,
    ContinueLoop,
    ReturnDecoder,
    Abort,
}

#[allow(clippy::too_many_arguments)]
pub(super) fn handle_seek_request<T: Copy, F: FnOnce()>(
    decoder: &mut dyn AudioDecoder,
    producer: &mut Producer<T>,
    inner: &PlayerInner,
    cancel_flag: &AtomicBool,
    cancel_token: &CancellationToken,
    eof_flag: &AtomicBool,
    fade_ctrl: &AudioFadeControl,
    session_id: u64,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
    target_ms: u64,
    log_prefix: &str,
    reset_stages: F,
) -> SeekOutcome {
    let seek_ep = inner.seek_epoch.load(Ordering::Acquire);
    // 1. Start decoder seek immediately in parallel with the callback's 10 ms fade-out.
    if let Err(e) = decoder.seek(Duration::from_millis(target_ms)) {
        if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
            return SeekOutcome::ReturnDecoder;
        }
        if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
            return SeekOutcome::Abort;
        }
        match e {
            DecoderError::StreamFormatChanged(new_spec) => {
                fade_ctrl.notify_seek_ready(seek_ep, inner.paused.load(Ordering::Acquire));
                inner.is_seeking.store(false, Ordering::SeqCst);
                let _ = cmd_tx.send(PlayerCommand::HotReloadSpec {
                    session_id,
                    new_spec: *new_spec,
                    resume_ms: target_ms,
                });
                return SeekOutcome::Abort;
            }
            DecoderError::StreamAuthRequired {
                provider_id,
                status,
            } => {
                fade_ctrl.notify_seek_ready(seek_ep, true);
                inner.is_seeking.store(false, Ordering::SeqCst);
                record_playback_error_with_code(
                    inner,
                    format!("Authentication required for {provider_id} (HTTP {status})"),
                    Some("AUTH_REQUIRED"),
                    Some(provider_id),
                );
                eof_flag.store(true, Ordering::SeqCst);
                return SeekOutcome::Abort;
            }
            other => {
                tracing::warn!("{log_prefix} to {target_ms} ms failed: {other}");
                if is_fatal_seek_io_error(&other) {
                    fade_ctrl.notify_seek_ready(seek_ep, true);
                    inner.is_seeking.store(false, Ordering::SeqCst);
                    record_playback_error(inner, format!("Seek error: {other}"));
                    eof_flag.store(true, Ordering::SeqCst);
                    return SeekOutcome::Abort;
                }
            }
        }
    }
    if inner.seek_request_ms.load(Ordering::Acquire) >= 0 {
        return SeekOutcome::ContinueLoop;
    }
    // 2. Bounded wait (<= 15 ms) for callback fade-out to reach 0 before flushing the ring.
    if !inner.paused.load(Ordering::Acquire) && !fade_ctrl.is_fade_out_done() {
        let deadline = Instant::now() + Duration::from_millis(15);
        while !fade_ctrl.is_fade_out_done()
            && !cancel_flag.load(Ordering::Relaxed)
            && !cancel_token.is_cancelled()
            && !inner.stopped.load(Ordering::Relaxed)
            && !inner.device_lost.load(Ordering::Acquire)
            && !inner.paused.load(Ordering::Acquire)
            && inner.seek_request_ms.load(Ordering::Acquire) < 0
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(1));
        }
    }
    if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
        return SeekOutcome::ReturnDecoder;
    }
    if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
        return SeekOutcome::Abort;
    }
    if inner.seek_request_ms.load(Ordering::Acquire) >= 0 {
        return SeekOutcome::ContinueLoop;
    }
    // 3. Flush ring epoch, reset packer/framer/DSP/verification, pin clock, release seek fade gate.
    producer.request_flush();
    producer.sync_epoch();
    reset_stages();
    inner.buffered_ms.store(0, Ordering::Relaxed);
    let rate = inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
    inner
        .frames_rendered
        .store(((target_ms as u128) * rate / 1000) as u64, Ordering::SeqCst);
    let is_paused_now = inner.paused.load(Ordering::Acquire);
    fade_ctrl.notify_seek_ready(seek_ep, is_paused_now);
    inner.is_seeking.store(false, Ordering::SeqCst);
    let target_state = if is_paused_now {
        PlaybackLifecycleState::Paused as i32
    } else {
        PlaybackLifecycleState::Playing as i32
    };
    inner.state_code.store(target_state, Ordering::SeqCst);
    SeekOutcome::Done
}
