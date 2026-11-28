use std::path::Path;

use unicode_normalization::UnicodeNormalization;

use super::ExtractedMetadata;
use crate::local::encoding::sanitize_tag_text;

pub(super) fn fill_opt_str(slot: &mut Option<String>, candidate: Option<String>) {
    if slot.is_none() {
        if let Some(s) = candidate {
            let clean = sanitize_tag_text(&s);
            if !clean.is_empty() {
                *slot = Some(clean);
            }
        }
    }
}

pub(super) fn parse_bool_flag(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" => Some(true),
        "0" | "false" | "no" => Some(false),
        _ => None,
    }
}

pub(crate) fn normalize_custom_tag_key(raw_key: &str) -> String {
    let trimmed = raw_key.trim();
    let tail = trimmed.rsplit(':').next().unwrap_or(trimmed).trim();
    tail.to_ascii_uppercase().replace([' ', '_', '-'], "")
}

pub(super) fn normalize_isrc(raw: &str) -> Option<String> {
    let clean = raw.trim().replace('-', "").to_ascii_uppercase();
    if clean.len() == 12 && clean.chars().all(|c| c.is_ascii_alphanumeric()) {
        Some(clean)
    } else {
        None
    }
}

pub(super) fn normalize_upc(raw: &str) -> Option<String> {
    let clean: String = raw
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    if clean.is_empty() { None } else { Some(clean) }
}

pub fn derive_title_and_track_from_filename(path: &Path) -> (String, u16) {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Unknown Title");

    let trimmed = stem.trim();
    if trimmed.is_empty() {
        return ("Unknown Title".to_string(), 1);
    }

    // Purely numeric stem (e.g. "1999" or "2001") is the title itself, not a track number!
    if trimmed.chars().all(|c| c.is_ascii_digit()) {
        return (trimmed.to_string(), 1);
    }

    let mut num_str = String::new();
    let mut rest = trimmed;

    for (idx, ch) in trimmed.char_indices() {
        if ch.is_ascii_digit() && num_str.len() < 3 {
            num_str.push(ch);
        } else {
            rest = &trimmed[idx..];
            break;
        }
    }

    let track_num = num_str.parse::<u16>().unwrap_or(1).max(1);

    let clean_title = rest
        .trim_start_matches(|c: char| c == '-' || c == '.' || c == '_' || c.is_whitespace())
        .trim();

    let final_title = if clean_title.trim().is_empty() {
        trimmed.to_string()
    } else {
        clean_title.to_string()
    };

    let final_title = if final_title.trim().is_empty() {
        "Unknown Title".to_string()
    } else {
        final_title
    };

    (final_title, track_num)
}

/// Splits multi-artist tag strings on `;`, ` / `, ` feat. `, ` ft. `, and ` featuring `
/// while preserving order and deduplicating case-insensitively.
pub fn split_artists(raw: &str) -> Vec<String> {
    let mut out = Vec::new();
    append_split_artists(&mut out, raw);
    out
}

pub(super) fn append_split_artists(out: &mut Vec<String>, raw: &str) {
    let mut segments = vec![raw.to_string()];

    // Split on ';' and " / "
    for delim in [";", " / "] {
        let mut next = Vec::new();
        for seg in segments {
            for part in seg.split(delim) {
                next.push(part.to_string());
            }
        }
        segments = next;
    }

    // Case-insensitive split on " featuring ", " feat. ", " feat ", " ft. ", " ft " (including paren/bracket forms)
    for prefix in [" (", " [", " "] {
        for kw in ["featuring ", "feat. ", "feat ", "ft. ", "ft "] {
            let needle = format!("{prefix}{kw}");
            let mut next = Vec::new();
            for seg in segments {
                split_case_insensitive_into(&seg, &needle, &mut next);
            }
            segments = next;
        }
    }

    for seg in segments {
        let cleaned = strip_outer_and_unbalanced_brackets(&seg);
        if cleaned.is_empty() {
            continue;
        }
        if !out
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(cleaned))
        {
            out.push(cleaned.to_string());
        }
    }
}

fn strip_outer_and_unbalanced_brackets(input: &str) -> &str {
    let mut s = input.trim();
    loop {
        let before = s;
        for (open, close) in [('(', ')'), ('[', ']')] {
            if is_single_enclosed_pair(s, open, close) {
                s = s[open.len_utf8()..s.len() - close.len_utf8()].trim();
            }
            let opens = s.chars().filter(|&c| c == open).count();
            let closes = s.chars().filter(|&c| c == close).count();
            let unmatched = (opens > closes)
                .then_some(open)
                .or((closes > opens).then_some(close));
            if let Some(ch) = unmatched {
                s = s
                    .strip_suffix(ch)
                    .or_else(|| s.strip_prefix(ch))
                    .unwrap_or(s)
                    .trim();
            }
        }
        if s == before {
            return s;
        }
    }
}

fn is_single_enclosed_pair(s: &str, open: char, close: char) -> bool {
    if !(s.starts_with(open) && s.ends_with(close)) {
        return false;
    }
    let (mut depth, last_idx) = (0usize, s.len() - close.len_utf8());
    for (idx, ch) in s.char_indices() {
        if ch == open {
            depth += 1;
        } else if ch == close {
            depth = depth.checked_sub(1).unwrap_or(usize::MAX);
            if depth == usize::MAX || (depth == 0 && idx < last_idx) {
                return false;
            }
        }
    }
    depth == 0
}

fn split_case_insensitive_into(input: &str, needle_lower: &str, out: &mut Vec<String>) {
    let lower = input.to_ascii_lowercase();
    let mut start = 0usize;
    let nlen = needle_lower.len();
    while let Some(rel) = lower[start..].find(needle_lower) {
        let idx = start + rel;
        out.push(input[start..idx].to_string());
        start = idx + nlen;
    }
    out.push(input[start..].to_string());
}

/// Extracts an explicit disc number from multi-disc subfolder names such as
/// `CD1`, `CD 2`, `CD-02`, `CD1 - Bonus`, `Disc 1`, `Disc 2 (Acoustic)`, `Disk 03`,
/// `Part 1`, `Pt. 2`, `D1`, `ＣＤ１`, `第1碟`, `ディスク2`.
///
/// Strictly rejects non-disc folder names such as `"Disco Classics"`, `"CD-ROM"`, `"Partner"`.
pub fn extract_disc_number_from_dir_name(name: &str) -> Option<u32> {
    let nfkc: String = name.nfkc().collect();
    let trimmed = nfkc.trim();
    if trimmed.is_empty() {
        return None;
    }

    // CJK patterns: "第1碟", "第02張", "碟2", "ディスク1"
    if let Some(rest) = trimmed.strip_prefix('第') {
        for suffix in ['碟', '張', '张', '盘', '盤'] {
            if let Some(pos) = rest.find(suffix) {
                let num_part = rest[..pos].trim();
                let after = rest[pos + suffix.len_utf8()..].trim();
                let after_ok =
                    after.is_empty() || after.starts_with([' ', '-', '_', '(', '[', '（', '【']);
                if after_ok {
                    if let Ok(n) = num_part.parse::<u32>() {
                        return (1..=99).contains(&n).then_some(n);
                    }
                }
            }
        }
    }
    for prefix in ["碟", "ディスク"] {
        if let Some(rest) = trimmed.strip_prefix(prefix) {
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
            if !digits.is_empty() {
                let tail = &after_sep[rem_idx..];
                if tail.is_empty() || tail.starts_with([' ', '-', '_', '(', '[', '（', '【']) {
                    if let Ok(n) = digits.parse::<u32>() {
                        return (1..=99).contains(&n).then_some(n);
                    }
                }
            }
        }
    }

    let lower = trimmed.to_ascii_lowercase();
    let (rest, allow_subtitle) = if let Some(r) = lower.strip_prefix("disc") {
        (r, true)
    } else if let Some(r) = lower.strip_prefix("disk") {
        (r, true)
    } else if let Some(r) = lower.strip_prefix("cd") {
        (r, true)
    } else if let Some(r) = lower.strip_prefix("part") {
        // Must have digit or separator after "part" so "Partner" / "Party" return None
        if r.starts_with(|c: char| c.is_ascii_digit() || matches!(c, ' ' | '-' | '_' | '.' | '#')) {
            (r, true)
        } else {
            return None;
        }
    } else if let Some(r) = lower.strip_prefix("pt") {
        if r.starts_with(|c: char| c.is_ascii_digit() || matches!(c, ' ' | '-' | '_' | '.' | '#')) {
            (r, true)
        } else {
            return None;
        }
    } else {
        let r = lower.strip_prefix('d')?;
        // Only allow strict short form like "D1", "D02", "D-1", "D 2" (no arbitrary subtitle)
        if r.starts_with(|c: char| c.is_ascii_digit() || matches!(c, ' ' | '-' | '_')) {
            (r, false)
        } else {
            return None;
        }
    };

    // Reject if prefix continues directly with ASCII letters (e.g. "Disco Classics")
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

    let tail = &after_sep[rem_idx..];
    if !tail.is_empty() {
        if !allow_subtitle {
            return None;
        }
        // Only allow a clear separator before optional subtitle/total (e.g. "CD1 - Bonus",
        // "Disc 2 (Acoustic)", "Part 1/2", "CD 1 [Main]"). Rejects "CD1a", "CD-ROM".
        let valid_tail = tail.starts_with([' ', '-', '_', '(', '[', '/', ',', ':']);
        if !valid_tail {
            return None;
        }
    }

    let parsed = digits.parse::<u32>().ok()?;
    (1..=99).contains(&parsed).then_some(parsed)
}

pub(super) fn disc_number_from_parent_dir(path: &Path) -> Option<u16> {
    let parent_name = path.parent()?.file_name()?.to_str()?;
    extract_disc_number_from_dir_name(parent_name).map(|d| d as u16)
}

/// Detects replacement-character mojibake (`\u{FFFD}`), C1 control bytes (`U+0080..=U+009F`),
/// or unexpected ASCII control characters in extracted tag strings so callers can record a
/// `SkipReason::GarbledTags` warning.
pub fn detect_garbled_tags(meta: &ExtractedMetadata) -> Option<String> {
    let fields: [(&str, Option<&str>); 6] = [
        ("title", Some(meta.title.as_str())),
        ("artist", Some(meta.artist.as_str())),
        ("album", Some(meta.album.as_str())),
        ("album_artist", meta.album_artist.as_deref()),
        ("genre", meta.genre.as_deref()),
        ("composer", meta.composer.as_deref()),
    ];

    for (field, val_opt) in fields {
        if let Some(val) = val_opt {
            if val.contains('\u{FFFD}') {
                return Some(format!(
                    "Field '{field}' contains Unicode replacement character (possible mojibake)"
                ));
            }
            if val.chars().any(|c| (0x80..=0x9F).contains(&(c as u32))) {
                return Some(format!(
                    "Field '{field}' contains C1 control codepoints (possible unrecovered Latin-1 mojibake)"
                ));
            }
            if val
                .chars()
                .any(|c| (c as u32) < 0x20 && !matches!(c, '\t' | '\n' | '\r'))
            {
                return Some(format!(
                    "Field '{field}' contains unexpected ASCII control characters"
                ));
            }
        }
    }
    None
}

pub fn is_generic_directory_name(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.len() == 4 && trimmed.chars().all(|c| c.is_ascii_digit()) {
        if let Ok(year) = trimmed.parse::<u16>() {
            if (1900..=2100).contains(&year) {
                return true;
            }
        }
    }
    let lower = trimmed.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "" | "music"
            | "mymusic"
            | "my music"
            | "music library"
            | "itunes"
            | "itunes media"
            | "media"
            | "library"
            | "desktop"
            | "downloads"
            | "download"
            | "documents"
            | "mydocuments"
            | "my documents"
            | "flac"
            | "alac"
            | "wav"
            | "aiff"
            | "dsd"
            | "sacd"
            | "mp3"
            | "m4a"
            | "aac"
            | "ogg"
            | "opus"
            | "lossless"
            | "hi-res"
            | "hires"
            | "audio"
            | "sound"
            | "tracks"
            | "songs"
            | "album"
            | "albums"
            | "artist"
            | "artists"
            | "cd"
            | "cds"
            | "rip"
            | "rips"
            | "vinyl"
            | "singles"
            | "compilations"
            | "soundtracks"
            | "ost"
            | "various"
            | "various artists"
            | "unknown"
            | "unknown artist"
            | "unknown album"
            | "users"
            | "user"
            | "home"
            | "new folder"
            | "temp"
            | "tmp"
            | "misc"
            | "other"
            | "音乐"
            | "音樂"
            | "无损"
            | "無損"
            | "無损"
            | "无损音乐"
            | "無損音樂"
            | "本地音乐"
            | "本地音樂"
            | "下载"
            | "下載"
            | "专辑"
            | "專輯"
            | "歌手"
            | "新建文件夹"
            | "新建資料夾"
    ) || extract_disc_number_from_dir_name(name).is_some()
}

pub fn derive_album_and_artist_from_dir(path: &Path) -> (String, String) {
    let parent = path.parent();
    let mut album_dir = parent
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("");
    let mut artist_dir = parent
        .and_then(|p| p.parent())
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("");

    // Detect multi-disc subfolders (CD1, Disc 2, Disk 02, Part 1, etc.) without false-matching "Disco Classics"
    if extract_disc_number_from_dir_name(album_dir).is_some() {
        album_dir = artist_dir;
        artist_dir = parent
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
    }

    let album_name = if album_dir.trim().is_empty() || is_generic_directory_name(album_dir) {
        "Unknown Album".to_string()
    } else {
        sanitize_tag_text(album_dir)
    };

    let artist_name = if artist_dir.trim().is_empty() || is_generic_directory_name(artist_dir) {
        "Unknown Artist".to_string()
    } else {
        sanitize_tag_text(artist_dir)
    };

    (album_name, artist_name)
}
