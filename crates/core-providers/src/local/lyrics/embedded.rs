use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use super::embedded_id3::{extract_mp3_embedded, extract_wav_embedded};
use super::lrc_parser::is_lrc_content;
use super::models::{EmbeddedLyricsPair, LyricsManager};

impl LyricsManager {
    /// Extracts embedded lyrics from an audio file read-only.
    pub(super) fn extract_embedded_lyrics(path: &Path) -> EmbeddedLyricsPair {
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

// -----------------------------------------------------------------------------
// Format-specific read-only embedded lyrics extraction (FLAC, Ogg, M4A)
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
        let block_len =
            ((header[1] as usize) << 16) | ((header[2] as usize) << 8) | (header[3] as usize);

        if block_type == 4 {
            // VORBIS_COMMENT block
            let mut buf = vec![0u8; block_len];
            if file.read_exact(&mut buf).is_ok() {
                parse_vorbis_comment_lyrics(&buf, &mut result);
            }
            break;
        } else if file.seek(SeekFrom::Current(block_len as i64)).is_err() {
            break;
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
                "UNSYNCEDLYRICS" if result.unsynced.is_none() => {
                    result.unsynced = Some(val.to_string());
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
    let data_tag_pos = data[after_tag..after_tag + 24]
        .windows(4)
        .position(|w| w == b"data")?;
    let data_box_start = after_tag + data_tag_pos - 4;
    if data_box_start + 16 > data.len() {
        return None;
    }

    let data_box_size =
        u32::from_be_bytes(data[data_box_start..data_box_start + 4].try_into().unwrap()) as usize;
    if data_box_size < 16 || data_box_start + data_box_size > data.len() {
        return None;
    }

    let payload = &data[data_box_start + 16..data_box_start + data_box_size];
    let text = String::from_utf8_lossy(payload).trim().to_string();
    if text.is_empty() { None } else { Some(text) }
}
