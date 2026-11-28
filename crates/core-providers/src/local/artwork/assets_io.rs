use std::fs;
use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};

use core_db::{AlbumAssetRepository, CatalogQueryRepository, SqlitePool};
use core_types::{AlbumAssetKind, AlbumAssetSourceKind};

use super::assets::ALLOWED_IMAGE_EXTENSIONS;
use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::metadata::{ExtractOptions, MetadataExtractor};

/// Validates and resolves a registered on-disk album asset to its canonical file path.
///
/// Rejects unregistered IDs, embedded-only records, path traversal (`..`), symlinks,
/// non-regular files, and disallowed file extensions.
pub async fn resolve_safe_asset_file_path(
    pool: &SqlitePool,
    asset_id: &str,
) -> Result<(String, String, PathBuf), ProviderError> {
    let record = AlbumAssetRepository::get_asset_by_id(pool, asset_id)
        .await
        .map_err(db_err)?
        .ok_or_else(|| {
            ProviderError::Io(std::io::Error::new(
                ErrorKind::NotFound,
                format!("Album asset '{asset_id}' not found"),
            ))
        })?;

    if record.source_kind != AlbumAssetSourceKind::File {
        return Err(ProviderError::InvalidConfig(format!(
            "Album asset '{asset_id}' is embedded and has no standalone file path"
        )));
    }

    let raw_path = record.file_path.clone().ok_or_else(|| {
        ProviderError::InvalidConfig(format!("Album asset '{asset_id}' is missing file_path"))
    })?;
    let expected_kind = record.asset_kind;

    let canonical =
        tokio::task::spawn_blocking(move || validate_safe_file_path(&raw_path, expected_kind))
            .await
            .map_err(|e| ProviderError::Other(format!("Asset path validation panicked: {e}")))??;

    Ok((record.mime_type, record.display_name, canonical))
}

/// Safely reads bytes for any registered album asset (on-disk file or on-demand embedded tag art).
///
/// Returns `(mime_type, display_name, bytes)`.
pub async fn read_album_asset_bytes(
    pool: &SqlitePool,
    asset_id: &str,
) -> Result<(String, String, Vec<u8>), ProviderError> {
    let record = AlbumAssetRepository::get_asset_by_id(pool, asset_id)
        .await
        .map_err(db_err)?
        .ok_or_else(|| {
            ProviderError::Io(std::io::Error::new(
                ErrorKind::NotFound,
                format!("Album asset '{asset_id}' not found"),
            ))
        })?;

    match record.source_kind {
        AlbumAssetSourceKind::File => {
            let raw_path = record.file_path.clone().ok_or_else(|| {
                ProviderError::InvalidConfig(format!(
                    "Album asset '{asset_id}' is missing file_path"
                ))
            })?;
            let expected_kind = record.asset_kind;
            let canonical = tokio::task::spawn_blocking(move || {
                validate_safe_file_path(&raw_path, expected_kind)
            })
            .await
            .map_err(|e| ProviderError::Other(format!("Asset path validation panicked: {e}")))??;

            let bytes = tokio::fs::read(&canonical).await?;
            Ok((record.mime_type, record.display_name, bytes))
        }
        AlbumAssetSourceKind::Embedded => {
            let track_id = record.embedded_track_id.as_deref().ok_or_else(|| {
                ProviderError::InvalidConfig(format!(
                    "Embedded album asset '{asset_id}' is missing embedded_track_id"
                ))
            })?;
            let pic_index = record
                .embedded_pic_index
                .and_then(|i| usize::try_from(i).ok())
                .ok_or_else(|| {
                    ProviderError::InvalidConfig(format!(
                        "Embedded album asset '{asset_id}' has invalid embedded_pic_index"
                    ))
                })?;

            let (track_path_str, _) =
                CatalogQueryRepository::get_track_path_and_album_by_id(pool, track_id)
                    .await
                    .map_err(db_err)?
                    .ok_or_else(|| {
                        ProviderError::TrackNotFound(format!(
                            "Source track '{track_id}' for embedded asset '{asset_id}' not found"
                        ))
                    })?;

            if has_parent_traversal(&track_path_str) {
                return Err(ProviderError::InvalidConfig(
                    "Embedded asset source track path contains forbidden traversal".into(),
                ));
            }
            let track_path = PathBuf::from(&track_path_str);

            let extracted = tokio::task::spawn_blocking(move || {
                let meta = MetadataExtractor::extract_with_options(
                    &track_path,
                    ExtractOptions {
                        include_pictures: true,
                    },
                )?;
                meta.pictures.into_iter().nth(pic_index).ok_or_else(|| {
                    ProviderError::Io(std::io::Error::new(
                        ErrorKind::NotFound,
                        format!("Embedded picture index {pic_index} not found"),
                    ))
                })
            })
            .await
            .map_err(|e| ProviderError::Other(format!("Embedded asset extract panicked: {e}")))??;

            let mime = if !extracted.mime_type.trim().is_empty() {
                extracted.mime_type
            } else {
                record.mime_type
            };
            Ok((mime, record.display_name, extracted.data))
        }
    }
}

fn has_parent_traversal(raw_path: &str) -> bool {
    raw_path.contains('\0')
        || raw_path.split(['/', '\\']).any(|seg| seg == "..")
        || Path::new(raw_path)
            .components()
            .any(|c| matches!(c, Component::ParentDir))
}

fn validate_safe_file_path(
    raw_path: &str,
    expected_kind: AlbumAssetKind,
) -> Result<PathBuf, ProviderError> {
    let trimmed = raw_path.trim();
    if trimmed.is_empty() || has_parent_traversal(trimmed) {
        return Err(ProviderError::InvalidConfig(
            "Album asset path rejected: empty or contains '..' traversal".into(),
        ));
    }

    let path = Path::new(trimmed);
    validate_allowed_extension(path, expected_kind)?;

    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Err(ProviderError::InvalidConfig(
            "Album asset path rejected: symlinks are not permitted".into(),
        ));
    }
    if !meta.file_type().is_file() {
        return Err(ProviderError::InvalidConfig(
            "Album asset path rejected: target is not a regular file".into(),
        ));
    }

    if let Some(parent) = path.parent() {
        if let Ok(parent_meta) = fs::symlink_metadata(parent) {
            if parent_meta.file_type().is_symlink() {
                return Err(ProviderError::InvalidConfig(
                    "Album asset path rejected: parent directory is a symlink".into(),
                ));
            }
        }
    }

    let canonical = fs::canonicalize(path)?;
    validate_allowed_extension(&canonical, expected_kind)?;
    if !canonical.is_file() {
        return Err(ProviderError::InvalidConfig(
            "Album asset canonical path is not a regular file".into(),
        ));
    }

    Ok(canonical)
}

fn validate_allowed_extension(
    path: &Path,
    expected_kind: AlbumAssetKind,
) -> Result<(), ProviderError> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    let allowed = match expected_kind {
        AlbumAssetKind::Pdf => ext == "pdf",
        AlbumAssetKind::Image => ALLOWED_IMAGE_EXTENSIONS.contains(&ext.as_str()),
    };
    if !allowed {
        return Err(ProviderError::InvalidConfig(format!(
            "Album asset extension '.{ext}' is not allowed for kind '{expected_kind}'"
        )));
    }
    Ok(())
}
