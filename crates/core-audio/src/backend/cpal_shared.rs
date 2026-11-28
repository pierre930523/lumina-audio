use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use core_types::{AudioDeviceDescription, OutputBackendKind};
use cpal::traits::{DeviceTrait, HostTrait};
use cpal::{FromSample, HostId, SampleFormat, SizedSample};

use crate::backend::device_manager::AudioDeviceManager;
use crate::buffer::Consumer;
use crate::error::{BackendError, CoreAudioError};
use crate::pipeline::ring_buffer::UnderrunGuard;
use crate::pipeline::rt_telemetry::{RtErrorCode, RtTelemetry};

pub const VIRTUAL_DEVICE_ID: &str = "virtual-hifi-dac";

/// Stack chunk size in `f32` samples for reduced-stack RT cpal rendering (`256 * 4 = 1024 B`,
/// keeping total callback frame usage strictly <= 2 KiB instead of 36 KiB).
pub const CPAL_RT_CHUNK_SAMPLES: usize = 256;

pub fn map_host_to_backend(host_id: HostId, device_name: &str) -> OutputBackendKind {
    match host_id.to_string().to_ascii_lowercase().as_str() {
        "asio" => OutputBackendKind::WindowsAsio,
        "coreaudio" => OutputBackendKind::MacOsCoreAudioHog,
        "aaudio" => OutputBackendKind::MobileDirect,
        "wasapi" => {
            if device_name.to_ascii_lowercase().contains("asio") {
                OutputBackendKind::WindowsAsio
            } else {
                OutputBackendKind::WindowsWasapiShared
            }
        }
        _ => {
            if device_name.to_ascii_lowercase().contains("asio") {
                OutputBackendKind::WindowsAsio
            } else {
                OutputBackendKind::WindowsWasapiShared
            }
        }
    }
}

pub fn enumerate_cpal_devices() -> Vec<AudioDeviceDescription> {
    const STANDARD_RATES: [u32; 8] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ];

    let mut out = Vec::new();
    let default_host_id = cpal::default_host().id();

    for host_id in cpal::available_hosts() {
        let Ok(host) = cpal::host_from_id(host_id) else {
            continue;
        };
        let default_dev_id = host
            .default_output_device()
            .and_then(|d| d.id().ok())
            .map(|id| id.to_string());

        let Ok(devices) = host.output_devices() else {
            continue;
        };

        for dev in devices {
            let Ok(dev_id) = dev.id() else {
                continue;
            };
            let id_str = dev_id.to_string();
            let name = dev
                .description()
                .map(|d| d.name().to_string())
                .unwrap_or_else(|_| id_str.clone());
            let backend = map_host_to_backend(host_id, &name);
            let is_default =
                host_id == default_host_id && default_dev_id.as_deref() == Some(id_str.as_str());

            let mut rates = Vec::new();
            let mut bit_depths = Vec::new();
            if let Ok(configs) = dev.supported_output_configs() {
                for range in configs {
                    let min_r = range.min_sample_rate();
                    let max_r = range.max_sample_rate();
                    for &sr in &STANDARD_RATES {
                        if sr >= min_r && sr <= max_r && !rates.contains(&sr) {
                            rates.push(sr);
                        }
                    }
                    if !rates.contains(&min_r) {
                        rates.push(min_r);
                    }
                    if !rates.contains(&max_r) {
                        rates.push(max_r);
                    }

                    let depth = match range.sample_format() {
                        SampleFormat::I16 | SampleFormat::U16 => 16,
                        SampleFormat::I24 | SampleFormat::U24 => 24,
                        _ => 32,
                    };
                    if !bit_depths.contains(&depth) {
                        bit_depths.push(depth);
                    }
                }
            }
            if rates.is_empty() {
                rates = vec![44_100, 48_000];
            } else {
                rates.sort_unstable();
            }
            if bit_depths.is_empty() {
                bit_depths = vec![16, 24];
            } else {
                bit_depths.sort_unstable();
            }

            out.push(AudioDeviceDescription {
                id: id_str,
                name,
                backend,
                is_default,
                is_exclusive: backend.is_exclusive(),
                supported_sample_rates: rates,
                supported_bit_depths: bit_depths,
                supports_native_dsd: backend == OutputBackendKind::WindowsAsio,
            });
        }
    }

    out
}

pub fn rank_sample_format(fmt: SampleFormat) -> Option<u8> {
    match fmt {
        SampleFormat::F32 => Some(0),
        SampleFormat::F64 => Some(1),
        SampleFormat::I32 => Some(2),
        SampleFormat::I24 => Some(3),
        SampleFormat::I16 => Some(4),
        SampleFormat::U16 => Some(5),
        SampleFormat::U8 => Some(6),
        _ => None,
    }
}

/// Pure config ranking helper for unit tests: picks the best index among
/// `(channels, min_sample_rate, max_sample_rate, sample_format)` candidates
/// matching `(desired_channels, desired_rate)`.
pub fn select_best_config_index(
    candidates: &[(u16, u32, u32, SampleFormat)],
    desired_rate: u32,
    desired_channels: u16,
) -> Option<usize> {
    let mut best: Option<(u8, usize)> = None;
    for (idx, &(channels, min_rate, max_rate, fmt)) in candidates.iter().enumerate() {
        if channels != desired_channels || desired_rate < min_rate || desired_rate > max_rate {
            continue;
        }
        let Some(rank) = rank_sample_format(fmt) else {
            continue;
        };
        if best.is_none_or(|(best_rank, _)| rank < best_rank) {
            best = Some((rank, idx));
            if rank == 0 {
                break;
            }
        }
    }
    best.map(|(_, idx)| idx)
}

pub fn select_output_config(
    device: &cpal::Device,
    desired_rate: u32,
    desired_channels: u16,
) -> Result<cpal::SupportedStreamConfig, CoreAudioError> {
    if let Ok(ranges) = device.supported_output_configs() {
        let mut best: Option<(u8, cpal::SupportedStreamConfig)> = None;
        for range in ranges {
            if range.channels() != desired_channels {
                continue;
            }
            let Some(rank) = rank_sample_format(range.sample_format()) else {
                continue;
            };
            let Some(exact) = range.try_with_sample_rate(desired_rate) else {
                continue;
            };
            if best.as_ref().is_none_or(|(best_rank, _)| rank < *best_rank) {
                best = Some((rank, exact));
                if rank == 0 {
                    break;
                }
            }
        }
        if let Some((_, cfg)) = best {
            return Ok(cfg);
        }
    }

    device.default_output_config().map_err(|e| {
        CoreAudioError::Backend(BackendError::DriverError(format!(
            "Failed to query output config for audio device: {e}"
        )))
    })
}

pub fn resolve_cpal_device(
    selected_id: Option<&str>,
    selected_backend: Option<OutputBackendKind>,
) -> Result<(cpal::Device, OutputBackendKind, String), CoreAudioError> {
    if selected_id == Some(VIRTUAL_DEVICE_ID) || selected_id == Some("virtual-exclusive-dac") {
        return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
            selected_id.unwrap_or(VIRTUAL_DEVICE_ID).to_string(),
        )));
    }

    if let Some(target_id) = selected_id {
        let clean_target = AudioDeviceManager::strip_mode_prefix(target_id);
        if clean_target.starts_with("asio::") {
            return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
                target_id.to_string(),
            )));
        }
        for host_id in cpal::available_hosts() {
            let Ok(host) = cpal::host_from_id(host_id) else {
                continue;
            };
            let Ok(devices) = host.output_devices() else {
                continue;
            };
            for dev in devices {
                if let Ok(id) = dev.id() {
                    let id_str = id.to_string();
                    if id_str == clean_target || id_str.contains(clean_target) {
                        let name = dev
                            .description()
                            .map(|d| d.name().to_string())
                            .unwrap_or_else(|_| clean_target.to_string());
                        let backend = match selected_backend {
                            Some(OutputBackendKind::WindowsWasapiExclusive)
                            | Some(OutputBackendKind::WindowsAsio)
                            | None => map_host_to_backend(host_id, &name),
                            Some(other) => other,
                        };
                        return Ok((dev, backend, name));
                    }
                }
            }
        }
        return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
            target_id.to_string(),
        )));
    }

    if let Some(target_backend) = selected_backend {
        for host_id in cpal::available_hosts() {
            let Ok(host) = cpal::host_from_id(host_id) else {
                continue;
            };
            if let Some(dev) = host.default_output_device() {
                let name = dev
                    .description()
                    .map(|d| d.name().to_string())
                    .unwrap_or_else(|_| "System Audio Output".to_string());
                let detected = map_host_to_backend(host_id, &name);
                if detected == target_backend {
                    return Ok((dev, detected, name));
                }
            }
        }
    }

    let host = cpal::default_host();
    let host_id = host.id();
    if let Some(dev) = host.default_output_device() {
        let name = dev
            .description()
            .map(|d| d.name().to_string())
            .unwrap_or_else(|_| "System Audio Output".to_string());
        let backend = selected_backend.unwrap_or_else(|| map_host_to_backend(host_id, &name));
        return Ok((dev, backend, name));
    }

    for alt_host_id in cpal::available_hosts() {
        let Ok(alt_host) = cpal::host_from_id(alt_host_id) else {
            continue;
        };
        if let Some(dev) = alt_host
            .default_output_device()
            .or_else(|| alt_host.output_devices().ok().and_then(|mut it| it.next()))
        {
            let name = dev
                .description()
                .map(|d| d.name().to_string())
                .unwrap_or_else(|_| "System Audio Output".to_string());
            let backend =
                selected_backend.unwrap_or_else(|| map_host_to_backend(alt_host_id, &name));
            return Ok((dev, backend, name));
        }
    }

    Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
        "No hardware audio output device available".to_string(),
    )))
}

/// Reduced-stack RT chunked output renderer for cpal callbacks.
///
/// Uses a fixed 256-sample (`1 KiB`) stack scratch buffer (keeping total stack usage <= 2 KiB
/// instead of allocating 16-36 KiB per OS audio callback). Strictly No-Lock, No-Alloc, No-Log.
#[inline]
pub fn render_cpal_output_chunked<T, F>(output: &mut [T], channels: usize, mut fill_chunk: F)
where
    T: SizedSample + FromSample<f32>,
    F: FnMut(&mut [f32]) -> bool,
{
    let ch = channels.max(1);
    let max_pos = if T::FORMAT.is_float() {
        1.0_f32
    } else {
        // dasp_sample requires -1.0 <= s < 1.0 for float-to-integer conversions
        0.99999994_f32
    };
    let mut chunk_f32 = [0.0f32; CPAL_RT_CHUNK_SAMPLES];
    let chunk_cap = ((CPAL_RT_CHUNK_SAMPLES / ch) * ch).clamp(1, CPAL_RT_CHUNK_SAMPLES);
    let total_samples = (output.len() / ch) * ch;
    let mut written = 0usize;

    while written < total_samples {
        let want = (total_samples - written).min(chunk_cap);
        let keep_going = fill_chunk(&mut chunk_f32[..want]);
        for i in 0..want {
            let s = chunk_f32[i];
            let safe = if s.is_finite() {
                s.clamp(-1.0, max_pos)
            } else {
                0.0
            };
            output[written + i] = T::from_sample(safe);
        }
        written += want;
        if !keep_going {
            break;
        }
    }

    if written < output.len() {
        output[written..].fill(T::EQUILIBRIUM);
    }
}

/// Builds a strictly RT-safe, reduced-stack (`<= 2 KiB`) pull-based cpal output stream reading
/// directly from an `SpscRingBuffer<f32>` consumer and updating `RtTelemetry`.
pub fn build_cpal_pull_stream<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    mut consumer: Consumer<f32>,
    telemetry: Arc<RtTelemetry>,
    kill_flag: Arc<AtomicBool>,
    strict_bit_perfect: bool,
) -> Result<cpal::Stream, cpal::Error>
where
    T: SizedSample + FromSample<f32>,
{
    let ch = config.channels.max(1) as usize;
    let err_tel = Arc::clone(&telemetry);

    device.build_output_stream(
        config,
        move |output: &mut [T], _| {
            if kill_flag.load(Ordering::Acquire) {
                output.fill(T::EQUILIBRIUM);
                return;
            }
            let mut peak_l = 0.0f32;
            let mut peak_r = 0.0f32;
            let mut frames_total = 0u64;

            render_cpal_output_chunked(output, ch, |dst_f32| {
                let popped = consumer.pop_slice_aligned(dst_f32, ch);
                if popped < dst_f32.len() {
                    UnderrunGuard::handle_f32_underrun(
                        dst_f32,
                        popped,
                        ch,
                        strict_bit_perfect,
                        Some(&telemetry),
                    );
                }
                if popped > 0 {
                    let frames = popped / ch;
                    frames_total += frames as u64;
                    for f in 0..frames {
                        let l = dst_f32[f * ch].abs();
                        let r = if ch > 1 { dst_f32[f * ch + 1].abs() } else { l };
                        if l > peak_l {
                            peak_l = l;
                        }
                        if r > peak_r {
                            peak_r = r;
                        }
                    }
                }
                true
            });

            if frames_total > 0 {
                telemetry.add_frames_rt(frames_total);
                telemetry.set_peaks_rt(peak_l, peak_r);
            }
        },
        move |_err| {
            err_tel.record_error_rt(RtErrorCode::DeviceInvalidated, -1);
        },
        None,
    )
}
