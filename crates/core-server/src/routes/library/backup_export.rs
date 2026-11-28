use std::path::Path as StdPath;
use std::sync::Arc;

use axum::Json;
use axum::extract::{Path, Query, State};
use core_db::{BackupExportRepository, DbError, SqlitePool};
use core_types::{
    AudioExportProgress, AudioExportRequest, BackupHistoryRecord, BackupScheduleMode,
    BackupSettings, BackupTriggerMode, CatalogExportRequest, CatalogExportResult,
    RestoreBackupResult,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::ServerError;
use crate::state::AppState;
use crate::ws::messages::WsMessage;

#[derive(Debug, Deserialize)]
pub struct UpdateBackupSettingsBody {
    #[serde(default)]
    pub backup_dir: String,
    #[serde(default)]
    pub schedule_mode: BackupScheduleMode,
    #[serde(default = "default_max_keep")]
    pub max_keep: u32,
}

fn default_max_keep() -> u32 {
    10
}

#[derive(Debug, Deserialize, Default)]
pub struct ListBackupHistoryQuery {
    #[serde(default)]
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize, Default)]
pub struct CreateBackupBody {
    #[serde(default)]
    pub trigger_mode: BackupTriggerMode,
    #[serde(default)]
    pub backup_dir_override: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RestoreBackupBody {
    pub backup_path: String,
}

fn require_pool(state: &AppState) -> Result<&SqlitePool, ServerError> {
    state
        .db_pool
        .as_ref()
        .ok_or_else(|| ServerError::BadRequest("Database not initialized".to_string()))
}

fn map_db_err(err: DbError) -> ServerError {
    match err {
        DbError::NotFound(msg) => ServerError::NotFound(msg),
        DbError::ConstraintViolation(msg) => ServerError::BadRequest(msg),
        other => ServerError::Database(other.to_string()),
    }
}

/// `GET /api/v1/library/backups/settings`
pub async fn get_backup_settings(
    State(state): State<Arc<AppState>>,
) -> Result<Json<BackupSettings>, ServerError> {
    let pool = require_pool(&state)?;
    let settings = BackupExportRepository::get_backup_settings(pool, None)
        .await
        .map_err(map_db_err)?;
    Ok(Json(settings))
}

/// `PUT /api/v1/library/backups/settings`
pub async fn put_backup_settings(
    State(state): State<Arc<AppState>>,
    Json(body): Json<UpdateBackupSettingsBody>,
) -> Result<Json<BackupSettings>, ServerError> {
    let pool = require_pool(&state)?;
    let updated = BackupExportRepository::update_backup_settings(
        pool,
        None,
        &body.backup_dir,
        body.schedule_mode,
        body.max_keep,
    )
    .await
    .map_err(map_db_err)?;
    Ok(Json(updated))
}

/// `GET /api/v1/library/backups?limit=50`
pub async fn get_backup_history(
    State(state): State<Arc<AppState>>,
    Query(query): Query<ListBackupHistoryQuery>,
) -> Result<Json<Vec<BackupHistoryRecord>>, ServerError> {
    let Some(pool) = &state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let history = BackupExportRepository::list_backup_history(pool, query.limit.unwrap_or(50))
        .await
        .map_err(map_db_err)?;
    Ok(Json(history))
}

/// `POST /api/v1/library/backups`
pub async fn post_create_backup(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<CreateBackupBody>>,
) -> Result<Json<BackupHistoryRecord>, ServerError> {
    let pool = require_pool(&state)?;
    let body = payload.map(|Json(b)| b).unwrap_or_default();
    let dir_override = body
        .backup_dir_override
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(StdPath::new);
    let rec = BackupExportRepository::create_library_backup(pool, body.trigger_mode, dir_override)
        .await
        .map_err(map_db_err)?;
    Ok(Json(rec))
}

/// `POST /api/v1/library/backups/restore`
pub async fn post_restore_backup(
    State(state): State<Arc<AppState>>,
    Json(body): Json<RestoreBackupBody>,
) -> Result<Json<RestoreBackupResult>, ServerError> {
    let pool = require_pool(&state)?;
    let db_filename = pool.connect_options().get_filename().to_path_buf();
    let db_raw = db_filename.to_string_lossy();
    if db_raw.is_empty() || db_raw == ":memory:" {
        return Err(ServerError::BadRequest(
            "Database restore requires an on-disk SQLite database (not supported for :memory:)"
                .to_string(),
        ));
    }

    let backup_path_str = body.backup_path.trim();
    if backup_path_str.is_empty() {
        return Err(ServerError::BadRequest(
            "backup_path must not be empty".to_string(),
        ));
    }
    let backup_path = StdPath::new(backup_path_str);

    // 1. Verify archive integrity & SHA-256 BEFORE touching live DB.
    let (manifest, _manifest_path) = BackupExportRepository::verify_backup_archive(backup_path)
        .await
        .map_err(map_db_err)?;

    // 2. Create automatic pre_restore safety snapshot.
    let pre_restore =
        BackupExportRepository::create_library_backup(pool, BackupTriggerMode::PreRestore, None)
            .await
            .map_err(map_db_err)?;

    let result = RestoreBackupResult {
        restored_backup_id: manifest.backup_id.clone(),
        pre_restore_backup_id: Some(pre_restore.id.clone()),
        restored_from_path: backup_path_str.to_string(),
        schema_version: manifest.schema_version,
        table_counts: manifest.table_counts,
        reload_required: true,
    };

    let _ = state.broadcast_tx.send(WsMessage::LibraryReloaded {
        payload: json!({
            "restored_backup_id": result.restored_backup_id,
            "pre_restore_backup_id": result.pre_restore_backup_id,
            "restored_from_path": result.restored_from_path,
            "reload_required": true,
        }),
    });

    Ok(Json(result))
}

/// `POST /api/v1/library/export/catalog`
pub async fn post_export_catalog(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CatalogExportRequest>,
) -> Result<Json<CatalogExportResult>, ServerError> {
    let pool = require_pool(&state)?;
    let result = BackupExportRepository::export_catalog(pool, &req)
        .await
        .map_err(map_db_err)?;
    Ok(Json(result))
}

/// `POST /api/v1/library/export/audio`
pub async fn post_start_audio_export(
    State(state): State<Arc<AppState>>,
    Json(req): Json<AudioExportRequest>,
) -> Result<Json<AudioExportProgress>, ServerError> {
    let pool = require_pool(&state)?;
    let progress = BackupExportRepository::start_audio_export(pool, req)
        .await
        .map_err(map_db_err)?;
    Ok(Json(progress))
}

/// `GET /api/v1/library/export/audio/{job_id}`
pub async fn get_audio_export_progress(
    Path(job_id): Path<String>,
) -> Result<Json<AudioExportProgress>, ServerError> {
    let progress = BackupExportRepository::get_audio_export_progress(&job_id)
        .ok_or_else(|| ServerError::NotFound(format!("Audio export job '{job_id}' not found")))?;
    Ok(Json(progress))
}

/// `POST /api/v1/library/export/audio/{job_id}/cancel`
pub async fn post_cancel_audio_export(
    Path(job_id): Path<String>,
) -> Result<Json<Value>, ServerError> {
    let cancelled = BackupExportRepository::cancel_audio_export(&job_id);
    Ok(Json(json!({ "cancelled": cancelled })))
}
