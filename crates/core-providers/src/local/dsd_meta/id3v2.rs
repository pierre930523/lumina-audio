use std::borrow::Cow;
use std::io::Read;

use super::id3v2_frames::{FrameDecodeState, apply_staged_frame};
use super::{Id3v2ParsedTags, RawId3Frame};
use crate::local::encoding::{DetectedEncoding, detect_tag_block_encoding};

pub fn decode_syncsafe(bytes: &[u8]) -> u32 {
    if bytes.len() < 4 {
        return 0;
    }
    ((bytes[0] as u32 & 0x7F) << 21)
        | ((bytes[1] as u32 & 0x7F) << 14)
        | ((bytes[2] as u32 & 0x7F) << 7)
        | (bytes[3] as u32 & 0x7F)
}

/// Parses an ID3v2 (v2.2 / v2.3 / v2.4) tag starting at the current reader position (`ID3` header).
pub fn parse_id3v2_from_reader<R: Read>(reader: &mut R) -> Option<Id3v2ParsedTags> {
    parse_id3v2_from_reader_ext(reader, false, true)
}

/// Parses an ID3v2 tag starting at the current reader position, optionally capturing raw frames.
pub fn parse_id3v2_from_reader_with_options<R: Read>(
    reader: &mut R,
    collect_raw: bool,
) -> Option<Id3v2ParsedTags> {
    parse_id3v2_from_reader_ext(reader, collect_raw, true)
}

/// Parses an ID3v2 tag starting at the current reader position with picture & raw frame controls.
pub fn parse_id3v2_from_reader_ext<R: Read>(
    reader: &mut R,
    collect_raw: bool,
    include_pictures: bool,
) -> Option<Id3v2ParsedTags> {
    let mut id3_header = [0u8; 10];
    reader.read_exact(&mut id3_header).ok()?;
    if &id3_header[0..3] != b"ID3" {
        return None;
    }

    let major = id3_header[3];
    if !matches!(major, 2..=4) {
        return None;
    }

    let flags = id3_header[5];
    let tag_size = decode_syncsafe(&id3_header[6..10]) as usize;
    if tag_size == 0 || tag_size > 16 * 1024 * 1024 {
        return None;
    }

    let mut tag_data = vec![0u8; tag_size];
    reader.read_exact(&mut tag_data).ok()?;
    Some(parse_id3v2_body_ext(
        &tag_data,
        major,
        flags,
        collect_raw,
        include_pictures,
    ))
}

/// Parses an ID3v2 (v2.2 / v2.3 / v2.4) tag from an in-memory buffer starting with `"ID3"`.
pub fn parse_id3v2_from_slice(data: &[u8]) -> Option<Id3v2ParsedTags> {
    parse_id3v2_from_slice_ext(data, false, true)
}

/// Parses an ID3v2 tag from an in-memory buffer, optionally capturing raw frames for inspection.
pub fn parse_id3v2_from_slice_with_options(
    data: &[u8],
    collect_raw: bool,
) -> Option<Id3v2ParsedTags> {
    parse_id3v2_from_slice_ext(data, collect_raw, true)
}

pub fn parse_id3v2_from_slice_ext(
    data: &[u8],
    collect_raw: bool,
    include_pictures: bool,
) -> Option<Id3v2ParsedTags> {
    if data.len() < 10 || &data[0..3] != b"ID3" {
        return None;
    }
    let major = data[3];
    if !matches!(major, 2..=4) {
        return None;
    }
    let flags = data[5];
    let tag_size = decode_syncsafe(&data[6..10]) as usize;
    if tag_size == 0 {
        return None;
    }
    let end = (10 + tag_size).min(data.len());
    Some(parse_id3v2_body_ext(
        &data[10..end],
        major,
        flags,
        collect_raw,
        include_pictures,
    ))
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

fn looks_like_frame_boundary(data: &[u8], pos: usize) -> bool {
    if pos == data.len() {
        return true;
    }
    if pos > data.len() {
        return false;
    }
    if data[pos] == 0 {
        return true;
    }
    if pos + 4 <= data.len() {
        return data[pos..pos + 4]
            .iter()
            .all(|&b| b.is_ascii_uppercase() || b.is_ascii_digit());
    }
    false
}

pub(super) struct StagedFrame<'a> {
    pub(super) mapped_id: &'a str,
    pub(super) raw_id: &'a str,
    pub(super) payload: Cow<'a, [u8]>,
}

pub fn parse_id3v2_body(raw_body: &[u8], major: u8, tag_flags: u8) -> Id3v2ParsedTags {
    parse_id3v2_body_ext(raw_body, major, tag_flags, false, true)
}

pub fn parse_id3v2_body_with_options(
    raw_body: &[u8],
    major: u8,
    tag_flags: u8,
    collect_raw: bool,
) -> Id3v2ParsedTags {
    parse_id3v2_body_ext(raw_body, major, tag_flags, collect_raw, true)
}

pub fn parse_id3v2_body_ext(
    raw_body: &[u8],
    major: u8,
    tag_flags: u8,
    collect_raw: bool,
    include_pictures: bool,
) -> Id3v2ParsedTags {
    let mut tags = Id3v2ParsedTags {
        version_major: major,
        ..Default::default()
    };
    let tag_unsync = (tag_flags & 0x80) != 0;
    let has_ext = (tag_flags & 0x40) != 0;

    let body_cow: Cow<'_, [u8]> = if (major == 2 || major == 3) && tag_unsync {
        Cow::Owned(de_unsync(raw_body))
    } else {
        Cow::Borrowed(raw_body)
    };
    let data = body_cow.as_ref();

    let mut offset = 0usize;
    if has_ext && data.len() >= 4 {
        if major == 3 {
            let ext_size = u32::from_be_bytes(data[0..4].try_into().unwrap()) as usize;
            offset = (4 + ext_size).min(data.len());
        } else if major == 4 {
            let ext_size = decode_syncsafe(&data[0..4]) as usize;
            if ext_size >= 6 {
                offset = ext_size.min(data.len());
            }
        }
    }

    // Pass 1: Stage all valid frames so we can detect ONE shared tag-wide encoding across all enc=0 frames.
    let mut staged: Vec<StagedFrame<'_>> = Vec::new();
    while offset < data.len() {
        if data[offset] == 0 {
            break;
        }

        let (mapped_id, raw_id, frame_size, header_len, frame_flags) = if major == 2 {
            if offset + 6 > data.len() {
                break;
            }
            let raw_id = match std::str::from_utf8(&data[offset..offset + 3]) {
                Ok(id) if id.chars().all(|c| c.is_ascii_alphanumeric()) => id,
                _ => break,
            };
            let sz = ((data[offset + 3] as usize) << 16)
                | ((data[offset + 4] as usize) << 8)
                | (data[offset + 5] as usize);
            let mapped_id = match raw_id {
                "TT2" => "TIT2",
                "TP1" => "TPE1",
                "TAL" => "TALB",
                "TP2" => "TPE2",
                "TRK" => "TRCK",
                "TPA" => "TPOS",
                "TYE" => "TYER",
                "TCO" => "TCON",
                "TCM" => "TCOM",
                "TPB" => "TPUB",
                "TRC" => "TSRC",
                "TCP" => "TCMP",
                "TXX" => "TXXX",
                "ULT" => "USLT",
                "PIC" => "PIC",
                _ => raw_id,
            };
            (mapped_id, raw_id, sz, 6, 0u16)
        } else {
            if offset + 10 > data.len() {
                break;
            }
            let raw_id = match std::str::from_utf8(&data[offset..offset + 4]) {
                Ok(id) if id.chars().all(|c| c.is_ascii_alphanumeric()) => id,
                _ => break,
            };
            let sz = if major == 4 {
                let raw_sz = &data[offset + 4..offset + 8];
                let sync_sz = decode_syncsafe(raw_sz) as usize;
                let be_sz = u32::from_be_bytes(raw_sz.try_into().unwrap()) as usize;
                if raw_sz.iter().any(|&b| b >= 0x80) {
                    be_sz
                } else if sync_sz != be_sz && sync_sz >= 128 {
                    let sync_ok = looks_like_frame_boundary(data, offset + 10 + sync_sz);
                    let be_ok = looks_like_frame_boundary(data, offset + 10 + be_sz);
                    if !sync_ok && be_ok { be_sz } else { sync_sz }
                } else {
                    sync_sz
                }
            } else {
                u32::from_be_bytes(data[offset + 4..offset + 8].try_into().unwrap()) as usize
            };
            let flags = u16::from_be_bytes([data[offset + 8], data[offset + 9]]);
            (raw_id, raw_id, sz, 10, flags)
        };

        offset += header_len;

        if frame_size == 0 || offset + frame_size > data.len() {
            break;
        }

        let mut payload = &data[offset..offset + frame_size];
        offset += frame_size;

        // Skip compressed or encrypted frames; strip optional header extensions
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

        if !include_pictures && !collect_raw && matches!(mapped_id, "APIC" | "PIC") {
            continue;
        }

        let unsync_payload: Cow<'_, [u8]> =
            if major == 4 && ((frame_flags & 0x0002) != 0 || tag_unsync) {
                Cow::Owned(de_unsync(payload))
            } else {
                Cow::Borrowed(payload)
            };

        if unsync_payload.is_empty() {
            continue;
        }

        staged.push(StagedFrame {
            mapped_id,
            raw_id,
            payload: unsync_payload,
        });
    }

    // Collect tag-wide encoding samples across ALL enc=0 text / TXXX / USLT frames.
    let mut enc0_samples: Vec<&[u8]> = Vec::new();
    let mut saw_utf8 = false;
    let mut saw_utf16_le = false;
    let mut saw_utf16_be = false;

    for frame in &staged {
        let p = frame.payload.as_ref();
        if p.is_empty() {
            continue;
        }
        let is_text = matches!(
            frame.mapped_id,
            "TIT2"
                | "TPE1"
                | "TALB"
                | "TPE2"
                | "TRCK"
                | "TPOS"
                | "TDRC"
                | "TYER"
                | "TSRC"
                | "TCON"
                | "TCOM"
                | "TPUB"
                | "TCMP"
                | "TXXX"
                | "USLT"
        );
        if !is_text {
            continue;
        }
        match p[0] {
            0 => {
                if frame.mapped_id == "USLT" && p.len() > 4 {
                    let rest = &p[4..];
                    let start = rest
                        .iter()
                        .position(|&b| b == 0)
                        .map(|i| i + 1)
                        .unwrap_or(0);
                    if start < rest.len() {
                        enc0_samples.push(&rest[start..]);
                    }
                } else if p.len() > 1 {
                    for part in p[1..].split(|&b| b == 0) {
                        if !part.is_empty() {
                            enc0_samples.push(part);
                        }
                    }
                }
            }
            1 => {
                if p.len() >= 3 && p[1] == 0xFE && p[2] == 0xFF {
                    saw_utf16_be = true;
                } else {
                    saw_utf16_le = true;
                }
            }
            2 => saw_utf16_be = true,
            3 => saw_utf8 = true,
            _ => {}
        }
    }

    let enc0_resolved = detect_tag_block_encoding(&enc0_samples);
    tags.detected_encoding = if !enc0_samples.is_empty() && enc0_resolved != DetectedEncoding::Ascii
    {
        enc0_resolved
    } else if saw_utf8 {
        DetectedEncoding::Utf8
    } else if saw_utf16_le {
        DetectedEncoding::Utf16Le
    } else if saw_utf16_be {
        DetectedEncoding::Utf16Be
    } else {
        enc0_resolved
    };

    // Pass 2: Decode every frame using the unified tag-wide encoding for enc=0.
    let mut state = FrameDecodeState::default();
    for frame in &staged {
        let frame_payload = frame.payload.as_ref();
        let declared_enc = if frame.mapped_id.starts_with('T')
            || matches!(frame.mapped_id, "USLT" | "APIC" | "PIC" | "COMM")
        {
            frame_payload.first().copied()
        } else {
            None
        };

        let raw_decoded_summary = apply_staged_frame(
            frame.mapped_id,
            frame_payload,
            enc0_resolved,
            collect_raw,
            include_pictures,
            &mut tags,
            &mut state,
        );

        if collect_raw {
            let is_pic = matches!(frame.mapped_id, "APIC" | "PIC");
            let raw_bytes = if is_pic {
                Vec::new()
            } else {
                frame_payload[..frame_payload.len().min(256)].to_vec()
            };
            tags.raw_frames.push(RawId3Frame {
                frame_id: frame.mapped_id.to_string(),
                raw_frame_id: frame.raw_id.to_string(),
                declared_encoding: declared_enc,
                raw_bytes,
                decoded_value: raw_decoded_summary,
            });
        }
    }

    // Strict ALBUMARTIST precedence: TXXX:ALBUMARTIST > TXXX:ALBUM ARTIST > TPE2
    tags.album_artist = state
        .txxx_album_artist_exact
        .or(state.txxx_album_artist_alias)
        .or(state.tpe2_album_artist);
    // Strict record label precedence: TPUB > TXXX:LABEL > TXXX:PUBLISHER
    tags.record_label = state
        .tpub_record_label
        .or(state.txxx_record_label)
        .or(state.txxx_publisher);
    tags.release_year = state.tdrc_year.or(state.tyer_year);
    tags
}
