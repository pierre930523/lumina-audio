use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use core_types::{
    AudioDeviceCapabilities, DeviceTransportKind, DsdRate, OutputBackendKind, OutputMode,
};

use super::super::device_fsm::{OutputDeviceFsm, OutputDeviceState};
use super::super::{PullAudioBackend, PullStreamConfig};
use super::processor::{DEFAULT_MOCK_CAPTURE_BYTES, MockRtProcessor};
use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::{RtErrorCode, RtTelemetry};

enum MockStreamRunner {
    Inline(MockRtProcessor),
    Threaded {
        stop_flag: Arc<AtomicBool>,
        handle: JoinHandle<MockRtProcessor>,
    },
}

struct MockActiveStream {
    config: PullStreamConfig,
    runner: Option<MockStreamRunner>,
}

impl MockActiveStream {
    fn stop_and_collect_capture(&mut self) -> Vec<u8> {
        match self.runner.take() {
            Some(MockStreamRunner::Inline(proc)) => {
                proc.capture_buf[..proc.capture_written].to_vec()
            }
            Some(MockStreamRunner::Threaded { stop_flag, handle }) => {
                stop_flag.store(true, Ordering::SeqCst);
                match handle.join() {
                    Ok(proc) => proc.capture_buf[..proc.capture_written].to_vec(),
                    Err(_) => Vec::new(),
                }
            }
            None => Vec::new(),
        }
    }
}

/// Pull-based, RT-safe mock audio backend implementing [`OutputDeviceFsm`] and [`PullAudioBackend`]
/// for deterministic Bit-Perfect, underrun, rapid-skip, and exclusive-mode lifecycle testing.
pub struct MockAudioBackend {
    name: String,
    capabilities: AudioDeviceCapabilities,
    fsm: OutputDeviceFsm,
    telemetry: Arc<RtTelemetry>,
    capture_capacity_bytes: usize,
    active_stream: Option<MockActiveStream>,
    archived_capture: Vec<u8>,
    remaining_open_failures: u32,
}

impl Default for MockAudioBackend {
    fn default() -> Self {
        Self::new("Mock RT Pull DAC")
    }
}

impl MockAudioBackend {
    pub fn new(name: impl Into<String>) -> Self {
        let name_str = name.into();
        let capabilities = AudioDeviceCapabilities {
            device_id: "mock-rt-dac-0".to_string(),
            name: name_str.clone(),
            backend: OutputBackendKind::WindowsWasapiExclusive,
            transport: DeviceTransportKind::Virtual,
            is_default: true,
            is_exclusive: true,
            supported_sample_rates: vec![
                44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600,
                768_000, 2_822_400, 5_644_800, 11_289_600, 22_579_200,
            ],
            supported_bit_depths: vec![16, 24, 32],
            supported_container_bits: vec![8, 16, 24, 32, 64],
            supported_channels: vec![1, 2, 4, 6, 8],
            supported_output_modes: vec![
                OutputMode::VirtualMock,
                OutputMode::WasapiExclusive,
                OutputMode::AsioPcm,
                OutputMode::AsioNativeDsd,
                OutputMode::DoPOverWasapiExclusive,
                OutputMode::DoPOverAsio,
            ],
            supports_native_dsd: true,
            supports_dop: true,
            supports_float32: true,
            max_dsd_rate: Some(DsdRate::Dsd512),
            asio_available: true,
            asio_driver_name: Some(name_str.clone()),
            exclusive_available: true,
            probe_note: Some("Deterministic RT pull mock backend".to_string()),
        };

        Self {
            name: name_str,
            capabilities,
            fsm: OutputDeviceFsm::with_guard_delay(Duration::from_millis(1)),
            telemetry: Arc::new(RtTelemetry::new()),
            capture_capacity_bytes: DEFAULT_MOCK_CAPTURE_BYTES,
            active_stream: None,
            archived_capture: Vec::new(),
            remaining_open_failures: 0,
        }
    }

    pub fn with_guard_delay(mut self, delay: Duration) -> Self {
        self.fsm.set_post_release_guard_delay(delay);
        self
    }

    pub fn with_capture_capacity(mut self, bytes: usize) -> Self {
        self.capture_capacity_bytes = bytes.max(4096);
        self
    }

    pub fn with_capabilities(mut self, capabilities: AudioDeviceCapabilities) -> Self {
        self.capabilities = capabilities;
        self
    }

    pub fn set_post_release_guard_delay(&mut self, delay: Duration) {
        self.fsm.set_post_release_guard_delay(delay);
    }

    /// Injects `fail_count` consecutive open/reconfigure failures for fault-recovery testing.
    pub fn inject_open_failure(&mut self, fail_count: u32) {
        self.remaining_open_failures = fail_count;
    }

    pub fn state_history(&self) -> &[OutputDeviceState] {
        self.fsm.transition_history()
    }

    pub fn handle_drop_count(&self) -> u64 {
        self.fsm.handle_drop_count()
    }

    pub fn reconfigure_count(&self) -> u64 {
        self.fsm.reconfigure_count()
    }

    pub fn guard_delay_sleeps(&self) -> u64 {
        self.fsm.guard_delay_sleeps()
    }

    pub fn last_guard_delay_elapsed(&self) -> Option<Duration> {
        self.fsm.last_guard_delay_elapsed()
    }

    pub fn active_config(&self) -> Option<&PullStreamConfig> {
        self.active_stream.as_ref().map(|s| &s.config)
    }

    /// Deterministic single-period RT callback execution (when not running a background thread).
    /// Returns the number of frames rendered into the pre-allocated capture buffer.
    pub fn render_once(&mut self, frames: usize) -> Result<usize, BackendError> {
        let Some(active) = self.active_stream.as_mut() else {
            return Err(BackendError::InvalidState(
                "MockAudioBackend has no active stream".into(),
            ));
        };
        match active.runner.as_mut() {
            Some(MockStreamRunner::Inline(proc)) => Ok(proc.render_period_rt(frames)),
            Some(MockStreamRunner::Threaded { .. }) => Err(BackendError::InvalidState(
                "Cannot call render_once while mock RT render thread is running".into(),
            )),
            None => Err(BackendError::InvalidState(
                "MockAudioBackend runner already stopped".into(),
            )),
        }
    }

    /// Spawns a high-frequency OS render thread pulling `config.buffer_frames` every `period`.
    pub fn start_render_thread(&mut self, period: Duration) -> Result<(), BackendError> {
        let Some(active) = self.active_stream.as_mut() else {
            return Err(BackendError::InvalidState(
                "MockAudioBackend has no active stream".into(),
            ));
        };
        let proc = match active.runner.take() {
            Some(MockStreamRunner::Inline(p)) => p,
            Some(existing @ MockStreamRunner::Threaded { .. }) => {
                active.runner = Some(existing);
                return Ok(());
            }
            None => {
                return Err(BackendError::InvalidState(
                    "MockAudioBackend runner already stopped".into(),
                ));
            }
        };
        let stop_flag = Arc::new(AtomicBool::new(false));
        let th_stop = Arc::clone(&stop_flag);
        let period_frames = active.config.buffer_frames.max(32) as usize;
        let sleep_dur = period.max(Duration::from_micros(250));

        let handle = thread::Builder::new()
            .name("lumina-mock-rt-dac".to_string())
            .spawn(move || {
                let mut rt_proc = proc;
                while !th_stop.load(Ordering::Acquire) {
                    let _ = rt_proc.render_period_rt(period_frames);
                    thread::sleep(sleep_dur);
                }
                rt_proc
            })
            .map_err(|e| {
                BackendError::DriverError(format!("Failed to spawn mock RT thread: {e}"))
            })?;

        active.runner = Some(MockStreamRunner::Threaded { stop_flag, handle });
        Ok(())
    }

    /// Stops the background render thread (if running) and returns to inline deterministic mode.
    pub fn stop_render_thread(&mut self) {
        if let Some(active) = self.active_stream.as_mut()
            && matches!(active.runner, Some(MockStreamRunner::Threaded { .. }))
            && let Some(MockStreamRunner::Threaded { stop_flag, handle }) = active.runner.take()
        {
            stop_flag.store(true, Ordering::SeqCst);
            if let Ok(proc) = handle.join() {
                active.runner = Some(MockStreamRunner::Inline(proc));
            }
        }
    }

    /// Returns captured hardware wire bytes (live while inline, or archived after `stop_and_release()`).
    pub fn captured_wire_bytes(&self) -> &[u8] {
        if let Some(active) = &self.active_stream
            && let Some(MockStreamRunner::Inline(proc)) = &active.runner
        {
            return &proc.capture_buf[..proc.capture_written];
        }
        &self.archived_capture
    }
}

impl PullAudioBackend for MockAudioBackend {
    fn name(&self) -> &str {
        &self.name
    }

    fn state(&self) -> OutputDeviceState {
        self.fsm.state()
    }

    fn capabilities(&self) -> AudioDeviceCapabilities {
        self.capabilities.clone()
    }

    fn telemetry(&self) -> Arc<RtTelemetry> {
        Arc::clone(&self.telemetry)
    }

    fn open_stream(
        &mut self,
        config: PullStreamConfig,
        consumer: Consumer<u8>,
    ) -> Result<(), BackendError> {
        self.reconfigure(config, consumer)
    }

    fn reconfigure(
        &mut self,
        config: PullStreamConfig,
        consumer: Consumer<u8>,
    ) -> Result<(), BackendError> {
        let capture_cap = self.capture_capacity_bytes;
        let tel = Arc::clone(&self.telemetry);
        let cfg_clone = config.clone();
        let mut consumer_opt = Some(consumer);
        let mut captured_prev = Vec::new();
        let remaining_failures = &mut self.remaining_open_failures;

        let new_stream = self.fsm.reconfigure_sequence(
            &mut self.active_stream,
            config.strict_bit_perfect,
            |old| {
                captured_prev = old.stop_and_collect_capture();
            },
            || {
                if *remaining_failures > 0 {
                    *remaining_failures -= 1;
                    tel.record_error_rt(RtErrorCode::StreamStartFailed, -1);
                    return Err(BackendError::DriverError(
                        "Injected MockAudioBackend open failure".into(),
                    ));
                }
                let cons = consumer_opt.take().ok_or_else(|| {
                    BackendError::InvalidState("MockAudioBackend consumer already consumed".into())
                })?;
                let proc =
                    MockRtProcessor::new(cfg_clone.clone(), cons, Arc::clone(&tel), capture_cap);
                Ok(MockActiveStream {
                    config: cfg_clone.clone(),
                    runner: Some(MockStreamRunner::Inline(proc)),
                })
            },
            None::<fn(&BackendError) -> Result<MockActiveStream, BackendError>>,
        )?;

        if !captured_prev.is_empty() {
            self.archived_capture = captured_prev;
        }
        self.active_stream = Some(new_stream);
        Ok(())
    }

    fn stop_and_release(&mut self) -> Result<(), BackendError> {
        let mut captured = Vec::new();
        let res = self
            .fsm
            .stop_and_release_sequence(&mut self.active_stream, |old| {
                captured = old.stop_and_collect_capture();
            });
        self.archived_capture = captured;
        res
    }
}

impl Drop for MockAudioBackend {
    fn drop(&mut self) {
        let _ = self.stop_and_release();
    }
}
