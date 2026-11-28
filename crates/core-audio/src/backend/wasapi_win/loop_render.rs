use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use windows::Win32::Media::Audio::{AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_E_BUFFER_TOO_LARGE};

use crate::buffer::Consumer;
use crate::pipeline::rt_telemetry::RtErrorCode;
use crate::player::{
    AudioFadeControl, FadeDirection, FadeTarget, LinearFadeState, apply_fade_ramp_to_wire_bytes,
    fade_out_wire_tail,
};
use crate::verification::{VerificationTapProducer, WireSampleFormat};

use super::clock::{WasapiExclusiveOpenSpec, fill_wasapi_wire_silence, wasapi_chunk_has_nonzero};
use super::control::WasapiRenderControl;
use super::loop_impl::{
    RtLoopControl, is_wasapi_format_mismatched, record_wasapi_error_rt, try_commit_loop_exit,
};
use super::ops::WasapiStreamOps;

pub(super) struct RtRenderVars {
    pub(super) dop_phase: bool,
    pub(super) buffering_gate: bool,
    pub(super) last_ring_epoch: u64,
    pub(super) skip_fading: bool,
    pub(super) draining_eof: bool,
    pub(super) drain_deadline: Option<Instant>,
}

#[allow(clippy::too_many_arguments)]
#[inline(always)]
pub(super) fn render_wasapi_period<O: WasapiStreamOps>(
    ops: &mut O,
    spec: &WasapiExclusiveOpenSpec,
    actual_frames: u32,
    bytes_per_frame: usize,
    is_dsd_or_dop: bool,
    clock_rate: u64,
    consumer: &mut Consumer<u8>,
    ver_tap: &mut VerificationTapProducer,
    scratch: &mut [u8],
    active_eof_flag: &mut Arc<AtomicBool>,
    active_fade_ctrl: &mut Option<Arc<AudioFadeControl>>,
    ctrl: &WasapiRenderControl,
    active_expected_stamp: u64,
    active_watermark_bytes: usize,
    fade: &mut LinearFadeState,
    skip_fade: &mut LinearFadeState,
    in_skip_silence: bool,
    vars: &mut RtRenderVars,
) -> RtLoopControl {
    // 5. Render next audio period (strictly zero-lock, zero-alloc on RT render thread).
    match ops.get_buffer(actual_frames) {
        Ok(ptr) => {
            let needed = ((actual_frames as usize) * bytes_per_frame).min(scratch.len());
            let strict_bp = ctrl.strict_bit_perfect.load(Ordering::Relaxed);
            if in_skip_silence {
                if ctrl.skip_fade_requested.swap(false, Ordering::AcqRel) {
                    if !is_dsd_or_dop && !strict_bp && fade.gain() > 0.0 {
                        skip_fade.set_gain(fade.gain());
                        vars.skip_fading = true;
                    } else {
                        vars.skip_fading = false;
                        fade.set_zero();
                    }
                }
                if vars.skip_fading {
                    let aligned_bytes =
                        consumer.pop_slice_aligned(&mut scratch[..needed], bytes_per_frame);
                    if aligned_bytes > 0 {
                        apply_fade_ramp_to_wire_bytes(
                            &mut scratch[..aligned_bytes],
                            spec.wire_format,
                            spec.channels as usize,
                            skip_fade,
                            FadeDirection::Down,
                        );
                        if aligned_bytes < needed {
                            fill_wasapi_wire_silence(
                                &mut scratch[aligned_bytes..needed],
                                spec.wire_format,
                                spec.channels,
                                &mut vars.dop_phase,
                            );
                            skip_fade.set_zero();
                        }
                        if skip_fade.gain() <= 0.0 {
                            vars.skip_fading = false;
                            fade.set_zero();
                        }
                        unsafe {
                            std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                        }
                        if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                            record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                            return RtLoopControl::Break;
                        }
                        if let Ok((pos, qpc)) = ops.clock_position() {
                            ctrl.clock_state.record_position(pos, qpc);
                        }
                        return RtLoopControl::Continue;
                    } else {
                        vars.skip_fading = false;
                        fade.set_zero();
                    }
                }
                // Keep IAudioClient alive with full-period silent release during rapid skips.
                let rel_res = if is_dsd_or_dop {
                    fill_wasapi_wire_silence(
                        &mut scratch[..needed],
                        spec.wire_format,
                        spec.channels,
                        &mut vars.dop_phase,
                    );
                    unsafe {
                        std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                    }
                    ops.release_buffer(actual_frames, 0)
                } else {
                    ops.release_buffer(actual_frames, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32)
                };
                if let Err(hr) = rel_res {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                    return RtLoopControl::Break;
                }
                if let Ok((pos, qpc)) = ops.clock_position() {
                    ctrl.clock_state.record_position(pos, qpc);
                }
                return RtLoopControl::Continue;
            }
            if is_wasapi_format_mismatched(ctrl, active_expected_stamp) {
                ctrl.telemetry
                    .record_error_rt(RtErrorCode::FormatMismatch, 0);
                fill_wasapi_wire_silence(
                    &mut scratch[..needed],
                    spec.wire_format,
                    spec.channels,
                    &mut vars.dop_phase,
                );
                unsafe {
                    std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                }
                if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                    return RtLoopControl::Break;
                }
                return RtLoopControl::Continue;
            }
            let fade_target = active_fade_ctrl
                .as_ref()
                .map(|fc| fc.target())
                .unwrap_or(FadeTarget::Playing);

            if matches!(
                fade_target,
                FadeTarget::PauseFadeOut | FadeTarget::StopFadeOut | FadeTarget::SeekFadeOut
            ) {
                if let Some(fc) = active_fade_ctrl.as_deref() {
                    if strict_bp || !fade.fade_out_enabled() || fade.gain() <= 0.0 {
                        fade.set_zero();
                        fc.mark_fade_out_done();
                        if fade_target == FadeTarget::SeekFadeOut {
                            vars.buffering_gate = active_watermark_bytes > 0;
                        }
                        fill_wasapi_wire_silence(
                            &mut scratch[..needed],
                            spec.wire_format,
                            spec.channels,
                            &mut vars.dop_phase,
                        );
                    } else {
                        let aligned_bytes =
                            consumer.pop_slice_aligned(&mut scratch[..needed], bytes_per_frame);
                        if aligned_bytes > 0 {
                            apply_fade_ramp_to_wire_bytes(
                                &mut scratch[..aligned_bytes],
                                spec.wire_format,
                                spec.channels as usize,
                                fade,
                                FadeDirection::Down,
                            );
                        } else {
                            fade.set_zero();
                        }
                        if aligned_bytes < needed {
                            fill_wasapi_wire_silence(
                                &mut scratch[aligned_bytes..needed],
                                spec.wire_format,
                                spec.channels,
                                &mut vars.dop_phase,
                            );
                        }
                        if fade.gain() <= 0.0 {
                            fc.mark_fade_out_done();
                            if fade_target == FadeTarget::SeekFadeOut {
                                vars.buffering_gate = active_watermark_bytes > 0;
                            }
                        }
                    }
                }
                unsafe {
                    std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                }
                if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                    return RtLoopControl::Break;
                }
                return RtLoopControl::Continue;
            }

            // Detect ring flush epoch change (e.g. post-seek) and re-arm watermark gate.
            let req_ep = consumer.requested_epoch();
            if req_ep != vars.last_ring_epoch {
                if consumer.has_pending_flush() && consumer.try_flush_and_ack().is_none() {
                    fill_wasapi_wire_silence(
                        &mut scratch[..needed],
                        spec.wire_format,
                        spec.channels,
                        &mut vars.dop_phase,
                    );
                    unsafe {
                        std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                    }
                    if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                        record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                        return RtLoopControl::Break;
                    }
                    return RtLoopControl::Continue;
                }
                vars.last_ring_epoch = consumer.epoch();
                vars.buffering_gate = active_watermark_bytes > 0;
                fade.reset_for_play_start();
            }

            // Update lock-free buffered_ms telemetry.
            let avail_before = consumer.available_read();
            if let Some(ref bms) = ctrl.buffered_ms {
                let frames_avail = (avail_before / bytes_per_frame) as u64;
                bms.store((frames_avail * 1000) / clock_rate, Ordering::Relaxed);
            }

            if vars.buffering_gate {
                if avail_before >= active_watermark_bytes || active_eof_flag.load(Ordering::Acquire)
                {
                    vars.buffering_gate = false;
                } else {
                    fill_wasapi_wire_silence(
                        &mut scratch[..needed],
                        spec.wire_format,
                        spec.channels,
                        &mut vars.dop_phase,
                    );
                    unsafe {
                        std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                    }
                    if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                        record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                        return RtLoopControl::Break;
                    }
                    return RtLoopControl::Continue;
                }
            }

            let aligned_bytes = consumer.pop_slice_aligned(&mut scratch[..needed], bytes_per_frame);

            if aligned_bytes > 0 {
                if !strict_bp && fade.gain() < 1.0 {
                    apply_fade_ramp_to_wire_bytes(
                        &mut scratch[..aligned_bytes],
                        spec.wire_format,
                        spec.channels as usize,
                        fade,
                        FadeDirection::Up,
                    );
                }
                if let Some(fc) = active_fade_ctrl.as_deref() {
                    fc.mark_audible();
                }
                if matches!(spec.wire_format, WireSampleFormat::Dop24In32MsbLe { .. }) {
                    vars.dop_phase = scratch[aligned_bytes - 1] == 0x05;
                }
                if aligned_bytes < needed {
                    if !active_eof_flag.load(Ordering::Acquire) {
                        ctrl.underrun_count.fetch_add(1, Ordering::Relaxed);
                        ctrl.telemetry.record_xrun_rt();
                        if !strict_bp {
                            fade_out_wire_tail(
                                &mut scratch[..aligned_bytes],
                                spec.wire_format,
                                spec.channels as usize,
                                128,
                            );
                        }
                        if active_watermark_bytes > 0 {
                            vars.buffering_gate = true;
                            fade.reset_for_play_start();
                        }
                    }
                    fill_wasapi_wire_silence(
                        &mut scratch[aligned_bytes..needed],
                        spec.wire_format,
                        spec.channels,
                        &mut vars.dop_phase,
                    );
                }
                unsafe {
                    std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                }
                let frames = (aligned_bytes / bytes_per_frame) as u64;
                ver_tap.push_wire(&scratch[..aligned_bytes]);
                if let Some(tap) = crate::visualizer::try_global_tap() {
                    tap.feed_wire(
                        &scratch[..aligned_bytes],
                        spec.wire_format,
                        spec.channels,
                        spec.sample_rate,
                    );
                }
                ctrl.frames_rendered.fetch_add(frames, Ordering::Relaxed);
                ctrl.telemetry.add_frames_rt(frames);
                if wasapi_chunk_has_nonzero(&scratch[..aligned_bytes], spec.wire_format) {
                    ctrl.nonzero_frames.fetch_add(frames, Ordering::Relaxed);
                }

                if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                    return RtLoopControl::Break;
                }
                if let Ok((pos, qpc)) = ops.clock_position() {
                    ctrl.clock_state.record_position(pos, qpc);
                }
            } else if active_eof_flag.load(Ordering::SeqCst)
                && consumer.available_read() < bytes_per_frame
            {
                // Release empty without pushing an extra full period of trailing silence.
                if let Err(hr) = ops.release_buffer(0, 0) {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                    return RtLoopControl::Break;
                }
                match ops.current_padding() {
                    Ok(0) => {
                        if !try_commit_loop_exit(ctrl) {
                            return RtLoopControl::Continue;
                        }
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
                        return RtLoopControl::Break;
                    }
                    Ok(_) => {
                        vars.draining_eof = true;
                        let buf_ms = ((actual_frames as u64 * 1000)
                            / spec.sample_rate.max(1) as u64)
                            .max(10);
                        vars.drain_deadline = Some(
                            Instant::now() + Duration::from_millis((buf_ms * 3).clamp(50, 500)),
                        );
                        return RtLoopControl::Continue;
                    }
                    Err(hr) => {
                        record_wasapi_error_rt(ctrl, RtErrorCode::ClockQueryFailed, hr);
                        return RtLoopControl::Break;
                    }
                }
            } else {
                // Transient underrun while track still playing: increment atomic counter,
                // emit format-appropriate silence, and re-arm watermark gate so recovery fades in cleanly.
                ctrl.underrun_count.fetch_add(1, Ordering::Relaxed);
                ctrl.telemetry.record_xrun_rt();
                if active_watermark_bytes > 0 {
                    vars.buffering_gate = true;
                    fade.reset_for_play_start();
                }
                fill_wasapi_wire_silence(
                    &mut scratch[..needed],
                    spec.wire_format,
                    spec.channels,
                    &mut vars.dop_phase,
                );
                unsafe {
                    std::ptr::copy_nonoverlapping(scratch.as_ptr(), ptr, needed);
                }
                if let Err(hr) = ops.release_buffer(actual_frames, 0) {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferReleaseFailed, hr);
                    return RtLoopControl::Break;
                }
                if let Ok((pos, qpc)) = ops.clock_position() {
                    ctrl.clock_state.record_position(pos, qpc);
                }
            }
        }
        Err(hr) => {
            if hr == AUDCLNT_E_BUFFER_TOO_LARGE {
                return RtLoopControl::Continue;
            }
            record_wasapi_error_rt(ctrl, RtErrorCode::BufferGetFailed, hr);
            return RtLoopControl::Break;
        }
    }
    RtLoopControl::Proceed
}
