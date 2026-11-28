use std::io::{Cursor, Read, Seek, SeekFrom};

use core_types::{ExtractedPicture, PictureType};

use super::dsd_meta::{
    parse_disc_number, parse_replay_gain_db_str, parse_replay_gain_peak_str,
    parse_track_and_disc_number, parse_year,
};
use super::encoding::{
    DetectedEncoding, decode_bytes_with_encoding, detect_tag_block_encoding,
    sanitize_multiline_tag_text, sanitize_tag_text,
};

const APE_PREAMBLE: &[u8; 8] = b"APETAGEX";
const APE_MAX_TAG_SIZE: usize = 16 * 1024 * 1024;
const APE_MAX_ITEMS: usize = 4096;

#[derive(Debug, Clone)]
pub struct RawApeItem {
    pub key: String,
    pub flags: u32,
    pub is_binary: bool,
    pub raw_bytes: Vec<u8>,
    pub decoded_values: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ApeParsedTags {
    pub version: u32,
    pub detected_encoding: DetectedEncoding,
    pub raw_items: Vec<RawApeItem>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub release_year: Option<i32>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub isrc: Option<String>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub record_label: Option<String>,
    pub compilation: Option<bool>,
    pub lyrics: Option<String>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
    pub pictures: Vec<ExtractedPicture>,
}

/// Parses an APEv2 (or APEv1) tag from a seekable reader.
///
/// Checks the trailing APE footer before an optional 128-byte ID3v1 tag, and falls back to
/// checking a leading APEv2 header at byte offset 0.
pub fn parse_ape_from_reader<R: Read + Seek>(reader: &mut R) -> Option<ApeParsedTags> {
    let file_len = reader.seek(SeekFrom::End(0)).ok()?;
    if file_len < 32 {
        return None;
    }

    // Determine effective end, stripping trailing 128-byte ID3v1 tag if present.
    let mut effective_end = file_len;
    if file_len >= 128 && reader.seek(SeekFrom::Start(file_len - 128)).is_ok() {
        let mut id3v1_magic = [0u8; 3];
        if reader.read_exact(&mut id3v1_magic).is_ok() && &id3v1_magic == b"TAG" {
            effective_end = file_len - 128;
        }
    }

    // 1. Check APE footer at effective_end - 32
    if effective_end >= 32 {
        if let Some(parsed) = try_read_ape_footer_at(reader, effective_end) {
            return Some(parsed);
        }
    }

    // 2. If ID3v1 wasn't actually an ID3v1 tag (false "TAG" match inside APE), also try EOF - 32
    if effective_end != file_len && file_len >= 32 {
        if let Some(parsed) = try_read_ape_footer_at(reader, file_len) {
            return Some(parsed);
        }
    }

    // 3. Check leading APEv2 header at offset 0
    if reader.seek(SeekFrom::Start(0)).is_ok() {
        let mut hdr = [0u8; 32];
        if reader.read_exact(&mut hdr).is_ok() && &hdr[0..8] == APE_PREAMBLE {
            let version = u32::from_le_bytes(hdr[8..12].try_into().unwrap());
            let tag_size = u32::from_le_bytes(hdr[12..16].try_into().unwrap()) as usize;
            let item_count = u32::from_le_bytes(hdr[16..20].try_into().unwrap()) as usize;
            let flags = u32::from_le_bytes(hdr[20..24].try_into().unwrap());
            let is_header = (flags & (1 << 29)) != 0;
            let no_footer = (flags & (1 << 30)) != 0;
            if is_header && tag_size <= APE_MAX_TAG_SIZE && item_count <= APE_MAX_ITEMS {
                let items_len = if no_footer {
                    tag_size
                } else {
                    tag_size.saturating_sub(32)
                };
                if items_len as u64 <= file_len.saturating_sub(32) {
                    let mut items_buf = vec![0u8; items_len];
                    if reader.read_exact(&mut items_buf).is_ok() {
                        return Some(parse_ape_items(&items_buf, version, item_count));
                    }
                }
            }
        }
    }

    None
}

/// Parses an APEv2 (or APEv1) tag from an in-memory byte slice.
pub fn parse_ape_from_slice(data: &[u8]) -> Option<ApeParsedTags> {
    let mut cursor = Cursor::new(data);
    parse_ape_from_reader(&mut cursor)
}

fn try_read_ape_footer_at<R: Read + Seek>(
    reader: &mut R,
    footer_end: u64,
) -> Option<ApeParsedTags> {
    if footer_end < 32 {
        return None;
    }
    reader.seek(SeekFrom::Start(footer_end - 32)).ok()?;
    let mut footer = [0u8; 32];
    reader.read_exact(&mut footer).ok()?;
    if &footer[0..8] != APE_PREAMBLE {
        return None;
    }

    let version = u32::from_le_bytes(footer[8..12].try_into().unwrap());
    let tag_size = u32::from_le_bytes(footer[12..16].try_into().unwrap()) as usize;
    let item_count = u32::from_le_bytes(footer[16..20].try_into().unwrap()) as usize;

    // tag_size includes the 32-byte footer and all items, excluding any 32-byte header.
    if !(32..=APE_MAX_TAG_SIZE).contains(&tag_size) || item_count > APE_MAX_ITEMS {
        return None;
    }
    let items_len = tag_size - 32;
    let items_start = footer_end.checked_sub(tag_size as u64)?;
    reader.seek(SeekFrom::Start(items_start)).ok()?;
    let mut items_buf = vec![0u8; items_len];
    reader.read_exact(&mut items_buf).ok()?;

    Some(parse_ape_items(&items_buf, version, item_count))
}

struct StagedApeItem {
    key: String,
    flags: u32,
    is_binary: bool,
    raw_bytes: Vec<u8>,
}

fn parse_ape_items(buf: &[u8], version: u32, item_count: usize) -> ApeParsedTags {
    let mut staged: Vec<StagedApeItem> = Vec::with_capacity(item_count.min(64));
    let mut pos = 0usize;

    for _ in 0..item_count {
        if pos + 8 > buf.len() {
            break;
        }
        let val_size = u32::from_le_bytes(buf[pos..pos + 4].try_into().unwrap()) as usize;
        let flags = u32::from_le_bytes(buf[pos + 4..pos + 8].try_into().unwrap());
        pos += 8;

        let Some(nul_rel) = buf[pos..].iter().position(|&b| b == 0) else {
            break;
        };
        if nul_rel == 0 || nul_rel > 255 {
            break;
        }
        let key = String::from_utf8_lossy(&buf[pos..pos + nul_rel]).into_owned();
        pos += nul_rel + 1;

        if pos + val_size > buf.len() {
            break;
        }
        let raw_bytes = buf[pos..pos + val_size].to_vec();
        pos += val_size;

        let item_type = (flags >> 1) & 0x03;
        let is_binary = item_type == 1;

        staged.push(StagedApeItem {
            key,
            flags,
            is_binary,
            raw_bytes,
        });
    }

    // Two-pass encoding detection across all non-binary APE text items.
    let text_samples: Vec<&[u8]> = staged
        .iter()
        .filter(|it| !it.is_binary)
        .flat_map(|it| it.raw_bytes.split(|&b| b == 0))
        .filter(|s| !s.is_empty())
        .collect();
    let detected_encoding = detect_tag_block_encoding(&text_samples);

    let mut parsed = ApeParsedTags {
        version,
        detected_encoding,
        ..Default::default()
    };
    let mut ape_label: Option<String> = None;
    let mut ape_publisher: Option<String> = None;

    for item in staged {
        if item.is_binary {
            if let Some(pic) = parse_ape_picture(&item.key, &item.raw_bytes) {
                parsed.pictures.push(pic);
            }
            parsed.raw_items.push(RawApeItem {
                key: item.key,
                flags: item.flags,
                is_binary: true,
                raw_bytes: item.raw_bytes,
                decoded_values: Vec::new(),
            });
            continue;
        }

        let norm_key = normalize_ape_key(&item.key);
        let is_multiline = matches!(
            norm_key.as_str(),
            "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS"
        );

        let decoded_values: Vec<String> = item
            .raw_bytes
            .split(|&b| b == 0)
            .filter(|part| !part.is_empty())
            .map(|part| {
                let raw = decode_bytes_with_encoding(part, detected_encoding);
                if is_multiline {
                    sanitize_multiline_tag_text(&raw)
                } else {
                    sanitize_tag_text(&raw)
                }
            })
            .filter(|s| !s.is_empty())
            .collect();

        if let Some(first) = decoded_values.first() {
            match norm_key.as_str() {
                "TITLE" if parsed.title.is_none() => parsed.title = Some(first.clone()),
                "ARTIST" => {
                    for val in &decoded_values {
                        if !parsed.artists.iter().any(|e| e.eq_ignore_ascii_case(val)) {
                            parsed.artists.push(val.clone());
                        }
                    }
                    if parsed.artist.is_none() {
                        parsed.artist = Some(first.clone());
                    }
                }
                "ALBUM" if parsed.album.is_none() => parsed.album = Some(first.clone()),
                "ALBUMARTIST" | "ALBUMARTISTS" if parsed.album_artist.is_none() => {
                    parsed.album_artist = Some(first.clone());
                }
                "TRACK" | "TRACKNUMBER" if parsed.track_number.is_none() => {
                    let (trk, disc) = parse_track_and_disc_number(first);
                    if let Some(n) = trk {
                        parsed.track_number = Some(n);
                    }
                    if parsed.disc_number.is_none() {
                        if let Some(d) = disc {
                            parsed.disc_number = Some(d);
                        }
                    }
                }
                "DISC" | "DISCNUMBER" | "MEDIA"
                    if norm_key != "MEDIA" && parsed.disc_number.is_none() =>
                {
                    parsed.disc_number = parse_disc_number(first);
                }
                "YEAR" | "DATE" | "RELEASEDATE" if parsed.release_year.is_none() => {
                    parsed.release_year = parse_year(first);
                }
                "GENRE" if parsed.genre.is_none() => parsed.genre = Some(first.clone()),
                "COMPOSER" if parsed.composer.is_none() => parsed.composer = Some(first.clone()),
                "ISRC" if parsed.isrc.is_none() => {
                    let clean = first.replace('-', "").to_ascii_uppercase();
                    if clean.len() == 12 && clean.chars().all(|c| c.is_ascii_alphanumeric()) {
                        parsed.isrc = Some(clean);
                    }
                }
                "UPC" | "BARCODE" | "EAN" if parsed.upc.is_none() => {
                    let clean: String = first
                        .chars()
                        .filter(|c| c.is_ascii_alphanumeric())
                        .collect();
                    if !clean.is_empty() {
                        parsed.upc = Some(clean);
                    }
                }
                "MUSICBRAINZRELEASEGROUPID" if parsed.musicbrainz_release_group_id.is_none() => {
                    parsed.musicbrainz_release_group_id = Some(first.clone());
                }
                "EDITION" | "VERSION" | "RELEASETYPE" if parsed.edition_label.is_none() => {
                    parsed.edition_label = Some(first.clone());
                }
                "LABEL" | "RECORDLABEL" if ape_label.is_none() => {
                    ape_label = Some(first.clone());
                }
                "PUBLISHER" if ape_publisher.is_none() => {
                    ape_publisher = Some(first.clone());
                }
                "COMPILATION" if parsed.compilation.is_none() => {
                    parsed.compilation = parse_bool_flag(first);
                }
                "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS" if parsed.lyrics.is_none() => {
                    parsed.lyrics = Some(first.clone());
                }
                "REPLAYGAINTRACKGAIN" if parsed.replay_gain_track_db.is_none() => {
                    parsed.replay_gain_track_db = parse_replay_gain_db_str(first);
                }
                "REPLAYGAINALBUMGAIN" if parsed.replay_gain_album_db.is_none() => {
                    parsed.replay_gain_album_db = parse_replay_gain_db_str(first);
                }
                "REPLAYGAINTRACKPEAK" if parsed.replay_gain_track_peak.is_none() => {
                    parsed.replay_gain_track_peak = parse_replay_gain_peak_str(first);
                }
                "REPLAYGAINALBUMPEAK" if parsed.replay_gain_album_peak.is_none() => {
                    parsed.replay_gain_album_peak = parse_replay_gain_peak_str(first);
                }
                _ => {}
            }
        }

        parsed.raw_items.push(RawApeItem {
            key: item.key,
            flags: item.flags,
            is_binary: false,
            raw_bytes: item.raw_bytes,
            decoded_values,
        });
    }

    parsed.record_label = ape_label.or(ape_publisher);
    parsed
}

fn normalize_ape_key(raw: &str) -> String {
    raw.trim().to_ascii_uppercase().replace([' ', '_', '-'], "")
}

fn parse_bool_flag(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" => Some(true),
        "0" | "false" | "no" => Some(false),
        _ => None,
    }
}

fn parse_ape_picture(key: &str, raw: &[u8]) -> Option<ExtractedPicture> {
    let key_lower = key.trim().to_ascii_lowercase();
    if !key_lower.starts_with("cover art") {
        return None;
    }
    // Binary cover art payload in APEv2: "<filename>\0<image bytes>"
    let nul = raw.iter().position(|&b| b == 0)?;
    let name = String::from_utf8_lossy(&raw[..nul]).to_ascii_lowercase();
    let img_bytes = &raw[nul + 1..];
    if img_bytes.is_empty() {
        return None;
    }

    let mime_type = if name.ends_with(".png") || img_bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png".to_string()
    } else if name.ends_with(".webp") {
        "image/webp".to_string()
    } else {
        "image/jpeg".to_string()
    };

    let picture_type = if key_lower.contains("front") {
        PictureType::FrontCover
    } else if key_lower.contains("back") {
        PictureType::BackCover
    } else {
        PictureType::Other
    };

    Some(ExtractedPicture {
        picture_type,
        mime_type,
        data: img_bytes.to_vec(),
    })
}
