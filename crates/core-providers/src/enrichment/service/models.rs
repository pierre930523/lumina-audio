use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnrichmentConfig {
    pub force_refresh: bool,
    pub fetch_artist_bios: bool,
    pub merge_on_mbid_match: bool,
    pub rebuild_search_index: bool,
    pub max_albums_per_run: usize,
}

impl Default for EnrichmentConfig {
    fn default() -> Self {
        Self {
            force_refresh: false,
            fetch_artist_bios: true,
            merge_on_mbid_match: false,
            rebuild_search_index: true,
            max_albums_per_run: 100,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnrichedAlbumResult {
    pub album_id: String,
    pub skipped: bool,
    pub merged_into_album_id: Option<String>,
    pub mb_release_group_id: Option<String>,
    pub credits_added: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnrichmentReport {
    pub albums_processed: usize,
    pub albums_enriched: usize,
    pub albums_skipped: usize,
    pub albums_merged: usize,
    pub credits_added: usize,
    pub errors: Vec<String>,
}

pub(super) struct CreditRowCandidate {
    pub(super) artist_name: String,
    pub(super) mbid: Option<String>,
    pub(super) bio: Option<String>,
    pub(super) image_url: Option<String>,
    pub(super) role: String,
}
