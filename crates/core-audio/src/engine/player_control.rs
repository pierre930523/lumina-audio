//! Transport controls (pause/resume/stop/seek), volume, and engine policy configuration.

use std::sync::atomic::Ordering;
use std::sync::{Arc, mpsc};
use std::time::Duration;

use core_types::{DeckState, DsdOutputMode, PlaybackEnginePolicy, PlaybackLifecycleState};
use tokio_util::sync::CancellationToken;

use crate::backend::device_fsm::OutputDeviceState;
use crate::engine::AudioPlayer;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::types::decode_device_fsm_state;
use crate::error::CoreAudioError;
use crate::pipeline::rt_telemetry::RtTelemetry;

impl AudioPlayer {
    pub fn pause(&self) {
        if let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_pause_fade_out();
        }
        self.inner.paused.store(true, Ordering::SeqCst);
        let cur = self.state_code();
        if cur == PlaybackLifecycleState::Playing as i32
            || cur == PlaybackLifecycleState::Seeking as i32
            || cur == PlaybackLifecycleState::Buffering as i32
        {
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
        }
        let _ = self.cmd_tx.send(PlayerCommand::Pause);
    }

    pub fn resume(&self) {
        if let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_play_fade_in();
        }
        self.inner.paused.store(false, Ordering::SeqCst);
        let cur = self.state_code();
        if cur == PlaybackLifecycleState::Paused as i32
            || cur == PlaybackLifecycleState::Seeking as i32
        {
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);
        }
        let _ = self.cmd_tx.send(PlayerCommand::Resume);
    }

    pub fn stop(&self) {
        self.inner.clear_latest_start();
        if let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_stop_fade_out();
        }
        let _ = self.swap_cancel_and_bump_epoch(None, CancellationToken::new());
        self.inner
            .dual_deck
            .cancel_standby_nonblocking(&self.inner.reaper);
        self.inner
            .dual_deck
            .cancel_active_nonblocking(&self.inner.reaper);
        self.inner.dual_deck.deck_states[0].store(DeckState::Idle as u8, Ordering::SeqCst);
        self.inner.dual_deck.deck_states[1].store(DeckState::Idle as u8, Ordering::SeqCst);
        self.inner.dual_deck.set_deck_key(0, None);
        self.inner.dual_deck.set_deck_key(1, None);
        self.inner.dual_deck.set_deck_track_meta(0, None);
        self.inner.dual_deck.set_deck_track_meta(1, None);
        self.inner
            .dual_deck
            .committed_deck_gen
            .store(0, Ordering::Release);
        if let Ok(mut tm_lock) = self.inner.active_track_metadata.write() {
            *tm_lock = None;
        }
        self.inner
            .dual_deck
            .standby_buffered_ms
            .store(0, Ordering::Relaxed);
        if let Ok(mut spec_lock) = self.inner.active_source_spec.write() {
            *spec_lock = None;
        }
        if let Ok(mut next_spec_lock) = self.inner.queued_next_spec.write() {
            *next_spec_lock = None;
        }
        self.inner
            .has_queued_next_spec
            .store(false, Ordering::SeqCst);
        self.inner.stopped.store(true, Ordering::SeqCst);
        self.inner.paused.store(false, Ordering::SeqCst);
        self.inner.frames_rendered.store(0, Ordering::SeqCst);
        self.inner.buffered_ms.store(0, Ordering::Relaxed);
        self.inner
            .state_code
            .store(PlaybackLifecycleState::Stopped as i32, Ordering::SeqCst);
        let _ = self.cmd_tx.send(PlayerCommand::Stop);
    }

    pub fn seek_ms(&self, pos_ms: u64) {
        self.inner
            .dual_deck
            .mismatch_armed
            .store(false, Ordering::SeqCst);
        let dur = self.duration_ms();
        let clamped = if dur > 0 { pos_ms.min(dur) } else { pos_ms };
        let rate = self.inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
        let target_frames = ((clamped as u128) * rate / 1000) as u64;
        let new_seek_ep = {
            let _ep_guard = self
                .inner
                .epoch_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            self.inner.epoch.fetch_add(1, Ordering::SeqCst);
            self.inner.seek_epoch.fetch_add(1, Ordering::SeqCst) + 1
        };
        self.inner.is_seeking.store(true, Ordering::SeqCst);
        let is_paused = self.inner.paused.load(Ordering::SeqCst);
        if !is_paused
            && let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_seek_fade_out(new_seek_ep);
        }
        let cur_state = self.inner.state_code.load(Ordering::SeqCst);
        let was_ended = cur_state == PlaybackLifecycleState::Ended as i32;
        if !is_paused && (cur_state == PlaybackLifecycleState::Playing as i32 || was_ended) {
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Seeking as i32, Ordering::SeqCst);
        }
        self.inner
            .seek_request_ms
            .store(clamped as i64, Ordering::SeqCst);
        self.inner
            .frames_rendered
            .store(target_frames, Ordering::SeqCst);
        let _ = self.cmd_tx.send(PlayerCommand::SeekMs { was_ended });
    }

    pub fn set_volume(&self, vol: f32) {
        let clamped = if vol.is_nan() {
            0.0
        } else {
            vol.clamp(0.0, 1.0)
        };
        self.inner
            .saved_normal_volume_bits
            .store(clamped.to_bits(), Ordering::Relaxed);
        if self.is_strict_bit_perfect() {
            self.inner
                .volume_bits
                .store((1.0f32).to_bits(), Ordering::Relaxed);
            return;
        }
        self.inner
            .volume_bits
            .store(clamped.to_bits(), Ordering::Relaxed);
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
    }

    pub fn volume(&self) -> f32 {
        if self.is_strict_bit_perfect() {
            return 1.0;
        }
        f32::from_bits(self.inner.volume_bits.load(Ordering::Relaxed))
    }

    pub fn is_strict_bit_perfect(&self) -> bool {
        self.inner.strict_bit_perfect.load(Ordering::Acquire)
    }

    /// Returns the explicit output hardware lifecycle state managed by `OutputDeviceFsm`.
    pub fn device_fsm_state(&self) -> OutputDeviceState {
        decode_device_fsm_state(self.inner.device_fsm_state.load(Ordering::Acquire))
    }

    /// Returns the lock-free, cache-line-padded real-time audio telemetry block.
    pub fn rt_telemetry(&self) -> Arc<RtTelemetry> {
        Arc::clone(&self.inner.rt_telemetry)
    }

    pub fn engine_policy(&self) -> PlaybackEnginePolicy {
        self.inner
            .policy
            .read()
            .map(|p| p.clone())
            .unwrap_or_default()
    }

    pub fn set_allow_shared_fallback(&self, allow: bool) {
        self.inner
            .saved_allow_shared_fallback
            .store(allow, Ordering::SeqCst);
        if let Ok(mut p) = self.inner.policy.write() {
            // BP-1: Strict Bit-Perfect mode never permits silent fallback to Shared/Resampled output.
            p.allow_shared_fallback = if p.strict_bit_perfect { false } else { allow };
        }
    }

    pub fn set_strict_bit_perfect(&self, enabled: bool) -> Result<(), CoreAudioError> {
        let prev = self.is_strict_bit_perfect();
        if let Ok(mut p) = self.inner.policy.write() {
            if !prev && enabled {
                self.inner
                    .saved_allow_shared_fallback
                    .store(p.allow_shared_fallback, Ordering::SeqCst);
                p.allow_shared_fallback = false;
            } else if prev && !enabled {
                p.allow_shared_fallback = self
                    .inner
                    .saved_allow_shared_fallback
                    .load(Ordering::SeqCst);
            }
            p.strict_bit_perfect = enabled;
        }
        self.inner
            .strict_bit_perfect
            .store(enabled, Ordering::SeqCst);
        if !prev && enabled {
            let cur_bypass = self.inner.dsp_bypassed.load(Ordering::SeqCst);
            self.inner
                .saved_normal_dsp_bypass
                .store(cur_bypass, Ordering::SeqCst);
            let cur_vol = self.inner.volume_bits.load(Ordering::Relaxed);
            self.inner
                .saved_normal_volume_bits
                .store(cur_vol, Ordering::Relaxed);

            self.inner.dsp_bypassed.store(true, Ordering::SeqCst);
            if let Ok(mut guard) = self.inner.dsp_config.write() {
                guard.bypass = true;
            }
            self.inner
                .volume_bits
                .store((1.0f32).to_bits(), Ordering::Relaxed);
            if let Ok(fade_lock) = self.inner.active_fade.read()
                && let Some(ref fc) = *fade_lock
            {
                fc.set_strict_bit_perfect(true, false);
            }
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        } else if prev && !enabled {
            let restored_bypass = self.inner.saved_normal_dsp_bypass.load(Ordering::SeqCst);
            let restored_vol = self.inner.saved_normal_volume_bits.load(Ordering::Relaxed);
            self.inner
                .dsp_bypassed
                .store(restored_bypass, Ordering::SeqCst);
            if let Ok(mut guard) = self.inner.dsp_config.write() {
                guard.bypass = restored_bypass;
            }
            self.inner
                .volume_bits
                .store(restored_vol, Ordering::Relaxed);
            if let Ok(fade_lock) = self.inner.active_fade.read()
                && let Some(ref fc) = *fade_lock
            {
                fc.set_strict_bit_perfect(false, false);
            }
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        }

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: false,
            })
            .is_ok()
        {
            match ack_rx.recv_timeout(Duration::from_secs(10)) {
                Ok(res) => res,
                Err(_) => Ok(()),
            }
        } else {
            Ok(())
        }
    }

    pub fn set_dsd_output_mode(&self, mode: DsdOutputMode) -> Result<(), CoreAudioError> {
        if let Ok(mut p) = self.inner.policy.write() {
            p.dsd_output_mode = mode;
        }
        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: false,
            })
            .is_ok()
        {
            match ack_rx.recv_timeout(Duration::from_secs(10)) {
                Ok(res) => res,
                Err(_) => Ok(()),
            }
        } else {
            Ok(())
        }
    }

    pub fn preferred_buffer_frames(&self) -> u32 {
        self.inner
            .policy
            .read()
            .map(|p| p.preferred_buffer_frames)
            .unwrap_or(512)
    }

    pub fn set_preferred_buffer_frames(&self, frames: u32) -> Result<(), CoreAudioError> {
        let clamped = frames.clamp(32, 32768);
        if let Ok(mut p) = self.inner.policy.write() {
            p.preferred_buffer_frames = clamped;
        }
        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: false,
            })
            .is_ok()
        {
            match ack_rx.recv_timeout(Duration::from_secs(10)) {
                Ok(res) => res,
                Err(_) => Ok(()),
            }
        } else {
            Ok(())
        }
    }
}
