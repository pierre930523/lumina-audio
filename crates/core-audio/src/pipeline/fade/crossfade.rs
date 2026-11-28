//! RT-safe tail fade-out and micro-crossfade helpers for PCM and packed wire samples.

use super::is_fade_permitted;
use crate::verification::WireSampleFormat;

/// RT-safe, zero-allocation linear tail fade-out on interleaved `f32` PCM samples.
///
/// Applied when a ring buffer runs partially dry mid-callback so the boundary into silence
/// ramps smoothly down to `0.0` instead of emitting an audible step discontinuity/click.
#[inline]
pub fn fade_out_f32_tail(samples: &mut [f32], channels: usize, max_tail_frames: usize) {
    let ch = channels.max(1);
    let total_frames = samples.len() / ch;
    let tail_frames = total_frames.min(max_tail_frames);
    if tail_frames == 0 {
        return;
    }
    let start_frame = total_frames - tail_frames;
    let denom = tail_frames as f32;
    for i in 0..tail_frames {
        // Reaches exact 0.0 on the final valid frame (i == tail_frames - 1).
        let g = ((tail_frames - 1 - i) as f32) / denom;
        let base = (start_frame + i) * ch;
        for c in 0..ch {
            let s = samples[base + c];
            samples[base + c] = if s.is_finite() { s * g } else { 0.0 };
        }
    }
}

/// Strict Bit-Perfect-gated wrapper over [`fade_out_f32_tail`].
/// Strictly a no-op when `strict_bit_perfect == true`.
#[inline]
pub fn fade_out_f32_tail_guarded(
    samples: &mut [f32],
    channels: usize,
    max_tail_frames: usize,
    strict_bit_perfect: bool,
) {
    if strict_bit_perfect {
        return;
    }
    fade_out_f32_tail(samples, channels, max_tail_frames);
}

/// RT-safe, zero-allocation linear tail fade-out on packed wire-format PCM bytes.
///
/// Skips DSD / DoP formats where sample-level linear scaling is invalid.
pub fn fade_out_wire_tail(
    wire_bytes: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    max_tail_frames: usize,
) {
    if matches!(
        wire,
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. }
    ) {
        return;
    }
    let bps = wire.bytes_per_sample();
    let ch = channels.max(1);
    let bpf = bps * ch;
    if bpf == 0 {
        return;
    }
    let total_frames = wire_bytes.len() / bpf;
    let tail_frames = total_frames.min(max_tail_frames);
    if tail_frames == 0 {
        return;
    }
    let start_frame = total_frames - tail_frames;
    let denom = tail_frames as f32;
    for i in 0..tail_frames {
        let g = ((tail_frames - 1 - i) as f32) / denom;
        let frame_off = (start_frame + i) * bpf;
        let frame = &mut wire_bytes[frame_off..frame_off + bpf];
        for c in 0..ch {
            let s = &mut frame[c * bps..(c + 1) * bps];
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
                    let scaled = if v.is_finite() { v * g } else { 0.0 };
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Float64Le => {
                    let v = f64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]);
                    let scaled = if v.is_finite() { v * (g as f64) } else { 0.0 };
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => {}
            }
        }
    }
}

/// Strict Bit-Perfect-gated wrapper over [`fade_out_wire_tail`].
/// Strictly a no-op when `strict_bit_perfect == true` or `wire` is Native DSD / DoP.
#[inline]
pub fn fade_out_wire_tail_guarded(
    wire_bytes: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    max_tail_frames: usize,
    strict_bit_perfect: bool,
) {
    if !is_fade_permitted(wire, strict_bit_perfect) {
        return;
    }
    fade_out_wire_tail(wire_bytes, wire, channels, max_tail_frames);
}

#[inline]
fn read_wire_sample_f64(bytes: &[u8], wire: WireSampleFormat) -> f64 {
    match wire {
        WireSampleFormat::Int16Le => i16::from_le_bytes([bytes[0], bytes[1]]) as f64 / 32_768.0,
        WireSampleFormat::Int24PackedLe => {
            let sign = if bytes[2] & 0x80 != 0 { 0xFF } else { 0x00 };
            let v = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], sign]);
            v as f64 / 8_388_608.0
        }
        WireSampleFormat::Int24In32MsbLe => {
            let v = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) >> 8;
            v as f64 / 8_388_608.0
        }
        WireSampleFormat::Int32Le => {
            let v = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            v as f64 / 2_147_483_648.0
        }
        WireSampleFormat::Float32Le => {
            f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64
        }
        WireSampleFormat::Float64Le => f64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => 0.0,
    }
}

#[inline]
fn write_wire_sample_f64(dst: &mut [u8], val: f64, wire: WireSampleFormat) {
    let clamped = if val.is_finite() {
        val.clamp(-1.0, 1.0)
    } else {
        0.0
    };
    match wire {
        WireSampleFormat::Int16Le => {
            let s = (clamped * 32_768.0)
                .round()
                .clamp(i16::MIN as f64, i16::MAX as f64) as i16;
            dst.copy_from_slice(&s.to_le_bytes());
        }
        WireSampleFormat::Int24PackedLe => {
            let s = (clamped * 8_388_608.0)
                .round()
                .clamp(-8_388_608.0, 8_388_607.0) as i32;
            let le = s.to_le_bytes();
            dst[0] = le[0];
            dst[1] = le[1];
            dst[2] = le[2];
        }
        WireSampleFormat::Int24In32MsbLe => {
            let s = (clamped * 8_388_608.0)
                .round()
                .clamp(-8_388_608.0, 8_388_607.0) as i32;
            dst.copy_from_slice(&(s << 8).to_le_bytes());
        }
        WireSampleFormat::Int32Le => {
            let s = (clamped * 2_147_483_648.0)
                .round()
                .clamp(i32::MIN as f64, i32::MAX as f64) as i32;
            dst.copy_from_slice(&s.to_le_bytes());
        }
        WireSampleFormat::Float32Le => {
            dst.copy_from_slice(&(clamped as f32).to_le_bytes());
        }
        WireSampleFormat::Float64Le => {
            dst.copy_from_slice(&clamped.to_le_bytes());
        }
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => {}
    }
}

/// Linearly micro-crossfades interleaved wire bytes from `active` (`1 - t`) into `standby` (`t`).
/// Strictly zero-allocation and lock-free.
#[inline]
pub fn crossfade_wire_bytes(
    active_bytes: &[u8],
    standby_bytes: &[u8],
    out: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    crossfade_pos: &mut usize,
    crossfade_frames: usize,
) -> usize {
    let ch = channels.max(1);
    let bps = wire.bytes_per_sample();
    let bpf = bps * ch;
    if bpf == 0 || out.len() < bpf {
        return 0;
    }
    let frames = (out.len() / bpf).min(standby_bytes.len() / bpf);
    if frames == 0 {
        return 0;
    }
    if matches!(
        wire,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    ) {
        let byte_len = frames * bpf;
        out[..byte_len].copy_from_slice(&standby_bytes[..byte_len]);
        *crossfade_pos = crossfade_frames;
        return byte_len;
    }
    let total_cf = crossfade_frames.max(1) as f64;
    for f in 0..frames {
        *crossfade_pos = (*crossfade_pos).saturating_add(1);
        let t = ((*crossfade_pos as f64) / total_cf).clamp(0.0, 1.0);
        let ga = 1.0 - t;
        let gb = t;
        let frame_off = f * bpf;
        for c in 0..ch {
            let off = frame_off + c * bps;
            let a = if off + bps <= active_bytes.len() {
                read_wire_sample_f64(&active_bytes[off..off + bps], wire)
            } else {
                0.0
            };
            let b = read_wire_sample_f64(&standby_bytes[off..off + bps], wire);
            write_wire_sample_f64(&mut out[off..off + bps], a * ga + b * gb, wire);
        }
    }
    frames * bpf
}

/// Strict Bit-Perfect-gated wrapper over [`crossfade_wire_bytes`].
///
/// When `strict_bit_perfect == true` (or `wire` is Native DSD / DoP), performs a bit-exact
/// hard-cut copy from `standby_bytes` into `out` with zero float conversion or mixing,
/// and marks `*crossfade_pos = crossfade_frames`.
#[inline]
#[allow(clippy::too_many_arguments)]
pub fn crossfade_wire_bytes_guarded(
    active_bytes: &[u8],
    standby_bytes: &[u8],
    out: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    crossfade_pos: &mut usize,
    crossfade_frames: usize,
    strict_bit_perfect: bool,
) -> usize {
    if !is_fade_permitted(wire, strict_bit_perfect) {
        let ch = channels.max(1);
        let bps = wire.bytes_per_sample();
        let bpf = bps * ch;
        if bpf == 0 || out.len() < bpf {
            return 0;
        }
        let frames = (out.len() / bpf).min(standby_bytes.len() / bpf);
        if frames == 0 {
            return 0;
        }
        let byte_len = frames * bpf;
        out[..byte_len].copy_from_slice(&standby_bytes[..byte_len]);
        *crossfade_pos = crossfade_frames;
        return byte_len;
    }
    crossfade_wire_bytes(
        active_bytes,
        standby_bytes,
        out,
        wire,
        channels,
        crossfade_pos,
        crossfade_frames,
    )
}
