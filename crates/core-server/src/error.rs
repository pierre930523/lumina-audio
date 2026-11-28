use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use core_types::{LuminaError, LuminaErrorCode};
use serde_json::json;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("Invalid PIN format: must be 6 numeric digits")]
    InvalidPinFormat,

    #[error("PIN not found or expired")]
    PinNotFoundOrExpired,

    #[error("PIN already consumed")]
    PinAlreadyConsumed,

    #[error("IP locked out due to excessive failed attempts")]
    IpLockedOut,

    #[error("Unauthorized: invalid or missing Bearer token")]
    Unauthorized,

    #[error("Payload too large: exceeds 10MB limit")]
    PayloadTooLarge,

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Bad request: {0}")]
    BadRequest(String),

    #[error("Database error: {0}")]
    Database(String),

    #[error("Internal server error: {0}")]
    Internal(String),

    #[error("{0}")]
    Lumina(#[from] LuminaError),
}

impl ServerError {
    pub fn http_status(&self) -> StatusCode {
        match self {
            ServerError::InvalidPinFormat
            | ServerError::PinNotFoundOrExpired
            | ServerError::PinAlreadyConsumed
            | ServerError::BadRequest(_) => StatusCode::BAD_REQUEST,
            ServerError::IpLockedOut => StatusCode::TOO_MANY_REQUESTS,
            ServerError::Unauthorized => StatusCode::UNAUTHORIZED,
            ServerError::PayloadTooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            ServerError::NotFound(_) => StatusCode::NOT_FOUND,
            ServerError::Database(_) | ServerError::Internal(_) => {
                StatusCode::INTERNAL_SERVER_ERROR
            }
            ServerError::Lumina(err) => {
                if let Some(code) = err.http_status
                    && let Ok(status) = StatusCode::from_u16(code)
                {
                    return status;
                }
                match err.code {
                    LuminaErrorCode::InvalidCommand | LuminaErrorCode::InvalidState => {
                        StatusCode::BAD_REQUEST
                    }
                    LuminaErrorCode::StreamAuthRequired => StatusCode::UNAUTHORIZED,
                    LuminaErrorCode::DeviceNotFound => StatusCode::NOT_FOUND,
                    LuminaErrorCode::ExclusiveModeConflict => StatusCode::CONFLICT,
                    LuminaErrorCode::StreamResolveTimeout => StatusCode::GATEWAY_TIMEOUT,
                    LuminaErrorCode::NetworkDisconnected => StatusCode::SERVICE_UNAVAILABLE,
                    _ => StatusCode::INTERNAL_SERVER_ERROR,
                }
            }
        }
    }

    pub fn to_lumina_error(&self) -> LuminaError {
        let status = self.http_status().as_u16();
        match self {
            ServerError::InvalidPinFormat
            | ServerError::PinNotFoundOrExpired
            | ServerError::PinAlreadyConsumed => {
                LuminaError::new(LuminaErrorCode::InvalidCommand, self.to_string())
                    .with_http_status(status)
            }
            ServerError::IpLockedOut => {
                LuminaError::new(LuminaErrorCode::HttpError, self.to_string())
                    .with_retryable(true)
                    .with_http_status(status)
            }
            ServerError::Unauthorized => {
                LuminaError::new(LuminaErrorCode::StreamAuthRequired, self.to_string())
                    .with_http_status(status)
            }
            ServerError::PayloadTooLarge => {
                LuminaError::new(LuminaErrorCode::InvalidCommand, self.to_string())
                    .with_http_status(status)
            }
            ServerError::NotFound(m) => {
                LuminaError::new(LuminaErrorCode::InvalidCommand, m.clone())
                    .with_http_status(status)
            }
            ServerError::BadRequest(m) => {
                LuminaError::new(LuminaErrorCode::InvalidCommand, m.clone())
                    .with_http_status(status)
            }
            ServerError::Database(e) => {
                LuminaError::new(LuminaErrorCode::DatabaseError, e.clone()).with_http_status(status)
            }
            ServerError::Internal(e) => {
                LuminaError::new(LuminaErrorCode::Internal, e.clone()).with_http_status(status)
            }
            ServerError::Lumina(err) => {
                let mut cloned = err.clone();
                if cloned.http_status.is_none() {
                    cloned.http_status = Some(status);
                }
                cloned
            }
        }
    }
}

impl IntoResponse for ServerError {
    fn into_response(self) -> Response {
        let status = self.http_status();
        let lumina = self.to_lumina_error();

        let mut map = serde_json::Map::new();
        // Legacy compatibility keys
        map.insert("status".to_string(), json!("error"));
        map.insert("error".to_string(), json!(lumina.message));
        // Canonical LuminaError keys
        if let Ok(serde_json::Value::Object(canonical)) = serde_json::to_value(&lumina) {
            for (k, v) in canonical {
                map.insert(k, v);
            }
        }

        (status, Json(serde_json::Value::Object(map))).into_response()
    }
}
