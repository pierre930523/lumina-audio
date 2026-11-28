use std::ffi::c_void;

pub(super) type OSStatus = i32;
pub(super) type AudioObjectID = u32;
pub(super) type AudioDeviceID = AudioObjectID;
pub(super) type AudioObjectPropertySelector = u32;
pub(super) type AudioObjectPropertyScope = u32;
pub(super) type AudioObjectPropertyElement = u32;
pub(super) type AudioDeviceIOProcID = *mut c_void;

pub(super) const K_AUDIO_OBJECT_SYSTEM_OBJECT: AudioObjectID = 1;
pub(super) const K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL: AudioObjectPropertyScope = 0x676c_6f62; // 'glob'
pub(super) const K_AUDIO_OBJECT_PROPERTY_SCOPE_OUTPUT: AudioObjectPropertyScope = 0x6f75_7470; // 'outp'
pub(super) const K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN: AudioObjectPropertyElement = 0;

pub(super) const K_AUDIO_HARDWARE_PROPERTY_DEVICES: AudioObjectPropertySelector = 0x6465_7623; // 'dev#'
pub(super) const K_AUDIO_HARDWARE_PROPERTY_DEFAULT_OUTPUT_DEVICE: AudioObjectPropertySelector =
    0x644f_7574; // 'dOut'
pub(super) const K_AUDIO_DEVICE_PROPERTY_HOG_MODE: AudioObjectPropertySelector = 0x6f69_6e6b; // 'oink'
pub(super) const K_AUDIO_DEVICE_PROPERTY_NOMINAL_SAMPLE_RATE: AudioObjectPropertySelector =
    0x6e73_7274; // 'nsrt'
pub(super) const K_AUDIO_DEVICE_PROPERTY_AVAILABLE_NOMINAL_SAMPLE_RATES:
    AudioObjectPropertySelector = 0x6e73_7223; // 'nsr#'
pub(super) const K_AUDIO_DEVICE_PROPERTY_BUFFER_FRAME_SIZE: AudioObjectPropertySelector =
    0x6673_697a; // 'fsiz'

#[repr(C)]
#[derive(Clone, Copy)]
pub(super) struct AudioObjectPropertyAddress {
    pub(super) m_selector: AudioObjectPropertySelector,
    pub(super) m_scope: AudioObjectPropertyScope,
    pub(super) m_element: AudioObjectPropertyElement,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(super) struct AudioValueRange {
    pub(super) m_minimum: f64,
    pub(super) m_maximum: f64,
}

#[repr(C)]
pub(super) struct AudioBuffer {
    pub(super) m_number_channels: u32,
    pub(super) m_data_byte_size: u32,
    pub(super) m_data: *mut c_void,
}

#[repr(C)]
pub(super) struct AudioBufferList {
    pub(super) m_number_buffers: u32,
    pub(super) m_buffers: [AudioBuffer; 1],
}

pub(super) type AudioDeviceIOProc = unsafe extern "C" fn(
    in_device: AudioDeviceID,
    in_now: *const c_void,
    in_input_data: *const AudioBufferList,
    in_input_time: *const c_void,
    out_output_data: *mut AudioBufferList,
    in_output_time: *const c_void,
    in_client_data: *mut c_void,
) -> OSStatus;

#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    pub(super) fn AudioObjectGetPropertyDataSize(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: *const c_void,
        out_data_size: *mut u32,
    ) -> OSStatus;

    pub(super) fn AudioObjectGetPropertyData(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: *const c_void,
        io_data_size: *mut u32,
        out_data: *mut c_void,
    ) -> OSStatus;

    pub(super) fn AudioObjectSetPropertyData(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: *const c_void,
        in_data_size: u32,
        in_data: *const c_void,
    ) -> OSStatus;

    pub(super) fn AudioDeviceCreateIOProcID(
        in_device: AudioDeviceID,
        in_proc: AudioDeviceIOProc,
        in_client_data: *mut c_void,
        out_io_proc_id: *mut AudioDeviceIOProcID,
    ) -> OSStatus;

    pub(super) fn AudioDeviceDestroyIOProcID(
        in_device: AudioDeviceID,
        in_io_proc_id: AudioDeviceIOProcID,
    ) -> OSStatus;

    pub(super) fn AudioDeviceStart(
        in_device: AudioDeviceID,
        in_proc_id: AudioDeviceIOProcID,
    ) -> OSStatus;

    pub(super) fn AudioDeviceStop(
        in_device: AudioDeviceID,
        in_proc_id: AudioDeviceIOProcID,
    ) -> OSStatus;
}

unsafe extern "C" {
    pub(super) fn getpid() -> i32;
}
