//! Lock-free, bounded RT-safe `Consumer` implementation for [`super::SpscRingBuffer`].

use std::sync::Arc;
use std::sync::atomic::Ordering;

use super::{Consumer, RingBufferControl, epoch_lt, unpack_epoch_idx};

impl<T: Copy + Default> Consumer<T> {
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
        let req = self.inner.epoch.requested_epoch.0.load(Ordering::Acquire);
        req != self.local_epoch || self.synced_barrier_epoch != self.local_epoch
    }

    /// Bounded epoch barrier sync safe for RT audio callbacks (at most 16 spin checks per transition).
    #[inline]
    fn sync_consumer_epoch(&mut self) -> Result<usize, ()> {
        const MAX_RT_BARRIER_RETRIES: usize = 16;

        let initial_tail = self.local_tail;

        let h = self.inner.epoch.head_epoch.0.load(Ordering::Acquire);
        let (w_epoch, mut head) = unpack_epoch_idx(h);

        if epoch_lt(self.synced_barrier_epoch, w_epoch) {
            let mut synced = false;
            for _ in 0..MAX_RT_BARRIER_RETRIES {
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
            for _ in 0..MAX_RT_BARRIER_RETRIES {
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

    /// Bounded, RT-safe flush acknowledgment for real-time audio callbacks.
    /// Returns `Some(discarded)` when synced, or `None` if the producer is mid-barrier update
    /// (allowing the RT callback to output silence and retry on the next period without blocking).
    #[inline]
    pub fn try_flush_and_ack(&mut self) -> Option<usize> {
        self.sync_consumer_epoch().ok()
    }

    /// Synchronizes the consumer to the latest flush epoch, discarding all pre-flush items and
    /// acknowledging the flush. Returns the number of stale elements discarded.
    ///
    /// **Non-RT / test helper only**: retries until barrier observation completes.
    /// Real-time audio callbacks MUST use [`Self::try_flush_and_ack`] instead.
    pub fn flush_and_ack(&mut self) -> usize {
        loop {
            if let Ok(discarded) = self.sync_consumer_epoch() {
                return discarded;
            }
            std::hint::spin_loop();
        }
    }

    /// Bounded, RT-safe clear for real-time audio callbacks. Returns `Some(discarded)` if
    /// cleared cleanly, or `None` if a concurrent producer epoch transition is still in progress.
    #[inline]
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
    ///
    /// **Non-RT / test helper only**: retries until barrier observation completes.
    /// Real-time audio callbacks MUST use [`Self::try_clear`] instead.
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

    #[inline]
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

    #[inline]
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

    #[inline]
    pub fn is_empty(&mut self) -> bool {
        self.available_read() == 0
    }

    /// Pops elements into `out`. Returns the number of elements read (0 if empty or flush pending).
    /// Strictly bounded, lock-free, zero-allocation (RT-safe).
    #[inline]
    pub fn pop_slice(&mut self, out: &mut [T]) -> usize {
        self.pop_slice_aligned(out, 1)
    }

    /// Pops whole `align`-element frames into `out`, leaving partial trailing frames unread.
    /// Strictly bounded, lock-free, zero-allocation (RT-safe).
    #[inline]
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
                if self.sync_consumer_epoch().is_err()
                    || self.synced_barrier_epoch != self.local_epoch
                {
                    return 0;
                }
                let tail2 = self.local_tail;
                let available2 = self.cached_head.wrapping_sub(tail2) as usize;
                return self.copy_out(tail2, available2, out, align);
            }
        }

        self.copy_out(tail, available, out, align)
    }

    #[inline]
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

    /// Pops a single element. Returns `Some(item)` if available, `None` if empty.
    #[inline]
    pub fn pop(&mut self) -> Option<T> {
        let mut item = [T::default()];
        if self.pop_slice(&mut item) == 1 {
            Some(item[0])
        } else {
            None
        }
    }
}
