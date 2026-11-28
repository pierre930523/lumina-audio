//! Core SPSC ring buffer storage and lock-free `Producer` implementation.

use std::cell::UnsafeCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

use super::{CachePadded, EpochShared, RingBufferControl, pack_epoch_idx};

/// Internal shared storage for the lock-free SPSC ring buffer.
pub struct SpscRingBuffer<T> {
    pub(super) buffer: Box<[UnsafeCell<T>]>,
    pub(super) capacity: usize,
    pub(super) mask: usize,
    /// Exclusively written by `Consumer`.
    pub(super) tail: CachePadded<AtomicU32>,
    pub(super) epoch: Arc<EpochShared>,
}

unsafe impl<T: Send> Send for SpscRingBuffer<T> {}
unsafe impl<T: Send> Sync for SpscRingBuffer<T> {}

/// Producer handle for the lock-free SPSC ring buffer.
pub struct Producer<T> {
    inner: Arc<SpscRingBuffer<T>>,
    cached_tail: u32,
    local_epoch: u32,
    local_head: u32,
}

unsafe impl<T: Send> Send for Producer<T> {}

/// Consumer handle for the lock-free SPSC ring buffer.
pub struct Consumer<T> {
    pub(super) inner: Arc<SpscRingBuffer<T>>,
    pub(super) cached_head: u32,
    pub(super) local_tail: u32,
    pub(super) local_epoch: u32,
    pub(super) synced_barrier_epoch: u32,
}

unsafe impl<T: Send> Send for Consumer<T> {}

impl<T: Copy + Default> SpscRingBuffer<T> {
    /// Creates a new lock-free SPSC ring buffer with capacity rounded up to next power of two.
    #[allow(clippy::new_ret_no_self)]
    pub fn new(capacity: usize) -> (Producer<T>, Consumer<T>) {
        let cap = capacity.max(2).next_power_of_two();
        assert!(cap <= (1 << 30), "SpscRingBuffer capacity must be <= 2^30");

        let raw_box: Box<[T]> = vec![T::default(); cap].into_boxed_slice();
        let raw_ptr = Box::into_raw(raw_box) as *mut [UnsafeCell<T>];
        // SAFETY: `UnsafeCell<T>` is `#[repr(transparent)]` and has identical layout to `T`.
        let buffer = unsafe { Box::from_raw(raw_ptr) };

        let epoch = Arc::new(EpochShared {
            requested_epoch: CachePadded(AtomicU32::new(0)),
            producer_epoch: CachePadded(AtomicU32::new(0)),
            consumer_epoch: CachePadded(AtomicU32::new(0)),
            head_epoch: CachePadded(AtomicU64::new(0)),
            barrier: CachePadded(AtomicU64::new(0)),
        });

        let ring = Arc::new(Self {
            buffer,
            capacity: cap,
            mask: cap - 1,
            tail: CachePadded(AtomicU32::new(0)),
            epoch,
        });

        let producer = Producer {
            inner: Arc::clone(&ring),
            cached_tail: 0,
            local_epoch: 0,
            local_head: 0,
        };
        let consumer = Consumer {
            inner: ring,
            cached_head: 0,
            local_tail: 0,
            local_epoch: 0,
            synced_barrier_epoch: 0,
        };

        (producer, consumer)
    }
}

impl<T: Copy> Producer<T> {
    #[inline]
    pub fn capacity(&self) -> usize {
        self.inner.capacity
    }

    pub fn control(&self) -> RingBufferControl {
        RingBufferControl {
            shared: Arc::clone(&self.inner.epoch),
        }
    }

    pub fn request_flush(&self) -> u64 {
        self.inner
            .epoch
            .requested_epoch
            .0
            .fetch_add(1, Ordering::SeqCst)
            .wrapping_add(1) as u64
    }

    #[inline]
    pub fn epoch(&self) -> u64 {
        self.local_epoch as u64
    }

    #[inline]
    pub fn requested_epoch(&self) -> u64 {
        self.inner.epoch.requested_epoch.0.load(Ordering::Acquire) as u64
    }

    #[inline]
    pub fn has_pending_flush(&self) -> bool {
        self.inner.epoch.requested_epoch.0.load(Ordering::Acquire) != self.local_epoch
    }

    /// Acknowledges any pending flush epoch and establishes the SPSC flush barrier at `local_head`.
    /// Must only be called by the single `Producer` after it has discarded/seeked its pre-flush source.
    pub fn sync_epoch(&mut self) -> u64 {
        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        if req != self.local_epoch {
            let packed = pack_epoch_idx(req, self.local_head);
            self.inner.epoch.barrier.0.store(packed, Ordering::Release);
            self.inner
                .epoch
                .head_epoch
                .0
                .store(packed, Ordering::Release);
            self.local_epoch = req;
            self.inner
                .epoch
                .producer_epoch
                .0
                .store(req, Ordering::Release);
            self.cached_tail = self.inner.tail.0.load(Ordering::Acquire);
        }
        self.local_epoch as u64
    }

    #[inline]
    pub fn available_write(&mut self) -> usize {
        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        if req != self.local_epoch {
            return 0;
        }
        self.cached_tail = self.inner.tail.0.load(Ordering::Acquire);
        let cap = self.inner.capacity as u32;
        let used = self.local_head.wrapping_sub(self.cached_tail);
        cap.saturating_sub(used) as usize
    }

    #[inline]
    pub fn is_full(&mut self) -> bool {
        self.available_write() == 0
    }

    /// Pushes a slice into the ring buffer. Returns the number of elements written (0 if full or flush pending).
    #[inline]
    pub fn push_slice(&mut self, data: &[T]) -> usize {
        self.push_slice_aligned(data, 1)
    }

    /// Pushes whole `align`-element frames into the ring buffer, never writing partial frames.
    #[inline]
    pub fn push_slice_aligned(&mut self, data: &[T], align: usize) -> usize {
        if data.is_empty() {
            return 0;
        }
        let align = align.max(1);

        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        if req != self.local_epoch {
            return 0;
        }

        let cap = self.inner.capacity as u32;
        let head = self.local_head;
        let used = head.wrapping_sub(self.cached_tail);
        let mut available = cap.saturating_sub(used) as usize;
        if available < data.len() {
            self.cached_tail = self.inner.tail.0.load(Ordering::Acquire);
            let used = head.wrapping_sub(self.cached_tail);
            available = cap.saturating_sub(used) as usize;
        }

        let raw_write = data.len().min(available);
        let to_write = (raw_write / align) * align;
        if to_write == 0 {
            return 0;
        }

        let mask = self.inner.mask;
        let start = (head as usize) & mask;
        let end = (start + to_write).min(self.inner.capacity);
        let first_len = end - start;

        unsafe {
            let buf_ptr = self.inner.buffer.as_ptr() as *mut T;
            std::ptr::copy_nonoverlapping(data.as_ptr(), buf_ptr.add(start), first_len);
            if to_write > first_len {
                let second_len = to_write - first_len;
                std::ptr::copy_nonoverlapping(data.as_ptr().add(first_len), buf_ptr, second_len);
            }
        }

        let new_head = head.wrapping_add(to_write as u32);
        self.local_head = new_head;
        self.inner.epoch.head_epoch.0.store(
            pack_epoch_idx(self.local_epoch, new_head),
            Ordering::Release,
        );
        to_write
    }

    /// Pushes `data` only if `epoch` matches the current requested epoch, syncing `Producer` if needed.
    /// Returns `Err(latest_requested_epoch)` if `epoch` is stale or a concurrent flush superseded it.
    pub fn push_with_epoch(&mut self, epoch: u64, data: &[T]) -> Result<usize, u64> {
        self.push_with_epoch_aligned(epoch, data, 1)
    }

    /// Pushes whole `align`-element frames only if `epoch` matches the current requested epoch.
    pub fn push_with_epoch_aligned(
        &mut self,
        epoch: u64,
        data: &[T],
        align: usize,
    ) -> Result<usize, u64> {
        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire) as u64;
        if epoch != req {
            return Err(req);
        }
        if (self.local_epoch as u64) != epoch {
            self.sync_epoch();
            let req2 = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire) as u64;
            if epoch != req2 {
                return Err(req2);
            }
        }
        let written = self.push_slice_aligned(data, align);
        if written == 0 && !data.is_empty() {
            let req3 = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire) as u64;
            if req3 != epoch {
                return Err(req3);
            }
        }
        Ok(written)
    }

    /// Pushes a single element into the buffer. Returns true if successful, false if full or flush pending.
    #[inline]
    pub fn push(&mut self, item: T) -> bool {
        self.push_slice(&[item]) == 1
    }
}
