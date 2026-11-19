use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, RwLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use core_types::{
    AudioDeviceCapabilities, AudioDeviceDescription, AudioEngineOutputInfo, AudioFormat,
    ChannelLayout, CrossfeedConfig, DeviceTransportKind, DsdOutputMode,
    DspPipelineConfig as SharedDspConfig, OutputBackendKind, OutputMode, PeqBandConfig,
    PeqFilterKind, PlaybackEnginePolicy, ReplayGainConfig as SharedReplayGainConfig,
    ReplayGainMode as SharedReplayGainMode, SignalPath, UnifiedAudioFormat,
};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, HostId, SampleFormat, SizedSample};

use crate::buffer::{Consumer, Producer, SpscRingBuffer};
use crate::device_manager::{
    AudioDeviceManager, AudioFormatManager, DeviceExtraMeta, NegotiatedFormat,
};
use crate::dsd::{DopFramer, DsdStereoDecimator, DsdiffReader, DsfReader};
use crate::dsp::{
    BiquadCoefficients, DspPipeline, FilterType, ParametricBand, ReplayGain,
    ReplayGainConfig as InternalReplayGainConfig, ReplayGainMode as InternalReplayGainMode,
};
use crate::error::{BackendError, CoreAudioError, DspError};
use crate::pcm::{AudioChunk, AudioDecoder, DecodedTrackMetadata, SymphoniaDecoder, SynthAudioDecoder};
use crate::signal_path::{SignalPathContext, SignalPathEngine};
use crate::stream::{
    is_playlist_extension, looks_like_playlist_magic, resolve_playlist_url, HttpRangeMediaSource,
    StreamOrigin, StreamSource,
};
use crate::verification::{
    pack_chunk_to_wire_bytes, AudioVerificationEngine, VerificationConfig, WireSampleFormat,
};

const VIRTUAL_DEVICE_ID: &str = "virtual-exclusive-dac";
const VIRTUAL_DEVICE_NAME: &str = "Virtual Exclusive DAC";

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaybackLifecycleState {
    Uninitialized = 0,
    Stopped = 1,
    Playing = 2,
    Paused = 3,
    Error = 4,
    Loading = 5,
    Seeking = 6,
    Buffering = 7,
    Ended = 8,
}

impl PlaybackLifecycleState {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::Uninitialized,
            1 => Self::Stopped,
            2 => Self::Playing,
            3 => Self::Paused,
            4 => Self::Error,
            5 => Self::Loading,
            6 => Self::Seeking,
            7 => Self::Buffering,
            8 => Self::Ended,
            _ => Self::Error,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Uninitialized => "Uninitialized",
            Self::Stopped => "Stopped",
            Self::Playing => "Playing",
            Self::Paused => "Paused",
            Self::Error => "Error",
            Self::Loading => "Loading",
            Self::Seeking => "Seeking",
            Self::Buffering => "Buffering",
            Self::Ended => "Ended",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ActiveTrackMeta {
    pub path: PathBuf,
    pub source_label: String,
    pub format: AudioFormat,
    pub duration_ms: u64,
    pub resampled_to_hz: Option<u32>,
    pub backend: OutputBackendKind,
    pub device_name: String,
}

#[derive(Debug, Clone, Default)]
struct TrackReplayGainTags {
    track_db: Option<f64>,
    album_db: Option<f64>,
    track_peak: Option<f64>,
    album_peak: Option<f64>,
}

impl TrackReplayGainTags {
    fn from_stream(stream: &StreamSource) -> Self {
        Self {
            track_db: stream.replay_gain_track_db,
            album_db: stream.replay_gain_album_db,
            track_peak: stream.replay_gain_track_peak,
            album_peak: stream.replay_gain_album_peak,
        }
    }
}

enum PlayerCommand {
    Start {
        session_id: u64,
        decoder: Box<dyn AudioDecoder>,
        path: PathBuf,
        source_label: String,
        ack_tx: mpsc::SyncSender<Result<(), CoreAudioError>>,
    },
    FormatSwitchNext {
        session_id: u64,
        decoder: Box<dyn AudioDecoder>,
        path: PathBuf,
        source_label: String,
        rg_tags: TrackReplayGainTags,
    },
    RerouteOutput {
        ack_tx: mpsc::SyncSender<Result<(), CoreAudioError>>,
    },
    Pause,
    Resume,
    Stop,
    SeekMs,
    Shutdown,
}

struct PlayerInner {
    headless: bool,
    state_code: Arc<AtomicI32>,
    paused: AtomicBool,
    stopped: AtomicBool,
    volume_bits: AtomicU32,
    dsp_bypassed: AtomicBool,
    dsp_generation: AtomicU64,
    dsp_config: RwLock<SharedDspConfig>,
    track_replay_gain: RwLock<TrackReplayGainTags>,
    selected_output: RwLock<(Option<String>, Option<OutputBackendKind>)>,
    out_sample_rate: AtomicU32,
    duration_ms: AtomicU64,
    frames_rendered: Arc<AtomicU64>,
    nonzero_output_frames: Arc<AtomicU64>,
    current_session_id: Arc<AtomicU64>,
    seek_request_ms: AtomicI64,
    active_meta: RwLock<Option<ActiveTrackMeta>>,
    last_error: Arc<RwLock<Option<String>>>,
    policy: RwLock<PlaybackEnginePolicy>,
    saved_normal_dsp_bypass: AtomicBool,
    saved_normal_volume_bits: AtomicU32,
    verification: RwLock<Option<(AudioVerificationEngine, String, String)>>,
    queued_next: RwLock<Option<(StreamSource, String)>>,
    gapless_transitions: AtomicU64,
    format_reinit_count: AtomicU64,
    seek_epoch: AtomicU64,
    device_lost: Arc<AtomicBool>,
    is_seeking: AtomicBool,
}

fn default_shared_peq_bands() -> Vec<PeqBandConfig> {
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

fn default_shared_dsp_config() -> SharedDspConfig {
    SharedDspConfig {
        bypass: false,
        peq_bands: default_shared_peq_bands(),
        crossfeed: CrossfeedConfig::default(),
        replay_gain: SharedReplayGainConfig::default(),
    }
}

impl PlayerInner {
    fn new(headless: bool) -> Self {
        Self {
            headless,
            state_code: Arc::new(AtomicI32::new(PlaybackLifecycleState::Stopped as i32)),
            paused: AtomicBool::new(false),
            stopped: AtomicBool::new(true),
            volume_bits: AtomicU32::new((1.0f32).to_bits()),
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
            last_error: Arc::new(RwLock::new(None)),
            policy: RwLock::new(PlaybackEnginePolicy::default()),
            saved_normal_dsp_bypass: AtomicBool::new(false),
            saved_normal_volume_bits: AtomicU32::new((1.0f32).to_bits()),
            verification: RwLock::new(None),
            queued_next: RwLock::new(None),
            gapless_transitions: AtomicU64::new(0),
            format_reinit_count: AtomicU64::new(0),
            seek_epoch: AtomicU64::new(0),
            device_lost: Arc::new(AtomicBool::new(false)),
            is_seeking: AtomicBool::new(false),
        }
    }
}

/// Real streaming audio player supporting Symphonia PCM, HTTP/HTTPS range-buffered streams,
/// DSF/DSDIFF DSD decimation, 64-bit float DSP with live reconfiguration & one-click bypass,
/// lock-free SPSC ring buffering, and `cpal` device enumeration & output.
#[derive(Clone)]
pub struct AudioPlayer {
    inner: Arc<PlayerInner>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
}

impl std::fmt::Debug for AudioPlayer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AudioPlayer")
            .field("headless", &self.inner.headless)
            .field("state_code", &self.state_code())
            .finish()
    }
}

impl Default for AudioPlayer {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioPlayer {
    /// Creates an audio player bound to the host's real audio output device (`cpal`),
    /// falling back gracefully to a paced virtual output consumer if no device is available.
    pub fn new() -> Self {
        Self::create(false)
    }

    /// Creates a deterministic headless player that runs the full decode, DSP, and SPSC
    /// ring-buffer pipeline into a paced virtual DAC consumer without touching physical speakers.
    pub fn new_headless() -> Self {
        Self::create(true)
    }

    fn create(headless: bool) -> Self {
        let inner = Arc::new(PlayerInner::new(headless));
        let (cmd_tx, cmd_rx) = mpsc::channel();
        let coord_inner = Arc::clone(&inner);
        let coord_tx = cmd_tx.clone();

        thread::Builder::new()
            .name("lumina-audio-coordinator".to_string())
            .spawn(move || coordinator_loop(coord_inner, cmd_rx, coord_tx))
            .expect("spawn audio coordinator thread");

        Self { inner, cmd_tx }
    }

    /// Opens a `StreamSource` (local file or HTTP/HTTPS stream), probes codec/container headers,
    /// stores ReplayGain tags, and starts streaming playback.
    pub fn play_stream(
        &self,
        stream: StreamSource,
        source_label: &str,
    ) -> Result<(), CoreAudioError> {
        let decoder = open_decoder_for_stream(&stream)?;
        let label = if source_label.trim().is_empty() {
            "Stream".to_string()
        } else {
            source_label.to_string()
        };
        let path_buf = stream.display_path();
        let format = decoder.format().clone();
        let duration_ms = decoder
            .duration()
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);

        if let Ok(mut q) = self.inner.queued_next.write() {
            *q = None;
        }
        if let Ok(mut rg_lock) = self.inner.track_replay_gain.write() {
            *rg_lock = TrackReplayGainTags::from_stream(&stream);
        }
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);

        let session_id = self
            .inner
            .current_session_id
            .fetch_add(1, Ordering::SeqCst)
            + 1;

        self.inner.duration_ms.store(duration_ms, Ordering::SeqCst);
        self.inner.stopped.store(false, Ordering::SeqCst);
        self.inner.paused.store(false, Ordering::SeqCst);
        self.inner.frames_rendered.store(0, Ordering::SeqCst);
        self.inner.nonzero_output_frames.store(0, Ordering::SeqCst);
        self.inner.seek_request_ms.store(-1, Ordering::SeqCst);
        if let Ok(mut err_lock) = self.inner.last_error.write() {
            *err_lock = None;
        }
        self.inner
            .state_code
            .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);

        let (preview_backend, preview_device) = self.preview_output_target();
        if let Ok(mut meta_lock) = self.inner.active_meta.write() {
            *meta_lock = Some(ActiveTrackMeta {
                path: path_buf.clone(),
                source_label: label.clone(),
                format,
                duration_ms,
                resampled_to_hz: None,
                backend: preview_backend,
                device_name: preview_device,
            });
        }

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::Start {
                session_id,
                decoder,
                path: path_buf,
                source_label: label,
                ack_tx,
            })
            .is_err()
        {
            let msg = "Audio coordinator thread is shut down".to_string();
            if let Ok(mut err_lock) = self.inner.last_error.write() {
                *err_lock = Some(msg.clone());
            }
            self.inner.stopped.store(true, Ordering::SeqCst);
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
            return Err(CoreAudioError::Backend(BackendError::InvalidState(msg)));
        }

        match ack_rx.recv() {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => {
                if let Ok(mut err_lock) = self.inner.last_error.write() {
                    *err_lock = Some(e.to_string());
                }
                self.inner.stopped.store(true, Ordering::SeqCst);
                self.inner
                    .state_code
                    .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
                Err(e)
            }
            Err(_) => {
                let msg = "Audio coordinator failed to acknowledge stream start".to_string();
                if let Ok(mut err_lock) = self.inner.last_error.write() {
                    *err_lock = Some(msg.clone());
                }
                self.inner.stopped.store(true, Ordering::SeqCst);
                self.inner
                    .state_code
                    .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
                Err(CoreAudioError::Backend(BackendError::DriverError(msg)))
            }
        }
    }

    /// Opens `path`, probes codec/container headers, and starts streaming playback.
    pub fn play_file(
        &self,
        path: impl AsRef<Path>,
        source_label: Option<String>,
    ) -> Result<(), CoreAudioError> {
        let stream = StreamSource::local_file(path.as_ref());
        let label = source_label.as_deref().unwrap_or("Local Library");
        self.play_stream(stream, label)
    }

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

    pub fn pause(&self) {
        self.inner.paused.store(true, Ordering::SeqCst);
        let cur = self.state_code();
        if cur == PlaybackLifecycleState::Playing as i32
            || cur == PlaybackLifecycleState::Seeking as i32
            || cur == PlaybackLifecycleState::Buffering as i32
        {
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
        }
        let _ = self.cmd_tx.send(PlayerCommand::Pause);
    }

    pub fn resume(&self) {
        self.inner.paused.store(false, Ordering::SeqCst);
        let cur = self.state_code();
        if cur == PlaybackLifecycleState::Paused as i32
            || cur == PlaybackLifecycleState::Seeking as i32
        {
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);
        }
        let _ = self.cmd_tx.send(PlayerCommand::Resume);
    }

    pub fn stop(&self) {
        self.inner.stopped.store(true, Ordering::SeqCst);
        self.inner.paused.store(false, Ordering::SeqCst);
        self.inner.frames_rendered.store(0, Ordering::SeqCst);
        self.inner
            .state_code
            .store(PlaybackLifecycleState::Stopped as i32, Ordering::SeqCst);
        let _ = self.cmd_tx.send(PlayerCommand::Stop);
    }

    pub fn seek_ms(&self, pos_ms: u64) {
        let dur = self.duration_ms();
        let clamped = if dur > 0 { pos_ms.min(dur) } else { pos_ms };
        let rate = self.inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
        let target_frames = ((clamped as u128) * rate / 1000) as u64;
        self.inner.seek_epoch.fetch_add(1, Ordering::SeqCst);
        self.inner.is_seeking.store(true, Ordering::SeqCst);
        let cur_state = self.inner.state_code.load(Ordering::SeqCst);
        if !self.inner.paused.load(Ordering::SeqCst)
            && cur_state == PlaybackLifecycleState::Playing as i32
        {
            self.inner
                .state_code
                .store(PlaybackLifecycleState::Seeking as i32, Ordering::SeqCst);
        }
        self.inner
            .seek_request_ms
            .store(clamped as i64, Ordering::SeqCst);
        self.inner
            .frames_rendered
            .store(target_frames, Ordering::SeqCst);
        let _ = self.cmd_tx.send(PlayerCommand::SeekMs);
    }

    pub fn set_volume(&self, vol: f32) {
        let clamped = if vol.is_nan() { 0.0 } else { vol.clamp(0.0, 1.0) };
        self.inner
            .saved_normal_volume_bits
            .store(clamped.to_bits(), Ordering::Relaxed);
        if self.is_strict_bit_perfect() {
            self.inner
                .volume_bits
                .store((1.0f32).to_bits(), Ordering::Relaxed);
            return;
        }
        self.inner
            .volume_bits
            .store(clamped.to_bits(), Ordering::Relaxed);
    }

    pub fn volume(&self) -> f32 {
        if self.is_strict_bit_perfect() {
            return 1.0;
        }
        f32::from_bits(self.inner.volume_bits.load(Ordering::Relaxed))
    }

    pub fn is_strict_bit_perfect(&self) -> bool {
        self.inner
            .policy
            .read()
            .map(|p| p.strict_bit_perfect)
            .unwrap_or(false)
    }

    pub fn engine_policy(&self) -> PlaybackEnginePolicy {
        self.inner
            .policy
            .read()
            .map(|p| p.clone())
            .unwrap_or_default()
    }

    pub fn set_allow_shared_fallback(&self, allow: bool) {
        if let Ok(mut p) = self.inner.policy.write() {
            p.allow_shared_fallback = allow;
        }
    }

    pub fn set_strict_bit_perfect(&self, enabled: bool) -> Result<(), CoreAudioError> {
        let prev = self.is_strict_bit_perfect();
        if let Ok(mut p) = self.inner.policy.write() {
            p.strict_bit_perfect = enabled;
        }
        if !prev && enabled {
            let cur_bypass = self.inner.dsp_bypassed.load(Ordering::SeqCst);
            self.inner
                .saved_normal_dsp_bypass
                .store(cur_bypass, Ordering::SeqCst);
            let cur_vol = self.inner.volume_bits.load(Ordering::Relaxed);
            self.inner
                .saved_normal_volume_bits
                .store(cur_vol, Ordering::Relaxed);

            self.inner.dsp_bypassed.store(true, Ordering::SeqCst);
            if let Ok(mut guard) = self.inner.dsp_config.write() {
                guard.bypass = true;
            }
            self.inner
                .volume_bits
                .store((1.0f32).to_bits(), Ordering::Relaxed);
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        } else if prev && !enabled {
            let restored_bypass = self.inner.saved_normal_dsp_bypass.load(Ordering::SeqCst);
            let restored_vol = self.inner.saved_normal_volume_bits.load(Ordering::Relaxed);
            self.inner
                .dsp_bypassed
                .store(restored_bypass, Ordering::SeqCst);
            if let Ok(mut guard) = self.inner.dsp_config.write() {
                guard.bypass = restored_bypass;
            }
            self.inner
                .volume_bits
                .store(restored_vol, Ordering::Relaxed);
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        }

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput { ack_tx })
            .is_ok()
        {
            ack_rx.recv().unwrap_or(Ok(()))
        } else {
            Ok(())
        }
    }

    pub fn set_dsd_output_mode(&self, mode: DsdOutputMode) -> Result<(), CoreAudioError> {
        if let Ok(mut p) = self.inner.policy.write() {
            p.dsd_output_mode = mode;
        }
        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput { ack_tx })
            .is_ok()
        {
            ack_rx.recv().unwrap_or(Ok(()))
        } else {
            Ok(())
        }
    }

    pub fn preferred_buffer_frames(&self) -> u32 {
        self.inner
            .policy
            .read()
            .map(|p| p.preferred_buffer_frames)
            .unwrap_or(512)
    }

    pub fn set_preferred_buffer_frames(&self, frames: u32) -> Result<(), CoreAudioError> {
        let clamped = frames.clamp(32, 32768);
        if let Ok(mut p) = self.inner.policy.write() {
            p.preferred_buffer_frames = clamped;
        }
        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput { ack_tx })
            .is_ok()
        {
            ack_rx.recv().unwrap_or(Ok(()))
        } else {
            Ok(())
        }
    }

    pub fn list_device_capabilities(&self) -> Vec<AudioDeviceCapabilities> {
        self.list_device_capabilities_with_meta()
            .into_iter()
            .map(|(cap, _)| cap)
            .collect()
    }

    pub fn list_device_capabilities_with_meta(&self) -> Vec<(AudioDeviceCapabilities, DeviceExtraMeta)> {
        let mut caps = if self.inner.headless {
            vec![(
                AudioDeviceManager::virtual_device_capabilities(),
                DeviceExtraMeta {
                    is_os_default: true,
                    is_hdmi: false,
                    hardware_supports_exclusive: true,
                    buffer_size_supported: true,
                    min_buffer_frames: Some(64),
                    max_buffer_frames: Some(4096),
                    default_buffer_frames: Some(512),
                    buffer_granularity: None,
                },
            )]
        } else {
            AudioDeviceManager::list_devices_with_meta()
        };
        if caps.is_empty() {
            caps.push((
                AudioDeviceManager::virtual_device_capabilities(),
                DeviceExtraMeta::default(),
            ));
        }
        caps
    }

    pub fn output_info(&self) -> AudioEngineOutputInfo {
        if let Ok(g) = self.inner.verification.read()
            && let Some((ref engine, ref api, ref dev)) = *g
        {
            return engine.snapshot(api, dev);
        }

        let mut info = AudioEngineOutputInfo::default();
        let (sel_id, sel_backend) = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));
        let caps = resolve_target_capabilities(&self.inner, sel_id.as_deref(), sel_backend);
        let (backend, dev_name) = self.preview_output_target();
        let policy = self.engine_policy();
        let is_shared = backend == OutputBackendKind::WindowsWasapiShared;
        info.output.selected_device = dev_name;
        info.output.transport_kind = caps.transport.label_zh().to_string();
        info.output.audio_api = format!("{backend:?}");
        info.output.buffer_size_frames = policy.preferred_buffer_frames;
        info.output.output_mode = if is_shared {
            "WASAPI Shared (Idle)".to_string()
        } else if policy.strict_bit_perfect {
            "Strict Bit-Perfect Armed (Idle)".to_string()
        } else {
            "Idle".to_string()
        };
        info.output.dsp_status = if self.is_dsp_bypassed() {
            "Bypassed".to_string()
        } else {
            "Enabled".to_string()
        };
        info.output.software_volume_status =
            if policy.strict_bit_perfect || (self.volume() - 1.0).abs() < 1e-6 {
                "Disabled (Unity 1.0x)".to_string()
            } else {
                "Active Attenuated".to_string()
            };
        info.output.strict_mode = !is_shared && policy.strict_bit_perfect;
        info.output.hardware_volume_recommended = !is_shared && policy.strict_bit_perfect;
        info
    }

    pub fn get_dsp_config(&self) -> SharedDspConfig {
        let mut cfg = self
            .inner
            .dsp_config
            .read()
            .map(|g| g.clone())
            .unwrap_or_else(|_| default_shared_dsp_config());
        cfg.bypass = self.is_dsp_bypassed();
        cfg
    }

    pub fn set_dsp_config(&self, mut config: SharedDspConfig) -> Result<(), CoreAudioError> {
        validate_shared_dsp_config(&config)?;
        self.inner
            .saved_normal_dsp_bypass
            .store(config.bypass, Ordering::SeqCst);
        if self.is_strict_bit_perfect() {
            // Preserve user's preset bands, but enforce hard bypass while Strict Mode is active
            config.bypass = true;
            self.inner.dsp_bypassed.store(true, Ordering::SeqCst);
        } else {
            self.inner
                .dsp_bypassed
                .store(config.bypass, Ordering::SeqCst);
        }
        if let Ok(mut guard) = self.inner.dsp_config.write() {
            *guard = config;
        }
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    pub fn set_dsp_bypass(&self, bypass: bool) {
        self.inner
            .saved_normal_dsp_bypass
            .store(bypass, Ordering::SeqCst);
        let effective = if self.is_strict_bit_perfect() {
            true
        } else {
            bypass
        };
        self.inner.dsp_bypassed.store(effective, Ordering::SeqCst);
        if let Ok(mut guard) = self.inner.dsp_config.write() {
            guard.bypass = effective;
        }
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
    }

    pub fn toggle_dsp_bypass(&self) -> bool {
        if self.is_strict_bit_perfect() {
            // Strict Mode enforces hard bypass; toggling DSP bypass leaves Strict Mode locked
            self.inner.dsp_bypassed.store(true, Ordering::SeqCst);
            return true;
        }
        let prev = self.inner.dsp_bypassed.fetch_xor(true, Ordering::SeqCst);
        let new_val = !prev;
        self.inner
            .saved_normal_dsp_bypass
            .store(new_val, Ordering::SeqCst);
        if let Ok(mut guard) = self.inner.dsp_config.write() {
            guard.bypass = new_val;
        }
        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        new_val
    }

    pub fn is_dsp_bypassed(&self) -> bool {
        self.inner.dsp_bypassed.load(Ordering::SeqCst)
    }

    pub fn list_output_devices(&self) -> Vec<AudioDeviceDescription> {
        let mut devices = Vec::new();
        if !self.inner.headless {
            for cap in AudioDeviceManager::list_devices() {
                if cap.backend == OutputBackendKind::WindowsAsio && !cap.asio_available {
                    continue;
                }
                if !devices
                    .iter()
                    .any(|d: &AudioDeviceDescription| d.id == cap.device_id && d.backend == cap.backend)
                {
                    devices.push(AudioDeviceDescription {
                        id: cap.device_id,
                        name: cap.name,
                        backend: cap.backend,
                        is_default: cap.is_default,
                        is_exclusive: cap.is_exclusive,
                        supported_sample_rates: cap.supported_sample_rates,
                        supported_bit_depths: cap.supported_bit_depths,
                        supports_native_dsd: cap.supports_native_dsd,
                    });
                }
            }
            if devices.is_empty() {
                devices = enumerate_cpal_devices();
            }
        }
        if self.inner.headless || devices.is_empty() {
            let has_virtual = devices.iter().any(|d| d.id == VIRTUAL_DEVICE_ID);
            if !has_virtual {
                devices.push(virtual_exclusive_device(devices.is_empty()));
            }
        }
        devices
    }

    pub fn select_output_device(
        &self,
        device_id: Option<&str>,
        backend: Option<OutputBackendKind>,
    ) -> Result<(), CoreAudioError> {
        let clean_id = device_id
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != "__system_output__")
            .map(str::to_string);

        let effective_backend = backend.or_else(|| {
            clean_id.as_deref().and_then(|id| {
                if id.starts_with("wasapi-shared::") {
                    Some(OutputBackendKind::WindowsWasapiShared)
                } else if id.starts_with("asio::") {
                    Some(OutputBackendKind::WindowsAsio)
                } else {
                    None
                }
            })
        });

        if clean_id.as_deref() == Some(VIRTUAL_DEVICE_ID) {
            if !self.inner.headless && !self.list_output_devices().iter().all(|d| d.id == VIRTUAL_DEVICE_ID) {
                return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
                    VIRTUAL_DEVICE_ID.to_string(),
                )));
            }
        } else if let Some(ref id) = clean_id {
            let available = self.list_output_devices();
            let caps = self.list_device_capabilities();
            let raw_id = AudioDeviceManager::strip_mode_prefix(id);
            let matched_cap = caps.iter().find(|c| {
                let id_match = c.device_id == *id
                    || AudioDeviceManager::strip_mode_prefix(&c.device_id) == raw_id
                    || c.name == *id;
                let bk_match = effective_backend.is_none_or(|bk| c.backend == bk);
                id_match && bk_match
            });

            if let Some(cap) = matched_cap {
                if cap.backend == OutputBackendKind::WindowsAsio && !cap.asio_available {
                    return Err(CoreAudioError::Backend(BackendError::DriverError(
                        cap.probe_note.clone().unwrap_or_else(|| {
                            format!("ASIO driver '{}' is offline or hardware disconnected", cap.name)
                        }),
                    )));
                }
                if cap.backend == OutputBackendKind::WindowsWasapiExclusive && !cap.exclusive_available {
                    return Err(CoreAudioError::Backend(BackendError::DeviceInUse));
                }
            } else if !available.iter().any(|d| {
                let id_match = d.id == *id || AudioDeviceManager::strip_mode_prefix(&d.id) == raw_id;
                let bk_match = effective_backend.is_none_or(|bk| d.backend == bk);
                id_match && bk_match
            }) {
                return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
                    id.clone(),
                )));
            }
        }

        let previous = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));
        let prev_strict = self.is_strict_bit_perfect();
        let prev_bypass = self.inner.dsp_bypassed.load(Ordering::SeqCst);
        let prev_vol_bits = self.inner.volume_bits.load(Ordering::Relaxed);

        if let Ok(mut guard) = self.inner.selected_output.write() {
            *guard = (clean_id, effective_backend);
        }

        // Switching to explicit WASAPI Shared clears Strict Bit-Perfect Mode before a single
        // RerouteOutput so Shared playback immediately restores normal volume/DSP rules.
        let cleared_strict_for_shared =
            effective_backend == Some(OutputBackendKind::WindowsWasapiShared) && prev_strict;
        if cleared_strict_for_shared {
            if let Ok(mut p) = self.inner.policy.write() {
                p.strict_bit_perfect = false;
            }
            let restored_bypass = self.inner.saved_normal_dsp_bypass.load(Ordering::SeqCst);
            let restored_vol = self.inner.saved_normal_volume_bits.load(Ordering::Relaxed);
            self.inner
                .dsp_bypassed
                .store(restored_bypass, Ordering::SeqCst);
            if let Ok(mut guard) = self.inner.dsp_config.write() {
                guard.bypass = restored_bypass;
            }
            self.inner
                .volume_bits
                .store(restored_vol, Ordering::Relaxed);
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
        }

        self.inner.device_lost.store(false, Ordering::SeqCst);
        let state = self.inner.state_code.load(Ordering::SeqCst);
        let is_active_stream = !self.inner.stopped.load(Ordering::SeqCst)
            && (state == PlaybackLifecycleState::Playing as i32
                || state == PlaybackLifecycleState::Paused as i32);
        if !is_active_stream {
            if let Ok(mut vw) = self.inner.verification.write() {
                *vw = None;
            }
            if let Ok(mut meta_lock) = self.inner.active_meta.write() {
                *meta_lock = None;
            }
        }

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput { ack_tx })
            .is_ok()
        {
            match ack_rx.recv() {
                Ok(Ok(())) => Ok(()),
                Ok(Err(e)) => {
                    if let Ok(mut guard) = self.inner.selected_output.write() {
                        *guard = previous;
                    }
                    if cleared_strict_for_shared {
                        if let Ok(mut p) = self.inner.policy.write() {
                            p.strict_bit_perfect = prev_strict;
                        }
                        self.inner.dsp_bypassed.store(prev_bypass, Ordering::SeqCst);
                        if let Ok(mut guard) = self.inner.dsp_config.write() {
                            guard.bypass = prev_bypass;
                        }
                        self.inner
                            .volume_bits
                            .store(prev_vol_bits, Ordering::Relaxed);
                        self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
                    }
                    Err(e)
                }
                Err(_) => Ok(()),
            }
        } else {
            Ok(())
        }
    }

    fn preview_output_target(&self) -> (OutputBackendKind, String) {
        let (sel_id, sel_backend) = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));

        if self.inner.headless || sel_id.as_deref() == Some(VIRTUAL_DEVICE_ID) {
            return (
                sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
                VIRTUAL_DEVICE_NAME.to_string(),
            );
        }

        let caps = resolve_target_capabilities(&self.inner, sel_id.as_deref(), sel_backend);
        if sel_id.is_some() {
            return (sel_backend.unwrap_or(caps.backend), caps.name);
        }

        // System Output: follows OS default endpoint and reflects active engine routing mode
        let policy = self.engine_policy();
        let bypassed = self.is_dsp_bypassed();
        let eff_backend = if let Some(bk) = sel_backend {
            bk
        } else if (policy.strict_bit_perfect || bypassed) && caps.exclusive_available {
            OutputBackendKind::WindowsWasapiExclusive
        } else {
            OutputBackendKind::WindowsWasapiShared
        };
        (eff_backend, caps.name)
    }

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
        let (sel_id, sel_backend) = self
            .inner
            .selected_output
            .read()
            .map(|g| g.clone())
            .unwrap_or((None, None));
        let caps = resolve_target_capabilities(&self.inner, sel_id.as_deref(), sel_backend);
        if caps.backend == OutputBackendKind::WindowsAsio {
            "asio_hardware"
        } else if caps.backend == OutputBackendKind::WindowsWasapiExclusive {
            "wasapi_hardware"
        } else {
            "stream_frames"
        }
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
        self.inner.duration_ms.load(Ordering::Relaxed)
    }

    pub fn nonzero_output_frames(&self) -> u64 {
        self.inner.nonzero_output_frames.load(Ordering::Relaxed)
    }

    pub fn last_error(&self) -> Option<String> {
        self.inner
            .last_error
            .read()
            .ok()
            .and_then(|g| g.clone())
    }

    pub fn take_last_error(&self) -> Option<String> {
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

    pub fn shutdown(&self) {
        self.stop();
        let _ = self.cmd_tx.send(PlayerCommand::Shutdown);
    }
}

fn map_filter_kind(kind: PeqFilterKind) -> FilterType {
    match kind {
        PeqFilterKind::Peaking => FilterType::Peaking,
        PeqFilterKind::LowShelf => FilterType::LowShelf,
        PeqFilterKind::HighShelf => FilterType::HighShelf,
        PeqFilterKind::LowPass => FilterType::LowPass,
        PeqFilterKind::HighPass => FilterType::HighPass,
    }
}

fn validate_shared_dsp_config(cfg: &SharedDspConfig) -> Result<(), CoreAudioError> {
    if !cfg.replay_gain.preamp_db.is_finite() || cfg.replay_gain.preamp_db.abs() > 60.0 {
        return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
            format!("ReplayGain preamp out of bounds: {}", cfg.replay_gain.preamp_db),
        )));
    }
    for band in &cfg.peq_bands {
        if !band.frequency_hz.is_finite()
            || band.frequency_hz <= 0.0
            || band.frequency_hz > 100_000.0
        {
            return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
                format!("PEQ frequency out of bounds: {}", band.frequency_hz),
            )));
        }
        if !band.q_factor.is_finite() || band.q_factor <= 0.0 || band.q_factor > 100.0 {
            return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
                format!("PEQ Q factor out of bounds: {}", band.q_factor),
            )));
        }
        if !band.gain_db.is_finite() || band.gain_db.abs() > 60.0 {
            return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
                format!("PEQ gain out of bounds (+/-60dB): {}", band.gain_db),
            )));
        }
        BiquadCoefficients::compute(
            map_filter_kind(band.filter_type),
            48_000.0,
            band.frequency_hz,
            band.gain_db,
            band.q_factor,
        )?;
    }
    Ok(())
}

fn to_parametric_bands(bands: &[PeqBandConfig]) -> Vec<ParametricBand> {
    bands
        .iter()
        .map(|b| ParametricBand {
            filter_type: map_filter_kind(b.filter_type),
            frequency_hz: b.frequency_hz,
            gain_db: b.gain_db,
            q_factor: b.q_factor,
            enabled: b.enabled,
        })
        .collect()
}

fn to_internal_replay_gain(
    cfg: &SharedReplayGainConfig,
    tags: &TrackReplayGainTags,
) -> InternalReplayGainConfig {
    match cfg.mode {
        SharedReplayGainMode::Off => InternalReplayGainConfig {
            mode: InternalReplayGainMode::Track,
            preamp_db: 0.0,
            track_gain_db: None,
            track_peak: None,
            album_gain_db: None,
            album_peak: None,
            prevent_clipping: false,
        },
        SharedReplayGainMode::Track => InternalReplayGainConfig {
            mode: InternalReplayGainMode::Track,
            preamp_db: cfg.preamp_db,
            track_gain_db: tags.track_db,
            track_peak: tags.track_peak,
            album_gain_db: tags.album_db,
            album_peak: tags.album_peak,
            prevent_clipping: cfg.prevent_clipping,
        },
        SharedReplayGainMode::Album => InternalReplayGainConfig {
            mode: InternalReplayGainMode::Album,
            preamp_db: cfg.preamp_db,
            track_gain_db: tags.track_db,
            track_peak: tags.track_peak,
            album_gain_db: tags.album_db,
            album_peak: tags.album_peak,
            prevent_clipping: cfg.prevent_clipping,
        },
    }
}

fn compute_effective_replay_gain_db(
    cfg: &SharedReplayGainConfig,
    tags: &TrackReplayGainTags,
) -> Option<f64> {
    if cfg.mode == SharedReplayGainMode::Off {
        return None;
    }
    let internal = to_internal_replay_gain(cfg, tags);
    let rg = ReplayGain::new(internal);
    let linear = rg.linear_gain();
    if (linear - 1.0).abs() > 1e-6 {
        Some(20.0 * linear.log10())
    } else {
        None
    }
}

pub fn open_decoder_for_path(path: &Path) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    match ext.as_str() {
        "dsf" => {
            let file = File::open(path)?;
            let reader = DsfReader::new(file)?;
            Ok(Box::new(reader))
        }
        "dff" | "dsdiff" => {
            let file = File::open(path)?;
            let reader = DsdiffReader::new(file)?;
            Ok(Box::new(reader))
        }
        _ => {
            let decoder = SymphoniaDecoder::from_file(path)?;
            Ok(Box::new(decoder))
        }
    }
}

fn infer_extension_from_url(url: &str) -> Option<String> {
    let without_frag = url.split('#').next().unwrap_or(url);
    let without_query = without_frag.split('?').next().unwrap_or(without_frag);
    let last_seg = without_query.rsplit('/').next()?;
    let dot_idx = last_seg.rfind('.')?;
    let ext = &last_seg[dot_idx + 1..];
    if (1..=6).contains(&ext.len()) && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        Some(ext.to_ascii_lowercase())
    } else {
        None
    }
}

pub fn infer_extension_from_magic(magic: &[u8]) -> Option<&'static str> {
    if magic.starts_with(b"fLaC") {
        Some("flac")
    } else if magic.len() >= 12 && &magic[0..4] == b"RIFF" && &magic[8..12] == b"WAVE" {
        Some("wav")
    } else if magic.starts_with(b"FORM") {
        Some("aiff")
    } else if magic.starts_with(b"OggS") {
        Some("ogg")
    } else if magic.len() >= 2 && magic[0] == 0xFF && (magic[1] & 0xF6) == 0xF0 {
        Some("aac")
    } else if magic.starts_with(b"ID3")
        || (magic.len() >= 2 && magic[0] == 0xFF && (magic[1] & 0xE0) == 0xE0 && (magic[1] & 0x06) != 0)
    {
        Some("mp3")
    } else if magic.len() >= 8 && &magic[4..8] == b"ftyp" {
        Some("m4a")
    } else {
        None
    }
}

pub fn open_decoder_for_stream(stream: &StreamSource) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    match &stream.origin {
        StreamOrigin::LocalFile(path) => open_decoder_for_path(path),
        StreamOrigin::Http { url, headers } => {
            let mut media = HttpRangeMediaSource::open(url, headers)?;
            let mut magic = media.read_magic_prefix(32)?;
            if looks_like_playlist_magic(&magic) {
                let resolved = resolve_playlist_url(media.resolved_url(), headers)?;
                media = HttpRangeMediaSource::open(&resolved, headers)?;
                magic = media.read_magic_prefix(32)?;
            }

            let ext_hint = stream
                .hint_extension
                .clone()
                .filter(|ext| !is_playlist_extension(ext))
                .or_else(|| {
                    infer_extension_from_url(media.resolved_url())
                        .filter(|ext| !is_playlist_extension(ext))
                })
                .or_else(|| infer_extension_from_magic(&magic).map(str::to_string));

            if magic.starts_with(b"DSD ") || ext_hint.as_deref() == Some("dsf") {
                let reader = DsfReader::new(media)?;
                return Ok(Box::new(reader));
            }
            if (magic.len() >= 12 && &magic[0..4] == b"FRM8" && &magic[8..12] == b"DSD ")
                || matches!(ext_hint.as_deref(), Some("dff" | "dsdiff"))
            {
                let reader = DsdiffReader::new(media)?;
                return Ok(Box::new(reader));
            }

            let content_type = media.content_type().map(str::to_string);
            let decoder = SymphoniaDecoder::from_media_source(
                Box::new(media),
                ext_hint.as_deref(),
                content_type.as_deref(),
            )?;
            Ok(Box::new(decoder))
        }
        StreamOrigin::Synth {
            track_id,
            title,
            duration_ms,
            sample_rate_hz,
            channels,
        } => Ok(Box::new(SynthAudioDecoder::new(
            track_id,
            title,
            *duration_ms,
            *sample_rate_hz,
            *channels,
        ))),
    }
}

enum NativeOutputSession {
    #[cfg(target_os = "windows")]
    WasapiExclusive(crate::backend::wasapi_win::WasapiExclusiveSession),
    #[cfg(target_os = "windows")]
    AsioNative(crate::backend::asio_win::AsioNativeSession),
    VirtualWire(JoinHandle<()>),
}

impl NativeOutputSession {
    fn set_paused(&self, paused: bool) {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.set_paused(paused),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.set_paused(paused),
            Self::VirtualWire(_) => {}
        }
    }

    fn flush(&self) -> Result<(), BackendError> {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.flush(),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => {
                if s.flush() {
                    Ok(())
                } else {
                    Err(BackendError::DriverError("ASIO flush failed".into()))
                }
            }
            Self::VirtualWire(_) => Ok(()),
        }
    }

    #[allow(dead_code)]
    fn is_device_lost(&self) -> bool {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.is_device_lost(),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.is_device_lost(),
            Self::VirtualWire(_) => false,
        }
    }

    fn set_eof_state_code(&self, code: i32) {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.set_eof_state_code(code),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.set_eof_target_state(code),
            Self::VirtualWire(_) => {}
        }
    }

    fn stop_and_join(self) {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.stop(),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.stop(),
            Self::VirtualWire(h) => {
                let _ = h.join();
            }
        }
    }
}

struct ActiveSession {
    cancel_flag: Arc<AtomicBool>,
    eof_flag: Arc<AtomicBool>,
    decode_handle: Option<JoinHandle<Option<Box<dyn AudioDecoder>>>>,
    virtual_handle: Option<JoinHandle<()>>,
    _cpal_stream: Option<cpal::Stream>,
    native_output: Option<NativeOutputSession>,
    path: PathBuf,
    source_label: String,
    format: AudioFormat,
    duration_ms: u64,
    pcm_rate: u32,
}

impl ActiveSession {
    fn stop_and_join(&mut self) -> Option<Box<dyn AudioDecoder>> {
        self.cancel_flag.store(true, Ordering::SeqCst);
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
        self.decode_handle
            .take()
            .and_then(|h| h.join().ok().flatten())
    }
}

impl Drop for ActiveSession {
    fn drop(&mut self) {
        let _ = self.stop_and_join();
    }
}

fn position_ms_from_inner(inner: &PlayerInner) -> u64 {
    let rate = inner.out_sample_rate.load(Ordering::Relaxed) as u128;
    if rate == 0 {
        return 0;
    }
    let frames = inner.frames_rendered.load(Ordering::Relaxed) as u128;
    ((frames * 1000) / rate) as u64
}

/// Seek inside a running decode thread: drop everything already queued in the ring
/// (the output side discards pre-flush data on its next pop), move the decoder, and
/// re-pin the playback clock to the target so frames popped before the flush don't skew it.
#[allow(dead_code)]
fn flush_ring_and_seek<T: Copy>(
    decoder: &mut dyn AudioDecoder,
    producer: &mut Producer<T>,
    inner: &PlayerInner,
    target_ms: u64,
) {
    producer.request_flush();
    producer.sync_epoch();
    if let Err(e) = decoder.seek(Duration::from_millis(target_ms)) {
        tracing::warn!("Decoder seek to {target_ms} ms failed: {e}");
    }
    let rate = inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
    inner
        .frames_rendered
        .store(((target_ms as u128) * rate / 1000) as u64, Ordering::SeqCst);
}

/// Called when the decoder hits end of stream. The buffered tail may still be playing, so
/// keep the thread (and decoder) alive until a seek, a queued next track, cancel or stop.
/// Returns `true` if decoding should continue (seek or queued track), `false` to exit.
fn wait_at_eof(inner: &PlayerInner, cancel_flag: &AtomicBool, eof_flag: &AtomicBool) -> bool {
    eof_flag.store(true, Ordering::SeqCst);
    loop {
        if cancel_flag.load(Ordering::Relaxed) || inner.stopped.load(Ordering::Relaxed) {
            return false;
        }
        // Output finished draining the tail: the coordinator owns any later seek (it
        // restarts the pipeline), so this thread is done.
        let state = inner.state_code.load(Ordering::SeqCst);
        if state != PlaybackLifecycleState::Playing as i32
            && state != PlaybackLifecycleState::Paused as i32
            && state != PlaybackLifecycleState::Seeking as i32
        {
            return false;
        }
        let has_next = inner
            .queued_next
            .read()
            .map(|g| g.is_some())
            .unwrap_or(false);
        if inner.seek_request_ms.load(Ordering::SeqCst) >= 0 || has_next {
            eof_flag.store(false, Ordering::SeqCst);
            return true;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn record_playback_error(inner: &PlayerInner, msg: String) {
    let lower = msg.to_ascii_lowercase();
    if lower.contains("device") || lower.contains("invalidated") {
        inner.device_lost.store(true, Ordering::SeqCst);
    }
    if let Ok(mut err_lock) = inner.last_error.write() {
        *err_lock = Some(msg);
    }
    inner.stopped.store(true, Ordering::SeqCst);
    inner
        .state_code
        .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
}

struct PipelineSpec {
    session_id: u64,
    pcm_rate: u32,
    out_channels: u16,
    path: PathBuf,
    source_label: String,
    format: AudioFormat,
    duration_ms: u64,
    start_paused: bool,
}

fn resolve_target_capabilities(
    inner: &PlayerInner,
    sel_id: Option<&str>,
    sel_backend: Option<OutputBackendKind>,
) -> AudioDeviceCapabilities {
    if inner.headless || sel_id == Some(VIRTUAL_DEVICE_ID) {
        return AudioDeviceManager::virtual_device_capabilities();
    }
    let caps = AudioDeviceManager::list_devices();
    if caps.is_empty() {
        return AudioDeviceManager::virtual_device_capabilities();
    }

    let eff_backend = sel_backend.or_else(|| {
        sel_id.and_then(|s| {
            if s.starts_with("wasapi-shared::") {
                Some(OutputBackendKind::WindowsWasapiShared)
            } else if s.starts_with("asio::") {
                Some(OutputBackendKind::WindowsAsio)
            } else {
                None
            }
        })
    });

    if eff_backend == Some(OutputBackendKind::WindowsAsio)
        || sel_id.is_some_and(|s| s.starts_with("asio::"))
    {
        if let Some(id) = sel_id
            && let Some(found) = caps.iter().find(|c| {
                c.backend == OutputBackendKind::WindowsAsio
                    && (c.device_id == id || c.name == id)
            })
        {
            return found.clone();
        }
        if let Some(asio) = caps
            .iter()
            .find(|c| c.backend == OutputBackendKind::WindowsAsio && c.asio_available)
        {
            return asio.clone();
        }
    }

    if let Some(id) = sel_id {
        let raw_id = AudioDeviceManager::strip_mode_prefix(id);
        // 1. Exact (id + backend) match
        if let Some(bk) = eff_backend
            && let Some(found) = caps.iter().find(|c| {
                c.backend == bk
                    && (c.device_id == id
                        || AudioDeviceManager::strip_mode_prefix(&c.device_id) == raw_id
                        || raw_id.contains(AudioDeviceManager::strip_mode_prefix(&c.device_id))
                        || c.name == id)
            })
        {
            return found.clone();
        }
        // 2. General id match when backend wasn't specified
        if eff_backend.is_none()
            && let Some(found) = caps.iter().find(|c| {
                c.device_id == id
                    || AudioDeviceManager::strip_mode_prefix(&c.device_id) == raw_id
                    || raw_id.contains(AudioDeviceManager::strip_mode_prefix(&c.device_id))
                    || c.name == id
            })
        {
            return found.clone();
        }
        // 3. Match via cpal device description name when sel_id came from enumerate_cpal_devices()
        let cpal_name = enumerate_cpal_devices()
            .into_iter()
            .find(|d| d.id == id)
            .map(|d| d.name);
        if let Some(ref name) = cpal_name
            && let Some(found) = caps.iter().find(|c| {
                c.name == *name && eff_backend.is_none_or(|bk| c.backend == bk)
            })
        {
            return found.clone();
        }
    }

    if let Some(bk) = eff_backend
        && let Some(found) = caps.iter().find(|c| c.backend == bk && c.is_default)
    {
        return found.clone();
    }

    caps.iter()
        .find(|c| c.is_default)
        .or_else(|| caps.first())
        .cloned()
        .unwrap_or_else(AudioDeviceManager::virtual_device_capabilities)
}

fn start_output_pipeline(
    inner: &Arc<PlayerInner>,
    decoder: Box<dyn AudioDecoder>,
    spec: PipelineSpec,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
) -> Result<ActiveSession, CoreAudioError> {
    let PipelineSpec {
        session_id,
        pcm_rate,
        out_channels: default_out_channels,
        path,
        source_label,
        format,
        duration_ms,
        start_paused,
    } = spec;
    let cancel_flag = Arc::new(AtomicBool::new(false));
    let eof_flag = Arc::new(AtomicBool::new(false));

    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let unified_src = decoder.unified_format();
    let track_meta: Option<DecodedTrackMetadata> = decoder.metadata().cloned();
    let caps = resolve_target_capabilities(inner, sel_id.as_deref(), sel_backend);
    let policy = inner.policy.read().map(|g| g.clone()).unwrap_or_default();
    let dsp_bypassed = inner.dsp_bypassed.load(Ordering::SeqCst);
    let eff_vol = if policy.strict_bit_perfect {
        1.0
    } else {
        f32::from_bits(inner.volume_bits.load(Ordering::Relaxed))
    };

    let explicit_shared = sel_backend == Some(OutputBackendKind::WindowsWasapiShared)
        || sel_id.as_deref().is_some_and(|s| s.starts_with("wasapi-shared::"));

    let want_native_wire = !explicit_shared
        && (policy.strict_bit_perfect
            || dsp_bypassed
            || caps.backend == OutputBackendKind::WindowsAsio
            || sel_backend == Some(OutputBackendKind::WindowsAsio)
            || sel_backend == Some(OutputBackendKind::WindowsWasapiExclusive)
            || (unified_src.dsd_rate.is_some()
                && !matches!(policy.dsd_output_mode, DsdOutputMode::DsdToPcm)
                && dsp_bypassed
                && (eff_vol - 1.0).abs() < 1e-6));

    let negotiated_res = AudioFormatManager::negotiate(&unified_src, &caps, &policy);
    if let Err(ref msg) = negotiated_res
        && policy.strict_bit_perfect
        && !policy.allow_shared_fallback
    {
        tracing::warn!("Strict bit-perfect format negotiation rejected stream: {msg}");
        return Err(CoreAudioError::Backend(BackendError::UnsupportedFormat(
            format.clone(),
        )));
    }

    let mut exclusive_fallback_reason: Option<String> = None;

    if want_native_wire
        && let Ok(ref negotiated) = negotiated_res
        && negotiated.output_mode.is_exclusive_or_asio()
    {
        // Note: on headless virtual target, native wire runs if Strict Mode is armed or DSP is bypassed
        let allow_virtual_wire = caps.transport == DeviceTransportKind::Virtual
            && (policy.strict_bit_perfect
                || dsp_bypassed
                || matches!(
                    negotiated.output_mode,
                    OutputMode::DoPOverWasapiExclusive | OutputMode::AsioNativeDsd
                ));

        if caps.transport != DeviceTransportKind::Virtual || allow_virtual_wire {
            let wire = negotiated.wire_format;
            let ver_cfg = VerificationConfig {
                source_format: unified_src.clone(),
                output_mode: negotiated.output_mode,
                transport: caps.transport,
                target_rate_hz: negotiated.target_sample_rate,
                target_channels: negotiated.target_channels,
                target_valid_bits: negotiated.valid_bits,
                target_container_bits: negotiated.container_bits,
                buffer_size_frames: policy.preferred_buffer_frames,
                dsp_active: false,
                software_volume_unity: true,
                resampled: negotiated.requires_resampling,
                exclusive_unavailable_reason: None,
            };
            let verification = AudioVerificationEngine::new(ver_cfg);
            if let Some(ref m) = track_meta {
                verification.set_source_metadata(
                    m.title.clone(),
                    m.artist.clone(),
                    m.album.clone(),
                );
            }

            let ring_bytes = (negotiated.target_sample_rate.max(44_100) as usize / 2)
                * (negotiated.target_channels.max(1) as usize)
                * wire.bytes_per_sample().max(1);
            let (byte_prod, byte_cons) =
                SpscRingBuffer::<u8>::new(ring_bytes.clamp(131_072, 4 * 1024 * 1024));

            let native_attempt: Result<(NativeOutputSession, u32, String, OutputBackendKind, &'static str), BackendError> =
                if allow_virtual_wire {
                    let h = spawn_virtual_wire_consumer(
                        byte_cons,
                        wire,
                        negotiated.target_sample_rate,
                        negotiated.target_channels,
                        Arc::clone(inner),
                        verification.clone(),
                        Arc::clone(&cancel_flag),
                        Arc::clone(&eof_flag),
                        session_id,
                    );
                    Ok((
                        NativeOutputSession::VirtualWire(h),
                        policy.preferred_buffer_frames,
                        VIRTUAL_DEVICE_NAME.to_string(),
                        OutputBackendKind::WindowsWasapiExclusive,
                        "Virtual Wire Engine",
                    ))
                } else {
                    #[cfg(target_os = "windows")]
                    {
                        if matches!(
                            negotiated.output_mode,
                            OutputMode::AsioPcm | OutputMode::AsioNativeDsd | OutputMode::DoPOverAsio
                        ) {
                            let is_native_dsd =
                                negotiated.output_mode == OutputMode::AsioNativeDsd;
                            crate::backend::asio_win::AsioNativeSession::open_and_start(
                                Some(&caps.device_id),
                                negotiated.target_sample_rate,
                                negotiated.target_channels,
                                wire,
                                is_native_dsd,
                                byte_cons,
                                verification.clone(),
                                Arc::clone(&inner.frames_rendered),
                                Arc::clone(&inner.nonzero_output_frames),
                                Arc::clone(&inner.state_code),
                                Arc::clone(&eof_flag),
                                session_id,
                                Arc::clone(&inner.current_session_id),
                            )
                            .map(|sess| {
                                if start_paused {
                                    sess.set_paused(true);
                                }
                                let frames = sess.buffer_frames;
                                let dname = sess.driver_name.clone();
                                (
                                    NativeOutputSession::AsioNative(sess),
                                    frames,
                                    dname,
                                    OutputBackendKind::WindowsAsio,
                                    "ASIO 2.x COM Driver",
                                )
                            })
                        } else {
                            let open_spec = crate::backend::wasapi_win::WasapiExclusiveOpenSpec {
                                device_id: Some(caps.device_id.clone()),
                                sample_rate: negotiated.target_sample_rate,
                                channels: negotiated.target_channels,
                                layout: ChannelLayout::from_channels(negotiated.target_channels),
                                wire_format: wire,
                                is_dop: negotiated.output_mode == OutputMode::DoPOverWasapiExclusive,
                                buffer_frames_hint: policy.preferred_buffer_frames,
                            };
                            crate::backend::wasapi_win::WasapiExclusiveSession::open_and_start(
                                open_spec,
                                byte_cons,
                                verification.clone(),
                                Arc::clone(&inner.frames_rendered),
                                Arc::clone(&inner.nonzero_output_frames),
                                Arc::clone(&inner.state_code),
                                Arc::clone(&eof_flag),
                                Arc::clone(&inner.last_error),
                                session_id,
                                Arc::clone(&inner.current_session_id),
                            )
                            .map(|sess| {
                                if start_paused {
                                    sess.set_paused(true);
                                }
                                let frames = sess.actual_buffer_frames;
                                let dname = sess.device_name.clone();
                                (
                                    NativeOutputSession::WasapiExclusive(sess),
                                    frames,
                                    dname,
                                    OutputBackendKind::WindowsWasapiExclusive,
                                    "WASAPI Exclusive (Event-Driven)",
                                )
                            })
                        }
                    }
                    #[cfg(not(target_os = "windows"))]
                    {
                        Err(BackendError::DeviceNotFound(
                            "Native Windows WASAPI/ASIO unavailable on this OS".into(),
                        ))
                    }
                };

            match native_attempt {
                Ok((native_sess, actual_frames, dev_name, bk, api_label)) => {
                    native_sess.set_eof_state_code(PlaybackLifecycleState::Ended as i32);
                    verification.set_buffer_size_frames(actual_frames);
                    // Native DSD clocks at 1-bit frequency; track frame clock cleanly for position_ms()
                    let rate_for_pos = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
                        negotiated.target_sample_rate
                    } else {
                        negotiated.target_sample_rate
                    };
                    inner.out_sample_rate.store(rate_for_pos, Ordering::SeqCst);

                    if let Ok(mut vw) = inner.verification.write() {
                        *vw = Some((verification.clone(), api_label.to_string(), dev_name.clone()));
                    }
                    if let Ok(mut meta_lock) = inner.active_meta.write() {
                        *meta_lock = Some(ActiveTrackMeta {
                            path: path.clone(),
                            source_label: source_label.clone(),
                            format: format.clone(),
                            duration_ms,
                            resampled_to_hz: None,
                            backend: bk,
                            device_name: dev_name,
                        });
                    }

                    let dec_inner = Arc::clone(inner);
                    let dec_cancel = Arc::clone(&cancel_flag);
                    let dec_eof = Arc::clone(&eof_flag);
                    let dec_neg = negotiated.clone();
                    let dec_caps = caps.clone();
                    let dec_tx = cmd_tx.clone();
                    let dec_path = path.clone();
                    let dec_label = source_label.clone();
                    let decode_handle = thread::Builder::new()
                        .name("lumina-wire-decoder".to_string())
                        .spawn(move || {
                            decode_wire_loop(
                                decoder,
                                byte_prod,
                                unified_src,
                                dec_neg,
                                dec_caps,
                                verification,
                                dec_inner,
                                dec_cancel,
                                dec_eof,
                                session_id,
                                dec_tx,
                                dec_path,
                                dec_label,
                            )
                        })
                        .ok();

                    return Ok(ActiveSession {
                        cancel_flag,
                        eof_flag,
                        decode_handle,
                        virtual_handle: None,
                        _cpal_stream: None,
                        native_output: Some(native_sess),
                        path,
                        source_label,
                        format,
                        duration_ms,
                        pcm_rate: rate_for_pos,
                    });
                }
                Err(backend_err) => {
                    tracing::warn!("Exclusive/ASIO open failed: {}", backend_err);
                    // NEVER silently fall back to WASAPI Shared when ASIO was explicitly selected!
                    if !policy.allow_shared_fallback
                        || sel_backend == Some(OutputBackendKind::WindowsAsio)
                        || caps.backend == OutputBackendKind::WindowsAsio
                    {
                        return Err(CoreAudioError::Backend(backend_err));
                    }
                    exclusive_fallback_reason = Some(backend_err.to_string());
                }
            }
        }
    }

    // Path B: Shared Mode / DSP Active / Explicit DSD-to-PCM Fallback / Headless Normal
    let use_virtual = inner.headless
        || (sel_id.as_deref() == Some(VIRTUAL_DEVICE_ID) && enumerate_cpal_devices().is_empty());

    let shared_verification = AudioVerificationEngine::new(VerificationConfig {
        source_format: unified_src.clone(),
        output_mode: OutputMode::WasapiShared,
        transport: caps.transport,
        target_rate_hz: pcm_rate,
        target_channels: default_out_channels,
        target_valid_bits: 32,
        target_container_bits: 32,
        buffer_size_frames: policy.preferred_buffer_frames,
        dsp_active: !dsp_bypassed,
        software_volume_unity: (eff_vol - 1.0).abs() < 1e-6,
        resampled: false,
        exclusive_unavailable_reason: exclusive_fallback_reason.clone(),
    });
    if let Some(ref m) = track_meta {
        shared_verification.set_source_metadata(m.title.clone(), m.artist.clone(), m.album.clone());
    }

    let (producer, virtual_handle, cpal_stream, out_rate, out_channels, backend_kind, device_name) =
        if use_virtual {
            let (prod, cons) = SpscRingBuffer::<f32>::new(65_536);
            let vh = spawn_virtual_consumer(
                cons,
                pcm_rate,
                default_out_channels,
                Arc::clone(inner),
                Some(shared_verification.clone()),
                Arc::clone(&cancel_flag),
                Arc::clone(&eof_flag),
                session_id,
            );
            (
                prod,
                Some(vh),
                None,
                pcm_rate,
                default_out_channels,
                OutputBackendKind::WindowsWasapiExclusive,
                VIRTUAL_DEVICE_NAME.to_string(),
            )
        } else {
            let (stream, prod, actual_rate, actual_ch, bk, dev_name) = open_cpal_output(
                pcm_rate,
                default_out_channels,
                inner,
                Some(shared_verification.clone()),
                &cancel_flag,
                &eof_flag,
                session_id,
            )?;
            (prod, None, Some(stream), actual_rate, actual_ch, bk, dev_name)
        };

    inner.out_sample_rate.store(out_rate, Ordering::SeqCst);
    let resampled_to_hz = if pcm_rate != out_rate {
        Some(out_rate)
    } else {
        None
    };

    let mode_b = if unified_src.dsd_rate.is_some() {
        OutputMode::DsdToPcm
    } else if use_virtual {
        OutputMode::VirtualMock
    } else {
        OutputMode::WasapiShared
    };
    let degrad_b = exclusive_fallback_reason.or_else(|| {
        if unified_src.dsd_rate.is_some() {
            Some("DSD-to-PCM 轉換輸出".to_string())
        } else if mode_b == OutputMode::WasapiShared {
            Some("Windows Shared Mode (經過系統混音器)".to_string())
        } else {
            None
        }
    });
    shared_verification.update_config(VerificationConfig {
        source_format: unified_src.clone(),
        output_mode: mode_b,
        transport: caps.transport,
        target_rate_hz: out_rate,
        target_channels: out_channels,
        target_valid_bits: 32,
        target_container_bits: 32,
        buffer_size_frames: policy.preferred_buffer_frames,
        dsp_active: !dsp_bypassed,
        software_volume_unity: (eff_vol - 1.0).abs() < 1e-6,
        resampled: pcm_rate != out_rate,
        exclusive_unavailable_reason: degrad_b,
    });
    let api_label_b = if use_virtual {
        "Virtual Consumer".to_string()
    } else {
        format!("{backend_kind:?}")
    };
    if let Ok(mut vw) = inner.verification.write() {
        *vw = Some((shared_verification.clone(), api_label_b, device_name.clone()));
    }

    if let Ok(mut meta_lock) = inner.active_meta.write() {
        *meta_lock = Some(ActiveTrackMeta {
            path: path.clone(),
            source_label: source_label.clone(),
            format: format.clone(),
            duration_ms,
            resampled_to_hz,
            backend: backend_kind,
            device_name,
        });
    }

    let decode_inner = Arc::clone(inner);
    let decode_cancel = Arc::clone(&cancel_flag);
    let decode_eof = Arc::clone(&eof_flag);
    let decode_tx = cmd_tx.clone();
    let fallback_neg = NegotiatedFormat {
        output_mode: mode_b,
        wire_format: WireSampleFormat::Float32Le,
        target_sample_rate: out_rate,
        target_channels: out_channels,
        container_bits: 32,
        valid_bits: 32,
        is_bit_perfect_candidate: false,
        requires_dsp_bypass: false,
        requires_unity_volume: false,
        requires_resampling: pcm_rate != out_rate,
        degradation_reason: None,
    };
    let decode_handle = thread::Builder::new()
        .name("lumina-audio-decoder".to_string())
        .spawn(move || {
            decode_loop(
                decoder,
                producer,
                pcm_rate,
                out_rate,
                out_channels,
                decode_inner,
                Some(shared_verification),
                unified_src,
                fallback_neg,
                caps,
                decode_cancel,
                decode_eof,
                session_id,
                decode_tx,
            )
        })
        .ok();

    if !start_paused
        && let Some(ref stream) = cpal_stream
        && let Err(e) = stream.play()
    {
        cancel_flag.store(true, Ordering::SeqCst);
        let _ = stream.pause();
        if let Some(h) = decode_handle {
            let _ = h.join();
        }
        if let Some(h) = virtual_handle {
            let _ = h.join();
        }
        return Err(CoreAudioError::Backend(BackendError::DriverError(format!(
            "Failed to start cpal output stream: {e}"
        ))));
    }

    Ok(ActiveSession {
        cancel_flag,
        eof_flag,
        decode_handle,
        virtual_handle,
        _cpal_stream: cpal_stream,
        native_output: None,
        path,
        source_label,
        format,
        duration_ms,
        pcm_rate,
    })
}

fn coordinator_loop(
    inner: Arc<PlayerInner>,
    cmd_rx: mpsc::Receiver<PlayerCommand>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
) {
    let mut active: Option<ActiveSession> = None;

    while let Ok(cmd) = cmd_rx.recv() {
        match cmd {
            PlayerCommand::Start {
                session_id,
                decoder,
                path,
                source_label,
                ack_tx,
            } => {
                if let Some(mut prev) = active.take() {
                    let _ = prev.stop_and_join();
                }

                let format = decoder.format().clone();
                let duration_ms = decoder
                    .duration()
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                let pcm_rate = if format.is_dsd {
                    (format.sample_rate_hz / 8).max(44_100)
                } else {
                    format.sample_rate_hz.max(8_000)
                };
                let src_channels = (format.channels as u16).max(1);

                inner.duration_ms.store(duration_ms, Ordering::SeqCst);
                let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
                let start_paused = inner.paused.load(Ordering::SeqCst);

                match start_output_pipeline(
                    &inner,
                    decoder,
                    PipelineSpec {
                        session_id,
                        pcm_rate,
                        out_channels: default_out_channels,
                        path,
                        source_label,
                        format,
                        duration_ms,
                        start_paused,
                    },
                    &cmd_tx,
                ) {
                    Ok(sess) => {
                        active = Some(sess);
                        let _ = ack_tx.send(Ok(()));
                    }
                    Err(e) => {
                        record_playback_error(&inner, e.to_string());
                        let _ = ack_tx.send(Err(e));
                    }
                }
            }
            PlayerCommand::FormatSwitchNext {
                session_id,
                decoder,
                path,
                source_label,
                rg_tags,
            } => {
                if inner.current_session_id.load(Ordering::Relaxed) != session_id
                    || inner.stopped.load(Ordering::Relaxed)
                {
                    continue;
                }
                // Wait briefly for trailing frames of Track A to finish draining cleanly
                if let Some(ref prev) = active {
                    let wait_start = Instant::now();
                    while prev.eof_flag.load(Ordering::SeqCst)
                        && inner.state_code.load(Ordering::SeqCst)
                            == PlaybackLifecycleState::Playing as i32
                        && wait_start.elapsed() < Duration::from_millis(600)
                    {
                        thread::sleep(Duration::from_millis(10));
                    }
                }
                if let Some(mut prev) = active.take() {
                    let _ = prev.stop_and_join();
                }

                inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
                if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
                    *rg_lock = rg_tags;
                }
                let next_sid = inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                let format = decoder.format().clone();
                let duration_ms = decoder
                    .duration()
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                let pcm_rate = if format.is_dsd {
                    (format.sample_rate_hz / 8).max(44_100)
                } else {
                    format.sample_rate_hz.max(8_000)
                };
                let src_channels = (format.channels as u16).max(1);
                let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
                inner.duration_ms.store(duration_ms, Ordering::SeqCst);
                inner.frames_rendered.store(0, Ordering::SeqCst);
                inner.nonzero_output_frames.store(0, Ordering::SeqCst);
                inner
                    .state_code
                    .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);

                match start_output_pipeline(
                    &inner,
                    decoder,
                    PipelineSpec {
                        session_id: next_sid,
                        pcm_rate,
                        out_channels: default_out_channels,
                        path,
                        source_label,
                        format,
                        duration_ms,
                        start_paused: false,
                    },
                    &cmd_tx,
                ) {
                    Ok(sess) => active = Some(sess),
                    Err(e) => record_playback_error(&inner, e.to_string()),
                }
            }
            PlayerCommand::RerouteOutput { ack_tx } => {
                let state = inner.state_code.load(Ordering::SeqCst);
                let should_reroute = active.is_some()
                    && !inner.stopped.load(Ordering::SeqCst)
                    && (state == PlaybackLifecycleState::Playing as i32
                        || state == PlaybackLifecycleState::Paused as i32);
                if !should_reroute {
                    let _ = ack_tx.send(Ok(()));
                    continue;
                }

                let resume_pos_ms = position_ms_from_inner(&inner);
                let is_paused = inner.paused.load(Ordering::SeqCst);
                let mut prev = active.take().unwrap();
                let path = prev.path.clone();
                let source_label = prev.source_label.clone();
                let format = prev.format.clone();
                let duration_ms = prev.duration_ms;
                let pcm_rate = prev.pcm_rate;
                let src_channels = (format.channels as u16).max(1);
                let default_out_channels = if src_channels == 1 { 2 } else { src_channels };

                let Some(mut decoder) = prev
                    .stop_and_join()
                    .or_else(|| open_decoder_for_path(&path).ok())
                else {
                    let _ = ack_tx.send(Ok(()));
                    continue;
                };

                let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
                let session_id = inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;

                match start_output_pipeline(
                    &inner,
                    decoder,
                    PipelineSpec {
                        session_id,
                        pcm_rate,
                        out_channels: default_out_channels,
                        path,
                        source_label,
                        format,
                        duration_ms,
                        start_paused: is_paused,
                    },
                    &cmd_tx,
                ) {
                    Ok(sess) => {
                        let new_out_rate = inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                        let rescaled_frames = ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                        inner.frames_rendered.store(rescaled_frames, Ordering::SeqCst);
                        active = Some(sess);
                        let _ = ack_tx.send(Ok(()));
                    }
                    Err(e) => {
                        record_playback_error(&inner, e.to_string());
                        let _ = ack_tx.send(Err(e));
                    }
                }
            }
            PlayerCommand::Pause => {
                if let Some(sess) = &active {
                    if let Some(stream) = &sess._cpal_stream {
                        let _ = stream.pause();
                    }
                    if let Some(native) = &sess.native_output {
                        native.set_paused(true);
                    }
                }
            }
            PlayerCommand::Resume => {
                if let Some(sess) = &active {
                    if let Some(stream) = &sess._cpal_stream {
                        let _ = stream.play();
                    }
                    if let Some(native) = &sess.native_output {
                        native.set_paused(false);
                    }
                }
            }
            PlayerCommand::Stop => {
                if let Some(mut prev) = active.take() {
                    let _ = prev.stop_and_join();
                }
            }
            PlayerCommand::SeekMs => {
                let req_ms = inner.seek_request_ms.load(Ordering::SeqCst);
                let is_paused = inner.paused.load(Ordering::SeqCst);
                let is_ended = inner.state_code.load(Ordering::SeqCst)
                    == PlaybackLifecycleState::Ended as i32;

                if let Some(ref mut sess) = active {
                    if let Some(ref native) = sess.native_output {
                        let _ = native.flush();
                    }

                    let decode_finished = sess
                        .decode_handle
                        .as_ref()
                        .map(|h| h.is_finished())
                        .unwrap_or(true);
                    if is_ended || decode_finished {
                        let path = sess.path.clone();
                        let source_label = sess.source_label.clone();
                        let format = sess.format.clone();
                        let duration_ms = sess.duration_ms;
                        let pcm_rate = sess.pcm_rate;
                        let src_channels = (format.channels as u16).max(1);
                        let default_out_channels = if src_channels == 1 { 2 } else { src_channels };

                        if let Some(mut prev) = active.take() {
                            let _ = prev.stop_and_join();
                        }

                        if let Ok(mut decoder) = open_decoder_for_path(&path) {
                            if req_ms >= 0 {
                                let _ = decoder.seek(Duration::from_millis(req_ms as u64));
                            }
                            let session_id =
                                inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                            inner.seek_request_ms.store(-1, Ordering::SeqCst);

                            match start_output_pipeline(
                                &inner,
                                decoder,
                                PipelineSpec {
                                    session_id,
                                    pcm_rate,
                                    out_channels: default_out_channels,
                                    path,
                                    source_label,
                                    format,
                                    duration_ms,
                                    start_paused: is_paused,
                                },
                                &cmd_tx,
                            ) {
                                Ok(new_sess) => {
                                    let new_out_rate =
                                        inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                                    let target_ms = req_ms.max(0) as u128;
                                    let rescaled_frames = (target_ms * new_out_rate / 1000) as u64;
                                    inner.frames_rendered.store(rescaled_frames, Ordering::SeqCst);
                                    let target_state = if is_paused {
                                        PlaybackLifecycleState::Paused as i32
                                    } else {
                                        PlaybackLifecycleState::Playing as i32
                                    };
                                    inner.state_code.store(target_state, Ordering::SeqCst);
                                    inner.is_seeking.store(false, Ordering::SeqCst);
                                    active = Some(new_sess);
                                }
                                Err(e) => {
                                    record_playback_error(&inner, e.to_string());
                                }
                            }
                        }
                    }
                }
            }
            PlayerCommand::Shutdown => {
                if let Some(mut prev) = active.take() {
                    let _ = prev.stop_and_join();
                }
                break;
            }
        }
    }
}

fn apply_live_dsp(d: &mut DspPipeline, inner: &PlayerInner) {
    let cfg = inner
        .dsp_config
        .read()
        .map(|g| g.clone())
        .unwrap_or_else(|_| default_shared_dsp_config());
    let rg_tags = inner
        .track_replay_gain
        .read()
        .map(|g| g.clone())
        .unwrap_or_default();

    let bypassed = inner.dsp_bypassed.load(Ordering::Relaxed) || cfg.bypass;
    d.set_bypass(bypassed);
    let _ = d.set_peq_bands(to_parametric_bands(&cfg.peq_bands));
    d.set_crossfeed_enabled(cfg.crossfeed.enabled);
    d.set_replay_gain(to_internal_replay_gain(&cfg.replay_gain, &rg_tags));
    d.set_limiter_enabled(true);
}

#[allow(clippy::too_many_arguments)]
fn decode_wire_loop(
    mut decoder: Box<dyn AudioDecoder>,
    mut producer: Producer<u8>,
    mut curr_unified: UnifiedAudioFormat,
    mut curr_neg: NegotiatedFormat,
    curr_caps: AudioDeviceCapabilities,
    verification: AudioVerificationEngine,
    inner: Arc<PlayerInner>,
    cancel_flag: Arc<AtomicBool>,
    eof_flag: Arc<AtomicBool>,
    session_id: u64,
    cmd_tx: mpsc::Sender<PlayerCommand>,
    mut curr_path: PathBuf,
    mut curr_label: String,
) -> Option<Box<dyn AudioDecoder>> {
    let mut dop_framer = matches!(curr_neg.wire_format, WireSampleFormat::Dop24In32MsbLe { .. })
        .then(DopFramer::new);

    loop {
        if cancel_flag.load(Ordering::Relaxed) {
            return Some(decoder);
        }
        if inner.stopped.load(Ordering::Relaxed) {
            return None;
        }

        let req_seek = inner.seek_request_ms.swap(-1, Ordering::SeqCst);
        if req_seek >= 0 {
            let target_ms = req_seek as u64;
            producer.request_flush();
            producer.sync_epoch();
            if let Err(e) = decoder.seek(Duration::from_millis(target_ms)) {
                tracing::warn!("Decoder wire seek to {target_ms} ms failed: {e}");
            }
            if let Some(ref mut df) = dop_framer {
                df.reset();
            }
            verification.reset_streams();
            let rate = inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
            inner
                .frames_rendered
                .store(((target_ms as u128) * rate / 1000) as u64, Ordering::SeqCst);
            inner.is_seeking.store(false, Ordering::SeqCst);
            let target_state = if inner.paused.load(Ordering::Relaxed) {
                PlaybackLifecycleState::Paused as i32
            } else {
                PlaybackLifecycleState::Playing as i32
            };
            inner.state_code.store(target_state, Ordering::SeqCst);
        }

        if inner.paused.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        match decoder.next_chunk() {
            Ok(Some(chunk)) => {
                verification.record_decoder_output(&chunk);
                verification.record_processed_output(&chunk);

                let wire_bytes =
                    pack_chunk_to_wire_bytes(&chunk, curr_neg.wire_format, dop_framer.as_mut());
                let mut offset = 0;
                while offset < wire_bytes.len()
                    && !cancel_flag.load(Ordering::Relaxed)
                    && !inner.stopped.load(Ordering::Relaxed)
                {
                    if inner.seek_request_ms.load(Ordering::Relaxed) >= 0 {
                        break;
                    }
                    let pushed = producer.push_slice(&wire_bytes[offset..]);
                    offset += pushed;
                    if offset < wire_bytes.len() {
                        thread::sleep(Duration::from_millis(4));
                    }
                }
            }
            Ok(None) => {
                // Check Gapless or Format-Switch queued next track
                if let Some((next_stream, next_label)) =
                    inner.queued_next.write().ok().and_then(|mut g| g.take())
                {
                    let next_rg = TrackReplayGainTags::from_stream(&next_stream);
                    let next_path = next_stream.display_path();
                    if let Ok(next_dec) = open_decoder_for_stream(&next_stream) {
                        let next_unified = next_dec.unified_format();
                        let policy = inner.policy.read().map(|g| g.clone()).unwrap_or_default();
                        if let Some(next_neg) = AudioFormatManager::can_gapless_transition(
                            &curr_unified,
                            &curr_neg,
                            &next_unified,
                            &curr_caps,
                            &policy,
                        ) {
                            let next_dur = next_dec
                                .duration()
                                .map(|d| d.as_millis() as u64)
                                .unwrap_or(0);
                            inner.duration_ms.store(next_dur, Ordering::SeqCst);
                            inner.frames_rendered.store(0, Ordering::SeqCst);
                            inner.nonzero_output_frames.store(0, Ordering::SeqCst);
                            inner.seek_epoch.fetch_add(1, Ordering::SeqCst);
                            verification.reset_streams();
                            inner.gapless_transitions.fetch_add(1, Ordering::SeqCst);
                            if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
                                *rg_lock = next_rg;
                            }
                            if let Ok(mut meta_lock) = inner.active_meta.write()
                                && let Some(ref mut meta) = *meta_lock
                            {
                                meta.path = next_path.clone();
                                meta.source_label = next_label.clone();
                                meta.format = next_dec.format().clone();
                                meta.duration_ms = next_dur;
                            }
                            if let Some(m) = next_dec.metadata() {
                                verification.set_source_metadata(
                                    m.title.clone(),
                                    m.artist.clone(),
                                    m.album.clone(),
                                );
                            } else {
                                verification.set_source_metadata(None, None, None);
                            }
                            curr_path = next_path;
                            curr_label = next_label;
                            curr_unified = next_unified;
                            curr_neg = next_neg;
                            decoder = next_dec;
                            continue;
                        }

                        // Format changed: drain Track A, then re-open output backend for Track B
                        eof_flag.store(true, Ordering::SeqCst);
                        let _ = cmd_tx.send(PlayerCommand::FormatSwitchNext {
                            session_id,
                            decoder: next_dec,
                            path: next_path,
                            source_label: next_label,
                            rg_tags: next_rg,
                        });
                        return None;
                    }
                }
                let _ = (&curr_path, &curr_label);
                if wait_at_eof(&inner, &cancel_flag, &eof_flag) {
                    continue;
                }
                return None;
            }
            Err(e) => {
                tracing::error!("Wire audio decode error: {}", e);
                if let Ok(mut err_lock) = inner.last_error.write() {
                    *err_lock = Some(format!("Decode error: {e}"));
                }
                inner
                    .state_code
                    .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
                eof_flag.store(true, Ordering::SeqCst);
                return None;
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn decode_loop(
    mut decoder: Box<dyn AudioDecoder>,
    mut producer: Producer<f32>,
    initial_pcm_rate: u32,
    out_rate: u32,
    out_channels: u16,
    inner: Arc<PlayerInner>,
    verification: Option<AudioVerificationEngine>,
    mut curr_unified: UnifiedAudioFormat,
    mut curr_neg: NegotiatedFormat,
    curr_caps: AudioDeviceCapabilities,
    cancel_flag: Arc<AtomicBool>,
    eof_flag: Arc<AtomicBool>,
    session_id: u64,
    cmd_tx: mpsc::Sender<PlayerCommand>,
) -> Option<Box<dyn AudioDecoder>> {
    let mut dsd_decimator = DsdStereoDecimator::new();
    let mut dsp_channels = out_channels.max(1) as usize;
    let mut dsp_rate = initial_pcm_rate.max(8_000);
    let mut dsp = DspPipeline::new(dsp_rate as f64, dsp_channels).ok();
    let mut applied_gen = inner.dsp_generation.load(Ordering::Acquire);
    if let Some(ref mut d) = dsp {
        apply_live_dsp(d, &inner);
    }

    loop {
        if cancel_flag.load(Ordering::Relaxed) {
            return Some(decoder);
        }
        if inner.stopped.load(Ordering::Relaxed) {
            return None;
        }

        let req_seek = inner.seek_request_ms.swap(-1, Ordering::SeqCst);
        if req_seek >= 0 {
            let target_ms = req_seek as u64;
            producer.request_flush();
            producer.sync_epoch();
            if let Err(e) = decoder.seek(Duration::from_millis(target_ms)) {
                tracing::warn!("Decoder seek to {target_ms} ms failed: {e}");
            }
            dsd_decimator.reset();
            if let Some(ref mut d) = dsp {
                d.reset();
            }
            if let Some(ref v) = verification {
                v.reset_streams();
            }
            let rate = inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
            inner
                .frames_rendered
                .store(((target_ms as u128) * rate / 1000) as u64, Ordering::SeqCst);
            inner.is_seeking.store(false, Ordering::SeqCst);
            let target_state = if inner.paused.load(Ordering::Relaxed) {
                PlaybackLifecycleState::Paused as i32
            } else {
                PlaybackLifecycleState::Playing as i32
            };
            inner.state_code.store(target_state, Ordering::SeqCst);
        }

        if inner.paused.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        match decoder.next_chunk() {
            Ok(Some(chunk)) => {
                if let Some(ref v) = verification {
                    v.record_decoder_output(&chunk);
                }

                let (mut f64_samples, chunk_channels, chunk_pcm_rate) = match chunk {
                    AudioChunk::PcmI16 {
                        ref samples,
                        channels,
                        sample_rate,
                    } => {
                        let _ = samples;
                        (chunk.to_f64_interleaved(), channels.max(1), sample_rate.max(8_000))
                    }
                    AudioChunk::PcmI24In32 {
                        ref samples,
                        channels,
                        sample_rate,
                    } => {
                        let _ = samples;
                        (chunk.to_f64_interleaved(), channels.max(1), sample_rate.max(8_000))
                    }
                    AudioChunk::PcmI32 {
                        ref samples,
                        channels,
                        sample_rate,
                    } => {
                        let _ = samples;
                        (chunk.to_f64_interleaved(), channels.max(1), sample_rate.max(8_000))
                    }
                    AudioChunk::PcmF64 {
                        samples,
                        channels,
                        sample_rate,
                    } => (samples, channels.max(1), sample_rate.max(8_000)),
                    AudioChunk::PcmF32 {
                        samples,
                        channels,
                        sample_rate,
                    } => (
                        samples.into_iter().map(|s| s as f64).collect(),
                        channels.max(1),
                        sample_rate.max(8_000),
                    ),
                    AudioChunk::DsdBitstream {
                        bytes,
                        channels,
                        sample_rate,
                        is_lsb_first,
                    } => {
                        let pcm_samples = if channels <= 1 {
                            let mut stereo = Vec::with_capacity(bytes.len() * 2);
                            for b in bytes {
                                let v = dsd_decimator.left.translate_byte(b, is_lsb_first);
                                stereo.push(v);
                                stereo.push(v);
                            }
                            stereo
                        } else {
                            dsd_decimator.decimate_interleaved(&bytes, is_lsb_first)
                        };
                        (pcm_samples, 2, (sample_rate / 8).max(44_100))
                    }
                };

                f64_samples = adapt_channels_f64(&f64_samples, chunk_channels, out_channels);

                let mut recreated_dsp = false;
                if dsp.is_none()
                    || dsp_rate != chunk_pcm_rate
                    || dsp_channels != out_channels as usize
                {
                    dsp_rate = chunk_pcm_rate;
                    dsp_channels = out_channels as usize;
                    dsp = DspPipeline::new(dsp_rate as f64, dsp_channels).ok();
                    recreated_dsp = true;
                }

                let current_gen = inner.dsp_generation.load(Ordering::Acquire);
                if let Some(ref mut d) = dsp {
                    if recreated_dsp || current_gen != applied_gen {
                        apply_live_dsp(d, &inner);
                        applied_gen = current_gen;
                    }
                    d.set_bypass(inner.dsp_bypassed.load(Ordering::Relaxed));
                    d.process_interleaved(&mut f64_samples);
                }

                let resampled = resample_interleaved_f64(
                    &f64_samples,
                    out_channels as usize,
                    chunk_pcm_rate,
                    out_rate,
                );
                let f32_buf: Vec<f32> = resampled.into_iter().map(|s| s as f32).collect();
                if let Some(ref v) = verification {
                    v.record_processed_output(&AudioChunk::PcmF32 {
                        samples: f32_buf.clone(),
                        channels: out_channels,
                        sample_rate: out_rate,
                    });
                }

                let mut offset = 0;
                while offset < f32_buf.len()
                    && !cancel_flag.load(Ordering::Relaxed)
                    && !inner.stopped.load(Ordering::Relaxed)
                {
                    if inner.seek_request_ms.load(Ordering::Relaxed) >= 0 {
                        break;
                    }
                    let pushed = producer.push_slice(&f32_buf[offset..]);
                    offset += pushed;
                    if offset < f32_buf.len() {
                        thread::sleep(Duration::from_millis(5));
                    }
                }
            }
            Ok(None) => {
                if let Some((next_stream, next_label)) =
                    inner.queued_next.write().ok().and_then(|mut g| g.take())
                {
                    let next_rg = TrackReplayGainTags::from_stream(&next_stream);
                    let next_path = next_stream.display_path();
                    if let Ok(next_dec) = open_decoder_for_stream(&next_stream) {
                        let next_unified = next_dec.unified_format();
                        let policy = inner.policy.read().map(|g| g.clone()).unwrap_or_default();
                        if let Some(next_neg) = AudioFormatManager::can_gapless_transition(
                            &curr_unified,
                            &curr_neg,
                            &next_unified,
                            &curr_caps,
                            &policy,
                        ) {
                            let next_dur = next_dec
                                .duration()
                                .map(|d| d.as_millis() as u64)
                                .unwrap_or(0);
                            inner.duration_ms.store(next_dur, Ordering::SeqCst);
                            inner.frames_rendered.store(0, Ordering::SeqCst);
                            inner.nonzero_output_frames.store(0, Ordering::SeqCst);
                            inner.seek_epoch.fetch_add(1, Ordering::SeqCst);
                            if let Some(ref v) = verification {
                                v.reset_streams();
                            }
                            inner.gapless_transitions.fetch_add(1, Ordering::SeqCst);
                            if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
                                *rg_lock = next_rg;
                            }
                            if let Ok(mut meta_lock) = inner.active_meta.write()
                                && let Some(ref mut meta) = *meta_lock
                            {
                                meta.path = next_path;
                                meta.source_label = next_label;
                                meta.format = next_dec.format().clone();
                                meta.duration_ms = next_dur;
                            }
                            if let Some(ref v) = verification
                                && let Some(m) = next_dec.metadata()
                            {
                                v.set_source_metadata(
                                    m.title.clone(),
                                    m.artist.clone(),
                                    m.album.clone(),
                                );
                            }
                            curr_unified = next_unified;
                            curr_neg = next_neg;
                            decoder = next_dec;
                            continue;
                        }

                        eof_flag.store(true, Ordering::SeqCst);
                        let _ = cmd_tx.send(PlayerCommand::FormatSwitchNext {
                            session_id,
                            decoder: next_dec,
                            path: next_path,
                            source_label: next_label,
                            rg_tags: next_rg,
                        });
                        return None;
                    }
                }
                if wait_at_eof(&inner, &cancel_flag, &eof_flag) {
                    continue;
                }
                return None;
            }
            Err(e) => {
                tracing::error!("Audio decode error: {}", e);
                if let Ok(mut err_lock) = inner.last_error.write() {
                    *err_lock = Some(format!("Decode error: {e}"));
                }
                inner
                    .state_code
                    .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
                eof_flag.store(true, Ordering::SeqCst);
                return None;
            }
        }
    }
}

fn adapt_channels_f64(samples: &[f64], in_ch: u16, out_ch: u16) -> Vec<f64> {
    let ich = in_ch.max(1) as usize;
    let och = out_ch.max(1) as usize;
    if ich == och || samples.is_empty() {
        return samples.to_vec();
    }
    let frames = samples.len() / ich;
    let mut out = Vec::with_capacity(frames * och);
    for frame in samples.chunks_exact(ich) {
        if ich == 1 && och >= 2 {
            let s = frame[0];
            for _ in 0..och {
                out.push(s);
            }
        } else {
            for c in 0..och {
                out.push(frame[c % ich]);
            }
        }
    }
    out
}

fn resample_interleaved_f64(
    input: &[f64],
    channels: usize,
    in_rate: u32,
    out_rate: u32,
) -> Vec<f64> {
    if in_rate == out_rate || input.is_empty() || channels == 0 {
        return input.to_vec();
    }
    let in_frames = input.len() / channels;
    if in_frames == 0 {
        return Vec::new();
    }
    let ratio = out_rate as f64 / in_rate as f64;
    let out_frames = ((in_frames as f64) * ratio).round().max(1.0) as usize;
    let mut out = Vec::with_capacity(out_frames * channels);
    for of in 0..out_frames {
        let src_pos = (of as f64) / ratio;
        let idx0 = (src_pos.floor() as usize).min(in_frames - 1);
        let idx1 = (idx0 + 1).min(in_frames - 1);
        let frac = src_pos - (idx0 as f64);
        for c in 0..channels {
            let s0 = input[idx0 * channels + c];
            let s1 = input[idx1 * channels + c];
            out.push(s0 + (s1 - s0) * frac);
        }
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn spawn_virtual_wire_consumer(
    mut consumer: Consumer<u8>,
    wire: WireSampleFormat,
    out_rate: u32,
    out_channels: u16,
    inner: Arc<PlayerInner>,
    verification: AudioVerificationEngine,
    cancel_flag: Arc<AtomicBool>,
    eof_flag: Arc<AtomicBool>,
    session_id: u64,
) -> JoinHandle<()> {
    let ch = out_channels.max(1) as usize;
    let bpf = wire.bytes_per_sample().max(1) * ch;
    let clock_rate = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        (out_rate / 8).max(44_100)
    } else {
        out_rate.max(8_000)
    };
    let sil_byte: u8 = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        0x69
    } else {
        0x00
    };

    thread::Builder::new()
        .name("lumina-virtual-wire-dac".to_string())
        .spawn(move || {
            let mut last_tick = Instant::now();
            let mut scratch = vec![sil_byte; 4096 * bpf];
            let mut frac_frames = 0.0f64;

            loop {
                if cancel_flag.load(Ordering::Relaxed)
                    || inner.stopped.load(Ordering::Relaxed)
                    || inner.current_session_id.load(Ordering::Relaxed) != session_id
                {
                    break;
                }

                thread::sleep(Duration::from_millis(10));
                let now = Instant::now();
                let dt = now.duration_since(last_tick).as_secs_f64();
                last_tick = now;

                if inner.paused.load(Ordering::Relaxed) {
                    continue;
                }

                frac_frames += dt * (clock_rate as f64);
                let frames_needed = frac_frames.floor() as usize;
                frac_frames -= frames_needed as f64;

                let bytes_needed = ((frames_needed * bpf).min(scratch.len()) / bpf) * bpf;
                if bytes_needed > 0 {
                    let popped = consumer.pop_slice(&mut scratch[..bytes_needed]);
                    let aligned = (popped / bpf) * bpf;
                    if aligned > 0 {
                        verification.record_backend_input_wire(
                            &scratch[..aligned],
                            wire,
                            out_channels,
                            out_rate,
                        );
                        let rendered_frames = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
                            ((aligned / bpf) * 8) as u64
                        } else {
                            (aligned / bpf) as u64
                        };
                        inner
                            .frames_rendered
                            .fetch_add(rendered_frames, Ordering::Relaxed);
                        if scratch[..aligned].iter().any(|&b| b != sil_byte) {
                            inner
                                .nonzero_output_frames
                                .fetch_add(rendered_frames, Ordering::Relaxed);
                        }
                    } else if eof_flag.load(Ordering::SeqCst) && consumer.available_read() < bpf {
                        let _ = inner.state_code.compare_exchange(
                            PlaybackLifecycleState::Playing as i32,
                            PlaybackLifecycleState::Ended as i32,
                            Ordering::SeqCst,
                            Ordering::SeqCst,
                        );
                        break;
                    }
                }
            }
        })
        .expect("spawn virtual wire dac thread")
}

#[allow(clippy::too_many_arguments)]
fn spawn_virtual_consumer(
    mut consumer: Consumer<f32>,
    out_rate: u32,
    out_channels: u16,
    inner: Arc<PlayerInner>,
    verification: Option<AudioVerificationEngine>,
    cancel_flag: Arc<AtomicBool>,
    eof_flag: Arc<AtomicBool>,
    session_id: u64,
) -> JoinHandle<()> {
    let ch = out_channels.max(1) as usize;
    thread::Builder::new()
        .name("lumina-virtual-dac".to_string())
        .spawn(move || {
            let mut last_tick = Instant::now();
            let mut drain_buf = vec![0.0f32; 4096 * ch];
            let mut wire_bytes = Vec::<u8>::with_capacity(4096 * ch * 4);
            let mut frac_frames = 0.0f64;

            loop {
                if cancel_flag.load(Ordering::Relaxed)
                    || inner.stopped.load(Ordering::Relaxed)
                    || inner.current_session_id.load(Ordering::Relaxed) != session_id
                {
                    break;
                }

                thread::sleep(Duration::from_millis(10));
                let now = Instant::now();
                let dt = now.duration_since(last_tick).as_secs_f64();
                last_tick = now;

                if inner.paused.load(Ordering::Relaxed) {
                    continue;
                }

                frac_frames += dt * (out_rate as f64);
                let frames_needed = frac_frames.floor() as usize;
                frac_frames -= frames_needed as f64;

                let samples_needed = ((frames_needed * ch).min(drain_buf.len()) / ch) * ch;
                if samples_needed > 0 {
                    let popped = consumer.pop_slice(&mut drain_buf[..samples_needed]);
                    let aligned = (popped / ch) * ch;
                    if aligned > 0 {
                        let vol = f32::from_bits(inner.volume_bits.load(Ordering::Relaxed));
                        wire_bytes.clear();
                        let mut has_nonzero = false;
                        for &src in &drain_buf[..aligned] {
                            let scaled = src * vol;
                            if scaled.abs() > 1e-6 {
                                has_nonzero = true;
                            }
                            if verification.is_some() {
                                wire_bytes.extend_from_slice(&scaled.to_le_bytes());
                            }
                        }
                        if let Some(ref v) = verification {
                            v.record_backend_input_wire(
                                &wire_bytes,
                                WireSampleFormat::Float32Le,
                                out_channels,
                                out_rate,
                            );
                        }
                        let rendered_frames = (aligned / ch) as u64;
                        inner
                            .frames_rendered
                            .fetch_add(rendered_frames, Ordering::Relaxed);
                        if has_nonzero {
                            inner
                                .nonzero_output_frames
                                .fetch_add(rendered_frames, Ordering::Relaxed);
                        }
                    } else if eof_flag.load(Ordering::SeqCst) && consumer.available_read() == 0 {
                        let _ = inner.state_code.compare_exchange(
                            PlaybackLifecycleState::Playing as i32,
                            PlaybackLifecycleState::Ended as i32,
                            Ordering::SeqCst,
                            Ordering::SeqCst,
                        );
                        break;
                    }
                }
            }
        })
        .expect("spawn virtual dac thread")
}

fn map_host_to_backend(host_id: HostId, device_name: &str) -> OutputBackendKind {
    match host_id.to_string().to_ascii_lowercase().as_str() {
        "asio" => OutputBackendKind::WindowsAsio,
        "coreaudio" => OutputBackendKind::MacOsCoreAudioHog,
        "aaudio" => OutputBackendKind::MobileDirect,
        "wasapi" => {
            if device_name.to_ascii_lowercase().contains("asio") {
                OutputBackendKind::WindowsAsio
            } else {
                OutputBackendKind::WindowsWasapiShared
            }
        }
        _ => {
            if device_name.to_ascii_lowercase().contains("asio") {
                OutputBackendKind::WindowsAsio
            } else {
                OutputBackendKind::WindowsWasapiShared
            }
        }
    }
}

fn virtual_exclusive_device(is_default: bool) -> AudioDeviceDescription {
    AudioDeviceDescription {
        id: VIRTUAL_DEVICE_ID.to_string(),
        name: VIRTUAL_DEVICE_NAME.to_string(),
        backend: OutputBackendKind::WindowsWasapiExclusive,
        is_default,
        is_exclusive: true,
        supported_sample_rates: vec![44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000],
        supported_bit_depths: vec![16, 24, 32],
        supports_native_dsd: true,
    }
}

pub fn enumerate_cpal_devices() -> Vec<AudioDeviceDescription> {
    const STANDARD_RATES: [u32; 8] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ];

    let mut out = Vec::new();
    let default_host_id = cpal::default_host().id();

    for host_id in cpal::available_hosts() {
        let Ok(host) = cpal::host_from_id(host_id) else {
            continue;
        };
        let default_dev_id = host
            .default_output_device()
            .and_then(|d| d.id().ok())
            .map(|id| id.to_string());

        let Ok(devices) = host.output_devices() else {
            continue;
        };

        for dev in devices {
            let Ok(dev_id) = dev.id() else {
                continue;
            };
            let id_str = dev_id.to_string();
            let name = dev
                .description()
                .map(|d| d.name().to_string())
                .unwrap_or_else(|_| id_str.clone());
            let backend = map_host_to_backend(host_id, &name);
            let is_default =
                host_id == default_host_id && default_dev_id.as_deref() == Some(id_str.as_str());

            let mut rates = Vec::new();
            let mut bit_depths = Vec::new();
            if let Ok(configs) = dev.supported_output_configs() {
                for range in configs {
                    let min_r = range.min_sample_rate();
                    let max_r = range.max_sample_rate();
                    for &sr in &STANDARD_RATES {
                        if sr >= min_r && sr <= max_r && !rates.contains(&sr) {
                            rates.push(sr);
                        }
                    }
                    if !rates.contains(&min_r) {
                        rates.push(min_r);
                    }
                    if !rates.contains(&max_r) {
                        rates.push(max_r);
                    }

                    let depth = match range.sample_format() {
                        SampleFormat::I16 | SampleFormat::U16 => 16,
                        SampleFormat::I24 | SampleFormat::U24 => 24,
                        _ => 32,
                    };
                    if !bit_depths.contains(&depth) {
                        bit_depths.push(depth);
                    }
                }
            }
            if rates.is_empty() {
                rates = vec![44_100, 48_000];
            } else {
                rates.sort_unstable();
            }
            if bit_depths.is_empty() {
                bit_depths = vec![16, 24];
            } else {
                bit_depths.sort_unstable();
            }

            out.push(AudioDeviceDescription {
                id: id_str,
                name,
                backend,
                is_default,
                is_exclusive: backend.is_exclusive(),
                supported_sample_rates: rates,
                supported_bit_depths: bit_depths,
                supports_native_dsd: backend == OutputBackendKind::WindowsAsio,
            });
        }
    }

    out
}

pub fn rank_sample_format(fmt: SampleFormat) -> Option<u8> {
    match fmt {
        SampleFormat::F32 => Some(0),
        SampleFormat::F64 => Some(1),
        SampleFormat::I32 => Some(2),
        SampleFormat::I24 => Some(3),
        SampleFormat::I16 => Some(4),
        SampleFormat::U16 => Some(5),
        SampleFormat::U8 => Some(6),
        _ => None,
    }
}

/// Pure config ranking helper for unit tests: picks the best index among
/// `(channels, min_sample_rate, max_sample_rate, sample_format)` candidates
/// matching `(desired_channels, desired_rate)`.
pub fn select_best_config_index(
    candidates: &[(u16, u32, u32, SampleFormat)],
    desired_rate: u32,
    desired_channels: u16,
) -> Option<usize> {
    let mut best: Option<(u8, usize)> = None;
    for (idx, &(channels, min_rate, max_rate, fmt)) in candidates.iter().enumerate() {
        if channels != desired_channels || desired_rate < min_rate || desired_rate > max_rate {
            continue;
        }
        let Some(rank) = rank_sample_format(fmt) else {
            continue;
        };
        if best.is_none_or(|(best_rank, _)| rank < best_rank) {
            best = Some((rank, idx));
            if rank == 0 {
                break;
            }
        }
    }
    best.map(|(_, idx)| idx)
}

fn select_output_config(
    device: &cpal::Device,
    desired_rate: u32,
    desired_channels: u16,
) -> Result<cpal::SupportedStreamConfig, CoreAudioError> {
    if let Ok(ranges) = device.supported_output_configs() {
        let mut best: Option<(u8, cpal::SupportedStreamConfig)> = None;
        for range in ranges {
            if range.channels() != desired_channels {
                continue;
            }
            let Some(rank) = rank_sample_format(range.sample_format()) else {
                continue;
            };
            let Some(exact) = range.try_with_sample_rate(desired_rate) else {
                continue;
            };
            if best.as_ref().is_none_or(|(best_rank, _)| rank < *best_rank) {
                best = Some((rank, exact));
                if rank == 0 {
                    break;
                }
            }
        }
        if let Some((_, cfg)) = best {
            return Ok(cfg);
        }
    }

    device.default_output_config().map_err(|e| {
        CoreAudioError::Backend(BackendError::DriverError(format!(
            "Failed to query output config for audio device: {e}"
        )))
    })
}

fn resolve_cpal_device(
    selected_id: Option<&str>,
    selected_backend: Option<OutputBackendKind>,
) -> Result<(cpal::Device, OutputBackendKind, String), CoreAudioError> {
    if selected_id == Some(VIRTUAL_DEVICE_ID) {
        return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
            VIRTUAL_DEVICE_ID.to_string(),
        )));
    }

    if let Some(target_id) = selected_id {
        let clean_target = AudioDeviceManager::strip_mode_prefix(target_id);
        if clean_target.starts_with("asio::") {
            return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
                target_id.to_string(),
            )));
        }
        for host_id in cpal::available_hosts() {
            let Ok(host) = cpal::host_from_id(host_id) else {
                continue;
            };
            let Ok(devices) = host.output_devices() else {
                continue;
            };
            for dev in devices {
                if let Ok(id) = dev.id() {
                    let id_str = id.to_string();
                    if id_str == clean_target || id_str.contains(clean_target) {
                        let name = dev
                            .description()
                            .map(|d| d.name().to_string())
                            .unwrap_or_else(|_| clean_target.to_string());
                        let backend = match selected_backend {
                            Some(OutputBackendKind::WindowsWasapiExclusive)
                            | Some(OutputBackendKind::WindowsAsio)
                            | None => map_host_to_backend(host_id, &name),
                            Some(other) => other,
                        };
                        return Ok((dev, backend, name));
                    }
                }
            }
        }
        return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
            target_id.to_string(),
        )));
    }

    if let Some(target_backend) = selected_backend {
        for host_id in cpal::available_hosts() {
            let Ok(host) = cpal::host_from_id(host_id) else {
                continue;
            };
            if let Some(dev) = host.default_output_device() {
                let name = dev
                    .description()
                    .map(|d| d.name().to_string())
                    .unwrap_or_else(|_| "System Audio Output".to_string());
                let detected = map_host_to_backend(host_id, &name);
                if detected == target_backend {
                    return Ok((dev, detected, name));
                }
            }
        }
    }

    let host = cpal::default_host();
    let host_id = host.id();
    if let Some(dev) = host.default_output_device() {
        let name = dev
            .description()
            .map(|d| d.name().to_string())
            .unwrap_or_else(|_| "System Audio Output".to_string());
        let backend = selected_backend.unwrap_or_else(|| map_host_to_backend(host_id, &name));
        return Ok((dev, backend, name));
    }

    for alt_host_id in cpal::available_hosts() {
        let Ok(alt_host) = cpal::host_from_id(alt_host_id) else {
            continue;
        };
        if let Some(dev) = alt_host
            .default_output_device()
            .or_else(|| alt_host.output_devices().ok().and_then(|mut it| it.next()))
        {
            let name = dev
                .description()
                .map(|d| d.name().to_string())
                .unwrap_or_else(|_| "System Audio Output".to_string());
            let backend =
                selected_backend.unwrap_or_else(|| map_host_to_backend(alt_host_id, &name));
            return Ok((dev, backend, name));
        }
    }

    Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
        "No hardware audio output device available".to_string(),
    )))
}

#[allow(clippy::type_complexity)]
fn open_cpal_output(
    desired_rate: u32,
    desired_channels: u16,
    inner: &Arc<PlayerInner>,
    verification: Option<AudioVerificationEngine>,
    cancel_flag: &Arc<AtomicBool>,
    eof_flag: &Arc<AtomicBool>,
    session_id: u64,
) -> Result<
    (
        cpal::Stream,
        Producer<f32>,
        u32,
        u16,
        OutputBackendKind,
        String,
    ),
    CoreAudioError,
> {
    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let (device, backend_kind, dev_name) =
        resolve_cpal_device(sel_id.as_deref(), sel_backend)?;

    let selected_config = select_output_config(&device, desired_rate, desired_channels)?;
    let sample_format = selected_config.sample_format();
    let out_rate = selected_config.sample_rate();
    let out_channels = selected_config.channels();
    let stream_config: cpal::StreamConfig = selected_config.into();
    let (producer, consumer) = SpscRingBuffer::<f32>::new(65_536);

    let stream_res = match sample_format {
        SampleFormat::F32 => build_cpal_typed_stream::<f32>(
            &device,
            stream_config,
            consumer,
            Arc::clone(inner),
            verification,
            Arc::clone(cancel_flag),
            Arc::clone(eof_flag),
            session_id,
        ),
        SampleFormat::F64 => build_cpal_typed_stream::<f64>(
            &device,
            stream_config,
            consumer,
            Arc::clone(inner),
            verification,
            Arc::clone(cancel_flag),
            Arc::clone(eof_flag),
            session_id,
        ),
        SampleFormat::I32 => build_cpal_typed_stream::<i32>(
            &device,
            stream_config,
            consumer,
            Arc::clone(inner),
            verification,
            Arc::clone(cancel_flag),
            Arc::clone(eof_flag),
            session_id,
        ),
        SampleFormat::I24 => build_cpal_typed_stream::<cpal::I24>(
            &device,
            stream_config,
            consumer,
            Arc::clone(inner),
            verification,
            Arc::clone(cancel_flag),
            Arc::clone(eof_flag),
            session_id,
        ),
        SampleFormat::I16 => build_cpal_typed_stream::<i16>(
            &device,
            stream_config,
            consumer,
            Arc::clone(inner),
            verification,
            Arc::clone(cancel_flag),
            Arc::clone(eof_flag),
            session_id,
        ),
        SampleFormat::U16 => build_cpal_typed_stream::<u16>(
            &device,
            stream_config,
            consumer,
            Arc::clone(inner),
            verification,
            Arc::clone(cancel_flag),
            Arc::clone(eof_flag),
            session_id,
        ),
        SampleFormat::U8 => build_cpal_typed_stream::<u8>(
            &device,
            stream_config,
            consumer,
            Arc::clone(inner),
            verification,
            Arc::clone(cancel_flag),
            Arc::clone(eof_flag),
            session_id,
        ),
        other => {
            return Err(CoreAudioError::Backend(BackendError::DriverError(format!(
                "Unsupported cpal output sample format: {other:?}"
            ))));
        }
    };

    let stream = stream_res.map_err(|e| {
        CoreAudioError::Backend(BackendError::DriverError(format!(
            "Failed to build cpal output stream for '{dev_name}': {e}"
        )))
    })?;

    Ok((
        stream,
        producer,
        out_rate,
        out_channels,
        backend_kind,
        dev_name,
    ))
}

#[allow(clippy::too_many_arguments)]
fn build_cpal_typed_stream<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    mut consumer: Consumer<f32>,
    inner: Arc<PlayerInner>,
    verification: Option<AudioVerificationEngine>,
    cancel_flag: Arc<AtomicBool>,
    eof_flag: Arc<AtomicBool>,
    session_id: u64,
) -> Result<cpal::Stream, cpal::Error>
where
    T: SizedSample + FromSample<f32>,
{
    let ch = config.channels.max(1) as usize;
    let out_rate = config.sample_rate;
    let max_pos = if T::FORMAT.is_float() {
        1.0_f32
    } else {
        // dasp_sample 0.11 requires -1.0 <= s < 1.0 for float-to-integer conversions
        0.99999994_f32
    };
    let mut temp_f32 = Vec::<f32>::new();
    let mut temp_wire = Vec::<u8>::with_capacity(8192);
    let err_inner = Arc::clone(&inner);

    device.build_output_stream(
        config,
        move |output: &mut [T], _| {
            if cancel_flag.load(Ordering::Relaxed)
                || inner.stopped.load(Ordering::Relaxed)
                || inner.paused.load(Ordering::Relaxed)
                || inner.current_session_id.load(Ordering::Relaxed) != session_id
            {
                output.fill(T::EQUILIBRIUM);
                return;
            }

            let vol = f32::from_bits(inner.volume_bits.load(Ordering::Relaxed));
            let max_samples = (output.len() / ch) * ch;
            if temp_f32.len() < max_samples {
                temp_f32.resize(max_samples, 0.0);
            }

            let read = consumer.pop_slice(&mut temp_f32[..max_samples]);
            let aligned = (read / ch) * ch;
            let mut has_nonzero = false;
            temp_wire.clear();
            for (dst, &src) in output[..aligned].iter_mut().zip(&temp_f32[..aligned]) {
                let scaled = (src * vol).clamp(-1.0, max_pos);
                if scaled.abs() > 1e-6 {
                    has_nonzero = true;
                }
                if verification.is_some() {
                    temp_wire.extend_from_slice(&scaled.to_le_bytes());
                }
                *dst = T::from_sample(scaled);
            }
            if let Some(ref v) = verification
                && !temp_wire.is_empty()
            {
                v.record_backend_input_wire(
                    &temp_wire,
                    WireSampleFormat::Float32Le,
                    ch as u16,
                    out_rate,
                );
            }
            if aligned < output.len() {
                output[aligned..].fill(T::EQUILIBRIUM);
                if eof_flag.load(Ordering::SeqCst) && consumer.available_read() == 0 {
                    let _ = inner.state_code.compare_exchange(
                        PlaybackLifecycleState::Playing as i32,
                        PlaybackLifecycleState::Ended as i32,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                }
            }
            if aligned > 0 {
                let frames = (aligned / ch) as u64;
                inner.frames_rendered.fetch_add(frames, Ordering::Relaxed);
                if has_nonzero {
                    inner
                        .nonzero_output_frames
                        .fetch_add(frames, Ordering::Relaxed);
                }
            }
        },
        move |err| {
            tracing::warn!("cpal output stream error: {}", err);
            if let Ok(mut guard) = err_inner.last_error.write() {
                *guard = Some(format!("Audio output stream error: {err}"));
            }
            err_inner
                .state_code
                .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
        },
        None,
    )
}
