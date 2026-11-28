use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use windows::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows::Win32::Media::Audio::AUDCLNT_E_NOT_STOPPED;
use windows::Win32::System::Threading::WaitForMultipleObjects;
use windows::core::HRESULT;

use crate::buffer::Consumer;
use crate::pipeline::rt_telemetry::RtErrorCode;
use crate::player::{AudioFadeControl, FadeTarget, LinearFadeState};
use crate::verification::{VerificationTapProducer, WireSampleFormat};

use super::clock::WasapiExclusiveOpenSpec;
use super::control::WasapiRenderControl;
use super::loop_impl::{
    LoopExitGuard, RtLoopControl, ack_flush_and_wake, prime_wasapi_buffer, record_wasapi_error_rt,
    try_commit_loop_exit, wake_all_flush_waiters,
};
use super::loop_render::{RtRenderVars, render_wasapi_period};
use super::ops::WasapiStreamOps;

/// Strictly hard real-time WASAPI render loop executed under MMCSS `"Pro Audio"` priority:
/// ZERO mutex/RwLock locks, ZERO heap allocations/drops, ZERO `format!`/`String`, ZERO thread spawns.
#[allow(clippy::too_many_arguments)]
pub(super) fn run_wasapi_render_loop_rt<O: WasapiStreamOps>(
    ops: &mut O,
    spec: &WasapiExclusiveOpenSpec,
    actual_frames: u32,
    consumer: &mut Consumer<u8>,
    ver_tap: &mut VerificationTapProducer,
    scratch: &mut [u8],
    active_eof_flag: &mut Arc<AtomicBool>,
    active_fade_ctrl: &mut Option<Arc<AudioFadeControl>>,
    ctrl: &WasapiRenderControl,
) {
    let bytes_per_frame = spec.wire_format.bytes_per_sample() * (spec.channels.max(1) as usize);
    let is_dsd_or_dop = matches!(
        spec.wire_format,
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. }
    );
    let clock_rate = if matches!(spec.wire_format, WireSampleFormat::NativeDsd { .. }) {
        (spec.sample_rate / 8).max(44_100) as u64
    } else {
        spec.sample_rate.max(8_000) as u64
    };
    let mut dop_phase = false;
    let mut active_session_id = ctrl.session_id;
    let mut active_expected_stamp = ctrl.expected_format_stamp;
    let mut active_watermark_bytes = ctrl.startup_watermark_bytes.load(Ordering::Acquire);
    let mut buffering_gate = active_watermark_bytes > 0;
    let mut last_ring_epoch = consumer.epoch();
    let (fade_in, fade_out) = active_fade_ctrl
        .as_ref()
        .map(|fc| (fc.fade_in_enabled(), fc.fade_out_enabled()))
        .unwrap_or((false, false));
    let mut fade = LinearFadeState::new(
        spec.sample_rate,
        fade_in,
        fade_out,
        ctrl.paused.load(Ordering::Acquire),
    );
    let skip_fade_frames = ((spec.sample_rate.max(8_000) as u64) * 5) / 1000;
    let mut skip_fade = LinearFadeState::with_frames(skip_fade_frames, false, true, false);
    let mut skip_fading = false;

    if let Err(hr) = prime_wasapi_buffer(
        ops,
        actual_frames,
        spec,
        consumer,
        ver_tap,
        scratch,
        &mut dop_phase,
        ctrl,
        active_eof_flag.as_ref(),
        active_fade_ctrl.as_deref(),
        active_expected_stamp,
        &mut buffering_gate,
        active_watermark_bytes,
        &mut fade,
    ) {
        record_wasapi_error_rt(ctrl, RtErrorCode::BufferGetFailed, hr);
        ctrl.stopped.store(true, Ordering::Release);
        wake_all_flush_waiters(ctrl);
        return;
    }

    if let Err(hr) = ops.start() {
        record_wasapi_error_rt(ctrl, RtErrorCode::StreamStartFailed, hr);
        ctrl.stopped.store(true, Ordering::Release);
        wake_all_flush_waiters(ctrl);
        return;
    }

    let _exit_guard = LoopExitGuard(ctrl);

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
    let mut consecutive_timeouts: u32 = 0;
    let mut last_stall_probe: Option<(u32, Option<u64>)> = None;
    let mut stall_unmoved_ticks: u32 = 0;

    loop {
        let base_timeout_ms = ctrl.wait_timeout_ms.load(Ordering::Relaxed).max(1);
        let timeout_ms = if draining_eof {
            base_timeout_ms.min(10)
        } else {
            base_timeout_ms
        };
        let wait = unsafe { WaitForMultipleObjects(&events, false, timeout_ms) };

        if ctrl.stopped.load(Ordering::Acquire) || wait.0 == WAIT_OBJECT_0.0 + 1 {
            break;
        }
        if wait.0 == 0xFFFF_FFFF {
            record_wasapi_error_rt(ctrl, RtErrorCode::WaitFailed, HRESULT(-1));
            break;
        }

        // 0. Lock-free hot-swap adoption (zero alloc, zero drop, zero COM reopen on RT thread).
        let incoming_swap = ctrl.swap_inbox.swap(null_mut(), Ordering::AcqRel);
        if !incoming_swap.is_null() {
            let adopted_skip_seq: u64;
            unsafe {
                let env = &mut *incoming_swap;
                adopted_skip_seq = env.expected_skip_seq;
                let p = &mut env.payload;
                std::mem::swap(consumer, &mut p.consumer);
                std::mem::swap(ver_tap, &mut p.ver_tap);
                std::mem::swap(active_eof_flag, &mut p.eof_flag);
                std::mem::swap(active_fade_ctrl, &mut p.fade_ctrl);
                active_watermark_bytes = p.watermark_bytes;
                active_session_id = p.session_id;
                active_expected_stamp = p.expected_format_stamp;
            }
            ctrl.retire_swap_ptr_rt(incoming_swap);
            ctrl.active_session_id
                .store(active_session_id, Ordering::Release);
            // Clear `skip_silence` strictly on the RT thread and ONLY when no newer
            // `enter_skip_silence()` or `current_session_id` raced with this hot-swap.
            if ctrl.current_session_id.load(Ordering::SeqCst) == active_session_id
                && ctrl.skip_silence_seq.load(Ordering::SeqCst) == adopted_skip_seq
            {
                ctrl.skip_fade_requested.store(false, Ordering::Release);
                ctrl.skip_silence.store(false, Ordering::SeqCst);
                if ctrl.skip_silence_seq.load(Ordering::SeqCst) != adopted_skip_seq
                    || ctrl.current_session_id.load(Ordering::SeqCst) != active_session_id
                {
                    ctrl.skip_fade_requested.store(true, Ordering::Release);
                    ctrl.skip_silence.store(true, Ordering::SeqCst);
                }
            }
            last_ring_epoch = consumer.epoch();
            buffering_gate = active_watermark_bytes > 0;
            let (new_fi, new_fo) = active_fade_ctrl
                .as_ref()
                .map(|fc| (fc.fade_in_enabled(), fc.fade_out_enabled()))
                .unwrap_or((false, false));
            fade = LinearFadeState::new(
                spec.sample_rate,
                new_fi,
                new_fo,
                ctrl.paused.load(Ordering::Acquire),
            );
            skip_fading = false;
            draining_eof = false;
            drain_deadline = None;
            ctrl.eof_drained.store(false, Ordering::Release);
            dop_phase = false;
            consecutive_timeouts = 0;
            last_stall_probe = None;
            stall_unmoved_ticks = 0;
            if was_paused {
                // Clear Track A's stale paused hardware buffer and force a fresh prime of Track B
                // before `ops.start()` on resume.
                if let Err(hr) = ops.reset() {
                    if hr == AUDCLNT_E_NOT_STOPPED {
                        let _ = ops.stop();
                        if let Err(hr2) = ops.reset() {
                            record_wasapi_error_rt(ctrl, RtErrorCode::StreamResetFailed, hr2);
                            break;
                        }
                    } else {
                        record_wasapi_error_rt(ctrl, RtErrorCode::StreamResetFailed, hr);
                        break;
                    }
                }
                ops.reset_buf_event();
                ctrl.clock_state.on_reset();
                needs_prime = true;
            }
        }

        let in_skip_silence = ctrl.skip_silence.load(Ordering::Acquire);
        if in_skip_silence && draining_eof {
            draining_eof = false;
            drain_deadline = None;
        }
        let stop_fade_in_progress = active_fade_ctrl
            .as_ref()
            .is_some_and(|fc| fc.target() == FadeTarget::StopFadeOut && !fc.is_fade_out_done());
        if !stop_fade_in_progress
            && !in_skip_silence
            && ctrl.swap_inbox.load(Ordering::SeqCst).is_null()
            && ctrl.current_session_id.load(Ordering::SeqCst) != active_session_id
        {
            if !try_commit_loop_exit(ctrl) {
                continue;
            }
            break;
        }

        // 1. Flush handling (processed before pause/render on ANY wake).
        let req_seq = ctrl.flush_req_seq.load(Ordering::Acquire);
        if req_seq > last_handled_flush_seq {
            if !was_paused && let Err(hr) = ops.stop() {
                record_wasapi_error_rt(ctrl, RtErrorCode::StreamStopFailed, hr);
                wake_all_flush_waiters(ctrl);
                break;
            }

            if let Err(hr) = ops.reset() {
                if hr == AUDCLNT_E_NOT_STOPPED {
                    let _ = ops.stop();
                    if let Err(hr2) = ops.reset() {
                        record_wasapi_error_rt(ctrl, RtErrorCode::StreamResetFailed, hr2);
                        wake_all_flush_waiters(ctrl);
                        break;
                    }
                } else {
                    record_wasapi_error_rt(ctrl, RtErrorCode::StreamResetFailed, hr);
                    wake_all_flush_waiters(ctrl);
                    break;
                }
            }

            ops.reset_buf_event();
            if consumer.has_pending_flush() {
                let _ = consumer.try_flush_and_ack();
            } else {
                let _ = consumer.try_clear();
            }
            last_ring_epoch = consumer.epoch();
            buffering_gate = active_watermark_bytes > 0;
            fade.reset_for_play_start();
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
                    ver_tap,
                    scratch,
                    &mut dop_phase,
                    ctrl,
                    active_eof_flag.as_ref(),
                    active_fade_ctrl.as_deref(),
                    active_expected_stamp,
                    &mut buffering_gate,
                    active_watermark_bytes,
                    &mut fade,
                ) {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferGetFailed, hr);
                    wake_all_flush_waiters(ctrl);
                    break;
                }
                if let Err(hr) = ops.start() {
                    record_wasapi_error_rt(ctrl, RtErrorCode::StreamStartFailed, hr);
                    wake_all_flush_waiters(ctrl);
                    break;
                }
                was_paused = false;
                needs_prime = false;
            }

            last_handled_flush_seq = req_seq;
            consecutive_timeouts = 0;
            last_stall_probe = None;
            stall_unmoved_ticks = 0;
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
                record_wasapi_error_rt(ctrl, RtErrorCode::StreamStopFailed, hr);
                break;
            }
            was_paused = true;
            consecutive_timeouts = 0;
            last_stall_probe = None;
            stall_unmoved_ticks = 0;
            continue;
        } else if !now_paused && was_paused {
            if needs_prime {
                fade.reset_for_play_start();
                if let Err(hr) = prime_wasapi_buffer(
                    ops,
                    actual_frames,
                    spec,
                    consumer,
                    ver_tap,
                    scratch,
                    &mut dop_phase,
                    ctrl,
                    active_eof_flag.as_ref(),
                    active_fade_ctrl.as_deref(),
                    active_expected_stamp,
                    &mut buffering_gate,
                    active_watermark_bytes,
                    &mut fade,
                ) {
                    record_wasapi_error_rt(ctrl, RtErrorCode::BufferGetFailed, hr);
                    break;
                }
                needs_prime = false;
            }
            if let Err(hr) = ops.start() {
                record_wasapi_error_rt(ctrl, RtErrorCode::StreamStartFailed, hr);
                break;
            }
            was_paused = false;
            consecutive_timeouts = 0;
            last_stall_probe = None;
            stall_unmoved_ticks = 0;
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
                        if !try_commit_loop_exit(ctrl) {
                            draining_eof = false;
                            drain_deadline = None;
                            continue;
                        }
                        if let Some(fc) = active_fade_ctrl.as_deref() {
                            fc.mark_silent();
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
                    continue;
                }
                Err(hr) => {
                    record_wasapi_error_rt(ctrl, RtErrorCode::ClockQueryFailed, hr);
                    break;
                }
            }
        }

        // 4. Strict wake gate + hardware clock stall watchdog while playing.
        if wait.0 != WAIT_OBJECT_0.0 {
            if wait.0 == WAIT_TIMEOUT.0 && !was_paused && !draining_eof {
                consecutive_timeouts = consecutive_timeouts.saturating_add(1);
                if consecutive_timeouts >= 10 {
                    match ops.current_padding() {
                        Err(hr) => {
                            ctrl.device_lost.store(true, Ordering::SeqCst);
                            record_wasapi_error_rt(ctrl, RtErrorCode::DeviceInvalidated, hr);
                            break;
                        }
                        Ok(padding) => {
                            let clock_pos = ops.clock_position().ok().map(|(pos, _)| pos);
                            let sample = (padding, clock_pos);
                            if last_stall_probe == Some(sample) {
                                stall_unmoved_ticks = stall_unmoved_ticks.saturating_add(1);
                                if stall_unmoved_ticks >= 10 {
                                    ctrl.device_lost.store(true, Ordering::SeqCst);
                                    ctrl.telemetry
                                        .record_error_rt(RtErrorCode::ClockQueryFailed, 0);
                                    ctrl.state_code.store(4, Ordering::SeqCst);
                                    break;
                                }
                            } else {
                                last_stall_probe = Some(sample);
                                stall_unmoved_ticks = 0;
                            }
                        }
                    }
                }
            }
            continue;
        }
        consecutive_timeouts = 0;
        last_stall_probe = None;
        stall_unmoved_ticks = 0;

        let mut vars = RtRenderVars {
            dop_phase,
            buffering_gate,
            last_ring_epoch,
            skip_fading,
            draining_eof,
            drain_deadline,
        };
        let step = render_wasapi_period(
            ops,
            spec,
            actual_frames,
            bytes_per_frame,
            is_dsd_or_dop,
            clock_rate,
            consumer,
            ver_tap,
            scratch,
            active_eof_flag,
            active_fade_ctrl,
            ctrl,
            active_expected_stamp,
            active_watermark_bytes,
            &mut fade,
            &mut skip_fade,
            in_skip_silence,
            &mut vars,
        );
        dop_phase = vars.dop_phase;
        buffering_gate = vars.buffering_gate;
        last_ring_epoch = vars.last_ring_epoch;
        skip_fading = vars.skip_fading;
        draining_eof = vars.draining_eof;
        drain_deadline = vars.drain_deadline;
        match step {
            RtLoopControl::Proceed => {}
            RtLoopControl::Continue => continue,
            RtLoopControl::Break => break,
        }
    }

    if !ctrl.device_lost.load(Ordering::Acquire) {
        let _ = ops.stop();
    }
    ctrl.stopped.store(true, Ordering::Release);
    wake_all_flush_waiters(ctrl);
}
