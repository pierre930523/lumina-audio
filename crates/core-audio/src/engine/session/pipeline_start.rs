//! Fresh output pipeline startup (`start_output_pipeline`) and native wire path.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread;

use core_types::{
    AudioCodec, DeckState, DeviceTransportKind, DsdOutputMode, OutputBackendKind, OutputMode,
    PlaybackLifecycleState,
};

use crate::backend::device_manager::AudioFormatManager;
use crate::decoder::pcm::{AudioDecoder, DecodedTrackMetadata};
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dual_deck::{
    ActiveOutputProfile, DeckDecodeHandle, DeckMetadataSnapshot, DecodeThreadGuard,
    StandbyWakeState,
};
use crate::engine::{ActiveTrackMeta, PlayerInner, is_any_dsp_active};
use crate::error::{BackendError, CoreAudioError};
use crate::pipeline::decode_worker::{decode_wire_loop, is_opus_dump_enabled};
use crate::pipeline::fade::{
    AudioFadeControl, compute_startup_watermark_bytes, compute_wire_ring_bytes,
};
use crate::pipeline::ring_buffer::SpscRingBuffer;
use crate::verification::{
    AudioVerificationEngine, VerificationConfig, WireFormatStamp, WireSampleFormat,
};

use super::active::ActiveSession;
use super::native_open::open_native_wire_session;
use super::pipeline_start_pcm::start_pcm_pipeline;
use super::types::{
    NativeOutputSession, PipelineSpec, backend_to_clock_src, resolve_target_capabilities,
};
use super::virtual_out::open_virtual_wire_session;

pub(crate) fn start_output_pipeline(
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
        track_meta: incoming_deck_track_meta,
        cancel_token,
        format,
        duration_ms,
        start_paused,
    } = spec;
    let effective_deck_track_meta = incoming_deck_track_meta.map(|mut m| {
        if duration_ms > 0 {
            m.duration_ms = duration_ms;
        }
        m
    });
    let _ = crate::visualizer::init_global_tap();
    let active_idx = inner.dual_deck.active_idx();
    let active_gen = inner.dual_deck.alloc_deck_gen(active_idx);
    inner.dual_deck.deck_states[active_idx].store(DeckState::Playing as u8, Ordering::SeqCst);
    inner
        .dual_deck
        .set_deck_key(active_idx, origin.stream_key());
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
            let initial_wire_dsp_active = !policy.strict_bit_perfect
                && !dsp_bypassed
                && !is_dsd_wire
                && is_any_dsp_active(inner);
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
            let fade_ctrl = Arc::new(AudioFadeControl::new_for_mode(
                is_dsd_wire,
                policy.strict_bit_perfect,
                start_paused,
            ));

            let feeder_session_id = Arc::new(AtomicU64::new(session_id));
            let expected_stamp_arc = Arc::new(AtomicU64::new(expected_stamp));
            let native_attempt = if allow_virtual_wire {
                open_virtual_wire_session(
                    inner,
                    negotiated,
                    wire,
                    byte_cons,
                    &verification,
                    watermark_bytes,
                    &fade_ctrl,
                    expected_stamp,
                    &output_kill_flag,
                    &feeder_session_id,
                    &expected_stamp_arc,
                    active_idx,
                    active_gen,
                    policy.preferred_buffer_frames,
                    sel_backend,
                )
            } else {
                open_native_wire_session(
                    inner,
                    &caps,
                    negotiated,
                    &policy,
                    byte_cons,
                    &verification,
                    &eof_flag,
                    session_id,
                    watermark_bytes,
                    &fade_ctrl,
                    expected_stamp,
                    start_paused,
                )
            };

            match native_attempt {
                Ok((native_sess, actual_frames, dev_name, bk, api_label, reuse_key)) => {
                    inner.output_reopen_count.fetch_add(1, Ordering::Relaxed);
                    inner
                        .cached_clock_source
                        .store(backend_to_clock_src(inner.headless, bk), Ordering::Release);
                    #[cfg(target_os = "windows")]
                    match &native_sess {
                        NativeOutputSession::WasapiExclusive(s) => {
                            inner.set_active_wasapi_ctrl(Some(s.control()));
                        }
                        _ => inner.set_active_wasapi_ctrl(None),
                    }
                    #[cfg(not(target_os = "windows"))]
                    inner.set_active_wasapi_ctrl();
                    native_sess.set_eof_state_code(PlaybackLifecycleState::Ended as i32);
                    verification.set_buffer_size_frames(actual_frames);
                    let mut dec_ver_cfg = ver_cfg;
                    dec_ver_cfg.buffer_size_frames = actual_frames;
                    let rate_for_pos = negotiated.target_sample_rate;
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
                        *vw = Some((
                            verification.clone(),
                            api_label.to_string(),
                            dev_name.clone(),
                        ));
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
                            track_meta: effective_deck_track_meta.clone(),
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
                        output_reuse_key: reuse_key,
                        feeder_session_id,
                        expected_stamp_arc,
                        path,
                        source_label,
                        origin,
                        format,
                        duration_ms,
                        pcm_rate: rate_for_pos,
                        active_device_id: caps.device_id,
                        track_meta: effective_deck_track_meta,
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

    start_pcm_pipeline(
        inner,
        decoder,
        cmd_tx,
        active_idx,
        active_gen,
        session_id,
        pcm_rate,
        default_out_channels,
        path,
        source_label,
        origin,
        effective_deck_track_meta,
        cancel_flag,
        output_kill_flag,
        eof_flag,
        cancel_token,
        format,
        duration_ms,
        start_paused,
        unified_src,
        track_meta,
        caps,
        policy,
        sel_id,
        dsp_bypassed,
        eff_vol,
        exclusive_fallback_reason,
    )
}
