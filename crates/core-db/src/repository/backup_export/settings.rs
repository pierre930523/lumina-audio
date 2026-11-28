use std::path::{Path, PathBuf};
use std::str::FromStr;

use core_types::{BackupScheduleMode, BackupSettings};
use sqlx::SqlitePool;

use crate::error::Result;
use crate::repository::LibraryRepository;
use crate::write_coordinator::DbWriteCoordinator;

pub const BACKUP_DIR_PREF_KEY: &str = "backup_dir";
pub const BACKUP_SCHEDULE_MODE_PREF_KEY: &str = "backup_schedule_mode";
pub const BACKUP_MAX_KEEP_PREF_KEY: &str = "backup_max_keep";
pub const DEFAULT_BACKUP_MAX_KEEP: u32 = 10;
const MIN_BACKUP_MAX_KEEP: u32 = 1;
const MAX_BACKUP_MAX_KEEP: u32 = 100;

pub(crate) fn clamp_max_keep(value: u32) -> u32 {
    if value == 0 {
        DEFAULT_BACKUP_MAX_KEEP
    } else {
        value.clamp(MIN_BACKUP_MAX_KEEP, MAX_BACKUP_MAX_KEEP)
    }
}

pub(crate) fn resolve_backup_dir(
    pool: &SqlitePool,
    configured_dir: &str,
    db_path_opt: Option<&Path>,
) -> PathBuf {
    let trimmed = configured_dir.trim();
    if !trimmed.is_empty() {
        return PathBuf::from(trimmed);
    }

    if let Some(path) = db_path_opt
        && let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty())
    {
        return parent.join("backups");
    }

    let pool_file = pool.connect_options().get_filename().to_path_buf();
    let raw = pool_file.to_string_lossy();
    if !raw.is_empty()
        && raw != ":memory:"
        && let Some(parent) = pool_file.parent().filter(|p| !p.as_os_str().is_empty())
    {
        return parent.join("backups");
    }

    std::env::temp_dir().join("lumina_backups")
}

pub async fn get_backup_settings(
    pool: &SqlitePool,
    db_path_opt: Option<&Path>,
) -> Result<BackupSettings> {
    let backup_dir = LibraryRepository::get_preference(pool, BACKUP_DIR_PREF_KEY)
        .await?
        .unwrap_or_default()
        .trim()
        .to_string();

    let schedule_mode = LibraryRepository::get_preference(pool, BACKUP_SCHEDULE_MODE_PREF_KEY)
        .await?
        .and_then(|v| BackupScheduleMode::from_str(&v).ok())
        .unwrap_or(BackupScheduleMode::Off);

    let max_keep = LibraryRepository::get_preference(pool, BACKUP_MAX_KEEP_PREF_KEY)
        .await?
        .and_then(|v| v.trim().parse::<u32>().ok())
        .map(clamp_max_keep)
        .unwrap_or(DEFAULT_BACKUP_MAX_KEEP);

    let resolved_backup_dir = resolve_backup_dir(pool, &backup_dir, db_path_opt)
        .to_string_lossy()
        .to_string();

    Ok(BackupSettings {
        backup_dir,
        schedule_mode,
        max_keep,
        resolved_backup_dir,
    })
}

pub async fn update_backup_settings(
    pool: &SqlitePool,
    db_path_opt: Option<&Path>,
    backup_dir: &str,
    schedule_mode: BackupScheduleMode,
    max_keep: u32,
) -> Result<BackupSettings> {
    let clean_dir = backup_dir.trim().to_string();
    let clamped_keep = clamp_max_keep(max_keep);

    let coord = DbWriteCoordinator::for_pool(pool);
    let _write_guard = coord.write_lock().await;

    LibraryRepository::set_preference(pool, BACKUP_DIR_PREF_KEY, &clean_dir).await?;
    LibraryRepository::set_preference(pool, BACKUP_SCHEDULE_MODE_PREF_KEY, schedule_mode.as_str())
        .await?;
    LibraryRepository::set_preference(pool, BACKUP_MAX_KEEP_PREF_KEY, &clamped_keep.to_string())
        .await?;

    let resolved_backup_dir = resolve_backup_dir(pool, &clean_dir, db_path_opt)
        .to_string_lossy()
        .to_string();

    Ok(BackupSettings {
        backup_dir: clean_dir,
        schedule_mode,
        max_keep: clamped_keep,
        resolved_backup_dir,
    })
}
