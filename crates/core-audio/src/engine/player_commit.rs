//! Committing a pre-opened decoder into the active playback coordinator slot.

use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::time::Duration;

use core_types::{DeckState, DeckTrackMetadata, PlaybackLifecycleState};
use tokio_util::sync::CancellationToken;

use crate::decoder::pcm::AudioDecoder;
use crate::decoder::source_opener::source_spec_default_label;
use crate::engine::coordinator::{PendingStart, PlayerCommand};
use crate::engine::{ActiveTrackMeta, AudioPlayer, PlayerOrigin};
use crate::error::{BackendError, CoreAudioError};

impl AudioPlayer {
    pub(super) fn commit_opened_decoder(
        &self,
        origin: PlayerOrigin,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        cancel: CancellationToken,
        expected_play_epoch: Option<u64>,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        let label = if source_label.trim().is_empty() {
            match &origin {
                PlayerOrigin::Legacy(_) => "Stream".to_string(),
                PlayerOrigin::SourceSpec(spec) => source_spec_default_label(spec),
            }
        } else {
            source_label.to_string()
        };
        let path_buf = origin.display_path();
        let format = decoder.format().clone();
        let duration_ms = decoder
            .duration()
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let effective_track_meta = track_meta.map(|mut m| {
            if duration_ms > 0 {
                m.duration_ms = duration_ms;
            }
            m
        });

        if cancel.is_cancelled() {
            return Ok(());
        }
        if let Some(expected) = expected_play_epoch
            && self.inner.play_epoch.load(Ordering::SeqCst) != expected
        {
            return Ok(());
        }

        // Resolve preview target OUTSIDE `epoch_lock` using existing active metadata or TTL-cached
        // capabilities so we never run COM/ASIO device probing while holding any control lock.
        let (preview_backend, preview_device) = self
            .inner
            .active_meta
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|m| (m.backend, m.device_name.clone())))
            .unwrap_or_else(|| self.preview_output_target());

        let session_id = {
            let _ep_guard = self
                .inner
                .epoch_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if cancel.is_cancelled() {
                return Ok(());
            }
            if let Some(expected) = expected_play_epoch
                && self.inner.play_epoch.load(Ordering::SeqCst) != expected
            {
                return Ok(());
            }
            if expected_play_epoch.is_none() {
                self.inner.playback_epoch.fetch_add(1, Ordering::SeqCst);
            }

            if let Ok(mut q) = self.inner.queued_next.write() {
                *q = None;
            }
            if let Ok(mut qs) = self.inner.queued_next_spec.write() {
                *qs = None;
            }
            self.inner
                .has_queued_next_spec
                .store(false, Ordering::SeqCst);

            // Transition any live output stream into silent keep-alive BEFORE bumping
            // `current_session_id` so matching formats can hot-swap without hardware teardown.
            self.inner.enter_output_skip_silence();

            if let Ok(mut rg_lock) = self.inner.track_replay_gain.write() {
                *rg_lock = origin
                    .replay_gain_tags()
                    .with_metadata_fallback(decoder.metadata());
            }
            if let Ok(mut spec_lock) = self.inner.active_source_spec.write() {
                *spec_lock = match &origin {
                    PlayerOrigin::SourceSpec(spec) => Some(spec.clone()),
                    PlayerOrigin::Legacy(_) => None,
                };
            }
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);

            let sid = self.inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;

            self.inner.duration_ms.store(duration_ms, Ordering::SeqCst);
            self.inner.buffered_ms.store(0, Ordering::Relaxed);
            self.inner
                .ring_buffer_underrun_count
                .store(0, Ordering::Relaxed);
            self.inner
                .cpal_stream_error_flag
                .store(false, Ordering::Release);
            self.inner.stopped.store(false, Ordering::SeqCst);
            self.inner.paused.store(false, Ordering::SeqCst);
            self.inner.device_lost.store(false, Ordering::SeqCst);
            self.inner
                .format_mismatch_flag
                .store(false, Ordering::Release);
            self.inner.frames_rendered.store(0, Ordering::SeqCst);
            self.inner.nonzero_output_frames.store(0, Ordering::SeqCst);
            self.inner.seek_request_ms.store(-1, Ordering::SeqCst);
            self.inner.clear_error_state();
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);

            if let Ok(mut meta_lock) = self.inner.active_meta.write() {
                *meta_lock = Some(ActiveTrackMeta {
                    path: path_buf.clone(),
                    source_label: label.clone(),
                    format,
                    duration_ms,
                    resampled_to_hz: None,
                    backend: preview_backend,
                    device_name: preview_device,
                    track_meta: effective_track_meta.clone(),
                });
            }
            if let Ok(mut tm_lock) = self.inner.active_track_metadata.write() {
                *tm_lock = effective_track_meta.clone();
            }
            sid
        };

        // Non-blocking deck cancellation & retirement outside `epoch_lock` (zero `jh.join()`).
        self.inner
            .dual_deck
            .cancel_standby_nonblocking(&self.inner.reaper);
        self.inner
            .dual_deck
            .cancel_active_nonblocking(&self.inner.reaper);
        if cancel.is_cancelled()
            || self.inner.current_session_id.load(Ordering::Acquire) != session_id
        {
            return Ok(());
        }
        self.inner
            .dual_deck
            .active_deck_idx
            .store(0, Ordering::SeqCst);
        self.inner.dual_deck.deck_states[0].store(DeckState::Playing as u8, Ordering::SeqCst);
        self.inner.dual_deck.deck_states[1].store(DeckState::Idle as u8, Ordering::SeqCst);
        self.inner.dual_deck.set_deck_key(0, origin.stream_key());
        self.inner.dual_deck.set_deck_key(1, None);
        self.inner
            .dual_deck
            .set_deck_track_meta(0, effective_track_meta.clone());
        self.inner.dual_deck.set_deck_track_meta(1, None);
        self.inner
            .dual_deck
            .committed_deck_gen
            .store(self.inner.dual_deck.deck_gen_for(0), Ordering::Release);

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        let displaced = {
            let mut slot = self
                .inner
                .latest_start
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if cancel.is_cancelled()
                || self.inner.current_session_id.load(Ordering::Acquire) != session_id
            {
                return Ok(());
            }
            slot.replace(PendingStart {
                session_id,
                decoder,
                path: path_buf,
                source_label: label,
                origin,
                track_meta: effective_track_meta,
                cancel_token: cancel.clone(),
                ack_tx,
            })
        };
        if let Some(old) = displaced {
            let _ = old.ack_tx.send(Ok(()));
        }

        if self.cmd_tx.send(PlayerCommand::ApplyLatestStart).is_err() {
            self.inner.clear_latest_start();
            let msg = "Audio coordinator thread is shut down".to_string();
            if let Ok(mut err_lock) = self.inner.last_error.write() {
                *err_lock = Some(msg.clone());
            }
            self.inner.stopped.store(true, Ordering::SeqCst);
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
            return Err(CoreAudioError::Backend(BackendError::InvalidState(msg)));
        }

        match ack_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => {
                if !cancel.is_cancelled()
                    && self.inner.current_session_id.load(Ordering::Acquire) == session_id
                {
                    if let Ok(mut err_lock) = self.inner.last_error.write() {
                        *err_lock = Some(e.to_string());
                    }
                    self.inner.stopped.store(true, Ordering::SeqCst);
                    self.inner
                        .state_code
                        .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
                }
                Err(e)
            }
            Err(_) => {
                if cancel.is_cancelled()
                    || self.inner.current_session_id.load(Ordering::Acquire) != session_id
                {
                    return Ok(());
                }
                let msg = "Audio coordinator failed to acknowledge stream start".to_string();
                if let Ok(mut err_lock) = self.inner.last_error.write() {
                    *err_lock = Some(msg.clone());
                }
                self.inner.stopped.store(true, Ordering::SeqCst);
                self.inner
                    .state_code
                    .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
                Err(CoreAudioError::Backend(BackendError::DriverError(msg)))
            }
        }
    }
}
