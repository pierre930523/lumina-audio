use std::ffi::c_void;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use core_types::{ChannelLayout, DeviceTransportKind};
use windows::Win32::Foundation::{CloseHandle, HANDLE, PROPERTYKEY as ShellPropKey, S_FALSE, S_OK};
use windows::Win32::Media::Audio::{
    AUDCLNT_E_DEVICE_IN_USE, AUDCLNT_E_DEVICE_INVALIDATED, AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED,
    AUDCLNT_E_SERVICE_NOT_RUNNING, AUDCLNT_SHAREMODE_EXCLUSIVE, IAudioClient, WAVEFORMATEX,
    WAVEFORMATEXTENSIBLE, WAVEFORMATEXTENSIBLE_0,
};
use windows::Win32::Media::KernelStreaming::KSDATAFORMAT_SUBTYPE_PCM;
use windows::Win32::Media::Multimedia::KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
use windows::Win32::System::Com::StructuredStorage::PropVariantToStringAlloc;
use windows::Win32::System::Com::{
    COINIT_MULTITHREADED, CoInitializeEx, CoTaskMemFree, CoUninitialize,
};
use windows::Win32::System::Threading::{CreateEventW, ResetEvent, SetEvent};
use windows::Win32::UI::Shell::PropertiesSystem::IPropertyStore;
use windows::core::{GUID, HRESULT, PWSTR};

use crate::error::BackendError;
use crate::verification::WireSampleFormat;

pub(super) const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

pub(super) const AUDIOPHILE_RATES: [u32; 10] = [
    44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
];

pub(super) struct ComGuard {
    pub(super) should_uninit: bool,
}

impl ComGuard {
    pub(super) fn init_mta() -> Self {
        let hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        Self {
            should_uninit: hr == S_OK || hr == S_FALSE,
        }
    }
}

impl Drop for ComGuard {
    fn drop(&mut self) {
        if self.should_uninit {
            unsafe { CoUninitialize() };
        }
    }
}

pub(super) fn to_shell_pkey(fmtid: GUID, pid: u32) -> ShellPropKey {
    ShellPropKey { fmtid, pid }
}

pub(super) unsafe fn pwstr_to_string_and_free(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { p.to_string() }.unwrap_or_default();
    unsafe { CoTaskMemFree(Some(p.0 as *const c_void)) };
    s
}

pub(super) unsafe fn read_prop_string(
    store: &IPropertyStore,
    key: &ShellPropKey,
) -> Option<String> {
    let pv = unsafe { store.GetValue(key as *const ShellPropKey) }.ok()?;
    let pw = unsafe { PropVariantToStringAlloc(&pv) }.ok();
    let _ = pv;
    pw.and_then(|p| {
        let s = unsafe { pwstr_to_string_and_free(p) };
        if s.trim().is_empty() {
            None
        } else {
            Some(s.trim().to_string())
        }
    })
}

pub(super) unsafe fn read_prop_u32(store: &IPropertyStore, key: &ShellPropKey) -> Option<u32> {
    let pv = unsafe { store.GetValue(key as *const ShellPropKey) }.ok()?;
    let s = unsafe { PropVariantToStringAlloc(&pv) }.ok()?;
    let txt = unsafe { pwstr_to_string_and_free(s) };
    txt.trim().parse::<u32>().ok()
}

pub fn build_waveformatextensible(
    rate: u32,
    channels: u16,
    wire: WireSampleFormat,
    layout: ChannelLayout,
) -> WAVEFORMATEXTENSIBLE {
    let ch = channels.max(1);
    let container_bits = wire.container_bits() as u16;
    let valid_bits = wire.valid_bits() as u16;
    let block_align = ch * (container_bits / 8);
    let avg_bytes_per_sec = rate * (block_align as u32);

    let subformat = match wire {
        WireSampleFormat::Float32Le | WireSampleFormat::Float64Le => {
            KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
        }
        _ => KSDATAFORMAT_SUBTYPE_PCM,
    };

    WAVEFORMATEXTENSIBLE {
        Format: WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_EXTENSIBLE,
            nChannels: ch,
            nSamplesPerSec: rate,
            nAvgBytesPerSec: avg_bytes_per_sec,
            nBlockAlign: block_align,
            wBitsPerSample: container_bits,
            cbSize: 22,
        },
        Samples: WAVEFORMATEXTENSIBLE_0 {
            wValidBitsPerSample: valid_bits,
        },
        dwChannelMask: layout.speaker_mask(),
        SubFormat: subformat,
    }
}

pub(super) fn is_hdmi_endpoint(name: &str, form_factor: Option<u32>) -> bool {
    if form_factor == Some(9) {
        return true;
    }
    let lower_name = name.to_ascii_lowercase();
    lower_name.contains("hdmi")
        || lower_name.contains("displayport")
        || lower_name.contains("display audio")
        || lower_name.contains("nvidia high definition")
        || lower_name.contains("amd high definition")
}

pub(super) fn classify_transport(
    name: &str,
    enumerator: Option<&str>,
    form_factor: Option<u32>,
) -> DeviceTransportKind {
    let lower_name = name.to_ascii_lowercase();
    let lower_enum = enumerator.unwrap_or("").to_ascii_lowercase();
    if lower_enum.contains("bth")
        || lower_name.contains("bluetooth")
        || lower_name.contains("airpods")
    {
        return DeviceTransportKind::Bluetooth;
    }
    if lower_enum.contains("usb")
        || lower_name.contains("dac")
        || lower_name.contains("fiio")
        || lower_name.contains("topping")
        || lower_name.contains("ifi")
        || lower_name.contains("schiit")
        || lower_name.contains("chord")
        || lower_name.contains("usb")
    {
        return DeviceTransportKind::UsbDac;
    }
    // Windows EndpointFormFactor enum: 3 = Headphones, 5 = Headset, 1 = Speakers
    match form_factor {
        Some(3) | Some(5) => DeviceTransportKind::Headphones,
        Some(1) => DeviceTransportKind::Speakers,
        _ if lower_name.contains("headphone") || lower_name.contains("耳機") => {
            DeviceTransportKind::Headphones
        }
        _ if lower_name.contains("speaker") || lower_name.contains("喇叭") => {
            DeviceTransportKind::Speakers
        }
        _ => DeviceTransportKind::Internal,
    }
}

/// Strictly checks `IAudioClient::IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, ...)`.
/// Returns `true` ONLY if COM returns exact `S_OK` (`0`). Never accepts `S_FALSE` closest match!
///
/// # Safety
/// `client` must be a valid initialized COM `IAudioClient` pointer on a COM-initialized thread.
pub unsafe fn is_exclusive_format_exact_ok(
    client: &IAudioClient,
    rate: u32,
    channels: u16,
    wire: WireSampleFormat,
) -> HRESULT {
    let wf =
        build_waveformatextensible(rate, channels, wire, ChannelLayout::from_channels(channels));
    unsafe {
        client.IsFormatSupported(
            AUDCLNT_SHAREMODE_EXCLUSIVE,
            &wf.Format as *const WAVEFORMATEX,
            None,
        )
    }
}

/// Safe RAII wrapper around a Win32 event `HANDLE`.
#[doc(hidden)]
pub struct Win32Event(pub(super) HANDLE);

unsafe impl Send for Win32Event {}
unsafe impl Sync for Win32Event {}

impl Win32Event {
    pub fn new_manual_reset() -> Result<Self, BackendError> {
        let h = unsafe { CreateEventW(None, true, false, None) }
            .map_err(|e| BackendError::DriverError(format!("CreateEventW failed: {e}")))?;
        Ok(Self(h))
    }

    pub fn new_auto_reset() -> Result<Self, BackendError> {
        let h = unsafe { CreateEventW(None, false, false, None) }
            .map_err(|e| BackendError::DriverError(format!("CreateEventW failed: {e}")))?;
        Ok(Self(h))
    }

    pub fn signal(&self) {
        unsafe {
            let _ = SetEvent(self.0);
        }
    }

    pub fn reset(&self) {
        unsafe {
            let _ = ResetEvent(self.0);
        }
    }

    pub fn raw(&self) -> HANDLE {
        self.0
    }
}

impl Drop for Win32Event {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}

#[doc(hidden)]
pub fn join_handle_bounded(handle: JoinHandle<()>, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while !handle.is_finished() {
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(1));
    }
    let _ = handle.join();
    true
}

pub(super) fn map_wasapi_hresult(hr: HRESULT, context: &str) -> BackendError {
    if hr == AUDCLNT_E_DEVICE_IN_USE || hr == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED {
        BackendError::DeviceInUse
    } else if hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING {
        BackendError::DeviceNotFound(context.to_string())
    } else {
        BackendError::DriverError(context.to_string())
    }
}
