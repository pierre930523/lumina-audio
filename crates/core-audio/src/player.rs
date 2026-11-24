use std::fs::File;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicI64, AtomicPtr, AtomicU32, AtomicU64, AtomicU8, AtomicUsize,
    Ordering,
};
use std::sync::{mpsc, Arc, Condvar, Mutex, OnceLock, RwLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use core_types::{
    compute_l2_target_bytes, AudioCodec, AudioDeviceCapabilities, AudioDeviceDescription,
    AudioEngineOutputInfo, AudioFormat, ChannelLayout, CrossfeedConfig, DeckId, DeckState,
    DeviceTransportKind, DsdOutputMode, DspPipelineConfig as SharedDspConfig,
    DualDeckStatusSnapshot, ManifestFormat, OutputBackendKind, OutputMode, PeqBandConfig,
    PeqFilterKind, PlaybackEnginePolicy, ReplayGainConfig as SharedReplayGainConfig,
    ReplayGainMode as SharedReplayGainMode, SignalPath, StreamCipher, StreamKey, StreamSourceSpec,
    UnifiedAudioFormat,
};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, HostId, SampleFormat, SizedSample};
use tokio_util::sync::CancellationToken;

use crate::backend::DeviceEvent;
use crate::buffer::{Consumer, Producer, SpscRingBuffer};
use crate::device_manager::{
    AudioDeviceManager, AudioFormatManager, DeviceExtraMeta, NegotiatedFormat,
};
use crate::dsd::{DopFramer, DsdStereoDecimator, DsdiffReader, DsfReader};
use crate::dsp::{
    BiquadCoefficients, DspPipeline, FilterType, LookaheadLimiter, ParametricBand, ReplayGain,
    ReplayGainConfig as InternalReplayGainConfig, ReplayGainMode as InternalReplayGainMode,
};
use crate::error::{BackendError, CoreAudioError, DecoderError, DspError};
use crate::pcm::{AudioChunk, AudioDecoder, DecodedTrackMetadata, SymphoniaDecoder, SynthAudioDecoder};
use crate::signal_path::{SignalPathContext, SignalPathEngine};
use crate::stream::{
    is_playlist_extension, looks_like_playlist_magic, resolve_playlist_url_with_cancel,
    HttpRangeMediaSource, StreamOrigin, StreamSource,
};
use crate::streaming::{
    drop_idle_http_connections, should_admit_to_l2, streaming_runtime, subscribe_network_epoch,
    BlockingStreamBridge, ByteStreamSource, ChunkedStreamProxy, DecryptingByteStream,
    FormatMismatchCallback, HybridByteStream, HybridSegmentedConfig, HybridSegmentedStream,
    L2CacheManager, ReqwestStreamTransport, SegmentedStreamProxy, StreamError, StreamHttpConfig,
    StreamRefreshHandler, DEFAULT_INITIAL_CHUNK_SIZE, DEFAULT_PREFETCH_AHEAD,
    DEFAULT_REFRESH_403_BACKOFFS, DEEZER_ALIGNED_CHUNK_SIZE, DEEZER_INITIAL_CHUNK_SIZE,
};
use crate::verification::{
    pack_chunk_to_wire_bytes, AudioVerificationEngine, VerificationConfig, VerificationTapProducer,
    WireFormatStamp, WireSampleFormat,
};

const VIRTUAL_DEVICE_ID: &str = "virtual-exclusive-dac";
const VIRTUAL_DEVICE_NAME: &str = "Virtual Exclusive DAC";

/// Concrete boxed decoder returned by [`AudioPlayer`] async open helpers.
pub type OpenedStreamDecoder = Box<dyn AudioDecoder>;

/// Streaming-resilient startup / post-seek audio release watermark in milliseconds (400–600 ms target).
pub const STARTUP_WATERMARK_MS: u64 = 500;

/// Anti-jitter background decode ring-buffer target duration in seconds (~10–15 s after pow2 rounding).
pub const TARGET_RING_BUFFER_SECS: usize = 10;

/// Linear micro-crossfade duration in milliseconds (5–15 ms click/pop prevention target).
pub const MICRO_FADE_MS: u64 = 10;

/// Standby pre-decode target duration in milliseconds (2–3 seconds target).
pub const STANDBY_PREDECODE_MS: u64 = 2_500;

/// FormatMismatch dual-track alignment lead time in milliseconds (`current_pts_ms + 800ms`).
pub const MISMATCH_ALIGNMENT_OFFSET_MS: u64 = 800;

/// FormatMismatch linear micro-crossfade duration in milliseconds (`5 ms`).
pub const MISMATCH_CROSSFADE_MS: u64 = 5;

/// Remaining duration threshold (`<= 20s`) for automatic Standby pre-decode trigger.
pub const AUTO_PREDECODE_REMAINING_MS: u64 = 20_000;

/// Computes `SpscRingBuffer<f32>` capacity for 10–15 s of anti-jitter PCM buffering.
pub fn compute_pcm_ring_samples(out_rate: u32, out_channels: u16) -> usize {
    let rate = out_rate.max(8_000) as usize;
    let ch = out_channels.max(1) as usize;
    let desired = rate.saturating_mul(ch).saturating_mul(TARGET_RING_BUFFER_SECS);
    desired.clamp(65_536, 8_388_608).next_power_of_two()
}

/// Computes `SpscRingBuffer<u8>` capacity for 10–15 s of anti-jitter wire buffering.
pub fn compute_wire_ring_bytes(
    sample_rate: u32,
    channels: u16,
    wire: WireSampleFormat,
) -> usize {
    let effective_rate = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        (sample_rate / 8).max(44_100) as usize
    } else {
        sample_rate.max(8_000) as usize
    };
    let bpf = wire.bytes_per_sample().max(1) * (channels.max(1) as usize);
    let desired = effective_rate
        .saturating_mul(bpf)
        .saturating_mul(TARGET_RING_BUFFER_SECS);
    desired.clamp(262_144, 32 * 1024 * 1024).next_power_of_two()
}

/// Computes the `STARTUP_WATERMARK_MS` startup/post-seek release watermark in interleaved `f32` samples.
pub fn compute_startup_watermark_samples(
    out_rate: u32,
    out_channels: u16,
    ring_capacity: usize,
) -> usize {
    let ch = out_channels.max(1) as usize;
    let frames = ((out_rate.max(8_000) as u64 * STARTUP_WATERMARK_MS) / 1000) as usize;
    let raw = frames.saturating_mul(ch);
    let max_cap = (ring_capacity / 2 / ch) * ch;
    raw.min(max_cap)
}

/// Computes the `STARTUP_WATERMARK_MS` startup/post-seek release watermark in wire bytes (aligned to `bpf`).
pub fn compute_startup_watermark_bytes(
    sample_rate: u32,
    channels: u16,
    wire: WireSampleFormat,
    ring_capacity: usize,
) -> usize {
    let effective_rate = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
        (sample_rate / 8).max(44_100) as u64
    } else {
        sample_rate.max(8_000) as u64
    };
    let bpf = wire.bytes_per_sample().max(1) * (channels.max(1) as usize);
    let frames = ((effective_rate * STARTUP_WATERMARK_MS) / 1000) as usize;
    let raw = frames.saturating_mul(bpf);
    let max_cap = (ring_capacity / 2 / bpf) * bpf;
    raw.min(max_cap)
}

/// Lock-free fade target signaled from control/decode threads to the RT audio callback.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FadeTarget {
    Playing = 0,
    PauseFadeOut = 1,
    StopFadeOut = 2,
    SeekFadeOut = 3,
}

impl FadeTarget {
    #[inline]
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::PauseFadeOut,
            2 => Self::StopFadeOut,
            3 => Self::SeekFadeOut,
            _ => Self::Playing,
        }
    }
}

/// Lock-free atomic state coordinating 5–15 ms RT callback micro-fades without mutexes or allocations.
#[derive(Debug)]
pub struct AudioFadeControl {
    target: AtomicU8,
    fade_out_done: AtomicBool,
    seek_fade_epoch: AtomicU64,
    seek_ready_epoch: AtomicU64,
    fade_in_enabled: AtomicBool,
    fade_out_enabled: AtomicBool,
    has_audible_output: AtomicBool,
}

impl AudioFadeControl {
    pub fn new(fade_in_enabled: bool, fade_out_enabled: bool, start_paused: bool) -> Self {
        Self {
            target: AtomicU8::new(if start_paused {
                FadeTarget::PauseFadeOut as u8
            } else {
                FadeTarget::Playing as u8
            }),
            fade_out_done: AtomicBool::new(start_paused || !fade_out_enabled),
            seek_fade_epoch: AtomicU64::new(0),
            seek_ready_epoch: AtomicU64::new(0),
            fade_in_enabled: AtomicBool::new(fade_in_enabled),
            fade_out_enabled: AtomicBool::new(fade_out_enabled),
            has_audible_output: AtomicBool::new(false),
        }
    }

    #[inline]
    pub fn target(&self) -> FadeTarget {
        FadeTarget::from_u8(self.target.load(Ordering::Acquire))
    }

    #[inline]
    pub fn is_fade_out_done(&self) -> bool {
        self.fade_out_done.load(Ordering::Acquire)
    }

    #[inline]
    pub fn fade_in_enabled(&self) -> bool {
        self.fade_in_enabled.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn fade_out_enabled(&self) -> bool {
        self.fade_out_enabled.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn mark_fade_out_done(&self) {
        self.fade_out_done.store(true, Ordering::Release);
    }

    #[inline]
    pub fn mark_audible(&self) {
        if !self.has_audible_output.load(Ordering::Relaxed) {
            self.has_audible_output.store(true, Ordering::Release);
        }
    }

    #[inline]
    pub fn mark_silent(&self) {
        self.has_audible_output.store(false, Ordering::Release);
        self.fade_out_done.store(true, Ordering::Release);
    }

    pub fn request_pause_fade_out(&self) {
        if self.target() == FadeTarget::PauseFadeOut {
            return;
        }
        let immediate = !self.fade_out_enabled() || !self.has_audible_output.load(Ordering::Acquire);
        self.fade_out_done.store(immediate, Ordering::Release);
        self.target
            .store(FadeTarget::PauseFadeOut as u8, Ordering::Release);
    }

    pub fn request_play_fade_in(&self) {
        self.target
            .store(FadeTarget::Playing as u8, Ordering::Release);
    }

    pub fn request_stop_fade_out(&self) {
        if self.target() == FadeTarget::StopFadeOut {
            return;
        }
        let already_silent =
            self.target() == FadeTarget::PauseFadeOut && self.is_fade_out_done();
        let immediate = already_silent
            || !self.fade_out_enabled()
            || !self.has_audible_output.load(Ordering::Acquire);
        self.fade_out_done.store(immediate, Ordering::Release);
        self.target
            .store(FadeTarget::StopFadeOut as u8, Ordering::Release);
    }

    pub fn request_seek_fade_out(&self, seek_epoch: u64) {
        let already_silent = (self.target() == FadeTarget::PauseFadeOut
            || self.target() == FadeTarget::SeekFadeOut)
            && self.is_fade_out_done();
        let immediate = already_silent
            || !self.fade_out_enabled()
            || !self.has_audible_output.load(Ordering::Acquire);
        self.seek_fade_epoch.store(seek_epoch, Ordering::Release);
        self.fade_out_done.store(immediate, Ordering::Release);
        self.target
            .store(FadeTarget::SeekFadeOut as u8, Ordering::Release);
    }

    pub fn notify_seek_ready(&self, seek_epoch: u64, still_paused: bool) {
        self.seek_ready_epoch.store(seek_epoch, Ordering::Release);
        if still_paused {
            self.fade_out_done.store(true, Ordering::Release);
            let _ = self.target.compare_exchange(
                FadeTarget::SeekFadeOut as u8,
                FadeTarget::PauseFadeOut as u8,
                Ordering::SeqCst,
                Ordering::Relaxed,
            );
        } else {
            let _ = self.target.compare_exchange(
                FadeTarget::SeekFadeOut as u8,
                FadeTarget::Playing as u8,
                Ordering::SeqCst,
                Ordering::Relaxed,
            );
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FadeDirection {
    Up,
    Down,
}

/// Callback-local zero-allocation linear ramp state (10 ms default).
#[derive(Debug, Clone, Copy)]
pub struct LinearFadeState {
    gain: f32,
    step: f32,
    fade_in_enabled: bool,
    fade_out_enabled: bool,
}

impl LinearFadeState {
    pub fn new(sample_rate: u32, fade_in_enabled: bool, fade_out_enabled: bool, start_paused: bool) -> Self {
        let fade_frames = ((sample_rate.max(8_000) as u64 * MICRO_FADE_MS) / 1000).clamp(64, 4096);
        let initial_gain = if start_paused || fade_in_enabled { 0.0 } else { 1.0 };
        Self {
            gain: initial_gain,
            step: 1.0 / (fade_frames as f32),
            fade_in_enabled,
            fade_out_enabled,
        }
    }

    pub fn with_frames(
        fade_frames: u64,
        fade_in_enabled: bool,
        fade_out_enabled: bool,
        start_paused: bool,
    ) -> Self {
        let frames = fade_frames.clamp(32, 4096);
        let initial_gain = if start_paused || fade_in_enabled { 0.0 } else { 1.0 };
        Self {
            gain: initial_gain,
            step: 1.0 / (frames as f32),
            fade_in_enabled,
            fade_out_enabled,
        }
    }

    #[inline]
    pub fn gain(&self) -> f32 {
        self.gain
    }

    #[inline]
    pub fn set_zero(&mut self) {
        self.gain = 0.0;
    }

    #[inline]
    pub fn set_unity(&mut self) {
        self.gain = 1.0;
    }

    #[inline]
    pub fn set_gain(&mut self, gain: f32) {
        self.gain = gain.clamp(0.0, 1.0);
    }

    #[inline]
    pub fn remaining_down_frames(&self) -> usize {
        if !self.fade_out_enabled || self.gain <= 0.0 || self.step <= 0.0 {
            0
        } else {
            (self.gain / self.step).ceil() as usize
        }
    }

    #[inline]
    pub fn reset_for_play_start(&mut self) {
        self.gain = if self.fade_in_enabled { 0.0 } else { 1.0 };
    }

    #[inline]
    pub fn fade_out_enabled(&self) -> bool {
        self.fade_out_enabled
    }

    #[inline]
    pub fn step_frame(&mut self, dir: FadeDirection) -> f32 {
        match dir {
            FadeDirection::Up => {
                if !self.fade_in_enabled {
                    self.gain = 1.0;
                } else if self.gain < 1.0 {
                    self.gain = (self.gain + self.step).min(1.0);
                }
                self.gain
            }
            FadeDirection::Down => {
                if !self.fade_out_enabled {
                    self.gain = 0.0;
                } else if self.gain > 0.0 {
                    self.gain = (self.gain - self.step).max(0.0);
                }
                self.gain
            }
        }
    }
}

/// Applies a per-frame linear gain ramp in-place to interleaved PCM wire bytes.
/// Strictly zero-allocation and lock-free. No-op for Native DSD and DoP.
#[inline]
pub fn apply_fade_ramp_to_wire_bytes(
    wire_bytes: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    fade: &mut LinearFadeState,
    direction: FadeDirection,
) {
    if matches!(
        wire,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    ) {
        return;
    }
    let ch = channels.max(1);
    let bps = wire.bytes_per_sample();
    let bpf = bps * ch;
    if bpf == 0 || wire_bytes.len() < bpf {
        return;
    }
    let frames = wire_bytes.len() / bpf;
    for f in 0..frames {
        let g = fade.step_frame(direction);
        if direction == FadeDirection::Up && (g - 1.0).abs() < 1e-6 {
            break;
        }
        let frame_slice = &mut wire_bytes[f * bpf..(f + 1) * bpf];
        for c in 0..ch {
            let s = &mut frame_slice[c * bps..(c + 1) * bps];
            match wire {
                WireSampleFormat::Int16Le => {
                    let v = i16::from_le_bytes([s[0], s[1]]);
                    let scaled = ((v as f32) * g)
                        .round()
                        .clamp(i16::MIN as f32, i16::MAX as f32)
                        as i16;
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Int24PackedLe => {
                    let sign = if s[2] & 0x80 != 0 { 0xFF } else { 0x00 };
                    let v = i32::from_le_bytes([s[0], s[1], s[2], sign]);
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(-8_388_608.0, 8_388_607.0) as i32;
                    let le = scaled.to_le_bytes();
                    s[0] = le[0];
                    s[1] = le[1];
                    s[2] = le[2];
                }
                WireSampleFormat::Int24In32MsbLe => {
                    let v = i32::from_le_bytes([s[0], s[1], s[2], s[3]]) >> 8;
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(-8_388_608.0, 8_388_607.0) as i32;
                    s.copy_from_slice(&(scaled << 8).to_le_bytes());
                }
                WireSampleFormat::Int32Le => {
                    let v = i32::from_le_bytes([s[0], s[1], s[2], s[3]]);
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(i32::MIN as f64, i32::MAX as f64) as i32;
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Float32Le => {
                    let v = f32::from_le_bytes([s[0], s[1], s[2], s[3]]);
                    s.copy_from_slice(&(v * g).to_le_bytes());
                }
                WireSampleFormat::Float64Le => {
                    let v = f64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]);
                    s.copy_from_slice(&(v * (g as f64)).to_le_bytes());
                }
                WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => {}
            }
        }
    }
}

/// RT-safe, zero-allocation linear tail fade-out on interleaved `f32` PCM samples.
///
/// Applied when a ring buffer runs partially dry mid-callback so the boundary into silence
/// ramps smoothly down to `0.0` instead of emitting an audible step discontinuity/click.
#[inline]
pub fn fade_out_f32_tail(samples: &mut [f32], channels: usize, max_tail_frames: usize) {
    let ch = channels.max(1);
    let total_frames = samples.len() / ch;
    let tail_frames = total_frames.min(max_tail_frames);
    if tail_frames == 0 {
        return;
    }
    let start_frame = total_frames - tail_frames;
    let denom = tail_frames as f32;
    for i in 0..tail_frames {
        // Reaches exact 0.0 on the final valid frame (i == tail_frames - 1).
        let g = ((tail_frames - 1 - i) as f32) / denom;
        let base = (start_frame + i) * ch;
        for c in 0..ch {
            let s = samples[base + c];
            samples[base + c] = if s.is_finite() { s * g } else { 0.0 };
        }
    }
}

/// RT-safe, zero-allocation linear tail fade-out on packed wire-format PCM bytes.
///
/// Skips DSD / DoP formats where sample-level linear scaling is invalid.
pub fn fade_out_wire_tail(
    wire_bytes: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    max_tail_frames: usize,
) {
    if matches!(
        wire,
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. }
    ) {
        return;
    }
    let bps = wire.bytes_per_sample();
    let ch = channels.max(1);
    let bpf = bps * ch;
    if bpf == 0 {
        return;
    }
    let total_frames = wire_bytes.len() / bpf;
    let tail_frames = total_frames.min(max_tail_frames);
    if tail_frames == 0 {
        return;
    }
    let start_frame = total_frames - tail_frames;
    let denom = tail_frames as f32;
    for i in 0..tail_frames {
        let g = ((tail_frames - 1 - i) as f32) / denom;
        let frame_off = (start_frame + i) * bpf;
        let frame = &mut wire_bytes[frame_off..frame_off + bpf];
        for c in 0..ch {
            let s = &mut frame[c * bps..(c + 1) * bps];
            match wire {
                WireSampleFormat::Int16Le => {
                    let v = i16::from_le_bytes([s[0], s[1]]);
                    let scaled = ((v as f32) * g)
                        .round()
                        .clamp(i16::MIN as f32, i16::MAX as f32) as i16;
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Int24PackedLe => {
                    let sign = if s[2] & 0x80 != 0 { 0xFF } else { 0x00 };
                    let v = i32::from_le_bytes([s[0], s[1], s[2], sign]);
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(-8_388_608.0, 8_388_607.0) as i32;
                    let le = scaled.to_le_bytes();
                    s[0] = le[0];
                    s[1] = le[1];
                    s[2] = le[2];
                }
                WireSampleFormat::Int24In32MsbLe => {
                    let v = i32::from_le_bytes([s[0], s[1], s[2], s[3]]) >> 8;
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(-8_388_608.0, 8_388_607.0) as i32;
                    s.copy_from_slice(&(scaled << 8).to_le_bytes());
                }
                WireSampleFormat::Int32Le => {
                    let v = i32::from_le_bytes([s[0], s[1], s[2], s[3]]);
                    let scaled = ((v as f64) * (g as f64))
                        .round()
                        .clamp(i32::MIN as f64, i32::MAX as f64) as i32;
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Float32Le => {
                    let v = f32::from_le_bytes([s[0], s[1], s[2], s[3]]);
                    let scaled = if v.is_finite() { v * g } else { 0.0 };
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Float64Le => {
                    let v = f64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]);
                    let scaled = if v.is_finite() { v * (g as f64) } else { 0.0 };
                    s.copy_from_slice(&scaled.to_le_bytes());
                }
                WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => {}
            }
        }
    }
}

/// RT-safe sample sanitizer: converts non-finite (`NaN`/`Inf`) samples to `0.0` before clamping.
#[inline(always)]
fn sanitize_and_clamp_f32(sample: f32, max_pos: f32) -> f32 {
    if sample.is_finite() {
        sample.clamp(-1.0, max_pos)
    } else {
        0.0
    }
}

#[inline]
fn read_wire_sample_f64(bytes: &[u8], wire: WireSampleFormat) -> f64 {
    match wire {
        WireSampleFormat::Int16Le => {
            i16::from_le_bytes([bytes[0], bytes[1]]) as f64 / 32_768.0
        }
        WireSampleFormat::Int24PackedLe => {
            let sign = if bytes[2] & 0x80 != 0 { 0xFF } else { 0x00 };
            let v = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], sign]);
            v as f64 / 8_388_608.0
        }
        WireSampleFormat::Int24In32MsbLe => {
            let v = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) >> 8;
            v as f64 / 8_388_608.0
        }
        WireSampleFormat::Int32Le => {
            let v = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            v as f64 / 2_147_483_648.0
        }
        WireSampleFormat::Float32Le => {
            f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64
        }
        WireSampleFormat::Float64Le => f64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => 0.0,
    }
}

#[inline]
fn write_wire_sample_f64(dst: &mut [u8], val: f64, wire: WireSampleFormat) {
    let clamped = if val.is_finite() {
        val.clamp(-1.0, 1.0)
    } else {
        0.0
    };
    match wire {
        WireSampleFormat::Int16Le => {
            let s = (clamped * 32_768.0)
                .round()
                .clamp(i16::MIN as f64, i16::MAX as f64) as i16;
            dst.copy_from_slice(&s.to_le_bytes());
        }
        WireSampleFormat::Int24PackedLe => {
            let s = (clamped * 8_388_608.0)
                .round()
                .clamp(-8_388_608.0, 8_388_607.0) as i32;
            let le = s.to_le_bytes();
            dst[0] = le[0];
            dst[1] = le[1];
            dst[2] = le[2];
        }
        WireSampleFormat::Int24In32MsbLe => {
            let s = (clamped * 8_388_608.0)
                .round()
                .clamp(-8_388_608.0, 8_388_607.0) as i32;
            dst.copy_from_slice(&(s << 8).to_le_bytes());
        }
        WireSampleFormat::Int32Le => {
            let s = (clamped * 2_147_483_648.0)
                .round()
                .clamp(i32::MIN as f64, i32::MAX as f64) as i32;
            dst.copy_from_slice(&s.to_le_bytes());
        }
        WireSampleFormat::Float32Le => {
            dst.copy_from_slice(&(clamped as f32).to_le_bytes());
        }
        WireSampleFormat::Float64Le => {
            dst.copy_from_slice(&clamped.to_le_bytes());
        }
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => {}
    }
}

/// Linearly micro-crossfades interleaved wire bytes from `active` (`1 - t`) into `standby` (`t`).
/// Strictly zero-allocation and lock-free.
#[inline]
pub(crate) fn crossfade_wire_bytes(
    active_bytes: &[u8],
    standby_bytes: &[u8],
    out: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    crossfade_pos: &mut usize,
    crossfade_frames: usize,
) -> usize {
    let ch = channels.max(1);
    let bps = wire.bytes_per_sample();
    let bpf = bps * ch;
    if bpf == 0 || out.len() < bpf {
        return 0;
    }
    let frames = (out.len() / bpf).min(standby_bytes.len() / bpf);
    if frames == 0 {
        return 0;
    }
    if matches!(
        wire,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    ) {
        let byte_len = frames * bpf;
        out[..byte_len].copy_from_slice(&standby_bytes[..byte_len]);
        *crossfade_pos = crossfade_frames;
        return byte_len;
    }
    let total_cf = crossfade_frames.max(1) as f64;
    for f in 0..frames {
        *crossfade_pos = (*crossfade_pos).saturating_add(1);
        let t = ((*crossfade_pos as f64) / total_cf).clamp(0.0, 1.0);
        let ga = 1.0 - t;
        let gb = t;
        let frame_off = f * bpf;
        for c in 0..ch {
            let off = frame_off + c * bps;
            let a = if off + bps <= active_bytes.len() {
                read_wire_sample_f64(&active_bytes[off..off + bps], wire)
            } else {
                0.0
            };
            let b = read_wire_sample_f64(&standby_bytes[off..off + bps], wire);
            write_wire_sample_f64(&mut out[off..off + bps], a * ga + b * gb, wire);
        }
    }
    frames * bpf
}

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

/// Default paused idle duration before releasing proxy RAM LRU caches & idle HTTP sockets (10 minutes).
pub const DEFAULT_IDLE_RECLAIM_THRESHOLD: Duration = Duration::from_secs(600);

#[derive(Debug, Clone, Default)]
struct TrackReplayGainTags {
    track_db: Option<f64>,
    album_db: Option<f64>,
    track_peak: Option<f64>,
    album_peak: Option<f64>,
    /// True when originating from a remote streaming `StreamSourceSpec` (`DirectRange`,
    /// `SegmentedManifest`, `EncryptedRange`), enabling automatic loudness normalization even
    /// when user ReplayGain mode is `Off` (still bypassed in Strict Bit-Perfect / DSP bypass).
    from_streaming_spec: bool,
}

impl TrackReplayGainTags {
    fn from_stream(stream: &StreamSource) -> Self {
        Self {
            track_db: stream.replay_gain_track_db,
            album_db: stream.replay_gain_album_db,
            track_peak: stream.replay_gain_track_peak,
            album_peak: stream.replay_gain_album_peak,
            from_streaming_spec: false,
        }
    }

    fn from_source_spec(spec: &StreamSourceSpec) -> Self {
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

    fn with_metadata_fallback(mut self, meta: Option<&DecodedTrackMetadata>) -> Self {
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

    fn stream_key(&self) -> Option<StreamKey> {
        match self {
            Self::Legacy(_) => None,
            Self::SourceSpec(spec) => Some(spec.key().clone()),
        }
    }

    fn source_spec(&self) -> Option<&StreamSourceSpec> {
        match self {
            Self::Legacy(_) => None,
            Self::SourceSpec(spec) => Some(spec),
        }
    }

    fn replay_gain_tags(&self) -> TrackReplayGainTags {
        match self {
            Self::Legacy(stream) => TrackReplayGainTags::from_stream(stream),
            Self::SourceSpec(spec) => TrackReplayGainTags::from_source_spec(spec),
        }
    }

    fn open_decoder_with_refresh(
        &self,
        inner: &Arc<PlayerInner>,
        cancel: CancellationToken,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        self.open_decoder_with_options(inner, cancel, refresh_handler, false)
    }

    fn open_decoder_with_options(
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
                Some(Arc::downgrade(inner)),
            ),
        }
    }
}

fn source_spec_display_path(spec: &StreamSourceSpec) -> PathBuf {
    match spec {
        StreamSourceSpec::DirectRange { url, .. }
        | StreamSourceSpec::EncryptedRange { url, .. } => PathBuf::from(url),
        StreamSourceSpec::SegmentedManifest {
            manifest_url_or_xml,
            key,
            ..
        } => {
            if manifest_url_or_xml.trim_start().starts_with('<') {
                PathBuf::from(format!("dash://{}:{}:{}", key.provider_id, key.track_id, key.quality_key))
            } else {
                PathBuf::from(manifest_url_or_xml)
            }
        }
        StreamSourceSpec::LocalFile { path, .. } => PathBuf::from(path),
        StreamSourceSpec::ExternalBackend { track_uri, .. } => PathBuf::from(track_uri),
    }
}

fn source_spec_default_label(spec: &StreamSourceSpec) -> String {
    match spec {
        StreamSourceSpec::LocalFile { .. } => "Local Library".to_string(),
        _ => {
            let key = spec.key();
            if key.quality_key.is_empty() {
                key.provider_id.clone()
            } else {
                format!("{} ({})", key.provider_id, key.quality_key)
            }
        }
    }
}

enum PlayerCommand {
    Start {
        session_id: u64,
        decoder: Box<dyn AudioDecoder>,
        path: PathBuf,
        source_label: String,
        origin: PlayerOrigin,
        cancel_token: CancellationToken,
        ack_tx: mpsc::SyncSender<Result<(), CoreAudioError>>,
    },
    FormatSwitchNext {
        session_id: u64,
        decoder: Box<dyn AudioDecoder>,
        path: PathBuf,
        source_label: String,
        origin: PlayerOrigin,
        cancel_token: CancellationToken,
        rg_tags: TrackReplayGainTags,
    },
    ReopenForFormatChange {
        session_id: u64,
        #[allow(dead_code)]
        new_format: AudioFormat,
        resume_pos_ms: u64,
    },
    HotReloadSpec {
        session_id: u64,
        new_spec: StreamSourceSpec,
        resume_ms: u64,
    },
    HardwareDeviceEvent(DeviceEvent),
    RerouteOutput {
        ack_tx: mpsc::SyncSender<Result<(), CoreAudioError>>,
        recover_device_lost: bool,
    },
    Pause,
    Resume,
    Stop,
    SeekMs {
        was_ended: bool,
    },
    RetireDeck {
        deck_idx: usize,
        #[allow(dead_code)]
        deck_gen: u64,
    },
    ReopenOntoStandby {
        from_deck: usize,
        to_deck: usize,
        to_deck_gen: u64,
        is_manual_skip: bool,
        is_mismatch_recovery: bool,
    },
    TriggerAutoStandby,
    Shutdown,
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RtTransitionKind {
    GaplessFlip = 1,
    CrossRateDrain = 2,
    ManualSkipFlip = 3,
    ManualSkipDrain = 4,
    MismatchCrossfadeFlip = 5,
    MismatchDrain = 6,
}

impl RtTransitionKind {
    #[inline]
    fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::GaplessFlip),
            2 => Some(Self::CrossRateDrain),
            3 => Some(Self::ManualSkipFlip),
            4 => Some(Self::ManualSkipDrain),
            5 => Some(Self::MismatchCrossfadeFlip),
            6 => Some(Self::MismatchDrain),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RtTransitionEvent {
    kind: RtTransitionKind,
    from_deck: u8,
    to_deck: u8,
    to_deck_gen: u64,
}

impl RtTransitionEvent {
    #[inline]
    fn pack(self) -> u64 {
        ((self.kind as u64) & 0xFF)
            | (((self.from_deck as u64) & 0xFF) << 8)
            | (((self.to_deck as u64) & 0xFF) << 16)
            | ((self.to_deck_gen & 0xFF_FFFF_FFFF) << 24)
    }

    #[inline]
    fn unpack(raw: u64) -> Option<Self> {
        let kind = RtTransitionKind::from_u8((raw & 0xFF) as u8)?;
        Some(Self {
            kind,
            from_deck: ((raw >> 8) & 0xFF) as u8,
            to_deck: ((raw >> 16) & 0xFF) as u8,
            to_deck_gen: raw >> 24,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StandbyWakeState {
    Parked,
    Promoted,
    Cancelled,
}

struct DeckDecodeHandle {
    #[allow(dead_code)]
    deck_gen: u64,
    cancel_flag: Arc<AtomicBool>,
    cancel_token: CancellationToken,
    wake: Arc<(Mutex<StandbyWakeState>, Condvar)>,
    join_handle: Option<JoinHandle<Option<Box<dyn AudioDecoder>>>>,
}

#[derive(Clone)]
struct DeckMetadataSnapshot {
    path: PathBuf,
    source_label: String,
    origin: PlayerOrigin,
    format: AudioFormat,
    #[allow(dead_code)]
    unified_format: UnifiedAudioFormat,
    negotiated: NegotiatedFormat,
    duration_ms: u64,
    pcm_rate: u32,
    out_rate: u32,
    out_channels: u16,
    rg_tags: TrackReplayGainTags,
    verification: AudioVerificationEngine,
    api_label: String,
    device_name: String,
    backend: OutputBackendKind,
    active_device_id: String,
    expected_stamp: u64,
    is_wire: bool,
    resampled_to_hz: Option<u32>,
}

#[derive(Debug, Clone)]
struct ActiveOutputProfile {
    #[allow(dead_code)]
    session_id: u64,
    is_wire: bool,
    uses_dual_feeder: bool,
    output_mode: OutputMode,
    wire_format: WireSampleFormat,
    out_rate: u32,
    out_channels: u16,
}

struct RtPcmInboxPayload {
    consumer: Consumer<f32>,
    ver_tap: Option<VerificationTapProducer>,
    watermark_samples: usize,
    out_rate: u32,
    out_channels: u16,
    deck_gen: u64,
    last_ring_epoch: u64,
}

pub(crate) struct RtWireInboxPayload {
    consumer: Consumer<u8>,
    ver_tap: VerificationTapProducer,
    watermark_bytes: usize,
    wire: WireSampleFormat,
    out_rate: u32,
    out_channels: u16,
    expected_stamp: u64,
    deck_gen: u64,
    last_ring_epoch: u64,
}

const RT_EVENT_RING_LEN: usize = 16;
const RT_RETIRE_RING_LEN: usize = 16;

pub(crate) struct DualDeckControl {
    active_deck_idx: Arc<AtomicU8>,
    deck_states: [Arc<AtomicU8>; 2],
    deck_keys: Arc<RwLock<[Option<StreamKey>; 2]>>,
    deck_eof_flags: [Arc<AtomicBool>; 2],
    deck_buffered_ms: [Arc<AtomicU64>; 2],
    deck_gens: [AtomicU64; 2],
    next_deck_gen: AtomicU64,
    standby_buffered_ms: Arc<AtomicU64>,
    manual_zero_latency_switches: Arc<AtomicU64>,
    format_mismatch_recoveries: Arc<AtomicU64>,
    standby_compatible: [Arc<AtomicBool>; 2],
    standby_is_mismatch_recovery: [Arc<AtomicBool>; 2],
    standby_target_pts_ms: [Arc<AtomicU64>; 2],
    standby_target_frame: [Arc<AtomicU64>; 2],
    deck_meta: [RwLock<Option<DeckMetadataSnapshot>>; 2],
    active_profile: RwLock<Option<ActiveOutputProfile>>,
    decode_entries: [Mutex<Option<DeckDecodeHandle>>; 2],
    standby_pending_pcm: [Mutex<Option<RtPcmInboxPayload>>; 2],
    standby_pending_wire: [Mutex<Option<RtWireInboxPayload>>; 2],
    pcm_inbox: [AtomicPtr<RtPcmInboxPayload>; 2],
    wire_inbox: [AtomicPtr<RtWireInboxPayload>; 2],
    pcm_retire_ring: [AtomicPtr<RtPcmInboxPayload>; RT_RETIRE_RING_LEN],
    pcm_retire_head: AtomicUsize,
    wire_retire_ring: [AtomicPtr<RtWireInboxPayload>; RT_RETIRE_RING_LEN],
    wire_retire_head: AtomicUsize,
    skip_request_seq: AtomicU64,
    skip_handled_seq: AtomicU64,
    skip_target_deck: AtomicU8,
    skip_lock: Mutex<()>,
    flip_done_sync: (Mutex<u64>, Condvar),
    mismatch_armed: AtomicBool,
    mismatch_target_deck: AtomicU8,
    mismatch_align_frame: AtomicU64,
    mismatch_resume_frame: AtomicU64,
    rt_events: [AtomicU64; RT_EVENT_RING_LEN],
    rt_event_head: AtomicUsize,
    rt_event_tail: AtomicUsize,
    relay_thread: OnceLock<thread::Thread>,
    relay_stop: AtomicBool,
}

impl DualDeckControl {
    fn new() -> Self {
        Self {
            active_deck_idx: Arc::new(AtomicU8::new(0)),
            deck_states: [
                Arc::new(AtomicU8::new(DeckState::Idle as u8)),
                Arc::new(AtomicU8::new(DeckState::Idle as u8)),
            ],
            deck_keys: Arc::new(RwLock::new([None, None])),
            deck_eof_flags: [
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
            ],
            deck_buffered_ms: [
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicU64::new(0)),
            ],
            deck_gens: [AtomicU64::new(0), AtomicU64::new(0)],
            next_deck_gen: AtomicU64::new(1),
            standby_buffered_ms: Arc::new(AtomicU64::new(0)),
            manual_zero_latency_switches: Arc::new(AtomicU64::new(0)),
            format_mismatch_recoveries: Arc::new(AtomicU64::new(0)),
            standby_compatible: [
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
            ],
            standby_is_mismatch_recovery: [
                Arc::new(AtomicBool::new(false)),
                Arc::new(AtomicBool::new(false)),
            ],
            standby_target_pts_ms: [
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicU64::new(0)),
            ],
            standby_target_frame: [
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicU64::new(0)),
            ],
            deck_meta: [RwLock::new(None), RwLock::new(None)],
            active_profile: RwLock::new(None),
            decode_entries: [Mutex::new(None), Mutex::new(None)],
            standby_pending_pcm: [Mutex::new(None), Mutex::new(None)],
            standby_pending_wire: [Mutex::new(None), Mutex::new(None)],
            pcm_inbox: [AtomicPtr::new(null_mut()), AtomicPtr::new(null_mut())],
            wire_inbox: [AtomicPtr::new(null_mut()), AtomicPtr::new(null_mut())],
            pcm_retire_ring: std::array::from_fn(|_| AtomicPtr::new(null_mut())),
            pcm_retire_head: AtomicUsize::new(0),
            wire_retire_ring: std::array::from_fn(|_| AtomicPtr::new(null_mut())),
            wire_retire_head: AtomicUsize::new(0),
            skip_request_seq: AtomicU64::new(0),
            skip_handled_seq: AtomicU64::new(0),
            skip_target_deck: AtomicU8::new(1),
            skip_lock: Mutex::new(()),
            flip_done_sync: (Mutex::new(0), Condvar::new()),
            mismatch_armed: AtomicBool::new(false),
            mismatch_target_deck: AtomicU8::new(1),
            mismatch_align_frame: AtomicU64::new(0),
            mismatch_resume_frame: AtomicU64::new(0),
            rt_events: std::array::from_fn(|_| AtomicU64::new(0)),
            rt_event_head: AtomicUsize::new(0),
            rt_event_tail: AtomicUsize::new(0),
            relay_thread: OnceLock::new(),
            relay_stop: AtomicBool::new(false),
        }
    }

    #[inline]
    fn active_idx(&self) -> usize {
        (self.active_deck_idx.load(Ordering::Acquire) & 1) as usize
    }

    #[inline]
    fn standby_idx(&self) -> usize {
        1 - self.active_idx()
    }

    #[inline]
    fn deck_state(&self, idx: usize) -> DeckState {
        DeckState::from_u8(self.deck_states[idx & 1].load(Ordering::Acquire))
    }

    #[inline]
    fn deck_gen_for(&self, idx: usize) -> u64 {
        self.deck_gens[idx & 1].load(Ordering::Acquire)
    }

    fn alloc_deck_gen(&self, idx: usize) -> u64 {
        let dgen = self.next_deck_gen.fetch_add(1, Ordering::SeqCst).max(1);
        self.deck_gens[idx & 1].store(dgen, Ordering::SeqCst);
        dgen
    }

    fn set_deck_key(&self, idx: usize, key: Option<StreamKey>) {
        if let Ok(mut g) = self.deck_keys.write() {
            g[idx & 1] = key;
        }
    }

    #[inline]
    fn unpark_relay(&self) {
        if let Some(th) = self.relay_thread.get() {
            th.unpark();
        }
    }

    fn stop_relay(&self) {
        self.relay_stop.store(true, Ordering::SeqCst);
        self.unpark_relay();
    }

    #[inline]
    fn push_rt_event(&self, kind: RtTransitionKind, from_deck: u8, to_deck: u8, to_deck_gen: u64) {
        let idx = self.rt_event_head.fetch_add(1, Ordering::Relaxed) % RT_EVENT_RING_LEN;
        let packed = RtTransitionEvent {
            kind,
            from_deck,
            to_deck,
            to_deck_gen,
        }
        .pack();
        self.rt_events[idx].store(packed, Ordering::Release);
        self.unpark_relay();
    }

    fn pop_rt_event(&self) -> Option<RtTransitionEvent> {
        let head = self.rt_event_head.load(Ordering::Acquire);
        let mut tail = self.rt_event_tail.load(Ordering::Relaxed);
        while tail < head {
            let slot = tail % RT_EVENT_RING_LEN;
            let raw = self.rt_events[slot].swap(0, Ordering::AcqRel);
            tail += 1;
            self.rt_event_tail.store(tail, Ordering::Release);
            if raw != 0
                && let Some(evt) = RtTransitionEvent::unpack(raw)
            {
                return Some(evt);
            }
        }
        None
    }

    #[inline]
    fn retire_pcm_ptr(&self, ptr: *mut RtPcmInboxPayload) {
        if ptr.is_null() {
            return;
        }
        let slot = self.pcm_retire_head.fetch_add(1, Ordering::Relaxed) % RT_RETIRE_RING_LEN;
        let displaced = self.pcm_retire_ring[slot].swap(ptr, Ordering::AcqRel);
        let _ = displaced;
        self.unpark_relay();
    }

    #[inline]
    fn retire_wire_ptr(&self, ptr: *mut RtWireInboxPayload) {
        if ptr.is_null() {
            return;
        }
        let slot = self.wire_retire_head.fetch_add(1, Ordering::Relaxed) % RT_RETIRE_RING_LEN;
        let displaced = self.wire_retire_ring[slot].swap(ptr, Ordering::AcqRel);
        let _ = displaced;
        self.unpark_relay();
    }

    fn drain_retired_payloads(&self) {
        for slot in &self.pcm_retire_ring {
            let ptr = slot.swap(null_mut(), Ordering::AcqRel);
            if !ptr.is_null() {
                unsafe {
                    drop(Box::from_raw(ptr));
                }
            }
        }
        for slot in &self.wire_retire_ring {
            let ptr = slot.swap(null_mut(), Ordering::AcqRel);
            if !ptr.is_null() {
                unsafe {
                    drop(Box::from_raw(ptr));
                }
            }
        }
    }

    fn clear_inboxes_for_deck(&self, idx: usize) {
        let i = idx & 1;
        let p = self.pcm_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !p.is_null() {
            unsafe {
                drop(Box::from_raw(p));
            }
        }
        let w = self.wire_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !w.is_null() {
            unsafe {
                drop(Box::from_raw(w));
            }
        }
        if let Ok(mut g) = self.standby_pending_pcm[i].lock() {
            *g = None;
        }
        if let Ok(mut g) = self.standby_pending_wire[i].lock() {
            *g = None;
        }
    }

    fn send_pcm_inbox(&self, idx: usize, payload: RtPcmInboxPayload) {
        self.drain_retired_payloads();
        let boxed = Box::into_raw(Box::new(payload));
        let prev = self.pcm_inbox[idx & 1].swap(boxed, Ordering::AcqRel);
        if !prev.is_null() {
            unsafe {
                drop(Box::from_raw(prev));
            }
        }
    }

    fn send_wire_inbox(&self, idx: usize, payload: RtWireInboxPayload) {
        self.drain_retired_payloads();
        let boxed = Box::into_raw(Box::new(payload));
        let prev = self.wire_inbox[idx & 1].swap(boxed, Ordering::AcqRel);
        if !prev.is_null() {
            unsafe {
                drop(Box::from_raw(prev));
            }
        }
    }

    fn take_standby_pcm_payload(&self, idx: usize) -> Option<RtPcmInboxPayload> {
        let i = idx & 1;
        let ptr = self.pcm_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !ptr.is_null() {
            return Some(unsafe { *Box::from_raw(ptr) });
        }
        self.standby_pending_pcm[i]
            .lock()
            .ok()
            .and_then(|mut g| g.take())
    }

    fn take_standby_wire_payload(&self, idx: usize) -> Option<RtWireInboxPayload> {
        let i = idx & 1;
        let ptr = self.wire_inbox[i].swap(null_mut(), Ordering::AcqRel);
        if !ptr.is_null() {
            return Some(unsafe { *Box::from_raw(ptr) });
        }
        self.standby_pending_wire[i]
            .lock()
            .ok()
            .and_then(|mut g| g.take())
    }

    fn is_compatible_with_profile(snap: &DeckMetadataSnapshot, prof: &ActiveOutputProfile) -> bool {
        if !prof.uses_dual_feeder {
            return false;
        }
        if prof.is_wire {
            snap.is_wire
                && snap.negotiated.output_mode == prof.output_mode
                && snap.negotiated.wire_format == prof.wire_format
                && snap.out_rate == prof.out_rate
                && snap.out_channels == prof.out_channels
        } else {
            !snap.is_wire && snap.out_rate == prof.out_rate && snap.out_channels == prof.out_channels
        }
    }

    fn rebind_standby_for_new_profile(&self, prof: ActiveOutputProfile) {
        let sb = self.standby_idx();
        if self.deck_state(sb) == DeckState::StandbyReady {
            let compat = self.deck_meta[sb]
                .read()
                .ok()
                .and_then(|g| {
                    g.as_ref()
                        .map(|snap| Self::is_compatible_with_profile(snap, &prof))
                })
                .unwrap_or(false);
            self.standby_compatible[sb].store(compat, Ordering::SeqCst);
            if compat {
                if prof.is_wire {
                    if let Some(payload) = self.standby_pending_wire[sb]
                        .lock()
                        .ok()
                        .and_then(|mut g| g.take())
                    {
                        self.send_wire_inbox(sb, payload);
                    }
                } else if let Some(payload) = self.standby_pending_pcm[sb]
                    .lock()
                    .ok()
                    .and_then(|mut g| g.take())
                {
                    self.send_pcm_inbox(sb, payload);
                }
            }
        }
        if let Ok(mut g) = self.active_profile.write() {
            *g = Some(prof);
        }
    }

    fn retire_inactive_deck(&self, idx: usize) {
        let i = idx & 1;
        if self.active_idx() == i {
            return;
        }
        let st = self.deck_state(i);
        if st != DeckState::Idle && st != DeckState::Draining {
            return;
        }
        let _ = self.cancel_and_join_deck(i);
    }

    fn promote_decode_thread(&self, idx: usize) {
        let i = idx & 1;
        if let Ok(guard) = self.decode_entries[i].lock()
            && let Some(ref entry) = *guard
            && let Ok(mut wg) = entry.wake.0.lock()
        {
            *wg = StandbyWakeState::Promoted;
            entry.wake.1.notify_all();
        }
    }

    fn cancel_and_join_deck(&self, idx: usize) -> Option<Box<dyn AudioDecoder>> {
        let i = idx & 1;
        // Bump deck_gen first so any in-flight open for this deck immediately notices replacement.
        self.alloc_deck_gen(i);
        let entry_opt = self.decode_entries[i].lock().ok().and_then(|mut g| g.take());
        let mut reused = None;
        if let Some(mut entry) = entry_opt {
            entry.cancel_token.cancel();
            entry.cancel_flag.store(true, Ordering::SeqCst);
            if let Ok(mut wg) = entry.wake.0.lock() {
                *wg = StandbyWakeState::Cancelled;
                entry.wake.1.notify_all();
            }
            if let Some(jh) = entry.join_handle.take() {
                reused = jh.join().ok().flatten();
            }
        }
        self.clear_inboxes_for_deck(i);
        self.drain_retired_payloads();
        self.deck_states[i].store(DeckState::Idle as u8, Ordering::SeqCst);
        self.set_deck_key(i, None);
        self.deck_eof_flags[i].store(false, Ordering::SeqCst);
        self.deck_buffered_ms[i].store(0, Ordering::Relaxed);
        self.standby_compatible[i].store(false, Ordering::SeqCst);
        self.standby_is_mismatch_recovery[i].store(false, Ordering::SeqCst);
        self.standby_target_pts_ms[i].store(0, Ordering::SeqCst);
        self.standby_target_frame[i].store(0, Ordering::SeqCst);
        if let Ok(mut mg) = self.deck_meta[i].write() {
            *mg = None;
        }
        reused
    }

    fn cancel_standby(&self) {
        let sb = self.standby_idx();
        self.mismatch_armed.store(false, Ordering::Release);
        self.standby_buffered_ms.store(0, Ordering::Relaxed);
        let _ = self.cancel_and_join_deck(sb);
    }

    fn notify_flip_done(&self) {
        if let Ok(mut g) = self.flip_done_sync.0.lock() {
            *g = g.wrapping_add(1);
            self.flip_done_sync.1.notify_all();
        }
    }
}

impl Drop for DualDeckControl {
    fn drop(&mut self) {
        self.stop_relay();
        self.clear_inboxes_for_deck(0);
        self.clear_inboxes_for_deck(1);
        self.drain_retired_payloads();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PcmRenderOutcome {
    Rendered,
    FadeOut,
    Silent,
    Draining,
    Ended,
}

struct DualDeckPcmFeeder {
    dual: Arc<DualDeckControl>,
    inner: Arc<PlayerInner>,
    session_id: u64,
    slot_ptrs: [*mut RtPcmInboxPayload; 2],
    out_rate: u32,
    out_channels: usize,
    buffering_gate: bool,
    fade: LinearFadeState,
    skip_fade: LinearFadeState,
    active_skip_seq: Option<(u64, usize)>,
    crossfade_active: bool,
    crossfade_pos: usize,
    crossfade_frames: usize,
    crossfade_target_deck: usize,
    crossfade_resume_frame: u64,
    drain_notified: bool,
}

unsafe impl Send for DualDeckPcmFeeder {}

impl DualDeckPcmFeeder {
    fn new(
        dual: Arc<DualDeckControl>,
        inner: Arc<PlayerInner>,
        session_id: u64,
        active_deck: usize,
        initial_payload: RtPcmInboxPayload,
        fade_ctrl: &AudioFadeControl,
    ) -> Self {
        let out_rate = initial_payload.out_rate.max(8_000);
        let out_channels = initial_payload.out_channels.max(1) as usize;
        let watermark = initial_payload.watermark_samples;
        let mut slot_ptrs = [null_mut(), null_mut()];
        slot_ptrs[active_deck & 1] = Box::into_raw(Box::new(initial_payload));
        let crossfade_frames =
            ((out_rate as u64 * MISMATCH_CROSSFADE_MS) / 1000).clamp(32, 2048) as usize;
        let mut feeder = Self {
            dual,
            inner: Arc::clone(&inner),
            session_id,
            slot_ptrs,
            out_rate,
            out_channels,
            buffering_gate: watermark > 0,
            fade: LinearFadeState::new(
                out_rate,
                fade_ctrl.fade_in_enabled(),
                fade_ctrl.fade_out_enabled(),
                inner.paused.load(Ordering::Acquire),
            ),
            skip_fade: LinearFadeState::new(out_rate, false, true, false),
            active_skip_seq: None,
            crossfade_active: false,
            crossfade_pos: 0,
            crossfade_frames,
            crossfade_target_deck: 1 - (active_deck & 1),
            crossfade_resume_frame: 0,
            drain_notified: false,
        };
        feeder.poll_inbox();
        feeder
    }

    #[inline]
    fn poll_inbox(&mut self) {
        for i in 0..2 {
            let incoming = self.dual.pcm_inbox[i].swap(null_mut(), Ordering::AcqRel);
            if !incoming.is_null() {
                let old = std::mem::replace(&mut self.slot_ptrs[i], incoming);
                if !old.is_null() {
                    self.dual.retire_pcm_ptr(old);
                }
            }
        }
    }

    #[inline]
    fn flip_to_standby(
        &self,
        from_deck: usize,
        to_deck: usize,
        kind: RtTransitionKind,
        resume_frame: u64,
    ) {
        let tgen = unsafe { (*self.slot_ptrs[to_deck]).deck_gen };
        self.dual
            .active_deck_idx
            .store(to_deck as u8, Ordering::Release);
        self.dual.deck_states[from_deck].store(DeckState::Idle as u8, Ordering::Release);
        self.dual.deck_states[to_deck].store(DeckState::Playing as u8, Ordering::Release);
        self.dual.standby_buffered_ms.store(0, Ordering::Relaxed);
        self.inner
            .frames_rendered
            .store(resume_frame, Ordering::SeqCst);
        self.dual
            .push_rt_event(kind, from_deck as u8, to_deck as u8, tgen);
    }

    fn render_f32(
        &mut self,
        out_f32: &mut [f32],
        wire_scratch: &mut [u8],
        fade_ctrl: &AudioFadeControl,
        max_pos: f32,
    ) -> PcmRenderOutcome {
        self.poll_inbox();

        let ch = self.out_channels.max(1);
        let total_samples = (out_f32.len() / ch) * ch;
        if total_samples == 0 {
            out_f32.fill(0.0);
            return PcmRenderOutcome::Silent;
        }
        let vol = f32::from_bits(self.inner.volume_bits.load(Ordering::Relaxed));
        let cur = self.dual.active_idx();
        let other = 1 - cur;

        let fade_target = fade_ctrl.target();
        if matches!(
            fade_target,
            FadeTarget::PauseFadeOut | FadeTarget::StopFadeOut | FadeTarget::SeekFadeOut
        ) {
            if !self.fade.fade_out_enabled() || self.fade.gain() <= 0.0 || self.slot_ptrs[cur].is_null() {
                self.fade.set_zero();
                fade_ctrl.mark_fade_out_done();
                if fade_target == FadeTarget::SeekFadeOut && !self.slot_ptrs[cur].is_null() {
                    let wm = unsafe { (*self.slot_ptrs[cur]).watermark_samples };
                    self.buffering_gate = wm > 0;
                }
                out_f32.fill(0.0);
                return PcmRenderOutcome::FadeOut;
            }
            let active = unsafe { &mut *self.slot_ptrs[cur] };
            let aligned = active
                .consumer
                .pop_slice_aligned(&mut out_f32[..total_samples], ch);
            if aligned == 0 {
                self.fade.set_zero();
                fade_ctrl.mark_fade_out_done();
                if fade_target == FadeTarget::SeekFadeOut {
                    self.buffering_gate = active.watermark_samples > 0;
                }
                out_f32.fill(0.0);
                return PcmRenderOutcome::FadeOut;
            }
            let frames = aligned / ch;
            let mut written = 0usize;
            for f in 0..frames {
                let g = self.fade.step_frame(FadeDirection::Down);
                for c in 0..ch {
                    let idx = f * ch + c;
                    out_f32[idx] = sanitize_and_clamp_f32(out_f32[idx] * vol * g, max_pos);
                }
                written = (f + 1) * ch;
                if self.fade.gain() <= 0.0 {
                    break;
                }
            }
            if written < out_f32.len() {
                out_f32[written..].fill(0.0);
            }
            if self.fade.gain() <= 0.0 || aligned < total_samples {
                self.fade.set_zero();
                fade_ctrl.mark_fade_out_done();
                if fade_target == FadeTarget::SeekFadeOut {
                    self.buffering_gate = active.watermark_samples > 0;
                }
            }
            return PcmRenderOutcome::FadeOut;
        }

        if self.inner.stopped.load(Ordering::Relaxed)
            || self.inner.paused.load(Ordering::Relaxed)
            || self.inner.current_session_id.load(Ordering::Relaxed) != self.session_id
            || self.slot_ptrs[cur].is_null()
        {
            out_f32.fill(0.0);
            return PcmRenderOutcome::Silent;
        }

        if self.drain_notified
            || self.dual.deck_states[cur].load(Ordering::Acquire) == DeckState::Draining as u8
        {
            out_f32.fill(0.0);
            return PcmRenderOutcome::Draining;
        }

        {
            let active = unsafe { &mut *self.slot_ptrs[cur] };
            let req_ep = active.consumer.requested_epoch();
            if req_ep != active.last_ring_epoch {
                if active.consumer.has_pending_flush()
                    && active.consumer.try_flush_and_ack().is_none()
                {
                    out_f32.fill(0.0);
                    return PcmRenderOutcome::Silent;
                }
                active.last_ring_epoch = active.consumer.epoch();
                self.buffering_gate = active.watermark_samples > 0;
                self.fade.reset_for_play_start();
            }

            let avail_before = active.consumer.available_read();
            let frames_avail = (avail_before / ch) as u64;
            let rate_u64 = self.out_rate.max(8_000) as u64;
            let bms = (frames_avail * 1000) / rate_u64;
            self.inner.buffered_ms.store(bms, Ordering::Relaxed);
            self.dual.deck_buffered_ms[cur].store(bms, Ordering::Relaxed);

            if self.buffering_gate {
                if avail_before >= active.watermark_samples
                    || self.dual.deck_eof_flags[cur].load(Ordering::Acquire)
                    || self.dual.skip_request_seq.load(Ordering::Acquire)
                        != self.dual.skip_handled_seq.load(Ordering::Acquire)
                {
                    self.buffering_gate = false;
                } else {
                    out_f32.fill(0.0);
                    return PcmRenderOutcome::Silent;
                }
            }
        }

        // Check manual skip trigger
        let req_seq = self.dual.skip_request_seq.load(Ordering::Acquire);
        let handled_seq = self.dual.skip_handled_seq.load(Ordering::Acquire);
        if self.active_skip_seq.is_none() && req_seq != handled_seq {
            let target = (self.dual.skip_target_deck.load(Ordering::Acquire) & 1) as usize;
            if target == other
                && self.dual.deck_states[other].load(Ordering::Acquire)
                    == DeckState::StandbyReady as u8
            {
                let compat = self.dual.standby_compatible[other].load(Ordering::Acquire)
                    && !self.slot_ptrs[other].is_null();
                let fade_ms = if compat {
                    MICRO_FADE_MS
                } else {
                    MISMATCH_CROSSFADE_MS
                };
                let fade_frames =
                    ((self.out_rate.max(8_000) as u64 * fade_ms) / 1000).clamp(32, 4096);
                self.skip_fade = LinearFadeState::with_frames(fade_frames, false, true, false);
                self.skip_fade.set_gain(self.fade.gain().max(0.01));
                self.active_skip_seq = Some((req_seq, target));
            }
        }

        // Check FormatMismatch alignment trigger
        if !self.crossfade_active
            && self.active_skip_seq.is_none()
            && self.dual.mismatch_armed.load(Ordering::Acquire)
        {
            let target = (self.dual.mismatch_target_deck.load(Ordering::Acquire) & 1) as usize;
            if target == other
                && self.dual.deck_states[other].load(Ordering::Acquire)
                    == DeckState::StandbyReady as u8
            {
                let cur_frame = self.inner.frames_rendered.load(Ordering::Relaxed);
                let align_frame = self.dual.mismatch_align_frame.load(Ordering::Acquire);
                if cur_frame >= align_frame {
                    if self.dual.standby_compatible[other].load(Ordering::Acquire)
                        && !self.slot_ptrs[other].is_null()
                    {
                        self.crossfade_active = true;
                        self.crossfade_pos = 0;
                        self.crossfade_target_deck = target;
                        self.crossfade_resume_frame =
                            self.dual.mismatch_resume_frame.load(Ordering::Acquire);
                    } else {
                        let rapid_frames =
                            ((self.out_rate.max(8_000) as u64 * MISMATCH_CROSSFADE_MS) / 1000)
                                .clamp(32, 2048);
                        self.skip_fade =
                            LinearFadeState::with_frames(rapid_frames, false, true, false);
                        self.skip_fade.set_gain(self.fade.gain().max(0.01));
                        self.active_skip_seq = Some((u64::MAX, target));
                    }
                }
            }
        }

        let mut written = 0usize;

        // 1. Active manual skip / rapid drain fade-out
        if let Some((skip_seq, target)) = self.active_skip_seq {
            let active = unsafe { &mut *self.slot_ptrs[cur] };
            let rem_fade_samples = self.skip_fade.remaining_down_frames().max(1) * ch;
            let want = (total_samples - written).min(rem_fade_samples);
            let aligned = active
                .consumer
                .pop_slice_aligned(&mut out_f32[written..written + want], ch);
            let mut faded_samples = 0usize;
            if aligned > 0 {
                let frames = aligned / ch;
                let mut has_nz = false;
                for f in 0..frames {
                    let g = self.skip_fade.step_frame(FadeDirection::Down);
                    for c in 0..ch {
                        let idx = written + f * ch + c;
                        let scaled = sanitize_and_clamp_f32(out_f32[idx] * vol * g, max_pos);
                        if scaled.abs() > 1e-6 {
                            has_nz = true;
                        }
                        out_f32[idx] = scaled;
                        let b = scaled.to_le_bytes();
                        let woff = (f * ch + c) * 4;
                        wire_scratch[woff..woff + 4].copy_from_slice(&b);
                    }
                    faded_samples = (f + 1) * ch;
                    if self.skip_fade.gain() <= 0.0 {
                        break;
                    }
                }
                if faded_samples > 0 {
                    if let Some(ref mut tap) = active.ver_tap {
                        tap.push_wire(&wire_scratch[..faded_samples * 4]);
                    }
                    crate::visualizer::global_tap().feed_wire(
                        &wire_scratch[..faded_samples * 4],
                        WireSampleFormat::Float32Le,
                        ch as u16,
                        self.out_rate,
                    );
                    let f_cnt = (faded_samples / ch) as u64;
                    self.inner.frames_rendered.fetch_add(f_cnt, Ordering::Relaxed);
                    if has_nz {
                        self.inner
                            .nonzero_output_frames
                            .fetch_add(f_cnt, Ordering::Relaxed);
                    }
                    fade_ctrl.mark_audible();
                }
                written += faded_samples;
            }
            if self.skip_fade.gain() <= 0.0 || aligned < want {
                self.active_skip_seq = None;
                if skip_seq != u64::MAX
                    && self.dual.standby_compatible[target].load(Ordering::Acquire)
                    && !self.slot_ptrs[target].is_null()
                {
                    self.flip_to_standby(cur, target, RtTransitionKind::ManualSkipFlip, 0);
                    self.dual
                        .manual_zero_latency_switches
                        .fetch_add(1, Ordering::Release);
                    self.dual.skip_handled_seq.store(skip_seq, Ordering::Release);
                    self.fade.set_unity();
                } else {
                    if written < out_f32.len() {
                        out_f32[written..].fill(0.0);
                    }
                    let kind = if skip_seq == u64::MAX {
                        self.dual.mismatch_armed.store(false, Ordering::Release);
                        RtTransitionKind::MismatchDrain
                    } else {
                        self.dual.skip_handled_seq.store(skip_seq, Ordering::Release);
                        RtTransitionKind::ManualSkipDrain
                    };
                    self.dual.deck_states[cur].store(DeckState::Draining as u8, Ordering::Release);
                    self.drain_notified = true;
                    let tgen = self.dual.deck_gen_for(target);
                    self.dual.push_rt_event(kind, cur as u8, target as u8, tgen);
                    return PcmRenderOutcome::Draining;
                }
            } else {
                return PcmRenderOutcome::Rendered;
            }
        }

        // 2. Active 5 ms micro-crossfade for FormatMismatch recovery
        if self.crossfade_active {
            let cur_now = self.dual.active_idx();
            let target = self.crossfade_target_deck;
            if cur_now != target && !self.slot_ptrs[cur_now].is_null() && !self.slot_ptrs[target].is_null() {
                let (active, standby) = unsafe {
                    (&mut *self.slot_ptrs[cur_now], &mut *self.slot_ptrs[target])
                };
                let mut stack_a = [0.0f32; 2048];
                let mut stack_b = [0.0f32; 2048];
                while self.crossfade_active && written < total_samples {
                    let rem_cf = self.crossfade_frames.saturating_sub(self.crossfade_pos);
                    if rem_cf == 0 {
                        self.crossfade_active = false;
                        break;
                    }
                    let max_chunk_frames = (stack_a.len() / ch).min((total_samples - written) / ch);
                    let cf_frames = rem_cf.min(max_chunk_frames);
                    if cf_frames == 0 {
                        break;
                    }
                    let want = cf_frames * ch;
                    let aligned_a = active.consumer.pop_slice_aligned(&mut stack_a[..want], ch);
                    if aligned_a < want {
                        stack_a[aligned_a..want].fill(0.0);
                    }
                    let aligned_b = standby.consumer.pop_slice_aligned(&mut stack_b[..want], ch);
                    if aligned_b < want {
                        stack_b[aligned_b..want].fill(0.0);
                    }
                    let actual_frames = cf_frames;
                    let mut has_nz = false;
                    for f in 0..actual_frames {
                        self.crossfade_pos += 1;
                        let t = (self.crossfade_pos as f32 / self.crossfade_frames.max(1) as f32)
                            .clamp(0.0, 1.0);
                        let ga = 1.0 - t;
                        let gb = t;
                        for c in 0..ch {
                            let sidx = f * ch + c;
                            let mixed = sanitize_and_clamp_f32(
                                (stack_a[sidx] * ga + stack_b[sidx] * gb) * vol,
                                max_pos,
                            );
                            if mixed.abs() > 1e-6 {
                                has_nz = true;
                            }
                            out_f32[written + sidx] = mixed;
                            let woff = sidx * 4;
                            wire_scratch[woff..woff + 4].copy_from_slice(&mixed.to_le_bytes());
                        }
                    }
                    let cf_samples = actual_frames * ch;
                    if let Some(ref mut tap) = standby.ver_tap {
                        tap.push_wire(&wire_scratch[..cf_samples * 4]);
                    }
                    crate::visualizer::global_tap().feed_wire(
                        &wire_scratch[..cf_samples * 4],
                        WireSampleFormat::Float32Le,
                        ch as u16,
                        self.out_rate,
                    );
                    if has_nz {
                        self.inner
                            .nonzero_output_frames
                            .fetch_add(actual_frames as u64, Ordering::Relaxed);
                    }
                    fade_ctrl.mark_audible();
                    written += cf_samples;
                    if self.crossfade_pos >= self.crossfade_frames {
                        self.crossfade_active = false;
                        self.dual.mismatch_armed.store(false, Ordering::Release);
                        self.flip_to_standby(
                            cur_now,
                            target,
                            RtTransitionKind::MismatchCrossfadeFlip,
                            self.crossfade_resume_frame,
                        );
                        self.dual
                            .format_mismatch_recoveries
                            .fetch_add(1, Ordering::Release);
                        self.fade.set_unity();
                    }
                }
                if written >= total_samples {
                    return PcmRenderOutcome::Rendered;
                }
            } else {
                self.crossfade_active = false;
            }
        }

        // 3. Normal Active playback + inline Gapless / FormatMismatch alignment / Cross-rate drain
        loop {
            if written >= total_samples {
                break;
            }
            let cur_now = self.dual.active_idx();
            let other_now = 1 - cur_now;
            if self.slot_ptrs[cur_now].is_null() {
                out_f32[written..].fill(0.0);
                return PcmRenderOutcome::Silent;
            }
            let mut want = total_samples - written;
            let mut hit_mismatch_boundary = false;
            if !self.crossfade_active && self.dual.mismatch_armed.load(Ordering::Acquire) {
                let m_target = (self.dual.mismatch_target_deck.load(Ordering::Acquire) & 1) as usize;
                if m_target == other_now
                    && self.dual.deck_states[other_now].load(Ordering::Acquire)
                        == DeckState::StandbyReady as u8
                {
                    let cur_frame = self.inner.frames_rendered.load(Ordering::Relaxed);
                    let align_frame = self.dual.mismatch_align_frame.load(Ordering::Acquire);
                    if cur_frame >= align_frame {
                        want = 0;
                        hit_mismatch_boundary = true;
                    } else {
                        let rem_until = (align_frame - cur_frame) as usize * ch;
                        if rem_until < want {
                            want = rem_until;
                            hit_mismatch_boundary = true;
                        }
                    }
                }
            }

            let aligned = if want > 0 {
                let active = unsafe { &mut *self.slot_ptrs[cur_now] };
                let al = active
                    .consumer
                    .pop_slice_aligned(&mut out_f32[written..written + want], ch);
                if al > 0 {
                    let frames = al / ch;
                    let mut has_nz = false;
                    for f in 0..frames {
                        let g = if self.fade.gain() < 1.0 {
                            self.fade.step_frame(FadeDirection::Up)
                        } else {
                            1.0
                        };
                        for c in 0..ch {
                            let idx = written + f * ch + c;
                            let scaled = sanitize_and_clamp_f32(out_f32[idx] * vol * g, max_pos);
                            if scaled.abs() > 1e-6 {
                                has_nz = true;
                            }
                            out_f32[idx] = scaled;
                            let woff = (f * ch + c) * 4;
                            wire_scratch[woff..woff + 4].copy_from_slice(&scaled.to_le_bytes());
                        }
                    }
                    if let Some(ref mut tap) = active.ver_tap {
                        tap.push_wire(&wire_scratch[..al * 4]);
                    }
                    crate::visualizer::global_tap().feed_wire(
                        &wire_scratch[..al * 4],
                        WireSampleFormat::Float32Le,
                        ch as u16,
                        self.out_rate,
                    );
                    fade_ctrl.mark_audible();
                    let f_cnt = frames as u64;
                    self.inner.frames_rendered.fetch_add(f_cnt, Ordering::Relaxed);
                    if has_nz {
                        self.inner
                            .nonzero_output_frames
                            .fetch_add(f_cnt, Ordering::Relaxed);
                    }
                    written += al;
                }
                al
            } else {
                0
            };

            if hit_mismatch_boundary && aligned == want {
                if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                    && !self.slot_ptrs[other_now].is_null()
                {
                    let (active, standby) = unsafe {
                        (&mut *self.slot_ptrs[cur_now], &mut *self.slot_ptrs[other_now])
                    };
                    let resume_frame = self.dual.mismatch_resume_frame.load(Ordering::Acquire);
                    self.crossfade_active = true;
                    self.crossfade_pos = 0;
                    self.crossfade_target_deck = other_now;
                    self.crossfade_resume_frame = resume_frame;

                    let mut stack_a = [0.0f32; 2048];
                    let mut stack_b = [0.0f32; 2048];
                    while self.crossfade_active && written < total_samples {
                        let rem_cf = self.crossfade_frames.saturating_sub(self.crossfade_pos);
                        let max_chunk_frames =
                            (stack_a.len() / ch).min((total_samples - written) / ch);
                        let cf_frames = rem_cf.min(max_chunk_frames);
                        if cf_frames == 0 {
                            break;
                        }
                        let cf_want = cf_frames * ch;
                        let aa = active.consumer.pop_slice_aligned(&mut stack_a[..cf_want], ch);
                        if aa < cf_want {
                            stack_a[aa..cf_want].fill(0.0);
                        }
                        let ab = standby.consumer.pop_slice_aligned(&mut stack_b[..cf_want], ch);
                        if ab < cf_want {
                            stack_b[ab..cf_want].fill(0.0);
                        }
                        let mut has_nz = false;
                        for f in 0..cf_frames {
                            self.crossfade_pos += 1;
                            let t = (self.crossfade_pos as f32
                                / self.crossfade_frames.max(1) as f32)
                                .clamp(0.0, 1.0);
                            let ga = 1.0 - t;
                            let gb = t;
                            for c in 0..ch {
                                let sidx = f * ch + c;
                                let mixed = sanitize_and_clamp_f32(
                                    (stack_a[sidx] * ga + stack_b[sidx] * gb) * vol,
                                    max_pos,
                                );
                                if mixed.abs() > 1e-6 {
                                    has_nz = true;
                                }
                                out_f32[written + sidx] = mixed;
                                let woff = sidx * 4;
                                wire_scratch[woff..woff + 4].copy_from_slice(&mixed.to_le_bytes());
                            }
                        }
                        if let Some(ref mut tap) = standby.ver_tap {
                            tap.push_wire(&wire_scratch[..cf_want * 4]);
                        }
                        crate::visualizer::global_tap().feed_wire(
                            &wire_scratch[..cf_want * 4],
                            WireSampleFormat::Float32Le,
                            ch as u16,
                            self.out_rate,
                        );
                        if has_nz {
                            self.inner
                                .nonzero_output_frames
                                .fetch_add(cf_frames as u64, Ordering::Relaxed);
                        }
                        written += cf_want;
                        if self.crossfade_pos >= self.crossfade_frames {
                            self.crossfade_active = false;
                            self.dual.mismatch_armed.store(false, Ordering::Release);
                            self.flip_to_standby(
                                cur_now,
                                other_now,
                                RtTransitionKind::MismatchCrossfadeFlip,
                                resume_frame,
                            );
                            self.dual
                                .format_mismatch_recoveries
                                .fetch_add(1, Ordering::Release);
                            self.fade.set_unity();
                        }
                    }
                    continue;
                } else {
                    if written < out_f32.len() {
                        out_f32[written..].fill(0.0);
                    }
                    self.dual.mismatch_armed.store(false, Ordering::Release);
                    self.dual.deck_states[cur_now]
                        .store(DeckState::Draining as u8, Ordering::Release);
                    self.drain_notified = true;
                    let tgen = self.dual.deck_gen_for(other_now);
                    self.dual.push_rt_event(
                        RtTransitionKind::MismatchDrain,
                        cur_now as u8,
                        other_now as u8,
                        tgen,
                    );
                    return PcmRenderOutcome::Draining;
                }
            }

            if aligned < want {
                let active_avail = unsafe { (*self.slot_ptrs[cur_now]).consumer.available_read() };
                if self.dual.deck_eof_flags[cur_now].load(Ordering::SeqCst) && active_avail < ch {
                    // Active reached EOF. Check mismatch early-EOF OR normal Standby!
                    if self.dual.mismatch_armed.load(Ordering::Acquire)
                        && self.dual.deck_states[other_now].load(Ordering::Acquire)
                            == DeckState::StandbyReady as u8
                    {
                        if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                            && !self.slot_ptrs[other_now].is_null()
                        {
                            self.crossfade_active = true;
                            self.crossfade_pos = 0;
                            self.crossfade_target_deck = other_now;
                            self.crossfade_resume_frame =
                                self.dual.mismatch_resume_frame.load(Ordering::Acquire);
                            // Run crossfade immediately over remainder with active = 0.0
                            let standby = unsafe { &mut *self.slot_ptrs[other_now] };
                            let mut stack_b = [0.0f32; 2048];
                            while self.crossfade_active && written < total_samples {
                                let rem_cf =
                                    self.crossfade_frames.saturating_sub(self.crossfade_pos);
                                let max_chunk_frames =
                                    (stack_b.len() / ch).min((total_samples - written) / ch);
                                let cf_frames = rem_cf.min(max_chunk_frames);
                                if cf_frames == 0 {
                                    break;
                                }
                                let cf_want = cf_frames * ch;
                                let ab = standby
                                    .consumer
                                    .pop_slice_aligned(&mut stack_b[..cf_want], ch);
                                if ab < cf_want {
                                    stack_b[ab..cf_want].fill(0.0);
                                }
                                let mut has_nz = false;
                                for f in 0..cf_frames {
                                    self.crossfade_pos += 1;
                                    let t = (self.crossfade_pos as f32
                                        / self.crossfade_frames.max(1) as f32)
                                        .clamp(0.0, 1.0);
                                    for c in 0..ch {
                                        let sidx = f * ch + c;
                                        let mixed = sanitize_and_clamp_f32(
                                            stack_b[sidx] * t * vol,
                                            max_pos,
                                        );
                                        if mixed.abs() > 1e-6 {
                                            has_nz = true;
                                        }
                                        out_f32[written + sidx] = mixed;
                                        let woff = sidx * 4;
                                        wire_scratch[woff..woff + 4]
                                            .copy_from_slice(&mixed.to_le_bytes());
                                    }
                                }
                                if let Some(ref mut tap) = standby.ver_tap {
                                    tap.push_wire(&wire_scratch[..cf_want * 4]);
                                }
                                crate::visualizer::global_tap().feed_wire(
                                    &wire_scratch[..cf_want * 4],
                                    WireSampleFormat::Float32Le,
                                    ch as u16,
                                    self.out_rate,
                                );
                                if has_nz {
                                    self.inner
                                        .nonzero_output_frames
                                        .fetch_add(cf_frames as u64, Ordering::Relaxed);
                                }
                                written += cf_want;
                                if self.crossfade_pos >= self.crossfade_frames {
                                    self.crossfade_active = false;
                                    self.dual.mismatch_armed.store(false, Ordering::Release);
                                    self.flip_to_standby(
                                        cur_now,
                                        other_now,
                                        RtTransitionKind::MismatchCrossfadeFlip,
                                        self.crossfade_resume_frame,
                                    );
                                    self.dual
                                        .format_mismatch_recoveries
                                        .fetch_add(1, Ordering::Release);
                                    self.fade.set_unity();
                                }
                            }
                            continue;
                        } else {
                            if written < out_f32.len() {
                                out_f32[written..].fill(0.0);
                            }
                            self.dual.mismatch_armed.store(false, Ordering::Release);
                            self.dual.deck_states[cur_now]
                                .store(DeckState::Draining as u8, Ordering::Release);
                            self.drain_notified = true;
                            let tgen = self.dual.deck_gen_for(other_now);
                            self.dual.push_rt_event(
                                RtTransitionKind::MismatchDrain,
                                cur_now as u8,
                                other_now as u8,
                                tgen,
                            );
                            return PcmRenderOutcome::Draining;
                        }
                    }

                    if self.dual.deck_states[other_now].load(Ordering::Acquire)
                        == DeckState::StandbyReady as u8
                    {
                        if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                            && !self.slot_ptrs[other_now].is_null()
                        {
                            self.flip_to_standby(
                                cur_now,
                                other_now,
                                RtTransitionKind::GaplessFlip,
                                0,
                            );
                            self.inner
                                .gapless_transitions
                                .fetch_add(1, Ordering::Release);
                            self.fade.set_unity();
                            self.buffering_gate = false;
                            continue;
                        } else {
                            if written < out_f32.len() {
                                out_f32[written..].fill(0.0);
                            }
                            self.dual.deck_states[cur_now]
                                .store(DeckState::Draining as u8, Ordering::Release);
                            self.drain_notified = true;
                            let tgen = self.dual.deck_gen_for(other_now);
                            self.dual.push_rt_event(
                                RtTransitionKind::CrossRateDrain,
                                cur_now as u8,
                                other_now as u8,
                                tgen,
                            );
                            return PcmRenderOutcome::Draining;
                        }
                    }

                    if written < out_f32.len() {
                        out_f32[written..].fill(0.0);
                    }
                    fade_ctrl.mark_silent();
                    self.dual.deck_states[cur_now].store(DeckState::Idle as u8, Ordering::Release);
                    let _ = self.inner.state_code.compare_exchange(
                        PlaybackLifecycleState::Playing as i32,
                        PlaybackLifecycleState::Ended as i32,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                    return PcmRenderOutcome::Ended;
                } else {
                    self.inner
                        .ring_buffer_underrun_count
                        .fetch_add(1, Ordering::Relaxed);
                    if aligned > 0 {
                        let tail_start = written.saturating_sub(aligned);
                        fade_out_f32_tail(&mut out_f32[tail_start..written], ch, 128);
                    }
                    if written < out_f32.len() {
                        out_f32[written..].fill(0.0);
                    }
                    let wm = unsafe { (*self.slot_ptrs[cur_now]).watermark_samples };
                    if wm > 0 {
                        self.buffering_gate = true;
                        self.fade.reset_for_play_start();
                    }
                    break;
                }
            }
        }

        if written < out_f32.len() {
            out_f32[written..].fill(0.0);
        }
        PcmRenderOutcome::Rendered
    }
}

impl Drop for DualDeckPcmFeeder {
    fn drop(&mut self) {
        let cur = self.dual.active_idx();
        for i in 0..2 {
            let ptr = std::mem::replace(&mut self.slot_ptrs[i], null_mut());
            if !ptr.is_null() {
                let boxed = unsafe { Box::from_raw(ptr) };
                if i != cur
                    && self.dual.deck_state(i) == DeckState::StandbyReady
                    && let Ok(mut pg) = self.dual.standby_pending_pcm[i].lock()
                    && pg.is_none()
                {
                    *pg = Some(*boxed);
                }
            }
        }
        self.dual.drain_retired_payloads();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DualDeckWireOutcome {
    Rendered { valid_bytes: usize },
    CrossRateDraining,
    EofEmpty,
    Underrun,
}

#[inline]
pub(crate) fn fill_wire_silence(
    buf: &mut [u8],
    wire: WireSampleFormat,
    channels: usize,
    dop_phase: &mut bool,
) {
    match wire {
        WireSampleFormat::NativeDsd { .. } => buf.fill(0x69),
        WireSampleFormat::Dop24In32MsbLe { .. } => {
            let ch = channels.max(1);
            let bpf = 4 * ch;
            let aligned = (buf.len() / bpf) * bpf;
            for f in 0..(aligned / bpf) {
                let marker = if *dop_phase { 0xFAu8 } else { 0x05u8 };
                *dop_phase = !*dop_phase;
                for c in 0..ch {
                    let off = f * bpf + c * 4;
                    buf[off] = 0x00;
                    buf[off + 1] = 0x69;
                    buf[off + 2] = 0x69;
                    buf[off + 3] = marker;
                }
            }
            if aligned < buf.len() {
                buf[aligned..].fill(0x00);
            }
        }
        _ => buf.fill(0x00),
    }
}

#[inline]
fn wire_bytes_have_nonzero(buf: &[u8], wire: WireSampleFormat) -> bool {
    match wire {
        WireSampleFormat::NativeDsd { .. } => buf.iter().any(|&b| b != 0x69),
        WireSampleFormat::Dop24In32MsbLe { .. } => buf
            .as_chunks::<4>()
            .0
            .iter()
            .any(|s| s[0] != 0x00 || s[1] != 0x69 || s[2] != 0x69 || (s[3] != 0x05 && s[3] != 0xFA)),
        _ => buf.iter().any(|&b| b != 0),
    }
}

pub(crate) struct DualDeckWireFeeder {
    dual: Arc<DualDeckControl>,
    frames_rendered: Arc<AtomicU64>,
    nonzero_frames: Arc<AtomicU64>,
    buffered_ms: Arc<AtomicU64>,
    gapless_transitions: Arc<AtomicU64>,
    underrun_count: Arc<AtomicU64>,
    slot_ptrs: [*mut RtWireInboxPayload; 2],
    wire: WireSampleFormat,
    out_rate: u32,
    out_channels: usize,
    clock_rate: u32,
    skip_fade: LinearFadeState,
    active_skip_seq: Option<(u64, usize)>,
    crossfade_active: bool,
    crossfade_pos: usize,
    crossfade_frames: usize,
    crossfade_target_deck: usize,
    crossfade_resume_frame: u64,
    drain_notified: bool,
}

unsafe impl Send for DualDeckWireFeeder {}

impl DualDeckWireFeeder {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        dual: Arc<DualDeckControl>,
        frames_rendered: Arc<AtomicU64>,
        nonzero_frames: Arc<AtomicU64>,
        buffered_ms: Arc<AtomicU64>,
        gapless_transitions: Arc<AtomicU64>,
        underrun_count: Arc<AtomicU64>,
        active_deck: usize,
        initial_payload: RtWireInboxPayload,
    ) -> Self {
        let wire = initial_payload.wire;
        let out_rate = initial_payload.out_rate.max(8_000);
        let out_channels = initial_payload.out_channels.max(1) as usize;
        let clock_rate = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
            (out_rate / 8).max(44_100)
        } else {
            out_rate
        };
        let mut slot_ptrs = [null_mut(), null_mut()];
        slot_ptrs[active_deck & 1] = Box::into_raw(Box::new(initial_payload));
        let crossfade_frames =
            ((clock_rate as u64 * MISMATCH_CROSSFADE_MS) / 1000).clamp(32, 2048) as usize;
        let mut feeder = Self {
            dual,
            frames_rendered,
            nonzero_frames,
            buffered_ms,
            gapless_transitions,
            underrun_count,
            slot_ptrs,
            wire,
            out_rate,
            out_channels,
            clock_rate,
            skip_fade: LinearFadeState::new(clock_rate, false, true, false),
            active_skip_seq: None,
            crossfade_active: false,
            crossfade_pos: 0,
            crossfade_frames,
            crossfade_target_deck: 1 - (active_deck & 1),
            crossfade_resume_frame: 0,
            drain_notified: false,
        };
        feeder.poll_inbox();
        feeder
    }

    #[inline]
    pub(crate) fn poll_inbox(&mut self) {
        for i in 0..2 {
            let incoming = self.dual.wire_inbox[i].swap(null_mut(), Ordering::AcqRel);
            if !incoming.is_null() {
                let old = std::mem::replace(&mut self.slot_ptrs[i], incoming);
                if !old.is_null() {
                    self.dual.retire_wire_ptr(old);
                }
            }
        }
    }

    #[inline]
    pub(crate) fn active_epoch_pair(&mut self) -> (u64, u64) {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return (0, 0);
        }
        let slot = unsafe { &*self.slot_ptrs[cur] };
        (slot.consumer.requested_epoch(), slot.last_ring_epoch)
    }

    #[inline]
    pub(crate) fn sync_active_epoch(&mut self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        let slot = unsafe { &mut *self.slot_ptrs[cur] };
        if slot.consumer.has_pending_flush() {
            let _ = slot.consumer.try_flush_and_ack();
        }
        slot.last_ring_epoch = slot.consumer.epoch();
        slot.watermark_bytes
    }

    #[inline]
    #[allow(dead_code)]
    pub(crate) fn handle_active_flush(&mut self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        let slot = unsafe { &mut *self.slot_ptrs[cur] };
        if slot.consumer.has_pending_flush() {
            let _ = slot.consumer.try_flush_and_ack();
        } else {
            let _ = slot.consumer.try_clear();
        }
        slot.last_ring_epoch = slot.consumer.epoch();
        slot.watermark_bytes
    }

    #[inline]
    pub(crate) fn active_available_read(&mut self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        unsafe { (*self.slot_ptrs[cur]).consumer.available_read() }
    }

    #[inline]
    pub(crate) fn active_eof_reached(&self) -> bool {
        let cur = self.dual.active_idx();
        self.dual.deck_eof_flags[cur].load(Ordering::Acquire)
    }

    #[inline]
    pub(crate) fn active_watermark_bytes(&self) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            0
        } else {
            unsafe { (*self.slot_ptrs[cur]).watermark_bytes }
        }
    }

    #[inline]
    pub(crate) fn update_active_buffered_ms(&mut self, bpf: usize) {
        let cur = self.dual.active_idx();
        let avail = self.active_available_read();
        let frames_avail = (avail / bpf.max(1)) as u64;
        let bms = (frames_avail * 1000) / (self.clock_rate.max(8_000) as u64);
        self.buffered_ms.store(bms, Ordering::Relaxed);
        self.dual.deck_buffered_ms[cur].store(bms, Ordering::Relaxed);
    }

    #[inline]
    pub(crate) fn pop_active_raw(&mut self, dst: &mut [u8]) -> usize {
        let cur = self.dual.active_idx();
        if self.slot_ptrs[cur].is_null() {
            return 0;
        }
        let bpf = self.wire.bytes_per_sample().max(1) * self.out_channels.max(1);
        unsafe { (*self.slot_ptrs[cur]).consumer.pop_slice_aligned(dst, bpf) }
    }

    #[inline]
    fn flip_to_standby(
        &self,
        from_deck: usize,
        to_deck: usize,
        kind: RtTransitionKind,
        resume_frame: u64,
    ) {
        let tgen = unsafe { (*self.slot_ptrs[to_deck]).deck_gen };
        self.dual
            .active_deck_idx
            .store(to_deck as u8, Ordering::Release);
        self.dual.deck_states[from_deck].store(DeckState::Idle as u8, Ordering::Release);
        self.dual.deck_states[to_deck].store(DeckState::Playing as u8, Ordering::Release);
        self.dual.standby_buffered_ms.store(0, Ordering::Relaxed);
        self.frames_rendered.store(resume_frame, Ordering::SeqCst);
        self.dual
            .push_rt_event(kind, from_deck as u8, to_deck as u8, tgen);
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn pop_wire_period(
        &mut self,
        out: &mut [u8],
        bpf: usize,
        fade: &mut LinearFadeState,
        fade_ctrl: Option<&AudioFadeControl>,
        dop_phase: &mut bool,
        buffering_gate: &mut bool,
    ) -> DualDeckWireOutcome {
        self.poll_inbox();

        let needed = (out.len() / bpf.max(1)) * bpf.max(1);
        if needed == 0 || bpf == 0 {
            return DualDeckWireOutcome::Underrun;
        }
        let cur = self.dual.active_idx();
        let other = 1 - cur;
        if self.slot_ptrs[cur].is_null() {
            fill_wire_silence(out, self.wire, self.out_channels, dop_phase);
            return DualDeckWireOutcome::Underrun;
        }
        if self.drain_notified
            || self.dual.deck_states[cur].load(Ordering::Acquire) == DeckState::Draining as u8
        {
            fill_wire_silence(out, self.wire, self.out_channels, dop_phase);
            return DualDeckWireOutcome::CrossRateDraining;
        }

        // Check manual skip trigger
        let req_seq = self.dual.skip_request_seq.load(Ordering::Acquire);
        let handled_seq = self.dual.skip_handled_seq.load(Ordering::Acquire);
        if self.active_skip_seq.is_none() && req_seq != handled_seq {
            let target = (self.dual.skip_target_deck.load(Ordering::Acquire) & 1) as usize;
            if target == other
                && self.dual.deck_states[other].load(Ordering::Acquire)
                    == DeckState::StandbyReady as u8
            {
                let compat = self.dual.standby_compatible[other].load(Ordering::Acquire)
                    && !self.slot_ptrs[other].is_null();
                let fade_ms = if compat {
                    MICRO_FADE_MS
                } else {
                    MISMATCH_CROSSFADE_MS
                };
                let fade_frames =
                    ((self.clock_rate.max(8_000) as u64 * fade_ms) / 1000).clamp(32, 4096);
                let can_fade = !matches!(
                    self.wire,
                    WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
                );
                self.skip_fade =
                    LinearFadeState::with_frames(fade_frames, false, can_fade, false);
                self.skip_fade.set_gain(fade.gain().max(0.01));
                self.active_skip_seq = Some((req_seq, target));
            }
        }

        // Check FormatMismatch alignment trigger
        if !self.crossfade_active
            && self.active_skip_seq.is_none()
            && self.dual.mismatch_armed.load(Ordering::Acquire)
        {
            let target = (self.dual.mismatch_target_deck.load(Ordering::Acquire) & 1) as usize;
            if target == other
                && self.dual.deck_states[other].load(Ordering::Acquire)
                    == DeckState::StandbyReady as u8
            {
                let cur_frame = self.frames_rendered.load(Ordering::Relaxed);
                let align_frame = self.dual.mismatch_align_frame.load(Ordering::Acquire);
                if cur_frame >= align_frame {
                    if self.dual.standby_compatible[other].load(Ordering::Acquire)
                        && !self.slot_ptrs[other].is_null()
                    {
                        self.crossfade_active = true;
                        self.crossfade_pos = 0;
                        self.crossfade_target_deck = target;
                        self.crossfade_resume_frame =
                            self.dual.mismatch_resume_frame.load(Ordering::Acquire);
                    } else {
                        let rapid_frames =
                            ((self.clock_rate.max(8_000) as u64 * MISMATCH_CROSSFADE_MS) / 1000)
                                .clamp(32, 2048);
                        self.skip_fade =
                            LinearFadeState::with_frames(rapid_frames, false, true, false);
                        self.skip_fade.set_gain(fade.gain().max(0.01));
                        self.active_skip_seq = Some((u64::MAX, target));
                    }
                }
            }
        }

        let is_dsd = matches!(self.wire, WireSampleFormat::NativeDsd { .. });
        let mut written = 0usize;

        // 1. Active manual skip / rapid drain fade-out
        if let Some((skip_seq, target)) = self.active_skip_seq {
            let active = unsafe { &mut *self.slot_ptrs[cur] };
            let rem_fade_bytes = if self.skip_fade.fade_out_enabled() {
                self.skip_fade.remaining_down_frames().max(1) * bpf
            } else {
                0
            };
            let want = (needed - written).min(rem_fade_bytes);
            let aligned = if want > 0 {
                active
                    .consumer
                    .pop_slice_aligned(&mut out[written..written + want], bpf)
            } else {
                0
            };
            if aligned > 0 {
                apply_fade_ramp_to_wire_bytes(
                    &mut out[written..written + aligned],
                    self.wire,
                    self.out_channels,
                    &mut self.skip_fade,
                    FadeDirection::Down,
                );
                if matches!(self.wire, WireSampleFormat::Dop24In32MsbLe { .. }) {
                    *dop_phase = out[written + aligned - 1] == 0x05;
                }
                active.ver_tap.push_wire(&out[written..written + aligned]);
                crate::visualizer::global_tap().feed_wire(
                    &out[written..written + aligned],
                    self.wire,
                    self.out_channels as u16,
                    self.out_rate,
                );
                let f_cnt = if is_dsd {
                    ((aligned / bpf) * 8) as u64
                } else {
                    (aligned / bpf) as u64
                };
                self.frames_rendered.fetch_add(f_cnt, Ordering::Relaxed);
                if wire_bytes_have_nonzero(&out[written..written + aligned], self.wire) {
                    self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
                }
                if let Some(fc) = fade_ctrl {
                    fc.mark_audible();
                }
                written += aligned;
            }
            if !self.skip_fade.fade_out_enabled() || self.skip_fade.gain() <= 0.0 || aligned < want {
                self.active_skip_seq = None;
                if skip_seq != u64::MAX
                    && self.dual.standby_compatible[target].load(Ordering::Acquire)
                    && !self.slot_ptrs[target].is_null()
                {
                    self.flip_to_standby(cur, target, RtTransitionKind::ManualSkipFlip, 0);
                    self.dual
                        .manual_zero_latency_switches
                        .fetch_add(1, Ordering::Release);
                    self.dual.skip_handled_seq.store(skip_seq, Ordering::Release);
                    fade.set_unity();
                    *buffering_gate = false;
                } else {
                    fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
                    let kind = if skip_seq == u64::MAX {
                        self.dual.mismatch_armed.store(false, Ordering::Release);
                        RtTransitionKind::MismatchDrain
                    } else {
                        self.dual.skip_handled_seq.store(skip_seq, Ordering::Release);
                        RtTransitionKind::ManualSkipDrain
                    };
                    self.dual.deck_states[cur].store(DeckState::Draining as u8, Ordering::Release);
                    self.drain_notified = true;
                    let tgen = self.dual.deck_gen_for(target);
                    self.dual.push_rt_event(kind, cur as u8, target as u8, tgen);
                    return if written > 0 {
                        DualDeckWireOutcome::Rendered {
                            valid_bytes: written,
                        }
                    } else {
                        DualDeckWireOutcome::CrossRateDraining
                    };
                }
            } else {
                fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
                return DualDeckWireOutcome::Rendered {
                    valid_bytes: written,
                };
            }
        }

        // 2. Active 5 ms micro-crossfade for FormatMismatch recovery
        if self.crossfade_active {
            let cur_now = self.dual.active_idx();
            let target = self.crossfade_target_deck;
            if cur_now != target && !self.slot_ptrs[cur_now].is_null() && !self.slot_ptrs[target].is_null() {
                let (active, standby) = unsafe {
                    (&mut *self.slot_ptrs[cur_now], &mut *self.slot_ptrs[target])
                };
                let mut stack_a = [0u8; 8192];
                let mut stack_b = [0u8; 8192];
                while self.crossfade_active && written < needed {
                    let rem_cf = self.crossfade_frames.saturating_sub(self.crossfade_pos);
                    if rem_cf == 0 {
                        self.crossfade_active = false;
                        break;
                    }
                    let max_bytes = (stack_a.len() / bpf) * bpf;
                    let cf_bytes = (rem_cf * bpf).min(needed - written).min(max_bytes);
                    let cf_aligned = (cf_bytes / bpf) * bpf;
                    if cf_aligned == 0 {
                        break;
                    }
                    let aa = active
                        .consumer
                        .pop_slice_aligned(&mut stack_a[..cf_aligned], bpf);
                    let ab = standby
                        .consumer
                        .pop_slice_aligned(&mut stack_b[..cf_aligned], bpf);
                    if ab == 0 {
                        break;
                    }
                    let mixed_bytes = crossfade_wire_bytes(
                        &stack_a[..aa],
                        &stack_b[..ab],
                        &mut out[written..written + ab],
                        self.wire,
                        self.out_channels,
                        &mut self.crossfade_pos,
                        self.crossfade_frames,
                    );
                    if mixed_bytes > 0 {
                        standby
                            .ver_tap
                            .push_wire(&out[written..written + mixed_bytes]);
                        crate::visualizer::global_tap().feed_wire(
                            &out[written..written + mixed_bytes],
                            self.wire,
                            self.out_channels as u16,
                            self.out_rate,
                        );
                        let f_cnt = if is_dsd {
                            ((mixed_bytes / bpf) * 8) as u64
                        } else {
                            (mixed_bytes / bpf) as u64
                        };
                        if wire_bytes_have_nonzero(&out[written..written + mixed_bytes], self.wire) {
                            self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
                        }
                        if let Some(fc) = fade_ctrl {
                            fc.mark_audible();
                        }
                        written += mixed_bytes;
                    }
                    if self.crossfade_pos >= self.crossfade_frames {
                        self.crossfade_active = false;
                        self.dual.mismatch_armed.store(false, Ordering::Release);
                        self.flip_to_standby(
                            cur_now,
                            target,
                            RtTransitionKind::MismatchCrossfadeFlip,
                            self.crossfade_resume_frame,
                        );
                        self.dual
                            .format_mismatch_recoveries
                            .fetch_add(1, Ordering::Release);
                        fade.set_unity();
                    }
                }
                if written >= needed {
                    return DualDeckWireOutcome::Rendered {
                        valid_bytes: written,
                    };
                }
            } else {
                self.crossfade_active = false;
            }
        }

        // 3. Normal Active playback + inline Gapless / FormatMismatch alignment / Cross-rate drain
        loop {
            if written >= needed {
                break;
            }
            let cur_now = self.dual.active_idx();
            let other_now = 1 - cur_now;
            if self.slot_ptrs[cur_now].is_null() {
                break;
            }
            let mut want = needed - written;
            let mut hit_mismatch_boundary = false;
            if !self.crossfade_active && self.dual.mismatch_armed.load(Ordering::Acquire) {
                let m_target = (self.dual.mismatch_target_deck.load(Ordering::Acquire) & 1) as usize;
                if m_target == other_now
                    && self.dual.deck_states[other_now].load(Ordering::Acquire)
                        == DeckState::StandbyReady as u8
                {
                    let cur_frame = self.frames_rendered.load(Ordering::Relaxed);
                    let align_frame = self.dual.mismatch_align_frame.load(Ordering::Acquire);
                    let frame_units = if is_dsd { 8 } else { 1 };
                    if cur_frame >= align_frame {
                        want = 0;
                        hit_mismatch_boundary = true;
                    } else {
                        let rem_bytes = (((align_frame - cur_frame) as usize) / frame_units) * bpf;
                        if rem_bytes < want {
                            want = rem_bytes;
                            hit_mismatch_boundary = true;
                        }
                    }
                }
            }

            let aligned = if want > 0 {
                let active = unsafe { &mut *self.slot_ptrs[cur_now] };
                let al = active
                    .consumer
                    .pop_slice_aligned(&mut out[written..written + want], bpf);
                if al > 0 {
                    if fade.gain() < 1.0 {
                        apply_fade_ramp_to_wire_bytes(
                            &mut out[written..written + al],
                            self.wire,
                            self.out_channels,
                            fade,
                            FadeDirection::Up,
                        );
                    }
                    if let Some(fc) = fade_ctrl {
                        fc.mark_audible();
                    }
                    if matches!(self.wire, WireSampleFormat::Dop24In32MsbLe { .. }) {
                        *dop_phase = out[written + al - 1] == 0x05;
                    }
                    active.ver_tap.push_wire(&out[written..written + al]);
                    crate::visualizer::global_tap().feed_wire(
                        &out[written..written + al],
                        self.wire,
                        self.out_channels as u16,
                        self.out_rate,
                    );
                    let f_cnt = if is_dsd {
                        ((al / bpf) * 8) as u64
                    } else {
                        (al / bpf) as u64
                    };
                    self.frames_rendered.fetch_add(f_cnt, Ordering::Relaxed);
                    if wire_bytes_have_nonzero(&out[written..written + al], self.wire) {
                        self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
                    }
                    written += al;
                }
                al
            } else {
                0
            };

            if hit_mismatch_boundary && aligned == want {
                if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                    && !self.slot_ptrs[other_now].is_null()
                {
                    let (active, standby) = unsafe {
                        (&mut *self.slot_ptrs[cur_now], &mut *self.slot_ptrs[other_now])
                    };
                    let resume_frame = self.dual.mismatch_resume_frame.load(Ordering::Acquire);
                    self.crossfade_active = true;
                    self.crossfade_pos = 0;
                    self.crossfade_target_deck = other_now;
                    self.crossfade_resume_frame = resume_frame;

                    let mut stack_a = [0u8; 8192];
                    let mut stack_b = [0u8; 8192];
                    while self.crossfade_active && written < needed {
                        let rem_cf = self.crossfade_frames.saturating_sub(self.crossfade_pos);
                        let max_bytes = (stack_a.len() / bpf) * bpf;
                        let cf_raw = (rem_cf * bpf).min(needed - written).min(max_bytes);
                        let cf_aligned = (cf_raw / bpf) * bpf;
                        if cf_aligned == 0 {
                            break;
                        }
                        let aa = active
                            .consumer
                            .pop_slice_aligned(&mut stack_a[..cf_aligned], bpf);
                        let ab = standby
                            .consumer
                            .pop_slice_aligned(&mut stack_b[..cf_aligned], bpf);
                        if ab == 0 {
                            break;
                        }
                        let mixed_bytes = crossfade_wire_bytes(
                            &stack_a[..aa],
                            &stack_b[..ab],
                            &mut out[written..written + ab],
                            self.wire,
                            self.out_channels,
                            &mut self.crossfade_pos,
                            self.crossfade_frames,
                        );
                        if mixed_bytes > 0 {
                            standby
                                .ver_tap
                                .push_wire(&out[written..written + mixed_bytes]);
                            crate::visualizer::global_tap().feed_wire(
                                &out[written..written + mixed_bytes],
                                self.wire,
                                self.out_channels as u16,
                                self.out_rate,
                            );
                            let f_cnt = if is_dsd {
                                ((mixed_bytes / bpf) * 8) as u64
                            } else {
                                (mixed_bytes / bpf) as u64
                            };
                            if wire_bytes_have_nonzero(
                                &out[written..written + mixed_bytes],
                                self.wire,
                            ) {
                                self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
                            }
                            written += mixed_bytes;
                        }
                        if self.crossfade_pos >= self.crossfade_frames {
                            self.crossfade_active = false;
                            self.dual.mismatch_armed.store(false, Ordering::Release);
                            self.flip_to_standby(
                                cur_now,
                                other_now,
                                RtTransitionKind::MismatchCrossfadeFlip,
                                resume_frame,
                            );
                            self.dual
                                .format_mismatch_recoveries
                                .fetch_add(1, Ordering::Release);
                            fade.set_unity();
                        }
                    }
                    continue;
                } else {
                    fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
                    self.dual.mismatch_armed.store(false, Ordering::Release);
                    self.dual.deck_states[cur_now]
                        .store(DeckState::Draining as u8, Ordering::Release);
                    self.drain_notified = true;
                    let tgen = self.dual.deck_gen_for(other_now);
                    self.dual.push_rt_event(
                        RtTransitionKind::MismatchDrain,
                        cur_now as u8,
                        other_now as u8,
                        tgen,
                    );
                    return if written > 0 {
                        DualDeckWireOutcome::Rendered {
                            valid_bytes: written,
                        }
                    } else {
                        DualDeckWireOutcome::CrossRateDraining
                    };
                }
            }

            if aligned < want {
                let avail_rem = unsafe { (*self.slot_ptrs[cur_now]).consumer.available_read() };
                if self.dual.deck_eof_flags[cur_now].load(Ordering::SeqCst) && avail_rem < bpf {
                    if self.dual.mismatch_armed.load(Ordering::Acquire)
                        && self.dual.deck_states[other_now].load(Ordering::Acquire)
                            == DeckState::StandbyReady as u8
                    {
                        if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                            && !self.slot_ptrs[other_now].is_null()
                        {
                            self.crossfade_active = true;
                            self.crossfade_pos = 0;
                            self.crossfade_target_deck = other_now;
                            self.crossfade_resume_frame =
                                self.dual.mismatch_resume_frame.load(Ordering::Acquire);
                            let standby = unsafe { &mut *self.slot_ptrs[other_now] };
                            let mut stack_b = [0u8; 8192];
                            while self.crossfade_active && written < needed {
                                let rem_cf =
                                    self.crossfade_frames.saturating_sub(self.crossfade_pos);
                                let max_bytes = (stack_b.len() / bpf) * bpf;
                                let cf_raw = (rem_cf * bpf).min(needed - written).min(max_bytes);
                                let cf_aligned = (cf_raw / bpf) * bpf;
                                if cf_aligned == 0 {
                                    break;
                                }
                                let ab = standby
                                    .consumer
                                    .pop_slice_aligned(&mut stack_b[..cf_aligned], bpf);
                                if ab == 0 {
                                    break;
                                }
                                let mixed_bytes = crossfade_wire_bytes(
                                    &[],
                                    &stack_b[..ab],
                                    &mut out[written..written + ab],
                                    self.wire,
                                    self.out_channels,
                                    &mut self.crossfade_pos,
                                    self.crossfade_frames,
                                );
                                if mixed_bytes > 0 {
                                    standby
                                        .ver_tap
                                        .push_wire(&out[written..written + mixed_bytes]);
                                    crate::visualizer::global_tap().feed_wire(
                                        &out[written..written + mixed_bytes],
                                        self.wire,
                                        self.out_channels as u16,
                                        self.out_rate,
                                    );
                                    let f_cnt = if is_dsd {
                                        ((mixed_bytes / bpf) * 8) as u64
                                    } else {
                                        (mixed_bytes / bpf) as u64
                                    };
                                    if wire_bytes_have_nonzero(
                                        &out[written..written + mixed_bytes],
                                        self.wire,
                                    ) {
                                        self.nonzero_frames.fetch_add(f_cnt, Ordering::Relaxed);
                                    }
                                    written += mixed_bytes;
                                }
                                if self.crossfade_pos >= self.crossfade_frames {
                                    self.crossfade_active = false;
                                    self.dual.mismatch_armed.store(false, Ordering::Release);
                                    self.flip_to_standby(
                                        cur_now,
                                        other_now,
                                        RtTransitionKind::MismatchCrossfadeFlip,
                                        self.crossfade_resume_frame,
                                    );
                                    self.dual
                                        .format_mismatch_recoveries
                                        .fetch_add(1, Ordering::Release);
                                    fade.set_unity();
                                }
                            }
                            continue;
                        } else {
                            fill_wire_silence(
                                &mut out[written..],
                                self.wire,
                                self.out_channels,
                                dop_phase,
                            );
                            self.dual.mismatch_armed.store(false, Ordering::Release);
                            self.dual.deck_states[cur_now]
                                .store(DeckState::Draining as u8, Ordering::Release);
                            self.drain_notified = true;
                            let tgen = self.dual.deck_gen_for(other_now);
                            self.dual.push_rt_event(
                                RtTransitionKind::MismatchDrain,
                                cur_now as u8,
                                other_now as u8,
                                tgen,
                            );
                            return if written > 0 {
                                DualDeckWireOutcome::Rendered {
                                    valid_bytes: written,
                                }
                            } else {
                                DualDeckWireOutcome::CrossRateDraining
                            };
                        }
                    }

                    if self.dual.deck_states[other_now].load(Ordering::Acquire)
                        == DeckState::StandbyReady as u8
                    {
                        if self.dual.standby_compatible[other_now].load(Ordering::Acquire)
                            && !self.slot_ptrs[other_now].is_null()
                        {
                            self.flip_to_standby(
                                cur_now,
                                other_now,
                                RtTransitionKind::GaplessFlip,
                                0,
                            );
                            self.gapless_transitions.fetch_add(1, Ordering::Release);
                            fade.set_unity();
                            *buffering_gate = false;
                            continue;
                        } else {
                            fill_wire_silence(
                                &mut out[written..],
                                self.wire,
                                self.out_channels,
                                dop_phase,
                            );
                            self.dual.deck_states[cur_now]
                                .store(DeckState::Draining as u8, Ordering::Release);
                            self.drain_notified = true;
                            let tgen = self.dual.deck_gen_for(other_now);
                            self.dual.push_rt_event(
                                RtTransitionKind::CrossRateDrain,
                                cur_now as u8,
                                other_now as u8,
                                tgen,
                            );
                            return if written > 0 {
                                DualDeckWireOutcome::Rendered {
                                    valid_bytes: written,
                                }
                            } else {
                                DualDeckWireOutcome::CrossRateDraining
                            };
                        }
                    }

                    fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
                    return if written > 0 {
                        DualDeckWireOutcome::Rendered {
                            valid_bytes: written,
                        }
                    } else {
                        self.dual.deck_states[cur_now]
                            .store(DeckState::Idle as u8, Ordering::Release);
                        DualDeckWireOutcome::EofEmpty
                    };
                }
                self.underrun_count.fetch_add(1, Ordering::Relaxed);
                if written == 0 {
                    if self.active_watermark_bytes() > 0 {
                        *buffering_gate = true;
                        fade.reset_for_play_start();
                    }
                    return DualDeckWireOutcome::Underrun;
                }
                if aligned > 0 {
                    let tail_start = written.saturating_sub(aligned);
                    fade_out_wire_tail(
                        &mut out[tail_start..written],
                        self.wire,
                        self.out_channels,
                        128,
                    );
                }
                if self.active_watermark_bytes() > 0 {
                    *buffering_gate = true;
                    fade.reset_for_play_start();
                }
                break;
            }
        }
        if written < out.len() {
            fill_wire_silence(&mut out[written..], self.wire, self.out_channels, dop_phase);
        }
        DualDeckWireOutcome::Rendered {
            valid_bytes: written,
        }
    }
}

impl Drop for DualDeckWireFeeder {
    fn drop(&mut self) {
        let cur = self.dual.active_idx();
        for i in 0..2 {
            let ptr = std::mem::replace(&mut self.slot_ptrs[i], null_mut());
            if !ptr.is_null() {
                let boxed = unsafe { Box::from_raw(ptr) };
                if i != cur
                    && self.dual.deck_state(i) == DeckState::StandbyReady
                    && let Ok(mut pg) = self.dual.standby_pending_wire[i].lock()
                    && pg.is_none()
                {
                    *pg = Some(*boxed);
                }
            }
        }
        self.dual.drain_retired_payloads();
    }
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
    active_source_spec: RwLock<Option<StreamSourceSpec>>,
    last_error: Arc<RwLock<Option<String>>>,
    last_error_code: Arc<RwLock<Option<String>>>,
    last_error_provider: Arc<RwLock<Option<String>>>,
    policy: RwLock<PlaybackEnginePolicy>,
    saved_normal_dsp_bypass: AtomicBool,
    saved_normal_volume_bits: AtomicU32,
    verification: RwLock<Option<(AudioVerificationEngine, String, String)>>,
    queued_next: RwLock<Option<(StreamSource, String)>>,
    queued_next_spec: RwLock<Option<(StreamSourceSpec, String)>>,
    has_queued_next_spec: AtomicBool,
    gapless_transitions: Arc<AtomicU64>,
    format_reinit_count: AtomicU64,
    seek_epoch: AtomicU64,
    epoch: AtomicU64,
    play_epoch: AtomicU64,
    last_caller_play_epoch: AtomicU64,
    active_cancel: RwLock<CancellationToken>,
    epoch_lock: Mutex<()>,
    device_lost: Arc<AtomicBool>,
    format_mismatch_flag: Arc<AtomicBool>,
    published_format_stamp: Arc<AtomicU64>,
    stream_refresh_handler: RwLock<Option<Arc<dyn StreamRefreshHandler>>>,
    l2_cache_manager: RwLock<Option<Arc<L2CacheManager>>>,
    cmd_tx_slot: OnceLock<mpsc::Sender<PlayerCommand>>,
    idle_reclaim_threshold: RwLock<Duration>,
    idle_reclaim_count: AtomicU64,
    is_seeking: AtomicBool,
    buffered_ms: Arc<AtomicU64>,
    ring_buffer_underrun_count: Arc<AtomicU64>,
    cpal_stream_error_flag: Arc<AtomicBool>,
    active_fade: RwLock<Option<Arc<AudioFadeControl>>>,
    dual_deck: Arc<DualDeckControl>,
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
            is_seeking: AtomicBool::new(false),
            buffered_ms: Arc::new(AtomicU64::new(0)),
            ring_buffer_underrun_count: Arc::new(AtomicU64::new(0)),
            cpal_stream_error_flag: Arc::new(AtomicBool::new(false)),
            active_fade: RwLock::new(None),
            dual_deck: Arc::new(DualDeckControl::new()),
        }
    }

    fn stream_refresh_handler(&self) -> Option<Arc<dyn StreamRefreshHandler>> {
        self.stream_refresh_handler
            .read()
            .ok()
            .and_then(|g| g.clone())
    }

    fn l2_cache_manager(&self) -> Option<Arc<L2CacheManager>> {
        self.l2_cache_manager.read().ok().and_then(|g| g.clone())
    }

    fn clear_error_state(&self) {
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
        crate::visualizer::global_tap().ensure_worker_started();
        let inner = Arc::new(PlayerInner::new(headless));
        let (cmd_tx, cmd_rx) = mpsc::channel();
        let _ = inner.cmd_tx_slot.set(cmd_tx.clone());
        let coord_inner = Arc::clone(&inner);
        let coord_tx = cmd_tx.clone();

        let relay_weak = Arc::downgrade(&inner);
        let relay_tx = cmd_tx.clone();
        let relay_jh = thread::Builder::new()
            .name("lumina-deck-relay".to_string())
            .spawn(move || relay_loop(relay_weak, relay_tx))
            .expect("spawn audio deck relay thread");
        let _ = inner.dual_deck.relay_thread.set(relay_jh.thread().clone());

        thread::Builder::new()
            .name("lumina-audio-coordinator".to_string())
            .spawn(move || coordinator_loop(coord_inner, cmd_rx, coord_tx))
            .expect("spawn audio coordinator thread");

        Self { inner, cmd_tx }
    }

    /// Returns the player's monotonic lifecycle epoch (incremented on every play, stop, and seek).
    pub fn current_epoch(&self) -> u64 {
        self.inner.epoch.load(Ordering::SeqCst)
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
            .and_then(|g| g.as_ref().map(|spec| spec.key().provider_id.eq_ignore_ascii_case(pid)))
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

    fn swap_cancel_and_bump_epoch(
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
            Some(Arc::downgrade(&self.inner)),
        ) {
            Ok(pair) => pair,
            Err(e) => {
                if cancel.is_cancelled()
                    || self.inner.play_epoch.load(Ordering::SeqCst) != play_ep
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
                            format!(
                                "Authentication required for {provider_id} (HTTP {status})"
                            ),
                            Some("AUTH_REQUIRED"),
                            Some(provider_id.clone()),
                        );
                    }
                    _ => record_playback_error(&self.inner, e.to_string()),
                }
                return Err(e);
            }
        };

        self.start_opened_source_spec(&adopted_spec, decoder, source_label, play_ep, cancel)
    }

    /// Opens a [`StreamSourceSpec`] asynchronously using this player's L2 cache manager,
    /// format-mismatch recovery callback, and stable-play admission hook.
    ///
    /// Returns `(decoder, adopted_spec)` where `adopted_spec` reflects any initial
    /// `StreamFormatChanged` self-healing refresh performed during probe. The returned future is
    /// `Send + 'static` so callers can release locks guarding `&AudioPlayer` before `.await`ing.
    pub fn open_source_spec_async_with_l2(
        &self,
        spec: StreamSourceSpec,
        cancel: CancellationToken,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    ) -> impl std::future::Future<
        Output = Result<(OpenedStreamDecoder, StreamSourceSpec), CoreAudioError>,
    > + Send
           + 'static {
        let inner = Arc::clone(&self.inner);
        async move {
            let effective_refresh = refresh_handler.or_else(|| inner.stream_refresh_handler());
            let l2_manager = inner.l2_cache_manager();
            open_decoder_for_source_spec_async_with_l2(
                spec,
                cancel,
                effective_refresh,
                l2_manager,
                Some(inner),
            )
            .await
        }
    }

    /// Opens a [`StreamSourceSpec`] asynchronously (non-blocking manifest fetch,
    /// cancellable `spawn_blocking` probe) without blocking a Tokio worker thread.
    pub async fn open_source_spec_async(
        spec: StreamSourceSpec,
        cancel: CancellationToken,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        open_decoder_for_source_spec_async(spec, cancel).await
    }

    /// Opens a [`StreamSourceSpec`] asynchronously with an optional [`StreamRefreshHandler`] wired
    /// into underlying range/segmented proxies.
    pub async fn open_source_spec_async_with_refresh(
        spec: StreamSourceSpec,
        cancel: CancellationToken,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        open_decoder_for_source_spec_async_with_refresh(spec, cancel, refresh_handler).await
    }

    /// Opens a legacy [`StreamSource`] asynchronously on Tokio's blocking pool with cancellation.
    pub async fn open_stream_async(
        stream: StreamSource,
        cancel: CancellationToken,
        timeout: Duration,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        if cancel.is_cancelled() {
            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
        }
        tokio::task::spawn_blocking(move || open_decoder_for_stream_with_token(&stream, cancel, timeout))
            .await
            .map_err(|e| {
                CoreAudioError::Io(std::io::Error::other(format!(
                    "Decoder open task failed: {e}"
                )))
            })?
    }

    /// Commits a pre-opened `decoder` for `spec` if `play_ep` and `cancel` are still current.
    pub fn start_opened_source_spec(
        &self,
        spec: &StreamSourceSpec,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        play_ep: u64,
        cancel: CancellationToken,
    ) -> Result<(), CoreAudioError> {
        if let StreamSourceSpec::ExternalBackend {
            key, provider_id, ..
        } = spec
        {
            return Err(CoreAudioError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                key.track_id
            )));
        }

        self.commit_opened_decoder(
            PlayerOrigin::SourceSpec(spec.clone()),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
        )
    }

    /// Commits a pre-opened legacy `stream` decoder if `play_ep` and `cancel` are still current.
    pub fn start_opened_decoder_with_epoch(
        &self,
        stream: &StreamSource,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        play_ep: u64,
        cancel: CancellationToken,
    ) -> Result<(), CoreAudioError> {
        self.commit_opened_decoder(
            PlayerOrigin::Legacy(stream.clone()),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
        )
    }

    /// Opens a `StreamSource` (local file or HTTP/HTTPS stream), probes codec/container headers,
    /// stores ReplayGain tags, and starts streaming playback.
    pub fn play_stream(
        &self,
        stream: StreamSource,
        source_label: &str,
    ) -> Result<(), CoreAudioError> {
        let cancel = CancellationToken::new();
        let Some(play_ep) = self.swap_cancel_and_bump_epoch(None, cancel.clone()) else {
            return Ok(());
        };
        let decoder = match open_decoder_for_stream_with_token(
            &stream,
            cancel.clone(),
            Duration::from_secs(10),
        ) {
            Ok(d) => d,
            Err(e) => {
                if cancel.is_cancelled() || self.inner.play_epoch.load(Ordering::SeqCst) != play_ep
                {
                    return Ok(());
                }
                return Err(e);
            }
        };
        self.commit_opened_decoder(
            PlayerOrigin::Legacy(stream),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
        )
    }

    /// Commits a pre-opened `decoder` into active playback without doing any network/probe I/O.
    pub fn start_opened_decoder(
        &self,
        stream: &StreamSource,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
    ) -> Result<(), CoreAudioError> {
        let cancel = CancellationToken::new();
        let Some(play_ep) = self.swap_cancel_and_bump_epoch(None, cancel.clone()) else {
            return Ok(());
        };
        self.commit_opened_decoder(
            PlayerOrigin::Legacy(stream.clone()),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
        )
    }

    fn commit_opened_decoder(
        &self,
        origin: PlayerOrigin,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        cancel: CancellationToken,
        expected_play_epoch: Option<u64>,
    ) -> Result<(), CoreAudioError> {
        let label = if source_label.trim().is_empty() {
            match &origin {
                PlayerOrigin::Legacy(_) => "Stream".to_string(),
                PlayerOrigin::SourceSpec(spec) => source_spec_default_label(spec),
            }
        } else {
            source_label.to_string()
        };
        let path_buf = origin.display_path();
        let format = decoder.format().clone();
        let duration_ms = decoder
            .duration()
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);

        let session_id = {
            let _ep_guard = self
                .inner
                .epoch_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if cancel.is_cancelled() {
                return Ok(());
            }
            if let Some(expected) = expected_play_epoch
                && self.inner.play_epoch.load(Ordering::SeqCst) != expected
            {
                return Ok(());
            }

            if let Ok(mut q) = self.inner.queued_next.write() {
                *q = None;
            }
            if let Ok(mut qs) = self.inner.queued_next_spec.write() {
                *qs = None;
            }
            self.inner
                .has_queued_next_spec
                .store(false, Ordering::SeqCst);
            self.inner.dual_deck.cancel_standby();
            let active_idx = self.inner.dual_deck.active_idx();
            let _ = self.inner.dual_deck.cancel_and_join_deck(active_idx);
            self.inner.dual_deck.active_deck_idx.store(0, Ordering::SeqCst);
            self.inner.dual_deck.deck_states[0].store(DeckState::Playing as u8, Ordering::SeqCst);
            self.inner.dual_deck.deck_states[1].store(DeckState::Idle as u8, Ordering::SeqCst);
            self.inner.dual_deck.set_deck_key(0, origin.stream_key());
            self.inner.dual_deck.set_deck_key(1, None);
            if let Ok(mut rg_lock) = self.inner.track_replay_gain.write() {
                *rg_lock = origin
                    .replay_gain_tags()
                    .with_metadata_fallback(decoder.metadata());
            }
            if let Ok(mut spec_lock) = self.inner.active_source_spec.write() {
                *spec_lock = match &origin {
                    PlayerOrigin::SourceSpec(spec) => Some(spec.clone()),
                    PlayerOrigin::Legacy(_) => None,
                };
            }
            self.inner.dsp_generation.fetch_add(1, Ordering::SeqCst);

            if let Ok(fade_lock) = self.inner.active_fade.read()
                && let Some(ref fc) = *fade_lock
            {
                fc.request_stop_fade_out();
            }

            let sid = self
                .inner
                .current_session_id
                .fetch_add(1, Ordering::SeqCst)
                + 1;

            self.inner.duration_ms.store(duration_ms, Ordering::SeqCst);
            self.inner.buffered_ms.store(0, Ordering::Relaxed);
            self.inner
                .ring_buffer_underrun_count
                .store(0, Ordering::Relaxed);
            self.inner
                .cpal_stream_error_flag
                .store(false, Ordering::Release);
            self.inner.stopped.store(false, Ordering::SeqCst);
            self.inner.paused.store(false, Ordering::SeqCst);
            self.inner.device_lost.store(false, Ordering::SeqCst);
            self.inner.format_mismatch_flag.store(false, Ordering::Release);
            self.inner.frames_rendered.store(0, Ordering::SeqCst);
            self.inner.nonzero_output_frames.store(0, Ordering::SeqCst);
            self.inner.seek_request_ms.store(-1, Ordering::SeqCst);
            self.inner.clear_error_state();
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
            sid
        };

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::Start {
                session_id,
                decoder,
                path: path_buf,
                source_label: label,
                origin,
                cancel_token: cancel,
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

    /// Returns a live snapshot of both physical decks (`Deck A` / `Deck B`), standby buffer
    /// depth, and transition telemetry counters.
    pub fn dual_deck_status(&self) -> DualDeckStatusSnapshot {
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
            *qs = Some((spec, label));
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
        if matches!(spec, StreamSourceSpec::ExternalBackend { .. }) {
            let _op_guard = self
                .inner
                .dual_deck
                .skip_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            self.inner.dual_deck.cancel_standby();
            return Ok(());
        }
        let label = source_spec_default_label(&spec);
        self.prepare_standby_internal(
            PlayerOrigin::SourceSpec(spec),
            label,
            false,
            false,
            None,
            None,
        )
    }

    /// Pre-resolves and pre-decodes 2–3 seconds of a legacy `StreamSource` onto the Standby deck.
    pub fn prepare_standby(
        &self,
        stream: StreamSource,
        label: impl Into<String>,
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
        )
    }

    /// Performs a zero-latency switch to the Standby deck if it is `StandbyReady`.
    /// Returns `Ok(true)` when the fast transition completes, or `Ok(false)` if Standby is not ready.
    pub fn skip_to_standby(&self) -> Result<bool, CoreAudioError> {
        let _op_guard = self
            .inner
            .dual_deck
            .skip_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());

        let sb = self.inner.dual_deck.standby_idx();
        let cur = 1 - sb;
        if self.inner.dual_deck.deck_state(sb) != DeckState::StandbyReady {
            return Ok(false);
        }

        let sb_gen = self.inner.dual_deck.deck_gen_for(sb);
        let compat = self.inner.dual_deck.standby_compatible[sb].load(Ordering::Acquire);
        let state = self.inner.state_code.load(Ordering::Acquire);
        let is_paused = self.inner.paused.load(Ordering::Acquire);
        let has_active_output = !self.inner.stopped.load(Ordering::Acquire)
            && (state == PlaybackLifecycleState::Playing as i32
                || state == PlaybackLifecycleState::Paused as i32);

        if !has_active_output || is_paused {
            let flip_before = self
                .inner
                .dual_deck
                .flip_done_sync
                .0
                .lock()
                .map(|g| *g)
                .unwrap_or(0);
            if self
                .cmd_tx
                .send(PlayerCommand::ReopenOntoStandby {
                    from_deck: cur,
                    to_deck: sb,
                    to_deck_gen: sb_gen,
                    is_manual_skip: true,
                    is_mismatch_recovery: false,
                })
                .is_err()
            {
                return Err(CoreAudioError::Backend(BackendError::InvalidState(
                    "Audio coordinator shut down".into(),
                )));
            }
            let (lock, cvar) = &self.inner.dual_deck.flip_done_sync;
            if let Ok(mut g) = lock.lock() {
                let deadline = Instant::now() + Duration::from_millis(500);
                while *g == flip_before && Instant::now() < deadline {
                    let rem = deadline.saturating_duration_since(Instant::now());
                    let (ng, _) = cvar.wait_timeout(g, rem).unwrap_or_else(|e| e.into_inner());
                    g = ng;
                }
            }
            return Ok(self.inner.dual_deck.active_idx() == sb);
        }

        let flip_before = self
            .inner
            .dual_deck
            .flip_done_sync
            .0
            .lock()
            .map(|g| *g)
            .unwrap_or(0);

        self.inner
            .dual_deck
            .skip_target_deck
            .store(sb as u8, Ordering::Release);
        let req = self
            .inner
            .dual_deck
            .skip_request_seq
            .fetch_add(1, Ordering::AcqRel)
            + 1;

        let wait_ms = if compat { 80 } else { 400 };
        let (lock, cvar) = &self.inner.dual_deck.flip_done_sync;
        if let Ok(mut g) = lock.lock() {
            let deadline = Instant::now() + Duration::from_millis(wait_ms);
            while *g == flip_before && Instant::now() < deadline {
                let rem = deadline.saturating_duration_since(Instant::now());
                let (ng, _) = cvar.wait_timeout(g, rem).unwrap_or_else(|e| e.into_inner());
                g = ng;
            }
        }

        if self.inner.dual_deck.active_idx() == sb {
            return Ok(true);
        }

        // Fallback if RT callback didn't fire in time (e.g. stream paused/draining at edge)
        if self.inner.dual_deck.skip_handled_seq.load(Ordering::Acquire) < req
            && self.inner.dual_deck.deck_state(sb) == DeckState::StandbyReady
        {
            let _ = self.cmd_tx.send(PlayerCommand::ReopenOntoStandby {
                from_deck: cur,
                to_deck: sb,
                to_deck_gen: sb_gen,
                is_manual_skip: true,
                is_mismatch_recovery: false,
            });
            if let Ok(mut g) = lock.lock() {
                let deadline = Instant::now() + Duration::from_millis(400);
                while self.inner.dual_deck.active_idx() != sb && Instant::now() < deadline {
                    let rem = deadline.saturating_duration_since(Instant::now());
                    let (ng, _) = cvar.wait_timeout(g, rem).unwrap_or_else(|e| e.into_inner());
                    g = ng;
                }
            }
        }

        Ok(self.inner.dual_deck.active_idx() == sb)
    }

    /// Triggers seamless dual-track recovery after an L2 `FormatMismatch` event.
    /// Active continues playing from its local `.head` buffer while Standby opens pure-remote
    /// `fresh_spec` at `current_pts_ms + 800ms`, prebuffers 2s, and aligns a 5ms micro-crossfade.
    pub fn trigger_format_mismatch_recovery(
        &self,
        key: StreamKey,
        fresh_spec: StreamSourceSpec,
    ) -> Result<(), CoreAudioError> {
        if let StreamSourceSpec::ExternalBackend {
            key: ext_key,
            provider_id,
            ..
        } = &fresh_spec
        {
            return Err(CoreAudioError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                ext_key.track_id
            )));
        }

        let active_idx = self.inner.dual_deck.active_idx();
        let active_key_matches = self
            .inner
            .dual_deck
            .deck_keys
            .read()
            .ok()
            .and_then(|g| g[active_idx].clone())
            .is_none_or(|k| k == key);
        if !active_key_matches {
            return Ok(());
        }

        let state = self.inner.state_code.load(Ordering::Acquire);
        if self.inner.stopped.load(Ordering::Acquire)
            || (state != PlaybackLifecycleState::Playing as i32
                && state != PlaybackLifecycleState::Paused as i32)
        {
            return Err(CoreAudioError::Backend(BackendError::InvalidState(
                "No active playback session for format mismatch recovery".into(),
            )));
        }

        let cur_pts_ms = position_ms_from_inner(&self.inner);
        let target_pts_ms = cur_pts_ms.saturating_add(MISMATCH_ALIGNMENT_OFFSET_MS);
        let out_rate = self.inner.out_sample_rate.load(Ordering::Acquire).max(8_000) as u128;
        let target_frame = ((target_pts_ms as u128) * out_rate / 1000) as u64;
        let label = source_spec_default_label(&fresh_spec);

        self.prepare_standby_internal(
            PlayerOrigin::SourceSpec(fresh_spec),
            label,
            true,
            true,
            Some(target_pts_ms),
            Some(target_frame),
        )
    }

    fn prepare_standby_internal(
        &self,
        origin: PlayerOrigin,
        label: String,
        bypass_l2_read: bool,
        is_mismatch_recovery: bool,
        mismatch_pts_ms: Option<u64>,
        mismatch_frame: Option<u64>,
    ) -> Result<(), CoreAudioError> {
        let _op_guard = self
            .inner
            .dual_deck
            .skip_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());

        let sb = self.inner.dual_deck.standby_idx();
        let _ = self.inner.dual_deck.cancel_and_join_deck(sb);

        let deck_gen = self.inner.dual_deck.alloc_deck_gen(sb);
        self.inner.dual_deck.deck_states[sb]
            .store(DeckState::Resolving as u8, Ordering::SeqCst);
        self.inner.dual_deck.set_deck_key(sb, origin.stream_key());
        self.inner
            .dual_deck
            .standby_buffered_ms
            .store(0, Ordering::Relaxed);
        self.inner.dual_deck.standby_compatible[sb].store(false, Ordering::SeqCst);
        self.inner.dual_deck.standby_is_mismatch_recovery[sb]
            .store(is_mismatch_recovery, Ordering::SeqCst);
        self.inner.dual_deck.standby_target_pts_ms[sb]
            .store(mismatch_pts_ms.unwrap_or(0), Ordering::SeqCst);
        self.inner.dual_deck.standby_target_frame[sb]
            .store(mismatch_frame.unwrap_or(0), Ordering::SeqCst);

        let cancel_flag = Arc::new(AtomicBool::new(false));
        let cancel_token = CancellationToken::new();
        let wake = Arc::new((Mutex::new(StandbyWakeState::Parked), Condvar::new()));

        let worker_inner = Arc::clone(&self.inner);
        let worker_cmd_tx = self.cmd_tx.clone();
        let worker_cancel_flag = Arc::clone(&cancel_flag);
        let worker_cancel_token = cancel_token.clone();
        let worker_wake = Arc::clone(&wake);

        let mut entry_guard = self.inner.dual_deck.decode_entries[sb]
            .lock()
            .unwrap_or_else(|e| e.into_inner());

        let jh = thread::Builder::new()
            .name(format!("lumina-deck-standby-{sb}"))
            .spawn(move || {
                run_standby_deck_worker(
                    worker_inner,
                    worker_cmd_tx,
                    sb,
                    deck_gen,
                    origin,
                    label,
                    bypass_l2_read,
                    is_mismatch_recovery,
                    mismatch_pts_ms.unwrap_or(0),
                    mismatch_frame.unwrap_or(0),
                    worker_cancel_flag,
                    worker_cancel_token,
                    worker_wake,
                )
            })
            .map_err(|e| {
                self.inner.dual_deck.deck_states[sb]
                    .store(DeckState::Idle as u8, Ordering::SeqCst);
                self.inner.dual_deck.set_deck_key(sb, None);
                CoreAudioError::Backend(BackendError::DriverError(format!(
                    "Failed to spawn standby deck worker: {e}"
                )))
            })?;

        *entry_guard = Some(DeckDecodeHandle {
            deck_gen,
            cancel_flag,
            cancel_token,
            wake,
            join_handle: Some(jh),
        });
        Ok(())
    }

    pub fn pause(&self) {
        if let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_pause_fade_out();
        }
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
        if let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_play_fade_in();
        }
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
        if let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_stop_fade_out();
        }
        let _ = self.swap_cancel_and_bump_epoch(None, CancellationToken::new());
        self.inner.dual_deck.cancel_standby();
        self.inner.dual_deck.deck_states[0].store(DeckState::Idle as u8, Ordering::SeqCst);
        self.inner.dual_deck.deck_states[1].store(DeckState::Idle as u8, Ordering::SeqCst);
        self.inner.dual_deck.set_deck_key(0, None);
        self.inner.dual_deck.set_deck_key(1, None);
        self.inner
            .dual_deck
            .standby_buffered_ms
            .store(0, Ordering::Relaxed);
        if let Ok(mut spec_lock) = self.inner.active_source_spec.write() {
            *spec_lock = None;
        }
        if let Ok(mut next_spec_lock) = self.inner.queued_next_spec.write() {
            *next_spec_lock = None;
        }
        self.inner
            .has_queued_next_spec
            .store(false, Ordering::SeqCst);
        self.inner.stopped.store(true, Ordering::SeqCst);
        self.inner.paused.store(false, Ordering::SeqCst);
        self.inner.frames_rendered.store(0, Ordering::SeqCst);
        self.inner.buffered_ms.store(0, Ordering::Relaxed);
        self.inner
            .state_code
            .store(PlaybackLifecycleState::Stopped as i32, Ordering::SeqCst);
        let _ = self.cmd_tx.send(PlayerCommand::Stop);
    }

    pub fn seek_ms(&self, pos_ms: u64) {
        self.inner
            .dual_deck
            .mismatch_armed
            .store(false, Ordering::SeqCst);
        let dur = self.duration_ms();
        let clamped = if dur > 0 { pos_ms.min(dur) } else { pos_ms };
        let rate = self.inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
        let target_frames = ((clamped as u128) * rate / 1000) as u64;
        let new_seek_ep = {
            let _ep_guard = self
                .inner
                .epoch_lock
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            self.inner.epoch.fetch_add(1, Ordering::SeqCst);
            self.inner.seek_epoch.fetch_add(1, Ordering::SeqCst) + 1
        };
        self.inner.is_seeking.store(true, Ordering::SeqCst);
        let is_paused = self.inner.paused.load(Ordering::SeqCst);
        if !is_paused
            && let Ok(fade_lock) = self.inner.active_fade.read()
            && let Some(ref fc) = *fade_lock
        {
            fc.request_seek_fade_out(new_seek_ep);
        }
        let cur_state = self.inner.state_code.load(Ordering::SeqCst);
        let was_ended = cur_state == PlaybackLifecycleState::Ended as i32;
        if !is_paused
            && (cur_state == PlaybackLifecycleState::Playing as i32 || was_ended)
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
        let _ = self.cmd_tx.send(PlayerCommand::SeekMs { was_ended });
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
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: false,
            })
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
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: false,
            })
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
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: false,
            })
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

        let was_device_lost = self.inner.device_lost.swap(false, Ordering::SeqCst);
        let state = self.inner.state_code.load(Ordering::SeqCst);
        let is_active_stream = (!self.inner.stopped.load(Ordering::SeqCst)
            && (state == PlaybackLifecycleState::Playing as i32
                || state == PlaybackLifecycleState::Paused as i32))
            || (was_device_lost
                && (state == PlaybackLifecycleState::Paused as i32
                    || state == PlaybackLifecycleState::Error as i32));
        if !is_active_stream {
            if let Ok(mut vw) = self.inner.verification.write() {
                *vw = None;
            }
            if let Ok(mut meta_lock) = self.inner.active_meta.write() {
                *meta_lock = None;
            }
        }
        if was_device_lost {
            self.inner.clear_error_state();
        }

        let (ack_tx, ack_rx) = mpsc::sync_channel(1);
        if self
            .cmd_tx
            .send(PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost: was_device_lost,
            })
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

    /// Approximate PCM/wire duration currently queued in the playback ring buffer (in ms).
    pub fn buffered_ms(&self) -> u64 {
        self.inner.buffered_ms.load(Ordering::Relaxed)
    }

    /// Cumulative count of RT audio output ring-buffer underrun events for the active track.
    pub fn ring_buffer_underrun_count(&self) -> u64 {
        self.inner.ring_buffer_underrun_count.load(Ordering::Relaxed)
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

    pub fn shutdown(&self) {
        self.stop();
        self.inner.dual_deck.stop_relay();
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
        SharedReplayGainMode::Off => {
            if tags.from_streaming_spec && tags.track_db.is_some() {
                InternalReplayGainConfig {
                    mode: InternalReplayGainMode::Track,
                    preamp_db: 0.0,
                    track_gain_db: tags.track_db,
                    track_peak: tags.track_peak,
                    album_gain_db: tags.album_db,
                    album_peak: tags.album_peak,
                    prevent_clipping: cfg.prevent_clipping,
                }
            } else {
                InternalReplayGainConfig {
                    mode: InternalReplayGainMode::Track,
                    preamp_db: 0.0,
                    track_gain_db: None,
                    track_peak: None,
                    album_gain_db: None,
                    album_peak: None,
                    prevent_clipping: false,
                }
            }
        }
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
    if cfg.mode == SharedReplayGainMode::Off && !(tags.from_streaming_spec && tags.track_db.is_some())
    {
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
    } else if magic.starts_with(b"\x1A\x45\xDF\xA3") {
        Some("webm")
    } else {
        None
    }
}

fn provider_needs_network_epoch_reset(provider_id: &str) -> bool {
    crate::network_monitor::NETWORK_EPOCH_RESET_PROVIDERS
        .iter()
        .any(|p| p.eq_ignore_ascii_case(provider_id))
}

fn stream_error_to_core(err: StreamError) -> CoreAudioError {
    match err {
        StreamError::AuthRequired {
            provider_id,
            status,
        } => CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
            provider_id,
            status,
        }),
        StreamError::FormatChanged(spec) => {
            CoreAudioError::Decoder(DecoderError::StreamFormatChanged(spec))
        }
        StreamError::DrmRestricted(msg) | StreamError::Unsupported(msg) => {
            CoreAudioError::UnsupportedFormat(msg)
        }
        StreamError::InvalidManifest(msg) => CoreAudioError::InvalidConfig(msg),
        other => CoreAudioError::Io(other.to_io_error()),
    }
}

fn open_segmented_proxy_sync(
    key: StreamKey,
    manifest_url_or_xml: String,
    headers: std::collections::BTreeMap<String, String>,
    mime_type: Option<String>,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<SegmentedStreamProxy, CoreAudioError> {
    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    let rt = streaming_runtime().map_err(stream_error_to_core)?;
    let (tx, rx) = mpsc::sync_channel(1);
    let needs_epoch_reset = provider_needs_network_epoch_reset(&key.provider_id);
    rt.spawn(async move {
        let res = async {
            let transport = Arc::new(ReqwestStreamTransport::shared()?);
            SegmentedStreamProxy::open_with_refresh(
                manifest_url_or_xml,
                &headers,
                None,
                mime_type,
                transport,
                StreamHttpConfig::default(),
                cancel,
                Some(key),
                refresh_handler,
                needs_epoch_reset,
                DEFAULT_REFRESH_403_BACKOFFS,
                subscribe_network_epoch(),
            )
            .await
        }
        .await;
        let _ = tx.send(res);
    });
    rx.recv()
        .map_err(|_| CoreAudioError::Io(StreamError::Cancelled.to_io_error()))?
        .map_err(stream_error_to_core)
}

async fn open_segmented_proxy_async(
    key: StreamKey,
    manifest_url_or_xml: String,
    headers: std::collections::BTreeMap<String, String>,
    mime_type: Option<String>,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<SegmentedStreamProxy, CoreAudioError> {
    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    let rt = streaming_runtime().map_err(stream_error_to_core)?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    let needs_epoch_reset = provider_needs_network_epoch_reset(&key.provider_id);
    rt.spawn(async move {
        let res = async {
            let transport = Arc::new(ReqwestStreamTransport::shared()?);
            SegmentedStreamProxy::open_with_refresh(
                manifest_url_or_xml,
                &headers,
                None,
                mime_type,
                transport,
                StreamHttpConfig::default(),
                cancel,
                Some(key),
                refresh_handler,
                needs_epoch_reset,
                DEFAULT_REFRESH_403_BACKOFFS,
                subscribe_network_epoch(),
            )
            .await
        }
        .await;
        let _ = tx.send(res);
    });
    rx.await
        .map_err(|_| CoreAudioError::Io(StreamError::Cancelled.to_io_error()))?
        .map_err(stream_error_to_core)
}

fn run_on_streaming_runtime<F, T>(fut: F) -> Result<T, StreamError>
where
    F: std::future::Future<Output = Result<T, StreamError>> + Send + 'static,
    T: Send + 'static,
{
    let rt = streaming_runtime()?;
    if tokio::runtime::Handle::try_current().is_ok() {
        let (tx, rx) = mpsc::sync_channel(1);
        rt.spawn(async move {
            let _ = tx.send(fut.await);
        });
        rx.recv()
            .map_err(|_| StreamError::Io("L2 runtime channel closed".to_string()))?
    } else {
        rt.block_on(fut)
    }
}

fn compute_l2_target_bytes_for_spec(spec: &StreamSourceSpec) -> u64 {
    match spec {
        StreamSourceSpec::DirectRange {
            key,
            bitrate_bps,
            content_length,
            ..
        } => compute_l2_target_bytes(&key.provider_id, *bitrate_bps, *content_length, false),
        StreamSourceSpec::EncryptedRange {
            key,
            bitrate_bps,
            content_length,
            ..
        } => compute_l2_target_bytes(&key.provider_id, *bitrate_bps, *content_length, true),
        StreamSourceSpec::SegmentedManifest {
            key, bitrate_bps, ..
        } => compute_l2_target_bytes(&key.provider_id, *bitrate_bps, None, false),
        _ => 0,
    }
}

fn build_mismatch_callback(
    inner: &Arc<PlayerInner>,
    spec: &StreamSourceSpec,
) -> Option<FormatMismatchCallback> {
    let cmd_tx = inner.cmd_tx_slot.get()?.clone();
    let weak_inner = Arc::downgrade(inner);
    let spec_clone = spec.clone();
    Some(Arc::new(move |mismatch_key, reason| {
        tracing::warn!(
            "L2 FormatMismatch detected for {mismatch_key:?}: {reason:?}; triggering dual-track recovery"
        );
        if let Some(strong_inner) = weak_inner.upgrade() {
            let player = AudioPlayer {
                inner: strong_inner,
                cmd_tx: cmd_tx.clone(),
            };
            let _ = player.trigger_format_mismatch_recovery(mismatch_key, spec_clone.clone());
        }
    }))
}

async fn wait_for_l2_stable_play_gate(
    key: &StreamKey,
    min_play_ms: u64,
    bypass_l2_read: bool,
    cancel: &CancellationToken,
    weak_inner: &Option<std::sync::Weak<PlayerInner>>,
) -> Option<u64> {
    if bypass_l2_read || min_play_ms == 0 {
        return Some(min_play_ms);
    }
    let mut played_ms = 0u64;
    let step_ms = 50u64;
    while played_ms < min_play_ms {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return None,
            _ = tokio::time::sleep(Duration::from_millis(step_ms)) => {}
        }
        if cancel.is_cancelled() {
            return None;
        }
        if let Some(wi) = weak_inner {
            let Some(inner) = wi.upgrade() else {
                return None;
            };
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
            if is_active_track
                && inner.state_code.load(Ordering::Relaxed) == PlaybackLifecycleState::Playing as i32
                && !inner.paused.load(Ordering::Relaxed)
            {
                played_ms = played_ms
                    .saturating_add(step_ms)
                    .max(position_ms_from_inner(&inner));
            }
        } else {
            played_ms = played_ms.saturating_add(step_ms);
        }
    }
    Some(played_ms)
}

fn spawn_direct_l2_admission_task(
    l2: Arc<L2CacheManager>,
    spec: StreamSourceSpec,
    proxy: Arc<ChunkedStreamProxy>,
    cancel: CancellationToken,
    bypass_l2_read: bool,
    weak_inner: Option<std::sync::Weak<PlayerInner>>,
) {
    let target_bytes = compute_l2_target_bytes_for_spec(&spec);
    let index_range_end = match &spec {
        StreamSourceSpec::DirectRange {
            index_range_end, ..
        } => *index_range_end,
        _ => None,
    };
    let key = spec.key().clone();
    let min_play_ms = l2.config().min_stable_play_ms;
    if !should_admit_to_l2(
        &key,
        target_bytes,
        min_play_ms,
        min_play_ms,
        0,
        index_range_end,
        false,
    ) {
        return;
    }
    if let Ok(rt) = streaming_runtime() {
        rt.spawn(async move {
            let Some(played_ms) = wait_for_l2_stable_play_gate(
                &key,
                min_play_ms,
                bypass_l2_read,
                &cancel,
                &weak_inner,
            )
            .await
            else {
                return;
            };
            if !should_admit_to_l2(
                &key,
                target_bytes,
                played_ms,
                min_play_ms,
                0,
                index_range_end,
                false,
            ) {
                return;
            }
            if let Ok(prefix) = proxy.capture_prefix_bytes(target_bytes).await
                && !prefix.is_empty()
                && !cancel.is_cancelled()
            {
                let _ = l2.store_direct_head(&key, &prefix, proxy.len(), 0).await;
            }
        });
    }
}

fn spawn_dash_l2_admission_task(
    l2: Arc<L2CacheManager>,
    spec: StreamSourceSpec,
    proxy: Arc<SegmentedStreamProxy>,
    cancel: CancellationToken,
    bypass_l2_read: bool,
    weak_inner: Option<std::sync::Weak<PlayerInner>>,
) {
    let target_bytes = compute_l2_target_bytes_for_spec(&spec);
    let key = spec.key().clone();
    let min_play_ms = l2.config().min_stable_play_ms;
    if !should_admit_to_l2(&key, target_bytes, min_play_ms, min_play_ms, 0, None, false) {
        return;
    }
    if let Ok(rt) = streaming_runtime() {
        rt.spawn(async move {
            let Some(played_ms) = wait_for_l2_stable_play_gate(
                &key,
                min_play_ms,
                bypass_l2_read,
                &cancel,
                &weak_inner,
            )
            .await
            else {
                return;
            };
            if !should_admit_to_l2(&key, target_bytes, played_ms, min_play_ms, 0, None, false) {
                return;
            }
            if let Ok(pkg) = proxy.export_l2_package(target_bytes as usize).await
                && !cancel.is_cancelled()
            {
                let _ = l2.store_dash_head(&key, &pkg, 0).await;
            }
        });
    }
}

fn open_bridge_for_sync_spec(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    weak_inner: Option<std::sync::Weak<PlayerInner>>,
) -> Result<BlockingStreamBridge, CoreAudioError> {
    match spec {
        StreamSourceSpec::DirectRange {
            key,
            url,
            headers,
            content_length,
            bitrate_bps,
            hint_extension,
            mime_type,
            loudness,
            album_loudness,
            ..
        } => {
            let l2_hit = if !bypass_l2_read && let Some(ref l2) = l2_manager {
                let l2_c = Arc::clone(l2);
                let key_c = key.clone();
                run_on_streaming_runtime(async move { l2_c.lookup_direct_head(&key_c).await })
                    .ok()
                    .flatten()
            } else {
                None
            };
            let eff_len = l2_hit
                .as_ref()
                .and_then(|h| h.total_content_length)
                .or(*content_length);
            let mut raw_proxy = ChunkedStreamProxy::new(
                url.as_str(),
                headers,
                eff_len,
                hint_extension.clone(),
                mime_type.clone(),
            )
            .map_err(stream_error_to_core)?
            .with_expected_kind("direct_range")
            .with_spec_metadata(*bitrate_bps, *loudness, *album_loudness)
            .with_cancellation_token(cancel.clone());
            raw_proxy = if let Some(handler) = refresh_handler {
                raw_proxy.with_refresh_context(
                    key.clone(),
                    handler,
                    provider_needs_network_epoch_reset(&key.provider_id),
                )
            } else {
                raw_proxy.with_stream_key(key.clone())
            };
            let proxy = Arc::new(raw_proxy);
            if let (Some(hit), Some(l2)) = (l2_hit, l2_manager.as_ref())
                && let Ok(hybrid) = HybridByteStream::new(
                    key.clone(),
                    hit,
                    Arc::clone(&proxy),
                    Arc::clone(l2),
                    on_mismatch,
                )
            {
                return BlockingStreamBridge::new(Arc::new(hybrid)).map_err(stream_error_to_core);
            }
            if let Some(l2) = l2_manager {
                spawn_direct_l2_admission_task(
                    l2,
                    spec.clone(),
                    Arc::clone(&proxy),
                    cancel,
                    bypass_l2_read,
                    weak_inner,
                );
            }
            BlockingStreamBridge::new(proxy).map_err(stream_error_to_core)
        }
        StreamSourceSpec::EncryptedRange {
            key,
            url,
            headers,
            content_length,
            bitrate_bps,
            hint_extension,
            mime_type,
            cipher,
            loudness,
            album_loudness,
            ..
        } => match cipher {
            StreamCipher::DeezerBlowfish {
                track_id,
                block_size,
                stride,
            } => {
                let l2_hit = if !bypass_l2_read && let Some(ref l2) = l2_manager {
                    let l2_c = Arc::clone(l2);
                    let key_c = key.clone();
                    run_on_streaming_runtime(async move { l2_c.lookup_direct_head(&key_c).await })
                        .ok()
                        .flatten()
                } else {
                    None
                };
                let eff_len = l2_hit
                    .as_ref()
                    .and_then(|h| h.total_content_length)
                    .or(*content_length);
                let stripe = block_size.saturating_mul(*stride).max(1);
                let chunk_size = if stripe == 6144 {
                    DEEZER_ALIGNED_CHUNK_SIZE
                } else {
                    ((512 * 1024) / stripe).max(1).saturating_mul(stripe)
                };
                let initial_chunk_size = if stripe == 6144 {
                    DEEZER_INITIAL_CHUNK_SIZE
                } else {
                    (DEFAULT_INITIAL_CHUNK_SIZE / stripe)
                        .max(1)
                        .saturating_mul(stripe)
                };
                let mut raw_proxy = ChunkedStreamProxy::new(
                    url.as_str(),
                    headers,
                    eff_len,
                    hint_extension.clone(),
                    mime_type.clone(),
                )
                .map_err(stream_error_to_core)?
                .with_expected_kind("encrypted_range")
                .with_spec_metadata(*bitrate_bps, *loudness, *album_loudness)
                .with_initial_chunk_size(initial_chunk_size)
                .with_chunk_size(chunk_size)
                .with_range_alignment(stripe)
                .with_cancellation_token(cancel.clone());
                raw_proxy = if let Some(handler) = refresh_handler {
                    raw_proxy.with_refresh_context(
                        key.clone(),
                        handler,
                        provider_needs_network_epoch_reset(&key.provider_id),
                    )
                } else {
                    raw_proxy.with_stream_key(key.clone())
                };
                let proxy = Arc::new(raw_proxy);
                if let (Some(hit), Some(l2)) = (l2_hit, l2_manager.as_ref())
                    && let Ok(hybrid) = HybridByteStream::new(
                        key.clone(),
                        hit,
                        Arc::clone(&proxy),
                        Arc::clone(l2),
                        on_mismatch,
                    )
                {
                    let decrypting = Arc::new(
                        DecryptingByteStream::with_geometry(
                            Arc::new(hybrid),
                            track_id,
                            *block_size,
                            *stride,
                        )
                        .map_err(stream_error_to_core)?,
                    );
                    return BlockingStreamBridge::new(decrypting).map_err(stream_error_to_core);
                }
                if let Some(l2) = l2_manager {
                    spawn_direct_l2_admission_task(
                        l2,
                        spec.clone(),
                        Arc::clone(&proxy),
                        cancel,
                        bypass_l2_read,
                        weak_inner,
                    );
                }
                let decrypting = Arc::new(
                    DecryptingByteStream::with_geometry(proxy, track_id, *block_size, *stride)
                        .map_err(stream_error_to_core)?,
                );
                BlockingStreamBridge::new(decrypting).map_err(stream_error_to_core)
            }
        },
        _ => Err(CoreAudioError::InvalidConfig(
            "Expected DirectRange or EncryptedRange StreamSourceSpec".to_string(),
        )),
    }
}

/// Synchronously opens a decoder for a declarative [`StreamSourceSpec`] with cooperative
/// [`CancellationToken`] support. Safe to call from OS threads or `tokio::task::spawn_blocking`.
pub fn open_decoder_for_source_spec(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_with_refresh(spec, cancel, None)
}

/// Synchronously opens a decoder for a declarative [`StreamSourceSpec`] with an optional
/// [`StreamRefreshHandler`] attached to range/segmented proxies.
pub fn open_decoder_for_source_spec_with_refresh(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_with_l2(spec, cancel, refresh_handler, None, false, None, None)
}

/// Synchronously opens a decoder for a declarative [`StreamSourceSpec`] with optional L2 cache,
/// bypass control, format mismatch callback, and stable-play admission capture.
///
/// If an expired initial URL triggers HTTP 403/410 self-healing at `offset = 0` before any audio
/// is decoded and the refresh returns a fallback format/length (`StreamFormatChanged`), this
/// function adopts the refreshed spec (bypassing stale L2) up to 2 times seamlessly.
fn open_decoder_for_source_spec_with_l2(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    weak_inner: Option<std::sync::Weak<PlayerInner>>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_with_l2_adopted(
        spec,
        cancel,
        refresh_handler,
        l2_manager,
        bypass_l2_read,
        on_mismatch,
        weak_inner,
    )
    .map(|(dec, _)| dec)
}

fn open_decoder_for_source_spec_with_l2_adopted(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    weak_inner: Option<std::sync::Weak<PlayerInner>>,
) -> Result<(Box<dyn AudioDecoder>, StreamSourceSpec), CoreAudioError> {
    const MAX_INITIAL_FORMAT_ADOPTIONS: usize = 2;
    let mut current_spec = spec.clone();
    let mut current_bypass_l2 = bypass_l2_read;

    for attempt in 0..=MAX_INITIAL_FORMAT_ADOPTIONS {
        match open_decoder_for_source_spec_once(
            &current_spec,
            cancel.clone(),
            refresh_handler.clone(),
            l2_manager.clone(),
            current_bypass_l2,
            on_mismatch.clone(),
            weak_inner.clone(),
        ) {
            Err(CoreAudioError::Decoder(DecoderError::StreamFormatChanged(next_spec)))
                if attempt < MAX_INITIAL_FORMAT_ADOPTIONS && !cancel.is_cancelled() =>
            {
                current_spec = *next_spec;
                current_bypass_l2 = true;
            }
            Ok(dec) => return Ok((dec, current_spec)),
            Err(e) => return Err(e),
        }
    }
    unreachable!()
}

async fn lookup_dash_head_async(
    l2: Arc<L2CacheManager>,
    key: StreamKey,
) -> Option<crate::streaming::L2DashHit> {
    let rt = streaming_runtime().ok()?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    rt.spawn(async move {
        let _ = tx.send(l2.lookup_dash_head(&key).await.ok().flatten());
    });
    rx.await.ok().flatten()
}

async fn open_decoder_for_source_spec_async_with_l2(
    spec: StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    inner: Option<Arc<PlayerInner>>,
) -> Result<(OpenedStreamDecoder, StreamSourceSpec), CoreAudioError> {
    const MAX_INITIAL_FORMAT_ADOPTIONS: usize = 2;
    let mut current_spec = spec;
    let mut current_bypass_l2 = false;

    for attempt in 0..=MAX_INITIAL_FORMAT_ADOPTIONS {
        if cancel.is_cancelled() {
            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
        }
        let on_mismatch = inner
            .as_ref()
            .and_then(|i| build_mismatch_callback(i, &current_spec));
        let weak_inner = inner.as_ref().map(Arc::downgrade);

        let res: Result<(OpenedStreamDecoder, StreamSourceSpec), CoreAudioError> = match &current_spec
        {
            StreamSourceSpec::ExternalBackend {
                key, provider_id, ..
            } => Err(CoreAudioError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                key.track_id
            ))),
            StreamSourceSpec::SegmentedManifest {
                key,
                manifest_url_or_xml,
                format,
                headers,
                mime_type,
                ..
            } => {
                if *format != ManifestFormat::Dash {
                    return Err(CoreAudioError::UnsupportedFormat(
                        "HLS manifest playback is not supported in Phase 1".to_string(),
                    ));
                }
                let audio_mime = mime_type
                    .as_deref()
                    .map(str::trim)
                    .filter(|m| !m.is_empty() && !m.eq_ignore_ascii_case("application/dash+xml"))
                    .map(str::to_string);

                if !current_bypass_l2
                    && let Some(ref l2) = l2_manager
                    && let Some(hit) = lookup_dash_head_async(Arc::clone(l2), key.clone()).await
                {
                    let cfg = HybridSegmentedConfig {
                        headers: headers.clone(),
                        hint_extension: None,
                        mime_type: audio_mime.clone(),
                        http_config: StreamHttpConfig::default(),
                        refresh_handler: refresh_handler.clone(),
                        needs_network_epoch_reset: provider_needs_network_epoch_reset(
                            &key.provider_id,
                        ),
                        refresh_backoffs: DEFAULT_REFRESH_403_BACKOFFS,
                        prefetch_ahead: DEFAULT_PREFETCH_AHEAD,
                        epoch_rx: None,
                        on_mismatch: on_mismatch.clone(),
                    };
                    if let Ok(hybrid) = HybridSegmentedStream::open_shared(
                        key.clone(),
                        hit,
                        manifest_url_or_xml.clone(),
                        Arc::clone(l2),
                        cancel.clone(),
                        cfg,
                    ) {
                        let dur_ms = hybrid.total_duration_ms();
                        let spec_clone = current_spec.clone();
                        let cancel_clone = cancel.clone();
                        let opened = tokio::task::spawn_blocking(move || {
                            if cancel_clone.is_cancelled() {
                                return Err(CoreAudioError::Io(
                                    StreamError::Cancelled.to_io_error(),
                                ));
                            }
                            let bridge = BlockingStreamBridge::new(Arc::new(hybrid))
                                .map_err(stream_error_to_core)?;
                            let decoder = SymphoniaDecoder::from_blocking_bridge_with_duration(
                                bridge,
                                &spec_clone,
                                dur_ms,
                            )?;
                            Ok((Box::new(decoder) as OpenedStreamDecoder, spec_clone))
                        })
                        .await
                        .map_err(|e| {
                            CoreAudioError::Io(std::io::Error::other(format!(
                                "Decoder open task failed: {e}"
                            )))
                        })?;
                        if opened.is_ok() {
                            return opened;
                        }
                    }
                }

                match open_segmented_proxy_async(
                    key.clone(),
                    manifest_url_or_xml.clone(),
                    headers.clone(),
                    audio_mime,
                    cancel.clone(),
                    refresh_handler.clone(),
                )
                .await
                {
                    Err(e) => Err(e),
                    Ok(proxy) => {
                        if cancel.is_cancelled() {
                            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
                        }
                        let dur_ms = proxy.manifest().duration_ms;
                        let proxy_arc = Arc::new(proxy);
                        if let Some(ref l2) = l2_manager {
                            spawn_dash_l2_admission_task(
                                Arc::clone(l2),
                                current_spec.clone(),
                                Arc::clone(&proxy_arc),
                                cancel.clone(),
                                current_bypass_l2,
                                weak_inner,
                            );
                        }
                        let spec_clone = current_spec.clone();
                        let cancel_clone = cancel.clone();
                        tokio::task::spawn_blocking(move || {
                            if cancel_clone.is_cancelled() {
                                return Err(CoreAudioError::Io(
                                    StreamError::Cancelled.to_io_error(),
                                ));
                            }
                            let bridge = BlockingStreamBridge::new(proxy_arc)
                                .map_err(stream_error_to_core)?;
                            let decoder = SymphoniaDecoder::from_blocking_bridge_with_duration(
                                bridge,
                                &spec_clone,
                                dur_ms,
                            )?;
                            Ok((Box::new(decoder) as OpenedStreamDecoder, spec_clone))
                        })
                        .await
                        .map_err(|e| {
                            CoreAudioError::Io(std::io::Error::other(format!(
                                "Decoder open task failed: {e}"
                            )))
                        })?
                    }
                }
            }
            _ => {
                let spec_clone = current_spec.clone();
                let cancel_clone = cancel.clone();
                let refresh_clone = refresh_handler.clone();
                let l2_clone = l2_manager.clone();
                return tokio::task::spawn_blocking(move || {
                    open_decoder_for_source_spec_with_l2_adopted(
                        &spec_clone,
                        cancel_clone,
                        refresh_clone,
                        l2_clone,
                        current_bypass_l2,
                        on_mismatch,
                        weak_inner,
                    )
                })
                .await
                .map_err(|e| {
                    CoreAudioError::Io(std::io::Error::other(format!(
                        "Decoder open task failed: {e}"
                    )))
                })?;
            }
        };

        match res {
            Err(CoreAudioError::Decoder(DecoderError::StreamFormatChanged(next_spec)))
                if attempt < MAX_INITIAL_FORMAT_ADOPTIONS && !cancel.is_cancelled() =>
            {
                current_spec = *next_spec;
                current_bypass_l2 = true;
            }
            other => return other,
        }
    }
    unreachable!()
}

fn open_decoder_for_source_spec_once(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    weak_inner: Option<std::sync::Weak<PlayerInner>>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    match spec {
        StreamSourceSpec::ExternalBackend {
            key, provider_id, ..
        } => Err(CoreAudioError::UnsupportedFormat(format!(
            "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
            key.track_id
        ))),
        StreamSourceSpec::LocalFile { path, .. } => open_decoder_for_path(Path::new(path)),
        StreamSourceSpec::DirectRange { .. } | StreamSourceSpec::EncryptedRange { .. } => {
            let bridge = open_bridge_for_sync_spec(
                spec,
                cancel,
                refresh_handler,
                l2_manager,
                bypass_l2_read,
                on_mismatch,
                weak_inner,
            )?;
            let decoder = SymphoniaDecoder::from_blocking_bridge(bridge, spec)?;
            Ok(Box::new(decoder))
        }
        StreamSourceSpec::SegmentedManifest {
            key,
            manifest_url_or_xml,
            format,
            headers,
            mime_type,
            ..
        } => {
            if *format != ManifestFormat::Dash {
                return Err(CoreAudioError::UnsupportedFormat(
                    "HLS manifest playback is not supported in Phase 1".to_string(),
                ));
            }
            let audio_mime = mime_type
                .as_deref()
                .map(str::trim)
                .filter(|m| !m.is_empty() && !m.eq_ignore_ascii_case("application/dash+xml"))
                .map(str::to_string);
            if !bypass_l2_read && let Some(ref l2) = l2_manager {
                let l2_c = Arc::clone(l2);
                let key_c = key.clone();
                if let Some(hit) = run_on_streaming_runtime(async move {
                    l2_c.lookup_dash_head(&key_c).await
                })
                .ok()
                .flatten()
                {
                    let cfg = HybridSegmentedConfig {
                        headers: headers.clone(),
                        hint_extension: None,
                        mime_type: audio_mime.clone(),
                        http_config: StreamHttpConfig::default(),
                        refresh_handler: refresh_handler.clone(),
                        needs_network_epoch_reset: provider_needs_network_epoch_reset(
                            &key.provider_id,
                        ),
                        refresh_backoffs: DEFAULT_REFRESH_403_BACKOFFS,
                        prefetch_ahead: DEFAULT_PREFETCH_AHEAD,
                        epoch_rx: None,
                        on_mismatch,
                    };
                    if let Ok(hybrid) = HybridSegmentedStream::open_shared(
                        key.clone(),
                        hit,
                        manifest_url_or_xml.clone(),
                        Arc::clone(l2),
                        cancel.clone(),
                        cfg,
                    ) {
                        let dur_ms = hybrid.total_duration_ms();
                        let bridge = BlockingStreamBridge::new(Arc::new(hybrid))
                            .map_err(stream_error_to_core)?;
                        let decoder = SymphoniaDecoder::from_blocking_bridge_with_duration(
                            bridge, spec, dur_ms,
                        )?;
                        return Ok(Box::new(decoder));
                    }
                }
            }
            let proxy = open_segmented_proxy_sync(
                key.clone(),
                manifest_url_or_xml.clone(),
                headers.clone(),
                audio_mime,
                cancel.clone(),
                refresh_handler,
            )?;
            let dur_ms = proxy.manifest().duration_ms;
            let proxy_arc = Arc::new(proxy);
            if let Some(l2) = l2_manager {
                spawn_dash_l2_admission_task(
                    l2,
                    spec.clone(),
                    Arc::clone(&proxy_arc),
                    cancel,
                    bypass_l2_read,
                    weak_inner,
                );
            }
            let bridge = BlockingStreamBridge::new(proxy_arc).map_err(stream_error_to_core)?;
            let decoder =
                SymphoniaDecoder::from_blocking_bridge_with_duration(bridge, spec, dur_ms)?;
            Ok(Box::new(decoder))
        }
    }
}

/// Non-blocking/cancellable async helper that resolves manifests on `STREAMING_RUNTIME` and
/// probes the decoder via `tokio::task::spawn_blocking` without calling `block_on`.
pub async fn open_decoder_for_source_spec_async(
    spec: StreamSourceSpec,
    cancel: CancellationToken,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_async_with_refresh(spec, cancel, None).await
}

/// Non-blocking/cancellable async helper with an optional [`StreamRefreshHandler`] wired into
/// range and DASH segmented proxies.
pub async fn open_decoder_for_source_spec_async_with_refresh(
    spec: StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    const MAX_INITIAL_FORMAT_ADOPTIONS: usize = 2;
    let mut current_spec = spec;

    for attempt in 0..=MAX_INITIAL_FORMAT_ADOPTIONS {
        if cancel.is_cancelled() {
            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
        }
        let res = match &current_spec {
            StreamSourceSpec::ExternalBackend {
                key, provider_id, ..
            } => Err(CoreAudioError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                key.track_id
            ))),
            StreamSourceSpec::SegmentedManifest {
                key,
                manifest_url_or_xml,
                format,
                headers,
                mime_type,
                ..
            } => {
                if *format != ManifestFormat::Dash {
                    return Err(CoreAudioError::UnsupportedFormat(
                        "HLS manifest playback is not supported in Phase 1".to_string(),
                    ));
                }
                let audio_mime = mime_type
                    .as_deref()
                    .map(str::trim)
                    .filter(|m| !m.is_empty() && !m.eq_ignore_ascii_case("application/dash+xml"))
                    .map(str::to_string);
                match open_segmented_proxy_async(
                    key.clone(),
                    manifest_url_or_xml.clone(),
                    headers.clone(),
                    audio_mime,
                    cancel.clone(),
                    refresh_handler.clone(),
                )
                .await
                {
                    Err(e) => Err(e),
                    Ok(proxy) => {
                        if cancel.is_cancelled() {
                            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
                        }
                        let dur_ms = proxy.manifest().duration_ms;
                        let spec_clone = current_spec.clone();
                        let cancel_clone = cancel.clone();
                        tokio::task::spawn_blocking(move || {
                            if cancel_clone.is_cancelled() {
                                return Err(CoreAudioError::Io(
                                    StreamError::Cancelled.to_io_error(),
                                ));
                            }
                            let bridge = BlockingStreamBridge::new(Arc::new(proxy))
                                .map_err(stream_error_to_core)?;
                            let decoder = SymphoniaDecoder::from_blocking_bridge_with_duration(
                                bridge,
                                &spec_clone,
                                dur_ms,
                            )?;
                            Ok(Box::new(decoder) as Box<dyn AudioDecoder>)
                        })
                        .await
                        .map_err(|e| {
                            CoreAudioError::Io(std::io::Error::other(format!(
                                "Decoder open task failed: {e}"
                            )))
                        })?
                    }
                }
            }
            _ => {
                let spec_clone = current_spec.clone();
                let cancel_clone = cancel.clone();
                let refresh_clone = refresh_handler.clone();
                return tokio::task::spawn_blocking(move || {
                    open_decoder_for_source_spec_with_refresh(
                        &spec_clone,
                        cancel_clone,
                        refresh_clone,
                    )
                })
                .await
                .map_err(|e| {
                    CoreAudioError::Io(std::io::Error::other(format!(
                        "Decoder open task failed: {e}"
                    )))
                })?;
            }
        };

        match res {
            Err(CoreAudioError::Decoder(DecoderError::StreamFormatChanged(next_spec)))
                if attempt < MAX_INITIAL_FORMAT_ADOPTIONS && !cancel.is_cancelled() =>
            {
                current_spec = *next_spec;
            }
            other => return other,
        }
    }
    unreachable!()
}

pub fn open_decoder_for_stream(stream: &StreamSource) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_stream_cancellable(stream, None, Duration::from_secs(10))
}

fn open_decoder_for_stream_with_token(
    stream: &StreamSource,
    cancel: CancellationToken,
    timeout: Duration,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    let cancel_flag = Arc::new(AtomicBool::new(false));
    let guard_token = cancel.child_token();
    if let Ok(rt) = streaming_runtime() {
        let watch_token = guard_token.clone();
        let watch_flag = Arc::clone(&cancel_flag);
        rt.spawn(async move {
            watch_token.cancelled().await;
            watch_flag.store(true, Ordering::SeqCst);
        });
    }
    let res = open_decoder_for_stream_cancellable(stream, Some(cancel_flag), timeout);
    guard_token.cancel();
    res
}

pub fn open_decoder_for_stream_cancellable(
    stream: &StreamSource,
    cancel: Option<Arc<AtomicBool>>,
    timeout: Duration,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    let check_cancelled = || -> Result<(), CoreAudioError> {
        if cancel.as_ref().is_some_and(|flag| flag.load(Ordering::SeqCst)) {
            Err(std::io::Error::new(std::io::ErrorKind::Interrupted, "Stream open cancelled").into())
        } else {
            Ok(())
        }
    };
    check_cancelled()?;
    match &stream.origin {
        StreamOrigin::LocalFile(path) => open_decoder_for_path(path),
        StreamOrigin::Http { url, headers } => {
            let deadline = Instant::now() + timeout;
            let remaining = || {
                let rem = deadline.saturating_duration_since(Instant::now());
                if rem.is_zero() {
                    Duration::from_millis(1)
                } else {
                    rem
                }
            };
            let mut media = HttpRangeMediaSource::open_with_cancel(
                url,
                headers,
                cancel.clone(),
                remaining(),
            )?;
            check_cancelled()?;
            let mut magic = media.read_magic_prefix(32)?;
            check_cancelled()?;
            if looks_like_playlist_magic(&magic) {
                let resolved = resolve_playlist_url_with_cancel(
                    media.resolved_url(),
                    headers,
                    cancel.clone(),
                    remaining(),
                )?;
                check_cancelled()?;
                media = HttpRangeMediaSource::open_with_cancel(
                    &resolved,
                    headers,
                    cancel.clone(),
                    remaining(),
                )?;
                check_cancelled()?;
                magic = media.read_magic_prefix(32)?;
                check_cancelled()?;
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
    dual_deck: Arc<DualDeckControl>,
    cancel_flag: Arc<AtomicBool>,
    output_kill_flag: Arc<AtomicBool>,
    fade_ctrl: Arc<AudioFadeControl>,
    cancel_token: CancellationToken,
    eof_flag: Arc<AtomicBool>,
    decode_handle: Option<JoinHandle<Option<Box<dyn AudioDecoder>>>>,
    virtual_handle: Option<JoinHandle<()>>,
    _cpal_stream: Option<cpal::Stream>,
    native_output: Option<NativeOutputSession>,
    path: PathBuf,
    source_label: String,
    origin: PlayerOrigin,
    format: AudioFormat,
    duration_ms: u64,
    pcm_rate: u32,
    active_device_id: String,
}

struct SavedRecoverySession {
    path: PathBuf,
    source_label: String,
    origin: PlayerOrigin,
    format: AudioFormat,
    duration_ms: u64,
    pcm_rate: u32,
    resume_pos_ms: u64,
    was_playing: bool,
    from_suspend: bool,
}

impl ActiveSession {
    fn stop_and_join(&mut self) -> Option<Box<dyn AudioDecoder>> {
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

fn maybe_reclaim_idle_memory(
    inner: &PlayerInner,
    decoder: &mut dyn AudioDecoder,
    paused_since: &mut Option<Instant>,
    idle_reclaimed: &mut bool,
) {
    if inner.paused.load(Ordering::Relaxed) {
        let started = *paused_since.get_or_insert_with(Instant::now);
        if !*idle_reclaimed {
            let threshold = inner
                .idle_reclaim_threshold
                .read()
                .map(|g| *g)
                .unwrap_or(DEFAULT_IDLE_RECLAIM_THRESHOLD);
            if started.elapsed() >= threshold {
                let freed = decoder.reclaim_idle_memory();
                drop_idle_http_connections();
                *idle_reclaimed = true;
                inner.idle_reclaim_count.fetch_add(1, Ordering::Relaxed);
                tracing::info!("Idle pause memory reclamation executed (freed {freed} bytes)");
            }
        }
    } else {
        *paused_since = None;
        *idle_reclaimed = false;
    }
}

/// Called when the decoder hits end of stream. The buffered tail may still be playing, so
/// keep the thread (and decoder) alive until a seek, a queued next track, cancel or stop.
/// Returns `true` if decoding should continue (seek or queued track), `false` to exit.
fn wait_at_eof(
    inner: &PlayerInner,
    decoder: &mut dyn AudioDecoder,
    cancel_flag: &AtomicBool,
    eof_flag: &AtomicBool,
    paused_since: &mut Option<Instant>,
    idle_reclaimed: &mut bool,
) -> bool {
    eof_flag.store(true, Ordering::SeqCst);
    loop {
        if cancel_flag.load(Ordering::Relaxed)
            || inner.stopped.load(Ordering::Relaxed)
            || inner.device_lost.load(Ordering::Acquire)
        {
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
        maybe_reclaim_idle_memory(inner, decoder, paused_since, idle_reclaimed);
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
    let inferred_code = if lower.contains("device") || lower.contains("invalidated") {
        inner.device_lost.store(true, Ordering::SeqCst);
        Some("DEVICE_LOST")
    } else {
        None
    };
    record_playback_error_with_code(inner, msg, inferred_code, None);
}

fn record_playback_error_with_code(
    inner: &PlayerInner,
    msg: String,
    code: Option<&str>,
    provider: Option<String>,
) {
    if code == Some("DEVICE_LOST") {
        inner.device_lost.store(true, Ordering::SeqCst);
    }
    if let Ok(mut err_lock) = inner.last_error.write() {
        *err_lock = Some(msg);
    }
    if let Ok(mut code_lock) = inner.last_error_code.write() {
        *code_lock = code.map(str::to_string);
    }
    if let Ok(mut prov_lock) = inner.last_error_provider.write() {
        *prov_lock = provider;
    }
    inner.stopped.store(true, Ordering::SeqCst);
    inner
        .state_code
        .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
}

fn is_any_dsp_active(inner: &PlayerInner) -> bool {
    let cfg = inner
        .dsp_config
        .read()
        .map(|g| g.clone())
        .unwrap_or_else(|_| default_shared_dsp_config());
    if inner.dsp_bypassed.load(Ordering::Relaxed) || cfg.bypass {
        return false;
    }
    let peq_active = cfg.peq_bands.iter().any(|b| {
        b.enabled
            && (b.gain_db.abs() > 1e-4
                || matches!(
                    b.filter_type,
                    PeqFilterKind::LowPass | PeqFilterKind::HighPass
                ))
    });
    if peq_active || cfg.crossfeed.enabled {
        return true;
    }
    let rg_tags = inner
        .track_replay_gain
        .read()
        .map(|g| g.clone())
        .unwrap_or_default();
    compute_effective_replay_gain_db(&cfg.replay_gain, &rg_tags).is_some()
}

fn is_fatal_seek_io_error(err: &crate::error::DecoderError) -> bool {
    match err {
        crate::error::DecoderError::Io(io_err) => {
            io_err.kind() != std::io::ErrorKind::Unsupported
        }
        _ => {
            let msg = err.to_string();
            msg.contains("HTTP ")
                && !msg.contains("unsupported on unseekable HTTP stream")
                && !msg.contains("Backward seek past retained buffer on non-range HTTP stream")
        }
    }
}

struct PipelineSpec {
    session_id: u64,
    pcm_rate: u32,
    out_channels: u16,
    path: PathBuf,
    source_label: String,
    origin: PlayerOrigin,
    cancel_token: CancellationToken,
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

fn commit_deck_metadata_to_inner(inner: &PlayerInner, snap: &DeckMetadataSnapshot) {
    inner.duration_ms.store(snap.duration_ms, Ordering::SeqCst);
    inner.out_sample_rate.store(snap.out_rate, Ordering::SeqCst);
    inner
        .published_format_stamp
        .store(snap.expected_stamp, Ordering::Release);
    if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
        *rg_lock = snap.rg_tags.clone();
    }
    inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
    if let Ok(mut spec_lock) = inner.active_source_spec.write() {
        *spec_lock = snap.origin.source_spec().cloned();
    }
    if let Ok(mut vw) = inner.verification.write() {
        *vw = Some((
            snap.verification.clone(),
            snap.api_label.clone(),
            snap.device_name.clone(),
        ));
    }
    if let Ok(mut meta_lock) = inner.active_meta.write() {
        *meta_lock = Some(ActiveTrackMeta {
            path: snap.path.clone(),
            source_label: snap.source_label.clone(),
            format: snap.format.clone(),
            duration_ms: snap.duration_ms,
            resampled_to_hz: snap.resampled_to_hz,
            backend: snap.backend,
            device_name: snap.device_name.clone(),
        });
    }
}

fn relay_loop(weak_inner: std::sync::Weak<PlayerInner>, cmd_tx: mpsc::Sender<PlayerCommand>) {
    loop {
        let Some(inner) = weak_inner.upgrade() else {
            break;
        };
        if inner.dual_deck.relay_stop.load(Ordering::Acquire) {
            break;
        }
        inner.dual_deck.drain_retired_payloads();

        if inner
            .cpal_stream_error_flag
            .swap(false, Ordering::AcqRel)
        {
            tracing::warn!("cpal output stream error signalled on audio callback (device lost)");
            if let Ok(mut code_guard) = inner.last_error_code.write()
                && code_guard.is_none()
            {
                *code_guard = Some("DEVICE_LOST".to_string());
            }
            if let Ok(mut guard) = inner.last_error.write()
                && guard.is_none()
            {
                *guard = Some(
                    "Audio output stream error (device lost or invalidated)".to_string(),
                );
            }
        }

        while let Some(evt) = inner.dual_deck.pop_rt_event() {
            let from_idx = (evt.from_deck & 1) as usize;
            let to_idx = (evt.to_deck & 1) as usize;
            match evt.kind {
                RtTransitionKind::GaplessFlip
                | RtTransitionKind::ManualSkipFlip
                | RtTransitionKind::MismatchCrossfadeFlip => {
                    if (inner.dual_deck.deck_gen_for(to_idx) & 0xFF_FFFF_FFFF)
                        == (evt.to_deck_gen & 0xFF_FFFF_FFFF)
                    {
                        if let Ok(mg) = inner.dual_deck.deck_meta[to_idx].read()
                            && let Some(ref snap) = *mg
                        {
                            commit_deck_metadata_to_inner(&inner, snap);
                        }
                        inner.dual_deck.set_deck_key(from_idx, None);
                        inner.dual_deck.promote_decode_thread(to_idx);
                    }
                    inner.dual_deck.notify_flip_done();
                    let _ = cmd_tx.send(PlayerCommand::RetireDeck {
                        deck_idx: from_idx,
                        deck_gen: evt.to_deck_gen,
                    });
                }
                RtTransitionKind::CrossRateDrain
                | RtTransitionKind::ManualSkipDrain
                | RtTransitionKind::MismatchDrain => {
                    let _ = cmd_tx.send(PlayerCommand::ReopenOntoStandby {
                        from_deck: from_idx,
                        to_deck: to_idx,
                        to_deck_gen: evt.to_deck_gen,
                        is_manual_skip: evt.kind == RtTransitionKind::ManualSkipDrain,
                        is_mismatch_recovery: evt.kind == RtTransitionKind::MismatchDrain,
                    });
                }
            }
        }

        if inner.has_queued_next_spec.load(Ordering::Acquire)
            && !inner.stopped.load(Ordering::Relaxed)
            && inner.state_code.load(Ordering::Relaxed) == PlaybackLifecycleState::Playing as i32
        {
            let sb = inner.dual_deck.standby_idx();
            if inner.dual_deck.deck_state(sb) == DeckState::Idle {
                let dur = inner.duration_ms.load(Ordering::Relaxed);
                let pos = position_ms_from_inner(&inner);
                let should_trigger = if dur > 0 {
                    dur.saturating_sub(pos) <= AUTO_PREDECODE_REMAINING_MS
                        || (pos.saturating_mul(100) / dur) >= 75
                } else {
                    true
                };
                if should_trigger {
                    let _ = cmd_tx.send(PlayerCommand::TriggerAutoStandby);
                }
            }
        }

        drop(inner);
        thread::park_timeout(Duration::from_millis(20));
    }
}

struct StandbyDeckGate {
    target_ms: u64,
    is_mismatch_recovery: bool,
    mismatch_pts_ms: u64,
    mismatch_frame: u64,
    out_rate: u32,
    pending_pcm: Option<RtPcmInboxPayload>,
    pending_wire: Option<RtWireInboxPayload>,
    wake: Arc<(Mutex<StandbyWakeState>, Condvar)>,
}

impl StandbyDeckGate {
    fn complete_prebuffer_and_park(
        &mut self,
        inner: &PlayerInner,
        deck_idx: usize,
        deck_gen: u64,
        cancel_flag: &AtomicBool,
        cancel_token: &CancellationToken,
        eof_flag: &AtomicBool,
        at_eof: bool,
    ) -> bool {
        if cancel_flag.load(Ordering::Relaxed)
            || cancel_token.is_cancelled()
            || inner.stopped.load(Ordering::Relaxed)
            || inner.dual_deck.deck_gen_for(deck_idx) != deck_gen
        {
            return false;
        }
        if at_eof {
            eof_flag.store(true, Ordering::SeqCst);
        }
        let compat = inner
            .dual_deck
            .active_profile
            .read()
            .ok()
            .and_then(|pg| {
                pg.as_ref().and_then(|prof| {
                    inner.dual_deck.deck_meta[deck_idx]
                        .read()
                        .ok()
                        .and_then(|mg| {
                            mg.as_ref()
                                .map(|snap| DualDeckControl::is_compatible_with_profile(snap, prof))
                        })
                })
            })
            .unwrap_or(false);
        inner.dual_deck.standby_compatible[deck_idx].store(compat, Ordering::SeqCst);

        if let Some(pcm_payload) = self.pending_pcm.take() {
            if compat {
                inner.dual_deck.send_pcm_inbox(deck_idx, pcm_payload);
            } else if let Ok(mut g) = inner.dual_deck.standby_pending_pcm[deck_idx].lock() {
                *g = Some(pcm_payload);
            }
        }
        if let Some(wire_payload) = self.pending_wire.take() {
            if compat {
                inner.dual_deck.send_wire_inbox(deck_idx, wire_payload);
            } else if let Ok(mut g) = inner.dual_deck.standby_pending_wire[deck_idx].lock() {
                *g = Some(wire_payload);
            }
        }

        inner.dual_deck.deck_states[deck_idx]
            .store(DeckState::StandbyReady as u8, Ordering::SeqCst);

        if self.is_mismatch_recovery {
            let out_rate_u128 = self.out_rate.max(8_000) as u128;
            let resume_frame = ((self.mismatch_pts_ms as u128) * out_rate_u128 / 1000) as u64;
            inner
                .dual_deck
                .mismatch_target_deck
                .store(deck_idx as u8, Ordering::SeqCst);
            inner
                .dual_deck
                .mismatch_align_frame
                .store(self.mismatch_frame, Ordering::SeqCst);
            inner
                .dual_deck
                .mismatch_resume_frame
                .store(resume_frame, Ordering::SeqCst);
            inner
                .dual_deck
                .mismatch_armed
                .store(true, Ordering::SeqCst);
        }

        let (lock, cvar) = &*self.wake;
        let mut wg = lock.lock().unwrap_or_else(|e| e.into_inner());
        while *wg == StandbyWakeState::Parked
            && !cancel_flag.load(Ordering::Relaxed)
            && !cancel_token.is_cancelled()
            && !inner.stopped.load(Ordering::Relaxed)
            && inner.dual_deck.deck_gen_for(deck_idx) == deck_gen
        {
            wg = cvar.wait(wg).unwrap_or_else(|e| e.into_inner());
        }
        *wg == StandbyWakeState::Promoted
            && !cancel_flag.load(Ordering::Relaxed)
            && !cancel_token.is_cancelled()
            && !inner.stopped.load(Ordering::Relaxed)
            && inner.dual_deck.deck_gen_for(deck_idx) == deck_gen
    }
}

#[allow(clippy::too_many_arguments)]
fn run_standby_deck_worker(
    inner: Arc<PlayerInner>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
    deck_idx: usize,
    deck_gen: u64,
    origin: PlayerOrigin,
    source_label: String,
    bypass_l2_read: bool,
    is_mismatch_recovery: bool,
    mismatch_pts_ms: u64,
    mismatch_frame: u64,
    cancel_flag: Arc<AtomicBool>,
    cancel_token: CancellationToken,
    wake: Arc<(Mutex<StandbyWakeState>, Condvar)>,
) -> Option<Box<dyn AudioDecoder>> {
    if cancel_flag.load(Ordering::Relaxed)
        || cancel_token.is_cancelled()
        || inner.dual_deck.deck_gen_for(deck_idx) != deck_gen
    {
        return None;
    }
    if matches!(
        origin,
        PlayerOrigin::SourceSpec(StreamSourceSpec::ExternalBackend { .. })
    ) {
        inner.dual_deck.deck_states[deck_idx].store(DeckState::Idle as u8, Ordering::SeqCst);
        inner.dual_deck.set_deck_key(deck_idx, None);
        return None;
    }

    let mut decoder = match origin.open_decoder_with_options(
        &inner,
        cancel_token.clone(),
        inner.stream_refresh_handler(),
        bypass_l2_read,
    ) {
        Ok(d) => d,
        Err(e) => {
            if !cancel_flag.load(Ordering::Relaxed)
                && !cancel_token.is_cancelled()
                && inner.dual_deck.deck_gen_for(deck_idx) == deck_gen
            {
                tracing::warn!("Standby deck {deck_idx} open failed: {e}");
                inner.dual_deck.deck_states[deck_idx]
                    .store(DeckState::Idle as u8, Ordering::SeqCst);
                inner.dual_deck.set_deck_key(deck_idx, None);
            }
            return None;
        }
    };

    if cancel_flag.load(Ordering::Relaxed)
        || cancel_token.is_cancelled()
        || inner.dual_deck.deck_gen_for(deck_idx) != deck_gen
    {
        return Some(decoder);
    }

    if is_mismatch_recovery && mismatch_pts_ms > 0 {
        inner.dual_deck.deck_states[deck_idx].store(DeckState::Seeking as u8, Ordering::SeqCst);
        if let Err(e) = decoder.seek(Duration::from_millis(mismatch_pts_ms)) {
            tracing::warn!("Standby mismatch recovery seek to {mismatch_pts_ms}ms failed: {e}");
        }
        if cancel_flag.load(Ordering::Relaxed)
            || cancel_token.is_cancelled()
            || inner.dual_deck.deck_gen_for(deck_idx) != deck_gen
        {
            return Some(decoder);
        }
    }

    inner.dual_deck.deck_states[deck_idx].store(DeckState::Prebuffering as u8, Ordering::SeqCst);
    let eof_flag = Arc::clone(&inner.dual_deck.deck_eof_flags[deck_idx]);
    eof_flag.store(false, Ordering::SeqCst);
    inner.dual_deck.deck_buffered_ms[deck_idx].store(0, Ordering::Relaxed);
    inner.dual_deck.standby_buffered_ms.store(0, Ordering::Relaxed);

    let path = origin.display_path();
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
    let unified_src = decoder.unified_format();
    let track_meta = decoder.metadata().cloned();
    let rg_tags = origin
        .replay_gain_tags()
        .with_metadata_fallback(decoder.metadata());

    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let caps = resolve_target_capabilities(&inner, sel_id.as_deref(), sel_backend);
    let policy = inner.policy.read().map(|g| g.clone()).unwrap_or_default();
    let dsp_bypassed = inner.dsp_bypassed.load(Ordering::SeqCst);
    let eff_vol = if policy.strict_bit_perfect {
        1.0
    } else {
        f32::from_bits(inner.volume_bits.load(Ordering::Relaxed))
    };

    let explicit_shared = sel_backend == Some(OutputBackendKind::WindowsWasapiShared)
        || sel_id
            .as_deref()
            .is_some_and(|s| s.starts_with("wasapi-shared::"));
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
    let predecode_target_ms = if is_mismatch_recovery {
        2_000
    } else {
        STANDBY_PREDECODE_MS
    };
    let session_id = inner.current_session_id.load(Ordering::Acquire);
    let fade_ctrl = inner
        .active_fade
        .read()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| Arc::new(AudioFadeControl::new(true, true, false)));

    if want_native_wire
        && let Ok(ref negotiated) = negotiated_res
        && negotiated.output_mode.is_exclusive_or_asio()
    {
        let allow_virtual_wire = caps.transport == DeviceTransportKind::Virtual
            && (policy.strict_bit_perfect
                || dsp_bypassed
                || sel_backend == Some(OutputBackendKind::WindowsWasapiExclusive)
                || sel_backend == Some(OutputBackendKind::WindowsAsio)
                || matches!(
                    negotiated.output_mode,
                    OutputMode::DoPOverWasapiExclusive | OutputMode::AsioNativeDsd
                ));
        if caps.transport != DeviceTransportKind::Virtual || allow_virtual_wire {
            let wire = negotiated.wire_format;
            let is_dsd_wire = matches!(
                wire,
                WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
            );
            let initial_wire_dsp_active = !policy.strict_bit_perfect
                && !dsp_bypassed
                && !is_dsd_wire
                && is_any_dsp_active(&inner);
            let ver_cfg = VerificationConfig {
                source_format: unified_src.clone(),
                output_mode: negotiated.output_mode,
                transport: caps.transport,
                target_rate_hz: negotiated.target_sample_rate,
                target_channels: negotiated.target_channels,
                target_valid_bits: negotiated.valid_bits,
                target_container_bits: negotiated.container_bits,
                buffer_size_frames: policy.preferred_buffer_frames,
                dsp_active: initial_wire_dsp_active,
                software_volume_unity: true,
                resampled: negotiated.requires_resampling,
                exclusive_unavailable_reason: None,
            };
            let verification = AudioVerificationEngine::new(ver_cfg.clone());
            if let Some(ref m) = track_meta {
                verification.set_source_metadata(
                    m.title.clone(),
                    m.artist.clone(),
                    m.album.clone(),
                );
            }
            let expected_stamp = WireFormatStamp::from_wire(
                negotiated.target_sample_rate,
                negotiated.target_channels,
                wire,
            )
            .0;
            let ring_bytes = compute_wire_ring_bytes(
                negotiated.target_sample_rate,
                negotiated.target_channels,
                wire,
            );
            let (byte_prod, byte_cons) = SpscRingBuffer::<u8>::new(ring_bytes);
            let watermark_bytes = compute_startup_watermark_bytes(
                negotiated.target_sample_rate,
                negotiated.target_channels,
                wire,
                byte_prod.capacity(),
            );
            let ver_tap = verification.attach_rt_tap(
                wire,
                negotiated.target_channels,
                negotiated.target_sample_rate,
                1024 * 1024,
            );
            let (bk, api_label, dev_name) = if allow_virtual_wire {
                (
                    sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
                    "Virtual Wire Engine".to_string(),
                    VIRTUAL_DEVICE_NAME.to_string(),
                )
            } else if matches!(
                negotiated.output_mode,
                OutputMode::AsioPcm | OutputMode::AsioNativeDsd | OutputMode::DoPOverAsio
            ) {
                (
                    OutputBackendKind::WindowsAsio,
                    "ASIO 2.x COM Driver".to_string(),
                    caps.name.clone(),
                )
            } else {
                (
                    OutputBackendKind::WindowsWasapiExclusive,
                    "WASAPI Exclusive (Event-Driven)".to_string(),
                    caps.name.clone(),
                )
            };
            let snap = DeckMetadataSnapshot {
                path: path.clone(),
                source_label: source_label.clone(),
                origin,
                format,
                unified_format: unified_src.clone(),
                negotiated: negotiated.clone(),
                duration_ms,
                pcm_rate: negotiated.target_sample_rate,
                out_rate: negotiated.target_sample_rate,
                out_channels: negotiated.target_channels,
                rg_tags,
                verification: verification.clone(),
                api_label,
                device_name: dev_name,
                backend: bk,
                active_device_id: caps.device_id.clone(),
                expected_stamp,
                is_wire: true,
                resampled_to_hz: None,
            };
            if let Ok(mut mg) = inner.dual_deck.deck_meta[deck_idx].write() {
                *mg = Some(snap);
            }
            let last_ring_epoch = byte_cons.epoch();
            let wire_payload = RtWireInboxPayload {
                consumer: byte_cons,
                ver_tap,
                watermark_bytes,
                wire,
                out_rate: negotiated.target_sample_rate,
                out_channels: negotiated.target_channels,
                expected_stamp,
                deck_gen,
                last_ring_epoch,
            };
            let gate = StandbyDeckGate {
                target_ms: predecode_target_ms,
                is_mismatch_recovery,
                mismatch_pts_ms,
                mismatch_frame,
                out_rate: negotiated.target_sample_rate,
                pending_pcm: None,
                pending_wire: Some(wire_payload),
                wake,
            };
            return decode_wire_loop(
                decoder,
                byte_prod,
                unified_src,
                negotiated.clone(),
                caps,
                verification,
                ver_cfg,
                inner,
                cancel_flag,
                cancel_token,
                eof_flag,
                fade_ctrl,
                watermark_bytes,
                expected_stamp,
                session_id,
                cmd_tx,
                path,
                source_label,
                deck_idx,
                deck_gen,
                Some(gate),
            );
        }
    }

    let use_virtual = inner.headless
        || (sel_id.as_deref() == Some(VIRTUAL_DEVICE_ID) && enumerate_cpal_devices().is_empty());
    let active_prof = inner
        .dual_deck
        .active_profile
        .read()
        .ok()
        .and_then(|g| g.clone());
    let (out_rate, out_channels, out_sample_format) = if !use_virtual {
        if let Some(ref prof) = active_prof
            && !prof.is_wire
        {
            (prof.out_rate, prof.out_channels, None)
        } else if let Ok((dev, _, _)) = resolve_cpal_device(sel_id.as_deref(), sel_backend)
            && let Ok(cfg) = select_output_config(&dev, pcm_rate, default_out_channels)
        {
            (cfg.sample_rate(), cfg.channels(), Some(cfg.sample_format()))
        } else {
            (pcm_rate, default_out_channels, None)
        }
    } else {
        (pcm_rate, default_out_channels, Some(SampleFormat::F32))
    };
    let mode_b = if unified_src.dsd_rate.is_some() {
        OutputMode::DsdToPcm
    } else if use_virtual {
        OutputMode::VirtualMock
    } else {
        OutputMode::WasapiShared
    };
    let degrad_b = if unified_src.dsd_rate.is_some() {
        Some("DSD-to-PCM 轉換輸出".to_string())
    } else if mode_b == OutputMode::WasapiShared {
        Some("Windows Shared Mode (經過系統混音器)".to_string())
    } else {
        None
    };
    let shared_verification = AudioVerificationEngine::new(VerificationConfig {
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
    if let Some(ref m) = track_meta {
        shared_verification.set_source_metadata(m.title.clone(), m.artist.clone(), m.album.clone());
    }
    let ring_samples = compute_pcm_ring_samples(out_rate, out_channels);
    let (pcm_prod, pcm_cons) = SpscRingBuffer::<f32>::new(ring_samples);
    let watermark_samples =
        compute_startup_watermark_samples(out_rate, out_channels, pcm_prod.capacity());
    let ver_tap = shared_verification.attach_rt_tap(
        WireSampleFormat::Float32Le,
        out_channels,
        out_rate,
        1024 * 1024,
    );
    let (backend_kind, device_name, api_label_b) = if use_virtual {
        (
            OutputBackendKind::WindowsWasapiExclusive,
            VIRTUAL_DEVICE_NAME.to_string(),
            "Virtual Consumer".to_string(),
        )
    } else {
        let (bk, dn) = inner
            .active_meta
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|m| (m.backend, m.device_name.clone())))
            .unwrap_or((OutputBackendKind::WindowsWasapiShared, caps.name.clone()));
        (bk, dn, format!("{bk:?}"))
    };
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
    let snap = DeckMetadataSnapshot {
        path,
        source_label,
        origin,
        format,
        unified_format: unified_src.clone(),
        negotiated: fallback_neg.clone(),
        duration_ms,
        pcm_rate,
        out_rate,
        out_channels,
        rg_tags,
        verification: shared_verification.clone(),
        api_label: api_label_b,
        device_name,
        backend: backend_kind,
        active_device_id: caps.device_id.clone(),
        expected_stamp: 0,
        is_wire: false,
        resampled_to_hz: if pcm_rate != out_rate {
            Some(out_rate)
        } else {
            None
        },
    };
    if let Ok(mut mg) = inner.dual_deck.deck_meta[deck_idx].write() {
        *mg = Some(snap);
    }
    let last_ring_epoch = pcm_cons.epoch();
    let pcm_payload = RtPcmInboxPayload {
        consumer: pcm_cons,
        ver_tap: Some(ver_tap),
        watermark_samples,
        out_rate,
        out_channels,
        deck_gen,
        last_ring_epoch,
    };
    let gate = StandbyDeckGate {
        target_ms: predecode_target_ms,
        is_mismatch_recovery,
        mismatch_pts_ms,
        mismatch_frame,
        out_rate,
        pending_pcm: Some(pcm_payload),
        pending_wire: None,
        wake,
    };
    decode_loop(
        decoder,
        pcm_prod,
        pcm_rate,
        out_rate,
        out_channels,
        out_sample_format,
        inner,
        Some(shared_verification),
        unified_src,
        fallback_neg,
        caps,
        cancel_flag,
        cancel_token,
        eof_flag,
        fade_ctrl,
        watermark_samples,
        session_id,
        cmd_tx,
        deck_idx,
        deck_gen,
        Some(gate),
    )
}

fn start_output_pipeline_from_standby(
    inner: &Arc<PlayerInner>,
    to_deck: usize,
    session_id: u64,
    start_paused: bool,
) -> Result<ActiveSession, CoreAudioError> {
    let snap = inner.dual_deck.deck_meta[to_deck]
        .read()
        .ok()
        .and_then(|g| g.clone())
        .ok_or_else(|| {
            CoreAudioError::Backend(BackendError::InvalidState(
                "Standby deck metadata missing on reopen".into(),
            ))
        })?;
    let (cancel_flag, cancel_token) = inner.dual_deck.decode_entries[to_deck]
        .lock()
        .ok()
        .and_then(|g| {
            g.as_ref()
                .map(|e| (Arc::clone(&e.cancel_flag), e.cancel_token.clone()))
        })
        .unwrap_or_else(|| (Arc::new(AtomicBool::new(false)), CancellationToken::new()));
    let output_kill_flag = Arc::new(AtomicBool::new(false));
    let eof_flag = Arc::clone(&inner.dual_deck.deck_eof_flags[to_deck]);

    let policy = inner.policy.read().map(|g| g.clone()).unwrap_or_default();
    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let caps = resolve_target_capabilities(inner, sel_id.as_deref(), sel_backend);
    let dsp_bypassed = inner.dsp_bypassed.load(Ordering::SeqCst);

    if snap.is_wire {
        let payload = inner
            .dual_deck
            .take_standby_wire_payload(to_deck)
            .ok_or_else(|| {
                CoreAudioError::Backend(BackendError::InvalidState(
                    "Standby wire ring buffer missing on reopen".into(),
                ))
            })?;
        let wire = payload.wire;
        let is_dsd_wire = matches!(
            wire,
            WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
        );
        let fade_in_enabled = !is_dsd_wire && !policy.strict_bit_perfect;
        let fade_out_enabled = !is_dsd_wire;
        let fade_ctrl = Arc::new(AudioFadeControl::new(
            fade_in_enabled,
            fade_out_enabled,
            start_paused,
        ));
        let watermark_bytes = payload.watermark_bytes;
        let expected_stamp = payload.expected_stamp;
        inner
            .published_format_stamp
            .store(expected_stamp, Ordering::Release);
        inner.format_mismatch_flag.store(false, Ordering::Release);
        inner.device_lost.store(false, Ordering::SeqCst);

        let allow_virtual_wire = caps.transport == DeviceTransportKind::Virtual
            && (policy.strict_bit_perfect
                || dsp_bypassed
                || sel_backend == Some(OutputBackendKind::WindowsWasapiExclusive)
                || sel_backend == Some(OutputBackendKind::WindowsAsio)
                || matches!(
                    snap.negotiated.output_mode,
                    OutputMode::DoPOverWasapiExclusive | OutputMode::AsioNativeDsd
                ));

        let (native_sess, actual_frames, dev_name, bk, api_label) = if allow_virtual_wire {
            let feeder = DualDeckWireFeeder::new(
                Arc::clone(&inner.dual_deck),
                Arc::clone(&inner.frames_rendered),
                Arc::clone(&inner.nonzero_output_frames),
                Arc::clone(&inner.buffered_ms),
                Arc::clone(&inner.gapless_transitions),
                Arc::clone(&inner.ring_buffer_underrun_count),
                to_deck,
                payload,
            );
            let h = spawn_virtual_wire_consumer(
                feeder,
                wire,
                snap.out_rate,
                snap.out_channels,
                Arc::clone(inner),
                Arc::clone(&output_kill_flag),
                session_id,
                watermark_bytes,
                Arc::clone(&fade_ctrl),
                expected_stamp,
            );
            (
                NativeOutputSession::VirtualWire(h),
                policy.preferred_buffer_frames,
                VIRTUAL_DEVICE_NAME.to_string(),
                sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
                "Virtual Wire Engine",
            )
        } else {
            #[cfg(target_os = "windows")]
            {
                let RtWireInboxPayload {
                    consumer: byte_cons,
                    ..
                } = payload;
                let res = if matches!(
                    snap.negotiated.output_mode,
                    OutputMode::AsioPcm | OutputMode::AsioNativeDsd | OutputMode::DoPOverAsio
                ) {
                    let is_native_dsd = snap.negotiated.output_mode == OutputMode::AsioNativeDsd;
                    crate::backend::asio_win::AsioNativeSession::open_and_start_with_telemetry(
                        Some(&caps.device_id),
                        snap.out_rate,
                        snap.out_channels,
                        wire,
                        is_native_dsd,
                        byte_cons,
                        snap.verification.clone(),
                        Arc::clone(&inner.frames_rendered),
                        Arc::clone(&inner.nonzero_output_frames),
                        Arc::clone(&inner.state_code),
                        Arc::clone(&eof_flag),
                        session_id,
                        Arc::clone(&inner.current_session_id),
                        watermark_bytes,
                        Some(Arc::clone(&fade_ctrl)),
                        Some(Arc::clone(&inner.buffered_ms)),
                        Arc::clone(&inner.ring_buffer_underrun_count),
                        Arc::clone(&inner.device_lost),
                        Arc::clone(&inner.last_error),
                        Arc::clone(&inner.format_mismatch_flag),
                        Arc::clone(&inner.published_format_stamp),
                        expected_stamp,
                        None,
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
                        sample_rate: snap.out_rate,
                        channels: snap.out_channels,
                        layout: ChannelLayout::from_channels(snap.out_channels),
                        wire_format: wire,
                        is_dop: snap.negotiated.output_mode == OutputMode::DoPOverWasapiExclusive,
                        buffer_frames_hint: policy.preferred_buffer_frames,
                    };
                    crate::backend::wasapi_win::WasapiExclusiveSession::open_and_start_with_telemetry(
                        open_spec,
                        byte_cons,
                        snap.verification.clone(),
                        Arc::clone(&inner.frames_rendered),
                        Arc::clone(&inner.nonzero_output_frames),
                        Arc::clone(&inner.state_code),
                        Arc::clone(&eof_flag),
                        Arc::clone(&inner.last_error),
                        session_id,
                        Arc::clone(&inner.current_session_id),
                        watermark_bytes,
                        Some(Arc::clone(&fade_ctrl)),
                        Some(Arc::clone(&inner.buffered_ms)),
                        Arc::clone(&inner.ring_buffer_underrun_count),
                        Arc::clone(&inner.device_lost),
                        Arc::clone(&inner.format_mismatch_flag),
                        Arc::clone(&inner.published_format_stamp),
                        expected_stamp,
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
                };
                res.map_err(CoreAudioError::Backend)?
            }
            #[cfg(not(target_os = "windows"))]
            {
                return Err(CoreAudioError::Backend(BackendError::DeviceNotFound(
                    "Native Windows WASAPI/ASIO unavailable on this OS".into(),
                )));
            }
        };

        native_sess.set_eof_state_code(PlaybackLifecycleState::Ended as i32);
        snap.verification.set_buffer_size_frames(actual_frames);
        if let Ok(mut af) = inner.active_fade.write() {
            *af = Some(Arc::clone(&fade_ctrl));
        }
        let mut updated_snap = snap;
        updated_snap.device_name = dev_name;
        updated_snap.backend = bk;
        updated_snap.api_label = api_label.to_string();
        commit_deck_metadata_to_inner(inner, &updated_snap);
        if let Ok(mut mg) = inner.dual_deck.deck_meta[to_deck].write() {
            *mg = Some(updated_snap.clone());
        }
        inner
            .dual_deck
            .rebind_standby_for_new_profile(ActiveOutputProfile {
                session_id,
                is_wire: true,
                uses_dual_feeder: allow_virtual_wire,
                output_mode: updated_snap.negotiated.output_mode,
                wire_format: wire,
                out_rate: updated_snap.out_rate,
                out_channels: updated_snap.out_channels,
            });
        inner.dual_deck.promote_decode_thread(to_deck);

        return Ok(ActiveSession {
            dual_deck: Arc::clone(&inner.dual_deck),
            cancel_flag,
            output_kill_flag,
            fade_ctrl,
            cancel_token,
            eof_flag,
            decode_handle: None,
            virtual_handle: None,
            _cpal_stream: None,
            native_output: Some(native_sess),
            path: updated_snap.path,
            source_label: updated_snap.source_label,
            origin: updated_snap.origin,
            format: updated_snap.format,
            duration_ms: updated_snap.duration_ms,
            pcm_rate: updated_snap.pcm_rate,
            active_device_id: updated_snap.active_device_id,
        });
    }

    let payload = inner
        .dual_deck
        .take_standby_pcm_payload(to_deck)
        .ok_or_else(|| {
            CoreAudioError::Backend(BackendError::InvalidState(
                "Standby PCM ring buffer missing on reopen".into(),
            ))
        })?;
    let fade_ctrl = Arc::new(AudioFadeControl::new(true, true, start_paused));
    let use_virtual = inner.headless
        || (sel_id.as_deref() == Some(VIRTUAL_DEVICE_ID) && enumerate_cpal_devices().is_empty());

    let (
        virtual_handle,
        cpal_stream,
        out_rate,
        out_channels,
        out_sample_format,
        backend_kind,
        device_name,
    ) = if use_virtual {
        let out_rate = payload.out_rate;
        let out_channels = payload.out_channels;
        let feeder = DualDeckPcmFeeder::new(
            Arc::clone(&inner.dual_deck),
            Arc::clone(inner),
            session_id,
            to_deck,
            payload,
            &fade_ctrl,
        );
        let vh = spawn_virtual_consumer(
            feeder,
            out_rate,
            out_channels,
            Arc::clone(inner),
            Arc::clone(&output_kill_flag),
            session_id,
            Arc::clone(&fade_ctrl),
        );
        (
            Some(vh),
            None,
            out_rate,
            out_channels,
            SampleFormat::F32,
            OutputBackendKind::WindowsWasapiExclusive,
            VIRTUAL_DEVICE_NAME.to_string(),
        )
    } else {
        let (stream, actual_rate, actual_ch, sample_fmt, bk, dev_name) =
            open_cpal_output_with_payload(
                to_deck,
                payload,
                inner,
                &output_kill_flag,
                session_id,
                &fade_ctrl,
            )?;
        if !start_paused && let Err(e) = stream.play() {
            output_kill_flag.store(true, Ordering::SeqCst);
            let _ = stream.pause();
            return Err(CoreAudioError::Backend(BackendError::DriverError(format!(
                "Failed to start cpal output stream on standby reopen: {e}"
            ))));
        }
        (
            None,
            Some(stream),
            actual_rate,
            actual_ch,
            sample_fmt,
            bk,
            dev_name,
        )
    };

    if is_opus_dump_enabled() && snap.unified_format.codec == AudioCodec::Opus {
        tracing::info!(
            sample_rate = out_rate,
            channels = out_channels,
            sample_format = ?out_sample_format,
            backend = ?backend_kind,
            device = %device_name,
            "[LuminaOpusDiag] Standby promoted to CPAL Opus output"
        );
    }

    if let Ok(mut af) = inner.active_fade.write() {
        *af = Some(Arc::clone(&fade_ctrl));
    }
    let mut updated_snap = snap;
    updated_snap.out_rate = out_rate;
    updated_snap.out_channels = out_channels;
    updated_snap.backend = backend_kind;
    updated_snap.device_name = device_name;
    commit_deck_metadata_to_inner(inner, &updated_snap);
    if let Ok(mut mg) = inner.dual_deck.deck_meta[to_deck].write() {
        *mg = Some(updated_snap.clone());
    }
    inner
        .dual_deck
        .rebind_standby_for_new_profile(ActiveOutputProfile {
            session_id,
            is_wire: false,
            uses_dual_feeder: true,
            output_mode: updated_snap.negotiated.output_mode,
            wire_format: WireSampleFormat::Float32Le,
            out_rate,
            out_channels,
        });
    inner.dual_deck.promote_decode_thread(to_deck);

    Ok(ActiveSession {
        dual_deck: Arc::clone(&inner.dual_deck),
        cancel_flag,
        output_kill_flag,
        fade_ctrl,
        cancel_token,
        eof_flag,
        decode_handle: None,
        virtual_handle,
        _cpal_stream: cpal_stream,
        native_output: None,
        path: updated_snap.path,
        source_label: updated_snap.source_label,
        origin: updated_snap.origin,
        format: updated_snap.format,
        duration_ms: updated_snap.duration_ms,
        pcm_rate: updated_snap.pcm_rate,
        active_device_id: updated_snap.active_device_id,
    })
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
        origin,
        cancel_token,
        format,
        duration_ms,
        start_paused,
    } = spec;
    crate::visualizer::global_tap().ensure_worker_started();
    let active_idx = inner.dual_deck.active_idx();
    let active_gen = inner.dual_deck.alloc_deck_gen(active_idx);
    inner.dual_deck.deck_states[active_idx].store(DeckState::Playing as u8, Ordering::SeqCst);
    inner.dual_deck.set_deck_key(active_idx, origin.stream_key());
    let cancel_flag = Arc::new(AtomicBool::new(false));
    let output_kill_flag = Arc::new(AtomicBool::new(false));
    let eof_flag = Arc::clone(&inner.dual_deck.deck_eof_flags[active_idx]);
    eof_flag.store(false, Ordering::SeqCst);
    inner.dual_deck.deck_buffered_ms[active_idx].store(0, Ordering::Relaxed);
    inner.dual_deck.clear_inboxes_for_deck(active_idx);
    inner.buffered_ms.store(0, Ordering::Relaxed);

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
        // Note: on headless virtual target, native wire runs if Strict Mode is armed, DSP is
        // bypassed, or an exclusive/ASIO backend was explicitly selected.
        let allow_virtual_wire = caps.transport == DeviceTransportKind::Virtual
            && (policy.strict_bit_perfect
                || dsp_bypassed
                || sel_backend == Some(OutputBackendKind::WindowsWasapiExclusive)
                || sel_backend == Some(OutputBackendKind::WindowsAsio)
                || matches!(
                    negotiated.output_mode,
                    OutputMode::DoPOverWasapiExclusive | OutputMode::AsioNativeDsd
                ));

        if caps.transport != DeviceTransportKind::Virtual || allow_virtual_wire {
            let wire = negotiated.wire_format;
            let is_dsd_wire = matches!(
                wire,
                WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
            );
            let initial_wire_dsp_active =
                !policy.strict_bit_perfect && !dsp_bypassed && !is_dsd_wire && is_any_dsp_active(inner);
            let ver_cfg = VerificationConfig {
                source_format: unified_src.clone(),
                output_mode: negotiated.output_mode,
                transport: caps.transport,
                target_rate_hz: negotiated.target_sample_rate,
                target_channels: negotiated.target_channels,
                target_valid_bits: negotiated.valid_bits,
                target_container_bits: negotiated.container_bits,
                buffer_size_frames: policy.preferred_buffer_frames,
                dsp_active: initial_wire_dsp_active,
                software_volume_unity: true,
                resampled: negotiated.requires_resampling,
                exclusive_unavailable_reason: None,
            };
            let verification = AudioVerificationEngine::new(ver_cfg.clone());
            if let Some(ref m) = track_meta {
                verification.set_source_metadata(
                    m.title.clone(),
                    m.artist.clone(),
                    m.album.clone(),
                );
            }

            let expected_stamp = WireFormatStamp::from_wire(
                negotiated.target_sample_rate,
                negotiated.target_channels,
                wire,
            )
            .0;
            inner
                .published_format_stamp
                .store(expected_stamp, Ordering::Release);
            inner.format_mismatch_flag.store(false, Ordering::Release);
            inner.device_lost.store(false, Ordering::SeqCst);

            let ring_bytes = compute_wire_ring_bytes(
                negotiated.target_sample_rate,
                negotiated.target_channels,
                wire,
            );
            let (byte_prod, byte_cons) = SpscRingBuffer::<u8>::new(ring_bytes);
            let watermark_bytes = compute_startup_watermark_bytes(
                negotiated.target_sample_rate,
                negotiated.target_channels,
                wire,
                byte_prod.capacity(),
            );
            let fade_in_enabled = !is_dsd_wire && !policy.strict_bit_perfect;
            let fade_out_enabled = !is_dsd_wire;
            let fade_ctrl = Arc::new(AudioFadeControl::new(
                fade_in_enabled,
                fade_out_enabled,
                start_paused,
            ));

            let native_attempt: Result<(NativeOutputSession, u32, String, OutputBackendKind, &'static str), BackendError> =
                if allow_virtual_wire {
                    let ver_tap = verification.attach_rt_tap(
                        wire,
                        negotiated.target_channels,
                        negotiated.target_sample_rate,
                        1024 * 1024,
                    );
                    let last_ring_epoch = byte_cons.epoch();
                    let wire_payload = RtWireInboxPayload {
                        consumer: byte_cons,
                        ver_tap,
                        watermark_bytes,
                        wire,
                        out_rate: negotiated.target_sample_rate,
                        out_channels: negotiated.target_channels,
                        expected_stamp,
                        deck_gen: active_gen,
                        last_ring_epoch,
                    };
                    let feeder = DualDeckWireFeeder::new(
                        Arc::clone(&inner.dual_deck),
                        Arc::clone(&inner.frames_rendered),
                        Arc::clone(&inner.nonzero_output_frames),
                        Arc::clone(&inner.buffered_ms),
                        Arc::clone(&inner.gapless_transitions),
                        Arc::clone(&inner.ring_buffer_underrun_count),
                        active_idx,
                        wire_payload,
                    );
                    let h = spawn_virtual_wire_consumer(
                        feeder,
                        wire,
                        negotiated.target_sample_rate,
                        negotiated.target_channels,
                        Arc::clone(inner),
                        Arc::clone(&output_kill_flag),
                        session_id,
                        watermark_bytes,
                        Arc::clone(&fade_ctrl),
                        expected_stamp,
                    );
                    Ok((
                        NativeOutputSession::VirtualWire(h),
                        policy.preferred_buffer_frames,
                        VIRTUAL_DEVICE_NAME.to_string(),
                        sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
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
                            crate::backend::asio_win::AsioNativeSession::open_and_start_with_telemetry(
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
                                watermark_bytes,
                                Some(Arc::clone(&fade_ctrl)),
                                Some(Arc::clone(&inner.buffered_ms)),
                                Arc::clone(&inner.ring_buffer_underrun_count),
                                Arc::clone(&inner.device_lost),
                                Arc::clone(&inner.last_error),
                                Arc::clone(&inner.format_mismatch_flag),
                                Arc::clone(&inner.published_format_stamp),
                                expected_stamp,
                                None,
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
                            crate::backend::wasapi_win::WasapiExclusiveSession::open_and_start_with_telemetry(
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
                                watermark_bytes,
                                Some(Arc::clone(&fade_ctrl)),
                                Some(Arc::clone(&inner.buffered_ms)),
                                Arc::clone(&inner.ring_buffer_underrun_count),
                                Arc::clone(&inner.device_lost),
                                Arc::clone(&inner.format_mismatch_flag),
                                Arc::clone(&inner.published_format_stamp),
                                expected_stamp,
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
                    let mut dec_ver_cfg = ver_cfg;
                    dec_ver_cfg.buffer_size_frames = actual_frames;
                    // Native DSD clocks at 1-bit frequency; track frame clock cleanly for position_ms()
                    let rate_for_pos = if matches!(wire, WireSampleFormat::NativeDsd { .. }) {
                        negotiated.target_sample_rate
                    } else {
                        negotiated.target_sample_rate
                    };
                    inner.out_sample_rate.store(rate_for_pos, Ordering::SeqCst);
                    if is_opus_dump_enabled() && unified_src.codec == AudioCodec::Opus {
                        tracing::info!(
                            sample_rate = negotiated.target_sample_rate,
                            channels = negotiated.target_channels,
                            sample_format = ?wire,
                            backend = ?bk,
                            device = %dev_name,
                            "[LuminaOpusDiag] Opus wire output opened"
                        );
                    }

                    if let Ok(mut af) = inner.active_fade.write() {
                        *af = Some(Arc::clone(&fade_ctrl));
                    }
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
                            device_name: dev_name.clone(),
                        });
                    }
                    let rg_tags = inner
                        .track_replay_gain
                        .read()
                        .map(|g| g.clone())
                        .unwrap_or_default();
                    if let Ok(mut mg) = inner.dual_deck.deck_meta[active_idx].write() {
                        *mg = Some(DeckMetadataSnapshot {
                            path: path.clone(),
                            source_label: source_label.clone(),
                            origin: origin.clone(),
                            format: format.clone(),
                            unified_format: unified_src.clone(),
                            negotiated: negotiated.clone(),
                            duration_ms,
                            pcm_rate: rate_for_pos,
                            out_rate: negotiated.target_sample_rate,
                            out_channels: negotiated.target_channels,
                            rg_tags,
                            verification: verification.clone(),
                            api_label: api_label.to_string(),
                            device_name: dev_name,
                            backend: bk,
                            active_device_id: caps.device_id.clone(),
                            expected_stamp,
                            is_wire: true,
                            resampled_to_hz: None,
                        });
                    }
                    inner
                        .dual_deck
                        .rebind_standby_for_new_profile(ActiveOutputProfile {
                            session_id,
                            is_wire: true,
                            uses_dual_feeder: allow_virtual_wire,
                            output_mode: negotiated.output_mode,
                            wire_format: wire,
                            out_rate: negotiated.target_sample_rate,
                            out_channels: negotiated.target_channels,
                        });

                    let dec_inner = Arc::clone(inner);
                    let dec_cancel = Arc::clone(&cancel_flag);
                    let dec_cancel_token = cancel_token.clone();
                    let dec_eof = Arc::clone(&eof_flag);
                    let dec_fade = Arc::clone(&fade_ctrl);
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
                                dec_ver_cfg,
                                dec_inner,
                                dec_cancel,
                                dec_cancel_token,
                                dec_eof,
                                dec_fade,
                                watermark_bytes,
                                expected_stamp,
                                session_id,
                                dec_tx,
                                dec_path,
                                dec_label,
                                active_idx,
                                active_gen,
                                None,
                            )
                        })
                        .ok();
                    if let Ok(mut eg) = inner.dual_deck.decode_entries[active_idx].lock() {
                        *eg = Some(DeckDecodeHandle {
                            deck_gen: active_gen,
                            cancel_flag: Arc::clone(&cancel_flag),
                            cancel_token: cancel_token.clone(),
                            wake: Arc::new((
                                Mutex::new(StandbyWakeState::Promoted),
                                Condvar::new(),
                            )),
                            join_handle: decode_handle,
                        });
                    }

                    return Ok(ActiveSession {
                        dual_deck: Arc::clone(&inner.dual_deck),
                        cancel_flag,
                        output_kill_flag,
                        fade_ctrl,
                        cancel_token,
                        eof_flag,
                        decode_handle: None,
                        virtual_handle: None,
                        _cpal_stream: None,
                        native_output: Some(native_sess),
                        path,
                        source_label,
                        origin,
                        format,
                        duration_ms,
                        pcm_rate: rate_for_pos,
                        active_device_id: caps.device_id,
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

    let fade_ctrl = Arc::new(AudioFadeControl::new(true, true, start_paused));

    let (
        producer,
        virtual_handle,
        cpal_stream,
        out_rate,
        out_channels,
        out_sample_format,
        backend_kind,
        device_name,
        watermark_samples,
    ) = if use_virtual {
        let ring_samples = compute_pcm_ring_samples(pcm_rate, default_out_channels);
        let (prod, cons) = SpscRingBuffer::<f32>::new(ring_samples);
        let wm_samples =
            compute_startup_watermark_samples(pcm_rate, default_out_channels, prod.capacity());
        let ver_tap = shared_verification.attach_rt_tap(
            WireSampleFormat::Float32Le,
            default_out_channels,
            pcm_rate,
            1024 * 1024,
        );
        let last_ring_epoch = cons.epoch();
        let pcm_payload = RtPcmInboxPayload {
            consumer: cons,
            ver_tap: Some(ver_tap),
            watermark_samples: wm_samples,
            out_rate: pcm_rate,
            out_channels: default_out_channels,
            deck_gen: active_gen,
            last_ring_epoch,
        };
        let feeder = DualDeckPcmFeeder::new(
            Arc::clone(&inner.dual_deck),
            Arc::clone(inner),
            session_id,
            active_idx,
            pcm_payload,
            &fade_ctrl,
        );
        let vh = spawn_virtual_consumer(
            feeder,
            pcm_rate,
            default_out_channels,
            Arc::clone(inner),
            Arc::clone(&output_kill_flag),
            session_id,
            Arc::clone(&fade_ctrl),
        );
        (
            prod,
            Some(vh),
            None,
            pcm_rate,
            default_out_channels,
            SampleFormat::F32,
            OutputBackendKind::WindowsWasapiExclusive,
            VIRTUAL_DEVICE_NAME.to_string(),
            wm_samples,
        )
    } else {
        let (stream, prod, actual_rate, actual_ch, sample_fmt, bk, dev_name, wm_samples) =
            open_cpal_output(
                pcm_rate,
                default_out_channels,
                inner,
                Some(&shared_verification),
                &output_kill_flag,
                active_idx,
                active_gen,
                session_id,
                &fade_ctrl,
            )?;
        (
            prod,
            None,
            Some(stream),
            actual_rate,
            actual_ch,
            sample_fmt,
            bk,
            dev_name,
            wm_samples,
        )
    };

    inner.out_sample_rate.store(out_rate, Ordering::SeqCst);
    if is_opus_dump_enabled() && unified_src.codec == AudioCodec::Opus {
        tracing::info!(
            sample_rate = out_rate,
            channels = out_channels,
            sample_format = ?out_sample_format,
            backend = ?backend_kind,
            device = %device_name,
            "[LuminaOpusDiag] Opus CPAL output opened"
        );
    }
    if let Ok(mut af) = inner.active_fade.write() {
        *af = Some(Arc::clone(&fade_ctrl));
    }
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
        *vw = Some((
            shared_verification.clone(),
            api_label_b.clone(),
            device_name.clone(),
        ));
    }

    if let Ok(mut meta_lock) = inner.active_meta.write() {
        *meta_lock = Some(ActiveTrackMeta {
            path: path.clone(),
            source_label: source_label.clone(),
            format: format.clone(),
            duration_ms,
            resampled_to_hz,
            backend: backend_kind,
            device_name: device_name.clone(),
        });
    }

    let decode_inner = Arc::clone(inner);
    let decode_cancel = Arc::clone(&cancel_flag);
    let decode_cancel_token = cancel_token.clone();
    let decode_eof = Arc::clone(&eof_flag);
    let decode_fade = Arc::clone(&fade_ctrl);
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
    let rg_tags = inner
        .track_replay_gain
        .read()
        .map(|g| g.clone())
        .unwrap_or_default();
    if let Ok(mut mg) = inner.dual_deck.deck_meta[active_idx].write() {
        *mg = Some(DeckMetadataSnapshot {
            path: path.clone(),
            source_label: source_label.clone(),
            origin: origin.clone(),
            format: format.clone(),
            unified_format: unified_src.clone(),
            negotiated: fallback_neg.clone(),
            duration_ms,
            pcm_rate,
            out_rate,
            out_channels,
            rg_tags,
            verification: shared_verification.clone(),
            api_label: api_label_b,
            device_name,
            backend: backend_kind,
            active_device_id: caps.device_id.clone(),
            expected_stamp: 0,
            is_wire: false,
            resampled_to_hz,
        });
    }
    inner
        .dual_deck
        .rebind_standby_for_new_profile(ActiveOutputProfile {
            session_id,
            is_wire: false,
            uses_dual_feeder: true,
            output_mode: mode_b,
            wire_format: WireSampleFormat::Float32Le,
            out_rate,
            out_channels,
        });
    let active_device_id = caps.device_id.clone();
    let decode_handle = thread::Builder::new()
        .name("lumina-audio-decoder".to_string())
        .spawn(move || {
            decode_loop(
                decoder,
                producer,
                pcm_rate,
                out_rate,
                out_channels,
                Some(out_sample_format),
                decode_inner,
                Some(shared_verification),
                unified_src,
                fallback_neg,
                caps,
                decode_cancel,
                decode_cancel_token,
                decode_eof,
                decode_fade,
                watermark_samples,
                session_id,
                decode_tx,
                active_idx,
                active_gen,
                None,
            )
        })
        .ok();

    if !start_paused
        && let Some(ref stream) = cpal_stream
        && let Err(e) = stream.play()
    {
        cancel_token.cancel();
        cancel_flag.store(true, Ordering::SeqCst);
        output_kill_flag.store(true, Ordering::SeqCst);
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

    if let Ok(mut eg) = inner.dual_deck.decode_entries[active_idx].lock() {
        *eg = Some(DeckDecodeHandle {
            deck_gen: active_gen,
            cancel_flag: Arc::clone(&cancel_flag),
            cancel_token: cancel_token.clone(),
            wake: Arc::new((Mutex::new(StandbyWakeState::Promoted), Condvar::new())),
            join_handle: decode_handle,
        });
    }

    Ok(ActiveSession {
        dual_deck: Arc::clone(&inner.dual_deck),
        cancel_flag,
        output_kill_flag,
        fade_ctrl,
        cancel_token,
        eof_flag,
        decode_handle: None,
        virtual_handle,
        _cpal_stream: cpal_stream,
        native_output: None,
        path,
        source_label,
        origin,
        format,
        duration_ms,
        pcm_rate,
        active_device_id,
    })
}

fn install_fresh_cancel_token(inner: &PlayerInner) -> Option<CancellationToken> {
    let _ep_guard = inner.epoch_lock.lock().unwrap_or_else(|e| e.into_inner());
    if inner.stopped.load(Ordering::SeqCst) {
        return None;
    }
    let fresh = CancellationToken::new();
    if let Ok(mut guard) = inner.active_cancel.write() {
        let prev = std::mem::replace(&mut *guard, fresh.clone());
        prev.cancel();
    }
    Some(fresh)
}

fn reopen_origin_decoder(
    inner: &Arc<PlayerInner>,
    origin: &PlayerOrigin,
    reused: Option<Box<dyn AudioDecoder>>,
    fresh_cancel: &CancellationToken,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    let can_reuse = !matches!(
        origin,
        PlayerOrigin::SourceSpec(_)
            | PlayerOrigin::Legacy(StreamSource {
                origin: StreamOrigin::Http { .. },
                ..
            })
    );
    let refresh_handler = inner.stream_refresh_handler();
    let dec = if can_reuse {
        match reused {
            Some(d) => d,
            None => origin.open_decoder_with_refresh(inner, fresh_cancel.clone(), refresh_handler)?,
        }
    } else {
        drop(reused);
        origin.open_decoder_with_refresh(inner, fresh_cancel.clone(), refresh_handler)?
    };
    if fresh_cancel.is_cancelled() || inner.stopped.load(Ordering::SeqCst) {
        return Err(CoreAudioError::Backend(BackendError::InvalidState(
            "Playback cancelled during decoder reopen".to_string(),
        )));
    }
    Ok(dec)
}

fn device_removal_affects_session(
    inner: &PlayerInner,
    sess: &ActiveSession,
    removed_id: &str,
) -> bool {
    let removed_raw = AudioDeviceManager::strip_mode_prefix(removed_id.trim());
    if removed_raw.is_empty() {
        return false;
    }
    if inner.headless
        && (removed_raw == VIRTUAL_DEVICE_ID
            || removed_raw.eq_ignore_ascii_case("default")
            || removed_raw == "*")
    {
        return true;
    }
    let active_raw = AudioDeviceManager::strip_mode_prefix(&sess.active_device_id);
    if sess.active_device_id == removed_id
        || active_raw == removed_raw
        || (!active_raw.is_empty()
            && (active_raw.contains(removed_raw) || removed_raw.contains(active_raw)))
    {
        return true;
    }
    let (sel_id, _) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    if let Some(ref id) = sel_id {
        let sel_raw = AudioDeviceManager::strip_mode_prefix(id);
        if id == removed_id
            || sel_raw == removed_raw
            || (!sel_raw.is_empty()
                && (sel_raw.contains(removed_raw) || removed_raw.contains(sel_raw)))
        {
            return true;
        }
    }
    false
}

fn coordinator_loop(
    inner: Arc<PlayerInner>,
    cmd_rx: mpsc::Receiver<PlayerCommand>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
) {
    let mut active: Option<ActiveSession> = None;
    let mut saved_recovery: Option<SavedRecoverySession> = None;

    while let Ok(cmd) = cmd_rx.recv() {
        match cmd {
            PlayerCommand::Start {
                session_id,
                decoder,
                path,
                source_label,
                origin,
                cancel_token,
                ack_tx,
            } => {
                saved_recovery = None;
                if cancel_token.is_cancelled() || inner.stopped.load(Ordering::SeqCst) {
                    let _ = ack_tx.send(Ok(()));
                    continue;
                }
                if let Some(mut prev) = active.take() {
                    let _ = prev.stop_and_join();
                }
                if cancel_token.is_cancelled() || inner.stopped.load(Ordering::SeqCst) {
                    let _ = ack_tx.send(Ok(()));
                    continue;
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
                        origin,
                        cancel_token,
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
                origin,
                cancel_token,
                rg_tags,
            } => {
                if inner.current_session_id.load(Ordering::Relaxed) != session_id
                    || inner.stopped.load(Ordering::Relaxed)
                    || cancel_token.is_cancelled()
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
                    prev.fade_ctrl.mark_silent();
                    let _ = prev.stop_and_join();
                }
                if inner.stopped.load(Ordering::SeqCst) || cancel_token.is_cancelled() {
                    continue;
                }
                {
                    let _ep_guard = inner.epoch_lock.lock().unwrap_or_else(|e| e.into_inner());
                    if inner.stopped.load(Ordering::SeqCst) {
                        continue;
                    }
                    if let Ok(mut guard) = inner.active_cancel.write() {
                        *guard = cancel_token.clone();
                    }
                }

                inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
                let effective_rg = rg_tags.with_metadata_fallback(decoder.metadata());
                if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
                    *rg_lock = effective_rg;
                }
                inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
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
                        origin,
                        cancel_token,
                        format,
                        duration_ms,
                        start_paused: false,
                    },
                    &cmd_tx,
                ) {
                    Ok(sess) => active = Some(sess),
                    Err(e) => record_playback_error_with_code(
                        &inner,
                        e.to_string(),
                        Some("FORMAT_SWITCH_FAILED"),
                        None,
                    ),
                }
            }
            PlayerCommand::ReopenForFormatChange {
                session_id,
                new_format,
                resume_pos_ms,
            } => {
                if inner.current_session_id.load(Ordering::Relaxed) != session_id
                    || inner.stopped.load(Ordering::Relaxed)
                {
                    continue;
                }
                let Some(mut prev) = active.take() else {
                    continue;
                };
                let is_paused = inner.paused.load(Ordering::SeqCst);
                let path = prev.path.clone();
                let source_label = prev.source_label.clone();
                let origin = prev.origin.clone();
                prev.fade_ctrl.mark_silent();
                let reused = prev.stop_and_join();

                let Some(fresh_cancel) = install_fresh_cancel_token(&inner) else {
                    continue;
                };
                let mut decoder = match reopen_origin_decoder(&inner, &origin, reused, &fresh_cancel)
                {
                    Ok(d) => d,
                    Err(e) => {
                        record_playback_error_with_code(
                            &inner,
                            format!("Format change reopen error: {e}"),
                            Some("FORMAT_SWITCH_FAILED"),
                            None,
                        );
                        continue;
                    }
                };
                if resume_pos_ms > 0 {
                    let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
                }

                inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
                inner.format_mismatch_flag.store(false, Ordering::Release);
                let mut format = decoder.format().clone();
                // Honor detected mid-stream format overrides (e.g. SBR/PS rate or channel switch)
                // when the container header still reports the pre-change parameters.
                if new_format.sample_rate_hz >= 8_000
                    && new_format.sample_rate_hz != format.sample_rate_hz
                {
                    format.sample_rate_hz = new_format.sample_rate_hz;
                }
                if new_format.channels > 0 && new_format.channels != format.channels {
                    format.channels = new_format.channels;
                }
                if new_format.bit_depth > 0 && new_format.bit_depth != format.bit_depth {
                    format.bit_depth = new_format.bit_depth;
                }
                format.is_dsd = new_format.is_dsd;
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
                let next_sid = inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                inner.duration_ms.store(duration_ms, Ordering::SeqCst);

                match start_output_pipeline(
                    &inner,
                    decoder,
                    PipelineSpec {
                        session_id: next_sid,
                        pcm_rate,
                        out_channels: default_out_channels,
                        path,
                        source_label,
                        origin,
                        cancel_token: fresh_cancel,
                        format,
                        duration_ms,
                        start_paused: is_paused,
                    },
                    &cmd_tx,
                ) {
                    Ok(sess) => {
                        let new_out_rate =
                            inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                        let rescaled_frames =
                            ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                        inner
                            .frames_rendered
                            .store(rescaled_frames, Ordering::SeqCst);
                        let target_state = if is_paused {
                            PlaybackLifecycleState::Paused as i32
                        } else {
                            PlaybackLifecycleState::Playing as i32
                        };
                        inner.state_code.store(target_state, Ordering::SeqCst);
                        active = Some(sess);
                    }
                    Err(e) => record_playback_error_with_code(
                        &inner,
                        format!("Format change output reopen failed: {e}"),
                        Some("FORMAT_SWITCH_FAILED"),
                        None,
                    ),
                }
            }
            PlayerCommand::HotReloadSpec {
                session_id,
                new_spec,
                resume_ms,
            } => {
                if inner.current_session_id.load(Ordering::Relaxed) != session_id
                    || inner.stopped.load(Ordering::Relaxed)
                {
                    continue;
                }
                let is_paused = inner.paused.load(Ordering::SeqCst);
                let source_label = active
                    .as_ref()
                    .map(|s| s.source_label.clone())
                    .unwrap_or_else(|| source_spec_default_label(&new_spec));
                if let Some(mut prev) = active.take() {
                    prev.fade_ctrl.mark_silent();
                    let _ = prev.stop_and_join();
                }

                let Some(fresh_cancel) = install_fresh_cancel_token(&inner) else {
                    continue;
                };
                if let Ok(mut spec_lock) = inner.active_source_spec.write() {
                    *spec_lock = Some(new_spec.clone());
                }
                let refresh_handler = inner.stream_refresh_handler();
                let mut decoder = match open_decoder_for_source_spec_with_l2(
                    &new_spec,
                    fresh_cancel.clone(),
                    refresh_handler,
                    inner.l2_cache_manager(),
                    false,
                    build_mismatch_callback(&inner, &new_spec),
                    Some(Arc::downgrade(&inner)),
                ) {
                    Ok(d) => d,
                    Err(CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    })) => {
                        record_playback_error_with_code(
                            &inner,
                            format!("Authentication required for {provider_id} (HTTP {status})"),
                            Some("AUTH_REQUIRED"),
                            Some(provider_id),
                        );
                        continue;
                    }
                    Err(e) => {
                        if !fresh_cancel.is_cancelled() && !inner.stopped.load(Ordering::SeqCst) {
                            record_playback_error_with_code(
                                &inner,
                                format!("Stream hot-reload failed: {e}"),
                                Some("FORMAT_SWITCH_FAILED"),
                                None,
                            );
                        }
                        continue;
                    }
                };
                if fresh_cancel.is_cancelled() || inner.stopped.load(Ordering::SeqCst) {
                    continue;
                }
                if resume_ms > 0 {
                    let _ = decoder.seek(Duration::from_millis(resume_ms));
                }

                let new_origin = PlayerOrigin::SourceSpec(new_spec.clone());
                let new_path = new_origin.display_path();
                if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
                    *rg_lock = new_origin
                        .replay_gain_tags()
                        .with_metadata_fallback(decoder.metadata());
                }
                inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
                inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
                inner.format_mismatch_flag.store(false, Ordering::Release);
                inner.clear_error_state();

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
                let next_sid = inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                inner.duration_ms.store(duration_ms, Ordering::SeqCst);

                match start_output_pipeline(
                    &inner,
                    decoder,
                    PipelineSpec {
                        session_id: next_sid,
                        pcm_rate,
                        out_channels: default_out_channels,
                        path: new_path,
                        source_label,
                        origin: new_origin,
                        cancel_token: fresh_cancel,
                        format,
                        duration_ms,
                        start_paused: is_paused,
                    },
                    &cmd_tx,
                ) {
                    Ok(sess) => {
                        let new_out_rate =
                            inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                        let rescaled_frames =
                            ((resume_ms as u128) * new_out_rate / 1000) as u64;
                        inner
                            .frames_rendered
                            .store(rescaled_frames, Ordering::SeqCst);
                        let target_state = if is_paused {
                            PlaybackLifecycleState::Paused as i32
                        } else {
                            PlaybackLifecycleState::Playing as i32
                        };
                        inner.state_code.store(target_state, Ordering::SeqCst);
                        active = Some(sess);
                    }
                    Err(e) => record_playback_error_with_code(
                        &inner,
                        format!("Hot-reload output reopen failed: {e}"),
                        Some("FORMAT_SWITCH_FAILED"),
                        None,
                    ),
                }
            }
            PlayerCommand::HardwareDeviceEvent(event) => match event {
                DeviceEvent::DefaultRenderChanged(_) => {
                    let following_default = inner
                        .selected_output
                        .read()
                        .map(|g| g.0.is_none())
                        .unwrap_or(true);
                    let state = inner.state_code.load(Ordering::SeqCst);
                    if following_default
                        && active.is_some()
                        && !inner.stopped.load(Ordering::SeqCst)
                        && (state == PlaybackLifecycleState::Playing as i32
                            || state == PlaybackLifecycleState::Paused as i32)
                    {
                        let resume_pos_ms = position_ms_from_inner(&inner);
                        let is_paused = inner.paused.load(Ordering::SeqCst);
                        let mut prev = active.take().unwrap();
                        let path = prev.path.clone();
                        let source_label = prev.source_label.clone();
                        let prev_origin = prev.origin.clone();
                        let format = prev.format.clone();
                        let duration_ms = prev.duration_ms;
                        let pcm_rate = prev.pcm_rate;
                        let src_channels = (format.channels as u16).max(1);
                        let default_out_channels =
                            if src_channels == 1 { 2 } else { src_channels };
                        let reused = prev.stop_and_join();

                        if let Some(fresh_cancel) = install_fresh_cancel_token(&inner)
                            && let Ok(mut decoder) =
                                reopen_origin_decoder(&inner, &prev_origin, reused, &fresh_cancel)
                        {
                            let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
                            let session_id =
                                inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                            match start_output_pipeline(
                                &inner,
                                decoder,
                                PipelineSpec {
                                    session_id,
                                    pcm_rate,
                                    out_channels: default_out_channels,
                                    path,
                                    source_label,
                                    origin: prev_origin,
                                    cancel_token: fresh_cancel,
                                    format,
                                    duration_ms,
                                    start_paused: is_paused,
                                },
                                &cmd_tx,
                            ) {
                                Ok(sess) => {
                                    let new_out_rate =
                                        inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                                    let rescaled_frames =
                                        ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                                    inner
                                        .frames_rendered
                                        .store(rescaled_frames, Ordering::SeqCst);
                                    active = Some(sess);
                                }
                                Err(e) => record_playback_error_with_code(
                                    &inner,
                                    format!("Default device reroute failed: {e}"),
                                    Some("DEVICE_LOST"),
                                    None,
                                ),
                            }
                        }
                    }
                }
                DeviceEvent::DeviceRemoved(device_id) => {
                    let affects = active
                        .as_ref()
                        .is_some_and(|s| device_removal_affects_session(&inner, s, &device_id));
                    if affects && let Some(mut prev) = active.take() {
                        let resume_pos_ms = position_ms_from_inner(&inner);
                        let was_playing = !inner.paused.load(Ordering::SeqCst)
                            && inner.state_code.load(Ordering::SeqCst)
                                == PlaybackLifecycleState::Playing as i32;
                        inner.device_lost.store(true, Ordering::SeqCst);
                        inner.paused.store(true, Ordering::SeqCst);
                        if let Ok(mut err_lock) = inner.last_error.write() {
                            *err_lock = Some(format!("Audio output device removed: {device_id}"));
                        }
                        if let Ok(mut code_lock) = inner.last_error_code.write() {
                            *code_lock = Some("DEVICE_LOST".to_string());
                        }
                        if let Ok(mut prov_lock) = inner.last_error_provider.write() {
                            *prov_lock = None;
                        }
                        inner
                            .state_code
                            .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
                        saved_recovery = Some(SavedRecoverySession {
                            path: prev.path.clone(),
                            source_label: prev.source_label.clone(),
                            origin: prev.origin.clone(),
                            format: prev.format.clone(),
                            duration_ms: prev.duration_ms,
                            pcm_rate: prev.pcm_rate,
                            resume_pos_ms,
                            was_playing,
                            from_suspend: false,
                        });
                        prev.fade_ctrl.mark_silent();
                        let _ = prev.stop_and_join();
                        if let Ok(mut af) = inner.active_fade.write() {
                            *af = None;
                        }
                    }
                }
                DeviceEvent::DeviceAdded(_) => {
                    if !inner.headless {
                        let _ = AudioDeviceManager::list_devices();
                    }
                    // Keep saved_recovery intact so RerouteOutput or Resume recovers at saved_pos cleanly.
                }
                DeviceEvent::SystemSuspend => {
                    if let Some(mut prev) = active.take() {
                        let resume_pos_ms = position_ms_from_inner(&inner);
                        let was_playing = !inner.paused.load(Ordering::SeqCst)
                            && inner.state_code.load(Ordering::SeqCst)
                                == PlaybackLifecycleState::Playing as i32;
                        if was_playing {
                            prev.fade_ctrl.request_pause_fade_out();
                            let deadline = Instant::now() + Duration::from_millis(20);
                            while !prev.fade_ctrl.is_fade_out_done() && Instant::now() < deadline {
                                thread::sleep(Duration::from_millis(1));
                            }
                        }
                        inner.paused.store(true, Ordering::SeqCst);
                        inner
                            .state_code
                            .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
                        saved_recovery = Some(SavedRecoverySession {
                            path: prev.path.clone(),
                            source_label: prev.source_label.clone(),
                            origin: prev.origin.clone(),
                            format: prev.format.clone(),
                            duration_ms: prev.duration_ms,
                            pcm_rate: prev.pcm_rate,
                            resume_pos_ms,
                            was_playing,
                            from_suspend: true,
                        });
                        let _ = prev.stop_and_join();
                        if let Ok(mut af) = inner.active_fade.write() {
                            *af = None;
                        }
                    }
                }
                DeviceEvent::SystemResume => {
                    if !inner.headless {
                        let _ = AudioDeviceManager::list_devices();
                    }
                    if active.is_none()
                        && !inner.stopped.load(Ordering::SeqCst)
                        && let Some(rec) = saved_recovery.take()
                        && rec.from_suspend
                    {
                        let resume_pos_ms = rec.resume_pos_ms;
                        let start_paused = !rec.was_playing;
                        let src_channels = (rec.format.channels as u16).max(1);
                        let default_out_channels =
                            if src_channels == 1 { 2 } else { src_channels };
                        let reopen_result = install_fresh_cancel_token(&inner).and_then(|cancel| {
                            reopen_origin_decoder(&inner, &rec.origin, None, &cancel)
                                .ok()
                                .map(|dec| (cancel, dec))
                        });
                        if let Some((fresh_cancel, mut decoder)) = reopen_result {
                            if resume_pos_ms > 0 {
                                let _ = decoder.seek(Duration::from_millis(resume_pos_ms));
                            }
                            let session_id =
                                inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                            match start_output_pipeline(
                                &inner,
                                decoder,
                                PipelineSpec {
                                    session_id,
                                    pcm_rate: rec.pcm_rate,
                                    out_channels: default_out_channels,
                                    path: rec.path.clone(),
                                    source_label: rec.source_label.clone(),
                                    origin: rec.origin.clone(),
                                    cancel_token: fresh_cancel,
                                    format: rec.format.clone(),
                                    duration_ms: rec.duration_ms,
                                    start_paused,
                                },
                                &cmd_tx,
                            ) {
                                Ok(sess) => {
                                    let new_out_rate =
                                        inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                                    let rescaled_frames =
                                        ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                                    inner
                                        .frames_rendered
                                        .store(rescaled_frames, Ordering::SeqCst);
                                    inner.device_lost.store(false, Ordering::SeqCst);
                                    inner.clear_error_state();
                                    inner.paused.store(start_paused, Ordering::SeqCst);
                                    let target_state = if start_paused {
                                        PlaybackLifecycleState::Paused as i32
                                    } else {
                                        PlaybackLifecycleState::Playing as i32
                                    };
                                    inner.state_code.store(target_state, Ordering::SeqCst);
                                    active = Some(sess);
                                }
                                Err(e) => {
                                    tracing::warn!(
                                        "Audio output resume after sleep unavailable (safe pause): {e}"
                                    );
                                    inner.device_lost.store(true, Ordering::SeqCst);
                                    inner.paused.store(true, Ordering::SeqCst);
                                    if let Ok(mut code_lock) = inner.last_error_code.write() {
                                        *code_lock = Some("DEVICE_LOST".to_string());
                                    }
                                    if let Ok(mut err_lock) = inner.last_error.write() {
                                        *err_lock = Some(format!(
                                            "Audio device unavailable after wake: {e}"
                                        ));
                                    }
                                    inner.state_code.store(
                                        PlaybackLifecycleState::Paused as i32,
                                        Ordering::SeqCst,
                                    );
                                    saved_recovery = Some(rec);
                                }
                            }
                        } else {
                            saved_recovery = Some(rec);
                        }
                    }
                }
            },
            PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost,
            } => {
                let state = inner.state_code.load(Ordering::SeqCst);
                let was_lost = recover_device_lost || inner.device_lost.load(Ordering::Acquire);
                let can_recover_active = active.is_some()
                    && ((!inner.stopped.load(Ordering::SeqCst)
                        && (state == PlaybackLifecycleState::Playing as i32
                            || state == PlaybackLifecycleState::Paused as i32))
                        || (was_lost
                            && (state == PlaybackLifecycleState::Paused as i32
                                || state == PlaybackLifecycleState::Error as i32)));
                let can_recover_saved = active.is_none()
                    && saved_recovery.is_some()
                    && (was_lost
                        || state == PlaybackLifecycleState::Paused as i32
                        || state == PlaybackLifecycleState::Error as i32);

                if !can_recover_active && !can_recover_saved {
                    let _ = ack_tx.send(Ok(()));
                    continue;
                }

                let (
                    path,
                    source_label,
                    prev_origin,
                    format,
                    duration_ms,
                    pcm_rate,
                    resume_pos_ms,
                    is_paused,
                    reused,
                ) = if can_recover_active {
                    let resume_pos_ms = position_ms_from_inner(&inner);
                    let is_paused = inner.paused.load(Ordering::SeqCst)
                        && state != PlaybackLifecycleState::Error as i32;
                    let mut prev = active.take().unwrap();
                    let path = prev.path.clone();
                    let source_label = prev.source_label.clone();
                    let prev_origin = prev.origin.clone();
                    let format = prev.format.clone();
                    let duration_ms = prev.duration_ms;
                    let pcm_rate = prev.pcm_rate;
                    let reused = prev.stop_and_join();
                    (
                        path,
                        source_label,
                        prev_origin,
                        format,
                        duration_ms,
                        pcm_rate,
                        resume_pos_ms,
                        is_paused,
                        reused,
                    )
                } else {
                    let rec = saved_recovery.take().unwrap();
                    let is_paused = inner.paused.load(Ordering::SeqCst) && !rec.was_playing;
                    (
                        rec.path,
                        rec.source_label,
                        rec.origin,
                        rec.format,
                        rec.duration_ms,
                        rec.pcm_rate,
                        rec.resume_pos_ms,
                        is_paused,
                        None,
                    )
                };

                if was_lost {
                    inner.stopped.store(false, Ordering::SeqCst);
                    inner.device_lost.store(false, Ordering::SeqCst);
                    inner.clear_error_state();
                }

                let src_channels = (format.channels as u16).max(1);
                let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
                let Some(fresh_cancel) = install_fresh_cancel_token(&inner) else {
                    let _ = ack_tx.send(Ok(()));
                    continue;
                };
                let Ok(mut decoder) =
                    reopen_origin_decoder(&inner, &prev_origin, reused, &fresh_cancel)
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
                        path: path.clone(),
                        source_label: source_label.clone(),
                        origin: prev_origin.clone(),
                        cancel_token: fresh_cancel,
                        format: format.clone(),
                        duration_ms,
                        start_paused: is_paused,
                    },
                    &cmd_tx,
                ) {
                    Ok(sess) => {
                        let new_out_rate =
                            inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                        let rescaled_frames =
                            ((resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                        inner
                            .frames_rendered
                            .store(rescaled_frames, Ordering::SeqCst);
                        inner.paused.store(is_paused, Ordering::SeqCst);
                        let target_state = if is_paused {
                            PlaybackLifecycleState::Paused as i32
                        } else {
                            PlaybackLifecycleState::Playing as i32
                        };
                        inner.state_code.store(target_state, Ordering::SeqCst);
                        saved_recovery = None;
                        active = Some(sess);
                        let _ = ack_tx.send(Ok(()));
                    }
                    Err(e) => {
                        if was_lost {
                            saved_recovery = Some(SavedRecoverySession {
                                path,
                                source_label,
                                origin: prev_origin,
                                format,
                                duration_ms,
                                pcm_rate,
                                resume_pos_ms,
                                was_playing: !is_paused,
                                from_suspend: false,
                            });
                        }
                        record_playback_error(&inner, e.to_string());
                        let _ = ack_tx.send(Err(e));
                    }
                }
            }
            PlayerCommand::Pause => {
                if let Some(sess) = &active {
                    sess.fade_ctrl.request_pause_fade_out();
                    let deadline = Instant::now() + Duration::from_millis(25);
                    while !sess.fade_ctrl.is_fade_out_done()
                        && sess.fade_ctrl.target() == FadeTarget::PauseFadeOut
                        && !inner.stopped.load(Ordering::Acquire)
                        && Instant::now() < deadline
                    {
                        thread::sleep(Duration::from_millis(1));
                    }
                    if inner.paused.load(Ordering::Acquire)
                        && sess.fade_ctrl.target() == FadeTarget::PauseFadeOut
                    {
                        if let Some(stream) = &sess._cpal_stream {
                            let _ = stream.pause();
                        }
                        if let Some(native) = &sess.native_output {
                            native.set_paused(true);
                        }
                    }
                }
            }
            PlayerCommand::Resume => {
                if let Some(sess) = &active {
                    sess.fade_ctrl.request_play_fade_in();
                    if let Some(stream) = &sess._cpal_stream {
                        let _ = stream.play();
                    }
                    if let Some(native) = &sess.native_output {
                        native.set_paused(false);
                    }
                } else if let Some(rec) = saved_recovery.take() {
                    inner.stopped.store(false, Ordering::SeqCst);
                    inner.device_lost.store(false, Ordering::SeqCst);
                    inner.clear_error_state();
                    let src_channels = (rec.format.channels as u16).max(1);
                    let default_out_channels = if src_channels == 1 { 2 } else { src_channels };
                    if let Some(fresh_cancel) = install_fresh_cancel_token(&inner)
                        && let Ok(mut decoder) =
                            reopen_origin_decoder(&inner, &rec.origin, None, &fresh_cancel)
                    {
                        if rec.resume_pos_ms > 0 {
                            let _ = decoder.seek(Duration::from_millis(rec.resume_pos_ms));
                        }
                        let session_id =
                            inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                        match start_output_pipeline(
                            &inner,
                            decoder,
                            PipelineSpec {
                                session_id,
                                pcm_rate: rec.pcm_rate,
                                out_channels: default_out_channels,
                                path: rec.path.clone(),
                                source_label: rec.source_label.clone(),
                                origin: rec.origin.clone(),
                                cancel_token: fresh_cancel,
                                format: rec.format.clone(),
                                duration_ms: rec.duration_ms,
                                start_paused: false,
                            },
                            &cmd_tx,
                        ) {
                            Ok(sess) => {
                                let new_out_rate =
                                    inner.out_sample_rate.load(Ordering::SeqCst).max(1) as u128;
                                let rescaled_frames =
                                    ((rec.resume_pos_ms as u128) * new_out_rate / 1000) as u64;
                                inner
                                    .frames_rendered
                                    .store(rescaled_frames, Ordering::SeqCst);
                                inner.paused.store(false, Ordering::SeqCst);
                                inner
                                    .state_code
                                    .store(PlaybackLifecycleState::Playing as i32, Ordering::SeqCst);
                                active = Some(sess);
                            }
                            Err(e) => {
                                saved_recovery = Some(rec);
                                inner.paused.store(true, Ordering::SeqCst);
                                inner.device_lost.store(true, Ordering::SeqCst);
                                if let Ok(mut code_lock) = inner.last_error_code.write() {
                                    *code_lock = Some("DEVICE_LOST".to_string());
                                }
                                if let Ok(mut err_lock) = inner.last_error.write() {
                                    *err_lock = Some(format!("Failed to resume output: {e}"));
                                }
                                inner
                                    .state_code
                                    .store(PlaybackLifecycleState::Paused as i32, Ordering::SeqCst);
                            }
                        }
                    } else {
                        saved_recovery = Some(rec);
                    }
                }
            }
            PlayerCommand::Stop => {
                saved_recovery = None;
                if let Some(mut prev) = active.take() {
                    let _ = prev.stop_and_join();
                }
                if let Ok(mut af) = inner.active_fade.write() {
                    *af = None;
                }
            }
            PlayerCommand::SeekMs { was_ended } => {
                let req_ms = inner.seek_request_ms.load(Ordering::SeqCst);
                let is_paused = inner.paused.load(Ordering::SeqCst);
                let is_ended = was_ended
                    || inner.state_code.load(Ordering::SeqCst)
                        == PlaybackLifecycleState::Ended as i32;

                if let Some(ref mut sess) = active {
                    let cur_active = inner.dual_deck.active_idx();
                    if let Ok(mg) = inner.dual_deck.deck_meta[cur_active].read()
                        && let Some(ref snap) = *mg
                    {
                        sess.path = snap.path.clone();
                        sess.source_label = snap.source_label.clone();
                        sess.origin = snap.origin.clone();
                        sess.format = snap.format.clone();
                        sess.duration_ms = snap.duration_ms;
                        sess.pcm_rate = snap.pcm_rate;
                        sess.eof_flag = Arc::clone(&inner.dual_deck.deck_eof_flags[cur_active]);
                    }
                    let decode_finished = inner.dual_deck.decode_entries[cur_active]
                        .lock()
                        .ok()
                        .and_then(|g| {
                            g.as_ref()
                                .and_then(|e| e.join_handle.as_ref().map(|h| h.is_finished()))
                        })
                        .or_else(|| sess.decode_handle.as_ref().map(|h| h.is_finished()))
                        .unwrap_or(true);
                    let output_finished = sess
                        .virtual_handle
                        .as_ref()
                        .is_some_and(|h| h.is_finished())
                        || matches!(
                            sess.native_output,
                            Some(NativeOutputSession::VirtualWire(ref h)) if h.is_finished()
                        );
                    if !is_paused && !is_ended && !decode_finished && !output_finished {
                        let deadline = Instant::now() + Duration::from_millis(15);
                        while !sess.fade_ctrl.is_fade_out_done()
                            && sess.fade_ctrl.target() == FadeTarget::SeekFadeOut
                            && !inner.stopped.load(Ordering::Acquire)
                            && Instant::now() < deadline
                        {
                            thread::sleep(Duration::from_millis(1));
                        }
                    }
                    if let Some(ref native) = sess.native_output {
                        let _ = native.flush();
                    }

                    if is_ended || decode_finished || output_finished {
                        let path = sess.path.clone();
                        let source_label = sess.source_label.clone();
                        let origin = sess.origin.clone();
                        let format = sess.format.clone();
                        let duration_ms = sess.duration_ms;
                        let pcm_rate = sess.pcm_rate;
                        let src_channels = (format.channels as u16).max(1);
                        let default_out_channels = if src_channels == 1 { 2 } else { src_channels };

                        if let Some(mut prev) = active.take() {
                            prev.fade_ctrl.mark_silent();
                            let _ = prev.stop_and_join();
                        }

                        let Some(fresh_cancel) = install_fresh_cancel_token(&inner) else {
                            inner.is_seeking.store(false, Ordering::SeqCst);
                            continue;
                        };
                        let refresh_handler = inner.stream_refresh_handler();
                        match origin.open_decoder_with_refresh(&inner, fresh_cancel.clone(), refresh_handler)
                        {
                            Ok(mut decoder) => {
                                if fresh_cancel.is_cancelled() || inner.stopped.load(Ordering::SeqCst)
                                {
                                    inner.is_seeking.store(false, Ordering::SeqCst);
                                    continue;
                                }
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
                                        origin,
                                        cancel_token: fresh_cancel,
                                        format,
                                        duration_ms,
                                        start_paused: is_paused,
                                    },
                                    &cmd_tx,
                                ) {
                                    Ok(new_sess) => {
                                        let new_out_rate =
                                            inner.out_sample_rate.load(Ordering::SeqCst).max(1)
                                                as u128;
                                        let target_ms = req_ms.max(0) as u128;
                                        let rescaled_frames =
                                            (target_ms * new_out_rate / 1000) as u64;
                                        inner
                                            .frames_rendered
                                            .store(rescaled_frames, Ordering::SeqCst);
                                        let paused_now = inner.paused.load(Ordering::SeqCst);
                                        let target_state = if paused_now {
                                            PlaybackLifecycleState::Paused as i32
                                        } else {
                                            PlaybackLifecycleState::Playing as i32
                                        };
                                        inner.state_code.store(target_state, Ordering::SeqCst);
                                        inner.is_seeking.store(false, Ordering::SeqCst);
                                        active = Some(new_sess);
                                    }
                                    Err(e) => {
                                        inner.is_seeking.store(false, Ordering::SeqCst);
                                        record_playback_error(&inner, e.to_string());
                                    }
                                }
                            }
                            Err(e) => {
                                inner.is_seeking.store(false, Ordering::SeqCst);
                                if !fresh_cancel.is_cancelled()
                                    && !inner.stopped.load(Ordering::SeqCst)
                                {
                                    record_playback_error(
                                        &inner,
                                        format!("Seek reopen error: {e}"),
                                    );
                                }
                            }
                        }
                    }
                }
            }
            PlayerCommand::RetireDeck {
                deck_idx,
                deck_gen: _,
            } => {
                inner.dual_deck.retire_inactive_deck(deck_idx);
                let cur_active = inner.dual_deck.active_idx();
                if let Some(ref mut sess) = active {
                    if let Ok(mg) = inner.dual_deck.deck_meta[cur_active].read()
                        && let Some(ref snap) = *mg
                    {
                        sess.path = snap.path.clone();
                        sess.source_label = snap.source_label.clone();
                        sess.origin = snap.origin.clone();
                        sess.format = snap.format.clone();
                        sess.duration_ms = snap.duration_ms;
                        sess.pcm_rate = snap.pcm_rate;
                        sess.active_device_id = snap.active_device_id.clone();
                        sess.eof_flag = Arc::clone(&inner.dual_deck.deck_eof_flags[cur_active]);
                    }
                    if let Ok(eg) = inner.dual_deck.decode_entries[cur_active].lock()
                        && let Some(ref entry) = *eg
                    {
                        sess.cancel_flag = Arc::clone(&entry.cancel_flag);
                        sess.cancel_token = entry.cancel_token.clone();
                    }
                }
            }
            PlayerCommand::ReopenOntoStandby {
                from_deck,
                to_deck,
                to_deck_gen,
                is_manual_skip,
                is_mismatch_recovery,
            } => {
                let from_i = from_deck & 1;
                let to_i = to_deck & 1;
                if inner.stopped.load(Ordering::SeqCst)
                    || (inner.dual_deck.deck_gen_for(to_i) & 0xFF_FFFF_FFFF)
                        != (to_deck_gen & 0xFF_FFFF_FFFF)
                    || inner.dual_deck.deck_state(to_i) != DeckState::StandbyReady
                {
                    inner.dual_deck.notify_flip_done();
                    continue;
                }
                let is_paused = inner.paused.load(Ordering::SeqCst);
                if let Some(mut prev) = active.take() {
                    prev.fade_ctrl.mark_silent();
                    let _ = prev.stop_and_join();
                }
                let _ = inner.dual_deck.cancel_and_join_deck(from_i);

                let resume_frame = if is_mismatch_recovery {
                    inner.dual_deck.mismatch_resume_frame.load(Ordering::Acquire)
                } else {
                    0
                };
                inner.dual_deck.mismatch_armed.store(false, Ordering::SeqCst);
                inner
                    .dual_deck
                    .active_deck_idx
                    .store(to_i as u8, Ordering::SeqCst);
                inner.dual_deck.deck_states[to_i]
                    .store(DeckState::Playing as u8, Ordering::SeqCst);
                inner.dual_deck.deck_states[from_i]
                    .store(DeckState::Idle as u8, Ordering::SeqCst);
                inner.dual_deck.set_deck_key(from_i, None);
                inner
                    .dual_deck
                    .standby_buffered_ms
                    .store(0, Ordering::Relaxed);
                inner.format_reinit_count.fetch_add(1, Ordering::SeqCst);
                if is_manual_skip {
                    inner
                        .dual_deck
                        .manual_zero_latency_switches
                        .fetch_add(1, Ordering::SeqCst);
                } else if is_mismatch_recovery {
                    inner
                        .dual_deck
                        .format_mismatch_recoveries
                        .fetch_add(1, Ordering::SeqCst);
                } else {
                    inner.gapless_transitions.fetch_add(1, Ordering::SeqCst);
                }

                let next_sid = inner.current_session_id.fetch_add(1, Ordering::SeqCst) + 1;
                inner.frames_rendered.store(resume_frame, Ordering::SeqCst);
                inner.nonzero_output_frames.store(0, Ordering::SeqCst);
                inner.state_code.store(
                    if is_paused {
                        PlaybackLifecycleState::Paused as i32
                    } else {
                        PlaybackLifecycleState::Playing as i32
                    },
                    Ordering::SeqCst,
                );

                let standby_snap_backup = inner.dual_deck.deck_meta[to_i]
                    .read()
                    .ok()
                    .and_then(|g| g.clone());

                match start_output_pipeline_from_standby(&inner, to_i, next_sid, is_paused) {
                    Ok(sess) => {
                        active = Some(sess);
                    }
                    Err(e) => {
                        tracing::warn!(
                            "Standby output reopen failed ({e}); falling back to clean decoder reopen"
                        );
                        let mut fallback_ok = false;
                        if let Some(snap) = standby_snap_backup {
                            let reused = inner.dual_deck.cancel_and_join_deck(to_i);
                            if let Some(fresh_cancel) = install_fresh_cancel_token(&inner) {
                                match reopen_origin_decoder(
                                    &inner,
                                    &snap.origin,
                                    reused,
                                    &fresh_cancel,
                                ) {
                                    Ok(mut dec) => {
                                        let resume_ms = if is_mismatch_recovery
                                            && resume_frame > 0
                                            && snap.out_rate > 0
                                        {
                                            ((resume_frame as u128) * 1000
                                                / (snap.out_rate as u128))
                                                as u64
                                        } else {
                                            0
                                        };
                                        if resume_ms > 0 {
                                            let _ = dec.seek(Duration::from_millis(resume_ms));
                                        }
                                        let fmt = dec.format().clone();
                                        let dur_ms = dec
                                            .duration()
                                            .map(|d| d.as_millis() as u64)
                                            .unwrap_or(snap.duration_ms);
                                        let pcm_rate = if fmt.is_dsd {
                                            (fmt.sample_rate_hz / 8).max(44_100)
                                        } else {
                                            fmt.sample_rate_hz.max(8_000)
                                        };
                                        let src_ch = (fmt.channels as u16).max(1);
                                        let default_out_ch = if src_ch == 1 { 2 } else { src_ch };
                                        inner.duration_ms.store(dur_ms, Ordering::SeqCst);
                                        if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
                                            *rg_lock = snap.rg_tags.clone();
                                        }
                                        inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
                                        match start_output_pipeline(
                                            &inner,
                                            dec,
                                            PipelineSpec {
                                                session_id: next_sid,
                                                pcm_rate,
                                                out_channels: default_out_ch,
                                                path: snap.path,
                                                source_label: snap.source_label,
                                                origin: snap.origin,
                                                cancel_token: fresh_cancel,
                                                format: fmt,
                                                duration_ms: dur_ms,
                                                start_paused: is_paused,
                                            },
                                            &cmd_tx,
                                        ) {
                                            Ok(sess) => {
                                                active = Some(sess);
                                                fallback_ok = true;
                                            }
                                            Err(fb_err) => {
                                                record_playback_error_with_code(
                                                    &inner,
                                                    fb_err.to_string(),
                                                    Some("FORMAT_SWITCH_FAILED"),
                                                    None,
                                                );
                                            }
                                        }
                                    }
                                    Err(reopen_err) => {
                                        record_playback_error_with_code(
                                            &inner,
                                            format!(
                                                "Standby fallback reopen failed: {reopen_err}"
                                            ),
                                            Some("FORMAT_SWITCH_FAILED"),
                                            None,
                                        );
                                    }
                                }
                            }
                        }
                        if !fallback_ok {
                            record_playback_error_with_code(
                                &inner,
                                e.to_string(),
                                Some("FORMAT_SWITCH_FAILED"),
                                None,
                            );
                        }
                    }
                }
                inner.dual_deck.notify_flip_done();
            }
            PlayerCommand::TriggerAutoStandby => {
                if inner.stopped.load(Ordering::Relaxed) {
                    continue;
                }
                let sb = inner.dual_deck.standby_idx();
                if inner.dual_deck.deck_state(sb) != DeckState::Idle {
                    continue;
                }
                let next_opt = inner
                    .queued_next_spec
                    .write()
                    .ok()
                    .and_then(|mut g| g.take());
                inner.has_queued_next_spec.store(false, Ordering::SeqCst);
                if let Some((spec, label)) = next_opt {
                    if matches!(spec, StreamSourceSpec::ExternalBackend { .. }) {
                        continue;
                    }
                    let player = AudioPlayer {
                        inner: Arc::clone(&inner),
                        cmd_tx: cmd_tx.clone(),
                    };
                    let _ = player.prepare_standby_internal(
                        PlayerOrigin::SourceSpec(spec),
                        label,
                        false,
                        false,
                        None,
                        None,
                    );
                }
            }
            PlayerCommand::Shutdown => {
                let _ = saved_recovery.take();
                if let Some(mut prev) = active.take() {
                    prev.fade_ctrl.mark_silent();
                    let _ = prev.stop_and_join();
                }
                inner.dual_deck.cancel_standby();
                let cur_active = inner.dual_deck.active_idx();
                let _ = inner.dual_deck.cancel_and_join_deck(cur_active);
                break;
            }
        }
    }
}

fn apply_live_dsp_for_deck(d: &mut DspPipeline, inner: &PlayerInner, deck_idx: usize) {
    let cfg = inner
        .dsp_config
        .read()
        .map(|g| g.clone())
        .unwrap_or_else(|_| default_shared_dsp_config());
    let rg_tags = inner.dual_deck.deck_meta[deck_idx & 1]
        .read()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.rg_tags.clone()))
        .unwrap_or_else(|| {
            inner
                .track_replay_gain
                .read()
                .map(|g| g.clone())
                .unwrap_or_default()
        });

    let bypassed = inner.dsp_bypassed.load(Ordering::Relaxed) || cfg.bypass;
    d.set_bypass(bypassed);
    let _ = d.set_peq_bands(to_parametric_bands(&cfg.peq_bands));
    d.set_crossfeed_enabled(cfg.crossfeed.enabled);
    d.set_replay_gain(to_internal_replay_gain(&cfg.replay_gain, &rg_tags));
    d.set_limiter_enabled(true);
}

fn check_wire_chunk_format_mismatch(
    chunk: &AudioChunk,
    curr_unified: &UnifiedAudioFormat,
    curr_neg: &NegotiatedFormat,
) -> Option<(u64, AudioFormat)> {
    let is_dsd_wire = matches!(
        curr_neg.wire_format,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    );
    let chunk_is_dsd = matches!(chunk, AudioChunk::DsdBitstream { .. });
    let expected_chunk_rate = if is_dsd_wire {
        curr_unified.sample_rate
    } else {
        curr_neg.target_sample_rate
    };
    let rate_mismatch = chunk.sample_rate() != expected_chunk_rate;
    let ch_mismatch = chunk.channels() != curr_neg.target_channels;
    let kind_mismatch = chunk_is_dsd != is_dsd_wire;
    let bits_mismatch = !chunk_is_dsd
        && curr_unified.codec.is_lossless()
        && chunk.valid_bits() > curr_unified.valid_bits
        && chunk.valid_bits() > curr_neg.valid_bits;

    if rate_mismatch || ch_mismatch || kind_mismatch || bits_mismatch {
        let new_wire = match chunk {
            AudioChunk::PcmI16 { .. } => WireSampleFormat::Int16Le,
            AudioChunk::PcmI24In32 { .. } => WireSampleFormat::Int24In32MsbLe,
            AudioChunk::PcmI32 { .. } => WireSampleFormat::Int32Le,
            AudioChunk::PcmF32 { .. } => WireSampleFormat::Float32Le,
            AudioChunk::PcmF64 { .. } => WireSampleFormat::Float64Le,
            AudioChunk::DsdBitstream { channels, .. } => WireSampleFormat::NativeDsd {
                channels: *channels,
            },
        };
        let new_stamp =
            WireFormatStamp::from_wire(chunk.sample_rate(), chunk.channels(), new_wire).0;
        let new_fmt = AudioFormat {
            codec: curr_unified.codec,
            sample_rate_hz: chunk.sample_rate(),
            bit_depth: if chunk_is_dsd { 1 } else { chunk.valid_bits() },
            channels: chunk.channels().min(u8::MAX as u16) as u8,
            is_dsd: chunk_is_dsd,
        };
        return Some((new_stamp, new_fmt));
    }
    None
}

#[inline]
fn is_opus_dump_enabled() -> bool {
    std::env::var_os("LUMINA_DUMP_OPUS_WAV").is_some_and(|v| v == "1")
}

fn write_ieee_f32_wav(
    path: &Path,
    sample_rate: u32,
    channels: u16,
    samples: &[f32],
) -> std::io::Result<()> {
    use std::io::{BufWriter, Write};

    let ch = channels.max(1);
    let bits_per_sample: u16 = 32;
    let block_align = ch * (bits_per_sample / 8);
    let byte_rate = sample_rate.saturating_mul(block_align as u32);
    let max_samples = u32::try_from(samples.len().saturating_mul(4))
        .unwrap_or(u32::MAX - 36) as usize
        / 4;
    let data_bytes = (max_samples * 4) as u32;
    let riff_size = 36u32.saturating_add(data_bytes);

    let file = File::create(path)?;
    let mut w = BufWriter::new(file);
    w.write_all(b"RIFF")?;
    w.write_all(&riff_size.to_le_bytes())?;
    w.write_all(b"WAVE")?;
    w.write_all(b"fmt ")?;
    w.write_all(&16u32.to_le_bytes())?;
    w.write_all(&3u16.to_le_bytes())?; // WAVE_FORMAT_IEEE_FLOAT
    w.write_all(&ch.to_le_bytes())?;
    w.write_all(&sample_rate.to_le_bytes())?;
    w.write_all(&byte_rate.to_le_bytes())?;
    w.write_all(&block_align.to_le_bytes())?;
    w.write_all(&bits_per_sample.to_le_bytes())?;
    w.write_all(b"data")?;
    w.write_all(&data_bytes.to_le_bytes())?;
    for &s in &samples[..max_samples] {
        w.write_all(&s.to_le_bytes())?;
    }
    w.flush()
}

/// Off-RT diagnostic capturer gated behind `LUMINA_DUMP_OPUS_WAV=1`.
/// Collects the first 5 seconds of raw Opus-decoded PCM before DSP/resampling/clipping,
/// writes an IEEE Float32 WAV to `%TEMP%`, and logs `max_sample_abs`, `ring_buffer_underrun_count`,
/// and output `(sample_rate, channels, sample_format)`.
struct OpusDiagnosticDumper {
    inner: Arc<PlayerInner>,
    pcm_rate: u32,
    pcm_channels: u16,
    out_sample_rate: u32,
    out_channels: u16,
    out_sample_format: String,
    max_samples: usize,
    samples: Vec<f32>,
    max_sample_abs: f32,
    flushed: bool,
}

impl OpusDiagnosticDumper {
    fn maybe_new(
        codec: AudioCodec,
        inner: &Arc<PlayerInner>,
        out_sample_rate: u32,
        out_channels: u16,
        out_sample_format: String,
    ) -> Option<Self> {
        if codec != AudioCodec::Opus || !is_opus_dump_enabled() {
            return None;
        }
        Some(Self {
            inner: Arc::clone(inner),
            pcm_rate: 0,
            pcm_channels: 0,
            out_sample_rate,
            out_channels,
            out_sample_format,
            max_samples: 0,
            samples: Vec::new(),
            max_sample_abs: 0.0,
            flushed: false,
        })
    }

    fn record_chunk(&mut self, chunk: &AudioChunk) {
        if self.flushed {
            return;
        }
        let AudioChunk::PcmF32 {
            samples,
            channels,
            sample_rate,
        } = chunk
        else {
            return;
        };
        if self.max_samples == 0 {
            let sr = (*sample_rate).max(8_000);
            let ch = (*channels).max(1);
            self.pcm_rate = sr;
            self.pcm_channels = ch;
            self.max_samples = 5usize.saturating_mul(sr as usize).saturating_mul(ch as usize);
            self.samples.reserve(self.max_samples.min(480_000));
        }
        for &s in samples {
            if s.is_finite() {
                let abs = s.abs();
                if abs > self.max_sample_abs {
                    self.max_sample_abs = abs;
                }
            }
        }
        let remaining = self.max_samples.saturating_sub(self.samples.len());
        let to_take = remaining.min(samples.len());
        self.samples.extend_from_slice(&samples[..to_take]);
        if self.samples.len() >= self.max_samples {
            self.flush();
        }
    }

    fn flush(&mut self) {
        if self.flushed {
            return;
        }
        self.flushed = true;
        if self.samples.is_empty() || self.pcm_rate == 0 || self.pcm_channels == 0 {
            return;
        }
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let wav_path = std::env::temp_dir().join(format!(
            "lumina_opus_dump_{}_{}.wav",
            std::process::id(),
            millis
        ));
        let write_res =
            write_ieee_f32_wav(&wav_path, self.pcm_rate, self.pcm_channels, &self.samples);
        let underruns = self.inner.ring_buffer_underrun_count.load(Ordering::Relaxed);
        match write_res {
            Ok(()) => {
                tracing::info!(
                    wav_path = %wav_path.display(),
                    pcm_sample_rate = self.pcm_rate,
                    pcm_channels = self.pcm_channels,
                    dumped_samples = self.samples.len(),
                    max_sample_abs = self.max_sample_abs,
                    ring_buffer_underrun_count = underruns,
                    output_sample_rate = self.out_sample_rate,
                    output_channels = self.out_channels,
                    output_sample_format = %self.out_sample_format,
                    "[LuminaOpusDiag] Opus 5s raw PCM WAV dump completed"
                );
            }
            Err(err) => {
                tracing::warn!(
                    wav_path = %wav_path.display(),
                    error = %err,
                    max_sample_abs = self.max_sample_abs,
                    ring_buffer_underrun_count = underruns,
                    output_sample_rate = self.out_sample_rate,
                    output_channels = self.out_channels,
                    output_sample_format = %self.out_sample_format,
                    "[LuminaOpusDiag] Failed to write Opus WAV dump"
                );
            }
        }
        self.samples.clear();
        self.samples.shrink_to_fit();
    }
}

impl Drop for OpusDiagnosticDumper {
    fn drop(&mut self) {
        self.flush();
    }
}

#[allow(clippy::too_many_arguments)]
fn decode_wire_loop(
    mut decoder: Box<dyn AudioDecoder>,
    mut producer: Producer<u8>,
    mut curr_unified: UnifiedAudioFormat,
    mut curr_neg: NegotiatedFormat,
    curr_caps: AudioDeviceCapabilities,
    verification: AudioVerificationEngine,
    mut ver_cfg: VerificationConfig,
    inner: Arc<PlayerInner>,
    cancel_flag: Arc<AtomicBool>,
    cancel_token: CancellationToken,
    eof_flag: Arc<AtomicBool>,
    fade_ctrl: Arc<AudioFadeControl>,
    watermark_bytes: usize,
    mut expected_stamp: u64,
    session_id: u64,
    cmd_tx: mpsc::Sender<PlayerCommand>,
    mut curr_path: PathBuf,
    mut curr_label: String,
    deck_idx: usize,
    deck_gen: u64,
    mut standby_gate: Option<StandbyDeckGate>,
) -> Option<Box<dyn AudioDecoder>> {
    let mut dop_framer = matches!(curr_neg.wire_format, WireSampleFormat::Dop24In32MsbLe { .. })
        .then(DopFramer::new);
    let mut wire_dsp: Option<DspPipeline> = None;
    let mut wire_dsp_rate: u32 = 0;
    let mut wire_dsp_channels: usize = 0;
    let mut applied_dsp_gen: u64 = 0;
    let mut last_ver_dsp_active = ver_cfg.dsp_active;
    let mut paused_since: Option<Instant> = None;
    let mut idle_reclaimed = false;
    let mut last_logged_underruns = inner.ring_buffer_underrun_count.load(Ordering::Relaxed);
    let mut last_underrun_log_at = Instant::now() - Duration::from_secs(2);
    let mut opus_dumper = OpusDiagnosticDumper::maybe_new(
        curr_unified.codec,
        &inner,
        curr_neg.target_sample_rate,
        curr_neg.target_channels,
        format!("{:?}", curr_neg.wire_format),
    );

    loop {
        maybe_log_underrun_off_rt(
            &inner,
            &mut last_logged_underruns,
            &mut last_underrun_log_at,
        );
        if cancel_flag.load(Ordering::Relaxed)
            || cancel_token.is_cancelled()
            || inner.dual_deck.deck_gen_for(deck_idx) != deck_gen
        {
            return Some(decoder);
        }
        let is_standby = standby_gate.is_some();
        if !is_standby && inner.dual_deck.active_idx() != deck_idx {
            return Some(decoder);
        }
        if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
            return None;
        }
        // If the hardware callback (e.g. ASIO external sample rate change) flagged a format mismatch,
        // request clean device close/reopen without pushing any more bytes into the ring buffer.
        if !is_standby && inner.format_mismatch_flag.load(Ordering::Acquire) {
            let resume_pos_ms = position_ms_from_inner(&inner);
            let _ = cmd_tx.send(PlayerCommand::ReopenForFormatChange {
                session_id,
                new_format: decoder.format().clone(),
                resume_pos_ms,
            });
            return None;
        }

        let req_seek = if is_standby {
            -1
        } else {
            inner.seek_request_ms.swap(-1, Ordering::SeqCst)
        };
        if req_seek >= 0 {
            let target_ms = req_seek as u64;
            let seek_ep = inner.seek_epoch.load(Ordering::Acquire);
            // 1. Start decoder seek immediately in parallel with the callback's 10 ms fade-out.
            if let Err(e) = decoder.seek(Duration::from_millis(target_ms)) {
                if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                    return Some(decoder);
                }
                if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire)
                {
                    return None;
                }
                match e {
                    DecoderError::StreamFormatChanged(new_spec) => {
                        fade_ctrl.notify_seek_ready(seek_ep, inner.paused.load(Ordering::Acquire));
                        inner.is_seeking.store(false, Ordering::SeqCst);
                        let _ = cmd_tx.send(PlayerCommand::HotReloadSpec {
                            session_id,
                            new_spec: *new_spec,
                            resume_ms: target_ms,
                        });
                        return None;
                    }
                    DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    } => {
                        fade_ctrl.notify_seek_ready(seek_ep, true);
                        inner.is_seeking.store(false, Ordering::SeqCst);
                        record_playback_error_with_code(
                            &inner,
                            format!("Authentication required for {provider_id} (HTTP {status})"),
                            Some("AUTH_REQUIRED"),
                            Some(provider_id),
                        );
                        eof_flag.store(true, Ordering::SeqCst);
                        return None;
                    }
                    other => {
                        tracing::warn!("Decoder wire seek to {target_ms} ms failed: {other}");
                        if is_fatal_seek_io_error(&other) {
                            fade_ctrl.notify_seek_ready(seek_ep, true);
                            inner.is_seeking.store(false, Ordering::SeqCst);
                            record_playback_error(&inner, format!("Seek error: {other}"));
                            eof_flag.store(true, Ordering::SeqCst);
                            return None;
                        }
                    }
                }
            }
            if inner.seek_request_ms.load(Ordering::Acquire) >= 0 {
                continue;
            }
            // 2. Bounded wait (<= 15 ms) for callback fade-out to reach 0 before flushing the ring.
            if !inner.paused.load(Ordering::Acquire) && !fade_ctrl.is_fade_out_done() {
                let deadline = Instant::now() + Duration::from_millis(15);
                while !fade_ctrl.is_fade_out_done()
                    && !cancel_flag.load(Ordering::Relaxed)
                    && !cancel_token.is_cancelled()
                    && !inner.stopped.load(Ordering::Relaxed)
                    && !inner.device_lost.load(Ordering::Acquire)
                    && !inner.paused.load(Ordering::Acquire)
                    && inner.seek_request_ms.load(Ordering::Acquire) < 0
                    && Instant::now() < deadline
                {
                    thread::sleep(Duration::from_millis(1));
                }
            }
            if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                return Some(decoder);
            }
            if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
                return None;
            }
            if inner.seek_request_ms.load(Ordering::Acquire) >= 0 {
                continue;
            }
            // 3. Flush ring epoch, reset framer/DSP/verification, pin clock, release seek fade gate.
            producer.request_flush();
            producer.sync_epoch();
            if let Some(ref mut df) = dop_framer {
                df.reset();
            }
            if let Some(ref mut d) = wire_dsp {
                d.reset();
            }
            verification.reset_streams();
            inner.buffered_ms.store(0, Ordering::Relaxed);
            let rate = inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
            inner
                .frames_rendered
                .store(((target_ms as u128) * rate / 1000) as u64, Ordering::SeqCst);
            let is_paused_now = inner.paused.load(Ordering::Acquire);
            fade_ctrl.notify_seek_ready(seek_ep, is_paused_now);
            inner.is_seeking.store(false, Ordering::SeqCst);
            let target_state = if is_paused_now {
                PlaybackLifecycleState::Paused as i32
            } else {
                PlaybackLifecycleState::Playing as i32
            };
            inner.state_code.store(target_state, Ordering::SeqCst);
        }

        if !is_standby {
            maybe_reclaim_idle_memory(
                &inner,
                decoder.as_mut(),
                &mut paused_since,
                &mut idle_reclaimed,
            );

            // Seek-while-paused prefill: fill up to the 200 ms watermark even while paused so
            // subsequent Resume releases immediately without waiting on network/decode latency.
            if inner.paused.load(Ordering::Relaxed) {
                let buffered = producer.capacity().saturating_sub(producer.available_write());
                if buffered >= watermark_bytes {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
            }
        }

        match decoder.next_chunk() {
            Ok(Some(chunk)) => {
                // Producer Format Guard: never pack or push raw PCM bytes that mismatch the open
                // exclusive/ASIO wire format; signal RT silence and trigger safe device reopen.
                if let Some((new_stamp, new_fmt)) =
                    check_wire_chunk_format_mismatch(&chunk, &curr_unified, &curr_neg)
                {
                    tracing::warn!(
                        "Exclusive wire format mismatch detected (expected stamp=0x{expected_stamp:016X}, got 0x{new_stamp:016X}); requesting safe reopen"
                    );
                    inner
                        .published_format_stamp
                        .store(new_stamp, Ordering::Release);
                    inner.format_mismatch_flag.store(true, Ordering::Release);
                    let resume_pos_ms = position_ms_from_inner(&inner);
                    let _ = cmd_tx.send(PlayerCommand::ReopenForFormatChange {
                        session_id,
                        new_format: new_fmt,
                        resume_pos_ms,
                    });
                    return None;
                }

                verification.record_decoder_output(&chunk);
                if let Some(ref mut dumper) = opus_dumper {
                    dumper.record_chunk(&chunk);
                }

                let is_dsd_wire = matches!(
                    curr_neg.wire_format,
                    WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
                );
                let strict_bp = inner
                    .policy
                    .read()
                    .map(|p| p.strict_bit_perfect)
                    .unwrap_or(false);
                let dsp_bypassed = inner.dsp_bypassed.load(Ordering::Relaxed);

                let wire_bytes = if !strict_bp && !dsp_bypassed && !is_dsd_wire {
                    let rate = curr_neg.target_sample_rate.max(8_000);
                    let ch = curr_neg.target_channels.max(1) as usize;
                    let mut recreated = false;
                    if wire_dsp.is_none() || wire_dsp_rate != rate || wire_dsp_channels != ch {
                        wire_dsp = DspPipeline::new(rate as f64, ch).ok();
                        wire_dsp_rate = rate;
                        wire_dsp_channels = ch;
                        recreated = true;
                    }
                    let current_gen = inner.dsp_generation.load(Ordering::Acquire);
                    let mut processed_bytes: Option<Vec<u8>> = None;
                    let mut active_now = false;
                    if let Some(ref mut d) = wire_dsp {
                        if recreated || current_gen != applied_dsp_gen {
                            apply_live_dsp_for_deck(d, &inner, deck_idx);
                            applied_dsp_gen = current_gen;
                        }
                        if d.is_dsp_active() {
                            active_now = true;
                            let mut f64_samples = chunk.to_f64_interleaved();
                            if chunk.channels() != curr_neg.target_channels {
                                f64_samples = adapt_channels_f64(
                                    &f64_samples,
                                    chunk.channels(),
                                    curr_neg.target_channels,
                                );
                            }
                            d.process_interleaved(&mut f64_samples);
                            let processed_chunk = AudioChunk::PcmF64 {
                                samples: f64_samples,
                                channels: curr_neg.target_channels,
                                sample_rate: curr_neg.target_sample_rate,
                            };
                            verification.record_processed_output(&processed_chunk);
                            processed_bytes = Some(pack_chunk_to_wire_bytes(
                                &processed_chunk,
                                curr_neg.wire_format,
                                None,
                            ));
                        }
                    }
                    if active_now != last_ver_dsp_active {
                        ver_cfg.dsp_active = active_now;
                        verification.update_config(ver_cfg.clone());
                        last_ver_dsp_active = active_now;
                    }
                    if let Some(bytes) = processed_bytes {
                        bytes
                    } else if let AudioChunk::PcmF32 {
                        ref samples,
                        channels,
                        sample_rate,
                    } = chunk
                    {
                        // Lossy floating-point streams (AAC/Opus/MP3/Vorbis) can emit inter-sample
                        // peaks slightly exceeding +/-1.0 or non-finite values; sanitize and softly
                        // limit above 0.98 while keeping lossless integer/DSD chunks bit-exact.
                        let needs_safety = samples
                            .iter()
                            .any(|&s| !s.is_finite() || s.abs() > 0.98);
                        if needs_safety {
                            let safe_samples: Vec<f32> = samples
                                .iter()
                                .map(|&s| {
                                    let v = if s.is_finite() { s as f64 } else { 0.0 };
                                    LookaheadLimiter::soft_clip(v, 0.98).clamp(-1.0, 1.0) as f32
                                })
                                .collect();
                            let safe_chunk = AudioChunk::PcmF32 {
                                samples: safe_samples,
                                channels,
                                sample_rate,
                            };
                            verification.record_processed_output(&safe_chunk);
                            pack_chunk_to_wire_bytes(
                                &safe_chunk,
                                curr_neg.wire_format,
                                dop_framer.as_mut(),
                            )
                        } else {
                            verification.record_processed_output(&chunk);
                            pack_chunk_to_wire_bytes(
                                &chunk,
                                curr_neg.wire_format,
                                dop_framer.as_mut(),
                            )
                        }
                    } else {
                        verification.record_processed_output(&chunk);
                        pack_chunk_to_wire_bytes(&chunk, curr_neg.wire_format, dop_framer.as_mut())
                    }
                } else {
                    if last_ver_dsp_active {
                        ver_cfg.dsp_active = false;
                        verification.update_config(ver_cfg.clone());
                        last_ver_dsp_active = false;
                    }
                    verification.record_processed_output(&chunk);
                    pack_chunk_to_wire_bytes(&chunk, curr_neg.wire_format, dop_framer.as_mut())
                };

                let bpf = curr_neg.wire_format.bytes_per_sample().max(1)
                    * (curr_neg.target_channels.max(1) as usize);
                let clock_rate = if matches!(curr_neg.wire_format, WireSampleFormat::NativeDsd { .. })
                {
                    (curr_neg.target_sample_rate / 8).max(44_100) as u64
                } else {
                    curr_neg.target_sample_rate.max(8_000) as u64
                };
                let mut offset = 0;
                while offset < wire_bytes.len()
                    && !cancel_flag.load(Ordering::Relaxed)
                    && !cancel_token.is_cancelled()
                    && inner.dual_deck.deck_gen_for(deck_idx) == deck_gen
                    && !inner.stopped.load(Ordering::Relaxed)
                    && !inner.device_lost.load(Ordering::Acquire)
                    && (standby_gate.is_some() || !inner.format_mismatch_flag.load(Ordering::Acquire))
                {
                    if standby_gate.is_none() {
                        if inner.dual_deck.active_idx() != deck_idx {
                            return Some(decoder);
                        }
                        if inner.seek_request_ms.load(Ordering::Relaxed) >= 0 {
                            break;
                        }
                    }
                    let pushed = producer.push_slice_aligned(&wire_bytes[offset..], bpf);
                    offset += pushed;
                    if pushed > 0 {
                        let buffered =
                            producer.capacity().saturating_sub(producer.available_write());
                        let bms = ((buffered / bpf) as u64 * 1000) / clock_rate;
                        inner.dual_deck.deck_buffered_ms[deck_idx].store(bms, Ordering::Relaxed);
                        if standby_gate.is_some() {
                            inner.dual_deck.standby_buffered_ms.store(bms, Ordering::Relaxed);
                        } else {
                            inner.buffered_ms.store(bms, Ordering::Relaxed);
                        }
                    }
                    if offset < wire_bytes.len() {
                        thread::sleep(Duration::from_millis(4));
                    }
                }
                if let Some(ref mut gate) = standby_gate {
                    let bms = inner.dual_deck.deck_buffered_ms[deck_idx].load(Ordering::Relaxed);
                    if bms >= gate.target_ms {
                        let promoted = gate.complete_prebuffer_and_park(
                            &inner,
                            deck_idx,
                            deck_gen,
                            &cancel_flag,
                            &cancel_token,
                            &eof_flag,
                            false,
                        );
                        standby_gate = None;
                        if !promoted {
                            return Some(decoder);
                        }
                    }
                }
            }
            Ok(None) => {
                if let Some(mut gate) = standby_gate.take() {
                    let promoted = gate.complete_prebuffer_and_park(
                        &inner,
                        deck_idx,
                        deck_gen,
                        &cancel_flag,
                        &cancel_token,
                        &eof_flag,
                        true,
                    );
                    if !promoted {
                        return Some(decoder);
                    }
                }
                // Check Gapless or Format-Switch queued next track
                if let Some((next_stream, next_label)) =
                    inner.queued_next.write().ok().and_then(|mut g| g.take())
                {
                    let next_path = next_stream.display_path();
                    let next_cancel = CancellationToken::new();
                    if let Ok(next_dec) = open_decoder_for_stream_with_token(
                        &next_stream,
                        next_cancel.clone(),
                        Duration::from_secs(10),
                    ) {
                        if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                            return Some(decoder);
                        }
                        if inner.stopped.load(Ordering::Relaxed)
                            || inner.device_lost.load(Ordering::Acquire)
                        {
                            return None;
                        }
                        let next_rg = TrackReplayGainTags::from_stream(&next_stream)
                            .with_metadata_fallback(next_dec.metadata());
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
                            inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
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
                            expected_stamp = WireFormatStamp::from_wire(
                                next_neg.target_sample_rate,
                                next_neg.target_channels,
                                next_neg.wire_format,
                            )
                            .0;
                            curr_path = next_path;
                            curr_label = next_label;
                            curr_unified = next_unified;
                            curr_neg = next_neg;
                            decoder = next_dec;
                            opus_dumper = OpusDiagnosticDumper::maybe_new(
                                curr_unified.codec,
                                &inner,
                                curr_neg.target_sample_rate,
                                curr_neg.target_channels,
                                format!("{:?}", curr_neg.wire_format),
                            );
                            continue;
                        }

                        // Format changed: drain Track A, then re-open output backend for Track B
                        eof_flag.store(true, Ordering::SeqCst);
                        let _ = cmd_tx.send(PlayerCommand::FormatSwitchNext {
                            session_id,
                            decoder: next_dec,
                            path: next_path,
                            source_label: next_label,
                            origin: PlayerOrigin::Legacy(next_stream),
                            cancel_token: next_cancel,
                            rg_tags: next_rg,
                        });
                        return None;
                    }
                }
                let _ = (&curr_path, &curr_label);
                if wait_at_eof(
                    &inner,
                    decoder.as_mut(),
                    &cancel_flag,
                    &eof_flag,
                    &mut paused_since,
                    &mut idle_reclaimed,
                ) {
                    continue;
                }
                return None;
            }
            Err(e) => {
                if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                    return Some(decoder);
                }
                if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire)
                {
                    return None;
                }
                match e {
                    DecoderError::StreamFormatChanged(new_spec) => {
                        let resume_ms = position_ms_from_inner(&inner);
                        let _ = cmd_tx.send(PlayerCommand::HotReloadSpec {
                            session_id,
                            new_spec: *new_spec,
                            resume_ms,
                        });
                        return None;
                    }
                    DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    } => {
                        record_playback_error_with_code(
                            &inner,
                            format!("Authentication required for {provider_id} (HTTP {status})"),
                            Some("AUTH_REQUIRED"),
                            Some(provider_id),
                        );
                        eof_flag.store(true, Ordering::SeqCst);
                        return None;
                    }
                    other => {
                        tracing::error!("Wire audio decode error: {}", other);
                        record_playback_error(&inner, format!("Decode error: {other}"));
                        eof_flag.store(true, Ordering::SeqCst);
                        return None;
                    }
                }
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
    out_sample_format: Option<SampleFormat>,
    inner: Arc<PlayerInner>,
    verification: Option<AudioVerificationEngine>,
    mut curr_unified: UnifiedAudioFormat,
    mut curr_neg: NegotiatedFormat,
    curr_caps: AudioDeviceCapabilities,
    cancel_flag: Arc<AtomicBool>,
    cancel_token: CancellationToken,
    eof_flag: Arc<AtomicBool>,
    fade_ctrl: Arc<AudioFadeControl>,
    watermark_samples: usize,
    session_id: u64,
    cmd_tx: mpsc::Sender<PlayerCommand>,
    deck_idx: usize,
    deck_gen: u64,
    mut standby_gate: Option<StandbyDeckGate>,
) -> Option<Box<dyn AudioDecoder>> {
    let mut dsd_decimator = DsdStereoDecimator::new();
    let mut dsp_channels = out_channels.max(1) as usize;
    let mut dsp_rate = initial_pcm_rate.max(8_000);
    let mut dsp = DspPipeline::new(dsp_rate as f64, dsp_channels).ok();
    let mut resampler = StreamingSincResampler::new(dsp_rate, out_rate.max(8_000), dsp_channels);
    let mut applied_gen = inner.dsp_generation.load(Ordering::Acquire);
    if let Some(ref mut d) = dsp {
        apply_live_dsp_for_deck(d, &inner, deck_idx);
    }
    let mut paused_since: Option<Instant> = None;
    let mut idle_reclaimed = false;
    let mut last_logged_underruns = inner.ring_buffer_underrun_count.load(Ordering::Relaxed);
    let mut last_underrun_log_at = Instant::now() - Duration::from_secs(2);
    let out_fmt_label = out_sample_format
        .map_or_else(|| "Unknown".to_string(), |fmt| format!("{fmt:?}"));
    let mut opus_dumper = OpusDiagnosticDumper::maybe_new(
        curr_unified.codec,
        &inner,
        out_rate,
        out_channels,
        out_fmt_label.clone(),
    );

    loop {
        maybe_log_underrun_off_rt(
            &inner,
            &mut last_logged_underruns,
            &mut last_underrun_log_at,
        );
        if cancel_flag.load(Ordering::Relaxed)
            || cancel_token.is_cancelled()
            || inner.dual_deck.deck_gen_for(deck_idx) != deck_gen
        {
            return Some(decoder);
        }
        let is_standby = standby_gate.is_some();
        if !is_standby && inner.dual_deck.active_idx() != deck_idx {
            return Some(decoder);
        }
        if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
            return None;
        }

        let req_seek = if is_standby {
            -1
        } else {
            inner.seek_request_ms.swap(-1, Ordering::SeqCst)
        };
        if req_seek >= 0 {
            let target_ms = req_seek as u64;
            let seek_ep = inner.seek_epoch.load(Ordering::Acquire);
            // 1. Start decoder seek immediately in parallel with callback's 10 ms fade-out.
            if let Err(e) = decoder.seek(Duration::from_millis(target_ms)) {
                if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                    return Some(decoder);
                }
                if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire)
                {
                    return None;
                }
                match e {
                    DecoderError::StreamFormatChanged(new_spec) => {
                        fade_ctrl.notify_seek_ready(seek_ep, inner.paused.load(Ordering::Acquire));
                        inner.is_seeking.store(false, Ordering::SeqCst);
                        let _ = cmd_tx.send(PlayerCommand::HotReloadSpec {
                            session_id,
                            new_spec: *new_spec,
                            resume_ms: target_ms,
                        });
                        return None;
                    }
                    DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    } => {
                        fade_ctrl.notify_seek_ready(seek_ep, true);
                        inner.is_seeking.store(false, Ordering::SeqCst);
                        record_playback_error_with_code(
                            &inner,
                            format!("Authentication required for {provider_id} (HTTP {status})"),
                            Some("AUTH_REQUIRED"),
                            Some(provider_id),
                        );
                        eof_flag.store(true, Ordering::SeqCst);
                        return None;
                    }
                    other => {
                        tracing::warn!("Decoder seek to {target_ms} ms failed: {other}");
                        if is_fatal_seek_io_error(&other) {
                            fade_ctrl.notify_seek_ready(seek_ep, true);
                            inner.is_seeking.store(false, Ordering::SeqCst);
                            record_playback_error(&inner, format!("Seek error: {other}"));
                            eof_flag.store(true, Ordering::SeqCst);
                            return None;
                        }
                    }
                }
            }
            if inner.seek_request_ms.load(Ordering::Acquire) >= 0 {
                continue;
            }
            // 2. Bounded wait (<= 15 ms) for callback fade-out to finish before flushing ring.
            if !inner.paused.load(Ordering::Acquire) && !fade_ctrl.is_fade_out_done() {
                let deadline = Instant::now() + Duration::from_millis(15);
                while !fade_ctrl.is_fade_out_done()
                    && !cancel_flag.load(Ordering::Relaxed)
                    && !cancel_token.is_cancelled()
                    && !inner.stopped.load(Ordering::Relaxed)
                    && !inner.device_lost.load(Ordering::Acquire)
                    && !inner.paused.load(Ordering::Acquire)
                    && inner.seek_request_ms.load(Ordering::Acquire) < 0
                    && Instant::now() < deadline
                {
                    thread::sleep(Duration::from_millis(1));
                }
            }
            if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                return Some(decoder);
            }
            if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire) {
                return None;
            }
            if inner.seek_request_ms.load(Ordering::Acquire) >= 0 {
                continue;
            }
            // 3. Flush ring epoch, reset decimator/DSP/verification, pin clock, release seek gate.
            producer.request_flush();
            producer.sync_epoch();
            dsd_decimator.reset();
            resampler.reset();
            if let Some(ref mut d) = dsp {
                d.reset();
            }
            if let Some(ref v) = verification {
                v.reset_streams();
            }
            inner.buffered_ms.store(0, Ordering::Relaxed);
            let rate = inner.out_sample_rate.load(Ordering::Relaxed).max(1) as u128;
            inner
                .frames_rendered
                .store(((target_ms as u128) * rate / 1000) as u64, Ordering::SeqCst);
            let is_paused_now = inner.paused.load(Ordering::Acquire);
            fade_ctrl.notify_seek_ready(seek_ep, is_paused_now);
            inner.is_seeking.store(false, Ordering::SeqCst);
            let target_state = if is_paused_now {
                PlaybackLifecycleState::Paused as i32
            } else {
                PlaybackLifecycleState::Playing as i32
            };
            inner.state_code.store(target_state, Ordering::SeqCst);
        }

        if !is_standby {
            maybe_reclaim_idle_memory(
                &inner,
                decoder.as_mut(),
                &mut paused_since,
                &mut idle_reclaimed,
            );

            // Seek-while-paused prefill: decode up to the 200 ms watermark even while paused.
            if inner.paused.load(Ordering::Relaxed) {
                let buffered = producer.capacity().saturating_sub(producer.available_write());
                if buffered >= watermark_samples {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
            }
        }

        match decoder.next_chunk() {
            Ok(Some(chunk)) => {
                if let Some(ref v) = verification {
                    v.record_decoder_output(&chunk);
                }
                if let Some(ref mut dumper) = opus_dumper {
                    dumper.record_chunk(&chunk);
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
                        apply_live_dsp_for_deck(d, &inner, deck_idx);
                        applied_gen = current_gen;
                    }
                    d.set_bypass(inner.dsp_bypassed.load(Ordering::Relaxed));
                    d.process_interleaved(&mut f64_samples);
                }

                resampler.ensure_config(chunk_pcm_rate, out_rate.max(8_000), out_channels as usize);
                let resampled = resampler.process(&f64_samples);
                let f32_buf: Vec<f32> = resampled
                    .into_iter()
                    .map(|s| {
                        let finite = if s.is_finite() { s } else { 0.0 };
                        LookaheadLimiter::soft_clip(finite, 0.98).clamp(-1.0, 1.0) as f32
                    })
                    .collect();
                if let Some(ref v) = verification {
                    v.record_processed_output(&AudioChunk::PcmF32 {
                        samples: f32_buf.clone(),
                        channels: out_channels,
                        sample_rate: out_rate,
                    });
                }

                let out_ch = out_channels.max(1) as usize;
                let out_rate_u64 = out_rate.max(8_000) as u64;
                let mut offset = 0;
                while offset < f32_buf.len()
                    && !cancel_flag.load(Ordering::Relaxed)
                    && !cancel_token.is_cancelled()
                    && inner.dual_deck.deck_gen_for(deck_idx) == deck_gen
                    && !inner.stopped.load(Ordering::Relaxed)
                    && !inner.device_lost.load(Ordering::Acquire)
                {
                    if standby_gate.is_none() {
                        if inner.dual_deck.active_idx() != deck_idx {
                            return Some(decoder);
                        }
                        if inner.seek_request_ms.load(Ordering::Relaxed) >= 0 {
                            break;
                        }
                    }
                    let pushed = producer.push_slice_aligned(&f32_buf[offset..], out_ch);
                    offset += pushed;
                    if pushed > 0 {
                        let buffered =
                            producer.capacity().saturating_sub(producer.available_write());
                        let bms = ((buffered / out_ch) as u64 * 1000) / out_rate_u64;
                        inner.dual_deck.deck_buffered_ms[deck_idx].store(bms, Ordering::Relaxed);
                        if standby_gate.is_some() {
                            inner.dual_deck.standby_buffered_ms.store(bms, Ordering::Relaxed);
                        } else {
                            inner.buffered_ms.store(bms, Ordering::Relaxed);
                        }
                    }
                    if offset < f32_buf.len() {
                        thread::sleep(Duration::from_millis(5));
                    }
                }
                if let Some(ref mut gate) = standby_gate {
                    let bms = inner.dual_deck.deck_buffered_ms[deck_idx].load(Ordering::Relaxed);
                    if bms >= gate.target_ms {
                        let promoted = gate.complete_prebuffer_and_park(
                            &inner,
                            deck_idx,
                            deck_gen,
                            &cancel_flag,
                            &cancel_token,
                            &eof_flag,
                            false,
                        );
                        standby_gate = None;
                        if !promoted {
                            return Some(decoder);
                        }
                    }
                }
            }
            Ok(None) => {
                // Flush any remaining windowed-sinc resampler tail frames before EOF so
                // total output length stays exact without trailing truncation.
                let tail = resampler.flush();
                if !tail.is_empty() {
                    let tail_f32: Vec<f32> = tail
                        .into_iter()
                        .map(|s| {
                            let finite = if s.is_finite() { s } else { 0.0 };
                            LookaheadLimiter::soft_clip(finite, 0.98).clamp(-1.0, 1.0) as f32
                        })
                        .collect();
                    if let Some(ref v) = verification {
                        v.record_processed_output(&AudioChunk::PcmF32 {
                            samples: tail_f32.clone(),
                            channels: out_channels,
                            sample_rate: out_rate,
                        });
                    }
                    let out_ch = out_channels.max(1) as usize;
                    let out_rate_u64 = out_rate.max(8_000) as u64;
                    let mut offset = 0;
                    while offset < tail_f32.len()
                        && !cancel_flag.load(Ordering::Relaxed)
                        && !cancel_token.is_cancelled()
                        && inner.dual_deck.deck_gen_for(deck_idx) == deck_gen
                        && !inner.stopped.load(Ordering::Relaxed)
                        && !inner.device_lost.load(Ordering::Acquire)
                    {
                        if standby_gate.is_none()
                            && (inner.dual_deck.active_idx() != deck_idx
                                || inner.seek_request_ms.load(Ordering::Relaxed) >= 0)
                        {
                            break;
                        }
                        let pushed = producer.push_slice_aligned(&tail_f32[offset..], out_ch);
                        offset += pushed;
                        if pushed > 0 {
                            let buffered =
                                producer.capacity().saturating_sub(producer.available_write());
                            let bms = ((buffered / out_ch) as u64 * 1000) / out_rate_u64;
                            inner.dual_deck.deck_buffered_ms[deck_idx]
                                .store(bms, Ordering::Relaxed);
                            if standby_gate.is_some() {
                                inner.dual_deck.standby_buffered_ms.store(bms, Ordering::Relaxed);
                            } else {
                                inner.buffered_ms.store(bms, Ordering::Relaxed);
                            }
                        }
                        if offset < tail_f32.len() {
                            thread::sleep(Duration::from_millis(5));
                        }
                    }
                }
                if let Some(mut gate) = standby_gate.take() {
                    let promoted = gate.complete_prebuffer_and_park(
                        &inner,
                        deck_idx,
                        deck_gen,
                        &cancel_flag,
                        &cancel_token,
                        &eof_flag,
                        true,
                    );
                    if !promoted {
                        return Some(decoder);
                    }
                }
                if let Some((next_stream, next_label)) =
                    inner.queued_next.write().ok().and_then(|mut g| g.take())
                {
                    let next_path = next_stream.display_path();
                    let next_cancel = CancellationToken::new();
                    if let Ok(next_dec) = open_decoder_for_stream_with_token(
                        &next_stream,
                        next_cancel.clone(),
                        Duration::from_secs(10),
                    ) {
                        if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                            return Some(decoder);
                        }
                        if inner.stopped.load(Ordering::Relaxed)
                            || inner.device_lost.load(Ordering::Acquire)
                        {
                            return None;
                        }
                        let next_rg = TrackReplayGainTags::from_stream(&next_stream)
                            .with_metadata_fallback(next_dec.metadata());
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
                            inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
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
                            resampler.reset();
                            opus_dumper = OpusDiagnosticDumper::maybe_new(
                                curr_unified.codec,
                                &inner,
                                out_rate,
                                out_channels,
                                out_fmt_label.clone(),
                            );
                            continue;
                        }

                        eof_flag.store(true, Ordering::SeqCst);
                        let _ = cmd_tx.send(PlayerCommand::FormatSwitchNext {
                            session_id,
                            decoder: next_dec,
                            path: next_path,
                            source_label: next_label,
                            origin: PlayerOrigin::Legacy(next_stream),
                            cancel_token: next_cancel,
                            rg_tags: next_rg,
                        });
                        return None;
                    }
                }
                if wait_at_eof(
                    &inner,
                    decoder.as_mut(),
                    &cancel_flag,
                    &eof_flag,
                    &mut paused_since,
                    &mut idle_reclaimed,
                ) {
                    continue;
                }
                return None;
            }
            Err(e) => {
                if cancel_flag.load(Ordering::Relaxed) || cancel_token.is_cancelled() {
                    return Some(decoder);
                }
                if inner.stopped.load(Ordering::Relaxed) || inner.device_lost.load(Ordering::Acquire)
                {
                    return None;
                }
                match e {
                    DecoderError::StreamFormatChanged(new_spec) => {
                        let resume_ms = position_ms_from_inner(&inner);
                        let _ = cmd_tx.send(PlayerCommand::HotReloadSpec {
                            session_id,
                            new_spec: *new_spec,
                            resume_ms,
                        });
                        return None;
                    }
                    DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    } => {
                        record_playback_error_with_code(
                            &inner,
                            format!("Authentication required for {provider_id} (HTTP {status})"),
                            Some("AUTH_REQUIRED"),
                            Some(provider_id),
                        );
                        eof_flag.store(true, Ordering::SeqCst);
                        return None;
                    }
                    other => {
                        tracing::error!("Audio decode error: {}", other);
                        record_playback_error(&inner, format!("Decode error: {other}"));
                        eof_flag.store(true, Ordering::SeqCst);
                        return None;
                    }
                }
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

/// Non-RT throttled logger for audio ring-buffer underruns (at most once per second).
///
/// Called exclusively from background decode threads — NEVER from audio output callbacks.
fn maybe_log_underrun_off_rt(
    inner: &PlayerInner,
    last_logged_count: &mut u64,
    last_logged_at: &mut Instant,
) {
    let count = inner.ring_buffer_underrun_count.load(Ordering::Relaxed);
    if count > *last_logged_count && last_logged_at.elapsed() >= Duration::from_secs(1) {
        let delta = count - *last_logged_count;
        let bms = inner.buffered_ms.load(Ordering::Relaxed);
        *last_logged_count = count;
        *last_logged_at = Instant::now();
        tracing::warn!(
            ring_buffer_underrun_count = count,
            underrun_delta = delta,
            buffered_ms = bms,
            "[LuminaAudio] Audio ring buffer underrun detected"
        );
        eprintln!(
            "[LuminaAudio] ring_buffer_underrun_count={count} (+{delta}) buffered_ms={bms}"
        );
    }
}

/// Stateful, continuous-phase 24-tap Lanczos-12 windowed-sinc streaming resampler.
///
/// Eliminates chunk-boundary phase jumps, rate-ratio rounding drift, and aliasing
/// distortion when resampling streaming audio (e.g. 44.1 kHz M4A/AAC <-> 48 kHz Opus/WASAPI).
/// When `in_rate == out_rate`, operates as a zero-overhead passthrough.
#[derive(Debug, Clone)]
pub struct StreamingSincResampler {
    in_rate: u32,
    out_rate: u32,
    channels: usize,
    step: f64,
    cutoff: f64,
    phase: f64,
    history: Vec<f64>,
}

impl StreamingSincResampler {
    /// Half-width of the Lanczos windowed-sinc kernel (24 taps total per output frame).
    pub const HALF_TAPS: usize = 12;

    pub fn new(in_rate: u32, out_rate: u32, channels: usize) -> Self {
        let mut r = Self {
            in_rate: in_rate.max(8_000),
            out_rate: out_rate.max(8_000),
            channels: channels.max(1),
            step: 1.0,
            cutoff: 0.95,
            phase: Self::HALF_TAPS as f64,
            history: Vec::new(),
        };
        r.reset();
        r
    }

    /// Reconfigures and resets history if sample rates or channel count changed.
    pub fn ensure_config(&mut self, in_rate: u32, out_rate: u32, channels: usize) {
        let ir = in_rate.max(8_000);
        let or = out_rate.max(8_000);
        let ch = channels.max(1);
        if self.in_rate != ir || self.out_rate != or || self.channels != ch {
            self.in_rate = ir;
            self.out_rate = or;
            self.channels = ch;
            self.reset();
        }
    }

    /// Resets internal phase and causal zero-padding history (call on seek or track switch).
    pub fn reset(&mut self) {
        self.step = (self.in_rate as f64) / (self.out_rate as f64);
        // Apply anti-aliasing low-pass cutoff below target Nyquist on downsampling
        // and keep flat audible passband (20 Hz - 19+ kHz) on upsampling.
        self.cutoff = if self.out_rate < self.in_rate {
            ((self.out_rate as f64) / (self.in_rate as f64)) * 0.92
        } else {
            0.95
        };
        self.history.clear();
        self.phase = Self::HALF_TAPS as f64;
        if self.in_rate != self.out_rate {
            self.history.resize(Self::HALF_TAPS * self.channels, 0.0);
        }
    }

    #[inline(always)]
    fn sinc(x: f64) -> f64 {
        if x.abs() < 1e-9 {
            1.0
        } else {
            let px = std::f64::consts::PI * x;
            px.sin() / px
        }
    }

    /// Processes an interleaved `f64` input chunk, maintaining exact fractional phase
    /// and rolling sample history across arbitrary chunk boundaries.
    pub fn process(&mut self, input: &[f64]) -> Vec<f64> {
        if input.is_empty() || self.channels == 0 {
            return Vec::new();
        }
        if self.in_rate == self.out_rate {
            return input.to_vec();
        }
        let ch = self.channels;
        let aligned_len = (input.len() / ch) * ch;
        if aligned_len == 0 {
            return Vec::new();
        }
        self.history.extend_from_slice(&input[..aligned_len]);
        self.emit_available()
    }

    /// Flushes remaining buffered frames at EOF by appending causal right-side zero padding.
    pub fn flush(&mut self) -> Vec<f64> {
        if self.in_rate == self.out_rate || self.channels == 0 {
            return Vec::new();
        }
        let ch = self.channels;
        let current_frames = self.history.len() / ch;
        if current_frames <= Self::HALF_TAPS {
            self.reset();
            return Vec::new();
        }
        self.history
            .resize((current_frames + Self::HALF_TAPS) * ch, 0.0);
        let out = self.emit_available();
        self.reset();
        out
    }

    fn emit_available(&mut self) -> Vec<f64> {
        let ch = self.channels;
        let total_frames = self.history.len() / ch;
        let half = Self::HALF_TAPS;
        if total_frames <= 2 * half {
            return Vec::new();
        }
        let max_center = total_frames - half;
        let est_frames = (((max_center as f64 - self.phase).max(0.0)) / self.step).ceil() as usize;
        let mut out = Vec::with_capacity(est_frames.saturating_add(2) * ch);
        let a = half as f64;
        let cutoff = self.cutoff;

        // Precompute tap weights once per output frame and reuse across all channels.
        let mut weights = [0.0f64; Self::HALF_TAPS * 2];

        loop {
            let center = self.phase.floor() as usize;
            if center + half >= total_frames {
                break;
            }
            let start_k = center + 1 - half;
            let mut w_sum = 0.0f64;
            for (t, w_slot) in weights.iter_mut().enumerate() {
                let k = start_k + t;
                let d = self.phase - (k as f64);
                let w = if d.abs() < a {
                    Self::sinc(d * cutoff) * Self::sinc(d / a)
                } else {
                    0.0
                };
                *w_slot = w;
                w_sum += w;
            }
            let inv_w_sum = if w_sum.abs() > 1e-12 {
                1.0 / w_sum
            } else {
                0.0
            };

            if ch <= 8 {
                let mut acc = [0.0f64; 8];
                for (t, &w) in weights.iter().enumerate() {
                    if w == 0.0 {
                        continue;
                    }
                    let base = (start_k + t) * ch;
                    for c in 0..ch {
                        acc[c] += self.history[base + c] * w;
                    }
                }
                for c in 0..ch {
                    out.push(acc[c] * inv_w_sum);
                }
            } else {
                let out_start = out.len();
                out.resize(out_start + ch, 0.0);
                for (t, &w) in weights.iter().enumerate() {
                    if w == 0.0 {
                        continue;
                    }
                    let base = (start_k + t) * ch;
                    for c in 0..ch {
                        out[out_start + c] += self.history[base + c] * w;
                    }
                }
                for s in &mut out[out_start..out_start + ch] {
                    *s *= inv_w_sum;
                }
            }

            self.phase += self.step;
        }

        // Discard input frames strictly before the earliest tap required for the next output frame.
        let next_center = self.phase.floor() as usize;
        let keep_from = next_center.saturating_sub(half - 1);
        if keep_from > 0 {
            let drain_samples = (keep_from * ch).min(self.history.len());
            self.history.drain(..drain_samples);
            self.phase -= (drain_samples / ch) as f64;
        }

        out
    }
}

#[allow(clippy::too_many_arguments)]
fn spawn_virtual_wire_consumer(
    mut feeder: DualDeckWireFeeder,
    wire: WireSampleFormat,
    out_rate: u32,
    out_channels: u16,
    inner: Arc<PlayerInner>,
    output_kill_flag: Arc<AtomicBool>,
    session_id: u64,
    watermark_bytes: usize,
    fade_ctrl: Arc<AudioFadeControl>,
    expected_format_stamp: u64,
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
            let mut buffering_gate = watermark_bytes > 0;
            let mut dop_phase = false;
            let mut fade = LinearFadeState::new(
                clock_rate,
                fade_ctrl.fade_in_enabled(),
                fade_ctrl.fade_out_enabled(),
                inner.paused.load(Ordering::Acquire),
            );

            loop {
                if output_kill_flag.load(Ordering::Acquire) {
                    break;
                }

                thread::sleep(Duration::from_millis(5));
                let now = Instant::now();
                let dt = now.duration_since(last_tick).as_secs_f64();
                last_tick = now;

                if output_kill_flag.load(Ordering::Acquire) {
                    break;
                }

                feeder.poll_inbox();

                // RT Format-Mismatch Silence Guard: never output mismatched PCM bytes
                let stamp_mismatch = expected_format_stamp != 0
                    && inner.published_format_stamp.load(Ordering::Acquire)
                        != expected_format_stamp;
                if inner.format_mismatch_flag.load(Ordering::Acquire) || stamp_mismatch {
                    if stamp_mismatch {
                        inner.format_mismatch_flag.store(true, Ordering::Release);
                    }
                    scratch.fill(sil_byte);
                    fade_ctrl.mark_silent();
                    continue;
                }

                let fade_target = fade_ctrl.target();
                if matches!(
                    fade_target,
                    FadeTarget::PauseFadeOut | FadeTarget::StopFadeOut | FadeTarget::SeekFadeOut
                ) {
                    if !fade.fade_out_enabled() || fade.gain() <= 0.0 {
                        fade.set_zero();
                        fade_ctrl.mark_fade_out_done();
                        if fade_target == FadeTarget::SeekFadeOut {
                            buffering_gate = feeder.active_watermark_bytes() > 0;
                        }
                        if fade_target == FadeTarget::StopFadeOut {
                            break;
                        }
                        continue;
                    }
                    frac_frames += dt * (clock_rate as f64);
                    let frames_needed = frac_frames.floor() as usize;
                    frac_frames -= frames_needed as f64;
                    let bytes_needed = ((frames_needed * bpf).min(scratch.len()) / bpf) * bpf;
                    if bytes_needed > 0 {
                        let popped = feeder.pop_active_raw(&mut scratch[..bytes_needed]);
                        let aligned = (popped / bpf) * bpf;
                        if aligned > 0 {
                            apply_fade_ramp_to_wire_bytes(
                                &mut scratch[..aligned],
                                wire,
                                ch,
                                &mut fade,
                                FadeDirection::Down,
                            );
                        } else {
                            fade.set_zero();
                        }
                        if fade.gain() <= 0.0 {
                            fade_ctrl.mark_fade_out_done();
                            if fade_target == FadeTarget::SeekFadeOut {
                                buffering_gate = feeder.active_watermark_bytes() > 0;
                            }
                            if fade_target == FadeTarget::StopFadeOut {
                                break;
                            }
                        }
                    }
                    continue;
                }

                if inner.stopped.load(Ordering::Relaxed)
                    || inner.current_session_id.load(Ordering::Relaxed) != session_id
                {
                    break;
                }
                if inner.paused.load(Ordering::Relaxed) {
                    continue;
                }

                let (req_ep, last_ep) = feeder.active_epoch_pair();
                if req_ep != last_ep {
                    let wm = feeder.sync_active_epoch();
                    buffering_gate = wm > 0;
                    fade.reset_for_play_start();
                }

                feeder.update_active_buffered_ms(bpf);
                let avail_before = feeder.active_available_read();

                if buffering_gate {
                    if avail_before >= feeder.active_watermark_bytes()
                        || feeder.active_eof_reached()
                        || inner.dual_deck.skip_request_seq.load(Ordering::Acquire)
                            != inner.dual_deck.skip_handled_seq.load(Ordering::Acquire)
                    {
                        buffering_gate = false;
                    } else {
                        continue;
                    }
                }

                frac_frames += dt * (clock_rate as f64);
                let frames_needed = frac_frames.floor() as usize;
                frac_frames -= frames_needed as f64;

                let bytes_needed = ((frames_needed * bpf).min(scratch.len()) / bpf) * bpf;
                if bytes_needed > 0 {
                    match feeder.pop_wire_period(
                        &mut scratch[..bytes_needed],
                        bpf,
                        &mut fade,
                        Some(&fade_ctrl),
                        &mut dop_phase,
                        &mut buffering_gate,
                    ) {
                        DualDeckWireOutcome::Rendered { .. }
                        | DualDeckWireOutcome::CrossRateDraining => {}
                        DualDeckWireOutcome::EofEmpty => {
                            fade_ctrl.mark_silent();
                            let _ = inner.state_code.compare_exchange(
                                PlaybackLifecycleState::Playing as i32,
                                PlaybackLifecycleState::Ended as i32,
                                Ordering::SeqCst,
                                Ordering::SeqCst,
                            );
                            break;
                        }
                        DualDeckWireOutcome::Underrun => {
                            if feeder.active_watermark_bytes() > 0 {
                                buffering_gate = true;
                                fade.reset_for_play_start();
                            }
                        }
                    }
                }
            }
            fade_ctrl.mark_silent();
        })
        .expect("spawn virtual wire dac thread")
}

#[allow(clippy::too_many_arguments)]
fn spawn_virtual_consumer(
    mut feeder: DualDeckPcmFeeder,
    out_rate: u32,
    out_channels: u16,
    inner: Arc<PlayerInner>,
    output_kill_flag: Arc<AtomicBool>,
    session_id: u64,
    fade_ctrl: Arc<AudioFadeControl>,
) -> JoinHandle<()> {
    let ch = out_channels.max(1) as usize;
    thread::Builder::new()
        .name("lumina-virtual-dac".to_string())
        .spawn(move || {
            let mut last_tick = Instant::now();
            let mut drain_buf = vec![0.0f32; 4096 * ch];
            let mut wire_bytes = vec![0u8; 4096 * ch * 4];
            let mut frac_frames = 0.0f64;

            loop {
                if output_kill_flag.load(Ordering::Acquire) {
                    break;
                }

                thread::sleep(Duration::from_millis(5));
                let now = Instant::now();
                let dt = now.duration_since(last_tick).as_secs_f64();
                last_tick = now;

                if output_kill_flag.load(Ordering::Acquire) {
                    break;
                }

                if inner.stopped.load(Ordering::Relaxed)
                    || inner.current_session_id.load(Ordering::Relaxed) != session_id
                {
                    break;
                }

                frac_frames += dt * (out_rate as f64);
                let frames_needed = frac_frames.floor().max(1.0) as usize;
                frac_frames = (frac_frames - frames_needed as f64).max(0.0);

                let samples_needed = ((frames_needed * ch).min(drain_buf.len()) / ch) * ch;
                if samples_needed > 0 {
                    let outcome = feeder.render_f32(
                        &mut drain_buf[..samples_needed],
                        &mut wire_bytes[..samples_needed * 4],
                        &fade_ctrl,
                        1.0,
                    );
                    if fade_ctrl.target() == FadeTarget::StopFadeOut
                        && fade_ctrl.is_fade_out_done()
                    {
                        break;
                    }
                    if outcome == PcmRenderOutcome::Ended {
                        fade_ctrl.mark_silent();
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
            fade_ctrl.mark_silent();
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

#[allow(clippy::type_complexity, clippy::too_many_arguments)]
fn open_cpal_output(
    desired_rate: u32,
    desired_channels: u16,
    inner: &Arc<PlayerInner>,
    verification: Option<&AudioVerificationEngine>,
    output_kill_flag: &Arc<AtomicBool>,
    active_deck: usize,
    active_gen: u64,
    session_id: u64,
    fade_ctrl: &Arc<AudioFadeControl>,
) -> Result<
    (
        cpal::Stream,
        Producer<f32>,
        u32,
        u16,
        SampleFormat,
        OutputBackendKind,
        String,
        usize,
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
    let ring_samples = compute_pcm_ring_samples(out_rate, out_channels);
    let (producer, consumer) = SpscRingBuffer::<f32>::new(ring_samples);
    let watermark_samples =
        compute_startup_watermark_samples(out_rate, out_channels, producer.capacity());
    let ver_tap = verification
        .map(|v| v.attach_rt_tap(WireSampleFormat::Float32Le, out_channels, out_rate, 1024 * 1024));
    let last_ring_epoch = consumer.epoch();
    let payload = RtPcmInboxPayload {
        consumer,
        ver_tap,
        watermark_samples,
        out_rate,
        out_channels,
        deck_gen: active_gen,
        last_ring_epoch,
    };
    let feeder = DualDeckPcmFeeder::new(
        Arc::clone(&inner.dual_deck),
        Arc::clone(inner),
        session_id,
        active_deck,
        payload,
        fade_ctrl,
    );

    let stream = build_cpal_stream_for_format(
        &device,
        sample_format,
        stream_config,
        feeder,
        inner,
        output_kill_flag,
        fade_ctrl,
        &dev_name,
    )?;

    Ok((
        stream,
        producer,
        out_rate,
        out_channels,
        sample_format,
        backend_kind,
        dev_name,
        watermark_samples,
    ))
}

#[allow(clippy::type_complexity)]
fn open_cpal_output_with_payload(
    active_deck: usize,
    payload: RtPcmInboxPayload,
    inner: &Arc<PlayerInner>,
    output_kill_flag: &Arc<AtomicBool>,
    session_id: u64,
    fade_ctrl: &Arc<AudioFadeControl>,
) -> Result<(cpal::Stream, u32, u16, SampleFormat, OutputBackendKind, String), CoreAudioError> {
    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let (device, backend_kind, dev_name) =
        resolve_cpal_device(sel_id.as_deref(), sel_backend)?;
    let selected_config =
        select_output_config(&device, payload.out_rate, payload.out_channels)?;
    let sample_format = selected_config.sample_format();
    let out_rate = selected_config.sample_rate();
    let out_channels = selected_config.channels();
    if out_rate != payload.out_rate || out_channels != payload.out_channels {
        return Err(CoreAudioError::Backend(BackendError::InvalidState(format!(
            "Standby PCM format mismatch with cpal output device: standby={}Hz/{}ch vs device={}Hz/{}ch",
            payload.out_rate, payload.out_channels, out_rate, out_channels
        ))));
    }
    let stream_config: cpal::StreamConfig = selected_config.into();
    let feeder = DualDeckPcmFeeder::new(
        Arc::clone(&inner.dual_deck),
        Arc::clone(inner),
        session_id,
        active_deck,
        payload,
        fade_ctrl,
    );
    let stream = build_cpal_stream_for_format(
        &device,
        sample_format,
        stream_config,
        feeder,
        inner,
        output_kill_flag,
        fade_ctrl,
        &dev_name,
    )?;
    Ok((
        stream,
        out_rate,
        out_channels,
        sample_format,
        backend_kind,
        dev_name,
    ))
}

#[allow(clippy::too_many_arguments)]
fn build_cpal_stream_for_format(
    device: &cpal::Device,
    sample_format: SampleFormat,
    stream_config: cpal::StreamConfig,
    feeder: DualDeckPcmFeeder,
    inner: &Arc<PlayerInner>,
    output_kill_flag: &Arc<AtomicBool>,
    fade_ctrl: &Arc<AudioFadeControl>,
    dev_name: &str,
) -> Result<cpal::Stream, CoreAudioError> {
    let stream_res = match sample_format {
        SampleFormat::F32 => build_cpal_typed_stream::<f32>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::F64 => build_cpal_typed_stream::<f64>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::I32 => build_cpal_typed_stream::<i32>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::I24 => build_cpal_typed_stream::<cpal::I24>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::I16 => build_cpal_typed_stream::<i16>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::U16 => build_cpal_typed_stream::<u16>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::U8 => build_cpal_typed_stream::<u8>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        other => {
            return Err(CoreAudioError::Backend(BackendError::DriverError(format!(
                "Unsupported cpal output sample format: {other:?}"
            ))));
        }
    };

    stream_res.map_err(|e| {
        CoreAudioError::Backend(BackendError::DriverError(format!(
            "Failed to build cpal output stream for '{dev_name}': {e}"
        )))
    })
}

#[allow(clippy::too_many_arguments)]
fn build_cpal_typed_stream<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    mut feeder: DualDeckPcmFeeder,
    inner: Arc<PlayerInner>,
    output_kill_flag: Arc<AtomicBool>,
    fade_ctrl: Arc<AudioFadeControl>,
) -> Result<cpal::Stream, cpal::Error>
where
    T: SizedSample + FromSample<f32>,
{
    let ch = config.channels.max(1) as usize;
    let max_pos = if T::FORMAT.is_float() {
        1.0_f32
    } else {
        // dasp_sample 0.11 requires -1.0 <= s < 1.0 for float-to-integer conversions
        0.99999994_f32
    };
    let err_inner = Arc::clone(&inner);

    device.build_output_stream(
        config,
        move |output: &mut [T], _| {
            // Strictly real-time safe: ZERO mutex locks, ZERO heap allocations, ZERO I/O.
            if output_kill_flag.load(Ordering::Acquire) {
                output.fill(T::EQUILIBRIUM);
                return;
            }

            let mut stack_f32 = [0.0f32; 2048];
            let mut stack_wire = [0u8; 8192];
            let chunk_cap = ((stack_f32.len() / ch) * ch).max(1).min(stack_f32.len());
            let total_samples = (output.len() / ch) * ch;
            let mut written = 0usize;

            while written < total_samples {
                let want = (total_samples - written).min(chunk_cap);
                let outcome = feeder.render_f32(
                    &mut stack_f32[..want],
                    &mut stack_wire[..want * 4],
                    &fade_ctrl,
                    max_pos,
                );
                for i in 0..want {
                    output[written + i] = T::from_sample(stack_f32[i]);
                }
                written += want;
                if outcome == PcmRenderOutcome::Ended {
                    fade_ctrl.mark_silent();
                    let _ = inner.state_code.compare_exchange(
                        PlaybackLifecycleState::Playing as i32,
                        PlaybackLifecycleState::Ended as i32,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                    break;
                }
                if outcome != PcmRenderOutcome::Rendered {
                    break;
                }
            }
            if written < output.len() {
                output[written..].fill(T::EQUILIBRIUM);
            }
        },
        move |_err| {
            // Strictly lock-free, allocation-free, log-free on the cpal audio thread:
            // relay_loop observes `cpal_stream_error_flag` off-RT and populates error metadata.
            err_inner.device_lost.store(true, Ordering::SeqCst);
            err_inner
                .cpal_stream_error_flag
                .store(true, Ordering::Release);
            err_inner
                .state_code
                .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
            err_inner.dual_deck.unpark_relay();
        },
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::{is_fatal_seek_io_error, AudioPlayer};
    use crate::error::DecoderError;
    use crate::stream::StreamSource;
    use core_types::{DeckId, DeckState, StreamKey, StreamSourceSpec};
    use std::io::{Error, ErrorKind, Write};
    use std::time::{Duration, Instant};

    fn write_test_wav_16bit(path: &std::path::Path, sample_rate: u32, duration_ms: u64, freq_hz: f64) {
        let channels: u16 = 2;
        let total_frames = ((sample_rate as u64 * duration_ms) / 1000) as u32;
        let data_bytes = total_frames * (channels as u32) * 2;
        let mut buf = Vec::with_capacity(44 + data_bytes as usize);
        buf.extend_from_slice(b"RIFF");
        buf.extend_from_slice(&(36 + data_bytes).to_le_bytes());
        buf.extend_from_slice(b"WAVEfmt ");
        buf.extend_from_slice(&16u32.to_le_bytes());
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&channels.to_le_bytes());
        buf.extend_from_slice(&sample_rate.to_le_bytes());
        let byte_rate = sample_rate * (channels as u32) * 2;
        buf.extend_from_slice(&byte_rate.to_le_bytes());
        let block_align = channels * 2;
        buf.extend_from_slice(&block_align.to_le_bytes());
        buf.extend_from_slice(&16u16.to_le_bytes());
        buf.extend_from_slice(b"data");
        buf.extend_from_slice(&data_bytes.to_le_bytes());
        for f in 0..total_frames {
            let t = (f as f64) / (sample_rate as f64);
            let s = ((2.0 * std::f64::consts::PI * freq_hz * t).sin() * 12000.0) as i16;
            let b = s.to_le_bytes();
            buf.extend_from_slice(&b);
            buf.extend_from_slice(&b);
        }
        let mut file = std::fs::File::create(path).expect("create test wav");
        file.write_all(&buf).expect("write test wav");
    }

    fn make_synth_stream(
        track_id: &str,
        title: &str,
        duration_ms: u64,
        rate: u32,
        ch: u16,
    ) -> StreamSource {
        let mut s = StreamSource::synth(track_id, title, duration_ms);
        if let crate::stream::StreamOrigin::Synth {
            ref mut sample_rate_hz,
            ref mut channels,
            ..
        } = s.origin
        {
            *sample_rate_hz = rate;
            *channels = ch;
        }
        s
    }

    fn wait_for_standby_ready(player: &AudioPlayer, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            let sb = player.standby_deck();
            if player.deck_state(sb) == DeckState::StandbyReady {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        player.deck_state(player.standby_deck()) == DeckState::StandbyReady
    }

    #[test]
    fn non_seekable_unsupported_seek_errors_are_not_fatal() {
        let unsupported = DecoderError::Io(Error::new(
            ErrorKind::Unsupported,
            "Backward seek past retained buffer on non-range HTTP stream",
        ));
        assert!(!is_fatal_seek_io_error(&unsupported));

        let wrapped_unsupported = DecoderError::SeekError(
            "Backward seek past retained buffer on non-range HTTP stream (unsupported)".to_string(),
        );
        assert!(!is_fatal_seek_io_error(&wrapped_unsupported));

        let wrapped_end_unsupported = DecoderError::SeekError(
            "SeekFrom::End unsupported on unseekable HTTP stream without Content-Length"
                .to_string(),
        );
        assert!(!is_fatal_seek_io_error(&wrapped_end_unsupported));

        let http_403_io = DecoderError::Io(Error::new(
            ErrorKind::PermissionDenied,
            "HTTP 403 fetching https://example.com/track",
        ));
        assert!(is_fatal_seek_io_error(&http_403_io));

        let http_403_seek = DecoderError::SeekError(
            "HTTP 403 fetching https://example.com/track (I/O error)".to_string(),
        );
        assert!(is_fatal_seek_io_error(&http_403_seek));
    }

    #[test]
    fn test_dual_deck_state_transitions_and_external_backend_skip() {
        let player = AudioPlayer::new_headless();
        assert_eq!(player.active_deck(), DeckId::DeckA);
        assert_eq!(player.standby_deck(), DeckId::DeckB);
        assert_eq!(player.deck_state(DeckId::DeckA), DeckState::Idle);
        assert_eq!(player.deck_state(DeckId::DeckB), DeckState::Idle);

        player
            .play_stream(
                make_synth_stream("dd-trk-1", "Track 1", 4_000, 48_000, 2),
                "Synth A",
            )
            .expect("play synth A");
        assert_eq!(player.active_deck(), DeckId::DeckA);
        assert_eq!(player.deck_state(DeckId::DeckA), DeckState::Playing);
        assert_eq!(player.deck_state(DeckId::DeckB), DeckState::Idle);

        // ExternalBackend (Apple Music) must skip Native pre-decoding cleanly
        let apple_spec = StreamSourceSpec::ExternalBackend {
            key: StreamKey::new("apple_music", "am-100", "aac_256"),
            provider_id: "apple_music".to_string(),
            track_uri: "applemusic://track/am-100".to_string(),
            external_web_url: None,
            preview_url: None,
            notice: None,
        };
        player
            .prepare_standby_spec(apple_spec.clone())
            .expect("external backend prepare standby is no-op");
        assert_eq!(player.deck_state(DeckId::DeckB), DeckState::Idle);
        assert!(!player.skip_to_standby().expect("skip_to_standby when idle"));

        // Prepare real Standby track (2-3s pre-decode + Condvar parking)
        player
            .prepare_standby(
                make_synth_stream("dd-trk-2", "Track 2", 4_000, 48_000, 2),
                "Synth B",
            )
            .expect("prepare standby B");
        assert!(
            wait_for_standby_ready(&player, Duration::from_secs(2)),
            "Standby deck did not reach StandbyReady"
        );
        let status = player.dual_deck_status();
        assert_eq!(status.active_deck, DeckId::DeckA);
        assert_eq!(status.deck_a_state, DeckState::Playing);
        assert_eq!(status.deck_b_state, DeckState::StandbyReady);
        assert!(
            status.standby_buffered_ms >= 2_000,
            "expected >= 2000ms prebuffered, got {}",
            status.standby_buffered_ms
        );
        player.shutdown();
    }

    #[test]
    fn test_dual_deck_same_rate_single_callback_gapless_transition() {
        let player = AudioPlayer::new_headless();

        player
            .play_stream(
                make_synth_stream("gap-1", "Gapless Track 1", 600, 48_000, 2),
                "Gapless 1",
            )
            .expect("play gapless 1");
        player
            .prepare_standby(
                make_synth_stream("gap-2", "Gapless Track 2", 3_000, 48_000, 2),
                "Gapless 2",
            )
            .expect("prepare standby gapless 2");
        assert!(wait_for_standby_ready(&player, Duration::from_secs(2)));

        let deadline = Instant::now() + Duration::from_secs(3);
        while player.active_deck() != DeckId::DeckB && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }

        let status = player.dual_deck_status();
        assert_eq!(status.active_deck, DeckId::DeckB);
        assert_eq!(status.deck_b_state, DeckState::Playing);
        assert_eq!(status.deck_a_state, DeckState::Idle);
        assert!(
            status.gapless_transitions >= 1,
            "expected gapless_transitions >= 1, got {}",
            status.gapless_transitions
        );
        assert_eq!(
            player.format_reinit_count(),
            0,
            "same-rate gapless transition must splice in single RT callback without device reinit"
        );
        let deadline_meta = Instant::now() + Duration::from_millis(500);
        while player
            .active_meta()
            .map(|m| m.source_label != "Gapless 2")
            .unwrap_or(true)
            && Instant::now() < deadline_meta
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            player.active_meta().unwrap().source_label,
            "Gapless 2"
        );
        player.shutdown();
    }

    #[test]
    fn test_dual_deck_cross_rate_eof_draining_and_reopen_onto_standby() {
        let player = AudioPlayer::new_headless();

        player
            .play_stream(
                make_synth_stream("xr-48k", "Track 48k", 600, 48_000, 2),
                "Track 48k",
            )
            .expect("play 48k");
        player
            .prepare_standby(
                make_synth_stream("xr-96k", "Track 96k", 3_000, 96_000, 2),
                "Track 96k",
            )
            .expect("prepare standby 96k");
        assert!(wait_for_standby_ready(&player, Duration::from_secs(2)));

        let deadline = Instant::now() + Duration::from_secs(3);
        while player.active_deck() != DeckId::DeckB && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }

        let status = player.dual_deck_status();
        assert_eq!(status.active_deck, DeckId::DeckB);
        assert_eq!(status.deck_b_state, DeckState::Playing);
        assert_eq!(status.deck_a_state, DeckState::Idle);
        assert!(status.gapless_transitions >= 1);
        assert!(
            player.format_reinit_count() >= 1,
            "cross-rate 48k -> 96k must reopen output bound to Standby ring buffer"
        );
        assert_eq!(
            player.active_meta().unwrap().format.sample_rate_hz,
            96_000
        );
        player.shutdown();
    }

    #[test]
    fn test_dual_deck_zero_latency_manual_skip_and_ping_pong() {
        let player = AudioPlayer::new_headless();
        player
            .play_stream(
                make_synth_stream("skip-1", "Skip Track 1", 5_000, 48_000, 2),
                "Skip 1",
            )
            .expect("play skip 1");
        player
            .prepare_standby(
                make_synth_stream("skip-2", "Skip Track 2", 5_000, 48_000, 2),
                "Skip 2",
            )
            .expect("prepare skip 2");
        assert!(wait_for_standby_ready(&player, Duration::from_secs(2)));

        let switched = player.skip_to_standby().expect("skip_to_standby 1->2");
        assert!(switched, "expected fast zero-latency switch to Deck B");
        let st1 = player.dual_deck_status();
        assert_eq!(st1.active_deck, DeckId::DeckB);
        assert_eq!(st1.deck_b_state, DeckState::Playing);
        assert_eq!(st1.manual_zero_latency_switches, 1);
        assert_eq!(player.active_meta().unwrap().source_label, "Skip 2");

        // Ping-pong back from Deck B -> Deck A
        player
            .prepare_standby(
                make_synth_stream("skip-3", "Skip Track 3", 5_000, 48_000, 2),
                "Skip 3",
            )
            .expect("prepare skip 3 on Deck A");
        assert!(wait_for_standby_ready(&player, Duration::from_secs(2)));
        assert_eq!(player.standby_deck(), DeckId::DeckA);

        let switched_back = player.skip_to_standby().expect("skip_to_standby 2->3");
        assert!(switched_back, "expected fast zero-latency switch back to Deck A");
        let st2 = player.dual_deck_status();
        assert_eq!(st2.active_deck, DeckId::DeckA);
        assert_eq!(st2.deck_a_state, DeckState::Playing);
        assert_eq!(st2.manual_zero_latency_switches, 2);
        assert_eq!(player.active_meta().unwrap().source_label, "Skip 3");
        player.shutdown();
    }

    #[test]
    fn test_dual_deck_format_mismatch_recovery_and_auto_predecode() {
        let dir = std::env::temp_dir().join(format!(
            "lumina_dual_deck_test_{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let wav_a = dir.join("mismatch_a.wav");
        let wav_b = dir.join("mismatch_b.wav");
        write_test_wav_16bit(&wav_a, 48_000, 3_500, 440.0);
        write_test_wav_16bit(&wav_b, 48_000, 3_500, 880.0);

        let key = StreamKey::new("youtube", "yt-mismatch-1", "opus_160");
        let spec_a = StreamSourceSpec::LocalFile {
            key: key.clone(),
            path: wav_a.to_string_lossy().into_owned(),
            loudness: None,
            album_loudness: None,
        };
        let spec_b = StreamSourceSpec::LocalFile {
            key: key.clone(),
            path: wav_b.to_string_lossy().into_owned(),
            loudness: None,
            album_loudness: None,
        };

        let player = AudioPlayer::new_headless();
        let cancel = tokio_util::sync::CancellationToken::new();
        player
            .play_source_spec_with_label(spec_a, "Cached Head Track", 1, cancel)
            .expect("play spec_a");
        std::thread::sleep(Duration::from_millis(80));

        player
            .trigger_format_mismatch_recovery(key.clone(), spec_b)
            .expect("trigger format mismatch recovery");

        let deadline = Instant::now() + Duration::from_secs(3);
        while player.dual_deck_status().format_mismatch_recoveries < 1
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(15));
        }

        let status = player.dual_deck_status();
        assert_eq!(status.active_deck, DeckId::DeckB);
        assert_eq!(status.deck_b_state, DeckState::Playing);
        assert!(
            status.format_mismatch_recoveries >= 1,
            "expected format_mismatch_recoveries >= 1, got {}",
            status.format_mismatch_recoveries
        );
        assert!(
            player.position_ms() >= 750,
            "expected playback clock aligned to >= 750ms after +800ms mismatch crossfade, got {}ms",
            player.position_ms()
        );

        // Verify auto-predecode trigger when remaining duration <= 20s
        let next_key = StreamKey::new("youtube", "yt-auto-next", "opus_160");
        let next_spec = StreamSourceSpec::LocalFile {
            key: next_key.clone(),
            path: wav_a.to_string_lossy().into_owned(),
            loudness: None,
            album_loudness: None,
        };
        player.queue_next_spec(next_spec, Some("Auto Queued Next".to_string()));
        assert!(
            wait_for_standby_ready(&player, Duration::from_secs(2)),
            "Queued next spec with remaining duration <= 20s should auto-predecode onto Standby"
        );
        assert_eq!(
            player.dual_deck_status().deck_a_key,
            Some(next_key)
        );

        player.shutdown();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_streaming_sinc_resampler_continuity_44k_to_48k_and_48k_to_44k() {
        use super::StreamingSincResampler;
        use std::f64::consts::TAU;

        // 1. Upsampling 44.1 kHz -> 48 kHz across 1024-frame AAC-sized chunks
        {
            let in_rate = 44_100u32;
            let out_rate = 48_000u32;
            let ch = 2usize;
            let total_in_frames = in_rate as usize; // 1.0 s
            let f_l = 1_000.0f64;
            let f_r = 2_500.0f64;

            let mut resampler = StreamingSincResampler::new(in_rate, out_rate, ch);
            let mut out_all = Vec::new();
            let mut seam_indices = Vec::new();

            let mut cursor = 0usize;
            while cursor < total_in_frames {
                let n = 1024usize.min(total_in_frames - cursor);
                let mut chunk = Vec::with_capacity(n * ch);
                for i in 0..n {
                    let t = (cursor + i) as f64 / in_rate as f64;
                    chunk.push((TAU * f_l * t).sin() * 0.7);
                    chunk.push((TAU * f_r * t).sin() * 0.5);
                }
                let produced = resampler.process(&chunk);
                if !out_all.is_empty() && !produced.is_empty() {
                    seam_indices.push(out_all.len() / ch);
                }
                out_all.extend_from_slice(&produced);
                cursor += n;
            }
            out_all.extend_from_slice(&resampler.flush());

            let total_out_frames = out_all.len() / ch;
            assert!(
                (total_out_frames as i64 - out_rate as i64).abs() <= 1,
                "44.1k->48k frame count drift: got {total_out_frames}, expected ~{out_rate}"
            );
            assert!(out_all.iter().all(|s| s.is_finite()));

            // Verify analytical sine wave accuracy in steady state (excluding filter edges)
            let mut max_err = 0.0f64;
            for f in 100..(total_out_frames - 100) {
                let t = f as f64 / out_rate as f64;
                let exp_l = (TAU * f_l * t).sin() * 0.7;
                let exp_r = (TAU * f_r * t).sin() * 0.5;
                max_err = max_err
                    .max((out_all[f * ch] - exp_l).abs())
                    .max((out_all[f * ch + 1] - exp_r).abs());
            }
            assert!(
                max_err < 0.005,
                "44.1k->48k steady-state sinc error too high (boundary click or distortion): {max_err}"
            );

            // Specifically verify zero boundary spikes at every chunk seam
            for &seam in &seam_indices {
                if seam > 100 && seam + 2 < total_out_frames - 100 {
                    for c in 0..ch {
                        let y_prev = out_all[(seam - 1) * ch + c];
                        let y_curr = out_all[seam * ch + c];
                        let y_next = out_all[(seam + 1) * ch + c];
                        let second_diff = (y_next - 2.0 * y_curr + y_prev).abs();
                        assert!(
                            second_diff < 0.08,
                            "Chunk seam discontinuity at frame {seam} ch {c}: second_diff={second_diff}"
                        );
                    }
                }
            }
        }

        // 2. Downsampling 48 kHz -> 44.1 kHz across 960-frame Opus-sized chunks + alias rejection
        {
            let in_rate = 48_000u32;
            let out_rate = 44_100u32;
            let ch = 2usize;
            let total_in_frames = in_rate as usize; // 1.0 s
            let f_l = 1_000.0f64;
            let f_r = 23_000.0f64; // Above 44.1 kHz Nyquist (22.05 kHz): must be attenuated

            let mut resampler = StreamingSincResampler::new(in_rate, out_rate, ch);
            let mut out_all = Vec::new();
            let mut cursor = 0usize;
            while cursor < total_in_frames {
                let n = 960usize.min(total_in_frames - cursor);
                let mut chunk = Vec::with_capacity(n * ch);
                for i in 0..n {
                    let t = (cursor + i) as f64 / in_rate as f64;
                    chunk.push((TAU * f_l * t).sin() * 0.7);
                    chunk.push((TAU * f_r * t).sin() * 0.7);
                }
                out_all.extend_from_slice(&resampler.process(&chunk));
                cursor += n;
            }
            out_all.extend_from_slice(&resampler.flush());

            let total_out_frames = out_all.len() / ch;
            assert!(
                (total_out_frames as i64 - out_rate as i64).abs() <= 1,
                "48k->44.1k frame count drift: got {total_out_frames}, expected ~{out_rate}"
            );
            assert!(out_all.iter().all(|s| s.is_finite()));

            let mut max_err_l = 0.0f64;
            let mut sum_sq_r = 0.0f64;
            let mut count = 0usize;
            for f in 100..(total_out_frames - 100) {
                let t = f as f64 / out_rate as f64;
                let exp_l = (TAU * f_l * t).sin() * 0.7;
                max_err_l = max_err_l.max((out_all[f * ch] - exp_l).abs());
                let r = out_all[f * ch + 1];
                sum_sq_r += r * r;
                count += 1;
            }
            let rms_r = (sum_sq_r / count as f64).sqrt();
            assert!(
                max_err_l < 0.005,
                "48k->44.1k passband error too high: {max_err_l}"
            );
            assert!(
                rms_r < 0.05,
                "48k->44.1k failed to attenuate ultrasonic 23 kHz aliasing tone: rms={rms_r}"
            );
        }

        // 3. Same-rate passthrough must be bit-exact and flush empty
        {
            let mut r = StreamingSincResampler::new(48_000, 48_000, 2);
            let input = vec![0.25, -0.5, 0.75, -0.125];
            assert_eq!(r.process(&input), input);
            assert!(r.flush().is_empty());
        }
    }

    #[test]
    fn test_loudness_db_sign_cap_streaming_auto_apply_and_soft_limiter() {
        use super::{
            compute_effective_replay_gain_db, to_internal_replay_gain, TrackReplayGainTags,
        };
        use crate::dsp::{DspPipeline, LookaheadLimiter};
        use core_types::{
            NormalizedLoudness, ReplayGainConfig as SharedReplayGainConfig,
            ReplayGainMode as SharedReplayGainMode,
        };
        use std::collections::BTreeMap;

        // Positive YTM loudnessDb (+6.0) means track is louder than -14 LUFS -> MUST attenuate (-6.0 dB)
        let loud = NormalizedLoudness::from_ytm_loudness_db(6.0);
        assert!((loud.gain_db - (-6.0)).abs() < 1e-4);

        // Quiet YTM track (-8.0 loudnessDb -> +8.0 dB desired) MUST be capped at +6.0 dB
        let quiet = NormalizedLoudness::from_ytm_loudness_db(-8.0);
        assert!((quiet.gain_db - 6.0).abs() < 1e-4);

        // Direct sanitization and ReplayGain engine MUST also enforce the +6.0 dB cap
        let raw_overboost = NormalizedLoudness {
            gain_db: 18.0,
            peak: 1.0,
        };
        assert!((raw_overboost.sanitized().gain_db - 6.0).abs() < 1e-4);
        let rg_overboost = crate::dsp::ReplayGain::from_gain_db(18.0, 4.0);
        assert!(
            (rg_overboost.linear_gain() - 10_f64.powf(6.0 / 20.0)).abs() < 1e-4,
            "ReplayGain must clamp total gain to <= +6.0 dB"
        );

        // Automatic streaming loudness normalization when ReplayGainMode::Off
        let off_cfg = SharedReplayGainConfig {
            mode: SharedReplayGainMode::Off,
            preamp_db: 0.0,
            prevent_clipping: true,
        };

        let ytm_loud_spec = StreamSourceSpec::DirectRange {
            key: StreamKey::new("youtube_music", "vid-loud", "251"),
            url: "https://example.invalid/audio.webm".to_string(),
            headers: BTreeMap::new(),
            content_length: Some(1_000_000),
            bitrate_bps: Some(160_000),
            mime_type: Some("audio/webm; codecs=opus".to_string()),
            hint_extension: Some("webm".to_string()),
            expire_at: None,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness: Some(loud),
            album_loudness: None,
        };
        let tags_loud = TrackReplayGainTags::from_source_spec(&ytm_loud_spec);
        let eff_loud = compute_effective_replay_gain_db(&off_cfg, &tags_loud)
            .expect("streaming track loudnessDb=+6 must auto-apply even when RG mode is Off");
        assert!(
            (eff_loud - (-6.0)).abs() < 1e-3,
            "expected -6.0 dB, got {eff_loud}"
        );

        let ytm_quiet_spec = StreamSourceSpec::DirectRange {
            key: StreamKey::new("youtube_music", "vid-quiet", "251"),
            url: "https://example.invalid/audio.webm".to_string(),
            headers: BTreeMap::new(),
            content_length: Some(1_000_000),
            bitrate_bps: Some(160_000),
            mime_type: Some("audio/webm; codecs=opus".to_string()),
            hint_extension: Some("webm".to_string()),
            expire_at: None,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness: Some(quiet),
            album_loudness: None,
        };
        let tags_quiet = TrackReplayGainTags::from_source_spec(&ytm_quiet_spec);
        let eff_quiet = compute_effective_replay_gain_db(&off_cfg, &tags_quiet)
            .expect("quiet streaming track must auto-apply capped +6.0 dB boost");
        assert!(
            (eff_quiet - 6.0).abs() < 1e-3,
            "expected +6.0 dB capped boost (not zeroed by synthetic peak=1.0), got {eff_quiet}"
        );

        // Local files must stay untouched when ReplayGainMode::Off (preserves lossless/bit-perfect)
        let local_spec = StreamSourceSpec::LocalFile {
            key: StreamKey::new("local", "loc-1", "flac"),
            path: "track.flac".to_string(),
            loudness: Some(loud),
            album_loudness: None,
        };
        let tags_local = TrackReplayGainTags::from_source_spec(&local_spec);
        assert!(compute_effective_replay_gain_db(&off_cfg, &tags_local).is_none());

        // End-to-end DSP + LookaheadLimiter + post-resample soft clip safety under +6 dB boost + NaN/Inf
        let mut dsp = DspPipeline::new(48_000.0, 2).unwrap();
        dsp.set_replay_gain(to_internal_replay_gain(&off_cfg, &tags_quiet));
        dsp.set_limiter_enabled(true);
        let mut buf = vec![0.9f64; 512];
        buf[10] = f64::NAN;
        buf[11] = f64::INFINITY;
        buf[12] = f64::NEG_INFINITY;
        dsp.process_interleaved(&mut buf);
        for &s in &buf {
            let finite = if s.is_finite() { s } else { 0.0 };
            let out = LookaheadLimiter::soft_clip(finite, 0.98).clamp(-1.0, 1.0) as f32;
            assert!(out.is_finite(), "output sample must never be NaN/Inf");
            assert!(
                (-1.0..=1.0).contains(&out),
                "output sample exceeded [-1.0, 1.0]: {out}"
            );
        }
    }

    #[test]
    fn test_partial_underrun_fade_out_and_atomic_counter() {
        use super::{
            fade_out_wire_tail, AudioFadeControl, DeckState, DualDeckPcmFeeder, PcmRenderOutcome,
            PlayerInner, RtPcmInboxPayload,
        };
        use crate::buffer::SpscRingBuffer;
        use crate::verification::WireSampleFormat;
        use std::sync::atomic::Ordering;
        use std::sync::Arc;

        // 1. DualDeckPcmFeeder partial underrun: smooth tail fade-out, atomic counter, re-arm gate
        let inner = Arc::new(PlayerInner::new(true));
        inner.stopped.store(false, Ordering::SeqCst);
        inner.paused.store(false, Ordering::SeqCst);
        inner.current_session_id.store(1, Ordering::SeqCst);
        inner.dual_deck.active_deck_idx.store(0, Ordering::SeqCst);
        inner.dual_deck.deck_states[0].store(DeckState::Playing as u8, Ordering::SeqCst);
        inner.dual_deck.deck_eof_flags[0].store(false, Ordering::SeqCst);

        let (mut prod, cons) = SpscRingBuffer::<f32>::new(4096);
        let ch = 2usize;
        let watermark_frames = 256usize;
        let payload = RtPcmInboxPayload {
            consumer: cons,
            ver_tap: None,
            watermark_samples: watermark_frames * ch,
            out_rate: 48_000,
            out_channels: ch as u16,
            deck_gen: 1,
            last_ring_epoch: 0,
        };
        let fade_ctrl = Arc::new(AudioFadeControl::new(false, false, false));
        let mut feeder = DualDeckPcmFeeder::new(
            Arc::clone(&inner.dual_deck),
            Arc::clone(&inner),
            1,
            0,
            payload,
            &fade_ctrl,
        );
        feeder.fade.set_unity();

        // Push 300 stereo frames (> 256 watermark so gate releases) of constant +0.8
        let valid_frames = 300usize;
        let pushed = prod.push_slice(&vec![0.8f32; valid_frames * ch]);
        assert_eq!(pushed, valid_frames * ch);

        // Request 512 frames -> partial underrun (300 available, 212 missing, EOF=false)
        let mut out = vec![99.0f32; 512 * ch];
        let mut wire_scratch = vec![0u8; 512 * ch * 4];
        let outcome = feeder.render_f32(&mut out, &mut wire_scratch, &fade_ctrl, 1.0);
        assert_eq!(outcome, PcmRenderOutcome::Rendered);
        assert_eq!(
            inner.ring_buffer_underrun_count.load(Ordering::Relaxed),
            1,
            "partial underrun must increment atomic ring_buffer_underrun_count"
        );

        // Early frames (before 128-frame tail) preserve audio amplitude
        assert!(
            (out[10 * ch] - 0.8).abs() < 1e-4,
            "early frame should preserve amplitude, got {}",
            out[10 * ch]
        );
        // Tail frames ramp monotonically down to exact 0.0 on the final valid frame (299)
        let tail_start = valid_frames - 128;
        assert!(out[tail_start * ch] > 0.75);
        assert!(out[(tail_start + 64) * ch] < 0.45 && out[(tail_start + 64) * ch] > 0.35);
        assert_eq!(
            out[(valid_frames - 1) * ch],
            0.0,
            "final valid frame before silence must hit exact 0.0 (no click)"
        );
        assert_eq!(out[(valid_frames - 1) * ch + 1], 0.0);
        // Remainder of callback buffer must be zeroed (never stale data)
        assert!(out[valid_frames * ch..].iter().all(|&s| s == 0.0));
        // Buffering gate must be re-armed so a tiny trickle (50 frames < 256 watermark) stays silent
        let _ = prod.push_slice(&vec![0.5f32; 50 * ch]);
        let mut out2 = vec![1.0f32; 256 * ch];
        let outcome2 = feeder.render_f32(&mut out2, &mut wire_scratch, &fade_ctrl, 1.0);
        assert_eq!(outcome2, PcmRenderOutcome::Silent);
        assert!(out2.iter().all(|&s| s == 0.0));

        // 2. Wire-format tail fade-out (Int16Le + Float32Le NaN safety)
        let mut i16_bytes = Vec::new();
        for _ in 0..16 {
            i16_bytes.extend_from_slice(&20_000i16.to_le_bytes());
            i16_bytes.extend_from_slice(&(-20_000i16).to_le_bytes());
        }
        fade_out_wire_tail(&mut i16_bytes, WireSampleFormat::Int16Le, 2, 8);
        let first_l = i16::from_le_bytes([i16_bytes[0], i16_bytes[1]]);
        let last_l = i16::from_le_bytes([i16_bytes[60], i16_bytes[61]]);
        let last_r = i16::from_le_bytes([i16_bytes[62], i16_bytes[63]]);
        assert_eq!(first_l, 20_000, "frames before fade tail must be untouched");
        assert_eq!(last_l, 0, "final wire frame L must reach 0");
        assert_eq!(last_r, 0, "final wire frame R must reach 0");

        let mut f32_bytes = Vec::new();
        for i in 0..8 {
            let v = if i == 4 { f32::NAN } else { 0.8f32 };
            f32_bytes.extend_from_slice(&v.to_le_bytes());
        }
        fade_out_wire_tail(&mut f32_bytes, WireSampleFormat::Float32Le, 1, 8);
        for chunk in f32_bytes.chunks_exact(4) {
            let v = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            assert!(v.is_finite());
        }
        let last_f = f32::from_le_bytes([f32_bytes[28], f32_bytes[29], f32_bytes[30], f32_bytes[31]]);
        assert_eq!(last_f, 0.0);
    }
}
