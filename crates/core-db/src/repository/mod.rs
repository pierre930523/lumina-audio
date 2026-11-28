pub mod album_assets;
pub mod backup_export;
pub mod bookmarks;
pub mod bulk_edit;
pub mod catalog_album_groups;
pub mod catalog_queries;
pub mod focus;
pub mod folders;
pub mod ingestion;
pub mod l1_cache;
pub mod l2_cache;
pub mod library;
pub mod listen_later;
pub mod pairing;
pub mod playlist_improver;
pub mod preferences;
pub mod profile;
pub mod smart_playlists;
pub mod tags;
pub mod tx;
pub mod zones;

pub use album_assets::AlbumAssetRepository;
pub use backup_export::BackupExportRepository;
pub use bookmarks::BookmarkRepository;
pub use bulk_edit::BulkEditRepository;
pub use catalog_queries::{CatalogAlbumSummaryRow, CatalogQueryRepository, CatalogTrackRow};
pub use ingestion::{IngestionRepository, RelinkCandidate, SidecarPlaylist, SidecarPlaylistEntry};
pub use l1_cache::{L1StreamCacheRepository, L1StreamUrlRecord};
pub use l2_cache::{
    L2AccessUpdate, L2CacheStoreError, L2HeadCacheRepository, L2HeadCacheStore, L2HeadChunkRecord,
    SqliteL2HeadCacheStore,
};
pub use library::{
    AlbumCredit, AlbumGroupingBindingsSnapshot, AlbumUserBindingsSnapshot, Artist,
    ArtworkCacheEntry, ArtworkOverride, DEFAULT_METADATA_POLICY_PREF_KEY,
    ForceRebuildFinalizeReport, ForceRebuildPrepareReport, LibraryRepository, PairedClient,
    PlayHistoryEntry, ProfileFavorite, PruneLocalTracksReport, PruneOrphansReport,
    PurgeMissingReport, TrackFileCacheInfo, deterministic_artist_id, normalize_match_key,
};
pub use listen_later::ListenLaterRepository;
pub use pairing::PairingRepository;
pub use playlist_improver::PlaylistImproverRepository;
pub use preferences::PreferenceRepository;
pub use profile::ProfileRepository;
pub use smart_playlists::SmartPlaylistRepository;
pub use tx::ImmediateTx;
pub use zones::ZonesRepository;
