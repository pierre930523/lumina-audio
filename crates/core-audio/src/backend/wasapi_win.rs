use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, RwLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use core_types::{ChannelLayout, DeviceTransportKind, OutputBackendKind, OutputMode};
use windows::core::{GUID, HRESULT, PCWSTR, PWSTR};
use windows::Win32::Devices::Properties::{
    DEVPKEY_Device_BusTypeGuid, DEVPKEY_Device_EnumeratorName,
};
use windows::Win32::Foundation::{
    CloseHandle, HANDLE, PROPERTYKEY as ShellPropKey, S_FALSE, S_OK, WAIT_OBJECT_0,
};
use windows::Win32::Media::Audio::{
    eAll, eConsole, eRender, IAudioClient, IAudioClock, IAudioRenderClient, IMMDevice,
    IMMDeviceEnumerator, MMDeviceEnumerator, PKEY_AudioEndpoint_FormFactor,
    AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED, AUDCLNT_E_BUFFER_TOO_LARGE, AUDCLNT_E_DEVICE_INVALIDATED,
    AUDCLNT_E_DEVICE_IN_USE, AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED, AUDCLNT_E_NOT_STOPPED,
    AUDCLNT_E_SERVICE_NOT_RUNNING, AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_EVENTCALLBACK, DEVICE_STATE_ACTIVE, WAVEFORMATEX,
    WAVEFORMATEXTENSIBLE, WAVEFORMATEXTENSIBLE_0,
};
use windows::Win32::Media::KernelStreaming::KSDATAFORMAT_SUBTYPE_PCM;
use windows::Win32::Media::Multimedia::KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
use windows::Win32::System::Com::StructuredStorage::PropVariantToStringAlloc;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL,
    COINIT_MULTITHREADED, STGM_READ,
};
use windows::Win32::System::Threading::{
    AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, CreateEventW, ResetEvent,
    SetEvent, WaitForMultipleObjects,
};
use windows::Win32::UI::Shell::PropertiesSystem::IPropertyStore;

const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::verification::{AudioVerificationEngine, WireSampleFormat};

const AUDIOPHILE_RATES: [u32; 10] = [
    44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
];

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

struct ComGuard {
    should_uninit: bool,
}

impl ComGuard {
    fn init_mta() -> Self {
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

fn to_shell_pkey(fmtid: GUID, pid: u32) -> ShellPropKey {
    ShellPropKey { fmtid, pid }
}

unsafe fn pwstr_to_string_and_free(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { p.to_string() }.unwrap_or_default();
    unsafe { CoTaskMemFree(Some(p.0 as *const c_void)) };
    s
}

unsafe fn read_prop_string(store: &IPropertyStore, key: &ShellPropKey) -> Option<String> {
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

unsafe fn read_prop_u32(store: &IPropertyStore, key: &ShellPropKey) -> Option<u32> {
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
        WireSampleFormat::Float32Le | WireSampleFormat::Float64Le => KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
        _ => KSDATAFORMAT_SUBTYPE_PCM,
    };

    WAVEFORMATEXTENSIBLE {
        Format: WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_EXTENSIBLE as u16,
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

fn is_hdmi_endpoint(name: &str, form_factor: Option<u32>) -> bool {
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

fn classify_transport(name: &str, enumerator: Option<&str>, form_factor: Option<u32>) -> DeviceTransportKind {
    let lower_name = name.to_ascii_lowercase();
    let lower_enum = enumerator.unwrap_or("").to_ascii_lowercase();
    if lower_enum.contains("bth") || lower_name.contains("bluetooth") || lower_name.contains("airpods") {
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
pub unsafe fn is_exclusive_format_exact_ok(
    client: &IAudioClient,
    rate: u32,
    channels: u16,
    wire: WireSampleFormat,
) -> HRESULT {
    let wf = build_waveformatextensible(
        rate,
        channels,
        wire,
        ChannelLayout::from_channels(channels),
    );
    unsafe {
        client.IsFormatSupported(
            AUDCLNT_SHAREMODE_EXCLUSIVE,
            &wf.Format as *const WAVEFORMATEX,
            None,
        )
    }
}

/// Probes real Windows WASAPI endpoints and tests genuine Exclusive Mode capabilities.
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

    let Ok(collection) = (unsafe { enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) }) else {
        return Vec::new();
    };
    let count = unsafe { collection.GetCount() }.unwrap_or(0);
    let mut out = Vec::with_capacity(count as usize);

    // Common FriendlyName PKEY_Device_FriendlyName {A45C254E-DF1C-4EFD-8020-67D146A850E0}, pid 14
    let pkey_friendly = to_shell_pkey(
        GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
        14,
    );
    let pkey_enum = to_shell_pkey(
        DEVPKEY_Device_EnumeratorName.fmtid,
        DEVPKEY_Device_EnumeratorName.pid,
    );
    let pkey_form = to_shell_pkey(PKEY_AudioEndpoint_FormFactor.fmtid, PKEY_AudioEndpoint_FormFactor.pid);
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
                    let min_f = ((min_period.max(1) as u128 * ref_rate) / 10_000_000).max(32) as u32;
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

/// Parameters required to open a native WASAPI Exclusive event-driven stream.
#[derive(Debug, Clone)]
pub struct WasapiExclusiveOpenSpec {
    pub device_id: Option<String>,
    pub sample_rate: u32,
    pub channels: u16,
    pub layout: ChannelLayout,
    pub wire_format: WireSampleFormat,
    pub is_dop: bool,
    pub buffer_frames_hint: u32,
}

/// Hardware clock snapshot captured on the WASAPI MTA render thread via `IAudioClock::GetPosition`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WasapiClockSnapshot {
    pub position: u64,
    pub frequency: u64,
    pub qpc_100ns: u64,
    pub clock_epoch: u64,
    pub sample_rate: u32,
}

/// Safe RAII wrapper around a Win32 event `HANDLE`.
#[doc(hidden)]
pub struct Win32Event(HANDLE);

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

/// Lock-free seqlock-protected hardware clock state updated by the WASAPI render thread.
#[doc(hidden)]
pub struct WasapiClockState {
    seq: AtomicU64,
    hw_pos_raw: AtomicU64,
    hw_freq: AtomicU64,
    hw_qpc_100ns: AtomicU64,
    clock_epoch: AtomicU64,
    sample_rate: AtomicU32,
    hw_valid: AtomicBool,
    last_pos_in_epoch: AtomicU64,
}

impl WasapiClockState {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            seq: AtomicU64::new(0),
            hw_pos_raw: AtomicU64::new(0),
            hw_freq: AtomicU64::new(0),
            hw_qpc_100ns: AtomicU64::new(0),
            clock_epoch: AtomicU64::new(0),
            sample_rate: AtomicU32::new(sample_rate),
            hw_valid: AtomicBool::new(false),
            last_pos_in_epoch: AtomicU64::new(0),
        }
    }

    pub fn set_frequency(&self, freq: u64) {
        if freq > 0 {
            self.hw_freq.store(freq, Ordering::Release);
        }
    }

    pub fn record_position(&self, raw_pos: u64, qpc_100ns: u64) {
        if self.hw_freq.load(Ordering::Acquire) == 0 {
            return;
        }
        let prev = self.last_pos_in_epoch.load(Ordering::Relaxed);
        let mono_pos = raw_pos.max(prev);
        let s = self.seq.load(Ordering::Relaxed);
        self.seq.store(s.wrapping_add(1), Ordering::Release);
        std::sync::atomic::fence(Ordering::Release);
        self.last_pos_in_epoch.store(mono_pos, Ordering::Relaxed);
        self.hw_pos_raw.store(mono_pos, Ordering::Relaxed);
        self.hw_qpc_100ns.store(qpc_100ns, Ordering::Relaxed);
        self.hw_valid.store(true, Ordering::Relaxed);
        self.seq.store(s.wrapping_add(2), Ordering::Release);
    }

    pub fn on_reset(&self) {
        let s = self.seq.load(Ordering::Relaxed);
        self.seq.store(s.wrapping_add(1), Ordering::Release);
        std::sync::atomic::fence(Ordering::Release);
        self.last_pos_in_epoch.store(0, Ordering::Relaxed);
        self.hw_pos_raw.store(0, Ordering::Relaxed);
        self.hw_qpc_100ns.store(0, Ordering::Relaxed);
        self.clock_epoch.fetch_add(1, Ordering::Relaxed);
        self.seq.store(s.wrapping_add(2), Ordering::Release);
    }

    pub fn snapshot(&self) -> Option<WasapiClockSnapshot> {
        for _ in 0..8 {
            let s1 = self.seq.load(Ordering::Acquire);
            if s1 & 1 != 0 {
                std::hint::spin_loop();
                continue;
            }
            if !self.hw_valid.load(Ordering::Acquire) {
                return None;
            }
            let position = self.hw_pos_raw.load(Ordering::Relaxed);
            let frequency = self.hw_freq.load(Ordering::Relaxed);
            let qpc_100ns = self.hw_qpc_100ns.load(Ordering::Relaxed);
            let clock_epoch = self.clock_epoch.load(Ordering::Relaxed);
            let sample_rate = self.sample_rate.load(Ordering::Relaxed);
            std::sync::atomic::fence(Ordering::Acquire);
            let s2 = self.seq.load(Ordering::Acquire);
            if s1 == s2 {
                if frequency == 0 {
                    return None;
                }
                return Some(WasapiClockSnapshot {
                    position,
                    frequency,
                    qpc_100ns,
                    clock_epoch,
                    sample_rate,
                });
            }
        }
        None
    }

    pub fn hardware_position_frames(&self) -> Option<u64> {
        let snap = self.snapshot()?;
        Some(((snap.position as u128 * snap.sample_rate as u128) / snap.frequency as u128) as u64)
    }

    pub fn clock_position_ns(&self) -> Option<u64> {
        let snap = self.snapshot()?;
        Some(((snap.position as u128 * 1_000_000_000u128) / snap.frequency as u128) as u64)
    }
}

/// Fills `dst` with format-appropriate silence (`0x69` for Native DSD, alternating DoP v1.1
/// `0x05`/`0xFA` + `0x69` frames for DoP, `0x00` for PCM).
pub fn fill_wasapi_wire_silence(
    dst: &mut [u8],
    wire: WireSampleFormat,
    channels: u16,
    dop_phase: &mut bool,
) {
    match wire {
        WireSampleFormat::NativeDsd { .. } => {
            dst.fill(0x69);
        }
        WireSampleFormat::Dop24In32MsbLe { .. } => {
            let ch = channels.max(1) as usize;
            let frame_bytes = ch * 4;
            let aligned = (dst.len() / frame_bytes) * frame_bytes;
            for frame in dst[..aligned].chunks_exact_mut(frame_bytes) {
                let marker = if *dop_phase { 0xFAu8 } else { 0x05u8 };
                *dop_phase = !*dop_phase;
                for sample in frame.as_chunks_mut::<4>().0 {
                    sample[0] = 0x00;
                    sample[1] = 0x69;
                    sample[2] = 0x69;
                    sample[3] = marker;
                }
            }
            if aligned < dst.len() {
                dst[aligned..].fill(0x00);
            }
        }
        _ => {
            dst.fill(0x00);
        }
    }
}

#[inline]
fn wasapi_chunk_has_nonzero(data: &[u8], wire: WireSampleFormat) -> bool {
    match wire {
        WireSampleFormat::NativeDsd { .. } => data.iter().any(|&b| b != 0x69),
        WireSampleFormat::Dop24In32MsbLe { .. } => data
            .as_chunks::<4>()
            .0
            .iter()
            .any(|s| s[0] != 0x00 || s[1] != 0x69 || s[2] != 0x69 || (s[3] != 0x05 && s[3] != 0xFA)),
        _ => data.iter().any(|&b| b != 0),
    }
}

/// Trait abstracting COM WASAPI stream operations so `run_wasapi_render_loop` can be tested
/// deterministically with real Win32 events and fake COM ops.
#[doc(hidden)]
pub trait WasapiStreamOps {
    fn start(&mut self) -> Result<(), HRESULT>;
    fn stop(&mut self) -> Result<(), HRESULT>;
    fn reset(&mut self) -> Result<(), HRESULT>;
    fn reset_buf_event(&mut self);
    fn current_padding(&mut self) -> Result<u32, HRESULT>;
    fn get_buffer(&mut self, num_frames: u32) -> Result<*mut u8, HRESULT>;
    fn release_buffer(&mut self, num_frames_written: u32, flags: u32) -> Result<(), HRESULT>;
    fn clock_frequency(&mut self) -> Option<u64>;
    fn clock_position(&mut self) -> Result<(u64, u64), HRESULT>;
}

struct RealWasapiStreamOps {
    client: IAudioClient,
    render: IAudioRenderClient,
    clock: Option<IAudioClock>,
    buf_event: Arc<Win32Event>,
}

impl WasapiStreamOps for RealWasapiStreamOps {
    fn start(&mut self) -> Result<(), HRESULT> {
        unsafe { self.client.Start() }.map_err(|e| e.code())
    }

    fn stop(&mut self) -> Result<(), HRESULT> {
        unsafe { self.client.Stop() }.map_err(|e| e.code())
    }

    fn reset(&mut self) -> Result<(), HRESULT> {
        unsafe { self.client.Reset() }.map_err(|e| e.code())
    }

    fn reset_buf_event(&mut self) {
        self.buf_event.reset();
    }

    fn current_padding(&mut self) -> Result<u32, HRESULT> {
        unsafe { self.client.GetCurrentPadding() }.map_err(|e| e.code())
    }

    fn get_buffer(&mut self, num_frames: u32) -> Result<*mut u8, HRESULT> {
        unsafe { self.render.GetBuffer(num_frames) }.map_err(|e| e.code())
    }

    fn release_buffer(&mut self, num_frames_written: u32, flags: u32) -> Result<(), HRESULT> {
        unsafe { self.render.ReleaseBuffer(num_frames_written, flags) }.map_err(|e| e.code())
    }

    fn clock_frequency(&mut self) -> Option<u64> {
        self.clock
            .as_ref()
            .and_then(|c| unsafe { c.GetFrequency().ok() })
            .filter(|&f| f > 0)
    }

    fn clock_position(&mut self) -> Result<(u64, u64), HRESULT> {
        if let Some(c) = &self.clock {
            let mut pos = 0u64;
            let mut qpc = 0u64;
            unsafe { c.GetPosition(&mut pos, Some(&mut qpc)) }.map_err(|e| e.code())?;
            Ok((pos, qpc))
        } else {
            Err(HRESULT(-1))
        }
    }
}

/// Shared synchronization & control block between `WasapiExclusiveSession` and the render thread.
#[doc(hidden)]
pub struct WasapiRenderControl {
    pub buf_event: Arc<Win32Event>,
    pub stop_event: Arc<Win32Event>,
    pub wake_event: Arc<Win32Event>,
    pub paused: Arc<AtomicBool>,
    pub stopped: Arc<AtomicBool>,
    pub device_lost: Arc<AtomicBool>,
    pub eof_drained: Arc<AtomicBool>,
    pub eof_target_state: Arc<AtomicI32>,
    pub eof_flag: Arc<AtomicBool>,
    pub frames_rendered: Arc<AtomicU64>,
    pub nonzero_frames: Arc<AtomicU64>,
    pub state_code: Arc<AtomicI32>,
    pub last_error: Arc<RwLock<Option<String>>>,
    pub session_id: u64,
    pub current_session_id: Arc<AtomicU64>,
    pub flush_req_seq: AtomicU64,
    pub flush_ack: (Mutex<u64>, Condvar),
    pub clock_state: Arc<WasapiClockState>,
}

impl WasapiRenderControl {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        buf_event: Arc<Win32Event>,
        stop_event: Arc<Win32Event>,
        wake_event: Arc<Win32Event>,
        sample_rate: u32,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        session_id: u64,
        current_session_id: Arc<AtomicU64>,
    ) -> Self {
        Self {
            buf_event,
            stop_event,
            wake_event,
            paused: Arc::new(AtomicBool::new(false)),
            stopped: Arc::new(AtomicBool::new(false)),
            device_lost: Arc::new(AtomicBool::new(false)),
            eof_drained: Arc::new(AtomicBool::new(false)),
            eof_target_state: Arc::new(AtomicI32::new(1)),
            eof_flag,
            frames_rendered,
            nonzero_frames,
            state_code,
            last_error,
            session_id,
            current_session_id,
            flush_req_seq: AtomicU64::new(0),
            flush_ack: (Mutex::new(0), Condvar::new()),
            clock_state: Arc::new(WasapiClockState::new(sample_rate)),
        }
    }

    pub fn set_paused(&self, p: bool) {
        self.paused.store(p, Ordering::SeqCst);
        self.wake_event.signal();
    }

    pub fn request_flush(&self) {
        self.flush_req_seq.fetch_add(1, Ordering::SeqCst);
        self.wake_event.signal();
    }

    pub fn flush(&self) -> Result<(), BackendError> {
        if self.device_lost.load(Ordering::Acquire) {
            return Err(BackendError::DeviceNotFound(
                "WASAPI device lost before flush".into(),
            ));
        }
        if self.stopped.load(Ordering::Acquire) {
            return Ok(());
        }

        let mut ack = self
            .flush_ack
            .0
            .lock()
            .map_err(|_| BackendError::DriverError("WASAPI flush mutex poisoned".into()))?;
        let req = self.flush_req_seq.fetch_add(1, Ordering::SeqCst) + 1;
        self.wake_event.signal();

        let deadline = Instant::now() + Duration::from_secs(2);
        while *ack < req {
            if self.device_lost.load(Ordering::Acquire) {
                return Err(BackendError::DeviceNotFound(
                    "WASAPI device invalidated during flush".into(),
                ));
            }
            if self.stopped.load(Ordering::Acquire)
                || self.current_session_id.load(Ordering::Relaxed) != self.session_id
            {
                return Err(BackendError::DriverError(
                    "WASAPI session stopped during flush".into(),
                ));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(BackendError::DriverError(
                    "WASAPI flush timed out waiting for render thread".into(),
                ));
            }
            let wait_for = remaining.min(Duration::from_millis(100));
            let (guard, _) = self
                .flush_ack
                .1
                .wait_timeout(ack, wait_for)
                .map_err(|_| BackendError::DriverError("WASAPI flush condvar poisoned".into()))?;
            ack = guard;
        }
        Ok(())
    }

    pub fn is_device_lost(&self) -> bool {
        self.device_lost.load(Ordering::Acquire)
    }

    pub fn is_eof_drained(&self) -> bool {
        self.eof_drained.load(Ordering::Acquire)
    }

    pub fn set_eof_state_code(&self, code: i32) {
        self.eof_target_state.store(code, Ordering::SeqCst);
    }

    pub fn clock_snapshot(&self) -> Option<WasapiClockSnapshot> {
        self.clock_state.snapshot()
    }

    pub fn hardware_position_frames(&self) -> Option<u64> {
        self.clock_state.hardware_position_frames()
    }

    pub fn clock_position_ns(&self) -> Option<u64> {
        self.clock_state.clock_position_ns()
    }
}

#[inline]
fn is_device_lost_hr(hr: HRESULT) -> bool {
    hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING
}

fn record_wasapi_error(ctrl: &WasapiRenderControl, hr: HRESULT, msg: &str) {
    if is_device_lost_hr(hr) {
        ctrl.device_lost.store(true, Ordering::SeqCst);
    }
    if let Ok(mut g) = ctrl.last_error.write() {
        *g = Some(msg.to_string());
    }
    ctrl.state_code.store(4, Ordering::SeqCst);
}

fn ack_flush_and_wake(ctrl: &WasapiRenderControl, seq: u64) {
    if let Ok(mut g) = ctrl.flush_ack.0.lock() {
        if *g < seq {
            *g = seq;
        }
        ctrl.flush_ack.1.notify_all();
    }
}

fn wake_all_flush_waiters(ctrl: &WasapiRenderControl) {
    if let Ok(_g) = ctrl.flush_ack.0.lock() {
        ctrl.flush_ack.1.notify_all();
    }
}

#[allow(clippy::too_many_arguments)]
fn prime_wasapi_buffer<O: WasapiStreamOps>(
    ops: &mut O,
    actual_frames: u32,
    spec: &WasapiExclusiveOpenSpec,
    consumer: &mut Consumer<u8>,
    verification: &AudioVerificationEngine,
    scratch: &mut Vec<u8>,
    dop_phase: &mut bool,
    ctrl: &WasapiRenderControl,
) -> Result<(), HRESULT> {
    let bytes_per_frame = spec.wire_format.bytes_per_sample() * (spec.channels.max(1) as usize);
    let needed = (actual_frames as usize) * bytes_per_frame;
    if scratch.len() < needed {
        scratch.resize(needed, 0);
    }

    let ptr = ops.get_buffer(actual_frames)?;
    let read = consumer.pop_slice(&mut scratch[..needed]);
    let aligned_read = (read / bytes_per_frame) * bytes_per_frame;
    if aligned_read > 0 && matches!(spec.wire_format, WireSampleFormat::Dop24In32MsbLe { .. }) {
        *dop_phase = scratch[aligned_read - 1] == 0x05;
    }
    if aligned_read < needed {
        fill_wasapi_wire_silence(
            &mut scratch[aligned_read..needed],
            spec.wire_format,
            spec.channels,
            dop_phase,
        );
    }
    if aligned_read > 0 {
        let frames = (aligned_read / bytes_per_frame) as u64;
        verification.record_backend_input_wire(
            &scratch[..aligned_read],
            spec.wire_format,
            spec.channels,
            spec.sample_rate,
        );
        ctrl.frames_rendered.fetch_add(frames, Ordering::Relaxed);
        if wasapi_chunk_has_nonzero(&scratch[..aligned_read], spec.wire_format) {
            ctrl.nonzero_frames.fetch_add(frames, Ordering::Relaxed);
        }
    }
    unsafe {
        std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
    }
    ops.release_buffer(actual_frames, 0)?;
    Ok(())
}

/// Core WASAPI render loop, factored over [`WasapiStreamOps`] for both real COM hardware
/// execution and deterministic Win32 event-driven testing.
#[doc(hidden)]
pub fn run_wasapi_render_loop<O: WasapiStreamOps>(
    ops: &mut O,
    spec: &WasapiExclusiveOpenSpec,
    actual_frames: u32,
    consumer: &mut Consumer<u8>,
    verification: &AudioVerificationEngine,
    ctrl: &WasapiRenderControl,
) {
    if let Some(freq) = ops.clock_frequency() {
        ctrl.clock_state.set_frequency(freq);
    }

    let bytes_per_frame = spec.wire_format.bytes_per_sample() * (spec.channels.max(1) as usize);
    let mut scratch = vec![0u8; (actual_frames as usize) * bytes_per_frame];
    let mut dop_phase = false;

    if let Err(hr) = prime_wasapi_buffer(
        ops,
        actual_frames,
        spec,
        consumer,
        verification,
        &mut scratch,
        &mut dop_phase,
        ctrl,
    ) {
        record_wasapi_error(
            ctrl,
            hr,
            &format!("WASAPI initial buffer prime failed: HRESULT=0x{:08X}", hr.0 as u32),
        );
        ctrl.stopped.store(true, Ordering::Release);
        wake_all_flush_waiters(ctrl);
        return;
    }

    if let Err(hr) = ops.start() {
        record_wasapi_error(
            ctrl,
            hr,
            &format!("WASAPI IAudioClient::Start failed: HRESULT=0x{:08X}", hr.0 as u32),
        );
        ctrl.stopped.store(true, Ordering::Release);
        wake_all_flush_waiters(ctrl);
        return;
    }

    let events = [
        ctrl.buf_event.raw(),
        ctrl.stop_event.raw(),
        ctrl.wake_event.raw(),
    ];
    let mut was_paused = false;
    let mut needs_prime = false;
    let mut last_handled_flush_seq = 0u64;
    let mut draining_eof = false;
    let mut drain_deadline: Option<Instant> = None;

    loop {
        let timeout_ms = if draining_eof { 10 } else { 100 };
        let wait = unsafe { WaitForMultipleObjects(&events, false, timeout_ms) };

        if ctrl.stopped.load(Ordering::Acquire)
            || ctrl.current_session_id.load(Ordering::Relaxed) != ctrl.session_id
        {
            break;
        }
        if wait.0 == WAIT_OBJECT_0.0 + 1 {
            break;
        }
        if wait.0 == 0xFFFF_FFFF {
            let err = std::io::Error::last_os_error();
            if let Ok(mut g) = ctrl.last_error.write() {
                *g = Some(format!("WASAPI WaitForMultipleObjects failed: {err}"));
            }
            ctrl.state_code.store(4, Ordering::SeqCst);
            break;
        }

        // 1. Flush handling (processed before pause/render on ANY wake).
        let req_seq = ctrl.flush_req_seq.load(Ordering::Acquire);
        if req_seq > last_handled_flush_seq {
            if !was_paused
                && let Err(hr) = ops.stop()
            {
                record_wasapi_error(
                    ctrl,
                    hr,
                    &format!("WASAPI Stop during flush failed: HRESULT=0x{:08X}", hr.0 as u32),
                );
                wake_all_flush_waiters(ctrl);
                break;
            }

            if let Err(hr) = ops.reset() {
                if hr == AUDCLNT_E_NOT_STOPPED {
                    let _ = ops.stop();
                    if let Err(hr2) = ops.reset() {
                        record_wasapi_error(
                            ctrl,
                            hr2,
                            &format!(
                                "WASAPI Reset retry during flush failed: HRESULT=0x{:08X}",
                                hr2.0 as u32
                            ),
                        );
                        wake_all_flush_waiters(ctrl);
                        break;
                    }
                } else {
                    record_wasapi_error(
                        ctrl,
                        hr,
                        &format!("WASAPI Reset during flush failed: HRESULT=0x{:08X}", hr.0 as u32),
                    );
                    wake_all_flush_waiters(ctrl);
                    break;
                }
            }

            ops.reset_buf_event();
            if consumer.has_pending_flush() {
                consumer.flush_and_ack();
            } else {
                consumer.clear();
            }
            ctrl.clock_state.on_reset();
            draining_eof = false;
            drain_deadline = None;
            ctrl.eof_drained.store(false, Ordering::Release);
            dop_phase = false;

            let now_paused = ctrl.paused.load(Ordering::Acquire);
            if now_paused {
                was_paused = true;
                needs_prime = true;
            } else {
                if let Err(hr) = prime_wasapi_buffer(
                    ops,
                    actual_frames,
                    spec,
                    consumer,
                    verification,
                    &mut scratch,
                    &mut dop_phase,
                    ctrl,
                ) {
                    record_wasapi_error(
                        ctrl,
                        hr,
                        &format!(
                            "WASAPI post-flush prime failed: HRESULT=0x{:08X}",
                            hr.0 as u32
                        ),
                    );
                    wake_all_flush_waiters(ctrl);
                    break;
                }
                if let Err(hr) = ops.start() {
                    record_wasapi_error(
                        ctrl,
                        hr,
                        &format!(
                            "WASAPI post-flush Start failed: HRESULT=0x{:08X}",
                            hr.0 as u32
                        ),
                    );
                    wake_all_flush_waiters(ctrl);
                    break;
                }
                was_paused = false;
                needs_prime = false;
            }

            last_handled_flush_seq = req_seq;
            ack_flush_and_wake(ctrl, req_seq);
            continue;
        }

        // 2. Pause / Resume handling (processed on ANY wake, preventing WAIT_TIMEOUT deadlock).
        let now_paused = ctrl.paused.load(Ordering::Acquire);
        if now_paused && !was_paused {
            if let Ok((pos, qpc)) = ops.clock_position() {
                ctrl.clock_state.record_position(pos, qpc);
            }
            if let Err(hr) = ops.stop() {
                record_wasapi_error(
                    ctrl,
                    hr,
                    &format!("WASAPI Stop on pause failed: HRESULT=0x{:08X}", hr.0 as u32),
                );
                break;
            }
            was_paused = true;
            continue;
        } else if !now_paused && was_paused {
            if needs_prime {
                if let Err(hr) = prime_wasapi_buffer(
                    ops,
                    actual_frames,
                    spec,
                    consumer,
                    verification,
                    &mut scratch,
                    &mut dop_phase,
                    ctrl,
                ) {
                    record_wasapi_error(
                        ctrl,
                        hr,
                        &format!(
                            "WASAPI resume prime failed: HRESULT=0x{:08X}",
                            hr.0 as u32
                        ),
                    );
                    break;
                }
                needs_prime = false;
            }
            if let Err(hr) = ops.start() {
                record_wasapi_error(
                    ctrl,
                    hr,
                    &format!("WASAPI Start on resume failed: HRESULT=0x{:08X}", hr.0 as u32),
                );
                break;
            }
            was_paused = false;
            continue;
        }
        if now_paused {
            continue;
        }

        // 3. EOF hardware buffer drain check (before requiring a new buffer event).
        if draining_eof {
            match ops.current_padding() {
                Ok(padding) => {
                    if let Ok((pos, qpc)) = ops.clock_position() {
                        ctrl.clock_state.record_position(pos, qpc);
                    }
                    if padding == 0 || drain_deadline.is_some_and(|d| Instant::now() >= d) {
                        ctrl.eof_drained.store(true, Ordering::SeqCst);
                        let target = ctrl.eof_target_state.load(Ordering::Relaxed);
                        let _ = ctrl.state_code.compare_exchange(
                            2,
                            target,
                            Ordering::SeqCst,
                            Ordering::SeqCst,
                        );
                        break;
                    }
                    continue;
                }
                Err(hr) => {
                    record_wasapi_error(
                        ctrl,
                        hr,
                        &format!(
                            "WASAPI GetCurrentPadding during EOF drain failed: HRESULT=0x{:08X}",
                            hr.0 as u32
                        ),
                    );
                    break;
                }
            }
        }

        // 4. Strict wake gate: only invoke GetBuffer when WASAPI signaled buf_event (WAIT_OBJECT_0).
        if wait.0 != WAIT_OBJECT_0.0 {
            continue;
        }

        // 5. Render next audio period.
        match ops.get_buffer(actual_frames) {
            Ok(ptr) => {
                let needed = (actual_frames as usize) * bytes_per_frame;
                if scratch.len() < needed {
                    scratch.resize(needed, 0);
                }
                let got = consumer.pop_slice(&mut scratch[..needed]);
                let aligned_bytes = (got / bytes_per_frame) * bytes_per_frame;

                if aligned_bytes > 0 {
                    if matches!(spec.wire_format, WireSampleFormat::Dop24In32MsbLe { .. }) {
                        dop_phase = scratch[aligned_bytes - 1] == 0x05;
                    }
                    if aligned_bytes < needed {
                        fill_wasapi_wire_silence(
                            &mut scratch[aligned_bytes..needed],
                            spec.wire_format,
                            spec.channels,
                            &mut dop_phase,
                        );
                    }
                    unsafe {
                        std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                    }
                    let frames = (aligned_bytes / bytes_per_frame) as u64;
                    verification.record_backend_input_wire(
                        &scratch[..aligned_bytes],
                        spec.wire_format,
                        spec.channels,
                        spec.sample_rate,
                    );
                    ctrl.frames_rendered.fetch_add(frames, Ordering::Relaxed);
                    if wasapi_chunk_has_nonzero(&scratch[..aligned_bytes], spec.wire_format) {
                        ctrl.nonzero_frames.fetch_add(frames, Ordering::Relaxed);
                    }

                    if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                        record_wasapi_error(
                            ctrl,
                            hr,
                            &format!(
                                "WASAPI ReleaseBuffer failed: HRESULT=0x{:08X}",
                                hr.0 as u32
                            ),
                        );
                        break;
                    }
                    if let Ok((pos, qpc)) = ops.clock_position() {
                        ctrl.clock_state.record_position(pos, qpc);
                    }
                } else if ctrl.eof_flag.load(Ordering::SeqCst)
                    && consumer.available_read() < bytes_per_frame
                {
                    // Release empty without pushing an extra full period of trailing silence.
                    if let Err(hr) = ops.release_buffer(0, 0) {
                        record_wasapi_error(
                            ctrl,
                            hr,
                            &format!(
                                "WASAPI ReleaseBuffer(0) at EOF failed: HRESULT=0x{:08X}",
                                hr.0 as u32
                            ),
                        );
                        break;
                    }
                    match ops.current_padding() {
                        Ok(0) => {
                            if let Ok((pos, qpc)) = ops.clock_position() {
                                ctrl.clock_state.record_position(pos, qpc);
                            }
                            ctrl.eof_drained.store(true, Ordering::SeqCst);
                            let target = ctrl.eof_target_state.load(Ordering::Relaxed);
                            let _ = ctrl.state_code.compare_exchange(
                                2,
                                target,
                                Ordering::SeqCst,
                                Ordering::SeqCst,
                            );
                            break;
                        }
                        Ok(_) => {
                            draining_eof = true;
                            let buf_ms = ((actual_frames as u64 * 1000)
                                / spec.sample_rate.max(1) as u64)
                                .max(10);
                            drain_deadline =
                                Some(Instant::now() + Duration::from_millis((buf_ms * 3).clamp(50, 500)));
                            continue;
                        }
                        Err(hr) => {
                            record_wasapi_error(
                                ctrl,
                                hr,
                                &format!(
                                    "WASAPI GetCurrentPadding at EOF failed: HRESULT=0x{:08X}",
                                    hr.0 as u32
                                ),
                            );
                            break;
                        }
                    }
                } else {
                    // Transient underrun while track still playing: emit format-appropriate silence.
                    fill_wasapi_wire_silence(
                        &mut scratch[..needed],
                        spec.wire_format,
                        spec.channels,
                        &mut dop_phase,
                    );
                    unsafe {
                        std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                    }
                    if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                        record_wasapi_error(
                            ctrl,
                            hr,
                            &format!(
                                "WASAPI ReleaseBuffer(silence) failed: HRESULT=0x{:08X}",
                                hr.0 as u32
                            ),
                        );
                        break;
                    }
                    if let Ok((pos, qpc)) = ops.clock_position() {
                        ctrl.clock_state.record_position(pos, qpc);
                    }
                }
            }
            Err(hr) => {
                if hr == AUDCLNT_E_BUFFER_TOO_LARGE {
                    continue;
                }
                record_wasapi_error(
                    ctrl,
                    hr,
                    &format!("WASAPI GetBuffer failed: HRESULT=0x{:08X}", hr.0 as u32),
                );
                break;
            }
        }
    }

    let _ = ops.stop();
    ctrl.stopped.store(true, Ordering::Release);
    wake_all_flush_waiters(ctrl);
}

/// Active native Windows COM WASAPI Exclusive Event-Driven playback session.
/// Bypasses Windows `audiodg.exe` mixer completely and transfers raw wire bytes directly to `IAudioRenderClient`.
pub struct WasapiExclusiveSession {
    pub device_name: String,
    pub actual_buffer_frames: u32,
    pub wire_format: WireSampleFormat,
    ctrl: Arc<WasapiRenderControl>,
    handle: Option<JoinHandle<()>>,
}

impl WasapiExclusiveSession {
    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start(
        spec: WasapiExclusiveOpenSpec,
        mut consumer: Consumer<u8>,
        verification: AudioVerificationEngine,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        session_id: u64,
        current_session_id: Arc<AtomicU64>,
    ) -> Result<Self, BackendError> {
        let stop_event = Arc::new(Win32Event::new_manual_reset()?);
        let wake_event = Arc::new(Win32Event::new_auto_reset()?);

        let (ack_tx, ack_rx) = mpsc::sync_channel::<
            Result<(String, u32, Arc<WasapiRenderControl>), BackendError>,
        >(1);
        let thread_spec = spec.clone();
        let thread_stop_event = Arc::clone(&stop_event);
        let thread_wake_event = Arc::clone(&wake_event);

        let handle = thread::Builder::new()
            .name("lumina-wasapi-exclusive".to_string())
            .spawn(move || {
                let _com = ComGuard::init_mta();
                let open_res = unsafe { open_client_exclusive(&thread_spec) };
                let (client, render, clock, buf_event, actual_frames, dev_name) = match open_res {
                    Ok(v) => v,
                    Err(e) => {
                        let _ = ack_tx.send(Err(e));
                        return;
                    }
                };

                let ctrl = Arc::new(WasapiRenderControl::new(
                    Arc::clone(&buf_event),
                    thread_stop_event,
                    thread_wake_event,
                    thread_spec.sample_rate,
                    frames_rendered,
                    nonzero_frames,
                    state_code,
                    eof_flag,
                    last_error,
                    session_id,
                    current_session_id,
                ));

                if ack_tx
                    .send(Ok((dev_name, actual_frames, Arc::clone(&ctrl))))
                    .is_err()
                {
                    return;
                }

                // Elevate render thread via MMCSS "Pro Audio"
                let mut task_idx = 0u32;
                let task_wide: Vec<u16> = "Pro Audio\0".encode_utf16().collect();
                let mmcss_handle = unsafe {
                    AvSetMmThreadCharacteristicsW(PCWSTR(task_wide.as_ptr()), &mut task_idx)
                }
                .ok();

                let mut ops = RealWasapiStreamOps {
                    client,
                    render,
                    clock,
                    buf_event,
                };
                run_wasapi_render_loop(
                    &mut ops,
                    &thread_spec,
                    actual_frames,
                    &mut consumer,
                    &verification,
                    &ctrl,
                );

                if let Some(h) = mmcss_handle {
                    let _ = unsafe { AvRevertMmThreadCharacteristics(h) };
                }
            })
            .map_err(|e| BackendError::DriverError(format!("Failed to spawn WASAPI thread: {e}")))?;

        match ack_rx.recv() {
            Ok(Ok((device_name, actual_buffer_frames, ctrl))) => Ok(Self {
                device_name,
                actual_buffer_frames,
                wire_format: spec.wire_format,
                ctrl,
                handle: Some(handle),
            }),
            Ok(Err(e)) => {
                let _ = handle.join();
                Err(e)
            }
            Err(_) => {
                let _ = handle.join();
                Err(BackendError::DriverError(
                    "WASAPI exclusive thread terminated during open".into(),
                ))
            }
        }
    }

    pub fn set_paused(&self, p: bool) {
        self.ctrl.set_paused(p);
    }

    pub fn request_flush(&self) {
        self.ctrl.request_flush();
    }

    pub fn flush(&self) -> Result<(), BackendError> {
        self.ctrl.flush()
    }

    pub fn is_device_lost(&self) -> bool {
        self.ctrl.is_device_lost()
    }

    pub fn is_eof_drained(&self) -> bool {
        self.ctrl.is_eof_drained()
    }

    pub fn set_eof_state_code(&self, code: i32) {
        self.ctrl.set_eof_state_code(code);
    }

    pub fn clock_snapshot(&self) -> Option<WasapiClockSnapshot> {
        self.ctrl.clock_snapshot()
    }

    pub fn hardware_position_frames(&self) -> Option<u64> {
        self.ctrl.hardware_position_frames()
    }

    pub fn clock_position_ns(&self) -> Option<u64> {
        self.ctrl.clock_position_ns()
    }

    fn shutdown_internal(&mut self) {
        self.ctrl.stopped.store(true, Ordering::SeqCst);
        self.ctrl.stop_event.signal();
        self.ctrl.wake_event.signal();
        wake_all_flush_waiters(&self.ctrl);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }

    pub fn stop(mut self) {
        self.shutdown_internal();
    }
}

impl Drop for WasapiExclusiveSession {
    fn drop(&mut self) {
        self.shutdown_internal();
    }
}

unsafe fn resolve_mmdevice(
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
        unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eConsole) }.map_err(|e| {
            BackendError::DeviceNotFound(format!("No default WASAPI endpoint: {e}"))
        })?
    };

    let pkey_friendly = to_shell_pkey(
        GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
        14,
    );
    let name = unsafe { device.OpenPropertyStore(STGM_READ) }
        .ok()
        .and_then(|st| unsafe { read_prop_string(&st, &pkey_friendly) })
        .unwrap_or_else(|| "WASAPI Exclusive Endpoint".to_string());

    Ok((device, name))
}

type OpenedExclusiveClient = (
    IAudioClient,
    IAudioRenderClient,
    Option<IAudioClock>,
    Arc<Win32Event>,
    u32,
    String,
);

unsafe fn open_client_exclusive(
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

    let hint_hns = ((spec.buffer_frames_hint.max(64) as i64) * 10_000_000) / (spec.sample_rate.max(8000) as i64);
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
            period = ((10_000_000.0 * aligned_frames as f64) / spec.sample_rate as f64 + 0.5) as i64;
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
        return Err(BackendError::DriverError(format!("SetEventHandle failed: {e}")));
    }

    let render: IAudioRenderClient = unsafe { client.GetService() }
        .map_err(|e| BackendError::DriverError(format!("GetService<IAudioRenderClient> failed: {e}")))?;
    let clock: Option<IAudioClock> = unsafe { client.GetService().ok() };

    let _ = AUDCLNT_SHAREMODE_SHARED;
    let _ = OutputBackendKind::WindowsWasapiExclusive;
    let _ = OutputMode::WasapiExclusive;

    Ok((client, render, clock, buf_event, actual_buffer_frames, dev_name))
}

fn map_wasapi_hresult(hr: HRESULT, context: &str) -> BackendError {
    if hr == AUDCLNT_E_DEVICE_IN_USE || hr == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED {
        BackendError::DeviceInUse
    } else if hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING {
        BackendError::DeviceNotFound(context.to_string())
    } else {
        BackendError::DriverError(context.to_string())
    }
}
