use serde::{Deserialize, Serialize};
use std::f64::consts::PI;

use crate::error::DspError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FilterType {
    Peaking,
    LowShelf,
    HighShelf,
    LowPass,
    HighPass,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct BiquadCoefficients {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

impl Default for BiquadCoefficients {
    fn default() -> Self {
        // Identity pass-through
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
        }
    }
}

impl BiquadCoefficients {
    /// Computes biquad filter coefficients based on Robert Bristow-Johnson's Audio EQ Cookbook.
    /// All coefficients are normalized by a0.
    pub fn compute(
        filter_type: FilterType,
        sample_rate_hz: f64,
        frequency_hz: f64,
        gain_db: f64,
        q_factor: f64,
    ) -> Result<Self, DspError> {
        if sample_rate_hz <= 0.0 {
            return Err(DspError::InvalidFilterParameters(
                "Sample rate must be > 0".into(),
            ));
        }

        let nyquist = sample_rate_hz * 0.5;
        let f0 = frequency_hz.clamp(1.0, nyquist * 0.999);
        let q = q_factor.max(0.001);

        let w0 = 2.0 * PI * (f0 / sample_rate_hz);
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let a = 10.0f64.powf(gain_db / 40.0);
        let beta = 2.0 * a.sqrt() * alpha;

        let (b0, b1, b2, a0, a1, a2) = match filter_type {
            FilterType::Peaking => (
                1.0 + alpha * a,
                -2.0 * cos_w0,
                1.0 - alpha * a,
                1.0 + alpha / a,
                -2.0 * cos_w0,
                1.0 - alpha / a,
            ),
            FilterType::LowShelf => (
                a * ((a + 1.0) - (a - 1.0) * cos_w0 + beta),
                2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0),
                a * ((a + 1.0) - (a - 1.0) * cos_w0 - beta),
                (a + 1.0) + (a - 1.0) * cos_w0 + beta,
                -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0),
                (a + 1.0) + (a - 1.0) * cos_w0 - beta,
            ),
            FilterType::HighShelf => (
                a * ((a + 1.0) + (a - 1.0) * cos_w0 + beta),
                -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0),
                a * ((a + 1.0) + (a - 1.0) * cos_w0 - beta),
                (a + 1.0) - (a - 1.0) * cos_w0 + beta,
                2.0 * ((a - 1.0) - (a + 1.0) * cos_w0),
                (a + 1.0) - (a - 1.0) * cos_w0 - beta,
            ),
            FilterType::LowPass => (
                (1.0 - cos_w0) * 0.5,
                1.0 - cos_w0,
                (1.0 - cos_w0) * 0.5,
                1.0 + alpha,
                -2.0 * cos_w0,
                1.0 - alpha,
            ),
            FilterType::HighPass => (
                (1.0 + cos_w0) * 0.5,
                -(1.0 + cos_w0),
                (1.0 + cos_w0) * 0.5,
                1.0 + alpha,
                -2.0 * cos_w0,
                1.0 - alpha,
            ),
        };

        if a0.abs() < 1e-12 {
            return Err(DspError::InvalidFilterParameters(
                "Singular filter denominator a0".into(),
            ));
        }

        let inv_a0 = 1.0 / a0;
        let coeffs = Self {
            b0: b0 * inv_a0,
            b1: b1 * inv_a0,
            b2: b2 * inv_a0,
            a1: a1 * inv_a0,
            a2: a2 * inv_a0,
        };

        if !coeffs.is_stable() {
            return Err(DspError::UnstableFilter(format!(
                "Poles outside unit circle (a1={:.4}, a2={:.4})",
                coeffs.a1, coeffs.a2
            )));
        }

        Ok(coeffs)
    }

    /// Checks filter stability via the Jury stability criterion for 2nd order discrete systems:
    /// 1. |a2| < 1
    /// 2. 1 + a1 + a2 > 0
    /// 3. 1 - a1 + a2 > 0
    pub fn is_stable(&self) -> bool {
        self.a2.abs() < 1.0 && (1.0 + self.a1 + self.a2) > 0.0 && (1.0 - self.a1 + self.a2) > 0.0
    }

    /// Evaluates the DTFT frequency response magnitude in dB at `eval_freq_hz`.
    pub fn frequency_response_db(&self, eval_freq_hz: f64, sample_rate_hz: f64) -> f64 {
        let w = 2.0 * PI * (eval_freq_hz / sample_rate_hz);
        let cos_w = w.cos();
        let sin_w = w.sin();
        let cos_2w = (2.0 * w).cos();
        let sin_2w = (2.0 * w).sin();

        // Numerator H_num(e^{jw}) = b0 + b1 e^{-jw} + b2 e^{-j 2w}
        let num_re = self.b0 + self.b1 * cos_w + self.b2 * cos_2w;
        let num_im = -self.b1 * sin_w - self.b2 * sin_2w;
        let num_mag_sq = num_re * num_re + num_im * num_im;

        // Denominator H_den(e^{jw}) = 1 + a1 e^{-jw} + a2 e^{-j 2w}
        let den_re = 1.0 + self.a1 * cos_w + self.a2 * cos_2w;
        let den_im = -self.a1 * sin_w - self.a2 * sin_2w;
        let den_mag_sq = den_re * den_re + den_im * den_im;

        if den_mag_sq <= 0.0 {
            return 0.0;
        }

        10.0 * (num_mag_sq / den_mag_sq).log10()
    }
}

/// Transposed Direct Form II state variables for one channel.
#[derive(Debug, Clone, Copy, Default)]
pub struct BiquadState {
    pub s1: f64,
    pub s2: f64,
}

impl BiquadState {
    #[inline(always)]
    pub fn reset(&mut self) {
        self.s1 = 0.0;
        self.s2 = 0.0;
    }
}

/// 64-bit Biquad IIR Filter with Transposed Direct Form II and anti-denormal flushing.
#[derive(Debug, Clone)]
pub struct BiquadFilter {
    pub coeffs: BiquadCoefficients,
    pub states: Vec<BiquadState>, // One per channel
}

impl BiquadFilter {
    pub fn new(coeffs: BiquadCoefficients, channels: usize) -> Self {
        Self {
            coeffs,
            states: vec![BiquadState::default(); channels.max(1)],
        }
    }

    pub fn reset(&mut self) {
        for state in &mut self.states {
            state.reset();
        }
    }

    /// Processes a single sample on a given channel using Transposed Direct Form II.
    #[inline(always)]
    pub fn process_sample(&mut self, channel: usize, x: f64) -> f64 {
        if channel >= self.states.len() {
            return x;
        }
        let state = &mut self.states[channel];
        let y = self.coeffs.b0 * x + state.s1;
        state.s1 = self.coeffs.b1 * x - self.coeffs.a1 * y + state.s2;
        state.s2 = self.coeffs.b2 * x - self.coeffs.a2 * y;

        // Anti-denormal flushing to prevent x86 microcode traps
        if state.s1.abs() < 1.0e-25 {
            state.s1 = 0.0;
        }
        if state.s2.abs() < 1.0e-25 {
            state.s2 = 0.0;
        }

        y
    }
}
