use core_types::{PeqBandConfig, PeqFilterKind};
use serde::{Deserialize, Serialize};

use super::biquad::FilterType;
use super::peq::{ParametricBand, ParametricEq};
use crate::error::{CoreAudioError, DspError};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AutoEqProfile {
    pub preamp_db: f64,
    pub bands: Vec<ParametricBand>,
}

fn strip_unit_suffix<'a>(token: &'a str, unit_lower: &str) -> &'a str {
    let trimmed = token.trim();
    if trimmed.len() > unit_lower.len()
        && trimmed[trimmed.len() - unit_lower.len()..].eq_ignore_ascii_case(unit_lower)
    {
        &trimmed[..trimmed.len() - unit_lower.len()]
    } else {
        trimmed
    }
}

pub struct AutoEqParser;

impl AutoEqParser {
    /// Parses an AutoEQ or Equalizer APO parametric export configuration.
    pub fn parse(text: &str) -> Result<AutoEqProfile, DspError> {
        if text.trim().is_empty() {
            return Err(DspError::InvalidAutoEqSyntax(
                "AutoEQ text is empty".to_string(),
            ));
        }

        let mut preamp_db = 0.0;
        let mut bands = Vec::new();

        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            // 1. Check for Preamp: line
            if line.to_ascii_lowercase().starts_with("preamp:") {
                let parts: Vec<&str> = line["preamp:".len()..].split_whitespace().collect();
                let val_str = parts.first().ok_or_else(|| {
                    DspError::InvalidAutoEqSyntax(format!("Missing Preamp value: {line}"))
                })?;
                let val: f64 = strip_unit_suffix(val_str, "db")
                    .parse()
                    .map_err(|_| DspError::InvalidAutoEqSyntax(format!("Invalid Preamp value: {line}")))?;
                if !val.is_finite() || val.abs() > 60.0 {
                    return Err(DspError::InvalidFilterParameters(format!(
                        "Preamp out of bounds (+/-60dB): {val}"
                    )));
                }
                preamp_db = val;
                continue;
            }

            // 2. Check for Filter <N>: line
            if line.to_ascii_lowercase().starts_with("filter") {
                let colon_idx = line
                    .find(':')
                    .ok_or_else(|| DspError::InvalidAutoEqSyntax(format!("Missing colon in filter line: {line}")))?;
                let tokens: Vec<&str> = line[colon_idx + 1..].split_whitespace().collect();
                if tokens.is_empty() {
                    continue;
                }

                let mut enabled = true;
                let mut filter_type = FilterType::Peaking;
                let mut freq_hz: Option<f64> = None;
                let mut gain_db: f64 = 0.0;
                let mut q_factor: f64 = 1.0 / std::f64::consts::SQRT_2; // 0.7071

                let mut i = 0;
                while i < tokens.len() {
                    let tok = tokens[i].to_ascii_uppercase();
                    match tok.as_str() {
                        "ON" => {
                            enabled = true;
                            i += 1;
                        }
                        "OFF" => {
                            enabled = false;
                            i += 1;
                        }
                        "PK" | "PEQ" => {
                            filter_type = FilterType::Peaking;
                            i += 1;
                        }
                        "LSC" | "LS" => {
                            filter_type = FilterType::LowShelf;
                            i += 1;
                        }
                        "HSC" | "HS" => {
                            filter_type = FilterType::HighShelf;
                            i += 1;
                        }
                        "LP" | "LPF" => {
                            filter_type = FilterType::LowPass;
                            i += 1;
                        }
                        "HP" | "HPF" => {
                            filter_type = FilterType::HighPass;
                            i += 1;
                        }
                        "FC" => {
                            if i + 1 >= tokens.len() {
                                return Err(DspError::InvalidAutoEqSyntax(format!(
                                    "Missing Fc value in line: {line}"
                                )));
                            }
                            let parsed_freq: f64 = strip_unit_suffix(tokens[i + 1], "hz")
                                .parse()
                                .map_err(|_| DspError::InvalidAutoEqSyntax(format!("Invalid Fc: {}", tokens[i + 1])))?;
                            freq_hz = Some(parsed_freq);
                            i += 2;
                            if i < tokens.len() && tokens[i].eq_ignore_ascii_case("HZ") {
                                i += 1;
                            }
                        }
                        "GAIN" => {
                            if i + 1 >= tokens.len() {
                                return Err(DspError::InvalidAutoEqSyntax(format!(
                                    "Missing Gain value in line: {line}"
                                )));
                            }
                            gain_db = strip_unit_suffix(tokens[i + 1], "db")
                                .parse()
                                .map_err(|_| DspError::InvalidAutoEqSyntax(format!("Invalid Gain: {}", tokens[i + 1])))?;
                            i += 2;
                            if i < tokens.len() && tokens[i].eq_ignore_ascii_case("DB") {
                                i += 1;
                            }
                        }
                        "Q" => {
                            if i + 1 >= tokens.len() {
                                return Err(DspError::InvalidAutoEqSyntax(format!(
                                    "Missing Q value in line: {line}"
                                )));
                            }
                            q_factor = tokens[i + 1]
                                .parse()
                                .map_err(|_| {
                                    DspError::InvalidAutoEqSyntax(format!(
                                        "Invalid Q: {}",
                                        tokens[i + 1]
                                    ))
                                })?;
                            i += 2;
                        }
                        _ => {
                            i += 1;
                        }
                    }
                }

                let freq_hz = freq_hz.ok_or_else(|| {
                    DspError::InvalidAutoEqSyntax(format!("Missing Fc frequency in filter line: {line}"))
                })?;

                // Range validation
                if !freq_hz.is_finite() || freq_hz <= 0.0 || freq_hz > 100_000.0 {
                    return Err(DspError::InvalidFilterParameters(format!("Frequency out of bounds: {freq_hz}")));
                }
                if !q_factor.is_finite() || q_factor <= 0.0 || q_factor > 100.0 {
                    return Err(DspError::InvalidFilterParameters(format!("Q factor out of bounds: {q_factor}")));
                }
                if !gain_db.is_finite() || gain_db.abs() > 60.0 {
                    return Err(DspError::InvalidFilterParameters(format!("Gain out of bounds (+/-60dB): {gain_db}")));
                }

                bands.push(ParametricBand {
                    filter_type,
                    frequency_hz: freq_hz,
                    gain_db,
                    q_factor,
                    enabled,
                });
            }
        }

        if bands.is_empty() {
            return Err(DspError::InvalidAutoEqSyntax(
                "No valid Filter lines found in AutoEQ input".to_string(),
            ));
        }

        Ok(AutoEqProfile { preamp_db, bands })
    }
}

impl AutoEqProfile {
    pub fn to_peq(&self, sample_rate_hz: f64, channels: usize) -> Result<ParametricEq, DspError> {
        ParametricEq::new(sample_rate_hz, channels, self.bands.clone())
    }

    pub fn to_band_configs(&self) -> Vec<PeqBandConfig> {
        self.bands
            .iter()
            .map(|b| PeqBandConfig {
                filter_type: match b.filter_type {
                    FilterType::Peaking => PeqFilterKind::Peaking,
                    FilterType::LowShelf => PeqFilterKind::LowShelf,
                    FilterType::HighShelf => PeqFilterKind::HighShelf,
                    FilterType::LowPass => PeqFilterKind::LowPass,
                    FilterType::HighPass => PeqFilterKind::HighPass,
                },
                frequency_hz: b.frequency_hz,
                gain_db: b.gain_db,
                q_factor: b.q_factor,
                enabled: b.enabled,
            })
            .collect()
    }
}

/// Parses an AutoEQ / Equalizer APO parametric EQ text into `core_types::PeqBandConfig` items.
pub fn parse_autoeq_txt(input: &str) -> Result<Vec<PeqBandConfig>, CoreAudioError> {
    let profile = AutoEqParser::parse(input)?;
    Ok(profile.to_band_configs())
}

/// Parses an AutoEQ / Equalizer APO text preserving both `Preamp` dB and `PeqBandConfig` list.
pub fn parse_autoeq_profile_dto(input: &str) -> Result<(f64, Vec<PeqBandConfig>), CoreAudioError> {
    let profile = AutoEqParser::parse(input)?;
    Ok((profile.preamp_db, profile.to_band_configs()))
}
