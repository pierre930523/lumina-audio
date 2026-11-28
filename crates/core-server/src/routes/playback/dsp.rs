use super::models::{AutoEqImportRequest, AutoEqImportResponse};
use crate::error::ServerError;
use crate::state::{AppState, signal_path_to_payload};
use crate::ws::messages::{SignalPathPayload, WsMessage};
use axum::extract::{Json, State};
use core_audio::parse_autoeq_txt;
use core_types::DspPipelineConfig as SharedDspConfig;
use std::sync::Arc;

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
        let sp_raw = player.current_signal_path();
        let sp_payload = signal_path_to_payload(&sp_raw);
        *state.signal_path_raw.write().await = sp_raw;
        *state.signal_path.write().await = sp_payload.clone();
        let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
            payload: sp_payload,
        });
    }
    *state.dsp_config.write().await = cfg.clone();
    state.broadcast_playback_state().await;
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
            let sp_raw = player.current_signal_path();
            let sp_payload = signal_path_to_payload(&sp_raw);
            *state.signal_path_raw.write().await = sp_raw;
            *state.signal_path.write().await = sp_payload.clone();
            let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                payload: sp_payload,
            });
        }
        *state.dsp_config.write().await = cfg;
        state.broadcast_playback_state().await;
    }
    Ok(Json(AutoEqImportResponse {
        peq_bands: bands,
        applied: apply,
    }))
}

pub async fn get_signal_path(State(state): State<Arc<AppState>>) -> Json<SignalPathPayload> {
    if let Some(ref player) = state.player {
        let sp_raw = player.current_signal_path();
        let sp = signal_path_to_payload(&sp_raw);
        *state.signal_path_raw.write().await = sp_raw;
        *state.signal_path.write().await = sp.clone();
        Json(sp)
    } else {
        Json(state.signal_path.read().await.clone())
    }
}
