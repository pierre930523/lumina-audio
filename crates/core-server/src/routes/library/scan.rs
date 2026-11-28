use super::models::{RescanRequest, ScanLibraryRequest, ScanLibraryResponse, ScanStartRequest};
use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::State;
use core_db::{CatalogQueryRepository, DbWriteCoordinator, SqlitePool};
use core_providers::{IngestionPipeline, LibrarySyncService, LocalProvider, MusicProvider};
use std::sync::Arc;

pub async fn count_albums_under_root(pool: &SqlitePool, root_path: &str) -> usize {
    CatalogQueryRepository::count_albums_under_local_root(pool, root_path)
        .await
        .unwrap_or(0)
}

pub async fn invalidate_dir_mtime_cache(pool: &SqlitePool, dir_path: &str) {
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    let _ = CatalogQueryRepository::invalidate_local_dir_mtime_cache(pool, dir_path).await;
}

pub async fn post_scan_library(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ScanLibraryRequest>,
) -> Result<Json<ScanLibraryResponse>, ServerError> {
    if let Some(pool) = &state.db_pool {
        state.ensure_scan_progress_relay();
        let pipeline = state
            .ingestion_pipeline
            .clone()
            .unwrap_or_else(|| IngestionPipeline::with_defaults(pool.clone()));
        let ev = pipeline
            .scan_root(std::path::Path::new(&req.path), "local")
            .await
            .map_err(|e| ServerError::Internal(e.to_string()))?;
        let albums_count = count_albums_under_root(pool, &req.path).await;
        return Ok(Json(ScanLibraryResponse {
            scanned_files: ev.scanned as usize,
            albums_count,
            tracks_count: (ev.added + ev.updated + ev.unchanged) as usize,
            errors_count: ev.skipped as usize,
        }));
    }

    let provider = LocalProvider::from_root(&req.path);
    let sync = provider
        .sync_library()
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;

    Ok(Json(ScanLibraryResponse {
        scanned_files: sync.scanned_files_count,
        albums_count: sync.albums.len(),
        tracks_count: sync.tracks.len(),
        errors_count: sync.errors.len(),
    }))
}

pub async fn post_rescan_library(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<RescanRequest>>,
) -> Result<Json<core_types::RescanReport>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(core_types::RescanReport::default()));
    };
    let req = payload.map(|Json(r)| r).unwrap_or_default();
    let force = req.force.unwrap_or(false);
    let report = LibrarySyncService::rescan_tags(pool, req.dir_path.as_deref(), force)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(report))
}

pub async fn post_rescan_start(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<RescanRequest>>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let Some(pool) = state.db_pool.clone() else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    state.ensure_scan_progress_relay();
    let req = payload.map(|Json(r)| r).unwrap_or_default();
    let dir_opt = req
        .dir_path
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let force = req.force.unwrap_or(false);
    let progress_tx = state
        .ingestion_pipeline
        .as_ref()
        .map(|p| p.progress_sender());
    let scan_id = uuid::Uuid::new_v4().to_string();
    let scan_id_task = scan_id.clone();

    tokio::spawn(async move {
        let res = LibrarySyncService::rescan_tags_with_progress(
            &pool,
            dir_opt.as_deref(),
            force,
            progress_tx.as_ref(),
            Some(scan_id_task.clone()),
        )
        .await;
        if let Err(err) = res
            && let Some(ref tx) = progress_tx
        {
            let _ = tx.send(core_types::ScanProgressEvent {
                scan_id: scan_id_task,
                root_path: dir_opt.unwrap_or_else(|| "local".to_string()),
                state: core_types::ScanLifecycleState::Failed,
                message: Some(err.to_string()),
                ..Default::default()
            });
        }
    });

    Ok(Json(serde_json::json!({ "scan_id": scan_id })))
}

/// Starts a non-destructive Force Rebuild of the local library asynchronously and streams
/// 200ms-throttled progress events over the shared `IngestionPipeline` channel.
pub async fn post_force_rebuild_start(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<RescanRequest>>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let Some(pool) = state.db_pool.clone() else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    state.ensure_scan_progress_relay();
    let req = payload.map(|Json(r)| r).unwrap_or_default();
    let dir_opt = req
        .dir_path
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let pipeline = state
        .ingestion_pipeline
        .clone()
        .unwrap_or_else(|| IngestionPipeline::with_defaults(pool));
    let scan_id = uuid::Uuid::new_v4().to_string();
    let scan_id_task = scan_id.clone();

    tokio::spawn(async move {
        let _ = pipeline
            .force_rebuild_library(dir_opt.as_deref(), Some(scan_id_task))
            .await;
    });

    Ok(Json(serde_json::json!({ "scan_id": scan_id })))
}

pub async fn post_scan_start(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ScanStartRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let dir_path = req.dir_path.trim().to_string();
    if dir_path.is_empty() {
        return Err(ServerError::BadRequest("dir_path is empty".to_string()));
    }
    let Some(pool) = state.db_pool.clone() else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    state.ensure_scan_progress_relay();
    let pipeline = state
        .ingestion_pipeline
        .clone()
        .unwrap_or_else(|| IngestionPipeline::with_defaults(pool.clone()));
    let force = req.force.unwrap_or(false);
    let scan_id = uuid::Uuid::new_v4().to_string();
    let scan_id_task = scan_id.clone();

    tokio::spawn(async move {
        if force {
            invalidate_dir_mtime_cache(&pool, &dir_path).await;
        }
        let _ = pipeline
            .scan_root_with_id(std::path::Path::new(&dir_path), "local", Some(scan_id_task))
            .await;
    });

    Ok(Json(serde_json::json!({ "scan_id": scan_id })))
}
