use crate::error::Result;
use sqlx::pool::PoolConnection;
use sqlx::{Sqlite, SqlitePool};

/// Immediate transaction guard for SQLite WAL mode.
///
/// Acquires a connection and immediately issues `BEGIN IMMEDIATE`, acquiring a reserved
/// write lock immediately. This guarantees that multi-statement read-modify-write transactions
/// will not fail with `SQLITE_BUSY_SNAPSHOT (code: 517)` due to stale WAL read snapshots
/// when other transactions commit concurrently.
pub struct ImmediateTx {
    conn: Option<PoolConnection<Sqlite>>,
}

impl ImmediateTx {
    /// Acquires a connection from the pool and starts a `BEGIN IMMEDIATE` transaction.
    pub async fn begin(pool: &SqlitePool) -> Result<Self> {
        let mut conn = pool.acquire().await?;
        sqlx::query("BEGIN IMMEDIATE").execute(&mut *conn).await?;
        Ok(Self { conn: Some(conn) })
    }

    /// Provides mutable access to the underlying connection for executing queries.
    pub fn conn(&mut self) -> &mut sqlx::SqliteConnection {
        self.conn.as_mut().expect("transaction already completed")
    }

    /// Commits the immediate transaction.
    pub async fn commit(mut self) -> Result<()> {
        if let Some(mut conn) = self.conn.take() {
            sqlx::query("COMMIT").execute(&mut *conn).await?;
        }
        Ok(())
    }

    /// Rolls back the immediate transaction.
    pub async fn rollback(mut self) -> Result<()> {
        if let Some(mut conn) = self.conn.take() {
            let _ = sqlx::query("ROLLBACK").execute(&mut *conn).await;
        }
        Ok(())
    }
}
