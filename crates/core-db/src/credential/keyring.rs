//! OS Keyring implementation using the `keyring` crate.

use super::{CredentialError, CredentialStore, validate_service_and_key};
use async_trait::async_trait;

#[derive(Debug, Default, Clone)]
pub struct KeyringStore;

impl KeyringStore {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl CredentialStore for KeyringStore {
    async fn set_secret(
        &self,
        service: &str,
        key: &str,
        secret: &str,
    ) -> Result<(), CredentialError> {
        validate_service_and_key(service, key)?;
        let service = service.to_string();
        let key = key.to_string();
        let secret = secret.to_string();

        tokio::task::spawn_blocking(move || {
            let entry = keyring::Entry::new(&service, &key)
                .map_err(|e| CredentialError::System(e.to_string()))?;
            entry
                .set_password(&secret)
                .map_err(|e| CredentialError::System(e.to_string()))?;
            Ok(())
        })
        .await
        .map_err(|e| CredentialError::System(format!("Join error: {e}")))?
    }

    async fn get_secret(
        &self,
        service: &str,
        key: &str,
    ) -> Result<Option<String>, CredentialError> {
        validate_service_and_key(service, key)?;
        let service = service.to_string();
        let key = key.to_string();

        tokio::task::spawn_blocking(move || {
            let entry = keyring::Entry::new(&service, &key)
                .map_err(|e| CredentialError::System(e.to_string()))?;
            match entry.get_password() {
                Ok(pwd) => Ok(Some(pwd)),
                Err(keyring::Error::NoEntry) => Ok(None),
                Err(e) => Err(CredentialError::System(e.to_string())),
            }
        })
        .await
        .map_err(|e| CredentialError::System(format!("Join error: {e}")))?
    }

    async fn delete_secret(&self, service: &str, key: &str) -> Result<(), CredentialError> {
        validate_service_and_key(service, key)?;
        let service = service.to_string();
        let key = key.to_string();

        tokio::task::spawn_blocking(move || {
            let entry = keyring::Entry::new(&service, &key)
                .map_err(|e| CredentialError::System(e.to_string()))?;
            match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(e) => Err(CredentialError::System(e.to_string())),
            }
        })
        .await
        .map_err(|e| CredentialError::System(format!("Join error: {e}")))?
    }
}
