//! Hard real-time underrun silence and XRUN handler.

use crate::pipeline::fade::{fade_out_f32_tail, fade_out_wire_tail};
use crate::pipeline::rt_telemetry::RtTelemetry;
use crate::verification::WireSampleFormat;

/// Real-time underrun silence & XRUN handler shared across WASAPI, ASIO, CoreAudio, cpal, and Mock
/// output callbacks.
///
/// All methods are strictly **No-Lock, No-Alloc, No-Log, No-Syscall**.
pub struct UnderrunGuard;

impl UnderrunGuard {
    /// Maximum tail frames linearly ramped to silence on partial PCM underrun when `!strict_bit_perfect`.
    pub const DEFAULT_UNDERRUN_FADE_FRAMES: usize = 128;

    /// Native DSD 1-bit silence byte (alternating `0110_1001` pattern, zero DC bias).
    pub const DSD_SILENCE_BYTE: u8 = 0x69;

    /// Fills `dst` with format-appropriate digital silence without allocating or locking:
    /// - PCM (`Int16Le`, `Int24PackedLe`, `Int24In32MsbLe`, `Int32Le`, `Float32Le`, `Float64Le`): `0x00`
    /// - Native DSD: `0x69`
    /// - DoP v1.1 (`Dop24In32MsbLe`): alternating `0x05`/`0xFA` marker per multi-channel frame + `0x69` DSD payload
    ///   in little-endian 24-in-32 MSB-aligned layout `[0x00, 0x69, 0x69, marker]`.
    #[inline]
    pub fn fill_wire_silence(
        dst: &mut [u8],
        format: WireSampleFormat,
        dop_marker_phase: &mut bool,
    ) {
        if dst.is_empty() {
            return;
        }
        match format {
            WireSampleFormat::NativeDsd { .. } => {
                dst.fill(Self::DSD_SILENCE_BYTE);
            }
            WireSampleFormat::Dop24In32MsbLe { channels, .. } => {
                let ch = (channels as usize).max(1);
                let frame_bytes = ch * 4;
                let aligned_len = (dst.len() / frame_bytes) * frame_bytes;
                for frame in dst[..aligned_len].chunks_exact_mut(frame_bytes) {
                    let marker = if *dop_marker_phase { 0xFAu8 } else { 0x05u8 };
                    *dop_marker_phase = !*dop_marker_phase;
                    for sample in frame.as_chunks_mut::<4>().0 {
                        sample[0] = 0x00;
                        sample[1] = Self::DSD_SILENCE_BYTE;
                        sample[2] = Self::DSD_SILENCE_BYTE;
                        sample[3] = marker;
                    }
                }
                if aligned_len < dst.len() {
                    let rem = &mut dst[aligned_len..];
                    let marker = if *dop_marker_phase { 0xFAu8 } else { 0x05u8 };
                    let rem_aligned = (rem.len() / 4) * 4;
                    for sample in rem[..rem_aligned].as_chunks_mut::<4>().0 {
                        sample[0] = 0x00;
                        sample[1] = Self::DSD_SILENCE_BYTE;
                        sample[2] = Self::DSD_SILENCE_BYTE;
                        sample[3] = marker;
                    }
                    if rem_aligned < rem.len() {
                        rem[rem_aligned..].fill(0x00);
                    }
                }
            }
            _ => {
                dst.fill(0x00);
            }
        }
    }

    /// Handles a full or partial wire-buffer underrun on the real-time audio callback:
    /// 1. Applies a short linear micro fade-out to `dst[..valid_bytes]` **ONLY** when
    ///    `!strict_bit_perfect` and `format` is PCM (never for Strict Bit-Perfect, Native DSD, or DoP!).
    /// 2. Fills `dst[valid_bytes..]` with format-appropriate silence via [`Self::fill_wire_silence`].
    /// 3. Increments `telemetry.record_xrun_rt()` when `telemetry` is provided.
    #[inline]
    pub fn handle_wire_underrun(
        dst: &mut [u8],
        valid_bytes: usize,
        format: WireSampleFormat,
        channels: usize,
        strict_bit_perfect: bool,
        dop_marker_phase: &mut bool,
        telemetry: Option<&RtTelemetry>,
    ) {
        let valid = valid_bytes.min(dst.len());

        if valid > 0 {
            if matches!(format, WireSampleFormat::Dop24In32MsbLe { .. })
                && valid >= 4
                && valid.is_multiple_of(4)
            {
                // Keep DoP silence markers phase-locked with the final valid DoP frame.
                match dst[valid - 1] {
                    0x05 => *dop_marker_phase = true,
                    0xFA => *dop_marker_phase = false,
                    _ => {}
                }
            }

            if !strict_bit_perfect {
                fade_out_wire_tail(
                    &mut dst[..valid],
                    format,
                    channels,
                    Self::DEFAULT_UNDERRUN_FADE_FRAMES,
                );
            }
        }

        Self::fill_wire_silence(&mut dst[valid..], format, dop_marker_phase);

        if let Some(t) = telemetry {
            t.record_xrun_rt();
        }
    }

    /// Handles a full or partial interleaved `f32` PCM underrun on the real-time audio callback:
    /// 1. Applies a short linear micro fade-out to `dst[..valid_samples]` ONLY when `!strict_bit_perfect`.
    /// 2. Fills `dst[valid_samples..]` with `0.0`.
    /// 3. Increments `telemetry.record_xrun_rt()` when `telemetry` is provided.
    #[inline]
    pub fn handle_f32_underrun(
        dst: &mut [f32],
        valid_samples: usize,
        channels: usize,
        strict_bit_perfect: bool,
        telemetry: Option<&RtTelemetry>,
    ) {
        let valid = valid_samples.min(dst.len());
        if valid > 0 && !strict_bit_perfect {
            fade_out_f32_tail(
                &mut dst[..valid],
                channels,
                Self::DEFAULT_UNDERRUN_FADE_FRAMES,
            );
        }
        dst[valid..].fill(0.0);

        if let Some(t) = telemetry {
            t.record_xrun_rt();
        }
    }
}
