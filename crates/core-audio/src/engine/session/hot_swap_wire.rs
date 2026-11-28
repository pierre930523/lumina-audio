//! Lock-free zero-reopen hot-swap for native Wire (WASAPI Exclusive / Virtual Wire) sessions.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread;

#[cfg(target_os = "windows")]
use core_types::ChannelLayout;
use core_types::{
    AudioDeviceCapabilities, DeckState, DeckTrackMetadata, OutputBackendKind, OutputMode,
    PlaybackEnginePolicy, UnifiedAudioFormat,
};

use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::{AudioDecoder, DecodedTrackMetadata};
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dual_deck::{
    ActiveOutputProfile, DeckDecodeHandle, DeckMetadataSnapshot, DecodeThreadGuard,
    RtWireInboxPayload, StandbyWakeState,
};
use crate::engine::{ActiveTrackMeta, PlayerInner, VIRTUAL_DEVICE_NAME, is_any_dsp_active};
use crate::error::CoreAudioError;
use crate::pipeline::decode_worker::decode_wire_loop;
use crate::pipeline::fade::{
    AudioFadeControl, compute_startup_watermark_bytes, compute_wire_ring_bytes,
};
use crate::pipeline::ring_buffer::SpscRingBuffer;
use crate::verification::{
    AudioVerificationEngine, VerificationConfig, WireFormatStamp, WireSampleFormat,
};

use super::active::ActiveSession;
use super::types::{NativeOutputSession, OutputReuseKey, PipelineSpec, backend_to_clock_src};

#[allow(clippy::too_many_arguments)]
pub(super) fn try_hot_swap_wire(
    inner: &Arc<PlayerInner>,
    active: &mut ActiveSession,
    decoder: Box<dyn AudioDecoder>,
    spec: &PipelineSpec,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
    caps: &AudioDeviceCapabilities,
    policy: &PlaybackEnginePolicy,
    sel_backend: Option<OutputBackendKind>,
    dsp_bypassed: bool,
    allow_virtual_wire: bool,
    negotiated: &NegotiatedFormat,
    unified_src: UnifiedAudioFormat,
    track_meta: Option<DecodedTrackMetadata>,
    effective_deck_track_meta: Option<DeckTrackMetadata>,
) -> Result<Result<(), Box<dyn AudioDecoder>>, CoreAudioError> {
    let wire = negotiated.wire_format;
    let desired_key = if allow_virtual_wire {
        OutputReuseKey::VirtualWire {
            output_mode: negotiated.output_mode,
            wire_format: wire,
            sample_rate: negotiated.target_sample_rate,
            channels: negotiated.target_channels,
        }
    } else if matches!(
        negotiated.output_mode,
        OutputMode::AsioPcm | OutputMode::AsioNativeDsd | OutputMode::DoPOverAsio
    ) {
        OutputReuseKey::None
    } else {
        #[cfg(target_os = "windows")]
        {
            OutputReuseKey::WasapiExclusive(crate::backend::wasapi_win::WasapiExclusiveOpenSpec {
                device_id: Some(caps.device_id.clone()),
                sample_rate: negotiated.target_sample_rate,
                channels: negotiated.target_channels,
                layout: ChannelLayout::from_channels(negotiated.target_channels),
                wire_format: wire,
                is_dop: negotiated.output_mode == OutputMode::DoPOverWasapiExclusive,
                buffer_frames_hint: policy.preferred_buffer_frames,
            })
        }
        #[cfg(not(target_os = "windows"))]
        {
            OutputReuseKey::None
        }
    };

    if desired_key == OutputReuseKey::None || active.output_reuse_key != desired_key {
        return Ok(Err(decoder));
    }

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

    let is_dsd_wire = matches!(
        wire,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    );
    let initial_wire_dsp_active =
        !policy.strict_bit_perfect && !dsp_bypassed && !is_dsd_wire && is_any_dsp_active(inner);
    let actual_frames = match active.native_output {
        #[cfg(target_os = "windows")]
        Some(NativeOutputSession::WasapiExclusive(ref s)) => s.actual_buffer_frames,
        _ => policy.preferred_buffer_frames,
    };
    let ver_cfg = VerificationConfig {
        source_format: unified_src.clone(),
        output_mode: negotiated.output_mode,
        transport: caps.transport,
        target_rate_hz: negotiated.target_sample_rate,
        target_channels: negotiated.target_channels,
        target_valid_bits: negotiated.valid_bits,
        target_container_bits: negotiated.container_bits,
        buffer_size_frames: actual_frames,
        dsp_active: initial_wire_dsp_active,
        software_volume_unity: true,
        resampled: negotiated.requires_resampling,
        exclusive_unavailable_reason: None,
    };
    let verification = AudioVerificationEngine::new(ver_cfg.clone());
    if let Some(ref m) = track_meta {
        verification.set_source_metadata(m.title.clone(), m.artist.clone(), m.album.clone());
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
    inner
        .out_sample_rate
        .store(negotiated.target_sample_rate, Ordering::SeqCst);

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

    let (dev_name, bk, api_label, fade_ctrl) = match active.native_output {
        #[cfg(target_os = "windows")]
        Some(NativeOutputSession::WasapiExclusive(ref sess)) => {
            if spec.cancel_token.is_cancelled()
                || inner.current_session_id.load(Ordering::Acquire) != spec.session_id
            {
                return Ok(Ok(()));
            }
            let fc = Arc::new(AudioFadeControl::new_for_mode(
                is_dsd_wire,
                policy.strict_bit_perfect,
                spec.start_paused,
            ));
            if sess
                .try_hot_swap(crate::backend::wasapi_win::WasapiHotSwapPayload {
                    consumer: byte_cons,
                    ver_tap,
                    watermark_bytes,
                    eof_flag: Arc::clone(&eof_flag),
                    fade_ctrl: Some(Arc::clone(&fc)),
                    session_id: spec.session_id,
                    expected_format_stamp: expected_stamp,
                })
                .is_err()
            {
                return Ok(Err(decoder));
            }
            sess.set_paused(spec.start_paused);
            (
                sess.device_name.clone(),
                OutputBackendKind::WindowsWasapiExclusive,
                "WASAPI Exclusive (Event-Driven)",
                fc,
            )
        }
        Some(NativeOutputSession::VirtualWire(ref vh)) => {
            if spec.cancel_token.is_cancelled()
                || inner.current_session_id.load(Ordering::Acquire) != spec.session_id
            {
                return Ok(Ok(()));
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
                deck_gen: active_gen,
                last_ring_epoch,
            };
            active
                .expected_stamp_arc
                .store(expected_stamp, Ordering::Release);
            active
                .feeder_session_id
                .store(spec.session_id, Ordering::Release);
            inner.dual_deck.send_wire_inbox(active_idx, wire_payload);
            if vh.is_finished() {
                inner.dual_deck.clear_inboxes_for_deck(active_idx);
                return Ok(Err(decoder));
            }
            let fc = Arc::clone(&active.fade_ctrl);
            if spec.start_paused {
                fc.request_pause_fade_out();
            } else {
                fc.request_play_fade_in();
            }
            (
                VIRTUAL_DEVICE_NAME.to_string(),
                sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
                "Virtual Wire Engine",
                fc,
            )
        }
        _ => return Ok(Err(decoder)),
    };

    inner
        .cached_clock_source
        .store(backend_to_clock_src(inner.headless, bk), Ordering::Release);
    if let Ok(mut af) = inner.active_fade.write() {
        *af = Some(Arc::clone(&fade_ctrl));
    }
    if let Ok(mut vw) = inner.verification.write() {
        *vw = Some((
            verification.clone(),
            api_label.to_string(),
            dev_name.clone(),
        ));
    }
    if let Ok(mut meta_lock) = inner.active_meta.write() {
        *meta_lock = Some(ActiveTrackMeta {
            path: spec.path.clone(),
            source_label: spec.source_label.clone(),
            format: spec.format.clone(),
            duration_ms: spec.duration_ms,
            resampled_to_hz: None,
            backend: bk,
            device_name: dev_name.clone(),
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
            negotiated: negotiated.clone(),
            duration_ms: spec.duration_ms,
            pcm_rate: negotiated.target_sample_rate,
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
            track_meta: effective_deck_track_meta.clone(),
        });
    }
    inner
        .dual_deck
        .rebind_standby_for_new_profile(ActiveOutputProfile {
            session_id: spec.session_id,
            is_wire: true,
            uses_dual_feeder: allow_virtual_wire,
            output_mode: negotiated.output_mode,
            wire_format: wire,
            out_rate: negotiated.target_sample_rate,
            out_channels: negotiated.target_channels,
        });

    let dec_inner = Arc::clone(inner);
    let dec_cancel = Arc::clone(&cancel_flag);
    let dec_cancel_token = spec.cancel_token.clone();
    let dec_eof = Arc::clone(&eof_flag);
    let dec_fade = Arc::clone(&fade_ctrl);
    let dec_neg = negotiated.clone();
    let dec_caps = caps.clone();
    let dec_tx = cmd_tx.clone();
    let dec_path = spec.path.clone();
    let dec_label = spec.source_label.clone();
    let dec_sid = spec.session_id;
    let thread_guard_counter = Arc::clone(&inner.live_decode_threads);
    let decode_handle = thread::Builder::new()
        .name("lumina-wire-decoder".to_string())
        .spawn(move || {
            let _live_guard = DecodeThreadGuard::new(&thread_guard_counter);
            decode_wire_loop(
                decoder,
                byte_prod,
                unified_src,
                dec_neg,
                dec_caps,
                verification,
                ver_cfg,
                dec_inner,
                dec_cancel,
                dec_cancel_token,
                dec_eof,
                dec_fade,
                watermark_bytes,
                expected_stamp,
                dec_sid,
                dec_tx,
                dec_path,
                dec_label,
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
    active.fade_ctrl = fade_ctrl;
    active.cancel_token = spec.cancel_token.clone();
    active.eof_flag = eof_flag;
    active.path = spec.path.clone();
    active.source_label = spec.source_label.clone();
    active.origin = spec.origin.clone();
    active.format = spec.format.clone();
    active.duration_ms = spec.duration_ms;
    active.pcm_rate = negotiated.target_sample_rate;
    active.active_device_id = caps.device_id.clone();
    active.track_meta = effective_deck_track_meta;
    Ok(Ok(()))
}
