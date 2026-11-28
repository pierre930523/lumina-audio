use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};

use crate::buffer::Consumer;
use crate::player::{AudioFadeControl, LinearFadeState};
use crate::verification::{AudioVerificationEngine, VerificationTapProducer, WireSampleFormat};

use super::callbacks::{AsioCallbackSignals, fill_asio_buffer_silence};
use super::ffi_types::{ASIO_ST_DSD_INT8_LSB1, ASIO_ST_DSD_INT8_MSB1};
use super::render_trampoline::{ASIO_MSG_SAMPLE_RATE_HZ, ASIO_MSG_SESSION_ID, asio_sample_bytes};

/// Driver-independent ASIO double-buffer render state machine, factored for deterministic unit
/// testing without COM or physical ASIO hardware.
#[doc(hidden)]
pub struct AsioRenderCore {
    pub consumer: Consumer<u8>,
    pub verification: AudioVerificationEngine,
    pub(super) ver_tap: VerificationTapProducer,
    pub frames_rendered: Arc<AtomicU64>,
    pub nonzero_frames: Arc<AtomicU64>,
    pub state_code: Arc<AtomicI32>,
    pub eof_flag: Arc<AtomicBool>,
    pub paused: Arc<AtomicBool>,
    pub stopped: Arc<AtomicBool>,
    pub current_session_id: Arc<AtomicU64>,
    pub session_id: u64,
    pub signals: Arc<AsioCallbackSignals>,
    pub buffer_size: usize,
    pub channels: usize,
    pub sample_rate: u32,
    pub sample_type: i32,
    pub wire: WireSampleFormat,
    pub expected_format_stamp: u64,
    pub scratch: Vec<u8>,
    pub(super) last_handled_flush_epoch: u64,
    pub(super) last_ring_epoch: u64,
    pub(super) eof_drain_remaining: Option<u32>,
    pub(super) dop_silence_phase: bool,
    pub(super) was_paused: bool,
    pub(super) startup_watermark_bytes: usize,
    pub(super) buffering_gate: bool,
    pub(super) fade_ctrl: Option<Arc<AudioFadeControl>>,
    pub(super) fade: LinearFadeState,
    pub(super) buffered_ms: Option<Arc<AtomicU64>>,
}

impl AsioRenderCore {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        consumer: Consumer<u8>,
        verification: AudioVerificationEngine,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        state_code: Arc<AtomicI32>,
        eof_flag: Arc<AtomicBool>,
        paused: Arc<AtomicBool>,
        stopped: Arc<AtomicBool>,
        current_session_id: Arc<AtomicU64>,
        session_id: u64,
        signals: Arc<AsioCallbackSignals>,
        buffer_size: usize,
        channels: usize,
        sample_rate: u32,
        sample_type: i32,
        wire: WireSampleFormat,
    ) -> Self {
        // Non-RT setup on STA host thread BEFORE `asio.start()`: initialize visualizer worker
        // so the driver RT callback only calls strictly lock-free `try_global_tap()`.
        let _ = crate::visualizer::init_global_tap();
        let ver_tap = verification.attach_rt_tap(wire, channels as u16, sample_rate, 1024 * 1024);
        let last_ring_epoch = consumer.epoch();
        let start_paused = paused.load(Ordering::Acquire);
        let expected_format_stamp = signals.expected_format_stamp.load(Ordering::Acquire);
        Self {
            consumer,
            verification,
            ver_tap,
            frames_rendered,
            nonzero_frames,
            state_code,
            eof_flag,
            paused,
            stopped,
            current_session_id,
            session_id,
            signals,
            buffer_size,
            channels,
            sample_rate,
            sample_type,
            wire,
            expected_format_stamp,
            scratch: vec![0; buffer_size * channels.max(1) * wire.bytes_per_sample().max(8)],
            last_handled_flush_epoch: 0,
            last_ring_epoch,
            eof_drain_remaining: None,
            dop_silence_phase: false,
            was_paused: false,
            startup_watermark_bytes: 0,
            buffering_gate: false,
            fade_ctrl: None,
            fade: LinearFadeState::new(sample_rate, false, false, start_paused),
            buffered_ms: None,
        }
    }

    pub fn with_expected_format_stamp(mut self, expected_format_stamp: u64) -> Self {
        self.expected_format_stamp = expected_format_stamp;
        self.signals
            .expected_format_stamp
            .store(expected_format_stamp, Ordering::Release);
        self
    }

    pub fn with_phase2_controls(
        mut self,
        startup_watermark_bytes: usize,
        fade_ctrl: Option<Arc<AudioFadeControl>>,
        buffered_ms: Option<Arc<AtomicU64>>,
    ) -> Self {
        self.startup_watermark_bytes = startup_watermark_bytes;
        self.buffering_gate = startup_watermark_bytes > 0;
        let (fade_in, fade_out) = fade_ctrl
            .as_ref()
            .map(|fc| (fc.fade_in_enabled(), fc.fade_out_enabled()))
            .unwrap_or((false, false));
        self.fade = LinearFadeState::new(
            self.sample_rate,
            fade_in,
            fade_out,
            self.paused.load(Ordering::Acquire),
        );
        self.fade_ctrl = fade_ctrl;
        self.buffered_ms = buffered_ms;
        self
    }

    pub(super) fn fill_half_buffer_silence(
        &mut self,
        channel_buffers: &[[*mut u8; 2]],
        idx: usize,
    ) {
        let ch = self.channels.min(channel_buffers.len());
        let drv_bps = asio_sample_bytes(self.sample_type);
        let is_dsd_bit_packed = matches!(
            self.sample_type,
            ASIO_ST_DSD_INT8_LSB1 | ASIO_ST_DSD_INT8_MSB1
        );
        let byte_frames = if is_dsd_bit_packed {
            self.buffer_size / 8
        } else {
            self.buffer_size
        };
        let start_phase = self.dop_silence_phase;
        let mut next_phase = start_phase;
        for pair in channel_buffers.iter().take(ch) {
            let dst_ptr = pair[idx];
            if !dst_ptr.is_null() {
                let dst = unsafe { std::slice::from_raw_parts_mut(dst_ptr, byte_frames * drv_bps) };
                let mut ch_phase = start_phase;
                fill_asio_buffer_silence(dst, self.wire, drv_bps, &mut ch_phase);
                next_phase = ch_phase;
            }
        }
        self.dop_silence_phase = next_phase;
    }

    pub(super) fn fill_both_double_buffers_silence(&mut self, channel_buffers: &[[*mut u8; 2]]) {
        self.fill_half_buffer_silence(channel_buffers, 0);
        self.fill_half_buffer_silence(channel_buffers, 1);
    }

    #[inline]
    pub(super) fn is_format_mismatched(&self) -> bool {
        if self.signals.format_mismatch_flag.load(Ordering::Acquire) {
            return true;
        }
        if self.expected_format_stamp != 0 {
            let published = self.signals.published_format_stamp.load(Ordering::Acquire);
            if published != self.expected_format_stamp {
                self.signals
                    .format_mismatch_flag
                    .store(true, Ordering::Release);
                return true;
            }
        }
        let drv_sr = self
            .signals
            .observed_driver_sample_rate
            .load(Ordering::Acquire);
        if drv_sr != 0 && drv_sr != self.sample_rate {
            self.signals
                .format_mismatch_flag
                .store(true, Ordering::Release);
            return true;
        }
        if ASIO_MSG_SESSION_ID.load(Ordering::Acquire) == self.session_id {
            let msg_sr = ASIO_MSG_SAMPLE_RATE_HZ.load(Ordering::Acquire);
            if msg_sr != 0 && msg_sr != self.sample_rate {
                self.signals
                    .observed_driver_sample_rate
                    .store(msg_sr, Ordering::Release);
                self.signals
                    .format_mismatch_flag
                    .store(true, Ordering::Release);
                return true;
            }
        }
        false
    }
}
