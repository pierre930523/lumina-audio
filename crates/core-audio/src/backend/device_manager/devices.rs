use std::sync::{Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};

use core_types::{
    AudioDeviceCapabilities, AudioDeviceDescription, AudioDeviceInfo, DeviceTransportKind, DsdRate,
    OutputBackendKind, OutputMode,
};

const DEVICE_PROBE_CACHE_TTL: Duration = Duration::from_secs(5);
type CachedDeviceEntry = (Instant, Vec<(AudioDeviceCapabilities, DeviceExtraMeta)>);
static DEVICE_PROBE_CACHE: OnceLock<RwLock<Option<CachedDeviceEntry>>> = OnceLock::new();
/// Serializes hardware COM/ASIO cache refreshes so concurrent expired callers do not stampede.
static DEVICE_PROBE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

/// Additional hardware probe metadata exposed to UI/FFI without altering shared `core-types`.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct DeviceExtraMeta {
    pub is_os_default: bool,
    pub is_hdmi: bool,
    pub hardware_supports_exclusive: bool,
    pub buffer_size_supported: bool,
    pub min_buffer_frames: Option<u32>,
    pub max_buffer_frames: Option<u32>,
    pub default_buffer_frames: Option<u32>,
    pub buffer_granularity: Option<i32>,
}

/// Phase 7: Intelligent Device Manager combining real Windows WASAPI endpoints
/// (USB DAC / Internal / Headphones / Speakers / HDMI / Bluetooth) and ASIO drivers.
pub struct AudioDeviceManager;

impl AudioDeviceManager {
    pub fn strip_mode_prefix(id: &str) -> &str {
        let trimmed = id.trim();
        trimmed
            .strip_prefix("wasapi-shared::")
            .or_else(|| trimmed.strip_prefix("wasapi-excl::"))
            .unwrap_or(trimmed)
    }

    /// Enumerates real audio hardware on the current host without fabricating capabilities,
    /// cleanly separating `WASAPI Exclusive`, `WASAPI Shared`, and `ASIO` as distinct entries.
    pub fn list_devices() -> Vec<AudioDeviceCapabilities> {
        Self::list_devices_with_meta()
            .into_iter()
            .map(|(cap, _)| cap)
            .collect()
    }

    /// Clears the process-wide hardware probe cache so the next query re-enumerates COM/ASIO.
    pub fn invalidate_device_cache() {
        let cache = DEVICE_PROBE_CACHE.get_or_init(|| RwLock::new(None));
        if let Ok(mut guard) = cache.write() {
            *guard = None;
        }
    }

    /// Enumerates real audio hardware capabilities paired with extended probe metadata,
    /// served from a short-TTL cache (invalidated on OS device/resume events) with double-checked
    /// mutex serialization so concurrent expired callers never trigger duplicate COM/ASIO probes.
    pub fn list_devices_with_meta() -> Vec<(AudioDeviceCapabilities, DeviceExtraMeta)> {
        let cache = DEVICE_PROBE_CACHE.get_or_init(|| RwLock::new(None));
        if let Ok(guard) = cache.read()
            && let Some((ts, ref cached)) = *guard
            && ts.elapsed() < DEVICE_PROBE_CACHE_TTL
        {
            return cached.clone();
        }

        // Serialize cache refresh to prevent thundering-herd duplicate COM/ASIO probes.
        let probe_lock = DEVICE_PROBE_LOCK.get_or_init(|| Mutex::new(()));
        let _probe_guard = probe_lock.lock().unwrap_or_else(|e| e.into_inner());

        // Double-check after acquiring probe mutex in case another caller refreshed it.
        if let Ok(guard) = cache.read()
            && let Some((ts, ref cached)) = *guard
            && ts.elapsed() < DEVICE_PROBE_CACHE_TTL
        {
            return cached.clone();
        }

        let devices = Self::probe_devices_with_meta_uncached();
        if let Ok(mut guard) = cache.write() {
            *guard = Some((Instant::now(), devices.clone()));
        }
        devices
    }

    /// Forces a fresh hardware probe and refreshes the process-wide device capability cache.
    pub fn list_devices_with_meta_fresh() -> Vec<(AudioDeviceCapabilities, DeviceExtraMeta)> {
        let probe_lock = DEVICE_PROBE_LOCK.get_or_init(|| Mutex::new(()));
        let _probe_guard = probe_lock.lock().unwrap_or_else(|e| e.into_inner());

        let devices = Self::probe_devices_with_meta_uncached();
        let cache = DEVICE_PROBE_CACHE.get_or_init(|| RwLock::new(None));
        if let Ok(mut guard) = cache.write() {
            *guard = Some((Instant::now(), devices.clone()));
        }
        devices
    }

    fn probe_devices_with_meta_uncached() -> Vec<(AudioDeviceCapabilities, DeviceExtraMeta)> {
        let mut devices = Vec::new();

        #[cfg(target_os = "windows")]
        {
            for p in crate::backend::wasapi_win::probe_wasapi_endpoints() {
                let is_bt = p.transport == DeviceTransportKind::Bluetooth;
                let exclusive_ok = p.exclusive_available && !is_bt;
                let supports_dop = exclusive_ok
                    && matches!(p.transport, DeviceTransportKind::UsbDac)
                    && p.supported_bit_depths.contains(&24)
                    && p.supported_rates.contains(&176_400);

                if exclusive_ok {
                    let mut excl_modes = vec![OutputMode::WasapiExclusive];
                    if supports_dop {
                        excl_modes.push(OutputMode::DoPOverWasapiExclusive);
                    }
                    devices.push((
                        AudioDeviceCapabilities {
                            device_id: p.id.clone(),
                            name: p.name.clone(),
                            backend: OutputBackendKind::WindowsWasapiExclusive,
                            transport: p.transport,
                            is_default: p.is_default,
                            is_exclusive: true,
                            supported_sample_rates: p.supported_rates.clone(),
                            supported_bit_depths: p.supported_bit_depths.clone(),
                            supported_container_bits: p.supported_container_bits.clone(),
                            supported_channels: p.supported_channels.clone(),
                            supported_output_modes: excl_modes,
                            supports_native_dsd: false,
                            supports_dop,
                            supports_float32: p.supports_float32,
                            max_dsd_rate: None,
                            asio_available: false,
                            asio_driver_name: None,
                            exclusive_available: true,
                            probe_note: None,
                        },
                        DeviceExtraMeta {
                            is_os_default: p.is_default,
                            is_hdmi: p.is_hdmi,
                            hardware_supports_exclusive: true,
                            buffer_size_supported: p.min_buffer_frames.is_some(),
                            min_buffer_frames: p.min_buffer_frames,
                            max_buffer_frames: p.max_buffer_frames,
                            default_buffer_frames: p.default_buffer_frames,
                            buffer_granularity: None,
                        },
                    ));
                }

                let shared_note = if is_bt && p.probe_note.is_none() {
                    Some("Bluetooth wireless audio (lossy A2DP codec transport)".to_string())
                } else if p.probe_note.is_some() {
                    p.probe_note.clone()
                } else if p.shared_mix_rate > 0 {
                    Some(format!("Windows Shared Mixer ({} Hz)", p.shared_mix_rate))
                } else {
                    None
                };

                let shared_rates = if p.shared_mix_rate > 0 {
                    vec![p.shared_mix_rate]
                } else {
                    p.supported_rates.clone()
                };
                let shared_bits = if p.shared_mix_bits > 0 {
                    vec![p.shared_mix_bits]
                } else {
                    p.supported_bit_depths.clone()
                };
                let shared_channels = if p.shared_mix_channels > 0 {
                    vec![p.shared_mix_channels]
                } else {
                    p.supported_channels.clone()
                };

                devices.push((
                    AudioDeviceCapabilities {
                        device_id: format!("wasapi-shared::{}", p.id),
                        name: p.name,
                        backend: OutputBackendKind::WindowsWasapiShared,
                        transport: p.transport,
                        is_default: !exclusive_ok && p.is_default,
                        is_exclusive: false,
                        supported_sample_rates: shared_rates,
                        supported_bit_depths: shared_bits.clone(),
                        supported_container_bits: shared_bits,
                        supported_channels: shared_channels,
                        supported_output_modes: vec![
                            OutputMode::WasapiShared,
                            OutputMode::DsdToPcm,
                        ],
                        supports_native_dsd: false,
                        supports_dop: false,
                        supports_float32: p.shared_float32 || !exclusive_ok,
                        max_dsd_rate: None,
                        asio_available: false,
                        asio_driver_name: None,
                        exclusive_available: false,
                        probe_note: shared_note,
                    },
                    DeviceExtraMeta {
                        is_os_default: p.is_default,
                        is_hdmi: p.is_hdmi,
                        hardware_supports_exclusive: exclusive_ok,
                        buffer_size_supported: false,
                        min_buffer_frames: None,
                        max_buffer_frames: None,
                        default_buffer_frames: None,
                        buffer_granularity: None,
                    },
                ));
            }

            for asio in crate::backend::asio_win::enumerate_asio_drivers(true) {
                let asio_ready = asio.dll_exists && asio.initialized_ok;
                let asio_is_integer_24_or_32 = matches!(
                    asio.sample_type,
                    Some(
                        crate::backend::asio_win::ASIO_ST_INT24_LSB
                            | crate::backend::asio_win::ASIO_ST_INT32_LSB
                    )
                );
                let dop_ok = asio_ready
                    && asio_is_integer_24_or_32
                    && asio.supported_bit_depths.iter().any(|&b| b >= 24)
                    && asio.supported_rates.contains(&176_400);

                let mut modes = Vec::new();
                if asio_ready {
                    modes.push(OutputMode::AsioPcm);
                    if asio.supports_native_dsd {
                        modes.push(OutputMode::AsioNativeDsd);
                    }
                    if dop_ok {
                        modes.push(OutputMode::DoPOverAsio);
                    }
                    modes.push(OutputMode::DsdToPcm);
                }

                let container_bits = if asio.supported_bit_depths.contains(&16) {
                    vec![16, 24, 32]
                } else {
                    vec![24, 32]
                };

                devices.push((
                    AudioDeviceCapabilities {
                        device_id: format!("asio::{}", asio.id),
                        name: format!("{} (ASIO)", asio.name),
                        backend: OutputBackendKind::WindowsAsio,
                        transport: DeviceTransportKind::Asio,
                        is_default: false,
                        is_exclusive: asio_ready,
                        supported_sample_rates: asio.supported_rates,
                        supported_bit_depths: asio.supported_bit_depths,
                        supported_container_bits: container_bits,
                        supported_channels: if asio.output_channels > 0 {
                            vec![asio.output_channels.min(2), asio.output_channels]
                                .into_iter()
                                .collect::<std::collections::BTreeSet<_>>()
                                .into_iter()
                                .collect()
                        } else {
                            Vec::new()
                        },
                        supported_output_modes: modes,
                        supports_native_dsd: asio.supports_native_dsd,
                        supports_dop: dop_ok,
                        supports_float32: matches!(
                            asio.sample_type,
                            Some(crate::backend::asio_win::ASIO_ST_FLOAT32_LSB)
                        ),
                        max_dsd_rate: asio.max_dsd_rate,
                        asio_available: asio_ready,
                        asio_driver_name: Some(asio.name),
                        exclusive_available: asio_ready,
                        probe_note: asio.probe_note,
                    },
                    DeviceExtraMeta {
                        is_os_default: false,
                        is_hdmi: false,
                        hardware_supports_exclusive: asio_ready,
                        buffer_size_supported: asio_ready && asio.min_buffer_frames.is_some(),
                        min_buffer_frames: asio.min_buffer_frames,
                        max_buffer_frames: asio.max_buffer_frames,
                        default_buffer_frames: asio.preferred_buffer_frames,
                        buffer_granularity: asio.buffer_granularity,
                    },
                ));
            }
        }

        #[cfg(target_os = "macos")]
        {
            for ca in crate::backend::coreaudio::enumerate_coreaudio_devices() {
                devices.push((
                    ca,
                    DeviceExtraMeta {
                        is_os_default: false,
                        is_hdmi: false,
                        hardware_supports_exclusive: true,
                        buffer_size_supported: true,
                        min_buffer_frames: Some(64),
                        max_buffer_frames: Some(4096),
                        default_buffer_frames: Some(512),
                        buffer_granularity: None,
                    },
                ));
            }
        }

        devices
    }

    pub fn resolve_device<'a>(
        devices: &'a [AudioDeviceCapabilities],
        selected: Option<&str>,
    ) -> Option<&'a AudioDeviceCapabilities> {
        if let Some(sel) = selected.filter(|s| !s.trim().is_empty())
            && let Some(found) = devices.iter().find(|d| {
                d.device_id == sel || d.name == sel || d.asio_driver_name.as_deref() == Some(sel)
            })
        {
            return Some(found);
        }
        devices
            .iter()
            .find(|d| d.is_default)
            .or_else(|| devices.first())
    }

    /// Virtual full-matrix capability profile used strictly inside headless deterministic tests.
    pub fn virtual_device_capabilities() -> AudioDeviceCapabilities {
        AudioDeviceCapabilities {
            device_id: "virtual-hifi-dac".to_string(),
            name: "Virtual Hi-Fi DAC".to_string(),
            backend: OutputBackendKind::WindowsWasapiExclusive,
            transport: DeviceTransportKind::Virtual,
            is_default: true,
            is_exclusive: true,
            supported_sample_rates: vec![
                44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
            ],
            supported_bit_depths: vec![16, 24, 32],
            supported_container_bits: vec![16, 24, 32, 64],
            supported_channels: vec![1, 2, 4, 6, 8],
            supported_output_modes: vec![
                OutputMode::VirtualMock,
                OutputMode::DoPOverWasapiExclusive,
                OutputMode::DsdToPcm,
            ],
            supports_native_dsd: false,
            supports_dop: true,
            supports_float32: true,
            max_dsd_rate: Some(DsdRate::Dsd128),
            asio_available: false,
            asio_driver_name: None,
            exclusive_available: true,
            probe_note: Some("Headless deterministic pipeline consumer".to_string()),
        }
    }

    /// Builds a canonical [`AudioDeviceInfo`] from an [`AudioDeviceDescription`] plus optional
    /// hardware probe metadata (`DeviceExtraMeta`) and active selection flag.
    pub fn to_device_info(
        desc: &AudioDeviceDescription,
        meta: Option<&DeviceExtraMeta>,
        is_active: bool,
    ) -> AudioDeviceInfo {
        let mut info = AudioDeviceInfo::from(desc);
        info.is_active = is_active;
        if let Some(m) = meta {
            info.is_default = info.is_default || m.is_os_default;
            info.supports_exclusive = info.supports_exclusive || m.hardware_supports_exclusive;
            info.is_hdmi = m.is_hdmi;
            info.buffer_size_supported = m.buffer_size_supported;
            info.min_buffer_frames = m.min_buffer_frames.unwrap_or(0);
            info.max_buffer_frames = m.max_buffer_frames.unwrap_or(0);
            info.default_buffer_frames = m.default_buffer_frames.unwrap_or(0);
            info.buffer_granularity = m
                .buffer_granularity
                .and_then(|g| u32::try_from(g).ok())
                .unwrap_or(0);
        }
        info
    }

    /// Builds a canonical [`AudioDeviceInfo`] from rich probed [`AudioDeviceCapabilities`] and
    /// [`DeviceExtraMeta`].
    pub fn capabilities_to_device_info(
        cap: &AudioDeviceCapabilities,
        meta: &DeviceExtraMeta,
        is_active: bool,
    ) -> AudioDeviceInfo {
        let mut info = AudioDeviceInfo::from(cap);
        info.is_default = cap.is_default || meta.is_os_default;
        info.is_active = is_active;
        info.supports_exclusive =
            cap.exclusive_available || cap.is_exclusive || meta.hardware_supports_exclusive;
        info.is_hdmi = meta.is_hdmi;
        info.buffer_size_supported = meta.buffer_size_supported;
        info.min_buffer_frames = meta.min_buffer_frames.unwrap_or(0);
        info.max_buffer_frames = meta.max_buffer_frames.unwrap_or(0);
        info.default_buffer_frames = meta.default_buffer_frames.unwrap_or(0);
        info.buffer_granularity = meta
            .buffer_granularity
            .and_then(|g| u32::try_from(g).ok())
            .unwrap_or(0);
        info
    }

    /// Lists all probed host audio devices as canonical [`AudioDeviceInfo`] entries.
    pub fn list_device_infos(active_device_id: Option<&str>) -> Vec<AudioDeviceInfo> {
        Self::list_devices_with_meta()
            .into_iter()
            .map(|(cap, meta)| {
                let active = active_device_id.is_some_and(|id| id == cap.device_id);
                Self::capabilities_to_device_info(&cap, &meta, active)
            })
            .collect()
    }
}
