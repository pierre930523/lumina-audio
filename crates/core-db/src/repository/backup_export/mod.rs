pub mod audio_export;
pub mod backup;
pub mod catalog_export;
pub mod settings;

use std::path::{Path, PathBuf};

use core_types::{
    AudioExportProgress, AudioExportRequest, BackupHistoryRecord, BackupManifest,
    BackupScheduleMode, BackupSettings, BackupTriggerMode, CatalogExportRequest,
    CatalogExportResult,
};
use sqlx::SqlitePool;

use crate::error::Result;

pub use audio_export::AudioExportManager;
pub use backup::CURRENT_SCHEMA_VERSION;
pub use settings::{
    BACKUP_DIR_PREF_KEY, BACKUP_MAX_KEEP_PREF_KEY, BACKUP_SCHEDULE_MODE_PREF_KEY,
    DEFAULT_BACKUP_MAX_KEEP,
};

pub struct BackupExportRepository;

impl BackupExportRepository {
    pub async fn get_backup_settings(
        pool: &SqlitePool,
        db_path_opt: Option<&Path>,
    ) -> Result<BackupSettings> {
        settings::get_backup_settings(pool, db_path_opt).await
    }

    pub async fn update_backup_settings(
        pool: &SqlitePool,
        db_path_opt: Option<&Path>,
        backup_dir: &str,
        schedule_mode: BackupScheduleMode,
        max_keep: u32,
    ) -> Result<BackupSettings> {
        settings::update_backup_settings(pool, db_path_opt, backup_dir, schedule_mode, max_keep)
            .await
    }

    pub async fn create_library_backup(
        pool: &SqlitePool,
        trigger_mode: BackupTriggerMode,
        backup_dir_override: Option<&Path>,
    ) -> Result<BackupHistoryRecord> {
        backup::create_library_backup(pool, trigger_mode, backup_dir_override).await
    }

    pub async fn list_backup_history(
        pool: &SqlitePool,
        limit: u32,
    ) -> Result<Vec<BackupHistoryRecord>> {
        backup::list_backup_history(pool, limit).await
    }

    pub async fn verify_backup_archive(backup_path: &Path) -> Result<(BackupManifest, PathBuf)> {
        backup::verify_backup_archive(backup_path).await
    }

    pub async fn is_scheduled_backup_due(pool: &SqlitePool) -> Result<bool> {
        backup::is_scheduled_backup_due(pool).await
    }

    pub async fn export_catalog(
        pool: &SqlitePool,
        req: &CatalogExportRequest,
    ) -> Result<CatalogExportResult> {
        catalog_export::export_catalog(pool, req).await
    }

    pub async fn start_audio_export(
        pool: &SqlitePool,
        req: AudioExportRequest,
    ) -> Result<AudioExportProgress> {
        AudioExportManager::start_audio_export(pool, req).await
    }

    pub fn get_audio_export_progress(job_id: &str) -> Option<AudioExportProgress> {
        AudioExportManager::get_audio_export_progress(job_id)
    }

    pub fn cancel_audio_export(job_id: &str) -> bool {
        AudioExportManager::cancel_audio_export(job_id)
    }
}
