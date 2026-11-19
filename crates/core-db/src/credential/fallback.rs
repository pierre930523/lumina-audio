//! Graceful fallback credential store.

use super::{CredentialError, CredentialStore, MemoryCredentialStore};
use async_trait::async_trait;
use std::sync::Arc;
use tracing::warn;

/// Wraps a primary CredentialStore (e.g. KeyringStore) with an in-memory fallback.
/// If the primary store returns an OS / System error (e.g. daemon unavailable),
/// operations automatically fall back to memory.
#[derive(Clone)]
pub struct FallbackCredentialStore {
    primary: Arc<dyn CredentialStore>,
    fallback: Arc<MemoryCredentialStore>,
}

impl FallbackCredentialStore {
    pub fn new(primary: Arc<dyn CredentialStore>) -> Self {
        Self {
            primary,
            fallback: Arc::new(MemoryCredentialStore::new()),
        }
    }
}

#[async_trait]
impl CredentialStore for FallbackCredentialStore {
    async fn set_secret(&self, service: &str, key: &str, secret: &str) -> Result<(), CredentialError> {
        match self.primary.set_secret(service, key, secret).await {
            Ok(()) => Ok(()),
            Err(CredentialError::System(e)) | Err(CredentialError::Unavailable(e)) => {
                warn!("Primary credential store unavailable ({e}); falling back to in-memory store");
                self.fallback.set_secret(service, key, secret).await
            }
            Err(e) => Err(e),
        }
    }

    async fn get_secret(&self, service: &str, key: &str) -> Result<Option<String>, CredentialError> {
        match self.primary.get_secret(service, key).await {
            Ok(Some(secret)) => Ok(Some(secret)),
            Ok(None) => self.fallback.get_secret(service, key).await,
            Err(CredentialError::System(e)) | Err(CredentialError::Unavailable(e)) => {
                warn!("Primary credential store unavailable ({e}); reading from in-memory fallback");
                self.fallback.get_secret(service, key).await
            }
            Err(e) => Err(e),
        }
    }

    async fn delete_secret(&self, service: &str, key: &str) -> Result<(), CredentialError> {
        let _ = self.primary.delete_secret(service, key).await;
        self.fallback.delete_secret(service, key).await
    }
}
