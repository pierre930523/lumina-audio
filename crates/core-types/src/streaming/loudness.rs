use serde::{Deserialize, Serialize};

fn default_loudness_peak() -> f32 {
    1.0
}

/// Raw deserialization wire format for [`NormalizedLoudness`] so serde JSON payloads
/// from FFI/clients always pass through [`NormalizedLoudness::new`] clamping & NaN guards.
#[derive(Debug, Clone, Copy, Deserialize)]
struct RawNormalizedLoudness {
    gain_db: f32,
    #[serde(default = "default_loudness_peak")]
    peak: f32,
}

/// Unified loudness normalization metadata targeting a common `-14.0 LUFS` reference.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawNormalizedLoudness")]
pub struct NormalizedLoudness {
    pub gain_db: f32,
    #[serde(default = "default_loudness_peak")]
    pub peak: f32,
}

impl From<RawNormalizedLoudness> for NormalizedLoudness {
    fn from(raw: RawNormalizedLoudness) -> Self {
        Self::new(raw.gain_db, raw.peak)
    }
}

impl NormalizedLoudness {
    pub const TARGET_LUFS: f32 = -14.0;
    pub const MIN_GAIN_DB: f32 = -24.0;
    pub const MAX_POSITIVE_GAIN_DB: f32 = 6.0;

    /// Constructs a sanitized loudness adjustment targeting `-14.0 LUFS`.
    ///
    /// Finite `gain_db` is clamped to `[-24.0, +6.0]` dB (non-finite defaults to `0.0`);
    /// finite positive `peak` is preserved (otherwise defaults to `1.0`).
    pub fn new(gain_db: f32, peak: f32) -> Self {
        let gain_db = if gain_db.is_finite() {
            gain_db.clamp(Self::MIN_GAIN_DB, Self::MAX_POSITIVE_GAIN_DB)
        } else {
            0.0
        };
        let peak = if peak.is_finite() && peak > 0.0 {
            peak
        } else {
            1.0
        };
        Self { gain_db, peak }
    }

    /// Returns a sanitized copy with `gain_db` clamped to `[-24.0, +6.0]` dB and valid `peak`.
    pub fn sanitized(self) -> Self {
        Self::new(self.gain_db, self.peak)
    }

    /// Converts YouTube Music `loudnessDb` (positive = louder than -14 LUFS) to target gain.
    pub fn from_ytm_loudness_db(loudness_db: f32) -> Self {
        Self::new(-loudness_db, 1.0)
    }

    /// Converts ReplayGain 2.0 (-18 LUFS reference) to -14 LUFS target gain.
    pub fn from_replay_gain(gain_db: f32, peak: Option<f32>) -> Self {
        Self::new(gain_db + 4.0, peak.unwrap_or(1.0))
    }

    /// Converts Deezer `GAIN` (-15 LUFS reference) to -14 LUFS target gain.
    pub fn from_deezer_gain(gain_db: f32) -> Self {
        Self::new(gain_db + 1.0, 1.0)
    }

    /// Converts EBU R128 Q7.8 fixed-point gain (-23 LUFS reference) to -14 LUFS target gain.
    pub fn from_r128_q78(q78: i16) -> Self {
        Self::new((q78 as f32 / 256.0) + 9.0, 1.0)
    }
}
