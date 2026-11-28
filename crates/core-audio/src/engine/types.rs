//! Shared engine types, origin descriptors, ReplayGain tags, and `PlayerInner` state.

use std::path::PathBuf;
use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicI64, AtomicU8, AtomicU32, AtomicU64, AtomicUsize, Ordering,
};
use std::sync::{Arc, Mutex, OnceLock, RwLock, mpsc};
use std::time::Duration;

use core_types::{
    AudioFormat, CrossfeedConfig, DeckTrackMetadata, DspPipelineConfig as SharedDspConfig,
    OutputBackendKind, PeqBandConfig, PeqFilterKind, PlaybackEnginePolicy, PlaybackLifecycleState,
    ReplayGainConfig as SharedReplayGainConfig, StreamKey, StreamSourceSpec,
};
use tokio_util::sync::CancellationToken;

use crate::backend::device_fsm::OutputDeviceState;
use crate::decoder::pcm::{AudioDecoder, DecodedTrackMetadata};
use crate::decoder::source_opener::{
    L2PlayGateProbe, open_decoder_for_source_spec_with_l2, open_decoder_for_stream_with_token,
    source_spec_display_path,
};
use crate::engine::coordinator::{PendingStart, PlayerCommand};
use crate::engine::dsp_helpers::{build_mismatch_callback, position_ms_from_inner};
use crate::engine::dual_deck::{DualDeckControl, ThreadReaper};
use crate::engine::session::{CLOCK_SRC_STREAM_FRAMES, CLOCK_SRC_UNINIT};
use crate::error::CoreAudioError;
use crate::pipeline::fade::AudioFadeControl;
use crate::pipeline::rt_telemetry::RtTelemetry;
use crate::stream::StreamSource;
use crate::streaming::{L2CacheManager, StreamRefreshHandler};
use crate::verification::AudioVerificationEngine;

pub(crate) const VIRTUAL_DEVICE_ID: &str = "virtual-exclusive-dac";
pub(crate) const VIRTUAL_DEVICE_NAME: &str = "Virtual Exclusive DAC";

#[derive(Debug, Clone)]
pub struct ActiveTrackMeta {
    pub path: PathBuf,
    pub source_label: String,
    pub format: AudioFormat,
    pub duration_ms: u64,
    pub resampled_to_hz: Option<u32>,
    pub backend: OutputBackendKind,
    pub device_name: String,
    pub track_meta: Option<DeckTrackMetadata>,
}

/// Default paused idle duration before releasing proxy RAM LRU caches & idle HTTP sockets (10 minutes).
pub const DEFAULT_IDLE_RECLAIM_THRESHOLD: Duration = Duration::from_secs(600);

#[derive(Debug, Clone, Default)]
pub(crate) struct TrackReplayGainTags {
    pub(crate) track_db: Option<f64>,
    pub(crate) album_db: Option<f64>,
    pub(crate) track_peak: Option<f64>,
    pub(crate) album_peak: Option<f64>,
    /// True when originating from a remote streaming `StreamSourceSpec` (`DirectRange`,
    /// `SegmentedManifest`, `EncryptedRange`), enabling automatic loudness normalization even
    /// when user ReplayGain mode is `Off` (still bypassed in Strict Bit-Perfect / DSP bypass).
    pub(crate) from_streaming_spec: bool,
}

impl TrackReplayGainTags {
    pub(crate) fn from_stream(stream: &StreamSource) -> Self {
        Self {
            track_db: stream.replay_gain_track_db,
            album_db: stream.replay_gain_album_db,
            track_peak: stream.replay_gain_track_peak,
            album_peak: stream.replay_gain_album_peak,
            from_streaming_spec: false,
        }
    }

    pub(crate) fn from_source_spec(spec: &StreamSourceSpec) -> Self {
        let from_streaming_spec = !matches!(spec, StreamSourceSpec::LocalFile { .. });
        let track = spec.loudness().map(|l| l.sanitized());
        let album = spec.album_loudness().map(|l| l.sanitized());
        // Streaming providers such as YouTube Music supply loudnessDb without a measured
        // sample peak, so `NormalizedLoudness` uses a synthetic default `peak = 1.0`.
        // When boosting a quiet track (`gain_db > 0`), treat synthetic `peak == 1.0` as
        // unmeasured (`None`) so `prevent_clipping` does not zero out the +6 dB boost; the
        // downstream LookaheadLimiter + post-resample soft clip guarantees [-1.0, 1.0] safety.
        let extract_peak = |l: core_types::NormalizedLoudness| -> Option<f64> {
            if l.gain_db > 0.0 && (l.peak - 1.0).abs() < 1e-6 {
                None
            } else {
                Some(l.peak as f64)
            }
        };
        Self {
            track_db: track.map(|l| l.gain_db as f64),
            album_db: album.map(|l| l.gain_db as f64),
            track_peak: track.and_then(extract_peak),
            album_peak: album.and_then(extract_peak),
            from_streaming_spec,
        }
    }

    pub(crate) fn with_metadata_fallback(mut self, meta: Option<&DecodedTrackMetadata>) -> Self {
        if let Some(m) = meta {
            if self.track_db.is_none()
                && let Some(nl) = m.track_normalized_loudness().map(|l| l.sanitized())
            {
                self.track_db = Some(nl.gain_db as f64);
                self.track_peak = Some(nl.peak as f64);
            }
            if self.album_db.is_none()
                && let Some(nl) = m.album_normalized_loudness().map(|l| l.sanitized())
            {
                self.album_db = Some(nl.gain_db as f64);
                self.album_peak = Some(nl.peak as f64);
            }
        }
        self
    }
}

#[derive(Debug, Clone)]
pub enum PlayerOrigin {
    Legacy(StreamSource),
    SourceSpec(StreamSourceSpec),
}

impl PlayerOrigin {
    pub fn display_path(&self) -> PathBuf {
        match self {
            Self::Legacy(stream) => stream.display_path(),
            Self::SourceSpec(spec) => source_spec_display_path(spec),
        }
    }

    pub(crate) fn stream_key(&self) -> Option<StreamKey> {
        match self {
            Self::Legacy(_) => None,
            Self::SourceSpec(spec) => Some(spec.key().clone()),
        }
    }

    pub(crate) fn source_spec(&self) -> Option<&StreamSourceSpec> {
        match self {
            Self::Legacy(_) => None,
            Self::SourceSpec(spec) => Some(spec),
        }
    }

    pub(crate) fn replay_gain_tags(&self) -> TrackReplayGainTags {
        match self {
            Self::Legacy(stream) => TrackReplayGainTags::from_stream(stream),
            Self::SourceSpec(spec) => TrackReplayGainTags::from_source_spec(spec),
        }
    }

    pub(crate) fn open_decoder_with_refresh(
        &self,
        inner: &Arc<PlayerInner>,
        cancel: CancellationToken,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        self.open_decoder_with_options(inner, cancel, refresh_handler, false)
    }

    pub(crate) fn open_decoder_with_options(
        &self,
        inner: &Arc<PlayerInner>,
        cancel: CancellationToken,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
        bypass_l2_read: bool,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        match self {
            Self::Legacy(stream) => {
                open_decoder_for_stream_with_token(stream, cancel, Duration::from_secs(10))
            }
            Self::SourceSpec(spec) => open_decoder_for_source_spec_with_l2(
                spec,
                cancel,
                refresh_handler,
                inner.l2_cache_manager(),
                bypass_l2_read,
                build_mismatch_callback(inner, spec),
                Some(build_l2_play_gate_probe(inner)),
            ),
        }
    }
}

pub(crate) fn build_l2_play_gate_probe(inner: &Arc<PlayerInner>) -> L2PlayGateProbe {
    let weak = Arc::downgrade(inner);
    Arc::new(move |key: &StreamKey| {
        let inner = weak.upgrade()?;
        if inner.stopped.load(Ordering::Relaxed) {
            return None;
        }
        let active_idx = inner.dual_deck.active_idx();
        let is_active_track = inner
            .dual_deck
            .deck_keys
            .read()
            .ok()
            .and_then(|g| g[active_idx].clone())
            .is_none_or(|k| &k == key);
        let is_playing = is_active_track
            && inner.state_code.load(Ordering::Relaxed) == PlaybackLifecycleState::Playing as i32
            && !inner.paused.load(Ordering::Relaxed);
        Some((is_playing, position_ms_from_inner(&inner)))
    })
}

pub(crate) fn encode_device_fsm_state(s: OutputDeviceState) -> u8 {
    match s {
        OutputDeviceState::Idle => 0,
        OutputDeviceState::Opening => 1,
        OutputDeviceState::Running => 2,
        OutputDeviceState::Reconfiguring => 3,
        OutputDeviceState::Stopping => 4,
        OutputDeviceState::Faulted => 5,
    }
}

pub(crate) fn decode_device_fsm_state(code: u8) -> OutputDeviceState {
    match code {
        0 => OutputDeviceState::Idle,
        1 => OutputDeviceState::Opening,
        2 => OutputDeviceState::Running,
        3 => OutputDeviceState::Reconfiguring,
        4 => OutputDeviceState::Stopping,
        _ => OutputDeviceState::Faulted,
    }
}

pub(crate) struct PlayerInner {
    pub(crate) headless: bool,
    pub(crate) state_code: Arc<AtomicI32>,
    pub(crate) paused: AtomicBool,
    pub(crate) stopped: AtomicBool,
    pub(crate) volume_bits: AtomicU32,
    pub(crate) strict_bit_perfect: Arc<AtomicBool>,
    pub(crate) saved_allow_shared_fallback: AtomicBool,
    pub(crate) device_fsm_state: Arc<AtomicU8>,
    pub(crate) rt_telemetry: Arc<RtTelemetry>,
    pub(crate) dsp_bypassed: AtomicBool,
    pub(crate) dsp_generation: AtomicU64,
    pub(crate) dsp_config: RwLock<SharedDspConfig>,
    pub(crate) track_replay_gain: RwLock<TrackReplayGainTags>,
    pub(crate) selected_output: RwLock<(Option<String>, Option<OutputBackendKind>)>,
    pub(crate) out_sample_rate: AtomicU32,
    pub(crate) duration_ms: AtomicU64,
    pub(crate) frames_rendered: Arc<AtomicU64>,
    pub(crate) nonzero_output_frames: Arc<AtomicU64>,
    pub(crate) current_session_id: Arc<AtomicU64>,
    pub(crate) seek_request_ms: AtomicI64,
    pub(crate) active_meta: RwLock<Option<ActiveTrackMeta>>,
    pub(crate) active_track_metadata: RwLock<Option<DeckTrackMetadata>>,
    pub(crate) active_source_spec: RwLock<Option<StreamSourceSpec>>,
    pub(crate) last_error: Arc<RwLock<Option<String>>>,
    pub(crate) last_error_code: Arc<RwLock<Option<String>>>,
    pub(crate) last_error_provider: Arc<RwLock<Option<String>>>,
    pub(crate) policy: RwLock<PlaybackEnginePolicy>,
    pub(crate) saved_normal_dsp_bypass: AtomicBool,
    pub(crate) saved_normal_volume_bits: AtomicU32,
    pub(crate) verification: RwLock<Option<(AudioVerificationEngine, String, String)>>,
    pub(crate) queued_next: RwLock<Option<(StreamSource, String)>>,
    pub(crate) queued_next_spec:
        RwLock<Option<(StreamSourceSpec, String, Option<DeckTrackMetadata>)>>,
    pub(crate) has_queued_next_spec: AtomicBool,
    pub(crate) gapless_transitions: Arc<AtomicU64>,
    pub(crate) format_reinit_count: AtomicU64,
    pub(crate) seek_epoch: AtomicU64,
    pub(crate) epoch: AtomicU64,
    pub(crate) playback_epoch: Arc<AtomicU64>,
    pub(crate) play_epoch: AtomicU64,
    pub(crate) last_caller_play_epoch: AtomicU64,
    pub(crate) active_cancel: RwLock<CancellationToken>,
    pub(crate) epoch_lock: Mutex<()>,
    pub(crate) device_lost: Arc<AtomicBool>,
    pub(crate) format_mismatch_flag: Arc<AtomicBool>,
    pub(crate) published_format_stamp: Arc<AtomicU64>,
    pub(crate) stream_refresh_handler: RwLock<Option<Arc<dyn StreamRefreshHandler>>>,
    pub(crate) l2_cache_manager: RwLock<Option<Arc<L2CacheManager>>>,
    pub(crate) cmd_tx_slot: OnceLock<mpsc::Sender<PlayerCommand>>,
    pub(crate) idle_reclaim_threshold: RwLock<Duration>,
    pub(crate) idle_reclaim_count: AtomicU64,
    pub(crate) output_reopen_count: AtomicU64,
    pub(crate) live_decode_threads: Arc<AtomicUsize>,
    pub(crate) cached_clock_source: AtomicU8,
    pub(crate) is_seeking: AtomicBool,
    pub(crate) buffered_ms: Arc<AtomicU64>,
    pub(crate) ring_buffer_underrun_count: Arc<AtomicU64>,
    pub(crate) cpal_stream_error_flag: Arc<AtomicBool>,
    pub(crate) active_fade: RwLock<Option<Arc<AudioFadeControl>>>,
    #[cfg(target_os = "windows")]
    pub(crate) active_wasapi_ctrl:
        RwLock<Option<Arc<crate::backend::wasapi_win::WasapiRenderControl>>>,
    pub(crate) latest_start: Mutex<Option<PendingStart>>,
    pub(crate) reaper: ThreadReaper,
    pub(crate) dual_deck: Arc<DualDeckControl>,
}

pub(crate) fn default_shared_peq_bands() -> Vec<PeqBandConfig> {
    vec![
        PeqBandConfig {
            filter_type: PeqFilterKind::LowShelf,
            frequency_hz: 80.0,
            gain_db: 1.5,
            q_factor: std::f64::consts::FRAC_1_SQRT_2,
            enabled: true,
        },
        PeqBandConfig {
            filter_type: PeqFilterKind::HighShelf,
            frequency_hz: 10_000.0,
            gain_db: 1.0,
            q_factor: std::f64::consts::FRAC_1_SQRT_2,
            enabled: true,
        },
    ]
}

pub(crate) fn default_shared_dsp_config() -> SharedDspConfig {
    SharedDspConfig {
        bypass: false,
        peq_bands: default_shared_peq_bands(),
        crossfeed: CrossfeedConfig::default(),
        replay_gain: SharedReplayGainConfig::default(),
    }
}

impl PlayerInner {
    pub(crate) fn new(headless: bool) -> Self {
        Self {
            headless,
            state_code: Arc::new(AtomicI32::new(PlaybackLifecycleState::Stopped as i32)),
            paused: AtomicBool::new(false),
            stopped: AtomicBool::new(true),
            volume_bits: AtomicU32::new((1.0f32).to_bits()),
            strict_bit_perfect: Arc::new(AtomicBool::new(false)),
            saved_allow_shared_fallback: AtomicBool::new(true),
            device_fsm_state: Arc::new(AtomicU8::new(encode_device_fsm_state(
                OutputDeviceState::Idle,
            ))),
            rt_telemetry: Arc::new(RtTelemetry::new()),
            dsp_bypassed: AtomicBool::new(false),
            dsp_generation: AtomicU64::new(1),
            dsp_config: RwLock::new(default_shared_dsp_config()),
            track_replay_gain: RwLock::new(TrackReplayGainTags::default()),
            selected_output: RwLock::new((None, None)),
            out_sample_rate: AtomicU32::new(48_000),
            duration_ms: AtomicU64::new(0),
            frames_rendered: Arc::new(AtomicU64::new(0)),
            nonzero_output_frames: Arc::new(AtomicU64::new(0)),
            current_session_id: Arc::new(AtomicU64::new(0)),
            seek_request_ms: AtomicI64::new(-1),
            active_meta: RwLock::new(None),
            active_track_metadata: RwLock::new(None),
            active_source_spec: RwLock::new(None),
            last_error: Arc::new(RwLock::new(None)),
            last_error_code: Arc::new(RwLock::new(None)),
            last_error_provider: Arc::new(RwLock::new(None)),
            policy: RwLock::new(PlaybackEnginePolicy::default()),
            saved_normal_dsp_bypass: AtomicBool::new(false),
            saved_normal_volume_bits: AtomicU32::new((1.0f32).to_bits()),
            verification: RwLock::new(None),
            queued_next: RwLock::new(None),
            queued_next_spec: RwLock::new(None),
            has_queued_next_spec: AtomicBool::new(false),
            gapless_transitions: Arc::new(AtomicU64::new(0)),
            format_reinit_count: AtomicU64::new(0),
            seek_epoch: AtomicU64::new(0),
            epoch: AtomicU64::new(0),
            playback_epoch: Arc::new(AtomicU64::new(0)),
            play_epoch: AtomicU64::new(0),
            last_caller_play_epoch: AtomicU64::new(0),
            active_cancel: RwLock::new(CancellationToken::new()),
            epoch_lock: Mutex::new(()),
            device_lost: Arc::new(AtomicBool::new(false)),
            format_mismatch_flag: Arc::new(AtomicBool::new(false)),
            published_format_stamp: Arc::new(AtomicU64::new(0)),
            stream_refresh_handler: RwLock::new(None),
            l2_cache_manager: RwLock::new(None),
            cmd_tx_slot: OnceLock::new(),
            idle_reclaim_threshold: RwLock::new(DEFAULT_IDLE_RECLAIM_THRESHOLD),
            idle_reclaim_count: AtomicU64::new(0),
            output_reopen_count: AtomicU64::new(0),
            live_decode_threads: Arc::new(AtomicUsize::new(0)),
            cached_clock_source: AtomicU8::new(if headless {
                CLOCK_SRC_STREAM_FRAMES
            } else {
                CLOCK_SRC_UNINIT
            }),
            is_seeking: AtomicBool::new(false),
            buffered_ms: Arc::new(AtomicU64::new(0)),
            ring_buffer_underrun_count: Arc::new(AtomicU64::new(0)),
            cpal_stream_error_flag: Arc::new(AtomicBool::new(false)),
            active_fade: RwLock::new(None),
            #[cfg(target_os = "windows")]
            active_wasapi_ctrl: RwLock::new(None),
            latest_start: Mutex::new(None),
            reaper: ThreadReaper::new(),
            dual_deck: Arc::new(DualDeckControl::new()),
        }
    }

    pub(crate) fn clear_latest_start(&self) {
        let displaced = self.latest_start.lock().ok().and_then(|mut g| g.take());
        if let Some(old) = displaced {
            let _ = old.ack_tx.send(Ok(()));
        }
    }

    pub(crate) fn advance_playback_epoch(&self, min_epoch: Option<u64>) -> u64 {
        let floor = min_epoch.unwrap_or(0);
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        loop {
            let next = cur.saturating_add(1).max(floor);
            match self.playback_epoch.compare_exchange_weak(
                cur,
                next,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return next,
                Err(actual) => cur = actual,
            }
        }
    }

    pub(crate) fn enter_output_skip_silence(&self) {
        #[cfg(target_os = "windows")]
        if let Ok(guard) = self.active_wasapi_ctrl.read()
            && let Some(ref ctrl) = *guard
        {
            ctrl.enter_skip_silence();
        }
        if let Ok(fade_lock) = self.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_skip_fade_out();
        }
    }

    pub(crate) fn set_active_wasapi_ctrl(
        &self,
        #[cfg(target_os = "windows")] ctrl: Option<
            Arc<crate::backend::wasapi_win::WasapiRenderControl>,
        >,
    ) {
        #[cfg(target_os = "windows")]
        if let Ok(mut guard) = self.active_wasapi_ctrl.write() {
            *guard = ctrl;
        }
    }

    pub(crate) fn stream_refresh_handler(&self) -> Option<Arc<dyn StreamRefreshHandler>> {
        self.stream_refresh_handler
            .read()
            .ok()
            .and_then(|g| g.clone())
    }

    pub(crate) fn l2_cache_manager(&self) -> Option<Arc<L2CacheManager>> {
        self.l2_cache_manager.read().ok().and_then(|g| g.clone())
    }

    pub(crate) fn clear_error_state(&self) {
        if let Ok(mut err_lock) = self.last_error.write() {
            *err_lock = None;
        }
        if let Ok(mut code_lock) = self.last_error_code.write() {
            *code_lock = None;
        }
        if let Ok(mut prov_lock) = self.last_error_provider.write() {
            *prov_lock = None;
        }
    }
}
