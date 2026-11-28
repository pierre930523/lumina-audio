//! Output device enumeration, selection, capability queries, and DSP configuration APIs.

use std::sync::atomic::Ordering;
use std::sync::mpsc;

use core_types::{
    AudioDeviceCapabilities, AudioDeviceDescription, AudioEngineOutputInfo,
    DspPipelineConfig as SharedDspConfig, OutputBackendKind, PlaybackLifecycleState,
};

use crate::backend::cpal_shared::enumerate_cpal_devices;
use crate::backend::device_manager::{AudioDeviceManager, DeviceExtraMeta};
use crate::engine::AudioPlayer;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dsp_helpers::validate_shared_dsp_config;
use crate::engine::session::{
    CLOCK_SRC_UNINIT, resolve_target_capabilities, virtual_exclusive_device,
};
use crate::engine::types::{VIRTUAL_DEVICE_ID, VIRTUAL_DEVICE_NAME, default_shared_dsp_config};
use crate::error::{BackendError, CoreAudioError};

impl AudioPlayer {
    pub fn list_device_capabilities(&self) -> Vec<AudioDeviceCapabilities> {
        self.list_device_capabilities_with_meta()
            .into_iter()
            .map(|(cap, _)| cap)
            .collect()
    }

    pub fn list_device_capabilities_with_meta(
        &self,
    ) -> Vec<(AudioDeviceCapabilities, DeviceExtraMeta)> {
        let mut caps = if self.inner.headless {
            vec![(
                AudioDeviceManager::virtual_device_capabilities(),
                DeviceExtraMeta {
                    is_os_default: true,
                    is_hdmi: false,
                    hardware_supports_exclusive: true,
                    buffer_size_supported: true,
                    min_buffer_frames: Some(64),
                    max_buffer_frames: Some(4096),
                    default_buffer_frames: Some(512),
                    buffer_granularity: None,
                },
            )]
        } else {
            AudioDeviceManager::list_devices_with_meta()
        };
        if caps.is_empty() {
            caps.push((
                AudioDeviceManager::virtual_device_capabilities(),
                DeviceExtraMeta::default(),
            ));
        }
        caps
    }

    pub fn output_info(&self) -> AudioEngineOutputInfo {
        if let Ok(g) = self.inner.verification.read()
            && let Some((ref engine, ref api, ref dev)) = *g
        {
            return engine.snapshot(api, dev);
        }

        let mut info = AudioEngineOutputInfo::default();
        let (sel_id, sel_backend) = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));
        let caps = resolve_target_capabilities(&self.inner, sel_id.as_deref(), sel_backend);
        let (backend, dev_name) = self.preview_output_target();
        let policy = self.engine_policy();
        let is_shared = backend == OutputBackendKind::WindowsWasapiShared;
        info.output.selected_device = dev_name;
        info.output.transport_kind = caps.transport.label_zh().to_string();
        info.output.audio_api = format!("{backend:?}");
        info.output.buffer_size_frames = policy.preferred_buffer_frames;
        info.output.output_mode = if is_shared {
            "WASAPI Shared (Idle)".to_string()
        } else if policy.strict_bit_perfect {
            "Strict Bit-Perfect Armed (Idle)".to_string()
        } else {
            "Idle".to_string()
        };
        info.output.dsp_status = if self.is_dsp_bypassed() {
            "Bypassed".to_string()
        } else {
            "Enabled".to_string()
        };
        info.output.software_volume_status =
            if policy.strict_bit_perfect || (self.volume() - 1.0).abs() < 1e-6 {
                "Disabled (Unity 1.0x)".to_string()
            } else {
                "Active Attenuated".to_string()
            };
        info.output.strict_mode = !is_shared && policy.strict_bit_perfect;
        info.output.hardware_volume_recommended = !is_shared && policy.strict_bit_perfect;
        info
    }

    pub fn get_dsp_config(&self) -> SharedDspConfig {
        let mut cfg = self
            .inner
            .dsp_config
            .read()
            .map(|g| g.clone())
            .unwrap_or_else(|_| default_shared_dsp_config());
        cfg.bypass = self.is_dsp_bypassed();
        cfg
    }

    pub fn set_dsp_config(&self, mut config: SharedDspConfig) -> Result<(), CoreAudioError> {
        validate_shared_dsp_config(&config)?;
        self.inner
            .saved_normal_dsp_bypass
            .store(config.bypass, Ordering::SeqCst);
        if self.is_strict_bit_perfect() {
            // Preserve user's preset bands, but enforce hard bypass while Strict Mode is active
            config.bypass = true;
            self.inner.dsp_bypassed.store(true, Ordering::SeqCst);
        } else {
            self.inner
                .dsp_bypassed
                .store(config.bypass, Ordering::SeqCst);
        }
        if let Ok(mut guard) = self.inner.dsp_config.write() {
            *guard = config;
        }
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    pub fn set_dsp_bypass(&self, bypass: bool) {
        self.inner
            .saved_normal_dsp_bypass
            .store(bypass, Ordering::SeqCst);
        let effective = if self.is_strict_bit_perfect() {
            true
        } else {
            bypass
        };
        self.inner.dsp_bypassed.store(effective, Ordering::SeqCst);
        if let Ok(mut guard) = self.inner.dsp_config.write() {
            guard.bypass = effective;
        }
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
    }

    pub fn toggle_dsp_bypass(&self) -> bool {
        if self.is_strict_bit_perfect() {
            // Strict Mode enforces hard bypass; toggling DSP bypass leaves Strict Mode locked
            self.inner.dsp_bypassed.store(true, Ordering::SeqCst);
            return true;
        }
        let prev = self.inner.dsp_bypassed.fetch_xor(true, Ordering::SeqCst);
        let new_val = !prev;
        self.inner
            .saved_normal_dsp_bypass
            .store(new_val, Ordering::SeqCst);
        if let Ok(mut guard) = self.inner.dsp_config.write() {
            guard.bypass = new_val;
        }
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        new_val
    }

    pub fn is_dsp_bypassed(&self) -> bool {
        self.inner.dsp_bypassed.load(Ordering::SeqCst)
    }

    pub fn list_output_devices(&self) -> Vec<AudioDeviceDescription> {
        let mut devices = Vec::new();
        if !self.inner.headless {
            for cap in AudioDeviceManager::list_devices() {
                if cap.backend == OutputBackendKind::WindowsAsio && !cap.asio_available {
                    continue;
                }
                if !devices.iter().any(|d: &AudioDeviceDescription| {
                    d.id == cap.device_id && d.backend == cap.backend
                }) {
                    devices.push(AudioDeviceDescription {
                        id: cap.device_id,
                        name: cap.name,
                        backend: cap.backend,
                        is_default: cap.is_default,
                        is_exclusive: cap.is_exclusive,
                        supported_sample_rates: cap.supported_sample_rates,
                        supported_bit_depths: cap.supported_bit_depths,
                        supports_native_dsd: cap.supports_native_dsd,
                    });
                }
            }
            if devices.is_empty() {
                devices = enumerate_cpal_devices();
            }
        }
        if self.inner.headless || devices.is_empty() {
            let has_virtual = devices.iter().any(|d| d.id == VIRTUAL_DEVICE_ID);
            if !has_virtual {
                devices.push(virtual_exclusive_device(devices.is_empty()));
            }
        }
        devices
    }

    pub fn select_output_device(
        &self,
        device_id: Option<&str>,
        backend: Option<OutputBackendKind>,
    ) -> Result<(), CoreAudioError> {
        let clean_id = device_id
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != "__system_output__")
            .map(str::to_string);

        let effective_backend = backend.or_else(|| {
            clean_id.as_deref().and_then(|id| {
                if id.starts_with("wasapi-shared::") {
                    Some(OutputBackendKind::WindowsWasapiShared)
                } else if id.starts_with("asio::") {
                    Some(OutputBackendKind::WindowsAsio)
                } else {
                    None
                }
            })
        });

        if clean_id.as_deref() == Some(VIRTUAL_DEVICE_ID) {
            if !self.inner.headless
                && !self
                    .list_output_devices()
                    .iter()
                    .all(|d| d.id == VIRTUAL_DEVICE_ID)
            {
                return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
                    VIRTUAL_DEVICE_ID.to_string(),
                )));
            }
        } else if let Some(ref id) = clean_id {
            let available = self.list_output_devices();
            let caps = self.list_device_capabilities();
            let raw_id = AudioDeviceManager::strip_mode_prefix(id);
            let matched_cap = caps.iter().find(|c| {
                let id_match = c.device_id == *id
                    || AudioDeviceManager::strip_mode_prefix(&c.device_id) == raw_id
                    || c.name == *id;
                let bk_match = effective_backend.is_none_or(|bk| c.backend == bk);
                id_match && bk_match
            });

            if let Some(cap) = matched_cap {
                if cap.backend == OutputBackendKind::WindowsAsio && !cap.asio_available {
                    return Err(CoreAudioError::Backend(BackendError::DriverError(
                        cap.probe_note.clone().unwrap_or_else(|| {
                            format!(
                                "ASIO driver '{}' is offline or hardware disconnected",
                                cap.name
                            )
                        }),
                    )));
                }
                if cap.backend == OutputBackendKind::WindowsWasapiExclusive
                    && !cap.exclusive_available
                {
                    return Err(CoreAudioError::Backend(BackendError::DeviceInUse));
                }
            } else if !available.iter().any(|d| {
                let id_match =
                    d.id == *id || AudioDeviceManager::strip_mode_prefix(&d.id) == raw_id;
                let bk_match = effective_backend.is_none_or(|bk| d.backend == bk);
                id_match && bk_match
            }) {
                return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
                    id.clone(),
                )));
            }
        }

        let previous = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));
        let prev_strict = self.is_strict_bit_perfect();
        let prev_bypass = self.inner.dsp_bypassed.load(Ordering::SeqCst);
        let prev_vol_bits = self.inner.volume_bits.load(Ordering::Relaxed);

        if let Ok(mut guard) = self.inner.selected_output.write() {
            *guard = (clean_id, effective_backend);
        }
        self.inner
            .cached_clock_source
            .store(CLOCK_SRC_UNINIT, Ordering::Release);

        // Switching to explicit WASAPI Shared clears Strict Bit-Perfect Mode before a single
        // RerouteOutput so Shared playback immediately restores normal volume/DSP rules.
        let cleared_strict_for_shared =
            effective_backend == Some(OutputBackendKind::WindowsWasapiShared) && prev_strict;
        if cleared_strict_for_shared {
            if let Ok(mut p) = self.inner.policy.write() {
                p.strict_bit_perfect = false;
                p.allow_shared_fallback = self
                    .inner
                    .saved_allow_shared_fallback
                    .load(Ordering::SeqCst);
            }
            self.inner.strict_bit_perfect.store(false, Ordering::SeqCst);
            let restored_bypass = self.inner.saved_normal_dsp_bypass.load(Ordering::SeqCst);
            let restored_vol = self.inner.saved_normal_volume_bits.load(Ordering::Relaxed);
            self.inner
                .dsp_bypassed
                .store(restored_bypass, Ordering::SeqCst);
            if let Ok(mut guard) = self.inner.dsp_config.write() {
                guard.bypass = restored_bypass;
            }
            self.inner
                .volume_bits
                .store(restored_vol, Ordering::Relaxed);
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        }

        let was_device_lost = self.inner.device_lost.swap(false, Ordering::SeqCst);
        let state = self.inner.state_code.load(Ordering::SeqCst);
        let is_active_stream = (!self.inner.stopped.load(Ordering::SeqCst)
            && (state == PlaybackLifecycleState::Playing as i32
                || state == PlaybackLifecycleState::Paused as i32))
            || (was_device_lost
                && (state == PlaybackLifecycleState::Paused as i32
                    || state == PlaybackLifecycleState::Error as i32));
        if !is_active_stream {
            if let Ok(mut vw) = self.inner.verification.write() {
                *vw = None;
            }
            if let Ok(mut meta_lock) = self.inner.active_meta.write() {
                *meta_lock = None;
            }
        }
        if was_device_lost {
            self.inner.clear_error_state();
        }

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: was_device_lost,
            })
            .is_ok()
        {
            match ack_rx.recv() {
                Ok(Ok(())) => Ok(()),
                Ok(Err(e)) => {
                    if let Ok(mut guard) = self.inner.selected_output.write() {
                        *guard = previous;
                    }
                    if cleared_strict_for_shared {
                        if let Ok(mut p) = self.inner.policy.write() {
                            p.strict_bit_perfect = prev_strict;
                            if prev_strict {
                                p.allow_shared_fallback = false;
                            }
                        }
                        self.inner
                            .strict_bit_perfect
                            .store(prev_strict, Ordering::SeqCst);
                        self.inner.dsp_bypassed.store(prev_bypass, Ordering::SeqCst);
                        if let Ok(mut guard) = self.inner.dsp_config.write() {
                            guard.bypass = prev_bypass;
                        }
                        self.inner
                            .volume_bits
                            .store(prev_vol_bits, Ordering::Relaxed);
                        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
                    }
                    Err(e)
                }
                Err(_) => Ok(()),
            }
        } else {
            Ok(())
        }
    }

    pub(super) fn preview_output_target(&self) -> (OutputBackendKind, String) {
        let (sel_id, sel_backend) = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));

        if self.inner.headless || sel_id.as_deref() == Some(VIRTUAL_DEVICE_ID) {
            return (
                sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
                VIRTUAL_DEVICE_NAME.to_string(),
            );
        }

        let caps = resolve_target_capabilities(&self.inner, sel_id.as_deref(), sel_backend);
        if sel_id.is_some() {
            return (sel_backend.unwrap_or(caps.backend), caps.name);
        }

        // System Output: follows OS default endpoint and reflects active engine routing mode
        let policy = self.engine_policy();
        let bypassed = self.is_dsp_bypassed();
        let eff_backend = if let Some(bk) = sel_backend {
            bk
        } else if (policy.strict_bit_perfect || bypassed) && caps.exclusive_available {
            OutputBackendKind::WindowsWasapiExclusive
        } else {
            OutputBackendKind::WindowsWasapiShared
        };
        (eff_backend, caps.name)
    }
}
