use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use core_db::repository::album_assets::NewAlbumAsset;
use core_db::{AlbumAssetRepository, SqlitePool};
use core_types::{
    AlbumAssetKind, AlbumAssetRole, AlbumAssetSourceKind, ExtractedPicture, PictureType,
};
use tracing::warn;

use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::ignore::should_ignore_name;
use crate::local::mapper::effective_album_dir;
use crate::local::metadata::{ExtractOptions, MetadataExtractor};
use crate::local::scanner::normalize_path;

pub use super::assets_io::{read_album_asset_bytes, resolve_safe_asset_file_path};

const ALLOWED_ASSET_SUBDIRS: &[&str] =
    &["scans", "artwork", "booklet", "booklets", "covers", "cover"];

pub(super) const ALLOWED_IMAGE_EXTENSIONS: &[&str] = &["jpg", "jpeg", "png", "webp", "bmp", "gif"];

/// Metadata descriptor for a discovered on-disk PDF booklet or image asset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredFileAsset {
    pub path: PathBuf,
    pub normalized_path: String,
    pub asset_kind: AlbumAssetKind,
    pub role: AlbumAssetRole,
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub file_size: Option<u64>,
    pub display_name: String,
}

/// Metadata descriptor for an embedded picture inside an audio track's tag block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredEmbeddedAsset {
    pub embedded_track_id: String,
    pub track_path: PathBuf,
    pub embedded_pic_index: i64,
    pub role: AlbumAssetRole,
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub file_size: u64,
    pub display_name: String,
}

/// Classifies an album asset filename into a canonical [`AlbumAssetRole`].
pub fn classify_asset_role(file_name: &str, is_pdf: bool) -> AlbumAssetRole {
    if is_pdf {
        return AlbumAssetRole::Booklet;
    }

    let stem = Path::new(file_name)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(file_name)
        .to_ascii_lowercase();

    let tokens: Vec<&str> = stem
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|t| !t.is_empty())
        .collect();

    if stem.contains("front") {
        AlbumAssetRole::Front
    } else if stem.contains("back") || stem.contains("rear") || stem.contains("tray") {
        AlbumAssetRole::Back
    } else if has_cd_token(&tokens)
        || stem.contains("disc")
        || stem.contains("disk")
        || stem.contains("vinyl")
        || stem.contains("media")
        || stem.contains("label")
    {
        AlbumAssetRole::Media
    } else if stem.contains("booklet")
        || stem.contains("liner")
        || stem.contains("inlay")
        || stem.contains("insert")
        || stem.contains("page")
        || stem.contains("scan")
    {
        AlbumAssetRole::Booklet
    } else if stem.contains("cover") || stem.contains("folder") {
        AlbumAssetRole::Front
    } else {
        AlbumAssetRole::Other
    }
}

fn has_cd_token(tokens: &[&str]) -> bool {
    tokens.iter().any(|t| {
        *t == "cd"
            || t.strip_prefix("cd")
                .is_some_and(|rest| !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()))
    })
}

fn role_priority(role: AlbumAssetRole) -> u8 {
    match role {
        AlbumAssetRole::Front => 0,
        AlbumAssetRole::Back => 1,
        AlbumAssetRole::Media => 2,
        AlbumAssetRole::Booklet => 3,
        AlbumAssetRole::Other => 4,
    }
}

fn role_display_label(role: AlbumAssetRole) -> &'static str {
    match role {
        AlbumAssetRole::Front => "Front Cover",
        AlbumAssetRole::Back => "Back Cover",
        AlbumAssetRole::Media => "Media",
        AlbumAssetRole::Booklet => "Booklet",
        AlbumAssetRole::Other => "Artwork",
    }
}

fn classify_extension(path: &Path) -> Option<(AlbumAssetKind, &'static str)> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        "pdf" => Some((AlbumAssetKind::Pdf, "application/pdf")),
        "jpg" | "jpeg" => Some((AlbumAssetKind::Image, "image/jpeg")),
        "png" => Some((AlbumAssetKind::Image, "image/png")),
        "webp" => Some((AlbumAssetKind::Image, "image/webp")),
        "bmp" => Some((AlbumAssetKind::Image, "image/bmp")),
        "gif" => Some((AlbumAssetKind::Image, "image/gif")),
        _ => None,
    }
}

/// Scans `album_dir` and immediate allowed subdirectories (`scans`, `artwork`, `booklet`,
/// `booklets`, `covers`, `cover`) at depth 1 for PDF booklets and image files.
///
/// Uses header-only `image::image_dimensions` (no full pixel decode) and skips hidden/system
/// entries and symlinks.
pub fn scan_album_dir_assets(album_dir: &Path) -> Vec<DiscoveredFileAsset> {
    let Ok(entries) = fs::read_dir(album_dir) else {
        return Vec::new();
    };

    let mut discovered = Vec::new();
    let mut subdirs = Vec::new();

    for entry in entries.flatten() {
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        if ft.is_symlink() {
            continue;
        }
        let name_os = entry.file_name();
        let Some(name) = name_os.to_str() else {
            continue;
        };
        if should_ignore_name(name) {
            continue;
        }
        if ft.is_file() {
            if let Some(asset) = inspect_file_asset(&entry.path(), name) {
                discovered.push(asset);
            }
        } else if ft.is_dir() && ALLOWED_ASSET_SUBDIRS.contains(&name.to_ascii_lowercase().as_str())
        {
            subdirs.push(entry.path());
        }
    }

    subdirs.sort();
    for subdir in subdirs {
        let Ok(sub_entries) = fs::read_dir(&subdir) else {
            continue;
        };
        for entry in sub_entries.flatten() {
            let Ok(ft) = entry.file_type() else {
                continue;
            };
            if ft.is_symlink() || !ft.is_file() {
                continue;
            }
            let name_os = entry.file_name();
            let Some(name) = name_os.to_str() else {
                continue;
            };
            if !should_ignore_name(name) {
                if let Some(asset) = inspect_file_asset(&entry.path(), name) {
                    discovered.push(asset);
                }
            }
        }
    }

    discovered.sort_by(|a, b| {
        role_priority(a.role)
            .cmp(&role_priority(b.role))
            .then_with(|| {
                a.display_name
                    .to_ascii_lowercase()
                    .cmp(&b.display_name.to_ascii_lowercase())
            })
            .then_with(|| a.normalized_path.cmp(&b.normalized_path))
    });
    discovered
}

fn inspect_file_asset(path: &Path, file_name: &str) -> Option<DiscoveredFileAsset> {
    let (asset_kind, mime_type) = classify_extension(path)?;
    let is_pdf = asset_kind == AlbumAssetKind::Pdf;
    let file_size = fs::metadata(path).ok().map(|m| m.len());
    let (width, height) = if is_pdf {
        (None, None)
    } else {
        image::image_dimensions(path)
            .map(|(w, h)| (Some(w), Some(h)))
            .unwrap_or((None, None))
    };

    Some(DiscoveredFileAsset {
        path: path.to_path_buf(),
        normalized_path: normalize_path(path),
        asset_kind,
        role: classify_asset_role(file_name, is_pdf),
        mime_type: mime_type.to_string(),
        width,
        height,
        file_size,
        display_name: file_name.to_string(),
    })
}

/// Converts embedded pictures from a track's probed metadata into lightweight asset descriptors
/// using header-only image dimension inspection (zero full pixel decode).
pub fn extract_embedded_asset_descriptors(
    track_id: &str,
    track_path: &Path,
    pictures: &[ExtractedPicture],
) -> Vec<DiscoveredEmbeddedAsset> {
    let mut out = Vec::new();
    for (idx, pic) in pictures.iter().enumerate() {
        if pic.data.is_empty() {
            continue;
        }
        let role = match pic.picture_type {
            PictureType::FrontCover => AlbumAssetRole::Front,
            PictureType::BackCover => AlbumAssetRole::Back,
            PictureType::Media => AlbumAssetRole::Media,
            PictureType::LeafletPage => AlbumAssetRole::Booklet,
            _ => AlbumAssetRole::Other,
        };

        let guessed = image::ImageReader::new(Cursor::new(&pic.data))
            .with_guessed_format()
            .ok();
        let guessed_mime = guessed
            .as_ref()
            .and_then(|r| r.format())
            .map(|fmt| fmt.to_mime_type().to_string());
        let (width, height) = guessed
            .and_then(|r| r.into_dimensions().ok())
            .map(|(w, h)| (Some(w), Some(h)))
            .unwrap_or((None, None));

        let trimmed_mime = pic.mime_type.trim();
        let mime_type = if !trimmed_mime.is_empty() && trimmed_mime.contains('/') {
            trimmed_mime.to_string()
        } else {
            guessed_mime.unwrap_or_else(|| "image/jpeg".to_string())
        };

        out.push(DiscoveredEmbeddedAsset {
            embedded_track_id: track_id.to_string(),
            track_path: track_path.to_path_buf(),
            embedded_pic_index: idx as i64,
            role,
            mime_type,
            width,
            height,
            file_size: pic.data.len() as u64,
            display_name: format!("Embedded {} #{}", role_display_label(role), idx + 1),
        });
    }
    out
}

/// Scans album directories and indexes representative embedded pictures for an `album_version_id`,
/// persisting metadata-only rows into `album_assets` via [`AlbumAssetRepository`].
pub async fn index_assets_for_album_version(
    pool: &SqlitePool,
    album_version_id: &str,
    album_dirs: &[PathBuf],
    embedded_tracks: &[(String, PathBuf)],
) -> Result<usize, ProviderError> {
    let mut unique_dirs = Vec::new();
    let mut seen_dirs = HashSet::new();
    for dir in album_dirs {
        let key = normalize_path(dir);
        if !key.is_empty() && seen_dirs.insert(key) {
            unique_dirs.push(dir.clone());
        }
    }
    let tracks_owned = embedded_tracks.to_vec();

    let new_assets = tokio::task::spawn_blocking(move || {
        let mut seen_files = HashSet::new();
        let mut file_assets = Vec::new();
        for dir in &unique_dirs {
            for asset in scan_album_dir_assets(dir) {
                if seen_files.insert(asset.normalized_path.clone()) {
                    file_assets.push(asset);
                }
            }
        }

        // Index all pictures from the first representative track with embedded art to avoid
        // repeating the exact same front cover for every track in a multi-track album.
        let mut embedded_assets = Vec::new();
        for (track_id, track_path) in &tracks_owned {
            if let Ok(meta) = MetadataExtractor::extract_with_options(
                track_path,
                ExtractOptions {
                    include_pictures: true,
                },
            ) {
                if !meta.pictures.is_empty() {
                    embedded_assets =
                        extract_embedded_asset_descriptors(track_id, track_path, &meta.pictures);
                    if !embedded_assets.is_empty() {
                        break;
                    }
                }
            }
        }

        let mut combined = Vec::with_capacity(file_assets.len() + embedded_assets.len());
        for a in file_assets {
            combined.push(NewAlbumAsset {
                asset_kind: a.asset_kind,
                source_kind: AlbumAssetSourceKind::File,
                role: a.role,
                file_path: Some(a.normalized_path),
                embedded_track_id: None,
                embedded_pic_index: None,
                mime_type: a.mime_type,
                width: a.width,
                height: a.height,
                file_size: a.file_size,
                display_name: a.display_name,
                sort_order: 0,
            });
        }
        for e in embedded_assets {
            combined.push(NewAlbumAsset {
                asset_kind: AlbumAssetKind::Image,
                source_kind: AlbumAssetSourceKind::Embedded,
                role: e.role,
                file_path: None,
                embedded_track_id: Some(e.embedded_track_id),
                embedded_pic_index: Some(e.embedded_pic_index),
                mime_type: e.mime_type,
                width: e.width,
                height: e.height,
                file_size: Some(e.file_size),
                display_name: e.display_name,
                sort_order: 0,
            });
        }

        combined.sort_by(|a, b| {
            role_priority(a.role)
                .cmp(&role_priority(b.role))
                .then_with(|| {
                    u8::from(a.source_kind == AlbumAssetSourceKind::Embedded)
                        .cmp(&u8::from(b.source_kind == AlbumAssetSourceKind::Embedded))
                })
                .then_with(|| {
                    a.display_name
                        .to_ascii_lowercase()
                        .cmp(&b.display_name.to_ascii_lowercase())
                })
        });
        for (idx, item) in combined.iter_mut().enumerate() {
            item.sort_order = idx as i64;
        }
        combined
    })
    .await
    .map_err(|e| ProviderError::ScanError(format!("Album asset indexer panicked: {e}")))?;

    AlbumAssetRepository::replace_album_version_assets(pool, album_version_id, &new_assets)
        .await
        .map_err(db_err)
}

pub(crate) type VersionAssetsBatch = HashMap<String, (HashSet<PathBuf>, Vec<(String, PathBuf)>)>;

pub(crate) fn record_version_asset_source(
    batch: &mut VersionAssetsBatch,
    version_id: &str,
    track_id: &str,
    track_path: &Path,
) {
    let entry = batch.entry(version_id.to_string()).or_default();
    if let Some(parent) = track_path.parent() {
        entry.0.insert(parent.to_path_buf());
    }
    if let Some(eff_dir) = effective_album_dir(track_path) {
        entry.0.insert(eff_dir.to_path_buf());
    }
    entry
        .1
        .push((track_id.to_string(), track_path.to_path_buf()));
}

pub(crate) async fn index_assets_for_committed_versions(
    pool: &SqlitePool,
    batch: VersionAssetsBatch,
) {
    for (version_id, (dirs_set, tracks)) in batch {
        let dirs: Vec<PathBuf> = dirs_set.into_iter().collect();
        if let Err(err) = index_assets_for_album_version(pool, &version_id, &dirs, &tracks).await {
            warn!("Non-fatal album asset indexing error for version '{version_id}': {err}");
        }
    }
}
