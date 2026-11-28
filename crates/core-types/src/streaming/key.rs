use serde::{Deserialize, Serialize};
use std::fmt;

/// Composite cache/resolution key uniquely identifying a track stream at a specific quality.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StreamKey {
    pub provider_id: String,
    pub track_id: String,
    pub quality_key: String,
}

impl StreamKey {
    /// Creates a composite stream key from provider identifier, track identifier, and quality key.
    pub fn new(
        provider_id: impl Into<String>,
        track_id: impl Into<String>,
        quality_key: impl Into<String>,
    ) -> Self {
        Self {
            provider_id: provider_id.into(),
            track_id: track_id.into(),
            quality_key: quality_key.into(),
        }
    }
}

impl fmt::Display for StreamKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}:{}",
            self.provider_id, self.track_id, self.quality_key
        )
    }
}

/// Streaming transport, caching, and session reset capabilities for a provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct StreamProviderCapabilities {
    pub supports_l1_url_cache: bool,
    pub supports_l2_head_cache: bool,
    pub requires_range_chunking: bool,
    pub needs_network_epoch_reset: bool,
    pub default_l1_safety_margin_sec: u64,
}

impl StreamProviderCapabilities {
    pub const fn new(
        supports_l1_url_cache: bool,
        supports_l2_head_cache: bool,
        requires_range_chunking: bool,
        needs_network_epoch_reset: bool,
        default_l1_safety_margin_sec: u64,
    ) -> Self {
        Self {
            supports_l1_url_cache,
            supports_l2_head_cache,
            requires_range_chunking,
            needs_network_epoch_reset,
            default_l1_safety_margin_sec,
        }
    }

    pub const fn youtube_music() -> Self {
        Self::new(true, true, true, true, 1800)
    }

    pub const fn qobuz() -> Self {
        Self::new(true, true, true, false, 60)
    }

    pub const fn tidal() -> Self {
        Self::new(true, true, true, false, 60)
    }

    pub const fn deezer() -> Self {
        Self::new(true, true, true, false, 120)
    }

    pub const fn apple_music() -> Self {
        Self::new(false, false, false, false, 0)
    }

    pub const fn local() -> Self {
        Self::new(false, false, false, false, 0)
    }

    /// Resolves streaming capabilities for a normalized provider identifier.
    pub fn for_provider(provider_id: &str) -> Self {
        match provider_id.trim().to_ascii_lowercase().as_str() {
            "youtube_music" | "ytm" => Self::youtube_music(),
            "qobuz" => Self::qobuz(),
            "tidal" => Self::tidal(),
            "deezer" => Self::deezer(),
            "apple_music" => Self::apple_music(),
            "local" => Self::local(),
            _ => Self::default(),
        }
    }
}
