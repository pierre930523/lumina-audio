use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use core_db::{CatalogQueryRepository, LibraryRepository, SqlitePool};
use core_types::{ArtworkResult, ArtworkSourceKind};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, Notify};

use super::album_resolve::resolve_from_album;
use super::extract::{process_image_file, resolve_from_single_file};
use crate::error::ProviderError;
use crate::local::scanner::normalize_path;

type InFlightMap = Mutex<HashMap<String, Arc<Notify>>>;

fn in_flight_map() -> &'static InFlightMap {
    static MAP: OnceLock<InFlightMap> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

struct InFlightGuard {
    key: String,
    notify: Arc<Notify>,
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        let key = self.key.clone();
        let notify = self.notify.clone();
        if let Ok(mut map) = in_flight_map().try_lock() {
            map.remove(&key);
            notify.notify_waiters();
        } else {
            tokio::spawn(async move {
                let mut map = in_flight_map().lock().await;
                map.remove(&key);
                notify.notify_waiters();
            });
        }
    }
}

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
    ///
    /// Deduplicates concurrent in-flight requests for the same `(target, max_dim)` and bounds
    /// image decode concurrency via a shared semaphore.
    pub async fn resolve_artwork(
        pool: &SqlitePool,
        target_str: &str,
        max_dim: u32,
        cache_dir: &Path,
    ) -> Result<ArtworkResult, ProviderError> {
        let flight_key = format!("{}:{max_dim}", target_str.trim());
        let _guard = loop {
            let mut map = in_flight_map().lock().await;
            if let Some(existing) = map.get(&flight_key).cloned() {
                drop(map);
                existing.notified().await;
                continue;
            }
            let notify = Arc::new(Notify::new());
            map.insert(flight_key.clone(), notify.clone());
            break InFlightGuard {
                key: flight_key.clone(),
                notify,
            };
        };

        Self::resolve_artwork_inner(pool, target_str, max_dim, cache_dir).await
    }

    async fn resolve_artwork_inner(
        pool: &SqlitePool,
        target_str: &str,
        max_dim: u32,
        cache_dir: &Path,
    ) -> Result<ArtworkResult, ProviderError> {
        let target = parse_target(target_str);

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
            if let Ok(Some(ovr)) = LibraryRepository::get_artwork_override(pool, "track", tid).await
            {
                if let Some(res) = process_image_file(
                    &ovr.image_path,
                    ArtworkSourceKind::User,
                    max_dim,
                    cache_dir,
                    pool,
                    Some(tid),
                    resolved_album_id.as_deref(),
                )
                .await
                {
                    return Ok(res);
                }
            }
        }
        if !is_album_query {
            if let Some(ref fp) = resolved_file_path {
                let norm = normalize_path(fp);
                if let Ok(Some(ovr)) =
                    LibraryRepository::get_artwork_override(pool, "track", &norm).await
                {
                    if let Some(res) = process_image_file(
                        &ovr.image_path,
                        ArtworkSourceKind::User,
                        max_dim,
                        cache_dir,
                        pool,
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
        if let Some(ref aid) = resolved_album_id {
            for target_type in ["album", "track"] {
                if let Ok(Some(ovr)) =
                    LibraryRepository::get_artwork_override(pool, target_type, aid).await
                {
                    if let Some(res) = process_image_file(
                        &ovr.image_path,
                        ArtworkSourceKind::User,
                        max_dim,
                        cache_dir,
                        pool,
                        resolved_track_id.as_deref(),
                        Some(aid),
                    )
                    .await
                    {
                        return Ok(res);
                    }
                }
            }
        }

        // Single-track (or explicit file_path) resolution
        if !is_album_query {
            if let Some(ref fp) = resolved_file_path {
                let file_path = PathBuf::from(fp);
                let check_path = file_path.clone();
                let exists = tokio::task::spawn_blocking(move || check_path.exists())
                    .await
                    .unwrap_or(false);
                if exists {
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

fn parse_target(target_str: &str) -> ArtworkTarget {
    let trimmed = target_str.trim();
    if trimmed.starts_with('{') {
        serde_json::from_str::<ArtworkTarget>(trimmed).unwrap_or_else(|_| ArtworkTarget {
            file_path: Some(trimmed.to_string()),
            ..Default::default()
        })
    } else if trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.ends_with(".flac")
        || trimmed.ends_with(".mp3")
        || trimmed.ends_with(".wav")
        || trimmed.ends_with(".m4a")
        || trimmed.ends_with(".dsf")
        || trimmed.ends_with(".dff")
    {
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

async fn resolve_target_info(
    pool: &SqlitePool,
    target: &ArtworkTarget,
) -> Result<(Option<String>, Option<String>, Option<String>), ProviderError> {
    if let Some(ref tid) = target.track_id {
        let row = CatalogQueryRepository::get_track_path_and_album_by_id(pool, tid)
            .await
            .ok()
            .flatten();

        if let Some((ext_id, alb_id)) = row {
            let fp = target.file_path.clone().unwrap_or(ext_id);
            return Ok((Some(tid.clone()), Some(alb_id), Some(fp)));
        }

        let has_file_path = target
            .file_path
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .is_some();
        if target.album_id.is_none() && !has_file_path {
            let exists = CatalogQueryRepository::canonical_album_exists(pool, tid)
                .await
                .unwrap_or(false);

            if exists {
                let first_fp =
                    CatalogQueryRepository::get_first_external_track_id_for_album(pool, tid)
                        .await
                        .ok()
                        .flatten();

                return Ok((None, Some(tid.clone()), first_fp));
            }
        }
    }

    if let Some(ref fp) = target.file_path {
        let norm = normalize_path(fp);
        let row = CatalogQueryRepository::get_track_id_and_album_by_normalized_path(pool, &norm)
            .await
            .ok()
            .flatten();

        if let Some((tid, alb_id)) = row {
            return Ok((Some(tid), Some(alb_id), Some(fp.clone())));
        }
        return Ok((
            target.track_id.clone(),
            target.album_id.clone(),
            Some(fp.clone()),
        ));
    }

    if let Some(ref aid) = target.album_id {
        let first_fp = CatalogQueryRepository::get_first_external_track_id_for_album(pool, aid)
            .await
            .ok()
            .flatten();

        return Ok((None, Some(aid.clone()), first_fp));
    }

    Ok((
        target.track_id.clone(),
        target.album_id.clone(),
        target.file_path.clone(),
    ))
}
