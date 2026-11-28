use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use core_db::{ArtworkCacheEntry, LibraryRepository, SqlitePool};
use core_types::{ArtworkResult, ArtworkSourceKind, PictureType};
use image::GenericImageView;
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;

use crate::local::metadata::MetadataExtractor;
use crate::local::scanner::normalize_path;

const MAX_CONCURRENT_ARTWORK_DECODES: usize = 4;

pub(super) fn artwork_decode_semaphore() -> &'static Arc<Semaphore> {
    static SEM: OnceLock<Arc<Semaphore>> = OnceLock::new();
    SEM.get_or_init(|| Arc::new(Semaphore::new(MAX_CONCURRENT_ARTWORK_DECODES)))
}

pub(super) fn file_mtime_and_size(path: &Path) -> (u64, u64) {
    match fs::metadata(path) {
        Ok(m) => {
            let mtime = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            (mtime, m.len())
        }
        Err(_) => (0, 0),
    }
}

pub(super) async fn lookup_cached_artwork(
    pool: &SqlitePool,
    cache_key: &str,
) -> Option<ArtworkResult> {
    let cached = LibraryRepository::get_artwork_cache(pool, cache_key)
        .await
        .ok()
        .flatten()?;
    let cp = PathBuf::from(&cached.cache_path);
    let exists = tokio::fs::try_exists(&cp).await.unwrap_or(false);
    if !exists {
        return None;
    }
    let kind = parse_source_kind(&cached.source_kind);
    Some(ArtworkResult {
        found: true,
        cache_path: Some(cached.cache_path),
        mime_type: cached.mime_type,
        width: cached.width.map(|w| w as u32),
        height: cached.height.map(|h| h as u32),
        source_kind: kind,
        cache_key: Some(cached.cache_key),
        error: None,
    })
}

pub(super) async fn resolve_from_single_file(
    pool: &SqlitePool,
    file_path: &Path,
    max_dim: u32,
    cache_dir: &Path,
    track_id: Option<&str>,
    album_id: Option<&str>,
) -> Option<ArtworkResult> {
    let fp_stat = file_path.to_path_buf();
    let (file_mtime, file_size) =
        tokio::task::spawn_blocking(move || file_mtime_and_size(&fp_stat))
            .await
            .unwrap_or((0, 0));
    let norm_path = normalize_path(file_path);
    let file_hash_key = compute_cache_key(&format!("{norm_path}:{file_size}"), file_mtime, max_dim);

    if let Some(cached) = lookup_cached_artwork(pool, &file_hash_key).await {
        return Some(cached);
    }

    let fp_extract = file_path.to_path_buf();
    let (extracted, external_cover) = tokio::task::spawn_blocking(move || {
        let extracted = MetadataExtractor::extract(&fp_extract).ok();
        let ext = fp_extract.parent().and_then(find_external_cover);
        (extracted, ext)
    })
    .await
    .unwrap_or((None, None));

    // 2. Embedded Front Cover
    if let Some(ref meta) = extracted {
        for pic in &meta.pictures {
            if pic.picture_type.is_front_cover()
                || matches!(pic.picture_type, PictureType::FrontCover)
            {
                if let Some(res) = process_image_bytes(
                    &pic.data,
                    ArtworkSourceKind::Embedded,
                    max_dim,
                    cache_dir,
                    pool,
                    &file_hash_key,
                    track_id,
                    album_id,
                )
                .await
                {
                    return Some(res);
                }
            }
        }
    }

    // 3. External folder covers with strict priority: cover.* -> folder.* -> front.*
    if let Some((ext_path, kind)) = external_cover {
        if let Some(res) = process_image_file(
            &ext_path.to_string_lossy(),
            kind,
            max_dim,
            cache_dir,
            pool,
            track_id,
            album_id,
        )
        .await
        {
            return Some(res);
        }
    }

    // 3b. Untyped embedded picture fallback (e.g. MP4/M4A covr atom)
    if let Some(ref meta) = extracted {
        for pic in &meta.pictures {
            if matches!(pic.picture_type, PictureType::Other) {
                if let Some(res) = process_image_bytes(
                    &pic.data,
                    ArtworkSourceKind::Embedded,
                    max_dim,
                    cache_dir,
                    pool,
                    &file_hash_key,
                    track_id,
                    album_id,
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

fn detect_magic_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        Some("image/jpeg")
    } else if bytes.len() >= 8
        && bytes[0] == 0x89
        && bytes[1] == 0x50
        && bytes[2] == 0x4E
        && bytes[3] == 0x47
    {
        Some("image/png")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

pub(super) fn find_external_cover(dir: &Path) -> Option<(PathBuf, ArtworkSourceKind)> {
    let entries = fs::read_dir(dir).ok()?;
    let mut files = Vec::new();
    for entry in entries.flatten() {
        if let Ok(ft) = entry.file_type() {
            if ft.is_file() {
                files.push(entry.path());
            }
        }
    }

    // Tier 1: cover.* (jpg, jpeg, png, webp)
    for ext in &["jpg", "jpeg", "png", "webp"] {
        let expected = format!("cover.{ext}");
        if let Some(p) = files.iter().find(|f| {
            f.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.eq_ignore_ascii_case(&expected))
                .unwrap_or(false)
        }) {
            return Some((p.clone(), ArtworkSourceKind::Cover));
        }
    }

    // Tier 2: folder.* (jpg, jpeg, png, webp)
    for ext in &["jpg", "jpeg", "png", "webp"] {
        let expected = format!("folder.{ext}");
        if let Some(p) = files.iter().find(|f| {
            f.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.eq_ignore_ascii_case(&expected))
                .unwrap_or(false)
        }) {
            return Some((p.clone(), ArtworkSourceKind::Folder));
        }
    }

    // Tier 3: front.* (jpg, jpeg, png, webp)
    for ext in &["jpg", "jpeg", "png", "webp"] {
        let expected = format!("front.{ext}");
        if let Some(p) = files.iter().find(|f| {
            f.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.eq_ignore_ascii_case(&expected))
                .unwrap_or(false)
        }) {
            return Some((p.clone(), ArtworkSourceKind::Front));
        }
    }

    None
}

pub(super) async fn process_image_file(
    path_str: &str,
    source_kind: ArtworkSourceKind,
    max_dim: u32,
    cache_dir: &Path,
    pool: &SqlitePool,
    track_id: Option<&str>,
    album_id: Option<&str>,
) -> Option<ArtworkResult> {
    let p_owned = PathBuf::from(path_str);
    let p_stat = p_owned.clone();
    let (mtime, size) = tokio::task::spawn_blocking(move || file_mtime_and_size(&p_stat))
        .await
        .unwrap_or((0, 0));
    let norm = normalize_path(&p_owned);
    let cache_key = compute_cache_key(
        &format!("{}:{norm}:{size}", source_kind.as_str()),
        mtime,
        max_dim,
    );

    if let Some(cached) = lookup_cached_artwork(pool, &cache_key).await {
        return Some(cached);
    }

    let bytes = tokio::fs::read(&p_owned).await.ok()?;
    process_image_bytes(
        &bytes,
        source_kind,
        max_dim,
        cache_dir,
        pool,
        &cache_key,
        track_id,
        album_id,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn process_image_bytes(
    bytes: &[u8],
    source_kind: ArtworkSourceKind,
    max_dim: u32,
    cache_dir: &Path,
    pool: &SqlitePool,
    cache_key: &str,
    track_id: Option<&str>,
    album_id: Option<&str>,
) -> Option<ArtworkResult> {
    let bytes_owned = bytes.to_vec();
    let cache_dir_owned = cache_dir.to_path_buf();
    let cache_key_owned = cache_key.to_string();

    let _permit = artwork_decode_semaphore().acquire().await.ok()?;
    let (mime, final_w, final_h, norm_cache_path) = tokio::task::spawn_blocking(move || {
        let mime = detect_magic_mime(&bytes_owned)?;
        let img = image::load_from_memory(&bytes_owned).ok()?;
        let (orig_w, orig_h) = img.dimensions();

        let (final_img, final_w, final_h, scaled) =
            if max_dim > 0 && (orig_w > max_dim || orig_h > max_dim) {
                let resized = img.thumbnail(max_dim, max_dim);
                let (rw, rh) = resized.dimensions();
                (Some(resized), rw, rh, true)
            } else {
                (None, orig_w, orig_h, false)
            };

        let ext = match mime {
            "image/png" => "png",
            "image/webp" => "webp",
            _ => "jpg",
        };

        let cache_filename = format!("{}.{ext}", sanitize_filename(&cache_key_owned));
        let cache_file_path = cache_dir_owned.join(&cache_filename);

        if let Err(e) = fs::create_dir_all(&cache_dir_owned) {
            tracing::warn!("Failed to create artwork cache dir: {e}");
        }

        let save_res = if let (true, Some(img)) = (scaled, final_img.as_ref()) {
            img.save(&cache_file_path)
        } else {
            fs::write(&cache_file_path, &bytes_owned).map_err(image::ImageError::IoError)
        };

        if let Err(e) = save_res {
            tracing::warn!("Failed to write cached artwork to {cache_file_path:?}: {e}");
            return None;
        }

        let norm_cache_path = normalize_path(&cache_file_path);
        Some((mime, final_w, final_h, norm_cache_path))
    })
    .await
    .ok()
    .flatten()?;

    // Save entry to SQLite artwork_cache table
    let entry = ArtworkCacheEntry {
        cache_key: cache_key.to_string(),
        track_id: track_id.map(str::to_string),
        album_id: album_id.map(str::to_string),
        source_kind: source_kind.to_string(),
        mime_type: Some(mime.to_string()),
        width: Some(final_w as i64),
        height: Some(final_h as i64),
        max_dim: max_dim as i64,
        cache_path: norm_cache_path.clone(),
        source_mtime: None,
        updated_at: chrono::Utc::now().to_rfc3339(),
    };
    let _ = LibraryRepository::upsert_artwork_cache(pool, &entry).await;

    Some(ArtworkResult {
        found: true,
        cache_path: Some(norm_cache_path),
        mime_type: Some(mime.to_string()),
        width: Some(final_w),
        height: Some(final_h),
        source_kind,
        cache_key: Some(cache_key.to_string()),
        error: None,
    })
}

/// Computes a stable, portable SHA-256 cache key across Rust versions & platforms.
pub(super) fn compute_cache_key(identifier: &str, mtime: u64, max_dim: u32) -> String {
    let mut hasher = Sha256::new();
    hasher.update(identifier.as_bytes());
    hasher.update(b"\0");
    hasher.update(mtime.to_le_bytes());
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(32);
    for b in &digest[..16] {
        let _ = write!(&mut hex, "{b:02x}");
    }
    format!("art:{hex}:{max_dim}")
}

fn sanitize_filename(key: &str) -> String {
    key.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn parse_source_kind(s: &str) -> ArtworkSourceKind {
    match s {
        "embedded" => ArtworkSourceKind::Embedded,
        "cover" => ArtworkSourceKind::Cover,
        "folder" => ArtworkSourceKind::Folder,
        "front" => ArtworkSourceKind::Front,
        "user" => ArtworkSourceKind::User,
        _ => ArtworkSourceKind::Placeholder,
    }
}
