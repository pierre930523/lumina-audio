//! Shared/CPAL/Virtual PCM path for `start_output_pipeline`.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread;

use core_types::{
    AudioCodec, AudioDeviceCapabilities, AudioFormat, DeckTrackMetadata, OutputBackendKind,
    OutputMode, PlaybackEnginePolicy, UnifiedAudioFormat,
};
use cpal::SampleFormat;
use cpal::traits::StreamTrait;
use tokio_util::sync::CancellationToken;

use crate::backend::cpal_shared::enumerate_cpal_devices;
use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::{AudioDecoder, DecodedTrackMetadata};
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dual_deck::{
    ActiveOutputProfile, DeckDecodeHandle, DeckMetadataSnapshot, DecodeThreadGuard,
    DualDeckPcmFeeder, RtPcmInboxPayload, StandbyWakeState,
};
use crate::engine::{
    ActiveTrackMeta, PlayerInner, PlayerOrigin, VIRTUAL_DEVICE_ID, VIRTUAL_DEVICE_NAME,
};
use crate::error::{BackendError, CoreAudioError};
use crate::pipeline::decode_worker::{decode_loop, is_opus_dump_enabled};
use crate::pipeline::fade::{
    AudioFadeControl, compute_pcm_ring_samples, compute_startup_watermark_samples,
};
use crate::pipeline::ring_buffer::SpscRingBuffer;
use crate::verification::{AudioVerificationEngine, VerificationConfig, WireSampleFormat};

use super::active::ActiveSession;
use super::cpal_out::open_cpal_output;
use super::types::{OutputReuseKey, backend_to_clock_src};
use super::virtual_out::spawn_virtual_consumer;

#[allow(clippy::too_many_arguments)]
pub(super) fn start_pcm_pipeline(
    inner: &Arc<PlayerInner>,
    decoder: Box<dyn AudioDecoder>,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
    active_idx: usize,
    active_gen: u64,
    session_id: u64,
    pcm_rate: u32,
    default_out_channels: u16,
    path: PathBuf,
    source_label: String,
    origin: PlayerOrigin,
    effective_deck_track_meta: Option<DeckTrackMetadata>,
    cancel_flag: Arc<AtomicBool>,
    output_kill_flag: Arc<AtomicBool>,
    eof_flag: Arc<AtomicBool>,
    cancel_token: CancellationToken,
    format: AudioFormat,
    duration_ms: u64,
    start_paused: bool,
    unified_src: UnifiedAudioFormat,
    track_meta: Option<DecodedTrackMetadata>,
    caps: AudioDeviceCapabilities,
    policy: PlaybackEnginePolicy,
    sel_id: Option<String>,
    dsp_bypassed: bool,
    eff_vol: f32,
    exclusive_fallback_reason: Option<String>,
) -> Result<ActiveSession, CoreAudioError> {
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
    let feeder_session_id = Arc::new(AtomicU64::new(session_id));
    let expected_stamp_arc = Arc::new(AtomicU64::new(0));

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
        reuse_key,
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
            Arc::clone(&feeder_session_id),
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
            Arc::clone(&feeder_session_id),
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
            OutputReuseKey::VirtualPcm {
                sample_rate: pcm_rate,
                channels: default_out_channels,
            },
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
                Arc::clone(&feeder_session_id),
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
            OutputReuseKey::CpalShared {
                device_id: caps.device_id.clone(),
                sample_rate: actual_rate,
                channels: actual_ch,
            },
        )
    };

    inner.output_reopen_count.fetch_add(1, Ordering::Relaxed);
    inner.cached_clock_source.store(
        backend_to_clock_src(inner.headless, backend_kind),
        Ordering::Release,
    );
    #[cfg(target_os = "windows")]
    inner.set_active_wasapi_ctrl(None);
    #[cfg(not(target_os = "windows"))]
    inner.set_active_wasapi_ctrl();
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
            track_meta: effective_deck_track_meta.clone(),
        });
    }
    if let Ok(mut tm_lock) = inner.active_track_metadata.write() {
        *tm_lock = effective_deck_track_meta.clone();
    }
    inner
        .dual_deck
        .set_deck_track_meta(active_idx, effective_deck_track_meta.clone());
    inner
        .dual_deck
        .committed_deck_gen
        .store(active_gen, Ordering::Release);

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
            track_meta: effective_deck_track_meta.clone(),
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
    let thread_guard_counter = Arc::clone(&inner.live_decode_threads);
    let decode_handle = thread::Builder::new()
        .name("lumina-audio-decoder".to_string())
        .spawn(move || {
            let _live_guard = DecodeThreadGuard::new(&thread_guard_counter);
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
            inner.reaper.retire_decode(h);
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
        output_reuse_key: reuse_key,
        feeder_session_id,
        expected_stamp_arc,
        path,
        source_label,
        origin,
        format,
        duration_ms,
        pcm_rate,
        active_device_id,
        track_meta: effective_deck_track_meta,
    })
}
