use crate::AudioCodec;

#[derive(Debug, thiserror::Error, PartialEq, Eq, Clone)]
pub enum ValidationError {
    #[error("field '{field}' cannot be empty: {message}")]
    EmptyField {
        field: &'static str,
        message: &'static str,
    },
    #[error("invalid sample rate: {0} Hz (must be between 1 and 50,000,000 Hz)")]
    InvalidSampleRate(u32),
    #[error("invalid channels: {0} (must be between 1 and 32)")]
    InvalidChannels(u8),
    #[error("invalid bit depth {bit_depth} for codec {codec:?}")]
    InvalidBitDepth { bit_depth: u8, codec: AudioCodec },
    #[error("DSD codec requires bit_depth == 1 and is_dsd == true")]
    InvalidDsdFormat,
    #[error("invalid duration: {0} ms (must be greater than 0)")]
    InvalidDuration(u64),
    #[error("invalid hex color '{0}': must be #RRGGBB or #RRGGBBAA")]
    InvalidHexColor(String),
    #[error("invalid ISRC '{0}': must be 12 alphanumeric characters (or CC-XXX-YY-NNNNN)")]
    InvalidIsrc(String),
    #[error("invalid release year: {0} (must be between 1000 and 3000)")]
    InvalidReleaseYear(i32),
    #[error("invalid track number: {0} (must be >= 1)")]
    InvalidTrackNumber(u16),
    #[error("invalid disc number: {0} (must be >= 1)")]
    InvalidDiscNumber(u16),
    #[error("unknown provider: '{0}'")]
    UnknownProvider(String),
    #[error("unknown audio codec: '{0}'")]
    UnknownAudioCodec(String),
    #[error("unknown output backend: '{0}'")]
    UnknownOutputBackend(String),
    #[error("unknown signal quality: '{0}'")]
    UnknownSignalQuality(String),
    #[error("signal path must contain at least one node")]
    EmptySignalPath,
    #[error("Qobuz token cannot be empty or whitespace")]
    EmptyQobuzToken,
    #[error("Qobuz credentials cannot be empty or whitespace")]
    EmptyQobuzCredentials,
}
