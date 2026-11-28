use std::ffi::{CStr, c_char, c_void};
use std::ptr::{NonNull, null_mut};

use windows::Win32::Foundation::{S_FALSE, S_OK};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize,
};
use windows::core::GUID;

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

pub(super) const K_ASIO_SET_IO_FORMAT: i32 = 0x23111961;
pub(super) const K_ASIO_CAN_DO_IO_FORMAT: i32 = 0x23112004;
pub(super) const K_ASIO_FORMAT_PCM: i32 = 0;
pub(super) const K_ASIO_FORMAT_DSD: i32 = 1;

pub(super) const PROBABLE_RATES: [u32; 16] = [
    44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
    2_822_400, 5_644_800, 11_289_600, 22_579_200, 3_072_000, 6_144_000,
];
pub(super) const DSD_PROBE_RATES: [u32; 4] = [2_822_400, 5_644_800, 11_289_600, 22_579_200];

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
pub(super) struct AsioBufferInfo {
    pub(super) is_input: i32,
    pub(super) channel_num: i32,
    pub(super) buffers: [*mut c_void; 2],
}

#[repr(C, packed(4))]
#[derive(Clone, Copy)]
pub(super) struct AsioChannelInfo {
    pub(super) channel: i32,
    pub(super) is_input: i32,
    pub(super) is_active: i32,
    pub(super) channel_group: i32,
    pub(super) sample_type: i32,
    pub(super) name: [c_char; 32],
}

#[repr(C, packed(4))]
pub(super) struct AsioIoFormat {
    pub(super) format_type: i32,
    pub(super) future: [u8; 508],
}

#[repr(C)]
pub(super) struct AsioCallbacks {
    pub(super) buffer_switch: unsafe extern "C" fn(double_buffer_index: i32, direct_process: i32),
    pub(super) sample_rate_did_change: unsafe extern "C" fn(s_rate: f64),
    pub(super) asio_message: unsafe extern "C" fn(
        selector: i32,
        value: i32,
        message: *const c_void,
        opt: *const f64,
    ) -> i32,
    pub(super) buffer_switch_time_info: unsafe extern "C" fn(
        params: *const c_void,
        double_buffer_index: i32,
        direct_process: i32,
    ) -> *const c_void,
}

/// Clean-room COM `IASIO` vtable matching Win64 MSVC ABI (slots 0..=23).
#[repr(C)]
pub(super) struct IAsioVtbl {
    // IUnknown (0..2)
    pub(super) query_interface:
        unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> i32,
    pub(super) add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
    pub(super) release: unsafe extern "system" fn(*mut c_void) -> u32,
    // IASIO (3..23)
    pub(super) init: unsafe extern "C" fn(*mut c_void, *mut c_void) -> i32,
    pub(super) get_driver_name: unsafe extern "C" fn(*mut c_void, *mut c_char),
    pub(super) get_driver_version: unsafe extern "C" fn(*mut c_void) -> i32,
    pub(super) get_error_message: unsafe extern "C" fn(*mut c_void, *mut c_char),
    pub(super) start: unsafe extern "C" fn(*mut c_void) -> i32,
    pub(super) stop: unsafe extern "C" fn(*mut c_void) -> i32,
    pub(super) get_channels: unsafe extern "C" fn(*mut c_void, *mut i32, *mut i32) -> i32,
    pub(super) get_latencies: unsafe extern "C" fn(*mut c_void, *mut i32, *mut i32) -> i32,
    pub(super) get_buffer_size:
        unsafe extern "C" fn(*mut c_void, *mut i32, *mut i32, *mut i32, *mut i32) -> i32,
    pub(super) can_sample_rate: unsafe extern "C" fn(*mut c_void, f64) -> i32,
    pub(super) get_sample_rate: unsafe extern "C" fn(*mut c_void, *mut f64) -> i32,
    pub(super) set_sample_rate: unsafe extern "C" fn(*mut c_void, f64) -> i32,
    pub(super) get_clock_sources: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut i32) -> i32,
    pub(super) set_clock_source: unsafe extern "C" fn(*mut c_void, i32) -> i32,
    pub(super) get_sample_position:
        unsafe extern "C" fn(*mut c_void, *mut AsioSamples, *mut AsioTimeStamp) -> i32,
    pub(super) get_channel_info: unsafe extern "C" fn(*mut c_void, *mut AsioChannelInfo) -> i32,
    pub(super) create_buffers:
        unsafe extern "C" fn(*mut c_void, *mut AsioBufferInfo, i32, i32, *mut AsioCallbacks) -> i32,
    pub(super) dispose_buffers: unsafe extern "C" fn(*mut c_void) -> i32,
    pub(super) control_panel: unsafe extern "C" fn(*mut c_void) -> i32,
    pub(super) future: unsafe extern "C" fn(*mut c_void, i32, *mut c_void) -> i32,
    pub(super) output_ready: unsafe extern "C" fn(*mut c_void) -> i32,
}

pub(super) struct ComAsioPtr(pub(super) NonNull<*const IAsioVtbl>);

pub(super) unsafe fn com_create_asio_instance(clsid: &GUID) -> Result<*mut c_void, i32> {
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
    let hr =
        unsafe { CoCreateInstance(clsid, null_mut(), CLSCTX_INPROC_SERVER.0, clsid, &mut out) };
    if hr >= 0 && !out.is_null() {
        Ok(out)
    } else {
        Err(hr)
    }
}

impl ComAsioPtr {
    #[inline]
    pub(super) unsafe fn vtbl(&self) -> &IAsioVtbl {
        unsafe { &**self.0.as_ptr() }
    }

    #[inline]
    pub(super) fn raw(&self) -> *mut c_void {
        self.0.as_ptr() as *mut c_void
    }

    pub(super) unsafe fn driver_error(&self) -> String {
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

pub(super) struct ComStaGuard(pub(super) bool);
impl ComStaGuard {
    pub(super) fn init() -> Self {
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
