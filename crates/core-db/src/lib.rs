use std::path::Path;
use std::time::Duration;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous,
};
pub use sqlx::SqlitePool;

pub mod credential;
pub mod error;
pub mod repository;
pub mod search;

pub use credential::{
    validate_service_and_key, CredentialError, CredentialStore, FallbackCredentialStore,
    MemoryCredentialStore, DEFAULT_SERVICE_NAME,
};
#[cfg(feature = "os-keyring")]
pub use credential::KeyringStore;

pub use error::{DbError, ProfileError, Result};
pub use repository::{
    deterministic_artist_id, normalize_match_key, AlbumCredit, Artist, ArtworkCacheEntry,
    ArtworkOverride, ImmediateTx, LibraryRepository, PairedClient, PlayHistoryEntry,
    ProfileFavorite, ProfileRepository, PruneLocalTracksReport, TrackFileCacheInfo,
};
pub use search::{
    delete_fts_entry, rebuild_search_index, sanitize_fts5_query, search_library,
    search_library_with_limit, sync_album_fts, sync_artist_fts, sync_track_fts, SearchResult,
};

/// Initializes SQLite database with WAL mode, foreign keys, 5s busy timeout,
/// normal synchronous mode, and max 8 pooled connections, applying embedded migrations.
pub async fn open_database(db_path: &Path) -> Result<SqlitePool> {
    if let Some(parent) = db_path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    let options = SqliteConnectOptions::new()
        .filename(db_path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .busy_timeout(Duration::from_secs(5))
        .foreign_keys(true);

    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;
    Ok(pool)
}

/// Helper for tests to open an isolated in-memory database with migrations applied.
pub async fn open_test_database() -> Result<SqlitePool> {
    let options = SqliteConnectOptions::new()
        .filename(":memory:")
        .busy_timeout(Duration::from_secs(5))
        .foreign_keys(true);

    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;
    Ok(pool)
}
