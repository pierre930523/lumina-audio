use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Signal Path Types
// ============================================================================

/// Roon-style Signal Path classification indicator.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalQuality {
    /// Lossless bit-perfect path (purple indicator).
    Lossless,
    /// High-precision 64-bit DSP or lossless conversion (green indicator).
    Enhanced,
    /// Lossy source or OS shared mixer resampling (yellow/amber indicator).
    HighQuality,
}

impl SignalQuality {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Lossless => "lossless",
            Self::Enhanced => "enhanced",
            Self::HighQuality => "high_quality",
        }
    }

    pub const fn hex_color(&self) -> &'static str {
        match self {
            Self::Lossless => "#A259FF",    // Purple
            Self::Enhanced => "#2ED573",    // Green
            Self::HighQuality => "#FFA502", // Amber
        }
    }

    pub const fn description(&self) -> &'static str {
        match self {
            Self::Lossless => "Bit-perfect lossless stream",
            Self::Enhanced => "High-precision 64-bit DSP or conversion",
            Self::HighQuality => "Lossy audio or OS resampled stream",
        }
    }
}

impl fmt::Display for SignalQuality {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for SignalQuality {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let normalized = s.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "lossless" => Ok(Self::Lossless),
            "enhanced" => Ok(Self::Enhanced),
            "high_quality" | "highquality" | "high-quality" => Ok(Self::HighQuality),
            _ => Err(ValidationError::UnknownSignalQuality(s.to_string())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignalPathNode {
    pub stage: String,
    pub detail: String,
    pub quality: SignalQuality,
}

impl SignalPathNode {
    pub fn new(
        stage: impl Into<String>,
        detail: impl Into<String>,
        quality: SignalQuality,
    ) -> Result<Self, ValidationError> {
        let s = stage.into();
        let d = detail.into();
        if s.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "stage",
                message: "stage name cannot be empty",
            });
        }
        if d.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "detail",
                message: "detail cannot be empty",
            });
        }
        Ok(Self {
            stage: s.trim().to_string(),
            detail: d.trim().to_string(),
            quality,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignalPath {
    pub overall: SignalQuality,
    pub nodes: Vec<SignalPathNode>,
}

impl SignalPath {
    pub fn new(nodes: Vec<SignalPathNode>) -> Result<Self, ValidationError> {
        if nodes.is_empty() {
            return Err(ValidationError::EmptySignalPath);
        }
        let overall = Self::compute_overall(&nodes);
        Ok(Self { overall, nodes })
    }

    pub fn with_overall(
        overall: SignalQuality,
        nodes: Vec<SignalPathNode>,
    ) -> Result<Self, ValidationError> {
        if nodes.is_empty() {
            return Err(ValidationError::EmptySignalPath);
        }
        Ok(Self { overall, nodes })
    }

    pub fn compute_overall(nodes: &[SignalPathNode]) -> SignalQuality {
        if nodes
            .iter()
            .any(|n| n.quality == SignalQuality::HighQuality)
        {
            SignalQuality::HighQuality
        } else if nodes.iter().any(|n| n.quality == SignalQuality::Enhanced) {
            SignalQuality::Enhanced
        } else {
            SignalQuality::Lossless
        }
    }
}
