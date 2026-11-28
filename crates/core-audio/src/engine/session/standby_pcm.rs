//! Shared/CPAL/Virtual PCM path for standby pre-decode workers.

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Condvar, Mutex, mpsc};

use core_types::{
    AudioDeviceCapabilities, AudioFormat, DeckTrackMetadata, OutputBackendKind, OutputMode,
    PlaybackEnginePolicy, UnifiedAudioFormat,
};
use cpal::SampleFormat;
use tokio_util::sync::CancellationToken;

use crate::backend::cpal_shared::{
    enumerate_cpal_devices, resolve_cpal_device, select_output_config,
};
use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::{AudioDecoder, DecodedTrackMetadata};
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dual_deck::{DeckMetadataSnapshot, RtPcmInboxPayload, StandbyWakeState};
use crate::engine::{
    PlayerInner, PlayerOrigin, TrackReplayGainTags, VIRTUAL_DEVICE_ID, VIRTUAL_DEVICE_NAME,
};
use crate::pipeline::decode_worker::decode_loop;
use crate::pipeline::fade::{
    AudioFadeControl, compute_pcm_ring_samples, compute_startup_watermark_samples,
};
use crate::pipeline::ring_buffer::SpscRingBuffer;
use crate::verification::{AudioVerificationEngine, VerificationConfig, WireSampleFormat};

use super::standby::StandbyDeckGate;

#[allow(clippy::too_many_arguments)]
pub(super) fn run_standby_pcm_worker(
    decoder: Box<dyn AudioDecoder>,
    inner: Arc<PlayerInner>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
    deck_idx: usize,
    deck_gen: u64,
    path: PathBuf,
    source_label: String,
    origin: PlayerOrigin,
    format: AudioFormat,
    unified_src: UnifiedAudioFormat,
    track_meta: Option<DecodedTrackMetadata>,
    standby_track_meta: Option<DeckTrackMetadata>,
    rg_tags: TrackReplayGainTags,
    caps: AudioDeviceCapabilities,
    policy: PlaybackEnginePolicy,
    sel_id: Option<String>,
    sel_backend: Option<OutputBackendKind>,
    dsp_bypassed: bool,
    eff_vol: f32,
    duration_ms: u64,
    pcm_rate: u32,
    default_out_channels: u16,
    predecode_target_ms: u64,
    is_mismatch_recovery: bool,
    mismatch_pts_ms: u64,
    mismatch_frame: u64,
    session_id: u64,
    cancel_flag: Arc<AtomicBool>,
    cancel_token: CancellationToken,
    eof_flag: Arc<AtomicBool>,
    fade_ctrl: Arc<AudioFadeControl>,
    wake: Arc<(Mutex<StandbyWakeState>, Condvar)>,
) -> Option<Box<dyn AudioDecoder>> {
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
        track_meta: standby_track_meta,
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
