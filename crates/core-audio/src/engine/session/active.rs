//! `ActiveSession` lifecycle management and graceful/retiring teardown.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use core_types::{AudioFormat, DeckTrackMetadata};
use cpal::traits::StreamTrait;
use tokio_util::sync::CancellationToken;

use crate::decoder::pcm::AudioDecoder;
use crate::engine::dual_deck::{DualDeckControl, StandbyWakeState};
use crate::engine::{PlayerInner, PlayerOrigin};
use crate::pipeline::fade::{AudioFadeControl, FadeTarget};

use super::types::{NativeOutputSession, OutputReuseKey};

pub(crate) struct ActiveSession {
    pub(crate) dual_deck: Arc<DualDeckControl>,
    pub(crate) cancel_flag: Arc<AtomicBool>,
    pub(crate) output_kill_flag: Arc<AtomicBool>,
    pub(crate) fade_ctrl: Arc<AudioFadeControl>,
    pub(crate) cancel_token: CancellationToken,
    pub(crate) eof_flag: Arc<AtomicBool>,
    pub(crate) decode_handle: Option<JoinHandle<Option<Box<dyn AudioDecoder>>>>,
    pub(crate) virtual_handle: Option<JoinHandle<()>>,
    pub(crate) _cpal_stream: Option<cpal::Stream>,
    pub(crate) native_output: Option<NativeOutputSession>,
    pub(crate) output_reuse_key: OutputReuseKey,
    pub(crate) feeder_session_id: Arc<AtomicU64>,
    pub(crate) expected_stamp_arc: Arc<AtomicU64>,
    pub(crate) path: PathBuf,
    pub(crate) source_label: String,
    pub(crate) origin: PlayerOrigin,
    pub(crate) format: AudioFormat,
    pub(crate) duration_ms: u64,
    pub(crate) pcm_rate: u32,
    pub(crate) active_device_id: String,
    pub(crate) track_meta: Option<DeckTrackMetadata>,
}

impl ActiveSession {
    /// Returns `true` if this session holds a real hardware output handle (WASAPI/ASIO/cpal).
    pub(crate) fn is_hardware_output(&self) -> bool {
        !matches!(
            self.native_output,
            Some(NativeOutputSession::VirtualWire(_))
        ) && (self.native_output.is_some() || self._cpal_stream.is_some())
    }

    pub(crate) fn is_output_alive(&self, inner: &PlayerInner) -> bool {
        if self.output_kill_flag.load(Ordering::Acquire)
            || inner.device_lost.load(Ordering::Acquire)
            || inner.cpal_stream_error_flag.load(Ordering::Acquire)
        {
            return false;
        }
        if let Some(ref native) = self.native_output {
            return match native {
                #[cfg(target_os = "windows")]
                NativeOutputSession::WasapiExclusive(s) => s.is_alive(),
                #[cfg(target_os = "windows")]
                NativeOutputSession::AsioNative(_) => false,
                NativeOutputSession::VirtualWire(h) => !h.is_finished(),
            };
        }
        if let Some(ref vh) = self.virtual_handle {
            return !vh.is_finished();
        }
        self._cpal_stream.is_some()
    }

    /// Stops output and retires any active decode thread handle to `inner.reaper` without
    /// blocking the coordinator on decode thread `join()`.
    pub(crate) fn stop_retiring_decode(&mut self, inner: &PlayerInner, cancel_own_token: bool) {
        if cancel_own_token {
            self.cancel_token.cancel();
        } else {
            // Detach parent token so `Drop::drop` cannot cancel a child token handed off to
            // `FormatSwitchNext`.
            self.cancel_token = CancellationToken::new();
        }
        self.cancel_flag.store(true, Ordering::SeqCst);
        let cur_active = self.dual_deck.active_idx();
        let deck_entry = self.dual_deck.decode_entries[cur_active]
            .lock()
            .ok()
            .and_then(|mut g| g.take());
        if let Some(mut entry) = deck_entry {
            if cancel_own_token {
                entry.cancel_token.cancel();
            }
            entry.cancel_flag.store(true, Ordering::SeqCst);
            if let Ok(mut wg) = entry.wake.0.lock() {
                *wg = StandbyWakeState::Cancelled;
                entry.wake.1.notify_all();
            }
            if let Some(h) = entry.join_handle.take() {
                inner.reaper.retire_decode(h);
            }
        }
        if let Some(h) = self.decode_handle.take() {
            inner.reaper.retire_decode(h);
        }

        // Skip blocking fade sleep if already silent or already in skip-silence keep-alive.
        let already_in_skip = self.fade_ctrl.target() == FadeTarget::SkipSilence;
        if !already_in_skip {
            self.fade_ctrl.request_stop_fade_out();
            if !self.fade_ctrl.is_fade_out_done() {
                let deadline = Instant::now() + Duration::from_millis(12);
                while !self.fade_ctrl.is_fade_out_done() && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(1));
                }
            }
        }
        #[cfg(target_os = "windows")]
        inner.set_active_wasapi_ctrl(None);
        #[cfg(not(target_os = "windows"))]
        inner.set_active_wasapi_ctrl();
        self.output_kill_flag.store(true, Ordering::SeqCst);
        if let Some(stream) = self._cpal_stream.take() {
            let _ = stream.pause();
            drop(stream);
        }
        if let Some(native) = self.native_output.take() {
            native.stop_and_join();
        }
        if let Some(h) = self.virtual_handle.take() {
            let _ = h.join();
        }
        self.dual_deck.clear_inboxes_for_deck(cur_active);
        self.dual_deck.drain_retired_payloads();
    }

    pub(crate) fn stop_and_join(&mut self) -> Option<Box<dyn AudioDecoder>> {
        if self.output_kill_flag.load(Ordering::Acquire)
            && self._cpal_stream.is_none()
            && self.native_output.is_none()
            && self.virtual_handle.is_none()
            && self.decode_handle.is_none()
        {
            return None;
        }
        // Cancel token first so any blocking HTTP Range/DASH read unblocks
        // immediately instead of stalling thread join on a network timeout.
        self.cancel_token.cancel();
        self.cancel_flag.store(true, Ordering::SeqCst);
        let cur_active = self.dual_deck.active_idx();
        if let Ok(guard) = self.dual_deck.decode_entries[cur_active].lock()
            && let Some(ref entry) = *guard
        {
            entry.cancel_token.cancel();
            entry.cancel_flag.store(true, Ordering::SeqCst);
            if let Ok(mut wg) = entry.wake.0.lock() {
                *wg = StandbyWakeState::Cancelled;
                entry.wake.1.notify_all();
            }
        }
        // Allow the RT audio callback up to 20 ms to complete its 10 ms linear fade-out
        // (0 ms if already paused/silent or fade-out disabled) before killing output.
        self.fade_ctrl.request_stop_fade_out();
        if !self.fade_ctrl.is_fade_out_done() {
            let deadline = Instant::now() + Duration::from_millis(20);
            while !self.fade_ctrl.is_fade_out_done() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
        }
        self.output_kill_flag.store(true, Ordering::SeqCst);
        if let Some(stream) = self._cpal_stream.take() {
            let _ = stream.pause();
            drop(stream);
        }
        if let Some(native) = self.native_output.take() {
            native.stop_and_join();
        }
        if let Some(h) = self.virtual_handle.take() {
            let _ = h.join();
        }
        let from_session = self
            .decode_handle
            .take()
            .and_then(|h| h.join().ok().flatten());
        let from_deck = self.dual_deck.decode_entries[cur_active]
            .lock()
            .ok()
            .and_then(|mut g| g.take())
            .and_then(|mut entry| {
                entry
                    .join_handle
                    .take()
                    .and_then(|h| h.join().ok().flatten())
            });
        self.dual_deck.clear_inboxes_for_deck(cur_active);
        self.dual_deck.drain_retired_payloads();
        from_deck.or(from_session)
    }
}

impl Drop for ActiveSession {
    fn drop(&mut self) {
        let _ = self.stop_and_join();
    }
}
