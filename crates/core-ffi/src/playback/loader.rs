use super::payload::{ADAPTIVE_DEBOUNCE_MS, parse_deck_track_metadata};
use super::resolver::{ResolvedPlaybackCandidate, resolve_candidate_async};
use super::standby::run_standby_loader_loop;
use crate::engine::{EngineState, PlayDispatchCmd};
use crate::error::set_last_error;
use core_audio::{AudioPlayer, CoreAudioError, DecoderError, OpenedStreamDecoder};
use core_types::StreamSourceSpec;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

fn is_play_cmd_current(engine: &EngineState, cmd: &PlayDispatchCmd) -> bool {
    engine.async_generation.load(Ordering::SeqCst) == cmd.generation
        && engine.play_request_id.load(Ordering::SeqCst) == cmd.request_id
        && engine.current_playback_epoch() == cmd.task_epoch
        && !cmd.cancel_token.is_cancelled()
}

fn fail_async_if_current(
    engine: &EngineState,
    generation: u64,
    request_id: u64,
    task_epoch: u64,
    cancel_token: &CancellationToken,
    msg: String,
) {
    fail_async_if_current_with_code(
        engine,
        generation,
        request_id,
        task_epoch,
        cancel_token,
        msg,
        None,
        None,
    );
}

#[allow(clippy::too_many_arguments)]
fn fail_async_if_current_with_code(
    engine: &EngineState,
    generation: u64,
    request_id: u64,
    task_epoch: u64,
    cancel_token: &CancellationToken,
    msg: String,
    code: Option<String>,
    provider: Option<String>,
) {
    let is_stale = engine.async_generation.load(Ordering::SeqCst) != generation
        || engine.play_request_id.load(Ordering::SeqCst) != request_id
        || engine.current_playback_epoch() != task_epoch
        || cancel_token.is_cancelled();
    if !is_stale {
        if let Ok(mut err_lock) = engine.async_last_error.write() {
            *err_lock = Some(msg.clone());
        }
        if let Ok(mut code_lock) = engine.async_last_error_code.write() {
            *code_lock = code;
        }
        if let Ok(mut prov_lock) = engine.async_last_error_provider.write() {
            *prov_lock = provider;
        }
        set_last_error(msg);
        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.playback_state.store(4, Ordering::SeqCst);
        engine.loaded_request_id.store(request_id, Ordering::SeqCst);
    }
}

pub(super) fn ensure_playback_loaders_started(engine: &Arc<EngineState>) {
    if let Ok(mut rx_guard) = engine.play_cmd_rx.lock()
        && let Some(rx) = rx_guard.take()
    {
        let eng = engine.clone();
        engine
            .runtime
            .spawn(async move { run_track_loader_loop(eng, rx).await });
    }
    if let Ok(mut rx_guard) = engine.standby_cmd_rx.lock()
        && let Some(rx) = rx_guard.take()
    {
        let eng = engine.clone();
        engine
            .runtime
            .spawn(async move { run_standby_loader_loop(eng, rx).await });
    }
}

pub(super) async fn ensure_l2_initialized_in_background(engine: &Arc<EngineState>) {
    let needs_l2 = engine
        .l2_cache_manager
        .read()
        .ok()
        .is_some_and(|g| g.is_none())
        && engine.db_pool.read().ok().is_some_and(|g| g.is_some());
    if needs_l2 {
        let eng_l2 = engine.clone();
        let _ = tokio::task::spawn_blocking(move || {
            let _ = crate::l2_cache::ensure_default_l2_cache_manager(&eng_l2);
        })
        .await;
    }
}

async fn run_track_loader_loop(
    engine: Arc<EngineState>,
    mut rx: watch::Receiver<Option<PlayDispatchCmd>>,
) {
    while rx.changed().await.is_ok() {
        loop {
            let Some(cmd) = rx.borrow_and_update().clone() else {
                break;
            };
            if !is_play_cmd_current(&engine, &cmd) {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            // Adaptive debounce: coalesce rapid skips (<=300ms) for 130ms unless caller already debounced.
            if !cmd.debounced && cmd.rapid_within_300ms {
                let superseded = tokio::select! {
                    biased;
                    _ = cmd.cancel_token.cancelled() => true,
                    changed = rx.changed() => {
                        if changed.is_err() {
                            return;
                        }
                        true
                    }
                    _ = tokio::time::sleep(Duration::from_millis(ADAPTIVE_DEBOUNCE_MS)) => false,
                };
                if superseded || !is_play_cmd_current(&engine, &cmd) {
                    if rx.has_changed().unwrap_or(false) {
                        continue;
                    }
                    break;
                }
            }

            ensure_l2_initialized_in_background(&engine).await;
            if !is_play_cmd_current(&engine, &cmd) {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            let candidate = tokio::select! {
                biased;
                _ = cmd.cancel_token.cancelled() => {
                    if rx.has_changed().unwrap_or(false) {
                        continue;
                    }
                    break;
                }
                changed = rx.changed() => {
                    if changed.is_err() {
                        return;
                    }
                    continue;
                }
                res = resolve_candidate_async(&engine, &cmd.payload) => match res {
                    Ok(c) => c,
                    Err(msg) => {
                        fail_async_if_current(
                            &engine,
                            cmd.generation,
                            cmd.request_id,
                            cmd.task_epoch,
                            &cmd.cancel_token,
                            msg,
                        );
                        if rx.has_changed().unwrap_or(false) {
                            continue;
                        }
                        break;
                    }
                }
            };

            if !is_play_cmd_current(&engine, &cmd) {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            let label = match &candidate {
                ResolvedPlaybackCandidate::SourceSpec { source_label, .. }
                | ResolvedPlaybackCandidate::Legacy { source_label, .. } => source_label.clone(),
            };

            let open_cancel = cmd.cancel_token.clone();
            let open_res: Result<(OpenedStreamDecoder, Option<StreamSourceSpec>), CoreAudioError> =
                match &candidate {
                    ResolvedPlaybackCandidate::SourceSpec { spec, .. } => {
                        let Some(player) = engine.player_clone() else {
                            fail_async_if_current(
                                &engine,
                                cmd.generation,
                                cmd.request_id,
                                cmd.task_epoch,
                                &cmd.cancel_token,
                                "Audio player not initialized".to_string(),
                            );
                            if rx.has_changed().unwrap_or(false) {
                                continue;
                            }
                            break;
                        };
                        tokio::select! {
                            biased;
                            _ = cmd.cancel_token.cancelled() => {
                                if rx.has_changed().unwrap_or(false) {
                                    continue;
                                }
                                break;
                            }
                            changed = rx.changed() => {
                                if changed.is_err() {
                                    return;
                                }
                                continue;
                            }
                            res = player.open_source_spec_async_with_l2(
                                spec.clone(),
                                open_cancel.clone(),
                                None,
                            ) => res.map(|(dec, adopted)| (dec, Some(adopted))),
                        }
                    }
                    ResolvedPlaybackCandidate::Legacy { stream, .. } => {
                        tokio::select! {
                            biased;
                            _ = cmd.cancel_token.cancelled() => {
                                if rx.has_changed().unwrap_or(false) {
                                    continue;
                                }
                                break;
                            }
                            changed = rx.changed() => {
                                if changed.is_err() {
                                    return;
                                }
                                continue;
                            }
                            res = AudioPlayer::open_stream_async(
                                stream.clone(),
                                open_cancel,
                                Duration::from_secs(10),
                            ) => res.map(|dec| (dec, None)),
                        }
                    }
                };

            let (decoder, adopted_spec) = match open_res {
                Ok(pair) => pair,
                Err(e) => {
                    let (err_code, err_provider, err_msg) = match &e {
                        CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
                            provider_id,
                            status,
                        }) => (
                            Some("AUTH_REQUIRED".to_string()),
                            Some(provider_id.clone()),
                            format!("Authentication required for {provider_id} (HTTP {status})"),
                        ),
                        _ => (None, None, format!("Failed to open stream ({label}): {e}")),
                    };
                    fail_async_if_current_with_code(
                        &engine,
                        cmd.generation,
                        cmd.request_id,
                        cmd.task_epoch,
                        &cmd.cancel_token,
                        err_msg,
                        err_code,
                        err_provider,
                    );
                    if rx.has_changed().unwrap_or(false) {
                        continue;
                    }
                    break;
                }
            };

            if !is_play_cmd_current(&engine, &cmd) {
                drop(decoder);
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            let eng_commit = engine.clone();
            let cmd_commit = cmd.clone();
            let _ = tokio::task::spawn_blocking(move || {
                if !is_play_cmd_current(&eng_commit, &cmd_commit) {
                    return;
                }

                let Some(player) = eng_commit.player_clone() else {
                    fail_async_if_current(
                        &eng_commit,
                        cmd_commit.generation,
                        cmd_commit.request_id,
                        cmd_commit.task_epoch,
                        &cmd_commit.cancel_token,
                        "Audio player not initialized".to_string(),
                    );
                    return;
                };

                let start_res = match &candidate {
                    ResolvedPlaybackCandidate::SourceSpec { spec, source_label } => {
                        let effective_spec = adopted_spec.as_ref().unwrap_or(spec);
                        let track_meta =
                            parse_deck_track_metadata(&cmd_commit.payload, Some(effective_spec));
                        player.start_opened_source_spec_with_metadata(
                            effective_spec,
                            decoder,
                            source_label,
                            cmd_commit.player_play_ep,
                            cmd_commit.cancel_token.clone(),
                            track_meta,
                        )
                    }
                    ResolvedPlaybackCandidate::Legacy {
                        stream,
                        source_label,
                    } => {
                        let track_meta = parse_deck_track_metadata(&cmd_commit.payload, None);
                        player.start_opened_decoder_with_epoch_and_metadata(
                            stream,
                            decoder,
                            source_label,
                            cmd_commit.player_play_ep,
                            cmd_commit.cancel_token.clone(),
                            track_meta,
                        )
                    }
                };

                if let Err(e) = start_res {
                    let msg = format!("Failed to play stream ({label}): {e}");
                    fail_async_if_current(
                        &eng_commit,
                        cmd_commit.generation,
                        cmd_commit.request_id,
                        cmd_commit.task_epoch,
                        &cmd_commit.cancel_token,
                        msg,
                    );
                    return;
                }

                if !is_play_cmd_current(&eng_commit, &cmd_commit) {
                    return;
                }

                eng_commit.has_real_stream.store(true, Ordering::SeqCst);
                eng_commit
                    .duration_ms
                    .store(player.duration_ms(), Ordering::Relaxed);
                eng_commit.position_ms.store(0, Ordering::Relaxed);
                eng_commit.playback_state.store(2, Ordering::SeqCst);
                eng_commit
                    .loaded_request_id
                    .store(cmd_commit.request_id, Ordering::SeqCst);
            })
            .await;

            if rx.has_changed().unwrap_or(false) {
                continue;
            }
            break;
        }
    }
}
