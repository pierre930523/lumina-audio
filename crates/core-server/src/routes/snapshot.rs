use crate::state::AppState;
use axum::Json;
use axum::extract::State;
use core_types::ProtocolSnapshot;
use std::sync::Arc;

/// Returns a complete atomic state snapshot for initial hydration and WebSocket reconnect resync.
pub async fn get_snapshot(State(state): State<Arc<AppState>>) -> Json<ProtocolSnapshot> {
    Json(state.build_protocol_snapshot().await)
}
