use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use windows::Win32::Media::Audio::{
    AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_E_DEVICE_INVALIDATED, AUDCLNT_E_SERVICE_NOT_RUNNING,
};
use windows::core::HRESULT;

use crate::buffer::Consumer;
use crate::pipeline::rt_telemetry::RtErrorCode;
use crate::player::{
    AudioFadeControl, FadeDirection, LinearFadeState, apply_fade_ramp_to_wire_bytes,
};
use crate::verification::{AudioVerificationEngine, VerificationTapProducer, WireSampleFormat};

use super::clock::{WasapiExclusiveOpenSpec, fill_wasapi_wire_silence, wasapi_chunk_has_nonzero};
use super::control::WasapiRenderControl;
use super::loop_rt::run_wasapi_render_loop_rt;
use super::ops::WasapiStreamOps;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum RtLoopControl {
    Proceed,
    Continue,
    Break,
}

pub(super) fn try_commit_loop_exit(ctrl: &WasapiRenderControl) -> bool {
    ctrl.loop_exited.store(true, Ordering::SeqCst);
    if !ctrl.stopped.load(Ordering::SeqCst)
        && !ctrl.device_lost.load(Ordering::SeqCst)
        && (!ctrl.swap_inbox.load(Ordering::SeqCst).is_null()
            || ctrl.skip_silence.load(Ordering::SeqCst))
    {
        ctrl.loop_exited.store(false, Ordering::SeqCst);
        return false;
    }
    true
}

pub(super) struct LoopExitGuard<'a>(pub(super) &'a WasapiRenderControl);

impl Drop for LoopExitGuard<'_> {
    fn drop(&mut self) {
        self.0.loop_exited.store(true, Ordering::SeqCst);
        self.0.stopped.store(true, Ordering::SeqCst);
        wake_all_flush_waiters(self.0);
    }
}

#[inline]
pub(super) fn is_device_lost_hr(hr: HRESULT) -> bool {
    hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING
}

/// Strictly lock-free, allocation-free RT error recorder.
/// Human-readable error formatting happens lazily off-RT via `WasapiRenderControl::sync_last_error_off_rt`.
#[inline]
pub(super) fn record_wasapi_error_rt(ctrl: &WasapiRenderControl, code: RtErrorCode, hr: HRESULT) {
    let effective_code = if is_device_lost_hr(hr) {
        ctrl.device_lost.store(true, Ordering::SeqCst);
        RtErrorCode::DeviceInvalidated
    } else {
        code
    };
    ctrl.telemetry.record_error_rt(effective_code, hr.0);
    ctrl.state_code.store(4, Ordering::SeqCst);
}

#[inline]
pub(super) fn ack_flush_and_wake(ctrl: &WasapiRenderControl, seq: u64) {
    // Strictly wait-free, lock-free acknowledgment on the MMCSS Pro Audio render thread.
    ctrl.flush_ack_seq.fetch_max(seq, Ordering::Release);
}

#[inline]
pub(super) fn wake_all_flush_waiters(_ctrl: &WasapiRenderControl) {
    // Control-thread flush waiters observe `ctrl.stopped` / `ctrl.device_lost` atomically.
}

/// Lock-free real-time format stamp check. If the ring-buffer producer has switched to a
/// different `WireFormatStamp`, sets `format_mismatch_flag` and forces silence output.
#[inline]
pub(super) fn is_wasapi_format_mismatched(
    ctrl: &WasapiRenderControl,
    expected_format_stamp: u64,
) -> bool {
    if ctrl.format_mismatch_flag.load(Ordering::Acquire) {
        return true;
    }
    if expected_format_stamp != 0 {
        let published = ctrl.published_format_stamp.load(Ordering::Acquire);
        if published != expected_format_stamp {
            ctrl.format_mismatch_flag.store(true, Ordering::Release);
            return true;
        }
    }
    false
}

#[allow(clippy::too_many_arguments)]
pub(super) fn prime_wasapi_buffer<O: WasapiStreamOps>(
    ops: &mut O,
    actual_frames: u32,
    spec: &WasapiExclusiveOpenSpec,
    consumer: &mut Consumer<u8>,
    ver_tap: &mut VerificationTapProducer,
    scratch: &mut [u8],
    dop_phase: &mut bool,
    ctrl: &WasapiRenderControl,
    active_eof_flag: &AtomicBool,
    active_fade_ctrl: Option<&AudioFadeControl>,
    active_expected_stamp: u64,
    buffering_gate: &mut bool,
    watermark_bytes: usize,
    fade: &mut LinearFadeState,
) -> Result<(), HRESULT> {
    let bytes_per_frame = spec.wire_format.bytes_per_sample() * (spec.channels.max(1) as usize);
    let needed = ((actual_frames as usize) * bytes_per_frame).min(scratch.len());
    let is_dsd_or_dop = matches!(
        spec.wire_format,
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. }
    );

    let ptr = ops.get_buffer(actual_frames)?;
    if ctrl.skip_silence.load(Ordering::Acquire) {
        if is_dsd_or_dop {
            fill_wasapi_wire_silence(
                &mut scratch[..needed],
                spec.wire_format,
                spec.channels,
                dop_phase,
            );
            unsafe {
                std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
            }
            ops.release_buffer(actual_frames, 0)?;
        } else {
            ops.release_buffer(actual_frames, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32)?;
        }
        return Ok(());
    }
    if is_wasapi_format_mismatched(ctrl, active_expected_stamp) {
        fill_wasapi_wire_silence(
            &mut scratch[..needed],
            spec.wire_format,
            spec.channels,
            dop_phase,
        );
        unsafe {
            std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
        }
        ops.release_buffer(actual_frames, 0)?;
        return Ok(());
    }
    if *buffering_gate {
        if consumer.available_read() >= watermark_bytes || active_eof_flag.load(Ordering::Acquire) {
            *buffering_gate = false;
        } else {
            fill_wasapi_wire_silence(
                &mut scratch[..needed],
                spec.wire_format,
                spec.channels,
                dop_phase,
            );
            unsafe {
                std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
            }
            ops.release_buffer(actual_frames, 0)?;
            return Ok(());
        }
    }

    let aligned_read = consumer.pop_slice_aligned(&mut scratch[..needed], bytes_per_frame);
    if aligned_read > 0 {
        if !ctrl.strict_bit_perfect.load(Ordering::Relaxed) && fade.gain() < 1.0 {
            apply_fade_ramp_to_wire_bytes(
                &mut scratch[..aligned_read],
                spec.wire_format,
                spec.channels as usize,
                fade,
                FadeDirection::Up,
            );
        }
        if let Some(fc) = active_fade_ctrl {
            fc.mark_audible();
        }
        if matches!(spec.wire_format, WireSampleFormat::Dop24In32MsbLe { .. }) {
            *dop_phase = scratch[aligned_read - 1] == 0x05;
        }
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
        ver_tap.push_wire(&scratch[..aligned_read]);
        if let Some(tap) = crate::visualizer::try_global_tap() {
            tap.feed_wire(
                &scratch[..aligned_read],
                spec.wire_format,
                spec.channels,
                spec.sample_rate,
            );
        }
        ctrl.frames_rendered.fetch_add(frames, Ordering::Relaxed);
        ctrl.telemetry.add_frames_rt(frames);
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

/// Core WASAPI render loop entry point (factored over [`WasapiStreamOps`] for deterministic testing).
/// Performs off-RT setup (`init_global_tap`, `attach_rt_tap`, scratch allocation), executes the
/// strictly lock-free / alloc-free [`run_wasapi_render_loop_rt`], and lazily syncs any RT error
/// string off-RT upon exit.
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

    // Off-RT setup: pre-initialize visualizer worker, SPSC verification tap, and period scratch buffer.
    let _ = crate::visualizer::init_global_tap();
    let mut ver_tap = verification.attach_rt_tap(
        spec.wire_format,
        spec.channels,
        spec.sample_rate,
        1024 * 1024,
    );
    let bytes_per_frame = spec.wire_format.bytes_per_sample() * (spec.channels.max(1) as usize);
    let mut scratch = vec![0u8; (actual_frames as usize) * bytes_per_frame];
    let mut active_eof_flag = Arc::clone(&ctrl.eof_flag);
    let mut active_fade_ctrl = ctrl.fade_ctrl.clone();

    run_wasapi_render_loop_rt(
        ops,
        spec,
        actual_frames,
        consumer,
        &mut ver_tap,
        &mut scratch,
        &mut active_eof_flag,
        &mut active_fade_ctrl,
        ctrl,
    );

    // Off-RT post-exit: lazily format any atomic RT error code into `ctrl.last_error`.
    ctrl.sync_last_error_off_rt();
}
