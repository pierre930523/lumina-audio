use super::models::{SERVER_DEBOUNCE_MS, ServerResolvedCandidate};
use crate::state::{AppState, ServerPlayCmd, now_unix_ms, signal_path_to_payload};
use crate::ws::messages::WsMessage;
use core_audio::{AudioPlayer, CoreAudioError, OpenedStreamDecoder, StreamSource};
use core_db::LibraryRepository;
use core_types::{
    DeckTrackMetadata, LuminaError, LuminaErrorCode, PlaybackLifecycleState, StreamSourceSpec,
    TrackMetadata,
};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::watch;

fn is_server_cmd_current(state: &AppState, cmd: &ServerPlayCmd) -> bool {
    state.play_generation.load(Ordering::SeqCst) == cmd.generation
        && state.current_playback_epoch() == cmd.task_epoch
        && !cmd.cancel_token.is_cancelled()
}

async fn set_server_play_error(state: &AppState, cmd: &ServerPlayCmd, err: LuminaError) {
    *state.last_structured_error.write().await = Some(err.clone());
    {
        let mut st = state.playback_state.write().await;
        st.status = "error".to_string();
        st.state_code = PlaybackLifecycleState::Error.as_i32();
        st.state_name = PlaybackLifecycleState::Error
            .as_legacy_state_name()
            .to_string();
        st.playback_epoch = cmd.task_epoch;
        st.timestamp_ms = now_unix_ms();
        st.error = Some(err);
    }
    state
        .loaded_generation
        .store(cmd.generation, Ordering::SeqCst);
    state.broadcast_playback_state().await;
}

async fn resolve_server_candidate(
    state: &AppState,
    cmd: &ServerPlayCmd,
) -> Result<Option<ServerResolvedCandidate>, String> {
    if let Some(ref spec) = cmd.source_spec {
        if let StreamSourceSpec::ExternalBackend {
            key, provider_id, ..
        } = spec
        {
            return Err(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                key.track_id
            ));
        }
        let label = cmd
            .source
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| spec.key().provider_id.clone());
        return Ok(Some(ServerResolvedCandidate::SourceSpec {
            spec: spec.clone(),
            label,
        }));
    }

    if let Some(ref url) = cmd.stream_url {
        let stream = StreamSource::http(
            url,
            cmd.headers.clone().unwrap_or_default(),
            cmd.hint_extension.clone(),
        );
        return Ok(Some(ServerResolvedCandidate::Legacy {
            stream,
            label: cmd
                .source
                .clone()
                .unwrap_or_else(|| "HTTP Stream".to_string()),
        }));
    }

    if let Some(ref path_str) = cmd.file_path {
        if path_str.starts_with("http://") || path_str.starts_with("https://") {
            let stream = StreamSource::http(
                path_str,
                cmd.headers.clone().unwrap_or_default(),
                cmd.hint_extension.clone(),
            );
            return Ok(Some(ServerResolvedCandidate::Legacy {
                stream,
                label: cmd
                    .source
                    .clone()
                    .unwrap_or_else(|| "HTTP Stream".to_string()),
            }));
        }
        if Path::new(path_str).is_file() {
            return Ok(Some(ServerResolvedCandidate::Legacy {
                stream: StreamSource::local_file(path_str),
                label: cmd
                    .source
                    .clone()
                    .unwrap_or_else(|| "Local Library".to_string()),
            }));
        }
    }

    if let Some(ref tid) = cmd.track_id {
        if tid.starts_with("http://") || tid.starts_with("https://") {
            return Ok(Some(ServerResolvedCandidate::Legacy {
                stream: StreamSource::http(
                    tid,
                    cmd.headers.clone().unwrap_or_default(),
                    cmd.hint_extension.clone(),
                ),
                label: cmd
                    .source
                    .clone()
                    .unwrap_or_else(|| "HTTP Stream".to_string()),
            }));
        }
        if Path::new(tid).is_file() {
            return Ok(Some(ServerResolvedCandidate::Legacy {
                stream: StreamSource::local_file(tid),
                label: cmd
                    .source
                    .clone()
                    .unwrap_or_else(|| "Local Library".to_string()),
            }));
        }
        if let Some(ref pool) = state.db_pool
            && let Ok(Some(trk)) = LibraryRepository::find_track_source_by_id(pool, tid).await
        {
            if let Ok(resolved) = state.provider_manager.resolve_stream(&trk).await {
                let header_map: HashMap<String, String> = resolved.headers.into_iter().collect();
                let hint = resolved
                    .hint_extension
                    .or_else(|| Some(trk.format.codec.as_str().to_string()));
                if resolved.url_or_path.starts_with("http://")
                    || resolved.url_or_path.starts_with("https://")
                {
                    let stream = StreamSource::http(resolved.url_or_path, header_map, hint)
                        .with_replay_gain(
                            resolved.replay_gain_track_db,
                            resolved.replay_gain_album_db,
                            resolved.replay_gain_track_peak,
                            resolved.replay_gain_album_peak,
                        );
                    return Ok(Some(ServerResolvedCandidate::Legacy {
                        stream,
                        label: trk.provider.display_name().to_string(),
                    }));
                }
                if Path::new(&resolved.url_or_path).is_file() {
                    let stream = StreamSource::local_file(&resolved.url_or_path).with_replay_gain(
                        resolved.replay_gain_track_db,
                        resolved.replay_gain_album_db,
                        resolved.replay_gain_track_peak,
                        resolved.replay_gain_album_peak,
                    );
                    return Ok(Some(ServerResolvedCandidate::Legacy {
                        stream,
                        label: trk.provider.display_name().to_string(),
                    }));
                }
            } else if Path::new(&trk.external_track_id).is_file() {
                let stream = StreamSource::local_file(&trk.external_track_id).with_replay_gain(
                    trk.replay_gain_track_db,
                    trk.replay_gain_album_db,
                    trk.replay_gain_track_peak,
                    trk.replay_gain_album_peak,
                );
                return Ok(Some(ServerResolvedCandidate::Legacy {
                    stream,
                    label: trk.provider.display_name().to_string(),
                }));
            }
        }
    }

    Ok(None)
}

pub(super) fn ensure_server_play_worker_started(state: &Arc<AppState>) {
    if let Ok(mut guard) = state.play_cmd_rx.lock()
        && let Some(rx) = guard.take()
    {
        let st = state.clone();
        tokio::spawn(async move { run_server_track_loader(st, rx).await });
    }
}

async fn run_server_track_loader(
    state: Arc<AppState>,
    mut rx: watch::Receiver<Option<ServerPlayCmd>>,
) {
    while rx.changed().await.is_ok() {
        loop {
            let Some(cmd) = rx.borrow_and_update().clone() else {
                break;
            };
            if !is_server_cmd_current(&state, &cmd) {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

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
                    _ = tokio::time::sleep(Duration::from_millis(SERVER_DEBOUNCE_MS)) => false,
                };
                if superseded || !is_server_cmd_current(&state, &cmd) {
                    if rx.has_changed().unwrap_or(false) {
                        continue;
                    }
                    break;
                }
            }

            let Some(player) = state.player.clone() else {
                break;
            };

            let candidate_opt = tokio::select! {
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
                res = resolve_server_candidate(&state, &cmd) => match res {
                    Ok(c) => c,
                    Err(err_msg) => {
                        if is_server_cmd_current(&state, &cmd) {
                            let err = LuminaError::new(LuminaErrorCode::InvalidCommand, err_msg);
                            set_server_play_error(&state, &cmd, err).await;
                        }
                        if rx.has_changed().unwrap_or(false) {
                            continue;
                        }
                        break;
                    }
                }
            };

            let Some(candidate) = candidate_opt else {
                if is_server_cmd_current(&state, &cmd) {
                    if player.state_code() == 3 {
                        player.resume();
                    } else if player.state_code() == 8 {
                        player.seek_ms(0);
                        player.resume();
                    }
                    {
                        let mut st = state.playback_state.write().await;
                        st.status = "playing".to_string();
                        st.state_code = PlaybackLifecycleState::Playing.as_i32();
                        st.state_name = PlaybackLifecycleState::Playing
                            .as_legacy_state_name()
                            .to_string();
                        st.playback_epoch = cmd.task_epoch;
                        st.timestamp_ms = now_unix_ms();
                    }
                    state
                        .loaded_generation
                        .store(cmd.generation, Ordering::SeqCst);
                    state.broadcast_playback_state().await;
                }
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            };

            if !is_server_cmd_current(&state, &cmd) {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            let open_res: Result<(OpenedStreamDecoder, Option<StreamSourceSpec>), CoreAudioError> =
                match &candidate {
                    ServerResolvedCandidate::SourceSpec { spec, .. } => tokio::select! {
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
                            cmd.cancel_token.clone(),
                            None,
                        ) => res.map(|(dec, adopted)| (dec, Some(adopted))),
                    },
                    ServerResolvedCandidate::Legacy { stream, .. } => tokio::select! {
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
                            cmd.cancel_token.clone(),
                            Duration::from_secs(10),
                        ) => res.map(|dec| (dec, None)),
                    },
                };

            let (decoder, adopted_spec) = match open_res {
                Ok(pair) => pair,
                Err(open_err) => {
                    if is_server_cmd_current(&state, &cmd) {
                        set_server_play_error(&state, &cmd, open_err.to_lumina_error()).await;
                    }
                    if rx.has_changed().unwrap_or(false) {
                        continue;
                    }
                    break;
                }
            };

            if !is_server_cmd_current(&state, &cmd) {
                drop(decoder);
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            let p_commit = player.clone();
            let track_meta_deck = cmd.track.as_ref().map(DeckTrackMetadata::from);
            let cancel_commit = cmd.cancel_token.clone();
            let play_ep = cmd.player_play_ep;
            let start_res = tokio::task::spawn_blocking(move || match &candidate {
                ServerResolvedCandidate::SourceSpec { spec, label } => {
                    let eff = adopted_spec.as_ref().unwrap_or(spec);
                    p_commit.start_opened_source_spec_with_metadata(
                        eff,
                        decoder,
                        label,
                        play_ep,
                        cancel_commit,
                        track_meta_deck,
                    )
                }
                ServerResolvedCandidate::Legacy { stream, label } => p_commit
                    .start_opened_decoder_with_epoch_and_metadata(
                        stream,
                        decoder,
                        label,
                        play_ep,
                        cancel_commit,
                        track_meta_deck,
                    ),
            })
            .await;

            if !is_server_cmd_current(&state, &cmd) {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            match start_res {
                Ok(Ok(())) => {
                    if let Some(start_pos) = cmd.start_position_ms.filter(|&p| p > 0) {
                        player.seek_ms(start_pos);
                    }
                    let eff_epoch = state.sync_playback_epoch_from_player(cmd.task_epoch);
                    let sp_raw = player.current_signal_path();
                    let sp_payload = signal_path_to_payload(&sp_raw);
                    *state.last_structured_error.write().await = None;
                    {
                        let mut st = state.playback_state.write().await;
                        st.status = "playing".to_string();
                        st.state_code = PlaybackLifecycleState::Playing.as_i32();
                        st.state_name = PlaybackLifecycleState::Playing
                            .as_legacy_state_name()
                            .to_string();
                        st.duration_ms = player.duration_ms();
                        st.position_ms = player.position_ms();
                        st.timestamp_ms = now_unix_ms();
                        st.swap_generation = player.swap_generation();
                        st.playback_epoch = eff_epoch;
                        st.error = None;
                        if let Some(meta) = cmd
                            .track
                            .clone()
                            .or_else(|| player.active_track_metadata().map(TrackMetadata::from))
                        {
                            if !meta.track_id.is_empty() {
                                st.track_id = Some(meta.track_id.clone());
                                st.current_track_id = Some(meta.track_id.clone());
                            }
                            st.track = Some(meta);
                        }
                    }
                    state
                        .loaded_generation
                        .store(cmd.generation, Ordering::SeqCst);
                    *state.signal_path_raw.write().await = sp_raw;
                    *state.signal_path.write().await = sp_payload.clone();
                    let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                        payload: sp_payload,
                    });
                    state.broadcast_playback_state().await;
                }
                start_err => {
                    let err = match start_err {
                        Ok(Err(audio_err)) => audio_err.to_lumina_error(),
                        Err(join_err) => {
                            LuminaError::new(LuminaErrorCode::Internal, join_err.to_string())
                        }
                        Ok(Ok(())) => unreachable!(),
                    };
                    set_server_play_error(&state, &cmd, err).await;
                }
            }

            if rx.has_changed().unwrap_or(false) {
                continue;
            }
            break;
        }
    }
}
