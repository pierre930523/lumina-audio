use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use core_types::{PlaybackCommand, QueueState, TrackMetadata};
use serde::Deserialize;
use std::sync::Arc;

fn default_auto_play() -> bool {
    true
}

#[derive(Debug, Deserialize)]
pub struct LoadQueueRequest {
    pub items: Vec<TrackMetadata>,
    #[serde(default)]
    pub start_index: usize,
    #[serde(default = "default_auto_play")]
    pub auto_play: bool,
}

#[derive(Debug, Deserialize)]
pub struct EnqueueRequest {
    pub items: Vec<TrackMetadata>,
    #[serde(default)]
    pub play_next: bool,
}

#[derive(Debug, Deserialize)]
pub struct ReorderQueueRequest {
    pub from_index: usize,
    pub to_index: usize,
}

pub async fn get_queue(State(state): State<Arc<AppState>>) -> Json<QueueState> {
    Json(state.queue.read().await.clone())
}

pub async fn post_load_queue(
    State(state): State<Arc<AppState>>,
    Json(req): Json<LoadQueueRequest>,
) -> Result<Json<QueueState>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::LoadQueue {
            items: req.items,
            start_index: req.start_index,
            auto_play: req.auto_play,
        })
        .await?;
    Ok(Json(state.queue.read().await.clone()))
}

pub async fn post_enqueue(
    State(state): State<Arc<AppState>>,
    Json(req): Json<EnqueueRequest>,
) -> Result<Json<QueueState>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::Enqueue {
            items: req.items,
            play_next: req.play_next,
        })
        .await?;
    Ok(Json(state.queue.read().await.clone()))
}

pub async fn delete_queue_item(
    State(state): State<Arc<AppState>>,
    Path(index): Path<usize>,
) -> Result<Json<QueueState>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::RemoveQueueItem { index })
        .await?;
    Ok(Json(state.queue.read().await.clone()))
}

pub async fn post_reorder_queue(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ReorderQueueRequest>,
) -> Result<Json<QueueState>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::ReorderQueue {
            from_index: req.from_index,
            to_index: req.to_index,
        })
        .await?;
    Ok(Json(state.queue.read().await.clone()))
}

pub async fn post_clear_queue(
    State(state): State<Arc<AppState>>,
) -> Result<Json<QueueState>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::ClearQueue)
        .await?;
    Ok(Json(state.queue.read().await.clone()))
}

pub async fn post_clear_upcoming_queue(
    State(state): State<Arc<AppState>>,
) -> Result<Json<QueueState>, ServerError> {
    state
        .dispatch_playback_command(PlaybackCommand::ClearUpcomingQueue)
        .await?;
    Ok(Json(state.queue.read().await.clone()))
}
