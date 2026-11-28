pub mod asio;
#[cfg(target_os = "windows")]
pub mod asio_win;
pub mod coreaudio;
pub mod cpal_shared;
pub mod device_fsm;
pub mod device_manager;
#[cfg(target_os = "windows")]
pub mod device_watcher_win;
pub mod mock;
pub mod wasapi;
#[cfg(target_os = "windows")]
pub mod wasapi_win;

use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::RtTelemetry;
use crate::verification::WireSampleFormat;
pub use core_types::AudioDeviceDescription;
use core_types::{AudioDeviceCapabilities, AudioFormat, OutputBackendKind};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub use coreaudio::{CoreAudioBackend, enumerate_coreaudio_devices};
pub use cpal_shared::{
    CPAL_RT_CHUNK_SAMPLES, enumerate_cpal_devices, rank_sample_format, render_cpal_output_chunked,
    select_best_config_index,
};
pub use device_fsm::{DEFAULT_POST_RELEASE_GUARD_DELAY, OutputDeviceFsm, OutputDeviceState};
pub use device_manager::{
    AudioDeviceManager, AudioFormatManager, DeviceExtraMeta, NegotiatedFormat,
};
pub use mock::MockAudioBackend;

/// Platform-agnostic hardware endpoint and OS power lifecycle events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceEvent {
    DefaultRenderChanged(String),
    DeviceRemoved(String),
    DeviceAdded(String),
    SystemSuspend,
    SystemResume,
}

/// Deterministic coalescing debouncer for OS audio device and suspend/resume event storms.
///
/// - `DeviceRemoved` and `SystemSuspend` fire **immediately** (0ms) so active playback can protect
///   hardware threads without delay.
/// - `DefaultRenderChanged` coalesces over 250ms (default).
/// - `DeviceAdded` (USB DAC replug) coalesces per endpoint over 500ms (default).
/// - `SystemResume` (`PBT_APMRESUMEAUTOMATIC` + `PBT_APMRESUMESUSPEND`) coalesces over 800ms
///   (default) so USB host controllers finish re-enumerating audio interfaces.
#[derive(Debug, Clone)]
pub struct DeviceEventDebouncer {
    default_switch_delay: Duration,
    replug_delay: Duration,
    resume_delay: Duration,
    pending_default: Option<(String, Instant)>,
    pending_added: BTreeMap<String, Instant>,
    pending_resume: Option<Instant>,
}

impl Default for DeviceEventDebouncer {
    fn default() -> Self {
        Self::new()
    }
}

impl DeviceEventDebouncer {
    pub const DEFAULT_SWITCH_DELAY: Duration = Duration::from_millis(250);
    pub const DEFAULT_REPLUG_DELAY: Duration = Duration::from_millis(500);
    pub const DEFAULT_RESUME_DELAY: Duration = Duration::from_millis(800);

    pub fn new() -> Self {
        Self::with_delays(
            Self::DEFAULT_SWITCH_DELAY,
            Self::DEFAULT_REPLUG_DELAY,
            Self::DEFAULT_RESUME_DELAY,
        )
    }

    pub fn with_delays(
        default_switch_delay: Duration,
        replug_delay: Duration,
        resume_delay: Duration,
    ) -> Self {
        Self {
            default_switch_delay,
            replug_delay,
            resume_delay,
            pending_default: None,
            pending_added: BTreeMap::new(),
            pending_resume: None,
        }
    }

    /// Ingests a raw OS event at timestamp `now`.
    /// Returns `Some(event)` immediately for urgent events (`DeviceRemoved`, `SystemSuspend`),
    /// or `None` when the event has been coalesced into the debounce window.
    pub fn push(&mut self, event: DeviceEvent, now: Instant) -> Option<DeviceEvent> {
        match event {
            DeviceEvent::SystemSuspend => {
                self.pending_resume = None;
                Some(DeviceEvent::SystemSuspend)
            }
            DeviceEvent::DeviceRemoved(id) => {
                self.pending_added.remove(&id);
                if self
                    .pending_default
                    .as_ref()
                    .is_some_and(|(pending_id, _)| pending_id == &id)
                {
                    self.pending_default = None;
                }
                Some(DeviceEvent::DeviceRemoved(id))
            }
            DeviceEvent::DefaultRenderChanged(id) => {
                self.pending_default = Some((id, now + self.default_switch_delay));
                None
            }
            DeviceEvent::DeviceAdded(id) => {
                self.pending_added.insert(id, now + self.replug_delay);
                None
            }
            DeviceEvent::SystemResume => {
                self.pending_resume = Some(now + self.resume_delay);
                None
            }
        }
    }

    /// Emits all debounced events whose deadlines have elapsed as of `now` in deterministic order
    /// (`SystemResume` -> `DeviceAdded` -> `DefaultRenderChanged`).
    pub fn poll_due(&mut self, now: Instant) -> Vec<DeviceEvent> {
        let mut due = Vec::new();
        if self.pending_resume.is_some_and(|dl| now >= dl) {
            self.pending_resume = None;
            due.push(DeviceEvent::SystemResume);
        }

        let due_added: Vec<String> = self
            .pending_added
            .iter()
            .filter(|&(_, &dl)| now >= dl)
            .map(|(id, _)| id.clone())
            .collect();
        for id in due_added {
            self.pending_added.remove(&id);
            due.push(DeviceEvent::DeviceAdded(id));
        }

        if self
            .pending_default
            .as_ref()
            .is_some_and(|(_, dl)| now >= *dl)
            && let Some((id, _)) = self.pending_default.take()
        {
            due.push(DeviceEvent::DefaultRenderChanged(id));
        }
        due
    }

    /// Returns the earliest pending debounce deadline, or `None` if idle.
    pub fn next_deadline(&self) -> Option<Instant> {
        let mut earliest = self.pending_resume;
        if let Some((_, dl)) = &self.pending_default {
            earliest = Some(earliest.map_or(*dl, |cur| cur.min(*dl)));
        }
        for &dl in self.pending_added.values() {
            earliest = Some(earliest.map_or(dl, |cur| cur.min(dl)));
        }
        earliest
    }
}

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

/// Configuration for opening or reconfiguring a pull-based hard real-time [`PullAudioBackend`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullStreamConfig {
    pub device_id: Option<String>,
    pub sample_rate: u32,
    pub channels: u16,
    pub wire_format: WireSampleFormat,
    pub buffer_frames: u32,
    pub strict_bit_perfect: bool,
}

/// Unified pull-based hardware audio output contract enforcing [`OutputDeviceState`] lifecycle,
/// SPSC ring-buffer consumption, and lock-free [`RtTelemetry`].
pub trait PullAudioBackend: Send {
    /// Friendly backend name.
    fn name(&self) -> &str;

    /// Current explicit hardware lifecycle FSM state.
    fn state(&self) -> OutputDeviceState;

    /// Hardware capabilities of the active or target device.
    fn capabilities(&self) -> AudioDeviceCapabilities;

    /// Lock-free real-time telemetry handle shared with the audio render callback.
    fn telemetry(&self) -> Arc<RtTelemetry>;

    /// Opens and starts the pull-based audio stream consuming from `consumer`.
    fn open_stream(
        &mut self,
        config: PullStreamConfig,
        consumer: Consumer<u8>,
    ) -> Result<(), BackendError>;

    /// Executes the strict exclusive-mode reconfigure sequence:
    /// mute/stop -> drop handle -> post-release guard delay -> query & reopen.
    fn reconfigure(
        &mut self,
        config: PullStreamConfig,
        consumer: Consumer<u8>,
    ) -> Result<(), BackendError>;

    /// Stops playback, releases the exclusive hardware handle, and waits the guard delay.
    fn stop_and_release(&mut self) -> Result<(), BackendError>;
}
