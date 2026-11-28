use super::biquad::FilterType;
use super::crossfeed::CrossfeedFilter;
use super::gain::{ReplayGain, ReplayGainConfig};
use super::limiter::LookaheadLimiter;
use super::peq::{ParametricBand, ParametricEq};
use crate::error::DspError;

/// Full 64-bit Floating Point DSP Pipeline with 1-Click Zero-Cost Bit-Perfect Bypass.
#[derive(Debug, Clone)]
pub struct DspPipeline {
    sample_rate_hz: f64,
    channels: usize,
    bypass: bool,
    peq: ParametricEq,
    crossfeed: Option<CrossfeedFilter>,
    gain: ReplayGain,
    limiter: LookaheadLimiter,
}

impl DspPipeline {
    pub fn new(sample_rate_hz: f64, channels: usize) -> Result<Self, DspError> {
        let ch = channels.max(1);
        let peq = ParametricEq::new(sample_rate_hz, ch, Vec::new())?;
        let crossfeed = if ch == 2 {
            let mut cf = CrossfeedFilter::new(sample_rate_hz)?;
            cf.set_enabled(false);
            Some(cf)
        } else {
            None
        };
        let gain = ReplayGain::new(ReplayGainConfig::default());
        let limiter = LookaheadLimiter::new(sample_rate_hz, ch);

        Ok(Self {
            sample_rate_hz,
            channels: ch,
            bypass: false,
            peq,
            crossfeed,
            gain,
            limiter,
        })
    }

    pub fn sample_rate_hz(&self) -> f64 {
        self.sample_rate_hz
    }

    pub fn set_bypass(&mut self, bypass: bool) {
        if self.bypass && !bypass {
            // Transitioning from bypass to active: reset filter states to prevent thumps
            self.reset();
        }
        self.bypass = bypass;
    }

    pub fn is_bypassed(&self) -> bool {
        self.bypass
    }

    pub fn reset(&mut self) {
        self.peq.reset();
        if let Some(cf) = &mut self.crossfeed {
            cf.reset();
        }
        self.limiter.reset();
    }

    pub fn peq_mut(&mut self) -> &mut ParametricEq {
        &mut self.peq
    }

    pub fn peq(&self) -> &ParametricEq {
        &self.peq
    }

    pub fn set_peq_bands(&mut self, bands: Vec<ParametricBand>) -> Result<(), DspError> {
        self.peq.set_bands(bands)
    }

    pub fn set_crossfeed_enabled(&mut self, enabled: bool) {
        if let Some(cf) = &mut self.crossfeed {
            cf.set_enabled(enabled);
        }
    }

    pub fn is_crossfeed_enabled(&self) -> bool {
        self.crossfeed
            .as_ref()
            .map(|c| c.is_enabled())
            .unwrap_or(false)
    }

    pub fn set_replay_gain(&mut self, config: ReplayGainConfig) {
        self.gain.set_config(config);
    }

    pub fn replay_gain(&self) -> &ReplayGain {
        &self.gain
    }

    pub fn set_limiter_enabled(&mut self, enabled: bool) {
        self.limiter.set_enabled(enabled);
    }

    pub fn is_limiter_enabled(&self) -> bool {
        self.limiter.is_enabled()
    }

    /// Returns true if any user DSP module (PEQ, Crossfeed, or ReplayGain) is actively altering audio (and bypass is false).
    pub fn is_dsp_active(&self) -> bool {
        if self.bypass {
            return false;
        }

        let peq_active = self.peq.bands().iter().any(|b| {
            b.enabled
                && (b.gain_db.abs() > 1e-4
                    || matches!(b.filter_type, FilterType::LowPass | FilterType::HighPass))
        });
        let cf_active = self.is_crossfeed_enabled();
        let gain_active = (self.gain.linear_gain() - 1.0).abs() > 1e-4;

        peq_active || cf_active || gain_active
    }

    /// Processes an interleaved slice of multi-channel 64-bit float samples.
    /// If bypass is true or all DSP modules are flat/inactive, returns immediately without modifying a single bit.
    pub fn process_interleaved(&mut self, samples: &mut [f64]) {
        if self.bypass || !self.is_dsp_active() {
            return;
        }

        // 1. ReplayGain linear scale
        self.gain.process_interleaved(samples);

        // 2. Parametric EQ cascade
        self.peq.process_interleaved(samples, self.channels);

        // 3. Headphone crossfeed (stereo only)
        if let Some(cf) = &mut self.crossfeed {
            cf.process_interleaved(samples, self.channels);
        }

        // 4. Lookahead peak limiter & soft clipper
        self.limiter.process_interleaved(samples, self.channels);
    }
}
