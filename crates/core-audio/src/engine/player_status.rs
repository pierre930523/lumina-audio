//! Playback state queries, clock/telemetry getters, error accessors, and Signal Path builder.

use std::sync::atomic::Ordering;

use core_types::{AudioFormat, PeqFilterKind, PlaybackLifecycleState, SignalPath};

use crate::engine::dsp_helpers::compute_effective_replay_gain_db;
use crate::engine::session::{
    CLOCK_SRC_UNINIT, backend_to_clock_src, clock_src_to_str, resolve_target_capabilities,
};
use crate::engine::{ActiveTrackMeta, AudioPlayer};
use crate::signal_path::{SignalPathContext, SignalPathEngine};

impl AudioPlayer {
    pub fn state_code(&self) -> i32 {
        self.inner.state_code.load(Ordering::SeqCst)
    }

    pub fn playback_state(&self) -> PlaybackLifecycleState {
        PlaybackLifecycleState::from_i32(self.state_code())
    }

    pub fn state_name(&self) -> &'static str {
        self.playback_state().as_str()
    }

    pub fn seek_epoch(&self) -> u64 {
        self.inner.seek_epoch.load(Ordering::Acquire)
    }

    pub fn is_seeking(&self) -> bool {
        self.inner.is_seeking.load(Ordering::Acquire)
            || self.state_code() == PlaybackLifecycleState::Seeking as i32
    }

    pub fn is_device_lost(&self) -> bool {
        if self.inner.device_lost.load(Ordering::Acquire) {
            return true;
        }
        if let Some(err) = self.last_error() {
            let lower = err.to_ascii_lowercase();
            if lower.contains("device invalidated")
                || lower.contains("device lost")
                || lower.contains("device_lost")
                || lower.contains("not found")
            {
                return true;
            }
        }
        false
    }

    pub fn set_device_lost(&self, lost: bool) {
        self.inner.device_lost.store(lost, Ordering::SeqCst);
    }

    pub fn clock_source(&self) -> &'static str {
        if self.inner.headless {
            return "stream_frames";
        }
        let cached = self.inner.cached_clock_source.load(Ordering::Acquire);
        if cached != CLOCK_SRC_UNINIT {
            return clock_src_to_str(cached);
        }
        let (sel_id, sel_backend) = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));
        let caps = resolve_target_capabilities(&self.inner, sel_id.as_deref(), sel_backend);
        let code = backend_to_clock_src(false, caps.backend);
        self.inner
            .cached_clock_source
            .store(code, Ordering::Release);
        clock_src_to_str(code)
    }

    pub fn hardware_clock_position_ms(&self) -> Option<u64> {
        let clock = self.clock_source();
        if clock == "stream_frames" {
            return None;
        }
        Some(self.position_ms())
    }

    pub fn position_ms(&self) -> u64 {
        let rate = self.inner.out_sample_rate.load(Ordering::Relaxed) as u128;
        if rate == 0 {
            return 0;
        }
        let frames = self.inner.frames_rendered.load(Ordering::Relaxed) as u128;
        ((frames * 1000) / rate) as u64
    }

    pub fn duration_ms(&self) -> u64 {
        if self.has_pending_transition_commit() {
            let active_idx = self.inner.dual_deck.active_idx();
            if let Ok(mg) = self.inner.dual_deck.deck_meta[active_idx].read()
                && let Some(ref snap) = *mg
            {
                return snap.duration_ms;
            }
        }
        self.inner.duration_ms.load(Ordering::Relaxed)
    }

    /// Approximate PCM/wire duration currently queued in the playback ring buffer (in ms).
    pub fn buffered_ms(&self) -> u64 {
        self.inner.buffered_ms.load(Ordering::Relaxed)
    }

    /// Cumulative count of RT audio output ring-buffer underrun events for the active track.
    pub fn ring_buffer_underrun_count(&self) -> u64 {
        self.inner
            .ring_buffer_underrun_count
            .load(Ordering::Relaxed)
    }

    pub fn nonzero_output_frames(&self) -> u64 {
        self.inner.nonzero_output_frames.load(Ordering::Relaxed)
    }

    pub fn last_error(&self) -> Option<String> {
        self.inner.last_error.read().ok().and_then(|g| g.clone())
    }

    pub fn last_error_code(&self) -> Option<String> {
        self.inner
            .last_error_code
            .read()
            .ok()
            .and_then(|g| g.clone())
    }

    pub fn last_error_provider(&self) -> Option<String> {
        self.inner
            .last_error_provider
            .read()
            .ok()
            .and_then(|g| g.clone())
    }

    pub fn take_last_error(&self) -> Option<String> {
        if let Ok(mut code_lock) = self.inner.last_error_code.write() {
            *code_lock = None;
        }
        if let Ok(mut prov_lock) = self.inner.last_error_provider.write() {
            *prov_lock = None;
        }
        self.inner
            .last_error
            .write()
            .ok()
            .and_then(|mut g| g.take())
    }

    pub fn active_meta(&self) -> Option<ActiveTrackMeta> {
        self.inner.active_meta.read().ok().and_then(|g| g.clone())
    }

    pub fn current_signal_path(&self) -> SignalPath {
        let cfg = self.get_dsp_config();
        let bypassed = cfg.bypass;
        let rg_tags = self
            .inner
            .track_replay_gain
            .read()
            .map(|g| g.clone())
            .unwrap_or_default();

        let active_peq_count = cfg
            .peq_bands
            .iter()
            .filter(|b| {
                b.enabled
                    && (b.gain_db.abs() > 1e-4
                        || matches!(
                            b.filter_type,
                            PeqFilterKind::LowPass | PeqFilterKind::HighPass
                        ))
            })
            .count();

        let applied_rg_db = compute_effective_replay_gain_db(&cfg.replay_gain, &rg_tags);
        let cf_enabled = cfg.crossfeed.enabled;
        let dsp_active =
            !bypassed && (active_peq_count > 0 || cf_enabled || applied_rg_db.is_some());

        let dsp_detail = if dsp_active {
            let mut parts = Vec::new();
            if active_peq_count > 0 {
                parts.push(format!("PEQ ({active_peq_count} bands)"));
            }
            if cf_enabled {
                parts.push("Crossfeed".to_string());
            }
            if let Some(rg_db) = applied_rg_db {
                parts.push(format!("ReplayGain ({rg_db:+.1} dB)"));
            }
            Some(parts.join(", "))
        } else {
            None
        };

        if let Some(meta) = self.active_meta() {
            let ctx = SignalPathContext {
                source_label: &meta.source_label,
                format: &meta.format,
                dsp_bypass: bypassed,
                dsp_active,
                resampled_to_hz: meta.resampled_to_hz,
                backend: meta.backend,
                device_name: &meta.device_name,
            };
            SignalPathEngine::build_with_dsp_detail(&ctx, dsp_detail.as_deref())
        } else {
            let fallback_format = AudioFormat {
                codec: core_types::AudioCodec::Flac,
                sample_rate_hz: 48_000,
                bit_depth: 24,
                channels: 2,
                is_dsd: false,
            };
            let (backend, dev_name) = self.preview_output_target();
            let ctx = SignalPathContext {
                source_label: "No Active Track",
                format: &fallback_format,
                dsp_bypass: bypassed,
                dsp_active,
                resampled_to_hz: None,
                backend,
                device_name: &dev_name,
            };
            SignalPathEngine::build_with_dsp_detail(&ctx, dsp_detail.as_deref())
        }
    }
}
