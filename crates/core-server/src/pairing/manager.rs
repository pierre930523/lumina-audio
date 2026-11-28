use crate::error::ServerError;
use crate::pairing::pin::{ActivePin, generate_six_digit_pin, validate_pin_format};
use crate::pairing::rate_limiter::PinRateLimiter;
use core_db::{DbError, PairedClient, PairingRepository, SqlitePool};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::{Mutex, RwLock};

#[derive(Debug, Clone)]
pub struct PinPairingManager {
    ttl_secs: f64,
    active_pins: Arc<RwLock<HashMap<String, ActivePin>>>,
    token_hashes: Arc<RwLock<HashSet<String>>>,
    rate_limiter: Arc<Mutex<PinRateLimiter>>,
    db_pool: Option<SqlitePool>,
}

impl Default for PinPairingManager {
    fn default() -> Self {
        Self::new(60.0, 5, None)
    }
}

impl PinPairingManager {
    pub fn new(ttl_secs: f64, max_failures: usize, db_pool: Option<SqlitePool>) -> Self {
        Self {
            ttl_secs,
            active_pins: Arc::new(RwLock::new(HashMap::new())),
            token_hashes: Arc::new(RwLock::new(HashSet::new())),
            rate_limiter: Arc::new(Mutex::new(PinRateLimiter::new(max_failures))),
            db_pool,
        }
    }

    /// Sets or updates the SQLite pool for persisting paired clients.
    pub fn set_db_pool(&mut self, pool: SqlitePool) {
        self.db_pool = Some(pool);
    }

    /// Generates a new 6-digit PIN and stores it with expiration.
    pub async fn generate_pin(&self, device_name: &str) -> String {
        let pin = generate_six_digit_pin();
        let active = ActivePin::new(pin.clone(), device_name.to_string(), self.ttl_secs);
        let mut pins = self.active_pins.write().await;
        pins.insert(pin.clone(), active);
        pin
    }

    /// Attempts to pair a client with a provided PIN.
    /// Enforces:
    /// 1. IP rate-limiting lockout check
    /// 2. PIN format validation
    /// 3. Active PIN lookup and immediate consumption (replay prevention)
    /// 4. TTL expiration check (60s)
    /// 5. Bearer token creation, SHA-256 hash generation, and SQLite insertion
    pub async fn attempt_pairing(
        &self,
        client_ip: &str,
        client_id: &str,
        device_name: &str,
        platform: &str,
        pin: &str,
    ) -> Result<String, ServerError> {
        // 1. Check IP lockout
        {
            let limiter = self.rate_limiter.lock().await;
            if limiter.is_locked(client_ip) {
                return Err(ServerError::IpLockedOut);
            }
        }

        // 2. Validate PIN format
        if !validate_pin_format(pin) {
            let mut limiter = self.rate_limiter.lock().await;
            limiter.record_failure(client_ip);
            return Err(ServerError::InvalidPinFormat);
        }

        // 3. Consume PIN immediately to prevent replay
        let active_pin = {
            let mut pins = self.active_pins.write().await;
            pins.remove(pin)
        };

        let active_pin = match active_pin {
            Some(p) => p,
            None => {
                let mut limiter = self.rate_limiter.lock().await;
                limiter.record_failure(client_ip);
                return Err(ServerError::PinNotFoundOrExpired);
            }
        };

        // 4. Check TTL expiration
        let now = Instant::now();
        if !active_pin.is_valid(now) {
            let mut limiter = self.rate_limiter.lock().await;
            limiter.record_failure(client_ip);
            return Err(ServerError::PinNotFoundOrExpired);
        }

        // 5. Successful PIN match! Reset rate limiter for IP
        {
            let mut limiter = self.rate_limiter.lock().await;
            limiter.record_success(client_ip);
        }

        // 6. Generate Bearer token & SHA-256 hash
        let token = format!("lum_sec_{}", hex::encode(rand::random::<[u8; 24]>()));
        let token_hash = hex::encode(Sha256::digest(token.as_bytes()));

        // 7. Store in in-memory token_hashes cache
        {
            let mut hashes = self.token_hashes.write().await;
            hashes.insert(token_hash.clone());
        }

        // 8. Persist to SQLite if DB pool is configured
        if let Some(pool) = &self.db_pool {
            let now_str = chrono::Utc::now().to_rfc3339();
            let client = PairedClient {
                id: client_id.to_string(),
                device_name: if device_name.is_empty() {
                    active_pin.device_name.clone()
                } else {
                    device_name.to_string()
                },
                platform: platform.to_string(),
                token_hash,
                created_at: now_str.clone(),
                last_seen_at: now_str,
            };
            let _ = PairingRepository::insert_paired_client(pool, &client).await;
        }

        Ok(token)
    }

    /// Checks if a SHA-256 token hash is authorized.
    pub async fn is_token_hash_valid(&self, token_hash: &str) -> bool {
        let hashes = self.token_hashes.read().await;
        hashes.contains(token_hash)
    }

    /// Validates a raw Bearer token directly by hashing it.
    pub async fn is_token_valid(&self, token: &str) -> bool {
        let token_hash = hex::encode(Sha256::digest(token.as_bytes()));
        self.is_token_hash_valid(&token_hash).await
    }

    /// Explicitly registers an authorized token (e.g. for testing or pre-paired tokens).
    pub async fn register_token(&self, token: &str) {
        let token_hash = hex::encode(Sha256::digest(token.as_bytes()));
        let mut hashes = self.token_hashes.write().await;
        hashes.insert(token_hash);
    }

    /// Explicitly registers an authorized token hash.
    pub async fn register_token_hash(&self, token_hash: &str) {
        let mut hashes = self.token_hashes.write().await;
        hashes.insert(token_hash.to_string());
    }

    /// Loads persisted token hashes from the SQLite database.
    pub async fn load_tokens_from_db(&self) -> Result<usize, DbError> {
        if let Some(pool) = &self.db_pool {
            let rows = PairingRepository::list_paired_token_hashes(pool).await?;
            let count = rows.len();
            let mut hashes = self.token_hashes.write().await;
            for h in rows {
                hashes.insert(h);
            }
            Ok(count)
        } else {
            Ok(0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_pairing_manager_flow() {
        let manager = PinPairingManager::new(60.0, 5, None);
        let pin = manager.generate_pin("Test-Device").await;
        assert_eq!(pin.len(), 6);

        // Attempt pairing with valid PIN
        let token = manager
            .attempt_pairing("127.0.0.1", "client-1", "My Phone", "iOS", &pin)
            .await
            .expect("Pairing should succeed");
        assert!(token.starts_with("lum_sec_"));

        // Replay attempt fails immediately
        let replay = manager
            .attempt_pairing("127.0.0.1", "client-1", "My Phone", "iOS", &pin)
            .await;
        assert!(matches!(replay, Err(ServerError::PinNotFoundOrExpired)));

        // Token is valid
        assert!(manager.is_token_valid(&token).await);
        assert!(!manager.is_token_valid("invalid_token").await);
    }

    #[tokio::test]
    async fn test_rate_limiting_lockout() {
        let manager = PinPairingManager::new(60.0, 5, None);
        let client_ip = "10.0.0.99";

        for _ in 0..5 {
            let res = manager
                .attempt_pairing(client_ip, "c", "d", "p", "999999")
                .await;
            assert!(res.is_err());
        }

        // 6th attempt is locked out
        let res = manager
            .attempt_pairing(client_ip, "c", "d", "p", "123456")
            .await;
        assert!(matches!(res, Err(ServerError::IpLockedOut)));
    }
}
