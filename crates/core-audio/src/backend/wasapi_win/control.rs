use std::ptr::null_mut;
use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicPtr, AtomicU32, AtomicU64, AtomicUsize, Ordering,
};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::{Duration, Instant};

use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::{RtErrorCode, RtTelemetry};
use crate::player::AudioFadeControl;
use crate::verification::VerificationTapProducer;

use super::clock::{WasapiClockSnapshot, WasapiClockState};
use super::com::Win32Event;

/// a new track's ring buffer without stopping, dropping, or re-initializing the hardware driver.
pub struct WasapiHotSwapPayload {
    pub consumer: Consumer<u8>,
    pub ver_tap: VerificationTapProducer,
    pub watermark_bytes: usize,
    pub eof_flag: Arc<AtomicBool>,
    pub fade_ctrl: Option<Arc<AudioFadeControl>>,
    pub session_id: u64,
    pub expected_format_stamp: u64,
}

pub(super) const WASAPI_SWAP_RETIRE_LEN: usize = 8;

pub(super) struct WasapiSwapEnvelope {
    pub(super) payload: WasapiHotSwapPayload,
    pub(super) expected_skip_seq: u64,
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
    pub active_session_id: AtomicU64,
    pub current_session_id: Arc<AtomicU64>,
    pub flush_req_seq: AtomicU64,
    pub flush_ack_seq: AtomicU64,
    pub clock_state: Arc<WasapiClockState>,
    pub startup_watermark_bytes: AtomicUsize,
    pub fade_ctrl: Option<Arc<AudioFadeControl>>,
    pub buffered_ms: Option<Arc<AtomicU64>>,
    pub underrun_count: Arc<AtomicU64>,
    pub telemetry: Arc<RtTelemetry>,
    pub strict_bit_perfect: AtomicBool,
    pub format_mismatch_flag: Arc<AtomicBool>,
    pub published_format_stamp: Arc<AtomicU64>,
    pub expected_format_stamp: u64,
    pub wait_timeout_ms: AtomicU32,
    pub skip_silence: AtomicBool,
    pub skip_fade_requested: AtomicBool,
    pub(super) skip_silence_seq: AtomicU64,
    pub(super) loop_exited: AtomicBool,
    pub(super) swap_inbox: AtomicPtr<WasapiSwapEnvelope>,
    pub(super) retire_ring: [AtomicPtr<WasapiSwapEnvelope>; WASAPI_SWAP_RETIRE_LEN],
    pub(super) retire_head: AtomicUsize,
    pub(super) retired_pending: AtomicUsize,
}

impl Drop for WasapiRenderControl {
    fn drop(&mut self) {
        let pending = self.swap_inbox.swap(null_mut(), Ordering::AcqRel);
        if !pending.is_null() {
            unsafe {
                drop(Box::from_raw(pending));
            }
        }
        self.drain_retired_swaps();
    }
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
            active_session_id: AtomicU64::new(session_id),
            current_session_id,
            flush_req_seq: AtomicU64::new(0),
            flush_ack_seq: AtomicU64::new(0),
            clock_state: Arc::new(WasapiClockState::new(sample_rate)),
            startup_watermark_bytes: AtomicUsize::new(0),
            fade_ctrl: None,
            buffered_ms: None,
            underrun_count: Arc::new(AtomicU64::new(0)),
            telemetry: Arc::new(RtTelemetry::new()),
            strict_bit_perfect: AtomicBool::new(false),
            format_mismatch_flag: Arc::new(AtomicBool::new(false)),
            published_format_stamp: Arc::new(AtomicU64::new(0)),
            expected_format_stamp: 0,
            wait_timeout_ms: AtomicU32::new(100),
            skip_silence: AtomicBool::new(false),
            skip_fade_requested: AtomicBool::new(false),
            skip_silence_seq: AtomicU64::new(0),
            loop_exited: AtomicBool::new(false),
            swap_inbox: AtomicPtr::new(null_mut()),
            retire_ring: std::array::from_fn(|_| AtomicPtr::new(null_mut())),
            retire_head: AtomicUsize::new(0),
            retired_pending: AtomicUsize::new(0),
        }
    }

    pub fn with_underrun_counter(mut self, underrun_count: Arc<AtomicU64>) -> Self {
        self.underrun_count = underrun_count;
        self
    }

    pub fn with_telemetry(mut self, telemetry: Arc<RtTelemetry>) -> Self {
        self.telemetry = telemetry;
        self
    }

    pub fn with_strict_bit_perfect(self, strict_bit_perfect: bool) -> Self {
        self.strict_bit_perfect
            .store(strict_bit_perfect, Ordering::Release);
        self
    }

    pub fn set_strict_bit_perfect(&self, strict_bit_perfect: bool) {
        self.strict_bit_perfect
            .store(strict_bit_perfect, Ordering::Release);
    }

    pub fn telemetry(&self) -> Arc<RtTelemetry> {
        Arc::clone(&self.telemetry)
    }

    /// Formats the last atomic RT error lazily on a non-RT thread.
    pub fn format_last_error(&self) -> Option<String> {
        let (code, hr) = self.telemetry.last_error()?;
        if code == RtErrorCode::ClockQueryFailed && hr == 0 {
            return Some("WASAPI hardware clock stalled".to_string());
        }
        Some(format!(
            "WASAPI {}: HRESULT=0x{:08X}",
            code.as_str(),
            hr as u32
        ))
    }

    /// Copies any atomic RT error into `self.last_error` strictly off the RT thread.
    pub fn sync_last_error_off_rt(&self) {
        if let Some(msg) = self.format_last_error()
            && let Ok(mut g) = self.last_error.write()
        {
            *g = Some(msg);
        }
    }

    /// Returns the last formatted error message without ever blocking the RT render thread.
    pub fn last_error_message(&self) -> Option<String> {
        self.format_last_error()
            .or_else(|| self.last_error.read().ok().and_then(|g| g.clone()))
    }

    pub fn with_phase2_controls(
        mut self,
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
    ) -> Self {
        self.startup_watermark_bytes = AtomicUsize::new(startup_watermark_bytes);
        self.fade_ctrl = fade_ctrl;
        self.buffered_ms = buffered_ms;
        self
    }

    pub fn with_phase3_guards(
        mut self,
        device_lost: Arc<AtomicBool>,
        format_mismatch_flag: Arc<AtomicBool>,
        published_format_stamp: Arc<AtomicU64>,
        expected_format_stamp: u64,
    ) -> Self {
        self.device_lost = device_lost;
        self.format_mismatch_flag = format_mismatch_flag;
        self.published_format_stamp = published_format_stamp;
        self.expected_format_stamp = expected_format_stamp;
        self
    }

    pub fn with_wait_timeout_ms(self, ms: u32) -> Self {
        self.wait_timeout_ms.store(ms.max(1), Ordering::Release);
        self
    }

    pub fn is_format_mismatch(&self) -> bool {
        self.format_mismatch_flag.load(Ordering::Acquire)
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

        let req = self.flush_req_seq.fetch_add(1, Ordering::SeqCst) + 1;
        self.wake_event.signal();

        let deadline = Instant::now() + Duration::from_secs(2);
        while self.flush_ack_seq.load(Ordering::Acquire) < req {
            if self.device_lost.load(Ordering::Acquire) {
                return Err(BackendError::DeviceNotFound(
                    "WASAPI device invalidated during flush".into(),
                ));
            }
            if self.stopped.load(Ordering::Acquire)
                || self.current_session_id.load(Ordering::Relaxed)
                    != self.active_session_id.load(Ordering::Acquire)
            {
                return Err(BackendError::DriverError(
                    "WASAPI session stopped during flush".into(),
                ));
            }
            if Instant::now() >= deadline {
                return Err(BackendError::DriverError(
                    "WASAPI flush timed out waiting for render thread".into(),
                ));
            }
            thread::sleep(Duration::from_millis(1));
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

    /// Transitions the live WASAPI render loop into lock-free 5 ms micro-fade -> silent keep-alive
    /// (`AUDCLNT_BUFFERFLAGS_SILENT` for PCM, wire-silence for DoP/DSD) without stopping or
    /// tearing down `IAudioClient`.
    pub fn enter_skip_silence(&self) {
        self.skip_silence_seq.fetch_add(1, Ordering::SeqCst);
        self.skip_fade_requested.store(true, Ordering::Release);
        self.skip_silence.store(true, Ordering::SeqCst);
        self.wake_event.signal();
    }

    pub fn is_skip_silence(&self) -> bool {
        self.skip_silence.load(Ordering::Acquire)
    }

    pub fn is_loop_exited(&self) -> bool {
        self.loop_exited.load(Ordering::Acquire)
    }

    /// Frees any retired hot-swap payloads off the real-time thread.
    pub fn drain_retired_swaps(&self) {
        for slot in &self.retire_ring {
            let ptr = slot.swap(null_mut(), Ordering::AcqRel);
            if !ptr.is_null() {
                self.retired_pending.fetch_sub(1, Ordering::AcqRel);
                unsafe {
                    drop(Box::from_raw(ptr));
                }
            }
        }
    }

    /// Atomically publishes a new track's ring buffer into the running WASAPI render loop,
    /// avoiding `IAudioClient` teardown/reopen when formats match.
    ///
    /// Returns `Err(payload)` if the render loop has already exited, lost the device, or
    /// the retire ring is full (preventing any leak on overflow).
    /// `skip_silence` is cleared strictly on the RT thread upon adoption only when no newer
    /// `enter_skip_silence()` or `current_session_id` raced with this hot-swap.
    pub fn try_push_hot_swap(
        &self,
        payload: WasapiHotSwapPayload,
    ) -> Result<(), WasapiHotSwapPayload> {
        self.drain_retired_swaps();
        if self.stopped.load(Ordering::SeqCst)
            || self.loop_exited.load(Ordering::SeqCst)
            || self.device_lost.load(Ordering::SeqCst)
            || self.retired_pending.load(Ordering::Acquire) >= WASAPI_SWAP_RETIRE_LEN - 1
        {
            return Err(payload);
        }
        let new_session_id = payload.session_id;
        let expected_skip_seq = self.skip_silence_seq.load(Ordering::SeqCst);
        let boxed = Box::into_raw(Box::new(WasapiSwapEnvelope {
            payload,
            expected_skip_seq,
        }));
        let prev = self.swap_inbox.swap(boxed, Ordering::SeqCst);
        if !prev.is_null() {
            unsafe {
                drop(Box::from_raw(prev));
            }
        }
        self.wake_event.signal();

        // Dekker mutual-visibility check against `try_commit_loop_exit` on the RT thread:
        // if the render loop committed to exiting before seeing `boxed`, reclaim `boxed` via
        // CAS and return `Err` so the caller reopens `IAudioClient` instead of stalling.
        if (self.loop_exited.load(Ordering::SeqCst)
            || self.stopped.load(Ordering::SeqCst)
            || self.device_lost.load(Ordering::SeqCst))
            && self
                .swap_inbox
                .compare_exchange(boxed, null_mut(), Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
        {
            let env = unsafe { Box::from_raw(boxed) };
            return Err(env.payload);
        }

        self.active_session_id
            .store(new_session_id, Ordering::Release);
        self.eof_drained.store(false, Ordering::Release);
        self.format_mismatch_flag.store(false, Ordering::Release);
        Ok(())
    }

    /// Convenience wrapper over [`Self::try_push_hot_swap`] returning `true` when handed off
    /// to a live render loop and `false` when the loop had already exited.
    pub fn push_hot_swap(&self, payload: WasapiHotSwapPayload) -> bool {
        self.try_push_hot_swap(payload).is_ok()
    }

    /// Strictly RT-safe retirement: places `ptr` into the first empty slot in `retire_ring`
    /// without ever overwriting an occupied slot or deallocating on the RT thread.
    #[inline]
    pub(super) fn retire_swap_ptr_rt(&self, ptr: *mut WasapiSwapEnvelope) {
        if ptr.is_null() {
            return;
        }
        let start = self.retire_head.fetch_add(1, Ordering::Relaxed);
        for offset in 0..WASAPI_SWAP_RETIRE_LEN {
            let idx = (start + offset) % WASAPI_SWAP_RETIRE_LEN;
            if self.retire_ring[idx]
                .compare_exchange(null_mut(), ptr, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                self.retired_pending.fetch_add(1, Ordering::Release);
                return;
            }
        }
        // `try_push_hot_swap` enforces a headroom threshold so this branch is unreachable
        // under normal operation; never drop on the RT thread.
    }
}
