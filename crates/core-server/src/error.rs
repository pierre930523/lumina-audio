use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
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
}

impl IntoResponse for ServerError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            ServerError::InvalidPinFormat => (StatusCode::BAD_REQUEST, self.to_string()),
            ServerError::PinNotFoundOrExpired => (StatusCode::BAD_REQUEST, self.to_string()),
            ServerError::PinAlreadyConsumed => (StatusCode::BAD_REQUEST, self.to_string()),
            ServerError::IpLockedOut => (StatusCode::TOO_MANY_REQUESTS, self.to_string()),
            ServerError::Unauthorized => (StatusCode::UNAUTHORIZED, self.to_string()),
            ServerError::PayloadTooLarge => (StatusCode::PAYLOAD_TOO_LARGE, self.to_string()),
            ServerError::NotFound(m) => (StatusCode::NOT_FOUND, m.clone()),
            ServerError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            ServerError::Database(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.clone()),
            ServerError::Internal(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.clone()),
        };

        let body = Json(json!({
            "status": "error",
            "error": msg,
        }));

        (status, body).into_response()
    }
}
