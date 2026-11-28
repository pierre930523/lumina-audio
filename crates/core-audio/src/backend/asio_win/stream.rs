use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::backend::device_fsm::DEFAULT_POST_RELEASE_GUARD_DELAY;
use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::RtTelemetry;
use crate::player::AudioFadeControl;
use crate::verification::{AudioVerificationEngine, WireSampleFormat};

use super::callbacks::{AsioCallbackSignals, AsioCallbackWatchdog, AsioClockSnapshot};
use super::driver::enumerate_asio_drivers;
use super::sta_runner::{AsioStaLaunch, spawn_asio_sta_thread};

pub struct AsioNativeSession {
    pub driver_name: String,
    pub buffer_frames: u32,
    paused: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
    signals: Arc<AsioCallbackSignals>,
    handle: Option<JoinHandle<()>>,
    post_release_guard_delay: Duration,
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
        Self::open_and_start_with_controls(
            driver_id,
            sample_rate,
            channels,
            wire,
            native_dsd,
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            session_id,
            current_session_id,
            0,
            None,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start_with_controls(
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
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
    ) -> Result<Self, BackendError> {
        Self::open_and_start_with_phase3_controls(
            driver_id,
            sample_rate,
            channels,
            wire,
            native_dsd,
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            session_id,
            current_session_id,
            startup_watermark_bytes,
            fade_ctrl,
            buffered_ms,
            Arc::new(AtomicBool::new(false)),
            Arc::new(RwLock::new(None)),
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicU64::new(0)),
            0,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start_with_phase3_controls(
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
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
        device_lost: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        format_mismatch_flag: Arc<AtomicBool>,
        published_format_stamp: Arc<AtomicU64>,
        expected_format_stamp: u64,
        stall_timeout: Option<Duration>,
    ) -> Result<Self, BackendError> {
        Self::open_and_start_with_telemetry(
            driver_id,
            sample_rate,
            channels,
            wire,
            native_dsd,
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            session_id,
            current_session_id,
            startup_watermark_bytes,
            fade_ctrl,
            buffered_ms,
            Arc::new(AtomicU64::new(0)),
            device_lost,
            last_error,
            format_mismatch_flag,
            published_format_stamp,
            expected_format_stamp,
            stall_timeout,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_and_start_with_telemetry(
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
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
        underrun_count: Arc<AtomicU64>,
        device_lost: Arc<AtomicBool>,
        last_error: Arc<RwLock<Option<String>>>,
        format_mismatch_flag: Arc<AtomicBool>,
        published_format_stamp: Arc<AtomicU64>,
        expected_format_stamp: u64,
        stall_timeout: Option<Duration>,
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
        .ok_or_else(|| {
            BackendError::DeviceNotFound("No ASIO driver installed in HKLM\\SOFTWARE\\ASIO".into())
        })?;

        if !chosen.dll_exists {
            return Err(BackendError::DriverError(format!(
                "ASIO driver DLL missing: {:?}",
                chosen.dll_path
            )));
        }

        let paused = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicBool::new(false));
        let signals = Arc::new(
            AsioCallbackSignals::new(sample_rate)
                .with_underrun_counter(underrun_count)
                .with_phase3_guards(
                    device_lost,
                    last_error,
                    format_mismatch_flag,
                    published_format_stamp,
                    expected_format_stamp,
                ),
        );
        let th_paused = Arc::clone(&paused);
        let th_stopped = Arc::clone(&stopped);
        let th_signals = Arc::clone(&signals);
        let watchdog_timeout = stall_timeout.unwrap_or(AsioCallbackWatchdog::DEFAULT_STALL_TIMEOUT);

        let (ack_tx, ack_rx) = mpsc::sync_channel::<Result<(String, u32), BackendError>>(1);

        let handle = spawn_asio_sta_thread(AsioStaLaunch {
            chosen,
            sample_rate,
            channels,
            wire,
            native_dsd,
            consumer,
            verification,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            session_id,
            current_session_id,
            startup_watermark_bytes,
            fade_ctrl,
            buffered_ms,
            th_paused,
            th_stopped,
            th_signals,
            watchdog_timeout,
            ack_tx,
        })?;

        match ack_rx.recv() {
            Ok(Ok((driver_name, buffer_frames))) => Ok(Self {
                driver_name,
                buffer_frames,
                paused,
                stopped,
                signals,
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
        self.signals
            .resync_requested
            .store(false, Ordering::Release);
    }

    pub fn is_device_lost(&self) -> bool {
        self.signals.device_lost.load(Ordering::Acquire)
    }

    pub fn is_format_mismatch(&self) -> bool {
        self.signals.is_format_mismatch()
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

    pub fn telemetry(&self) -> Arc<RtTelemetry> {
        self.signals.telemetry()
    }

    pub fn set_strict_bit_perfect(&self, strict_bit_perfect: bool) {
        self.signals.set_strict_bit_perfect(strict_bit_perfect);
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

    fn shutdown_internal(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        let mut had_handle = false;
        if let Some(h) = self.handle.take() {
            had_handle = true;
            if self.is_device_lost() {
                if !crate::backend::wasapi_win::join_handle_bounded(h, Duration::from_millis(500)) {
                    tracing::warn!(
                        "ASIO STA thread wedged after device_lost; detaching after 500ms"
                    );
                }
            } else {
                let mut lost_deadline: Option<Instant> = None;
                while !h.is_finished() {
                    if self.is_device_lost() {
                        let dl = *lost_deadline
                            .get_or_insert_with(|| Instant::now() + Duration::from_millis(500));
                        if Instant::now() >= dl {
                            tracing::warn!(
                                "ASIO STA thread lost device during shutdown; detaching after 500ms"
                            );
                            break;
                        }
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                if h.is_finished() {
                    let _ = h.join();
                }
            }
        }
        if had_handle && !self.post_release_guard_delay.is_zero() {
            thread::sleep(self.post_release_guard_delay);
        }
    }

    pub fn stop(mut self) {
        self.shutdown_internal();
    }
}

impl Drop for AsioNativeSession {
    fn drop(&mut self) {
        self.shutdown_internal();
    }
}
