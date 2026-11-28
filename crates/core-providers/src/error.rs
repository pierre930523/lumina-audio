use std::time::Duration;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("Unauthenticated: {0}")]
    Unauthenticated(String),

    #[error("Authentication failed: {0}")]
    AuthenticationFailed(String),

    #[error("Authentication expired: {0}")]
    AuthExpired(String),

    #[error("Track not found: {0}")]
    TrackNotFound(String),

    #[error("Album not found: {0}")]
    AlbumNotFound(String),

    #[error("Stream resolution failed: {0}")]
    StreamResolutionFailed(String),

    #[error("Unsupported format: {0}")]
    UnsupportedFormat(String),

    #[error("Scan error: {0}")]
    ScanError(String),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Network error: {0}")]
    Network(String),

    #[error("Rate limited: {message}")]
    RateLimited {
        message: String,
        retry_after: Option<Duration>,
    },

    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    #[error("Credential error: {0}")]
    Credential(#[from] core_db::credential::CredentialError),

    #[error("Validation error: {0}")]
    Validation(#[from] core_types::ValidationError),

    #[error("DRM restricted: {0}")]
    DrmRestricted(String),

    #[error("Region restricted: {0}")]
    RegionRestricted(String),

    #[error("Region blocked: {0}")]
    RegionBlocked(String),

    #[error("Track unavailable: {0}")]
    TrackUnavailable(String),

    #[error("Required binary '{binary}' not found (searched: {})", searched.join(", "))]
    BinaryMissing {
        binary: String,
        searched: Vec<String>,
    },

    #[error("Process '{binary}' failed (exit={exit_code:?}): {stderr}")]
    ProcessFailed {
        binary: String,
        exit_code: Option<i32>,
        stderr: String,
    },

    #[error("Operation cancelled")]
    Cancelled,

    #[error("Other error: {0}")]
    Other(String),
}

impl ProviderError {
    pub fn not_authenticated(provider: &str) -> Self {
        Self::Unauthenticated(format!("Provider '{provider}' requires login"))
    }

    pub fn track_not_found(provider: &str, track_id: &str) -> Self {
        Self::TrackNotFound(format!(
            "Track '{track_id}' not found on provider '{provider}'"
        ))
    }

    pub fn album_not_found(provider: &str, album_id: &str) -> Self {
        Self::AlbumNotFound(format!(
            "Album '{album_id}' not found on provider '{provider}'"
        ))
    }

    pub fn rate_limited(message: impl Into<String>, retry_after: Option<Duration>) -> Self {
        Self::RateLimited {
            message: message.into(),
            retry_after,
        }
    }

    pub fn is_retryable(&self) -> bool {
        matches!(self, Self::RateLimited { .. } | Self::Network(_))
    }

    pub fn retry_after(&self) -> Option<Duration> {
        match self {
            Self::RateLimited { retry_after, .. } => *retry_after,
            _ => None,
        }
    }

    pub fn is_auth_expired(&self) -> bool {
        matches!(self, Self::AuthExpired(_) | Self::Unauthenticated(_))
    }

    pub fn is_cancelled(&self) -> bool {
        matches!(self, Self::Cancelled)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifiers_and_helpers_work() {
        let rl = ProviderError::rate_limited("too many requests", Some(Duration::from_secs(5)));
        assert!(rl.is_retryable());
        assert_eq!(rl.retry_after(), Some(Duration::from_secs(5)));
        assert!(!rl.is_auth_expired());
        assert!(!rl.is_cancelled());
        assert_eq!(rl.to_string(), "Rate limited: too many requests");

        let net = ProviderError::Network("timeout".into());
        assert!(net.is_retryable());
        assert_eq!(net.retry_after(), None);

        let exp = ProviderError::AuthExpired("jwt expired".into());
        assert!(exp.is_auth_expired());
        assert!(!exp.is_retryable());

        let unauth = ProviderError::not_authenticated("tidal");
        assert!(unauth.is_auth_expired());

        let cancelled = ProviderError::Cancelled;
        assert!(cancelled.is_cancelled());
        assert!(!cancelled.is_retryable());

        let missing = ProviderError::BinaryMissing {
            binary: "yt-dlp".into(),
            searched: vec!["/usr/bin".into(), "vendor/bin".into()],
        };
        assert!(missing.to_string().contains("yt-dlp"));
        assert!(missing.to_string().contains("vendor/bin"));

        let proc_err = ProviderError::ProcessFailed {
            binary: "yt-dlp".into(),
            exit_code: Some(1),
            stderr: "boom".into(),
        };
        assert!(proc_err.to_string().contains("boom"));
    }
}
