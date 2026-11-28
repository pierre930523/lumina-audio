//! 64-bit floating-point windowed-sinc sample rate converter and channel adapter.
//!
//! Used exclusively on non-Bit-Perfect / Shared-Mode / DSD-to-PCM paths.
//! When `in_rate == out_rate`, [`StreamingSincResampler`] operates as a strict
//! bit-exact pass-through without modifying sample values.

/// Adapts interleaved 64-bit float PCM samples between channel counts, reusing `out`.
///
/// When `in_ch == out_ch`, copies input verbatim into `out`.
pub fn adapt_channels_f64_into(samples: &[f64], in_ch: u16, out_ch: u16, out: &mut Vec<f64>) {
    out.clear();
    let ich = in_ch.max(1) as usize;
    let och = out_ch.max(1) as usize;
    if samples.is_empty() {
        return;
    }
    if ich == och {
        out.extend_from_slice(samples);
        return;
    }
    let frames = samples.len() / ich;
    out.reserve(frames * och);
    for frame in samples.chunks_exact(ich) {
        if ich == 1 && och >= 2 {
            let s = frame[0];
            for _ in 0..och {
                out.push(s);
            }
        } else {
            for c in 0..och {
                out.push(frame[c % ich]);
            }
        }
    }
}

/// Adapts interleaved 64-bit float PCM samples between channel counts, returning a new `Vec<f64>`.
pub fn adapt_channels_f64(samples: &[f64], in_ch: u16, out_ch: u16) -> Vec<f64> {
    let mut out = Vec::new();
    adapt_channels_f64_into(samples, in_ch, out_ch, &mut out);
    out
}

/// Stateful, continuous-phase 24-tap Lanczos-12 windowed-sinc streaming resampler.
///
/// Eliminates chunk-boundary phase jumps, rate-ratio rounding drift, and aliasing
/// distortion when resampling streaming audio (e.g. 44.1 kHz M4A/AAC <-> 48 kHz Opus/WASAPI).
/// When `in_rate == out_rate`, operates as a zero-modification pass-through.
#[derive(Debug, Clone)]
pub struct StreamingSincResampler {
    in_rate: u32,
    out_rate: u32,
    channels: usize,
    step: f64,
    cutoff: f64,
    phase: f64,
    history: Vec<f64>,
}

impl StreamingSincResampler {
    /// Half-width of the Lanczos windowed-sinc kernel (24 taps total per output frame).
    pub const HALF_TAPS: usize = 12;

    pub fn new(in_rate: u32, out_rate: u32, channels: usize) -> Self {
        let mut r = Self {
            in_rate: in_rate.max(8_000),
            out_rate: out_rate.max(8_000),
            channels: channels.max(1),
            step: 1.0,
            cutoff: 0.95,
            phase: Self::HALF_TAPS as f64,
            history: Vec::new(),
        };
        r.reset();
        r
    }

    /// Returns `true` when input and output sample rates match and resampling is bypassed.
    #[inline]
    pub fn is_passthrough(&self) -> bool {
        self.in_rate == self.out_rate
    }

    /// Reconfigures and resets history if sample rates or channel count changed.
    pub fn ensure_config(&mut self, in_rate: u32, out_rate: u32, channels: usize) {
        let ir = in_rate.max(8_000);
        let or = out_rate.max(8_000);
        let ch = channels.max(1);
        if self.in_rate != ir || self.out_rate != or || self.channels != ch {
            self.in_rate = ir;
            self.out_rate = or;
            self.channels = ch;
            self.reset();
        }
    }

    /// Resets internal phase and causal zero-padding history (call on seek or track switch).
    pub fn reset(&mut self) {
        self.step = (self.in_rate as f64) / (self.out_rate as f64);
        // Apply anti-aliasing low-pass cutoff below target Nyquist on downsampling
        // and keep flat audible passband (20 Hz - 19+ kHz) on upsampling.
        self.cutoff = if self.out_rate < self.in_rate {
            ((self.out_rate as f64) / (self.in_rate as f64)) * 0.92
        } else {
            0.95
        };
        self.history.clear();
        self.phase = Self::HALF_TAPS as f64;
        if self.in_rate != self.out_rate {
            self.history.resize(Self::HALF_TAPS * self.channels, 0.0);
        }
    }

    #[inline(always)]
    fn sinc(x: f64) -> f64 {
        if x.abs() < 1e-9 {
            1.0
        } else {
            let px = std::f64::consts::PI * x;
            px.sin() / px
        }
    }

    /// Processes an interleaved `f64` input chunk into caller-provided `out` buffer,
    /// reusing `out`'s existing capacity to avoid per-chunk heap allocation.
    ///
    /// When `in_rate == out_rate`, copies `input` verbatim into `out` without altering any bit.
    pub fn process_into(&mut self, input: &[f64], out: &mut Vec<f64>) {
        out.clear();
        if input.is_empty() || self.channels == 0 {
            return;
        }
        if self.in_rate == self.out_rate {
            out.extend_from_slice(input);
            return;
        }
        let ch = self.channels;
        let aligned_len = (input.len() / ch) * ch;
        if aligned_len == 0 {
            return;
        }
        self.history.extend_from_slice(&input[..aligned_len]);
        self.emit_available_into(out);
    }

    /// Processes an interleaved `f64` input chunk, maintaining exact fractional phase
    /// and rolling sample history across arbitrary chunk boundaries.
    pub fn process(&mut self, input: &[f64]) -> Vec<f64> {
        let mut out = Vec::new();
        self.process_into(input, &mut out);
        out
    }

    /// Flushes remaining buffered frames at EOF into `out` by appending causal right-side zero padding.
    pub fn flush_into(&mut self, out: &mut Vec<f64>) {
        out.clear();
        if self.in_rate == self.out_rate || self.channels == 0 {
            return;
        }
        let ch = self.channels;
        let current_frames = self.history.len() / ch;
        if current_frames <= Self::HALF_TAPS {
            self.reset();
            return;
        }
        self.history
            .resize((current_frames + Self::HALF_TAPS) * ch, 0.0);
        self.emit_available_into(out);
        self.reset();
    }

    /// Flushes remaining buffered frames at EOF by appending causal right-side zero padding.
    pub fn flush(&mut self) -> Vec<f64> {
        let mut out = Vec::new();
        self.flush_into(&mut out);
        out
    }

    fn emit_available_into(&mut self, out: &mut Vec<f64>) {
        let ch = self.channels;
        let total_frames = self.history.len() / ch;
        let half = Self::HALF_TAPS;
        if total_frames <= 2 * half {
            return;
        }
        let max_center = total_frames - half;
        let est_frames = (((max_center as f64 - self.phase).max(0.0)) / self.step).ceil() as usize;
        out.reserve(est_frames.saturating_add(2) * ch);
        let a = half as f64;
        let cutoff = self.cutoff;

        // Precompute tap weights once per output frame and reuse across all channels.
        let mut weights = [0.0f64; Self::HALF_TAPS * 2];

        loop {
            let center = self.phase.floor() as usize;
            if center + half >= total_frames {
                break;
            }
            let start_k = center + 1 - half;
            let mut w_sum = 0.0f64;
            for (t, w_slot) in weights.iter_mut().enumerate() {
                let k = start_k + t;
                let d = self.phase - (k as f64);
                let w = if d.abs() < a {
                    Self::sinc(d * cutoff) * Self::sinc(d / a)
                } else {
                    0.0
                };
                *w_slot = w;
                w_sum += w;
            }
            let inv_w_sum = if w_sum.abs() > 1e-12 {
                1.0 / w_sum
            } else {
                0.0
            };

            if ch <= 8 {
                let mut acc = [0.0f64; 8];
                for (t, &w) in weights.iter().enumerate() {
                    if w == 0.0 {
                        continue;
                    }
                    let base = (start_k + t) * ch;
                    for c in 0..ch {
                        acc[c] += self.history[base + c] * w;
                    }
                }
                for &v in acc.iter().take(ch) {
                    out.push(v * inv_w_sum);
                }
            } else {
                let out_start = out.len();
                out.resize(out_start + ch, 0.0);
                for (t, &w) in weights.iter().enumerate() {
                    if w == 0.0 {
                        continue;
                    }
                    let base = (start_k + t) * ch;
                    for c in 0..ch {
                        out[out_start + c] += self.history[base + c] * w;
                    }
                }
                for s in &mut out[out_start..out_start + ch] {
                    *s *= inv_w_sum;
                }
            }

            self.phase += self.step;
        }

        // Discard input frames strictly before the earliest tap required for the next output frame.
        let next_center = self.phase.floor() as usize;
        let keep_from = next_center.saturating_sub(half - 1);
        if keep_from > 0 {
            let drain_samples = (keep_from * ch).min(self.history.len());
            self.history.drain(..drain_samples);
            self.phase -= (drain_samples / ch) as f64;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_preserves_bits_and_reuses_buffer() {
        let mut r = StreamingSincResampler::new(48_000, 48_000, 2);
        assert!(r.is_passthrough());

        let input = [0.125_f64, -0.5, 0.9999999, -0.9999999];
        let mut out = Vec::with_capacity(64);
        let initial_cap = out.capacity();
        let initial_ptr = out.as_ptr();

        r.process_into(&input, &mut out);
        assert_eq!(out.as_slice(), &input);
        assert_eq!(out.capacity(), initial_cap);
        assert_eq!(out.as_ptr(), initial_ptr);
        assert!(r.flush().is_empty());
    }

    #[test]
    fn resample_44100_to_48000_produces_expected_length() {
        let mut r = StreamingSincResampler::new(44_100, 48_000, 2);
        assert!(!r.is_passthrough());

        let frames = 4410;
        let mut input = Vec::with_capacity(frames * 2);
        for i in 0..frames {
            let s = (2.0 * std::f64::consts::PI * 1000.0 * (i as f64) / 44_100.0).sin() * 0.5;
            input.push(s);
            input.push(-s);
        }
        let mut out = Vec::with_capacity(12_000);
        r.process_into(&input, &mut out);
        let mut tail = Vec::new();
        r.flush_into(&mut tail);
        let total_out_frames = (out.len() + tail.len()) / 2;
        assert!(
            (4780..=4820).contains(&total_out_frames),
            "expected ~4800 frames, got {total_out_frames}"
        );
    }

    #[test]
    fn adapt_channels_mono_to_stereo_and_passthrough() {
        let mut buf = Vec::with_capacity(16);
        adapt_channels_f64_into(&[0.25, -0.75], 1, 2, &mut buf);
        assert_eq!(buf, vec![0.25, 0.25, -0.75, -0.75]);

        adapt_channels_f64_into(&[0.1, 0.2, 0.3, 0.4], 2, 2, &mut buf);
        assert_eq!(buf, vec![0.1, 0.2, 0.3, 0.4]);
    }
}
