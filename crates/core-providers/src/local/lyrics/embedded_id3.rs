use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use super::lrc_parser::decode_text_cjk;
use super::models::EmbeddedLyricsPair;

pub(super) fn extract_mp3_embedded(path: &Path) -> EmbeddedLyricsPair {
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

pub(super) fn extract_wav_embedded(path: &Path) -> EmbeddedLyricsPair {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return EmbeddedLyricsPair::default(),
    };

    let mut riff_hdr = [0u8; 12];
    if file.read_exact(&mut riff_hdr).is_err()
        || &riff_hdr[0..4] != b"RIFF"
        || &riff_hdr[8..12] != b"WAVE"
    {
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
            if file.read_exact(&mut id3_bytes).is_ok()
                && id3_bytes.len() >= 10
                && &id3_bytes[0..3] == b"ID3"
            {
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
            if file
                .seek(SeekFrom::Current((chunk_len + pad) as i64))
                .is_err()
            {
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
        3 => String::from_utf8_lossy(text_bytes)
            .trim_matches('\0')
            .to_string(),
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
        _ => content
            .iter()
            .position(|&b| b == 0)
            .map(|i| i + 1)
            .unwrap_or(0),
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
            3 => String::from_utf8_lossy(t_bytes)
                .trim_matches('\0')
                .to_string(),
            _ => decode_text_cjk(t_bytes),
        };

        let mins = ms / 60_000;
        let secs = (ms % 60_000) / 1000;
        let cs = (ms % 1000) / 10;
        lrc_lines.push(format!(
            "[{:02}:{:02}.{:02}]{}",
            mins,
            secs,
            cs,
            text.trim()
        ));
    }

    if lrc_lines.is_empty() {
        None
    } else {
        Some(lrc_lines.join("\n"))
    }
}

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
