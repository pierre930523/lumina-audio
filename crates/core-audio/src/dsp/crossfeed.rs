use super::biquad::{BiquadCoefficients, BiquadFilter, FilterType};
use crate::error::DspError;

/// Chu Moy / Linkwitz acoustic headphone crossfeed filter simulating a natural 60-degree speaker soundstage.
/// Features circular delay lines (~270 us ITD) and 700 Hz low-pass filters (ILD).
#[derive(Debug, Clone)]
pub struct CrossfeedFilter {
    sample_rate_hz: f64,
    delay_samples: usize,
    direct_gain: f64,
    cross_gain: f64,
    delay_buf_l: Vec<f64>,
    delay_buf_r: Vec<f64>,
    delay_pos: usize,
    filter_l_to_r: BiquadFilter,
    filter_r_to_l: BiquadFilter,
    enabled: bool,
}

impl CrossfeedFilter {
    pub const DEFAULT_CUTOFF_HZ: f64 = 700.0;
    pub const DEFAULT_ITD_SECONDS: f64 = 0.000270; // 270 microseconds
    pub const DEFAULT_DIRECT_GAIN_DB: f64 = -1.5;
    pub const DEFAULT_CROSS_GAIN_DB: f64 = -6.0;

    pub fn new(sample_rate_hz: f64) -> Result<Self, DspError> {
        let delay_samples = ((sample_rate_hz * Self::DEFAULT_ITD_SECONDS).round() as usize).max(1);
        let direct_gain = 10.0f64.powf(Self::DEFAULT_DIRECT_GAIN_DB / 20.0);
        let cross_gain = 10.0f64.powf(Self::DEFAULT_CROSS_GAIN_DB / 20.0);

        // Low-pass filter at 700 Hz with gentle Q=0.5
        let coeffs = BiquadCoefficients::compute(
            FilterType::LowPass,
            sample_rate_hz,
            Self::DEFAULT_CUTOFF_HZ,
            0.0,
            0.5,
        )?;

        let buf_size = (delay_samples + 1).next_power_of_two().max(128);

        Ok(Self {
            sample_rate_hz,
            delay_samples,
            direct_gain,
            cross_gain,
            delay_buf_l: vec![0.0; buf_size],
            delay_buf_r: vec![0.0; buf_size],
            delay_pos: 0,
            filter_l_to_r: BiquadFilter::new(coeffs, 1),
            filter_r_to_l: BiquadFilter::new(coeffs, 1),
            enabled: true,
        })
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.reset();
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn reset(&mut self) {
        self.delay_buf_l.fill(0.0);
        self.delay_buf_r.fill(0.0);
        self.delay_pos = 0;
        self.filter_l_to_r.reset();
        self.filter_r_to_l.reset();
    }

    pub fn delay_samples(&self) -> usize {
        self.delay_samples
    }

    pub fn sample_rate_hz(&self) -> f64 {
        self.sample_rate_hz
    }

    /// Processes a single stereo frame (left, right).
    #[inline]
    pub fn process_stereo(&mut self, left: f64, right: f64) -> (f64, f64) {
        if !self.enabled {
            return (left, right);
        }

        let cap = self.delay_buf_l.len();
        self.delay_buf_l[self.delay_pos] = left;
        self.delay_buf_r[self.delay_pos] = right;

        let delayed_idx = (self.delay_pos + cap - self.delay_samples) % cap;
        let delayed_l = self.delay_buf_l[delayed_idx];
        let delayed_r = self.delay_buf_r[delayed_idx];

        self.delay_pos = (self.delay_pos + 1) % cap;

        let filtered_l_to_r = self.filter_l_to_r.process_sample(0, delayed_l);
        let filtered_r_to_l = self.filter_r_to_l.process_sample(0, delayed_r);

        let out_l = self.direct_gain * left + self.cross_gain * filtered_r_to_l;
        let out_r = self.direct_gain * right + self.cross_gain * filtered_l_to_r;

        (out_l, out_r)
    }

    /// Processes an interleaved slice of audio. If channels != 2, audio passes untouched.
    pub fn process_interleaved(&mut self, samples: &mut [f64], channels: usize) {
        if !self.enabled || channels != 2 {
            return;
        }

        let frames = samples.len() / 2;
        for i in 0..frames {
            let l = samples[i * 2];
            let r = samples[i * 2 + 1];
            let (out_l, out_r) = self.process_stereo(l, r);
            samples[i * 2] = out_l;
            samples[i * 2 + 1] = out_r;
        }
    }
}
