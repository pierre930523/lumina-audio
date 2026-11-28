//! Callback-local linear fade ramp state and wire-ramp helpers.

use super::{MICRO_FADE_MS, is_fade_permitted};
use crate::verification::WireSampleFormat;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FadeDirection {
    Up,
    Down,
}

/// Callback-local zero-allocation linear ramp state (10 ms default).
#[derive(Debug, Clone, Copy)]
pub struct LinearFadeState {
    gain: f32,
    step: f32,
    fade_in_enabled: bool,
    fade_out_enabled: bool,
}

impl LinearFadeState {
    pub fn new(
        sample_rate: u32,
        fade_in_enabled: bool,
        fade_out_enabled: bool,
        start_paused: bool,
    ) -> Self {
        let fade_frames = ((sample_rate.max(8_000) as u64 * MICRO_FADE_MS) / 1000).clamp(64, 4096);
        let initial_gain = if start_paused || fade_in_enabled {
            0.0
        } else {
            1.0
        };
        Self {
            gain: initial_gain,
            step: 1.0 / (fade_frames as f32),
            fade_in_enabled,
            fade_out_enabled,
        }
    }

    /// Constructs a [`LinearFadeState`] honoring Strict Bit-Perfect and DSD/DoP invariants:
    /// both fade-in and fade-out are disabled when `is_dsd_or_dop || strict_bit_perfect`.
    pub fn new_for_mode(
        sample_rate: u32,
        is_dsd_or_dop: bool,
        strict_bit_perfect: bool,
        start_paused: bool,
    ) -> Self {
        let allow_fade = !is_dsd_or_dop && !strict_bit_perfect;
        Self::new(sample_rate, allow_fade, allow_fade, start_paused)
    }

    pub fn with_frames(
        fade_frames: u64,
        fade_in_enabled: bool,
        fade_out_enabled: bool,
        start_paused: bool,
    ) -> Self {
        let frames = fade_frames.clamp(32, 4096);
        let initial_gain = if start_paused || fade_in_enabled {
            0.0
        } else {
            1.0
        };
        Self {
            gain: initial_gain,
            step: 1.0 / (frames as f32),
            fade_in_enabled,
            fade_out_enabled,
        }
    }

    #[inline]
    pub fn gain(&self) -> f32 {
        self.gain
    }

    #[inline]
    pub fn set_zero(&mut self) {
        self.gain = 0.0;
    }

    #[inline]
    pub fn set_unity(&mut self) {
        self.gain = 1.0;
    }

    #[inline]
    pub fn set_gain(&mut self, gain: f32) {
        self.gain = gain.clamp(0.0, 1.0);
    }

    #[inline]
    pub fn remaining_down_frames(&self) -> usize {
        if !self.fade_out_enabled || self.gain <= 0.0 || self.step <= 0.0 {
            0
        } else {
            (self.gain / self.step).ceil() as usize
        }
    }

    #[inline]
    pub fn reset_for_play_start(&mut self) {
        self.gain = if self.fade_in_enabled { 0.0 } else { 1.0 };
    }

    #[inline]
    pub fn fade_in_enabled(&self) -> bool {
        self.fade_in_enabled
    }

    #[inline]
    pub fn fade_out_enabled(&self) -> bool {
        self.fade_out_enabled
    }

    #[inline]
    pub fn step_frame(&mut self, dir: FadeDirection) -> f32 {
        match dir {
            FadeDirection::Up => {
                if !self.fade_in_enabled {
                    self.gain = 1.0;
                } else if self.gain < 1.0 {
                    self.gain = (self.gain + self.step).min(1.0);
                }
                self.gain
            }
            FadeDirection::Down => {
                if !self.fade_out_enabled {
                    self.gain = 0.0;
                } else if self.gain > 0.0 {
                    self.gain = (self.gain - self.step).max(0.0);
                }
                self.gain
            }
        }
    }
}

/// Applies a per-frame linear gain ramp in-place to interleaved PCM wire bytes.
/// Strictly zero-allocation and lock-free. No-op for Native DSD and DoP.
#[inline]
pub fn apply_fade_ramp_to_wire_bytes(
    wire_bytes: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    fade: &mut LinearFadeState,
    direction: FadeDirection,
) {
    if matches!(
        wire,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    ) {
        return;
    }
    let ch = channels.max(1);
    let bps = wire.bytes_per_sample();
    let bpf = bps * ch;
    if bpf == 0 || wire_bytes.len() < bpf {
        return;
    }
    let frames = wire_bytes.len() / bpf;
    for f in 0..frames {
        let g = fade.step_frame(direction);
        if direction == FadeDirection::Up && (g - 1.0).abs() < 1e-6 {
            break;
        }
        let frame_slice = &mut wire_bytes[f * bpf..(f + 1) * bpf];
        for c in 0..ch {
            let s = &mut frame_slice[c * bps..(c + 1) * bps];
            match wire {
                WireSampleFormat::Int16Le => {
                    let v = i16::from_le_bytes([s[0], s[1]]);
                    let scaled = ((v as f32) * g)
                        .round()
                        .clamp(i16::MIN as f32, i16::MAX as f32)
                        as i16;
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Int24PackedLe => {
                    let sign = if s[2] & 0x80 != 0 { 0xFF } else { 0x00 };
                    let v = i32::from_le_bytes([s[0], s[1], s[2], sign]);
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(-8_388_608.0, 8_388_607.0) as i32;
                    let le = scaled.to_le_bytes();
                    s[0] = le[0];
                    s[1] = le[1];
                    s[2] = le[2];
                }
                WireSampleFormat::Int24In32MsbLe => {
                    let v = i32::from_le_bytes([s[0], s[1], s[2], s[3]]) >> 8;
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(-8_388_608.0, 8_388_607.0) as i32;
                    s.copy_from_slice(&(scaled << 8).to_le_bytes());
                }
                WireSampleFormat::Int32Le => {
                    let v = i32::from_le_bytes([s[0], s[1], s[2], s[3]]);
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(i32::MIN as f64, i32::MAX as f64)
                        as i32;
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Float32Le => {
                    let v = f32::from_le_bytes([s[0], s[1], s[2], s[3]]);
                    s.copy_from_slice(&(v * g).to_le_bytes());
                }
                WireSampleFormat::Float64Le => {
                    let v = f64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]);
                    s.copy_from_slice(&(v * (g as f64)).to_le_bytes());
                }
                WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => {}
            }
        }
    }
}

/// Strict Bit-Perfect-gated wrapper over [`apply_fade_ramp_to_wire_bytes`].
///
/// When `strict_bit_perfect == true` (or `wire` is Native DSD / DoP), leaves `wire_bytes`
/// completely bit-identical and snaps `fade` gain immediately (`Up -> 1.0`, `Down -> 0.0`).
#[inline]
pub fn apply_fade_ramp_to_wire_bytes_guarded(
    wire_bytes: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    fade: &mut LinearFadeState,
    direction: FadeDirection,
    strict_bit_perfect: bool,
) {
    if !is_fade_permitted(wire, strict_bit_perfect) {
        match direction {
            FadeDirection::Up => fade.set_unity(),
            FadeDirection::Down => fade.set_zero(),
        }
        return;
    }
    apply_fade_ramp_to_wire_bytes(wire_bytes, wire, channels, fade, direction);
}
