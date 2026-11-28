use super::loader::ensure_server_play_worker_started;
use super::models::{
    PlaybackActionResponse, PlaybackCommandRequest, PlaybackStateResponse, SERVER_RAPID_WINDOW_MS,
    SeekRequest, VolumeRequest,
};
use crate::error::ServerError;
use crate::state::{AppState, ServerPlayCmd, now_unix_ms};
use crate::ws::messages::{PlaybackStatePayload, WsMessage};
use axum::extract::{Json, State};
use core_types::{PlaybackCommand, PlaybackLifecycleState, StreamSourceSpec, TrackMetadata};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use tokio_util::sync::CancellationToken;

pub async fn get_playback_state(State(state): State<Arc<AppState>>) -> Json<PlaybackStateResponse> {
    let pb = state.build_playback_state().await;
    let current_track = pb.track.clone();
    let epoch = if let Some(ref p) = state.player {
        pb.playback_epoch.max(p.current_epoch())
    } else {
        pb.playback_epoch
    };
    Json(PlaybackStateResponse {
        state: pb,
        current_track,
        epoch,
    })
}

pub async fn post_playback_command(
    State(state): State<Arc<AppState>>,
    Json(cmd): Json<PlaybackCommand>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    state.dispatch_playback_command(cmd).await?;
    let pb = state.build_playback_state().await;
    Ok(Json(PlaybackActionResponse {
        status: pb.status.as_snake_str().to_string(),
        playback_epoch: pb.playback_epoch,
    }))
}

pub(crate) async fn execute_play_request(
    state: &Arc<AppState>,
    req: PlaybackCommandRequest,
    rich_track: Option<TrackMetadata>,
    start_position_ms: Option<u64>,
) -> Result<PlaybackActionResponse, ServerError> {
    if !state.accept_caller_epoch(req.playback_epoch) {
        return Ok(PlaybackActionResponse {
            status: "ignored".to_string(),
            playback_epoch: state.current_playback_epoch(),
        });
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

    let track_meta = rich_track.or_else(|| req.track.as_ref().map(TrackMetadata::from));

    let has_explicit_source = req.source_spec.is_some()
        || req.stream_url.is_some()
        || req.file_path.is_some()
        || req.track_id.is_some();

    let Some(player) = state.player.clone() else {
        let ep = state.advance_playback_epoch(req.playback_epoch);
        {
            let mut st = state.playback_state.write().await;
            if let Some(ref tid) = req.track_id {
                st.track_id = Some(tid.clone());
                st.current_track_id = Some(tid.clone());
            }
            if let Some(ref trk) = track_meta {
                if !trk.track_id.is_empty() {
                    st.track_id = Some(trk.track_id.clone());
                    st.current_track_id = Some(trk.track_id.clone());
                }
                if trk.duration_ms > 0 {
                    st.duration_ms = trk.duration_ms;
                }
                st.track = Some(trk.clone());
            }
            st.position_ms = start_position_ms.unwrap_or(0);
            st.status = "playing".to_string();
            st.state_code = PlaybackLifecycleState::Playing.as_i32();
            st.state_name = PlaybackLifecycleState::Playing
                .as_legacy_state_name()
                .to_string();
            st.playback_epoch = ep;
            st.timestamp_ms = now_unix_ms();
        }
        state.broadcast_playback_state().await;
        return Ok(PlaybackActionResponse {
            status: "playing".to_string(),
            playback_epoch: ep,
        });
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
        {
            let mut st = state.playback_state.write().await;
            st.status = "playing".to_string();
            st.state_code = PlaybackLifecycleState::Playing.as_i32();
            st.state_name = PlaybackLifecycleState::Playing
                .as_legacy_state_name()
                .to_string();
            st.position_ms = player.position_ms();
            st.duration_ms = player.duration_ms();
            st.swap_generation = player.swap_generation();
            st.playback_epoch = ep;
            st.timestamp_ms = now_unix_ms();
        }
        state.broadcast_playback_state().await;
        return Ok(PlaybackActionResponse {
            status: "playing".to_string(),
            playback_epoch: ep,
        });
    }

    let (player_play_ep, cancel_token, task_epoch) =
        if let Some(ep) = req.playback_epoch.filter(|&e| e > 0) {
            let tok = CancellationToken::new();
            let Some(play_ep) = player.begin_skip_transition_with_epoch(ep, tok.clone()) else {
                return Ok(PlaybackActionResponse {
                    status: "ignored".to_string(),
                    playback_epoch: state.current_playback_epoch(),
                });
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
        track_meta
            .as_ref()
            .map(|t| t.track_id.clone())
            .filter(|s| !s.is_empty())
    });

    {
        let mut st = state.playback_state.write().await;
        if let Some(ref tid) = effective_track_id {
            st.track_id = Some(tid.clone());
            st.current_track_id = Some(tid.clone());
        }
        if let Some(ref trk) = track_meta {
            st.track = Some(trk.clone());
            if trk.duration_ms > 0 {
                st.duration_ms = trk.duration_ms;
            }
        }
        st.status = "loading".to_string();
        st.state_code = PlaybackLifecycleState::Loading.as_i32();
        st.state_name = PlaybackLifecycleState::Loading
            .as_legacy_state_name()
            .to_string();
        st.position_ms = 0;
        st.playback_epoch = task_epoch;
        st.timestamp_ms = now_unix_ms();
    }
    state.broadcast_playback_state().await;

    let now_ms = state.elapsed_ms_since_start();
    let prev_ms = state.last_play_dispatch_ms.swap(now_ms, Ordering::SeqCst);
    let rapid_within_300ms =
        prev_ms > 0 && now_ms.saturating_sub(prev_ms) <= SERVER_RAPID_WINDOW_MS;

    ensure_server_play_worker_started(state);
    let _ = state.play_cmd_tx.send_replace(Some(ServerPlayCmd {
        track_id: effective_track_id,
        file_path: req.file_path,
        stream_url: req.stream_url,
        headers: req.headers,
        source: req.source,
        hint_extension: req.hint_extension,
        source_spec: req.source_spec,
        track: track_meta,
        start_position_ms,
        task_epoch,
        player_play_ep,
        generation,
        cancel_token,
        debounced: req.debounced,
        rapid_within_300ms,
    }));

    Ok(PlaybackActionResponse {
        status: "loading".to_string(),
        playback_epoch: task_epoch,
    })
}

pub async fn post_play(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<PlaybackCommandRequest>>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    let req = payload.map(|Json(r)| r).unwrap_or_default();
    let resp = execute_play_request(&state, req, None, None).await?;
    Ok(Json(resp))
}

pub(crate) async fn execute_resume(state: &Arc<AppState>) -> PlaybackActionResponse {
    if let Some(player) = &state.player {
        player.resume();
    }
    let ep = state.current_playback_epoch();
    {
        let mut st = state.playback_state.write().await;
        st.status = "playing".to_string();
        st.state_code = PlaybackLifecycleState::Playing.as_i32();
        st.state_name = PlaybackLifecycleState::Playing
            .as_legacy_state_name()
            .to_string();
        st.playback_epoch = ep;
        st.timestamp_ms = now_unix_ms();
        if let Some(player) = &state.player {
            st.position_ms = player.position_ms();
            st.duration_ms = player.duration_ms();
            st.swap_generation = player.swap_generation();
            if let Some(track) = player.active_track_metadata() {
                if !track.track_id.is_empty() {
                    st.track_id = Some(track.track_id.clone());
                    st.current_track_id = Some(track.track_id.clone());
                }
                st.track = Some(TrackMetadata::from(track));
            }
        }
    }
    state.broadcast_playback_state().await;
    PlaybackActionResponse {
        status: "playing".to_string(),
        playback_epoch: ep,
    }
}

pub async fn post_resume(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    Json(execute_resume(&state).await)
}

pub(crate) async fn execute_reconnect(state: &Arc<AppState>) -> PlaybackActionResponse {
    if let Some(player) = state.player.clone() {
        let _ = tokio::task::spawn_blocking(move || {
            player.set_device_lost(false);
            let _ = player.take_last_error();
            let _ = player.select_output_device(None, None);
        })
        .await;
    }
    *state.last_structured_error.write().await = None;
    let ep = state.current_playback_epoch();
    {
        let mut st = state.playback_state.write().await;
        if st.status == "error" {
            st.status = "stopped".to_string();
            st.state_code = PlaybackLifecycleState::Stopped.as_i32();
            st.state_name = PlaybackLifecycleState::Stopped
                .as_legacy_state_name()
                .to_string();
        }
        st.error = None;
        st.playback_epoch = ep;
        st.timestamp_ms = now_unix_ms();
    }
    state.broadcast_playback_state().await;
    let devices = state.list_device_infos().await;
    let _ = state
        .broadcast_tx
        .send(WsMessage::DevicesChanged { payload: devices });
    PlaybackActionResponse {
        status: "reconnected".to_string(),
        playback_epoch: ep,
    }
}

pub async fn post_reconnect(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    Json(execute_reconnect(&state).await)
}

pub(crate) async fn execute_pause(state: &Arc<AppState>) -> PlaybackActionResponse {
    if let Some(player) = &state.player {
        player.pause();
    }

    let ep = state.current_playback_epoch();
    {
        let mut st = state.playback_state.write().await;
        st.status = "paused".to_string();
        st.state_code = PlaybackLifecycleState::Paused.as_i32();
        st.state_name = PlaybackLifecycleState::Paused
            .as_legacy_state_name()
            .to_string();
        st.playback_epoch = ep;
        st.timestamp_ms = now_unix_ms();
        if let Some(player) = &state.player {
            st.position_ms = player.position_ms();
            st.duration_ms = player.duration_ms();
            st.swap_generation = player.swap_generation();
            if let Some(track) = player.active_track_metadata() {
                if !track.track_id.is_empty() {
                    st.track_id = Some(track.track_id.clone());
                    st.current_track_id = Some(track.track_id.clone());
                }
                st.track = Some(TrackMetadata::from(track));
            }
        }
    }

    state.broadcast_playback_state().await;

    PlaybackActionResponse {
        status: "paused".to_string(),
        playback_epoch: ep,
    }
}

pub async fn post_pause(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    Json(execute_pause(&state).await)
}

pub(crate) async fn execute_stop(state: &Arc<AppState>) -> PlaybackActionResponse {
    let next_gen = state.play_generation.fetch_add(1, Ordering::SeqCst) + 1;
    state.loaded_generation.store(next_gen, Ordering::SeqCst);
    state.cancel_active_play_token();
    let _ = state.play_cmd_tx.send_replace(None);
    let new_ep = state.advance_playback_epoch(None);
    if let Some(player) = &state.player {
        player.stop();
    }
    let eff_ep = state.sync_playback_epoch_from_player(new_ep);
    {
        let mut st = state.playback_state.write().await;
        st.status = "stopped".to_string();
        st.state_code = PlaybackLifecycleState::Stopped.as_i32();
        st.state_name = PlaybackLifecycleState::Stopped
            .as_legacy_state_name()
            .to_string();
        st.position_ms = 0;
        st.track = None;
        st.track_id = None;
        st.current_track_id = None;
        st.playback_epoch = eff_ep;
        st.timestamp_ms = now_unix_ms();
        if let Some(player) = &state.player {
            st.swap_generation = player.swap_generation();
        }
    }
    state.broadcast_playback_state().await;
    PlaybackActionResponse {
        status: "stopped".to_string(),
        playback_epoch: eff_ep,
    }
}

pub async fn post_stop(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    Json(execute_stop(&state).await)
}

pub(crate) async fn execute_seek(
    state: &Arc<AppState>,
    position_ms: u64,
) -> PlaybackActionResponse {
    if let Some(player) = &state.player {
        player.seek_ms(position_ms);
    }
    let ep = state.current_playback_epoch();
    {
        let mut st = state.playback_state.write().await;
        st.position_ms = if let Some(player) = &state.player {
            player.position_ms()
        } else {
            position_ms
        };
        st.playback_epoch = ep;
        st.timestamp_ms = now_unix_ms();
    }
    state.broadcast_playback_state().await;
    PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: ep,
    }
}

pub async fn post_seek(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SeekRequest>,
) -> Json<PlaybackActionResponse> {
    Json(execute_seek(&state, req.position_ms).await)
}

pub async fn post_next(
    State(state): State<Arc<AppState>>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::Next)
        .await?;
    Ok(Json(PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: state.current_playback_epoch(),
    }))
}

pub async fn post_previous(
    State(state): State<Arc<AppState>>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::Previous)
        .await?;
    Ok(Json(PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: state.current_playback_epoch(),
    }))
}

pub(crate) async fn execute_volume(state: &Arc<AppState>, volume: f32) -> PlaybackActionResponse {
    let vol = if volume.is_nan() {
        0.0
    } else {
        volume.clamp(0.0, 1.0)
    };
    if vol > 0.0 {
        state.is_muted.store(false, Ordering::SeqCst);
        *state.pre_mute_volume.write().await = vol;
    }
    if let Some(player) = &state.player {
        player.set_volume(vol);
    }
    {
        let mut v_lock = state.volume.write().await;
        *v_lock = vol;
    }

    let pb = state.build_playback_state().await;
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: PlaybackStatePayload::from(pb),
    });
    let _ = state.broadcast_tx.send(WsMessage::StateChanged {
        extra: serde_json::json!({
            "status": "ok",
            "volume": vol,
        }),
    });

    PlaybackActionResponse {
        status: "success".to_string(),
        playback_epoch: state.current_playback_epoch(),
    }
}

pub async fn post_volume(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<VolumeRequest>,
) -> Json<PlaybackActionResponse> {
    Json(execute_volume(&state, payload.volume).await)
}
