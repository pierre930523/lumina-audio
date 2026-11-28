use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat};

use super::accumulator::{
    ALBUM_ARTIST_PRIO_ALIAS, ALBUM_ARTIST_PRIO_BAND, ALBUM_ARTIST_PRIO_EXACT,
    RECORD_LABEL_PRIO_FALLBACK, RECORD_LABEL_PRIO_LABEL, RECORD_LABEL_PRIO_PUBLISHER,
    TagAccumulator,
};
use super::helpers::{
    append_split_artists, normalize_custom_tag_key, normalize_isrc, normalize_upc, parse_bool_flag,
};
use super::{ExtractOptions, ExtractedMetadata, FlacRawMetadata};
use crate::error::ProviderError;
use crate::local::ape_meta::parse_ape_from_reader;
use crate::local::dsd_meta::{
    Id3v2ParsedTags, decode_syncsafe, parse_disc_number, parse_id3v2_body_ext,
    parse_replay_gain_db_str, parse_replay_gain_peak_str, parse_track_and_disc_number, parse_year,
};
use crate::local::encoding::{
    decode_bytes_with_encoding, detect_tag_block_encoding, sanitize_multiline_tag_text,
    sanitize_tag_text,
};

pub(super) fn extract_flac_from_reader<R: Read + Seek>(
    mut reader: R,
    fallback_path: &Path,
    opts: ExtractOptions,
    collect_raw: bool,
) -> Result<(ExtractedMetadata, FlacRawMetadata), ProviderError> {
    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic)?;

    let mut id3_fallback: Option<Id3v2ParsedTags> = None;
    if &magic[0..3] == b"ID3" {
        let mut hdr_tail = [0u8; 6];
        reader.read_exact(&mut hdr_tail)?;
        // Full 10-byte ID3v2 header layout:
        // [0..3]="ID3", [3]=major, [4]=minor, [5]=flags, [6..10]=syncsafe size
        let major = magic[3];
        let flags = hdr_tail[1];
        let tag_size = decode_syncsafe(&hdr_tail[2..6]) as usize;
        if tag_size > 16 * 1024 * 1024 {
            return Err(ProviderError::UnsupportedFormat(
                "FLAC prepended ID3v2 tag exceeds maximum size".to_string(),
            ));
        }
        let mut body = vec![0u8; tag_size];
        reader.read_exact(&mut body)?;
        if (flags & 0x10) != 0 {
            let mut footer = [0u8; 10];
            let _ = reader.read_exact(&mut footer);
        }
        if matches!(major, 2..=4) {
            id3_fallback = Some(parse_id3v2_body_ext(
                &body,
                major,
                flags,
                collect_raw,
                opts.include_pictures,
            ));
        }

        let mut b = [0u8; 1];
        let mut found_magic = false;
        while reader.read_exact(&mut b).is_ok() {
            if b[0] != 0 {
                let mut rest = [0u8; 3];
                reader.read_exact(&mut rest)?;
                magic = [b[0], rest[0], rest[1], rest[2]];
                found_magic = true;
                break;
            }
        }
        if !found_magic {
            return Err(ProviderError::UnsupportedFormat(
                "Missing fLaC stream marker after prepended ID3v2".to_string(),
            ));
        }
    }

    if &magic != b"fLaC" {
        return Err(ProviderError::UnsupportedFormat(
            "Invalid FLAC stream marker".to_string(),
        ));
    }

    let mut sample_rate = 0u32;
    let mut channels = 2u8;
    let mut bit_depth = 16u8;
    let mut duration_ms = 1000u64;
    let mut saw_streaminfo = false;

    let mut staged_comments: Vec<(String, Vec<u8>)> = Vec::new();
    let mut extracted_pictures: Vec<core_types::ExtractedPicture> = Vec::new();

    loop {
        let mut hdr = [0u8; 4];
        if reader.read_exact(&mut hdr).is_err() {
            break;
        }
        let is_last = (hdr[0] & 0x80) != 0;
        let block_type = hdr[0] & 0x7F;
        let block_len = ((hdr[1] as usize) << 16) | ((hdr[2] as usize) << 8) | (hdr[3] as usize);

        match block_type {
            0 => {
                let mut data = vec![0u8; block_len];
                if reader.read_exact(&mut data).is_ok() && block_len >= 18 {
                    let b = &data[10..18];
                    let sr = ((b[0] as u32) << 12) | ((b[1] as u32) << 4) | ((b[2] as u32) >> 4);
                    let ch = (((b[2] >> 1) & 0x07) + 1) as u8;
                    let bps = ((((b[2] & 0x01) << 4) | (b[3] >> 4)) + 1) as u8;
                    let total_samples = (((b[3] & 0x0F) as u64) << 32)
                        | ((b[4] as u64) << 24)
                        | ((b[5] as u64) << 16)
                        | ((b[6] as u64) << 8)
                        | (b[7] as u64);
                    if sr > 0 {
                        sample_rate = sr;
                        channels = ch;
                        bit_depth = bps;
                        saw_streaminfo = true;
                        duration_ms = ((total_samples * 1000) / sr as u64).max(1);
                    }
                }
            }
            4 => {
                let mut data = vec![0u8; block_len];
                if reader.read_exact(&mut data).is_ok() && data.len() >= 8 {
                    let vendor_len = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
                    let mut cursor = 4 + vendor_len;
                    if cursor + 4 <= data.len() {
                        let count = u32::from_le_bytes(data[cursor..cursor + 4].try_into().unwrap())
                            as usize;
                        cursor += 4;
                        for _ in 0..count {
                            if cursor + 4 > data.len() {
                                break;
                            }
                            let c_len =
                                u32::from_le_bytes(data[cursor..cursor + 4].try_into().unwrap())
                                    as usize;
                            cursor += 4;
                            if cursor + c_len > data.len() {
                                break;
                            }
                            let raw_entry = &data[cursor..cursor + c_len];
                            cursor += c_len;

                            if let Some(eq_pos) = raw_entry.iter().position(|&b| b == b'=') {
                                let raw_k =
                                    String::from_utf8_lossy(&raw_entry[..eq_pos]).into_owned();
                                let raw_v = raw_entry[eq_pos + 1..].to_vec();
                                staged_comments.push((raw_k, raw_v));
                            }
                        }
                    }
                }
            }
            6 => {
                if !opts.include_pictures {
                    let _ = reader.seek(SeekFrom::Current(block_len as i64));
                } else {
                    let mut data = vec![0u8; block_len];
                    if reader.read_exact(&mut data).is_ok() && data.len() >= 32 {
                        let pic_type_val = u32::from_be_bytes(data[0..4].try_into().unwrap());
                        let pic_type = match pic_type_val {
                            3 => core_types::PictureType::FrontCover,
                            4 => core_types::PictureType::BackCover,
                            _ => core_types::PictureType::Other,
                        };
                        let mime_len = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
                        let mut cur = 8;
                        if cur + mime_len <= data.len() {
                            let mime_str =
                                String::from_utf8_lossy(&data[cur..cur + mime_len]).to_string();
                            cur += mime_len;
                            if cur + 4 <= data.len() {
                                let desc_len =
                                    u32::from_be_bytes(data[cur..cur + 4].try_into().unwrap())
                                        as usize;
                                cur += 4 + desc_len;
                                if cur + 20 <= data.len() {
                                    cur += 16;
                                    let data_len =
                                        u32::from_be_bytes(data[cur..cur + 4].try_into().unwrap())
                                            as usize;
                                    cur += 4;
                                    if cur + data_len <= data.len() {
                                        extracted_pictures.push(core_types::ExtractedPicture {
                                            picture_type: pic_type,
                                            mime_type: if mime_str.is_empty() {
                                                "image/jpeg".to_string()
                                            } else {
                                                mime_str
                                            },
                                            data: data[cur..cur + data_len].to_vec(),
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {
                let _ = reader.seek(SeekFrom::Current(block_len as i64));
            }
        }

        if is_last {
            break;
        }
    }

    if !saw_streaminfo {
        return Err(ProviderError::UnsupportedFormat(
            "Truncated or invalid FLAC file (missing valid STREAMINFO block)".to_string(),
        ));
    }

    let has_vorbis_comments = !staged_comments.is_empty();

    // Two-pass Vorbis Comment encoding detection (handles strict UTF-8 & broken legacy-encoded FLACs)
    let vc_samples: Vec<&[u8]> = staged_comments.iter().map(|(_, v)| v.as_slice()).collect();
    let vorbis_encoding = detect_tag_block_encoding(&vc_samples);

    let mut acc = TagAccumulator {
        pictures: extracted_pictures,
        ..Default::default()
    };

    let mut raw_vorbis_comments = Vec::new();
    let mut artist_values: Vec<String> = Vec::new();
    for (raw_k, raw_v_bytes) in staged_comments {
        let key_upper = raw_k.trim().to_ascii_uppercase();
        let norm_k = normalize_custom_tag_key(&raw_k);
        let is_lyrics = matches!(
            norm_k.as_str(),
            "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS"
        );
        let decoded_raw = decode_bytes_with_encoding(&raw_v_bytes, vorbis_encoding);
        let val = if is_lyrics {
            sanitize_multiline_tag_text(&decoded_raw)
        } else {
            sanitize_tag_text(&decoded_raw)
        };

        if collect_raw {
            raw_vorbis_comments.push((raw_k, raw_v_bytes, val.clone()));
        }

        if val.is_empty() {
            continue;
        }

        match norm_k.as_str() {
            "TITLE" if acc.title.is_none() => acc.title = Some(val),
            "ARTIST" => {
                append_split_artists(&mut acc.artists, &val);
                if !artist_values.iter().any(|e| e.eq_ignore_ascii_case(&val)) {
                    artist_values.push(val);
                }
            }
            "ALBUM" if acc.album.is_none() => acc.album = Some(val),
            "ALBUMARTIST" | "ALBUMARTISTS" => {
                let prio = if key_upper == "ALBUMARTIST" {
                    ALBUM_ARTIST_PRIO_EXACT
                } else {
                    ALBUM_ARTIST_PRIO_ALIAS
                };
                acc.set_album_artist(val, prio);
            }
            "BAND" | "ENSEMBLE" => {
                acc.set_album_artist(val, ALBUM_ARTIST_PRIO_BAND);
            }
            "TRACKNUMBER" | "TRACK" if acc.track_number.is_none() => {
                let (t, d) = parse_track_and_disc_number(&val);
                acc.track_number = t;
                if acc.disc_number.is_none() {
                    acc.disc_number = d;
                }
            }
            "DISCNUMBER" | "DISC" if acc.disc_number.is_none() => {
                acc.disc_number = parse_disc_number(&val);
            }
            "DATE" | "YEAR" if acc.release_year.is_none() => {
                acc.release_year = parse_year(&val);
            }
            "GENRE" if acc.genre.is_none() => acc.genre = Some(val),
            "COMPOSER" if acc.composer.is_none() => acc.composer = Some(val),
            "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS" if acc.lyrics.is_none() => {
                acc.lyrics = Some(val);
            }
            "ISRC" if acc.isrc.is_none() => {
                acc.isrc = normalize_isrc(&val);
            }
            "UPC" | "BARCODE" | "EAN" if acc.upc.is_none() => {
                acc.upc = normalize_upc(&val);
            }
            "MUSICBRAINZRELEASEGROUPID" if acc.mb_rg_id.is_none() => {
                acc.mb_rg_id = Some(val);
            }
            "EDITION" | "VERSION" | "RELEASETYPE" if acc.edition.is_none() => {
                acc.edition = Some(val);
            }
            "LABEL" | "RECORDLABEL" => {
                acc.set_record_label(val, RECORD_LABEL_PRIO_LABEL);
            }
            "PUBLISHER" => {
                acc.set_record_label(val, RECORD_LABEL_PRIO_PUBLISHER);
            }
            "ORGANIZATION" => {
                acc.set_record_label(val, RECORD_LABEL_PRIO_FALLBACK);
            }
            "COMPILATION" if acc.compilation.is_none() => {
                acc.compilation = parse_bool_flag(&val);
            }
            "REPLAYGAINTRACKGAIN" if acc.rg_track_db.is_none() => {
                acc.rg_track_db = parse_replay_gain_db_str(&val);
            }
            "REPLAYGAINALBUMGAIN" if acc.rg_album_db.is_none() => {
                acc.rg_album_db = parse_replay_gain_db_str(&val);
            }
            "REPLAYGAINTRACKPEAK" if acc.rg_track_peak.is_none() => {
                acc.rg_track_peak = parse_replay_gain_peak_str(&val);
            }
            "REPLAYGAINALBUMPEAK" if acc.rg_album_peak.is_none() => {
                acc.rg_album_peak = parse_replay_gain_peak_str(&val);
            }
            _ => {}
        }
    }

    if !artist_values.is_empty() && acc.artist.is_none() {
        acc.artist = Some(artist_values.join("; "));
    }

    // Only inspect trailing APEv2 when collecting raw debug blocks OR when Vorbis Comments are absent.
    let ape_tags = if collect_raw || !has_vorbis_comments {
        parse_ape_from_reader(&mut reader)
    } else {
        None
    };

    let raw_id3_for_debug = if collect_raw {
        id3_fallback.clone()
    } else {
        None
    };
    let raw_ape_for_debug = if collect_raw { ape_tags.clone() } else { None };

    // Strict FLAC rule: whenever Vorbis Comments are present, IGNORE residual prepended ID3v2 & APEv2
    // so stale ID3/APE fields never leak into clean Vorbis-tagged FLAC files.
    if !has_vorbis_comments {
        if let Some(id3) = id3_fallback {
            acc.apply_id3v2(id3, opts.include_pictures);
        }
        if let Some(ape) = ape_tags {
            acc.apply_ape(ape, opts.include_pictures);
        }
    }

    let format = AudioFormat::pcm(
        AudioCodec::Flac,
        sample_rate.max(8000),
        bit_depth.clamp(8, 32),
        channels.clamp(1, 8),
    )?;

    let meta = acc.finalize(fallback_path, format, duration_ms);
    let raw = FlacRawMetadata {
        vorbis_encoding,
        raw_vorbis_comments,
        prepended_id3: raw_id3_for_debug,
        ape_tags: raw_ape_for_debug,
    };
    Ok((meta, raw))
}
