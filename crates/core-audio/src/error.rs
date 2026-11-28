use core_types::{AudioFormat, LuminaError, LuminaErrorCode};
use std::io::ErrorKind;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreAudioError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Decoder error: {0}")]
    Decoder(#[from] DecoderError),

    #[error("DSD error: {0}")]
    Dsd(#[from] DsdError),

    #[error("DSP error: {0}")]
    Dsp(#[from] DspError),

    #[error("Backend error: {0}")]
    Backend(#[from] BackendError),

    #[error("Unsupported audio format: {0}")]
    UnsupportedFormat(String),

    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),
}

#[derive(Debug, Error)]
pub enum DecoderError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Format probe failed: {0}")]
    ProbeFailed(String),

    #[error("No supported audio tracks found in container")]
    NoAudioTrack,

    #[error("Codec initialization failed: {0}")]
    CodecInitFailed(String),

    #[error("Decode frame error: {0}")]
    DecodeError(String),

    #[error("Seek error: {0}")]
    SeekError(String),

    #[error("Unexpected end of file")]
    UnexpectedEof,

    #[error("Unsupported format or container: {0}")]
    UnsupportedFormat(String),

    #[error("Stream authentication required for provider '{provider_id}' (HTTP {status})")]
    StreamAuthRequired { provider_id: String, status: u16 },

    #[error("Stream format changed during refresh")]
    StreamFormatChanged(Box<core_types::streaming::StreamSourceSpec>),
}

#[derive(Debug, Error)]
pub enum DsdError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Invalid DSF container: {0}")]
    InvalidDsf(String),

    #[error("Invalid DSDIFF container: {0}")]
    InvalidDsdiff(String),

    #[error("Unsupported DSD compression (e.g. DST): {0}")]
    UnsupportedCompression(String),

    #[error("Unsupported DSD channels: {0}")]
    UnsupportedChannels(u16),

    #[error("Unsupported DSD sample rate: {0} Hz")]
    UnsupportedSampleRate(u32),

    #[error("Corrupt DSD header: {0}")]
    CorruptHeader(String),

    #[error("Truncated DSD data")]
    TruncatedData,

    #[error("Invalid DoP marker sequence: expected 0x05 / 0xFA, found 0x{0:02X}")]
    InvalidDopMarker(u8),
}

#[derive(Debug, Error)]
pub enum DspError {
    #[error("Invalid filter parameters: {0}")]
    InvalidFilterParameters(String),

    #[error("Unstable filter detected: poles outside unit circle ({0})")]
    UnstableFilter(String),

    #[error("Invalid AutoEQ syntax: {0}")]
    InvalidAutoEqSyntax(String),

    #[error("Channel mismatch: expected {expected}, found {found}")]
    ChannelMismatch { expected: u16, found: u16 },
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum BackendError {
    #[error("Device not found: {0}")]
    DeviceNotFound(String),

    #[error("Format unsupported: {0:?}")]
    UnsupportedFormat(AudioFormat),

    #[error("Invalid buffer size: {0} frames (must be power of two between 32 and 4096)")]
    InvalidBufferSize(u32),

    #[error("Device in use / exclusive access denied")]
    DeviceInUse,

    #[error("Driver initialization or runtime error: {0}")]
    DriverError(String),

    #[error("Backend is in invalid state for operation: {0}")]
    InvalidState(String),

    #[error("Audio buffer underflow")]
    Underflow,
}

fn map_io_error(io: &std::io::Error, fallback_code: LuminaErrorCode) -> LuminaError {
    let msg = io.to_string();
    match io.kind() {
        ErrorKind::TimedOut => {
            LuminaError::new(LuminaErrorCode::StreamResolveTimeout, msg).with_retryable(true)
        }
        ErrorKind::ConnectionReset
        | ErrorKind::ConnectionAborted
        | ErrorKind::NotConnected
        | ErrorKind::BrokenPipe
        | ErrorKind::ConnectionRefused => {
            LuminaError::new(LuminaErrorCode::NetworkDisconnected, msg).with_retryable(true)
        }
        ErrorKind::PermissionDenied => LuminaError::new(LuminaErrorCode::StreamAuthRequired, msg),
        _ => LuminaError::new(fallback_code, msg),
    }
}

impl BackendError {
    pub fn to_lumina_error(&self) -> LuminaError {
        match self {
            Self::DeviceNotFound(_) => {
                LuminaError::new(LuminaErrorCode::DeviceNotFound, self.to_string())
            }
            Self::UnsupportedFormat(_) => {
                LuminaError::new(LuminaErrorCode::UnsupportedFormat, self.to_string())
            }
            Self::InvalidBufferSize(_) => {
                LuminaError::new(LuminaErrorCode::InvalidCommand, self.to_string())
            }
            Self::DeviceInUse => {
                LuminaError::new(LuminaErrorCode::ExclusiveModeConflict, self.to_string())
                    .with_retryable(true)
            }
            Self::DriverError(_) => {
                LuminaError::new(LuminaErrorCode::DeviceOpenFailed, self.to_string())
                    .with_retryable(true)
            }
            Self::InvalidState(_) => {
                LuminaError::new(LuminaErrorCode::InvalidState, self.to_string())
            }
            Self::Underflow => LuminaError::new(LuminaErrorCode::Internal, self.to_string())
                .with_retryable(true)
                .with_details("audio_buffer_underflow"),
        }
    }
}

impl DecoderError {
    pub fn to_lumina_error(&self) -> LuminaError {
        match self {
            Self::Io(io) => map_io_error(io, LuminaErrorCode::DecodeFailed),
            Self::StreamAuthRequired {
                provider_id,
                status,
            } => LuminaError::new(LuminaErrorCode::StreamAuthRequired, self.to_string())
                .with_provider(provider_id.clone())
                .with_http_status(*status),
            Self::UnsupportedFormat(_) => {
                LuminaError::new(LuminaErrorCode::UnsupportedFormat, self.to_string())
            }
            Self::StreamFormatChanged(_) => {
                LuminaError::new(LuminaErrorCode::DecodeFailed, self.to_string())
                    .with_retryable(true)
            }
            Self::ProbeFailed(_)
            | Self::NoAudioTrack
            | Self::CodecInitFailed(_)
            | Self::DecodeError(_)
            | Self::SeekError(_)
            | Self::UnexpectedEof => {
                LuminaError::new(LuminaErrorCode::DecodeFailed, self.to_string())
            }
        }
    }
}

impl DsdError {
    pub fn to_lumina_error(&self) -> LuminaError {
        match self {
            Self::Io(io) => map_io_error(io, LuminaErrorCode::DecodeFailed),
            Self::UnsupportedCompression(_)
            | Self::UnsupportedChannels(_)
            | Self::UnsupportedSampleRate(_) => {
                LuminaError::new(LuminaErrorCode::UnsupportedFormat, self.to_string())
            }
            Self::InvalidDsf(_)
            | Self::InvalidDsdiff(_)
            | Self::CorruptHeader(_)
            | Self::TruncatedData
            | Self::InvalidDopMarker(_) => {
                LuminaError::new(LuminaErrorCode::DecodeFailed, self.to_string())
            }
        }
    }
}

impl DspError {
    pub fn to_lumina_error(&self) -> LuminaError {
        LuminaError::new(LuminaErrorCode::InvalidCommand, self.to_string())
    }
}

impl CoreAudioError {
    pub fn to_lumina_error(&self) -> LuminaError {
        match self {
            Self::Io(io) => map_io_error(io, LuminaErrorCode::Internal),
            Self::Decoder(err) => err.to_lumina_error(),
            Self::Dsd(err) => err.to_lumina_error(),
            Self::Dsp(err) => err.to_lumina_error(),
            Self::Backend(err) => err.to_lumina_error(),
            Self::UnsupportedFormat(_) => {
                LuminaError::new(LuminaErrorCode::UnsupportedFormat, self.to_string())
            }
            Self::InvalidConfig(_) => {
                LuminaError::new(LuminaErrorCode::InvalidCommand, self.to_string())
            }
        }
    }
}

impl From<&BackendError> for LuminaError {
    fn from(err: &BackendError) -> Self {
        err.to_lumina_error()
    }
}

impl From<BackendError> for LuminaError {
    fn from(err: BackendError) -> Self {
        err.to_lumina_error()
    }
}

impl From<&DecoderError> for LuminaError {
    fn from(err: &DecoderError) -> Self {
        err.to_lumina_error()
    }
}

impl From<DecoderError> for LuminaError {
    fn from(err: DecoderError) -> Self {
        err.to_lumina_error()
    }
}

impl From<&DsdError> for LuminaError {
    fn from(err: &DsdError) -> Self {
        err.to_lumina_error()
    }
}

impl From<DsdError> for LuminaError {
    fn from(err: DsdError) -> Self {
        err.to_lumina_error()
    }
}

impl From<&DspError> for LuminaError {
    fn from(err: &DspError) -> Self {
        err.to_lumina_error()
    }
}

impl From<DspError> for LuminaError {
    fn from(err: DspError) -> Self {
        err.to_lumina_error()
    }
}

impl From<&CoreAudioError> for LuminaError {
    fn from(err: &CoreAudioError) -> Self {
        err.to_lumina_error()
    }
}

impl From<CoreAudioError> for LuminaError {
    fn from(err: CoreAudioError) -> Self {
        err.to_lumina_error()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_core_audio_error_to_lumina_error_mappings() {
        let e1 = CoreAudioError::Backend(BackendError::DeviceInUse).to_lumina_error();
        assert_eq!(e1.code, LuminaErrorCode::ExclusiveModeConflict);
        assert!(e1.retryable);

        let e2 =
            CoreAudioError::Backend(BackendError::DeviceNotFound("dac-0".into())).to_lumina_error();
        assert_eq!(e2.code, LuminaErrorCode::DeviceNotFound);
        assert!(!e2.retryable);

        let e3 = CoreAudioError::Backend(BackendError::DriverError("init failed".into()))
            .to_lumina_error();
        assert_eq!(e3.code, LuminaErrorCode::DeviceOpenFailed);
        assert!(e3.retryable);

        let e4 = CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
            provider_id: "qobuz".into(),
            status: 401,
        })
        .to_lumina_error();
        assert_eq!(e4.code, LuminaErrorCode::StreamAuthRequired);
        assert_eq!(e4.provider.as_deref(), Some("qobuz"));
        assert_eq!(e4.http_status, Some(401));

        let e5 = CoreAudioError::Io(std::io::Error::new(ErrorKind::TimedOut, "resolve timeout"))
            .to_lumina_error();
        assert_eq!(e5.code, LuminaErrorCode::StreamResolveTimeout);
        assert!(e5.retryable);

        let e6 = CoreAudioError::Io(std::io::Error::new(
            ErrorKind::ConnectionReset,
            "connection reset",
        ))
        .to_lumina_error();
        assert_eq!(e6.code, LuminaErrorCode::NetworkDisconnected);
        assert!(e6.retryable);

        let e7 = CoreAudioError::UnsupportedFormat("MQA".into()).to_lumina_error();
        assert_eq!(e7.code, LuminaErrorCode::UnsupportedFormat);
    }
}
