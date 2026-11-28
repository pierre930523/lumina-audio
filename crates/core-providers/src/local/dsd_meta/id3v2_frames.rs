use core_types::{ExtractedPicture, PictureType};

use super::Id3v2ParsedTags;
use super::id3v2_extra::{normalize_id3_genre, parse_rva2_frame};
use super::id3v2_text::{
    decode_id3_text, decode_id3_text_values, decode_id3_text_with_enc, decode_utf8_or_fallback,
    decode_utf16_slice, parse_disc_number, parse_replay_gain_db_str, parse_replay_gain_peak_str,
    parse_track_and_disc_number, parse_year,
};
use crate::local::encoding::{
    DetectedEncoding, decode_bytes_with_encoding, sanitize_multiline_tag_text, sanitize_tag_text,
};

#[derive(Default)]
pub(super) struct FrameDecodeState {
    pub(super) txxx_album_artist_exact: Option<String>,
    pub(super) txxx_album_artist_alias: Option<String>,
    pub(super) tpe2_album_artist: Option<String>,
    pub(super) tpub_record_label: Option<String>,
    pub(super) txxx_record_label: Option<String>,
    pub(super) txxx_publisher: Option<String>,
    pub(super) tdrc_year: Option<i32>,
    pub(super) tyer_year: Option<i32>,
}

pub(super) fn apply_staged_frame(
    mapped_id: &str,
    frame_payload: &[u8],
    enc0_resolved: DetectedEncoding,
    collect_raw: bool,
    include_pictures: bool,
    tags: &mut Id3v2ParsedTags,
    state: &mut FrameDecodeState,
) -> Option<String> {
    let mut raw_decoded_summary: Option<String> = None;

    match mapped_id {
        "TXXX" => {
            if let Some((desc, val)) = decode_txxx_frame(frame_payload, enc0_resolved) {
                raw_decoded_summary = Some(format!("{desc}={val}"));
                apply_txxx_tag(&desc, &val, tags, state);
            }
        }
        "RVA2" => {
            parse_rva2_frame(frame_payload, tags);
            raw_decoded_summary = Some("[RVA2 volume adjustment]".to_string());
        }
        "TIT2" => {
            let vals = decode_id3_text_values(frame_payload, enc0_resolved);
            if let Some(t) = vals.first() {
                raw_decoded_summary = Some(vals.join(" / "));
                if tags.title.is_none() {
                    tags.title = Some(t.clone());
                }
            }
        }
        "TPE1" => {
            let vals = decode_id3_text_values(frame_payload, enc0_resolved);
            if !vals.is_empty() {
                raw_decoded_summary = Some(vals.join(" ; "));
                for v in &vals {
                    if !tags.artists.iter().any(|e| e.eq_ignore_ascii_case(v)) {
                        tags.artists.push(v.clone());
                    }
                }
                if tags.artist.is_none() {
                    tags.artist = Some(vals.join("; "));
                }
            }
        }
        "TALB" => {
            let vals = decode_id3_text_values(frame_payload, enc0_resolved);
            if let Some(t) = vals.first() {
                raw_decoded_summary = Some(t.clone());
                if tags.album.is_none() {
                    tags.album = Some(t.clone());
                }
            }
        }
        "TPE2" => {
            let vals = decode_id3_text_values(frame_payload, enc0_resolved);
            if !vals.is_empty() {
                let joined = vals.join("; ");
                raw_decoded_summary = Some(joined.clone());
                if state.tpe2_album_artist.is_none() {
                    state.tpe2_album_artist = Some(joined);
                }
            }
        }
        "TRCK" => {
            let t = decode_id3_text(frame_payload, enc0_resolved);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
            }
            let (trk, disc) = parse_track_and_disc_number(&t);
            if let Some(num) = trk {
                if tags.track_number.is_none() {
                    tags.track_number = Some(num);
                }
            }
            if tags.disc_number.is_none() {
                if let Some(d) = disc {
                    tags.disc_number = Some(d);
                }
            }
        }
        "TPOS" => {
            let t = decode_id3_text(frame_payload, enc0_resolved);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
            }
            if tags.disc_number.is_none() {
                if let Some(num) = parse_disc_number(&t) {
                    tags.disc_number = Some(num);
                }
            }
        }
        "TDRC" => {
            let t = decode_id3_text(frame_payload, enc0_resolved);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
            }
            if state.tdrc_year.is_none() {
                state.tdrc_year = parse_year(&t);
            }
        }
        "TYER" => {
            let t = decode_id3_text(frame_payload, enc0_resolved);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
            }
            if state.tyer_year.is_none() {
                state.tyer_year = parse_year(&t);
            }
        }
        "TSRC" => {
            let t = decode_id3_text(frame_payload, enc0_resolved);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
            }
            let clean = t.trim().replace('-', "");
            if clean.len() == 12 && clean.chars().all(|c| c.is_ascii_alphanumeric()) {
                tags.isrc = Some(clean.to_ascii_uppercase());
            }
        }
        "TCON" => {
            let raw = decode_id3_text(frame_payload, enc0_resolved);
            let t = normalize_id3_genre(&raw);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
                if tags.genre.is_none() {
                    tags.genre = Some(t);
                }
            }
        }
        "TCOM" => {
            let t = decode_id3_text(frame_payload, enc0_resolved);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
                if tags.composer.is_none() {
                    tags.composer = Some(t);
                }
            }
        }
        "TPUB" => {
            let vals = decode_id3_text_values(frame_payload, enc0_resolved);
            if let Some(t) = vals.first() {
                raw_decoded_summary = Some(vals.join("; "));
                if state.tpub_record_label.is_none() {
                    state.tpub_record_label = Some(t.clone());
                }
            }
        }
        "TCMP" => {
            let t = decode_id3_text(frame_payload, enc0_resolved);
            if !t.is_empty() {
                raw_decoded_summary = Some(t.clone());
                tags.compilation = parse_bool_flag(&t);
            }
        }
        "USLT" => {
            if frame_payload.len() > 4 {
                let enc = frame_payload[0];
                let rest = &frame_payload[4..];
                let txt_start = find_text_nul_end(enc, rest).unwrap_or(0);
                if txt_start <= rest.len() {
                    let raw_lyrics = &rest[txt_start..];
                    let text = sanitize_multiline_tag_text(&decode_id3_text_with_enc(
                        enc,
                        raw_lyrics,
                        enc0_resolved,
                    ));
                    if !text.is_empty() {
                        raw_decoded_summary =
                            Some(format!("[lyrics, {} chars]", text.chars().count()));
                        if tags.lyrics.is_none() {
                            tags.lyrics = Some(text);
                        }
                    }
                }
            }
        }
        "APIC" if frame_payload.len() > 3 => {
            if !include_pictures && !collect_raw {
                return None;
            }
            let enc = frame_payload[0];
            let mut idx = 1;
            if let Some(me) = frame_payload[idx..].iter().position(|&b| b == 0) {
                let mime_raw = &frame_payload[idx..idx + me];
                let mime_str = String::from_utf8_lossy(mime_raw).to_ascii_lowercase();
                let mime_type = if mime_str.is_empty() || mime_str == "image/" || mime_str == "jpg"
                {
                    "image/jpeg".to_string()
                } else if mime_str == "png" {
                    "image/png".to_string()
                } else {
                    mime_str
                };
                idx += me + 1;
                if idx < frame_payload.len() {
                    let pic_type_byte = frame_payload[idx];
                    idx += 1;
                    let desc_bytes = &frame_payload[idx..];
                    let data_start = idx + find_pic_desc_end(enc, desc_bytes);
                    if data_start < frame_payload.len() {
                        let img_len = frame_payload.len() - data_start;
                        raw_decoded_summary = Some(format!("[APIC {mime_type}, {img_len} bytes]"));
                        if include_pictures {
                            tags.pictures.push(ExtractedPicture {
                                picture_type: PictureType::from_apic_byte(pic_type_byte),
                                mime_type,
                                data: frame_payload[data_start..].to_vec(),
                            });
                        }
                    }
                }
            }
        }
        "PIC" if frame_payload.len() > 6 => {
            if !include_pictures && !collect_raw {
                return None;
            }
            // ID3v2.2 PIC: [1B enc][3B format e.g. JPG/PNG][1B pic_type][desc NUL][image data]
            let enc = frame_payload[0];
            let fmt_str = String::from_utf8_lossy(&frame_payload[1..4]).to_ascii_lowercase();
            let mime_type = if fmt_str == "png" {
                "image/png".to_string()
            } else {
                "image/jpeg".to_string()
            };
            let pic_type_byte = frame_payload[4];
            let desc_bytes = &frame_payload[5..];
            let data_start = 5 + find_pic_desc_end(enc, desc_bytes);
            if data_start < frame_payload.len() {
                let img_len = frame_payload.len() - data_start;
                raw_decoded_summary = Some(format!("[PIC {mime_type}, {img_len} bytes]"));
                if include_pictures {
                    tags.pictures.push(ExtractedPicture {
                        picture_type: PictureType::from_apic_byte(pic_type_byte),
                        mime_type,
                        data: frame_payload[data_start..].to_vec(),
                    });
                }
            }
        }
        _ => {
            if collect_raw && mapped_id.starts_with('T') {
                let t = decode_id3_text(frame_payload, enc0_resolved);
                if !t.is_empty() {
                    raw_decoded_summary = Some(t);
                }
            }
        }
    }

    raw_decoded_summary
}

fn find_text_nul_end(enc: u8, bytes: &[u8]) -> Option<usize> {
    if enc == 1 || enc == 2 {
        for i in (0..bytes.len().saturating_sub(1)).step_by(2) {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                return Some(i + 2);
            }
        }
        None
    } else {
        bytes.iter().position(|&b| b == 0).map(|p| p + 1)
    }
}

fn find_pic_desc_end(enc: u8, desc_bytes: &[u8]) -> usize {
    if enc == 1 || enc == 2 {
        find_text_nul_end(enc, desc_bytes).unwrap_or(desc_bytes.len())
    } else {
        find_text_nul_end(enc, desc_bytes).unwrap_or(0)
    }
}

fn decode_txxx_frame(payload: &[u8], enc0_resolved: DetectedEncoding) -> Option<(String, String)> {
    if payload.len() < 2 {
        return None;
    }
    let encoding = payload[0];
    let content = &payload[1..];

    match encoding {
        1 | 2 => {
            let mut split_idx = None;
            let mut i = 0;
            while i + 1 < content.len() {
                if content[i] == 0 && content[i + 1] == 0 {
                    split_idx = Some(i);
                    break;
                }
                i += 2;
            }
            let idx = split_idx?;
            let desc = sanitize_tag_text(&decode_utf16_slice(&content[..idx], encoding == 2));
            let val_bytes = &content[(idx + 2).min(content.len())..];
            let val = sanitize_tag_text(&decode_utf16_slice(val_bytes, encoding == 2));
            Some((desc, val))
        }
        0 | 3 => {
            let split_idx = content.iter().position(|&b| b == 0)?;
            let desc_bytes = &content[..split_idx];
            let val_bytes = &content[(split_idx + 1).min(content.len())..];
            let val_end = val_bytes
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(val_bytes.len());
            let val_slice = &val_bytes[..val_end];

            let desc = if encoding == 0 {
                sanitize_tag_text(&decode_bytes_with_encoding(desc_bytes, enc0_resolved))
            } else {
                sanitize_tag_text(&decode_utf8_or_fallback(desc_bytes))
            };
            let val = if encoding == 0 {
                sanitize_tag_text(&decode_bytes_with_encoding(val_slice, enc0_resolved))
            } else {
                sanitize_tag_text(&decode_utf8_or_fallback(val_slice))
            };
            Some((desc, val))
        }
        _ => None,
    }
}

fn apply_txxx_tag(desc: &str, val: &str, tags: &mut Id3v2ParsedTags, state: &mut FrameDecodeState) {
    let key = desc.trim().to_ascii_uppercase();
    let norm_key = key.replace([' ', '_', '-'], "");
    let trimmed_val = val.trim();
    if trimmed_val.is_empty() {
        return;
    }
    match norm_key.as_str() {
        "REPLAYGAINTRACKGAIN" => {
            if tags.txxx_rg_track_db.is_none() {
                tags.txxx_rg_track_db = parse_replay_gain_db_str(trimmed_val);
            }
        }
        "REPLAYGAINALBUMGAIN" => {
            if tags.txxx_rg_album_db.is_none() {
                tags.txxx_rg_album_db = parse_replay_gain_db_str(trimmed_val);
            }
        }
        "REPLAYGAINTRACKPEAK" => {
            if tags.txxx_rg_track_peak.is_none() {
                tags.txxx_rg_track_peak = parse_replay_gain_peak_str(trimmed_val);
            }
        }
        "REPLAYGAINALBUMPEAK" => {
            if tags.txxx_rg_album_peak.is_none() {
                tags.txxx_rg_album_peak = parse_replay_gain_peak_str(trimmed_val);
            }
        }
        "ALBUMARTIST" | "ALBUMARTISTS" => {
            if key == "ALBUMARTIST" {
                if state.txxx_album_artist_exact.is_none() {
                    state.txxx_album_artist_exact = Some(trimmed_val.to_string());
                }
            } else if state.txxx_album_artist_alias.is_none() {
                state.txxx_album_artist_alias = Some(trimmed_val.to_string());
            }
        }
        "COMPILATION" => {
            if tags.compilation.is_none() {
                tags.compilation = parse_bool_flag(trimmed_val);
            }
        }
        "DISCNUMBER" | "DISC" => {
            if tags.disc_number.is_none() {
                tags.disc_number = parse_disc_number(trimmed_val);
            }
        }
        "TRACKNUMBER" | "TRACK" => {
            if tags.track_number.is_none() {
                let (trk, disc) = parse_track_and_disc_number(trimmed_val);
                tags.track_number = trk;
                if tags.disc_number.is_none() {
                    tags.disc_number = disc;
                }
            }
        }
        "UPC" | "BARCODE" | "EAN" => {
            if tags.upc.is_none() {
                let clean: String = trimmed_val
                    .chars()
                    .filter(|c| c.is_ascii_alphanumeric())
                    .collect();
                if !clean.is_empty() {
                    tags.upc = Some(clean);
                }
            }
        }
        "MUSICBRAINZRELEASEGROUPID" => {
            if tags.musicbrainz_release_group_id.is_none() {
                tags.musicbrainz_release_group_id = Some(trimmed_val.to_string());
            }
        }
        "EDITION" | "VERSION" | "RELEASETYPE" if tags.edition_label.is_none() => {
            tags.edition_label = Some(trimmed_val.to_string());
        }
        "LABEL" | "RECORDLABEL" if state.txxx_record_label.is_none() => {
            state.txxx_record_label = Some(trimmed_val.to_string());
        }
        "PUBLISHER" if state.txxx_publisher.is_none() => {
            state.txxx_publisher = Some(trimmed_val.to_string());
        }
        _ => {}
    }
}

fn parse_bool_flag(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" => Some(true),
        "0" | "false" | "no" => Some(false),
        _ => None,
    }
}
