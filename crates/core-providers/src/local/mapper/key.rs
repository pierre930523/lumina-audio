use std::path::Path;

use core_db::normalize_match_key;
use unicode_normalization::UnicodeNormalization;

use super::AlbumKey;
use crate::local::metadata::{
    ExtractedMetadata, derive_album_and_artist_from_dir, extract_disc_number_from_dir_name,
};
use crate::local::scanner::normalize_path;

const EDITION_KEYWORDS: &[&str] = &[
    "remaster",
    "remastered",
    "deluxe",
    "super deluxe",
    "anniversary",
    "expanded",
    "special edition",
    "collector",
    "limited",
    "bonus",
    "mono",
    "stereo",
    "hi-res",
    "hires",
    "24-bit",
    "24bit",
    "16-bit",
    "16bit",
    "96khz",
    "192khz",
    "44.1khz",
    "dsd",
    "sacd",
    "mqa",
    "explicit",
    "clean",
    "live",
    "acoustic",
    "edition",
    "version",
    "japan",
    "japanese",
    "uk edition",
    "us edition",
];

fn normalize_key_nfkc(input: &str) -> String {
    let nfkc: String = input.nfkc().collect();
    normalize_match_key(&nfkc)
}

/// Parses a standalone disc designator token such as `Disc 1`, `CD 2`, `CD2`, `Disk 03`,
/// `Part 1`, `Disc 1/2`, `CD 2 of 3`, `第1碟`, `ディスク2`.
/// Rejects non-disc phrases like `Compact Disc`, `Part of Me`, `Disco Classics`, `CD-ROM`.
fn parse_standalone_disc_designator(token: &str) -> Option<u16> {
    let nfkc: String = token.nfkc().collect();
    let trimmed = nfkc.trim();
    if trimmed.is_empty() {
        return None;
    }

    // CJK patterns: "第1碟", "第02張", "碟2", "ディスク1"
    if let Some(rest) = trimmed.strip_prefix('第') {
        if let Some(num_str) = rest
            .strip_suffix('碟')
            .or_else(|| rest.strip_suffix('張'))
            .or_else(|| rest.strip_suffix('张'))
            .or_else(|| rest.strip_suffix('盘'))
            .or_else(|| rest.strip_suffix('盤'))
        {
            if let Ok(n) = num_str.trim().parse::<u16>() {
                return (1..=99).contains(&n).then_some(n);
            }
        }
    }
    for prefix in ["碟", "ディスク"] {
        if let Some(rest) = trimmed.strip_prefix(prefix) {
            let rest = rest.trim_start_matches([' ', '-', '_', '.', '#']);
            if let Ok(n) = rest.parse::<u16>() {
                return (1..=99).contains(&n).then_some(n);
            }
        }
    }

    let lower = trimmed.to_ascii_lowercase();
    let rest = if let Some(r) = lower.strip_prefix("disc") {
        r
    } else if let Some(r) = lower.strip_prefix("disk") {
        r
    } else if let Some(r) = lower.strip_prefix("cd") {
        r
    } else if let Some(r) = lower.strip_prefix("part") {
        // Require a separator or digit immediately after "part" so "partner"/"party" never match
        if r.starts_with(|c: char| c.is_ascii_digit() || matches!(c, ' ' | '-' | '_' | '.' | '#')) {
            r
        } else {
            return None;
        }
    } else {
        let r = lower.strip_prefix("pt")?;
        if r.starts_with(|c: char| c.is_ascii_digit() || matches!(c, ' ' | '-' | '_' | '.' | '#')) {
            r
        } else {
            return None;
        }
    };

    // Must not continue with ASCII letters (rejects "disco", "cd-rom" caught below)
    if rest.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }

    let after_sep = rest.trim_start_matches([' ', '-', '_', '.', '#']);
    let mut digits = String::new();
    let mut rem_idx = 0usize;
    for (idx, ch) in after_sep.char_indices() {
        if ch.is_ascii_digit() {
            digits.push(ch);
            rem_idx = idx + ch.len_utf8();
        } else {
            break;
        }
    }

    if digits.is_empty() {
        return None;
    }

    let tail = after_sep[rem_idx..].trim();
    // Allow empty tail, "/N", "of N" only (so "Part 1 of Me" is rejected!)
    let tail_ok = if tail.is_empty() {
        true
    } else if let Some(den) = tail.strip_prefix('/') {
        let den = den.trim();
        !den.is_empty() && den.chars().all(|c| c.is_ascii_digit())
    } else if let Some(den) = tail.strip_prefix("of ") {
        let den = den.trim();
        !den.is_empty() && den.chars().all(|c| c.is_ascii_digit())
    } else {
        false
    };

    if !tail_ok {
        return None;
    }

    let parsed = digits.parse::<u16>().ok()?;
    (1..=99).contains(&parsed).then_some(parsed)
}

/// Strips a trailing multi-disc designator from an album title (e.g. `(Disc 1)`, `[CD 2]`,
/// `- Disc 2`, `, CD1`, `(Part 1)`) while preserving non-disc titles like `"Compact Disc"` or
/// `"Part of Me"`.
pub fn strip_disc_suffix_from_album(title: &str) -> (String, Option<u16>) {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        return (String::new(), None);
    }

    // 1. Bracketed suffix: "The Wall (Disc 1)", "The Wall [CD 2]", "The Wall (Part 1)"
    let bracket_pair = if trimmed.ends_with(')') {
        trimmed.rfind('(')
    } else if trimmed.ends_with(']') {
        trimmed.rfind('[')
    } else if trimmed.ends_with('）') {
        trimmed.rfind('（')
    } else if trimmed.ends_with('】') {
        trimmed.rfind('【')
    } else {
        None
    };

    if let Some(open_idx) = bracket_pair {
        let open_ch_len = trimmed[open_idx..].chars().next().map_or(1, char::len_utf8);
        let close_ch_len = trimmed.chars().next_back().map_or(1, char::len_utf8);
        let prefix = trimmed[..open_idx].trim();
        let inner = trimmed[open_idx + open_ch_len..trimmed.len() - close_ch_len].trim();
        if !prefix.is_empty() {
            if let Some(disc) = parse_standalone_disc_designator(inner) {
                return (prefix.to_string(), Some(disc));
            }
        }
    }

    // 2. Delimited suffix: "The Wall - Disc 2", "The Wall, CD2", "The Wall: Part 1", "The Wall — CD 1"
    for sep in [" - ", " — ", " – ", ", ", ": "] {
        if let Some(sep_idx) = trimmed.rfind(sep) {
            let prefix = trimmed[..sep_idx].trim();
            let suffix = trimmed[sep_idx + sep.len()..].trim();
            if !prefix.is_empty() {
                if let Some(disc) = parse_standalone_disc_designator(suffix) {
                    return (prefix.to_string(), Some(disc));
                }
            }
        }
    }

    // 3. Space-separated trailing disc designator: "The Wall CD1", "The Wall Disc 2"
    let words: Vec<(usize, &str)> = trimmed
        .split_whitespace()
        .scan(0usize, |pos, w| {
            let rel = trimmed[*pos..].find(w)?;
            let start = *pos + rel;
            *pos = start + w.len();
            Some((start, w))
        })
        .collect();

    if words.len() >= 2 {
        // Check last 2 tokens (e.g., "Disc 2", "CD 1", "Part 2") and last 1 token (e.g., "CD2", "Disc1")
        for take_n in [2usize, 1usize] {
            if words.len() > take_n {
                let start_idx = words[words.len() - take_n].0;
                let prefix = trimmed[..start_idx]
                    .trim_end_matches([' ', '-', ',', ':'])
                    .trim();
                let candidate = trimmed[start_idx..].trim();
                if !prefix.is_empty() {
                    if let Some(disc) = parse_standalone_disc_designator(candidate) {
                        return (prefix.to_string(), Some(disc));
                    }
                }
            }
        }
    }

    (trimmed.to_string(), None)
}

/// Splits trailing edition suffixes such as `(2011 Remaster)` or `[Deluxe Edition]`
/// from an album title while leaving non-edition titles intact.
pub fn extract_edition_label(title: &str) -> (String, Option<String>) {
    let mut current = title.trim().to_string();
    let mut editions: Vec<String> = Vec::new();

    loop {
        let trimmed = current.trim_end();
        let pair = if trimmed.ends_with(')') {
            trimmed.rfind('(').map(|idx| (idx, ')'))
        } else if trimmed.ends_with(']') {
            trimmed.rfind('[').map(|idx| (idx, ']'))
        } else {
            None
        };

        let Some((open_idx, _)) = pair else {
            break;
        };

        let prefix = trimmed[..open_idx].trim();
        if prefix.is_empty() {
            break;
        }

        let inner = trimmed[open_idx + 1..trimmed.len() - 1].trim();
        let inner_lower = inner.to_ascii_lowercase();
        let looks_like_edition = EDITION_KEYWORDS
            .iter()
            .any(|kw| contains_keyword_with_boundary(&inner_lower, kw));

        if !looks_like_edition {
            break;
        }

        editions.push(inner.to_string());
        current = prefix.to_string();
    }

    if editions.is_empty() {
        (title.trim().to_string(), None)
    } else {
        editions.reverse();
        (current, Some(editions.join(" / ")))
    }
}

/// Strips both edition suffixes and multi-disc suffixes in either order, returning
/// `(canonical_base_title, edition_label, inferred_disc)`.
pub(super) fn strip_edition_and_disc_suffixes(
    title: &str,
) -> (String, Option<String>, Option<u16>) {
    let mut current = title.trim().to_string();
    let mut editions: Vec<String> = Vec::new();
    let mut inferred_disc: Option<u16> = None;

    loop {
        let mut changed = false;

        let (after_ed, maybe_ed) = extract_edition_label(&current);
        if let Some(ed) = maybe_ed {
            editions.push(ed);
            current = after_ed;
            changed = true;
        }

        if inferred_disc.is_none() {
            let (after_disc, maybe_disc) = strip_disc_suffix_from_album(&current);
            if let Some(d) = maybe_disc {
                inferred_disc = Some(d);
                current = after_disc;
                changed = true;
            }
        }

        if !changed {
            break;
        }
    }

    let edition = if editions.is_empty() {
        None
    } else {
        editions.reverse();
        Some(editions.join(" / "))
    };

    (current, edition, inferred_disc)
}

pub fn normalize_album_base_title(title: &str) -> String {
    let (base, _, _) = strip_edition_and_disc_suffixes(title);
    normalize_key_nfkc(&base)
}

/// Returns the effective album root directory for `path`, climbing one level up when the
/// immediate parent directory is a multi-disc subfolder (`CD1`, `Disc 2`, `Part 1`, etc.).
pub fn effective_album_dir(path: &Path) -> Option<&Path> {
    let parent = path.parent()?;
    let is_disc_dir = parent
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(extract_disc_number_from_dir_name)
        .is_some();
    if is_disc_dir {
        Some(parent.parent().unwrap_or(parent))
    } else {
        Some(parent)
    }
}

/// Computes the deterministic [`AlbumKey`] used by [`super::AlbumMapper`] and `tag_debug`.
pub fn compute_album_key(meta: &ExtractedMetadata, path: &Path) -> AlbumKey {
    let (album_dir_fallback, artist_dir_fallback) = derive_album_and_artist_from_dir(path);

    let effective_artist = if meta.artist.trim().is_empty() {
        if artist_dir_fallback.trim().is_empty() {
            "Unknown Artist".to_string()
        } else {
            artist_dir_fallback
        }
    } else {
        meta.artist.trim().to_string()
    };

    let effective_album = if meta.album.trim().is_empty() {
        if album_dir_fallback.trim().is_empty() {
            "Unknown Album".to_string()
        } else {
            album_dir_fallback
        }
    } else {
        meta.album.trim().to_string()
    };

    let album_artist_clean = meta
        .album_artist
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    // Priority: ALBUMARTIST > Compilation ("Various Artists") > primary split artist > ARTIST
    let artist_key_raw = if let Some(aa) = album_artist_clean {
        aa.to_string()
    } else if meta.compilation == Some(true) {
        "Various Artists".to_string()
    } else {
        meta.artists
            .first()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or(effective_artist)
    };

    let (base_title, edition_label, inferred_disc_from_title) =
        strip_edition_and_disc_suffixes(&effective_album);
    let canonical_title = if base_title.is_empty() {
        effective_album.clone()
    } else {
        base_title
    };

    let norm_artist = normalize_key_nfkc(&artist_key_raw);
    let norm_album = normalize_key_nfkc(&canonical_title);

    let inferred_disc_from_dir = path
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .and_then(extract_disc_number_from_dir_name)
        .map(|d| d as u16);

    let effective_dir_key = effective_album_dir(path)
        .map(normalize_path)
        .unwrap_or_else(|| "default".to_string());

    // Safety guard: never collapse distinct "Unknown Album" / "Unknown Artist" folders,
    // while keeping multi-disc subfolders (CD1/CD2) of the same untagged album together.
    let is_unknown_fallback = norm_album.is_empty()
        || norm_artist.is_empty()
        || norm_album == "unknown album"
        || norm_artist == "unknown artist";

    let (group_artist_key, group_album_key) = if is_unknown_fallback {
        let dir_for_unknown = effective_album_dir(path)
            .map(normalize_path)
            .unwrap_or_else(|| normalize_path(path));
        (format!("__unknown__:{dir_for_unknown}"), norm_album)
    } else {
        (norm_artist, norm_album)
    };

    let external_album_id = format!("{effective_dir_key}::{group_artist_key}::{group_album_key}");

    AlbumKey {
        group_artist_key,
        group_album_key,
        canonical_title,
        edition_label,
        inferred_disc_from_title,
        inferred_disc_from_dir,
        is_unknown_fallback,
        effective_dir_key,
        external_album_id,
    }
}

fn contains_keyword_with_boundary(haystack: &str, kw: &str) -> bool {
    haystack.match_indices(kw).any(|(start, _)| {
        let before_ok = haystack[..start]
            .chars()
            .next_back()
            .is_none_or(|c| !c.is_alphanumeric());
        let after_ok = haystack[start + kw.len()..]
            .chars()
            .next()
            .is_none_or(|c| !c.is_alphanumeric());
        before_ok && after_ok
    })
}
