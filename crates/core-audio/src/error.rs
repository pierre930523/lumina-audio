use core_types::AudioFormat;
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
