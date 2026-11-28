use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, OnceLock, Weak};

use sqlx::SqlitePool;
use tokio::sync::{Mutex, OwnedMutexGuard};

use crate::repository::library::normalize_local_path_for_compare;
use crate::repository::tx::ImmediateTx;

/// Lightweight single-writer coordinator for SQLite WAL write serialization.
///
/// Cloning a `DbWriteCoordinator` shares the underlying async mutex so all library
/// writers (`IngestionPipeline`, `LibrarySyncService`, `CreditEnrichmentService`,
/// `core-server`, `core-ffi`) serialize write transactions cleanly without `SQLITE_BUSY`
/// lock contention storms while concurrent WAL readers remain completely non-blocking.
#[derive(Clone, Debug)]
pub struct DbWriteCoordinator {
    lock: Arc<Mutex<()>>,
}

impl Default for DbWriteCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl DbWriteCoordinator {
    /// Creates a new isolated single-writer coordinator.
    pub fn new() -> Self {
        Self {
            lock: Arc::new(Mutex::new(())),
        }
    }

    /// Returns a process-wide shared coordinator keyed by normalized database file path.
    ///
    /// Multiple handles opened against the same on-disk SQLite file (e.g., `EngineState`
    /// and an embedded `core-server` `AppState`) automatically share the same writer lock.
    pub fn for_path(db_path: &Path) -> Self {
        static REGISTRY: OnceLock<std::sync::Mutex<HashMap<String, Weak<Mutex<()>>>>> =
            OnceLock::new();
        let key = normalize_local_path_for_compare(&db_path.to_string_lossy());
        let map_lock = REGISTRY.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
        let mut guard = map_lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.retain(|_, weak| weak.strong_count() > 0);
        if let Some(existing) = guard.get(&key).and_then(Weak::upgrade) {
            return Self { lock: existing };
        }
        let lock = Arc::new(Mutex::new(()));
        guard.insert(key, Arc::downgrade(&lock));
        Self { lock }
    }

    /// Returns a coordinator bound to the SQLite pool's backing file path when file-backed,
    /// or a dedicated coordinator for in-memory (`:memory:`) pools.
    pub fn for_pool(pool: &SqlitePool) -> Self {
        let filename = pool.connect_options().get_filename().to_path_buf();
        let raw = filename.to_string_lossy();
        if raw.is_empty() || raw == ":memory:" {
            Self::new()
        } else {
            Self::for_path(&filename)
        }
    }

    /// Acquires the single-writer async mutex guard.
    pub async fn write_lock(&self) -> OwnedMutexGuard<()> {
        Arc::clone(&self.lock).lock_owned().await
    }

    /// Acquires the single-writer lock and starts a `BEGIN IMMEDIATE` SQLite transaction.
    ///
    /// Keeping the returned `OwnedMutexGuard<()>` alive until after `tx.commit()` or
    /// `tx.rollback()` guarantees zero concurrent writer overlap across tasks.
    pub async fn begin_immediate(
        &self,
        pool: &SqlitePool,
    ) -> std::result::Result<(OwnedMutexGuard<()>, ImmediateTx), sqlx::Error> {
        let guard = self.write_lock().await;
        let tx = ImmediateTx::begin_sqlx(pool).await?;
        Ok((guard, tx))
    }
}
