use std::path::Path;

use super::models::{
    LyricLine, LyricWord, LyricsFormat, LyricsKind, LyricsManager, LyricsResult, LyricsSource,
};
use super::ttml_parser::is_ttml_content;

impl LyricsManager {
    /// Decodes byte content using BOM or CJK heuristic detection, then parses lyrics.
    pub fn parse_lyrics_bytes(
        bytes: &[u8],
        path: &Path,
        source: LyricsSource,
    ) -> Option<LyricsResult> {
        if bytes.is_empty() {
            return None;
        }

        let decoded = decode_text_cjk(bytes);
        if decoded.trim().is_empty() {
            return None;
        }

        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();

        if ext == "ttml" || is_ttml_content(&decoded) {
            if let Some(res) = Self::parse_ttml(&decoded, source) {
                return Some(res);
            }
        }

        if ext == "txt" && source != LyricsSource::UserFile {
            return Self::parse_plain_text(&decoded, source);
        }

        // If it contains timestamp pattern [mm:ss, parse as LRC / Enhanced LRC
        if is_lrc_content(&decoded) {
            Self::parse_lrc(&decoded, source)
        } else {
            Self::parse_plain_text(&decoded, source)
        }
    }

    /// Parses string content directly.
    pub fn parse_lyrics_str(content: &str, source: LyricsSource) -> Option<LyricsResult> {
        let trimmed = content.trim();
        if trimmed.is_empty() {
            return None;
        }

        if is_ttml_content(trimmed) {
            if let Some(res) = Self::parse_ttml(trimmed, source) {
                return Some(res);
            }
        }
        if is_lrc_content(trimmed) {
            Self::parse_lrc(trimmed, source)
        } else {
            Self::parse_plain_text(trimmed, source)
        }
    }

    /// Parses standard LRC and Enhanced LRC (`<mm:ss.xx>`) format.
    pub fn parse_lrc(content: &str, source: LyricsSource) -> Option<LyricsResult> {
        let mut offset_ms = 0i64;
        let mut parsed_lines: Vec<(i64, String, Vec<LyricWord>)> = Vec::new();
        let mut has_enhanced_words = false;

        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            // Check metadata tags e.g. [offset:+500] or [offset:-200]
            if let Some(rest) = trimmed.strip_prefix("[offset:") {
                if let Some(val_str) = rest.strip_suffix(']') {
                    if let Ok(val) = val_str.trim().parse::<i64>() {
                        offset_ms = val;
                    }
                }
                continue;
            }

            // Other header tags: [ti:...], [ar:...], [al:...], [by:...], etc.
            if trimmed.starts_with('[')
                && !trimmed
                    .as_bytes()
                    .get(1)
                    .is_some_and(|b| b.is_ascii_digit())
            {
                if let Some(close_idx) = trimmed.find(']') {
                    let tag_name = &trimmed[1..close_idx];
                    if tag_name.starts_with("ti:")
                        || tag_name.starts_with("ar:")
                        || tag_name.starts_with("al:")
                        || tag_name.starts_with("by:")
                        || tag_name.starts_with("length:")
                        || tag_name.starts_with("re:")
                        || tag_name.starts_with("ve:")
                    {
                        continue;
                    }
                }
            }

            // Extract all leading timestamp tags: e.g. [01:23.45][02:34.56]Text
            let mut timestamps = Vec::new();
            let mut cur = trimmed;

            while cur.starts_with('[') {
                if let Some(end_bracket) = cur.find(']') {
                    let tag_content = &cur[1..end_bracket];
                    if let Some(ts_ms) = parse_lrc_timestamp(tag_content) {
                        timestamps.push(ts_ms);
                        cur = &cur[end_bracket + 1..];
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }

            if timestamps.is_empty() {
                continue;
            }

            let text_part = cur.trim();
            let (clean_text, words) = parse_enhanced_lrc_words(text_part);
            if !words.is_empty() {
                has_enhanced_words = true;
            }

            for ts in timestamps {
                parsed_lines.push((ts, clean_text.clone(), words.clone()));
            }
        }

        if parsed_lines.is_empty() {
            // If timestamps could not be extracted but non-empty lines exist, fall back to plain
            return Self::parse_plain_text(content, source);
        }

        // Sort lines chronologically
        parsed_lines.sort_by_key(|&(ts, _, _)| ts);

        // Apply offset: clamp start_ms >= 0
        let mut lines = Vec::with_capacity(parsed_lines.len());
        for i in 0..parsed_lines.len() {
            let (raw_start, ref text, ref raw_words) = parsed_lines[i];
            let start_ms = (raw_start + offset_ms).max(0) as u64;

            let end_ms = if i + 1 < parsed_lines.len() {
                let next_start = (parsed_lines[i + 1].0 + offset_ms).max(0) as u64;
                Some(next_start.max(start_ms))
            } else {
                None
            };

            // Adjust word timestamps with offset
            let mut words = Vec::with_capacity(raw_words.len());
            for w in raw_words {
                let w_start = (w.start_ms as i64 + offset_ms).max(0) as u64;
                let w_end = (w.end_ms as i64 + offset_ms).max(0) as u64;
                words.push(LyricWord {
                    text: w.text.clone(),
                    start_ms: w_start,
                    end_ms: w_end.max(w_start),
                });
            }

            lines.push(LyricLine {
                start_ms: Some(start_ms),
                end_ms,
                text: text.clone(),
                words,
            });
        }

        let format = if has_enhanced_words {
            LyricsFormat::EnhancedLrc
        } else {
            LyricsFormat::Lrc
        };

        Some(LyricsResult {
            found: true,
            kind: LyricsKind::Synced,
            source,
            format,
            offset_ms,
            lines,
        })
    }

    /// Parses unsynchronized plain text lyrics.
    pub fn parse_plain_text(content: &str, source: LyricsSource) -> Option<LyricsResult> {
        let lines: Vec<LyricLine> = content
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .map(|text| LyricLine {
                start_ms: None,
                end_ms: None,
                text,
                words: Vec::new(),
            })
            .collect();

        if lines.is_empty() {
            return None;
        }

        Some(LyricsResult {
            found: true,
            kind: LyricsKind::Unsynced,
            source,
            format: LyricsFormat::Plain,
            offset_ms: 0,
            lines,
        })
    }
}

pub(super) fn is_lrc_content(s: &str) -> bool {
    let mut count = 0;
    for line in s.lines().take(10) {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            if let Some(close) = trimmed.find(']') {
                let tag = &trimmed[1..close];
                if parse_lrc_timestamp(tag).is_some() || tag.starts_with("offset:") {
                    count += 1;
                }
            }
        }
    }
    count > 0
}

/// Parses timestamp tag `mm:ss.xx` or `mm:ss.xxx` or `mm:ss` into milliseconds.
fn parse_lrc_timestamp(tag: &str) -> Option<i64> {
    let parts: Vec<&str> = tag.split(':').collect();
    if parts.len() != 2 {
        return None;
    }
    let mins = parts[0].trim().parse::<i64>().ok()?;
    let sec_parts: Vec<&str> = parts[1].split('.').collect();
    if sec_parts.is_empty() || sec_parts.len() > 2 {
        return None;
    }
    let secs = sec_parts[0].trim().parse::<i64>().ok()?;

    let ms = if sec_parts.len() == 2 {
        let frac_str = sec_parts[1].trim();
        if frac_str.is_empty() {
            0
        } else if frac_str.len() == 1 {
            frac_str.parse::<i64>().ok()? * 100
        } else if frac_str.len() == 2 {
            frac_str.parse::<i64>().ok()? * 10
        } else {
            let sub = &frac_str[..3.min(frac_str.len())];
            let val = sub.parse::<i64>().ok()?;
            match sub.len() {
                1 => val * 100,
                2 => val * 10,
                _ => val,
            }
        }
    } else {
        0
    };

    Some(mins * 60_000 + secs * 1_000 + ms)
}

/// Parses Enhanced LRC words within a line: `<00:01.00>word <00:01.50>word2`
fn parse_enhanced_lrc_words(text: &str) -> (String, Vec<LyricWord>) {
    if !text.contains('<') || !text.contains('>') {
        return (text.to_string(), Vec::new());
    }

    let mut words = Vec::new();
    let mut clean_text = String::new();
    let mut cur = text;

    let mut current_start_ms: Option<u64> = None;
    let mut current_word_text = String::new();

    while !cur.is_empty() {
        if let Some(open) = cur.find('<') {
            let before = &cur[..open];
            if !before.is_empty() {
                clean_text.push_str(before);
                current_word_text.push_str(before);
            }
            if let Some(close) = cur[open..].find('>') {
                let tag = &cur[open + 1..open + close];
                if let Some(ts) = parse_lrc_timestamp(tag) {
                    let ts_u64 = ts.max(0) as u64;
                    if let Some(start) = current_start_ms {
                        let w_text = current_word_text.trim().to_string();
                        if !w_text.is_empty() {
                            words.push(LyricWord {
                                text: w_text,
                                start_ms: start,
                                end_ms: ts_u64.max(start),
                            });
                        }
                    }
                    current_start_ms = Some(ts_u64);
                    current_word_text.clear();
                } else {
                    clean_text.push_str(&cur[open..=open + close]);
                    current_word_text.push_str(&cur[open..=open + close]);
                }
                cur = &cur[open + close + 1..];
            } else {
                clean_text.push_str(&cur[open..]);
                current_word_text.push_str(&cur[open..]);
                break;
            }
        } else {
            clean_text.push_str(cur);
            current_word_text.push_str(cur);
            break;
        }
    }

    if let Some(start) = current_start_ms {
        let w_text = current_word_text.trim().to_string();
        if !w_text.is_empty() {
            let end = start + 300;
            words.push(LyricWord {
                text: w_text,
                start_ms: start,
                end_ms: end,
            });
        }
    }

    // Set end_ms of words from subsequent word start
    for i in 0..words.len().saturating_sub(1) {
        let next_start = words[i + 1].start_ms;
        if words[i].end_ms < next_start {
            words[i].end_ms = next_start;
        }
    }

    let final_clean = if clean_text.trim().is_empty() {
        text.to_string()
    } else {
        clean_text.trim().to_string()
    };

    (final_clean, words)
}

/// Decodes byte array into a String, handling UTF-8 (with/without BOM), UTF-16,
/// legacy CJK encodings (GBK, Big5, Shift-JIS, EUC-KR), and Western Windows-1252.
pub fn decode_text_cjk(bytes: &[u8]) -> String {
    crate::local::encoding::decode_text_cjk(bytes)
}
