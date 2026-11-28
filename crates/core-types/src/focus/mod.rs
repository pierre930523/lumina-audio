use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

pub fn default_focus_limit() -> u32 {
    100
}

// ============================================================================
// Step 3: Focus Multi-Dimensional Filter Engine DTOs
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FocusEntity {
    #[default]
    Albums,
    Tracks,
}

impl FocusEntity {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Albums => "albums",
            Self::Tracks => "tracks",
        }
    }
}

impl fmt::Display for FocusEntity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for FocusEntity {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "albums" => Ok(Self::Albums),
            "tracks" => Ok(Self::Tracks),
            _ => Err(ValidationError::EmptyField {
                field: "entity",
                message: "focus entity must be 'albums' or 'tracks'",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FocusPredicateMode {
    #[default]
    Include,
    Exclude,
}

impl FocusPredicateMode {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Include => "include",
            Self::Exclude => "exclude",
        }
    }

    #[inline]
    pub const fn toggled(self) -> Self {
        match self {
            Self::Include => Self::Exclude,
            Self::Exclude => Self::Include,
        }
    }
}

impl fmt::Display for FocusPredicateMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for FocusPredicateMode {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "include" => Ok(Self::Include),
            "exclude" => Ok(Self::Exclude),
            _ => Err(ValidationError::EmptyField {
                field: "mode",
                message: "focus predicate mode must be 'include' or 'exclude'",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FocusFacet {
    Format,
    BitDepth,
    SampleRate,
    Channels,
    Source,
    ReleaseYear,
    AddedAt,
    PlayStatus,
    Genre,
    Label,
    Tag,
    Inspector,
    Preference,
}

impl FocusFacet {
    pub const ALL: [Self; 13] = [
        Self::Format,
        Self::BitDepth,
        Self::SampleRate,
        Self::Channels,
        Self::Source,
        Self::ReleaseYear,
        Self::AddedAt,
        Self::PlayStatus,
        Self::Genre,
        Self::Label,
        Self::Tag,
        Self::Inspector,
        Self::Preference,
    ];

    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Format => "format",
            Self::BitDepth => "bit_depth",
            Self::SampleRate => "sample_rate",
            Self::Channels => "channels",
            Self::Source => "source",
            Self::ReleaseYear => "release_year",
            Self::AddedAt => "added_at",
            Self::PlayStatus => "play_status",
            Self::Genre => "genre",
            Self::Label => "label",
            Self::Tag => "tag",
            Self::Inspector => "inspector",
            Self::Preference => "preference",
        }
    }
}

impl fmt::Display for FocusFacet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for FocusFacet {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "format" => Ok(Self::Format),
            "bit_depth" => Ok(Self::BitDepth),
            "sample_rate" => Ok(Self::SampleRate),
            "channels" => Ok(Self::Channels),
            "source" => Ok(Self::Source),
            "release_year" => Ok(Self::ReleaseYear),
            "added_at" => Ok(Self::AddedAt),
            "play_status" => Ok(Self::PlayStatus),
            "genre" => Ok(Self::Genre),
            "label" => Ok(Self::Label),
            "tag" => Ok(Self::Tag),
            "inspector" => Ok(Self::Inspector),
            "preference" => Ok(Self::Preference),
            _ => Err(ValidationError::EmptyField {
                field: "facet",
                message: "unknown focus facet",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FocusValue {
    String {
        value: String,
    },
    Int {
        value: i64,
    },
    IntRange {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        min: Option<i64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max: Option<i64>,
    },
    DateRange {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FocusPredicate {
    pub facet: FocusFacet,
    pub value: FocusValue,
    #[serde(default)]
    pub mode: FocusPredicateMode,
}

impl FocusPredicate {
    pub fn toggled(&self) -> Self {
        Self {
            facet: self.facet,
            value: self.value.clone(),
            mode: self.mode.toggled(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FocusSortField {
    #[default]
    Title,
    Artist,
    ReleaseYear,
    AddedAt,
    SampleRate,
    Duration,
    Random,
}

impl FocusSortField {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Title => "title",
            Self::Artist => "artist",
            Self::ReleaseYear => "release_year",
            Self::AddedAt => "added_at",
            Self::SampleRate => "sample_rate",
            Self::Duration => "duration",
            Self::Random => "random",
        }
    }
}

impl fmt::Display for FocusSortField {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for FocusSortField {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "title" => Ok(Self::Title),
            "artist" => Ok(Self::Artist),
            "release_year" => Ok(Self::ReleaseYear),
            "added_at" => Ok(Self::AddedAt),
            "sample_rate" => Ok(Self::SampleRate),
            "duration" => Ok(Self::Duration),
            "random" => Ok(Self::Random),
            _ => Err(ValidationError::EmptyField {
                field: "field",
                message: "unknown focus sort field",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FocusSortDirection {
    #[default]
    Asc,
    Desc,
}

impl FocusSortDirection {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Asc => "asc",
            Self::Desc => "desc",
        }
    }
}

impl fmt::Display for FocusSortDirection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for FocusSortDirection {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "asc" => Ok(Self::Asc),
            "desc" => Ok(Self::Desc),
            _ => Err(ValidationError::EmptyField {
                field: "direction",
                message: "sort direction must be 'asc' or 'desc'",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct FocusSort {
    #[serde(default)]
    pub field: FocusSortField,
    #[serde(default)]
    pub direction: FocusSortDirection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct FocusQuery {
    #[serde(default)]
    pub entity: FocusEntity,
    #[serde(default)]
    pub predicates: Vec<FocusPredicate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort: Option<FocusSort>,
    #[serde(default)]
    pub include_hidden: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FocusQueryRequest {
    #[serde(default)]
    pub query: FocusQuery,
    #[serde(default = "default_focus_limit")]
    pub limit: u32,
    #[serde(default)]
    pub offset: u32,
}

impl Default for FocusQueryRequest {
    fn default() -> Self {
        Self {
            query: FocusQuery::default(),
            limit: default_focus_limit(),
            offset: 0,
        }
    }
}

mod response;

pub use response::*;

#[cfg(test)]
mod tests;
