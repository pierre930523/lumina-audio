//! Shared/CPAL/Virtual PCM path for `try_hot_swap_active_session`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread;

use core_types::{
    AudioDeviceCapabilities, DeckState, DeckTrackMetadata, OutputBackendKind, OutputMode,
    PlaybackEnginePolicy, UnifiedAudioFormat,
};
use cpal::traits::StreamTrait;

use crate::backend::cpal_shared::enumerate_cpal_devices;
use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::{AudioDecoder, DecodedTrackMetadata};
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dual_deck::{
    ActiveOutputProfile, DeckDecodeHandle, DeckMetadataSnapshot, DecodeThreadGuard,
    RtPcmInboxPayload, StandbyWakeState,
};
use crate::engine::{ActiveTrackMeta, PlayerInner, VIRTUAL_DEVICE_ID, VIRTUAL_DEVICE_NAME};
use crate::error::CoreAudioError;
use crate::pipeline::decode_worker::decode_loop;
use crate::pipeline::fade::{compute_pcm_ring_samples, compute_startup_watermark_samples};
use crate::pipeline::ring_buffer::SpscRingBuffer;
use crate::verification::{AudioVerificationEngine, VerificationConfig, WireSampleFormat};

use super::active::ActiveSession;
use super::types::{OutputReuseKey, PipelineSpec, backend_to_clock_src};

#[allow(clippy::too_many_arguments)]
pub(super) fn try_hot_swap_pcm(
    inner: &Arc<PlayerInner>,
    active: &mut ActiveSession,
    decoder: Box<dyn AudioDecoder>,
    spec: &PipelineSpec,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
    caps: &AudioDeviceCapabilities,
    policy: &PlaybackEnginePolicy,
    sel_id: Option<String>,
    dsp_bypassed: bool,
    eff_vol: f32,
    unified_src: UnifiedAudioFormat,
    track_meta: Option<DecodedTrackMetadata>,
    effective_deck_track_meta: Option<DeckTrackMetadata>,
) -> Result<Result<(), Box<dyn AudioDecoder>>, CoreAudioError> {
    let use_virtual = inner.headless
        || (sel_id.as_deref() == Some(VIRTUAL_DEVICE_ID) && enumerate_cpal_devices().is_empty());
    let (out_rate, out_channels, backend_kind, device_name, api_label_b) = match &active
        .output_reuse_key
    {
        OutputReuseKey::VirtualPcm {
            sample_rate,
            channels,
        } if use_virtual && *sample_rate == spec.pcm_rate && *channels == spec.out_channels => (
            *sample_rate,
            *channels,
            OutputBackendKind::WindowsWasapiExclusive,
            VIRTUAL_DEVICE_NAME.to_string(),
            "Virtual Consumer".to_string(),
        ),
        OutputReuseKey::CpalShared {
            device_id,
            sample_rate,
            channels,
        } if !use_virtual && *device_id == caps.device_id && *channels == spec.out_channels => {
            let (bk, dn) = inner
                .active_meta
                .read()
                .ok()
                .and_then(|g| g.as_ref().map(|m| (m.backend, m.device_name.clone())))
                .unwrap_or((OutputBackendKind::WindowsWasapiShared, caps.name.clone()));
            (*sample_rate, *channels, bk, dn, format!("{bk:?}"))
        }
        _ => return Ok(Err(decoder)),
    };

    let active_idx = inner.dual_deck.active_idx();
    let active_gen = inner.dual_deck.alloc_deck_gen(active_idx);
    inner.dual_deck.deck_states[active_idx].store(DeckState::Playing as u8, Ordering::SeqCst);
    inner
        .dual_deck
        .set_deck_key(active_idx, spec.origin.stream_key());
    let cancel_flag = Arc::new(AtomicBool::new(false));
    let eof_flag = Arc::clone(&inner.dual_deck.deck_eof_flags[active_idx]);
    eof_flag.store(false, Ordering::SeqCst);
    inner.dual_deck.deck_buffered_ms[active_idx].store(0, Ordering::Relaxed);
    inner.buffered_ms.store(0, Ordering::Relaxed);

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
        resampled: spec.pcm_rate != out_rate,
        exclusive_unavailable_reason: degrad_b,
    });
    if let Some(ref m) = track_meta {
        shared_verification.set_source_metadata(m.title.clone(), m.artist.clone(), m.album.clone());
    }

    let ring_samples = compute_pcm_ring_samples(out_rate, out_channels);
    let (producer, consumer) = SpscRingBuffer::<f32>::new(ring_samples);
    let watermark_samples =
        compute_startup_watermark_samples(out_rate, out_channels, producer.capacity());
    let ver_tap = shared_verification.attach_rt_tap(
        WireSampleFormat::Float32Le,
        out_channels,
        out_rate,
        1024 * 1024,
    );
    let last_ring_epoch = consumer.epoch();
    let pcm_payload = RtPcmInboxPayload {
        consumer,
        ver_tap: Some(ver_tap),
        watermark_samples,
        out_rate,
        out_channels,
        deck_gen: active_gen,
        last_ring_epoch,
    };

    inner.out_sample_rate.store(out_rate, Ordering::SeqCst);
    inner.cached_clock_source.store(
        backend_to_clock_src(inner.headless, backend_kind),
        Ordering::Release,
    );
    let fade_ctrl = Arc::clone(&active.fade_ctrl);
    active
        .feeder_session_id
        .store(spec.session_id, Ordering::Release);
    inner.dual_deck.send_pcm_inbox(active_idx, pcm_payload);
    if spec.start_paused {
        fade_ctrl.request_pause_fade_out();
        if let Some(ref st) = active._cpal_stream {
            let _ = st.pause();
        }
    } else {
        fade_ctrl.request_play_fade_in();
        if let Some(ref st) = active._cpal_stream {
            let _ = st.play();
        }
    }

    let resampled_to_hz = if spec.pcm_rate != out_rate {
        Some(out_rate)
    } else {
        None
    };
    if let Ok(mut af) = inner.active_fade.write() {
        *af = Some(Arc::clone(&fade_ctrl));
    }
    if let Ok(mut vw) = inner.verification.write() {
        *vw = Some((
            shared_verification.clone(),
            api_label_b.clone(),
            device_name.clone(),
        ));
    }
    if let Ok(mut meta_lock) = inner.active_meta.write() {
        *meta_lock = Some(ActiveTrackMeta {
            path: spec.path.clone(),
            source_label: spec.source_label.clone(),
            format: spec.format.clone(),
            duration_ms: spec.duration_ms,
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
        requires_resampling: spec.pcm_rate != out_rate,
        degradation_reason: None,
    };
    let rg_tags = inner
        .track_replay_gain
        .read()
        .map(|g| g.clone())
        .unwrap_or_default();
    if let Ok(mut mg) = inner.dual_deck.deck_meta[active_idx].write() {
        *mg = Some(DeckMetadataSnapshot {
            path: spec.path.clone(),
            source_label: spec.source_label.clone(),
            origin: spec.origin.clone(),
            format: spec.format.clone(),
            unified_format: unified_src.clone(),
            negotiated: fallback_neg.clone(),
            duration_ms: spec.duration_ms,
            pcm_rate: spec.pcm_rate,
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
            session_id: spec.session_id,
            is_wire: false,
            uses_dual_feeder: true,
            output_mode: mode_b,
            wire_format: WireSampleFormat::Float32Le,
            out_rate,
            out_channels,
        });

    let decode_inner = Arc::clone(inner);
    let decode_cancel = Arc::clone(&cancel_flag);
    let decode_cancel_token = spec.cancel_token.clone();
    let decode_eof = Arc::clone(&eof_flag);
    let decode_fade = Arc::clone(&fade_ctrl);
    let decode_tx = cmd_tx.clone();
    let dec_pcm_rate = spec.pcm_rate;
    let dec_sid = spec.session_id;
    let dec_caps = caps.clone();
    let active_device_id = caps.device_id.clone();
    let thread_guard_counter = Arc::clone(&inner.live_decode_threads);
    let decode_handle = thread::Builder::new()
        .name("lumina-audio-decoder".to_string())
        .spawn(move || {
            let _live_guard = DecodeThreadGuard::new(&thread_guard_counter);
            decode_loop(
                decoder,
                producer,
                dec_pcm_rate,
                out_rate,
                out_channels,
                None,
                decode_inner,
                Some(shared_verification),
                unified_src,
                fallback_neg,
                dec_caps,
                decode_cancel,
                decode_cancel_token,
                decode_eof,
                decode_fade,
                watermark_samples,
                dec_sid,
                decode_tx,
                active_idx,
                active_gen,
                None,
            )
        })
        .ok();
    let old_entry = inner.dual_deck.decode_entries[active_idx]
        .lock()
        .ok()
        .and_then(|mut eg| {
            eg.replace(DeckDecodeHandle {
                deck_gen: active_gen,
                cancel_flag: Arc::clone(&cancel_flag),
                cancel_token: spec.cancel_token.clone(),
                wake: Arc::new((Mutex::new(StandbyWakeState::Promoted), Condvar::new())),
                join_handle: decode_handle,
            })
        });
    if let Some(mut old) = old_entry {
        old.cancel_token.cancel();
        old.cancel_flag.store(true, Ordering::SeqCst);
        if let Some(h) = old.join_handle.take() {
            inner.reaper.retire_decode(h);
        }
    }

    active.cancel_flag = cancel_flag;
    active.cancel_token = spec.cancel_token.clone();
    active.eof_flag = eof_flag;
    active.path = spec.path.clone();
    active.source_label = spec.source_label.clone();
    active.origin = spec.origin.clone();
    active.format = spec.format.clone();
    active.duration_ms = spec.duration_ms;
    active.pcm_rate = spec.pcm_rate;
    active.active_device_id = active_device_id;
    active.track_meta = effective_deck_track_meta;
    Ok(Ok(()))
}
