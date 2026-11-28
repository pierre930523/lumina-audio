//! Standby deck pre-buffering gate and wire/shared standby worker.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::Duration;

use core_types::{
    DeckState, DeckTrackMetadata, DeviceTransportKind, DsdOutputMode, OutputBackendKind,
    OutputMode, StreamSourceSpec,
};
use tokio_util::sync::CancellationToken;

use crate::backend::device_manager::AudioFormatManager;
use crate::decoder::pcm::AudioDecoder;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::dual_deck::{
    DeckMetadataSnapshot, DualDeckControl, RtPcmInboxPayload, RtWireInboxPayload, StandbyWakeState,
};
use crate::engine::{PlayerInner, PlayerOrigin, VIRTUAL_DEVICE_NAME, is_any_dsp_active};
use crate::pipeline::decode_worker::decode_wire_loop;
use crate::pipeline::fade::{
    AudioFadeControl, STANDBY_PREDECODE_MS, compute_startup_watermark_bytes,
    compute_wire_ring_bytes,
};
use crate::pipeline::ring_buffer::SpscRingBuffer;
use crate::verification::{
    AudioVerificationEngine, VerificationConfig, WireFormatStamp, WireSampleFormat,
};

use super::standby_pcm::run_standby_pcm_worker;
use super::types::resolve_target_capabilities;

pub(crate) struct StandbyDeckGate {
    pub(crate) target_ms: u64,
    pub(super) is_mismatch_recovery: bool,
    pub(super) mismatch_pts_ms: u64,
    pub(super) mismatch_frame: u64,
    pub(super) out_rate: u32,
    pub(super) pending_pcm: Option<RtPcmInboxPayload>,
    pub(super) pending_wire: Option<RtWireInboxPayload>,
    pub(super) wake: Arc<(Mutex<StandbyWakeState>, Condvar)>,
}

impl StandbyDeckGate {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn complete_prebuffer_and_park(
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
            inner.dual_deck.mismatch_armed.store(true, Ordering::SeqCst);
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
pub(crate) fn run_standby_deck_worker(
    inner: Arc<PlayerInner>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
    deck_idx: usize,
    deck_gen: u64,
    origin: PlayerOrigin,
    source_label: String,
    incoming_track_meta: Option<DeckTrackMetadata>,
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
        inner.dual_deck.set_deck_track_meta(deck_idx, None);
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
                inner.dual_deck.set_deck_track_meta(deck_idx, None);
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
    inner
        .dual_deck
        .standby_buffered_ms
        .store(0, Ordering::Relaxed);

    let path = origin.display_path();
    let format = decoder.format().clone();
    let duration_ms = decoder
        .duration()
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let standby_track_meta = incoming_track_meta.map(|mut m| {
        if duration_ms > 0 {
            m.duration_ms = duration_ms;
        }
        m
    });
    inner
        .dual_deck
        .set_deck_track_meta(deck_idx, standby_track_meta.clone());
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
                track_meta: standby_track_meta,
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

    run_standby_pcm_worker(
        decoder,
        inner,
        cmd_tx,
        deck_idx,
        deck_gen,
        path,
        source_label,
        origin,
        format,
        unified_src,
        track_meta,
        standby_track_meta,
        rg_tags,
        caps,
        policy,
        sel_id,
        sel_backend,
        dsp_bypassed,
        eff_vol,
        duration_ms,
        pcm_rate,
        default_out_channels,
        predecode_target_ms,
        is_mismatch_recovery,
        mismatch_pts_ms,
        mismatch_frame,
        session_id,
        cancel_flag,
        cancel_token,
        eof_flag,
        fade_ctrl,
        wake,
    )
}
