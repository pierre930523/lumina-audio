mod album_resolve;
mod assets;
mod assets_io;
mod extract;
mod manager;

pub use assets::{
    DiscoveredEmbeddedAsset, DiscoveredFileAsset, classify_asset_role,
    extract_embedded_asset_descriptors, index_assets_for_album_version, read_album_asset_bytes,
    resolve_safe_asset_file_path, scan_album_dir_assets,
};
pub(crate) use assets::{
    VersionAssetsBatch, index_assets_for_committed_versions, record_version_asset_source,
};
pub use manager::{ArtworkManager, ArtworkTarget};
