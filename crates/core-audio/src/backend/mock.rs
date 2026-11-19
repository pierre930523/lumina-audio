use std::time::Duration;
use core_types::{AudioFormat, OutputBackendKind};

use super::{AudioDeviceDescription, AudioOutputBackend, BackendConfig, BackendState};
use crate::error::BackendError;

/// Deterministic cross-platform mock audio backend for headless testing.
/// Records all submitted PCM frames and DSD bytes, simulates buffer underflows,
/// and tracks exact frame counts and clocks without requiring audio hardware.
#[derive(Debug, Clone)]
pub struct MockBackend {
    name: String,
    kind: OutputBackendKind,
    state: BackendState,
    config: Option<BackendConfig>,
    devices: Vec<AudioDeviceDescription>,
    current_device_idx: usize,
    recorded_f32: Vec<f32>,
    recorded_f64: Vec<f64>,
    recorded_dsd: Vec<u8>,
    frames_written: u64,
    underflows: u64,
    fail_on_open: bool,
    fail_on_start: bool,
}

impl Default for MockBackend {
    fn default() -> Self {
        Self::new("Mock DAC", OutputBackendKind::WindowsAsio)
    }
}

impl MockBackend {
    pub fn new(name: impl Into<String>, kind: OutputBackendKind) -> Self {
        let name_str = name.into();
        let default_device = AudioDeviceDescription {
            id: "mock-device-0".into(),
            name: name_str.clone(),
            backend: kind,
            is_default: true,
            is_exclusive: kind.is_exclusive(),
            supported_sample_rates: vec![44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 768000],
            supported_bit_depths: vec![16, 24, 32],
            supports_native_dsd: true,
        };

        Self {
            name: name_str,
            kind,
            state: BackendState::Uninitialized,
            config: None,
            devices: vec![default_device],
            current_device_idx: 0,
            recorded_f32: Vec::new(),
            recorded_f64: Vec::new(),
            recorded_dsd: Vec::new(),
            frames_written: 0,
            underflows: 0,
            fail_on_open: false,
            fail_on_start: false,
        }
    }

    pub fn set_devices(&mut self, devices: Vec<AudioDeviceDescription>) {
        self.devices = devices;
        self.current_device_idx = 0;
    }

    pub fn set_fail_on_open(&mut self, fail: bool) {
        self.fail_on_open = fail;
    }

    pub fn set_fail_on_start(&mut self, fail: bool) {
        self.fail_on_start = fail;
    }

    pub fn simulate_underflow(&mut self, count: u64) {
        self.underflows += count;
    }

    pub fn recorded_f32(&self) -> &[f32] {
        &self.recorded_f32
    }

    pub fn recorded_f64(&self) -> &[f64] {
        &self.recorded_f64
    }

    pub fn recorded_dsd(&self) -> &[u8] {
        &self.recorded_dsd
    }

    pub fn clear_recorded(&mut self) {
        self.recorded_f32.clear();
        self.recorded_f64.clear();
        self.recorded_dsd.clear();
        self.frames_written = 0;
    }

    pub fn assert_bit_perfect_dsd(&self, expected: &[u8]) {
        assert_eq!(
            self.recorded_dsd.as_slice(),
            expected,
            "Recorded DSD bytes do not match expected bit-perfect stream"
        );
    }

    pub fn assert_exact_f64(&self, expected: &[f64], tolerance: f64) {
        assert_eq!(
            self.recorded_f64.len(),
            expected.len(),
            "Sample count mismatch in recorded f64 buffer"
        );
        for (i, (&actual, &exp)) in self.recorded_f64.iter().zip(expected.iter()).enumerate() {
            assert!(
                (actual - exp).abs() <= tolerance,
                "Sample mismatch at index {i}: actual={actual}, expected={exp}, diff={}",
                (actual - exp).abs()
            );
        }
    }
}

impl AudioOutputBackend for MockBackend {
    fn name(&self) -> &str {
        &self.name
    }

    fn backend_kind(&self) -> OutputBackendKind {
        self.kind
    }

    fn current_device(&self) -> Option<&AudioDeviceDescription> {
        self.devices.get(self.current_device_idx)
    }

    fn state(&self) -> BackendState {
        self.state
    }

    fn list_devices(&self) -> Result<Vec<AudioDeviceDescription>, BackendError> {
        Ok(self.devices.clone())
    }

    fn is_format_supported(&self, format: &AudioFormat) -> bool {
        let dev = match self.current_device() {
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
        if self.fail_on_open {
            self.state = BackendState::Error;
            return Err(BackendError::DriverError("Simulated open driver failure".into()));
        }

        if !self.is_format_supported(&config.format) {
            return Err(BackendError::UnsupportedFormat(config.format.clone()));
        }

        if !BackendConfig::is_valid_buffer_size(config.buffer_frames) {
            return Err(BackendError::InvalidBufferSize(config.buffer_frames));
        }

        self.config = Some(config.clone());
        self.state = BackendState::Ready;
        tracing::trace!("MockBackend opened with config: {:?}", self.config);
        Ok(())
    }

    fn start(&mut self) -> Result<(), BackendError> {
        if self.state != BackendState::Ready && self.state != BackendState::Stopped {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }

        if self.fail_on_start {
            self.state = BackendState::Error;
            return Err(BackendError::DriverError("Simulated start driver failure".into()));
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

        self.recorded_f32.extend_from_slice(frames);
        self.frames_written += frame_count as u64;
        Ok(frame_count)
    }

    fn write_interleaved_f64(&mut self, frames: &[f64]) -> Result<usize, BackendError> {
        if self.state != BackendState::Playing {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }

        let ch = self.config.as_ref().map(|c| c.format.channels as usize).unwrap_or(2).max(1);
        let frame_count = frames.len() / ch;

        self.recorded_f64.extend_from_slice(frames);
        self.frames_written += frame_count as u64;
        Ok(frame_count)
    }

    fn write_native_dsd(&mut self, bytes: &[u8]) -> Result<usize, BackendError> {
        if self.state != BackendState::Playing {
            return Err(BackendError::InvalidState(format!("{:?}", self.state)));
        }

        self.recorded_dsd.extend_from_slice(bytes);
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
