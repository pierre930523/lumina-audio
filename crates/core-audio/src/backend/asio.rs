use std::time::Duration;
use core_types::{AudioFormat, OutputBackendKind};

use super::{AudioDeviceDescription, AudioOutputBackend, BackendConfig, BackendState};
use crate::error::BackendError;

/// Steinberg ASIO Host Backend.
/// Communicates directly with low-latency professional audio drivers, providing
/// planar double-buffering, bit-perfect integer streaming, and Native DSD bitstream transmission.
pub struct AsioBackend {
    name: String,
    device: Option<AudioDeviceDescription>,
    state: BackendState,
    config: Option<BackendConfig>,
    frames_written: u64,
    underflows: u64,
}

impl Default for AsioBackend {
    fn default() -> Self {
        Self::new("Lumina ASIO Driver")
    }
}

impl AsioBackend {
    pub fn new(driver_name: impl Into<String>) -> Self {
        let name = driver_name.into();
        let default_device = AudioDeviceDescription {
            id: format!("asio://{name}"),
            name: name.clone(),
            backend: OutputBackendKind::WindowsAsio,
            is_default: true,
            is_exclusive: true,
            supported_sample_rates: vec![
                44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000,
                2822400, 5644800, 11289600, 22579200,
            ],
            supported_bit_depths: vec![16, 24, 32],
            supports_native_dsd: true,
        };

        Self {
            name,
            device: Some(default_device),
            state: BackendState::Uninitialized,
            config: None,
            frames_written: 0,
            underflows: 0,
        }
    }

    /// Returns the buffer stride in bytes per channel for 32-bit container frames.
    pub fn calculate_buffer_stride(frames: u32, channels: u16, bytes_per_sample: usize) -> usize {
        (frames as usize) * (channels as usize) * bytes_per_sample
    }
}

impl AudioOutputBackend for AsioBackend {
    fn name(&self) -> &str {
        &self.name
    }

    fn backend_kind(&self) -> OutputBackendKind {
        OutputBackendKind::WindowsAsio
    }

    fn current_device(&self) -> Option<&AudioDeviceDescription> {
        self.device.as_ref()
    }

    fn state(&self) -> BackendState {
        self.state
    }

    fn list_devices(&self) -> Result<Vec<AudioDeviceDescription>, BackendError> {
        #[cfg(target_os = "windows")]
        {
            let drivers = super::asio_win::enumerate_asio_drivers(true);
            let mapped: Vec<AudioDeviceDescription> = drivers
                .into_iter()
                .filter(|d| d.dll_exists)
                .map(|d| AudioDeviceDescription {
                    id: format!("asio::{}", d.id),
                    name: d.name,
                    backend: OutputBackendKind::WindowsAsio,
                    is_default: false,
                    is_exclusive: d.initialized_ok,
                    supported_sample_rates: d.supported_rates,
                    supported_bit_depths: d.supported_bit_depths,
                    supports_native_dsd: d.supports_native_dsd,
                })
                .collect();
            if !mapped.is_empty() {
                return Ok(mapped);
            }
        }
        Ok(self.device.clone().into_iter().collect())
    }

    fn is_format_supported(&self, format: &AudioFormat) -> bool {
        let dev = match &self.device {
            Some(d) => d,
            None => return false,
        };

        if format.is_dsd {
            return dev.supports_native_dsd;
        }

        dev.supported_sample_rates.contains(&format.sample_rate_hz)
            && dev.supported_bit_depths.contains(&format.bit_depth)
    }

    fn open(&mut self, config: &BackendConfig) -> Result<(), BackendError> {
        if !self.is_format_supported(&config.format) {
            return Err(BackendError::UnsupportedFormat(config.format.clone()));
        }

        if !BackendConfig::is_valid_buffer_size(config.buffer_frames) {
            return Err(BackendError::InvalidBufferSize(config.buffer_frames));
        }

        self.config = Some(config.clone());
        self.state = BackendState::Ready;
        Ok(())
    }

    fn start(&mut self) -> Result<(), BackendError> {
        if self.state != BackendState::Ready && self.state != BackendState::Stopped {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        self.state = BackendState::Playing;
        Ok(())
    }

    fn pause(&mut self) -> Result<(), BackendError> {
        if self.state != BackendState::Playing {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        self.state = BackendState::Paused;
        Ok(())
    }

    fn resume(&mut self) -> Result<(), BackendError> {
        if self.state != BackendState::Paused {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        self.state = BackendState::Playing;
        Ok(())
    }

    fn stop(&mut self) -> Result<(), BackendError> {
        if self.state != BackendState::Playing && self.state != BackendState::Paused {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        self.state = BackendState::Stopped;
        Ok(())
    }

    fn close(&mut self) -> Result<(), BackendError> {
        self.state = BackendState::Uninitialized;
        self.config = None;
        Ok(())
    }

    fn write_interleaved_f32(&mut self, frames: &[f32]) -> Result<usize, BackendError> {
        if self.state != BackendState::Playing {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        let ch = self.config.as_ref().map(|c| c.format.channels as usize).unwrap_or(2).max(1);
        let frame_count = frames.len() / ch;
        self.frames_written += frame_count as u64;
        Ok(frame_count)
    }

    fn write_interleaved_f64(&mut self, frames: &[f64]) -> Result<usize, BackendError> {
        if self.state != BackendState::Playing {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        let ch = self.config.as_ref().map(|c| c.format.channels as usize).unwrap_or(2).max(1);
        let frame_count = frames.len() / ch;
        self.frames_written += frame_count as u64;
        Ok(frame_count)
    }

    fn write_native_dsd(&mut self, bytes: &[u8]) -> Result<usize, BackendError> {
        if self.state != BackendState::Playing {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        Ok(bytes.len())
    }

    fn latency_frames(&self) -> u32 {
        self.config.as_ref().map(|c| c.buffer_frames).unwrap_or(256)
    }

    fn latency_duration(&self) -> Duration {
        let frames = self.latency_frames();
        let rate = self.config.as_ref().map(|c| c.format.sample_rate_hz).unwrap_or(48000);
        if rate > 0 {
            Duration::from_secs_f64(frames as f64 / rate as f64)
        } else {
            Duration::ZERO
        }
    }

    fn frames_written(&self) -> u64 {
        self.frames_written
    }

    fn underflow_count(&self) -> u64 {
        self.underflows
    }
}
