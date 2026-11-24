use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

/// Cache-line padding wrapper ensuring alignment to 64 bytes to eliminate false sharing between CPU cores.
#[repr(align(64))]
#[derive(Debug)]
pub struct CachePadded<T>(pub T);

impl<T> std::ops::Deref for CachePadded<T> {
    type Target = T;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl<T> std::ops::DerefMut for CachePadded<T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

#[inline]
const fn pack_epoch_idx(epoch: u32, idx: u32) -> u64 {
    ((epoch as u64) << 32) | (idx as u64)
}

#[inline]
const fn unpack_epoch_idx(v: u64) -> (u32, u32) {
    ((v >> 32) as u32, v as u32)
}

#[inline]
const fn epoch_lt(a: u32, b: u32) -> bool {
    (a.wrapping_sub(b) as i32) < 0
}

#[derive(Debug)]
struct EpochShared {
    requested_epoch: CachePadded<AtomicU32>,
    producer_epoch: CachePadded<AtomicU32>,
    consumer_epoch: CachePadded<AtomicU32>,
    /// Packed `(writer_epoch: u32, head: u32)` — exclusively written by `Producer`.
    head_epoch: CachePadded<AtomicU64>,
    /// Packed `(barrier_epoch: u32, barrier_head: u32)` — exclusively written by `Producer`.
    barrier: CachePadded<AtomicU64>,
}

/// Non-generic, thread-safe flush/epoch coordination handle for [`SpscRingBuffer`].
/// Can be stored in `AudioPlayer` / `ActiveSession` regardless of element type (`u8` vs `f32`).
#[derive(Debug, Clone)]
pub struct RingBufferControl {
    shared: Arc<EpochShared>,
}

impl RingBufferControl {
    /// Requests a ring-buffer flush by advancing the generation epoch.
    /// Returns the newly requested epoch.
    pub fn request_flush(&self) -> u64 {
        self.shared
            .requested_epoch
            .0
            .fetch_add(1, Ordering::SeqCst)
            .wrapping_add(1) as u64
    }

    /// Returns the latest requested epoch.
    pub fn epoch(&self) -> u64 {
        self.shared.requested_epoch.0.load(Ordering::Acquire) as u64
    }

    /// Returns the latest epoch acknowledged by the `Producer`.
    pub fn producer_epoch(&self) -> u64 {
        self.shared.producer_epoch.0.load(Ordering::Acquire) as u64
    }

    /// Returns the latest epoch acknowledged by the `Consumer`.
    pub fn consumer_epoch(&self) -> u64 {
        self.shared.consumer_epoch.0.load(Ordering::Acquire) as u64
    }

    /// Returns `true` when both `Producer` and `Consumer` have observed the latest requested epoch.
    pub fn is_flushed(&self) -> bool {
        let req = self.shared.requested_epoch.0.load(Ordering::Acquire);
        let prod = self.shared.producer_epoch.0.load(Ordering::Acquire);
        let cons = self.shared.consumer_epoch.0.load(Ordering::Acquire);
        prod == req && cons == req
    }

    /// Returns `true` when the `Consumer` has synced to the latest requested epoch.
    pub fn is_consumer_synced(&self) -> bool {
        let req = self.shared.requested_epoch.0.load(Ordering::Acquire);
        let cons = self.shared.consumer_epoch.0.load(Ordering::Acquire);
        cons == req
    }
}

/// Internal shared storage for the lock-free SPSC ring buffer.
pub struct SpscRingBuffer<T> {
    buffer: Box<[UnsafeCell<T>]>,
    capacity: usize,
    mask: usize,
    /// Exclusively written by `Consumer`.
    tail: CachePadded<AtomicU32>,
    epoch: Arc<EpochShared>,
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
    inner: Arc<SpscRingBuffer<T>>,
    cached_head: u32,
    local_tail: u32,
    local_epoch: u32,
    synced_barrier_epoch: u32,
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

    pub fn epoch(&self) -> u64 {
        self.local_epoch as u64
    }

    pub fn requested_epoch(&self) -> u64 {
        self.inner.epoch.requested_epoch.0.load(Ordering::Acquire) as u64
    }

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
            self.inner.epoch.head_epoch.0.store(packed, Ordering::Release);
            self.local_epoch = req;
            self.inner.epoch.producer_epoch.0.store(req, Ordering::Release);
            self.cached_tail = self.inner.tail.0.load(Ordering::Acquire);
        }
        self.local_epoch as u64
    }

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

    pub fn is_full(&mut self) -> bool {
        self.available_write() == 0
    }

    /// Pushes a slice into the ring buffer. Returns the number of elements written (0 if full or flush pending).
    pub fn push_slice(&mut self, data: &[T]) -> usize {
        self.push_slice_aligned(data, 1)
    }

    /// Pushes whole `align`-element frames into the ring buffer, never writing partial frames.
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
        self.inner
            .epoch
            .head_epoch
            .0
            .store(pack_epoch_idx(self.local_epoch, new_head), Ordering::Release);
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
    pub fn push(&mut self, item: T) -> bool {
        self.push_slice(&[item]) == 1
    }
}

impl<T: Copy + Default> Consumer<T> {
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

    pub fn epoch(&self) -> u64 {
        self.local_epoch as u64
    }

    pub fn requested_epoch(&self) -> u64 {
        self.inner.epoch.requested_epoch.0.load(Ordering::Acquire) as u64
    }

    pub fn has_pending_flush(&self) -> bool {
        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        req != self.local_epoch || self.synced_barrier_epoch != self.local_epoch
    }

    fn sync_consumer_epoch(&mut self) -> Result<usize, ()> {
        let initial_tail = self.local_tail;

        let h = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
        let (w_epoch, mut head) = unpack_epoch_idx(h);

        if epoch_lt(self.synced_barrier_epoch, w_epoch) {
            let mut synced = false;
            for _ in 0..64 {
                let b = self.inner.epoch.barrier.0.load(Ordering::Acquire);
                let (b_epoch, b_head) = unpack_epoch_idx(b);
                let h2 = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
                let (w_epoch2, head2) = unpack_epoch_idx(h2);
                if b_epoch == w_epoch2 {
                    self.local_tail = b_head;
                    self.synced_barrier_epoch = w_epoch2;
                    if epoch_lt(self.local_epoch, w_epoch2) {
                        self.local_epoch = w_epoch2;
                    }
                    head = head2;
                    synced = true;
                    break;
                }
                std::hint::spin_loop();
            }
            if !synced {
                return Err(());
            }
        }

        let latest_req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        if epoch_lt(self.local_epoch, latest_req) {
            self.local_epoch = latest_req;
        }

        let h3 = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
        let (w_epoch3, head3) = unpack_epoch_idx(h3);
        if epoch_lt(w_epoch3, self.local_epoch) {
            // Producer has not synced yet for `self.local_epoch`: discard pre-flush writes up to `head3`.
            self.local_tail = head3;
            head = head3;
        } else if epoch_lt(self.synced_barrier_epoch, w_epoch3) {
            let mut synced = false;
            for _ in 0..64 {
                let b = self.inner.epoch.barrier.0.load(Ordering::Acquire);
                let (b_epoch, b_head) = unpack_epoch_idx(b);
                let h4 = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
                let (w_epoch4, head4) = unpack_epoch_idx(h4);
                if b_epoch == w_epoch4 {
                    self.local_tail = b_head;
                    self.synced_barrier_epoch = w_epoch4;
                    if epoch_lt(self.local_epoch, w_epoch4) {
                        self.local_epoch = w_epoch4;
                    }
                    head = head4;
                    synced = true;
                    break;
                }
                std::hint::spin_loop();
            }
            if !synced {
                return Err(());
            }
        }

        self.cached_head = head;
        let discarded = self.local_tail.wrapping_sub(initial_tail) as usize;
        if discarded > 0 {
            self.inner.tail.0.store(self.local_tail, Ordering::Release);
        }
        self.inner
            .epoch
            .consumer_epoch
            .0
            .store(self.local_epoch, Ordering::Release);
        Ok(discarded)
    }

    /// Bounded, wait-free flush acknowledgment for real-time audio callbacks.
    /// Returns `Some(discarded)` when synced, or `None` if the producer is mid-barrier update
    /// (allowing the RT callback to output silence and retry on the next period without spinning).
    #[inline]
    pub fn try_flush_and_ack(&mut self) -> Option<usize> {
        self.sync_consumer_epoch().ok()
    }

    /// Synchronizes the consumer to the latest flush epoch, discarding all pre-flush items and
    /// acknowledging the flush. Returns the number of stale elements discarded.
    pub fn flush_and_ack(&mut self) -> usize {
        loop {
            if let Ok(discarded) = self.sync_consumer_epoch() {
                return discarded;
            }
        }
    }

    /// Bounded, wait-free clear for real-time audio callbacks. Returns `Some(discarded)` if
    /// cleared cleanly, or `None` if a concurrent producer epoch transition is still in progress.
    pub fn try_clear(&mut self) -> Option<usize> {
        let initial_tail = self.local_tail;
        for _ in 0..8 {
            self.sync_consumer_epoch().ok()?;
            let h = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
            let (w_epoch, head) = unpack_epoch_idx(h);
            if !epoch_lt(self.synced_barrier_epoch, w_epoch) {
                self.local_tail = head;
                self.cached_head = head;
                let discarded = self.local_tail.wrapping_sub(initial_tail) as usize;
                if discarded > 0 {
                    self.inner.tail.0.store(self.local_tail, Ordering::Release);
                }
                return Some(discarded);
            }
            std::hint::spin_loop();
        }
        None
    }

    /// Discards all currently buffered elements from the consumer side in O(1) without data races.
    /// Returns the number of elements discarded.
    pub fn clear(&mut self) -> usize {
        let initial_tail = self.local_tail;
        let head_to_set;
        loop {
            let _ = self.flush_and_ack();
            let h = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
            let (w_epoch, head) = unpack_epoch_idx(h);
            if !epoch_lt(self.synced_barrier_epoch, w_epoch) {
                head_to_set = head;
                break;
            }
            std::hint::spin_loop();
        }
        self.local_tail = head_to_set;
        self.cached_head = head_to_set;
        let discarded = self.local_tail.wrapping_sub(initial_tail) as usize;
        if discarded > 0 {
            self.inner.tail.0.store(self.local_tail, Ordering::Release);
        }
        discarded
    }

    pub fn available_read(&mut self) -> usize {
        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        if req == self.local_epoch && self.synced_barrier_epoch == self.local_epoch {
            let tail = self.local_tail;
            let h = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
            let (w_epoch, head) = unpack_epoch_idx(h);
            if w_epoch == self.local_epoch {
                self.cached_head = head;
                return head.wrapping_sub(tail) as usize;
            }
            return self.peek_unsynced_available();
        }
        self.peek_unsynced_available()
    }

    fn peek_unsynced_available(&self) -> usize {
        for _ in 0..8 {
            let latest_req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
            let b = self.inner.epoch.barrier.0.load(Ordering::Acquire);
            let (b_epoch, b_head) = unpack_epoch_idx(b);
            let h = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
            let (w_epoch, head) = unpack_epoch_idx(h);

            if epoch_lt(w_epoch, latest_req) {
                return 0;
            }
            if b_epoch == w_epoch {
                let effective_tail = if epoch_lt(self.synced_barrier_epoch, w_epoch) {
                    b_head
                } else {
                    self.local_tail
                };
                return head.wrapping_sub(effective_tail) as usize;
            }
            std::hint::spin_loop();
        }
        0
    }

    pub fn is_empty(&mut self) -> bool {
        self.available_read() == 0
    }

    /// Pops elements into `out`. Returns the number of elements read (0 if empty or flush pending).
    pub fn pop_slice(&mut self, out: &mut [T]) -> usize {
        self.pop_slice_aligned(out, 1)
    }

    /// Pops whole `align`-element frames into `out`, leaving partial trailing frames unread.
    pub fn pop_slice_aligned(&mut self, out: &mut [T], align: usize) -> usize {
        if out.is_empty() {
            return 0;
        }
        let align = align.max(1);

        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        if req != self.local_epoch || self.synced_barrier_epoch != self.local_epoch {
            if self.sync_consumer_epoch().is_err() {
                return 0;
            }
            if self.synced_barrier_epoch != self.local_epoch {
                return 0;
            }
        }

        let tail = self.local_tail;
        let mut available = self.cached_head.wrapping_sub(tail) as usize;
        if available < out.len() {
            let h = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
            let (w_epoch, new_head) = unpack_epoch_idx(h);
            if w_epoch == self.local_epoch {
                self.cached_head = new_head;
                available = self.cached_head.wrapping_sub(tail) as usize;
            } else {
                // Producer already moved to a newer epoch; sync first before reading.
                if self.sync_consumer_epoch().is_err() || self.synced_barrier_epoch != self.local_epoch {
                    return 0;
                }
                let tail2 = self.local_tail;
                let available2 = self.cached_head.wrapping_sub(tail2) as usize;
                return self.copy_out(tail2, available2, out, align);
            }
        }

        self.copy_out(tail, available, out, align)
    }

    fn copy_out(&mut self, tail: u32, available: usize, out: &mut [T], align: usize) -> usize {
        let to_read = (out.len().min(available) / align) * align;
        if to_read == 0 {
            return 0;
        }

        let mask = self.inner.mask;
        let start = (tail as usize) & mask;
        let end = (start + to_read).min(self.inner.capacity);
        let first_len = end - start;

        unsafe {
            let buf_ptr = self.inner.buffer.as_ptr() as *const T;
            std::ptr::copy_nonoverlapping(buf_ptr.add(start), out.as_mut_ptr(), first_len);
            if to_read > first_len {
                let second_len = to_read - first_len;
                std::ptr::copy_nonoverlapping(buf_ptr, out.as_mut_ptr().add(first_len), second_len);
            }
        }

        let new_tail = tail.wrapping_add(to_read as u32);
        self.local_tail = new_tail;
        self.inner.tail.0.store(new_tail, Ordering::Release);
        to_read
    }

    /// Pops a single element. Returns Some(item) if available, None if empty.
    pub fn pop(&mut self) -> Option<T> {
        let mut item = [T::default()];
        if self.pop_slice(&mut item) == 1 {
            Some(item[0])
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SpscRingBuffer;

    #[test]
    fn aligned_push_and_pop_preserves_6_byte_frames_across_wraparounds() {
        // Capacity 64 is not divisible by 6 (64 % 6 == 4), exercising partial-capacity wraparounds.
        let (mut prod, mut cons) = SpscRingBuffer::<u8>::new(64);
        let total_frames: u32 = 500;
        let mut next_push: u32 = 0;
        let mut next_pop: u32 = 0;
        let mut pop_buf = [0u8; 29]; // Intentionally non-multiple of 6.

        while next_pop < total_frames {
            if next_push < total_frames {
                let batch_frames = ((total_frames - next_push).min(4)) as usize;
                let mut src = Vec::with_capacity(batch_frames * 6);
                for f in next_push..next_push + batch_frames as u32 {
                    let b = f.to_le_bytes();
                    src.extend_from_slice(&[b[0], b[1], b[2], b[3], 0xA5, 0x5A]);
                }
                let pushed = prod.push_slice_aligned(&src, 6);
                assert_eq!(pushed % 6, 0);
                next_push += (pushed / 6) as u32;
            }

            let read = cons.pop_slice_aligned(&mut pop_buf, 6);
            assert_eq!(read % 6, 0);
            for frame in pop_buf[..read].chunks_exact(6) {
                let b = next_pop.to_le_bytes();
                assert_eq!(frame, [b[0], b[1], b[2], b[3], 0xA5, 0x5A]);
                next_pop += 1;
            }
        }
    }
}
