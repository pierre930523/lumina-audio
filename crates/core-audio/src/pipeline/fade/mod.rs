//! Ring-buffer sizing/watermark math and real-time micro-fade / crossfade helpers.
//!
//! All sample-touching helpers in this module are strictly zero-allocation and lock-free.
//! When `strict_bit_perfect == true` (or for Native DSD / DoP wire formats), guarded helpers
//! guarantee that **zero** gain scaling, tail fade-out, or wire crossfade is applied to samples
//! (transitions drop cleanly to format-appropriate silence or verbatim hard-cut instead).

mod control;
mod crossfade;
mod linear;

pub use control::{AudioFadeControl, FadeTarget};
pub use crossfade::{
    crossfade_wire_bytes, crossfade_wire_bytes_guarded, fade_out_f32_tail,
    fade_out_f32_tail_guarded, fade_out_wire_tail, fade_out_wire_tail_guarded,
};
pub use linear::{
    FadeDirection, LinearFadeState, apply_fade_ramp_to_wire_bytes,
    apply_fade_ramp_to_wire_bytes_guarded,
};

use crate::verification::WireSampleFormat;

/// Streaming-resilient startup / post-seek audio release watermark in milliseconds (400–600 ms target).
pub const STARTUP_WATERMARK_MS: u64 = 500;

/// Anti-jitter background decode ring-buffer target duration in seconds (~10–15 s after pow2 rounding).
pub const TARGET_RING_BUFFER_SECS: usize = 10;

/// Linear micro-crossfade duration in milliseconds (5–15 ms click/pop prevention target).
pub const MICRO_FADE_MS: u64 = 10;

/// Standby pre-decode target duration in milliseconds (2–3 seconds target).
pub const STANDBY_PREDECODE_MS: u64 = 2_500;

/// FormatMismatch dual-track alignment lead time in milliseconds (`current_pts_ms + 800ms`).
pub const MISMATCH_ALIGNMENT_OFFSET_MS: u64 = 800;

/// FormatMismatch linear micro-crossfade duration in milliseconds (`5 ms`).
pub const MISMATCH_CROSSFADE_MS: u64 = 5;

/// Remaining duration threshold (`<= 20s`) for automatic Standby pre-decode trigger.
pub const AUTO_PREDECODE_REMAINING_MS: u64 = 20_000;

/// Computes `SpscRingBuffer<f32>` capacity for 10–15 s of anti-jitter PCM buffering.
pub fn compute_pcm_ring_samples(out_rate: u32, out_channels: u16) -> usize {
    let rate = out_rate.max(8_000) as usize;
    let ch = out_channels.max(1) as usize;
    let desired = rate
        .saturating_mul(ch)
        .saturating_mul(TARGET_RING_BUFFER_SECS);
    desired.clamp(65_536, 8_388_608).next_power_of_two()
}

/// Computes `SpscRingBuffer<u8>` capacity for 10–15 s of anti-jitter wire buffering.
pub fn compute_wire_ring_bytes(sample_rate: u32, channels: u16, wire: WireSampleFormat) -> usize {
    let effective_rate = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        (sample_rate / 8).max(44_100) as usize
    } else {
        sample_rate.max(8_000) as usize
    };
    let bpf = wire.bytes_per_sample().max(1) * (channels.max(1) as usize);
    let desired = effective_rate
        .saturating_mul(bpf)
        .saturating_mul(TARGET_RING_BUFFER_SECS);
    desired.clamp(262_144, 32 * 1024 * 1024).next_power_of_two()
}

/// Computes the `STARTUP_WATERMARK_MS` startup/post-seek release watermark in interleaved `f32` samples.
pub fn compute_startup_watermark_samples(
    out_rate: u32,
    out_channels: u16,
    ring_capacity: usize,
) -> usize {
    let ch = out_channels.max(1) as usize;
    let frames = ((out_rate.max(8_000) as u64 * STARTUP_WATERMARK_MS) / 1000) as usize;
    let raw = frames.saturating_mul(ch);
    let max_cap = (ring_capacity / 2 / ch) * ch;
    raw.min(max_cap)
}

/// Computes the `STARTUP_WATERMARK_MS` startup/post-seek release watermark in wire bytes (aligned to `bpf`).
pub fn compute_startup_watermark_bytes(
    sample_rate: u32,
    channels: u16,
    wire: WireSampleFormat,
    ring_capacity: usize,
) -> usize {
    let effective_rate = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        (sample_rate / 8).max(44_100) as u64
    } else {
        sample_rate.max(8_000) as u64
    };
    let bpf = wire.bytes_per_sample().max(1) * (channels.max(1) as usize);
    let frames = ((effective_rate * STARTUP_WATERMARK_MS) / 1000) as usize;
    let raw = frames.saturating_mul(bpf);
    let max_cap = (ring_capacity / 2 / bpf) * bpf;
    raw.min(max_cap)
}

/// Returns `true` ONLY when sample-level fade / crossfade processing is permitted.
///
/// Strictly forbids sample modification under `strict_bit_perfect == true` and for
/// Native DSD / DoP wire containers where linear sample scaling corrupts bitstreams or markers.
#[inline]
pub const fn is_fade_permitted(wire: WireSampleFormat, strict_bit_perfect: bool) -> bool {
    !strict_bit_perfect
        && !matches!(
            wire,
            WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_bit_perfect_disables_all_sample_fades_and_crossfades() {
        let orig: Vec<u8> = [10_000i16, -20_000, 15_000, -15_000, 8_000, -8_000]
            .iter()
            .flat_map(|s| s.to_le_bytes())
            .collect();

        // 1. Fade ramp guarded
        let mut buf = orig.clone();
        let mut fade = LinearFadeState::new(44_100, true, true, false);
        fade.set_unity();
        apply_fade_ramp_to_wire_bytes_guarded(
            &mut buf,
            WireSampleFormat::Int16Le,
            2,
            &mut fade,
            FadeDirection::Down,
            true,
        );
        assert_eq!(
            buf, orig,
            "Strict Bit-Perfect must not alter wire bytes on fade-out"
        );
        assert_eq!(fade.gain(), 0.0);

        // 2. Tail fade guarded
        let mut tail_buf = orig.clone();
        fade_out_wire_tail_guarded(&mut tail_buf, WireSampleFormat::Int16Le, 2, 128, true);
        assert_eq!(
            tail_buf, orig,
            "Strict Bit-Perfect must not alter wire bytes on underrun tail"
        );

        // 3. Crossfade guarded performs verbatim hard-cut from standby
        let standby: Vec<u8> = [1_234i16, -5_678, 9_012, -3_456, 7_890, -2_345]
            .iter()
            .flat_map(|s| s.to_le_bytes())
            .collect();
        let mut out = vec![0u8; standby.len()];
        let mut pos = 0usize;
        let written = crossfade_wire_bytes_guarded(
            &orig,
            &standby,
            &mut out,
            WireSampleFormat::Int16Le,
            2,
            &mut pos,
            100,
            true,
        );
        assert_eq!(written, standby.len());
        assert_eq!(
            out, standby,
            "Strict Bit-Perfect must hard-cut standby verbatim"
        );
        assert_eq!(pos, 100);

        // 4. Control constructors honor strict_bit_perfect
        let ctrl = AudioFadeControl::new_for_mode(false, true, false);
        assert!(!ctrl.fade_in_enabled());
        assert!(!ctrl.fade_out_enabled());
        let state = LinearFadeState::new_for_mode(44_100, false, true, false);
        assert!(!state.fade_in_enabled());
        assert!(!state.fade_out_enabled());
        assert_eq!(state.gain(), 1.0);
    }
}
