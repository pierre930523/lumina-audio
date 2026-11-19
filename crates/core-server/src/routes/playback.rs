use crate::error::ServerError;
use crate::state::{signal_path_to_payload, AppState};
use crate::ws::messages::{SignalPathPayload, WsMessage};
use axum::extract::{Json, State};
use core_audio::{parse_autoeq_txt, StreamSource};
use core_db::LibraryRepository;
use core_types::{
    AudioDeviceDescription, DspPipelineConfig as SharedDspConfig, OutputBackendKind, PeqBandConfig,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;

#[derive(Debug, Deserialize, Default)]
pub struct PlaybackCommandRequest {
    pub track_id: Option<String>,
    pub file_path: Option<String>,
    pub stream_url: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub source: Option<String>,
    pub hint_extension: Option<String>,
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
}

pub async fn get_playback_state(State(state): State<Arc<AppState>>) -> Json<PlaybackStateResponse> {
    let mut payload = state.playback_state.read().await.clone();
    let vol = *state.volume.read().await;
    let (state_code, state_name, pos_ms, dur_ms, clock_src, seek_epoch, is_seeking, dsp_byp, strict, last_err, dev_lost) = if let Some(player) = &state.player {
        let code = player.state_code();
        let name = player.state_name().to_string();
        let pos = player.position_ms();
        let dur = player.duration_ms();
        let clk = player.clock_source().to_string();
        let epoch = player.seek_epoch();
        let seeking = player.is_seeking();
        let b = player.is_dsp_bypassed();
        let s = player.is_strict_bit_perfect();
        let err = player.last_error();
        let lost = player.is_device_lost();
        payload.status = match code {
            2 => "playing".to_string(),
            3 => "paused".to_string(),
            8 => "ended".to_string(),
            4 => "error".to_string(),
            _ => "stopped".to_string(),
        };
        payload.position_ms = pos;
        payload.duration_ms = dur;
        (code, name, pos, dur, clk, epoch, seeking, b, s, err, lost)
    } else {
        let code = match payload.status.as_str() {
            "playing" => 2,
            "paused" => 3,
            "ended" => 8,
            "error" => 4,
            _ => 1,
        };
        let name = match code {
            2 => "Playing".to_string(),
            3 => "Paused".to_string(),
            8 => "Ended".to_string(),
            4 => "Error".to_string(),
            _ => "Stopped".to_string(),
        };
        (code, name, payload.position_ms, payload.duration_ms, "stream_frames".to_string(), 0, false, false, false, None, false)
    };

    let track_id = payload.track_id.clone();
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
    })
}

pub async fn post_play(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<PlaybackCommandRequest>>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    let req = payload.map(|Json(r)| r).unwrap_or_default();

    {
        let mut st = state.playback_state.write().await;
        if let Some(ref tid) = req.track_id {
            st.track_id = Some(tid.clone());
        }
    }

    let current_track_id = state.playback_state.read().await.track_id.clone();
    let mut candidate_stream: Option<(StreamSource, String)> = None;

    if let Some(ref url) = req.stream_url {
        let stream = StreamSource::http(
            url,
            req.headers.unwrap_or_default(),
            req.hint_extension.clone(),
        );
        candidate_stream = Some((
            stream,
            req.source.unwrap_or_else(|| "HTTP Stream".to_string()),
        ));
    } else if let Some(ref path_str) = req.file_path {
        if path_str.starts_with("http://") || path_str.starts_with("https://") {
            let stream = StreamSource::http(
                path_str,
                req.headers.unwrap_or_default(),
                req.hint_extension.clone(),
            );
            candidate_stream = Some((
                stream,
                req.source.unwrap_or_else(|| "HTTP Stream".to_string()),
            ));
        } else if Path::new(path_str).is_file() {
            candidate_stream = Some((
                StreamSource::local_file(path_str),
                req.source.unwrap_or_else(|| "Local Library".to_string()),
            ));
        }
    } else if let Some(ref tid) = current_track_id {
        if tid.starts_with("http://") || tid.starts_with("https://") {
            candidate_stream = Some((
                StreamSource::http(tid, req.headers.unwrap_or_default(), req.hint_extension),
                req.source.unwrap_or_else(|| "HTTP Stream".to_string()),
            ));
        } else if Path::new(tid).is_file() {
            candidate_stream = Some((
                StreamSource::local_file(tid),
                req.source.unwrap_or_else(|| "Local Library".to_string()),
            ));
        } else if let Some(ref pool) = state.db_pool
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
                    candidate_stream = Some((stream, trk.provider.display_name().to_string()));
                } else if Path::new(&resolved.url_or_path).is_file() {
                    let stream = StreamSource::local_file(&resolved.url_or_path)
                        .with_replay_gain(
                            resolved.replay_gain_track_db,
                            resolved.replay_gain_album_db,
                            resolved.replay_gain_track_peak,
                            resolved.replay_gain_album_peak,
                        );
                    candidate_stream = Some((stream, trk.provider.display_name().to_string()));
                }
            } else if Path::new(&trk.external_track_id).is_file() {
                let stream = StreamSource::local_file(&trk.external_track_id).with_replay_gain(
                    trk.replay_gain_track_db,
                    trk.replay_gain_album_db,
                    trk.replay_gain_track_peak,
                    trk.replay_gain_album_peak,
                );
                candidate_stream = Some((stream, trk.provider.display_name().to_string()));
            }
        }
    }

    let mut st = state.playback_state.write().await;
    if let Some(player) = &state.player {
        if let Some((stream, label)) = candidate_stream {
            let p_clone = player.clone();
            let play_res = tokio::task::spawn_blocking(move || p_clone.play_stream(stream, &label))
                .await
                .map_err(|e| ServerError::Internal(e.to_string()))?;
            if let Err(e) = play_res {
                return Err(ServerError::Internal(format!("Audio playback error: {e}")));
            }
            st.duration_ms = player.duration_ms();
            st.position_ms = player.position_ms();
            let sp_payload = signal_path_to_payload(&player.current_signal_path());
            *state.signal_path.write().await = sp_payload.clone();
            let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                payload: sp_payload,
            });
        } else if player.state_code() == 3 {
            player.resume();
        } else if player.state_code() == 8 {
            player.seek_ms(0);
            player.resume();
        }
    }

    st.status = "playing".to_string();
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: st.clone(),
    });

    Ok(Json(PlaybackActionResponse {
        status: "playing".to_string(),
    }))
}

pub async fn post_resume(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.resume();
    }
    let mut st = state.playback_state.write().await;
    st.status = "playing".to_string();
    if let Some(player) = &state.player {
        st.position_ms = player.position_ms();
        st.duration_ms = player.duration_ms();
    }
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: st.clone(),
    });
    Json(PlaybackActionResponse {
        status: "playing".to_string(),
    })
}

pub async fn post_reconnect(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.set_device_lost(false);
        let _ = player.take_last_error();
        let _ = player.select_output_device(None, None);
    }
    let mut st = state.playback_state.write().await;
    if st.status == "error" {
        st.status = "stopped".to_string();
    }
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: st.clone(),
    });
    Json(PlaybackActionResponse {
        status: "reconnected".to_string(),
    })
}

pub async fn post_pause(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.pause();
    }

    let mut st = state.playback_state.write().await;
    st.status = "paused".to_string();
    if let Some(player) = &state.player {
        st.position_ms = player.position_ms();
        st.duration_ms = player.duration_ms();
    }

    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: st.clone(),
    });

    Json(PlaybackActionResponse {
        status: "paused".to_string(),
    })
}

pub async fn post_stop(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.stop();
    }
    let mut st = state.playback_state.write().await;
    st.status = "stopped".to_string();
    st.position_ms = 0;
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: st.clone(),
    });
    Json(PlaybackActionResponse {
        status: "stopped".to_string(),
    })
}

pub async fn post_seek(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SeekRequest>,
) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.seek_ms(req.position_ms);
    }
    let mut st = state.playback_state.write().await;
    st.position_ms = if let Some(player) = &state.player {
        player.position_ms()
    } else {
        req.position_ms
    };
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: st.clone(),
    });
    Json(PlaybackActionResponse {
        status: "success".to_string(),
    })
}

pub async fn post_next(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    let st = state.playback_state.read().await.clone();
    let _ = state.broadcast_tx.send(WsMessage::Event {
        event: "track_next".to_string(),
        payload: serde_json::to_value(st).unwrap_or_default(),
    });
    Json(PlaybackActionResponse {
        status: "success".to_string(),
    })
}

pub async fn post_previous(State(state): State<Arc<AppState>>) -> Json<PlaybackActionResponse> {
    if let Some(player) = &state.player {
        player.seek_ms(0);
    }
    let mut st = state.playback_state.write().await;
    st.position_ms = 0;
    let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
        payload: st.clone(),
    });
    Json(PlaybackActionResponse {
        status: "success".to_string(),
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
    if let Some(ref player) = state.player {
        Json(player.list_output_devices())
    } else {
        let tmp = core_audio::AudioPlayer::new_headless();
        let devices = tmp.list_output_devices();
        tmp.shutdown();
        Json(devices)
    }
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

    if let Some(ref player) = state.player {
        player
            .select_output_device(req.device_id.as_deref(), backend)
            .map_err(|e| ServerError::BadRequest(e.to_string()))?;
        let sp_payload = signal_path_to_payload(&player.current_signal_path());
        *state.signal_path.write().await = sp_payload.clone();
        let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
            payload: sp_payload,
        });
    }

    Ok(Json(PlaybackActionResponse {
        status: "selected".to_string(),
    }))
}
