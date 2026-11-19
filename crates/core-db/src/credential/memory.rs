//! Thread-safe in-memory credential store.

use super::{validate_service_and_key, CredentialError, CredentialStore};
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// In-memory credential store for test suites, CI runners, and headless sessions.
#[derive(Debug, Default, Clone)]
pub struct MemoryCredentialStore {
    vault: Arc<RwLock<HashMap<String, String>>>,
}

impl MemoryCredentialStore {
    pub fn new() -> Self {
        Self {
            vault: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    fn composite_key(service: &str, key: &str) -> String {
        format!("{}:{}", service, key)
    }
}

#[async_trait]
impl CredentialStore for MemoryCredentialStore {
    async fn set_secret(&self, service: &str, key: &str, secret: &str) -> Result<(), CredentialError> {
        validate_service_and_key(service, key)?;
        let mut vault = self.vault.write().await;
        vault.insert(Self::composite_key(service, key), secret.to_string());
        Ok(())
    }

    async fn get_secret(&self, service: &str, key: &str) -> Result<Option<String>, CredentialError> {
        validate_service_and_key(service, key)?;
        let vault = self.vault.read().await;
        Ok(vault.get(&Self::composite_key(service, key)).cloned())
    }

    async fn delete_secret(&self, service: &str, key: &str) -> Result<(), CredentialError> {
        validate_service_and_key(service, key)?;
        let mut vault = self.vault.write().await;
        vault.remove(&Self::composite_key(service, key));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_memory_store_crud() {
        let store = MemoryCredentialStore::new();
        store
            .set_secret("com.lumina.audio", "qobuz_token", "secret123")
            .await
            .unwrap();

        let val = store
            .get_secret("com.lumina.audio", "qobuz_token")
            .await
            .unwrap();
        assert_eq!(val.as_deref(), Some("secret123"));

        let non_existent = store.get_secret("com.lumina.audio", "other").await.unwrap();
        assert_eq!(non_existent, None);

        store
            .delete_secret("com.lumina.audio", "qobuz_token")
            .await
            .unwrap();
        assert_eq!(
            store
                .get_secret("com.lumina.audio", "qobuz_token")
                .await
                .unwrap(),
            None
        );

        // Idempotent delete
        store
            .delete_secret("com.lumina.audio", "qobuz_token")
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn test_empty_keys_rejected() {
        let store = MemoryCredentialStore::new();
        assert!(store.set_secret("", "key", "v").await.is_err());
        assert!(store.set_secret("srv", "", "v").await.is_err());
        assert!(store.get_secret("  ", "key").await.is_err());
    }
}
