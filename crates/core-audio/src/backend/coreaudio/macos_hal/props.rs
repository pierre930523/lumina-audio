use std::ffi::c_void;
use std::ptr::null;

use core_types::{AudioDeviceCapabilities, DeviceTransportKind, OutputBackendKind, OutputMode};

use crate::error::BackendError;

use super::ffi::{
    AudioDeviceID, AudioObjectGetPropertyData, AudioObjectGetPropertyDataSize,
    AudioObjectPropertyAddress, AudioObjectSetPropertyData, AudioValueRange,
    K_AUDIO_DEVICE_PROPERTY_AVAILABLE_NOMINAL_SAMPLE_RATES,
    K_AUDIO_DEVICE_PROPERTY_BUFFER_FRAME_SIZE, K_AUDIO_DEVICE_PROPERTY_HOG_MODE,
    K_AUDIO_DEVICE_PROPERTY_NOMINAL_SAMPLE_RATE, K_AUDIO_HARDWARE_PROPERTY_DEFAULT_OUTPUT_DEVICE,
    K_AUDIO_HARDWARE_PROPERTY_DEVICES, K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL, K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT,
    K_AUDIO_OBJECT_SYSTEM_OBJECT, getpid,
};

pub(super) fn resolve_device_id(device_id: Option<&str>) -> Result<AudioDeviceID, BackendError> {
    if let Some(raw) = device_id {
        let trimmed = raw.trim().strip_prefix("coreaudio::").unwrap_or(raw.trim());
        if let Ok(parsed) = trimmed.parse::<u32>() {
            return Ok(parsed);
        }
    }
    let addr = AudioObjectPropertyAddress {
        m_selector: K_AUDIO_HARDWARE_PROPERTY_DEFAULT_OUTPUT_DEVICE,
        m_scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
        m_element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    };
    let mut dev_id: AudioDeviceID = 0;
    let mut size = std::mem::size_of::<AudioDeviceID>() as u32;
    let rc = unsafe {
        AudioObjectGetPropertyData(
            K_AUDIO_OBJECT_SYSTEM_OBJECT,
            &addr,
            0,
            null(),
            &mut size,
            &mut dev_id as *mut AudioDeviceID as *mut c_void,
        )
    };
    if rc != 0 || dev_id == 0 {
        return Err(BackendError::DeviceNotFound(format!(
            "CoreAudio default output device query failed: OSStatus={rc}"
        )));
    }
    Ok(dev_id)
}

pub(super) fn acquire_hog_mode(device_id: AudioDeviceID) -> bool {
    let addr = AudioObjectPropertyAddress {
        m_selector: K_AUDIO_DEVICE_PROPERTY_HOG_MODE,
        m_scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT,
        m_element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    };
    let pid: i32 = unsafe { getpid() };
    let rc = unsafe {
        AudioObjectSetPropertyData(
            device_id,
            &addr,
            0,
            null(),
            std::mem::size_of::<i32>() as u32,
            &pid as *const i32 as *const c_void,
        )
    };
    rc == 0
}

pub(super) fn release_hog_mode(device_id: AudioDeviceID) {
    let addr = AudioObjectPropertyAddress {
        m_selector: K_AUDIO_DEVICE_PROPERTY_HOG_MODE,
        m_scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT,
        m_element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    };
    let release_pid: i32 = -1;
    unsafe {
        let _ = AudioObjectSetPropertyData(
            device_id,
            &addr,
            0,
            null(),
            std::mem::size_of::<i32>() as u32,
            &release_pid as *const i32 as *const c_void,
        );
    }
}

pub(super) fn set_nominal_sample_rate(
    device_id: AudioDeviceID,
    rate_hz: f64,
) -> Result<(), BackendError> {
    let addr = AudioObjectPropertyAddress {
        m_selector: K_AUDIO_DEVICE_PROPERTY_NOMINAL_SAMPLE_RATE,
        m_scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
        m_element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    };
    let rc = unsafe {
        AudioObjectSetPropertyData(
            device_id,
            &addr,
            0,
            null(),
            std::mem::size_of::<f64>() as u32,
            &rate_hz as *const f64 as *const c_void,
        )
    };
    if rc != 0 {
        return Err(BackendError::DriverError(format!(
            "CoreAudio kAudioDevicePropertyNominalSampleRate({rate_hz}) failed: OSStatus={rc}"
        )));
    }
    Ok(())
}

pub(super) fn set_buffer_frame_size(
    device_id: AudioDeviceID,
    frames: u32,
) -> Result<(), BackendError> {
    let addr = AudioObjectPropertyAddress {
        m_selector: K_AUDIO_DEVICE_PROPERTY_BUFFER_FRAME_SIZE,
        m_scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT,
        m_element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    };
    let rc = unsafe {
        AudioObjectSetPropertyData(
            device_id,
            &addr,
            0,
            null(),
            std::mem::size_of::<u32>() as u32,
            &frames as *const u32 as *const c_void,
        )
    };
    if rc != 0 {
        return Err(BackendError::DriverError(format!(
            "CoreAudio kAudioDevicePropertyBufferFrameSize({frames}) failed: OSStatus={rc}"
        )));
    }
    Ok(())
}

fn query_supported_sample_rates(device_id: AudioDeviceID) -> Vec<u32> {
    const STANDARD_RATES: [u32; 8] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ];
    let addr = AudioObjectPropertyAddress {
        m_selector: K_AUDIO_DEVICE_PROPERTY_AVAILABLE_NOMINAL_SAMPLE_RATES,
        m_scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
        m_element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    };
    let mut size = 0u32;
    if unsafe { AudioObjectGetPropertyDataSize(device_id, &addr, 0, null(), &mut size) } != 0
        || size == 0
    {
        return vec![44_100, 48_000];
    }
    let count = (size as usize) / std::mem::size_of::<AudioValueRange>();
    let mut ranges = vec![
        AudioValueRange {
            m_minimum: 0.0,
            m_maximum: 0.0,
        };
        count
    ];
    if unsafe {
        AudioObjectGetPropertyData(
            device_id,
            &addr,
            0,
            null(),
            &mut size,
            ranges.as_mut_ptr() as *mut c_void,
        )
    } != 0
    {
        return vec![44_100, 48_000];
    }
    let mut rates = Vec::new();
    for &sr in &STANDARD_RATES {
        let f = sr as f64;
        if ranges.iter().any(|r| f >= r.m_minimum && f <= r.m_maximum) {
            rates.push(sr);
        }
    }
    if rates.is_empty() {
        vec![44_100, 48_000]
    } else {
        rates
    }
}

pub fn enumerate_devices() -> Vec<AudioDeviceCapabilities> {
    let addr = AudioObjectPropertyAddress {
        m_selector: K_AUDIO_HARDWARE_PROPERTY_DEVICES,
        m_scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
        m_element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
    };
    let mut size = 0u32;
    if unsafe {
        AudioObjectGetPropertyDataSize(K_AUDIO_OBJECT_SYSTEM_OBJECT, &addr, 0, null(), &mut size)
    } != 0
        || size == 0
    {
        return Vec::new();
    }
    let count = (size as usize) / std::mem::size_of::<AudioDeviceID>();
    let mut ids = vec![0u32; count];
    if unsafe {
        AudioObjectGetPropertyData(
            K_AUDIO_OBJECT_SYSTEM_OBJECT,
            &addr,
            0,
            null(),
            &mut size,
            ids.as_mut_ptr() as *mut c_void,
        )
    } != 0
    {
        return Vec::new();
    }
    let default_id = resolve_device_id(None).ok();

    ids.into_iter()
        .map(|id| {
            let rates = query_supported_sample_rates(id);
            let supports_dop = rates.contains(&176_400);
            let mut modes = vec![OutputMode::WasapiExclusive];
            if supports_dop {
                modes.push(OutputMode::DoPOverWasapiExclusive);
            }
            modes.push(OutputMode::DsdToPcm);
            AudioDeviceCapabilities {
                device_id: format!("coreaudio::{id}"),
                name: format!("CoreAudio Device #{id}"),
                backend: OutputBackendKind::MacOsCoreAudioHog,
                transport: DeviceTransportKind::UsbDac,
                is_default: default_id == Some(id),
                is_exclusive: true,
                supported_sample_rates: rates,
                supported_bit_depths: vec![16, 24, 32],
                supported_container_bits: vec![16, 24, 32],
                supported_channels: vec![2],
                supported_output_modes: modes,
                supports_native_dsd: false,
                supports_dop,
                supports_float32: true,
                max_dsd_rate: None,
                asio_available: false,
                asio_driver_name: None,
                exclusive_available: true,
                probe_note: None,
            }
        })
        .collect()
}
