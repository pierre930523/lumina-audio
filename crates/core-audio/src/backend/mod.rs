pub mod asio;
#[cfg(target_os = "windows")]
pub mod asio_win;
pub mod mock;
pub mod wasapi;
#[cfg(target_os = "windows")]
pub mod wasapi_win;

use std::time::Duration;
pub use core_types::AudioDeviceDescription;
use core_types::{AudioFormat, OutputBackendKind};
use crate::error::BackendError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendState {
    Uninitialized,
    Ready,
    Playing,
    Paused,
    Stopped,
    Error,
}

#[derive(Debug, Clone)]
pub struct BackendConfig {
    pub device_id: Option<String>,
    pub format: AudioFormat,
    pub buffer_frames: u32,
}

impl BackendConfig {
    pub fn new(format: AudioFormat, buffer_frames: u32) -> Result<Self, BackendError> {
        Self::with_device(None, format, buffer_frames)
    }

    pub fn with_device(
        device_id: Option<String>,
        format: AudioFormat,
        buffer_frames: u32,
    ) -> Result<Self, BackendError> {
        if !Self::is_valid_buffer_size(buffer_frames) {
            return Err(BackendError::InvalidBufferSize(buffer_frames));
        }

        Ok(Self {
            device_id,
            format,
            buffer_frames,
        })
    }

    pub fn is_valid_buffer_size(frames: u32) -> bool {
        (32..=4096).contains(&frames) && frames.is_power_of_two()
    }
}

pub trait AudioOutputBackend: Send + Sync {
    /// Friendly backend name.
    fn name(&self) -> &str;

    /// Kind of backend (ASIO, WASAPI Exclusive, Shared, etc.).
    fn backend_kind(&self) -> OutputBackendKind;

    /// Currently selected audio device description.
    fn current_device(&self) -> Option<&AudioDeviceDescription>;

    /// Current backend playback lifecycle state.
    fn state(&self) -> BackendState;

    /// Lists all enumerated audio devices for this backend.
    fn list_devices(&self) -> Result<Vec<AudioDeviceDescription>, BackendError>;

    /// Checks if the requested audio format can be rendered natively.
    fn is_format_supported(&self, format: &AudioFormat) -> bool;

    /// Opens the audio hardware interface with the given configuration.
    fn open(&mut self, config: &BackendConfig) -> Result<(), BackendError>;

    /// Starts audio playback stream.
    fn start(&mut self) -> Result<(), BackendError>;

    /// Pauses audio playback stream.
    fn pause(&mut self) -> Result<(), BackendError>;

    /// Resumes paused audio playback stream.
    fn resume(&mut self) -> Result<(), BackendError>;

    /// Stops audio playback stream.
    fn stop(&mut self) -> Result<(), BackendError>;

    /// Closes hardware stream and releases resources.
    fn close(&mut self) -> Result<(), BackendError>;

    /// Writes interleaved f32 PCM samples: `[L0, R0, L1, R1, ...]`. Returns frames written.
    fn write_interleaved_f32(&mut self, frames: &[f32]) -> Result<usize, BackendError>;

    /// Writes interleaved f64 PCM samples: `[L0, R0, L1, R1, ...]`. Returns frames written.
    fn write_interleaved_f64(&mut self, frames: &[f64]) -> Result<usize, BackendError>;

    /// Writes raw native DSD bitstream bytes. Returns bytes written.
    fn write_native_dsd(&mut self, bytes: &[u8]) -> Result<usize, BackendError>;

    /// Current hardware buffer latency in frames.
    fn latency_frames(&self) -> u32;

    /// Current hardware buffer latency as a duration.
    fn latency_duration(&self) -> Duration;

    /// Total audio frames successfully submitted to hardware.
    fn frames_written(&self) -> u64;

    /// Total count of audio buffer underruns/underflows experienced.
    fn underflow_count(&self) -> u64;
}
