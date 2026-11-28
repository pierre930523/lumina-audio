//! Shared/cpal float-PCM background decode worker loop.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use core_types::{AudioDeviceCapabilities, UnifiedAudioFormat};
use cpal::SampleFormat;
use tokio_util::sync::CancellationToken;

use crate::backend::device_manager::NegotiatedFormat;
use crate::decoder::pcm::AudioDecoder;
use crate::engine::PlayerInner;
use crate::engine::coordinator::PlayerCommand;
use crate::engine::session::StandbyDeckGate;
use crate::pipeline::fade::AudioFadeControl;
use crate::pipeline::ring_buffer::Producer;
use crate::verification::AudioVerificationEngine;

use super::diagnostics::{OpusDiagnosticDumper, maybe_log_underrun_off_rt};
use super::gapless::{NextTrackOutcome, handle_decode_error, try_open_gapless_or_switch};
use super::pcm_stage::{PcmDspState, push_slice_to_ring};
use super::seek::{SeekOutcome, handle_seek_request, maybe_reclaim_idle_memory, wait_at_eof};

#[allow(clippy::too_many_arguments)]
pub(crate) fn decode_loop(
    mut decoder: Box<dyn AudioDecoder>,
    mut producer: Producer<f32>,
    initial_pcm_rate: u32,
    out_rate: u32,
    out_channels: u16,
    out_sample_format: Option<SampleFormat>,
    inner: Arc<PlayerInner>,
    verification: Option<AudioVerificationEngine>,
    mut curr_unified: UnifiedAudioFormat,
    mut curr_neg: NegotiatedFormat,
    curr_caps: AudioDeviceCapabilities,
    cancel_flag: Arc<AtomicBool>,
    cancel_token: CancellationToken,
    eof_flag: Arc<AtomicBool>,
    fade_ctrl: Arc<AudioFadeControl>,
    watermark_samples: usize,
    session_id: u64,
    cmd_tx: mpsc::Sender<PlayerCommand>,
    deck_idx: usize,
    deck_gen: u64,
    mut standby_gate: Option<StandbyDeckGate>,
) -> Option<Box<dyn AudioDecoder>> {
    let mut pcm_state =
        PcmDspState::new(initial_pcm_rate, out_rate, out_channels, &inner, deck_idx);
    let mut paused_since: Option<Instant> = None;
    let mut idle_reclaimed = false;
    let mut last_logged_underruns = inner.ring_buffer_underrun_count.load(Ordering::Relaxed);
    let mut last_underrun_log_at = Instant::now() - Duration::from_secs(2);
    let out_fmt_label =
        out_sample_format.map_or_else(|| "Unknown".to_string(), |fmt| format!("{fmt:?}"));
    let mut opus_dumper = OpusDiagnosticDumper::maybe_new(
        curr_unified.codec,
        &inner,
        out_rate,
        out_channels,
        out_fmt_label.clone(),
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
                "Decoder seek",
                || {
                    pcm_state.reset_for_seek();
                    if let Some(ref v) = verification {
                        v.reset_streams();
                    }
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

            // Seek-while-paused prefill: decode up to the 200 ms watermark even while paused.
            if inner.paused.load(Ordering::Relaxed) {
                let buffered = producer
                    .capacity()
                    .saturating_sub(producer.available_write());
                if buffered >= watermark_samples {
                    thread::sleep(Duration::from_millis(2));
                    continue;
                }
            }
        }

        match decoder.next_chunk() {
            Ok(Some(chunk)) => {
                if let Some(ref v) = verification {
                    v.record_decoder_output(&chunk);
                }
                if let Some(ref mut dumper) = opus_dumper {
                    dumper.record_chunk(&chunk);
                }

                pcm_state.process_chunk(
                    &chunk,
                    out_rate,
                    out_channels,
                    &inner,
                    verification.as_ref(),
                    deck_idx,
                );

                let out_ch = out_channels.max(1) as usize;
                let out_rate_u64 = out_rate.max(8_000) as u64;
                if !push_slice_to_ring(
                    &pcm_state.f32_scratch,
                    out_ch,
                    out_rate_u64,
                    &mut producer,
                    &inner,
                    &cancel_flag,
                    &cancel_token,
                    deck_idx,
                    deck_gen,
                    &standby_gate,
                    false,
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
                // Flush any remaining windowed-sinc resampler tail frames before EOF so
                // total output length stays exact without trailing truncation.
                if pcm_state.flush_resampler_tail(
                    out_rate,
                    out_channels,
                    &inner,
                    verification.as_ref(),
                ) {
                    let out_ch = out_channels.max(1) as usize;
                    let out_rate_u64 = out_rate.max(8_000) as u64;
                    let _ = push_slice_to_ring(
                        &pcm_state.f32_scratch,
                        out_ch,
                        out_rate_u64,
                        &mut producer,
                        &inner,
                        &cancel_flag,
                        &cancel_token,
                        deck_idx,
                        deck_gen,
                        &standby_gate,
                        false,
                    );
                }
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
                    verification.as_ref(),
                    false,
                    &cancel_flag,
                    &cancel_token,
                    &eof_flag,
                    session_id,
                    &cmd_tx,
                ) {
                    NextTrackOutcome::Gapless(t) => {
                        curr_unified = t.unified;
                        curr_neg = t.negotiated;
                        decoder = t.decoder;
                        pcm_state.resampler.reset();
                        opus_dumper = OpusDiagnosticDumper::maybe_new(
                            curr_unified.codec,
                            &inner,
                            out_rate,
                            out_channels,
                            out_fmt_label.clone(),
                        );
                        continue;
                    }
                    NextTrackOutcome::ReturnDecoder => return Some(decoder),
                    NextTrackOutcome::Abort => return None,
                    NextTrackOutcome::NoneOrFailed => {}
                }
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
                    "Audio decode error",
                ) {
                    return Some(decoder);
                }
                return None;
            }
        }
    }
}
