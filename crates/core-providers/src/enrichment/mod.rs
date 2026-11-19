pub mod discogs;
pub mod musicbrainz;
pub mod rate_limiter;
pub mod service;

pub use discogs::{
    clean_discogs_artist_name, extract_discogs_credits, DiscogsArtist, DiscogsClient,
    DiscogsConfig, DiscogsCreditCandidate, DiscogsExtraArtist, DiscogsExtractedAlbum,
    DiscogsMaster, DiscogsRelease, DiscogsSearchResult, DEFAULT_DISCOGS_BASE_URL,
    DEFAULT_DISCOGS_USER_AGENT,
};
pub use musicbrainz::{
    extract_mb_credits, MbArtistDetail, MbCreditCandidate, MbIsrcLookup, MbRelease,
    MbReleaseDetail, MbReleaseGroup, MbReleaseGroupDetail, MusicBrainzClient, MusicBrainzConfig,
    DEFAULT_MUSICBRAINZ_BASE_URL, DEFAULT_MUSICBRAINZ_USER_AGENT,
};
pub use rate_limiter::RateLimiter;
pub use service::{
    CreditEnrichmentService, EnrichedAlbumResult, EnrichmentConfig, EnrichmentReport,
};
