use std::fs;
use std::path::{Path, PathBuf};

use super::lyrics::decode_text_cjk;
use super::scanner::normalize_path;
use crate::error::ProviderError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedPlaylistEntry {
    pub raw_entry: String,
    pub resolved_path: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedPlaylist {
    pub name: String,
    pub source_path: String,
    pub entries: Vec<ParsedPlaylistEntry>,
}

/// Parses an `.m3u` or `.m3u8` sidecar playlist file (UTF-8 / BOM / CJK fallback),
/// resolving relative paths against the playlist's parent directory.
pub fn parse_m3u_file(path: &Path) -> Result<ParsedPlaylist, ProviderError> {
    let bytes = fs::read(path)?;
    let content = decode_text_cjk(&bytes);
    let base_dir = path.parent();
    let default_name = path
        .file_stem()
        .and_then(|s| s.to_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("Playlist")
        .to_string();

    Ok(parse_m3u_content(
        &content,
        &normalize_path(path),
        &default_name,
        base_dir,
    ))
}

pub fn parse_m3u_content(
    content: &str,
    source_path: &str,
    default_name: &str,
    base_dir: Option<&Path>,
) -> ParsedPlaylist {
    let mut name = default_name.to_string();
    let mut entries = Vec::new();

    for line in content.lines() {
        let trimmed = line.trim().trim_start_matches('\u{FEFF}');
        if trimmed.is_empty() {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("#PLAYLIST:") {
            let candidate = rest.trim();
            if !candidate.is_empty() {
                name = candidate.to_string();
            }
            continue;
        }
        if trimmed.starts_with('#') {
            continue;
        }

        let resolved_path = resolve_entry_path(trimmed, base_dir);
        entries.push(ParsedPlaylistEntry {
            raw_entry: trimmed.to_string(),
            resolved_path,
        });
    }

    ParsedPlaylist {
        name,
        source_path: source_path.to_string(),
        entries,
    }
}

fn resolve_entry_path(raw: &str, base_dir: Option<&Path>) -> Option<PathBuf> {
    let lower = raw.to_ascii_lowercase();
    if lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("smb://")
        || lower.starts_with("dav://")
        || lower.starts_with("davs://")
    {
        return None;
    }

    let cleaned = if let Some(rest) = raw.strip_prefix("file:///") {
        rest
    } else if let Some(rest) = raw.strip_prefix("file://") {
        rest
    } else {
        raw
    };

    let p = PathBuf::from(cleaned);
    if p.is_absolute() {
        Some(p)
    } else if let Some(dir) = base_dir {
        Some(dir.join(p))
    } else {
        Some(p)
    }
}
