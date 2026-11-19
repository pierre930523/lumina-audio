use crate::error::ServerError;
use crate::state::{signal_path_to_payload, AppState};
use crate::ws::messages::{WsErrorResponse, WsMessage};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::header::AUTHORIZATION;
use axum::http::HeaderMap;
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{debug, info};

#[derive(Debug, Deserialize, Default)]
pub struct WsConnectQuery {
    pub token: Option<String>,
    pub snapshot: Option<String>,
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    Query(query): Query<WsConnectQuery>,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, ServerError> {
    let header_token = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let token = header_token.or_else(|| {
        query
            .token
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
    });

    if let Some(ref tok) = token {
        if !state.pairing_manager.is_token_valid(tok).await {
            let _ = state.pairing_manager.load_tokens_from_db().await;
            if !state.pairing_manager.is_token_valid(tok).await {
                return Err(ServerError::Unauthorized);
            }
        }
    } else {
        return Err(ServerError::Unauthorized);
    }

    let send_snapshot = query
        .snapshot
        .as_deref()
        .is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"));
    Ok(ws.on_upgrade(move |socket| handle_socket(socket, state, send_snapshot)))
}

async fn handle_socket(socket: WebSocket, state: Arc<AppState>, send_snapshot: bool) {
    let (mut sender, mut receiver) = socket.split();
    let mut rx = state.broadcast_tx.subscribe();
    let (direct_tx, mut direct_rx) = mpsc::channel::<WsMessage>(16);

    info!("New WebSocket client connected");

    if send_snapshot {
        let mut pb = state.playback_state.read().await.clone();
        if let Some(ref player) = state.player {
            pb.status = match player.state_code() {
                2 => "playing".to_string(),
                3 => "paused".to_string(),
                _ => "stopped".to_string(),
            };
            pb.position_ms = player.position_ms();
            pb.duration_ms = player.duration_ms();
        }
        let _ = direct_tx
            .send(WsMessage::PlaybackStateChanged { payload: pb })
            .await;
        let sp = state.signal_path.read().await.clone();
        let _ = direct_tx
            .send(WsMessage::SignalPathUpdated { payload: sp })
            .await;
    }

    let mut send_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                Some(direct_msg) = direct_rx.recv() => {
                    if let Ok(text) = serde_json::to_string(&direct_msg)
                        && sender.send(Message::Text(text.into())).await.is_err()
                    {
                        break;
                    }
                }
                Ok(msg) = rx.recv() => {
                    if let Ok(text) = serde_json::to_string(&msg)
                        && sender.send(Message::Text(text.into())).await.is_err()
                    {
                        break;
                    }
                }
                else => break,
            }
        }
    });

    let state_clone = state.clone();
    let direct_tx_cmd = direct_tx.clone();
    let mut recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = receiver.next().await {
            match msg {
                Message::Text(text) => match serde_json::from_str::<serde_json::Value>(&text) {
                    Ok(val) => {
                        debug!("Received WS command: {:?}", val);
                        if let Some(action) = val.get("action").and_then(|a| a.as_str()) {
                            handle_client_action(action, &val, &state_clone, &direct_tx_cmd).await;
                        }
                    }
                    Err(_) => {
                        let err_resp = WsErrorResponse::new("Invalid JSON text frame");
                        if let Ok(err_text) = serde_json::to_string(&err_resp) {
                            let _ = state_clone.broadcast_tx.send(WsMessage::StateChanged {
                                extra: serde_json::json!({
                                    "status": "error",
                                    "error": "Invalid JSON text frame"
                                }),
                            });
                            debug!("Invalid JSON WS frame: {}", err_text);
                        }
                    }
                },
                Message::Close(_) => break,
                _ => {}
            }
        }
    });

    tokio::select! {
        _ = (&mut send_task) => recv_task.abort(),
        _ = (&mut recv_task) => send_task.abort(),
    };

    info!("WebSocket client disconnected");
}

async fn handle_client_action(
    action: &str,
    val: &serde_json::Value,
    state: &Arc<AppState>,
    direct_tx: &mpsc::Sender<WsMessage>,
) {
    match action {
        "state.sync" => {
            let mut pb = state.playback_state.read().await.clone();
            if let Some(ref player) = state.player {
                pb.status = match player.state_code() {
                    2 => "playing".to_string(),
                    3 => "paused".to_string(),
                    _ => "stopped".to_string(),
                };
                pb.position_ms = player.position_ms();
                pb.duration_ms = player.duration_ms();
            }
            let _ = direct_tx
                .send(WsMessage::PlaybackStateChanged { payload: pb })
                .await;
            let sp = state.signal_path.read().await.clone();
            let _ = direct_tx
                .send(WsMessage::SignalPathUpdated { payload: sp })
                .await;
        }
        "playback.play" => {
            if let Some(ref player) = state.player
                && player.state_code() == 3
            {
                player.resume();
            }
            let mut st = state.playback_state.write().await;
            st.status = "playing".to_string();
            let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                payload: st.clone(),
            });
        }
        "playback.pause" => {
            if let Some(ref player) = state.player {
                player.pause();
            }
            let mut st = state.playback_state.write().await;
            st.status = "paused".to_string();
            if let Some(ref player) = state.player {
                st.position_ms = player.position_ms();
            }
            let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                payload: st.clone(),
            });
        }
        "playback.stop" => {
            if let Some(ref player) = state.player {
                player.stop();
            }
            let mut st = state.playback_state.write().await;
            st.status = "stopped".to_string();
            st.position_ms = 0;
            let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                payload: st.clone(),
            });
        }
        "playback.seek" => {
            if let Some(pos_ms) = val.get("position_ms").and_then(|v| v.as_u64()) {
                if let Some(ref player) = state.player {
                    player.seek_ms(pos_ms);
                }
                let mut st = state.playback_state.write().await;
                st.position_ms = pos_ms;
                let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                    payload: st.clone(),
                });
            }
        }
        "playback.volume" => {
            if let Some(vol) = val.get("volume").and_then(|v| v.as_f64()) {
                let clamped = vol.clamp(0.0, 1.0) as f32;
                if let Some(ref player) = state.player {
                    player.set_volume(clamped);
                }
                let mut v_lock = state.volume.write().await;
                *v_lock = clamped;
                let _ = state.broadcast_tx.send(WsMessage::StateChanged {
                    extra: serde_json::json!({ "volume": clamped }),
                });
            }
        }
        "dsp.bypass" => {
            if let Some(bypass) = val.get("bypass").and_then(|v| v.as_bool()) {
                if let Some(ref player) = state.player {
                    player.set_dsp_bypass(bypass);
                    let sp_payload = signal_path_to_payload(&player.current_signal_path());
                    *state.signal_path.write().await = sp_payload.clone();
                    let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                        payload: sp_payload,
                    });
                }
                state.dsp_config.write().await.bypass = bypass;
            }
        }
        _ => {}
    }
}
