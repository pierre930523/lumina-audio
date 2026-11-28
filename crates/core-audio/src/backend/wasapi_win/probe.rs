use std::ffi::c_void;
use std::sync::Arc;

use core_types::{DeviceTransportKind, OutputBackendKind, OutputMode};
use windows::Win32::Devices::Properties::{
    DEVPKEY_Device_BusTypeGuid, DEVPKEY_Device_EnumeratorName,
};
use windows::Win32::Foundation::S_OK;
use windows::Win32::Media::Audio::{
    AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED, AUDCLNT_E_DEVICE_IN_USE,
    AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED, AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_EVENTCALLBACK, DEVICE_STATE_ACTIVE, IAudioClient, IAudioClock,
    IAudioRenderClient, IMMDevice, IMMDeviceEnumerator, MMDeviceEnumerator,
    PKEY_AudioEndpoint_FormFactor, WAVEFORMATEX, eAll, eConsole, eRender,
};
use windows::Win32::System::Com::{CLSCTX_ALL, CoCreateInstance, CoTaskMemFree, STGM_READ};
use windows::core::{GUID, PCWSTR};

use crate::error::BackendError;
use crate::verification::WireSampleFormat;

use super::clock::WasapiExclusiveOpenSpec;
use super::com::{
    AUDIOPHILE_RATES, ComGuard, Win32Event, build_waveformatextensible, classify_transport,
    is_exclusive_format_exact_ok, is_hdmi_endpoint, map_wasapi_hresult, pwstr_to_string_and_free,
    read_prop_string, read_prop_u32, to_shell_pkey,
};

#[derive(Debug, Clone)]
pub struct WasapiEndpointProbe {
    pub id: String,
    pub name: String,
    pub transport: DeviceTransportKind,
    pub is_default: bool,
    pub is_hdmi: bool,
    pub supported_rates: Vec<u32>,
    pub supported_bit_depths: Vec<u8>,
    pub supported_container_bits: Vec<u8>,
    pub supported_channels: Vec<u16>,
    pub exclusive_available: bool,
    pub supports_dop: bool,
    pub supports_float32: bool,
    pub shared_mix_rate: u32,
    pub shared_mix_bits: u8,
    pub shared_mix_channels: u16,
    pub shared_float32: bool,
    pub min_buffer_frames: Option<u32>,
    pub max_buffer_frames: Option<u32>,
    pub default_buffer_frames: Option<u32>,
    pub probe_note: Option<String>,
}

pub fn probe_wasapi_endpoints() -> Vec<WasapiEndpointProbe> {
    let _com = ComGuard::init_mta();
    let Ok(enumerator): windows::core::Result<IMMDeviceEnumerator> =
        (unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) })
    else {
        return Vec::new();
    };

    let default_id = unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eConsole) }
        .ok()
        .and_then(|d| unsafe { d.GetId() }.ok())
        .map(|pw| unsafe { pwstr_to_string_and_free(pw) });

    let Ok(collection) = (unsafe { enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) })
    else {
        return Vec::new();
    };
    let count = unsafe { collection.GetCount() }.unwrap_or(0);
    let mut out = Vec::with_capacity(count as usize);

    // Common FriendlyName PKEY_Device_FriendlyName {A45C254E-DF1C-4EFD-8020-67D146A850E0}, pid 14
    let pkey_friendly = to_shell_pkey(GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0), 14);
    let pkey_enum = to_shell_pkey(
        DEVPKEY_Device_EnumeratorName.fmtid,
        DEVPKEY_Device_EnumeratorName.pid,
    );
    let pkey_form = to_shell_pkey(
        PKEY_AudioEndpoint_FormFactor.fmtid,
        PKEY_AudioEndpoint_FormFactor.pid,
    );
    let _ = DEVPKEY_Device_BusTypeGuid;

    let wire_candidates = [
        WireSampleFormat::Int16Le,
        WireSampleFormat::Int24PackedLe,
        WireSampleFormat::Int24In32MsbLe,
        WireSampleFormat::Int32Le,
        WireSampleFormat::Float32Le,
    ];

    for idx in 0..count {
        let Ok(device) = (unsafe { collection.Item(idx) }) else {
            continue;
        };
        let Ok(id_pw) = (unsafe { device.GetId() }) else {
            continue;
        };
        let id = unsafe { pwstr_to_string_and_free(id_pw) };
        let store = unsafe { device.OpenPropertyStore(STGM_READ) }.ok();

        let name = store
            .as_ref()
            .and_then(|st| unsafe { read_prop_string(st, &pkey_friendly) })
            .unwrap_or_else(|| id.clone());
        let enum_name = store
            .as_ref()
            .and_then(|st| unsafe { read_prop_string(st, &pkey_enum) });
        let form_factor = store
            .as_ref()
            .and_then(|st| unsafe { read_prop_u32(st, &pkey_form) });

        let transport = classify_transport(&name, enum_name.as_deref(), form_factor);
        let is_hdmi = is_hdmi_endpoint(&name, form_factor);
        let is_default = default_id.as_deref() == Some(id.as_str());

        let mut supported_rates = Vec::new();
        let mut supported_bit_depths = Vec::new();
        let mut supported_container_bits = Vec::new();
        let mut supported_channels = Vec::new();
        let mut exclusive_available = false;
        let mut supports_float32 = false;
        let mut shared_mix_rate = 0u32;
        let mut shared_mix_bits = 0u8;
        let mut shared_mix_channels = 0u16;
        let mut shared_float32 = false;
        let mut min_buffer_frames = None;
        let mut max_buffer_frames = None;
        let mut default_buffer_frames = None;
        let mut probe_note = None;

        if let Ok(client) = unsafe { device.Activate::<IAudioClient>(CLSCTX_ALL, None) } {
            let mut ch_to_probe = vec![2u16];
            if let Ok(mix_ptr) = unsafe { client.GetMixFormat() } {
                let mix = unsafe { *mix_ptr };
                let mix_ch = mix.nChannels;
                shared_mix_rate = mix.nSamplesPerSec;
                shared_mix_bits = mix.wBitsPerSample as u8;
                shared_mix_channels = mix.nChannels;
                shared_float32 = mix.wFormatTag == 3 || mix.wBitsPerSample == 32;
                if !ch_to_probe.contains(&mix_ch) {
                    ch_to_probe.push(mix_ch);
                }
                unsafe { CoTaskMemFree(Some(mix_ptr as *const c_void)) };
            }

            let mut denied_or_in_use = false;
            for &ch in &ch_to_probe {
                for &rate in &AUDIOPHILE_RATES {
                    for &wire in &wire_candidates {
                        let hr = unsafe { is_exclusive_format_exact_ok(&client, rate, ch, wire) };
                        if hr == S_OK {
                            exclusive_available = true;
                            if matches!(wire, WireSampleFormat::Float32Le) {
                                supports_float32 = true;
                            }
                            if !supported_rates.contains(&rate) {
                                supported_rates.push(rate);
                            }
                            if !supported_channels.contains(&ch) {
                                supported_channels.push(ch);
                            }
                            let vb = wire.valid_bits();
                            let cb = wire.container_bits();
                            if !supported_bit_depths.contains(&vb) {
                                supported_bit_depths.push(vb);
                            }
                            if !supported_container_bits.contains(&cb) {
                                supported_container_bits.push(cb);
                            }
                        } else if hr == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED
                            || hr == AUDCLNT_E_DEVICE_IN_USE
                        {
                            denied_or_in_use = true;
                        }
                    }
                }
            }

            if exclusive_available {
                let mut def_period = 0i64;
                let mut min_period = 0i64;
                if unsafe { client.GetDevicePeriod(Some(&mut def_period), Some(&mut min_period)) }
                    .is_ok()
                    && def_period > 0
                {
                    let ref_rate = if shared_mix_rate > 0 {
                        shared_mix_rate as u128
                    } else {
                        48_000u128
                    };
                    let min_f =
                        ((min_period.max(1) as u128 * ref_rate) / 10_000_000).max(32) as u32;
                    let def_f = ((def_period.max(1) as u128 * ref_rate) / 10_000_000)
                        .max(min_f as u128) as u32;
                    min_buffer_frames = Some(min_f);
                    default_buffer_frames = Some(def_f);
                    max_buffer_frames = Some((def_f.saturating_mul(8)).max(4096));
                }
            } else {
                // Report Shared Mode mix rate honestly without pretending exclusive support!
                if shared_mix_rate > 0 {
                    supported_rates.push(shared_mix_rate);
                    supported_bit_depths.push(shared_mix_bits);
                    supported_container_bits.push(shared_mix_bits);
                    supported_channels.push(shared_mix_channels);
                    probe_note = Some(if denied_or_in_use {
                        "Exclusive mode busy or disabled in Windows Sound settings".to_string()
                    } else {
                        format!("Shared-mode only (Windows mixer {shared_mix_rate} Hz)")
                    });
                }
            }
        }

        supported_rates.sort_unstable();
        supported_bit_depths.sort_unstable();
        supported_container_bits.sort_unstable();
        supported_channels.sort_unstable();

        // DoP v1.1 requires bit-exact 24-bit exclusive stream at >= 176.4 kHz (DSD64 DoP)
        let supports_dop = exclusive_available
            && supported_bit_depths.contains(&24)
            && supported_rates.contains(&176_400);

        out.push(WasapiEndpointProbe {
            id,
            name,
            transport,
            is_default,
            is_hdmi,
            supported_rates,
            supported_bit_depths,
            supported_container_bits,
            supported_channels,
            exclusive_available,
            supports_dop,
            supports_float32,
            shared_mix_rate,
            shared_mix_bits,
            shared_mix_channels,
            shared_float32,
            min_buffer_frames,
            max_buffer_frames,
            default_buffer_frames,
            probe_note,
        });
    }

    let _ = eAll;
    out
}

pub(super) unsafe fn resolve_mmdevice(
    enumerator: &IMMDeviceEnumerator,
    device_id: Option<&str>,
) -> Result<(IMMDevice, String), BackendError> {
    let clean_id = device_id
        .map(str::trim)
        .map(|s| {
            s.strip_prefix("wasapi-shared::")
                .or_else(|| s.strip_prefix("wasapi-excl::"))
                .unwrap_or(s)
        })
        .filter(|s| !s.is_empty());
    let device = if let Some(id) = clean_id {
        let wide: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe { enumerator.GetDevice(PCWSTR(wide.as_ptr())) }.map_err(|e| {
            BackendError::DeviceNotFound(format!("WASAPI endpoint '{id}' not found: {e}"))
        })?
    } else {
        unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eConsole) }
            .map_err(|e| BackendError::DeviceNotFound(format!("No default WASAPI endpoint: {e}")))?
    };

    let pkey_friendly = to_shell_pkey(GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0), 14);
    let name = unsafe { device.OpenPropertyStore(STGM_READ) }
        .ok()
        .and_then(|st| unsafe { read_prop_string(&st, &pkey_friendly) })
        .unwrap_or_else(|| "WASAPI Exclusive Endpoint".to_string());

    Ok((device, name))
}

pub(super) type OpenedExclusiveClient = (
    IAudioClient,
    IAudioRenderClient,
    Option<IAudioClock>,
    Arc<Win32Event>,
    u32,
    String,
);

pub(super) unsafe fn open_client_exclusive(
    spec: &WasapiExclusiveOpenSpec,
) -> Result<OpenedExclusiveClient, BackendError> {
    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
            .map_err(|e| BackendError::DriverError(format!("MMDeviceEnumerator failed: {e}")))?;

    let (device, dev_name) = unsafe { resolve_mmdevice(&enumerator, spec.device_id.as_deref()) }?;

    let mut client: IAudioClient = unsafe { device.Activate(CLSCTX_ALL, None) }
        .map_err(|e| BackendError::DriverError(format!("Activate IAudioClient failed: {e}")))?;

    // Strict IsFormatSupported(Exclusive): ONLY S_OK is accepted (NEVER S_FALSE Closest Match!)
    let hr = unsafe {
        is_exclusive_format_exact_ok(&client, spec.sample_rate, spec.channels, spec.wire_format)
    };
    if hr != S_OK {
        return Err(map_wasapi_hresult(
            hr,
            &format!(
                "Strict WASAPI IsFormatSupported rejected {} Hz / {}-bit (valid {}-bit) {}ch (HRESULT=0x{:08X})",
                spec.sample_rate,
                spec.wire_format.container_bits(),
                spec.wire_format.valid_bits(),
                spec.channels,
                hr.0 as u32
            ),
        ));
    }

    let wf = build_waveformatextensible(
        spec.sample_rate,
        spec.channels,
        spec.wire_format,
        spec.layout,
    );

    let mut def_period = 0i64;
    let mut min_period = 0i64;
    unsafe { client.GetDevicePeriod(Some(&mut def_period), Some(&mut min_period)) }
        .map_err(|e| map_wasapi_hresult(e.code(), &format!("GetDevicePeriod failed: {e}")))?;

    let hint_hns = ((spec.buffer_frames_hint.max(64) as i64) * 10_000_000)
        / (spec.sample_rate.max(8000) as i64);
    let mut period = hint_hns.max(min_period).max(def_period);

    let init_res = unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_EXCLUSIVE,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
            period,
            period,
            &wf.Format as *const WAVEFORMATEX,
            None,
        )
    };

    if let Err(e) = init_res {
        if e.code() == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED {
            // Official MSDN buffer alignment recovery flow: query hardware-aligned frame count,
            // release IAudioClient, re-activate, and re-initialize with aligned duration.
            let aligned_frames = unsafe { client.GetBufferSize() }
                .map_err(|ge| BackendError::DriverError(format!("GetBufferSize failed: {ge}")))?;
            period =
                ((10_000_000.0 * aligned_frames as f64) / spec.sample_rate as f64 + 0.5) as i64;
            drop(client);
            client = unsafe { device.Activate(CLSCTX_ALL, None) }.map_err(|ae| {
                BackendError::DriverError(format!("Re-activate IAudioClient failed: {ae}"))
            })?;
            unsafe {
                client.Initialize(
                    AUDCLNT_SHAREMODE_EXCLUSIVE,
                    AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    period,
                    period,
                    &wf.Format as *const WAVEFORMATEX,
                    None,
                )
            }
            .map_err(|re| map_wasapi_hresult(re.code(), &format!("Re-Initialize failed: {re}")))?;
        } else {
            return Err(map_wasapi_hresult(
                e.code(),
                &format!("IAudioClient::Initialize(Exclusive) failed: {e}"),
            ));
        }
    }

    let actual_buffer_frames = unsafe { client.GetBufferSize() }
        .map_err(|e| BackendError::DriverError(format!("GetBufferSize failed: {e}")))?;

    let buf_event = Arc::new(Win32Event::new_auto_reset()?);

    if let Err(e) = unsafe { client.SetEventHandle(buf_event.raw()) } {
        return Err(BackendError::DriverError(format!(
            "SetEventHandle failed: {e}"
        )));
    }

    let render: IAudioRenderClient = unsafe { client.GetService() }.map_err(|e| {
        BackendError::DriverError(format!("GetService<IAudioRenderClient> failed: {e}"))
    })?;
    let clock: Option<IAudioClock> = unsafe { client.GetService().ok() };

    let _ = AUDCLNT_SHAREMODE_SHARED;
    let _ = OutputBackendKind::WindowsWasapiExclusive;
    let _ = OutputMode::WasapiExclusive;

    Ok((
        client,
        render,
        clock,
        buf_event,
        actual_buffer_frames,
        dev_name,
    ))
}
