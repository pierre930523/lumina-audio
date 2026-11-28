use core_types::{AudioFormat, OutputBackendKind};
use std::sync::Arc;
use std::time::Duration;

use super::device_fsm::DEFAULT_POST_RELEASE_GUARD_DELAY;
use super::{AudioDeviceDescription, AudioOutputBackend, BackendConfig, BackendState};
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::RtTelemetry;

/// WASAPI Exclusive mode backend for Windows.
/// Bypasses the Windows system audio mixer (audiodg.exe) and directly addresses
/// DAC endpoints using exclusive event-driven streaming with MMCSS Pro Audio thread scheduling.
pub struct WasapiBackend {
    name: String,
    device: Option<AudioDeviceDescription>,
    state: BackendState,
    config: Option<BackendConfig>,
    frames_written: u64,
    underflows: u64,
    telemetry: Arc<RtTelemetry>,
    post_release_guard_delay: Duration,
}

impl Default for WasapiBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl WasapiBackend {
    pub fn new() -> Self {
        let default_device = AudioDeviceDescription {
            id: "{0.0.0.00000000}.{wasapi-default-output}".into(),
            name: "WASAPI Exclusive DAC Endpoint".into(),
            backend: OutputBackendKind::WindowsWasapiExclusive,
            is_default: true,
            is_exclusive: true,
            supported_sample_rates: vec![
                44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000,
            ],
            supported_bit_depths: vec![16, 24, 32],
            supports_native_dsd: false, // WASAPI supports DoP (DSD over PCM)
        };

        Self {
            name: "WASAPI Exclusive".into(),
            device: Some(default_device),
            state: BackendState::Uninitialized,
            config: None,
            frames_written: 0,
            underflows: 0,
            telemetry: Arc::new(RtTelemetry::new()),
            post_release_guard_delay: DEFAULT_POST_RELEASE_GUARD_DELAY,
        }
    }

    pub fn telemetry(&self) -> Arc<RtTelemetry> {
        Arc::clone(&self.telemetry)
    }

    pub fn post_release_guard_delay(&self) -> Duration {
        self.post_release_guard_delay
    }

    pub fn set_post_release_guard_delay(&mut self, delay: Duration) {
        self.post_release_guard_delay = delay;
    }
}

impl AudioOutputBackend for WasapiBackend {
    fn name(&self) -> &str {
        &self.name
    }

    fn backend_kind(&self) -> OutputBackendKind {
        OutputBackendKind::WindowsWasapiExclusive
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
            let probed = super::wasapi_win::probe_wasapi_endpoints();
            if !probed.is_empty() {
                return Ok(probed
                    .into_iter()
                    .map(|p| AudioDeviceDescription {
                        id: p.id,
                        name: p.name,
                        backend: if p.exclusive_available {
                            OutputBackendKind::WindowsWasapiExclusive
                        } else {
                            OutputBackendKind::WindowsWasapiShared
                        },
                        is_default: p.is_default,
                        is_exclusive: p.exclusive_available,
                        supported_sample_rates: p.supported_rates,
                        supported_bit_depths: p.supported_bit_depths,
                        supports_native_dsd: false,
                    })
                    .collect());
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
            return false; // Direct DSD via WASAPI must be encapsulated via DoP into PCM
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
        let ch = self
            .config
            .as_ref()
            .map(|c| c.format.channels as usize)
            .unwrap_or(2)
            .max(1);
        let frame_count = frames.len() / ch;
        self.frames_written += frame_count as u64;
        Ok(frame_count)
    }

    fn write_interleaved_f64(&mut self, frames: &[f64]) -> Result<usize, BackendError> {
        if self.state != BackendState::Playing {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }
        let ch = self
            .config
            .as_ref()
            .map(|c| c.format.channels as usize)
            .unwrap_or(2)
            .max(1);
        let frame_count = frames.len() / ch;
        self.frames_written += frame_count as u64;
        Ok(frame_count)
    }

    fn write_native_dsd(&mut self, _bytes: &[u8]) -> Result<usize, BackendError> {
        Err(BackendError::DriverError(
            "WASAPI Exclusive does not support raw Native DSD; use DoP or ASIO".into(),
        ))
    }

    fn latency_frames(&self) -> u32 {
        self.config.as_ref().map(|c| c.buffer_frames).unwrap_or(256)
    }

    fn latency_duration(&self) -> Duration {
        let frames = self.latency_frames();
        let rate = self
            .config
            .as_ref()
            .map(|c| c.format.sample_rate_hz)
            .unwrap_or(48000);
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
