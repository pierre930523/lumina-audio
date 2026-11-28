//! Lock-free, cache-line-padded, epoch-aware SPSC ring buffer and hard real-time [`UnderrunGuard`].
//!
//! All real-time consumer hot-path methods (`pop`, `pop_slice`, `pop_slice_aligned`,
//! `try_flush_and_ack`, `try_clear`, `available_read`, `is_empty`) perform strictly bounded work
//! with zero locks, zero heap allocations, zero logging, and zero syscalls.

mod consumer;
mod spsc;
mod underrun;

pub use spsc::{Consumer, Producer, SpscRingBuffer};
pub use underrun::UnderrunGuard;

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

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
pub(super) const fn pack_epoch_idx(epoch: u32, idx: u32) -> u64 {
    ((epoch as u64) << 32) | (idx as u64)
}

#[inline]
pub(super) const fn unpack_epoch_idx(v: u64) -> (u32, u32) {
    ((v >> 32) as u32, v as u32)
}

#[inline]
pub(super) const fn epoch_lt(a: u32, b: u32) -> bool {
    (a.wrapping_sub(b) as i32) < 0
}

/// Shared lock-free epoch coordination state for [`SpscRingBuffer`].
#[derive(Debug)]
pub struct EpochShared {
    pub(super) requested_epoch: CachePadded<AtomicU32>,
    pub(super) producer_epoch: CachePadded<AtomicU32>,
    pub(super) consumer_epoch: CachePadded<AtomicU32>,
    /// Packed `(writer_epoch: u32, head: u32)` — exclusively written by `Producer`.
    pub(super) head_epoch: CachePadded<AtomicU64>,
    /// Packed `(barrier_epoch: u32, barrier_head: u32)` — exclusively written by `Producer`.
    pub(super) barrier: CachePadded<AtomicU64>,
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

#[cfg(test)]
mod tests {
    use super::{SpscRingBuffer, UnderrunGuard};
    use crate::pipeline::rt_telemetry::RtTelemetry;
    use crate::verification::WireSampleFormat;

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
                assert!(pushed.is_multiple_of(6));
                next_push += (pushed / 6) as u32;
            }

            let read = cons.pop_slice_aligned(&mut pop_buf, 6);
            assert!(read.is_multiple_of(6));
            for frame in pop_buf[..read].as_chunks::<6>().0 {
                let b = next_pop.to_le_bytes();
                assert_eq!(*frame, [b[0], b[1], b[2], b[3], 0xA5, 0x5A]);
                next_pop += 1;
            }
        }
    }

    #[test]
    fn underrun_guard_fills_pcm_dsd_and_dop_silence_properly() {
        let mut phase = false;

        // PCM -> 0x00
        let mut pcm = [0xAAu8; 16];
        UnderrunGuard::fill_wire_silence(&mut pcm, WireSampleFormat::Int16Le, &mut phase);
        assert!(pcm.iter().all(|&b| b == 0x00));

        // Native DSD -> 0x69
        let mut dsd = [0x00u8; 16];
        UnderrunGuard::fill_wire_silence(
            &mut dsd,
            WireSampleFormat::NativeDsd { channels: 2 },
            &mut phase,
        );
        assert!(dsd.iter().all(|&b| b == 0x69));

        // DoP stereo -> alternating 0x05 / 0xFA marker per 2-channel (8-byte) frame + 0x69 payload
        let mut dop = [0x00u8; 16];
        UnderrunGuard::fill_wire_silence(
            &mut dop,
            WireSampleFormat::Dop24In32MsbLe {
                channels: 2,
                is_lsb_first: false,
            },
            &mut phase,
        );
        assert_eq!(
            dop,
            [
                0x00, 0x69, 0x69, 0x05, 0x00, 0x69, 0x69, 0x05, // Frame 0 (L, R)
                0x00, 0x69, 0x69, 0xFA, 0x00, 0x69, 0x69, 0xFA, // Frame 1 (L, R)
            ]
        );
        assert!(!phase);
    }

    #[test]
    fn underrun_guard_respects_strict_bit_perfect_and_increments_xrun() {
        let telemetry = RtTelemetry::new();
        let mut phase = false;

        // Strict Bit-Perfect: valid prefix must remain bit-exact; suffix zeroed; XRUN += 1.
        let mut strict_buf = [0xFFu8; 16];
        let valid_orig: Vec<u8> = [12_000i16, -12_000, 12_000, -12_000]
            .iter()
            .flat_map(|s| s.to_le_bytes())
            .collect();
        strict_buf[..8].copy_from_slice(&valid_orig);

        UnderrunGuard::handle_wire_underrun(
            &mut strict_buf,
            8,
            WireSampleFormat::Int16Le,
            2,
            true,
            &mut phase,
            Some(&telemetry),
        );
        assert_eq!(&strict_buf[..8], valid_orig.as_slice());
        assert_eq!(&strict_buf[8..], &[0u8; 8]);
        assert_eq!(telemetry.xrun_count(), 1);

        // Non-strict PCM: valid tail is faded to 0 on final frame; suffix zeroed; XRUN += 1.
        let mut non_strict_buf = [0xFFu8; 16];
        non_strict_buf[..8].copy_from_slice(&valid_orig);
        UnderrunGuard::handle_wire_underrun(
            &mut non_strict_buf,
            8,
            WireSampleFormat::Int16Le,
            2,
            false,
            &mut phase,
            Some(&telemetry),
        );
        assert_eq!(&non_strict_buf[4..8], &[0u8; 4]); // final valid frame faded to exact 0
        assert_eq!(&non_strict_buf[8..], &[0u8; 8]);
        assert_eq!(telemetry.xrun_count(), 2);

        // f32 strict vs non-strict
        let mut f32_strict = [0.8f32, -0.8, 0.8, -0.8, 1.0, 1.0];
        UnderrunGuard::handle_f32_underrun(&mut f32_strict, 4, 2, true, Some(&telemetry));
        assert_eq!(f32_strict, [0.8, -0.8, 0.8, -0.8, 0.0, 0.0]);
        assert_eq!(telemetry.xrun_count(), 3);

        let mut f32_fade = [0.8f32, -0.8, 0.8, -0.8, 1.0, 1.0];
        UnderrunGuard::handle_f32_underrun(&mut f32_fade, 4, 2, false, Some(&telemetry));
        assert_eq!(&f32_fade[2..], &[0.0, 0.0, 0.0, 0.0]);
        assert_eq!(telemetry.xrun_count(), 4);
    }
}
