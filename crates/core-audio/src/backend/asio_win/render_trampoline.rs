use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicPtr, AtomicU32, AtomicU64, AtomicUsize, Ordering,
};
use std::time::{Duration, Instant};

use crate::pipeline::rt_telemetry::RtErrorCode;
use crate::player::{FadeDirection, FadeTarget, apply_fade_ramp_to_wire_bytes, fade_out_wire_tail};
use crate::verification::WireSampleFormat;

use super::callbacks::asio_chunk_has_nonzero;
use super::ffi_types::{
    ASIO_OK, ASIO_ST_DSD_INT8_LSB1, ASIO_ST_DSD_INT8_LSB8, ASIO_ST_DSD_INT8_MSB1,
    ASIO_ST_FLOAT64_LSB, ASIO_ST_INT16_LSB, ASIO_ST_INT24_LSB,
    ASIO_TIME_INFO_SAMPLE_POSITION_VALID, ASIO_TIME_INFO_SYSTEM_TIME_VALID, AsioBufferInfo,
    AsioSamples, AsioTime, AsioTimeStamp, IAsioVtbl, K_ASIO_BUFFER_SIZE_CHANGE,
    K_ASIO_ENGINE_VERSION, K_ASIO_LATENCIES_CHANGED, K_ASIO_RESET_REQUEST, K_ASIO_RESYNC_REQUEST,
    K_ASIO_SELECTOR_SUPPORTED, K_ASIO_SUPPORTS_TIME_INFO,
};
use super::render_core::AsioRenderCore;

impl AsioRenderCore {
    /// Processes a single ASIO `bufferSwitch` period. Returns `true` if `output_ready()` should be invoked.
    /// Strictly real-time safe: ZERO mutex locks, ZERO heap allocations, ZERO I/O.
    pub fn process_buffer_switch(&mut self, idx: usize, channel_buffers: &[[*mut u8; 2]]) -> bool {
        self.signals.callback_count.fetch_add(1, Ordering::Relaxed);

        // 1. Lock-free bounded flush epoch handling (works in both Playing and Paused states).
        let req_epoch = self.signals.flush_requested_epoch.load(Ordering::Acquire);
        if req_epoch != self.last_handled_flush_epoch {
            let flushed = if self.consumer.has_pending_flush() {
                self.consumer.try_flush_and_ack().is_some()
            } else {
                self.consumer.try_clear().is_some()
            };
            self.fill_both_double_buffers_silence(channel_buffers);
            if !flushed {
                return true;
            }
            self.last_ring_epoch = self.consumer.epoch();
            self.buffering_gate = self.startup_watermark_bytes > 0;
            self.fade.reset_for_play_start();
            self.eof_drain_remaining = None;
            self.signals.eof_drained.store(false, Ordering::Release);
            self.dop_silence_phase = false;
            self.last_handled_flush_epoch = req_epoch;
            self.signals
                .flush_completed_epoch
                .store(req_epoch, Ordering::Release);
            return true;
        }

        // 2. Stopped / session mismatch / paused gate.
        let session_mismatch = self.current_session_id.load(Ordering::Relaxed) != self.session_id;
        let stop_fade_in_progress = self
            .fade_ctrl
            .as_ref()
            .is_some_and(|fc| fc.target() == FadeTarget::StopFadeOut && !fc.is_fade_out_done());
        let is_stopped = self.stopped.load(Ordering::Relaxed);
        let is_paused = self.paused.load(Ordering::Relaxed);
        if is_stopped || (session_mismatch && !stop_fade_in_progress) || is_paused {
            if is_paused && !self.was_paused {
                self.fill_both_double_buffers_silence(channel_buffers);
                self.was_paused = true;
            } else {
                self.fill_half_buffer_silence(channel_buffers, idx);
            }
            return is_paused && !is_stopped && !session_mismatch;
        }
        self.was_paused = false;

        // 2b. Lock-free real-time format-mismatch guard: emit silence & signal control layer
        // instead of popping/outputting mismatched sample-rate or wire-container PCM.
        if self.is_format_mismatched() {
            self.signals
                .telemetry
                .record_error_rt(RtErrorCode::FormatMismatch, 0);
            self.fill_half_buffer_silence(channel_buffers, idx);
            return true;
        }

        let strict_bp = self.signals.is_strict_bit_perfect();
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
        let needed_bytes = (frames_in_callback_bytes * wire_bpf).min(self.scratch.len());

        // 3. Lock-free micro-fade-out handling (Pause / Stop / Seek click/pop prevention).
        // Strict Bit-Perfect NEVER modifies samples; immediately emit format-appropriate silence.
        let fade_target = self
            .fade_ctrl
            .as_ref()
            .map(|fc| fc.target())
            .unwrap_or(FadeTarget::Playing);
        if matches!(
            fade_target,
            FadeTarget::PauseFadeOut | FadeTarget::StopFadeOut | FadeTarget::SeekFadeOut
        ) && let Some(ref fc) = self.fade_ctrl
        {
            if strict_bp || !self.fade.fade_out_enabled() || self.fade.gain() <= 0.0 {
                self.fade.set_zero();
                fc.mark_fade_out_done();
                if fade_target == FadeTarget::SeekFadeOut {
                    self.buffering_gate = self.startup_watermark_bytes > 0;
                }
                self.fill_half_buffer_silence(channel_buffers, idx);
                return true;
            }
            let aligned = self
                .consumer
                .pop_slice_aligned(&mut self.scratch[..needed_bytes], wire_bpf);
            if aligned > 0 {
                apply_fade_ramp_to_wire_bytes(
                    &mut self.scratch[..aligned],
                    self.wire,
                    self.channels,
                    &mut self.fade,
                    FadeDirection::Down,
                );
            } else {
                self.fade.set_zero();
            }
            if self.fade.gain() <= 0.0 {
                fc.mark_fade_out_done();
                if fade_target == FadeTarget::SeekFadeOut {
                    self.buffering_gate = self.startup_watermark_bytes > 0;
                }
            }
            if aligned > 0 {
                self.write_interleaved_to_planar(
                    channel_buffers,
                    idx,
                    aligned,
                    frames_in_callback_bytes,
                );
            } else {
                self.fill_half_buffer_silence(channel_buffers, idx);
            }
            return true;
        }

        // 4. Detect ring flush epoch change (post-seek) and re-arm watermark gate.
        let req_ring_ep = self.consumer.requested_epoch();
        if req_ring_ep != self.last_ring_epoch {
            if self.consumer.has_pending_flush() && self.consumer.try_flush_and_ack().is_none() {
                self.fill_half_buffer_silence(channel_buffers, idx);
                return true;
            }
            self.last_ring_epoch = self.consumer.epoch();
            self.buffering_gate = self.startup_watermark_bytes > 0;
            self.fade.reset_for_play_start();
        }

        // 5. Update lock-free buffered_ms telemetry & startup/post-seek watermark gate.
        let avail_before = self.consumer.available_read();
        if let Some(ref bms) = self.buffered_ms {
            let clock_rate = if matches!(self.wire, WireSampleFormat::NativeDsd { .. }) {
                (self.sample_rate / 8).max(44_100) as u64
            } else {
                self.sample_rate.max(8_000) as u64
            };
            let frames_avail = (avail_before / wire_bpf) as u64;
            bms.store((frames_avail * 1000) / clock_rate, Ordering::Relaxed);
        }

        if self.buffering_gate {
            if avail_before >= self.startup_watermark_bytes || self.eof_flag.load(Ordering::Acquire)
            {
                self.buffering_gate = false;
            } else {
                self.fill_half_buffer_silence(channel_buffers, idx);
                return true;
            }
        }

        let aligned = self
            .consumer
            .pop_slice_aligned(&mut self.scratch[..needed_bytes], wire_bpf);

        if aligned > 0 {
            self.eof_drain_remaining = None;
            self.signals.eof_drained.store(false, Ordering::Release);

            if !strict_bp && self.fade.gain() < 1.0 {
                apply_fade_ramp_to_wire_bytes(
                    &mut self.scratch[..aligned],
                    self.wire,
                    self.channels,
                    &mut self.fade,
                    FadeDirection::Up,
                );
            }
            if let Some(ref fc) = self.fade_ctrl {
                fc.mark_audible();
            }

            if matches!(self.wire, WireSampleFormat::Dop24In32MsbLe { .. }) {
                self.dop_silence_phase = self.scratch[aligned - 1] == 0x05;
            }

            if aligned < needed_bytes && !self.eof_flag.load(Ordering::Acquire) {
                self.signals.underrun_count.fetch_add(1, Ordering::Relaxed);
                self.signals.telemetry.record_xrun_rt();
                if !strict_bp {
                    fade_out_wire_tail(&mut self.scratch[..aligned], self.wire, self.channels, 128);
                }
                if self.startup_watermark_bytes > 0 {
                    self.buffering_gate = true;
                    self.fade.reset_for_play_start();
                }
            }

            self.ver_tap.push_wire(&self.scratch[..aligned]);
            if let Some(tap) = crate::visualizer::try_global_tap() {
                tap.feed_wire(
                    &self.scratch[..aligned],
                    self.wire,
                    self.channels as u16,
                    self.sample_rate,
                );
            }
            let frames = if is_dsd_bit_packed {
                ((aligned / wire_bpf) * 8) as u64
            } else {
                (aligned / wire_bpf) as u64
            };
            self.frames_rendered.fetch_add(frames, Ordering::Relaxed);
            self.signals.telemetry.add_frames_rt(frames);
            if asio_chunk_has_nonzero(&self.scratch[..aligned], self.wire) {
                self.nonzero_frames.fetch_add(frames, Ordering::Relaxed);
            }
        } else if self.eof_flag.load(Ordering::SeqCst) && self.consumer.available_read() < wire_bpf
        {
            self.fill_half_buffer_silence(channel_buffers, idx);
            let out_lat = self.signals.output_latency_frames.load(Ordering::Relaxed);
            let drain_periods = 2 + (out_lat / (self.buffer_size as u32).max(1)).min(4);
            let rem = self.eof_drain_remaining.get_or_insert(drain_periods);
            if *rem <= 1 {
                *rem = 0;
                if let Some(ref fc) = self.fade_ctrl {
                    fc.mark_silent();
                }
                self.signals.eof_drained.store(true, Ordering::Release);
                let target = self.signals.eof_target_state.load(Ordering::Relaxed);
                let _ =
                    self.state_code
                        .compare_exchange(2, target, Ordering::SeqCst, Ordering::SeqCst);
            } else {
                *rem -= 1;
            }
            return true;
        } else {
            // Transient underrun while track still active: increment counter, re-arm watermark gate & fade-in.
            self.signals.underrun_count.fetch_add(1, Ordering::Relaxed);
            self.signals.telemetry.record_xrun_rt();
            if self.startup_watermark_bytes > 0 {
                self.buffering_gate = true;
                self.fade.reset_for_play_start();
            }
            self.fill_half_buffer_silence(channel_buffers, idx);
            return true;
        }

        self.write_interleaved_to_planar(channel_buffers, idx, aligned, frames_in_callback_bytes);
        true
    }
}

pub(super) struct ActiveAsioCallbackState {
    pub(super) asio_raw: usize,
    pub(super) vtbl_raw: usize,
    pub(super) _buffer_infos: Vec<AsioBufferInfo>,
    pub(super) channel_buffers: Vec<[*mut u8; 2]>,
    pub(super) core: AsioRenderCore,
}

// ASIO double-buffer pointers come from the COM STA host thread; lifecycle is coordinated via
// `ACTIVE_ASIO_PTR` + `ACTIVE_ASIO_IN_CALLBACK` with zero mutexes on the RT callback path.
unsafe impl Send for ActiveAsioCallbackState {}
unsafe impl Sync for ActiveAsioCallbackState {}

pub(super) static ACTIVE_ASIO_PTR: AtomicPtr<ActiveAsioCallbackState> = AtomicPtr::new(null_mut());
pub(super) static ACTIVE_ASIO_IN_CALLBACK: AtomicU32 = AtomicU32::new(0);
pub(super) static ACTIVE_ASIO_SESSION_ID: AtomicU64 = AtomicU64::new(0);
pub(super) static LAST_ASIO_BUFFER_FRAMES: AtomicUsize = AtomicUsize::new(0);

pub(super) fn clear_and_drop_active_asio_state() {
    let old = ACTIVE_ASIO_PTR.swap(null_mut(), Ordering::AcqRel);
    if !old.is_null() {
        let deadline = Instant::now() + Duration::from_millis(200);
        while ACTIVE_ASIO_IN_CALLBACK.load(Ordering::Acquire) > 0 && Instant::now() < deadline {
            std::hint::spin_loop();
        }
        if ACTIVE_ASIO_IN_CALLBACK.load(Ordering::Acquire) == 0 {
            unsafe {
                drop(Box::from_raw(old));
            }
        }
    }
}

// Wait-free message atomics updated inside driver `asio_message` / `sampleRateDidChange` callbacks (zero locks).
pub(super) static ASIO_MSG_SESSION_ID: AtomicU64 = AtomicU64::new(0);
pub(super) static ASIO_MSG_RESET: AtomicBool = AtomicBool::new(false);
pub(super) static ASIO_MSG_RESYNC: AtomicBool = AtomicBool::new(false);
pub(super) static ASIO_MSG_LATENCIES_CHANGED: AtomicBool = AtomicBool::new(false);
pub(super) static ASIO_MSG_BUFFER_SIZE: AtomicI32 = AtomicI32::new(0);
pub(super) static ASIO_MSG_SAMPLE_RATE_HZ: AtomicU32 = AtomicU32::new(0);

#[doc(hidden)]
pub fn simulate_asio_sample_rate_changed(session_id: u64, s_rate: f64) {
    ASIO_MSG_SESSION_ID.store(session_id, Ordering::Release);
    unsafe {
        asio_sample_rate_changed(s_rate);
    }
}

#[doc(hidden)]
pub fn read_asio_msg_sample_rate_hz() -> u32 {
    ASIO_MSG_SAMPLE_RATE_HZ.load(Ordering::Acquire)
}

pub(super) unsafe extern "C" fn asio_buffer_switch(double_buffer_index: i32, direct_process: i32) {
    asio_buffer_switch_impl(double_buffer_index, direct_process, None);
}

pub(super) fn asio_buffer_switch_impl(
    double_buffer_index: i32,
    _direct_process: i32,
    time_info_pos: Option<(u64, u64)>,
) {
    let idx = if double_buffer_index == 0 {
        0usize
    } else {
        1usize
    };
    ACTIVE_ASIO_IN_CALLBACK.fetch_add(1, Ordering::AcqRel);
    let ptr = ACTIVE_ASIO_PTR.load(Ordering::Acquire);
    if ptr.is_null() {
        ACTIVE_ASIO_IN_CALLBACK.fetch_sub(1, Ordering::Release);
        return;
    }
    // SAFETY: `ACTIVE_ASIO_PTR` is only reclaimed after `asio.stop()` AND
    // `ACTIVE_ASIO_IN_CALLBACK == 0`, and ASIO drivers serialize `bufferSwitch` calls.
    let st = unsafe { &mut *ptr };

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

    ACTIVE_ASIO_IN_CALLBACK.fetch_sub(1, Ordering::Release);
}

pub(super) fn asio_sample_bytes(sample_type: i32) -> usize {
    match sample_type {
        ASIO_ST_INT16_LSB => 2,
        ASIO_ST_INT24_LSB => 3,
        ASIO_ST_FLOAT64_LSB => 8,
        ASIO_ST_DSD_INT8_LSB1 | ASIO_ST_DSD_INT8_MSB1 | ASIO_ST_DSD_INT8_LSB8 => 1,
        _ => 4,
    }
}

pub(super) unsafe extern "C" fn asio_sample_rate_changed(s_rate: f64) {
    if s_rate.is_finite() && s_rate > 0.0 && s_rate <= u32::MAX as f64 {
        ASIO_MSG_SAMPLE_RATE_HZ.store(s_rate.round() as u32, Ordering::Release);
    }
}

pub(super) unsafe extern "C" fn asio_message(
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

pub(super) unsafe extern "C" fn asio_buffer_switch_time_info(
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
