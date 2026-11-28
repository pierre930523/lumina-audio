//! Epoch/cancellation management, stream handler installation, and `play_source_spec*` entrypoints.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use core_types::{DeckTrackMetadata, StreamSourceSpec};
use tokio_util::sync::CancellationToken;

use crate::backend::DeviceEvent;
use crate::decoder::source_opener::{
    open_decoder_for_source_spec_with_l2_adopted, source_spec_default_label,
};
use crate::engine::AudioPlayer;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dsp_helpers::{
    build_mismatch_callback, record_playback_error, record_playback_error_with_code,
};
use crate::engine::types::build_l2_play_gate_probe;
use crate::error::{CoreAudioError, DecoderError};
use crate::streaming::{L2CacheManager, StreamRefreshHandler};

impl AudioPlayer {
    /// Returns the player's monotonic lifecycle epoch (incremented on every play, stop, and seek).
    pub fn current_epoch(&self) -> u64 {
        self.inner.epoch.load(Ordering::SeqCst)
    }

    /// Returns the player's monotonic track/transition epoch (incremented on play, skip, stop,
    /// and standby-to-active flips; never incremented on seek). Strictly lock-free.
    pub fn playback_epoch(&self) -> u64 {
        self.inner.playback_epoch.load(Ordering::Acquire)
    }

    /// Returns the cumulative number of hardware/virtual output sessions opened (not hot-swapped).
    pub fn output_reopen_count(&self) -> u64 {
        self.inner.output_reopen_count.load(Ordering::Acquire)
    }

    /// Returns the number of live background decode OS threads currently owned by this player.
    pub fn active_decode_thread_count(&self) -> usize {
        self.inner.live_decode_threads.load(Ordering::Acquire)
    }

    /// Cancels any active standby pre-decode and queued next-track spec without blocking.
    pub fn cancel_standby(&self) {
        if let Ok(mut q) = self.inner.queued_next.write() {
            *q = None;
        }
        if let Ok(mut qs) = self.inner.queued_next_spec.write() {
            *qs = None;
        }
        self.inner
            .has_queued_next_spec
            .store(false, Ordering::SeqCst);
        self.inner
            .dual_deck
            .cancel_standby_nonblocking(&self.inner.reaper);
    }

    fn enter_skip_transition_state(&self) {
        self.inner.clear_latest_start();
        if let Ok(mut q) = self.inner.queued_next.write() {
            *q = None;
        }
        if let Ok(mut qs) = self.inner.queued_next_spec.write() {
            *qs = None;
        }
        self.inner
            .has_queued_next_spec
            .store(false, Ordering::SeqCst);
        self.inner.paused.store(false, Ordering::SeqCst);
        self.inner.frames_rendered.store(0, Ordering::SeqCst);
        self.inner.buffered_ms.store(0, Ordering::Relaxed);
        self.inner.enter_output_skip_silence();
        self.inner
            .dual_deck
            .cancel_standby_nonblocking(&self.inner.reaper);
        self.inner
            .dual_deck
            .cancel_active_nonblocking(&self.inner.reaper);
    }

    /// Monotonically raises `playback_epoch`, `epoch`, and `last_caller_play_epoch` to at least
    /// `caller_epoch` so gapless transitions stay ahead of caller-driven skip epochs.
    pub fn sync_caller_epoch_floor(&self, caller_epoch: u64) {
        if caller_epoch == 0 {
            return;
        }
        let _guard = self
            .inner
            .epoch_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        self.inner
            .last_caller_play_epoch
            .fetch_max(caller_epoch, Ordering::SeqCst);
        self.inner.epoch.fetch_max(caller_epoch, Ordering::SeqCst);
        self.inner
            .playback_epoch
            .fetch_max(caller_epoch, Ordering::SeqCst);
    }

    /// Strictly non-blocking (`< 0.1 ms`) track-skip initiation:
    /// atomically bumps `playback_epoch`, `epoch`, and `play_epoch`, cancels active+standby decode
    /// tasks (retiring thread handles to the background reaper with zero `join()`), clears any
    /// superseded pending start, and shifts live WASAPI/CPAL/Virtual output into silent keep-alive
    /// without tearing down `IAudioClient`.
    /// Returns `(play_ep, fresh_cancel)` for direct use with `open_source_spec_async_with_l2` and
    /// `start_opened_source_spec_with_metadata` / `start_opened_decoder_with_epoch_and_metadata`.
    pub fn begin_skip_transition(&self) -> (u64, CancellationToken) {
        let fresh_cancel = CancellationToken::new();
        let play_ep = self
            .swap_cancel_and_bump_epoch(None, fresh_cancel.clone())
            .expect("fresh cancellation token cannot be cancelled");
        self.enter_skip_transition_state();
        (play_ep, fresh_cancel)
    }

    /// Same strictly non-blocking skip transition as [`Self::begin_skip_transition`], accepting a
    /// caller-supplied monotonic `caller_epoch` and `cancel` token in a single atomic step (zero
    /// double-bump). Returns `None` if `caller_epoch` is stale or `cancel` is already cancelled.
    pub fn begin_skip_transition_with_epoch(
        &self,
        caller_epoch: u64,
        cancel: CancellationToken,
    ) -> Option<u64> {
        let play_ep = self.swap_cancel_and_bump_epoch(Some(caller_epoch), cancel)?;
        self.enter_skip_transition_state();
        Some(play_ep)
    }

    /// Returns a clone of the active stream `CancellationToken`.
    pub fn active_cancellation_token(&self) -> CancellationToken {
        self.inner
            .active_cancel
            .read()
            .map(|g| g.clone())
            .unwrap_or_else(|_| CancellationToken::new())
    }

    /// Returns the currently active `StreamSourceSpec`, if playback was started via `play_source_spec`.
    pub fn active_source_spec(&self) -> Option<StreamSourceSpec> {
        self.inner
            .active_source_spec
            .read()
            .ok()
            .and_then(|g| g.clone())
    }

    /// Installs (or clears) the [`StreamRefreshHandler`] used by `ChunkedStreamProxy` and
    /// `SegmentedStreamProxy` for automatic HTTP 403/410 self-healing.
    pub fn set_stream_refresh_handler(&self, handler: Option<Arc<dyn StreamRefreshHandler>>) {
        if let Ok(mut guard) = self.inner.stream_refresh_handler.write() {
            *guard = handler;
        }
    }

    /// Returns the currently installed [`StreamRefreshHandler`], if any.
    pub fn stream_refresh_handler(&self) -> Option<Arc<dyn StreamRefreshHandler>> {
        self.inner.stream_refresh_handler()
    }

    /// Installs (or clears) the [`L2CacheManager`] used for local `.head` / `.dash.head`
    /// zero-latency playback, overlap verification, and stable-play admission capture.
    pub fn set_l2_cache_manager(&self, manager: Option<Arc<L2CacheManager>>) {
        if let Ok(mut guard) = self.inner.l2_cache_manager.write() {
            *guard = manager;
        }
    }

    /// Returns the currently installed [`L2CacheManager`], if any.
    pub fn l2_cache_manager(&self) -> Option<Arc<L2CacheManager>> {
        self.inner.l2_cache_manager()
    }

    /// Configures how long a paused session waits before releasing proxy LRU caches and idle HTTP
    /// sockets (defaults to 10 minutes).
    pub fn set_idle_reclaim_threshold(&self, threshold: Duration) {
        if let Ok(mut guard) = self.inner.idle_reclaim_threshold.write() {
            *guard = threshold;
        }
    }

    /// Returns how many times paused idle memory reclamation has fired on this player.
    pub fn idle_reclaim_count(&self) -> u64 {
        self.inner.idle_reclaim_count.load(Ordering::Relaxed)
    }

    /// Dispatches a hardware endpoint or OS sleep/wake [`DeviceEvent`] to the coordinator thread.
    pub fn handle_device_event(&self, event: DeviceEvent) {
        let _ = self.cmd_tx.send(PlayerCommand::HardwareDeviceEvent(event));
    }

    /// Cancels active playback immediately if the active [`StreamSourceSpec`] belongs to
    /// `provider_id`, recording `AUTH_REQUIRED` without affecting other providers or local files.
    pub fn cancel_active_stream_for_provider(&self, provider_id: &str) -> bool {
        let pid = provider_id.trim();
        if pid.is_empty() {
            return false;
        }
        let matches_active = self
            .inner
            .active_source_spec
            .read()
            .ok()
            .and_then(|g| {
                g.as_ref()
                    .map(|spec| spec.key().provider_id.eq_ignore_ascii_case(pid))
            })
            .unwrap_or(false);
        if !matches_active {
            return false;
        }

        if let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_stop_fade_out();
        }
        let _ = self.swap_cancel_and_bump_epoch(None, CancellationToken::new());
        if let Ok(mut spec_lock) = self.inner.active_source_spec.write() {
            *spec_lock = None;
        }
        self.inner.paused.store(false, Ordering::SeqCst);
        self.inner.frames_rendered.store(0, Ordering::SeqCst);
        self.inner.buffered_ms.store(0, Ordering::Relaxed);
        record_playback_error_with_code(
            &self.inner,
            format!("Authentication required for {pid}"),
            Some("AUTH_REQUIRED"),
            Some(pid.to_string()),
        );
        let _ = self.cmd_tx.send(PlayerCommand::Stop);
        true
    }

    pub(super) fn swap_cancel_and_bump_epoch(
        &self,
        caller_epoch: Option<u64>,
        new_cancel: CancellationToken,
    ) -> Option<u64> {
        if new_cancel.is_cancelled() {
            return None;
        }
        let _guard = self
            .inner
            .epoch_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if new_cancel.is_cancelled() {
            return None;
        }
        if let Some(req) = caller_epoch
            && req > 0
        {
            let last_caller = self.inner.last_caller_play_epoch.load(Ordering::SeqCst);
            if req < last_caller {
                return None;
            }
            self.inner
                .last_caller_play_epoch
                .store(req, Ordering::SeqCst);
        }

        let cur_ep = self.inner.epoch.load(Ordering::SeqCst);
        let next_ep = match caller_epoch {
            Some(req) if req > 0 => cur_ep.saturating_add(1).max(req),
            _ => cur_ep.saturating_add(1),
        };
        self.inner.epoch.store(next_ep, Ordering::SeqCst);
        self.inner
            .advance_playback_epoch(caller_epoch.filter(|&r| r > 0));
        let play_ep = self.inner.play_epoch.fetch_add(1, Ordering::SeqCst) + 1;

        let prev_cancel = self
            .inner
            .active_cancel
            .write()
            .ok()
            .map(|mut g| std::mem::replace(&mut *g, new_cancel));
        if let Some(prev) = prev_cancel {
            prev.cancel();
        }

        Some(play_ep)
    }

    /// Claims a new playback epoch and cancels any prior active/pending stream token.
    /// Returns `None` if `epoch` is stale (`< last play epoch`) or `cancel` is already cancelled.
    pub fn begin_source_epoch(&self, epoch: u64, cancel: CancellationToken) -> Option<u64> {
        self.swap_cancel_and_bump_epoch(Some(epoch), cancel)
    }

    /// Opens and plays a declarative [`StreamSourceSpec`] with epoch/cancellation coordination.
    /// Rejects [`StreamSourceSpec::ExternalBackend`] explicitly and silently discards stale tasks.
    pub fn play_source_spec(
        &self,
        spec: StreamSourceSpec,
        epoch: u64,
        cancel: CancellationToken,
    ) -> Result<(), CoreAudioError> {
        let label = source_spec_default_label(&spec);
        self.play_source_spec_with_label(spec, &label, epoch, cancel)
    }

    /// Opens and plays a [`StreamSourceSpec`] with a custom Signal Path source label.
    pub fn play_source_spec_with_label(
        &self,
        spec: StreamSourceSpec,
        source_label: &str,
        epoch: u64,
        cancel: CancellationToken,
    ) -> Result<(), CoreAudioError> {
        self.play_source_spec_with_metadata(spec, source_label, epoch, cancel, None)
    }

    /// Opens and plays a [`StreamSourceSpec`] with a custom Signal Path label and track metadata.
    pub fn play_source_spec_with_metadata(
        &self,
        spec: StreamSourceSpec,
        source_label: &str,
        epoch: u64,
        cancel: CancellationToken,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        if let StreamSourceSpec::ExternalBackend {
            key, provider_id, ..
        } = &spec
        {
            return Err(CoreAudioError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                key.track_id
            )));
        }

        let Some(play_ep) = self.begin_source_epoch(epoch, cancel.clone()) else {
            return Ok(());
        };

        let refresh_handler = self.stream_refresh_handler();
        let (decoder, adopted_spec) = match open_decoder_for_source_spec_with_l2_adopted(
            &spec,
            cancel.clone(),
            refresh_handler,
            self.inner.l2_cache_manager(),
            false,
            build_mismatch_callback(&self.inner, &spec),
            Some(build_l2_play_gate_probe(&self.inner)),
        ) {
            Ok(pair) => pair,
            Err(e) => {
                if cancel.is_cancelled() || self.inner.play_epoch.load(Ordering::SeqCst) != play_ep
                {
                    return Ok(());
                }
                match &e {
                    CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    }) => {
                        record_playback_error_with_code(
                            &self.inner,
                            format!("Authentication required for {provider_id} (HTTP {status})"),
                            Some("AUTH_REQUIRED"),
                            Some(provider_id.clone()),
                        );
                    }
                    _ => record_playback_error(&self.inner, e.to_string()),
                }
                return Err(e);
            }
        };

        self.start_opened_source_spec_with_metadata(
            &adopted_spec,
            decoder,
            source_label,
            play_ep,
            cancel,
            track_meta,
        )
    }
}
