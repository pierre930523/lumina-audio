use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use windows::Win32::System::Threading::{
    AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW,
};
use windows::core::PCWSTR;

use crate::backend::device_fsm::DEFAULT_POST_RELEASE_GUARD_DELAY;
use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::RtTelemetry;
use crate::player::AudioFadeControl;
use crate::verification::{AudioVerificationEngine, WireSampleFormat};

use super::clock::{WasapiClockSnapshot, WasapiExclusiveOpenSpec};
use super::com::{ComGuard, Win32Event, join_handle_bounded};
use super::control::{WasapiHotSwapPayload, WasapiRenderControl};
use super::loop_impl::wake_all_flush_waiters;
use super::loop_rt::run_wasapi_render_loop_rt;
use super::ops::{RealWasapiStreamOps, WasapiStreamOps};
use super::probe::open_client_exclusive;

/// Active native Windows COM WASAPI Exclusive Event-Driven playback session.
/// Bypasses Windows `audiodg.exe` mixer completely and transfers raw wire bytes directly to `IAudioRenderClient`.
pub struct WasapiExclusiveSession {
    pub spec: WasapiExclusiveOpenSpec,
    pub device_name: String,
    pub actual_buffer_frames: u32,
    pub wire_format: WireSampleFormat,
    ctrl: Arc<WasapiRenderControl>,
    handle: Option<JoinHandle<()>>,
    post_release_guard_delay: Duration,
}

impl WasapiExclusiveSession {
    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start(
        spec: WasapiExclusiveOpenSpec,
        consumer: Consumer<u8>,
        verification: AudioVerificationEngine,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        session_id: u64,
        current_session_id: Arc<AtomicU64>,
    ) -> Result<Self, BackendError> {
        Self::open_and_start_with_controls(
            spec,
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            last_error,
            session_id,
            current_session_id,
            0,
            None,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start_with_controls(
        spec: WasapiExclusiveOpenSpec,
        consumer: Consumer<u8>,
        verification: AudioVerificationEngine,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        session_id: u64,
        current_session_id: Arc<AtomicU64>,
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
    ) -> Result<Self, BackendError> {
        Self::open_and_start_with_phase3_controls(
            spec,
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            last_error,
            session_id,
            current_session_id,
            startup_watermark_bytes,
            fade_ctrl,
            buffered_ms,
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicU64::new(0)),
            0,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start_with_phase3_controls(
        spec: WasapiExclusiveOpenSpec,
        consumer: Consumer<u8>,
        verification: AudioVerificationEngine,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        session_id: u64,
        current_session_id: Arc<AtomicU64>,
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
        device_lost: Arc<AtomicBool>,
        format_mismatch_flag: Arc<AtomicBool>,
        published_format_stamp: Arc<AtomicU64>,
        expected_format_stamp: u64,
    ) -> Result<Self, BackendError> {
        Self::open_and_start_with_telemetry(
            spec,
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            last_error,
            session_id,
            current_session_id,
            startup_watermark_bytes,
            fade_ctrl,
            buffered_ms,
            Arc::new(AtomicU64::new(0)),
            device_lost,
            format_mismatch_flag,
            published_format_stamp,
            expected_format_stamp,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start_with_telemetry(
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
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
        underrun_count: Arc<AtomicU64>,
        device_lost: Arc<AtomicBool>,
        format_mismatch_flag: Arc<AtomicBool>,
        published_format_stamp: Arc<AtomicU64>,
        expected_format_stamp: u64,
    ) -> Result<Self, BackendError> {
        let stop_event = Arc::new(Win32Event::new_manual_reset()?);
        let wake_event = Arc::new(Win32Event::new_auto_reset()?);

        let (ack_tx, ack_rx) =
            mpsc::sync_channel::<Result<(String, u32, Arc<WasapiRenderControl>), BackendError>>(1);
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

                let ctrl = Arc::new(
                    WasapiRenderControl::new(
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
                    )
                    .with_phase2_controls(startup_watermark_bytes, fade_ctrl, buffered_ms)
                    .with_underrun_counter(underrun_count)
                    .with_phase3_guards(
                        device_lost,
                        format_mismatch_flag,
                        published_format_stamp,
                        expected_format_stamp,
                    ),
                );

                if ack_tx
                    .send(Ok((dev_name, actual_frames, Arc::clone(&ctrl))))
                    .is_err()
                {
                    return;
                }

                // Off-RT setup BEFORE MMCSS "Pro Audio" elevation:
                // initialize visualizer worker, attach lock-free verification tap, and pre-allocate
                // the period scratch buffer so zero locks/allocs/thread-spawns occur after elevation.
                let mut ops = RealWasapiStreamOps {
                    client,
                    render,
                    clock,
                    buf_event,
                };
                if let Some(freq) = ops.clock_frequency() {
                    ctrl.clock_state.set_frequency(freq);
                }
                let _ = crate::visualizer::init_global_tap();
                let mut ver_tap = verification.attach_rt_tap(
                    thread_spec.wire_format,
                    thread_spec.channels,
                    thread_spec.sample_rate,
                    1024 * 1024,
                );
                let bytes_per_frame = thread_spec.wire_format.bytes_per_sample()
                    * (thread_spec.channels.max(1) as usize);
                let mut scratch = vec![0u8; (actual_frames as usize) * bytes_per_frame];
                let mut active_eof_flag = Arc::clone(&ctrl.eof_flag);
                let mut active_fade_ctrl = ctrl.fade_ctrl.clone();

                // Elevate render thread via MMCSS "Pro Audio" ONLY AFTER all allocations & locks finish.
                let mut task_idx = 0u32;
                let task_wide: Vec<u16> = "Pro Audio\0".encode_utf16().collect();
                let mmcss_handle = unsafe {
                    AvSetMmThreadCharacteristicsW(PCWSTR(task_wide.as_ptr()), &mut task_idx)
                }
                .ok();

                run_wasapi_render_loop_rt(
                    &mut ops,
                    &thread_spec,
                    actual_frames,
                    &mut consumer,
                    &mut ver_tap,
                    &mut scratch,
                    &mut active_eof_flag,
                    &mut active_fade_ctrl,
                    &ctrl,
                );

                if let Some(h) = mmcss_handle {
                    let _ = unsafe { AvRevertMmThreadCharacteristics(h) };
                }

                // Off-RT post-exit: drop hoisted Arc handles strictly after reverting MMCSS,
                // and lazily format any atomic RT error into `ctrl.last_error`.
                drop(active_fade_ctrl);
                drop(active_eof_flag);
                ctrl.sync_last_error_off_rt();
            })
            .map_err(|e| {
                BackendError::DriverError(format!("Failed to spawn WASAPI thread: {e}"))
            })?;

        match ack_rx.recv() {
            Ok(Ok((device_name, actual_buffer_frames, ctrl))) => Ok(Self {
                wire_format: spec.wire_format,
                spec,
                device_name,
                actual_buffer_frames,
                ctrl,
                handle: Some(handle),
                post_release_guard_delay: DEFAULT_POST_RELEASE_GUARD_DELAY,
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

    pub fn is_format_mismatch(&self) -> bool {
        self.ctrl.is_format_mismatch()
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

    pub fn control(&self) -> Arc<WasapiRenderControl> {
        Arc::clone(&self.ctrl)
    }

    pub fn telemetry(&self) -> Arc<RtTelemetry> {
        self.ctrl.telemetry()
    }

    pub fn last_error(&self) -> Option<String> {
        self.ctrl.last_error_message()
    }

    pub fn post_release_guard_delay(&self) -> Duration {
        self.post_release_guard_delay
    }

    pub fn set_post_release_guard_delay(&mut self, delay: Duration) {
        self.post_release_guard_delay = delay;
    }

    pub fn with_post_release_guard_delay(mut self, delay: Duration) -> Self {
        self.post_release_guard_delay = delay;
        self
    }

    pub fn is_alive(&self) -> bool {
        !self.ctrl.stopped.load(Ordering::Acquire)
            && !self.ctrl.is_loop_exited()
            && !self.ctrl.is_device_lost()
            && self.handle.as_ref().is_some_and(|h| !h.is_finished())
    }

    pub fn matches_spec(&self, other: &WasapiExclusiveOpenSpec) -> bool {
        self.spec == *other
    }

    pub fn enter_skip_silence(&self) {
        self.ctrl.enter_skip_silence();
    }

    pub fn try_hot_swap(&self, payload: WasapiHotSwapPayload) -> Result<(), WasapiHotSwapPayload> {
        self.ctrl.try_push_hot_swap(payload)
    }

    pub fn hot_swap(&self, payload: WasapiHotSwapPayload) -> bool {
        self.ctrl.push_hot_swap(payload)
    }

    fn shutdown_internal(&mut self) {
        self.ctrl.stopped.store(true, Ordering::SeqCst);
        self.ctrl.stop_event.signal();
        self.ctrl.wake_event.signal();
        wake_all_flush_waiters(&self.ctrl);
        let had_handle = if let Some(h) = self.handle.take() {
            if !join_handle_bounded(h, Duration::from_millis(500)) {
                tracing::warn!(
                    "WASAPI Exclusive render thread wedged during shutdown (device_lost={}); detaching after 500ms",
                    self.ctrl.is_device_lost()
                );
            }
            true
        } else {
            false
        };
        self.ctrl.sync_last_error_off_rt();
        self.ctrl.drain_retired_swaps();
        if had_handle && !self.post_release_guard_delay.is_zero() {
            thread::sleep(self.post_release_guard_delay);
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
