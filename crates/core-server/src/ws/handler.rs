use crate::error::ServerError;
use crate::state::{AppState, signal_path_to_payload};
use crate::ws::messages::{PlaybackStatePayload, WsMessage};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::http::header::AUTHORIZATION;
use axum::response::IntoResponse;
use core_types::{LuminaError, LuminaErrorCode, PlaybackCommand};
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

async fn send_full_sync(state: &Arc<AppState>, direct_tx: &mpsc::Sender<WsMessage>) {
    let snapshot = state.build_protocol_snapshot().await;
    let pb_payload = PlaybackStatePayload::from(snapshot.playback.clone());
    let sp_payload = snapshot
        .signal_path
        .as_ref()
        .map(signal_path_to_payload)
        .unwrap_or_default();

    let _ = direct_tx
        .send(WsMessage::Snapshot { payload: snapshot })
        .await;
    let _ = direct_tx
        .send(WsMessage::PlaybackStateChanged {
            payload: pb_payload,
        })
        .await;
    let _ = direct_tx
        .send(WsMessage::SignalPathUpdated {
            payload: sp_payload,
        })
        .await;
}

async fn handle_socket(socket: WebSocket, state: Arc<AppState>, send_snapshot: bool) {
    let (mut sender, mut receiver) = socket.split();
    let mut rx = state.broadcast_tx.subscribe();
    let (direct_tx, mut direct_rx) = mpsc::channel::<WsMessage>(32);

    info!("New WebSocket client connected");

    if send_snapshot {
        send_full_sync(&state, &direct_tx).await;
    }

    let send_state = state.clone();
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
                res = rx.recv() => match res {
                    Ok(msg) => {
                        if let Ok(text) = serde_json::to_string(&msg)
                            && sender.send(Message::Text(text.into())).await.is_err()
                        {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                        tracing::warn!(
                            "WebSocket client lagged by {skipped} broadcast messages; sending resync Snapshot"
                        );
                        let snapshot = send_state.build_protocol_snapshot().await;
                        if let Ok(text) = serde_json::to_string(&WsMessage::Snapshot {
                            payload: snapshot,
                        }) && sender.send(Message::Text(text.into())).await.is_err()
                        {
                            break;
                        }
                        continue;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                },
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
                        if val.get("command").is_some() {
                            match serde_json::from_value::<PlaybackCommand>(val) {
                                Ok(cmd) => {
                                    if let Err(err) =
                                        state_clone.dispatch_playback_command(cmd).await
                                    {
                                        let _ = direct_tx_cmd
                                            .send(WsMessage::Error {
                                                payload: err.to_lumina_error(),
                                            })
                                            .await;
                                    }
                                }
                                Err(e) => {
                                    let _ = direct_tx_cmd
                                        .send(WsMessage::Error {
                                            payload: LuminaError::new(
                                                LuminaErrorCode::InvalidCommand,
                                                "Invalid PlaybackCommand payload",
                                            )
                                            .with_details(e.to_string()),
                                        })
                                        .await;
                                }
                            }
                        } else if let Some(action) = val.get("action").and_then(|a| a.as_str()) {
                            handle_client_action(action, &val, &state_clone, &direct_tx_cmd).await;
                        }
                    }
                    Err(e) => {
                        let err = LuminaError::new(
                            LuminaErrorCode::InvalidCommand,
                            "Invalid JSON text frame",
                        )
                        .with_details(e.to_string());
                        let _ = direct_tx_cmd.send(WsMessage::Error { payload: err }).await;
                        debug!("Invalid JSON WS frame unicast error to sender");
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
            send_full_sync(state, direct_tx).await;
        }
        "playback.play" => {
            let _ = state
                .dispatch_playback_command(PlaybackCommand::Resume)
                .await;
        }
        "playback.pause" => {
            let _ = state
                .dispatch_playback_command(PlaybackCommand::Pause)
                .await;
        }
        "playback.stop" => {
            let _ = state.dispatch_playback_command(PlaybackCommand::Stop).await;
        }
        "playback.seek" => {
            if let Some(pos_ms) = val.get("position_ms").and_then(|v| v.as_u64()) {
                let _ = state
                    .dispatch_playback_command(PlaybackCommand::Seek {
                        position_ms: pos_ms,
                    })
                    .await;
            }
        }
        "playback.volume" => {
            if let Some(vol) = val.get("volume").and_then(|v| v.as_f64()) {
                let _ = state
                    .dispatch_playback_command(PlaybackCommand::SetVolume { volume: vol as f32 })
                    .await;
            }
        }
        "dsp.bypass" => {
            if let Some(bypass) = val.get("bypass").and_then(|v| v.as_bool()) {
                if let Some(ref player) = state.player {
                    player.set_dsp_bypass(bypass);
                    let sp_raw = player.current_signal_path();
                    let sp_payload = signal_path_to_payload(&sp_raw);
                    *state.signal_path_raw.write().await = sp_raw;
                    *state.signal_path.write().await = sp_payload.clone();
                    let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                        payload: sp_payload,
                    });
                }
                state.dsp_config.write().await.bypass = bypass;
                state.broadcast_playback_state().await;
            }
        }
        _ => {}
    }
}
