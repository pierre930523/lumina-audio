//! Paced virtual DAC consumers for headless/virtual wire and float PCM playback.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use core_types::{OutputBackendKind, PlaybackLifecycleState};

use crate::backend::device_manager::NegotiatedFormat;
use crate::engine::dual_deck::{
    DualDeckPcmFeeder, DualDeckWireFeeder, DualDeckWireOutcome, PcmRenderOutcome,
    RtWireInboxPayload,
};
use crate::engine::{PlayerInner, VIRTUAL_DEVICE_NAME};
use crate::error::BackendError;
use crate::pipeline::fade::{
    AudioFadeControl, FadeDirection, FadeTarget, LinearFadeState,
    apply_fade_ramp_to_wire_bytes_guarded,
};
use crate::pipeline::ring_buffer::Consumer;
use crate::verification::{AudioVerificationEngine, WireSampleFormat};

use super::types::{NativeOutputSession, OutputReuseKey};

#[allow(clippy::too_many_arguments)]
pub(super) fn spawn_virtual_wire_consumer(
    mut feeder: DualDeckWireFeeder,
    wire: WireSampleFormat,
    out_rate: u32,
    out_channels: u16,
    inner: Arc<PlayerInner>,
    output_kill_flag: Arc<AtomicBool>,
    active_session_id: Arc<AtomicU64>,
    watermark_bytes: usize,
    fade_ctrl: Arc<AudioFadeControl>,
    expected_format_stamp: Arc<AtomicU64>,
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

                if let Some(new_wm) = feeder.poll_inbox() {
                    buffering_gate = new_wm > 0;
                    fade.reset_for_play_start();
                    dop_phase = false;
                }

                let fade_target = fade_ctrl.target();
                let in_skip_silence = fade_target == FadeTarget::SkipSilence;
                if matches!(
                    fade_target,
                    FadeTarget::PauseFadeOut
                        | FadeTarget::StopFadeOut
                        | FadeTarget::SeekFadeOut
                        | FadeTarget::SkipSilence
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
                            apply_fade_ramp_to_wire_bytes_guarded(
                                &mut scratch[..aligned],
                                wire,
                                ch,
                                &mut fade,
                                FadeDirection::Down,
                                inner.strict_bit_perfect.load(Ordering::Relaxed),
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

                // RT Format-Mismatch Silence Guard: never output mismatched PCM bytes
                let expected_stamp = expected_format_stamp.load(Ordering::Acquire);
                let stamp_mismatch = expected_stamp != 0
                    && inner.published_format_stamp.load(Ordering::Acquire) != expected_stamp;
                if inner.format_mismatch_flag.load(Ordering::Acquire) || stamp_mismatch {
                    if stamp_mismatch {
                        inner.format_mismatch_flag.store(true, Ordering::Release);
                    }
                    scratch.fill(sil_byte);
                    fade_ctrl.mark_silent();
                    continue;
                }

                if inner.stopped.load(Ordering::Relaxed)
                    || (!in_skip_silence
                        && inner.current_session_id.load(Ordering::Relaxed)
                            != active_session_id.load(Ordering::Acquire))
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
                            if let Some(new_wm) = feeder.poll_inbox() {
                                buffering_gate = new_wm > 0;
                                fade.reset_for_play_start();
                                dop_phase = false;
                                continue;
                            }
                            if fade_ctrl.target() == FadeTarget::SkipSilence {
                                continue;
                            }
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
pub(super) fn spawn_virtual_consumer(
    mut feeder: DualDeckPcmFeeder,
    out_rate: u32,
    out_channels: u16,
    inner: Arc<PlayerInner>,
    output_kill_flag: Arc<AtomicBool>,
    active_session_id: Arc<AtomicU64>,
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

                let in_skip_silence = fade_ctrl.target() == FadeTarget::SkipSilence;
                if inner.stopped.load(Ordering::Relaxed)
                    || (!in_skip_silence
                        && inner.current_session_id.load(Ordering::Relaxed)
                            != active_session_id.load(Ordering::Acquire))
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
                    if fade_ctrl.target() == FadeTarget::StopFadeOut && fade_ctrl.is_fade_out_done()
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

/// Opens a paced virtual wire consumer session and prepares the initial `RtWireInboxPayload`.
#[allow(clippy::too_many_arguments)]
pub(super) fn open_virtual_wire_session(
    inner: &Arc<PlayerInner>,
    negotiated: &NegotiatedFormat,
    wire: WireSampleFormat,
    byte_cons: Consumer<u8>,
    verification: &AudioVerificationEngine,
    watermark_bytes: usize,
    fade_ctrl: &Arc<AudioFadeControl>,
    expected_stamp: u64,
    output_kill_flag: &Arc<AtomicBool>,
    feeder_session_id: &Arc<AtomicU64>,
    expected_stamp_arc: &Arc<AtomicU64>,
    active_idx: usize,
    active_gen: u64,
    preferred_buffer_frames: u32,
    sel_backend: Option<OutputBackendKind>,
) -> Result<
    (
        NativeOutputSession,
        u32,
        String,
        OutputBackendKind,
        &'static str,
        OutputReuseKey,
    ),
    BackendError,
> {
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
        Arc::clone(&inner.playback_epoch),
        Arc::clone(&inner.strict_bit_perfect),
        Arc::clone(&inner.rt_telemetry),
        active_idx,
        wire_payload,
    );
    let h = spawn_virtual_wire_consumer(
        feeder,
        wire,
        negotiated.target_sample_rate,
        negotiated.target_channels,
        Arc::clone(inner),
        Arc::clone(output_kill_flag),
        Arc::clone(feeder_session_id),
        watermark_bytes,
        Arc::clone(fade_ctrl),
        Arc::clone(expected_stamp_arc),
    );
    Ok((
        NativeOutputSession::VirtualWire(h),
        preferred_buffer_frames,
        VIRTUAL_DEVICE_NAME.to_string(),
        sel_backend.unwrap_or(OutputBackendKind::WindowsWasapiExclusive),
        "Virtual Wire Engine",
        OutputReuseKey::VirtualWire {
            output_mode: negotiated.output_mode,
            wire_format: wire,
            sample_rate: negotiated.target_sample_rate,
            channels: negotiated.target_channels,
        },
    ))
}
