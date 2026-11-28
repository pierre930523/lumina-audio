use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

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
    #[serde(rename = "apple_music")]
    AppleMusic,
    #[serde(rename = "youtube_music")]
    YouTubeMusic,
}

impl ProviderKind {
    pub const ALL: [ProviderKind; 8] = [
        ProviderKind::Local,
        ProviderKind::Smb,
        ProviderKind::WebDav,
        ProviderKind::Qobuz,
        ProviderKind::Tidal,
        ProviderKind::Deezer,
        ProviderKind::AppleMusic,
        ProviderKind::YouTubeMusic,
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
            Self::AppleMusic => "apple_music",
            Self::YouTubeMusic => "youtube_music",
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
            Self::AppleMusic => "Apple Music",
            Self::YouTubeMusic => "YouTube Music",
        }
    }

    pub const fn is_streaming(&self) -> bool {
        matches!(
            self,
            Self::Qobuz | Self::Tidal | Self::Deezer | Self::AppleMusic | Self::YouTubeMusic
        )
    }

    pub const fn is_local_or_network(&self) -> bool {
        matches!(self, Self::Local | Self::Smb | Self::WebDav)
    }

    pub const fn requires_auth(&self) -> bool {
        matches!(
            self,
            Self::Qobuz | Self::Tidal | Self::Deezer | Self::AppleMusic | Self::Smb | Self::WebDav
        )
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
            "apple_music" | "applemusic" | "apple-music" => Ok(Self::AppleMusic),
            "youtube_music" | "youtubemusic" | "youtube-music" | "ytm" => Ok(Self::YouTubeMusic),
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
            Self::Token {
                user_auth_token, ..
            } => {
                if user_auth_token.trim().is_empty() {
                    return Err(ValidationError::EmptyQobuzToken);
                }
            }
            Self::Credentials {
                username, password, ..
            } => {
                if username.trim().is_empty() || password.trim().is_empty() {
                    return Err(ValidationError::EmptyQobuzCredentials);
                }
            }
        }
        Ok(())
    }
}
