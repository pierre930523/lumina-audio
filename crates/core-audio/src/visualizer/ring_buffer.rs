use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use super::{FFT_SIZE, MAX_FREQ, MIN_FREQ, NUM_BANDS};

#[repr(align(64))]
pub(super) struct CacheAligned<T>(pub(super) T);

/// Wait-free RAII release guard for [`VisualizerRingBuffer::producer_busy`].
struct ProducerBusyGuard<'a>(&'a AtomicBool);

impl Drop for ProducerBusyGuard<'_> {
    #[inline]
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

/// Lock-free single-producer single-consumer circular buffer for mono f32 PCM samples.
/// Designed for real-time audio threads: pushing is strictly non-blocking, lock-free, wait-free
/// drop-on-contention, and zero-allocation.
pub struct VisualizerRingBuffer {
    buffer: Box<[UnsafeCell<f32>]>,
    capacity: usize,
    mask: usize,
    /// Producer-owned write cursor on its own 64-byte cache line.
    head: CacheAligned<AtomicUsize>,
    /// Wait-free multi-producer contention guard (drop-on-contention, zero blocking).
    pub(super) producer_busy: CacheAligned<AtomicBool>,
    /// Consumer-owned read cursor on its own 64-byte cache line (never mutated by UI/producer).
    tail: CacheAligned<AtomicUsize>,
    /// Cross-thread clear request flag serviced exclusively on the consumer thread.
    clear_requested: CacheAligned<AtomicBool>,
}

unsafe impl Send for VisualizerRingBuffer {}
unsafe impl Sync for VisualizerRingBuffer {}

impl VisualizerRingBuffer {
    pub fn new(capacity: usize) -> Self {
        let cap = capacity.max(FFT_SIZE * 2).next_power_of_two();
        let mut v = Vec::with_capacity(cap);
        for _ in 0..cap {
            v.push(UnsafeCell::new(0.0f32));
        }
        Self {
            buffer: v.into_boxed_slice(),
            capacity: cap,
            mask: cap - 1,
            head: CacheAligned(AtomicUsize::new(0)),
            producer_busy: CacheAligned(AtomicBool::new(false)),
            tail: CacheAligned(AtomicUsize::new(0)),
            clear_requested: CacheAligned(AtomicBool::new(false)),
        }
    }

    /// Audio thread: wait-free, non-blocking push. Never blocks or allocates.
    /// If another producer is concurrently pushing during a transition, drops this frame
    /// immediately rather than racing on `UnsafeCell` writes.
    pub fn push_slice(&self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        if self.producer_busy.0.swap(true, Ordering::Acquire) {
            return;
        }
        let _guard = ProducerBusyGuard(&self.producer_busy.0);

        let head = self.head.0.load(Ordering::Relaxed);
        let tail = self.tail.0.load(Ordering::Acquire);
        let used = head.wrapping_sub(tail);
        let free = self.capacity.saturating_sub(used);
        let count = samples.len().min(free);
        if count == 0 {
            return;
        }

        for (i, &s) in samples[..count].iter().enumerate() {
            let idx = (head.wrapping_add(i)) & self.mask;
            unsafe {
                *self.buffer[idx].get() = s;
            }
        }
        self.head
            .0
            .store(head.wrapping_add(count), Ordering::Release);
    }

    /// Requests that the consumer thread clear the ring buffer on its next cycle.
    /// Safe to invoke from any thread without racing on `tail`.
    #[inline]
    pub fn request_clear(&self) {
        self.clear_requested.0.store(true, Ordering::Release);
    }

    /// Services a pending clear request on the sole consumer thread by advancing `tail = head`.
    #[inline]
    pub(crate) fn service_clear_request(&self) -> bool {
        if self.clear_requested.0.swap(false, Ordering::AcqRel) {
            let head = self.head.0.load(Ordering::Acquire);
            self.tail.0.store(head, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// Analysis worker thread: reads latest 2048 samples up to current head.
    /// Returns true if at least FFT_SIZE samples are available.
    /// Advances tail with 50% overlap hop to maintain strict lip-sync without drift.
    pub fn read_latest(&self, out: &mut [f32; FFT_SIZE]) -> bool {
        let _ = self.service_clear_request();

        let head = self.head.0.load(Ordering::Acquire);
        let tail = self.tail.0.load(Ordering::Relaxed);
        let available = head.wrapping_sub(tail);
        if available < FFT_SIZE {
            return false;
        }

        // Read the most recent FFT_SIZE samples up to head
        let start = head.wrapping_sub(FFT_SIZE);
        for (i, dst) in out.iter_mut().enumerate() {
            let idx = (start.wrapping_add(i)) & self.mask;
            unsafe {
                *dst = *self.buffer[idx].get();
            }
        }

        // Retain 50% overlap (1024 samples) for next frame, preventing lag accumulation
        let new_tail = head.wrapping_sub(FFT_SIZE / 2);
        self.tail.0.store(new_tail, Ordering::Release);
        true
    }

    /// Requests clearing the ring buffer safely via the consumer-side clear flag
    /// (never writes `tail` directly from non-consumer threads).
    #[inline]
    pub fn clear(&self) {
        self.request_clear();
    }
}

/// Generates a precomputed 2048-point Hann window.
pub fn generate_hann_window() -> [f32; FFT_SIZE] {
    let mut w = [0.0f32; FFT_SIZE];
    let n_minus_1 = (FFT_SIZE - 1) as f32;
    for (n, slot) in w.iter_mut().enumerate() {
        *slot = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * (n as f32) / n_minus_1).cos());
    }
    w
}

/// Generates 65 logarithmic frequency band edges (~30 Hz to 18 kHz) using formula:
/// f_edge[m] = 30.0 * (18000.0 / 30.0)^(m / 64)
pub fn generate_band_edges() -> [f32; NUM_BANDS + 1] {
    let mut edges = [0.0f32; NUM_BANDS + 1];
    let ratio = MAX_FREQ / MIN_FREQ;
    for (m, slot) in edges.iter_mut().enumerate() {
        *slot = MIN_FREQ * ratio.powf(m as f32 / NUM_BANDS as f32);
    }
    edges
}
