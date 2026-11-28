//! Deck decode handles, metadata snapshots, output profile, and RT inbox payload types.

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use core_types::{
    AudioFormat, DeckTrackMetadata, OutputBackendKind, OutputMode, UnifiedAudioFormat,
};
use tokio_util::sync::CancellationToken;

use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::AudioDecoder;
use crate::engine::{PlayerOrigin, TrackReplayGainTags};
use crate::pipeline::ring_buffer::Consumer;
use crate::verification::{AudioVerificationEngine, VerificationTapProducer, WireSampleFormat};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StandbyWakeState {
    Parked,
    Promoted,
    Cancelled,
}

pub(crate) struct DeckDecodeHandle {
    #[allow(dead_code)]
    pub(crate) deck_gen: u64,
    pub(crate) cancel_flag: Arc<AtomicBool>,
    pub(crate) cancel_token: CancellationToken,
    pub(crate) wake: Arc<(Mutex<StandbyWakeState>, Condvar)>,
    pub(crate) join_handle: Option<JoinHandle<Option<Box<dyn AudioDecoder>>>>,
}

#[derive(Clone)]
pub(crate) struct DeckMetadataSnapshot {
    pub(crate) path: PathBuf,
    pub(crate) source_label: String,
    pub(crate) origin: PlayerOrigin,
    pub(crate) format: AudioFormat,
    #[allow(dead_code)]
    pub(crate) unified_format: UnifiedAudioFormat,
    pub(crate) negotiated: NegotiatedFormat,
    pub(crate) duration_ms: u64,
    pub(crate) pcm_rate: u32,
    pub(crate) out_rate: u32,
    pub(crate) out_channels: u16,
    pub(crate) rg_tags: TrackReplayGainTags,
    pub(crate) verification: AudioVerificationEngine,
    pub(crate) api_label: String,
    pub(crate) device_name: String,
    pub(crate) backend: OutputBackendKind,
    pub(crate) active_device_id: String,
    pub(crate) expected_stamp: u64,
    pub(crate) is_wire: bool,
    pub(crate) resampled_to_hz: Option<u32>,
    pub(crate) track_meta: Option<DeckTrackMetadata>,
}

#[derive(Debug, Clone)]
pub(crate) struct ActiveOutputProfile {
    #[allow(dead_code)]
    pub(crate) session_id: u64,
    pub(crate) is_wire: bool,
    pub(crate) uses_dual_feeder: bool,
    pub(crate) output_mode: OutputMode,
    pub(crate) wire_format: WireSampleFormat,
    pub(crate) out_rate: u32,
    pub(crate) out_channels: u16,
}

pub(crate) struct RtPcmInboxPayload {
    pub(crate) consumer: Consumer<f32>,
    pub(crate) ver_tap: Option<VerificationTapProducer>,
    pub(crate) watermark_samples: usize,
    pub(crate) out_rate: u32,
    pub(crate) out_channels: u16,
    pub(crate) deck_gen: u64,
    pub(crate) last_ring_epoch: u64,
}

pub(crate) struct RtWireInboxPayload {
    pub(crate) consumer: Consumer<u8>,
    pub(crate) ver_tap: VerificationTapProducer,
    pub(crate) watermark_bytes: usize,
    pub(crate) wire: WireSampleFormat,
    pub(crate) out_rate: u32,
    pub(crate) out_channels: u16,
    pub(crate) expected_stamp: u64,
    pub(crate) deck_gen: u64,
    pub(crate) last_ring_epoch: u64,
}
