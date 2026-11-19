use core_types::QobuzAuthMode;
use serde::{Deserialize, Serialize};

pub const DEFAULT_QOBUZ_BASE_URL: &str = "https://www.qobuz.com/api.json/0.2/";
pub const DEFAULT_QOBUZ_APP_ID: &str = "8912301";
pub const DEFAULT_QOBUZ_APP_SECRET: &str = "";

pub mod format_ids {
    pub const MP3_320: u32 = 5;
    pub const FLAC_16_44: u32 = 6;
    pub const FLAC_24_96: u32 = 7;
    pub const FLAC_24_192: u32 = 27;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzConfig {
    pub auth: QobuzAuthMode,
    #[serde(default = "default_base_url")]
    pub base_url: String,
    #[serde(default)]
    pub default_format_id: Option<u32>,
}

fn default_base_url() -> String {
    DEFAULT_QOBUZ_BASE_URL.to_string()
}

impl QobuzConfig {
    pub fn from_token(token: impl Into<String>) -> Result<Self, core_types::ValidationError> {
        let auth = QobuzAuthMode::from_token(token)?;
        Ok(Self {
            auth,
            base_url: default_base_url(),
            default_format_id: None,
        })
    }

    pub fn from_token_with_app(
        token: impl Into<String>,
        app_id: Option<String>,
        app_secret: Option<String>,
    ) -> Result<Self, core_types::ValidationError> {
        let auth = QobuzAuthMode::token(token, app_id, app_secret)?;
        Ok(Self {
            auth,
            base_url: default_base_url(),
            default_format_id: None,
        })
    }

    pub fn from_credentials(
        username: impl Into<String>,
        password: impl Into<String>,
        app_id: Option<String>,
        app_secret: Option<String>,
    ) -> Result<Self, core_types::ValidationError> {
        let auth = QobuzAuthMode::credentials(username, password, app_id, app_secret)?;
        Ok(Self {
            auth,
            base_url: default_base_url(),
            default_format_id: None,
        })
    }

    pub fn app_id(&self) -> &str {
        match &self.auth {
            QobuzAuthMode::Token {
                app_id: Some(id), ..
            } if !id.trim().is_empty() => id.as_str(),
            QobuzAuthMode::Credentials {
                app_id: Some(id), ..
            } if !id.trim().is_empty() => id.as_str(),
            _ => DEFAULT_QOBUZ_APP_ID,
        }
    }

    pub fn app_secret(&self) -> Option<&str> {
        match &self.auth {
            QobuzAuthMode::Token {
                app_secret: Some(sec),
                ..
            } if !sec.trim().is_empty() => Some(sec.as_str()),
            QobuzAuthMode::Credentials {
                app_secret: Some(sec),
                ..
            } if !sec.trim().is_empty() => Some(sec.as_str()),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QobuzUserSession {
    pub user_id: u64,
    pub login: String,
    pub user_auth_token: String,
    pub label: Option<String>,
    pub hires: bool,
    pub lossless: bool,
    pub max_streaming_quality: u32,
}
