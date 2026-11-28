use std::collections::{BTreeMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use chrono::Utc;
use core_types::{BackupHistoryRecord, BackupManifest, BackupTriggerMode};
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use uuid::Uuid;

use super::settings::get_backup_settings;
use crate::error::{DbError, Result};
use crate::write_coordinator::DbWriteCoordinator;

pub const CURRENT_SCHEMA_VERSION: i64 = 13;

const CORE_TABLES: &[&str] = &[
    "canonical_albums",
    "album_versions",
    "track_sources",
    "playlists",
    "smart_playlists",
    "tags",
    "bookmarks",
    "listen_later_items",
    "album_assets",
];

const MAX_PRE_RESTORE_KEEP: usize = 5;

#[derive(Debug, sqlx::FromRow)]
struct BackupHistoryRow {
    id: String,
    trigger_mode: String,
    backup_path: String,
    manifest_path: String,
    sha256: String,
    size_bytes: i64,
    schema_version: i64,
    status: String,
    error_message: Option<String>,
    created_at: String,
}

impl From<BackupHistoryRow> for BackupHistoryRecord {
    fn from(r: BackupHistoryRow) -> Self {
        let exists_on_disk = Path::new(&r.backup_path).is_file();
        Self {
            id: r.id,
            trigger_mode: BackupTriggerMode::from_str(&r.trigger_mode)
                .unwrap_or(BackupTriggerMode::Manual),
            backup_path: r.backup_path,
            manifest_path: r.manifest_path,
            sha256: r.sha256,
            size_bytes: r.size_bytes.max(0) as u64,
            schema_version: r.schema_version,
            status: r.status,
            error_message: r.error_message,
            created_at: r.created_at,
            exists_on_disk,
        }
    }
}

pub(crate) fn manifest_path_for_backup(backup_path: &Path) -> PathBuf {
    let mut os = backup_path.as_os_str().to_os_string();
    if let Some(stem) = backup_path.file_stem()
        && let Some(parent) = backup_path.parent()
    {
        return parent.join(format!("{}.manifest.json", stem.to_string_lossy()));
    }
    os.push(".manifest.json");
    PathBuf::from(os)
}

async fn compute_file_sha256(path: PathBuf) -> Result<String> {
    tokio::task::spawn_blocking(move || -> Result<String> {
        let mut file = std::fs::File::open(&path)?;
        let mut hasher = Sha256::new();
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let digest = hasher.finalize();
        let mut hex = String::with_capacity(digest.len() * 2);
        for b in digest {
            hex.push_str(&format!("{b:02x}"));
        }
        Ok(hex)
    })
    .await
    .map_err(|e| DbError::ConstraintViolation(format!("SHA-256 task failed: {e}")))?
}

async fn inspect_sqlite_archive(db_path: &Path) -> Result<(i64, BTreeMap<String, i64>)> {
    let options = SqliteConnectOptions::new()
        .filename(db_path)
        .read_only(true);
    let ro_pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?;

    let result: Result<(i64, BTreeMap<String, i64>)> = async {
        let checks: Vec<(String,)> = sqlx::query_as("PRAGMA integrity_check")
            .fetch_all(&ro_pool)
            .await?;
        if checks.len() != 1 || !checks[0].0.eq_ignore_ascii_case("ok") {
            let detail = checks
                .into_iter()
                .map(|(s,)| s)
                .collect::<Vec<_>>()
                .join("; ");
            return Err(DbError::ConstraintViolation(format!(
                "Backup SQLite integrity_check failed: {detail}"
            )));
        }

        let tables_rows: Vec<(String,)> =
            sqlx::query_as("SELECT name FROM sqlite_master WHERE type = 'table'")
                .fetch_all(&ro_pool)
                .await?;
        let existing_tables: HashSet<String> = tables_rows.into_iter().map(|(n,)| n).collect();

        let schema_version: i64 = if existing_tables.contains("_sqlx_migrations") {
            let (ver,): (Option<i64>,) =
                sqlx::query_as("SELECT MAX(version) FROM _sqlx_migrations")
                    .fetch_one(&ro_pool)
                    .await?;
            ver.unwrap_or(0)
        } else {
            return Err(DbError::ConstraintViolation(
                "Backup archive is missing _sqlx_migrations metadata table".into(),
            ));
        };

        let mut table_counts = BTreeMap::new();
        for &table in CORE_TABLES {
            let count = if existing_tables.contains(table) {
                let sql = format!("SELECT COUNT(*) FROM {table}");
                let (c,): (i64,) = sqlx::query_as(&sql).fetch_one(&ro_pool).await?;
                c
            } else {
                0
            };
            table_counts.insert(table.to_string(), count);
        }

        Ok((schema_version, table_counts))
    }
    .await;

    ro_pool.close().await;
    result
}

async fn atomic_write_bytes(target: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = target.with_extension(format!(
        "{}.tmp",
        target
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("file")
    ));
    tokio::fs::write(&tmp, bytes).await?;
    if target.exists() {
        let _ = tokio::fs::remove_file(target).await;
    }
    if let Err(err) = tokio::fs::rename(&tmp, target).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(err.into());
    }
    Ok(())
}

async fn prune_backup_rows(
    pool: &SqlitePool,
    where_clause: &str,
    keep_limit: usize,
) -> Result<usize> {
    let sql = format!(
        "SELECT id, backup_path, manifest_path \
         FROM backup_history \
         WHERE status = 'completed' AND {where_clause} \
         ORDER BY created_at DESC, rowid DESC"
    );
    let rows: Vec<(String, String, String)> = sqlx::query_as(&sql).fetch_all(pool).await?;
    let mut pruned = 0usize;
    for (id, backup_path, manifest_path) in rows.into_iter().skip(keep_limit) {
        let _ = tokio::fs::remove_file(&backup_path).await;
        let _ = tokio::fs::remove_file(&manifest_path).await;
        sqlx::query("UPDATE backup_history SET status = 'pruned' WHERE id = ?")
            .bind(&id)
            .execute(pool)
            .await?;
        pruned += 1;
    }
    Ok(pruned)
}

pub async fn create_library_backup(
    pool: &SqlitePool,
    trigger_mode: BackupTriggerMode,
    backup_dir_override: Option<&Path>,
) -> Result<BackupHistoryRecord> {
    let settings = get_backup_settings(pool, None).await?;
    let target_dir = backup_dir_override
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from(&settings.resolved_backup_dir));
    tokio::fs::create_dir_all(&target_dir).await?;

    let backup_id = Uuid::new_v4().to_string();
    let short_id = &backup_id[..8];
    let now = Utc::now();
    let created_at = now.to_rfc3339();
    let ts = now.format("%Y%m%d_%H%M%S");
    let stem = format!("lumina_backup_{ts}_{short_id}");
    let tmp_db = target_dir.join(format!("{stem}.db.tmp"));
    let final_db = target_dir.join(format!("{stem}.db"));
    let manifest_path = target_dir.join(format!("{stem}.manifest.json"));

    let coord = DbWriteCoordinator::for_pool(pool);

    // 1. WAL-safe hot snapshot via SQLite VACUUM INTO under single-writer lock.
    {
        let _write_guard = coord.write_lock().await;
        if tmp_db.exists() {
            let _ = tokio::fs::remove_file(&tmp_db).await;
        }
        let vacuum_res = sqlx::query("VACUUM INTO ?")
            .bind(tmp_db.to_string_lossy().as_ref())
            .execute(pool)
            .await;
        if let Err(err) = vacuum_res {
            let _ = tokio::fs::remove_file(&tmp_db).await;
            return Err(err.into());
        }
        if let Err(err) = tokio::fs::rename(&tmp_db, &final_db).await {
            let _ = tokio::fs::remove_file(&tmp_db).await;
            return Err(err.into());
        }
    }

    // 2. Verify standalone snapshot integrity + compute schema, row counts & SHA-256.
    let inspect_res = inspect_sqlite_archive(&final_db).await;
    let (schema_version, table_counts) = match inspect_res {
        Ok(v) => v,
        Err(err) => {
            let _ = tokio::fs::remove_file(&final_db).await;
            return Err(err);
        }
    };
    let sha256 = compute_file_sha256(final_db.clone()).await?;
    let size_bytes = tokio::fs::metadata(&final_db).await?.len();

    let manifest = BackupManifest {
        backup_id: backup_id.clone(),
        created_at: created_at.clone(),
        trigger_mode,
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        schema_version,
        db_filename: format!("{stem}.db"),
        sha256: sha256.clone(),
        size_bytes,
        table_counts,
    };
    let manifest_json = serde_json::to_vec_pretty(&manifest)
        .map_err(|e| DbError::ConstraintViolation(format!("Serialize backup manifest: {e}")))?;
    atomic_write_bytes(&manifest_path, &manifest_json).await?;

    let backup_path_str = final_db.to_string_lossy().to_string();
    let manifest_path_str = manifest_path.to_string_lossy().to_string();

    // 3. Record history & enforce retention policy.
    {
        let _write_guard = coord.write_lock().await;
        sqlx::query(
            "INSERT INTO backup_history \
                 (id, trigger_mode, backup_path, manifest_path, sha256, size_bytes, \
                  schema_version, status, error_message, created_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, 'completed', NULL, ?)",
        )
        .bind(&backup_id)
        .bind(trigger_mode.as_str())
        .bind(&backup_path_str)
        .bind(&manifest_path_str)
        .bind(&sha256)
        .bind(size_bytes as i64)
        .bind(schema_version)
        .bind(&created_at)
        .execute(pool)
        .await?;

        if trigger_mode == BackupTriggerMode::PreRestore {
            let _ =
                prune_backup_rows(pool, "trigger_mode = 'pre_restore'", MAX_PRE_RESTORE_KEEP).await;
        } else {
            let _ = prune_backup_rows(
                pool,
                "trigger_mode != 'pre_restore'",
                settings.max_keep as usize,
            )
            .await;
        }
    }

    Ok(BackupHistoryRecord {
        id: backup_id,
        trigger_mode,
        backup_path: backup_path_str,
        manifest_path: manifest_path_str,
        sha256,
        size_bytes,
        schema_version,
        status: "completed".to_string(),
        error_message: None,
        created_at,
        exists_on_disk: true,
    })
}

pub async fn list_backup_history(
    pool: &SqlitePool,
    limit: u32,
) -> Result<Vec<BackupHistoryRecord>> {
    let clamped = if limit == 0 { 50 } else { limit.clamp(1, 500) };
    let rows: Vec<BackupHistoryRow> = sqlx::query_as(
        "SELECT id, trigger_mode, backup_path, manifest_path, sha256, size_bytes, \
                schema_version, status, error_message, created_at \
         FROM backup_history \
         ORDER BY created_at DESC, rowid DESC \
         LIMIT ?",
    )
    .bind(i64::from(clamped))
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(Into::into).collect())
}

pub async fn verify_backup_archive(backup_path: &Path) -> Result<(BackupManifest, PathBuf)> {
    if !backup_path.is_file() {
        return Err(DbError::NotFound(format!(
            "Backup file not found: {}",
            backup_path.display()
        )));
    }

    let manifest_path = manifest_path_for_backup(backup_path);
    if !manifest_path.is_file() {
        return Err(DbError::NotFound(format!(
            "Backup manifest not found: {}",
            manifest_path.display()
        )));
    }

    let raw_manifest = tokio::fs::read_to_string(&manifest_path).await?;
    let manifest: BackupManifest = serde_json::from_str(&raw_manifest)
        .map_err(|e| DbError::ConstraintViolation(format!("Invalid backup manifest JSON: {e}")))?;

    if manifest.schema_version > CURRENT_SCHEMA_VERSION {
        return Err(DbError::ConstraintViolation(format!(
            "Backup schema version {} exceeds supported version {}",
            manifest.schema_version, CURRENT_SCHEMA_VERSION
        )));
    }

    let actual_sha256 = compute_file_sha256(backup_path.to_path_buf()).await?;
    if !actual_sha256.eq_ignore_ascii_case(manifest.sha256.trim()) {
        return Err(DbError::ConstraintViolation(format!(
            "Backup SHA-256 mismatch: expected {}, got {actual_sha256}",
            manifest.sha256
        )));
    }

    let (actual_schema, _) = inspect_sqlite_archive(backup_path).await?;
    if actual_schema > CURRENT_SCHEMA_VERSION {
        return Err(DbError::ConstraintViolation(format!(
            "Backup database schema version {actual_schema} exceeds supported version {CURRENT_SCHEMA_VERSION}"
        )));
    }

    Ok((manifest, manifest_path))
}

pub async fn is_scheduled_backup_due(pool: &SqlitePool) -> Result<bool> {
    use chrono::Duration as ChronoDuration;
    use core_types::BackupScheduleMode;

    let settings = get_backup_settings(pool, None).await?;
    let interval = match settings.schedule_mode {
        BackupScheduleMode::Off => return Ok(false),
        BackupScheduleMode::Daily => ChronoDuration::hours(24),
        BackupScheduleMode::Weekly => ChronoDuration::days(7),
    };

    let row: Option<(String,)> = sqlx::query_as(
        "SELECT created_at \
         FROM backup_history \
         WHERE status = 'completed' AND trigger_mode != 'pre_restore' \
         ORDER BY created_at DESC, rowid DESC \
         LIMIT 1",
    )
    .fetch_optional(pool)
    .await?;

    let Some((last_created,)) = row else {
        return Ok(true);
    };
    let Ok(last_dt) = chrono::DateTime::parse_from_rfc3339(&last_created) else {
        return Ok(true);
    };
    Ok(Utc::now().signed_duration_since(last_dt.with_timezone(&Utc)) >= interval)
}
