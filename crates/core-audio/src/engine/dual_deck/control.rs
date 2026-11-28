//! `DualDeckControl` state, lock-free RT transition ring, and inbox payload management.

use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock};
use std::thread;

use core_types::{DeckState, DeckTrackMetadata, StreamKey};

use super::decode_handle::{
    ActiveOutputProfile, DeckDecodeHandle, DeckMetadataSnapshot, RtPcmInboxPayload,
    RtWireInboxPayload,
};
use super::transition::{RtTransitionEvent, RtTransitionKind};

pub(super) const RT_EVENT_RING_LEN: usize = 16;
pub(super) const RT_RETIRE_RING_LEN: usize = 16;

pub(crate) struct DualDeckControl {
    pub(crate) active_deck_idx: Arc<AtomicU8>,
    pub(crate) deck_states: [Arc<AtomicU8>; 2],
    pub(crate) deck_keys: Arc<RwLock<[Option<StreamKey>; 2]>>,
    pub(crate) deck_eof_flags: [Arc<AtomicBool>; 2],
    pub(crate) deck_buffered_ms: [Arc<AtomicU64>; 2],
    pub(crate) deck_gens: [AtomicU64; 2],
    pub(crate) next_deck_gen: AtomicU64,
    pub(crate) standby_buffered_ms: Arc<AtomicU64>,
    pub(crate) manual_zero_latency_switches: Arc<AtomicU64>,
    pub(crate) format_mismatch_recoveries: Arc<AtomicU64>,
    pub(crate) standby_compatible: [Arc<AtomicBool>; 2],
    pub(crate) standby_is_mismatch_recovery: [Arc<AtomicBool>; 2],
    pub(crate) standby_target_pts_ms: [Arc<AtomicU64>; 2],
    pub(crate) standby_target_frame: [Arc<AtomicU64>; 2],
    pub(crate) deck_meta: [RwLock<Option<DeckMetadataSnapshot>>; 2],
    pub(crate) deck_track_meta: [RwLock<Option<DeckTrackMetadata>>; 2],
    pub(crate) swap_generation: Arc<AtomicU64>,
    pub(crate) committed_deck_gen: AtomicU64,
    pub(crate) active_profile: RwLock<Option<ActiveOutputProfile>>,
    pub(crate) decode_entries: [Mutex<Option<DeckDecodeHandle>>; 2],
    pub(crate) standby_pending_pcm: [Mutex<Option<RtPcmInboxPayload>>; 2],
    pub(crate) standby_pending_wire: [Mutex<Option<RtWireInboxPayload>>; 2],
    pub(crate) pcm_inbox: [AtomicPtr<RtPcmInboxPayload>; 2],
    pub(crate) wire_inbox: [AtomicPtr<RtWireInboxPayload>; 2],
    pub(crate) pcm_retire_ring: [AtomicPtr<RtPcmInboxPayload>; RT_RETIRE_RING_LEN],
    pub(crate) pcm_retire_head: AtomicUsize,
    pub(crate) pcm_retired_pending: AtomicUsize,
    pub(crate) wire_retire_ring: [AtomicPtr<RtWireInboxPayload>; RT_RETIRE_RING_LEN],
    pub(crate) wire_retire_head: AtomicUsize,
    pub(crate) wire_retired_pending: AtomicUsize,
    pub(crate) skip_request_seq: AtomicU64,
    pub(crate) skip_handled_seq: AtomicU64,
    pub(crate) skip_target_deck: AtomicU8,
    pub(crate) skip_lock: Mutex<()>,
    pub(crate) deck_lifecycle_locks: [Mutex<()>; 2],
    pub(crate) flip_done_sync: (Mutex<u64>, Condvar),
    pub(crate) mismatch_armed: AtomicBool,
    pub(crate) mismatch_target_deck: AtomicU8,
    pub(crate) mismatch_align_frame: AtomicU64,
    pub(crate) mismatch_resume_frame: AtomicU64,
    pub(crate) rt_events: [AtomicU64; RT_EVENT_RING_LEN],
    pub(crate) rt_event_head: AtomicUsize,
    pub(crate) rt_event_tail: AtomicUsize,
    pub(crate) relay_signal: AtomicU64,
    pub(crate) relay_thread: OnceLock<thread::Thread>,
    pub(crate) relay_stop: AtomicBool,
}

impl DualDeckControl {
    pub(crate) fn new() -> Self {
        Self {
            active_deck_idx: Arc::new(AtomicU8::new(0)),
            deck_states: [
                Arc::new(AtomicU8::new(DeckState::Idle as u8)),
                Arc::new(AtomicU8::new(DeckState::Idle as u8)),
            ],
            deck_keys: Arc::new(RwLock::new([None, None])),
            deck_eof_flags: [
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
            ],
            deck_buffered_ms: [Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0))],
            deck_gens: [AtomicU64::new(0), AtomicU64::new(0)],
            next_deck_gen: AtomicU64::new(1),
            standby_buffered_ms: Arc::new(AtomicU64::new(0)),
            manual_zero_latency_switches: Arc::new(AtomicU64::new(0)),
            format_mismatch_recoveries: Arc::new(AtomicU64::new(0)),
            standby_compatible: [
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
            ],
            standby_is_mismatch_recovery: [
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
            ],
            standby_target_pts_ms: [Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0))],
            standby_target_frame: [Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0))],
            deck_meta: [RwLock::new(None), RwLock::new(None)],
            deck_track_meta: [RwLock::new(None), RwLock::new(None)],
            swap_generation: Arc::new(AtomicU64::new(0)),
            committed_deck_gen: AtomicU64::new(0),
            active_profile: RwLock::new(None),
            decode_entries: [Mutex::new(None), Mutex::new(None)],
            standby_pending_pcm: [Mutex::new(None), Mutex::new(None)],
            standby_pending_wire: [Mutex::new(None), Mutex::new(None)],
            pcm_inbox: [AtomicPtr::new(null_mut()), AtomicPtr::new(null_mut())],
            wire_inbox: [AtomicPtr::new(null_mut()), AtomicPtr::new(null_mut())],
            pcm_retire_ring: std::array::from_fn(|_| AtomicPtr::new(null_mut())),
            pcm_retire_head: AtomicUsize::new(0),
            pcm_retired_pending: AtomicUsize::new(0),
            wire_retire_ring: std::array::from_fn(|_| AtomicPtr::new(null_mut())),
            wire_retire_head: AtomicUsize::new(0),
            wire_retired_pending: AtomicUsize::new(0),
            skip_request_seq: AtomicU64::new(0),
            skip_handled_seq: AtomicU64::new(0),
            skip_target_deck: AtomicU8::new(1),
            skip_lock: Mutex::new(()),
            deck_lifecycle_locks: [Mutex::new(()), Mutex::new(())],
            flip_done_sync: (Mutex::new(0), Condvar::new()),
            mismatch_armed: AtomicBool::new(false),
            mismatch_target_deck: AtomicU8::new(1),
            mismatch_align_frame: AtomicU64::new(0),
            mismatch_resume_frame: AtomicU64::new(0),
            rt_events: std::array::from_fn(|_| AtomicU64::new(0)),
            rt_event_head: AtomicUsize::new(0),
            rt_event_tail: AtomicUsize::new(0),
            relay_signal: AtomicU64::new(0),
            relay_thread: OnceLock::new(),
            relay_stop: AtomicBool::new(false),
        }
    }

    #[inline]
    pub(crate) fn active_idx(&self) -> usize {
        (self.active_deck_idx.load(Ordering::Acquire) & 1) as usize
    }

    #[inline]
    pub(crate) fn standby_idx(&self) -> usize {
        1 - self.active_idx()
    }

    #[inline]
    pub(crate) fn deck_state(&self, idx: usize) -> DeckState {
        DeckState::from_u8(self.deck_states[idx & 1].load(Ordering::Acquire))
    }

    #[inline]
    pub(crate) fn deck_gen_for(&self, idx: usize) -> u64 {
        self.deck_gens[idx & 1].load(Ordering::Acquire)
    }

    pub(crate) fn alloc_deck_gen(&self, idx: usize) -> u64 {
        let dgen = self.next_deck_gen.fetch_add(1, Ordering::SeqCst).max(1);
        self.deck_gens[idx & 1].store(dgen, Ordering::SeqCst);
        dgen
    }

    pub(crate) fn set_deck_key(&self, idx: usize, key: Option<StreamKey>) {
        if let Ok(mut g) = self.deck_keys.write() {
            g[idx & 1] = key;
        }
    }

    pub(crate) fn set_deck_track_meta(&self, idx: usize, meta: Option<DeckTrackMetadata>) {
        if let Ok(mut g) = self.deck_track_meta[idx & 1].write() {
            *g = meta;
        }
    }

    #[inline]
    pub(crate) fn unpark_relay(&self) {
        if let Some(th) = self.relay_thread.get() {
            th.unpark();
        }
    }

    pub(crate) fn stop_relay(&self) {
        self.relay_stop.store(true, Ordering::SeqCst);
        self.unpark_relay();
    }

    /// Strictly RT-safe notification signal polled by `relay_loop` (zero OS syscalls).
    #[inline]
    pub(crate) fn signal_relay_rt(&self) {
        self.relay_signal.fetch_add(1, Ordering::Release);
    }

    #[inline]
    pub(crate) fn push_rt_event(
        &self,
        kind: RtTransitionKind,
        from_deck: u8,
        to_deck: u8,
        to_deck_gen: u64,
    ) {
        let idx = self.rt_event_head.fetch_add(1, Ordering::Relaxed) % RT_EVENT_RING_LEN;
        let packed = RtTransitionEvent {
            kind,
            from_deck,
            to_deck,
            to_deck_gen,
        }
        .pack();
        self.rt_events[idx].store(packed, Ordering::Release);
        // RT-4: Strictly atomic signal only; never invoke Thread::unpark() syscall on RT thread.
        self.signal_relay_rt();
    }

    pub(crate) fn pop_rt_event(&self) -> Option<RtTransitionEvent> {
        let head = self.rt_event_head.load(Ordering::Acquire);
        let mut tail = self.rt_event_tail.load(Ordering::Relaxed);
        while tail < head {
            let slot = tail % RT_EVENT_RING_LEN;
            let raw = self.rt_events[slot].swap(0, Ordering::AcqRel);
            tail += 1;
            self.rt_event_tail.store(tail, Ordering::Release);
            if raw != 0
                && let Some(evt) = RtTransitionEvent::unpack(raw)
            {
                return Some(evt);
            }
        }
        None
    }

    /// Strictly RT-safe retirement of a swapped PCM inbox payload using CAS slot search
    /// (zero dealloc, zero locks, zero syscalls; off-RT `drain_retired_payloads` reclaims memory).
    #[inline]
    pub(crate) fn retire_pcm_ptr(&self, ptr: *mut RtPcmInboxPayload) {
        if ptr.is_null() {
            return;
        }
        let start = self.pcm_retire_head.fetch_add(1, Ordering::Relaxed);
        for probe in 0..RT_RETIRE_RING_LEN {
            let slot = (start + probe) % RT_RETIRE_RING_LEN;
            if self.pcm_retire_ring[slot]
                .compare_exchange(null_mut(), ptr, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                self.pcm_retired_pending.fetch_add(1, Ordering::Release);
                self.signal_relay_rt();
                return;
            }
        }
        self.signal_relay_rt();
    }

    /// Strictly RT-safe retirement of a swapped wire inbox payload using CAS slot search.
    #[inline]
    pub(crate) fn retire_wire_ptr(&self, ptr: *mut RtWireInboxPayload) {
        if ptr.is_null() {
            return;
        }
        let start = self.wire_retire_head.fetch_add(1, Ordering::Relaxed);
        for probe in 0..RT_RETIRE_RING_LEN {
            let slot = (start + probe) % RT_RETIRE_RING_LEN;
            if self.wire_retire_ring[slot]
                .compare_exchange(null_mut(), ptr, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                self.wire_retired_pending.fetch_add(1, Ordering::Release);
                self.signal_relay_rt();
                return;
            }
        }
        self.signal_relay_rt();
    }

    pub(crate) fn drain_retired_payloads(&self) {
        for slot in &self.pcm_retire_ring {
            let ptr = slot.swap(null_mut(), Ordering::AcqRel);
            if !ptr.is_null() {
                let _ =
                    self.pcm_retired_pending
                        .try_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                            Some(n.saturating_sub(1))
                        });
                unsafe {
                    drop(Box::from_raw(ptr));
                }
            }
        }
        for slot in &self.wire_retire_ring {
            let ptr = slot.swap(null_mut(), Ordering::AcqRel);
            if !ptr.is_null() {
                let _ = self.wire_retired_pending.try_update(
                    Ordering::AcqRel,
                    Ordering::Acquire,
                    |n| Some(n.saturating_sub(1)),
                );
                unsafe {
                    drop(Box::from_raw(ptr));
                }
            }
        }
    }

    pub(crate) fn clear_inboxes_for_deck(&self, idx: usize) {
        let i = idx & 1;
        let p = self.pcm_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !p.is_null() {
            unsafe {
                drop(Box::from_raw(p));
            }
        }
        let w = self.wire_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !w.is_null() {
            unsafe {
                drop(Box::from_raw(w));
            }
        }
        if let Ok(mut g) = self.standby_pending_pcm[i].lock() {
            *g = None;
        }
        if let Ok(mut g) = self.standby_pending_wire[i].lock() {
            *g = None;
        }
    }

    pub(crate) fn send_pcm_inbox(&self, idx: usize, payload: RtPcmInboxPayload) {
        self.drain_retired_payloads();
        let boxed = Box::into_raw(Box::new(payload));
        let prev = self.pcm_inbox[idx & 1].swap(boxed, Ordering::AcqRel);
        if !prev.is_null() {
            unsafe {
                drop(Box::from_raw(prev));
            }
        }
    }

    pub(crate) fn send_wire_inbox(&self, idx: usize, payload: RtWireInboxPayload) {
        self.drain_retired_payloads();
        let boxed = Box::into_raw(Box::new(payload));
        let prev = self.wire_inbox[idx & 1].swap(boxed, Ordering::AcqRel);
        if !prev.is_null() {
            unsafe {
                drop(Box::from_raw(prev));
            }
        }
    }

    pub(crate) fn take_standby_pcm_payload(&self, idx: usize) -> Option<RtPcmInboxPayload> {
        let i = idx & 1;
        let ptr = self.pcm_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !ptr.is_null() {
            return Some(unsafe { *Box::from_raw(ptr) });
        }
        self.standby_pending_pcm[i]
            .lock()
            .ok()
            .and_then(|mut g| g.take())
    }

    pub(crate) fn take_standby_wire_payload(&self, idx: usize) -> Option<RtWireInboxPayload> {
        let i = idx & 1;
        let ptr = self.wire_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !ptr.is_null() {
            return Some(unsafe { *Box::from_raw(ptr) });
        }
        self.standby_pending_wire[i]
            .lock()
            .ok()
            .and_then(|mut g| g.take())
    }
}
