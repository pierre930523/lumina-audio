use serde::{Deserialize, Serialize};
use std::fmt;

use super::StreamKey;

/// Identifies one of the two native playback decks in the dual-deck gapless engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum DeckId {
    #[default]
    DeckA = 0,
    DeckB = 1,
}

impl DeckId {
    /// Returns the opposite deck.
    #[inline]
    pub const fn other(self) -> Self {
        match self {
            Self::DeckA => Self::DeckB,
            Self::DeckB => Self::DeckA,
        }
    }

    /// Returns the zero-based array index (`0` for Deck A, `1` for Deck B).
    #[inline]
    pub const fn index(self) -> usize {
        self as usize
    }

    /// Maps a numeric deck index (`0` or `1`) back into a [`DeckId`], defaulting to [`DeckId::DeckA`].
    #[inline]
    pub const fn from_index(idx: u8) -> Self {
        match idx {
            1 => Self::DeckB,
            _ => Self::DeckA,
        }
    }

    /// Returns the canonical snake-case string representation (`"deck_a"` or `"deck_b"`).
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::DeckA => "deck_a",
            Self::DeckB => "deck_b",
        }
    }
}

impl fmt::Display for DeckId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Lifecycle states of an individual deck in the dual-deck state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
#[repr(u8)]
pub enum DeckState {
    #[default]
    Idle = 0,
    Resolving = 1,
    Prebuffering = 2,
    StandbyReady = 3,
    Playing = 4,
    Seeking = 5,
    #[serde(rename = "RECOVERING_403", alias = "RECOVERING403")]
    Recovering403 = 6,
    Draining = 7,
}

impl DeckState {
    /// Converts a raw `u8` discriminant into a [`DeckState`], falling back to [`DeckState::Idle`].
    #[inline]
    pub const fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Idle,
            1 => Self::Resolving,
            2 => Self::Prebuffering,
            3 => Self::StandbyReady,
            4 => Self::Playing,
            5 => Self::Seeking,
            6 => Self::Recovering403,
            7 => Self::Draining,
            _ => Self::Idle,
        }
    }

    /// Returns the canonical uppercase string name of this deck state.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "IDLE",
            Self::Resolving => "RESOLVING",
            Self::Prebuffering => "PREBUFFERING",
            Self::StandbyReady => "STANDBY_READY",
            Self::Playing => "PLAYING",
            Self::Seeking => "SEEKING",
            Self::Recovering403 => "RECOVERING_403",
            Self::Draining => "DRAINING",
        }
    }
}

impl fmt::Display for DeckState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Track metadata associated with an active or standby playback deck.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct DeckTrackMetadata {
    pub track_id: String,
    pub provider_id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    #[serde(default)]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub duration_ms: u64,
}

/// Snapshot of the dual-deck engine state, standby readiness, and transition telemetry.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct DualDeckStatusSnapshot {
    pub active_deck: DeckId,
    pub deck_a_state: DeckState,
    pub deck_b_state: DeckState,
    pub deck_a_key: Option<StreamKey>,
    pub deck_b_key: Option<StreamKey>,
    pub standby_buffered_ms: u64,
    pub gapless_transitions: u64,
    pub manual_zero_latency_switches: u64,
    pub format_mismatch_recoveries: u64,
    #[serde(default)]
    pub swap_generation: u64,
    #[serde(default)]
    pub playback_epoch: u64,
    #[serde(default)]
    pub active_track: Option<DeckTrackMetadata>,
}
