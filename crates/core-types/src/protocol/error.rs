use serde::{Deserialize, Serialize};
use std::fmt;

use crate::ValidationError;

// ============================================================================
// LuminaErrorCode & LuminaError
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LuminaErrorCode {
    DeviceOpenFailed,
    ExclusiveModeConflict,
    DeviceNotFound,
    DeviceLost,
    StreamResolveTimeout,
    StreamAuthRequired,
    NetworkDisconnected,
    HttpError,
    DecodeFailed,
    UnsupportedFormat,
    InvalidCommand,
    InvalidState,
    NotInitialized,
    DatabaseError,
    #[default]
    Internal,
}

impl LuminaErrorCode {
    #[inline]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::DeviceOpenFailed => "device_open_failed",
            Self::ExclusiveModeConflict => "exclusive_mode_conflict",
            Self::DeviceNotFound => "device_not_found",
            Self::DeviceLost => "device_lost",
            Self::StreamResolveTimeout => "stream_resolve_timeout",
            Self::StreamAuthRequired => "stream_auth_required",
            Self::NetworkDisconnected => "network_disconnected",
            Self::HttpError => "http_error",
            Self::DecodeFailed => "decode_failed",
            Self::UnsupportedFormat => "unsupported_format",
            Self::InvalidCommand => "invalid_command",
            Self::InvalidState => "invalid_state",
            Self::NotInitialized => "not_initialized",
            Self::DatabaseError => "database_error",
            Self::Internal => "internal",
        }
    }
}

impl fmt::Display for LuminaErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct LuminaError {
    pub code: LuminaErrorCode,
    pub message: String,
    #[serde(default)]
    pub retryable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub http_status: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

impl LuminaError {
    pub fn new(code: LuminaErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: false,
            provider: None,
            http_status: None,
            details: None,
        }
    }

    pub fn with_retryable(mut self, retryable: bool) -> Self {
        self.retryable = retryable;
        self
    }

    pub fn with_provider(mut self, provider: impl Into<String>) -> Self {
        let p = provider.into();
        if !p.trim().is_empty() {
            self.provider = Some(p);
        }
        self
    }

    pub fn with_http_status(mut self, status: u16) -> Self {
        self.http_status = Some(status);
        self
    }

    pub fn with_details(mut self, details: impl Into<String>) -> Self {
        let d = details.into();
        if !d.trim().is_empty() {
            self.details = Some(d);
        }
        self
    }
}

impl fmt::Display for LuminaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for LuminaError {}

impl From<ValidationError> for LuminaError {
    fn from(err: ValidationError) -> Self {
        Self::new(LuminaErrorCode::InvalidCommand, err.to_string())
    }
}
