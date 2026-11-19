use std::ffi::{c_char, c_void, CStr};
use std::ptr::{null_mut, NonNull};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex, RwLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use core_types::DsdRate;
use windows::core::{GUID, PCWSTR, PWSTR};
use windows::Win32::Foundation::{S_FALSE, S_OK};
use windows::Win32::System::Com::{
    CLSIDFromString, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
    COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Registry::{
    RegCloseKey, RegEnumKeyExW, RegOpenKeyExW, RegQueryValueExW, HKEY, HKEY_LOCAL_MACHINE,
    KEY_READ, REG_SZ, REG_VALUE_TYPE,
};

use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::verification::{AudioVerificationEngine, WireSampleFormat};

// Standard Steinberg ASIO SDK integer/float/DSD sample types & selectors (clean-room binary ABI).
pub const ASIO_OK: i32 = 0;
pub const ASIO_SUCCESS: i32 = 0x3f4847a0;
pub const ASIO_TRUE: i32 = 1;

pub const ASIO_ST_INT16_LSB: i32 = 16;
pub const ASIO_ST_INT24_LSB: i32 = 17;
pub const ASIO_ST_INT32_LSB: i32 = 18;
pub const ASIO_ST_FLOAT32_LSB: i32 = 19;
pub const ASIO_ST_FLOAT64_LSB: i32 = 20;
pub const ASIO_ST_DSD_INT8_LSB1: i32 = 32;
pub const ASIO_ST_DSD_INT8_MSB1: i32 = 33;
pub const ASIO_ST_DSD_INT8_LSB8: i32 = 40;

pub const K_ASIO_SELECTOR_SUPPORTED: i32 = 1;
pub const K_ASIO_ENGINE_VERSION: i32 = 2;
pub const K_ASIO_RESET_REQUEST: i32 = 3;
pub const K_ASIO_BUFFER_SIZE_CHANGE: i32 = 4;
pub const K_ASIO_RESYNC_REQUEST: i32 = 5;
pub const K_ASIO_LATENCIES_CHANGED: i32 = 6;
pub const K_ASIO_SUPPORTS_TIME_INFO: i32 = 7;
pub const K_ASIO_SUPPORTS_TIME_CODE: i32 = 8;

const K_ASIO_SET_IO_FORMAT: i32 = 0x23111961;
const K_ASIO_CAN_DO_IO_FORMAT: i32 = 0x23112004;
const K_ASIO_FORMAT_PCM: i32 = 0;
const K_ASIO_FORMAT_DSD: i32 = 1;

const PROBABLE_RATES: [u32; 16] = [
    44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
    2_822_400, 5_644_800, 11_289_600, 22_579_200, 3_072_000, 6_144_000,
];
const DSD_PROBE_RATES: [u32; 4] = [2_822_400, 5_644_800, 11_289_600, 22_579_200];

/// Steinberg ASIO 2.x 64-bit sample counter / timestamp (`hi` word first in memory on Win64).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AsioSamples {
    pub hi: u32,
    pub lo: u32,
}

pub type AsioTimeStamp = AsioSamples;

impl AsioSamples {
    #[inline]
    pub const fn to_u64(self) -> u64 {
        ((self.hi as u64) << 32) | (self.lo as u64)
    }

    #[inline]
    pub const fn from_u64(v: u64) -> Self {
        Self {
            hi: (v >> 32) as u32,
            lo: v as u32,
        }
    }
}

pub const ASIO_TIME_INFO_SYSTEM_TIME_VALID: u32 = 1 << 0;
pub const ASIO_TIME_INFO_SAMPLE_POSITION_VALID: u32 = 1 << 1;

#[repr(C, packed(4))]
#[derive(Clone, Copy, Default)]
pub struct AsioTimeInfo {
    pub speed: f64,
    pub system_time: AsioTimeStamp,
    pub sample_position: AsioSamples,
    pub sample_rate: f64,
    pub flags: u32,
    pub reserved: [u8; 12],
}

#[repr(C, packed(4))]
#[derive(Clone, Copy, Default)]
pub struct AsioTime {
    pub reserved: [i32; 4],
    pub time_info: AsioTimeInfo,
}

#[repr(C, packed(4))]
#[derive(Clone, Copy)]
struct AsioBufferInfo {
    is_input: i32,
    channel_num: i32,
    buffers: [*mut c_void; 2],
}

#[repr(C, packed(4))]
#[derive(Clone, Copy)]
struct AsioChannelInfo {
    channel: i32,
    is_input: i32,
    is_active: i32,
    channel_group: i32,
    sample_type: i32,
    name: [c_char; 32],
}

#[repr(C, packed(4))]
struct AsioIoFormat {
    format_type: i32,
    future: [u8; 508],
}

#[repr(C)]
struct AsioCallbacks {
    buffer_switch: unsafe extern "C" fn(double_buffer_index: i32, direct_process: i32),
    sample_rate_did_change: unsafe extern "C" fn(s_rate: f64),
    asio_message: unsafe extern "C" fn(
        selector: i32,
        value: i32,
        message: *const c_void,
        opt: *const f64,
    ) -> i32,
    buffer_switch_time_info: unsafe extern "C" fn(
        params: *const c_void,
        double_buffer_index: i32,
        direct_process: i32,
    ) -> *const c_void,
}

/// Clean-room COM `IASIO` vtable matching Win64 MSVC ABI (slots 0..=23).
#[repr(C)]
struct IAsioVtbl {
    // IUnknown (0..2)
    query_interface: unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> i32,
    add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    // IASIO (3..23)
    init: unsafe extern "C" fn(*mut c_void, *mut c_void) -> i32,
    get_driver_name: unsafe extern "C" fn(*mut c_void, *mut c_char),
    get_driver_version: unsafe extern "C" fn(*mut c_void) -> i32,
    get_error_message: unsafe extern "C" fn(*mut c_void, *mut c_char),
    start: unsafe extern "C" fn(*mut c_void) -> i32,
    stop: unsafe extern "C" fn(*mut c_void) -> i32,
    get_channels: unsafe extern "C" fn(*mut c_void, *mut i32, *mut i32) -> i32,
    get_latencies: unsafe extern "C" fn(*mut c_void, *mut i32, *mut i32) -> i32,
    get_buffer_size: unsafe extern "C" fn(*mut c_void, *mut i32, *mut i32, *mut i32, *mut i32) -> i32,
    can_sample_rate: unsafe extern "C" fn(*mut c_void, f64) -> i32,
    get_sample_rate: unsafe extern "C" fn(*mut c_void, *mut f64) -> i32,
    set_sample_rate: unsafe extern "C" fn(*mut c_void, f64) -> i32,
    get_clock_sources: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut i32) -> i32,
    set_clock_source: unsafe extern "C" fn(*mut c_void, i32) -> i32,
    get_sample_position: unsafe extern "C" fn(*mut c_void, *mut AsioSamples, *mut AsioTimeStamp) -> i32,
    get_channel_info: unsafe extern "C" fn(*mut c_void, *mut AsioChannelInfo) -> i32,
    create_buffers:
        unsafe extern "C" fn(*mut c_void, *mut AsioBufferInfo, i32, i32, *mut AsioCallbacks) -> i32,
    dispose_buffers: unsafe extern "C" fn(*mut c_void) -> i32,
    control_panel: unsafe extern "C" fn(*mut c_void) -> i32,
    future: unsafe extern "C" fn(*mut c_void, i32, *mut c_void) -> i32,
    output_ready: unsafe extern "C" fn(*mut c_void) -> i32,
}

struct ComAsioPtr(NonNull<*const IAsioVtbl>);

unsafe fn com_create_asio_instance(clsid: &GUID) -> Result<*mut c_void, i32> {
    #[link(name = "ole32")]
    unsafe extern "system" {
        fn CoCreateInstance(
            rclsid: *const GUID,
            punkouter: *mut c_void,
            dwclscontext: u32,
            riid: *const GUID,
            ppv: *mut *mut c_void,
        ) -> i32;
    }
    let mut out: *mut c_void = null_mut();
    let hr = unsafe {
        CoCreateInstance(clsid, null_mut(), CLSCTX_INPROC_SERVER.0, clsid, &mut out)
    };
    if hr >= 0 && !out.is_null() {
        Ok(out)
    } else {
        Err(hr)
    }
}

impl ComAsioPtr {
    #[inline]
    unsafe fn vtbl(&self) -> &IAsioVtbl {
        unsafe { &**self.0.as_ptr() }
    }

    #[inline]
    fn raw(&self) -> *mut c_void {
        self.0.as_ptr() as *mut c_void
    }

    unsafe fn driver_error(&self) -> String {
        let mut buf = [0i8; 128];
        unsafe { (self.vtbl().get_error_message)(self.raw(), buf.as_mut_ptr()) };
        unsafe { CStr::from_ptr(buf.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    }
}

impl Drop for ComAsioPtr {
    fn drop(&mut self) {
        unsafe {
            (self.vtbl().release)(self.raw());
        }
    }
}

struct ComStaGuard(bool);
impl ComStaGuard {
    fn init() -> Self {
        let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        Self(hr == S_OK || hr == S_FALSE)
    }
}
impl Drop for ComStaGuard {
    fn drop(&mut self) {
        if self.0 {
            unsafe { CoUninitialize() };
        }
    }
}

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

fn read_reg_string(key: HKEY, value_name: Option<&str>) -> Option<String> {
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
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Enumerates ASIO drivers registered under `HKLM\SOFTWARE\ASIO\*` and probes real COM hardware capabilities.
pub fn enumerate_asio_drivers(probe_com: bool) -> Vec<AsioDriverEntry> {
    let mut asio_root = HKEY::default();
    let subkey: Vec<u16> = "SOFTWARE\\ASIO\0".encode_utf16().collect();
    if unsafe { RegOpenKeyExW(HKEY_LOCAL_MACHINE, PCWSTR(subkey.as_ptr()), Some(0), KEY_READ, &mut asio_root) }
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
        if unsafe { RegOpenKeyExW(asio_root, PCWSTR(drv_sub.as_ptr()), Some(0), KEY_READ, &mut drv_key) }
            .is_err()
        {
            continue;
        }

        let clsid_str = read_reg_string(drv_key, Some("CLSID"));
        let desc = read_reg_string(drv_key, Some("Description")).unwrap_or_else(|| key_name.clone());
        let _ = unsafe { RegCloseKey(drv_key) };

        let Some(clsid_str) = clsid_str else {
            continue;
        };

        let inproc_sub: Vec<u16> = format!("SOFTWARE\\Classes\\CLSID\\{clsid_str}\\InprocServer32\0")
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
        let dll_exists = dll_path.as_deref().is_some_and(|p| std::path::Path::new(p).exists());

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

fn probe_single_asio_com(entry: &mut AsioDriverEntry) {
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
                ASIO_ST_INT16_LSB => entry.supported_bit_depths.push(16),
                ASIO_ST_INT24_LSB => entry.supported_bit_depths = vec![16, 24],
                ASIO_ST_INT32_LSB | ASIO_ST_FLOAT32_LSB | ASIO_ST_FLOAT64_LSB => {
                    entry.supported_bit_depths = vec![16, 24, 32]
                }
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

/// Lock-free ASIO hardware clock snapshot captured inside `bufferSwitch` / `bufferSwitchTimeInfo`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AsioClockSnapshot {
    pub sample_position: u64,
    pub system_time_ns: u64,
    pub output_latency_frames: u32,
    pub sample_rate: u32,
    pub callback_count: u64,
}

/// Shared lock-free / wait-free control & telemetry signals for ASIO callbacks and `AsioNativeSession`.
#[doc(hidden)]
pub struct AsioCallbackSignals {
    pub flush_requested_epoch: AtomicU64,
    pub flush_completed_epoch: AtomicU64,
    pub eof_drained: AtomicBool,
    pub eof_target_state: AtomicI32,
    pub reset_requested: AtomicBool,
    pub resync_requested: AtomicBool,
    pub latencies_changed: AtomicBool,
    pub requested_buffer_size: AtomicI32,
    pub device_lost: AtomicBool,
    pub resync_count: AtomicU64,
    pub output_latency_frames: AtomicU32,
    pub sample_rate: AtomicU32,
    pub hw_sample_pos: AtomicU64,
    pub hw_timestamp_ns: AtomicU64,
    pub hw_clock_valid: AtomicBool,
    pub callback_count: AtomicU64,
    clock_seq: AtomicU64,
    pub last_error: RwLock<Option<String>>,
}

impl AsioCallbackSignals {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            flush_requested_epoch: AtomicU64::new(0),
            flush_completed_epoch: AtomicU64::new(0),
            eof_drained: AtomicBool::new(false),
            eof_target_state: AtomicI32::new(1),
            reset_requested: AtomicBool::new(false),
            resync_requested: AtomicBool::new(false),
            latencies_changed: AtomicBool::new(false),
            requested_buffer_size: AtomicI32::new(0),
            device_lost: AtomicBool::new(false),
            resync_count: AtomicU64::new(0),
            output_latency_frames: AtomicU32::new(0),
            sample_rate: AtomicU32::new(sample_rate),
            hw_sample_pos: AtomicU64::new(0),
            hw_timestamp_ns: AtomicU64::new(0),
            hw_clock_valid: AtomicBool::new(false),
            callback_count: AtomicU64::new(0),
            clock_seq: AtomicU64::new(0),
            last_error: RwLock::new(None),
        }
    }

    pub fn request_flush(&self) -> u64 {
        self.flush_requested_epoch
            .fetch_add(1, Ordering::SeqCst)
            .wrapping_add(1)
    }

    pub fn record_clock(&self, sample_position: u64, system_time_ns: u64) {
        let s = self.clock_seq.load(Ordering::Relaxed);
        self.clock_seq.store(s.wrapping_add(1), Ordering::Release);
        std::sync::atomic::fence(Ordering::Release);
        self.hw_sample_pos.store(sample_position, Ordering::Relaxed);
        self.hw_timestamp_ns.store(system_time_ns, Ordering::Relaxed);
        self.hw_clock_valid.store(true, Ordering::Relaxed);
        self.clock_seq.store(s.wrapping_add(2), Ordering::Release);
    }

    pub fn clock_snapshot(&self) -> Option<AsioClockSnapshot> {
        for _ in 0..8 {
            let s1 = self.clock_seq.load(Ordering::Acquire);
            if s1 & 1 != 0 {
                std::hint::spin_loop();
                continue;
            }
            if !self.hw_clock_valid.load(Ordering::Acquire) {
                return None;
            }
            let sample_position = self.hw_sample_pos.load(Ordering::Relaxed);
            let system_time_ns = self.hw_timestamp_ns.load(Ordering::Relaxed);
            let output_latency_frames = self.output_latency_frames.load(Ordering::Relaxed);
            let sample_rate = self.sample_rate.load(Ordering::Relaxed);
            let callback_count = self.callback_count.load(Ordering::Relaxed);
            std::sync::atomic::fence(Ordering::Acquire);
            let s2 = self.clock_seq.load(Ordering::Acquire);
            if s1 == s2 {
                return Some(AsioClockSnapshot {
                    sample_position,
                    system_time_ns,
                    output_latency_frames,
                    sample_rate,
                    callback_count,
                });
            }
        }
        None
    }

    pub fn hardware_sample_position(&self) -> Option<u64> {
        self.clock_snapshot().map(|s| s.sample_position)
    }

    /// Handles Steinberg ASIO 2.x `asioMessage` selectors deterministically using wait-free atomics.
    pub fn handle_asio_message(&self, selector: i32, value: i32) -> i32 {
        match selector {
            K_ASIO_SELECTOR_SUPPORTED => match value {
                1..=7 => 1,
                _ => 0,
            },
            K_ASIO_ENGINE_VERSION => 2,
            K_ASIO_RESET_REQUEST => {
                self.reset_requested.store(true, Ordering::Release);
                1
            }
            K_ASIO_BUFFER_SIZE_CHANGE => {
                self.requested_buffer_size.store(value, Ordering::Release);
                self.reset_requested.store(true, Ordering::Release);
                1
            }
            K_ASIO_RESYNC_REQUEST => {
                self.resync_requested.store(true, Ordering::Release);
                self.resync_count.fetch_add(1, Ordering::Relaxed);
                1
            }
            K_ASIO_LATENCIES_CHANGED => {
                self.latencies_changed.store(true, Ordering::Release);
                1
            }
            K_ASIO_SUPPORTS_TIME_INFO => 1,
            _ => 0,
        }
    }
}

/// Returns the single-byte silence value for raw PCM (`0x00`) or Native DSD (`0x69`).
#[inline]
pub fn asio_silence_byte(wire: WireSampleFormat) -> u8 {
    if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        0x69
    } else {
        0x00
    }
}

/// Fills a single planar ASIO channel buffer slice with format-appropriate silence.
/// For `Dop24In32MsbLe`, emits alternating `0x05`/`0xFA` markers + `0x69` DSD payload so the DAC
/// preserves DoP lock across seeks, pauses, and underruns.
pub fn fill_asio_buffer_silence(
    dst: &mut [u8],
    wire: WireSampleFormat,
    drv_bps: usize,
    dop_marker_phase: &mut bool,
) {
    match wire {
        WireSampleFormat::NativeDsd { .. } => {
            dst.fill(0x69);
        }
        WireSampleFormat::Dop24In32MsbLe { .. } => {
            if drv_bps == 4 {
                let aligned = (dst.len() / 4) * 4;
                for sample in dst[..aligned].as_chunks_mut::<4>().0 {
                    let marker = if *dop_marker_phase { 0xFAu8 } else { 0x05u8 };
                    *dop_marker_phase = !*dop_marker_phase;
                    sample[0] = 0x00;
                    sample[1] = 0x69;
                    sample[2] = 0x69;
                    sample[3] = marker;
                }
                if aligned < dst.len() {
                    dst[aligned..].fill(0x00);
                }
            } else if drv_bps == 3 {
                let aligned = (dst.len() / 3) * 3;
                for sample in dst[..aligned].as_chunks_mut::<3>().0 {
                    let marker = if *dop_marker_phase { 0xFAu8 } else { 0x05u8 };
                    *dop_marker_phase = !*dop_marker_phase;
                    sample[0] = 0x69;
                    sample[1] = 0x69;
                    sample[2] = marker;
                }
                if aligned < dst.len() {
                    dst[aligned..].fill(0x00);
                }
            } else {
                dst.fill(0x00);
            }
        }
        _ => {
            dst.fill(0x00);
        }
    }
}

#[inline]
fn asio_chunk_has_nonzero(data: &[u8], wire: WireSampleFormat) -> bool {
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

/// Driver-independent ASIO double-buffer render state machine, factored for deterministic unit
/// testing without COM or physical ASIO hardware.
#[doc(hidden)]
pub struct AsioRenderCore {
    pub consumer: Consumer<u8>,
    pub verification: AudioVerificationEngine,
    pub frames_rendered: Arc<AtomicU64>,
    pub nonzero_frames: Arc<AtomicU64>,
    pub state_code: Arc<AtomicI32>,
    pub eof_flag: Arc<AtomicBool>,
    pub paused: Arc<AtomicBool>,
    pub stopped: Arc<AtomicBool>,
    pub current_session_id: Arc<AtomicU64>,
    pub session_id: u64,
    pub signals: Arc<AsioCallbackSignals>,
    pub buffer_size: usize,
    pub channels: usize,
    pub sample_rate: u32,
    pub sample_type: i32,
    pub wire: WireSampleFormat,
    pub scratch: Vec<u8>,
    last_handled_flush_epoch: u64,
    eof_drain_remaining: Option<u32>,
    dop_silence_phase: bool,
    was_paused: bool,
}

impl AsioRenderCore {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        consumer: Consumer<u8>,
        verification: AudioVerificationEngine,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        paused: Arc<AtomicBool>,
        stopped: Arc<AtomicBool>,
        current_session_id: Arc<AtomicU64>,
        session_id: u64,
        signals: Arc<AsioCallbackSignals>,
        buffer_size: usize,
        channels: usize,
        sample_rate: u32,
        sample_type: i32,
        wire: WireSampleFormat,
    ) -> Self {
        Self {
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            paused,
            stopped,
            current_session_id,
            session_id,
            signals,
            buffer_size,
            channels,
            sample_rate,
            sample_type,
            wire,
            scratch: vec![0; buffer_size * channels.max(1) * 8],
            last_handled_flush_epoch: 0,
            eof_drain_remaining: None,
            dop_silence_phase: false,
            was_paused: false,
        }
    }

    fn fill_half_buffer_silence(&mut self, channel_buffers: &[[*mut u8; 2]], idx: usize) {
        let ch = self.channels.min(channel_buffers.len());
        let drv_bps = asio_sample_bytes(self.sample_type);
        let is_dsd_bit_packed = matches!(
            self.sample_type,
            ASIO_ST_DSD_INT8_LSB1 | ASIO_ST_DSD_INT8_MSB1
        );
        let byte_frames = if is_dsd_bit_packed {
            self.buffer_size / 8
        } else {
            self.buffer_size
        };
        let start_phase = self.dop_silence_phase;
        let mut next_phase = start_phase;
        for pair in channel_buffers.iter().take(ch) {
            let dst_ptr = pair[idx];
            if !dst_ptr.is_null() {
                let dst = unsafe { std::slice::from_raw_parts_mut(dst_ptr, byte_frames * drv_bps) };
                let mut ch_phase = start_phase;
                fill_asio_buffer_silence(dst, self.wire, drv_bps, &mut ch_phase);
                next_phase = ch_phase;
            }
        }
        self.dop_silence_phase = next_phase;
    }

    fn fill_both_double_buffers_silence(&mut self, channel_buffers: &[[*mut u8; 2]]) {
        self.fill_half_buffer_silence(channel_buffers, 0);
        self.fill_half_buffer_silence(channel_buffers, 1);
    }

    /// Processes a single ASIO `bufferSwitch` period. Returns `true` if `output_ready()` should be invoked.
    pub fn process_buffer_switch(
        &mut self,
        idx: usize,
        channel_buffers: &[[*mut u8; 2]],
    ) -> bool {
        self.signals.callback_count.fetch_add(1, Ordering::Relaxed);

        // 1. Lock-free flush epoch handling (works in both Playing and Paused states).
        let req_epoch = self.signals.flush_requested_epoch.load(Ordering::Acquire);
        if req_epoch != self.last_handled_flush_epoch {
            if self.consumer.has_pending_flush() {
                self.consumer.flush_and_ack();
            } else {
                self.consumer.clear();
            }
            self.eof_drain_remaining = None;
            self.signals.eof_drained.store(false, Ordering::Release);
            self.dop_silence_phase = false;
            self.fill_both_double_buffers_silence(channel_buffers);
            self.last_handled_flush_epoch = req_epoch;
            self.signals
                .flush_completed_epoch
                .store(req_epoch, Ordering::Release);
            return true;
        }

        // 2. Stopped / session mismatch / paused gate.
        let session_mismatch =
            self.current_session_id.load(Ordering::Relaxed) != self.session_id;
        let is_stopped = self.stopped.load(Ordering::Relaxed);
        let is_paused = self.paused.load(Ordering::Relaxed);
        if is_stopped || session_mismatch || is_paused {
            if is_paused && !self.was_paused {
                self.fill_both_double_buffers_silence(channel_buffers);
                self.was_paused = true;
            } else {
                self.fill_half_buffer_silence(channel_buffers, idx);
            }
            return is_paused && !is_stopped && !session_mismatch;
        }
        self.was_paused = false;

        let wire_bpf = self.wire.bytes_per_sample() * self.channels.max(1);
        let is_dsd_bit_packed = matches!(
            self.sample_type,
            ASIO_ST_DSD_INT8_LSB1 | ASIO_ST_DSD_INT8_MSB1
        );
        let frames_in_callback_bytes = if is_dsd_bit_packed {
            self.buffer_size / 8
        } else {
            self.buffer_size
        };
        let needed_bytes = frames_in_callback_bytes * wire_bpf;
        if self.scratch.len() < needed_bytes {
            self.scratch.resize(needed_bytes, 0);
        }

        let got = self.consumer.pop_slice(&mut self.scratch[..needed_bytes]);
        let aligned = (got / wire_bpf) * wire_bpf;

        if aligned > 0 {
            self.eof_drain_remaining = None;
            self.signals.eof_drained.store(false, Ordering::Release);

            if matches!(self.wire, WireSampleFormat::Dop24In32MsbLe { .. }) {
                self.dop_silence_phase = self.scratch[aligned - 1] == 0x05;
            }

            self.verification.record_backend_input_wire(
                &self.scratch[..aligned],
                self.wire,
                self.channels as u16,
                self.sample_rate,
            );
            let frames = if is_dsd_bit_packed {
                ((aligned / wire_bpf) * 8) as u64
            } else {
                (aligned / wire_bpf) as u64
            };
            self.frames_rendered.fetch_add(frames, Ordering::Relaxed);
            if asio_chunk_has_nonzero(&self.scratch[..aligned], self.wire) {
                self.nonzero_frames.fetch_add(frames, Ordering::Relaxed);
            }
        } else if self.eof_flag.load(Ordering::SeqCst)
            && self.consumer.available_read() < wire_bpf
        {
            self.fill_half_buffer_silence(channel_buffers, idx);
            let out_lat = self.signals.output_latency_frames.load(Ordering::Relaxed);
            let drain_periods = 2 + (out_lat / (self.buffer_size as u32).max(1)).min(4);
            let rem = self.eof_drain_remaining.get_or_insert(drain_periods);
            if *rem <= 1 {
                *rem = 0;
                self.signals.eof_drained.store(true, Ordering::Release);
                let target = self.signals.eof_target_state.load(Ordering::Relaxed);
                let _ = self.state_code.compare_exchange(
                    2,
                    target,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                );
            } else {
                *rem -= 1;
            }
            return true;
        } else {
            // Transient underrun while track still active.
            self.fill_half_buffer_silence(channel_buffers, idx);
            return true;
        }

        // Write interleaved wire bytes into ASIO driver's planar channel buffers cleanly.
        let ch = self.channels.min(channel_buffers.len());
        let drv_bps = asio_sample_bytes(self.sample_type);
        let src_bps = self.wire.bytes_per_sample();
        let valid_frames = aligned / wire_bpf;
        let tail_start_phase = self.dop_silence_phase;
        let mut tail_next_phase = tail_start_phase;

        for (c, pair) in channel_buffers.iter().enumerate().take(ch) {
            let dst_ptr = pair[idx];
            if dst_ptr.is_null() {
                continue;
            }
            let dst = unsafe {
                std::slice::from_raw_parts_mut(dst_ptr, frames_in_callback_bytes * drv_bps)
            };
            if src_bps == drv_bps {
                for f in 0..valid_frames {
                    let s_off = (f * ch + c) * src_bps;
                    let d_off = f * drv_bps;
                    dst[d_off..d_off + drv_bps]
                        .copy_from_slice(&self.scratch[s_off..s_off + drv_bps]);
                }
            } else if src_bps == 2 && drv_bps == 4 {
                // Left-justify 16-bit integer into 32-bit ASIO LSB integer container losslessly
                for f in 0..valid_frames {
                    let s_off = (f * ch + c) * 2;
                    let s16 = i16::from_le_bytes([self.scratch[s_off], self.scratch[s_off + 1]]);
                    let s32 = (s16 as i32) << 16;
                    dst[f * 4..(f + 1) * 4].copy_from_slice(&s32.to_le_bytes());
                }
            } else if src_bps == 3 && drv_bps == 4 {
                for f in 0..valid_frames {
                    let s_off = (f * ch + c) * 3;
                    let bytes = [
                        0u8,
                        self.scratch[s_off],
                        self.scratch[s_off + 1],
                        self.scratch[s_off + 2],
                    ];
                    dst[f * 4..(f + 1) * 4].copy_from_slice(&bytes);
                }
            }
            if valid_frames < frames_in_callback_bytes {
                let mut ch_phase = tail_start_phase;
                fill_asio_buffer_silence(
                    &mut dst[valid_frames * drv_bps..],
                    self.wire,
                    drv_bps,
                    &mut ch_phase,
                );
                tail_next_phase = ch_phase;
            }
        }
        if valid_frames < frames_in_callback_bytes {
            self.dop_silence_phase = tail_next_phase;
        }

        true
    }
}

struct ActiveAsioCallbackState {
    asio_raw: usize,
    vtbl_raw: usize,
    _buffer_infos: Vec<AsioBufferInfo>,
    channel_buffers: Vec<[*mut u8; 2]>,
    core: AsioRenderCore,
}

// ASIO double-buffer pointers come from the COM STA host thread and are exclusively guarded by ACTIVE_ASIO_SLOT.
unsafe impl Send for ActiveAsioCallbackState {}
unsafe impl Sync for ActiveAsioCallbackState {}

static ACTIVE_ASIO_SLOT: Mutex<Option<ActiveAsioCallbackState>> = Mutex::new(None);
static ACTIVE_ASIO_SESSION_ID: AtomicU64 = AtomicU64::new(0);
static LAST_ASIO_BUFFER_FRAMES: AtomicUsize = AtomicUsize::new(0);

// Wait-free message atomics updated inside driver `asio_message` callback (never locks ACTIVE_ASIO_SLOT).
static ASIO_MSG_SESSION_ID: AtomicU64 = AtomicU64::new(0);
static ASIO_MSG_RESET: AtomicBool = AtomicBool::new(false);
static ASIO_MSG_RESYNC: AtomicBool = AtomicBool::new(false);
static ASIO_MSG_LATENCIES_CHANGED: AtomicBool = AtomicBool::new(false);
static ASIO_MSG_BUFFER_SIZE: AtomicI32 = AtomicI32::new(0);

unsafe extern "C" fn asio_buffer_switch(double_buffer_index: i32, direct_process: i32) {
    asio_buffer_switch_impl(double_buffer_index, direct_process, None);
}

fn asio_buffer_switch_impl(
    double_buffer_index: i32,
    _direct_process: i32,
    time_info_pos: Option<(u64, u64)>,
) {
    let idx = if double_buffer_index == 0 { 0usize } else { 1usize };
    let Ok(mut guard) = ACTIVE_ASIO_SLOT.lock() else {
        return;
    };
    let Some(st) = guard.as_mut() else {
        return;
    };

    if let Some((pos, sys_ns)) = time_info_pos {
        st.core.signals.record_clock(pos, sys_ns);
    } else if st.asio_raw != 0 && st.vtbl_raw != 0 {
        let mut s_pos = AsioSamples::default();
        let mut t_stamp = AsioTimeStamp::default();
        let rc = unsafe {
            let vtbl = &*(st.vtbl_raw as *const IAsioVtbl);
            (vtbl.get_sample_position)(st.asio_raw as *mut c_void, &mut s_pos, &mut t_stamp)
        };
        if rc == ASIO_OK {
            st.core
                .signals
                .record_clock(s_pos.to_u64(), t_stamp.to_u64());
        }
    }

    let should_output_ready = st.core.process_buffer_switch(idx, &st.channel_buffers);

    if should_output_ready && st.asio_raw != 0 && st.vtbl_raw != 0 {
        unsafe {
            let vtbl = &*(st.vtbl_raw as *const IAsioVtbl);
            let _ = (vtbl.output_ready)(st.asio_raw as *mut c_void);
        }
    }
}

fn asio_sample_bytes(sample_type: i32) -> usize {
    match sample_type {
        ASIO_ST_INT16_LSB => 2,
        ASIO_ST_INT24_LSB => 3,
        ASIO_ST_FLOAT64_LSB => 8,
        ASIO_ST_DSD_INT8_LSB1 | ASIO_ST_DSD_INT8_MSB1 | ASIO_ST_DSD_INT8_LSB8 => 1,
        _ => 4,
    }
}

unsafe extern "C" fn asio_sample_rate_changed(_s_rate: f64) {}

unsafe extern "C" fn asio_message(
    selector: i32,
    value: i32,
    _message: *const c_void,
    _opt: *const f64,
) -> i32 {
    match selector {
        K_ASIO_SELECTOR_SUPPORTED => match value {
            1..=7 => 1,
            _ => 0,
        },
        K_ASIO_ENGINE_VERSION => 2,
        K_ASIO_RESET_REQUEST => {
            ASIO_MSG_RESET.store(true, Ordering::Release);
            1
        }
        K_ASIO_BUFFER_SIZE_CHANGE => {
            ASIO_MSG_BUFFER_SIZE.store(value, Ordering::Release);
            ASIO_MSG_RESET.store(true, Ordering::Release);
            1
        }
        K_ASIO_RESYNC_REQUEST => {
            ASIO_MSG_RESYNC.store(true, Ordering::Release);
            1
        }
        K_ASIO_LATENCIES_CHANGED => {
            ASIO_MSG_LATENCIES_CHANGED.store(true, Ordering::Release);
            1
        }
        K_ASIO_SUPPORTS_TIME_INFO => 1,
        _ => 0,
    }
}

unsafe extern "C" fn asio_buffer_switch_time_info(
    params: *const c_void,
    double_buffer_index: i32,
    direct_process: i32,
) -> *const c_void {
    let time_info_pos = if !params.is_null() {
        let t = unsafe { &*(params as *const AsioTime) };
        if (t.time_info.flags & ASIO_TIME_INFO_SAMPLE_POSITION_VALID) != 0 {
            let pos = t.time_info.sample_position.to_u64();
            let sys_ns = if (t.time_info.flags & ASIO_TIME_INFO_SYSTEM_TIME_VALID) != 0 {
                t.time_info.system_time.to_u64()
            } else {
                0
            };
            Some((pos, sys_ns))
        } else {
            None
        }
    } else {
        None
    };
    asio_buffer_switch_impl(double_buffer_index, direct_process, time_info_pos);
    null_mut()
}

pub struct AsioNativeSession {
    pub driver_name: String,
    pub buffer_frames: u32,
    paused: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
    signals: Arc<AsioCallbackSignals>,
    handle: Option<JoinHandle<()>>,
}

impl AsioNativeSession {
    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start(
        driver_id: Option<&str>,
        sample_rate: u32,
        channels: u16,
        wire: WireSampleFormat,
        native_dsd: bool,
        consumer: Consumer<u8>,
        verification: AudioVerificationEngine,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        session_id: u64,
        current_session_id: Arc<AtomicU64>,
    ) -> Result<Self, BackendError> {
        let drivers = enumerate_asio_drivers(false);
        let chosen = if let Some(raw_target) = driver_id {
            let target = raw_target.strip_prefix("asio::").unwrap_or(raw_target);
            drivers
                .into_iter()
                .find(|d| d.id == target || d.name == target || raw_target.contains(&d.name))
        } else {
            drivers.into_iter().next()
        }
        .ok_or_else(|| BackendError::DeviceNotFound("No ASIO driver installed in HKLM\\SOFTWARE\\ASIO".into()))?;

        if !chosen.dll_exists {
            return Err(BackendError::DriverError(format!(
                "ASIO driver DLL missing: {:?}",
                chosen.dll_path
            )));
        }

        let paused = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicBool::new(false));
        let signals = Arc::new(AsioCallbackSignals::new(sample_rate));
        let th_paused = Arc::clone(&paused);
        let th_stopped = Arc::clone(&stopped);
        let th_signals = Arc::clone(&signals);

        let (ack_tx, ack_rx) = mpsc::sync_channel::<Result<(String, u32), BackendError>>(1);

        let handle = thread::Builder::new()
            .name("lumina-asio-sta".to_string())
            .spawn(move || {
                let _com = ComStaGuard::init();
                let clsid_w: Vec<u16> = chosen
                    .clsid_str
                    .encode_utf16()
                    .chain(std::iter::once(0))
                    .collect();
                let Ok(clsid) = (unsafe { CLSIDFromString(PCWSTR(clsid_w.as_ptr())) }) else {
                    let _ = ack_tx.send(Err(BackendError::DriverError("Invalid ASIO CLSID".into())));
                    return;
                };
                let Ok(raw_unk) = (unsafe { com_create_asio_instance(&clsid) }) else {
                    let _ = ack_tx.send(Err(BackendError::DriverError("CoCreateInstance failed".into())));
                    return;
                };
                let Some(nn) = NonNull::new(raw_unk as *mut *const IAsioVtbl) else {
                    let _ = ack_tx.send(Err(BackendError::DriverError("Null ASIO object".into())));
                    return;
                };
                let asio = ComAsioPtr(nn);

                if unsafe { (asio.vtbl().init)(asio.raw(), null_mut()) } != ASIO_TRUE {
                    let err = unsafe { asio.driver_error() };
                    let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                        "ASIO driver init failed (DAC disconnected?): {err}"
                    ))));
                    return;
                }

                if native_dsd {
                    let mut fmt = AsioIoFormat {
                        format_type: K_ASIO_FORMAT_DSD,
                        future: [0; 508],
                    };
                    let rc = unsafe {
                        (asio.vtbl().future)(
                            asio.raw(),
                            K_ASIO_SET_IO_FORMAT,
                            &mut fmt as *mut AsioIoFormat as *mut c_void,
                        )
                    };
                    if rc != ASIO_SUCCESS && rc != ASIO_OK {
                        let _ = ack_tx.send(Err(BackendError::DriverError(
                            "ASIO driver rejected Native DSD IoFormat switch".into(),
                        )));
                        return;
                    }
                } else {
                    let mut fmt = AsioIoFormat {
                        format_type: K_ASIO_FORMAT_PCM,
                        future: [0; 508],
                    };
                    let _ = unsafe {
                        (asio.vtbl().future)(
                            asio.raw(),
                            K_ASIO_SET_IO_FORMAT,
                            &mut fmt as *mut AsioIoFormat as *mut c_void,
                        )
                    };
                }

                if unsafe { (asio.vtbl().can_sample_rate)(asio.raw(), sample_rate as f64) } != ASIO_OK
                {
                    let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                        "ASIO driver '{}' does not support exact sample rate {} Hz",
                        chosen.name, sample_rate
                    ))));
                    return;
                }
                if unsafe { (asio.vtbl().set_sample_rate)(asio.raw(), sample_rate as f64) } != ASIO_OK
                {
                    let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                        "ASIO set_sample_rate({sample_rate}) failed"
                    ))));
                    return;
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
                } != ASIO_OK
                {
                    pref_sz = 512;
                }
                let buf_frames = pref_sz.clamp(min_sz.max(64), max_sz.max(64)) as usize;
                LAST_ASIO_BUFFER_FRAMES.store(buf_frames, Ordering::Relaxed);

                let ch = channels.max(1) as usize;
                let mut ch_info = AsioChannelInfo {
                    channel: 0,
                    is_input: 0,
                    is_active: 0,
                    channel_group: 0,
                    sample_type: ASIO_ST_INT32_LSB,
                    name: [0; 32],
                };
                let _ = unsafe { (asio.vtbl().get_channel_info)(asio.raw(), &mut ch_info) };

                let mut buffer_infos: Vec<AsioBufferInfo> = (0..ch)
                    .map(|c| AsioBufferInfo {
                        is_input: 0,
                        channel_num: c as i32,
                        buffers: [null_mut(), null_mut()],
                    })
                    .collect();

                let mut callbacks = Box::new(AsioCallbacks {
                    buffer_switch: asio_buffer_switch,
                    sample_rate_did_change: asio_sample_rate_changed,
                    asio_message,
                    buffer_switch_time_info: asio_buffer_switch_time_info,
                });

                ASIO_MSG_RESET.store(false, Ordering::Release);
                ASIO_MSG_RESYNC.store(false, Ordering::Release);
                ASIO_MSG_LATENCIES_CHANGED.store(false, Ordering::Release);
                ASIO_MSG_BUFFER_SIZE.store(0, Ordering::Release);
                ASIO_MSG_SESSION_ID.store(session_id, Ordering::Release);

                if unsafe {
                    (asio.vtbl().create_buffers)(
                        asio.raw(),
                        buffer_infos.as_mut_ptr(),
                        ch as i32,
                        buf_frames as i32,
                        callbacks.as_mut() as *mut AsioCallbacks,
                    )
                } != ASIO_OK
                {
                    let err = unsafe { asio.driver_error() };
                    let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                        "ASIO createBuffers failed: {err}"
                    ))));
                    return;
                }

                let (mut in_lat, mut out_lat) = (0i32, 0i32);
                if unsafe { (asio.vtbl().get_latencies)(asio.raw(), &mut in_lat, &mut out_lat) }
                    == ASIO_OK
                    && out_lat > 0
                {
                    th_signals
                        .output_latency_frames
                        .store(out_lat as u32, Ordering::Release);
                }

                let channel_buffers: Vec<[*mut u8; 2]> = buffer_infos
                    .iter()
                    .map(|bi| [bi.buffers[0] as *mut u8, bi.buffers[1] as *mut u8])
                    .collect();

                let core = AsioRenderCore::new(
                    consumer,
                    verification,
                    frames_rendered,
                    nonzero_frames,
                    Arc::clone(&state_code),
                    eof_flag,
                    Arc::clone(&th_paused),
                    Arc::clone(&th_stopped),
                    Arc::clone(&current_session_id),
                    session_id,
                    Arc::clone(&th_signals),
                    buf_frames,
                    ch,
                    sample_rate,
                    ch_info.sample_type,
                    wire,
                );

                let vtbl_raw = unsafe { *asio.0.as_ptr() } as usize;
                ACTIVE_ASIO_SESSION_ID.store(session_id, Ordering::SeqCst);
                if let Ok(mut slot) = ACTIVE_ASIO_SLOT.lock() {
                    *slot = Some(ActiveAsioCallbackState {
                        asio_raw: asio.raw() as usize,
                        vtbl_raw,
                        _buffer_infos: buffer_infos,
                        channel_buffers,
                        core,
                    });
                }

                if unsafe { (asio.vtbl().start)(asio.raw()) } != ASIO_OK {
                    let err = unsafe { asio.driver_error() };
                    let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                        "ASIO start failed: {err}"
                    ))));
                    if let Ok(mut slot) = ACTIVE_ASIO_SLOT.lock() {
                        *slot = None;
                    }
                    let _ = unsafe { (asio.vtbl().dispose_buffers)(asio.raw()) };
                    return;
                }

                let _ = ack_tx.send(Ok((chosen.name.clone(), buf_frames as u32)));

                while !th_stopped.load(Ordering::Acquire)
                    && current_session_id.load(Ordering::Relaxed) == session_id
                {
                    if ASIO_MSG_SESSION_ID.load(Ordering::Acquire) == session_id {
                        if ASIO_MSG_RESET.swap(false, Ordering::AcqRel) {
                            let req_buf = ASIO_MSG_BUFFER_SIZE.load(Ordering::Acquire);
                            th_signals
                                .requested_buffer_size
                                .store(req_buf, Ordering::Release);
                            th_signals.reset_requested.store(true, Ordering::Release);
                            th_signals.device_lost.store(true, Ordering::Release);
                            if let Ok(mut g) = th_signals.last_error.write() {
                                *g = Some(if req_buf > 0 {
                                    format!(
                                        "ASIO driver requested buffer/reset (buffer_size={req_buf})"
                                    )
                                } else {
                                    "ASIO driver requested reset (kAsioResetRequest)".to_string()
                                });
                            }
                            let cur_state = state_code.load(Ordering::Acquire);
                            if cur_state == 2 || cur_state == 3 {
                                let _ = state_code.compare_exchange(
                                    cur_state,
                                    4,
                                    Ordering::SeqCst,
                                    Ordering::SeqCst,
                                );
                            }
                            th_stopped.store(true, Ordering::Release);
                            break;
                        }
                        if ASIO_MSG_RESYNC.swap(false, Ordering::AcqRel) {
                            th_signals.resync_requested.store(true, Ordering::Release);
                            th_signals.resync_count.fetch_add(1, Ordering::Relaxed);
                            th_signals.request_flush();
                        }
                        if ASIO_MSG_LATENCIES_CHANGED.swap(false, Ordering::AcqRel) {
                            th_signals.latencies_changed.store(true, Ordering::Release);
                            let (mut new_in, mut new_out) = (0i32, 0i32);
                            if unsafe {
                                (asio.vtbl().get_latencies)(asio.raw(), &mut new_in, &mut new_out)
                            } == ASIO_OK
                                && new_out >= 0
                            {
                                th_signals
                                    .output_latency_frames
                                    .store(new_out as u32, Ordering::Release);
                            }
                        }
                    }
                    thread::sleep(Duration::from_millis(10));
                }

                let _ = unsafe { (asio.vtbl().stop)(asio.raw()) };
                if let Ok(mut slot) = ACTIVE_ASIO_SLOT.lock() {
                    *slot = None;
                }
                let _ = unsafe { (asio.vtbl().dispose_buffers)(asio.raw()) };
            })
            .map_err(|e| BackendError::DriverError(format!("Spawn ASIO STA thread failed: {e}")))?;

        match ack_rx.recv() {
            Ok(Ok((driver_name, buffer_frames))) => Ok(Self {
                driver_name,
                buffer_frames,
                paused,
                stopped,
                signals,
                handle: Some(handle),
            }),
            Ok(Err(e)) => {
                let _ = handle.join();
                Err(e)
            }
            Err(_) => {
                let _ = handle.join();
                Err(BackendError::DriverError(
                    "ASIO STA thread closed during initialization".into(),
                ))
            }
        }
    }

    pub fn set_paused(&self, p: bool) {
        self.paused.store(p, Ordering::SeqCst);
    }

    /// Requests a lock-free double-buffer + ring-buffer flush and returns the target epoch.
    pub fn request_flush(&self) -> u64 {
        self.signals.request_flush()
    }

    /// Requests a flush and waits (bounded to 150ms) for `bufferSwitch` to clear both ASIO
    /// double-buffers and drain the consumer. Returns `true` if acknowledged before timeout/stop.
    pub fn flush(&self) -> bool {
        if self.stopped.load(Ordering::Acquire)
            || self.signals.device_lost.load(Ordering::Acquire)
            || self.signals.reset_requested.load(Ordering::Acquire)
        {
            return false;
        }
        let target = self.request_flush();
        let deadline = Instant::now() + Duration::from_millis(150);
        while self.signals.flush_completed_epoch.load(Ordering::Acquire) < target {
            if self.stopped.load(Ordering::Acquire)
                || self.signals.device_lost.load(Ordering::Acquire)
                || self.signals.reset_requested.load(Ordering::Acquire)
                || Instant::now() >= deadline
            {
                return false;
            }
            thread::sleep(Duration::from_millis(1));
        }
        true
    }

    pub fn hardware_clock_snapshot(&self) -> Option<AsioClockSnapshot> {
        self.signals.clock_snapshot()
    }

    pub fn hardware_sample_position(&self) -> Option<u64> {
        self.signals.hardware_sample_position()
    }

    pub fn output_latency_frames(&self) -> u32 {
        self.signals.output_latency_frames.load(Ordering::Acquire)
    }

    pub fn is_reset_requested(&self) -> bool {
        self.signals.reset_requested.load(Ordering::Acquire)
    }

    pub fn is_resync_requested(&self) -> bool {
        self.signals.resync_requested.load(Ordering::Acquire)
    }

    pub fn clear_resync_requested(&self) {
        self.signals.resync_requested.store(false, Ordering::Release);
    }

    pub fn is_device_lost(&self) -> bool {
        self.signals.device_lost.load(Ordering::Acquire)
    }

    pub fn last_error(&self) -> Option<String> {
        self.signals.last_error.read().ok().and_then(|g| g.clone())
    }

    pub fn is_eof_drained(&self) -> bool {
        self.signals.eof_drained.load(Ordering::Acquire)
    }

    pub fn set_eof_target_state(&self, code: i32) {
        self.signals.eof_target_state.store(code, Ordering::SeqCst);
    }

    pub fn stop(mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for AsioNativeSession {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}
