//! Reopening an output pipeline directly from a pre-buffered Standby deck.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use core_types::{
    AudioCodec, DeviceTransportKind, OutputBackendKind, OutputMode, PlaybackLifecycleState,
};
use cpal::SampleFormat;
use cpal::traits::StreamTrait;
use tokio_util::sync::CancellationToken;

use crate::backend::cpal_shared::enumerate_cpal_devices;
use crate::engine::dual_deck::{ActiveOutputProfile, DualDeckPcmFeeder, DualDeckWireFeeder};
use crate::engine::{PlayerInner, VIRTUAL_DEVICE_ID, VIRTUAL_DEVICE_NAME};
use crate::error::{BackendError, CoreAudioError};
use crate::pipeline::decode_worker::is_opus_dump_enabled;
use crate::pipeline::fade::AudioFadeControl;
use crate::verification::WireSampleFormat;

use super::active::ActiveSession;
use super::cpal_out::open_cpal_output_with_payload;
use super::native_open::open_native_wire_session;
use super::types::{
    NativeOutputSession, OutputReuseKey, backend_to_clock_src, commit_deck_metadata_to_inner,
    resolve_target_capabilities,
};
use super::virtual_out::{spawn_virtual_consumer, spawn_virtual_wire_consumer};

pub(crate) fn start_output_pipeline_from_standby(
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
        let fade_ctrl = Arc::new(AudioFadeControl::new_for_mode(
            is_dsd_wire,
            policy.strict_bit_perfect,
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

        let feeder_session_id = Arc::new(AtomicU64::new(session_id));
        let expected_stamp_arc = Arc::new(AtomicU64::new(expected_stamp));
        let (native_sess, actual_frames, dev_name, bk, api_label, reuse_key) = if allow_virtual_wire
        {
            let feeder = DualDeckWireFeeder::new(
                Arc::clone(&inner.dual_deck),
                Arc::clone(&inner.frames_rendered),
                Arc::clone(&inner.nonzero_output_frames),
                Arc::clone(&inner.buffered_ms),
                Arc::clone(&inner.gapless_transitions),
                Arc::clone(&inner.ring_buffer_underrun_count),
                Arc::clone(&inner.playback_epoch),
                Arc::clone(&inner.strict_bit_perfect),
                Arc::clone(&inner.rt_telemetry),
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
                Arc::clone(&feeder_session_id),
                watermark_bytes,
                Arc::clone(&fade_ctrl),
                Arc::clone(&expected_stamp_arc),
            );
            (
                NativeOutputSession::VirtualWire(h),
                policy.preferred_buffer_frames,
                VIRTUAL_DEVICE_NAME.to_string(),
                sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
                "Virtual Wire Engine",
                OutputReuseKey::VirtualWire {
                    output_mode: snap.negotiated.output_mode,
                    wire_format: wire,
                    sample_rate: snap.out_rate,
                    channels: snap.out_channels,
                },
            )
        } else {
            open_native_wire_session(
                inner,
                &caps,
                &snap.negotiated,
                &policy,
                payload.consumer,
                &snap.verification,
                &eof_flag,
                session_id,
                watermark_bytes,
                &fade_ctrl,
                expected_stamp,
                start_paused,
            )
            .map_err(CoreAudioError::Backend)?
        };

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
            output_reuse_key: reuse_key,
            feeder_session_id,
            expected_stamp_arc,
            path: updated_snap.path,
            source_label: updated_snap.source_label,
            origin: updated_snap.origin,
            format: updated_snap.format,
            duration_ms: updated_snap.duration_ms,
            pcm_rate: updated_snap.pcm_rate,
            active_device_id: updated_snap.active_device_id,
            track_meta: updated_snap.track_meta,
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
    let feeder_session_id = Arc::new(AtomicU64::new(session_id));
    let expected_stamp_arc = Arc::new(AtomicU64::new(0));
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
        reuse_key,
    ) = if use_virtual {
        let out_rate = payload.out_rate;
        let out_channels = payload.out_channels;
        let feeder = DualDeckPcmFeeder::new(
            Arc::clone(&inner.dual_deck),
            Arc::clone(inner),
            Arc::clone(&feeder_session_id),
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
            Arc::clone(&feeder_session_id),
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
            OutputReuseKey::VirtualPcm {
                sample_rate: out_rate,
                channels: out_channels,
            },
        )
    } else {
        let (stream, actual_rate, actual_ch, sample_fmt, bk, dev_name) =
            open_cpal_output_with_payload(
                to_deck,
                payload,
                inner,
                &output_kill_flag,
                Arc::clone(&feeder_session_id),
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
        output_reuse_key: reuse_key,
        feeder_session_id,
        expected_stamp_arc,
        path: updated_snap.path,
        source_label: updated_snap.source_label,
        origin: updated_snap.origin,
        format: updated_snap.format,
        duration_ms: updated_snap.duration_ms,
        pcm_rate: updated_snap.pcm_rate,
        active_device_id: updated_snap.active_device_id,
        track_meta: updated_snap.track_meta,
    })
}
