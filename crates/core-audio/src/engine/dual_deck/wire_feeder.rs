//! RT-safe packed-wire dual-deck feeder (`DualDeckWireFeeder`) and silence/epoch helpers.

use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use core_types::DeckState;

use crate::pipeline::fade::{LinearFadeState, MISMATCH_CROSSFADE_MS};
use crate::pipeline::rt_telemetry::RtTelemetry;
use crate::verification::WireSampleFormat;

use super::control::DualDeckControl;
use super::decode_handle::RtWireInboxPayload;
use super::transition::RtTransitionKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DualDeckWireOutcome {
    Rendered { valid_bytes: usize },
    CrossRateDraining,
    EofEmpty,
    Underrun,
}

#[inline]
pub(crate) fn fill_wire_silence(
    buf: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    dop_phase: &mut bool,
) {
    match wire {
        WireSampleFormat::NativeDsd { .. } => buf.fill(0x69),
        WireSampleFormat::Dop24In32MsbLe { .. } => {
            let ch = channels.max(1);
            let bpf = 4 * ch;
            let aligned = (buf.len() / bpf) * bpf;
            for f in 0..(aligned / bpf) {
                let marker = if *dop_phase { 0xFAu8 } else { 0x05u8 };
                *dop_phase = !*dop_phase;
                for c in 0..ch {
                    let off = f * bpf + c * 4;
                    buf[off] = 0x00;
                    buf[off + 1] = 0x69;
                    buf[off + 2] = 0x69;
                    buf[off + 3] = marker;
                }
            }
            if aligned < buf.len() {
                buf[aligned..].fill(0x00);
            }
        }
        _ => buf.fill(0x00),
    }
}

#[inline]
pub(super) fn wire_bytes_have_nonzero(buf: &[u8], wire: WireSampleFormat) -> bool {
    match wire {
        WireSampleFormat::NativeDsd { .. } => buf.iter().any(|&b| b != 0x69),
        WireSampleFormat::Dop24In32MsbLe { .. } => buf.as_chunks::<4>().0.iter().any(|s| {
            s[0] != 0x00 || s[1] != 0x69 || s[2] != 0x69 || (s[3] != 0x05 && s[3] != 0xFA)
        }),
        _ => buf.iter().any(|&b| b != 0),
    }
}

pub(crate) struct DualDeckWireFeeder {
    pub(super) dual: Arc<DualDeckControl>,
    pub(super) frames_rendered: Arc<AtomicU64>,
    pub(super) nonzero_frames: Arc<AtomicU64>,
    pub(super) buffered_ms: Arc<AtomicU64>,
    pub(super) gapless_transitions: Arc<AtomicU64>,
    pub(super) underrun_count: Arc<AtomicU64>,
    pub(super) playback_epoch: Arc<AtomicU64>,
    pub(super) strict_bit_perfect: Arc<AtomicBool>,
    pub(super) telemetry: Arc<RtTelemetry>,
    pub(super) slot_ptrs: [*mut RtWireInboxPayload; 2],
    pub(super) wire: WireSampleFormat,
    pub(super) out_rate: u32,
    pub(super) out_channels: usize,
    pub(super) clock_rate: u32,
    pub(super) skip_fade: LinearFadeState,
    pub(super) active_skip_seq: Option<(u64, usize)>,
    pub(super) crossfade_active: bool,
    pub(super) crossfade_pos: usize,
    pub(super) crossfade_frames: usize,
    pub(super) crossfade_target_deck: usize,
    pub(super) crossfade_resume_frame: u64,
    pub(super) drain_notified: bool,
}

unsafe impl Send for DualDeckWireFeeder {}

impl DualDeckWireFeeder {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        dual: Arc<DualDeckControl>,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        buffered_ms: Arc<AtomicU64>,
        gapless_transitions: Arc<AtomicU64>,
        underrun_count: Arc<AtomicU64>,
        playback_epoch: Arc<AtomicU64>,
        strict_bit_perfect: Arc<AtomicBool>,
        telemetry: Arc<RtTelemetry>,
        active_deck: usize,
        initial_payload: RtWireInboxPayload,
    ) -> Self {
        let wire = initial_payload.wire;
        let out_rate = initial_payload.out_rate.max(8_000);
        let out_channels = initial_payload.out_channels.max(1) as usize;
        let clock_rate = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
            (out_rate / 8).max(44_100)
        } else {
            out_rate
        };
        let mut slot_ptrs = [null_mut(), null_mut()];
        slot_ptrs[active_deck & 1] = Box::into_raw(Box::new(initial_payload));
        let crossfade_frames =
            ((clock_rate as u64 * MISMATCH_CROSSFADE_MS) / 1000).clamp(32, 2048) as usize;
        let mut feeder = Self {
            dual,
            frames_rendered,
            nonzero_frames,
            buffered_ms,
            gapless_transitions,
            underrun_count,
            playback_epoch,
            strict_bit_perfect,
            telemetry,
            slot_ptrs,
            wire,
            out_rate,
            out_channels,
            clock_rate,
            skip_fade: LinearFadeState::new(clock_rate, false, true, false),
            active_skip_seq: None,
            crossfade_active: false,
            crossfade_pos: 0,
            crossfade_frames,
            crossfade_target_deck: 1 - (active_deck & 1),
            crossfade_resume_frame: 0,
            drain_notified: false,
        };
        let _ = feeder.poll_inbox();
        feeder
    }

    #[inline]
    pub(crate) fn poll_inbox(&mut self) -> Option<usize> {
        let cur = self.dual.active_idx();
        let mut swapped_active_wm = None;
        for i in 0..2 {
            let incoming = self.dual.wire_inbox[i].swap(null_mut(), Ordering::AcqRel);
            if !incoming.is_null() {
                let wm = unsafe { (*incoming).watermark_bytes };
                let old = std::mem::replace(&mut self.slot_ptrs[i], incoming);
                if !old.is_null() {
                    self.dual.retire_wire_ptr(old);
                }
                if i == cur {
                    self.drain_notified = false;
                    self.active_skip_seq = None;
                    self.crossfade_active = false;
                    swapped_active_wm = Some(wm);
                }
            }
        }
        swapped_active_wm
    }

    #[inline]
    pub(crate) fn active_epoch_pair(&mut self) -> (u64, u64) {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return (0, 0);
        }
        let slot = unsafe { &*self.slot_ptrs[cur] };
        (slot.consumer.requested_epoch(), slot.last_ring_epoch)
    }

    #[inline]
    pub(crate) fn sync_active_epoch(&mut self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        let slot = unsafe { &mut *self.slot_ptrs[cur] };
        if slot.consumer.has_pending_flush() {
            let _ = slot.consumer.try_flush_and_ack();
        }
        slot.last_ring_epoch = slot.consumer.epoch();
        slot.watermark_bytes
    }

    #[inline]
    #[allow(dead_code)]
    pub(crate) fn handle_active_flush(&mut self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        let slot = unsafe { &mut *self.slot_ptrs[cur] };
        if slot.consumer.has_pending_flush() {
            let _ = slot.consumer.try_flush_and_ack();
        } else {
            let _ = slot.consumer.try_clear();
        }
        slot.last_ring_epoch = slot.consumer.epoch();
        slot.watermark_bytes
    }

    #[inline]
    pub(crate) fn active_available_read(&mut self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        unsafe { (*self.slot_ptrs[cur]).consumer.available_read() }
    }

    #[inline]
    pub(crate) fn active_eof_reached(&self) -> bool {
        let cur = self.dual.active_idx();
        self.dual.deck_eof_flags[cur].load(Ordering::Acquire)
    }

    #[inline]
    pub(crate) fn active_watermark_bytes(&self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            0
        } else {
            unsafe { (*self.slot_ptrs[cur]).watermark_bytes }
        }
    }

    #[inline]
    pub(crate) fn update_active_buffered_ms(&mut self, bpf: usize) {
        let cur = self.dual.active_idx();
        let avail = self.active_available_read();
        let frames_avail = (avail / bpf.max(1)) as u64;
        let bms = (frames_avail * 1000) / (self.clock_rate.max(8_000) as u64);
        self.buffered_ms.store(bms, Ordering::Relaxed);
        self.dual.deck_buffered_ms[cur].store(bms, Ordering::Relaxed);
    }

    #[inline]
    pub(crate) fn pop_active_raw(&mut self, dst: &mut [u8]) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        let bpf = self.wire.bytes_per_sample().max(1) * self.out_channels.max(1);
        unsafe { (*self.slot_ptrs[cur]).consumer.pop_slice_aligned(dst, bpf) }
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
        self.frames_rendered.store(resume_frame, Ordering::SeqCst);
        if kind != RtTransitionKind::MismatchCrossfadeFlip {
            self.dual.swap_generation.fetch_add(1, Ordering::Release);
            self.playback_epoch.fetch_add(1, Ordering::Release);
        }
        self.dual
            .push_rt_event(kind, from_deck as u8, to_deck as u8, tgen);
    }
}

impl Drop for DualDeckWireFeeder {
    fn drop(&mut self) {
        let cur = self.dual.active_idx();
        for i in 0..2 {
            let ptr = std::mem::replace(&mut self.slot_ptrs[i], null_mut());
            if !ptr.is_null() {
                let boxed = unsafe { Box::from_raw(ptr) };
                if i != cur
                    && self.dual.deck_state(i) == DeckState::StandbyReady
                    && let Ok(mut pg) = self.dual.standby_pending_wire[i].lock()
                    && pg.is_none()
                {
                    *pg = Some(*boxed);
                }
            }
        }
        self.dual.drain_retired_payloads();
    }
}
