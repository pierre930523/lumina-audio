#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub sort_name: String,
    pub musicbrainz_id: Option<String>,
    pub biography: Option<String>,
    pub image_path: Option<String>,
    #[serde(default)]
    pub preference: i32,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AlbumCredit {
    pub id: Option<i64>,
    pub canonical_album_id: String,
    pub artist_id: String,
    pub role: String,
    pub artist_name: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ProfileFavorite {
    pub profile_id: String,
    pub item_type: String,
    pub item_id: String,
    pub created_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PlayHistoryEntry {
    pub id: i64,
    pub profile_id: String,
    pub track_source_id: String,
    pub played_at: String,
    pub duration_listened_ms: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct PairedClient {
    pub id: String,
    pub device_name: String,
    pub platform: String,
    pub token_hash: String,
    pub created_at: String,
    pub last_seen_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct TrackFileCacheInfo {
    pub track_id: String,
    pub version_id: String,
    pub external_track_id: String,
    pub file_mtime: Option<i64>,
    pub file_size: Option<i64>,
    pub metadata_hash: Option<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PruneLocalTracksReport {
    pub tracks_pruned: usize,
    pub versions_pruned: usize,
    pub albums_pruned: usize,
    #[serde(default)]
    pub artists_pruned: usize,
    pub invalidated_artwork_paths: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PruneOrphansReport {
    pub versions_pruned: usize,
    pub albums_pruned: usize,
    pub canonical_tracks_pruned: usize,
    #[serde(default)]
    pub artists_pruned: usize,
    pub invalidated_artwork_paths: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PurgeMissingReport {
    pub missing_tracks_purged: usize,
    pub play_history_tombstones_kept: usize,
    pub orphans: PruneOrphansReport,
    pub invalidated_artwork_paths: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AlbumUserBindingsSnapshot {
    pub album_tracks: std::collections::HashMap<String, Vec<String>>,
    #[serde(default)]
    pub album_user_layers: std::collections::HashMap<String, (Option<String>, String)>,
    #[serde(default)]
    pub album_preferences: std::collections::HashMap<String, i32>,
    #[serde(default)]
    pub grouping: super::rebuild_grouping::AlbumGroupingBindingsSnapshot,
}

impl AlbumUserBindingsSnapshot {
    pub fn is_empty(&self) -> bool {
        self.album_tracks.is_empty()
            && self.album_user_layers.is_empty()
            && self.album_preferences.is_empty()
            && self.grouping.is_empty()
    }
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ForceRebuildPrepareReport {
    pub tracks_cache_reset: usize,
    pub cloud_overrides_cleared: usize,
    pub artwork_cache_cleared: usize,
    pub skipped_files_cleared: usize,
    pub albums_enrichment_cleared: usize,
    pub invalidated_artwork_paths: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ForceRebuildFinalizeReport {
    pub favorites_remapped: usize,
    pub metadata_overrides_remapped: usize,
    pub artwork_overrides_remapped: usize,
    pub playlist_items_resolved: usize,
    pub missing_tracks_purged: usize,
    pub play_history_tombstones_kept: usize,
    pub orphans: PruneOrphansReport,
    pub search_index_entries: usize,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct ArtworkCacheEntry {
    pub cache_key: String,
    pub track_id: Option<String>,
    pub album_id: Option<String>,
    pub source_kind: String,
    pub mime_type: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub max_dim: i64,
    pub cache_path: String,
    pub source_mtime: Option<i64>,
    pub updated_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq, sqlx::FromRow)]
pub struct ArtworkOverride {
    pub target_kind: String,
    pub target_id: String,
    pub image_path: String,
    pub updated_at: String,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct ArtistRow {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) sort_name: String,
    pub(super) musicbrainz_id: Option<String>,
    pub(super) biography: Option<String>,
    pub(super) image_path: Option<String>,
    pub(super) preference: i32,
}

impl From<ArtistRow> for Artist {
    fn from(row: ArtistRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            sort_name: row.sort_name,
            musicbrainz_id: row.musicbrainz_id,
            biography: row.biography,
            image_path: row.image_path,
            preference: row.preference,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct CanonicalAlbumRow {
    pub(super) id: String,
    pub(super) title: String,
    pub(super) sort_title: String,
    pub(super) artist_name: Option<String>,
    pub(super) album_artist: Option<String>,
    pub(super) release_year: Option<i32>,
    pub(super) musicbrainz_release_group_id: Option<String>,
    pub(super) cover_url: Option<String>,
    pub(super) meta_policy: String,
    pub(super) has_user_edits: i32,
    pub(super) primary_version_id: Option<String>,
    pub(super) is_primary_locked: i32,
    pub(super) preference: i32,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct AlbumVersionRow {
    pub(super) id: String,
    pub(super) canonical_album_id: String,
    pub(super) provider_id: String,
    pub(super) external_album_id: String,
    pub(super) codec: String,
    pub(super) sample_rate_hz: i64,
    pub(super) bit_depth: i64,
    pub(super) channels: i64,
    pub(super) is_dsd: i32,
    pub(super) edition_label: Option<String>,
    pub(super) is_primary: i32,
    pub(super) is_hidden: i32,
    pub(super) quality_score: f64,
    pub(super) manual_group_id: Option<String>,
    pub(super) disc_count: i64,
    pub(super) track_count: i64,
    pub(super) has_manual_tracks: i32,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct TrackSourceRow {
    pub(super) id: String,
    pub(super) version_id: String,
    pub(super) provider_id: String,
    pub(super) external_track_id: String,
    pub(super) title: String,
    pub(super) disc_number: i64,
    pub(super) track_number: i64,
    pub(super) duration_ms: i64,
    pub(super) sample_rate_hz: i64,
    pub(super) bit_depth: i64,
    pub(super) codec: String,
    pub(super) isrc: Option<String>,
    pub(super) replay_gain_track_db: Option<f64>,
    pub(super) replay_gain_album_db: Option<f64>,
    pub(super) replay_gain_track_peak: Option<f64>,
    pub(super) replay_gain_album_peak: Option<f64>,
    pub(super) artist_name: Option<String>,
    pub(super) album_artist: Option<String>,
    pub(super) genre: Option<String>,
    pub(super) composer: Option<String>,
    pub(super) channels: i64,
    pub(super) is_dsd: i32,
    pub(super) has_lyrics: i32,
    pub(super) file_status: String,
    pub(super) manual_version_id: Option<String>,
    pub(super) manual_disc_number: Option<i64>,
    pub(super) preference: i32,
    pub(super) is_hidden: i32,
    pub(super) release_year: Option<i32>,
    pub(super) bitrate_kbps: Option<i64>,
    pub(super) file_size: Option<i64>,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct AlbumCreditRow {
    pub(super) id: i64,
    pub(super) canonical_album_id: String,
    pub(super) artist_id: String,
    pub(super) role: String,
    pub(super) artist_name: String,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct ArtistCreditDetailRow {
    pub(super) artist_id: String,
    pub(super) artist_name: String,
    pub(super) role: String,
    pub(super) album_id: String,
    pub(super) album_title: String,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct ProfileFavoriteRow {
    pub(super) profile_id: String,
    pub(super) item_type: String,
    pub(super) item_id: String,
    pub(super) created_at: String,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct PlayHistoryRow {
    pub(super) id: i64,
    pub(super) profile_id: String,
    pub(super) track_source_id: String,
    pub(super) played_at: String,
    pub(super) duration_listened_ms: i64,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct DedupAlbumCandidateRow {
    pub(super) id: String,
    pub(super) title: String,
    pub(super) artist_name: Option<String>,
    pub(super) normalized_title: Option<String>,
    pub(super) normalized_artist: Option<String>,
    pub(super) upc: Option<String>,
    pub(super) musicbrainz_release_group_id: Option<String>,
    pub(super) cover_url: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct MergeAlbumSourceRow {
    pub(super) primary_artist_id: Option<String>,
    pub(super) album_artist: Option<String>,
    pub(super) release_year: Option<i32>,
    pub(super) upc: Option<String>,
    pub(super) musicbrainz_release_group_id: Option<String>,
    pub(super) editorial_bio: Option<String>,
    pub(super) cover_url: Option<String>,
    pub(super) merged_cover_path: Option<String>,
    pub(super) normalized_title: Option<String>,
    pub(super) normalized_artist: Option<String>,
    pub(super) enriched_at: Option<String>,
    pub(super) file_meta_json: Option<String>,
    pub(super) cloud_meta_json: Option<String>,
    pub(super) user_edits_json: Option<String>,
    pub(super) meta_policy: String,
}
