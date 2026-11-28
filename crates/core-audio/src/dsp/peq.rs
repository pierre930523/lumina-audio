use serde::{Deserialize, Serialize};

use super::biquad::{BiquadCoefficients, BiquadFilter, FilterType};
use crate::error::DspError;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParametricBand {
    pub filter_type: FilterType,
    pub frequency_hz: f64,
    pub gain_db: f64,
    pub q_factor: f64,
    pub enabled: bool,
}

impl Default for ParametricBand {
    fn default() -> Self {
        Self {
            filter_type: FilterType::Peaking,
            frequency_hz: 1000.0,
            gain_db: 0.0,
            q_factor: 1.414,
            enabled: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ParametricEq {
    sample_rate_hz: f64,
    channels: usize,
    bands: Vec<ParametricBand>,
    filters: Vec<Option<BiquadFilter>>,
}

impl ParametricEq {
    pub fn new(
        sample_rate_hz: f64,
        channels: usize,
        bands: Vec<ParametricBand>,
    ) -> Result<Self, DspError> {
        let mut peq = Self {
            sample_rate_hz,
            channels: channels.max(1),
            bands: Vec::new(),
            filters: Vec::new(),
        };
        peq.set_bands(bands)?;
        Ok(peq)
    }

    pub fn set_bands(&mut self, bands: Vec<ParametricBand>) -> Result<(), DspError> {
        let mut filters = Vec::with_capacity(bands.len());
        for band in &bands {
            if band.enabled
                && (band.gain_db.abs() > 1e-4
                    || band.filter_type == FilterType::LowPass
                    || band.filter_type == FilterType::HighPass)
            {
                let coeffs = BiquadCoefficients::compute(
                    band.filter_type,
                    self.sample_rate_hz,
                    band.frequency_hz,
                    band.gain_db,
                    band.q_factor,
                )?;
                filters.push(Some(BiquadFilter::new(coeffs, self.channels)));
            } else {
                filters.push(None);
            }
        }
        self.bands = bands;
        self.filters = filters;
        Ok(())
    }

    pub fn bands(&self) -> &[ParametricBand] {
        &self.bands
    }

    pub fn reset(&mut self) {
        for filter in self.filters.iter_mut().flatten() {
            filter.reset();
        }
    }

    /// Processes a single multi-channel sample frame in place: `frame = [L, R, ...]`.
    #[inline(always)]
    pub fn process_frame(&mut self, frame: &mut [f64]) {
        for filter in self.filters.iter_mut().flatten() {
            for (ch, sample) in frame.iter_mut().enumerate() {
                *sample = filter.process_sample(ch, *sample);
            }
        }
    }

    /// Processes an interleaved slice of multi-channel audio: `[L0, R0, L1, R1, ...]`.
    pub fn process_interleaved(&mut self, samples: &mut [f64], channels: usize) {
        if channels == 0 {
            return;
        }
        let frames = samples.len() / channels;
        for f in 0..frames {
            let offset = f * channels;
            let frame = &mut samples[offset..offset + channels];
            self.process_frame(frame);
        }
    }

    /// Calculates the overall cascaded frequency response magnitude in dB at `eval_freq_hz`.
    pub fn frequency_response_db(&self, eval_freq_hz: f64) -> f64 {
        let mut total_gain = 0.0;
        for filter in self.filters.iter().flatten() {
            total_gain += filter
                .coeffs
                .frequency_response_db(eval_freq_hz, self.sample_rate_hz);
        }
        total_gain
    }
}
