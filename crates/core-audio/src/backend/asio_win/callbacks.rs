use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use crate::pipeline::rt_telemetry::{RtErrorCode, RtTelemetry};
use crate::verification::WireSampleFormat;

use super::ffi_types::{
    K_ASIO_BUFFER_SIZE_CHANGE, K_ASIO_ENGINE_VERSION, K_ASIO_LATENCIES_CHANGED,
    K_ASIO_RESET_REQUEST, K_ASIO_RESYNC_REQUEST, K_ASIO_SELECTOR_SUPPORTED,
    K_ASIO_SUPPORTS_TIME_INFO,
};

/// Lock-free ASIO hardware clock snapshot captured inside `bufferSwitch` / `bufferSwitchTimeInfo`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AsioClockSnapshot {
    pub sample_position: u64,
    pub system_time_ns: u64,
    pub output_latency_frames: u32,
    pub sample_rate: u32,
    pub callback_count: u64,
}

/// Shared lock-free / wait-free control & telemetry signals for ASIO callbacks and `AsioNativeSession`.
#[doc(hidden)]
pub struct AsioCallbackSignals {
    pub flush_requested_epoch: AtomicU64,
    pub flush_completed_epoch: AtomicU64,
    pub eof_drained: AtomicBool,
    pub eof_target_state: AtomicI32,
    pub reset_requested: AtomicBool,
    pub resync_requested: AtomicBool,
    pub latencies_changed: AtomicBool,
    pub requested_buffer_size: AtomicI32,
    pub device_lost: Arc<AtomicBool>,
    pub resync_count: AtomicU64,
    pub output_latency_frames: AtomicU32,
    pub sample_rate: AtomicU32,
    pub observed_driver_sample_rate: AtomicU32,
    pub format_mismatch_flag: Arc<AtomicBool>,
    pub published_format_stamp: Arc<AtomicU64>,
    pub expected_format_stamp: AtomicU64,
    pub hw_sample_pos: AtomicU64,
    pub hw_timestamp_ns: AtomicU64,
    pub hw_clock_valid: AtomicBool,
    pub callback_count: AtomicU64,
    pub underrun_count: Arc<AtomicU64>,
    pub telemetry: Arc<RtTelemetry>,
    pub strict_bit_perfect: AtomicBool,
    pub(super) clock_seq: AtomicU64,
    pub last_error: Arc<RwLock<Option<String>>>,
}

impl AsioCallbackSignals {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            flush_requested_epoch: AtomicU64::new(0),
            flush_completed_epoch: AtomicU64::new(0),
            eof_drained: AtomicBool::new(false),
            eof_target_state: AtomicI32::new(1),
            reset_requested: AtomicBool::new(false),
            resync_requested: AtomicBool::new(false),
            latencies_changed: AtomicBool::new(false),
            requested_buffer_size: AtomicI32::new(0),
            device_lost: Arc::new(AtomicBool::new(false)),
            resync_count: AtomicU64::new(0),
            output_latency_frames: AtomicU32::new(0),
            sample_rate: AtomicU32::new(sample_rate),
            observed_driver_sample_rate: AtomicU32::new(0),
            format_mismatch_flag: Arc::new(AtomicBool::new(false)),
            published_format_stamp: Arc::new(AtomicU64::new(0)),
            expected_format_stamp: AtomicU64::new(0),
            hw_sample_pos: AtomicU64::new(0),
            hw_timestamp_ns: AtomicU64::new(0),
            hw_clock_valid: AtomicBool::new(false),
            callback_count: AtomicU64::new(0),
            underrun_count: Arc::new(AtomicU64::new(0)),
            telemetry: Arc::new(RtTelemetry::new()),
            strict_bit_perfect: AtomicBool::new(false),
            clock_seq: AtomicU64::new(0),
            last_error: Arc::new(RwLock::new(None)),
        }
    }

    pub fn with_underrun_counter(mut self, underrun_count: Arc<AtomicU64>) -> Self {
        self.underrun_count = underrun_count;
        self
    }

    pub fn with_telemetry(mut self, telemetry: Arc<RtTelemetry>) -> Self {
        self.telemetry = telemetry;
        self
    }

    pub fn with_strict_bit_perfect(self, strict_bit_perfect: bool) -> Self {
        self.strict_bit_perfect
            .store(strict_bit_perfect, Ordering::Release);
        self
    }

    pub fn set_strict_bit_perfect(&self, strict_bit_perfect: bool) {
        self.strict_bit_perfect
            .store(strict_bit_perfect, Ordering::Release);
    }

    #[inline]
    pub fn is_strict_bit_perfect(&self) -> bool {
        self.strict_bit_perfect.load(Ordering::Relaxed)
    }

    pub fn telemetry(&self) -> Arc<RtTelemetry> {
        Arc::clone(&self.telemetry)
    }

    pub fn with_phase3_guards(
        mut self,
        device_lost: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        format_mismatch_flag: Arc<AtomicBool>,
        published_format_stamp: Arc<AtomicU64>,
        expected_format_stamp: u64,
    ) -> Self {
        self.device_lost = device_lost;
        self.last_error = last_error;
        self.format_mismatch_flag = format_mismatch_flag;
        self.published_format_stamp = published_format_stamp;
        self.expected_format_stamp = AtomicU64::new(expected_format_stamp);
        self
    }

    /// Wait-free update when the ASIO driver reports `sampleRateDidChange(s_rate)`.
    pub fn on_sample_rate_changed(&self, s_rate: f64) {
        if s_rate.is_finite() && s_rate > 0.0 && s_rate <= u32::MAX as f64 {
            let hz = s_rate.round() as u32;
            self.observed_driver_sample_rate
                .store(hz, Ordering::Release);
            let expected_hz = self.sample_rate.load(Ordering::Relaxed);
            if expected_hz != 0 && hz != expected_hz {
                self.format_mismatch_flag.store(true, Ordering::Release);
            }
        }
    }

    pub fn is_format_mismatch(&self) -> bool {
        self.format_mismatch_flag.load(Ordering::Acquire)
    }

    pub fn request_flush(&self) -> u64 {
        self.flush_requested_epoch
            .fetch_add(1, Ordering::SeqCst)
            .wrapping_add(1)
    }

    pub fn record_clock(&self, sample_position: u64, system_time_ns: u64) {
        let s = self.clock_seq.load(Ordering::Relaxed);
        self.clock_seq.store(s.wrapping_add(1), Ordering::Release);
        std::sync::atomic::fence(Ordering::Release);
        self.hw_sample_pos.store(sample_position, Ordering::Relaxed);
        self.hw_timestamp_ns
            .store(system_time_ns, Ordering::Relaxed);
        self.hw_clock_valid.store(true, Ordering::Relaxed);
        self.clock_seq.store(s.wrapping_add(2), Ordering::Release);
    }

    pub fn clock_snapshot(&self) -> Option<AsioClockSnapshot> {
        for _ in 0..8 {
            let s1 = self.clock_seq.load(Ordering::Acquire);
            if s1 & 1 != 0 {
                std::hint::spin_loop();
                continue;
            }
            if !self.hw_clock_valid.load(Ordering::Acquire) {
                return None;
            }
            let sample_position = self.hw_sample_pos.load(Ordering::Relaxed);
            let system_time_ns = self.hw_timestamp_ns.load(Ordering::Relaxed);
            let output_latency_frames = self.output_latency_frames.load(Ordering::Relaxed);
            let sample_rate = self.sample_rate.load(Ordering::Relaxed);
            let callback_count = self.callback_count.load(Ordering::Relaxed);
            std::sync::atomic::fence(Ordering::Acquire);
            let s2 = self.clock_seq.load(Ordering::Acquire);
            if s1 == s2 {
                return Some(AsioClockSnapshot {
                    sample_position,
                    system_time_ns,
                    output_latency_frames,
                    sample_rate,
                    callback_count,
                });
            }
        }
        None
    }

    pub fn hardware_sample_position(&self) -> Option<u64> {
        self.clock_snapshot().map(|s| s.sample_position)
    }

    /// Handles Steinberg ASIO 2.x `asioMessage` selectors deterministically using wait-free atomics.
    pub fn handle_asio_message(&self, selector: i32, value: i32) -> i32 {
        match selector {
            K_ASIO_SELECTOR_SUPPORTED => match value {
                1..=7 => 1,
                _ => 0,
            },
            K_ASIO_ENGINE_VERSION => 2,
            K_ASIO_RESET_REQUEST => {
                self.reset_requested.store(true, Ordering::Release);
                self.telemetry.record_error_rt(RtErrorCode::DriverReset, 0);
                1
            }
            K_ASIO_BUFFER_SIZE_CHANGE => {
                self.requested_buffer_size.store(value, Ordering::Release);
                self.reset_requested.store(true, Ordering::Release);
                self.telemetry
                    .record_error_rt(RtErrorCode::DriverReset, value);
                1
            }
            K_ASIO_RESYNC_REQUEST => {
                self.resync_requested.store(true, Ordering::Release);
                self.resync_count.fetch_add(1, Ordering::Relaxed);
                1
            }
            K_ASIO_LATENCIES_CHANGED => {
                self.latencies_changed.store(true, Ordering::Release);
                1
            }
            K_ASIO_SUPPORTS_TIME_INFO => 1,
            _ => 0,
        }
    }
}

/// Returns the single-byte silence value for raw PCM (`0x00`) or Native DSD (`0x69`).
#[inline]
pub fn asio_silence_byte(wire: WireSampleFormat) -> u8 {
    if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        0x69
    } else {
        0x00
    }
}

/// Fills a single planar ASIO channel buffer slice with format-appropriate silence.
/// For `Dop24In32MsbLe`, emits alternating `0x05`/`0xFA` markers + `0x69` DSD payload so the DAC
/// preserves DoP lock across seeks, pauses, and underruns.
pub fn fill_asio_buffer_silence(
    dst: &mut [u8],
    wire: WireSampleFormat,
    drv_bps: usize,
    dop_marker_phase: &mut bool,
) {
    match wire {
        WireSampleFormat::NativeDsd { .. } => {
            dst.fill(0x69);
        }
        WireSampleFormat::Dop24In32MsbLe { .. } => {
            if drv_bps == 4 {
                let aligned = (dst.len() / 4) * 4;
                for sample in dst[..aligned].as_chunks_mut::<4>().0 {
                    let marker = if *dop_marker_phase { 0xFAu8 } else { 0x05u8 };
                    *dop_marker_phase = !*dop_marker_phase;
                    sample[0] = 0x00;
                    sample[1] = 0x69;
                    sample[2] = 0x69;
                    sample[3] = marker;
                }
                if aligned < dst.len() {
                    dst[aligned..].fill(0x00);
                }
            } else if drv_bps == 3 {
                let aligned = (dst.len() / 3) * 3;
                for sample in dst[..aligned].as_chunks_mut::<3>().0 {
                    let marker = if *dop_marker_phase { 0xFAu8 } else { 0x05u8 };
                    *dop_marker_phase = !*dop_marker_phase;
                    sample[0] = 0x69;
                    sample[1] = 0x69;
                    sample[2] = marker;
                }
                if aligned < dst.len() {
                    dst[aligned..].fill(0x00);
                }
            } else {
                dst.fill(0x00);
            }
        }
        _ => {
            dst.fill(0x00);
        }
    }
}

#[inline]
pub(super) fn asio_chunk_has_nonzero(data: &[u8], wire: WireSampleFormat) -> bool {
    match wire {
        WireSampleFormat::NativeDsd { .. } => data.iter().any(|&b| b != 0x69),
        WireSampleFormat::Dop24In32MsbLe { .. } => data.as_chunks::<4>().0.iter().any(|s| {
            s[0] != 0x00 || s[1] != 0x69 || s[2] != 0x69 || (s[3] != 0x05 && s[3] != 0xFA)
        }),
        _ => data.iter().any(|&b| b != 0),
    }
}

/// Tracks ASIO `bufferSwitch` callback progression to detect stalled/disconnected DAC drivers.
#[doc(hidden)]
pub struct AsioCallbackWatchdog {
    pub(super) stall_timeout: Duration,
    pub(super) last_count: u64,
    pub(super) last_progress_at: Instant,
    pub(super) was_active: bool,
}

impl AsioCallbackWatchdog {
    pub const DEFAULT_STALL_TIMEOUT: Duration = Duration::from_millis(1500);

    pub fn new(stall_timeout: Duration, initial_count: u64) -> Self {
        Self {
            stall_timeout,
            last_count: initial_count,
            last_progress_at: Instant::now(),
            was_active: false,
        }
    }

    /// Returns `true` when active playback has seen zero `bufferSwitch` progress for `>= stall_timeout`.
    pub fn check(&mut self, now: Instant, is_active: bool, callback_count: u64) -> bool {
        if !is_active {
            self.was_active = false;
            self.last_count = callback_count;
            self.last_progress_at = now;
            return false;
        }
        if !self.was_active || callback_count != self.last_count {
            self.was_active = true;
            self.last_count = callback_count;
            self.last_progress_at = now;
            return false;
        }
        now.saturating_duration_since(self.last_progress_at) >= self.stall_timeout
    }
}
