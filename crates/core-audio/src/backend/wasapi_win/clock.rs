use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

use core_types::ChannelLayout;

use crate::verification::WireSampleFormat;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WasapiExclusiveOpenSpec {
    pub device_id: Option<String>,
    pub sample_rate: u32,
    pub channels: u16,
    pub layout: ChannelLayout,
    pub wire_format: WireSampleFormat,
    pub is_dop: bool,
    pub buffer_frames_hint: u32,
}

/// Hardware clock snapshot captured on the WASAPI MTA render thread via `IAudioClock::GetPosition`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WasapiClockSnapshot {
    pub position: u64,
    pub frequency: u64,
    pub qpc_100ns: u64,
    pub clock_epoch: u64,
    pub sample_rate: u32,
}

#[doc(hidden)]
pub struct WasapiClockState {
    pub(super) seq: AtomicU64,
    pub(super) hw_pos_raw: AtomicU64,
    pub(super) hw_freq: AtomicU64,
    pub(super) hw_qpc_100ns: AtomicU64,
    pub(super) clock_epoch: AtomicU64,
    pub(super) sample_rate: AtomicU32,
    pub(super) hw_valid: AtomicBool,
    pub(super) last_pos_in_epoch: AtomicU64,
}

impl WasapiClockState {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            seq: AtomicU64::new(0),
            hw_pos_raw: AtomicU64::new(0),
            hw_freq: AtomicU64::new(0),
            hw_qpc_100ns: AtomicU64::new(0),
            clock_epoch: AtomicU64::new(0),
            sample_rate: AtomicU32::new(sample_rate),
            hw_valid: AtomicBool::new(false),
            last_pos_in_epoch: AtomicU64::new(0),
        }
    }

    pub fn set_frequency(&self, freq: u64) {
        if freq > 0 {
            self.hw_freq.store(freq, Ordering::Release);
        }
    }

    pub fn record_position(&self, raw_pos: u64, qpc_100ns: u64) {
        if self.hw_freq.load(Ordering::Acquire) == 0 {
            return;
        }
        let prev = self.last_pos_in_epoch.load(Ordering::Relaxed);
        let mono_pos = raw_pos.max(prev);
        let s = self.seq.load(Ordering::Relaxed);
        self.seq.store(s.wrapping_add(1), Ordering::Release);
        std::sync::atomic::fence(Ordering::Release);
        self.last_pos_in_epoch.store(mono_pos, Ordering::Relaxed);
        self.hw_pos_raw.store(mono_pos, Ordering::Relaxed);
        self.hw_qpc_100ns.store(qpc_100ns, Ordering::Relaxed);
        self.hw_valid.store(true, Ordering::Relaxed);
        self.seq.store(s.wrapping_add(2), Ordering::Release);
    }

    pub fn on_reset(&self) {
        let s = self.seq.load(Ordering::Relaxed);
        self.seq.store(s.wrapping_add(1), Ordering::Release);
        std::sync::atomic::fence(Ordering::Release);
        self.last_pos_in_epoch.store(0, Ordering::Relaxed);
        self.hw_pos_raw.store(0, Ordering::Relaxed);
        self.hw_qpc_100ns.store(0, Ordering::Relaxed);
        self.clock_epoch.fetch_add(1, Ordering::Relaxed);
        self.seq.store(s.wrapping_add(2), Ordering::Release);
    }

    pub fn snapshot(&self) -> Option<WasapiClockSnapshot> {
        for _ in 0..8 {
            let s1 = self.seq.load(Ordering::Acquire);
            if s1 & 1 != 0 {
                std::hint::spin_loop();
                continue;
            }
            if !self.hw_valid.load(Ordering::Acquire) {
                return None;
            }
            let position = self.hw_pos_raw.load(Ordering::Relaxed);
            let frequency = self.hw_freq.load(Ordering::Relaxed);
            let qpc_100ns = self.hw_qpc_100ns.load(Ordering::Relaxed);
            let clock_epoch = self.clock_epoch.load(Ordering::Relaxed);
            let sample_rate = self.sample_rate.load(Ordering::Relaxed);
            std::sync::atomic::fence(Ordering::Acquire);
            let s2 = self.seq.load(Ordering::Acquire);
            if s1 == s2 {
                if frequency == 0 {
                    return None;
                }
                return Some(WasapiClockSnapshot {
                    position,
                    frequency,
                    qpc_100ns,
                    clock_epoch,
                    sample_rate,
                });
            }
        }
        None
    }

    pub fn hardware_position_frames(&self) -> Option<u64> {
        let snap = self.snapshot()?;
        Some(((snap.position as u128 * snap.sample_rate as u128) / snap.frequency as u128) as u64)
    }

    pub fn clock_position_ns(&self) -> Option<u64> {
        let snap = self.snapshot()?;
        Some(((snap.position as u128 * 1_000_000_000u128) / snap.frequency as u128) as u64)
    }
}

/// Fills `dst` with format-appropriate silence (`0x69` for Native DSD, alternating DoP v1.1
/// `0x05`/`0xFA` + `0x69` frames for DoP, `0x00` for PCM).
pub fn fill_wasapi_wire_silence(
    dst: &mut [u8],
    wire: WireSampleFormat,
    channels: u16,
    dop_phase: &mut bool,
) {
    match wire {
        WireSampleFormat::NativeDsd { .. } => {
            dst.fill(0x69);
        }
        WireSampleFormat::Dop24In32MsbLe { .. } => {
            let ch = channels.max(1) as usize;
            let frame_bytes = ch * 4;
            let aligned = (dst.len() / frame_bytes) * frame_bytes;
            for frame in dst[..aligned].chunks_exact_mut(frame_bytes) {
                let marker = if *dop_phase { 0xFAu8 } else { 0x05u8 };
                *dop_phase = !*dop_phase;
                for sample in frame.as_chunks_mut::<4>().0 {
                    sample[0] = 0x00;
                    sample[1] = 0x69;
                    sample[2] = 0x69;
                    sample[3] = marker;
                }
            }
            if aligned < dst.len() {
                dst[aligned..].fill(0x00);
            }
        }
        _ => {
            dst.fill(0x00);
        }
    }
}

#[inline]
pub(super) fn wasapi_chunk_has_nonzero(data: &[u8], wire: WireSampleFormat) -> bool {
    match wire {
        WireSampleFormat::NativeDsd { .. } => data.iter().any(|&b| b != 0x69),
        WireSampleFormat::Dop24In32MsbLe { .. } => data.as_chunks::<4>().0.iter().any(|s| {
            s[0] != 0x00 || s[1] != 0x69 || s[2] != 0x69 || (s[3] != 0x05 && s[3] != 0xFA)
        }),
        _ => data.iter().any(|&b| b != 0),
    }
}
