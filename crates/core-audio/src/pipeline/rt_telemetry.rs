//! Lock-free, cache-line-padded real-time telemetry shared between OS audio callbacks
//! and non-RT control/UI threads.
//!
//! Every `*_rt` method is strictly **No-Lock, No-Alloc, No-Log, No-Syscall**.

use std::fmt;
use std::sync::atomic::{AtomicI32, AtomicU32, AtomicU64, Ordering};

use crate::pipeline::ring_buffer::CachePadded;

/// Compact numeric error codes written atomically by real-time audio render threads.
///
/// Human-readable error formatting is performed lazily on non-RT threads via
/// [`RtTelemetry::format_last_error`], avoiding `String` allocations and locks on the RT path.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RtErrorCode {
    None = 0,
    DeviceInvalidated = 1,
    BufferGetFailed = 2,
    BufferReleaseFailed = 3,
    StreamStartFailed = 4,
    StreamStopFailed = 5,
    StreamResetFailed = 6,
    WaitFailed = 7,
    FormatMismatch = 8,
    ClockQueryFailed = 9,
    DriverReset = 10,
    Unknown = 255,
}

impl RtErrorCode {
    /// Converts a raw atomic `u32` code back into an [`RtErrorCode`].
    #[inline]
    pub const fn from_u32(v: u32) -> Self {
        match v {
            0 => Self::None,
            1 => Self::DeviceInvalidated,
            2 => Self::BufferGetFailed,
            3 => Self::BufferReleaseFailed,
            4 => Self::StreamStartFailed,
            5 => Self::StreamStopFailed,
            6 => Self::StreamResetFailed,
            7 => Self::WaitFailed,
            8 => Self::FormatMismatch,
            9 => Self::ClockQueryFailed,
            10 => Self::DriverReset,
            _ => Self::Unknown,
        }
    }

    /// Returns a static diagnostic description suitable for non-RT logging and UI display.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::None => "no error",
            Self::DeviceInvalidated => "audio device invalidated or disconnected",
            Self::BufferGetFailed => "hardware audio buffer acquisition failed",
            Self::BufferReleaseFailed => "hardware audio buffer release failed",
            Self::StreamStartFailed => "audio stream start failed",
            Self::StreamStopFailed => "audio stream stop failed",
            Self::StreamResetFailed => "audio stream reset failed",
            Self::WaitFailed => "audio render event wait failed",
            Self::FormatMismatch => "hardware wire format mismatch detected",
            Self::ClockQueryFailed => "hardware audio clock query failed",
            Self::DriverReset => "audio driver requested reset",
            Self::Unknown => "unknown real-time audio error",
        }
    }
}

impl fmt::Display for RtErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Cache-line-padded (`#[repr(align(64))]`) atomic telemetry container bridging hard real-time
/// audio render callbacks and non-RT monitoring/control threads.
#[derive(Debug)]
pub struct RtTelemetry {
    frames_played: CachePadded<AtomicU64>,
    xrun_count: CachePadded<AtomicU64>,
    peak_left_bits: CachePadded<AtomicU32>,
    peak_right_bits: CachePadded<AtomicU32>,
    last_error_code: CachePadded<AtomicU32>,
    last_error_hresult: CachePadded<AtomicI32>,
    generation: CachePadded<AtomicU64>,
}

impl Default for RtTelemetry {
    fn default() -> Self {
        Self::new()
    }
}

impl RtTelemetry {
    /// Creates a zero-initialized [`RtTelemetry`] instance (non-RT).
    pub fn new() -> Self {
        Self {
            frames_played: CachePadded(AtomicU64::new(0)),
            xrun_count: CachePadded(AtomicU64::new(0)),
            peak_left_bits: CachePadded(AtomicU32::new(0.0f32.to_bits())),
            peak_right_bits: CachePadded(AtomicU32::new(0.0f32.to_bits())),
            last_error_code: CachePadded(AtomicU32::new(RtErrorCode::None as u32)),
            last_error_hresult: CachePadded(AtomicI32::new(0)),
            generation: CachePadded(AtomicU64::new(0)),
        }
    }

    // ------------------------------------------------------------------------
    // Hard Real-Time Methods (Strictly No-Lock, No-Alloc, No-Log, No-Syscall)
    // ------------------------------------------------------------------------

    /// Accumulates hardware frames rendered in the current audio callback.
    #[inline]
    pub fn add_frames_rt(&self, frames: u64) {
        self.frames_played.0.fetch_add(frames, Ordering::Relaxed);
    }

    /// Increments the atomic underrun (XRUN) counter from the audio callback.
    #[inline]
    pub fn record_xrun_rt(&self) {
        self.xrun_count.0.fetch_add(1, Ordering::Relaxed);
    }

    /// Publishes instantaneous stereo peak levels from the audio callback.
    /// Non-finite (`NaN`/`Inf`) inputs are sanitized to `0.0`.
    #[inline]
    pub fn set_peaks_rt(&self, left: f32, right: f32) {
        let l = if left.is_finite() { left.abs() } else { 0.0 };
        let r = if right.is_finite() { right.abs() } else { 0.0 };
        self.peak_left_bits.0.store(l.to_bits(), Ordering::Relaxed);
        self.peak_right_bits.0.store(r.to_bits(), Ordering::Relaxed);
    }

    /// Records a real-time backend error code and platform status/HRESULT without locking or allocating.
    #[inline]
    pub fn record_error_rt(&self, code: RtErrorCode, hresult: i32) {
        // Store the status payload before publishing `last_error_code` with Release semantics so
        // non-RT observers using Acquire on `last_error_code` observe the paired status code.
        self.last_error_hresult.0.store(hresult, Ordering::Relaxed);
        self.last_error_code.0.store(code as u32, Ordering::Release);
    }

    /// Reads the current lifecycle/reconfigure generation counter (RT-safe).
    #[inline]
    pub fn generation(&self) -> u64 {
        self.generation.0.load(Ordering::Acquire)
    }

    // ------------------------------------------------------------------------
    // Non-RT Control / UI / Diagnostics Methods
    // ------------------------------------------------------------------------

    /// Returns total hardware frames rendered since creation or last [`Self::reset_counters`].
    #[inline]
    pub fn frames_played(&self) -> u64 {
        self.frames_played.0.load(Ordering::Relaxed)
    }

    /// Returns total buffer underruns (XRUNs) observed by the RT callback.
    #[inline]
    pub fn xrun_count(&self) -> u64 {
        self.xrun_count.0.load(Ordering::Relaxed)
    }

    /// Returns the most recently published `(left, right)` peak amplitudes.
    #[inline]
    pub fn peaks(&self) -> (f32, f32) {
        let left = f32::from_bits(self.peak_left_bits.0.load(Ordering::Relaxed));
        let right = f32::from_bits(self.peak_right_bits.0.load(Ordering::Relaxed));
        (left, right)
    }

    /// Returns the last recorded `(RtErrorCode, hresult)`, or `None` if no error is active.
    #[inline]
    pub fn last_error(&self) -> Option<(RtErrorCode, i32)> {
        let raw = self.last_error_code.0.load(Ordering::Acquire);
        let code = RtErrorCode::from_u32(raw);
        if code == RtErrorCode::None {
            None
        } else {
            let hr = self.last_error_hresult.0.load(Ordering::Relaxed);
            Some((code, hr))
        }
    }

    /// Lazily formats the last recorded RT error on a non-RT thread.
    pub fn format_last_error(&self) -> Option<String> {
        let (code, hr) = self.last_error()?;
        if hr != 0 {
            Some(format!("{} (HRESULT 0x{:08X})", code.as_str(), hr as u32))
        } else {
            Some(code.as_str().to_string())
        }
    }

    /// Clears the active RT error state (non-RT).
    pub fn clear_error(&self) {
        self.last_error_code
            .0
            .store(RtErrorCode::None as u32, Ordering::Release);
        self.last_error_hresult.0.store(0, Ordering::Relaxed);
    }

    /// Atomically advances and returns the new lifecycle generation counter (non-RT).
    pub fn bump_generation(&self) -> u64 {
        self.generation
            .0
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1)
    }

    /// Resets frame, XRUN, peak, and error telemetry counters while preserving `generation`.
    pub fn reset_counters(&self) {
        self.frames_played.0.store(0, Ordering::Relaxed);
        self.xrun_count.0.store(0, Ordering::Relaxed);
        self.peak_left_bits
            .0
            .store(0.0f32.to_bits(), Ordering::Relaxed);
        self.peak_right_bits
            .0
            .store(0.0f32.to_bits(), Ordering::Relaxed);
        self.clear_error();
    }
}

#[cfg(test)]
mod tests {
    use super::{RtErrorCode, RtTelemetry};
    use crate::pipeline::ring_buffer::CachePadded;
    use std::sync::atomic::AtomicU64;

    #[test]
    fn error_code_roundtrip_and_descriptions() {
        let known = [
            (0, RtErrorCode::None),
            (1, RtErrorCode::DeviceInvalidated),
            (2, RtErrorCode::BufferGetFailed),
            (3, RtErrorCode::BufferReleaseFailed),
            (4, RtErrorCode::StreamStartFailed),
            (5, RtErrorCode::StreamStopFailed),
            (6, RtErrorCode::StreamResetFailed),
            (7, RtErrorCode::WaitFailed),
            (8, RtErrorCode::FormatMismatch),
            (9, RtErrorCode::ClockQueryFailed),
            (10, RtErrorCode::DriverReset),
            (255, RtErrorCode::Unknown),
        ];
        for (raw, expected) in known {
            let parsed = RtErrorCode::from_u32(raw);
            assert_eq!(parsed, expected);
            assert!(!parsed.as_str().is_empty());
        }
        assert_eq!(RtErrorCode::from_u32(999), RtErrorCode::Unknown);
    }

    #[test]
    fn telemetry_counters_peaks_errors_and_generation() {
        assert_eq!(std::mem::align_of::<CachePadded<AtomicU64>>(), 64);

        let t = RtTelemetry::new();
        assert_eq!(t.frames_played(), 0);
        assert_eq!(t.xrun_count(), 0);
        assert_eq!(t.peaks(), (0.0, 0.0));
        assert_eq!(t.last_error(), None);
        assert_eq!(t.format_last_error(), None);
        assert_eq!(t.generation(), 0);

        t.add_frames_rt(256);
        t.add_frames_rt(512);
        t.record_xrun_rt();
        t.record_xrun_rt();
        t.set_peaks_rt(-0.75, 0.5);
        assert_eq!(t.frames_played(), 768);
        assert_eq!(t.xrun_count(), 2);
        assert_eq!(t.peaks(), (0.75, 0.5));

        t.set_peaks_rt(f32::NAN, f32::INFINITY);
        assert_eq!(t.peaks(), (0.0, 0.0));

        let hr = -2004287484i32; // AUDCLNT_E_DEVICE_INVALIDATED (0x88890004)
        t.record_error_rt(RtErrorCode::DeviceInvalidated, hr);
        assert_eq!(t.last_error(), Some((RtErrorCode::DeviceInvalidated, hr)));
        let formatted = t.format_last_error().expect("formatted error");
        assert!(formatted.contains("invalidated"));
        assert!(formatted.contains("0x88890004"));

        assert_eq!(t.bump_generation(), 1);
        assert_eq!(t.generation(), 1);

        t.reset_counters();
        assert_eq!(t.frames_played(), 0);
        assert_eq!(t.xrun_count(), 0);
        assert_eq!(t.last_error(), None);
        assert_eq!(t.generation(), 1);
    }
}
