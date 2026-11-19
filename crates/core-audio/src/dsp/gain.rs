use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReplayGainMode {
    Track,
    Album,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReplayGainConfig {
    pub mode: ReplayGainMode,
    pub preamp_db: f64,
    pub track_gain_db: Option<f64>,
    pub track_peak: Option<f64>,
    pub album_gain_db: Option<f64>,
    pub album_peak: Option<f64>,
    pub prevent_clipping: bool,
}

impl Default for ReplayGainConfig {
    fn default() -> Self {
        Self {
            mode: ReplayGainMode::Track,
            preamp_db: 0.0,
            track_gain_db: None,
            track_peak: None,
            album_gain_db: None,
            album_peak: None,
            prevent_clipping: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ReplayGain {
    config: ReplayGainConfig,
    linear_gain: f64,
}

impl ReplayGain {
    pub fn new(config: ReplayGainConfig) -> Self {
        let linear_gain = Self::compute_linear_gain(&config);
        Self {
            config,
            linear_gain,
        }
    }

    pub fn from_gain_db(gain_db: f64, preamp_db: f64) -> Self {
        let config = ReplayGainConfig {
            mode: ReplayGainMode::Track,
            preamp_db,
            track_gain_db: Some(gain_db),
            track_peak: None,
            album_gain_db: None,
            album_peak: None,
            prevent_clipping: true,
        };
        Self::new(config)
    }

    pub fn linear_gain(&self) -> f64 {
        self.linear_gain
    }

    pub fn config(&self) -> &ReplayGainConfig {
        &self.config
    }

    pub fn set_config(&mut self, config: ReplayGainConfig) {
        self.linear_gain = Self::compute_linear_gain(&config);
        self.config = config;
    }

    fn compute_linear_gain(config: &ReplayGainConfig) -> f64 {
        let (raw_gain_db, peak) = match config.mode {
            ReplayGainMode::Track => (
                config.track_gain_db.or(config.album_gain_db),
                config.track_peak.or(config.album_peak),
            ),
            ReplayGainMode::Album => (
                config.album_gain_db.or(config.track_gain_db),
                config.album_peak.or(config.track_peak),
            ),
        };

        let gain_db = raw_gain_db.unwrap_or(0.0) + config.preamp_db;
        let mut linear = 10.0f64.powf(gain_db / 20.0);

        if config.prevent_clipping
            && let Some(peak_val) = peak
            && peak_val > 0.0
            && linear * peak_val > 1.0
        {
            linear = 1.0 / peak_val;
        }

        linear
    }

    #[inline(always)]
    pub fn process_sample(&self, sample: f64) -> f64 {
        sample * self.linear_gain
    }

    pub fn process_interleaved(&self, samples: &mut [f64]) {
        if (self.linear_gain - 1.0).abs() < 1e-9 {
            return;
        }
        for sample in samples.iter_mut() {
            *sample *= self.linear_gain;
        }
    }
}
