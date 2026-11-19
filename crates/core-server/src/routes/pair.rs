use crate::error::ServerError;
use crate::pairing::qr::generate_qr_pairing_uri;
use crate::state::AppState;
use axum::extract::{Json, State};
use axum::http::HeaderMap;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Deserialize)]
pub struct InitiatePairRequest {
    pub device_name: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
}

#[derive(Debug, Serialize)]
pub struct InitiatePairResponse {
    pub pin: String,
    pub qr_payload: String,
    pub expires_in_sec: u64,
}

#[derive(Debug, Deserialize)]
pub struct VerifyPairRequest {
    pub pin: String,
    pub client_id: Option<String>,
    pub device_name: Option<String>,
    pub platform: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct VerifyPairResponse {
    pub status: String,
    pub token: String,
    pub token_type: String,
}

#[derive(Debug, Deserialize)]
pub struct UnifiedPairRequest {
    pub action: Option<String>,
    pub pin: Option<String>,
    pub client_id: Option<String>,
    pub device_name: Option<String>,
    pub platform: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
}

pub async fn initiate_pairing(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<Option<InitiatePairRequest>>,
) -> Result<Json<InitiatePairResponse>, ServerError> {
    let req = payload.unwrap_or(InitiatePairRequest {
        device_name: None,
        host: None,
        port: None,
    });

    let dev_name = req.device_name.unwrap_or_else(|| "Lumina-Desktop".to_string());
    let host = req.host.unwrap_or_else(|| "127.0.0.1".to_string());
    let port = req.port.unwrap_or(9888);

    let pin = state.pairing_manager.generate_pin(&dev_name).await;
    let qr = generate_qr_pairing_uri(&pin, &host, port, None);

    Ok(Json(InitiatePairResponse {
        pin,
        qr_payload: qr,
        expires_in_sec: 60,
    }))
}

pub async fn verify_pairing(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<VerifyPairRequest>,
) -> Result<Json<VerifyPairResponse>, ServerError> {
    let client_ip = headers
        .get("x-forwarded-for")
        .or_else(|| headers.get("x-real-ip"))
        .and_then(|v| v.to_str().ok())
        .unwrap_or("127.0.0.1")
        .to_string();

    let client_id = payload
        .client_id
        .unwrap_or_else(|| format!("client-{}", payload.pin));
    let device_name = payload
        .device_name
        .unwrap_or_else(|| "Remote Device".to_string());
    let platform = payload.platform.unwrap_or_else(|| "generic".to_string());

    let token = state
        .pairing_manager
        .attempt_pairing(&client_ip, &client_id, &device_name, &platform, &payload.pin)
        .await?;

    Ok(Json(VerifyPairResponse {
        status: "success".to_string(),
        token,
        token_type: "Bearer".to_string(),
    }))
}

pub async fn unified_pair(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<UnifiedPairRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    // If PIN is provided, treat as verify; otherwise treat as initiate
    if let Some(pin) = payload.pin {
        let verify_req = VerifyPairRequest {
            pin,
            client_id: payload.client_id,
            device_name: payload.device_name,
            platform: payload.platform,
        };
        let resp = verify_pairing(State(state), headers, Json(verify_req)).await?;
        Ok(Json(serde_json::to_value(resp.0).unwrap()))
    } else {
        let init_req = InitiatePairRequest {
            device_name: payload.device_name,
            host: payload.host,
            port: payload.port,
        };
        let resp = initiate_pairing(State(state), Json(Some(init_req))).await?;
        Ok(Json(serde_json::to_value(resp.0).unwrap()))
    }
}

