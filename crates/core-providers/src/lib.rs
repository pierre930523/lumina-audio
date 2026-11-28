#![allow(clippy::collapsible_if, clippy::chunks_exact_to_as_chunks)]

pub mod deezer;
pub mod enrichment;
pub mod error;
pub mod http;
pub mod library;
pub mod local;
pub mod manager;
pub mod media_provider;
pub mod prefetcher;
pub mod process_guard;
pub mod providers;
pub mod qobuz;
pub mod registry;
pub mod remote;
pub mod resilience;
pub mod stream_cache;
pub mod tidal;
pub mod traits;

// Common error, HTTP transport, resilience, and trait contracts
pub use error::ProviderError;
pub use http::{
    HttpRequest, HttpResponse, HttpTransport, MockHttpTransport, ReqwestHttpTransport, endpoint_url,
};
pub use media_provider::{MediaPlaylist, MediaProvider, ProviderHealth};
pub use prefetcher::{
    DEFAULT_MAX_CONCURRENT_PREFETCHES, DEFAULT_TRIGGER_REMAINING_SECS, MAX_TRIGGER_REMAINING_SECS,
    MIN_TRIGGER_REMAINING_SECS, PlaybackProgressEvent, PrefetchConfig, PrefetchTarget,
    ProviderLookup, QueueUpdateEvent, StreamPrefetcher,
};
pub use process_guard::{
    BinaryKind, BinaryLocator, DEFAULT_GRACE_PERIOD, DEFAULT_MAX_STDOUT_BYTES,
    DEFAULT_STDERR_RING_BYTES, ProcessGuard, ProcessOutput, ProcessSpec, RingLogBuffer,
    is_process_alive,
};
pub use providers::{
    AppleMusicConfig, AppleMusicCredentialRefresher, AppleMusicCredentials, AppleMusicProvider,
    DEFAULT_APPLE_MUSIC_BASE_URL, DEFAULT_APPLE_MUSIC_STOREFRONT, DeezerMediaProvider,
    GuardedProcessRunner, QobuzMediaProvider, TidalMediaProvider, YtDlpCommandRunner,
    YtMusicAuthUpdate, YtMusicConfig, YtMusicCredentialRefresher, YtMusicProvider,
};
pub use resilience::{
    RetryPolicy, SingleFlightRefreshGate, execute_with_retry, parse_retry_after,
    send_http_with_retry,
};
pub use stream_cache::{
    CachedStreamEntry, ClockFn, CoreDbStreamCacheStore, StreamCacheConfig, StreamCacheStore,
    StreamUrlCache, extract_raw_expire_at, should_refresh_for_http_status, system_epoch_secs,
};
pub use traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, ScanErrorItem, StreamResolver,
    SyncProgress, SyncResult, SyncResultSummary,
};

// Local scanner & ingestion pipeline
pub use local::{
    AlbumKey, AlbumMapper, AlbumSyncMetadata, ArtworkManager, ArtworkTarget, COVER_ART_FILENAMES,
    DetailedScanOutput, DetectedEncoding, DirectoryScanner, DiscoveredEmbeddedAsset,
    DiscoveredFileAsset, ExtractOptions, ExtractedMetadata, IngestionConfig, IngestionPipeline,
    LocalProvider, LocalProviderConfig, LyricLine, LyricWord, LyricsFormat, LyricsKind,
    LyricsManager, LyricsResult, LyricsSource, LyricsTarget, MetadataExtractor,
    ParsedMetadataSummary, ParsedPlaylist, ParsedPlaylistEntry, RawTagField,
    SCANNABLE_AUDIO_EXTENSIONS, ScanSkippedCandidate, StorageWatcherManager, TagBlockInspection,
    TagInspectionReport, VersionSyncMetadata, classify_asset_role, classify_unsupported_container,
    compute_album_key, compute_content_fingerprint, delete_single_track, detect_garbled_tags,
    effective_album_dir, execute_library_cleanup, extract_disc_number_from_dir_name,
    extract_edition_label, extract_embedded_asset_descriptors, find_folder_cover,
    find_folder_cover_in_files, format_tag_inspection_report, index_assets_for_album_version,
    inspect_audio_tags, is_playlist_sidecar, is_root_accessible, is_scannable_audio,
    move_file_to_os_trash, normalize_album_base_title, normalize_path, parse_m3u_content,
    parse_m3u_file, preview_library_cleanup, read_album_asset_bytes, reidentify_single_track,
    rescan_single_track, resolve_safe_asset_file_path, scan_album_dir_assets, should_ignore_name,
    should_ignore_path, split_artists, strip_disc_suffix_from_album,
};

// Cross-source library sync & deduplication (F37)
pub use library::{LibrarySyncService, SyncPersistReport};

// MusicBrainz & Discogs credit enrichment (F38)
pub use enrichment::{
    CreditEnrichmentService, DEFAULT_DISCOGS_BASE_URL, DEFAULT_DISCOGS_USER_AGENT,
    DEFAULT_MUSICBRAINZ_BASE_URL, DEFAULT_MUSICBRAINZ_USER_AGENT, DiscogsArtist, DiscogsClient,
    DiscogsConfig, DiscogsCreditCandidate, DiscogsExtraArtist, DiscogsExtractedAlbum,
    DiscogsMaster, DiscogsRelease, DiscogsSearchResult, EnrichedAlbumResult, EnrichmentConfig,
    EnrichmentReport, MbArtistDetail, MbCreditCandidate, MbIsrcLookup, MbRelease, MbReleaseDetail,
    MbReleaseGroup, MbReleaseGroupDetail, MusicBrainzClient, MusicBrainzConfig, RateLimiter,
    clean_discogs_artist_name, extract_discogs_credits, extract_mb_credits,
};

// Remote SMB & WebDAV
pub use remote::{
    FilesystemSmbTransport, MockSmbTransport, RemoteShareUri, SMB_CREDENTIAL_SERVICE, SmbConfig,
    SmbEntry, SmbProvider, SmbTransport, UncSmbTransport, WEBDAV_CREDENTIAL_SERVICE, WebDavConfig,
    WebDavProvider, make_basic_auth, parse_remote_share_uri, percent_decode,
};

// Qobuz streaming provider
pub use qobuz::{
    QOBUZ_CREDENTIAL_SERVICE, QOBUZ_FALLBACK_TOKEN_KEY, QOBUZ_KEYRING_TOKEN_KEY, QobuzConfig,
    QobuzProvider, QobuzUserSession, format_ids as qobuz_format_ids, md5_hex,
    normalize_sample_rate as normalize_qobuz_sample_rate, resolve_qobuz_format_id,
};

// Tidal streaming provider
pub use tidal::{
    TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH, TidalConfig, TidalPkceSession, TidalProvider,
    TidalTokenResponse, generate_pkce_challenge, is_token_expired, validate_pkce_verifier,
};

// Deezer streaming provider
pub use deezer::{
    DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL, DeezerConfig, DeezerProvider, DeezerUser,
    validate_arl_cookie,
};

// Provider registry and coordinator manager
pub use manager::{AggregatedSearchResult, ProviderManager};
pub use registry::{ProviderRegistry, ProviderSummary};
