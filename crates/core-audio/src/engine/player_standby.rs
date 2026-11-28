//! Standby pre-decode worker spawning, zero-latency skip, and mismatch recovery.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use core_types::{
    DeckState, DeckTrackMetadata, PlaybackLifecycleState, StreamKey, StreamSourceSpec,
};
use tokio_util::sync::CancellationToken;

use crate::decoder::source_opener::source_spec_default_label;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dsp_helpers::position_ms_from_inner;
use crate::engine::dual_deck::{DeckDecodeHandle, DecodeThreadGuard, StandbyWakeState};
use crate::engine::session::run_standby_deck_worker;
use crate::engine::{AudioPlayer, PlayerOrigin};
use crate::error::{BackendError, CoreAudioError};
use crate::pipeline::fade::MISMATCH_ALIGNMENT_OFFSET_MS;

impl AudioPlayer {
    /// Performs a zero-latency switch to the Standby deck if it is `StandbyReady`.
    /// Returns `Ok(true)` when the fast transition completes, or `Ok(false)` if Standby is not ready.
    pub fn skip_to_standby(&self) -> Result<bool, CoreAudioError> {
        let (sb, cur, sb_gen, compat, flip_before, needs_reopen, req) = {
            let _op_guard = self
                .inner
                .dual_deck
                .skip_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner());

            let sb = self.inner.dual_deck.standby_idx();
            let cur = 1 - sb;
            if self.inner.dual_deck.deck_state(sb) != DeckState::StandbyReady {
                return Ok(false);
            }

            let sb_gen = self.inner.dual_deck.deck_gen_for(sb);
            let compat = self.inner.dual_deck.standby_compatible[sb].load(Ordering::Acquire);
            let state = self.inner.state_code.load(Ordering::Acquire);
            let is_paused = self.inner.paused.load(Ordering::Acquire);
            let has_active_output = !self.inner.stopped.load(Ordering::Acquire)
                && (state == PlaybackLifecycleState::Playing as i32
                    || state == PlaybackLifecycleState::Paused as i32);

            // Manual skip always resumes playback even if output was previously paused or ended.
            self.inner.paused.store(false, Ordering::SeqCst);

            let flip_before = self
                .inner
                .dual_deck
                .flip_done_sync
                .0
                .lock()
                .map(|g| *g)
                .unwrap_or(0);

            if !has_active_output || is_paused {
                if self
                    .cmd_tx
                    .send(PlayerCommand::ReopenOntoStandby {
                        from_deck: cur,
                        to_deck: sb,
                        to_deck_gen: sb_gen,
                        is_manual_skip: true,
                        is_mismatch_recovery: false,
                    })
                    .is_err()
                {
                    return Err(CoreAudioError::Backend(BackendError::InvalidState(
                        "Audio coordinator shut down".into(),
                    )));
                }
                (sb, cur, sb_gen, compat, flip_before, true, 0u64)
            } else {
                self.inner
                    .dual_deck
                    .skip_target_deck
                    .store(sb as u8, Ordering::Release);
                let req = self
                    .inner
                    .dual_deck
                    .skip_request_seq
                    .fetch_add(1, Ordering::AcqRel)
                    + 1;
                (sb, cur, sb_gen, compat, flip_before, false, req)
            }
        };
        // `skip_lock` is released BEFORE waiting on `flip_done_sync` to eliminate any
        // AB-BA deadlock with `coordinator_loop` (`TriggerAutoStandby`).

        let (lock, cvar) = &self.inner.dual_deck.flip_done_sync;
        if needs_reopen {
            if let Ok(mut g) = lock.lock() {
                let deadline = Instant::now() + Duration::from_millis(500);
                while *g == flip_before && Instant::now() < deadline {
                    let rem = deadline.saturating_duration_since(Instant::now());
                    let (ng, _) = cvar.wait_timeout(g, rem).unwrap_or_else(|e| e.into_inner());
                    g = ng;
                }
            }
            return Ok(self.inner.dual_deck.active_idx() == sb);
        }

        let wait_ms = if compat { 80 } else { 400 };
        if let Ok(mut g) = lock.lock() {
            let deadline = Instant::now() + Duration::from_millis(wait_ms);
            while *g == flip_before && Instant::now() < deadline {
                let rem = deadline.saturating_duration_since(Instant::now());
                let (ng, _) = cvar.wait_timeout(g, rem).unwrap_or_else(|e| e.into_inner());
                g = ng;
            }
        }

        if self.inner.dual_deck.active_idx() == sb {
            if self.has_pending_transition_commit()
                && let Ok(mut g) = lock.lock()
            {
                let commit_deadline = Instant::now() + Duration::from_millis(120);
                while self.has_pending_transition_commit() && Instant::now() < commit_deadline {
                    let rem = commit_deadline.saturating_duration_since(Instant::now());
                    let (ng, _) = cvar.wait_timeout(g, rem).unwrap_or_else(|e| e.into_inner());
                    g = ng;
                }
            }
            return Ok(true);
        }

        // Fallback if RT callback didn't fire in time (e.g. stream paused/draining at edge)
        if self
            .inner
            .dual_deck
            .skip_handled_seq
            .load(Ordering::Acquire)
            < req
            && self.inner.dual_deck.deck_state(sb) == DeckState::StandbyReady
        {
            let _ = self.cmd_tx.send(PlayerCommand::ReopenOntoStandby {
                from_deck: cur,
                to_deck: sb,
                to_deck_gen: sb_gen,
                is_manual_skip: true,
                is_mismatch_recovery: false,
            });
            if let Ok(mut g) = lock.lock() {
                let deadline = Instant::now() + Duration::from_millis(400);
                while self.inner.dual_deck.active_idx() != sb && Instant::now() < deadline {
                    let rem = deadline.saturating_duration_since(Instant::now());
                    let (ng, _) = cvar.wait_timeout(g, rem).unwrap_or_else(|e| e.into_inner());
                    g = ng;
                }
            }
        }

        Ok(self.inner.dual_deck.active_idx() == sb)
    }

    /// Triggers seamless dual-track recovery after an L2 `FormatMismatch` event.
    /// Active continues playing from its local `.head` buffer while Standby opens pure-remote
    /// `fresh_spec` at `current_pts_ms + 800ms`, prebuffers 2s, and aligns a 5ms micro-crossfade.
    pub fn trigger_format_mismatch_recovery(
        &self,
        key: StreamKey,
        fresh_spec: StreamSourceSpec,
    ) -> Result<(), CoreAudioError> {
        if let StreamSourceSpec::ExternalBackend {
            key: ext_key,
            provider_id,
            ..
        } = &fresh_spec
        {
            return Err(CoreAudioError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                ext_key.track_id
            )));
        }

        let active_idx = self.inner.dual_deck.active_idx();
        let active_key_matches = self
            .inner
            .dual_deck
            .deck_keys
            .read()
            .ok()
            .and_then(|g| g[active_idx].clone())
            .is_none_or(|k| k == key);
        if !active_key_matches {
            return Ok(());
        }

        let state = self.inner.state_code.load(Ordering::Acquire);
        if self.inner.stopped.load(Ordering::Acquire)
            || (state != PlaybackLifecycleState::Playing as i32
                && state != PlaybackLifecycleState::Paused as i32)
        {
            return Err(CoreAudioError::Backend(BackendError::InvalidState(
                "No active playback session for format mismatch recovery".into(),
            )));
        }

        let cur_pts_ms = position_ms_from_inner(&self.inner);
        let target_pts_ms = cur_pts_ms.saturating_add(MISMATCH_ALIGNMENT_OFFSET_MS);
        let out_rate = self
            .inner
            .out_sample_rate
            .load(Ordering::Acquire)
            .max(8_000) as u128;
        let target_frame = ((target_pts_ms as u128) * out_rate / 1000) as u64;
        let label = source_spec_default_label(&fresh_spec);
        let current_track_meta = self.active_track_metadata();

        self.prepare_standby_internal(
            PlayerOrigin::SourceSpec(fresh_spec),
            label,
            true,
            true,
            Some(target_pts_ms),
            Some(target_frame),
            current_track_meta,
            false,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_standby_internal(
        &self,
        origin: PlayerOrigin,
        label: String,
        bypass_l2_read: bool,
        is_mismatch_recovery: bool,
        mismatch_pts_ms: Option<u64>,
        mismatch_frame: Option<u64>,
        track_meta: Option<DeckTrackMetadata>,
        try_skip_lock: bool,
    ) -> Result<(), CoreAudioError> {
        let _op_guard = if try_skip_lock {
            match self.inner.dual_deck.skip_lock.try_lock() {
                Ok(g) => g,
                Err(std::sync::TryLockError::WouldBlock) => return Ok(()),
                Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
            }
        } else {
            self.inner
                .dual_deck
                .skip_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner())
        };

        let sb = self.inner.dual_deck.standby_idx();
        let _lifecycle_guard = self.inner.dual_deck.deck_lifecycle_locks[sb]
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        self.inner
            .dual_deck
            .cancel_and_retire_deck(sb, &self.inner.reaper);

        let deck_gen = self.inner.dual_deck.alloc_deck_gen(sb);
        self.inner.dual_deck.deck_states[sb].store(DeckState::Resolving as u8, Ordering::SeqCst);
        self.inner.dual_deck.set_deck_key(sb, origin.stream_key());
        self.inner
            .dual_deck
            .set_deck_track_meta(sb, track_meta.clone());
        self.inner
            .dual_deck
            .standby_buffered_ms
            .store(0, Ordering::Relaxed);
        self.inner.dual_deck.standby_compatible[sb].store(false, Ordering::SeqCst);
        self.inner.dual_deck.standby_is_mismatch_recovery[sb]
            .store(is_mismatch_recovery, Ordering::SeqCst);
        self.inner.dual_deck.standby_target_pts_ms[sb]
            .store(mismatch_pts_ms.unwrap_or(0), Ordering::SeqCst);
        self.inner.dual_deck.standby_target_frame[sb]
            .store(mismatch_frame.unwrap_or(0), Ordering::SeqCst);

        let cancel_flag = Arc::new(AtomicBool::new(false));
        let cancel_token = CancellationToken::new();
        let wake = Arc::new((Mutex::new(StandbyWakeState::Parked), Condvar::new()));

        let worker_inner = Arc::clone(&self.inner);
        let worker_cmd_tx = self.cmd_tx.clone();
        let worker_cancel_flag = Arc::clone(&cancel_flag);
        let worker_cancel_token = cancel_token.clone();
        let worker_wake = Arc::clone(&wake);
        let thread_guard_counter = Arc::clone(&self.inner.live_decode_threads);

        let mut entry_guard = self.inner.dual_deck.decode_entries[sb]
            .lock()
            .unwrap_or_else(|e| e.into_inner());

        let jh = thread::Builder::new()
            .name(format!("lumina-deck-standby-{sb}"))
            .spawn(move || {
                let _live_guard = DecodeThreadGuard::new(&thread_guard_counter);
                run_standby_deck_worker(
                    worker_inner,
                    worker_cmd_tx,
                    sb,
                    deck_gen,
                    origin,
                    label,
                    track_meta,
                    bypass_l2_read,
                    is_mismatch_recovery,
                    mismatch_pts_ms.unwrap_or(0),
                    mismatch_frame.unwrap_or(0),
                    worker_cancel_flag,
                    worker_cancel_token,
                    worker_wake,
                )
            })
            .map_err(|e| {
                self.inner.dual_deck.deck_states[sb].store(DeckState::Idle as u8, Ordering::SeqCst);
                self.inner.dual_deck.set_deck_key(sb, None);
                self.inner.dual_deck.set_deck_track_meta(sb, None);
                CoreAudioError::Backend(BackendError::DriverError(format!(
                    "Failed to spawn standby deck worker: {e}"
                )))
            })?;

        *entry_guard = Some(DeckDecodeHandle {
            deck_gen,
            cancel_flag,
            cancel_token,
            wake,
            join_handle: Some(jh),
        });
        Ok(())
    }
}
