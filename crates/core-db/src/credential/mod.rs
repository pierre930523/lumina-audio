//! Sensitive credential isolation abstraction.
//!
//! Enforces isolation of streaming secrets (Qobuz tokens, Tidal OAuth, Deezer ARL, SMB)
//! from SQLite storage into the OS Keyring or memory vault.

pub mod fallback;
#[cfg(feature = "os-keyring")]
pub mod keyring;
pub mod memory;

pub use fallback::FallbackCredentialStore;
#[cfg(feature = "os-keyring")]
pub use keyring::KeyringStore;
pub use memory::MemoryCredentialStore;

use async_trait::async_trait;
use thiserror::Error;

pub const DEFAULT_SERVICE_NAME: &str = "com.lumina.audio";

#[derive(Debug, Error, PartialEq, Eq, Clone)]
pub enum CredentialError {
    #[error("Invalid keyring key or service: {0}")]
    InvalidKey(String),

    #[error("Keyring service unavailable: {0}")]
    Unavailable(String),

    #[error("OS Keyring system error: {0}")]
    System(String),
}

/// Abstract contract for secure credential storage.
#[async_trait]
pub trait CredentialStore: Send + Sync {
    /// Stores a secret for the given service and account key.
    async fn set_secret(&self, service: &str, key: &str, secret: &str) -> Result<(), CredentialError>;

    /// Retrieves a secret. Returns Ok(None) if not found.
    async fn get_secret(&self, service: &str, key: &str) -> Result<Option<String>, CredentialError>;

    /// Deletes a secret idempotently. Returns Ok(()) if nonexistent.
    async fn delete_secret(&self, service: &str, key: &str) -> Result<(), CredentialError>;
}

/// Validates that service and key strings are non-empty.
pub fn validate_service_and_key(service: &str, key: &str) -> Result<(), CredentialError> {
    if service.trim().is_empty() {
        return Err(CredentialError::InvalidKey("Keyring service name cannot be empty".into()));
    }
    if key.trim().is_empty() {
        return Err(CredentialError::InvalidKey("Keyring account name cannot be empty".into()));
    }
    Ok(())
}
