use thiserror::Error;

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("Unauthenticated: {0}")]
    Unauthenticated(String),

    #[error("Authentication failed: {0}")]
    AuthenticationFailed(String),

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

    #[error("Rate limited: {0}")]
    RateLimited(String),

    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    #[error("Credential error: {0}")]
    Credential(#[from] core_db::credential::CredentialError),

    #[error("Validation error: {0}")]
    Validation(#[from] core_types::ValidationError),

    #[error("DRM restricted: {0}")]
    DrmRestricted(String),

    #[error("Other error: {0}")]
    Other(String),
}

impl ProviderError {
    pub fn not_authenticated(provider: &str) -> Self {
        Self::Unauthenticated(format!("Provider '{provider}' requires login"))
    }

    pub fn track_not_found(provider: &str, track_id: &str) -> Self {
        Self::TrackNotFound(format!("Track '{track_id}' not found on provider '{provider}'"))
    }

    pub fn album_not_found(provider: &str, album_id: &str) -> Self {
        Self::AlbumNotFound(format!("Album '{album_id}' not found on provider '{provider}'"))
    }
}
