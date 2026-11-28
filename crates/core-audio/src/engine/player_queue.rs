//! Queue-next, dual-deck status inspection, metadata updates, and public `prepare_standby*` APIs.

use std::path::Path;
use std::sync::atomic::Ordering;

use core_types::{DeckId, DeckState, DeckTrackMetadata, DualDeckStatusSnapshot, StreamSourceSpec};

use crate::decoder::source_opener::source_spec_default_label;
use crate::engine::session::patched_track_meta;
use crate::engine::{AudioPlayer, PlayerOrigin};
use crate::error::CoreAudioError;
use crate::stream::StreamSource;

impl AudioPlayer {
    /// Queues the next track for Gapless Playback (when format matches) or automatic
    /// hardware backend re-initialization (when sample rate, DSD rate, or bit depth changes).
    pub fn queue_next_stream(&self, stream: StreamSource, source_label: &str) {
        let label = if source_label.trim().is_empty() {
            "Stream".to_string()
        } else {
            source_label.to_string()
        };
        if let Ok(mut q) = self.inner.queued_next.write() {
            *q = Some((stream, label));
        }
    }

    pub fn queue_next_file(&self, path: impl AsRef<Path>, source_label: Option<String>) {
        let stream = StreamSource::local_file(path.as_ref());
        let label = source_label.as_deref().unwrap_or("Local Library");
        self.queue_next_stream(stream, label);
    }

    pub fn gapless_transition_count(&self) -> u64 {
        self.inner.gapless_transitions.load(Ordering::Relaxed)
    }

    pub fn format_reinit_count(&self) -> u64 {
        self.inner.format_reinit_count.load(Ordering::Relaxed)
    }

    /// Returns the monotonic dual-deck standby-to-active transition counter.
    pub fn swap_generation(&self) -> u64 {
        self.inner.dual_deck.swap_generation.load(Ordering::Acquire)
    }

    /// Returns `true` when an RT deck flip has occurred and `relay_loop` has not yet committed
    /// the promoted deck's metadata snapshot into `PlayerInner`.
    pub fn has_pending_transition_commit(&self) -> bool {
        let active_idx = self.inner.dual_deck.active_idx();
        let active_gen = self.inner.dual_deck.deck_gen_for(active_idx);
        let committed_gen = self
            .inner
            .dual_deck
            .committed_deck_gen
            .load(Ordering::Acquire);
        active_gen != 0
            && active_gen != committed_gen
            && self.inner.dual_deck.deck_state(active_idx) != DeckState::Idle
    }

    /// Returns metadata for the currently active playback track, if known.
    pub fn active_track_metadata(&self) -> Option<DeckTrackMetadata> {
        let active_idx = self.inner.dual_deck.active_idx();
        if self.has_pending_transition_commit() {
            if let Ok(mg) = self.inner.dual_deck.deck_meta[active_idx].read()
                && let Some(ref snap) = *mg
            {
                return patched_track_meta(snap);
            }
            if let Ok(tg) = self.inner.dual_deck.deck_track_meta[active_idx].read()
                && let Some(ref m) = *tg
            {
                return Some(m.clone());
            }
        }
        self.inner
            .active_track_metadata
            .read()
            .ok()
            .and_then(|g| g.clone())
    }

    /// Updates metadata for the currently active playback track.
    pub fn set_active_track_metadata(&self, meta: Option<DeckTrackMetadata>) {
        if let Ok(mut lock) = self.inner.active_track_metadata.write() {
            *lock = meta.clone();
        }
        if let Ok(mut am_lock) = self.inner.active_meta.write()
            && let Some(ref mut am) = *am_lock
        {
            am.track_meta = meta.clone();
        }
        let active_idx = self.inner.dual_deck.active_idx();
        if self.inner.dual_deck.deck_state(active_idx) != DeckState::Idle {
            self.inner
                .dual_deck
                .set_deck_track_meta(active_idx, meta.clone());
            if let Ok(mut mg) = self.inner.dual_deck.deck_meta[active_idx].write()
                && let Some(ref mut snap) = *mg
            {
                snap.track_meta = meta;
            }
        }
    }

    /// Returns a live snapshot of both physical decks (`Deck A` / `Deck B`), standby buffer
    /// depth, and transition telemetry counters.
    pub fn dual_deck_status(&self) -> DualDeckStatusSnapshot {
        let swap_generation = self.swap_generation();
        let keys = self
            .inner
            .dual_deck
            .deck_keys
            .read()
            .map(|g| g.clone())
            .unwrap_or([None, None]);
        DualDeckStatusSnapshot {
            active_deck: self.active_deck(),
            deck_a_state: self.deck_state(DeckId::DeckA),
            deck_b_state: self.deck_state(DeckId::DeckB),
            deck_a_key: keys[0].clone(),
            deck_b_key: keys[1].clone(),
            standby_buffered_ms: self
                .inner
                .dual_deck
                .standby_buffered_ms
                .load(Ordering::Relaxed),
            gapless_transitions: self.inner.gapless_transitions.load(Ordering::Relaxed),
            manual_zero_latency_switches: self
                .inner
                .dual_deck
                .manual_zero_latency_switches
                .load(Ordering::Relaxed),
            format_mismatch_recoveries: self
                .inner
                .dual_deck
                .format_mismatch_recoveries
                .load(Ordering::Relaxed),
            swap_generation,
            playback_epoch: self.playback_epoch(),
            active_track: self.active_track_metadata(),
        }
    }

    /// Returns the current lifecycle state of `deck`.
    pub fn deck_state(&self, deck: DeckId) -> DeckState {
        self.inner.dual_deck.deck_state(deck.index())
    }

    /// Returns the currently active playback deck (`DeckA` or `DeckB`).
    pub fn active_deck(&self) -> DeckId {
        DeckId::from_index(self.inner.dual_deck.active_deck_idx.load(Ordering::Acquire))
    }

    /// Returns the current standby deck (`active_deck().other()`).
    pub fn standby_deck(&self) -> DeckId {
        self.active_deck().other()
    }

    /// Registers a next queued [`StreamSourceSpec`] for automatic pre-decoding onto Standby
    /// once Active reaches `<= 20s` remaining or `> 75%` progress. Skips `ExternalBackend`.
    pub fn queue_next_spec(&self, spec: StreamSourceSpec, source_label: Option<String>) {
        self.queue_next_spec_with_metadata(spec, source_label, None);
    }

    /// Registers a next queued [`StreamSourceSpec`] with deck track metadata for automatic
    /// pre-decoding onto Standby.
    pub fn queue_next_spec_with_metadata(
        &self,
        spec: StreamSourceSpec,
        source_label: Option<String>,
        track_meta: Option<DeckTrackMetadata>,
    ) {
        if matches!(spec, StreamSourceSpec::ExternalBackend { .. }) {
            if let Ok(mut qs) = self.inner.queued_next_spec.write() {
                *qs = None;
            }
            self.inner
                .has_queued_next_spec
                .store(false, Ordering::SeqCst);
            return;
        }
        let label = source_label
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| source_spec_default_label(&spec));
        if let Ok(mut qs) = self.inner.queued_next_spec.write() {
            *qs = Some((spec, label, track_meta));
        }
        self.inner
            .has_queued_next_spec
            .store(true, Ordering::SeqCst);
        self.inner.dual_deck.unpark_relay();
    }

    /// Pre-resolves and pre-decodes 2–3 seconds of `spec` onto the Standby deck, then parks
    /// its decode thread on a `Condvar` until promoted or replaced.
    /// Cleanly skips [`StreamSourceSpec::ExternalBackend`] (e.g., Apple Music).
    pub fn prepare_standby_spec(&self, spec: StreamSourceSpec) -> Result<(), CoreAudioError> {
        self.prepare_standby_spec_with_metadata(spec, None)
    }

    /// Pre-resolves and pre-decodes 2–3 seconds of `spec` with deck track metadata onto the
    /// Standby deck.
    pub fn prepare_standby_spec_with_metadata(
        &self,
        spec: StreamSourceSpec,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        self.prepare_standby_spec_with_label_and_metadata(spec, None, track_meta)
    }

    /// Pre-resolves and pre-decodes `spec` onto the Standby deck with an optional source label
    /// and deck track metadata.
    pub fn prepare_standby_spec_with_label_and_metadata(
        &self,
        spec: StreamSourceSpec,
        source_label: Option<&str>,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        if matches!(spec, StreamSourceSpec::ExternalBackend { .. }) {
            let _op_guard = self
                .inner
                .dual_deck
                .skip_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            self.inner
                .dual_deck
                .cancel_standby_nonblocking(&self.inner.reaper);
            return Ok(());
        }
        let label = source_label
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| source_spec_default_label(&spec));
        self.prepare_standby_internal(
            PlayerOrigin::SourceSpec(spec),
            label,
            false,
            false,
            None,
            None,
            track_meta,
            false,
        )
    }

    /// Pre-resolves and pre-decodes 2–3 seconds of a legacy `StreamSource` onto the Standby deck.
    pub fn prepare_standby(
        &self,
        stream: StreamSource,
        label: impl Into<String>,
    ) -> Result<(), CoreAudioError> {
        self.prepare_standby_with_metadata(stream, label, None)
    }

    /// Pre-resolves and pre-decodes a legacy `StreamSource` with deck track metadata onto the
    /// Standby deck.
    pub fn prepare_standby_with_metadata(
        &self,
        stream: StreamSource,
        label: impl Into<String>,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        let raw_label = label.into();
        let eff_label = if raw_label.trim().is_empty() {
            "Stream".to_string()
        } else {
            raw_label
        };
        self.prepare_standby_internal(
            PlayerOrigin::Legacy(stream),
            eff_label,
            false,
            false,
            None,
            None,
            track_meta,
            false,
        )
    }
}
