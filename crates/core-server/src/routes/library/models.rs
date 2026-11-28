use core_types::AlbumGroupSummaryRow;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub q: Option<String>,
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, Default)]
pub struct TracksQuery {
    pub limit: Option<usize>,
    #[serde(default)]
    pub include_hidden: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct AlbumsQuery {
    pub limit: Option<usize>,
    pub offset: Option<usize>,
    #[serde(default)]
    pub include_hidden: bool,
}

#[derive(Debug, Deserialize)]
pub struct ScanLibraryRequest {
    pub path: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct EnrichLibraryRequest {
    pub musicbrainz_base_url: Option<String>,
    pub discogs_base_url: Option<String>,
    pub discogs_token: Option<String>,
    pub force_refresh: Option<bool>,
    pub max_albums_per_run: Option<usize>,
    pub rebuild_search_index: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DeduplicateResponse {
    pub merged_albums: usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ScanLibraryResponse {
    pub scanned_files: usize,
    pub albums_count: usize,
    pub tracks_count: usize,
    pub errors_count: usize,
}

fn default_one_u32() -> u32 {
    1
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AlbumSummaryDto {
    pub id: String,
    #[serde(default)]
    pub group_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_version_id: Option<String>,
    pub title: String,
    pub artist: String,
    #[serde(alias = "release_year")]
    pub year: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub track_count: u32,
    #[serde(default = "default_one_u32")]
    pub disc_count: u32,
    #[serde(default = "default_one_u32")]
    pub version_count: u32,
    #[serde(default)]
    pub hidden_version_count: u32,
    #[serde(default = "default_one_u32")]
    pub total_version_count: u32,
    #[serde(default)]
    pub is_primary: bool,
    #[serde(default)]
    pub is_primary_locked: bool,
    #[serde(default)]
    pub is_hidden: bool,
    #[serde(default)]
    pub is_manual_group: bool,
    #[serde(default)]
    pub quality_score: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample_rate_hz: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u8>,
    #[serde(default)]
    pub is_dsd: bool,
    #[serde(default)]
    pub preference: i32,
}

impl From<AlbumGroupSummaryRow> for AlbumSummaryDto {
    fn from(row: AlbumGroupSummaryRow) -> Self {
        let cover_url = row
            .cover_url
            .filter(|s| !s.trim().is_empty())
            .or_else(|| Some(format!("/api/v1/library/artwork/{}", row.group_id)));
        let total_version_count = row.version_count.max(1);
        Self {
            id: row.id,
            group_id: row.group_id,
            version_id: row.version_id,
            primary_version_id: row.primary_version_id,
            title: row.title,
            artist: row.artist,
            year: row.release_year.and_then(|y| u32::try_from(y).ok()),
            album_artist: row.album_artist,
            cover_url,
            track_count: row.track_count,
            disc_count: row.disc_count.max(1),
            version_count: row.version_count,
            hidden_version_count: row.hidden_version_count,
            total_version_count,
            is_primary: row.is_primary,
            is_primary_locked: row.is_primary_locked,
            is_hidden: row.is_hidden,
            is_manual_group: row.is_manual_group,
            quality_score: row.quality_score,
            edition_label: row.edition_label,
            provider: row.provider,
            codec: row.codec,
            sample_rate_hz: row.sample_rate_hz,
            bit_depth: row.bit_depth,
            is_dsd: row.is_dsd,
            preference: row.preference,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TrackItemDto {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u64,
    pub sample_rate_hz: u32,
    pub bit_depth: u8,
    pub channels: u8,
    pub codec: String,
    pub is_dsd: bool,
    pub file_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disc_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork_cache_key: Option<String>,
    #[serde(default)]
    pub has_lyrics: bool,
    #[serde(default)]
    pub preference: i32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_group_id: Option<String>,
    #[serde(default)]
    pub is_hidden: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_size_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SearchResultDto {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub item_type: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct ArtworkQuery {
    pub max_dim: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct ArtworkOverrideRequest {
    pub image_path: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct RescanRequest {
    #[serde(alias = "directory")]
    pub dir_path: Option<String>,
    pub force: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RetrySkippedFileResponse {
    pub status: String,
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ScanStartRequest {
    pub dir_path: String,
    #[serde(default)]
    pub force: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct AddWatchedRootRequest {
    pub root_path: String,
    #[serde(default)]
    pub watch_mode: Option<String>,
    #[serde(default)]
    pub poll_interval_sec: Option<u32>,
    #[serde(default)]
    pub provider_id: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct RemoveWatchedRootQuery {
    pub root_path: Option<String>,
    pub id: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct SkippedFilesQuery {
    pub include_dismissed: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct PutMetadataOverrideRequest {
    pub field_name: String,
    pub value_json: String,
}
