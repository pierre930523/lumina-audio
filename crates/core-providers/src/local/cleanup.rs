use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use core_db::{DbWriteCoordinator, IngestionRepository, LibraryRepository, SqlitePool};
use core_types::{LibraryCleanupOptions, LibraryCleanupPreview, LibraryCleanupResult};

use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::scanner::normalize_path;

/// Verifies that a local or mounted storage root is currently online and readable.
///
/// Checks existence, directory type, `fs::read_dir` accessibility, and guards against
/// unmounted removable/network volume stubs (e.g. empty `/Volumes/<vol>` or `/mnt/<vol>`
/// directories sitting on the parent filesystem when a drive/NAS is disconnected).
pub fn is_root_accessible(path: &Path) -> bool {
    let raw = path.to_string_lossy();
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return false;
    }

    if let Some(prefix) = extract_windows_volume_prefix(trimmed) {
        let p = Path::new(&prefix);
        if fs::metadata(p).is_err() {
            return false;
        }
    }

    if !path.exists() || !path.is_dir() {
        return false;
    }

    let Ok(mut entries) = fs::read_dir(path) else {
        return false;
    };

    #[cfg(unix)]
    if is_removable_mount_stub(path) {
        if entries.next().is_none() && !is_distinct_unix_mount(path) {
            return false;
        }
    }

    let _ = &mut entries;
    true
}

/// Normalizes a local path for case/separator-consistent comparison across Windows & Unix,
/// mirroring `core_db`'s `normalize_local_path_for_compare`.
pub(crate) fn normalize_path_for_compare(raw: &str) -> String {
    let trimmed = raw.trim();
    let stripped = trimmed
        .strip_prefix("file:///")
        .or_else(|| trimmed.strip_prefix("file://"))
        .unwrap_or(trimmed);
    let mut norm = normalize_path(stripped);
    if let Some(rest) = norm.strip_prefix("//?/") {
        norm = rest.to_string();
    }
    while norm.len() > 1 && norm.ends_with('/') {
        if norm.len() == 3 && norm.as_bytes()[1] == b':' {
            break;
        }
        norm.pop();
    }
    norm
}

/// Returns `true` if `track_norm` equals `root_norm` or is a descendant of `root_norm`.
pub(crate) fn path_under_root(track_norm: &str, root_norm: &str) -> bool {
    if root_norm.is_empty() {
        return false;
    }
    if track_norm == root_norm {
        return true;
    }
    if root_norm.ends_with('/') {
        track_norm.starts_with(root_norm)
    } else {
        track_norm.starts_with(root_norm)
            && track_norm.as_bytes().get(root_norm.len()) == Some(&b'/')
    }
}

struct RootEval {
    norm_path: String,
    accessible: bool,
}

struct CleanupFsAssessment {
    verified_missing_track_ids: Vec<String>,
    online_roots_checked: Vec<String>,
    offline_roots: Vec<String>,
    orphan_artwork_files: Vec<(PathBuf, u64)>,
}

/// Computes a read-only preview of Library Cleanup counts without mutating SQLite or disk.
pub async fn preview_library_cleanup(
    pool: &SqlitePool,
    artwork_cache_dir: &Path,
) -> Result<LibraryCleanupPreview, ProviderError> {
    let watched = IngestionRepository::list_watched_roots(pool)
        .await
        .map_err(db_err)?;
    let local_tracks = LibraryRepository::list_local_track_paths_for_cleanup(pool)
        .await
        .map_err(db_err)?;
    let referenced_artwork = LibraryRepository::collect_referenced_artwork_paths(pool)
        .await
        .map_err(db_err)?;

    let cache_dir = artwork_cache_dir.to_path_buf();
    let assessment = tokio::task::spawn_blocking(move || {
        assess_filesystem_for_cleanup(
            watched
                .into_iter()
                .filter(|r| r.provider_id.eq_ignore_ascii_case("local"))
                .map(|r| r.root_path)
                .collect(),
            local_tracks,
            Some((cache_dir, referenced_artwork)),
        )
    })
    .await
    .map_err(|e| ProviderError::ScanError(format!("Cleanup preview worker panicked: {e}")))?;

    let orphan_count = assessment.orphan_artwork_files.len();
    let orphan_bytes: u64 = assessment
        .orphan_artwork_files
        .iter()
        .map(|(_, sz)| *sz)
        .sum();

    LibraryRepository::preview_library_cleanup_db(
        pool,
        &assessment.verified_missing_track_ids,
        orphan_count,
        orphan_bytes,
        assessment.offline_roots,
        assessment.online_roots_checked,
    )
    .await
    .map_err(db_err)
}

/// Executes Library Cleanup safely:
/// 1. Evaluates root accessibility & missing local files in `spawn_blocking` (no DB write lock held).
/// 2. Acquires `DbWriteCoordinator` and runs `execute_library_cleanup_tx` atomically in ONE `ImmediateTx`.
/// 3. ONLY AFTER transaction commit, deletes unreferenced files strictly inside `artwork_cache_dir`.
pub async fn execute_library_cleanup(
    pool: &SqlitePool,
    write_coord: &DbWriteCoordinator,
    artwork_cache_dir: &Path,
    options: &LibraryCleanupOptions,
) -> Result<LibraryCleanupResult, ProviderError> {
    let watched = IngestionRepository::list_watched_roots(pool)
        .await
        .map_err(db_err)?;
    let local_tracks = if options.remove_missing_tracks {
        LibraryRepository::list_local_track_paths_for_cleanup(pool)
            .await
            .map_err(db_err)?
    } else {
        Vec::new()
    };

    let assessment = tokio::task::spawn_blocking(move || {
        assess_filesystem_for_cleanup(
            watched
                .into_iter()
                .filter(|r| r.provider_id.eq_ignore_ascii_case("local"))
                .map(|r| r.root_path)
                .collect(),
            local_tracks,
            None,
        )
    })
    .await
    .map_err(|e| ProviderError::ScanError(format!("Cleanup pre-check worker panicked: {e}")))?;

    let (mut result, surviving_refs) = {
        let (_wg, mut tx) = write_coord.begin_immediate(pool).await.map_err(db_err)?;
        match LibraryRepository::execute_library_cleanup_tx(
            tx.conn(),
            options,
            &assessment.verified_missing_track_ids,
            assessment.offline_roots,
        )
        .await
        .map_err(db_err)
        {
            Ok(out) => {
                tx.commit().await.map_err(db_err)?;
                out
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        }
    };

    if options.remove_orphan_artwork_cache {
        let cache_dir = artwork_cache_dir.to_path_buf();
        let (removed_files, freed_bytes) = tokio::task::spawn_blocking(move || {
            let orphans = scan_orphan_artwork_files(&cache_dir, &surviving_refs);
            let mut removed = 0usize;
            let mut freed = 0u64;
            for (path, size) in orphans {
                if fs::remove_file(&path).is_ok() {
                    removed += 1;
                    freed = freed.saturating_add(size);
                }
            }
            (removed, freed)
        })
        .await
        .unwrap_or((0, 0));

        result.removed_artwork_files = removed_files;
        result.freed_artwork_bytes = freed_bytes;
    }

    Ok(result)
}

fn assess_filesystem_for_cleanup(
    watched_root_paths: Vec<String>,
    local_tracks: Vec<(String, String, String)>,
    artwork_scan: Option<(PathBuf, HashSet<String>)>,
) -> CleanupFsAssessment {
    let mut root_evals: Vec<RootEval> = Vec::with_capacity(watched_root_paths.len());
    let mut online_roots_checked: Vec<String> = Vec::new();
    let mut offline_roots: Vec<String> = Vec::new();
    let mut offline_seen: HashSet<String> = HashSet::new();

    for raw in watched_root_paths {
        let norm = normalize_path_for_compare(&raw);
        let accessible = is_root_accessible(Path::new(&raw));
        if accessible {
            online_roots_checked.push(raw.clone());
        } else if offline_seen.insert(norm.clone()) {
            offline_roots.push(raw.clone());
        }
        root_evals.push(RootEval {
            norm_path: norm,
            accessible,
        });
    }
    // Sort longest prefix first so nested roots match the most specific root first.
    root_evals.sort_by_key(|a| std::cmp::Reverse(a.norm_path.len()));

    let mut inferred_root_cache: HashMap<String, bool> = HashMap::new();
    let mut verified_missing_track_ids: Vec<String> = Vec::new();

    for (track_id, raw_path, _file_status) in local_tracks {
        let track_norm = normalize_path_for_compare(&raw_path);
        if track_norm.is_empty() {
            continue;
        }

        if let Some(root) = root_evals
            .iter()
            .find(|r| path_under_root(&track_norm, &r.norm_path))
        {
            if !root.accessible {
                continue;
            }
        } else if let Some(inferred) = infer_volume_or_mount_root(&raw_path) {
            let inferred_norm = normalize_path_for_compare(&inferred);
            let accessible = *inferred_root_cache
                .entry(inferred_norm.clone())
                .or_insert_with(|| is_root_accessible(Path::new(&inferred)));
            if !accessible {
                if offline_seen.insert(inferred_norm) {
                    offline_roots.push(inferred);
                }
                continue;
            }
        }

        if is_definitely_missing_on_disk(Path::new(&raw_path)) {
            verified_missing_track_ids.push(track_id);
        }
    }

    let orphan_artwork_files = match artwork_scan {
        Some((dir, refs)) => scan_orphan_artwork_files(&dir, &refs),
        None => Vec::new(),
    };

    CleanupFsAssessment {
        verified_missing_track_ids,
        online_roots_checked,
        offline_roots,
        orphan_artwork_files,
    }
}

fn is_definitely_missing_on_disk(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(_) => false,
        Err(e) => e.kind() == ErrorKind::NotFound,
    }
}

/// Scans regular files strictly inside `artwork_cache_dir` and returns any whose normalized
/// path is not present in `referenced_norm_paths`.
pub(crate) fn scan_orphan_artwork_files(
    artwork_cache_dir: &Path,
    referenced_norm_paths: &HashSet<String>,
) -> Vec<(PathBuf, u64)> {
    if !artwork_cache_dir.exists() || !artwork_cache_dir.is_dir() {
        return Vec::new();
    }
    let Ok(canonical_root) = fs::canonicalize(artwork_cache_dir) else {
        return Vec::new();
    };
    let mut orphans = Vec::new();
    collect_orphan_files_rec(
        artwork_cache_dir,
        &canonical_root,
        referenced_norm_paths,
        &mut orphans,
    );
    orphans
}

fn collect_orphan_files_rec(
    dir: &Path,
    canonical_root: &Path,
    referenced: &HashSet<String>,
    out: &mut Vec<(PathBuf, u64)>,
) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        if ft.is_symlink() {
            continue;
        }
        let path = entry.path();
        if ft.is_dir() {
            collect_orphan_files_rec(&path, canonical_root, referenced, out);
        } else if ft.is_file() {
            if let Ok(canon) = fs::canonicalize(&path) {
                if !canon.starts_with(canonical_root) {
                    continue;
                }
            } else {
                continue;
            }
            let norm = normalize_path_for_compare(&path.to_string_lossy());
            let canon_norm = fs::canonicalize(&path)
                .ok()
                .map(|c| normalize_path_for_compare(&c.to_string_lossy()));
            let is_ref = referenced.contains(&norm)
                || canon_norm
                    .as_ref()
                    .is_some_and(|cn| referenced.contains(cn));
            if !is_ref {
                let sz = entry.metadata().map(|m| m.len()).unwrap_or(0);
                out.push((path, sz));
            }
        }
    }
}

fn extract_windows_volume_prefix(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.starts_with(r"\\") || trimmed.starts_with("//") {
        let rest = trimmed.trim_start_matches(['\\', '/']);
        let mut parts = rest.split(['\\', '/']).filter(|s| !s.is_empty());
        let host = parts.next()?;
        let share = parts.next()?;
        return Some(format!(r"\\{host}\{share}"));
    }
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        let drive = (bytes[0] as char).to_ascii_uppercase();
        return Some(format!(r"{drive}:\"));
    }
    None
}

pub(crate) fn infer_volume_or_mount_root(raw_path: &str) -> Option<String> {
    if let Some(prefix) = extract_windows_volume_prefix(raw_path) {
        return Some(prefix);
    }
    let norm = raw_path.trim().replace('\\', "/");
    if let Some(rest) = norm.strip_prefix("/Volumes/") {
        let vol = rest.split('/').find(|s| !s.is_empty())?;
        return Some(format!("/Volumes/{vol}"));
    }
    if let Some(rest) = norm.strip_prefix("/mnt/") {
        let vol = rest.split('/').find(|s| !s.is_empty())?;
        return Some(format!("/mnt/{vol}"));
    }
    if let Some(rest) = norm.strip_prefix("/media/") {
        let mut parts = rest.split('/').filter(|s| !s.is_empty());
        let first = parts.next()?;
        if let Some(second) = parts.next() {
            return Some(format!("/media/{first}/{second}"));
        }
        return Some(format!("/media/{first}"));
    }
    None
}

#[cfg(unix)]
fn is_removable_mount_stub(path: &Path) -> bool {
    let norm = path.to_string_lossy().replace('\\', "/");
    norm.starts_with("/Volumes/") || norm.starts_with("/mnt/") || norm.starts_with("/media/")
}

#[cfg(unix)]
fn is_distinct_unix_mount(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    let Some(parent) = path.parent() else {
        return true;
    };
    let Ok(parent_meta) = fs::metadata(parent) else {
        return false;
    };
    meta.dev() != parent_meta.dev()
}
