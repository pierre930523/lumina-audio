use std::ffi::{CStr, c_void};
use std::ptr::{NonNull, null_mut};

use core_types::DsdRate;
use windows::Win32::System::Com::CLSIDFromString;
use windows::Win32::System::Registry::{
    HKEY, HKEY_LOCAL_MACHINE, KEY_READ, REG_SZ, REG_VALUE_TYPE, RegCloseKey, RegEnumKeyExW,
    RegOpenKeyExW, RegQueryValueExW,
};
use windows::core::{PCWSTR, PWSTR};

use super::ffi_types::{
    ASIO_OK, ASIO_ST_DSD_INT8_LSB1, ASIO_ST_DSD_INT8_LSB8, ASIO_ST_DSD_INT8_MSB1,
    ASIO_ST_FLOAT32_LSB, ASIO_ST_FLOAT64_LSB, ASIO_ST_INT16_LSB, ASIO_ST_INT24_LSB,
    ASIO_ST_INT32_LSB, ASIO_SUCCESS, ASIO_TRUE, AsioChannelInfo, AsioIoFormat, ComAsioPtr,
    ComStaGuard, DSD_PROBE_RATES, IAsioVtbl, K_ASIO_CAN_DO_IO_FORMAT, K_ASIO_FORMAT_DSD,
    PROBABLE_RATES, com_create_asio_instance,
};

#[derive(Debug, Clone)]
pub struct AsioDriverEntry {
    pub id: String,
    pub name: String,
    pub clsid_str: String,
    pub dll_path: Option<String>,
    pub dll_exists: bool,
    pub supported_rates: Vec<u32>,
    pub supported_bit_depths: Vec<u8>,
    pub output_channels: u16,
    pub sample_type: Option<i32>,
    pub supports_native_dsd: bool,
    pub max_dsd_rate: Option<DsdRate>,
    pub min_buffer_frames: Option<u32>,
    pub max_buffer_frames: Option<u32>,
    pub preferred_buffer_frames: Option<u32>,
    pub buffer_granularity: Option<i32>,
    pub initialized_ok: bool,
    pub probe_note: Option<String>,
}

pub(super) fn read_reg_string(key: HKEY, value_name: Option<&str>) -> Option<String> {
    let wide_name: Option<Vec<u16>> =
        value_name.map(|n| n.encode_utf16().chain(std::iter::once(0)).collect());
    let name_ptr = match &wide_name {
        Some(v) => PCWSTR(v.as_ptr()),
        None => PCWSTR::null(),
    };
    let mut ty = REG_VALUE_TYPE::default();
    let mut len = 512u32;
    let mut buf = vec![0u16; 256];
    let err = unsafe {
        RegQueryValueExW(
            key,
            name_ptr,
            None,
            Some(&mut ty),
            Some(buf.as_mut_ptr() as *mut u8),
            Some(&mut len),
        )
    };
    if err.is_err() || ty != REG_SZ {
        return None;
    }
    let u16_len = (len as usize) / 2;
    let slice = &buf[..u16_len.min(buf.len())];
    let nul = slice.iter().position(|&c| c == 0).unwrap_or(slice.len());
    let s = String::from_utf16_lossy(&slice[..nul]).trim().to_string();
    if s.is_empty() { None } else { Some(s) }
}

/// Enumerates ASIO drivers registered under `HKLM\SOFTWARE\ASIO\*` and probes real COM hardware capabilities.
pub fn enumerate_asio_drivers(probe_com: bool) -> Vec<AsioDriverEntry> {
    let mut asio_root = HKEY::default();
    let subkey: Vec<u16> = "SOFTWARE\\ASIO\0".encode_utf16().collect();
    if unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(subkey.as_ptr()),
            Some(0),
            KEY_READ,
            &mut asio_root,
        )
    }
    .is_err()
    {
        return Vec::new();
    }

    let mut entries = Vec::new();
    let mut idx = 0u32;
    loop {
        let mut name_buf = [0u16; 256];
        let mut name_len = name_buf.len() as u32;
        if unsafe {
            RegEnumKeyExW(
                asio_root,
                idx,
                Some(PWSTR(name_buf.as_mut_ptr())),
                &mut name_len,
                None,
                None,
                None,
                None,
            )
        }
        .is_err()
        {
            break;
        }
        idx += 1;
        let key_name = String::from_utf16_lossy(&name_buf[..name_len as usize]);

        let mut drv_key = HKEY::default();
        let drv_sub: Vec<u16> = key_name.encode_utf16().chain(std::iter::once(0)).collect();
        if unsafe {
            RegOpenKeyExW(
                asio_root,
                PCWSTR(drv_sub.as_ptr()),
                Some(0),
                KEY_READ,
                &mut drv_key,
            )
        }
        .is_err()
        {
            continue;
        }

        let clsid_str = read_reg_string(drv_key, Some("CLSID"));
        let desc =
            read_reg_string(drv_key, Some("Description")).unwrap_or_else(|| key_name.clone());
        let _ = unsafe { RegCloseKey(drv_key) };

        let Some(clsid_str) = clsid_str else {
            continue;
        };

        let inproc_sub: Vec<u16> =
            format!("SOFTWARE\\Classes\\CLSID\\{clsid_str}\\InprocServer32\0")
                .encode_utf16()
                .collect();
        let mut inproc_key = HKEY::default();
        let dll_path = if unsafe {
            RegOpenKeyExW(
                HKEY_LOCAL_MACHINE,
                PCWSTR(inproc_sub.as_ptr()),
                Some(0),
                KEY_READ,
                &mut inproc_key,
            )
        }
        .is_ok()
        {
            let p = read_reg_string(inproc_key, None);
            let _ = unsafe { RegCloseKey(inproc_key) };
            p
        } else {
            None
        };
        let dll_exists = dll_path
            .as_deref()
            .is_some_and(|p| std::path::Path::new(p).exists());

        let mut entry = AsioDriverEntry {
            id: format!("asio://{key_name}"),
            name: desc,
            clsid_str: clsid_str.clone(),
            dll_path,
            dll_exists,
            supported_rates: Vec::new(),
            supported_bit_depths: Vec::new(),
            output_channels: 2,
            sample_type: None,
            supports_native_dsd: false,
            max_dsd_rate: None,
            min_buffer_frames: None,
            max_buffer_frames: None,
            preferred_buffer_frames: None,
            buffer_granularity: None,
            initialized_ok: false,
            probe_note: None,
        };

        if probe_com && dll_exists {
            probe_single_asio_com(&mut entry);
        }

        entries.push(entry);
    }

    let _ = unsafe { RegCloseKey(asio_root) };
    entries
}

pub(super) fn probe_single_asio_com(entry: &mut AsioDriverEntry) {
    let _com = ComStaGuard::init();
    let clsid_wide: Vec<u16> = entry
        .clsid_str
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let Ok(clsid) = (unsafe { CLSIDFromString(PCWSTR(clsid_wide.as_ptr())) }) else {
        entry.probe_note = Some("Invalid ASIO CLSID in registry".into());
        return;
    };

    let Ok(raw_unk) = (unsafe { com_create_asio_instance(&clsid) }) else {
        entry.probe_note = Some("CoCreateInstance(IASIO) failed".into());
        return;
    };

    let Some(nn) = NonNull::new(raw_unk as *mut *const IAsioVtbl) else {
        return;
    };
    let asio = ComAsioPtr(nn);

    let init_ok = unsafe { (asio.vtbl().init)(asio.raw(), null_mut()) };
    if init_ok != ASIO_TRUE {
        let err = unsafe { asio.driver_error() };
        entry.probe_note = Some(if err.trim().is_empty() {
            "ASIO hardware offline or DAC disconnected".to_string()
        } else {
            err
        });
        return;
    }

    entry.initialized_ok = true;
    let mut name_buf = [0i8; 64];
    unsafe { (asio.vtbl().get_driver_name)(asio.raw(), name_buf.as_mut_ptr()) };
    let drv_name = unsafe { CStr::from_ptr(name_buf.as_ptr()) }
        .to_string_lossy()
        .trim()
        .to_string();
    if !drv_name.is_empty() {
        entry.name = drv_name;
    }

    let mut num_in = 0i32;
    let mut num_out = 0i32;
    if unsafe { (asio.vtbl().get_channels)(asio.raw(), &mut num_in, &mut num_out) } == ASIO_OK
        && num_out > 0
    {
        entry.output_channels = num_out as u16;
        let mut ch_info = AsioChannelInfo {
            channel: 0,
            is_input: 0,
            is_active: 0,
            channel_group: 0,
            sample_type: 0,
            name: [0; 32],
        };
        if unsafe { (asio.vtbl().get_channel_info)(asio.raw(), &mut ch_info) } == ASIO_OK {
            entry.sample_type = Some(ch_info.sample_type);
            match ch_info.sample_type {
                ASIO_ST_INT16_LSB => entry.supported_bit_depths = vec![16],
                ASIO_ST_INT24_LSB => entry.supported_bit_depths = vec![16, 24],
                ASIO_ST_INT32_LSB => entry.supported_bit_depths = vec![16, 24, 32],
                ASIO_ST_FLOAT32_LSB => entry.supported_bit_depths = vec![32],
                ASIO_ST_FLOAT64_LSB => entry.supported_bit_depths = vec![64],
                ASIO_ST_DSD_INT8_LSB1 | ASIO_ST_DSD_INT8_MSB1 | ASIO_ST_DSD_INT8_LSB8 => {
                    entry.supports_native_dsd = true;
                }
                _ => {}
            }
        }
    }

    for &r in &PROBABLE_RATES {
        if unsafe { (asio.vtbl().can_sample_rate)(asio.raw(), r as f64) } == ASIO_OK {
            entry.supported_rates.push(r);
        }
    }

    let (mut min_sz, mut max_sz, mut pref_sz, mut gran) = (0i32, 0i32, 0i32, 0i32);
    if unsafe {
        (asio.vtbl().get_buffer_size)(
            asio.raw(),
            &mut min_sz,
            &mut max_sz,
            &mut pref_sz,
            &mut gran,
        )
    } == ASIO_OK
        && max_sz > 0
    {
        entry.min_buffer_frames = Some(min_sz.max(1) as u32);
        entry.max_buffer_frames = Some(max_sz.max(min_sz.max(1)) as u32);
        entry.preferred_buffer_frames = Some(pref_sz.max(min_sz.max(1)) as u32);
        entry.buffer_granularity = Some(gran);
    }

    // Check Native DSD IoFormat capability (`kAsioCanDoIoFormat` with `kASIODSDFormat`)
    let mut dsd_fmt = AsioIoFormat {
        format_type: K_ASIO_FORMAT_DSD,
        future: [0; 508],
    };
    let dsd_rc = unsafe {
        (asio.vtbl().future)(
            asio.raw(),
            K_ASIO_CAN_DO_IO_FORMAT,
            &mut dsd_fmt as *mut AsioIoFormat as *mut c_void,
        )
    };
    if dsd_rc == ASIO_SUCCESS || dsd_rc == ASIO_OK {
        entry.supports_native_dsd = true;
        for &rate in DSD_PROBE_RATES.iter().rev() {
            if entry.supported_rates.contains(&rate)
                || unsafe { (asio.vtbl().can_sample_rate)(asio.raw(), rate as f64) } == ASIO_OK
            {
                entry.max_dsd_rate = Some(DsdRate::from_bit_clock_hz(rate));
                break;
            }
        }
        if entry.max_dsd_rate.is_none() {
            entry.max_dsd_rate = Some(DsdRate::Dsd64);
        }
    }
}
