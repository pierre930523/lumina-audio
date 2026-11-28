//! `DualDeckControl` profile rebinding, deck retirement, cancellation, and Drop.

use std::sync::atomic::Ordering;

use core_types::DeckState;

use crate::decoder::pcm::AudioDecoder;

use super::control::DualDeckControl;
use super::decode_handle::{ActiveOutputProfile, DeckMetadataSnapshot, StandbyWakeState};
use super::reaper::ThreadReaper;

impl DualDeckControl {
    pub(crate) fn is_compatible_with_profile(
        snap: &DeckMetadataSnapshot,
        prof: &ActiveOutputProfile,
    ) -> bool {
        if !prof.uses_dual_feeder {
            return false;
        }
        if prof.is_wire {
            snap.is_wire
                && snap.negotiated.output_mode == prof.output_mode
                && snap.negotiated.wire_format == prof.wire_format
                && snap.out_rate == prof.out_rate
                && snap.out_channels == prof.out_channels
        } else {
            !snap.is_wire
                && snap.out_rate == prof.out_rate
                && snap.out_channels == prof.out_channels
        }
    }

    pub(crate) fn rebind_standby_for_new_profile(&self, prof: ActiveOutputProfile) {
        let sb = self.standby_idx();
        if self.deck_state(sb) == DeckState::StandbyReady {
            let compat = self.deck_meta[sb]
                .read()
                .ok()
                .and_then(|g| {
                    g.as_ref()
                        .map(|snap| Self::is_compatible_with_profile(snap, &prof))
                })
                .unwrap_or(false);
            self.standby_compatible[sb].store(compat, Ordering::SeqCst);
            if compat {
                if prof.is_wire {
                    if let Some(payload) = self.standby_pending_wire[sb]
                        .lock()
                        .ok()
                        .and_then(|mut g| g.take())
                    {
                        self.send_wire_inbox(sb, payload);
                    }
                } else if let Some(payload) = self.standby_pending_pcm[sb]
                    .lock()
                    .ok()
                    .and_then(|mut g| g.take())
                {
                    self.send_pcm_inbox(sb, payload);
                }
            }
        }
        if let Ok(mut g) = self.active_profile.write() {
            *g = Some(prof);
        }
    }

    pub(crate) fn retire_inactive_deck(&self, idx: usize, reaper: &ThreadReaper) {
        let i = idx & 1;
        let _lifecycle_guard = self.deck_lifecycle_locks[i]
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if self.active_idx() == i {
            return;
        }
        let st = self.deck_state(i);
        if st != DeckState::Idle && st != DeckState::Draining {
            return;
        }
        self.cancel_and_retire_deck(i, reaper);
    }

    pub(crate) fn promote_decode_thread(&self, idx: usize) {
        let i = idx & 1;
        if let Ok(guard) = self.decode_entries[i].lock()
            && let Some(ref entry) = *guard
            && let Ok(mut wg) = entry.wake.0.lock()
        {
            *wg = StandbyWakeState::Promoted;
            entry.wake.1.notify_all();
        }
    }

    /// Cancels deck `idx` and hands its decode thread `JoinHandle` to the background reaper
    /// without blocking the caller on `JoinHandle::join()`.
    pub(crate) fn cancel_and_retire_deck(&self, idx: usize, reaper: &ThreadReaper) {
        let i = idx & 1;
        self.alloc_deck_gen(i);
        let entry_opt = self.decode_entries[i]
            .lock()
            .ok()
            .and_then(|mut g| g.take());
        if let Some(mut entry) = entry_opt {
            entry.cancel_token.cancel();
            entry.cancel_flag.store(true, Ordering::SeqCst);
            if let Ok(mut wg) = entry.wake.0.lock() {
                *wg = StandbyWakeState::Cancelled;
                entry.wake.1.notify_all();
            }
            if let Some(jh) = entry.join_handle.take() {
                reaper.retire_decode(jh);
            }
        }
        self.reset_deck_slot(i);
    }

    pub(crate) fn cancel_and_join_deck(&self, idx: usize) -> Option<Box<dyn AudioDecoder>> {
        let i = idx & 1;
        // Bump deck_gen first so any in-flight open for this deck immediately notices replacement.
        self.alloc_deck_gen(i);
        let entry_opt = self.decode_entries[i]
            .lock()
            .ok()
            .and_then(|mut g| g.take());
        let mut reused = None;
        if let Some(mut entry) = entry_opt {
            entry.cancel_token.cancel();
            entry.cancel_flag.store(true, Ordering::SeqCst);
            if let Ok(mut wg) = entry.wake.0.lock() {
                *wg = StandbyWakeState::Cancelled;
                entry.wake.1.notify_all();
            }
            if let Some(jh) = entry.join_handle.take() {
                reused = jh.join().ok().flatten();
            }
        }
        self.reset_deck_slot(i);
        reused
    }

    fn reset_deck_slot(&self, i: usize) {
        self.clear_inboxes_for_deck(i);
        self.drain_retired_payloads();
        self.deck_states[i].store(DeckState::Idle as u8, Ordering::SeqCst);
        self.set_deck_key(i, None);
        self.deck_eof_flags[i].store(false, Ordering::SeqCst);
        self.deck_buffered_ms[i].store(0, Ordering::Relaxed);
        self.standby_compatible[i].store(false, Ordering::SeqCst);
        self.standby_is_mismatch_recovery[i].store(false, Ordering::SeqCst);
        self.standby_target_pts_ms[i].store(0, Ordering::SeqCst);
        self.standby_target_frame[i].store(0, Ordering::SeqCst);
        if let Ok(mut mg) = self.deck_meta[i].write() {
            *mg = None;
        }
        if let Ok(mut tg) = self.deck_track_meta[i].write() {
            *tg = None;
        }
    }

    pub(crate) fn cancel_standby_nonblocking(&self, reaper: &ThreadReaper) {
        let sb = self.standby_idx();
        let _lifecycle_guard = self.deck_lifecycle_locks[sb]
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        self.mismatch_armed.store(false, Ordering::Release);
        self.standby_buffered_ms.store(0, Ordering::Relaxed);
        self.cancel_and_retire_deck(sb, reaper);
    }

    pub(crate) fn cancel_active_nonblocking(&self, reaper: &ThreadReaper) {
        let act = self.active_idx();
        let _lifecycle_guard = self.deck_lifecycle_locks[act]
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        self.cancel_and_retire_deck(act, reaper);
    }

    pub(crate) fn cancel_standby(&self) {
        let sb = self.standby_idx();
        let _lifecycle_guard = self.deck_lifecycle_locks[sb]
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        self.mismatch_armed.store(false, Ordering::Release);
        self.standby_buffered_ms.store(0, Ordering::Relaxed);
        let _ = self.cancel_and_join_deck(sb);
    }

    pub(crate) fn notify_flip_done(&self) {
        if let Ok(mut g) = self.flip_done_sync.0.lock() {
            *g = g.wrapping_add(1);
            self.flip_done_sync.1.notify_all();
        }
    }
}

impl Drop for DualDeckControl {
    fn drop(&mut self) {
        self.stop_relay();
        self.clear_inboxes_for_deck(0);
        self.clear_inboxes_for_deck(1);
        self.drain_retired_payloads();
    }
}
