use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::{Path, PathBuf};

use core_db::BackupExportRepository;
use core_types::{AudioExportRequest, BackupScheduleMode, BackupTriggerMode, CatalogExportRequest};
use serde::Deserialize;

use super::ensure_db_pool;
use crate::engine::{ensure_backup_scheduler, get_engine, restore_database_from_backup};
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
    string_to_c_char,
};

#[derive(Debug, Deserialize)]
struct FfiUpdateBackupSettingsPayload {
    #[serde(default)]
    backup_dir: String,
    #[serde(default)]
    schedule_mode: BackupScheduleMode,
    #[serde(default = "default_max_keep")]
    max_keep: u32,
}

fn default_max_keep() -> u32 {
    10
}

#[derive(Debug, Deserialize, Default)]
struct FfiCreateBackupPayload {
    #[serde(default)]
    trigger_mode: BackupTriggerMode,
    #[serde(default)]
    backup_dir_override: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FfiRestoreBackupPayload {
    backup_path: String,
}

fn read_c_str<'a>(ptr: *const c_char, name: &str) -> anyhow::Result<&'a str> {
    if ptr.is_null() {
        anyhow::bail!("{name} is null");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

fn current_db_path_opt(engine: &crate::engine::EngineState) -> Option<PathBuf> {
    engine
        .db_path
        .read()
        .ok()
        .and_then(|g| g.clone())
        .filter(|s| !s.trim().is_empty() && s.trim() != ":memory:")
        .map(PathBuf::from)
}

/// Returns current `BackupSettings` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_backup_settings() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_backup_settings",
        || {
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let db_path = current_db_path_opt(&engine);
            let settings = engine
                .runtime
                .block_on(BackupExportRepository::get_backup_settings(
                    &pool,
                    db_path.as_deref(),
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(string_to_c_char(&serde_json::to_string(&settings)?))
        },
    )
}

/// Updates `BackupSettings` from JSON and refreshes the periodic scheduled-backup task.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_update_backup_settings(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_update_backup_settings",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: FfiUpdateBackupSettingsPayload = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let db_path = current_db_path_opt(&engine);
            let updated = engine
                .runtime
                .block_on(BackupExportRepository::update_backup_settings(
                    &pool,
                    db_path.as_deref(),
                    &req.backup_dir,
                    req.schedule_mode,
                    req.max_keep,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            ensure_backup_scheduler(&engine);
            Ok(string_to_c_char(&serde_json::to_string(&updated)?))
        },
    )
}

/// Lists recent `BackupHistoryRecord` rows as a JSON array.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_list_backup_history(limit: u32) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_list_backup_history",
        || {
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };
            let list = engine
                .runtime
                .block_on(BackupExportRepository::list_backup_history(&pool, limit))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(string_to_c_char(&serde_json::to_string(&list)?))
        },
    )
}

/// Executes a WAL-safe `VACUUM INTO` hot backup and returns `BackupHistoryRecord` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_create_backup(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_library_create_backup", || {
        let req = if req_json.is_null() {
            FfiCreateBackupPayload::default()
        } else {
            let raw = unsafe { CStr::from_ptr(req_json) }.to_str()?.trim();
            if raw.is_empty() {
                FfiCreateBackupPayload::default()
            } else {
                serde_json::from_str::<FfiCreateBackupPayload>(raw)?
            }
        };
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let dir_override = req
            .backup_dir_override
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(Path::new);
        let rec = engine
            .runtime
            .block_on(BackupExportRepository::create_library_backup(
                &pool,
                req.trigger_mode,
                dir_override,
            ))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(string_to_c_char(&serde_json::to_string(&rec)?))
    })
}

/// Safely verifies, tears down pools, replaces, and reconnects the live SQLite database
/// from a backup archive, returning `RestoreBackupResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_restore_backup(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_restore_backup",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: FfiRestoreBackupPayload = serde_json::from_str(raw)?;
            let trimmed = req.backup_path.trim();
            if trimmed.is_empty() {
                anyhow::bail!("backup_path must not be empty");
            }
            let engine = get_engine();
            let res = restore_database_from_backup(&engine, Path::new(trimmed))?;
            ensure_backup_scheduler(&engine);
            Ok(string_to_c_char(&serde_json::to_string(&res)?))
        },
    )
}

/// Exports library catalog metadata (CSV / JSON) and returns `CatalogExportResult` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_export_catalog(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_export_catalog",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: CatalogExportRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let res = engine
                .runtime
                .block_on(BackupExportRepository::export_catalog(&pool, &req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(string_to_c_char(&serde_json::to_string(&res)?))
        },
    )
}

/// Starts an asynchronous local audio + `.m3u8` export job and returns initial `AudioExportProgress` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_start_audio_export(req_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_start_audio_export",
        || {
            let raw = read_c_str(req_json, "req_json")?;
            let req: AudioExportRequest = serde_json::from_str(raw)?;
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let progress = engine
                .runtime
                .block_on(BackupExportRepository::start_audio_export(&pool, req))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(string_to_c_char(&serde_json::to_string(&progress)?))
        },
    )
}

/// Polls progress for an asynchronous audio export job as `AudioExportProgress` JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_audio_export_progress(job_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_audio_export_progress",
        || {
            let id = read_c_str(job_id, "job_id")?.trim();
            let Some(progress) = BackupExportRepository::get_audio_export_progress(id) else {
                set_last_error(format!("Audio export job '{id}' not found"));
                return Ok(std::ptr::null_mut());
            };
            Ok(string_to_c_char(&serde_json::to_string(&progress)?))
        },
    )
}

/// Signals cancellation for an asynchronous audio export job. Returns `LUMINA_OK` (0) if found.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_cancel_audio_export(job_id: *const c_char) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_cancel_audio_export",
        || {
            if job_id.is_null() {
                set_last_error("job_id is null");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let id = unsafe { CStr::from_ptr(job_id) }.to_str()?.trim();
            if BackupExportRepository::cancel_audio_export(id) {
                Ok(LUMINA_OK)
            } else {
                set_last_error(format!("Audio export job '{id}' not found"));
                Ok(LUMINA_ERR_GENERAL)
            }
        },
    )
}
