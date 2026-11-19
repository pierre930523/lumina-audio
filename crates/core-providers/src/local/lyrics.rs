use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use encoding_rs::{BIG5, GBK, SHIFT_JIS, UTF_16BE, UTF_16LE, UTF_8};
use serde::{Deserialize, Serialize};

use crate::error::ProviderError;

/// Format of the parsed lyrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LyricsFormat {
    Lrc,
    EnhancedLrc,
    Plain,
}

/// Synchronization kind matching Interface Contract #3.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LyricsKind {
    Synced,
    Unsynced,
    None,
}

/// Source origin of the lyrics matching Interface Contract #3.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LyricsSource {
    UserFile,
    EmbeddedSynced,
    SidecarLrc,
    EmbeddedUnsynced,
    SidecarTxt,
    None,
}

/// Word-level timing metadata for Enhanced LRC.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricWord {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// Line-level lyrics entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricLine {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_ms: Option<u64>,
    pub text: String,
    #[serde(default)]
    pub words: Vec<LyricWord>,
}

/// Exact JSON-serializable output struct matching Interface Contract #3.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricsResult {
    pub found: bool,
    pub kind: LyricsKind,
    pub source: LyricsSource,
    pub format: LyricsFormat,
    pub offset_ms: i64,
    pub lines: Vec<LyricLine>,
}

impl Default for LyricsResult {
    fn default() -> Self {
        Self::empty()
    }
}

impl LyricsResult {
    pub fn empty() -> Self {
        Self {
            found: false,
            kind: LyricsKind::None,
            source: LyricsSource::None,
            format: LyricsFormat::Plain,
            offset_ms: 0,
            lines: Vec::new(),
        }
    }
}

/// Target selector for lyrics queries and user overrides.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct LyricsTarget {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
}

pub struct LyricsManager;

impl LyricsManager {
    /// Loads lyrics for a given file and optional DB pool, following the strict priority chain:
    /// 1. User-specified file override (app_preferences DB table or explicit override path)
    /// 2. Embedded synchronized lyrics (MP3 SYLT, FLAC/Ogg SYNCEDLYRICS)
    /// 3. Same-name `.lrc` sidecar
    /// 4. Embedded unsynchronized lyrics (MP3 USLT, FLAC/Ogg LYRICS / UNSYNCEDLYRICS, MP4 ©lyr, WAV id3 chunk)
    /// 5. Same-name `.txt` sidecar
    /// 6. None (clean empty state)
    pub async fn get_lyrics(
        target: &LyricsTarget,
        pool: Option<&core_db::SqlitePool>,
    ) -> LyricsResult {
        // Resolve target file path and track id
        let (file_path_buf, track_id) = Self::resolve_target(target, pool).await;

        // 1. Check user override
        if let Some(user_override_path) = Self::get_user_override(target, pool).await {
            let p = Path::new(&user_override_path);
            if p.is_file() {
                if let Ok(bytes) = std::fs::read(p) {
                    if let Some(res) = Self::parse_lyrics_bytes(&bytes, p, LyricsSource::UserFile) {
                        return res;
                    }
                }
            }
        }

        let Some(path) = file_path_buf else {
            return LyricsResult::empty();
        };

        if !path.is_file() {
            return LyricsResult::empty();
        }

        // Extract embedded lyrics read-only without modifying PCM
        let embedded = Self::extract_embedded_lyrics(&path);

        // 2. Embedded synchronized lyrics
        if let Some(ref emb_synced) = embedded.synced {
            if let Some(res) = Self::parse_lyrics_str(emb_synced, LyricsSource::EmbeddedSynced) {
                if res.found {
                    return res;
                }
            }
        }

        // 3. Same-name .lrc sidecar
        let lrc_path = path.with_extension("lrc");
        if lrc_path.is_file() {
            if let Ok(bytes) = std::fs::read(&lrc_path) {
                if let Some(res) = Self::parse_lyrics_bytes(&bytes, &lrc_path, LyricsSource::SidecarLrc) {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        // Also check .LRC uppercase
        let lrc_upper = path.with_extension("LRC");
        if lrc_upper != lrc_path && lrc_upper.is_file() {
            if let Ok(bytes) = std::fs::read(&lrc_upper) {
                if let Some(res) = Self::parse_lyrics_bytes(&bytes, &lrc_upper, LyricsSource::SidecarLrc) {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        // 4. Embedded unsynchronized lyrics (or database cached embedded_lyrics)
        if let Some(ref emb_unsynced) = embedded.unsynced {
            if let Some(res) = Self::parse_lyrics_str(emb_unsynced, LyricsSource::EmbeddedUnsynced) {
                if res.found {
                    return res;
                }
            }
        }

        // Fallback: DB embedded_lyrics cache if track_id is known
        if let (Some(p), Some(tid)) = (pool, track_id.as_deref()) {
            if let Ok(Some(db_lyrics)) = core_db::LibraryRepository::get_track_embedded_lyrics(p, tid).await {
                if !db_lyrics.trim().is_empty() {
                    let source = if db_lyrics.contains('[') && db_lyrics.contains(']') {
                        LyricsSource::EmbeddedSynced
                    } else {
                        LyricsSource::EmbeddedUnsynced
                    };
                    if let Some(res) = Self::parse_lyrics_str(&db_lyrics, source) {
                        if res.found {
                            return res;
                        }
                    }
                }
            }
        }

        // 5. Same-name .txt sidecar
        let txt_path = path.with_extension("txt");
        if txt_path.is_file() {
            if let Ok(bytes) = std::fs::read(&txt_path) {
                if let Some(res) = Self::parse_lyrics_bytes(&bytes, &txt_path, LyricsSource::SidecarTxt) {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        let txt_upper = path.with_extension("TXT");
        if txt_upper != txt_path && txt_upper.is_file() {
            if let Ok(bytes) = std::fs::read(&txt_upper) {
                if let Some(res) = Self::parse_lyrics_bytes(&bytes, &txt_upper, LyricsSource::SidecarTxt) {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        // 6. None
        LyricsResult::empty()
    }

    /// Sets a user lyrics file override for a track or file path.
    pub async fn set_user_override(
        target: &LyricsTarget,
        file_path: &str,
        pool: &core_db::SqlitePool,
    ) -> Result<(), ProviderError> {
        let key = Self::override_pref_key(target, pool).await;
        core_db::LibraryRepository::set_preference(pool, &key, file_path)
            .await
            .map_err(|e| ProviderError::Other(e.to_string()))?;
        Ok(())
    }

    /// Clears any user lyrics file override for a track or file path.
    pub async fn clear_user_override(
        target: &LyricsTarget,
        pool: &core_db::SqlitePool,
    ) -> Result<bool, ProviderError> {
        let key = Self::override_pref_key(target, pool).await;
        let existed = core_db::LibraryRepository::get_preference(pool, &key)
            .await
            .map_err(|e| ProviderError::Other(e.to_string()))?
            .is_some();
        if existed {
            // Delete preference by setting empty or deleting
            sqlx::query("DELETE FROM app_preferences WHERE key = ?")
                .bind(&key)
                .execute(pool)
                .await
                .map_err(|e| ProviderError::Other(e.to_string()))?;
        }
        Ok(existed)
    }

    async fn get_user_override(
        target: &LyricsTarget,
        pool: Option<&core_db::SqlitePool>,
    ) -> Option<String> {
        let pool = pool?;
        let key = Self::override_pref_key(target, pool).await;
        core_db::LibraryRepository::get_preference(pool, &key)
            .await
            .ok()
            .flatten()
            .filter(|s| !s.trim().is_empty())
    }

    async fn override_pref_key(
        target: &LyricsTarget,
        pool: &core_db::SqlitePool,
    ) -> String {
        if let Some(ref tid) = target.track_id {
            if !tid.trim().is_empty() {
                return format!("lyrics_override:track:{}", tid.trim());
            }
        }
        if let Some(ref fp) = target.file_path {
            // Try resolving track ID from DB first
            if let Ok(Some(track)) = core_db::LibraryRepository::get_track_file_cache_info(pool, "local", fp).await {
                return format!("lyrics_override:track:{}", track.track_id);
            }
            return format!("lyrics_override:path:{}", normalize_path(fp));
        }
        "lyrics_override:unknown".to_string()
    }

    async fn resolve_target(
        target: &LyricsTarget,
        pool: Option<&core_db::SqlitePool>,
    ) -> (Option<PathBuf>, Option<String>) {
        if let Some(ref fp) = target.file_path {
            let p = PathBuf::from(fp);
            let tid = target.track_id.clone();
            return (Some(p), tid);
        }

        if let (Some(tid), Some(p)) = (&target.track_id, pool) {
            if let Ok(Some(ts)) = core_db::LibraryRepository::find_track_source_by_id(p, tid).await {
                return (Some(PathBuf::from(ts.external_track_id)), Some(tid.clone()));
            }
        }

        (None, target.track_id.clone())
    }

    /// Decodes byte content using BOM or CJK heuristic detection, then parses lyrics.
    pub fn parse_lyrics_bytes(bytes: &[u8], path: &Path, source: LyricsSource) -> Option<LyricsResult> {
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
                && !trimmed.as_bytes().get(1).is_some_and(|b| b.is_ascii_digit())
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

    /// Extracts embedded lyrics from an audio file read-only.
    fn extract_embedded_lyrics(path: &Path) -> EmbeddedLyricsPair {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();

        match ext.as_str() {
            "flac" => extract_flac_embedded(path),
            "mp3" => extract_mp3_embedded(path),
            "m4a" | "mp4" | "aac" => extract_m4a_embedded(path),
            "wav" | "wave" => extract_wav_embedded(path),
            "ogg" | "opus" => extract_ogg_embedded(path),
            _ => EmbeddedLyricsPair::default(),
        }
    }
}

#[derive(Default)]
struct EmbeddedLyricsPair {
    synced: Option<String>,
    unsynced: Option<String>,
}

fn is_lrc_content(s: &str) -> bool {
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
/// and legacy CJK encodings (GBK, Big5, Shift-JIS).
pub fn decode_text_cjk(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }

    // 1. Check BOM
    if bytes.len() >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
        return String::from_utf8_lossy(&bytes[3..]).to_string();
    }
    if bytes.len() >= 2 {
        if bytes[0] == 0xFF && bytes[1] == 0xFE {
            let (cow, _, _) = UTF_16LE.decode(&bytes[2..]);
            return cow.into_owned();
        } else if bytes[0] == 0xFE && bytes[1] == 0xFF {
            let (cow, _, _) = UTF_16BE.decode(&bytes[2..]);
            return cow.into_owned();
        }
    }

    // 2. Strict UTF-8 check
    if let Ok(valid_utf8) = std::str::from_utf8(bytes) {
        return valid_utf8.to_string();
    }

    // 3. Fallback heuristic for GBK vs Big5 vs Shift-JIS
    let (s_gbk, _, err_gbk) = GBK.decode(bytes);
    let (s_big5, _, err_big5) = BIG5.decode(bytes);
    let (s_sjis, _, err_sjis) = SHIFT_JIS.decode(bytes);

    if !err_gbk && err_big5 && err_sjis {
        return s_gbk.into_owned();
    }
    if !err_big5 && err_gbk && err_sjis {
        return s_big5.into_owned();
    }
    if !err_sjis && err_gbk && err_big5 {
        return s_sjis.into_owned();
    }

    // Score CJK candidate frequency
    let score_gbk = score_cjk_candidate(bytes, &s_gbk, "gbk");
    let score_big5 = score_cjk_candidate(bytes, &s_big5, "big5");
    let score_sjis = score_cjk_candidate(bytes, &s_sjis, "shift_jis");

    if score_sjis > score_gbk && score_sjis > score_big5 {
        return s_sjis.into_owned();
    }
    if score_big5 > score_gbk {
        return s_big5.into_owned();
    }
    if score_gbk > 0 {
        return s_gbk.into_owned();
    }

    // Final fallback: lossy UTF-8
    let (cow, _, _) = UTF_8.decode(bytes);
    cow.into_owned()
}

fn score_cjk_candidate(bytes: &[u8], decoded: &str, encoding: &str) -> usize {
    let mut score = 0usize;
    let err_count = decoded.chars().filter(|&c| c == '\u{FFFD}').count();
    let total_chars = decoded.chars().count();
    if total_chars == 0 {
        return 0;
    }
    if err_count > 0 {
        return 0;
    }

    match encoding {
        "shift_jis" => {
            for c in decoded.chars() {
                let u = c as u32;
                // Hiragana: 0x3040..=0x309F, Katakana: 0x30A0..=0x30FF
                if (0x3040..=0x30FF).contains(&u) {
                    score += 15;
                }
            }
            // Check SJIS lead byte 0x82 / 0x83
            for w in bytes.windows(2) {
                if w[0] == 0x82 || w[0] == 0x83 {
                    score += 5;
                }
            }
        }
        "big5" => {
            for c in decoded.chars() {
                let u = c as u32;
                // Common traditional characters
                if matches!(c, '繁' | '體' | '中' | '文' | '歌' | '詞' | '測' | '試' | '妳' | '說' | '線' | '桿' | '黃' | '飄') {
                    score += 30;
                } else if (0x4E00..=0x9FFF).contains(&u) {
                    score += 2;
                }
            }
            // Big5 common lead bytes 0xA4..=0xC6
            for &b in bytes {
                if (0xA4..=0xC6).contains(&b) {
                    score += 1;
                }
            }
        }
        "gbk" => {
            for c in decoded.chars() {
                let u = c as u32;
                // Common simplified characters
                if matches!(c, '简' | '体' | '中' | '文' | '歌' | '词' | '测' | '试' | '电' | '线' | '杆' | '说') {
                    score += 30;
                } else if (0x4E00..=0x9FFF).contains(&u) {
                    score += 2;
                }
            }
            // GB2312 level 1 lead bytes 0xB0..=0xD7
            for &b in bytes {
                if (0xB0..=0xD7).contains(&b) {
                    score += 1;
                }
            }
        }
        _ => {}
    }

    score
}

// -----------------------------------------------------------------------------
// Format-specific read-only embedded lyrics extraction
// -----------------------------------------------------------------------------

fn extract_flac_embedded(path: &Path) -> EmbeddedLyricsPair {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return EmbeddedLyricsPair::default(),
    };

    let mut magic = [0u8; 4];
    if file.read_exact(&mut magic).is_err() || &magic != b"fLaC" {
        return EmbeddedLyricsPair::default();
    }

    let mut result = EmbeddedLyricsPair::default();

    loop {
        let mut header = [0u8; 4];
        if file.read_exact(&mut header).is_err() {
            break;
        }

        let is_last = (header[0] & 0x80) != 0;
        let block_type = header[0] & 0x7F;
        let block_len = ((header[1] as usize) << 16)
            | ((header[2] as usize) << 8)
            | (header[3] as usize);

        if block_type == 4 {
            // VORBIS_COMMENT block
            let mut buf = vec![0u8; block_len];
            if file.read_exact(&mut buf).is_ok() {
                parse_vorbis_comment_lyrics(&buf, &mut result);
            }
            break;
        } else {
            if file.seek(SeekFrom::Current(block_len as i64)).is_err() {
                break;
            }
        }

        if is_last {
            break;
        }
    }

    result
}

fn parse_vorbis_comment_lyrics(buf: &[u8], result: &mut EmbeddedLyricsPair) {
    if buf.len() < 4 {
        return;
    }
    let vendor_len = u32::from_le_bytes(buf[0..4].try_into().unwrap()) as usize;
    let mut pos = 4 + vendor_len;
    if pos + 4 > buf.len() {
        return;
    }

    let user_comment_count = u32::from_le_bytes(buf[pos..pos + 4].try_into().unwrap()) as usize;
    pos += 4;

    for _ in 0..user_comment_count {
        if pos + 4 > buf.len() {
            break;
        }
        let len = u32::from_le_bytes(buf[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        if pos + len > buf.len() {
            break;
        }

        let entry_bytes = &buf[pos..pos + len];
        pos += len;

        let entry = String::from_utf8_lossy(entry_bytes);
        if let Some((k, v)) = entry.split_once('=') {
            let key = k.trim().to_ascii_uppercase();
            let val = v.trim();
            if val.is_empty() {
                continue;
            }

            match key.as_str() {
                "SYNCEDLYRICS" => {
                    if result.synced.is_none() {
                        result.synced = Some(val.to_string());
                    }
                }
                "LYRICS" => {
                    if is_lrc_content(val) {
                        if result.synced.is_none() {
                            result.synced = Some(val.to_string());
                        }
                    } else if result.unsynced.is_none() {
                        result.unsynced = Some(val.to_string());
                    }
                }
                "UNSYNCEDLYRICS" => {
                    if result.unsynced.is_none() {
                        result.unsynced = Some(val.to_string());
                    }
                }
                _ => {}
            }
        }
    }
}

fn extract_ogg_embedded(path: &Path) -> EmbeddedLyricsPair {
    // Search first 64KB for VORBIS_COMMENT packet or tags
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return EmbeddedLyricsPair::default(),
    };
    let mut buf = vec![0u8; 65536];
    let n = file.read(&mut buf).unwrap_or(0);
    buf.truncate(n);

    let mut result = EmbeddedLyricsPair::default();
    scan_vorbis_comment_tags_in_slice(&buf, &mut result);
    result
}

fn scan_vorbis_comment_tags_in_slice(buf: &[u8], result: &mut EmbeddedLyricsPair) {
    let hay = String::from_utf8_lossy(buf);
    for key in &["SYNCEDLYRICS=", "LYRICS=", "UNSYNCEDLYRICS="] {
        if let Some(idx) = hay.find(key) {
            let rest = &hay[idx + key.len()..];
            let val = rest.lines().next().unwrap_or("").trim();
            if !val.is_empty() {
                match *key {
                    "SYNCEDLYRICS=" => result.synced = Some(val.to_string()),
                    "LYRICS=" => {
                        if is_lrc_content(val) {
                            result.synced = Some(val.to_string());
                        } else {
                            result.unsynced = Some(val.to_string());
                        }
                    }
                    "UNSYNCEDLYRICS=" => result.unsynced = Some(val.to_string()),
                    _ => {}
                }
            }
        }
    }
}

fn extract_mp3_embedded(path: &Path) -> EmbeddedLyricsPair {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return EmbeddedLyricsPair::default(),
    };

    let mut id3_header = [0u8; 10];
    if file.read_exact(&mut id3_header).is_err() || &id3_header[0..3] != b"ID3" {
        return EmbeddedLyricsPair::default();
    }

    let major = id3_header[3];
    if major != 3 && major != 4 {
        return EmbeddedLyricsPair::default();
    }

    let flags = id3_header[5];
    let tag_size = decode_syncsafe(&id3_header[6..10]) as usize;
    if tag_size == 0 || tag_size > 16 * 1024 * 1024 {
        return EmbeddedLyricsPair::default();
    }

    let mut body = vec![0u8; tag_size];
    if file.read_exact(&mut body).is_err() {
        return EmbeddedLyricsPair::default();
    }

    parse_id3_lyrics_frames(&body, major, flags)
}

fn extract_wav_embedded(path: &Path) -> EmbeddedLyricsPair {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return EmbeddedLyricsPair::default(),
    };

    let mut riff_hdr = [0u8; 12];
    if file.read_exact(&mut riff_hdr).is_err() || &riff_hdr[0..4] != b"RIFF" || &riff_hdr[8..12] != b"WAVE" {
        return EmbeddedLyricsPair::default();
    }

    loop {
        let mut chunk_hdr = [0u8; 8];
        if file.read_exact(&mut chunk_hdr).is_err() {
            break;
        }

        let chunk_id = &chunk_hdr[0..4];
        let chunk_len = u32::from_le_bytes(chunk_hdr[4..8].try_into().unwrap()) as usize;

        if chunk_id == b"id3 " {
            let mut id3_bytes = vec![0u8; chunk_len];
            if file.read_exact(&mut id3_bytes).is_ok() && id3_bytes.len() >= 10 && &id3_bytes[0..3] == b"ID3" {
                let major = id3_bytes[3];
                let flags = id3_bytes[5];
                let tag_size = decode_syncsafe(&id3_bytes[6..10]) as usize;
                let body_end = (10 + tag_size).min(id3_bytes.len());
                if body_end > 10 {
                    return parse_id3_lyrics_frames(&id3_bytes[10..body_end], major, flags);
                }
            }
            break;
        } else {
            let pad = if chunk_len % 2 == 1 { 1 } else { 0 };
            if file.seek(SeekFrom::Current((chunk_len + pad) as i64)).is_err() {
                break;
            }
        }
    }

    EmbeddedLyricsPair::default()
}

fn parse_id3_lyrics_frames(raw_body: &[u8], major: u8, tag_flags: u8) -> EmbeddedLyricsPair {
    let mut result = EmbeddedLyricsPair::default();
    let tag_unsync = (tag_flags & 0x80) != 0;
    let has_ext = (tag_flags & 0x40) != 0;

    let body = if major == 3 && tag_unsync {
        de_unsync(raw_body)
    } else {
        raw_body.to_vec()
    };

    let mut offset = 0usize;
    if has_ext && body.len() >= 4 {
        if major == 3 {
            let ext_size = u32::from_be_bytes(body[0..4].try_into().unwrap()) as usize;
            offset = (4 + ext_size).min(body.len());
        } else if major == 4 {
            let ext_size = decode_syncsafe(&body[0..4]) as usize;
            if ext_size >= 6 {
                offset = ext_size.min(body.len());
            }
        }
    }

    while offset + 10 <= body.len() {
        if body[offset] == 0 {
            break;
        }

        let frame_id = match std::str::from_utf8(&body[offset..offset + 4]) {
            Ok(id) if id.chars().all(|c| c.is_ascii_alphanumeric()) => id,
            _ => break,
        };

        let frame_size = if major == 4 {
            decode_syncsafe(&body[offset + 4..offset + 8]) as usize
        } else {
            u32::from_be_bytes(body[offset + 4..offset + 8].try_into().unwrap()) as usize
        };

        let frame_flags = u16::from_be_bytes([body[offset + 8], body[offset + 9]]);
        offset += 10;

        if frame_size == 0 || offset + frame_size > body.len() {
            break;
        }

        let mut payload = &body[offset..offset + frame_size];
        offset += frame_size;

        if major == 3 {
            if (frame_flags & 0x0080) != 0 || (frame_flags & 0x0040) != 0 {
                continue;
            }
            if (frame_flags & 0x0020) != 0 && !payload.is_empty() {
                payload = &payload[1..];
            }
        } else if major == 4 {
            if (frame_flags & 0x0008) != 0 || (frame_flags & 0x0004) != 0 {
                continue;
            }
            if (frame_flags & 0x0040) != 0 && !payload.is_empty() {
                payload = &payload[1..];
            }
            if (frame_flags & 0x0001) != 0 && payload.len() >= 4 {
                payload = &payload[4..];
            }
        }

        let unsync_payload = if major == 4 && ((frame_flags & 0x0002) != 0 || tag_unsync) {
            de_unsync(payload)
        } else {
            payload.to_vec()
        };

        if unsync_payload.is_empty() {
            continue;
        }

        match frame_id {
            "SYLT" => {
                if let Some(synced_lrc) = parse_sylt_frame(&unsync_payload) {
                    if result.synced.is_none() {
                        result.synced = Some(synced_lrc);
                    }
                }
            }
            "USLT" => {
                if let Some(unsynced_text) = parse_uslt_frame(&unsync_payload) {
                    if result.unsynced.is_none() {
                        result.unsynced = Some(unsynced_text);
                    }
                }
            }
            _ => {}
        }
    }

    result
}

fn parse_uslt_frame(payload: &[u8]) -> Option<String> {
    if payload.len() < 4 {
        return None;
    }
    let encoding = payload[0];
    let content = &payload[4..]; // skip encoding (1B) + language (3B)

    // Locate end of description
    let text_bytes = match encoding {
        1 | 2 => {
            // UTF-16: find 0x0000 2-byte aligned
            let mut split_idx = None;
            let mut i = 0;
            while i + 1 < content.len() {
                if content[i] == 0 && content[i + 1] == 0 {
                    split_idx = Some(i + 2);
                    break;
                }
                i += 2;
            }
            split_idx.map(|idx| &content[idx..]).unwrap_or(content)
        }
        _ => {
            // 0 (Latin-1/legacy) or 3 (UTF-8): find 0x00
            content
                .iter()
                .position(|&b| b == 0)
                .map(|idx| &content[idx + 1..])
                .unwrap_or(content)
        }
    };

    let text = match encoding {
        1 => decode_utf16_slice(text_bytes, false),
        2 => decode_utf16_slice(text_bytes, true),
        3 => String::from_utf8_lossy(text_bytes).trim_matches('\0').to_string(),
        _ => decode_text_cjk(text_bytes),
    };

    let clean = text.trim();
    if clean.is_empty() {
        None
    } else {
        Some(clean.to_string())
    }
}

fn parse_sylt_frame(payload: &[u8]) -> Option<String> {
    if payload.len() < 6 {
        return None;
    }
    let encoding = payload[0];
    let time_format = payload[4]; // 1 = frames, 2 = milliseconds
    let content_type = payload[5]; // 1 = lyrics
    if content_type != 1 && content_type != 0 {
        // Not lyrics
    }

    let content = &payload[6..];
    // Skip descriptor
    let mut pos = match encoding {
        1 | 2 => {
            let mut idx = None;
            let mut i = 0;
            while i + 1 < content.len() {
                if content[i] == 0 && content[i + 1] == 0 {
                    idx = Some(i + 2);
                    break;
                }
                i += 2;
            }
            idx.unwrap_or(0)
        }
        _ => content.iter().position(|&b| b == 0).map(|i| i + 1).unwrap_or(0),
    };

    let mut lrc_lines = Vec::new();
    let body = &content[pos..];
    pos = 0;

    while pos < body.len() {
        // Text is terminated by NUL according to encoding, followed by 4-byte uint timestamp
        let text_start = pos;
        let mut text_end = None;

        if encoding == 1 || encoding == 2 {
            while pos + 1 < body.len() {
                if body[pos] == 0 && body[pos + 1] == 0 {
                    text_end = Some(pos);
                    pos += 2;
                    break;
                }
                pos += 2;
            }
        } else {
            while pos < body.len() {
                if body[pos] == 0 {
                    text_end = Some(pos);
                    pos += 1;
                    break;
                }
                pos += 1;
            }
        }

        let Some(t_end) = text_end else {
            break;
        };

        if pos + 4 > body.len() {
            break;
        }

        let raw_ts = u32::from_be_bytes(body[pos..pos + 4].try_into().unwrap()) as u64;
        pos += 4;

        let ms = if time_format == 1 {
            // MPEG frames (approx 26ms per frame at 44.1kHz, but standard says ms preferred)
            raw_ts * 26
        } else {
            raw_ts
        };

        let t_bytes = &body[text_start..t_end];
        let text = match encoding {
            1 => decode_utf16_slice(t_bytes, false),
            2 => decode_utf16_slice(t_bytes, true),
            3 => String::from_utf8_lossy(t_bytes).trim_matches('\0').to_string(),
            _ => decode_text_cjk(t_bytes),
        };

        let mins = ms / 60_000;
        let secs = (ms % 60_000) / 1000;
        let cs = (ms % 1000) / 10;
        lrc_lines.push(format!("[{:02}:{:02}.{:02}]{}", mins, secs, cs, text.trim()));
    }

    if lrc_lines.is_empty() {
        None
    } else {
        Some(lrc_lines.join("\n"))
    }
}

fn extract_m4a_embedded(path: &Path) -> EmbeddedLyricsPair {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return EmbeddedLyricsPair::default(),
    };

    let mut buf = Vec::new();
    // Scan up to first 2MB or entire file for ©lyr atom
    let max_read = 2 * 1024 * 1024;
    let mut chunk = vec![0u8; 65536];
    while buf.len() < max_read {
        let n = file.read(&mut chunk).unwrap_or(0);
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }

    let mut result = EmbeddedLyricsPair::default();
    if let Some(lyr_text) = find_m4a_lyr_atom(&buf) {
        if is_lrc_content(&lyr_text) {
            result.synced = Some(lyr_text);
        } else {
            result.unsynced = Some(lyr_text);
        }
    }
    result
}

fn find_m4a_lyr_atom(data: &[u8]) -> Option<String> {
    // ©lyr atom tag: 0xA9 0x6C 0x79 0x72
    let needle = [0xA9u8, b'l', b'y', b'r'];
    let pos = data.windows(4).position(|w| w == needle)?;

    // Atom format: [4B size][4B tag='©lyr'][data box: [4B size][4B tag='data'][4B type][4B locale][payload]]
    let after_tag = pos + 4;
    if after_tag + 16 > data.len() {
        return None;
    }

    // Look for 'data' sub-box
    let data_tag_pos = data[after_tag..after_tag + 24].windows(4).position(|w| w == b"data")?;
    let data_box_start = after_tag + data_tag_pos - 4;
    if data_box_start + 16 > data.len() {
        return None;
    }

    let data_box_size = u32::from_be_bytes(data[data_box_start..data_box_start + 4].try_into().unwrap()) as usize;
    if data_box_size < 16 || data_box_start + data_box_size > data.len() {
        return None;
    }

    let payload = &data[data_box_start + 16..data_box_start + data_box_size];
    let text = String::from_utf8_lossy(payload).trim().to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

// -----------------------------------------------------------------------------
// Helper utilities
// -----------------------------------------------------------------------------

fn decode_syncsafe(bytes: &[u8]) -> u32 {
    if bytes.len() < 4 {
        return 0;
    }
    ((bytes[0] as u32 & 0x7F) << 21)
        | ((bytes[1] as u32 & 0x7F) << 14)
        | ((bytes[2] as u32 & 0x7F) << 7)
        | (bytes[3] as u32 & 0x7F)
}

fn de_unsync(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        out.push(bytes[i]);
        if bytes[i] == 0xFF && i + 1 < bytes.len() && bytes[i + 1] == 0x00 {
            i += 2;
        } else {
            i += 1;
        }
    }
    out
}

fn decode_utf16_slice(content: &[u8], force_be: bool) -> String {
    if content.len() < 2 {
        return String::new();
    }
    let (is_be, slice) = if !force_be && content[0] == 0xFE && content[1] == 0xFF {
        (true, &content[2..])
    } else if !force_be && content[0] == 0xFF && content[1] == 0xFE {
        (false, &content[2..])
    } else {
        (force_be, content)
    };

    let u16s: Vec<u16> = slice
        .chunks_exact(2)
        .map(|c| {
            if is_be {
                u16::from_be_bytes([c[0], c[1]])
            } else {
                u16::from_le_bytes([c[0], c[1]])
            }
        })
        .take_while(|&u| u != 0)
        .collect();
    String::from_utf16_lossy(&u16s).trim().to_string()
}

fn normalize_path(path: &str) -> String {
    path.trim().replace('\\', "/").to_lowercase()
}
