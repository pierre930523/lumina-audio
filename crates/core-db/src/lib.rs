pub use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use std::path::Path;
use std::time::Duration;

pub mod credential;
pub mod error;
pub mod repository;
pub mod search;
pub mod write_coordinator;

#[cfg(feature = "os-keyring")]
pub use credential::KeyringStore;
pub use credential::{
    CredentialError, CredentialStore, DEFAULT_SERVICE_NAME, FallbackCredentialStore,
    MemoryCredentialStore, validate_service_and_key,
};

pub use error::{DbError, ProfileError, Result};
pub use repository::folders::FolderRepository;
pub use repository::{
    AlbumAssetRepository, AlbumCredit, AlbumGroupingBindingsSnapshot, AlbumUserBindingsSnapshot,
    Artist, ArtworkCacheEntry, ArtworkOverride, BackupExportRepository, BookmarkRepository,
    BulkEditRepository, CatalogAlbumSummaryRow, CatalogQueryRepository, CatalogTrackRow,
    DEFAULT_METADATA_POLICY_PREF_KEY, ForceRebuildFinalizeReport, ForceRebuildPrepareReport,
    ImmediateTx, IngestionRepository, L1StreamCacheRepository, L1StreamUrlRecord, L2AccessUpdate,
    L2CacheStoreError, L2HeadCacheRepository, L2HeadCacheStore, L2HeadChunkRecord,
    LibraryRepository, ListenLaterRepository, PairedClient, PairingRepository, PlayHistoryEntry,
    PlaylistImproverRepository, PreferenceRepository, ProfileFavorite, ProfileRepository,
    PruneLocalTracksReport, PruneOrphansReport, PurgeMissingReport, RelinkCandidate,
    SidecarPlaylist, SidecarPlaylistEntry, SmartPlaylistRepository, SqliteL2HeadCacheStore,
    TrackFileCacheInfo, ZonesRepository, deterministic_artist_id, normalize_match_key,
};
pub use search::{
    SearchResult, delete_fts_entry, delete_fts_entry_conn, rebuild_search_index,
    rebuild_search_index_conn, sanitize_fts5_query, search_library, search_library_with_limit,
    sync_album_fts, sync_album_fts_conn, sync_artist_fts, sync_artist_fts_conn,
    sync_single_album_fts_visibility_conn, sync_track_fts, sync_track_fts_conn,
};
pub use write_coordinator::DbWriteCoordinator;

/// Initializes SQLite database with WAL mode, foreign keys, 5s busy timeout,
/// normal synchronous mode, tuned cache/checkpoint pragmas, and max 8 pooled connections,
/// applying embedded migrations.
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
        .foreign_keys(true)
        .pragma("cache_size", "-32000")
        .pragma("temp_store", "MEMORY")
        .pragma("wal_autocheckpoint", "2000");

    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;
    FolderRepository::backfill_library_folders_if_needed(&pool).await?;
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
    FolderRepository::backfill_library_folders_if_needed(&pool).await?;
    Ok(pool)
}
