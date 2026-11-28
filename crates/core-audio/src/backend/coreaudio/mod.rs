use std::sync::Arc;
use std::time::Duration;

use core_types::{AudioDeviceCapabilities, DeviceTransportKind, OutputBackendKind, OutputMode};

use crate::backend::device_fsm::{OutputDeviceFsm, OutputDeviceState};
use crate::backend::{PullAudioBackend, PullStreamConfig};
use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::RtTelemetry;

#[cfg(target_os = "macos")]
mod macos_hal;

/// Platform-isolated macOS CoreAudio HAL / Hog Mode output backend.
///
/// - On `macos`, acquires exclusive DAC access via `kAudioDevicePropertyHogMode` (`'oink'`),
///   switches hardware clock rate via `kAudioDevicePropertyNominalSampleRate` (`'nsrt'`),
///   and renders audio from an `SpscRingBuffer<u8>` inside a real-time CoreAudio IOProc
///   with strictly zero locks, zero heap allocations, and zero logging.
/// - On non-macOS targets, exposes the identical type surface and FSM lifecycle cleanly
///   so cross-platform builds compile with zero warnings or `#[cfg]` leaks into `engine/`.
pub struct CoreAudioBackend {
    name: String,
    fsm: OutputDeviceFsm,
    telemetry: Arc<RtTelemetry>,
    active_config: Option<PullStreamConfig>,
    hog_mode_active: bool,
    #[cfg(target_os = "macos")]
    active_handle: Option<macos_hal::CoreAudioActiveHandle>,
    #[cfg(not(target_os = "macos"))]
    active_handle: Option<()>,
}

impl Default for CoreAudioBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl CoreAudioBackend {
    pub fn new() -> Self {
        Self::with_guard_delay(crate::backend::device_fsm::DEFAULT_POST_RELEASE_GUARD_DELAY)
    }

    pub fn with_guard_delay(guard_delay: Duration) -> Self {
        Self {
            name: "macOS CoreAudio Hog Mode".to_string(),
            fsm: OutputDeviceFsm::with_guard_delay(guard_delay),
            telemetry: Arc::new(RtTelemetry::new()),
            active_config: None,
            hog_mode_active: false,
            active_handle: None,
        }
    }

    pub fn fsm(&self) -> &OutputDeviceFsm {
        &self.fsm
    }

    pub fn set_post_release_guard_delay(&mut self, delay: Duration) {
        self.fsm.set_post_release_guard_delay(delay);
    }

    pub fn is_hog_mode_active(&self) -> bool {
        self.hog_mode_active
    }

    pub fn active_config(&self) -> Option<&PullStreamConfig> {
        self.active_config.as_ref()
    }
}

/// Enumerates CoreAudio hardware output devices on macOS; returns empty on non-macOS hosts.
pub fn enumerate_coreaudio_devices() -> Vec<AudioDeviceCapabilities> {
    #[cfg(target_os = "macos")]
    {
        macos_hal::enumerate_devices()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Vec::new()
    }
}

impl PullAudioBackend for CoreAudioBackend {
    fn name(&self) -> &str {
        &self.name
    }

    fn state(&self) -> OutputDeviceState {
        self.fsm.state()
    }

    fn capabilities(&self) -> AudioDeviceCapabilities {
        #[cfg(target_os = "macos")]
        {
            if let Some(first) = macos_hal::enumerate_devices().into_iter().next() {
                return first;
            }
        }
        AudioDeviceCapabilities {
            device_id: "coreaudio::default".to_string(),
            name: self.name.clone(),
            backend: OutputBackendKind::MacOsCoreAudioHog,
            transport: DeviceTransportKind::UsbDac,
            is_default: cfg!(target_os = "macos"),
            is_exclusive: cfg!(target_os = "macos"),
            supported_sample_rates: vec![
                44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
            ],
            supported_bit_depths: vec![16, 24, 32],
            supported_container_bits: vec![16, 24, 32],
            supported_channels: vec![2],
            supported_output_modes: vec![
                OutputMode::WasapiExclusive,
                OutputMode::DoPOverWasapiExclusive,
                OutputMode::DsdToPcm,
            ],
            supports_native_dsd: false,
            supports_dop: cfg!(target_os = "macos"),
            supports_float32: true,
            max_dsd_rate: None,
            asio_available: false,
            asio_driver_name: None,
            exclusive_available: cfg!(target_os = "macos"),
            probe_note: if cfg!(target_os = "macos") {
                None
            } else {
                Some("CoreAudio HAL is only available on macOS".to_string())
            },
        }
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
        #[cfg(target_os = "macos")]
        {
            let _ = crate::visualizer::init_global_tap();
            let tel = Arc::clone(&self.telemetry);
            let cfg_clone = config.clone();
            let mut consumer_opt = Some(consumer);

            let new_handle = self.fsm.reconfigure_sequence(
                &mut self.active_handle,
                config.strict_bit_perfect,
                |h| {
                    h.stop_io_proc();
                },
                || {
                    let cons = consumer_opt.take().ok_or_else(|| {
                        BackendError::InvalidState("CoreAudio consumer already consumed".into())
                    })?;
                    macos_hal::CoreAudioActiveHandle::open_and_start(
                        &cfg_clone,
                        cons,
                        Arc::clone(&tel),
                    )
                },
                None::<fn(&BackendError) -> Result<macos_hal::CoreAudioActiveHandle, BackendError>>,
            )?;

            self.hog_mode_active = new_handle.hog_acquired;
            self.active_handle = Some(new_handle);
            self.active_config = Some(config);
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = consumer;
            let res = self.fsm.reconfigure_sequence(
                &mut self.active_handle,
                config.strict_bit_perfect,
                |_| {},
                || {
                    Err(BackendError::DriverError(
                        "CoreAudio backend is only available on macOS".into(),
                    ))
                },
                None::<fn(&BackendError) -> Result<(), BackendError>>,
            );
            self.hog_mode_active = false;
            self.active_config = None;
            res
        }
    }

    fn stop_and_release(&mut self) -> Result<(), BackendError> {
        #[cfg(target_os = "macos")]
        {
            let res = self
                .fsm
                .stop_and_release_sequence(&mut self.active_handle, |h| h.stop_io_proc());
            self.hog_mode_active = false;
            self.active_config = None;
            res
        }
        #[cfg(not(target_os = "macos"))]
        {
            let res = self
                .fsm
                .stop_and_release_sequence(&mut self.active_handle, |_| {});
            self.hog_mode_active = false;
            self.active_config = None;
            res
        }
    }
}
