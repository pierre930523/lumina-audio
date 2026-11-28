use core_types::{
    AudioCodec, AudioDeviceCapabilities, DeviceTransportKind, DsdOutputMode, DsdRate, Endianness,
    OutputBackendKind, OutputMode, PlaybackEnginePolicy, SampleFormatKind, UnifiedAudioFormat,
};

use crate::verification::WireSampleFormat;

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
            DsdOutputMode::DsdToPcm => {
                if policy.strict_bit_perfect {
                    return Err(format!(
                        "嚴格位元完美模式阻擋 DSD-to-PCM 轉換：'{}' 必須以 Native DSD 或 DoP 輸出 {}",
                        device.name,
                        dsd_rate.label()
                    ));
                }
                Ok(Self::build_dsd_to_pcm(
                    source,
                    device,
                    "使用者明確選擇 DSD-to-PCM 轉換模式".to_string(),
                ))
            }
            DsdOutputMode::Auto => {
                if native_ok {
                    return Ok(Self::build_native_dsd(source, dsd_rate));
                }
                if dop_supported {
                    return Ok(Self::build_dop(source, dop_carrier.unwrap(), device));
                }
                // BP-1: Strict Bit-Perfect unconditionally blocks DSD-to-PCM downgrade,
                // regardless of `allow_shared_fallback`.
                if policy.strict_bit_perfect {
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
        // BP-3: Preserve true source DSD bit order instead of hardcoding `true`.
        // DSF streams are LSB-first; DSDIFF streams are MSB-first; otherwise honor `source.endianness`.
        let is_lsb_first = match source.codec {
            AudioCodec::Dsdiff => false,
            AudioCodec::Dsf => true,
            _ => source.endianness == Endianness::Little,
        };
        NegotiatedFormat {
            output_mode: mode,
            wire_format: WireSampleFormat::Dop24In32MsbLe {
                channels: source.channels.max(1),
                is_lsb_first,
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
            if device.asio_available
                && exact_rate
                && exact_ch
                && let Some(wire) = chosen_wire
            {
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
            // BP-1: Strict Bit-Perfect unconditionally rejects shared/degraded fallback.
            if policy.strict_bit_perfect {
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

        // BP-1: Strict Bit-Perfect unconditionally rejects shared/mixer fallback,
        // even if `allow_shared_fallback` was left `true`.
        if policy.strict_bit_perfect {
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
            device.probe_note.clone().unwrap_or_else(|| {
                "無法取得 WASAPI Exclusive 獨佔存取權限，已降級至 Shared Mode".to_string()
            })
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
                } else if has_cb(32)
                    && (has_vb(32) || device.backend == OutputBackendKind::WindowsAsio)
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
