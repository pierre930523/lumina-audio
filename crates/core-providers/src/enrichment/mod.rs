pub mod discogs;
pub mod musicbrainz;
pub mod rate_limiter;
pub mod service;

pub use discogs::{
    DEFAULT_DISCOGS_BASE_URL, DEFAULT_DISCOGS_USER_AGENT, DiscogsArtist, DiscogsClient,
    DiscogsConfig, DiscogsCreditCandidate, DiscogsExtraArtist, DiscogsExtractedAlbum,
    DiscogsMaster, DiscogsRelease, DiscogsSearchResult, clean_discogs_artist_name,
    extract_discogs_credits,
};
pub use musicbrainz::{
    DEFAULT_MUSICBRAINZ_BASE_URL, DEFAULT_MUSICBRAINZ_USER_AGENT, MbArtistDetail,
    MbCreditCandidate, MbIsrcLookup, MbRelease, MbReleaseDetail, MbReleaseGroup,
    MbReleaseGroupDetail, MusicBrainzClient, MusicBrainzConfig, extract_mb_credits,
};
pub use rate_limiter::RateLimiter;
pub use service::{
    CreditEnrichmentService, EnrichedAlbumResult, EnrichmentConfig, EnrichmentReport,
};
