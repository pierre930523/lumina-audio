mod album_mapper;
mod key;

use std::collections::HashMap;

use core_types::{CanonicalAlbum, TocSignature, TrackSource};
use serde::{Deserialize, Serialize};

pub use album_mapper::AlbumMapper;
pub use key::{
    compute_album_key, effective_album_dir, extract_edition_label, normalize_album_base_title,
    strip_disc_suffix_from_album,
};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VersionSyncMetadata {
    pub toc_signature: Option<TocSignature>,
    pub disc_count: u32,
    pub track_count: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AlbumSyncMetadata {
    pub upc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toc_signature: Option<TocSignature>,
    #[serde(default)]
    pub disc_count: u32,
    #[serde(default)]
    pub track_count: u32,
    #[serde(default)]
    pub version_metadata: HashMap<String, VersionSyncMetadata>,
}

/// Deterministic grouping key computed for a track before album canonicalization.
/// Shared between [`AlbumMapper`] and the `tag_debug` inspector so diagnostics always match
/// production grouping behavior.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumKey {
    pub group_artist_key: String,
    pub group_album_key: String,
    pub canonical_title: String,
    pub edition_label: Option<String>,
    pub inferred_disc_from_title: Option<u16>,
    pub inferred_disc_from_dir: Option<u16>,
    pub is_unknown_fallback: bool,
    pub effective_dir_key: String,
    pub external_album_id: String,
}

pub type MappedScanWithMetadata = (
    Vec<CanonicalAlbum>,
    Vec<TrackSource>,
    HashMap<String, AlbumSyncMetadata>,
);
