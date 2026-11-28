use super::state::EngineState;
use core_audio::AudioPlayer;
use core_types::LuminaError;
use std::sync::atomic::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio_util::sync::CancellationToken;

impl EngineState {
    pub fn player_clone(&self) -> Option<AudioPlayer> {
        self.player.read().ok().and_then(|g| g.clone())
    }

    pub fn elapsed_ms_since_start(&self) -> u64 {
        (self.created_at.elapsed().as_millis() as u64).max(1)
    }

    pub fn now_unix_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    pub fn next_sequence(&self) -> u64 {
        self.sequence
            .fetch_add(1, Ordering::SeqCst)
            .saturating_add(1)
    }

    pub fn current_sequence(&self) -> u64 {
        self.sequence.load(Ordering::SeqCst)
    }

    pub fn set_structured_error(&self, err: LuminaError) {
        if let Ok(mut lock) = self.async_last_error.write() {
            *lock = Some(err.message.clone());
        }
        if let Ok(mut lock) = self.async_last_error_code.write() {
            *lock = Some(err.code.as_str().to_string());
        }
        if let Ok(mut lock) = self.async_last_error_provider.write() {
            *lock = err.provider.clone();
        }
        if let Ok(mut lock) = self.last_structured_error.write() {
            *lock = Some(err);
        }
    }

    pub fn clear_structured_error(&self) {
        if let Ok(mut lock) = self.async_last_error.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.async_last_error_code.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.async_last_error_provider.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.last_structured_error.write() {
            *lock = None;
        }
    }

    pub fn current_structured_error(&self) -> Option<LuminaError> {
        if let Ok(guard) = self.last_structured_error.read()
            && let Some(ref err) = *guard
        {
            return Some(err.clone());
        }
        if let Some(player) = self.player_clone()
            && let Some(msg) = player.last_error()
        {
            return Some(crate::error::synthesize_lumina_error(
                msg,
                player.last_error_code().as_deref(),
                player.last_error_provider(),
            ));
        }
        let msg = self.async_last_error.read().ok().and_then(|g| g.clone())?;
        let code = self
            .async_last_error_code
            .read()
            .ok()
            .and_then(|g| g.clone());
        let provider = self
            .async_last_error_provider
            .read()
            .ok()
            .and_then(|g| g.clone());
        Some(crate::error::synthesize_lumina_error(
            msg,
            code.as_deref(),
            provider,
        ))
    }

    pub fn take_structured_error(&self) -> Option<LuminaError> {
        if let Ok(mut guard) = self.last_structured_error.write()
            && let Some(err) = guard.take()
        {
            if let Ok(mut lock) = self.async_last_error.write() {
                *lock = None;
            }
            if let Ok(mut lock) = self.async_last_error_code.write() {
                *lock = None;
            }
            if let Ok(mut lock) = self.async_last_error_provider.write() {
                *lock = None;
            }
            if let Some(player) = self.player_clone() {
                let _ = player.take_last_error();
            }
            return Some(err);
        }
        if let Some(player) = self.player_clone() {
            let code = player.last_error_code();
            let provider = player.last_error_provider();
            if let Some(msg) = player.take_last_error() {
                return Some(crate::error::synthesize_lumina_error(
                    msg,
                    code.as_deref(),
                    provider,
                ));
            }
        }
        let msg = self
            .async_last_error
            .write()
            .ok()
            .and_then(|mut g| g.take())?;
        let code = self
            .async_last_error_code
            .write()
            .ok()
            .and_then(|mut g| g.take());
        let provider = self
            .async_last_error_provider
            .write()
            .ok()
            .and_then(|mut g| g.take());
        Some(crate::error::synthesize_lumina_error(
            msg,
            code.as_deref(),
            provider,
        ))
    }

    pub fn set_volume(&self, vol: f32) {
        let clamped = if vol.is_nan() {
            0.0
        } else {
            vol.clamp(0.0, 1.0)
        };
        if clamped > 0.0 {
            self.pre_mute_volume_bits
                .store(clamped.to_bits() as u64, Ordering::Relaxed);
            self.is_muted.store(false, Ordering::SeqCst);
        }
        if let Some(p) = self.player_clone() {
            p.set_volume(clamped);
            let effective = p.volume();
            self.volume_bits
                .store(effective.to_bits() as u64, Ordering::Relaxed);
            return;
        }
        self.volume_bits
            .store(clamped.to_bits() as u64, Ordering::Relaxed);
    }

    pub fn set_muted(&self, muted: bool) {
        let was_muted = self.is_muted.swap(muted, Ordering::SeqCst);
        if muted {
            if !was_muted {
                let cur = self.get_volume();
                if cur > 0.0 {
                    self.pre_mute_volume_bits
                        .store(cur.to_bits() as u64, Ordering::Relaxed);
                }
            }
            if let Some(p) = self.player_clone() {
                p.set_volume(0.0);
                self.volume_bits
                    .store(p.volume().to_bits() as u64, Ordering::Relaxed);
            } else {
                self.volume_bits
                    .store((0.0f32).to_bits() as u64, Ordering::Relaxed);
            }
        } else {
            let restore = f32::from_bits(self.pre_mute_volume_bits.load(Ordering::Relaxed) as u32)
                .clamp(0.0, 1.0);
            let target = if restore <= 0.0 { 1.0 } else { restore };
            if let Some(p) = self.player_clone() {
                p.set_volume(target);
                self.volume_bits
                    .store(p.volume().to_bits() as u64, Ordering::Relaxed);
            } else {
                self.volume_bits
                    .store(target.to_bits() as u64, Ordering::Relaxed);
            }
        }
    }

    pub fn get_volume(&self) -> f32 {
        if let Some(p) = self.player_clone() {
            return p.volume();
        }
        let bits = self.volume_bits.load(Ordering::Relaxed) as u32;
        f32::from_bits(bits)
    }

    pub fn current_playback_epoch(&self) -> u64 {
        let ep = self.playback_epoch.load(Ordering::SeqCst);
        let player_ep = self.player_clone().map(|p| p.playback_epoch()).unwrap_or(0);
        ep.max(player_ep)
    }

    pub fn current_epoch(&self) -> u64 {
        let ep = self.epoch.load(Ordering::SeqCst);
        let pb_ep = self.playback_epoch.load(Ordering::SeqCst);
        let player_ep = self
            .player_clone()
            .map(|p| p.current_epoch().max(p.playback_epoch()))
            .unwrap_or(0);
        ep.max(pb_ep).max(player_ep)
    }

    pub fn advance_playback_epoch(&self, caller_epoch: Option<u64>) -> u64 {
        let (player_ep, player_pb_ep) = self
            .player_clone()
            .map(|p| (p.current_epoch(), p.playback_epoch()))
            .unwrap_or((0, 0));
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        let next = loop {
            let floor = cur.max(player_pb_ep);
            let candidate = match caller_epoch {
                Some(ep) if ep > floor => ep,
                _ => floor.saturating_add(1).max(1),
            };
            match self.playback_epoch.compare_exchange_weak(
                cur,
                candidate,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => break candidate,
                Err(actual) => cur = actual,
            }
        };
        if caller_epoch.is_none() {
            let mut ep_cur = self.epoch.load(Ordering::SeqCst);
            loop {
                let floor = ep_cur.max(player_ep);
                let ep_next = floor.saturating_add(1).max(next);
                match self.epoch.compare_exchange_weak(
                    ep_cur,
                    ep_next,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                ) {
                    Ok(_) => break,
                    Err(actual) => ep_cur = actual,
                }
            }
        } else {
            self.epoch.fetch_max(next.max(player_ep), Ordering::SeqCst);
        }
        next
    }

    pub fn sync_playback_epoch_from_player(&self, player: &AudioPlayer, min_epoch: u64) -> u64 {
        let eff_pb = min_epoch.max(player.playback_epoch());
        let prev_pb = self.playback_epoch.fetch_max(eff_pb, Ordering::SeqCst);
        let final_pb = prev_pb.max(eff_pb);
        self.epoch
            .fetch_max(final_pb.max(player.current_epoch()), Ordering::SeqCst);
        final_pb
    }

    /// Monotonically raises `playback_epoch`, `epoch`, and `last_caller_epoch` to at least
    /// `caller_epoch` without forcing an extra `+1` bump when already equal.
    pub fn sync_caller_epoch_floor(&self, caller_epoch: u64) -> u64 {
        if caller_epoch == 0 {
            return self.current_playback_epoch();
        }
        self.last_caller_epoch
            .fetch_max(caller_epoch, Ordering::SeqCst);
        self.playback_epoch
            .fetch_max(caller_epoch, Ordering::SeqCst);
        self.epoch.fetch_max(caller_epoch, Ordering::SeqCst);
        self.current_playback_epoch()
    }

    /// Advances `playback_epoch` monotonically after an epoch-less `player.begin_skip_transition()`.
    /// Uses `player.playback_epoch()` when it already exceeds the current floor (no double-bump),
    /// otherwise increments `self.playback_epoch` by 1 so the caller never observes a stale epoch.
    pub fn advance_after_epochless_skip(&self, player: &AudioPlayer) -> u64 {
        let player_pb = player.playback_epoch();
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        let next = loop {
            let candidate = if player_pb > cur {
                player_pb
            } else {
                cur.saturating_add(1).max(1)
            };
            match self.playback_epoch.compare_exchange_weak(
                cur,
                candidate,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => break candidate,
                Err(actual) => cur = actual,
            }
        };
        self.epoch
            .fetch_max(next.max(player.current_epoch()), Ordering::SeqCst);
        next
    }

    pub fn advance_epoch(&self, caller_epoch: Option<u64>) -> u64 {
        let player_ep = self.player_clone().map(|p| p.current_epoch()).unwrap_or(0);
        let mut cur = self.epoch.load(Ordering::SeqCst);
        loop {
            let floor = cur.max(player_ep);
            let next = match caller_epoch {
                Some(ep) if ep > floor => ep,
                _ => floor.saturating_add(1).max(1),
            };
            match self
                .epoch
                .compare_exchange_weak(cur, next, Ordering::SeqCst, Ordering::SeqCst)
            {
                Ok(_) => return next,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn accept_caller_epoch(&self, caller_epoch: Option<u64>) -> bool {
        let Some(ep) = caller_epoch.filter(|&e| e > 0) else {
            return true;
        };
        let mut cur = self.last_caller_epoch.load(Ordering::SeqCst);
        loop {
            if ep < cur {
                return false;
            }
            if ep == cur {
                return true;
            }
            match self.last_caller_epoch.compare_exchange_weak(
                cur,
                ep,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return true,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn cancel_active_play_token(&self) {
        if let Ok(mut guard) = self.active_play_cancel.write()
            && let Some(token) = guard.take()
        {
            token.cancel();
        }
    }

    pub fn swap_play_cancel_token(&self, new_token: CancellationToken) {
        if let Ok(mut guard) = self.active_play_cancel.write()
            && let Some(prev) = guard.replace(new_token)
        {
            prev.cancel();
        }
    }

    pub fn cancel_active_standby_token(&self) {
        if let Ok(mut guard) = self.active_standby_cancel.write()
            && let Some(token) = guard.take()
        {
            token.cancel();
        }
    }

    pub fn swap_standby_cancel_token(&self, new_token: CancellationToken) {
        if let Ok(mut guard) = self.active_standby_cancel.write()
            && let Some(prev) = guard.replace(new_token)
        {
            prev.cancel();
        }
    }

    pub fn clear_pending_commands(&self) {
        let _ = self.play_cmd_tx.send_replace(None);
        let _ = self.standby_cmd_tx.send_replace(None);
    }
}
