use std::sync::Arc;

use core_db::credential::{CredentialStore, DEFAULT_SERVICE_NAME};
use core_types::QobuzAuthMode;
use tokio::sync::RwLock;

use super::config::{QobuzConfig, QobuzUserSession, format_ids};
use super::models::QobuzLoginResponse;
use super::transport::{HttpRequest, HttpResponse, HttpTransport, ReqwestHttpTransport};
use crate::error::ProviderError;
use crate::http::endpoint_url;

pub const QOBUZ_CREDENTIAL_SERVICE: &str = "com.lumina.audio.qobuz";
pub const QOBUZ_KEYRING_TOKEN_KEY: &str = "qobuz:user_auth_token";
pub const QOBUZ_KEYRING_APP_ID_KEY: &str = "qobuz:app_id";
pub const QOBUZ_KEYRING_APP_SECRET_KEY: &str = "qobuz:app_secret";
pub const QOBUZ_FALLBACK_TOKEN_KEY: &str = "lumina_qobuz:auth_token";

pub struct QobuzProvider {
    pub(super) config: RwLock<QobuzConfig>,
    pub(super) session: RwLock<Option<QobuzUserSession>>,
    pub(super) transport: Arc<dyn HttpTransport>,
    credential_store: Option<Arc<dyn CredentialStore>>,
}

impl QobuzProvider {
    pub fn new(
        config: QobuzConfig,
        transport: Arc<dyn HttpTransport>,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self {
            config: RwLock::new(config),
            session: RwLock::new(None),
            transport,
            credential_store,
        }
    }

    pub fn live(config: QobuzConfig, credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::new(
            config,
            Arc::new(ReqwestHttpTransport::new()),
            credential_store,
        )
    }

    pub async fn authenticate(&self) -> Result<QobuzUserSession, ProviderError> {
        let (auth_mode, base_url, app_id) = {
            let cfg = self.config.read().await;
            (
                cfg.auth.clone(),
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
            )
        };

        match auth_mode {
            QobuzAuthMode::Token {
                user_auth_token, ..
            } => {
                let session = self
                    .verify_token(&base_url, &app_id, &user_auth_token)
                    .await?;
                *self.session.write().await = Some(session.clone());
                self.persist_token(&user_auth_token).await;
                Ok(session)
            }
            QobuzAuthMode::Credentials {
                username, password, ..
            } => {
                let session = self
                    .login_with_credentials(&base_url, &app_id, &username, &password)
                    .await?;
                *self.session.write().await = Some(session.clone());
                self.persist_token(&session.user_auth_token).await;
                Ok(session)
            }
        }
    }

    async fn persist_token(&self, token: &str) {
        if let Some(ref store) = self.credential_store {
            let _ = store
                .set_secret(DEFAULT_SERVICE_NAME, QOBUZ_KEYRING_TOKEN_KEY, token)
                .await;
            let _ = store
                .set_secret(DEFAULT_SERVICE_NAME, QOBUZ_FALLBACK_TOKEN_KEY, token)
                .await;
            let _ = store
                .set_secret(QOBUZ_CREDENTIAL_SERVICE, QOBUZ_KEYRING_TOKEN_KEY, token)
                .await;
        }
    }

    pub(super) async fn load_stored_token(&self) -> Option<String> {
        let store = self.credential_store.as_ref()?;
        for (svc, key) in [
            (DEFAULT_SERVICE_NAME, QOBUZ_KEYRING_TOKEN_KEY),
            (DEFAULT_SERVICE_NAME, QOBUZ_FALLBACK_TOKEN_KEY),
            (QOBUZ_CREDENTIAL_SERVICE, QOBUZ_KEYRING_TOKEN_KEY),
        ] {
            if let Ok(Some(tok)) = store.get_secret(svc, key).await {
                if !tok.trim().is_empty() {
                    return Some(tok);
                }
            }
        }
        None
    }

    pub(super) async fn ensure_session(&self) -> Result<QobuzUserSession, ProviderError> {
        if let Some(sess) = self.session.read().await.clone() {
            return Ok(sess);
        }

        let token_candidate = {
            let cfg = self.config.read().await;
            match &cfg.auth {
                QobuzAuthMode::Token {
                    user_auth_token, ..
                } if !user_auth_token.trim().is_empty() => Some(user_auth_token.clone()),
                _ => None,
            }
        };

        let token = if let Some(t) = token_candidate {
            Some(t)
        } else {
            self.load_stored_token().await
        };

        let Some(tok) = token else {
            return Err(ProviderError::not_authenticated("qobuz"));
        };

        let default_q = self
            .config
            .read()
            .await
            .default_format_id
            .unwrap_or(format_ids::FLAC_24_192);
        let session = QobuzUserSession {
            user_id: 0,
            login: "Qobuz Subscriber".to_string(),
            user_auth_token: tok,
            label: None,
            hires: default_q >= format_ids::FLAC_24_96,
            lossless: true,
            max_streaming_quality: default_q,
        };
        *self.session.write().await = Some(session.clone());
        Ok(session)
    }

    pub(crate) fn transport(&self) -> &Arc<dyn HttpTransport> {
        &self.transport
    }

    pub(crate) async fn config_snapshot(&self) -> QobuzConfig {
        self.config.read().await.clone()
    }

    pub(crate) async fn session_token(&self) -> Option<String> {
        if let Some(sess) = self.session.read().await.as_ref() {
            return Some(sess.user_auth_token.clone());
        }
        let cfg = self.config.read().await;
        match &cfg.auth {
            QobuzAuthMode::Token {
                user_auth_token, ..
            } if !user_auth_token.trim().is_empty() => Some(user_auth_token.clone()),
            _ => None,
        }
    }

    pub(crate) async fn clear_session(&self) {
        *self.session.write().await = None;
    }

    pub(super) fn map_http_response(
        &self,
        resp: &HttpResponse,
        context: &str,
    ) -> Result<(), ProviderError> {
        if resp.status == 429 {
            let retry_after = resp
                .header("retry-after")
                .and_then(crate::resilience::parse_retry_after);
            return Err(ProviderError::rate_limited(
                format!("Qobuz {context} rate limited (HTTP 429)"),
                retry_after,
            ));
        }
        self.map_http_status(resp.status, context, &resp.body)
    }

    pub(super) fn map_http_status(
        &self,
        status: u16,
        context: &str,
        body: &str,
    ) -> Result<(), ProviderError> {
        match status {
            200..=299 => Ok(()),
            401 => Err(ProviderError::AuthenticationFailed(format!(
                "Qobuz {context} unauthorized (HTTP 401)"
            ))),
            403 => Err(ProviderError::StreamResolutionFailed(format!(
                "Qobuz {context} forbidden (HTTP 403): {body}"
            ))),
            404 => Err(ProviderError::AlbumNotFound(format!(
                "Qobuz {context} not found (HTTP 404)"
            ))),
            429 => Err(ProviderError::rate_limited(
                format!("Qobuz {context} rate limited (HTTP 429)"),
                None,
            )),
            _ => Err(ProviderError::Network(format!(
                "Qobuz {context} failed with HTTP {status}: {body}"
            ))),
        }
    }

    async fn verify_token(
        &self,
        base_url: &str,
        app_id: &str,
        token: &str,
    ) -> Result<QobuzUserSession, ProviderError> {
        let url = endpoint_url(base_url, "user/get");
        let req = HttpRequest {
            method: "GET".to_string(),
            url,
            headers: vec![
                ("X-App-Id".to_string(), app_id.to_string()),
                ("X-User-Auth-Token".to_string(), token.to_string()),
            ],
            query_params: Vec::new(),
            body: None,
        };

        let resp = self.transport.execute(req).await?;
        self.map_http_status(resp.status, "user/get", &resp.body)?;

        let parsed: QobuzLoginResponse = serde_json::from_str(&resp.body)
            .map_err(|e| ProviderError::Network(format!("Failed to parse Qobuz user/get: {e}")))?;

        if parsed.status.as_deref() == Some("error") {
            return Err(ProviderError::AuthenticationFailed(
                parsed
                    .message
                    .unwrap_or_else(|| "Qobuz authentication error".to_string()),
            ));
        }

        let user = parsed.user.ok_or_else(|| {
            ProviderError::AuthenticationFailed("Missing user object in response".to_string())
        })?;
        let user_id = match user.id {
            Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0),
            Some(serde_json::Value::String(s)) => s.parse::<u64>().unwrap_or(0),
            _ => 0,
        };

        let params = user.credential.and_then(|c| c.parameters);
        Ok(QobuzUserSession {
            user_id,
            login: "Qobuz Subscriber".to_string(),
            user_auth_token: token.to_string(),
            label: None,
            hires: params.as_ref().and_then(|p| p.hires).unwrap_or(false),
            lossless: true,
            max_streaming_quality: params
                .as_ref()
                .and_then(|p| p.max_streaming_quality)
                .unwrap_or(format_ids::FLAC_16_44),
        })
    }

    async fn login_with_credentials(
        &self,
        base_url: &str,
        app_id: &str,
        username: &str,
        password: &str,
    ) -> Result<QobuzUserSession, ProviderError> {
        let url = endpoint_url(base_url, "user/login");
        let req = HttpRequest {
            method: "GET".to_string(),
            url,
            headers: vec![("X-App-Id".to_string(), app_id.to_string())],
            query_params: vec![
                ("username".to_string(), username.to_string()),
                ("password".to_string(), password.to_string()),
            ],
            body: None,
        };

        let resp = self.transport.execute(req).await?;
        self.map_http_status(resp.status, "user/login", &resp.body)?;

        let parsed: QobuzLoginResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Qobuz user/login: {e}"))
        })?;

        if parsed.status.as_deref() == Some("error") {
            return Err(ProviderError::AuthenticationFailed(
                parsed
                    .message
                    .unwrap_or_else(|| "Invalid username or password".to_string()),
            ));
        }

        let user = parsed.user.ok_or_else(|| {
            ProviderError::AuthenticationFailed("Missing user object".to_string())
        })?;
        let token = user.user_auth_token.ok_or_else(|| {
            ProviderError::AuthenticationFailed(
                "Missing user_auth_token in login response".to_string(),
            )
        })?;

        let user_id = match user.id {
            Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0),
            Some(serde_json::Value::String(s)) => s.parse::<u64>().unwrap_or(0),
            _ => 0,
        };

        let params = user.credential.and_then(|c| c.parameters);
        Ok(QobuzUserSession {
            user_id,
            login: username.to_string(),
            user_auth_token: token,
            label: None,
            hires: params.as_ref().and_then(|p| p.hires).unwrap_or(false),
            lossless: true,
            max_streaming_quality: params
                .as_ref()
                .and_then(|p| p.max_streaming_quality)
                .unwrap_or(format_ids::FLAC_16_44),
        })
    }
}
