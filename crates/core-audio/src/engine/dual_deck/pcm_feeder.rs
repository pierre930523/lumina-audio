//! RT-safe float-PCM dual-deck feeder (`DualDeckPcmFeeder`) struct, lifecycle, and inbox polling.

use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use core_types::DeckState;

use crate::engine::PlayerInner;
use crate::pipeline::fade::{AudioFadeControl, LinearFadeState, MISMATCH_CROSSFADE_MS};

use super::control::DualDeckControl;
use super::decode_handle::RtPcmInboxPayload;
use super::transition::RtTransitionKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PcmRenderOutcome {
    Rendered,
    FadeOut,
    Silent,
    Draining,
    Ended,
}

pub(crate) struct DualDeckPcmFeeder {
    pub(super) dual: Arc<DualDeckControl>,
    pub(super) inner: Arc<PlayerInner>,
    pub(super) active_session_id: Arc<AtomicU64>,
    pub(super) slot_ptrs: [*mut RtPcmInboxPayload; 2],
    pub(super) out_rate: u32,
    pub(super) out_channels: usize,
    pub(super) buffering_gate: bool,
    pub(crate) fade: LinearFadeState,
    pub(super) skip_fade: LinearFadeState,
    pub(super) active_skip_seq: Option<(u64, usize)>,
    pub(super) crossfade_active: bool,
    pub(super) crossfade_pos: usize,
    pub(super) crossfade_frames: usize,
    pub(super) crossfade_target_deck: usize,
    pub(super) crossfade_resume_frame: u64,
    pub(super) drain_notified: bool,
}

unsafe impl Send for DualDeckPcmFeeder {}

impl DualDeckPcmFeeder {
    pub(crate) fn new(
        dual: Arc<DualDeckControl>,
        inner: Arc<PlayerInner>,
        active_session_id: Arc<AtomicU64>,
        active_deck: usize,
        initial_payload: RtPcmInboxPayload,
        fade_ctrl: &AudioFadeControl,
    ) -> Self {
        let out_rate = initial_payload.out_rate.max(8_000);
        let out_channels = initial_payload.out_channels.max(1) as usize;
        let watermark = initial_payload.watermark_samples;
        let mut slot_ptrs = [null_mut(), null_mut()];
        slot_ptrs[active_deck & 1] = Box::into_raw(Box::new(initial_payload));
        let crossfade_frames =
            ((out_rate as u64 * MISMATCH_CROSSFADE_MS) / 1000).clamp(32, 2048) as usize;
        let mut feeder = Self {
            dual,
            inner: Arc::clone(&inner),
            active_session_id,
            slot_ptrs,
            out_rate,
            out_channels,
            buffering_gate: watermark > 0,
            fade: LinearFadeState::new(
                out_rate,
                fade_ctrl.fade_in_enabled(),
                fade_ctrl.fade_out_enabled(),
                inner.paused.load(Ordering::Acquire),
            ),
            skip_fade: LinearFadeState::new(out_rate, false, true, false),
            active_skip_seq: None,
            crossfade_active: false,
            crossfade_pos: 0,
            crossfade_frames,
            crossfade_target_deck: 1 - (active_deck & 1),
            crossfade_resume_frame: 0,
            drain_notified: false,
        };
        feeder.poll_inbox();
        feeder
    }

    #[inline]
    pub(super) fn poll_inbox(&mut self) {
        let cur = self.dual.active_idx();
        for i in 0..2 {
            let incoming = self.dual.pcm_inbox[i].swap(null_mut(), Ordering::AcqRel);
            if !incoming.is_null() {
                let wm = unsafe { (*incoming).watermark_samples };
                let old = std::mem::replace(&mut self.slot_ptrs[i], incoming);
                if !old.is_null() {
                    self.dual.retire_pcm_ptr(old);
                }
                if i == cur {
                    self.drain_notified = false;
                    self.active_skip_seq = None;
                    self.crossfade_active = false;
                    self.buffering_gate = wm > 0;
                    self.fade.reset_for_play_start();
                }
            }
        }
    }

    #[inline]
    pub(super) fn flip_to_standby(
        &self,
        from_deck: usize,
        to_deck: usize,
        kind: RtTransitionKind,
        resume_frame: u64,
    ) {
        let tgen = unsafe { (*self.slot_ptrs[to_deck]).deck_gen };
        self.dual
            .active_deck_idx
            .store(to_deck as u8, Ordering::Release);
        self.dual.deck_states[from_deck].store(DeckState::Idle as u8, Ordering::Release);
        self.dual.deck_states[to_deck].store(DeckState::Playing as u8, Ordering::Release);
        self.dual.standby_buffered_ms.store(0, Ordering::Relaxed);
        if kind == RtTransitionKind::ManualSkipFlip {
            self.inner.paused.store(false, Ordering::SeqCst);
        }
        self.inner
            .frames_rendered
            .store(resume_frame, Ordering::SeqCst);
        if kind != RtTransitionKind::MismatchCrossfadeFlip {
            self.dual.swap_generation.fetch_add(1, Ordering::Release);
            self.inner.playback_epoch.fetch_add(1, Ordering::Release);
        }
        self.dual
            .push_rt_event(kind, from_deck as u8, to_deck as u8, tgen);
    }
}

impl Drop for DualDeckPcmFeeder {
    fn drop(&mut self) {
        let cur = self.dual.active_idx();
        for i in 0..2 {
            let ptr = std::mem::replace(&mut self.slot_ptrs[i], null_mut());
            if !ptr.is_null() {
                let boxed = unsafe { Box::from_raw(ptr) };
                if i != cur
                    && self.dual.deck_state(i) == DeckState::StandbyReady
                    && let Ok(mut pg) = self.dual.standby_pending_pcm[i].lock()
                    && pg.is_none()
                {
                    *pg = Some(*boxed);
                }
            }
        }
        self.dual.drain_retired_payloads();
    }
}
