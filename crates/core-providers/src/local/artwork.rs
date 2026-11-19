use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

use core_db::{ArtworkCacheEntry, LibraryRepository, SqlitePool};
use core_types::{ArtworkResult, ArtworkSourceKind, PictureType};
use image::GenericImageView;
use serde::{Deserialize, Serialize};

use super::metadata::MetadataExtractor;
use super::scanner::normalize_path;
use crate::error::ProviderError;

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct ArtworkTarget {
    #[serde(default)]
    pub track_id: Option<String>,
    #[serde(default)]
    pub album_id: Option<String>,
    #[serde(default)]
    pub file_path: Option<String>,
}

pub struct ArtworkManager;

impl ArtworkManager {
    /// Resolves artwork for a target with strict priority:
    /// User Override -> Embedded Front Cover -> cover.* -> folder.* -> front.* -> Placeholder.
    pub async fn resolve_artwork(
        pool: &SqlitePool,
        target_str: &str,
        max_dim: u32,
        cache_dir: &Path,
    ) -> Result<ArtworkResult, ProviderError> {
        let target = parse_target(target_str);

        // Resolve track_id, album_id, and file_path from DB if needed
        let (resolved_track_id, resolved_album_id, resolved_file_path) =
            resolve_target_info(pool, &target).await?;

        let is_album_query = resolved_track_id.is_none()
            && target
                .file_path
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .is_none()
            && resolved_album_id.is_some();

        // 1. User Override Check
        if let Some(ref tid) = resolved_track_id {
            if let Ok(Some(ovr)) = LibraryRepository::get_artwork_override(pool, "track", tid).await {
                if let Some(res) = process_image_file(&ovr.image_path, ArtworkSourceKind::User, max_dim, cache_dir, pool, Some(tid), resolved_album_id.as_deref()).await {
                    return Ok(res);
                }
            }
        }
        if !is_album_query {
            if let Some(ref fp) = resolved_file_path {
                let norm = normalize_path(fp);
                if let Ok(Some(ovr)) = LibraryRepository::get_artwork_override(pool, "track", &norm).await {
                    if let Some(res) = process_image_file(&ovr.image_path, ArtworkSourceKind::User, max_dim, cache_dir, pool, resolved_track_id.as_deref(), resolved_album_id.as_deref()).await {
                        return Ok(res);
                    }
                }
            }
        }
        if let Some(ref aid) = resolved_album_id {
            if let Ok(Some(ovr)) = LibraryRepository::get_artwork_override(pool, "album", aid).await {
                if let Some(res) = process_image_file(&ovr.image_path, ArtworkSourceKind::User, max_dim, cache_dir, pool, resolved_track_id.as_deref(), Some(aid)).await {
                    return Ok(res);
                }
            }
            if let Ok(Some(ovr)) = LibraryRepository::get_artwork_override(pool, "track", aid).await {
                if let Some(res) = process_image_file(&ovr.image_path, ArtworkSourceKind::User, max_dim, cache_dir, pool, resolved_track_id.as_deref(), Some(aid)).await {
                    return Ok(res);
                }
            }
        }

        // Single-track (or explicit file_path) resolution
        if !is_album_query {
            if let Some(ref fp) = resolved_file_path {
                let file_path = PathBuf::from(fp);
                if file_path.exists() {
                    if let Some(res) = resolve_from_single_file(
                        pool,
                        &file_path,
                        max_dim,
                        cache_dir,
                        resolved_track_id.as_deref(),
                        resolved_album_id.as_deref(),
                    )
                    .await
                    {
                        return Ok(res);
                    }
                }
            }
        }

        // Album-level resolution (or track fallback to sibling tracks in same album)
        if let Some(ref aid) = resolved_album_id {
            let skip_path = if is_album_query {
                None
            } else {
                resolved_file_path.as_deref()
            };
            if let Some(res) = resolve_from_album(
                pool,
                aid,
                skip_path,
                max_dim,
                cache_dir,
                resolved_track_id.as_deref(),
            )
            .await
            {
                return Ok(res);
            }
        }

        // 4. Default Placeholder
        Ok(ArtworkResult {
            found: false,
            source_kind: ArtworkSourceKind::Placeholder,
            ..Default::default()
        })
    }

    /// Sets user cover override.
    pub async fn set_user_cover(
        pool: &SqlitePool,
        target_str: &str,
        image_path: &str,
    ) -> Result<(), ProviderError> {
        let target = parse_target(target_str);
        let (resolved_track_id, resolved_album_id, _) = resolve_target_info(pool, &target).await?;

        if let Some(ref tid) = resolved_track_id {
            LibraryRepository::set_artwork_override(pool, "track", tid, image_path)
                .await
                .map_err(|e| ProviderError::Other(e.to_string()))?;
            let _ = LibraryRepository::invalidate_artwork_cache_for_track(pool, tid).await;
        } else if let Some(ref aid) = resolved_album_id {
            LibraryRepository::set_artwork_override(pool, "album", aid, image_path)
                .await
                .map_err(|e| ProviderError::Other(e.to_string()))?;
            let _ = LibraryRepository::invalidate_artwork_cache_for_album(pool, aid).await;
        } else if let Some(ref fp) = target.file_path {
            let norm = normalize_path(fp);
            LibraryRepository::set_artwork_override(pool, "track", &norm, image_path)
                .await
                .map_err(|e| ProviderError::Other(e.to_string()))?;
        }

        Ok(())
    }

    /// Clears user cover override.
    pub async fn clear_user_cover(
        pool: &SqlitePool,
        target_str: &str,
    ) -> Result<(), ProviderError> {
        let target = parse_target(target_str);
        let (resolved_track_id, resolved_album_id, _) = resolve_target_info(pool, &target).await?;

        if let Some(ref tid) = resolved_track_id {
            LibraryRepository::clear_artwork_override(pool, "track", tid)
                .await
                .map_err(|e| ProviderError::Other(e.to_string()))?;
            let _ = LibraryRepository::invalidate_artwork_cache_for_track(pool, tid).await;
        } else if let Some(ref aid) = resolved_album_id {
            LibraryRepository::clear_artwork_override(pool, "album", aid)
                .await
                .map_err(|e| ProviderError::Other(e.to_string()))?;
            let _ = LibraryRepository::clear_artwork_override(pool, "track", aid).await;
            let _ = LibraryRepository::invalidate_artwork_cache_for_album(pool, aid).await;
        } else if let Some(ref fp) = target.file_path {
            let norm = normalize_path(fp);
            LibraryRepository::clear_artwork_override(pool, "track", &norm)
                .await
                .map_err(|e| ProviderError::Other(e.to_string()))?;
        }

        Ok(())
    }
}

fn file_mtime_and_size(path: &Path) -> (u64, u64) {
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

async fn lookup_cached_artwork(pool: &SqlitePool, cache_key: &str) -> Option<ArtworkResult> {
    let cached = LibraryRepository::get_artwork_cache(pool, cache_key)
        .await
        .ok()
        .flatten()?;
    let cp = PathBuf::from(&cached.cache_path);
    if !cp.exists() {
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

async fn resolve_from_single_file(
    pool: &SqlitePool,
    file_path: &Path,
    max_dim: u32,
    cache_dir: &Path,
    track_id: Option<&str>,
    album_id: Option<&str>,
) -> Option<ArtworkResult> {
    let (file_mtime, file_size) = file_mtime_and_size(file_path);
    let norm_path = normalize_path(file_path);
    let file_hash_key = compute_cache_key(&format!("{norm_path}:{file_size}"), file_mtime, max_dim);

    if let Some(cached) = lookup_cached_artwork(pool, &file_hash_key).await {
        return Some(cached);
    }

    let extracted = MetadataExtractor::extract(file_path).ok();

    // 2. Embedded Front Cover
    if let Some(ref meta) = extracted {
        for pic in &meta.pictures {
            if pic.picture_type.is_front_cover() || matches!(pic.picture_type, PictureType::FrontCover) {
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
    if let Some(parent) = file_path.parent() {
        if let Some((ext_path, kind)) = find_external_cover(parent) {
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

async fn resolve_from_album(
    pool: &SqlitePool,
    album_id: &str,
    skip_path: Option<&str>,
    max_dim: u32,
    cache_dir: &Path,
    track_id: Option<&str>,
) -> Option<ArtworkResult> {
    let rows: Vec<(String,)> = sqlx::query_as(
        "SELECT ts.external_track_id \
         FROM track_sources ts \
         JOIN album_versions av ON ts.version_id = av.id \
         WHERE av.canonical_album_id = ? \
         ORDER BY CASE WHEN av.provider_id = 'local' THEN 0 ELSE 1 END, \
                  ts.disc_number ASC, ts.track_number ASC, ts.external_track_id ASC",
    )
    .bind(album_id)
    .fetch_all(pool)
    .await
    .unwrap_or_default();

    let skip_norm = skip_path.map(normalize_path);
    let mut track_paths: Vec<PathBuf> = Vec::new();
    for (p,) in rows {
        let pb = PathBuf::from(&p);
        if pb.exists() {
            if let Some(ref sn) = skip_norm {
                if normalize_path(&pb) == *sn {
                    continue;
                }
            }
            track_paths.push(pb);
        }
    }

    // Fast path: check artwork_cache for any track in the album
    let mut track_keys: Vec<(PathBuf, String)> = Vec::with_capacity(track_paths.len());
    for pb in &track_paths {
        let (mtime, size) = file_mtime_and_size(pb);
        let key = compute_cache_key(&format!("{}:{size}", normalize_path(pb)), mtime, max_dim);
        if let Some(cached) = lookup_cached_artwork(pool, &key).await {
            return Some(cached);
        }
        track_keys.push((pb.clone(), key));
    }

    // Pass 1: Embedded Front Cover across album tracks
    let mut extracted_cache = Vec::with_capacity(track_keys.len());
    for (pb, key) in &track_keys {
        let meta = MetadataExtractor::extract(pb).ok();
        if let Some(ref m) = meta {
            for pic in &m.pictures {
                if pic.picture_type.is_front_cover() || matches!(pic.picture_type, PictureType::FrontCover) {
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
        extracted_cache.push((pb, key, meta));
    }

    // Pass 2: External folder covers (cover.* -> folder.* -> front.*) across album directories
    let mut checked_dirs = std::collections::HashSet::new();
    for (pb, _, _) in &extracted_cache {
        if let Some(parent) = pb.parent() {
            let norm_dir = normalize_path(parent);
            if checked_dirs.insert(norm_dir) {
                if let Some((ext_path, kind)) = find_external_cover(parent) {
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

    // Pass 3: Untyped embedded pictures (e.g. MP4/M4A covr atom)
    for (_, key, meta_opt) in &extracted_cache {
        if let Some(m) = meta_opt {
            for pic in &m.pictures {
                if matches!(pic.picture_type, PictureType::Other) {
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
    }

    // Pass 4: Fallback to canonical_albums.cover_url if it points to a real local image file
    let db_cover: Option<(Option<String>,)> = sqlx::query_as(
        "SELECT COALESCE(cover_url, merged_cover_path) FROM canonical_albums WHERE id = ? LIMIT 1",
    )
    .bind(album_id)
    .fetch_optional(pool)
    .await
    .ok()
    .flatten();
    if let Some((Some(cover_str),)) = db_cover {
        let trimmed = cover_str.trim();
        if !trimmed.is_empty() && !trimmed.starts_with("http://") && !trimmed.starts_with("https://") && !trimmed.starts_with('/') {
            let cp = Path::new(trimmed);
            if cp.is_file() {
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

fn parse_target(target_str: &str) -> ArtworkTarget {
    let trimmed = target_str.trim();
    if trimmed.starts_with('{') {
        serde_json::from_str::<ArtworkTarget>(trimmed).unwrap_or_else(|_| ArtworkTarget {
            file_path: Some(trimmed.to_string()),
            ..Default::default()
        })
    } else {
        // Plain string: could be track_id or file path
        if trimmed.contains('/') || trimmed.contains('\\') || trimmed.ends_with(".flac") || trimmed.ends_with(".mp3") || trimmed.ends_with(".wav") || trimmed.ends_with(".m4a") || trimmed.ends_with(".dsf") || trimmed.ends_with(".dff") {
            ArtworkTarget {
                file_path: Some(trimmed.to_string()),
                ..Default::default()
            }
        } else {
            ArtworkTarget {
                track_id: Some(trimmed.to_string()),
                ..Default::default()
            }
        }
    }
}

async fn resolve_target_info(
    pool: &SqlitePool,
    target: &ArtworkTarget,
) -> Result<(Option<String>, Option<String>, Option<String>), ProviderError> {
    if let Some(ref tid) = target.track_id {
        // Query track_sources
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT ts.external_track_id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE ts.id = ? LIMIT 1",
        )
        .bind(tid)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten();

        if let Some((ext_id, alb_id)) = row {
            let fp = target.file_path.clone().unwrap_or(ext_id);
            return Ok((Some(tid.clone()), Some(alb_id), Some(fp)));
        }

        // Check if tid is actually a canonical_albums.id (e.g. album-level callers via FFI)
        let has_file_path = target
            .file_path
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .is_some();
        if target.album_id.is_none() && !has_file_path {
            let alb_row: Option<(String,)> = sqlx::query_as(
                "SELECT id FROM canonical_albums WHERE id = ? LIMIT 1",
            )
            .bind(tid)
            .fetch_optional(pool)
            .await
            .ok()
            .flatten();

            if let Some((alb_id,)) = alb_row {
                let first_fp: Option<(String,)> = sqlx::query_as(
                    "SELECT ts.external_track_id \
                     FROM track_sources ts \
                     JOIN album_versions av ON ts.version_id = av.id \
                     WHERE av.canonical_album_id = ? \
                     ORDER BY CASE WHEN av.provider_id = 'local' THEN 0 ELSE 1 END, \
                              ts.disc_number ASC, ts.track_number ASC, ts.external_track_id ASC \
                     LIMIT 1",
                )
                .bind(&alb_id)
                .fetch_optional(pool)
                .await
                .ok()
                .flatten();

                return Ok((None, Some(alb_id), first_fp.map(|(fp,)| fp)));
            }
        }
    }

    if let Some(ref fp) = target.file_path {
        let norm = normalize_path(fp);
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT ts.id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE LOWER(REPLACE(ts.external_track_id, '\\', '/')) = LOWER(?) LIMIT 1",
        )
        .bind(&norm)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten();

        if let Some((tid, alb_id)) = row {
            return Ok((Some(tid), Some(alb_id), Some(fp.clone())));
        }
        return Ok((target.track_id.clone(), target.album_id.clone(), Some(fp.clone())));
    }

    if let Some(ref aid) = target.album_id {
        let row: Option<(String,)> = sqlx::query_as(
            "SELECT ts.external_track_id \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE av.canonical_album_id = ? \
             ORDER BY CASE WHEN av.provider_id = 'local' THEN 0 ELSE 1 END, \
                      ts.disc_number ASC, ts.track_number ASC, ts.external_track_id ASC \
             LIMIT 1",
        )
        .bind(aid)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten();

        return Ok((None, Some(aid.clone()), row.map(|(ext_id,)| ext_id)));
    }

    Ok((target.track_id.clone(), target.album_id.clone(), target.file_path.clone()))
}

fn detect_magic_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        Some("image/jpeg")
    } else if bytes.len() >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
        Some("image/png")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

fn find_external_cover(dir: &Path) -> Option<(PathBuf, ArtworkSourceKind)> {
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
        if let Some(p) = files.iter().find(|f| f.file_name().and_then(|n| n.to_str()).map(|n| n.eq_ignore_ascii_case(&expected)).unwrap_or(false)) {
            return Some((p.clone(), ArtworkSourceKind::Cover));
        }
    }

    // Tier 2: folder.* (jpg, jpeg, png, webp)
    for ext in &["jpg", "jpeg", "png", "webp"] {
        let expected = format!("folder.{ext}");
        if let Some(p) = files.iter().find(|f| f.file_name().and_then(|n| n.to_str()).map(|n| n.eq_ignore_ascii_case(&expected)).unwrap_or(false)) {
            return Some((p.clone(), ArtworkSourceKind::Folder));
        }
    }

    // Tier 3: front.* (jpg, jpeg, png, webp)
    for ext in &["jpg", "jpeg", "png", "webp"] {
        let expected = format!("front.{ext}");
        if let Some(p) = files.iter().find(|f| f.file_name().and_then(|n| n.to_str()).map(|n| n.eq_ignore_ascii_case(&expected)).unwrap_or(false)) {
            return Some((p.clone(), ArtworkSourceKind::Front));
        }
    }

    None
}

async fn process_image_file(
    path_str: &str,
    source_kind: ArtworkSourceKind,
    max_dim: u32,
    cache_dir: &Path,
    pool: &SqlitePool,
    track_id: Option<&str>,
    album_id: Option<&str>,
) -> Option<ArtworkResult> {
    let p = Path::new(path_str);
    let (mtime, size) = file_mtime_and_size(p);
    let norm = normalize_path(p);
    let cache_key = compute_cache_key(&format!("{}:{norm}:{size}", source_kind.as_str()), mtime, max_dim);

    if let Some(cached) = lookup_cached_artwork(pool, &cache_key).await {
        return Some(cached);
    }

    let bytes = fs::read(p).ok()?;
    process_image_bytes(&bytes, source_kind, max_dim, cache_dir, pool, &cache_key, track_id, album_id).await
}

async fn process_image_bytes(
    bytes: &[u8],
    source_kind: ArtworkSourceKind,
    max_dim: u32,
    cache_dir: &Path,
    pool: &SqlitePool,
    cache_key: &str,
    track_id: Option<&str>,
    album_id: Option<&str>,
) -> Option<ArtworkResult> {
    let mime = detect_magic_mime(bytes)?;
    let img = image::load_from_memory(bytes).ok()?;
    let (orig_w, orig_h) = img.dimensions();

    let (final_img, final_w, final_h, scaled) = if max_dim > 0 && (orig_w > max_dim || orig_h > max_dim) {
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

    let cache_filename = format!("{}.{ext}", sanitize_filename(cache_key));
    let cache_file_path = cache_dir.join(&cache_filename);

    if let Err(e) = fs::create_dir_all(cache_dir) {
        tracing::warn!("Failed to create artwork cache dir: {e}");
    }

    let save_res = if let (true, Some(img)) = (scaled, final_img.as_ref()) {
        img.save(&cache_file_path)
    } else {
        fs::write(&cache_file_path, bytes).map_err(image::ImageError::IoError)
    };

    if let Err(e) = save_res {
        tracing::warn!("Failed to write cached artwork to {cache_file_path:?}: {e}");
        return None;
    }

    let norm_cache_path = normalize_path(&cache_file_path);

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

fn compute_cache_key(identifier: &str, mtime: u64, max_dim: u32) -> String {
    let mut hasher = DefaultHasher::new();
    identifier.hash(&mut hasher);
    mtime.hash(&mut hasher);
    let hash = hasher.finish();
    format!("art:{:016x}:{}", hash, max_dim)
}

fn sanitize_filename(key: &str) -> String {
    key.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
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
