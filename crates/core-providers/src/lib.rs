#![allow(clippy::collapsible_if, clippy::chunks_exact_to_as_chunks)]

pub mod deezer;
pub mod enrichment;
pub mod error;
pub mod http;
pub mod library;
pub mod local;
pub mod manager;
pub mod qobuz;
pub mod registry;
pub mod remote;
pub mod tidal;
pub mod traits;

// Common error, HTTP transport, and trait contracts
pub use error::ProviderError;
pub use http::{
    endpoint_url, HttpRequest, HttpResponse, HttpTransport, MockHttpTransport, ReqwestHttpTransport,
};
pub use traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, ScanErrorItem, StreamResolver,
    SyncProgress, SyncResult, SyncResultSummary,
};

// Local scanner & ingestion pipeline
pub use local::{
    classify_unsupported_container, compute_content_fingerprint, detect_garbled_tags,
    extract_disc_number_from_dir_name, extract_edition_label, find_folder_cover,
    find_folder_cover_in_files, is_playlist_sidecar, is_scannable_audio, normalize_album_base_title,
    normalize_path, parse_m3u_content, parse_m3u_file, should_ignore_name, should_ignore_path,
    split_artists, AlbumMapper, AlbumSyncMetadata, ArtworkManager, ArtworkTarget,
    DetailedScanOutput, DirectoryScanner, ExtractOptions, ExtractedMetadata, IngestionConfig,
    IngestionPipeline, LocalProvider, LocalProviderConfig, LyricLine, LyricWord, LyricsFormat,
    LyricsKind, LyricsManager, LyricsResult, LyricsSource, LyricsTarget, MetadataExtractor,
    ParsedPlaylist, ParsedPlaylistEntry, ScanSkippedCandidate, StorageWatcherManager,
    VersionSyncMetadata, COVER_ART_FILENAMES, SCANNABLE_AUDIO_EXTENSIONS,
};

// Cross-source library sync & deduplication (F37)
pub use library::{LibrarySyncService, SyncPersistReport};

// MusicBrainz & Discogs credit enrichment (F38)
pub use enrichment::{
    clean_discogs_artist_name, extract_discogs_credits, extract_mb_credits,
    CreditEnrichmentService, DiscogsArtist, DiscogsClient, DiscogsConfig, DiscogsCreditCandidate,
    DiscogsExtraArtist, DiscogsExtractedAlbum, DiscogsMaster, DiscogsRelease, DiscogsSearchResult,
    EnrichedAlbumResult, EnrichmentConfig, EnrichmentReport, MbArtistDetail, MbCreditCandidate,
    MbIsrcLookup, MbRelease, MbReleaseDetail, MbReleaseGroup, MbReleaseGroupDetail,
    MusicBrainzClient, MusicBrainzConfig, RateLimiter, DEFAULT_DISCOGS_BASE_URL,
    DEFAULT_DISCOGS_USER_AGENT, DEFAULT_MUSICBRAINZ_BASE_URL, DEFAULT_MUSICBRAINZ_USER_AGENT,
};

// Remote SMB & WebDAV
pub use remote::{
    make_basic_auth, parse_remote_share_uri, percent_decode, FilesystemSmbTransport,
    MockSmbTransport, RemoteShareUri, SmbConfig, SmbEntry, SmbProvider, SmbTransport,
    UncSmbTransport, WebDavConfig, WebDavProvider, SMB_CREDENTIAL_SERVICE,
    WEBDAV_CREDENTIAL_SERVICE,
};

// Qobuz streaming provider
pub use qobuz::{
    format_ids as qobuz_format_ids, md5_hex, normalize_sample_rate as normalize_qobuz_sample_rate,
    resolve_qobuz_format_id, QobuzConfig, QobuzProvider, QobuzUserSession,
    QOBUZ_CREDENTIAL_SERVICE, QOBUZ_FALLBACK_TOKEN_KEY, QOBUZ_KEYRING_TOKEN_KEY,
};

// Tidal streaming provider
pub use tidal::{
    generate_pkce_challenge, is_token_expired, validate_pkce_verifier, TidalConfig,
    TidalPkceSession, TidalProvider, TidalTokenResponse, TIDAL_CREDENTIAL_SERVICE,
    TIDAL_KEY_OAUTH,
};

// Deezer streaming provider
pub use deezer::{
    validate_arl_cookie, DeezerConfig, DeezerProvider, DeezerUser, DEEZER_CREDENTIAL_SERVICE,
    DEEZER_KEY_ARL,
};

// Provider registry and coordinator manager
pub use manager::{AggregatedSearchResult, ProviderManager};
pub use registry::{ProviderRegistry, ProviderSummary};
