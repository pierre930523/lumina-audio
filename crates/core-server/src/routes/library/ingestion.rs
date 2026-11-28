use super::models::{
    AddWatchedRootRequest, PutMetadataOverrideRequest, RemoveWatchedRootQuery,
    RetrySkippedFileResponse, SkippedFilesQuery,
};
use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use core_db::{DbWriteCoordinator, IngestionRepository};
use core_providers::IngestionPipeline;
use core_types::{
    ExternalCatalogIngestBatch, MetadataLayer, MetadataOverride, SkippedFile, WatchMode,
    WatchedRoot,
};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;

pub async fn retry_skipped_file_by_id(
    pipeline: &IngestionPipeline,
    skipped_id: &str,
) -> Result<RetrySkippedFileResponse, ServerError> {
    let pool = pipeline.pool();
    let all = IngestionRepository::list_skipped_files(pool, true)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    let Some(rec) = all.into_iter().find(|r| r.id == skipped_id) else {
        return Ok(RetrySkippedFileResponse {
            status: "not_found".to_string(),
            detail: "Skipped file record not found".to_string(),
            file_path: None,
        });
    };

    let roots = IngestionRepository::list_watched_roots(pool)
        .await
        .unwrap_or_default();
    let norm_rec = rec.file_path.replace('\\', "/").to_ascii_lowercase();
    let covering_root = roots
        .iter()
        .filter(|r| {
            let norm_r = r
                .root_path
                .replace('\\', "/")
                .trim_end_matches('/')
                .to_ascii_lowercase();
            norm_rec == norm_r || norm_rec.starts_with(&format!("{norm_r}/"))
        })
        .max_by_key(|r| r.root_path.len())
        .map(|r| PathBuf::from(&r.root_path));

    let target_path = PathBuf::from(&rec.file_path);
    let target_check = target_path.clone();
    let root_check = covering_root.clone();
    let (root_online, file_missing) = tokio::task::spawn_blocking(move || {
        let online = root_check
            .as_deref()
            .is_none_or(core_providers::is_root_accessible);
        let missing = matches!(
            std::fs::symlink_metadata(&target_check),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound
        );
        (online, missing)
    })
    .await
    .unwrap_or((true, false));

    if !root_online {
        return Ok(RetrySkippedFileResponse {
            status: "still_skipped".to_string(),
            detail: "Root directory is currently offline or unreachable".to_string(),
            file_path: Some(rec.file_path),
        });
    }

    if file_missing {
        let coord = DbWriteCoordinator::for_pool(pool);
        let _wg = coord.write_lock().await;
        let _ =
            IngestionRepository::delete_skipped_by_ids(pool, std::slice::from_ref(&rec.id)).await;
        return Ok(RetrySkippedFileResponse {
            status: "removed_missing".to_string(),
            detail: "File no longer exists on disk; removed from skipped list".to_string(),
            file_path: Some(rec.file_path),
        });
    }

    let root_path = covering_root.unwrap_or_else(|| {
        target_path
            .parent()
            .map(std::path::Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."))
    });

    let ev = pipeline
        .process_changed_paths(
            &root_path,
            &rec.provider_id,
            std::slice::from_ref(&target_path),
        )
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;

    if ev.skipped == 0 && (ev.added + ev.updated + ev.unchanged) > 0 {
        let _ = IngestionRepository::clear_skipped_for_path(pool, &rec.provider_id, &rec.file_path)
            .await;
        return Ok(RetrySkippedFileResponse {
            status: "imported".to_string(),
            detail: "Successfully imported".to_string(),
            file_path: Some(rec.file_path),
        });
    }

    let updated_detail = IngestionRepository::list_skipped_files(pool, true)
        .await
        .unwrap_or_default()
        .into_iter()
        .find(|r| r.file_path == rec.file_path)
        .map(|r| r.detail)
        .unwrap_or(rec.detail);

    Ok(RetrySkippedFileResponse {
        status: "still_skipped".to_string(),
        detail: updated_detail,
        file_path: Some(rec.file_path),
    })
}

pub async fn get_watched_roots(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<WatchedRoot>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let roots = IngestionRepository::list_watched_roots(pool)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(roots))
}

pub async fn post_watched_root(
    State(state): State<Arc<AppState>>,
    Json(req): Json<AddWatchedRootRequest>,
) -> Result<Json<WatchedRoot>, ServerError> {
    let root_path = req.root_path.trim();
    if root_path.is_empty() {
        return Err(ServerError::BadRequest("root_path is empty".to_string()));
    }
    let Some(watcher) = state.ensure_watcher_manager().await else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let mode = match req.watch_mode.as_deref() {
        Some(m) if !m.trim().is_empty() => {
            WatchMode::from_str(m.trim()).map_err(|e| ServerError::BadRequest(e.to_string()))?
        }
        _ => WatchMode::NativeOs,
    };
    let poll_interval_sec = req.poll_interval_sec.unwrap_or(300);
    let provider_id = req.provider_id.as_deref().unwrap_or("local");

    let stored = watcher
        .add_root(
            provider_id,
            std::path::Path::new(root_path),
            mode,
            poll_interval_sec,
        )
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(stored))
}

pub async fn remove_watched_root_by_id_or_path(
    watcher: &core_providers::StorageWatcherManager,
    target: &str,
) -> Result<bool, ServerError> {
    let trimmed = target.trim();
    if watcher
        .remove_root(trimmed)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?
    {
        return Ok(true);
    }
    let norm_target = trimmed
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_ascii_lowercase();
    let roots = watcher
        .list_roots()
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    for root in roots {
        let norm_root = root
            .root_path
            .replace('\\', "/")
            .trim_end_matches('/')
            .to_ascii_lowercase();
        if root.id == trimmed || norm_root == norm_target {
            return watcher
                .remove_root(&root.id)
                .await
                .map_err(|e| ServerError::Internal(e.to_string()));
        }
    }
    Ok(false)
}

pub async fn delete_watched_root(
    State(state): State<Arc<AppState>>,
    Query(query): Query<RemoveWatchedRootQuery>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let target = query
        .root_path
        .or(query.id)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ServerError::BadRequest("root_path or id query parameter is required".to_string())
        })?;
    let Some(watcher) = state.ensure_watcher_manager().await else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let removed = remove_watched_root_by_id_or_path(&watcher, &target).await?;
    Ok(Json(serde_json::json!({ "ok": removed })))
}

pub async fn get_skipped_files(
    State(state): State<Arc<AppState>>,
    Query(query): Query<SkippedFilesQuery>,
) -> Result<Json<Vec<SkippedFile>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let include_dismissed = query.include_dismissed.unwrap_or(false);
    let list = IngestionRepository::list_skipped_files(pool, include_dismissed)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(list))
}

pub async fn post_dismiss_skipped_file(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    let dismissed = IngestionRepository::dismiss_skipped_file(pool, &id)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(serde_json::json!({ "ok": dismissed })))
}

pub async fn post_retry_skipped_file(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<RetrySkippedFileResponse>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    state.ensure_scan_progress_relay();
    let pipeline = state
        .ingestion_pipeline
        .clone()
        .unwrap_or_else(|| IngestionPipeline::with_defaults(pool.clone()));
    let resp = retry_skipped_file_by_id(&pipeline, &id).await?;
    Ok(Json(resp))
}

fn validate_entity_type(entity_type: &str) -> Result<&str, ServerError> {
    let trimmed = entity_type.trim();
    match trimmed {
        "track" | "album" | "artist" => Ok(trimmed),
        _ => Err(ServerError::BadRequest(format!(
            "Invalid entity_type '{trimmed}'; expected 'track', 'album', or 'artist'"
        ))),
    }
}

pub async fn get_metadata_overrides(
    State(state): State<Arc<AppState>>,
    Path((entity_type, entity_id)): Path<(String, String)>,
) -> Result<Json<Vec<MetadataOverride>>, ServerError> {
    let entity_type = validate_entity_type(&entity_type)?;
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let list = IngestionRepository::get_overrides_for_entity(pool, entity_type, &entity_id)
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(list))
}

pub async fn put_metadata_override(
    State(state): State<Arc<AppState>>,
    Path((entity_type, entity_id)): Path<(String, String)>,
    Json(req): Json<PutMetadataOverrideRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let entity_type = validate_entity_type(&entity_type)?;
    let field_name = req.field_name.trim();
    if field_name.is_empty() {
        return Err(ServerError::BadRequest("field_name is empty".to_string()));
    }
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    let written = IngestionRepository::set_metadata_override(
        pool,
        entity_type,
        &entity_id,
        field_name,
        &req.value_json,
        MetadataLayer::UserEdit,
    )
    .await
    .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(serde_json::json!({ "ok": written })))
}

pub async fn delete_metadata_override(
    State(state): State<Arc<AppState>>,
    Path((entity_type, entity_id, field_name)): Path<(String, String, String)>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let entity_type = validate_entity_type(&entity_type)?;
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let coord = DbWriteCoordinator::for_pool(pool);
    let _wg = coord.write_lock().await;
    let cleared =
        IngestionRepository::clear_metadata_override(pool, entity_type, &entity_id, &field_name)
            .await
            .map_err(|e| ServerError::Database(e.to_string()))?;
    Ok(Json(serde_json::json!({ "ok": cleared })))
}

pub async fn post_ingest_external_catalog(
    State(state): State<Arc<AppState>>,
    Json(batch): Json<ExternalCatalogIngestBatch>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Err(ServerError::BadRequest(
            "Database not initialized".to_string(),
        ));
    };
    let rep = IngestionPipeline::ingest_external_catalog(pool, &batch)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;
    Ok(Json(serde_json::json!({
        "albums_ingested": rep.albums_inserted + rep.albums_matched,
        "tracks_ingested": rep.tracks_upserted,
        "albums_inserted": rep.albums_inserted,
        "albums_matched": rep.albums_matched,
        "versions_upserted": rep.versions_upserted,
    })))
}
