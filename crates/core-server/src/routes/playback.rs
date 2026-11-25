use crate::error::ServerError;
use crate::state::{signal_path_to_payload, AppState, ServerPlayCmd};
use crate::ws::messages::{SignalPathPayload, WsMessage};
use axum::extract::{Json, State};
use core_audio::{parse_autoeq_txt, AudioPlayer, CoreAudioError, OpenedStreamDecoder, StreamSource};
use core_db::LibraryRepository;
use core_types::{
    AudioDeviceDescription, DeckTrackMetadata, DspPipelineConfig as SharedDspConfig,
    OutputBackendKind, PeqBandConfig, StreamSourceSpec,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::str::FromStr;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

const SERVER_RAPID_WINDOW_MS: u64 = 300;
const SERVER_DEBOUNCE_MS: u64 = 130;

#[derive(Debug, Deserialize, Default)]
pub struct PlaybackCommandRequest {
    pub track_id: Option<String>,
    pub file_path: Option<String>,
    pub stream_url: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub source: Option<String>,
    pub hint_extension: Option<String>,
    #[serde(default, alias = "epoch")]
    pub playback_epoch: Option<u64>,
    #[serde(default)]
    pub source_spec: Option<StreamSourceSpec>,
    #[serde(default)]
    pub track: Option<DeckTrackMetadata>,
    #[serde(default)]
    pub debounced: bool,
}

#[derive(Debug, Deserialize)]
pub struct SeekRequest {
    pub position_ms: u64,
}

#[derive(Debug, Deserialize)]
pub struct VolumeRequest {
    pub volume: f32,
}

#[derive(Debug, Deserialize)]
pub struct AutoEqImportRequest {
    pub text: String,
    pub apply: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct AutoEqImportResponse {
    pub peq_bands: Vec<PeqBandConfig>,
    pub applied: bool,
}

#[derive(Debug, Deserialize)]
pub struct SelectAudioDeviceRequest {
    pub device_id: Option<String>,
    pub backend: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PlaybackActionResponse {
    pub status: String,
    #[serde(default)]
    pub playback_epoch: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackStateResponse {
    pub state_code: i32,
    pub state_name: String,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub clock_source: String,
    pub seek_epoch: u64,
    pub is_seeking: bool,
    pub dsp_bypassed: bool,
    pub strict_bit_perfect: bool,
    pub volume: f32,
    #[serde(default)]
    pub last_error: Option<String>,
    pub device_lost: bool,
    #[serde(default)]
    pub current_track_id: Option<String>,
    pub status: String,
    #[serde(default)]
    pub track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_track: Option<DeckTrackMetadata>,
    #[serde(default)]
    pub swap_generation: u64,
    #[serde(default)]
    pub playback_epoch: u64,
    #[serde(default)]
    pub epoch: u64,
}

enum ServerResolvedCandidate {
    SourceSpec {
        spec: StreamSourceSpec,
        label: String,
    },
    Legacy {
        stream: StreamSource,
        label: String,
    },
}

fn is_server_cmd_current(state: &AppState, cmd: &ServerPlayCmd) -> bool {
    state.play_generation.load(Ordering::SeqCst) == cmd.generation
        && state.current_playback_epoch() == cmd.task_epoch
        && !cmd.cancel_token.is_cancelled()
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

fn ensure_server_play_worker_started(state: &Arc<AppState>) {
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
                    Err(_) => {
                        if is_server_cmd_current(&state, &cmd) {
                            let pb_payload = {
                                let mut st = state.playback_state.write().await;
                                st.status = "error".to_string();
                                st.playback_epoch = cmd.task_epoch;
                                st.clone()
                            };
                            state
                                .loaded_generation
                                .store(cmd.generation, Ordering::SeqCst);
                            let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                                payload: pb_payload,
                            });
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
                    let pb_payload = {
                        let mut st = state.playback_state.write().await;
                        st.status = "playing".to_string();
                        st.playback_epoch = cmd.task_epoch;
                        st.clone()
                    };
                    state
                        .loaded_generation
                        .store(cmd.generation, Ordering::SeqCst);
                    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                        payload: pb_payload,
                    });
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
                Err(_) => {
                    if is_server_cmd_current(&state, &cmd) {
                        let pb_payload = {
                            let mut st = state.playback_state.write().await;
                            st.status = "error".to_string();
                            st.playback_epoch = cmd.task_epoch;
                            st.clone()
                        };
                        state
                            .loaded_generation
                            .store(cmd.generation, Ordering::SeqCst);
                        let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                            payload: pb_payload,
                        });
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
            let track_meta = cmd.track.clone();
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
                        track_meta,
                    )
                }
                ServerResolvedCandidate::Legacy { stream, label } => p_commit
                    .start_opened_decoder_with_epoch_and_metadata(
                        stream,
                        decoder,
                        label,
                        play_ep,
                        cancel_commit,
                        track_meta,
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
                    let eff_epoch = state.sync_playback_epoch_from_player(cmd.task_epoch);
                    let sp_payload = signal_path_to_payload(&player.current_signal_path());
                    let pb_payload = {
                        let mut st = state.playback_state.write().await;
                        st.status = "playing".to_string();
                        st.duration_ms = player.duration_ms();
                        st.position_ms = player.position_ms();
                        st.swap_generation = player.swap_generation();
                        st.playback_epoch = eff_epoch;
                        if let Some(meta) = player.active_track_metadata().or(cmd.track.clone()) {
                            if !meta.track_id.is_empty() {
                                st.track_id = Some(meta.track_id.clone());
                            }
                            st.track = Some(meta);
                        }
                        st.clone()
                    };
                    state
                        .loaded_generation
                        .store(cmd.generation, Ordering::SeqCst);
                    *state.signal_path.write().await = sp_payload.clone();
                    let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                        payload: sp_payload,
                    });
                    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                        payload: pb_payload,
                    });
                }
                _ => {
                    let pb_payload = {
                        let mut st = state.playback_state.write().await;
                        st.status = "error".to_string();
                        st.playback_epoch = cmd.task_epoch;
                        st.clone()
                    };
                    state
                        .loaded_generation
                        .store(cmd.generation, Ordering::SeqCst);
                    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                        payload: pb_payload,
                    });
                }
            }

            if rx.has_changed().unwrap_or(false) {
                continue;
            }
            break;
        }
    }
}

pub async fn get_playback_state(State(state): State<Arc<AppState>>) -> Json<PlaybackStateResponse> {
    let mut payload = state.playback_state.read().await.clone();
    let vol = *state.volume.read().await;
    let playback_epoch = state.current_playback_epoch();
    let is_loading_pending = state.is_loading_pending();
    let (
        state_code,
        state_name,
        pos_ms,
        dur_ms,
        clock_src,
        seek_epoch,
        is_seeking,
        dsp_byp,
        strict,
        last_err,
        dev_lost,
        current_track,
        swap_generation,
        epoch,
    ) = if let Some(player) = &state.player {
        let clk = player.clock_source().to_string();
        let s_epoch = player.seek_epoch();
        let seeking = player.is_seeking();
        let b = player.is_dsp_bypassed();
        let s = player.is_strict_bit_perfect();
        let lost = player.is_device_lost();
        let dd = player.dual_deck_status();
        let eff_ep = playback_epoch.max(player.current_epoch());
        if is_loading_pending {
            let pending_dur = payload
                .track
                .as_ref()
                .map(|t| t.duration_ms)
                .filter(|&d| d > 0)
                .unwrap_or(payload.duration_ms);
            payload.status = "loading".to_string();
            payload.position_ms = 0;
            payload.duration_ms = pending_dur;
            (
                5,
                "Loading".to_string(),
                0,
                pending_dur,
                clk,
                s_epoch,
                false,
                b,
                s,
                None,
                lost,
                payload.track.clone(),
                dd.swap_generation,
                eff_ep,
            )
        } else {
            let code = player.state_code();
            let name = player.state_name().to_string();
            let pos = player.position_ms();
            let dur = player.duration_ms();
            let err = player.last_error();
            let cur_track = dd.active_track.map(|mut t| {
                if dur > 0 {
                    t.duration_ms = dur;
                }
                t
            });
            payload.status = match code {
                2 => "playing".to_string(),
                3 => "paused".to_string(),
                5 => "loading".to_string(),
                8 => "ended".to_string(),
                4 => "error".to_string(),
                _ => "stopped".to_string(),
            };
            payload.position_ms = pos;
            payload.duration_ms = dur;
            (
                code,
                name,
                pos,
                dur,
                clk,
                s_epoch,
                seeking,
                b,
                s,
                err,
                lost,
                cur_track.or_else(|| payload.track.clone()),
                dd.swap_generation,
                eff_ep,
            )
        }
    } else {
        let code = match payload.status.as_str() {
            "playing" => 2,
            "paused" => 3,
            "loading" => 5,
            "ended" => 8,
            "error" => 4,
            _ => 1,
        };
        let name = match code {
            2 => "Playing".to_string(),
            3 => "Paused".to_string(),
            5 => "Loading".to_string(),
            8 => "Ended".to_string(),
            4 => "Error".to_string(),
            _ => "Stopped".to_string(),
        };
        (
            code,
            name,
            payload.position_ms,
            payload.duration_ms,
            "stream_frames".to_string(),
            0,
            false,
            false,
            false,
            None,
            false,
            payload.track.clone(),
            payload.swap_generation,
            playback_epoch,
        )
    };

    let track_id = current_track
        .as_ref()
        .map(|t| t.track_id.clone())
        .filter(|id| !id.is_empty())
        .or_else(|| payload.track_id.clone());
    Json(PlaybackStateResponse {
        state_code,
        state_name,
        position_ms: pos_ms,
        duration_ms: dur_ms,
        clock_source: clock_src,
        seek_epoch,
        is_seeking,
        dsp_bypassed: dsp_byp,
        strict_bit_perfect: strict,
        volume: vol,
        last_error: last_err,
        device_lost: dev_lost,
        current_track_id: track_id.clone(),
        status: payload.status,
        track_id,
        current_track,
        swap_generation,
        playback_epoch,
        epoch,
    })
}

pub async fn post_play(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<PlaybackCommandRequest>>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    let req = payload.map(|Json(r)| r).unwrap_or_default();

    if !state.accept_caller_epoch(req.playback_epoch) {
        return Ok(Json(PlaybackActionResponse {
            status: "ignored".to_string(),
            playback_epoch: state.current_playback_epoch(),
        }));
    }

    if let Some(StreamSourceSpec::ExternalBackend {
        key, provider_id, ..
    }) = &req.source_spec
    {
        return Err(ServerError::BadRequest(format!(
            "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
            key.track_id
        )));
    }

    let has_explicit_source = req.source_spec.is_some()
        || req.stream_url.is_some()
        || req.file_path.is_some()
        || req.track_id.is_some();

    let Some(player) = state.player.clone() else {
        let ep = state.advance_playback_epoch(req.playback_epoch);
        let pb_payload = {
            let mut st = state.playback_state.write().await;
            if let Some(ref tid) = req.track_id {
                st.track_id = Some(tid.clone());
            }
            if let Some(ref trk) = req.track {
                st.track = Some(trk.clone());
            }
            st.status = "playing".to_string();
            st.playback_epoch = ep;
            st.clone()
        };
        let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
            payload: pb_payload,
        });
        return Ok(Json(PlaybackActionResponse {
            status: "playing".to_string(),
            playback_epoch: ep,
        }));
    };

    if !has_explicit_source {
        state.cancel_active_play_token();
        let _ = state.play_cmd_tx.send_replace(None);
        let next_gen = state.play_generation.fetch_add(1, Ordering::SeqCst) + 1;
        state.loaded_generation.store(next_gen, Ordering::SeqCst);
        let code = player.state_code();
        if code == 3 {
            player.resume();
        } else if code == 8 {
            player.seek_ms(0);
            player.resume();
        }
        let ep = state.current_playback_epoch();
        let pb_payload = {
            let mut st = state.playback_state.write().await;
            st.status = "playing".to_string();
            st.position_ms = player.position_ms();
            st.duration_ms = player.duration_ms();
            st.swap_generation = player.swap_generation();
            st.playback_epoch = ep;
            st.clone()
        };
        let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
            payload: pb_payload,
        });
        return Ok(Json(PlaybackActionResponse {
            status: "playing".to_string(),
            playback_epoch: ep,
        }));
    }

    let (player_play_ep, cancel_token, task_epoch) = if let Some(ep) = req.playback_epoch.filter(|&e| e > 0) {
        let tok = CancellationToken::new();
        let Some(play_ep) = player.begin_skip_transition_with_epoch(ep, tok.clone()) else {
            return Ok(Json(PlaybackActionResponse {
                status: "ignored".to_string(),
                playback_epoch: state.current_playback_epoch(),
            }));
        };
        let eff_ep = state.sync_playback_epoch_from_player(ep);
        (play_ep, tok, eff_ep)
    } else {
        let (play_ep, tok) = player.begin_skip_transition();
        let eff_ep = state.advance_after_epochless_skip();
        (play_ep, tok, eff_ep)
    };

    state.swap_play_cancel_token(cancel_token.clone());
    let generation = state.play_generation.fetch_add(1, Ordering::SeqCst) + 1;

    let effective_track_id = req.track_id.clone().or_else(|| {
        req.track
            .as_ref()
            .map(|t| t.track_id.clone())
            .filter(|s| !s.is_empty())
    });

    let pb_payload = {
        let mut st = state.playback_state.write().await;
        if let Some(ref tid) = effective_track_id {
            st.track_id = Some(tid.clone());
        }
        if let Some(ref trk) = req.track {
            st.track = Some(trk.clone());
        }
        st.status = "loading".to_string();
        st.position_ms = 0;
        st.playback_epoch = task_epoch;
        st.clone()
    };
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: pb_payload,
    });

    let now_ms = state.elapsed_ms_since_start();
    let prev_ms = state.last_play_dispatch_ms.swap(now_ms, Ordering::SeqCst);
    let rapid_within_300ms =
        prev_ms > 0 && now_ms.saturating_sub(prev_ms) <= SERVER_RAPID_WINDOW_MS;

    ensure_server_play_worker_started(&state);
    let _ = state.play_cmd_tx.send_replace(Some(ServerPlayCmd {
        track_id: effective_track_id,
        file_path: req.file_path,
        stream_url: req.stream_url,
        headers: req.headers,
        source: req.source,
        hint_extension: req.hint_extension,
        source_spec: req.source_spec,
        track: req.track,
        task_epoch,
        player_play_ep,
        generation,
        cancel_token,
        debounced: req.debounced,
        rapid_within_300ms,
    }));

    Ok(Json(PlaybackActionResponse {
        status: "loading".to_string(),
        playback_epoch: task_epoch,
    }))
}

pub async fn post_resume(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.resume();
    }
    let ep = state.current_playback_epoch();
    let payload = {
        let mut st = state.playback_state.write().await;
        st.status = "playing".to_string();
        st.playback_epoch = ep;
        if let Some(player) = &state.player {
            st.position_ms = player.position_ms();
            st.duration_ms = player.duration_ms();
            st.swap_generation = player.swap_generation();
            if let Some(track) = player.active_track_metadata() {
                if !track.track_id.is_empty() {
                    st.track_id = Some(track.track_id.clone());
                }
                st.track = Some(track);
            }
        }
        st.clone()
    };
    let _ = state
        .broadcast_tx
        .send(WsMessage::PlaybackStateChanged { payload });
    Json(PlaybackActionResponse {
        status: "playing".to_string(),
        playback_epoch: ep,
    })
}

pub async fn post_reconnect(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = state.player.clone() {
        let _ = tokio::task::spawn_blocking(move || {
            player.set_device_lost(false);
            let _ = player.take_last_error();
            let _ = player.select_output_device(None, None);
        })
        .await;
    }
    let ep = state.current_playback_epoch();
    let payload = {
        let mut st = state.playback_state.write().await;
        if st.status == "error" {
            st.status = "stopped".to_string();
        }
        st.playback_epoch = ep;
        st.clone()
    };
    let _ = state
        .broadcast_tx
        .send(WsMessage::PlaybackStateChanged { payload });
    Json(PlaybackActionResponse {
        status: "reconnected".to_string(),
        playback_epoch: ep,
    })
}

pub async fn post_pause(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.pause();
    }

    let ep = state.current_playback_epoch();
    let payload = {
        let mut st = state.playback_state.write().await;
        st.status = "paused".to_string();
        st.playback_epoch = ep;
        if let Some(player) = &state.player {
            st.position_ms = player.position_ms();
            st.duration_ms = player.duration_ms();
            st.swap_generation = player.swap_generation();
            if let Some(track) = player.active_track_metadata() {
                if !track.track_id.is_empty() {
                    st.track_id = Some(track.track_id.clone());
                }
                st.track = Some(track);
            }
        }
        st.clone()
    };

    let _ = state
        .broadcast_tx
        .send(WsMessage::PlaybackStateChanged { payload });

    Json(PlaybackActionResponse {
        status: "paused".to_string(),
        playback_epoch: ep,
    })
}

pub async fn post_stop(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    let next_gen = state.play_generation.fetch_add(1, Ordering::SeqCst) + 1;
    state.loaded_generation.store(next_gen, Ordering::SeqCst);
    state.cancel_active_play_token();
    let _ = state.play_cmd_tx.send_replace(None);
    let new_ep = state.advance_playback_epoch(None);
    if let Some(player) = &state.player {
        player.stop();
    }
    let eff_ep = state.sync_playback_epoch_from_player(new_ep);
    let payload = {
        let mut st = state.playback_state.write().await;
        st.status = "stopped".to_string();
        st.position_ms = 0;
        st.track = None;
        st.playback_epoch = eff_ep;
        if let Some(player) = &state.player {
            st.swap_generation = player.swap_generation();
        }
        st.clone()
    };
    let _ = state
        .broadcast_tx
        .send(WsMessage::PlaybackStateChanged { payload });
    Json(PlaybackActionResponse {
        status: "stopped".to_string(),
        playback_epoch: eff_ep,
    })
}

pub async fn post_seek(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SeekRequest>,
) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.seek_ms(req.position_ms);
    }
    let ep = state.current_playback_epoch();
    let payload = {
        let mut st = state.playback_state.write().await;
        st.position_ms = if let Some(player) = &state.player {
            player.position_ms()
        } else {
            req.position_ms
        };
        st.playback_epoch = ep;
        st.clone()
    };
    let _ = state
        .broadcast_tx
        .send(WsMessage::PlaybackStateChanged { payload });
    Json(PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: ep,
    })
}

pub async fn post_next(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    let ep = state.current_playback_epoch();
    let mut st = state.playback_state.read().await.clone();
    st.playback_epoch = ep;
    let _ = state.broadcast_tx.send(WsMessage::Event {
        event: "track_next".to_string(),
        payload: serde_json::to_value(st).unwrap_or_default(),
    });
    Json(PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: ep,
    })
}

pub async fn post_previous(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.seek_ms(0);
    }
    let ep = state.current_playback_epoch();
    let payload = {
        let mut st = state.playback_state.write().await;
        st.position_ms = 0;
        st.playback_epoch = ep;
        st.clone()
    };
    let _ = state
        .broadcast_tx
        .send(WsMessage::PlaybackStateChanged { payload });
    Json(PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: ep,
    })
}

pub async fn post_volume(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<VolumeRequest>,
) -> Json<PlaybackActionResponse> {
    let vol = if payload.volume.is_nan() {
        0.0
    } else {
        payload.volume.clamp(0.0, 1.0)
    };
    if let Some(player) = &state.player {
        player.set_volume(vol);
    }
    {
        let mut v_lock = state.volume.write().await;
        *v_lock = vol;
    }

    let _ = state.broadcast_tx.send(WsMessage::StateChanged {
        extra: serde_json::json!({
            "status": "ok",
            "volume": vol,
        }),
    });

    Json(PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: state.current_playback_epoch(),
    })
}

pub async fn get_dsp_config(State(state): State<Arc<AppState>>) -> Json<SharedDspConfig> {
    if let Some(ref player) = state.player {
        let cfg = player.get_dsp_config();
        *state.dsp_config.write().await = cfg.clone();
        Json(cfg)
    } else {
        Json(state.dsp_config.read().await.clone())
    }
}

pub async fn put_dsp_config(
    State(state): State<Arc<AppState>>,
    Json(cfg): Json<SharedDspConfig>,
) -> Result<Json<SharedDspConfig>, ServerError> {
    if let Some(ref player) = state.player {
        player
            .set_dsp_config(cfg.clone())
            .map_err(|e| ServerError::BadRequest(e.to_string()))?;
        let sp_payload = signal_path_to_payload(&player.current_signal_path());
        *state.signal_path.write().await = sp_payload.clone();
        let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
            payload: sp_payload,
        });
    }
    *state.dsp_config.write().await = cfg.clone();
    Ok(Json(cfg))
}

pub async fn post_dsp_autoeq(
    State(state): State<Arc<AppState>>,
    Json(req): Json<AutoEqImportRequest>,
) -> Result<Json<AutoEqImportResponse>, ServerError> {
    let bands = parse_autoeq_txt(&req.text).map_err(|e| ServerError::BadRequest(e.to_string()))?;
    let apply = req.apply.unwrap_or(true);
    if apply {
        let mut cfg = if let Some(ref player) = state.player {
            player.get_dsp_config()
        } else {
            state.dsp_config.read().await.clone()
        };
        cfg.peq_bands = bands.clone();
        cfg.bypass = false;
        if let Some(ref player) = state.player {
            player
                .set_dsp_config(cfg.clone())
                .map_err(|e| ServerError::BadRequest(e.to_string()))?;
            let sp_payload = signal_path_to_payload(&player.current_signal_path());
            *state.signal_path.write().await = sp_payload.clone();
            let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                payload: sp_payload,
            });
        }
        *state.dsp_config.write().await = cfg;
    }
    Ok(Json(AutoEqImportResponse {
        peq_bands: bands,
        applied: apply,
    }))
}

pub async fn get_signal_path(State(state): State<Arc<AppState>>) -> Json<SignalPathPayload> {
    if let Some(ref player) = state.player {
        let sp = signal_path_to_payload(&player.current_signal_path());
        *state.signal_path.write().await = sp.clone();
        Json(sp)
    } else {
        Json(state.signal_path.read().await.clone())
    }
}

pub async fn list_audio_devices(
    State(state): State<Arc<AppState>>,
) -> Json<Vec<AudioDeviceDescription>> {
    let player_opt = state.player.clone();
    let devices = tokio::task::spawn_blocking(move || {
        if let Some(player) = player_opt {
            player.list_output_devices()
        } else {
            let tmp = core_audio::AudioPlayer::new_headless();
            let devices = tmp.list_output_devices();
            tmp.shutdown();
            devices
        }
    })
    .await
    .unwrap_or_default();
    Json(devices)
}

pub async fn select_audio_device(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SelectAudioDeviceRequest>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    let backend = match req.backend {
        Some(ref b) if !b.trim().is_empty() => {
            Some(OutputBackendKind::from_str(b).map_err(|e| ServerError::BadRequest(e.to_string()))?)
        }
        _ => None,
    };

    if let Some(player) = state.player.clone() {
        let dev_id = req.device_id.clone();
        let sp_payload = tokio::task::spawn_blocking(move || {
            player
                .select_output_device(dev_id.as_deref(), backend)
                .map_err(|e| ServerError::BadRequest(e.to_string()))?;
            Ok::<_, ServerError>(signal_path_to_payload(&player.current_signal_path()))
        })
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))??;
        *state.signal_path.write().await = sp_payload.clone();
        let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
            payload: sp_payload,
        });
    }

    Ok(Json(PlaybackActionResponse {
        status: "selected".to_string(),
        playback_epoch: state.current_playback_epoch(),
    }))
}
