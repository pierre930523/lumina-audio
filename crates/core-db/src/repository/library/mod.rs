pub mod album_queries;
pub mod albums;
pub mod artists;
pub mod artwork;
pub mod cleanup;
pub mod credits;
pub mod dedup;
pub mod helpers;
pub mod metadata_layers;
pub mod metadata_recompute;
pub mod metadata_recompute_track;
pub mod models;
pub mod profiles;
pub mod prune;
mod prune_helpers;
pub mod rebuild;
pub mod rebuild_grouping;
mod rebuild_step4;
pub mod track_actions;
pub mod track_file_info;
pub mod track_queries;
pub mod tracks;
pub mod version_grouping;
pub mod version_ops;
mod version_ops_helpers;
pub mod version_scoring;

pub use helpers::{deterministic_artist_id, normalize_match_key};
pub(crate) use helpers::{
    normalize_local_path_for_compare, parse_audio_codec, parse_provider_kind, path_in_scope,
};
pub use metadata_layers::DEFAULT_METADATA_POLICY_PREF_KEY;
pub use models::{
    AlbumCredit, AlbumUserBindingsSnapshot, Artist, ArtworkCacheEntry, ArtworkOverride,
    ForceRebuildFinalizeReport, ForceRebuildPrepareReport, PairedClient, PlayHistoryEntry,
    ProfileFavorite, PruneLocalTracksReport, PruneOrphansReport, PurgeMissingReport,
    TrackFileCacheInfo,
};
pub use rebuild_grouping::AlbumGroupingBindingsSnapshot;

pub struct LibraryRepository;

impl LibraryRepository {
    pub fn deterministic_artist_id(name: &str) -> String {
        deterministic_artist_id(name)
    }
}
