use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use anyhow::{Context, anyhow};
use core_db::{BackupExportRepository, DbWriteCoordinator, L1StreamCacheRepository, open_database};
use core_types::{BackupTriggerMode, RestoreBackupResult};
use tokio_util::sync::CancellationToken;

use super::state::EngineState;

fn wal_sidecar_paths(db_path: &Path) -> (PathBuf, PathBuf) {
    let mut wal = db_path.as_os_str().to_os_string();
    wal.push("-wal");
    let mut shm = db_path.as_os_str().to_os_string();
    shm.push("-shm");
    (PathBuf::from(wal), PathBuf::from(shm))
}

fn remove_wal_sidecars(db_path: &Path) {
    let (wal, shm) = wal_sidecar_paths(db_path);
    let _ = std::fs::remove_file(&wal);
    let _ = std::fs::remove_file(&shm);
}

fn restore_tmp_and_old_paths(db_path: &Path) -> (PathBuf, PathBuf) {
    let mut tmp = db_path.as_os_str().to_os_string();
    tmp.push(".restore_tmp");
    let mut old = db_path.as_os_str().to_os_string();
    old.push(".restore_old");
    (PathBuf::from(tmp), PathBuf::from(old))
}

fn rewire_pool_into_engine(engine: &EngineState, pool: core_db::SqlitePool) {
    if let Ok(mut guard) = engine.db_pool.write() {
        *guard = Some(pool.clone());
    }
    engine
        .runtime
        .block_on(engine.zone_manager.swap_db_pool(Some(pool.clone())));
    let _ = engine.init_ingestion_for_pool(pool);
    if engine.player_clone().is_some() {
        let _ = crate::l2_cache::ensure_default_l2_cache_manager(engine);
    }
}

fn rollback_and_reopen(
    engine: &EngineState,
    db_path: &Path,
    old_db_path: &Path,
    pre_restore_backup_path: &Path,
) {
    remove_wal_sidecars(db_path);
    let _ = std::fs::remove_file(db_path);
    if old_db_path.is_file() {
        if std::fs::rename(old_db_path, db_path).is_err() {
            let _ = std::fs::copy(pre_restore_backup_path, db_path);
        }
    } else {
        let _ = std::fs::copy(pre_restore_backup_path, db_path);
    }
    if let Ok(rolled_pool) = engine.runtime.block_on(open_database(db_path)) {
        rewire_pool_into_engine(engine, rolled_pool);
    }
}

/// Safely restores the live SQLite library database from a verified backup archive.
///
/// Enforces strict Windows-safe teardown ordering so every `SqlitePool` handle across
/// embedded HTTP server, ingestion watchers, L1/L2 caches, and `ZoneManager` is dropped
/// before the database file is replaced, with automatic `pre_restore` backup & rollback.
pub fn restore_database_from_backup(
    engine: &EngineState,
    backup_path: &Path,
) -> anyhow::Result<RestoreBackupResult> {
    // 1. Verify candidate backup BEFORE touching the live database.
    let (manifest, _manifest_path) = engine
        .runtime
        .block_on(BackupExportRepository::verify_backup_archive(backup_path))
        .map_err(|e| anyhow!("Backup archive verification failed: {e}"))?;

    // 2. Resolve live DB path & pool.
    let db_path_str = engine
        .db_path
        .read()
        .ok()
        .and_then(|g| g.clone())
        .filter(|s| !s.trim().is_empty() && s.trim() != ":memory:")
        .ok_or_else(|| anyhow!("Database restore requires an on-disk SQLite database"))?;
    let db_path = PathBuf::from(&db_path_str);

    // 3. Create automatic pre_restore snapshot before tearing down live connections.
    let pre_restore = {
        let live_pool = engine
            .db_pool
            .read()
            .ok()
            .and_then(|g| g.clone())
            .ok_or_else(|| anyhow!("Library database pool is not initialized"))?;
        engine
            .runtime
            .block_on(BackupExportRepository::create_library_backup(
                &live_pool,
                BackupTriggerMode::PreRestore,
                None,
            ))
            .map_err(|e| anyhow!("Failed to create pre_restore safety backup: {e}"))?
    };
    let pre_restore_path = PathBuf::from(&pre_restore.backup_path);

    // 4. Serialize against all writers on this database path.
    let write_guard = engine
        .runtime
        .block_on(DbWriteCoordinator::for_path(&db_path).write_lock());

    // 5. Remember embedded server state, then stop it and await task completion.
    let was_server_running = engine.server_running.load(Ordering::SeqCst);
    let prev_port = engine.server_port.load(Ordering::SeqCst);
    let prev_mdns = engine.server_mdns_enabled.load(Ordering::SeqCst);
    crate::server::stop_embedded_server(engine);

    // 6. Stop backup scheduler, ingestion, L1/L2 caches, and ZoneManager pool.
    if let Ok(mut guard) = engine.backup_scheduler_cancel.write()
        && let Some(token) = guard.take()
    {
        token.cancel();
    }
    engine.shutdown_ingestion();
    crate::l1_cache::flush_pending_writes(engine);

    if let Some(player) = engine.player_clone() {
        player.set_l2_cache_manager(None);
    }
    let taken_l2 = engine
        .l2_cache_manager
        .write()
        .ok()
        .and_then(|mut g| g.take());
    if let Some(mgr) = taken_l2 {
        engine.runtime.block_on(async move {
            let _ = tokio::time::timeout(Duration::from_secs(3), mgr.shutdown()).await;
        });
    }

    engine
        .runtime
        .block_on(engine.zone_manager.swap_db_pool(None));

    // 7. Checkpoint WAL TRUNCATE, close and drop the final SqlitePool handle.
    let taken_pool = engine.db_pool.write().ok().and_then(|mut g| g.take());
    if let Some(pool) = taken_pool {
        engine.runtime.block_on(async move {
            let _ = tokio::time::timeout(Duration::from_secs(5), async move {
                let _ = L1StreamCacheRepository::wal_checkpoint_truncate(&pool).await;
                pool.close().await;
            })
            .await;
        });
    }

    // 8. Delete stale WAL/SHM sidecars and atomically replace db_path with verified backup.
    remove_wal_sidecars(&db_path);
    let (tmp_db, old_db) = restore_tmp_and_old_paths(&db_path);
    let _ = std::fs::remove_file(&tmp_db);
    let _ = std::fs::remove_file(&old_db);

    let replace_res: anyhow::Result<()> = (|| {
        std::fs::copy(backup_path, &tmp_db).with_context(|| {
            format!(
                "Failed to stage verified backup {} to {}",
                backup_path.display(),
                tmp_db.display()
            )
        })?;
        if db_path.exists() {
            std::fs::rename(&db_path, &old_db).with_context(|| {
                format!(
                    "Failed to move live database {} aside for atomic swap",
                    db_path.display()
                )
            })?;
        }
        std::fs::rename(&tmp_db, &db_path).with_context(|| {
            format!(
                "Failed to rename staged backup {} into {}",
                tmp_db.display(),
                db_path.display()
            )
        })?;
        Ok(())
    })();

    if let Err(err) = replace_res {
        let _ = std::fs::remove_file(&tmp_db);
        rollback_and_reopen(engine, &db_path, &old_db, &pre_restore_path);
        drop(write_guard);
        if was_server_running {
            let _ = crate::server::restart_embedded_server(engine, prev_port, prev_mdns);
        }
        return Err(err);
    }

    // 9. Re-open restored database; automatically roll back from pre_restore on error.
    let new_pool = match engine.runtime.block_on(open_database(&db_path)) {
        Ok(pool) => {
            let _ = std::fs::remove_file(&old_db);
            pool
        }
        Err(err) => {
            rollback_and_reopen(engine, &db_path, &old_db, &pre_restore_path);
            drop(write_guard);
            if was_server_running {
                let _ = crate::server::restart_embedded_server(engine, prev_port, prev_mdns);
            }
            return Err(anyhow!(
                "Failed to open restored database (rolled back to pre_restore backup): {err}"
            ));
        }
    };

    rewire_pool_into_engine(engine, new_pool);
    drop(write_guard);

    if was_server_running {
        crate::server::restart_embedded_server(engine, prev_port, prev_mdns)?;
    }

    Ok(RestoreBackupResult {
        restored_backup_id: manifest.backup_id,
        pre_restore_backup_id: Some(pre_restore.id),
        restored_from_path: backup_path.to_string_lossy().to_string(),
        schema_version: manifest.schema_version,
        table_counts: manifest.table_counts,
        reload_required: true,
    })
}

/// Ensures a single lightweight background Tokio scheduler checks `daily` / `weekly`
/// scheduled backup settings periodically and triggers `VACUUM INTO` backups when due.
pub fn ensure_backup_scheduler(engine: &Arc<EngineState>) {
    let cancel = CancellationToken::new();
    if let Ok(mut guard) = engine.backup_scheduler_cancel.write()
        && let Some(prev) = guard.replace(cancel.clone())
    {
        prev.cancel();
    }

    let weak_engine = Arc::downgrade(engine);
    engine.runtime.spawn(async move {
        // Initial delay avoids adding I/O contention during cold startup.
        tokio::select! {
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep(Duration::from_secs(60)) => {}
        }

        let mut ticker = tokio::time::interval(Duration::from_secs(1800));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            let Some(eng) = weak_engine.upgrade() else {
                break;
            };
            let maybe_pool = eng.db_pool.read().ok().and_then(|g| g.clone());
            if let Some(pool) = maybe_pool {
                match BackupExportRepository::is_scheduled_backup_due(&pool).await {
                    Ok(true) => {
                        if let Err(err) = BackupExportRepository::create_library_backup(
                            &pool,
                            BackupTriggerMode::Scheduled,
                            None,
                        )
                        .await
                        {
                            tracing::warn!("Scheduled library backup failed: {err}");
                        }
                    }
                    Ok(false) => {}
                    Err(err) => {
                        tracing::warn!("Scheduled backup due check failed: {err}");
                    }
                }
            }

            tokio::select! {
                _ = cancel.cancelled() => break,
                _ = ticker.tick() => {}
            }
        }
    });
}
