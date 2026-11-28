use std::path::{Component, Path};

use core_types::SkipReason;

const IGNORED_SYSTEM_NAMES: &[&str] = &[
    "@eadir",
    "@tmp",
    "@recycle",
    "__macosx",
    "#recycle",
    "#snapshot",
    "$recycle.bin",
    "system volume information",
    "thumbs.db",
    "ehthumbs.db",
    "desktop.ini",
    ".trashes",
    ".spotlight-v100",
    ".ds_store",
    ".fseventsd",
    ".temporaryitems",
    "lost+found",
];

/// Returns `true` if a single path segment (file or directory name) should be ignored
/// by local/NAS scanners and filesystem watchers.
pub fn should_ignore_name(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.starts_with('.') {
        return true;
    }
    let lower = trimmed.to_ascii_lowercase();
    IGNORED_SYSTEM_NAMES.contains(&lower.as_str())
}

/// Returns `true` if any component in `path` matches built-in ignore rules.
pub fn should_ignore_path(path: &Path) -> bool {
    for comp in path.components() {
        if let Component::Normal(os_name) = comp {
            if let Some(name) = os_name.to_str() {
                if should_ignore_name(name) {
                    return true;
                }
            }
        }
    }
    false
}

/// Returns `true` if any component of `path` **below `root`** matches built-in ignore rules.
///
/// Checking only the relative path avoids false-ignoring files when `root` itself lives
/// inside a dot-prefixed directory (e.g. `~/.local/...`, `.tmp...`, `.gemini/...`).
pub fn should_ignore_relative_path(path: &Path, root: &Path) -> bool {
    if let Ok(rel) = path.strip_prefix(root) {
        return should_ignore_path(rel);
    }

    let p_norm = super::scanner::normalize_path(path);
    let r_norm = super::scanner::normalize_path(root);
    let r_trimmed = r_norm.trim_end_matches('/');
    if let Some(rest) = p_norm.strip_prefix(r_trimmed) {
        if let Some(rel_str) = rest.strip_prefix('/') {
            return rel_str.split('/').any(should_ignore_name);
        }
        if rest.is_empty() {
            return false;
        }
    }

    // Fallback: check leaf file name only rather than unrelated ancestor dirs.
    path.file_name()
        .and_then(|n| n.to_str())
        .is_some_and(should_ignore_name)
}

/// Classifies known unsupported audio/disc container extensions into a quarantine [`SkipReason`].
pub fn classify_unsupported_container(path: &Path) -> Option<SkipReason> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        "cue" | "iso" => Some(SkipReason::UnsplitCueOrIso),
        "wv" | "ape" | "wma" | "mpc" | "tak" | "tta" => Some(SkipReason::UnsupportedFormat),
        _ => None,
    }
}

/// Returns `true` if `path` is a sibling `.m3u` or `.m3u8` playlist sidecar.
pub fn is_playlist_sidecar(path: &Path) -> bool {
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        if should_ignore_name(name) {
            return false;
        }
    } else {
        return false;
    }
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .as_deref(),
        Some("m3u" | "m3u8")
    )
}
