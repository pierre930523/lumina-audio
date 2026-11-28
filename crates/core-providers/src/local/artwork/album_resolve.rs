use std::collections::HashSet;
use std::path::{Path, PathBuf};

use core_db::{CatalogQueryRepository, SqlitePool};
use core_types::{ArtworkResult, ArtworkSourceKind, PictureType};

use super::extract::{
    artwork_decode_semaphore, compute_cache_key, file_mtime_and_size, find_external_cover,
    lookup_cached_artwork, process_image_bytes, process_image_file,
};
use crate::local::metadata::MetadataExtractor;
use crate::local::scanner::normalize_path;

const MAX_SIBLING_TRACK_ARTWORK_PROBES: usize = 8;

/// Album-level artwork resolution with bounded concurrency and streaming memory footprint:
/// 1. Fast-path DB `artwork_cache` hit across album tracks
/// 2. First track embedded `FrontCover`
/// 3. External folder covers (`cover.* -> folder.* -> front.*`) BEFORE scanning sibling tracks
/// 4. First track untyped picture (`PictureType::Other`, e.g., MP4 `covr` atom)
/// 5. Bounded streaming probe of up to `MAX_SIBLING_TRACK_ARTWORK_PROBES` sibling tracks (zero RAM cache)
/// 6. Fallback to local `canonical_albums.cover_url` (supports Windows AND Unix/macOS leading `/` paths)
pub(super) async fn resolve_from_album(
    pool: &SqlitePool,
    album_id: &str,
    skip_path: Option<&str>,
    max_dim: u32,
    cache_dir: &Path,
    track_id: Option<&str>,
) -> Option<ArtworkResult> {
    let rows = CatalogQueryRepository::list_external_track_ids_for_album(pool, album_id)
        .await
        .unwrap_or_default();

    let skip_norm = skip_path.map(normalize_path);
    let track_stats: Vec<(PathBuf, String)> = tokio::task::spawn_blocking(move || {
        let mut out = Vec::new();
        for p in rows {
            let pb = PathBuf::from(&p);
            if pb.exists() {
                if let Some(ref sn) = skip_norm {
                    if normalize_path(&pb) == *sn {
                        continue;
                    }
                }
                let (mtime, size) = file_mtime_and_size(&pb);
                let key =
                    compute_cache_key(&format!("{}:{size}", normalize_path(&pb)), mtime, max_dim);
                out.push((pb, key));
            }
        }
        out
    })
    .await
    .unwrap_or_default();

    // Fast path: check artwork_cache for any track in the album
    for (_, key) in &track_stats {
        if let Some(cached) = lookup_cached_artwork(pool, key).await {
            return Some(cached);
        }
    }

    // Pass 1: Probe ONLY the first track's embedded Front Cover (avoids buffering all tracks in RAM)
    let mut first_untyped_pic: Option<(Vec<u8>, String)> = None;
    if let Some((first_pb, first_key)) = track_stats.first() {
        let pb_clone = first_pb.clone();
        let meta = {
            let _permit = artwork_decode_semaphore().acquire().await.ok()?;
            tokio::task::spawn_blocking(move || MetadataExtractor::extract(&pb_clone).ok())
                .await
                .unwrap_or(None)
        };
        if let Some(m) = meta {
            for pic in m.pictures {
                if pic.picture_type.is_front_cover()
                    || matches!(pic.picture_type, PictureType::FrontCover)
                {
                    if let Some(res) = process_image_bytes(
                        &pic.data,
                        ArtworkSourceKind::Embedded,
                        max_dim,
                        cache_dir,
                        pool,
                        first_key,
                        track_id,
                        Some(album_id),
                    )
                    .await
                    {
                        return Some(res);
                    }
                } else if first_untyped_pic.is_none()
                    && matches!(pic.picture_type, PictureType::Other)
                {
                    first_untyped_pic = Some((pic.data, first_key.clone()));
                }
            }
        }
    }

    // Pass 2: External folder covers (cover.* -> folder.* -> front.*) BEFORE scanning sibling tracks
    let mut checked_dirs = HashSet::new();
    for (pb, _) in &track_stats {
        if let Some(parent) = pb.parent() {
            let norm_dir = normalize_path(parent);
            if checked_dirs.insert(norm_dir) {
                let parent_buf = parent.to_path_buf();
                let ext_found =
                    tokio::task::spawn_blocking(move || find_external_cover(&parent_buf))
                        .await
                        .unwrap_or(None);
                if let Some((ext_path, kind)) = ext_found {
                    if let Some(res) = process_image_file(
                        &ext_path.to_string_lossy(),
                        kind,
                        max_dim,
                        cache_dir,
                        pool,
                        track_id,
                        Some(album_id),
                    )
                    .await
                    {
                        return Some(res);
                    }
                }
            }
        }
    }

    // Pass 3a: First track's untyped embedded picture (e.g., MP4/M4A covr atom)
    if let Some((data, key)) = first_untyped_pic {
        if let Some(res) = process_image_bytes(
            &data,
            ArtworkSourceKind::Embedded,
            max_dim,
            cache_dir,
            pool,
            &key,
            track_id,
            Some(album_id),
        )
        .await
        {
            return Some(res);
        }
    }

    // Pass 3b: Stream remaining sibling tracks one-by-one (bounded cap, zero accumulated RAM cache)
    for (pb, key) in track_stats
        .iter()
        .skip(1)
        .take(MAX_SIBLING_TRACK_ARTWORK_PROBES)
    {
        let pb_clone = pb.clone();
        let meta = {
            let _permit = artwork_decode_semaphore().acquire().await.ok()?;
            tokio::task::spawn_blocking(move || MetadataExtractor::extract(&pb_clone).ok())
                .await
                .unwrap_or(None)
        };
        if let Some(m) = meta {
            if let Some(pic) = m
                .pictures
                .iter()
                .find(|p| p.picture_type.is_front_cover())
                .or_else(|| {
                    m.pictures
                        .iter()
                        .find(|p| matches!(p.picture_type, PictureType::Other))
                })
            {
                if let Some(res) = process_image_bytes(
                    &pic.data,
                    ArtworkSourceKind::Embedded,
                    max_dim,
                    cache_dir,
                    pool,
                    key,
                    track_id,
                    Some(album_id),
                )
                .await
                {
                    return Some(res);
                }
            }
        }
    }

    // Pass 4: Fallback to canonical_albums.cover_url if it points to a real local image file
    // (supports Windows drive paths AND Unix/macOS leading '/' absolute paths; excludes HTTP & API URLs)
    let db_cover = CatalogQueryRepository::get_album_cover_path(pool, album_id)
        .await
        .ok()
        .flatten();
    if let Some(cover_str) = db_cover {
        let trimmed = cover_str.trim();
        let is_remote_or_api = trimmed.starts_with("http://")
            || trimmed.starts_with("https://")
            || trimmed.starts_with("/api/");
        if !trimmed.is_empty() && !is_remote_or_api {
            let cp = PathBuf::from(trimmed);
            let is_file = tokio::task::spawn_blocking(move || cp.is_file())
                .await
                .unwrap_or(false);
            if is_file {
                if let Some(res) = process_image_file(
                    trimmed,
                    ArtworkSourceKind::Cover,
                    max_dim,
                    cache_dir,
                    pool,
                    track_id,
                    Some(album_id),
                )
                .await
                {
                    return Some(res);
                }
            }
        }
    }

    None
}
