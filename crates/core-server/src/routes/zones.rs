use crate::error::ServerError;
use crate::state::AppState;
use crate::zones::{
    ClockSyncMeasurement, ZoneDiscoverRequest, ZoneGroupRequest, ZoneGroupStatus, ZoneInfo,
};
use axum::extract::{Path, State};
use axum::Json;
use serde::Deserialize;
use std::sync::Arc;

#[derive(Debug, Deserialize)]
pub struct ZoneVolumeRequest {
    pub volume: f32,
}

#[derive(Debug, Deserialize, Default)]
pub struct ZoneSyncRequest {
    pub clock_addr: Option<String>,
    pub samples: Option<usize>,
    pub sample_interval_ms: Option<u64>,
    pub use_sntp_binary: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct ZoneCastRequest {
    pub action: String,
    pub media_uri: Option<String>,
    pub seek_secs: Option<u64>,
}

pub async fn list_zones(State(state): State<Arc<AppState>>) -> Json<Vec<ZoneInfo>> {
    Json(state.zone_manager.list_zones().await)
}

pub async fn upsert_zone(
    State(state): State<Arc<AppState>>,
    Json(zone): Json<ZoneInfo>,
) -> Json<ZoneInfo> {
    Json(state.zone_manager.upsert_zone(zone).await)
}

pub async fn discover_zones(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<ZoneDiscoverRequest>>,
) -> Result<Json<Vec<ZoneInfo>>, ServerError> {
    let req = payload.map(|Json(v)| v).unwrap_or_default();
    let zones = state
        .zone_manager
        .discover_zones(state.player.as_ref(), req)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(zones))
}

pub async fn group_zones(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ZoneGroupRequest>,
) -> Result<Json<ZoneGroupStatus>, ServerError> {
    let res = state
        .zone_manager
        .group_zones(req)
        .await
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    Ok(Json(res))
}

pub async fn sync_zone_clock(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    payload: Option<Json<ZoneSyncRequest>>,
) -> Result<Json<ClockSyncMeasurement>, ServerError> {
    let req = payload.map(|Json(v)| v).unwrap_or_default();
    let res = state
        .zone_manager
        .sync_zone_clock(
            &id,
            req.clock_addr.as_deref(),
            req.samples.unwrap_or(5),
            req.sample_interval_ms.unwrap_or(15),
            req.use_sntp_binary.unwrap_or(false),
        )
        .await
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    Ok(Json(res))
}

pub async fn set_zone_volume(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ZoneVolumeRequest>,
) -> Result<Json<ZoneInfo>, ServerError> {
    let zone = state
        .zone_manager
        .set_zone_volume(&id, req.volume)
        .await
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    Ok(Json(zone))
}

pub async fn cast_to_zone(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ZoneCastRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let res = state
        .zone_manager
        .cast_to_zone(&id, &req.action, req.media_uri.as_deref(), req.seek_secs)
        .await
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    Ok(Json(res))
}
