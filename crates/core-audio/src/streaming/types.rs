use std::io::ErrorKind;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use core_types::{StreamKey, StreamSourceSpec};
use reqwest::Method;
use reqwest::header::HeaderMap;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio_util::sync::CancellationToken;

pub(crate) const MAX_HTTP_REDIRECTS: usize = 15;
pub(crate) const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
pub(crate) const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
pub(crate) const DEFAULT_READ_TIMEOUT: Duration = Duration::from_secs(15);

/// Error type for streaming proxies, manifest parsing, decryption, and blocking bridge I/O.
#[derive(Debug, Clone, PartialEq, Error)]
pub enum StreamError {
    #[error("stream operation cancelled")]
    Cancelled,
    #[error("stream operation timed out")]
    Timeout,
    #[error("authentication required for provider '{provider_id}' (HTTP {status})")]
    AuthRequired { provider_id: String, status: u16 },
    #[error("stream format changed during refresh")]
    FormatChanged(Box<StreamSourceSpec>),
    #[error("HTTP {0} error")]
    HttpStatus(u16),
    #[error("network error: {0}")]
    Network(String),
    #[error("DRM-restricted stream: {0}")]
    DrmRestricted(String),
    #[error("invalid manifest: {0}")]
    InvalidManifest(String),
    #[error("unsupported stream feature: {0}")]
    Unsupported(String),
    #[error("I/O error: {0}")]
    Io(String),
}

impl StreamError {
    /// Converts this `StreamError` into an idiomatic `std::io::Error` preserving cancellation,
    /// timeout, and permission semantics for downstream demuxers.
    pub fn to_io_error(&self) -> std::io::Error {
        let kind = match self {
            Self::Cancelled => ErrorKind::Interrupted,
            Self::Timeout => ErrorKind::TimedOut,
            Self::AuthRequired { .. } | Self::HttpStatus(401 | 403) | Self::DrmRestricted(_) => {
                ErrorKind::PermissionDenied
            }
            Self::FormatChanged(_) | Self::InvalidManifest(_) => ErrorKind::InvalidData,
            Self::HttpStatus(404 | 410) => ErrorKind::NotFound,
            Self::Unsupported(_) => ErrorKind::Unsupported,
            Self::HttpStatus(_) | Self::Network(_) | Self::Io(_) => ErrorKind::Other,
        };
        std::io::Error::new(kind, self.to_string())
    }

    /// Maps this streaming error into the canonical wire [`core_types::LuminaError`].
    pub fn to_lumina_error(&self) -> core_types::LuminaError {
        use core_types::{LuminaError, LuminaErrorCode};
        match self {
            Self::Cancelled => LuminaError::new(LuminaErrorCode::InvalidState, self.to_string())
                .with_details("cancelled"),
            Self::Timeout => {
                LuminaError::new(LuminaErrorCode::StreamResolveTimeout, self.to_string())
                    .with_retryable(true)
            }
            Self::AuthRequired {
                provider_id,
                status,
            } => LuminaError::new(LuminaErrorCode::StreamAuthRequired, self.to_string())
                .with_provider(provider_id.clone())
                .with_http_status(*status),
            Self::FormatChanged(_) => {
                LuminaError::new(LuminaErrorCode::DecodeFailed, self.to_string())
                    .with_retryable(true)
            }
            Self::HttpStatus(status) => {
                let code = if *status == 401 || *status == 403 {
                    LuminaErrorCode::StreamAuthRequired
                } else {
                    LuminaErrorCode::HttpError
                };
                let retryable = *status == 408 || *status == 429 || *status >= 500;
                LuminaError::new(code, self.to_string())
                    .with_http_status(*status)
                    .with_retryable(retryable)
            }
            Self::Network(_) | Self::Io(_) => {
                LuminaError::new(LuminaErrorCode::NetworkDisconnected, self.to_string())
                    .with_retryable(true)
            }
            Self::DrmRestricted(_) | Self::Unsupported(_) => {
                LuminaError::new(LuminaErrorCode::UnsupportedFormat, self.to_string())
            }
            Self::InvalidManifest(_) => {
                LuminaError::new(LuminaErrorCode::DecodeFailed, self.to_string())
            }
        }
    }
}

impl From<&StreamError> for core_types::LuminaError {
    fn from(err: &StreamError) -> Self {
        err.to_lumina_error()
    }
}

impl From<StreamError> for core_types::LuminaError {
    fn from(err: StreamError) -> Self {
        err.to_lumina_error()
    }
}

/// Request payload dispatched when a streaming proxy encounters HTTP 403 or 410 and needs
/// a refreshed URL/manifest via `ResolverFacade.refresh_after_403`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamRefreshRequest {
    pub provider_id: String,
    pub track_id: String,
    pub quality_key: String,
    pub failed_url: String,
    pub status_code: u16,
    pub attempt: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_content_length: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_mime_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_kind: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_initial_probe: bool,
}

/// Outcome returned by [`StreamRefreshHandler::refresh_after_403`].
#[derive(Debug, Clone, PartialEq)]
pub enum StreamRefreshOutcome {
    Refreshed(StreamSourceSpec),
    FormatChanged(StreamSourceSpec, String),
    AuthRequired {
        provider_id: String,
        message: String,
    },
}

/// Injectable async hook invoked by streaming proxies on HTTP 403 / 410 (never on 401).
#[async_trait]
pub trait StreamRefreshHandler: Send + Sync {
    async fn refresh_after_403(
        &self,
        req: StreamRefreshRequest,
        cancel: &CancellationToken,
    ) -> Result<StreamRefreshOutcome, StreamError>;
}

impl From<StreamError> for std::io::Error {
    fn from(err: StreamError) -> Self {
        err.to_io_error()
    }
}

impl From<std::io::Error> for StreamError {
    fn from(err: std::io::Error) -> Self {
        match err.kind() {
            ErrorKind::Interrupted => Self::Cancelled,
            ErrorKind::TimedOut => Self::Timeout,
            _ => Self::Io(err.to_string()),
        }
    }
}

/// Logical window target returned when seeking a segmented manifest stream by presentation time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SegmentedSeekTarget {
    pub virtual_offset: u64,
    pub segment_index: usize,
    pub segment_start_ms: u64,
}

/// Reason an L2 cached head stream diverged from the fresh remote stream during overlap/manifest validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FormatMismatchReason {
    ContentLengthChanged { expected: u64, actual: u64 },
    TailFingerprintMismatch,
    DashSpecMismatch { detail: String },
}

impl std::fmt::Display for FormatMismatchReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ContentLengthChanged { expected, actual } => {
                write!(
                    f,
                    "content length changed (expected {expected}, got {actual})"
                )
            }
            Self::TailFingerprintMismatch => {
                write!(f, "64-byte L2 overlap tail fingerprint mismatch")
            }
            Self::DashSpecMismatch { detail } => {
                write!(f, "DASH L2 manifest compatibility mismatch: {detail}")
            }
        }
    }
}

/// Callback invoked once when a hybrid L2 stream detects a remote format or fingerprint mismatch.
pub type FormatMismatchCallback = Arc<dyn Fn(StreamKey, FormatMismatchReason) + Send + Sync>;

/// Random-access asynchronous byte stream abstraction implemented by HTTP proxies and stream
/// decorators.
#[async_trait]
pub trait ByteStreamSource: Send + Sync {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError>;

    fn len(&self) -> Option<u64>;

    fn is_empty(&self) -> bool {
        self.len() == Some(0)
    }

    fn cancel(&self);

    fn cancellation_token(&self) -> CancellationToken;

    fn hint_extension(&self) -> Option<&str>;

    fn mime_type(&self) -> Option<&str>;

    async fn seek_to_time_ms(
        &self,
        _target_ms: u64,
    ) -> Result<Option<SegmentedSeekTarget>, StreamError> {
        Ok(None)
    }

    /// Reclaims excess cached RAM chunks/segments while idle/paused, returning bytes freed.
    fn reclaim_idle_memory(&self) -> usize {
        0
    }
}

/// Per-proxy timeout and redirect limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamHttpConfig {
    pub connect_timeout: Duration,
    pub request_timeout: Duration,
    pub read_timeout: Duration,
    pub max_redirects: usize,
}

impl Default for StreamHttpConfig {
    fn default() -> Self {
        Self {
            connect_timeout: DEFAULT_CONNECT_TIMEOUT,
            request_timeout: DEFAULT_REQUEST_TIMEOUT,
            read_timeout: DEFAULT_READ_TIMEOUT,
            max_redirects: MAX_HTTP_REDIRECTS,
        }
    }
}

/// Request specification executed by [`StreamHttpTransport`].
#[derive(Debug, Clone)]
pub struct HttpRequestSpec {
    pub method: Method,
    pub url: String,
    pub headers: HeaderMap,
    pub range: Option<(u64, u64)>,
}

/// Buffered HTTP response metadata and payload returned by [`StreamHttpTransport`].
#[derive(Debug, Clone)]
pub struct HttpResponseData {
    pub status: u16,
    pub final_url: String,
    pub headers: HeaderMap,
    pub content_length: Option<u64>,
    pub content_range_total: Option<u64>,
    pub body: Bytes,
}

/// Injectable async HTTP transport abstraction enabling deterministic local server or mock tests.
#[async_trait]
pub trait StreamHttpTransport: Send + Sync {
    async fn execute(
        &self,
        req: HttpRequestSpec,
        read_body: bool,
        config: &StreamHttpConfig,
        cancel: &CancellationToken,
    ) -> Result<HttpResponseData, StreamError>;
}
