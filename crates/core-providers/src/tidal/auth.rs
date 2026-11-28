use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand::RngCore;
use sha2::{Digest, Sha256};

use super::client::TidalProvider;
use super::models::{
    DEFAULT_TIDAL_AUTH_BASE_URL, DEFAULT_TIDAL_CLIENT_ID, DEFAULT_TIDAL_REDIRECT_URI,
    TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH, TidalOAuthRawResponse, TidalPkceSession,
    TidalTokenResponse,
};
use crate::error::ProviderError;
use crate::http::{HttpRequest, endpoint_url};

pub fn generate_pkce_challenge() -> (String, String, String) {
    let session = start_pkce_with_params(
        DEFAULT_TIDAL_AUTH_BASE_URL,
        DEFAULT_TIDAL_CLIENT_ID,
        DEFAULT_TIDAL_REDIRECT_URI,
        "r_usr w_usr",
    );
    (session.verifier, session.challenge, session.auth_url)
}

fn start_pkce_with_params(
    auth_base_url: &str,
    client_id: &str,
    redirect_uri: &str,
    scopes: &str,
) -> TidalPkceSession {
    let mut random_bytes = [0u8; 48];
    rand::thread_rng().fill_bytes(&mut random_bytes);
    let verifier = URL_SAFE_NO_PAD.encode(random_bytes);

    let mut hasher = Sha256::new();
    hasher.update(verifier.as_bytes());
    let challenge = URL_SAFE_NO_PAD.encode(hasher.finalize());

    let enc_client = url::form_urlencoded::byte_serialize(client_id.as_bytes()).collect::<String>();
    let enc_redirect =
        url::form_urlencoded::byte_serialize(redirect_uri.as_bytes()).collect::<String>();
    let enc_scope = url::form_urlencoded::byte_serialize(scopes.as_bytes()).collect::<String>();

    let base_auth = endpoint_url(auth_base_url, "authorize");
    let auth_url = format!(
        "{base_auth}?response_type=code\
        &client_id={enc_client}\
        &redirect_uri={enc_redirect}\
        &code_challenge={challenge}\
        &code_challenge_method=S256\
        &scope={enc_scope}"
    );

    TidalPkceSession {
        verifier,
        challenge,
        auth_url,
    }
}

pub fn validate_pkce_verifier(verifier: &str) -> bool {
    let len = verifier.len();
    if !(43..=128).contains(&len) {
        return false;
    }
    verifier
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn is_token_expired(issued_at: u64, expires_in: u64, skew_sec: u64) -> bool {
    let now = now_secs();
    now >= (issued_at + expires_in).saturating_sub(skew_sec)
}

pub(super) fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

impl TidalProvider {
    pub async fn start_pkce_login(&self) -> TidalPkceSession {
        let cfg = self.config.read().await.clone();
        let session = start_pkce_with_params(
            &cfg.auth_base_url,
            &cfg.client_id,
            &cfg.redirect_uri,
            &cfg.scopes,
        );
        *self.pending_verifier.write().await = Some(session.verifier.clone());
        session
    }

    pub async fn pending_pkce_verifier(&self) -> Option<String> {
        self.pending_verifier.read().await.clone()
    }

    pub async fn exchange_pkce_code(
        &self,
        code: &str,
        code_verifier: &str,
    ) -> Result<TidalTokenResponse, ProviderError> {
        if code.trim().is_empty() {
            return Err(ProviderError::AuthenticationFailed(
                "Tidal authorization code cannot be empty".to_string(),
            ));
        }
        if !validate_pkce_verifier(code_verifier) {
            return Err(ProviderError::AuthenticationFailed(
                "Invalid Tidal PKCE code_verifier".to_string(),
            ));
        }

        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.auth_base_url, "token");
        let mut pairs: Vec<(&str, &str)> = vec![
            ("grant_type", "authorization_code"),
            ("client_id", &cfg.client_id),
            ("code", code.trim()),
            ("redirect_uri", &cfg.redirect_uri),
            ("code_verifier", code_verifier),
        ];
        if let Some(ref sec) = cfg.client_secret {
            pairs.push(("client_secret", sec));
        }

        let req = HttpRequest::post_form(url, &pairs);
        let resp = self.transport.execute(req).await?;
        if resp.status == 401 || resp.status == 403 || resp.status == 400 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Tidal token exchange failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Tidal token endpoint error (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let raw: TidalOAuthRawResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::AuthenticationFailed(format!("Invalid Tidal token response: {e}"))
        })?;

        let tokens = TidalTokenResponse {
            access_token: raw.access_token,
            refresh_token: raw.refresh_token.unwrap_or_default(),
            token_type: raw.token_type.unwrap_or_else(|| "Bearer".to_string()),
            expires_in: raw.expires_in.unwrap_or(3600),
            user_id: raw
                .user_id
                .or_else(|| raw.user.and_then(|u| u.user_id))
                .unwrap_or(0),
            issued_at: now_secs(),
        };

        self.login_with_tokens(tokens.clone()).await?;
        *self.pending_verifier.write().await = None;
        Ok(tokens)
    }

    pub async fn refresh_tokens(&self) -> Result<TidalTokenResponse, ProviderError> {
        self.refresh_tokens_single_flight(None, true).await
    }

    pub(super) async fn refresh_tokens_single_flight(
        &self,
        stale_access_token: Option<&str>,
        force: bool,
    ) -> Result<TidalTokenResponse, ProviderError> {
        let _guard = self.refresh_lock.lock().await;
        let current = self.load_any_tokens().await?;

        // Double-checked Single-Flight: if another caller already refreshed
        // while we waited on the mutex, reuse the fresh token directly.
        if !is_token_expired(current.issued_at, current.expires_in, 60) {
            if !force || stale_access_token.is_some_and(|stale| stale != current.access_token) {
                return Ok(current);
            }
        }

        if current.refresh_token.trim().is_empty() {
            return Err(ProviderError::Unauthenticated(
                "Tidal refresh token missing".to_string(),
            ));
        }

        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.auth_base_url, "token");
        let mut pairs: Vec<(&str, &str)> = vec![
            ("grant_type", "refresh_token"),
            ("client_id", &cfg.client_id),
            ("refresh_token", &current.refresh_token),
        ];
        if let Some(ref sec) = cfg.client_secret {
            pairs.push(("client_secret", sec));
        }

        let req = HttpRequest::post_form(url, &pairs);
        let resp = self.transport.execute(req).await?;
        if resp.status == 401 || resp.status == 403 || resp.status == 400 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Tidal token refresh failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Tidal token refresh error (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let raw: TidalOAuthRawResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::AuthenticationFailed(format!("Invalid Tidal refresh response: {e}"))
        })?;

        let tokens = TidalTokenResponse {
            access_token: raw.access_token,
            refresh_token: raw
                .refresh_token
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(current.refresh_token),
            token_type: raw.token_type.unwrap_or(current.token_type),
            expires_in: raw.expires_in.unwrap_or(3600),
            user_id: raw
                .user_id
                .or_else(|| raw.user.and_then(|u| u.user_id))
                .unwrap_or(current.user_id),
            issued_at: now_secs(),
        };

        self.login_with_tokens(tokens.clone()).await?;
        Ok(tokens)
    }

    pub async fn login_with_tokens(
        &self,
        mut tokens: TidalTokenResponse,
    ) -> Result<(), ProviderError> {
        if tokens.issued_at == 0 {
            tokens.issued_at = now_secs();
        }
        if let Some(ref store) = self.credential_store {
            let secret = serde_json::to_string(&tokens).map_err(|e| {
                ProviderError::Credential(core_db::credential::CredentialError::System(
                    e.to_string(),
                ))
            })?;
            store
                .set_secret(TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH, &secret)
                .await?;
        }

        let mut w = self.active_tokens.write().await;
        *w = Some(tokens);
        Ok(())
    }

    async fn load_any_tokens(&self) -> Result<TidalTokenResponse, ProviderError> {
        if let Some(tok) = self.active_tokens.read().await.clone() {
            return Ok(tok);
        }

        if let Some(ref store) = self.credential_store {
            if let Some(secret) = store
                .get_secret(TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH)
                .await?
            {
                let tokens: TidalTokenResponse = serde_json::from_str(&secret).map_err(|e| {
                    ProviderError::Credential(core_db::credential::CredentialError::System(
                        e.to_string(),
                    ))
                })?;
                *self.active_tokens.write().await = Some(tokens.clone());
                return Ok(tokens);
            }
        }

        Err(ProviderError::not_authenticated("tidal"))
    }

    pub(super) async fn get_valid_access_token(&self) -> Result<String, ProviderError> {
        let tok = self.load_any_tokens().await?;
        if !is_token_expired(tok.issued_at, tok.expires_in, 60) {
            return Ok(tok.access_token);
        }
        if !tok.refresh_token.trim().is_empty() {
            let refreshed = self.refresh_tokens_single_flight(None, false).await?;
            return Ok(refreshed.access_token);
        }
        Err(ProviderError::Unauthenticated(
            "Tidal access token expired: refresh required".to_string(),
        ))
    }

    pub(crate) async fn valid_access_token(&self) -> Result<String, ProviderError> {
        self.get_valid_access_token().await
    }
}
