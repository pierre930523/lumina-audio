pub mod hifi;
pub use hifi::*;

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

// ============================================================================
// Error Types
// ============================================================================

#[derive(Debug, thiserror::Error, PartialEq, Eq, Clone)]
pub enum ValidationError {
    #[error("field '{field}' cannot be empty: {message}")]
    EmptyField {
        field: &'static str,
        message: &'static str,
    },
    #[error("invalid sample rate: {0} Hz (must be between 1 and 50,000,000 Hz)")]
    InvalidSampleRate(u32),
    #[error("invalid channels: {0} (must be between 1 and 32)")]
    InvalidChannels(u8),
    #[error("invalid bit depth {bit_depth} for codec {codec:?}")]
    InvalidBitDepth {
        bit_depth: u8,
        codec: AudioCodec,
    },
    #[error("DSD codec requires bit_depth == 1 and is_dsd == true")]
    InvalidDsdFormat,
    #[error("invalid duration: {0} ms (must be greater than 0)")]
    InvalidDuration(u64),
    #[error("invalid hex color '{0}': must be #RRGGBB or #RRGGBBAA")]
    InvalidHexColor(String),
    #[error("invalid ISRC '{0}': must be 12 alphanumeric characters (or CC-XXX-YY-NNNNN)")]
    InvalidIsrc(String),
    #[error("invalid release year: {0} (must be between 1000 and 3000)")]
    InvalidReleaseYear(i32),
    #[error("invalid track number: {0} (must be >= 1)")]
    InvalidTrackNumber(u16),
    #[error("invalid disc number: {0} (must be >= 1)")]
    InvalidDiscNumber(u16),
    #[error("unknown provider: '{0}'")]
    UnknownProvider(String),
    #[error("unknown audio codec: '{0}'")]
    UnknownAudioCodec(String),
    #[error("unknown output backend: '{0}'")]
    UnknownOutputBackend(String),
    #[error("unknown signal quality: '{0}'")]
    UnknownSignalQuality(String),
    #[error("signal path must contain at least one node")]
    EmptySignalPath,
    #[error("Qobuz token cannot be empty or whitespace")]
    EmptyQobuzToken,
    #[error("Qobuz credentials cannot be empty or whitespace")]
    EmptyQobuzCredentials,
}

// ============================================================================
// Feature 6: ProviderKind
// ============================================================================

/// Supported music and storage providers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Local,
    Smb,
    WebDav,
    Qobuz,
    Tidal,
    Deezer,
}

impl ProviderKind {
    pub const ALL: [ProviderKind; 6] = [
        ProviderKind::Local,
        ProviderKind::Smb,
        ProviderKind::WebDav,
        ProviderKind::Qobuz,
        ProviderKind::Tidal,
        ProviderKind::Deezer,
    ];

    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Smb => "smb",
            Self::WebDav => "web_dav",
            Self::Qobuz => "qobuz",
            Self::Tidal => "tidal",
            Self::Deezer => "deezer",
        }
    }

    pub const fn display_name(&self) -> &'static str {
        match self {
            Self::Local => "Local Storage",
            Self::Smb => "SMB Network Share",
            Self::WebDav => "WebDAV Server",
            Self::Qobuz => "Qobuz",
            Self::Tidal => "Tidal",
            Self::Deezer => "Deezer",
        }
    }

    pub const fn is_streaming(&self) -> bool {
        matches!(self, Self::Qobuz | Self::Tidal | Self::Deezer)
    }

    pub const fn is_local_or_network(&self) -> bool {
        matches!(self, Self::Local | Self::Smb | Self::WebDav)
    }

    pub const fn requires_auth(&self) -> bool {
        matches!(self, Self::Qobuz | Self::Tidal | Self::Deezer | Self::Smb | Self::WebDav)
    }
}

impl fmt::Display for ProviderKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for ProviderKind {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let normalized = s.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "local" => Ok(Self::Local),
            "smb" => Ok(Self::Smb),
            "web_dav" | "webdav" | "web-dav" => Ok(Self::WebDav),
            "qobuz" => Ok(Self::Qobuz),
            "tidal" => Ok(Self::Tidal),
            "deezer" => Ok(Self::Deezer),
            _ => Err(ValidationError::UnknownProvider(s.to_string())),
        }
    }
}

// ============================================================================
// Feature 7: QobuzAuthMode
// ============================================================================

/// Supported Qobuz authentication flows, supporting direct `user_auth_token` login.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum QobuzAuthMode {
    Token {
        user_auth_token: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app_secret: Option<String>,
    },
    Credentials {
        username: String,
        password: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app_secret: Option<String>,
    },
}

impl QobuzAuthMode {
    pub fn token(
        user_auth_token: impl Into<String>,
        app_id: Option<String>,
        app_secret: Option<String>,
    ) -> Result<Self, ValidationError> {
        let token = user_auth_token.into();
        if token.trim().is_empty() {
            return Err(ValidationError::EmptyQobuzToken);
        }
        let mode = Self::Token {
            user_auth_token: token.trim().to_string(),
            app_id: app_id.filter(|s| !s.trim().is_empty()),
            app_secret: app_secret.filter(|s| !s.trim().is_empty()),
        };
        Ok(mode)
    }

    pub fn from_token(user_auth_token: impl Into<String>) -> Result<Self, ValidationError> {
        Self::token(user_auth_token, None, None)
    }

    pub fn credentials(
        username: impl Into<String>,
        password: impl Into<String>,
        app_id: Option<String>,
        app_secret: Option<String>,
    ) -> Result<Self, ValidationError> {
        let u = username.into();
        let p = password.into();
        if u.trim().is_empty() || p.trim().is_empty() {
            return Err(ValidationError::EmptyQobuzCredentials);
        }
        let mode = Self::Credentials {
            username: u.trim().to_string(),
            password: p,
            app_id: app_id.filter(|s| !s.trim().is_empty()),
            app_secret: app_secret.filter(|s| !s.trim().is_empty()),
        };
        Ok(mode)
    }

    pub fn from_credentials(
        username: impl Into<String>,
        password: impl Into<String>,
    ) -> Result<Self, ValidationError> {
        Self::credentials(username, password, None, None)
    }

    pub fn is_token(&self) -> bool {
        matches!(self, Self::Token { .. })
    }

    pub fn is_credentials(&self) -> bool {
        matches!(self, Self::Credentials { .. })
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        match self {
            Self::Token { user_auth_token, .. } => {
                if user_auth_token.trim().is_empty() {
                    return Err(ValidationError::EmptyQobuzToken);
                }
            }
            Self::Credentials { username, password, .. } => {
                if username.trim().is_empty() || password.trim().is_empty() {
                    return Err(ValidationError::EmptyQobuzCredentials);
                }
            }
        }
        Ok(())
    }
}

// ============================================================================
// Feature 8: AudioCodec & AudioFormat
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioCodec {
    Flac,
    Alac,
    Wav,
    Aiff,
    Dsf,
    Dsdiff,
    Aac,
    Mp3,
    Opus,
}

impl AudioCodec {
    pub const ALL: [AudioCodec; 9] = [
        Self::Flac,
        Self::Alac,
        Self::Wav,
        Self::Aiff,
        Self::Dsf,
        Self::Dsdiff,
        Self::Aac,
        Self::Mp3,
        Self::Opus,
    ];

    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Flac => "flac",
            Self::Alac => "alac",
            Self::Wav => "wav",
            Self::Aiff => "aiff",
            Self::Dsf => "dsf",
            Self::Dsdiff => "dsdiff",
            Self::Aac => "aac",
            Self::Mp3 => "mp3",
            Self::Opus => "opus",
        }
    }

    pub const fn is_dsd(&self) -> bool {
        matches!(self, Self::Dsf | Self::Dsdiff)
    }

    pub const fn is_lossless(&self) -> bool {
        matches!(self, Self::Flac | Self::Alac | Self::Wav | Self::Aiff | Self::Dsf | Self::Dsdiff)
    }

    pub const fn is_lossy(&self) -> bool {
        !self.is_lossless()
    }

    pub const fn default_file_extension(&self) -> &'static str {
        match self {
            Self::Flac => "flac",
            Self::Alac => "m4a",
            Self::Wav => "wav",
            Self::Aiff => "aiff",
            Self::Dsf => "dsf",
            Self::Dsdiff => "dff",
            Self::Aac => "aac",
            Self::Mp3 => "mp3",
            Self::Opus => "opus",
        }
    }
}

impl fmt::Display for AudioCodec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Flac => write!(f, "FLAC"),
            Self::Alac => write!(f, "ALAC"),
            Self::Wav => write!(f, "WAV"),
            Self::Aiff => write!(f, "AIFF"),
            Self::Dsf => write!(f, "DSF"),
            Self::Dsdiff => write!(f, "DSDIFF"),
            Self::Aac => write!(f, "AAC"),
            Self::Mp3 => write!(f, "MP3"),
            Self::Opus => write!(f, "Opus"),
        }
    }
}

impl FromStr for AudioCodec {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let normalized = s.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "flac" => Ok(Self::Flac),
            "alac" => Ok(Self::Alac),
            "wav" | "wave" => Ok(Self::Wav),
            "aiff" | "aif" => Ok(Self::Aiff),
            "dsf" => Ok(Self::Dsf),
            "dsdiff" | "dff" => Ok(Self::Dsdiff),
            "aac" => Ok(Self::Aac),
            "mp3" => Ok(Self::Mp3),
            "opus" => Ok(Self::Opus),
            _ => Err(ValidationError::UnknownAudioCodec(s.to_string())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AudioFormat {
    pub codec: AudioCodec,
    pub sample_rate_hz: u32,
    pub bit_depth: u8,
    pub channels: u8,
    pub is_dsd: bool,
}

impl AudioFormat {
    pub fn new(
        codec: AudioCodec,
        sample_rate_hz: u32,
        bit_depth: u8,
        channels: u8,
    ) -> Result<Self, ValidationError> {
        if sample_rate_hz == 0 || sample_rate_hz > 50_000_000 {
            return Err(ValidationError::InvalidSampleRate(sample_rate_hz));
        }
        if channels == 0 || channels > 32 {
            return Err(ValidationError::InvalidChannels(channels));
        }

        let is_dsd = codec.is_dsd();
        if is_dsd {
            if bit_depth != 1 {
                return Err(ValidationError::InvalidDsdFormat);
            }
        } else if bit_depth == 0 || bit_depth > 64 {
            return Err(ValidationError::InvalidBitDepth { bit_depth, codec });
        }

        Ok(Self {
            codec,
            sample_rate_hz,
            bit_depth,
            channels,
            is_dsd,
        })
    }

    pub fn pcm(
        codec: AudioCodec,
        sample_rate_hz: u32,
        bit_depth: u8,
        channels: u8,
    ) -> Result<Self, ValidationError> {
        if codec.is_dsd() {
            return Err(ValidationError::InvalidDsdFormat);
        }
        Self::new(codec, sample_rate_hz, bit_depth, channels)
    }

    pub fn dsd(
        codec: AudioCodec,
        sample_rate_hz: u32,
        channels: u8,
    ) -> Result<Self, ValidationError> {
        if !codec.is_dsd() {
            return Err(ValidationError::InvalidDsdFormat);
        }
        Self::new(codec, sample_rate_hz, 1, channels)
    }

    pub fn cd_quality() -> Self {
        Self {
            codec: AudioCodec::Flac,
            sample_rate_hz: 44100,
            bit_depth: 16,
            channels: 2,
            is_dsd: false,
        }
    }

    pub fn is_dsd(&self) -> bool {
        self.is_dsd
    }

    pub fn is_hi_res(&self) -> bool {
        self.is_dsd || self.sample_rate_hz > 48000 || self.bit_depth > 16
    }

    pub fn is_cd_quality(&self) -> bool {
        !self.is_dsd && self.sample_rate_hz == 44100 && self.bit_depth == 16
    }

    pub fn dsd_rate_label(&self) -> Option<&'static str> {
        if !self.is_dsd {
            return None;
        }
        match self.sample_rate_hz {
            2_822_400 | 3_072_000 => Some("DSD64"),
            5_644_800 | 6_144_000 => Some("DSD128"),
            11_289_600 | 12_288_000 => Some("DSD256"),
            22_579_200 | 24_576_000 => Some("DSD512"),
            45_158_400 => Some("DSD1024"),
            _ => Some("DSD"),
        }
    }

    fn formatted_rate(&self) -> String {
        if self.is_dsd {
            format!("{:.2}MHz", self.sample_rate_hz as f64 / 1_000_000.0)
        } else if self.sample_rate_hz.is_multiple_of(1000) {
            format!("{}kHz", self.sample_rate_hz / 1000)
        } else if self.sample_rate_hz.is_multiple_of(100) {
            format!("{:.1}kHz", self.sample_rate_hz as f64 / 1000.0)
        } else {
            format!("{:.2}kHz", self.sample_rate_hz as f64 / 1000.0)
        }
    }
}

impl fmt::Display for AudioFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_dsd {
            let label = self.dsd_rate_label().unwrap_or("DSD");
            let mhz = self.formatted_rate();
            write!(f, "{} {} {} {}ch", self.codec, label, mhz, self.channels)
        } else {
            write!(
                f,
                "{} {}-bit/{} {}ch",
                self.codec,
                self.bit_depth,
                self.formatted_rate(),
                self.channels
            )
        }
    }
}

// ============================================================================
// Feature 9: CanonicalAlbum & AlbumVersion
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalAlbum {
    pub id: String,
    pub title: String,
    pub sort_title: String,
    pub artist_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    pub release_year: Option<i32>,
    pub musicbrainz_release_group_id: Option<String>,
    pub cover_url: Option<String>,
    pub versions: Vec<AlbumVersion>,
}

impl CanonicalAlbum {
    pub fn new(
        title: impl Into<String>,
        artist_name: impl Into<String>,
    ) -> Result<Self, ValidationError> {
        let t = title.into();
        let a = artist_name.into();
        if t.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "title",
                message: "album title cannot be empty",
            });
        }
        if a.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "artist_name",
                message: "artist name cannot be empty",
            });
        }

        let sort_title = Self::derive_sort_title(&t);

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            title: t.trim().to_string(),
            sort_title,
            artist_name: a.trim().to_string(),
            album_artist: None,
            release_year: None,
            musicbrainz_release_group_id: None,
            cover_url: None,
            versions: Vec::new(),
        })
    }

    pub fn with_id(
        id: impl Into<String>,
        title: impl Into<String>,
        artist_name: impl Into<String>,
    ) -> Result<Self, ValidationError> {
        let mut album = Self::new(title, artist_name)?;
        let id_str = id.into();
        if id_str.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "id",
                message: "album ID cannot be empty",
            });
        }
        album.id = id_str;
        Ok(album)
    }

    pub fn with_release_year(mut self, year: i32) -> Result<Self, ValidationError> {
        if !(1000..=3000).contains(&year) {
            return Err(ValidationError::InvalidReleaseYear(year));
        }
        self.release_year = Some(year);
        Ok(self)
    }

    pub fn with_musicbrainz_id(mut self, mb_id: impl Into<String>) -> Self {
        self.musicbrainz_release_group_id = Some(mb_id.into().trim().to_string());
        self
    }

    pub fn with_cover_url(mut self, url: impl Into<String>) -> Self {
        self.cover_url = Some(url.into().trim().to_string());
        self
    }

    pub fn with_album_artist(mut self, album_artist: impl Into<String>) -> Self {
        let raw = album_artist.into();
        let trimmed = raw.trim();
        self.album_artist = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn add_version(&mut self, version: AlbumVersion) {
        self.versions.push(version);
    }

    pub fn derive_sort_title(title: &str) -> String {
        let trimmed = title.trim();
        let lower = trimmed.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("the ") {
            trimmed[trimmed.len() - rest.len()..].trim().to_string()
        } else if let Some(rest) = lower.strip_prefix("a ") {
            trimmed[trimmed.len() - rest.len()..].trim().to_string()
        } else if let Some(rest) = lower.strip_prefix("an ") {
            trimmed[trimmed.len() - rest.len()..].trim().to_string()
        } else {
            trimmed.to_string()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumVersion {
    pub id: String,
    pub canonical_album_id: String,
    pub provider: ProviderKind,
    pub external_album_id: String,
    pub format: AudioFormat,
    pub edition_label: Option<String>,
}

impl AlbumVersion {
    pub fn new(
        canonical_album_id: impl Into<String>,
        provider: ProviderKind,
        external_album_id: impl Into<String>,
        format: AudioFormat,
    ) -> Result<Self, ValidationError> {
        let cid = canonical_album_id.into();
        let eid = external_album_id.into();
        if cid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "canonical_album_id",
                message: "cannot be empty",
            });
        }
        if eid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "external_album_id",
                message: "cannot be empty",
            });
        }

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            canonical_album_id: cid.trim().to_string(),
            provider,
            external_album_id: eid.trim().to_string(),
            format,
            edition_label: None,
        })
    }

    pub fn with_edition_label(mut self, label: impl Into<String>) -> Self {
        self.edition_label = Some(label.into().trim().to_string());
        self
    }
}

// ============================================================================
// Feature 10: TrackSource
// ============================================================================

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackSource {
    pub id: String,
    pub version_id: String,
    pub provider: ProviderKind,
    pub external_track_id: String,
    pub title: String,
    pub disc_number: u16,
    pub track_number: u16,
    pub duration_ms: u64,
    pub format: AudioFormat,
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_album_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_peak: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_album_peak: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork_cache_key: Option<String>,
    #[serde(default)]
    pub has_lyrics: bool,
}

impl TrackSource {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        version_id: impl Into<String>,
        provider: ProviderKind,
        external_track_id: impl Into<String>,
        title: impl Into<String>,
        disc_number: u16,
        track_number: u16,
        duration_ms: u64,
        format: AudioFormat,
    ) -> Result<Self, ValidationError> {
        let vid = version_id.into();
        let eid = external_track_id.into();
        let t = title.into();

        if vid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "version_id",
                message: "version ID cannot be empty",
            });
        }
        if eid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "external_track_id",
                message: "external track ID cannot be empty",
            });
        }
        if t.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "title",
                message: "track title cannot be empty",
            });
        }
        if disc_number == 0 {
            return Err(ValidationError::InvalidDiscNumber(disc_number));
        }
        if track_number == 0 {
            return Err(ValidationError::InvalidTrackNumber(track_number));
        }
        if duration_ms == 0 {
            return Err(ValidationError::InvalidDuration(duration_ms));
        }

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            version_id: vid.trim().to_string(),
            provider,
            external_track_id: eid.trim().to_string(),
            title: t.trim().to_string(),
            disc_number,
            track_number,
            duration_ms,
            format,
            isrc: None,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
            artist_name: None,
            album_artist: None,
            genre: None,
            composer: None,
            cover_url: None,
            artwork_cache_key: None,
            has_lyrics: false,
        })
    }

    pub fn with_replay_gain(
        mut self,
        track_db: Option<f64>,
        album_db: Option<f64>,
        track_peak: Option<f64>,
        album_peak: Option<f64>,
    ) -> Self {
        self.replay_gain_track_db = track_db;
        self.replay_gain_album_db = album_db;
        self.replay_gain_track_peak = track_peak;
        self.replay_gain_album_peak = album_peak;
        self
    }

    pub fn with_artist_name(mut self, artist_name: impl Into<String>) -> Self {
        let raw = artist_name.into();
        let trimmed = raw.trim();
        self.artist_name = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_album_artist(mut self, album_artist: impl Into<String>) -> Self {
        let raw = album_artist.into();
        let trimmed = raw.trim();
        self.album_artist = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_genre(mut self, genre: impl Into<String>) -> Self {
        let raw = genre.into();
        let trimmed = raw.trim();
        self.genre = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_composer(mut self, composer: impl Into<String>) -> Self {
        let raw = composer.into();
        let trimmed = raw.trim();
        self.composer = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_cover_url(mut self, cover_url: impl Into<String>) -> Self {
        let raw = cover_url.into();
        let trimmed = raw.trim();
        self.cover_url = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_artwork_cache_key(mut self, key: impl Into<String>) -> Self {
        let raw = key.into();
        let trimmed = raw.trim();
        self.artwork_cache_key = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_has_lyrics(mut self, has_lyrics: bool) -> Self {
        self.has_lyrics = has_lyrics;
        self
    }

    pub fn with_isrc(mut self, isrc: impl Into<String>) -> Result<Self, ValidationError> {
        let raw = isrc.into();
        let cleaned: String = raw.chars().filter(|c| *c != '-').collect();
        if cleaned.len() != 12 || !cleaned.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(ValidationError::InvalidIsrc(raw));
        }
        self.isrc = Some(cleaned.to_ascii_uppercase());
        Ok(self)
    }

    pub fn formatted_duration(&self) -> String {
        let total_seconds = self.duration_ms / 1000;
        let hours = total_seconds / 3600;
        let minutes = (total_seconds % 3600) / 60;
        let seconds = total_seconds % 60;

        if hours > 0 {
            format!("{}:{:02}:{:02}", hours, minutes, seconds)
        } else {
            format!("{}:{:02}", minutes, seconds)
        }
    }
}

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
            Self::Lossless => "#A259FF",   // Purple
            Self::Enhanced => "#2ED573",   // Green
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
        if nodes.iter().any(|n| n.quality == SignalQuality::HighQuality) {
            SignalQuality::HighQuality
        } else if nodes.iter().any(|n| n.quality == SignalQuality::Enhanced) {
            SignalQuality::Enhanced
        } else {
            SignalQuality::Lossless
        }
    }
}

// ============================================================================
// Output & Profile Types
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputBackendKind {
    WindowsAsio,
    WindowsWasapiExclusive,
    WindowsWasapiShared,
    MacOsCoreAudioHog,
    MobileDirect,
    NetworkDlna,
    NetworkAirPlay,
}

impl OutputBackendKind {
    pub const ALL: [OutputBackendKind; 7] = [
        Self::WindowsAsio,
        Self::WindowsWasapiExclusive,
        Self::WindowsWasapiShared,
        Self::MacOsCoreAudioHog,
        Self::MobileDirect,
        Self::NetworkDlna,
        Self::NetworkAirPlay,
    ];

    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::WindowsAsio => "windows_asio",
            Self::WindowsWasapiExclusive => "windows_wasapi_exclusive",
            Self::WindowsWasapiShared => "windows_wasapi_shared",
            Self::MacOsCoreAudioHog => "macos_core_audio_hog",
            Self::MobileDirect => "mobile_direct",
            Self::NetworkDlna => "network_dlna",
            Self::NetworkAirPlay => "network_airplay",
        }
    }

    pub const fn is_bit_perfect_capable(&self) -> bool {
        matches!(
            self,
            Self::WindowsAsio
                | Self::WindowsWasapiExclusive
                | Self::MacOsCoreAudioHog
                | Self::MobileDirect
        )
    }

    pub const fn is_exclusive(&self) -> bool {
        matches!(
            self,
            Self::WindowsAsio | Self::WindowsWasapiExclusive | Self::MacOsCoreAudioHog
        )
    }

    pub const fn is_network(&self) -> bool {
        matches!(self, Self::NetworkDlna | Self::NetworkAirPlay)
    }
}

impl fmt::Display for OutputBackendKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for OutputBackendKind {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let normalized = s.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "windows_asio" | "asio" => Ok(Self::WindowsAsio),
            "windows_wasapi_exclusive" | "wasapi_exclusive" => Ok(Self::WindowsWasapiExclusive),
            "windows_wasapi_shared" | "wasapi_shared" | "wasapi" => Ok(Self::WindowsWasapiShared),
            "macos_core_audio_hog" | "core_audio_hog" | "hog" => Ok(Self::MacOsCoreAudioHog),
            "mobile_direct" => Ok(Self::MobileDirect),
            "network_dlna" | "dlna" => Ok(Self::NetworkDlna),
            "network_airplay" | "airplay" => Ok(Self::NetworkAirPlay),
            _ => Err(ValidationError::UnknownOutputBackend(s.to_string())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioZone {
    pub id: String,
    pub name: String,
    pub backend: OutputBackendKind,
    pub exclusive_mode: bool,
    pub dsp_bypass: bool,
}

impl AudioZone {
    pub fn new(
        name: impl Into<String>,
        backend: OutputBackendKind,
    ) -> Result<Self, ValidationError> {
        let n = name.into();
        if n.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "name",
                message: "zone name cannot be empty",
            });
        }
        let exclusive_mode = backend.is_exclusive();
        Ok(Self {
            id: Uuid::new_v4().to_string(),
            name: n.trim().to_string(),
            backend,
            exclusive_mode,
            dsp_bypass: false,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub avatar_color: String,
    pub is_default: bool,
}

impl Profile {
    pub fn new(
        name: impl Into<String>,
        avatar_color: impl Into<String>,
        is_default: bool,
    ) -> Result<Self, ValidationError> {
        let n = name.into();
        let color = avatar_color.into();
        if n.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "name",
                message: "profile name cannot be empty",
            });
        }
        Self::validate_hex_color(&color)?;

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            name: n.trim().to_string(),
            avatar_color: color.trim().to_uppercase(),
            is_default,
        })
    }

    pub fn default_profile() -> Self {
        Self {
            id: "default".to_string(),
            name: "Primary".to_string(),
            avatar_color: "#007AFF".to_string(),
            is_default: true,
        }
    }

    fn validate_hex_color(color: &str) -> Result<(), ValidationError> {
        let trimmed = color.trim();
        if !trimmed.starts_with('#') {
            return Err(ValidationError::InvalidHexColor(color.to_string()));
        }
        let hex_digits = &trimmed[1..];
        if (hex_digits.len() == 6 || hex_digits.len() == 8)
            && hex_digits.chars().all(|c| c.is_ascii_hexdigit())
        {
            Ok(())
        } else {
            Err(ValidationError::InvalidHexColor(color.to_string()))
        }
    }
}

// ============================================================================
// Shared DSP, Device, & Library Detail DTOs
// ============================================================================

fn default_true() -> bool {
    true
}

fn default_q_factor() -> f64 {
    std::f64::consts::FRAC_1_SQRT_2
}

fn default_crossfeed_cutoff_hz() -> f64 {
    700.0
}

fn default_crossfeed_feed_db() -> f64 {
    -6.0
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PeqFilterKind {
    #[default]
    Peaking,
    LowShelf,
    HighShelf,
    LowPass,
    HighPass,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PeqBandConfig {
    #[serde(default)]
    pub filter_type: PeqFilterKind,
    pub frequency_hz: f64,
    pub gain_db: f64,
    #[serde(default = "default_q_factor")]
    pub q_factor: f64,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

impl Default for PeqBandConfig {
    fn default() -> Self {
        Self {
            filter_type: PeqFilterKind::Peaking,
            frequency_hz: 1000.0,
            gain_db: 0.0,
            q_factor: default_q_factor(),
            enabled: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CrossfeedConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_crossfeed_cutoff_hz")]
    pub cutoff_hz: f64,
    #[serde(default = "default_crossfeed_feed_db")]
    pub feed_level_db: f64,
}

impl Default for CrossfeedConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            cutoff_hz: default_crossfeed_cutoff_hz(),
            feed_level_db: default_crossfeed_feed_db(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReplayGainMode {
    #[default]
    Off,
    Track,
    Album,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReplayGainConfig {
    #[serde(default)]
    pub mode: ReplayGainMode,
    #[serde(default)]
    pub preamp_db: f64,
    #[serde(default = "default_true")]
    pub prevent_clipping: bool,
}

impl Default for ReplayGainConfig {
    fn default() -> Self {
        Self {
            mode: ReplayGainMode::Off,
            preamp_db: 0.0,
            prevent_clipping: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct DspPipelineConfig {
    #[serde(default)]
    pub bypass: bool,
    #[serde(default)]
    pub peq_bands: Vec<PeqBandConfig>,
    #[serde(default)]
    pub crossfeed: CrossfeedConfig,
    #[serde(default)]
    pub replay_gain: ReplayGainConfig,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioDeviceDescription {
    pub id: String,
    pub name: String,
    pub backend: OutputBackendKind,
    pub is_default: bool,
    pub is_exclusive: bool,
    pub supported_sample_rates: Vec<u32>,
    pub supported_bit_depths: Vec<u8>,
    pub supports_native_dsd: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumCreditDetail {
    pub artist_id: String,
    pub artist_name: String,
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AlbumVersionDetail {
    pub version: AlbumVersion,
    #[serde(default)]
    pub tracks: Vec<TrackSource>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AlbumDetail {
    pub album: CanonicalAlbum,
    #[serde(default)]
    pub versions: Vec<AlbumVersionDetail>,
    #[serde(default)]
    pub credits: Vec<AlbumCreditDetail>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtistDetail {
    pub id: String,
    pub name: String,
    pub sort_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub biography: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_path: Option<String>,
    #[serde(default)]
    pub albums: Vec<CanonicalAlbum>,
    #[serde(default)]
    pub credits: Vec<AlbumCreditDetail>,
}

// ============================================================================
// Artwork & Rescan Types
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtworkSourceKind {
    Embedded,
    Cover,
    Folder,
    Front,
    User,
    #[default]
    Placeholder,
}

impl ArtworkSourceKind {
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Embedded => "embedded",
            Self::Cover => "cover",
            Self::Folder => "folder",
            Self::Front => "front",
            Self::User => "user",
            Self::Placeholder => "placeholder",
        }
    }
}

impl fmt::Display for ArtworkSourceKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ArtworkResult {
    #[serde(default)]
    pub found: bool,
    #[serde(default)]
    pub cache_path: Option<String>,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub width: Option<u32>,
    #[serde(default)]
    pub height: Option<u32>,
    #[serde(default)]
    pub source_kind: ArtworkSourceKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_key: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PictureType {
    #[default]
    Other,
    FileIcon,
    OtherFileIcon,
    FrontCover,
    BackCover,
    LeafletPage,
    Media,
    LeadArtist,
    Artist,
    Conductor,
    Band,
    Composer,
    Lyricist,
    RecordingLocation,
    DuringRecording,
    DuringPerformance,
    VideoCapture,
    BrightColouredFish,
    Illustration,
    BandLogotype,
    PublisherLogotype,
}

impl PictureType {
    pub const fn from_apic_byte(code: u8) -> Self {
        match code {
            1 => Self::FileIcon,
            2 => Self::OtherFileIcon,
            3 => Self::FrontCover,
            4 => Self::BackCover,
            5 => Self::LeafletPage,
            6 => Self::Media,
            7 => Self::LeadArtist,
            8 => Self::Artist,
            9 => Self::Conductor,
            10 => Self::Band,
            11 => Self::Composer,
            12 => Self::Lyricist,
            13 => Self::RecordingLocation,
            14 => Self::DuringRecording,
            15 => Self::DuringPerformance,
            16 => Self::VideoCapture,
            17 => Self::BrightColouredFish,
            18 => Self::Illustration,
            19 => Self::BandLogotype,
            20 => Self::PublisherLogotype,
            _ => Self::Other,
        }
    }

    pub const fn is_front_cover(&self) -> bool {
        matches!(self, Self::FrontCover)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtractedPicture {
    pub picture_type: PictureType,
    pub mime_type: String,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RescanReport {
    pub scanned: usize,
    pub updated: usize,
    pub unchanged_cached: usize,
    pub pruned: usize,
    #[serde(default)]
    pub errors: Vec<String>,
}

// ============================================================================
// Unit Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_provider_kind_roundtrip() {
        for provider in ProviderKind::ALL {
            let s = provider.to_string();
            let parsed = ProviderKind::from_str(&s).unwrap();
            assert_eq!(provider, parsed);

            // Serde JSON roundtrip
            let json = serde_json::to_string(&provider).unwrap();
            let de: ProviderKind = serde_json::from_str(&json).unwrap();
            assert_eq!(provider, de);
        }

        // Aliases
        assert_eq!(ProviderKind::from_str("webdav").unwrap(), ProviderKind::WebDav);
        assert_eq!(ProviderKind::from_str("web-dav").unwrap(), ProviderKind::WebDav);
        assert_eq!(ProviderKind::from_str("WEB_DAV").unwrap(), ProviderKind::WebDav);
        assert!(ProviderKind::from_str("unknown_prov").is_err());

        // Helper methods
        assert!(ProviderKind::Qobuz.is_streaming());
        assert!(!ProviderKind::Local.is_streaming());
        assert!(ProviderKind::Local.is_local_or_network());
        assert!(ProviderKind::Smb.is_local_or_network());
        assert!(ProviderKind::WebDav.is_local_or_network());
        assert!(!ProviderKind::Tidal.is_local_or_network());
        assert!(ProviderKind::Qobuz.requires_auth());
        assert!(!ProviderKind::Local.requires_auth());
    }

    #[test]
    fn test_qobuz_auth_mode_validation() {
        // Valid token
        let token_mode = QobuzAuthMode::from_token("test_token_123").unwrap();
        assert!(token_mode.is_token());
        assert!(!token_mode.is_credentials());
        assert!(token_mode.validate().is_ok());

        // Empty token rejected
        assert_eq!(
            QobuzAuthMode::from_token("   ").unwrap_err(),
            ValidationError::EmptyQobuzToken
        );

        // Valid credentials
        let cred_mode = QobuzAuthMode::from_credentials("user@example.com", "pass123").unwrap();
        assert!(cred_mode.is_credentials());
        assert!(!cred_mode.is_token());
        assert!(cred_mode.validate().is_ok());

        // Empty credentials rejected
        assert_eq!(
            QobuzAuthMode::from_credentials("", "pass").unwrap_err(),
            ValidationError::EmptyQobuzCredentials
        );
        assert_eq!(
            QobuzAuthMode::from_credentials("user", "  ").unwrap_err(),
            ValidationError::EmptyQobuzCredentials
        );

        // Serialization tag check
        let json = serde_json::to_string(&token_mode).unwrap();
        assert!(json.contains(r#""mode":"token""#));
        let de: QobuzAuthMode = serde_json::from_str(&json).unwrap();
        assert_eq!(token_mode, de);
    }

    #[test]
    fn test_audio_codec_display_and_parse() {
        for codec in AudioCodec::ALL {
            let disp = codec.to_string();
            let parsed = AudioCodec::from_str(&disp).unwrap();
            assert_eq!(codec, parsed);
        }

        // Aliases
        assert_eq!(AudioCodec::from_str("wave").unwrap(), AudioCodec::Wav);
        assert_eq!(AudioCodec::from_str("aif").unwrap(), AudioCodec::Aiff);
        assert_eq!(AudioCodec::from_str("dff").unwrap(), AudioCodec::Dsdiff);
        assert!(AudioCodec::from_str("mp4").is_err());

        // Properties
        assert!(AudioCodec::Flac.is_lossless());
        assert!(AudioCodec::Dsf.is_dsd());
        assert!(AudioCodec::Dsdiff.is_dsd());
        assert!(!AudioCodec::Flac.is_dsd());
        assert!(AudioCodec::Mp3.is_lossy());
        assert!(AudioCodec::Aac.is_lossy());
    }

    #[test]
    fn test_audio_format_validation_and_display() {
        // Valid PCM
        let flac = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
        assert_eq!(flac.to_string(), "FLAC 24-bit/96kHz 2ch");
        assert!(flac.is_hi_res());
        assert!(!flac.is_cd_quality());
        assert!(!flac.is_dsd());

        // CD Quality
        let cd = AudioFormat::cd_quality();
        assert_eq!(cd.to_string(), "FLAC 16-bit/44.1kHz 2ch");
        assert!(cd.is_cd_quality());
        assert!(!cd.is_hi_res());

        // Valid DSD
        let dsd64 = AudioFormat::dsd(AudioCodec::Dsf, 2_822_400, 2).unwrap();
        assert_eq!(dsd64.to_string(), "DSF DSD64 2.82MHz 2ch");
        assert!(dsd64.is_dsd());
        assert!(dsd64.is_hi_res());
        assert_eq!(dsd64.dsd_rate_label(), Some("DSD64"));

        // DSD error cases
        assert!(AudioFormat::pcm(AudioCodec::Dsf, 2_822_400, 1, 2).is_err());
        assert!(AudioFormat::dsd(AudioCodec::Flac, 96000, 2).is_err());
        assert_eq!(
            AudioFormat::new(AudioCodec::Dsf, 2_822_400, 24, 2).unwrap_err(),
            ValidationError::InvalidDsdFormat
        );

        // General validation errors
        assert_eq!(
            AudioFormat::new(AudioCodec::Flac, 0, 16, 2).unwrap_err(),
            ValidationError::InvalidSampleRate(0)
        );
        assert_eq!(
            AudioFormat::new(AudioCodec::Flac, 44100, 16, 0).unwrap_err(),
            ValidationError::InvalidChannels(0)
        );
        assert_eq!(
            AudioFormat::new(AudioCodec::Flac, 44100, 0, 2).unwrap_err(),
            ValidationError::InvalidBitDepth {
                bit_depth: 0,
                codec: AudioCodec::Flac
            }
        );
    }

    #[test]
    fn test_canonical_album_and_versions() {
        let album = CanonicalAlbum::new("The Dark Side of the Moon", "Pink Floyd")
            .unwrap()
            .with_release_year(1973)
            .unwrap()
            .with_musicbrainz_id("mb-rg-1234")
            .with_cover_url("https://example.com/cover.jpg");

        assert_eq!(album.title, "The Dark Side of the Moon");
        assert_eq!(album.sort_title, "Dark Side of the Moon");
        assert_eq!(album.artist_name, "Pink Floyd");
        assert_eq!(album.release_year, Some(1973));
        assert_eq!(album.musicbrainz_release_group_id.as_deref(), Some("mb-rg-1234"));
        assert_eq!(album.cover_url.as_deref(), Some("https://example.com/cover.jpg"));

        // Sort title stripping tests
        assert_eq!(CanonicalAlbum::derive_sort_title("A Hard Day's Night"), "Hard Day's Night");
        assert_eq!(CanonicalAlbum::derive_sort_title("An American in Paris"), "American in Paris");
        assert_eq!(CanonicalAlbum::derive_sort_title("The Beatles"), "Beatles");
        assert_eq!(CanonicalAlbum::derive_sort_title("Kind of Blue"), "Kind of Blue");

        // Release year bounds
        assert!(CanonicalAlbum::new("Title", "Artist").unwrap().with_release_year(999).is_err());
        assert!(CanonicalAlbum::new("Title", "Artist").unwrap().with_release_year(3001).is_err());

        // Empty title/artist rejected
        assert!(CanonicalAlbum::new("  ", "Artist").is_err());
        assert!(CanonicalAlbum::new("Title", "").is_err());

        // Version addition
        let format = AudioFormat::cd_quality();
        let version = AlbumVersion::new(&album.id, ProviderKind::Qobuz, "qobuz-alb-01", format)
            .unwrap()
            .with_edition_label("2011 Remaster");

        assert_eq!(version.canonical_album_id, album.id);
        assert_eq!(version.edition_label.as_deref(), Some("2011 Remaster"));
    }

    #[test]
    fn test_track_source_and_duration() {
        let format = AudioFormat::cd_quality();
        let track = TrackSource::new(
            "ver-1",
            ProviderKind::Local,
            "trk-1",
            "Breathe",
            1,
            2,
            163_000,
            format,
        )
        .unwrap()
        .with_isrc("GB-AYE-73-00002")
        .unwrap();

        assert_eq!(track.title, "Breathe");
        assert_eq!(track.formatted_duration(), "2:43");
        assert_eq!(track.isrc.as_deref(), Some("GBAYE7300002"));

        // Long duration formatting (hours)
        let long_track = TrackSource::new(
            "ver-1",
            ProviderKind::Local,
            "trk-2",
            "Symphony No. 9",
            1,
            1,
            3_945_000,
            AudioFormat::cd_quality(),
        )
        .unwrap();
        assert_eq!(long_track.formatted_duration(), "1:05:45");

        // Validation errors
        assert!(TrackSource::new("v", ProviderKind::Local, "e", "t", 0, 1, 1000, AudioFormat::cd_quality()).is_err());
        assert!(TrackSource::new("v", ProviderKind::Local, "e", "t", 1, 0, 1000, AudioFormat::cd_quality()).is_err());
        assert!(TrackSource::new("v", ProviderKind::Local, "e", "t", 1, 1, 0, AudioFormat::cd_quality()).is_err());
        assert!(track.with_isrc("short").is_err());
    }

    #[test]
    fn test_signal_path_quality_derivation() {
        assert_eq!(SignalQuality::Lossless.hex_color(), "#A259FF");
        assert_eq!(SignalQuality::Enhanced.hex_color(), "#2ED573");
        assert_eq!(SignalQuality::HighQuality.hex_color(), "#FFA502");

        let n1 = SignalPathNode::new("Source", "FLAC 24/96", SignalQuality::Lossless).unwrap();
        let n2 = SignalPathNode::new("DSP", "PEQ Active", SignalQuality::Enhanced).unwrap();
        let n3 = SignalPathNode::new("Output", "WASAPI Shared", SignalQuality::HighQuality).unwrap();

        // All lossless -> Lossless
        let path1 = SignalPath::new(vec![n1.clone()]).unwrap();
        assert_eq!(path1.overall, SignalQuality::Lossless);

        // Lossless + Enhanced -> Enhanced
        let path2 = SignalPath::new(vec![n1.clone(), n2.clone()]).unwrap();
        assert_eq!(path2.overall, SignalQuality::Enhanced);

        // Lossless + Enhanced + HighQuality -> HighQuality
        let path3 = SignalPath::new(vec![n1, n2, n3]).unwrap();
        assert_eq!(path3.overall, SignalQuality::HighQuality);

        // Empty signal path rejected
        assert_eq!(SignalPath::new(vec![]).unwrap_err(), ValidationError::EmptySignalPath);
    }

    #[test]
    fn test_backend_and_profiles() {
        assert!(OutputBackendKind::WindowsAsio.is_bit_perfect_capable());
        assert!(OutputBackendKind::WindowsAsio.is_exclusive());
        assert!(!OutputBackendKind::WindowsWasapiShared.is_exclusive());
        assert!(OutputBackendKind::NetworkAirPlay.is_network());

        assert_eq!(
            OutputBackendKind::from_str("asio").unwrap(),
            OutputBackendKind::WindowsAsio
        );

        let zone = AudioZone::new("Living Room", OutputBackendKind::WindowsAsio).unwrap();
        assert!(zone.exclusive_mode);
        assert_eq!(zone.name, "Living Room");

        // Profile default
        let def_p = Profile::default_profile();
        assert!(def_p.is_default);
        assert_eq!(def_p.avatar_color, "#007AFF");

        // Custom profile
        let p = Profile::new("Alice", "#ff5500", false).unwrap();
        assert_eq!(p.avatar_color, "#FF5500");

        // Invalid hex colors
        assert!(Profile::new("Bob", "red", false).is_err());
        assert!(Profile::new("Bob", "#12345", false).is_err());
        assert!(Profile::new("Bob", "#GG0000", false).is_err());
    }

    #[test]
    fn test_track_source_replay_gain_and_legacy_serde_compat() {
        let track = TrackSource::new(
            "ver-1",
            ProviderKind::Local,
            "trk-rg",
            "Time",
            1,
            3,
            413_000,
            AudioFormat::cd_quality(),
        )
        .unwrap()
        .with_replay_gain(Some(-4.25), Some(-5.10), Some(0.98), Some(0.99));

        assert_eq!(track.replay_gain_track_db, Some(-4.25));
        assert_eq!(track.replay_gain_album_db, Some(-5.10));
        assert_eq!(track.replay_gain_track_peak, Some(0.98));
        assert_eq!(track.replay_gain_album_peak, Some(0.99));

        let json = serde_json::to_string(&track).unwrap();
        let decoded: TrackSource = serde_json::from_str(&json).unwrap();
        assert_eq!(track, decoded);

        // Legacy JSON without ReplayGain keys deserializes cleanly with None defaults
        let legacy_json = r#"{
            "id": "t1",
            "version_id": "v1",
            "provider": "local",
            "external_track_id": "ext1",
            "title": "Legacy Track",
            "disc_number": 1,
            "track_number": 1,
            "duration_ms": 180000,
            "format": {
                "codec": "flac",
                "sample_rate_hz": 44100,
                "bit_depth": 16,
                "channels": 2,
                "is_dsd": false
            },
            "isrc": null
        }"#;
        let legacy: TrackSource = serde_json::from_str(legacy_json).unwrap();
        assert_eq!(legacy.replay_gain_track_db, None);
        assert_eq!(legacy.replay_gain_album_db, None);
        assert_eq!(legacy.replay_gain_track_peak, None);
        assert_eq!(legacy.replay_gain_album_peak, None);
    }

    #[test]
    fn test_dsp_and_detail_dtos_serde_roundtrip() {
        let minimal_band: PeqBandConfig = serde_json::from_str(
            r#"{"frequency_hz": 120.0, "gain_db": 3.5}"#,
        )
        .unwrap();
        assert_eq!(minimal_band.filter_type, PeqFilterKind::Peaking);
        assert!(minimal_band.enabled);
        assert!((minimal_band.q_factor - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-6);

        let cfg = DspPipelineConfig {
            bypass: false,
            peq_bands: vec![PeqBandConfig {
                filter_type: PeqFilterKind::LowShelf,
                frequency_hz: 80.0,
                gain_db: 2.0,
                q_factor: 0.707,
                enabled: true,
            }],
            crossfeed: CrossfeedConfig {
                enabled: true,
                cutoff_hz: 700.0,
                feed_level_db: -6.0,
            },
            replay_gain: ReplayGainConfig {
                mode: ReplayGainMode::Album,
                preamp_db: -1.5,
                prevent_clipping: true,
            },
        };
        let cfg_json = serde_json::to_string(&cfg).unwrap();
        let cfg_back: DspPipelineConfig = serde_json::from_str(&cfg_json).unwrap();
        assert_eq!(cfg, cfg_back);

        let default_cfg: DspPipelineConfig = serde_json::from_str("{}").unwrap();
        assert!(!default_cfg.bypass);
        assert!(default_cfg.peq_bands.is_empty());
        assert!(!default_cfg.crossfeed.enabled);
        assert_eq!(default_cfg.replay_gain.mode, ReplayGainMode::Off);
        assert!(default_cfg.replay_gain.prevent_clipping);

        let device = AudioDeviceDescription {
            id: "wasapi:dev-1".to_string(),
            name: "DAC".to_string(),
            backend: OutputBackendKind::WindowsWasapiShared,
            is_default: true,
            is_exclusive: false,
            supported_sample_rates: vec![44_100, 48_000, 96_000],
            supported_bit_depths: vec![16, 24],
            supports_native_dsd: false,
        };
        let dev_back: AudioDeviceDescription =
            serde_json::from_str(&serde_json::to_string(&device).unwrap()).unwrap();
        assert_eq!(device, dev_back);

        let album = CanonicalAlbum::new("Blue Train", "John Coltrane").unwrap();
        let version = AlbumVersion::new(
            &album.id,
            ProviderKind::Qobuz,
            "qobuz-1",
            AudioFormat::cd_quality(),
        )
        .unwrap();
        let track = TrackSource::new(
            &version.id,
            ProviderKind::Qobuz,
            "q-trk-1",
            "Blue Train",
            1,
            1,
            643_000,
            AudioFormat::cd_quality(),
        )
        .unwrap();
        let credit = AlbumCreditDetail {
            artist_id: "art-1".to_string(),
            artist_name: "John Coltrane".to_string(),
            role: "Tenor Saxophone".to_string(),
            album_id: Some(album.id.clone()),
            album_title: Some(album.title.clone()),
        };
        let detail = AlbumDetail {
            album: album.clone(),
            versions: vec![AlbumVersionDetail {
                version,
                tracks: vec![track],
            }],
            credits: vec![credit.clone()],
        };
        let detail_back: AlbumDetail =
            serde_json::from_str(&serde_json::to_string(&detail).unwrap()).unwrap();
        assert_eq!(detail, detail_back);

        let artist_detail = ArtistDetail {
            id: "art-1".to_string(),
            name: "John Coltrane".to_string(),
            sort_name: "Coltrane, John".to_string(),
            musicbrainz_id: Some("mb-coltrane".to_string()),
            biography: None,
            image_path: None,
            albums: vec![album],
            credits: vec![credit],
        };
        let artist_back: ArtistDetail =
            serde_json::from_str(&serde_json::to_string(&artist_detail).unwrap()).unwrap();
        assert_eq!(artist_detail, artist_back);
    }

    #[test]
    fn test_canonical_album_and_track_source_metadata_compat_and_roundtrip() {
        // Legacy CanonicalAlbum JSON without album_artist
        let legacy_album_json = r#"{
            "id": "alb-legacy",
            "title": "Kind of Blue",
            "sort_title": "Kind of Blue",
            "artist_name": "Miles Davis",
            "release_year": 1959,
            "musicbrainz_release_group_id": null,
            "cover_url": null,
            "versions": []
        }"#;
        let legacy_album: CanonicalAlbum = serde_json::from_str(legacy_album_json).unwrap();
        assert_eq!(legacy_album.album_artist, None);

        let album = CanonicalAlbum::new("Compilation Vol. 1", "Various Artists")
            .unwrap()
            .with_album_artist("  Various Artists  ");
        assert_eq!(album.album_artist.as_deref(), Some("Various Artists"));
        let album_json = serde_json::to_string(&album).unwrap();
        let album_back: CanonicalAlbum = serde_json::from_str(&album_json).unwrap();
        assert_eq!(album, album_back);

        // Blank album_artist builder clears to None
        let cleared_album = album.with_album_artist("   ");
        assert_eq!(cleared_album.album_artist, None);

        // Legacy TrackSource JSON without new metadata/artwork/lyrics fields
        let legacy_track_json = r#"{
            "id": "t-legacy",
            "version_id": "v1",
            "provider": "local",
            "external_track_id": "C:/Music/01.flac",
            "title": "Legacy",
            "disc_number": 1,
            "track_number": 1,
            "duration_ms": 120000,
            "format": {
                "codec": "flac",
                "sample_rate_hz": 44100,
                "bit_depth": 16,
                "channels": 2,
                "is_dsd": false
            },
            "isrc": null
        }"#;
        let legacy_track: TrackSource = serde_json::from_str(legacy_track_json).unwrap();
        assert_eq!(legacy_track.artist_name, None);
        assert_eq!(legacy_track.album_artist, None);
        assert_eq!(legacy_track.genre, None);
        assert_eq!(legacy_track.composer, None);
        assert_eq!(legacy_track.cover_url, None);
        assert_eq!(legacy_track.artwork_cache_key, None);
        assert!(!legacy_track.has_lyrics);

        // Full roundtrip with all new fields populated
        let full_track = TrackSource::new(
            "v1",
            ProviderKind::Local,
            "D:/Music/坂本龍一/01.flac",
            "Merry Christmas Mr. Lawrence",
            1,
            1,
            280_000,
            AudioFormat::pcm(AudioCodec::Flac, 96_000, 24, 2).unwrap(),
        )
        .unwrap()
        .with_artist_name("坂本龍一")
        .with_album_artist("Ryuichi Sakamoto")
        .with_genre("Soundtrack")
        .with_composer("坂本龍一")
        .with_cover_url("/cache/art/123.jpg")
        .with_artwork_cache_key("trk:abc:512")
        .with_has_lyrics(true);

        let full_json = serde_json::to_string(&full_track).unwrap();
        let full_back: TrackSource = serde_json::from_str(&full_json).unwrap();
        assert_eq!(full_track, full_back);
        assert_eq!(full_back.artist_name.as_deref(), Some("坂本龍一"));
        assert_eq!(full_back.album_artist.as_deref(), Some("Ryuichi Sakamoto"));
        assert_eq!(full_back.genre.as_deref(), Some("Soundtrack"));
        assert_eq!(full_back.composer.as_deref(), Some("坂本龍一"));
        assert_eq!(full_back.cover_url.as_deref(), Some("/cache/art/123.jpg"));
        assert_eq!(full_back.artwork_cache_key.as_deref(), Some("trk:abc:512"));
        assert!(full_back.has_lyrics);
    }

    #[test]
    fn test_artwork_and_rescan_types_serde_and_helpers() {
        let kinds = [
            (ArtworkSourceKind::Embedded, "embedded"),
            (ArtworkSourceKind::Cover, "cover"),
            (ArtworkSourceKind::Folder, "folder"),
            (ArtworkSourceKind::Front, "front"),
            (ArtworkSourceKind::User, "user"),
            (ArtworkSourceKind::Placeholder, "placeholder"),
        ];
        for (kind, expected) in kinds {
            assert_eq!(kind.as_str(), expected);
            assert_eq!(kind.to_string(), expected);
            let json = serde_json::to_string(&kind).unwrap();
            assert_eq!(json, format!("\"{expected}\""));
            let back: ArtworkSourceKind = serde_json::from_str(&json).unwrap();
            assert_eq!(back, kind);
        }

        let default_res = ArtworkResult::default();
        assert!(!default_res.found);
        assert_eq!(default_res.source_kind, ArtworkSourceKind::Placeholder);
        let default_val = serde_json::to_value(&default_res).unwrap();
        // Required keys for lumina_artwork_get JSON contract are always serialized
        assert!(default_val.get("found").is_some());
        assert!(default_val.get("cache_path").is_some());
        assert!(default_val.get("mime_type").is_some());
        assert!(default_val.get("width").is_some());
        assert!(default_val.get("height").is_some());
        assert!(default_val.get("source_kind").is_some());
        assert!(default_val.get("error").is_some());

        let populated_res = ArtworkResult {
            found: true,
            cache_path: Some("C:/cache/cover.webp".into()),
            mime_type: Some("image/webp".into()),
            width: Some(512),
            height: Some(512),
            source_kind: ArtworkSourceKind::Embedded,
            cache_key: Some("trk:1:512".into()),
            error: None,
        };
        let res_back: ArtworkResult =
            serde_json::from_str(&serde_json::to_string(&populated_res).unwrap()).unwrap();
        assert_eq!(populated_res, res_back);

        // PictureType APIC mapping
        assert_eq!(PictureType::from_apic_byte(3), PictureType::FrontCover);
        assert!(PictureType::from_apic_byte(3).is_front_cover());
        assert_eq!(PictureType::from_apic_byte(4), PictureType::BackCover);
        assert!(!PictureType::from_apic_byte(4).is_front_cover());
        assert_eq!(PictureType::from_apic_byte(255), PictureType::Other);

        let pic = ExtractedPicture {
            picture_type: PictureType::FrontCover,
            mime_type: "image/jpeg".into(),
            data: vec![0xFF, 0xD8, 0xFF, 0xE0],
        };
        let pic_back: ExtractedPicture =
            serde_json::from_str(&serde_json::to_string(&pic).unwrap()).unwrap();
        assert_eq!(pic, pic_back);

        let report = RescanReport {
            scanned: 100,
            updated: 12,
            unchanged_cached: 85,
            pruned: 3,
            errors: vec!["corrupt header".into()],
        };
        let report_back: RescanReport =
            serde_json::from_str(&serde_json::to_string(&report).unwrap()).unwrap();
        assert_eq!(report, report_back);
        let empty_report: RescanReport =
            serde_json::from_str(r#"{"scanned":1,"updated":0,"unchanged_cached":1,"pruned":0}"#)
                .unwrap();
        assert!(empty_report.errors.is_empty());
    }
}
