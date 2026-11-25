use std::sync::{OnceLock, RwLock};
use std::time::{Duration, Instant};

use core_types::{
    AudioDeviceCapabilities, DeviceTransportKind, DsdOutputMode, DsdRate, OutputBackendKind,
    OutputMode, PlaybackEnginePolicy, SampleFormatKind, UnifiedAudioFormat,
};

use crate::verification::WireSampleFormat;

const DEVICE_PROBE_CACHE_TTL: Duration = Duration::from_secs(5);
type CachedDeviceEntry = (Instant, Vec<(AudioDeviceCapabilities, DeviceExtraMeta)>);
static DEVICE_PROBE_CACHE: OnceLock<RwLock<Option<CachedDeviceEntry>>> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NegotiatedFormat {
    pub output_mode: OutputMode,
    pub wire_format: WireSampleFormat,
    pub target_sample_rate: u32,
    pub target_channels: u16,
    pub container_bits: u8,
    pub valid_bits: u8,
    pub is_bit_perfect_candidate: bool,
    pub requires_dsp_bypass: bool,
    pub requires_unity_volume: bool,
    pub requires_resampling: bool,
    pub degradation_reason: Option<String>,
}

/// Phase 2 + Phase 7: AudioFormatManager negotiates exact hardware output formats
/// without silent resampling or false Strict Mode capability claims.
pub struct AudioFormatManager;

impl AudioFormatManager {
    pub fn negotiate(
        source: &UnifiedAudioFormat,
        device: &AudioDeviceCapabilities,
        policy: &PlaybackEnginePolicy,
    ) -> Result<NegotiatedFormat, String> {
        if let Some(dsd_rate) = source.dsd_rate {
            return Self::negotiate_dsd(source, dsd_rate, device, policy);
        }
        Self::negotiate_pcm(source, device, policy)
    }

    /// Returns `Some(next_negotiated)` ONLY if the hardware stream can continue gaplessly
    /// without closing/re-opening the DAC endpoint (identical rate, channels, output mode, wire container).
    pub fn can_gapless_transition(
        prev: &UnifiedAudioFormat,
        prev_neg: &NegotiatedFormat,
        next: &UnifiedAudioFormat,
        device: &AudioDeviceCapabilities,
        policy: &PlaybackEnginePolicy,
    ) -> Option<NegotiatedFormat> {
        if prev.dsd_rate.is_some() != next.dsd_rate.is_some() {
            return None;
        }
        let next_neg = Self::negotiate(next, device, policy).ok()?;
        if next_neg.output_mode == prev_neg.output_mode
            && next_neg.wire_format == prev_neg.wire_format
            && next_neg.target_sample_rate == prev_neg.target_sample_rate
            && next_neg.target_channels == prev_neg.target_channels
            && prev.sample_format == next.sample_format
            && prev.valid_bits == next.valid_bits
        {
            Some(next_neg)
        } else {
            None
        }
    }

    fn negotiate_dsd(
        source: &UnifiedAudioFormat,
        dsd_rate: DsdRate,
        device: &AudioDeviceCapabilities,
        policy: &PlaybackEnginePolicy,
    ) -> Result<NegotiatedFormat, String> {
        let rate_within_max = device
            .max_dsd_rate
            .map(|max| dsd_rate <= max)
            .unwrap_or(false);
        let native_ok = device.asio_available && device.supports_native_dsd && rate_within_max;

        let dop_carrier = dsd_rate.dop_carrier_rate_hz();
        let dop_supported = device.supports_dop
            && (device.exclusive_available || device.asio_available)
            && device.supported_bit_depths.contains(&24)
            && dop_carrier
                .map(|r| device.supported_sample_rates.contains(&r))
                .unwrap_or(false);

        match policy.dsd_output_mode {
            DsdOutputMode::NativeDsd => {
                if native_ok {
                    return Ok(Self::build_native_dsd(source, dsd_rate));
                }
                Err(format!(
                    "設備 '{}' 不支援 {} Native DSD (ASIO Native DSD={}, Max={:?})",
                    device.name,
                    dsd_rate.label(),
                    device.supports_native_dsd,
                    device.max_dsd_rate
                ))
            }
            DsdOutputMode::DoP => {
                if dop_supported {
                    return Ok(Self::build_dop(source, dop_carrier.unwrap(), device));
                }
                Err(format!(
                    "設備 '{}' 未支援或未具備 {} DoP 條件 (需要 24-bit 獨佔 / {} Hz)",
                    device.name,
                    dsd_rate.label(),
                    dop_carrier.unwrap_or(0)
                ))
            }
            DsdOutputMode::DsdToPcm => Ok(Self::build_dsd_to_pcm(
                source,
                device,
                "使用者明確選擇 DSD-to-PCM 轉換模式".to_string(),
            )),
            DsdOutputMode::Auto => {
                if native_ok {
                    return Ok(Self::build_native_dsd(source, dsd_rate));
                }
                if dop_supported {
                    return Ok(Self::build_dop(source, dop_carrier.unwrap(), device));
                }
                if policy.strict_bit_perfect && !policy.allow_shared_fallback {
                    return Err(format!(
                        "嚴格位元完美模式阻擋 DSD 降級：'{}' 不支援 {} Native DSD 或 DoP",
                        device.name,
                        dsd_rate.label()
                    ));
                }
                Ok(Self::build_dsd_to_pcm(
                    source,
                    device,
                    format!(
                        "設備 '{}' 不支援 Native DSD / DoP，已明確降級為 DSD-to-PCM 輸出",
                        device.name
                    ),
                ))
            }
        }
    }

    fn build_native_dsd(source: &UnifiedAudioFormat, dsd_rate: DsdRate) -> NegotiatedFormat {
        NegotiatedFormat {
            output_mode: OutputMode::AsioNativeDsd,
            wire_format: WireSampleFormat::NativeDsd {
                channels: source.channels.max(1),
            },
            target_sample_rate: dsd_rate.bit_clock_hz(),
            target_channels: source.channels.max(1),
            container_bits: 8,
            valid_bits: 1,
            is_bit_perfect_candidate: true,
            requires_dsp_bypass: true,
            requires_unity_volume: true,
            requires_resampling: false,
            degradation_reason: None,
        }
    }

    fn build_dop(
        source: &UnifiedAudioFormat,
        carrier_rate: u32,
        device: &AudioDeviceCapabilities,
    ) -> NegotiatedFormat {
        let mode = if device.backend == OutputBackendKind::WindowsAsio {
            OutputMode::DoPOverAsio
        } else {
            OutputMode::DoPOverWasapiExclusive
        };
        NegotiatedFormat {
            output_mode: mode,
            wire_format: WireSampleFormat::Dop24In32MsbLe {
                channels: source.channels.max(1),
                is_lsb_first: true,
            },
            target_sample_rate: carrier_rate,
            target_channels: source.channels.max(1),
            container_bits: 32,
            valid_bits: 24,
            is_bit_perfect_candidate: true,
            requires_dsp_bypass: true,
            requires_unity_volume: true,
            requires_resampling: false,
            degradation_reason: None,
        }
    }

    fn build_dsd_to_pcm(
        source: &UnifiedAudioFormat,
        device: &AudioDeviceCapabilities,
        reason: String,
    ) -> NegotiatedFormat {
        let preferred_pcm = [176_400u32, 88_200, 96_000, 48_000, 44_100];
        let target_rate = preferred_pcm
            .iter()
            .copied()
            .find(|r| device.supported_sample_rates.contains(r))
            .or_else(|| device.supported_sample_rates.first().copied())
            .unwrap_or(48_000);
        let ch = if device.supported_channels.contains(&source.channels)
            || device.supported_channels.is_empty()
        {
            source.channels.max(1)
        } else {
            device.supported_channels[0].max(1)
        };
        NegotiatedFormat {
            output_mode: OutputMode::DsdToPcm,
            wire_format: WireSampleFormat::Float32Le,
            target_sample_rate: target_rate,
            target_channels: ch,
            container_bits: 32,
            valid_bits: 32,
            is_bit_perfect_candidate: false,
            requires_dsp_bypass: false,
            requires_unity_volume: false,
            requires_resampling: true,
            degradation_reason: Some(reason),
        }
    }

    fn negotiate_pcm(
        source: &UnifiedAudioFormat,
        device: &AudioDeviceCapabilities,
        policy: &PlaybackEnginePolicy,
    ) -> Result<NegotiatedFormat, String> {
        let exact_rate = device.supported_sample_rates.contains(&source.sample_rate);
        let exact_ch = device.supported_channels.is_empty()
            || device.supported_channels.contains(&source.channels);

        let chosen_wire = pick_bit_exact_wire(source, device);
        let is_bluetooth = device.transport == DeviceTransportKind::Bluetooth;
        let is_bit_perfect_candidate = !source.codec.is_lossy();

        if device.backend == OutputBackendKind::WindowsAsio {
            if device.asio_available && exact_rate && exact_ch && let Some(wire) = chosen_wire {
                return Ok(NegotiatedFormat {
                    output_mode: OutputMode::AsioPcm,
                    wire_format: wire,
                    target_sample_rate: source.sample_rate,
                    target_channels: source.channels,
                    container_bits: wire.container_bits(),
                    valid_bits: wire.valid_bits(),
                    is_bit_perfect_candidate,
                    requires_dsp_bypass: policy.strict_bit_perfect,
                    requires_unity_volume: policy.strict_bit_perfect,
                    requires_resampling: false,
                    degradation_reason: None,
                });
            }
            if policy.strict_bit_perfect && !policy.allow_shared_fallback {
                return Err(format!(
                    "ASIO '{}' 不支援精確格式 {} (avail={}, rate_ok={}, ch_ok={})",
                    device.name,
                    source.display_summary(),
                    device.asio_available,
                    exact_rate,
                    exact_ch
                ));
            }
        } else if device.exclusive_available
            && !is_bluetooth
            && exact_rate
            && exact_ch
            && let Some(wire) = chosen_wire
        {
            let mode = if device.transport == DeviceTransportKind::Virtual {
                OutputMode::VirtualMock
            } else {
                OutputMode::WasapiExclusive
            };
            return Ok(NegotiatedFormat {
                output_mode: mode,
                wire_format: wire,
                target_sample_rate: source.sample_rate,
                target_channels: source.channels,
                container_bits: wire.container_bits(),
                valid_bits: wire.valid_bits(),
                is_bit_perfect_candidate,
                requires_dsp_bypass: policy.strict_bit_perfect,
                requires_unity_volume: policy.strict_bit_perfect,
                requires_resampling: false,
                degradation_reason: None,
            });
        }

        if policy.strict_bit_perfect && !policy.allow_shared_fallback {
            return Err(format!(
                "Strict Mode 拒絕降級：'{}' 無法以獨佔模式播放 {}",
                device.name,
                source.display_summary()
            ));
        }

        // Shared / degraded path with explicit degradation notice
        let shared_rate = if exact_rate {
            source.sample_rate
        } else {
            closest_supported_rate(&device.supported_sample_rates, source.sample_rate)
        };
        let shared_ch = if exact_ch {
            source.channels
        } else {
            device.supported_channels.first().copied().unwrap_or(2)
        };
        let reason = if is_bluetooth {
            "藍牙音訊設備僅支援共用無線編碼通道，無法達到位元完美輸出".to_string()
        } else if !device.exclusive_available && device.backend != OutputBackendKind::WindowsAsio {
            device
                .probe_note
                .clone()
                .unwrap_or_else(|| "無法取得 WASAPI Exclusive 獨佔存取權限，已降級至 Shared Mode".to_string())
        } else if !exact_rate {
            format!(
                "硬體不支援 {} Hz，已降級轉換為 {} Hz",
                source.sample_rate, shared_rate
            )
        } else {
            format!(
                "以共用模式輸出 {} (非精確位元完美路徑)",
                source.display_summary()
            )
        };

        Ok(NegotiatedFormat {
            output_mode: OutputMode::WasapiShared,
            wire_format: WireSampleFormat::Float32Le,
            target_sample_rate: shared_rate,
            target_channels: shared_ch,
            container_bits: 32,
            valid_bits: 32,
            is_bit_perfect_candidate: false,
            requires_dsp_bypass: false,
            requires_unity_volume: false,
            requires_resampling: shared_rate != source.sample_rate,
            degradation_reason: Some(reason),
        })
    }
}

fn pick_bit_exact_wire(
    source: &UnifiedAudioFormat,
    device: &AudioDeviceCapabilities,
) -> Option<WireSampleFormat> {
    let has_cb = |cb: u8| device.supported_container_bits.contains(&cb);
    let has_vb = |vb: u8| device.supported_bit_depths.contains(&vb);

    match source.sample_format {
        SampleFormatKind::Int16 => {
            if has_vb(16) {
                Some(WireSampleFormat::Int16Le)
            } else if has_vb(24) && has_cb(32) {
                Some(WireSampleFormat::Int24In32MsbLe)
            } else if has_cb(32) && has_vb(32) {
                // Zero-padded LSB lossless promotion to 32-bit DAC container
                Some(WireSampleFormat::Int32Le)
            } else {
                None
            }
        }
        SampleFormatKind::Int24Packed | SampleFormatKind::Int24In32 => {
            if has_vb(24) && has_cb(32) {
                Some(WireSampleFormat::Int24In32MsbLe)
            } else if has_vb(24) && has_cb(24) {
                Some(WireSampleFormat::Int24PackedLe)
            } else if has_cb(32) && has_vb(32) {
                // Lossless left-aligned 24-in-32 into 32-bit DAC container (standard on ASIO INT32LSB)
                Some(WireSampleFormat::Int32Le)
            } else {
                None
            }
        }
        SampleFormatKind::Int32 => {
            if has_cb(32) && (has_vb(32) || device.backend == OutputBackendKind::WindowsAsio) {
                Some(WireSampleFormat::Int32Le)
            } else {
                None
            }
        }
        SampleFormatKind::Float32 => {
            if has_cb(32) && device.supports_float32 {
                Some(WireSampleFormat::Float32Le)
            } else if source.codec.is_lossy() {
                // Lossy streams (Opus/AAC/MP3) decode to Float32; select the DAC's highest
                // supported exclusive integer container at exact source rate rather than
                // forcing Shared-mode mixer resampling. Lossless Float32 WAV remains strict.
                if has_vb(24) && has_cb(32) {
                    Some(WireSampleFormat::Int24In32MsbLe)
                } else if has_cb(32) && (has_vb(32) || device.backend == OutputBackendKind::WindowsAsio)
                {
                    Some(WireSampleFormat::Int32Le)
                } else if has_vb(24) && has_cb(24) {
                    Some(WireSampleFormat::Int24PackedLe)
                } else if has_vb(16) {
                    Some(WireSampleFormat::Int16Le)
                } else {
                    None
                }
            } else {
                None
            }
        }
        SampleFormatKind::Float64 => {
            if has_cb(64) {
                Some(WireSampleFormat::Float64Le)
            } else {
                None
            }
        }
        SampleFormatKind::DsdU8 => Some(WireSampleFormat::NativeDsd { channels: 2 }),
    }
}

fn closest_supported_rate(supported: &[u32], wanted: u32) -> u32 {
    supported
        .iter()
        .copied()
        .min_by_key(|&r| r.abs_diff(wanted))
        .unwrap_or(48_000)
}

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
    /// served from a short-TTL cache (invalidated on OS device/resume events) so rapid skips
    /// and status polls never trigger synchronous COM/ASIO probing on the hot path.
    pub fn list_devices_with_meta() -> Vec<(AudioDeviceCapabilities, DeviceExtraMeta)> {
        let cache = DEVICE_PROBE_CACHE.get_or_init(|| RwLock::new(None));
        if let Ok(guard) = cache.read()
            && let Some((ts, ref cached)) = *guard
            && ts.elapsed() < DEVICE_PROBE_CACHE_TTL
        {
            return cached.clone();
        }
        Self::list_devices_with_meta_fresh()
    }

    /// Forces a fresh hardware probe and refreshes the process-wide device capability cache.
    pub fn list_devices_with_meta_fresh() -> Vec<(AudioDeviceCapabilities, DeviceExtraMeta)> {
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
                        supported_output_modes: vec![OutputMode::WasapiShared, OutputMode::DsdToPcm],
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::player::AudioPlayer;
    use crate::stream::StreamSource;
    use crate::verification::{AudioVerificationEngine, VerificationConfig, WireSampleFormat};
    use core_types::{
        AudioCodec, ChannelLayout, Endianness, Interleaving, VerificationStatus,
    };
    use std::collections::HashSet;

    #[test]
    fn test_device_manager_separates_wasapi_exclusive_shared_and_asio_without_duplicates() {
        let with_meta = AudioDeviceManager::list_devices_with_meta();
        let mut seen_ids = HashSet::new();
        let mut seen_pairs = HashSet::new();

        for (cap, _meta) in &with_meta {
            assert!(
                seen_ids.insert(cap.device_id.clone()),
                "Duplicate device_id emitted: {}",
                cap.device_id
            );
            let phys = AudioDeviceManager::strip_mode_prefix(&cap.device_id).to_string();
            assert!(
                seen_pairs.insert((phys.clone(), cap.backend)),
                "Duplicate (endpoint, backend) emitted: {} {:?}",
                phys,
                cap.backend
            );
            if cap.backend == OutputBackendKind::WindowsWasapiShared {
                assert!(
                    !cap.exclusive_available && !cap.is_exclusive,
                    "WASAPI Shared entry '{}' must never claim exclusive_available",
                    cap.name
                );
                assert!(
                    cap.device_id.starts_with("wasapi-shared::"),
                    "WASAPI Shared entry must use distinct mode prefix"
                );
            } else if cap.backend == OutputBackendKind::WindowsWasapiExclusive {
                assert!(
                    cap.exclusive_available && cap.is_exclusive,
                    "WASAPI Exclusive entry '{}' must have exclusive_available=true",
                    cap.name
                );
            }
        }
    }

    #[test]
    fn test_wasapi_shared_negotiation_and_verification_never_bit_perfect() {
        let shared_cap = AudioDeviceCapabilities {
            device_id: "wasapi-shared::dev-1".into(),
            name: "Speakers (Realtek)".into(),
            backend: OutputBackendKind::WindowsWasapiShared,
            transport: DeviceTransportKind::Speakers,
            is_default: true,
            is_exclusive: false,
            supported_sample_rates: vec![48_000],
            supported_bit_depths: vec![32],
            supported_container_bits: vec![32],
            supported_channels: vec![2],
            supported_output_modes: vec![OutputMode::WasapiShared, OutputMode::DsdToPcm],
            supports_native_dsd: false,
            supports_dop: false,
            supports_float32: true,
            max_dsd_rate: None,
            asio_available: false,
            asio_driver_name: None,
            exclusive_available: false,
            probe_note: Some("Windows Shared Mixer (48000 Hz)".into()),
        };

        let src = UnifiedAudioFormat {
            codec: AudioCodec::Flac,
            sample_rate: 48_000,
            channels: 2,
            channel_layout: ChannelLayout::Stereo,
            sample_format: SampleFormatKind::Int24In32,
            container_bits: 32,
            valid_bits: 24,
            endianness: Endianness::Little,
            interleaving: Interleaving::Interleaved,
            dsd_rate: None,
        };

        let neg = AudioFormatManager::negotiate(
            &src,
            &shared_cap,
            &PlaybackEnginePolicy {
                strict_bit_perfect: false,
                allow_shared_fallback: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(neg.output_mode, OutputMode::WasapiShared);
        assert!(!neg.is_bit_perfect_candidate);

        let ver = AudioVerificationEngine::new(VerificationConfig {
            source_format: src,
            output_mode: OutputMode::WasapiShared,
            transport: DeviceTransportKind::Speakers,
            target_rate_hz: 48_000,
            target_channels: 2,
            target_valid_bits: 32,
            target_container_bits: 32,
            buffer_size_frames: 480,
            dsp_active: false,
            software_volume_unity: true,
            resampled: false,
            exclusive_unavailable_reason: None,
        });
        ver.record_backend_input_wire(&[0u8; 32], WireSampleFormat::Float32Le, 2, 48_000);
        let snap = ver.snapshot("WindowsWasapiShared", "Speakers (Realtek)");
        assert_ne!(snap.verification.status, VerificationStatus::BitPerfect);
    }

    #[test]
    fn test_player_device_selection_errors_and_buffer_frames_policy() {
        let player = AudioPlayer::new_headless();
        player
            .play_stream(StreamSource::synth("t-buf", "Buffer Test", 5_000), "Synth")
            .unwrap();

        assert!(player.select_output_device(Some("missing-dac-999"), None).is_err());
        player.set_preferred_buffer_frames(1024).unwrap();
        assert_eq!(player.preferred_buffer_frames(), 1024);

        // Selecting System Output (None) mid-playback succeeds and re-initializes cleanly
        player.select_output_device(None, None).unwrap();

        // Switching to explicit WASAPI Shared clears Strict Bit-Perfect and restores normal volume
        player.set_volume(0.40);
        player.set_strict_bit_perfect(true).unwrap();
        assert!(player.is_strict_bit_perfect());
        assert!((player.volume() - 1.0).abs() < 1e-4);

        player
            .select_output_device(None, Some(OutputBackendKind::WindowsWasapiShared))
            .unwrap();
        assert!(!player.is_strict_bit_perfect());
        assert!((player.volume() - 0.40).abs() < 1e-4);

        player.stop();
        player.shutdown();
    }
}
