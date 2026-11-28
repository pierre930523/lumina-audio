//! Exclusive/ASIO packed-wire background decode worker loop.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use core_types::{AudioDeviceCapabilities, UnifiedAudioFormat};
use tokio_util::sync::CancellationToken;

use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::AudioDecoder;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::session::StandbyDeckGate;
use crate::engine::{PlayerInner, position_ms_from_inner};
use crate::pipeline::fade::AudioFadeControl;
use crate::pipeline::ring_buffer::Producer;
use crate::verification::{
    AudioVerificationEngine, VerificationConfig, WireFormatStamp, WireSampleFormat,
};

use super::diagnostics::{OpusDiagnosticDumper, maybe_log_underrun_off_rt};
use super::dsp_stage::{WireDspState, check_wire_chunk_format_mismatch};
use super::gapless::{NextTrackOutcome, handle_decode_error, try_open_gapless_or_switch};
use super::pcm_stage::push_slice_to_ring;
use super::seek::{SeekOutcome, handle_seek_request, maybe_reclaim_idle_memory, wait_at_eof};

#[allow(clippy::too_many_arguments)]
pub(crate) fn decode_wire_loop(
    mut decoder: Box<dyn AudioDecoder>,
    mut producer: Producer<u8>,
    mut curr_unified: UnifiedAudioFormat,
    mut curr_neg: NegotiatedFormat,
    curr_caps: AudioDeviceCapabilities,
    verification: AudioVerificationEngine,
    ver_cfg: VerificationConfig,
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
    let mut wire_state = WireDspState::new(ver_cfg);
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
            match handle_seek_request(
                decoder.as_mut(),
                &mut producer,
                &inner,
                &cancel_flag,
                &cancel_token,
                &eof_flag,
                &fade_ctrl,
                session_id,
                &cmd_tx,
                req_seek as u64,
                "Decoder wire seek",
                || {
                    wire_state.reset_for_seek();
                    verification.reset_streams();
                },
            ) {
                SeekOutcome::Done => {}
                SeekOutcome::ContinueLoop => continue,
                SeekOutcome::ReturnDecoder => return Some(decoder),
                SeekOutcome::Abort => return None,
            }
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
                let buffered = producer
                    .capacity()
                    .saturating_sub(producer.available_write());
                if buffered >= watermark_bytes {
                    thread::sleep(Duration::from_millis(2));
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

                let wire_bytes =
                    wire_state.pack_chunk(&chunk, &curr_neg, &inner, &verification, deck_idx);

                let bpf = curr_neg.wire_format.bytes_per_sample().max(1)
                    * (curr_neg.target_channels.max(1) as usize);
                let clock_rate =
                    if matches!(curr_neg.wire_format, WireSampleFormat::NativeDsd { .. }) {
                        (curr_neg.target_sample_rate / 8).max(44_100) as u64
                    } else {
                        curr_neg.target_sample_rate.max(8_000) as u64
                    };
                if !push_slice_to_ring(
                    wire_bytes,
                    bpf,
                    clock_rate,
                    &mut producer,
                    &inner,
                    &cancel_flag,
                    &cancel_token,
                    deck_idx,
                    deck_gen,
                    &standby_gate,
                    true,
                ) {
                    return Some(decoder);
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
                match try_open_gapless_or_switch(
                    &curr_unified,
                    &curr_neg,
                    &curr_caps,
                    &inner,
                    Some(&verification),
                    true,
                    &cancel_flag,
                    &cancel_token,
                    &eof_flag,
                    session_id,
                    &cmd_tx,
                ) {
                    NextTrackOutcome::Gapless(t) => {
                        expected_stamp = WireFormatStamp::from_wire(
                            t.negotiated.target_sample_rate,
                            t.negotiated.target_channels,
                            t.negotiated.wire_format,
                        )
                        .0;
                        curr_path = t.path;
                        curr_label = t.label;
                        curr_unified = t.unified;
                        curr_neg = t.negotiated;
                        decoder = t.decoder;
                        opus_dumper = OpusDiagnosticDumper::maybe_new(
                            curr_unified.codec,
                            &inner,
                            curr_neg.target_sample_rate,
                            curr_neg.target_channels,
                            format!("{:?}", curr_neg.wire_format),
                        );
                        continue;
                    }
                    NextTrackOutcome::ReturnDecoder => return Some(decoder),
                    NextTrackOutcome::Abort => return None,
                    NextTrackOutcome::NoneOrFailed => {}
                }
                let _ = (&curr_path, &curr_label);
                if wait_at_eof(
                    &inner,
                    decoder.as_mut(),
                    &cancel_flag,
                    &cancel_token,
                    &eof_flag,
                    &mut paused_since,
                    &mut idle_reclaimed,
                ) {
                    continue;
                }
                return None;
            }
            Err(e) => {
                if handle_decode_error(
                    e,
                    &inner,
                    &cancel_flag,
                    &cancel_token,
                    &eof_flag,
                    session_id,
                    &cmd_tx,
                    "Wire audio decode error",
                ) {
                    return Some(decoder);
                }
                return None;
            }
        }
    }
}
