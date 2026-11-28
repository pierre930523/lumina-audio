use super::models::{PlaybackActionResponse, SelectAudioDeviceRequest};
use crate::error::ServerError;
use crate::state::{AppState, signal_path_to_payload};
use crate::ws::messages::WsMessage;
use axum::extract::{Json, State};
use core_types::{AudioDeviceDescription, OutputBackendKind};
use std::str::FromStr;
use std::sync::Arc;

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

pub(crate) async fn execute_select_audio_device(
    state: &Arc<AppState>,
    device_id: Option<String>,
    backend: Option<OutputBackendKind>,
) -> Result<PlaybackActionResponse, ServerError> {
    if let Some(player) = state.player.clone() {
        let dev_id = device_id.clone();
        let sp_raw = tokio::task::spawn_blocking(move || {
            player
                .select_output_device(dev_id.as_deref(), backend)
                .map_err(|e| ServerError::Lumina(e.to_lumina_error()))?;
            Ok::<_, ServerError>(player.current_signal_path())
        })
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))??;
        let sp_payload = signal_path_to_payload(&sp_raw);
        *state.signal_path_raw.write().await = sp_raw;
        *state.signal_path.write().await = sp_payload.clone();
        let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
            payload: sp_payload,
        });
    }

    *state.active_device_id.write().await = device_id.clone();
    state
        .zone_manager
        .sync_local_zone_selected_device(device_id.as_deref(), state.player.as_ref())
        .await;

    let devices = state.list_device_infos().await;
    let active_dev = devices.iter().find(|d| d.is_active).cloned();
    *state.active_device.write().await = active_dev;
    let zones = state.zone_manager.list_zones().await;

    let _ = state
        .broadcast_tx
        .send(WsMessage::DevicesChanged { payload: devices });
    let _ = state
        .broadcast_tx
        .send(WsMessage::ZonesChanged { payload: zones });
    state.broadcast_playback_state().await;

    Ok(PlaybackActionResponse {
        status: "selected".to_string(),
        playback_epoch: state.current_playback_epoch(),
    })
}

pub async fn select_audio_device(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SelectAudioDeviceRequest>,
) -> Result<Json<PlaybackActionResponse>, ServerError> {
    let backend = match req.backend {
        Some(ref b) if !b.trim().is_empty() => Some(
            OutputBackendKind::from_str(b).map_err(|e| ServerError::BadRequest(e.to_string()))?,
        ),
        _ => None,
    };

    let resp = execute_select_audio_device(&state, req.device_id, backend).await?;
    Ok(Json(resp))
}
