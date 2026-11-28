mod ffi;
mod props;

use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::backend::PullStreamConfig;
use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::ring_buffer::UnderrunGuard;
use crate::pipeline::rt_telemetry::{RtErrorCode, RtTelemetry};
use crate::verification::WireSampleFormat;

use ffi::{
    AudioBufferList, AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID, AudioDeviceID,
    AudioDeviceIOProcID, AudioDeviceStart, AudioDeviceStop, OSStatus,
};
use props::{
    acquire_hog_mode, release_hog_mode, resolve_device_id, set_buffer_frame_size,
    set_nominal_sample_rate,
};

pub use props::enumerate_devices;

struct CoreAudioRtContext {
    consumer: Consumer<u8>,
    telemetry: Arc<RtTelemetry>,
    wire_format: WireSampleFormat,
    channels: usize,
    sample_rate: u32,
    strict_bit_perfect: bool,
    dop_phase: bool,
    muted: AtomicBool,
}

/// Strictly RT-safe CoreAudio HAL IOProc callback:
/// ZERO locks, ZERO heap allocations, ZERO logging, ZERO syscalls.
unsafe extern "C" fn coreaudio_io_proc(
    _in_device: AudioDeviceID,
    _in_now: *const c_void,
    _in_input_data: *const AudioBufferList,
    _in_input_time: *const c_void,
    out_output_data: *mut AudioBufferList,
    _in_output_time: *const c_void,
    in_client_data: *mut c_void,
) -> OSStatus {
    if out_output_data.is_null() || in_client_data.is_null() {
        return 0;
    }
    let ctx = unsafe { &mut *(in_client_data as *mut CoreAudioRtContext) };
    let list = unsafe { &mut *out_output_data };
    if list.m_number_buffers == 0 {
        return 0;
    }
    let buf = &mut list.m_buffers[0];
    if buf.m_data.is_null() || buf.m_data_byte_size == 0 {
        return 0;
    }
    let dst = unsafe {
        std::slice::from_raw_parts_mut(buf.m_data as *mut u8, buf.m_data_byte_size as usize)
    };

    if ctx.muted.load(Ordering::Acquire) {
        UnderrunGuard::fill_wire_silence(dst, ctx.wire_format, &mut ctx.dop_phase);
        return 0;
    }

    let bpf = ctx.wire_format.bytes_per_sample().max(1) * ctx.channels.max(1);
    let popped = ctx.consumer.pop_slice_aligned(dst, bpf);
    if popped < dst.len() {
        UnderrunGuard::handle_wire_underrun(
            dst,
            popped,
            ctx.wire_format,
            ctx.channels,
            ctx.strict_bit_perfect,
            &mut ctx.dop_phase,
            Some(&ctx.telemetry),
        );
    } else if matches!(ctx.wire_format, WireSampleFormat::Dop24In32MsbLe { .. }) && popped > 0 {
        ctx.dop_phase = dst[popped - 1] == 0x05;
    }

    if popped > 0 {
        let frames = (popped / bpf) as u64;
        ctx.telemetry.add_frames_rt(frames);
        if let Some(tap) = crate::visualizer::try_global_tap() {
            tap.feed_wire(
                &dst[..popped],
                ctx.wire_format,
                ctx.channels as u16,
                ctx.sample_rate,
            );
        }
    }
    0
}

pub struct CoreAudioActiveHandle {
    device_id: AudioDeviceID,
    io_proc_id: AudioDeviceIOProcID,
    rt_ctx: *mut CoreAudioRtContext,
    pub hog_acquired: bool,
    stopped: bool,
}

// SAFETY: Ownership of `CoreAudioActiveHandle` is synchronized off-RT via `OutputDeviceFsm`.
unsafe impl Send for CoreAudioActiveHandle {}

impl CoreAudioActiveHandle {
    pub fn open_and_start(
        config: &PullStreamConfig,
        consumer: Consumer<u8>,
        telemetry: Arc<RtTelemetry>,
    ) -> Result<Self, BackendError> {
        let device_id = resolve_device_id(config.device_id.as_deref())?;

        // 1. Acquire CoreAudio Hog Mode (`kAudioDevicePropertyHogMode`).
        let hog_acquired = acquire_hog_mode(device_id);
        if config.strict_bit_perfect && !hog_acquired {
            return Err(BackendError::DeviceInUse);
        }

        // 2. Switch hardware nominal sample rate (`kAudioDevicePropertyNominalSampleRate`).
        let target_sr = config.sample_rate as f64;
        if let Err(err) = set_nominal_sample_rate(device_id, target_sr) {
            if hog_acquired {
                release_hog_mode(device_id);
            }
            return Err(err);
        }

        // 3. Configure preferred hardware buffer frame size if requested.
        if config.buffer_frames > 0 {
            let _ = set_buffer_frame_size(device_id, config.buffer_frames);
        }

        // 4. Allocate RT context BEFORE registering IOProc (zero allocs inside callback).
        let rt_ctx = Box::into_raw(Box::new(CoreAudioRtContext {
            consumer,
            telemetry: Arc::clone(&telemetry),
            wire_format: config.wire_format,
            channels: config.channels.max(1) as usize,
            sample_rate: config.sample_rate,
            strict_bit_perfect: config.strict_bit_perfect,
            dop_phase: false,
            muted: AtomicBool::new(false),
        }));

        let mut io_proc_id: AudioDeviceIOProcID = null_mut();
        let create_status = unsafe {
            AudioDeviceCreateIOProcID(
                device_id,
                coreaudio_io_proc,
                rt_ctx as *mut c_void,
                &mut io_proc_id,
            )
        };
        if create_status != 0 || io_proc_id.is_null() {
            unsafe {
                drop(Box::from_raw(rt_ctx));
            }
            if hog_acquired {
                release_hog_mode(device_id);
            }
            telemetry.record_error_rt(RtErrorCode::StreamStartFailed, create_status);
            return Err(BackendError::DriverError(format!(
                "AudioDeviceCreateIOProcID failed: OSStatus={create_status}"
            )));
        }

        let start_status = unsafe { AudioDeviceStart(device_id, io_proc_id) };
        if start_status != 0 {
            unsafe {
                let _ = AudioDeviceDestroyIOProcID(device_id, io_proc_id);
                drop(Box::from_raw(rt_ctx));
            }
            if hog_acquired {
                release_hog_mode(device_id);
            }
            telemetry.record_error_rt(RtErrorCode::StreamStartFailed, start_status);
            return Err(BackendError::DriverError(format!(
                "AudioDeviceStart failed: OSStatus={start_status}"
            )));
        }

        Ok(Self {
            device_id,
            io_proc_id,
            rt_ctx,
            hog_acquired,
            stopped: false,
        })
    }

    pub fn stop_io_proc(&mut self) {
        if self.stopped {
            return;
        }
        if !self.rt_ctx.is_null() {
            unsafe {
                (*self.rt_ctx).muted.store(true, Ordering::Release);
            }
        }
        if !self.io_proc_id.is_null() {
            unsafe {
                let _ = AudioDeviceStop(self.device_id, self.io_proc_id);
                let _ = AudioDeviceDestroyIOProcID(self.device_id, self.io_proc_id);
            }
            self.io_proc_id = null_mut();
        }
        if self.hog_acquired {
            release_hog_mode(self.device_id);
            self.hog_acquired = false;
        }
        if !self.rt_ctx.is_null() {
            unsafe {
                drop(Box::from_raw(self.rt_ctx));
            }
            self.rt_ctx = null_mut();
        }
        self.stopped = true;
    }
}

impl Drop for CoreAudioActiveHandle {
    fn drop(&mut self) {
        self.stop_io_proc();
    }
}
