use sha2::{Digest, Sha256};
use std::fmt::Write as _;

use crate::repository::library::path_in_scope;

#[derive(Debug, Clone)]
pub(crate) struct WatchedRootInfo {
    pub id: String,
    pub norm_path: String,
    pub display_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FolderSegment {
    pub id: String,
    pub parent_id: Option<String>,
    pub root_id: Option<String>,
    pub name: String,
    pub norm_path: String,
    pub display_path: String,
    pub depth: i64,
}

/// Normalizes a local folder or file path for canonical comparison and storage.
///
/// Mirrors `normalize_local_path_for_compare`:
/// - Converts `\` -> `/`
/// - Strips `//?/UNC/` -> `//` and `//?/` -> ``
/// - Strips trailing `/` while preserving bare `/` and Windows drive roots (`c:/`)
/// - Lowercases on Windows (`cfg!(windows)`) or for Windows-style drive/UNC paths
pub fn normalize_folder_path(raw: &str) -> String {
    let mut s = raw.trim().replace('\\', "/");
    if s.get(..8)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("//?/UNC/"))
    {
        s = format!("//{}", &s[8..]);
    } else if let Some(rest) = s.strip_prefix("//?/") {
        s = rest.to_string();
    }

    while s.len() > 1 && s.ends_with('/') {
        let is_windows_drive_root = s.len() == 3 && s.as_bytes()[1] == b':';
        if is_windows_drive_root {
            break;
        }
        s.pop();
    }

    if s.len() == 2 && s.as_bytes()[0].is_ascii_alphabetic() && s.as_bytes()[1] == b':' {
        s.push('/');
    }

    let is_windows_style =
        cfg!(windows) || s.as_bytes().get(1) == Some(&b':') || s.starts_with("//");
    if is_windows_style {
        s.to_lowercase()
    } else {
        s
    }
}

/// Computes a deterministic, collision-resistant folder ID from a normalized folder path.
pub fn folder_id_for_norm_path(norm_path: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"lumina:folder:");
    hasher.update(norm_path.as_bytes());
    let digest = hasher.finalize();

    let mut hex32 = String::with_capacity(32);
    for byte in &digest[..16] {
        let _ = write!(&mut hex32, "{byte:02x}");
    }
    format!("fld_{hex32}")
}

/// Strips extended-length prefixes (`\\?\`, `\\?\UNC\`, `//?/`, `//?/UNC/`) and
/// trailing separators (preserving `/` and drive roots like `D:\` or `D:/`)
/// while preserving original casing and separator style.
pub(crate) fn clean_display_path(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let uses_backslash = trimmed.contains('\\');
    let mut s = if trimmed
        .get(..8)
        .is_some_and(|p| p.eq_ignore_ascii_case(r"\\?\UNC\") || p.eq_ignore_ascii_case("//?/UNC/"))
    {
        let prefix = if uses_backslash { r"\\" } else { "//" };
        format!("{prefix}{}", &trimmed[8..])
    } else if let Some(rest) = trimmed
        .strip_prefix(r"\\?\")
        .or_else(|| trimmed.strip_prefix("//?/"))
    {
        rest.to_string()
    } else {
        trimmed.to_string()
    };

    while s.len() > 1 && (s.ends_with('/') || s.ends_with('\\')) {
        let is_drive_root = s.len() == 3 && s.as_bytes()[1] == b':';
        if is_drive_root {
            break;
        }
        s.pop();
    }

    if s.len() == 2 && s.as_bytes()[0].is_ascii_alphabetic() && s.as_bytes()[1] == b':' {
        s.push(if uses_backslash { '\\' } else { '/' });
    }

    s
}

/// Extracts `(norm_dir, display_dir)` for the parent directory of a file path.
pub(crate) fn extract_parent_dir(file_path: &str) -> Option<(String, String)> {
    let cleaned = clean_display_path(file_path);
    if cleaned.is_empty() {
        return None;
    }

    let last_sep = cleaned.rfind(['/', '\\'])?;
    let display_dir = if last_sep == 0 {
        cleaned[..1].to_string()
    } else if last_sep == 2 && cleaned.as_bytes().get(1) == Some(&b':') {
        cleaned[..3].to_string()
    } else if (cleaned.starts_with(r"\\") || cleaned.starts_with("//")) && last_sep <= 1 {
        return None;
    } else {
        cleaned[..last_sep].to_string()
    };

    let norm_dir = normalize_folder_path(&display_dir);
    if norm_dir.is_empty() {
        return None;
    }
    Some((norm_dir, display_dir))
}

fn display_name_for_path(display_path: &str, norm_path: &str) -> String {
    if norm_path == "/" {
        return "/".to_string();
    }
    if norm_path.len() == 3 && norm_path.as_bytes()[1] == b':' && norm_path.ends_with('/') {
        return display_path.to_string();
    }
    let trimmed = display_path.trim_end_matches(['/', '\\']);
    if let Some(last) = trimmed
        .rsplit(['/', '\\'])
        .find(|segment| !segment.is_empty())
    {
        return last.to_string();
    }
    display_path.to_string()
}

fn fallback_volume_root(dir_norm: &str, dir_display: &str) -> (String, String) {
    let sep = if dir_display.contains('\\') {
        '\\'
    } else {
        '/'
    };

    // Windows drive path: `c:/...`
    if dir_norm.len() >= 3
        && dir_norm.as_bytes()[0].is_ascii_alphabetic()
        && dir_norm.as_bytes()[1] == b':'
        && dir_norm.as_bytes()[2] == b'/'
    {
        let root_norm = dir_norm[..3].to_string();
        let root_display = if dir_display.len() >= 2 && dir_display.as_bytes()[1] == b':' {
            format!("{}{sep}", &dir_display[..2])
        } else {
            root_norm.clone()
        };
        return (root_norm, root_display);
    }

    // UNC path: `//server/share/...`
    if let Some(rest_norm) = dir_norm.strip_prefix("//") {
        let mut norm_parts = rest_norm.split('/').filter(|p| !p.is_empty());
        if let (Some(server), Some(share)) = (norm_parts.next(), norm_parts.next()) {
            let root_norm = format!("//{server}/{share}");
            let disp_trimmed = dir_display.trim_start_matches(['/', '\\']);
            let mut disp_parts = disp_trimmed.split(['/', '\\']).filter(|p| !p.is_empty());
            let root_display = match (disp_parts.next(), disp_parts.next()) {
                (Some(ds), Some(dsh)) => {
                    if sep == '\\' {
                        format!(r"\\{ds}\{dsh}")
                    } else {
                        format!("//{ds}/{dsh}")
                    }
                }
                _ => root_norm.clone(),
            };
            return (root_norm, root_display);
        }
    }

    // Unix root: `/...`
    if dir_norm.starts_with('/') {
        return ("/".to_string(), "/".to_string());
    }

    // Relative fallback: first segment
    let first_norm = dir_norm.split('/').next().unwrap_or(dir_norm).to_string();
    let first_disp = dir_display
        .split(['/', '\\'])
        .next()
        .unwrap_or(dir_display)
        .to_string();
    (first_norm, first_disp)
}

fn join_norm(base: &str, seg: &str) -> String {
    if base.ends_with('/') {
        format!("{base}{seg}")
    } else {
        format!("{base}/{seg}")
    }
}

fn join_display(base: &str, seg: &str, sep: char) -> String {
    if base.ends_with('/') || base.ends_with('\\') {
        format!("{base}{seg}")
    } else {
        format!("{base}{sep}{seg}")
    }
}

/// Builds the ordered chain of directory nodes from the matching watched root
/// (or fallback volume root) down to `dir_norm`.
pub(crate) fn build_folder_chain(
    dir_norm: &str,
    dir_display: &str,
    roots: &[WatchedRootInfo],
) -> Vec<FolderSegment> {
    let matched_root = roots
        .iter()
        .filter(|r| !r.norm_path.is_empty() && path_in_scope(dir_norm, &r.norm_path))
        .max_by_key(|r| r.norm_path.len());

    let (root_id, base_norm, base_display) = match matched_root {
        Some(r) => (
            Some(r.id.clone()),
            r.norm_path.clone(),
            r.display_path.clone(),
        ),
        None => {
            let (bn, bd) = fallback_volume_root(dir_norm, dir_display);
            (None, bn, bd)
        }
    };

    let sep = if dir_display.contains('\\') || base_display.contains('\\') {
        '\\'
    } else {
        '/'
    };

    let rel_norm_segments: Vec<&str> = if dir_norm == base_norm {
        Vec::new()
    } else {
        let suffix = dir_norm.strip_prefix(&base_norm).unwrap_or("");
        suffix
            .trim_start_matches('/')
            .split('/')
            .filter(|s| !s.is_empty())
            .collect()
    };

    let all_disp_segments: Vec<&str> = dir_display
        .split(['/', '\\'])
        .filter(|s| !s.is_empty())
        .collect();
    let rel_disp_offset = all_disp_segments
        .len()
        .saturating_sub(rel_norm_segments.len());
    let rel_disp_segments = &all_disp_segments[rel_disp_offset..];

    let mut chain = Vec::with_capacity(1 + rel_norm_segments.len());

    let root_folder_id = folder_id_for_norm_path(&base_norm);
    let root_name = display_name_for_path(&base_display, &base_norm);
    chain.push(FolderSegment {
        id: root_folder_id.clone(),
        parent_id: None,
        root_id: root_id.clone(),
        name: root_name,
        norm_path: base_norm.clone(),
        display_path: base_display.clone(),
        depth: 0,
    });

    let mut cur_norm = base_norm;
    let mut cur_display = base_display;
    let mut parent_id = root_folder_id;

    for (idx, norm_seg) in rel_norm_segments.iter().enumerate() {
        let disp_seg = rel_disp_segments.get(idx).copied().unwrap_or(*norm_seg);
        cur_norm = join_norm(&cur_norm, norm_seg);
        cur_display = join_display(&cur_display, disp_seg, sep);
        let id = folder_id_for_norm_path(&cur_norm);
        chain.push(FolderSegment {
            id: id.clone(),
            parent_id: Some(parent_id),
            root_id: root_id.clone(),
            name: disp_seg.to_string(),
            norm_path: cur_norm.clone(),
            display_path: cur_display.clone(),
            depth: (idx + 1) as i64,
        });
        parent_id = id;
    }

    chain
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_folder_path_variants() {
        assert_eq!(
            normalize_folder_path(r"\\?\D:\Music\Jazz\"),
            "d:/music/jazz"
        );
        assert_eq!(
            normalize_folder_path(r"\\?\UNC\NAS\Music\Jazz\"),
            "//nas/music/jazz"
        );
        assert_eq!(normalize_folder_path(r"D:\"), "d:/");
        assert_eq!(normalize_folder_path("D:"), "d:/");
        assert_eq!(normalize_folder_path("/"), "/");
    }

    #[test]
    fn test_extract_parent_dir_windows_and_unix() {
        let (n1, d1) = extract_parent_dir(r"\\?\D:\Music\Miles Davis\01.flac").unwrap();
        assert_eq!(n1, "d:/music/miles davis");
        assert_eq!(d1, r"D:\Music\Miles Davis");

        let (n2, d2) = extract_parent_dir(r"D:\01.flac").unwrap();
        assert_eq!(n2, "d:/");
        assert_eq!(d2, r"D:\");

        let (n3, d3) = extract_parent_dir("/01.flac").unwrap();
        assert_eq!(n3, "/");
        assert_eq!(d3, "/");
    }
}
