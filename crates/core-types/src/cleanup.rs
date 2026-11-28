use serde::{Deserialize, Serialize};

fn default_true() -> bool {
    true
}

// ============================================================================
// Library Cleanup & Batch Skipped-File Rescan DTOs
// ============================================================================

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryCleanupPreview {
    #[serde(default)]
    pub missing_tracks_count: usize,
    #[serde(default)]
    pub empty_album_versions_count: usize,
    #[serde(default)]
    pub empty_albums_count: usize,
    #[serde(default)]
    pub orphan_artists_count: usize,
    #[serde(default)]
    pub orphan_artwork_files_count: usize,
    #[serde(default)]
    pub orphan_artwork_bytes: u64,
    #[serde(default)]
    pub offline_roots: Vec<String>,
    #[serde(default)]
    pub online_roots_checked: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryCleanupOptions {
    #[serde(default = "default_true")]
    pub remove_missing_tracks: bool,
    #[serde(default = "default_true")]
    pub remove_empty_albums: bool,
    #[serde(default = "default_true")]
    pub remove_orphan_artists: bool,
    #[serde(default = "default_true")]
    pub remove_orphan_artwork_cache: bool,
}

impl Default for LibraryCleanupOptions {
    fn default() -> Self {
        Self {
            remove_missing_tracks: true,
            remove_empty_albums: true,
            remove_orphan_artists: true,
            remove_orphan_artwork_cache: true,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryCleanupResult {
    #[serde(default)]
    pub removed_tracks: usize,
    #[serde(default)]
    pub removed_album_versions: usize,
    #[serde(default)]
    pub removed_albums: usize,
    #[serde(default)]
    pub removed_artists: usize,
    #[serde(default)]
    pub removed_artwork_files: usize,
    #[serde(default)]
    pub freed_artwork_bytes: u64,
    #[serde(default)]
    pub skipped_offline_roots: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BatchRescanSkippedResult {
    #[serde(default)]
    pub total: usize,
    #[serde(default)]
    pub resolved: usize,
    #[serde(default)]
    pub removed_missing: usize,
    #[serde(default)]
    pub still_skipped: usize,
}
