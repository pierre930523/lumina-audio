use base64::Engine as _;
use core_types::{ExtractedPicture, PictureType};

use super::accumulator::{
    ALBUM_ARTIST_PRIO_ALIAS, ALBUM_ARTIST_PRIO_BAND, ALBUM_ARTIST_PRIO_EXACT,
    RECORD_LABEL_PRIO_FALLBACK, RECORD_LABEL_PRIO_LABEL, RECORD_LABEL_PRIO_PUBLISHER,
    TagAccumulator,
};
use super::helpers::{
    append_split_artists, normalize_custom_tag_key, normalize_isrc, normalize_upc, parse_bool_flag,
};
use crate::local::dsd_meta::{
    parse_disc_number, parse_replay_gain_db_str, parse_replay_gain_peak_str,
    parse_track_and_disc_number, parse_year,
};
use crate::local::encoding::{
    decode_bytes_with_encoding, detect_tag_block_encoding, sanitize_multiline_tag_text,
    sanitize_tag_text,
};

pub(super) fn apply_vorbis_comments(
    staged_comments: &[(String, Vec<u8>)],
    acc: &mut TagAccumulator,
    include_pictures: bool,
) {
    let text_samples: Vec<&[u8]> = staged_comments
        .iter()
        .filter(|(k, _)| !k.eq_ignore_ascii_case("METADATA_BLOCK_PICTURE"))
        .map(|(_, v)| v.as_slice())
        .collect();
    let vorbis_encoding = detect_tag_block_encoding(&text_samples);

    let mut artist_values: Vec<String> = Vec::new();
    for (raw_k, raw_v_bytes) in staged_comments {
        let key_upper = raw_k.trim().to_ascii_uppercase();
        let norm_k = normalize_custom_tag_key(raw_k);

        if norm_k == "METADATABLOCKPICTURE" {
            if include_pictures {
                if let Some(pic) = decode_vorbis_picture(raw_v_bytes) {
                    acc.pictures.push(pic);
                }
            }
            continue;
        }

        let is_lyrics = matches!(
            norm_k.as_str(),
            "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS"
        );
        let decoded_raw = decode_bytes_with_encoding(raw_v_bytes, vorbis_encoding);
        let val = if is_lyrics {
            sanitize_multiline_tag_text(&decoded_raw)
        } else {
            sanitize_tag_text(&decoded_raw)
        };
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
            "ISRC" if acc.isrc.is_none() => acc.isrc = normalize_isrc(&val),
            "UPC" | "BARCODE" | "EAN" if acc.upc.is_none() => acc.upc = normalize_upc(&val),
            "MUSICBRAINZRELEASEGROUPID" if acc.mb_rg_id.is_none() => acc.mb_rg_id = Some(val),
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
}

fn decode_vorbis_picture(b64_bytes: &[u8]) -> Option<ExtractedPicture> {
    let b64_str = std::str::from_utf8(b64_bytes).ok()?.trim();
    let data = base64::engine::general_purpose::STANDARD
        .decode(b64_str)
        .ok()?;
    if data.len() < 32 {
        return None;
    }
    let pic_type_val = u32::from_be_bytes(data[0..4].try_into().unwrap());
    let picture_type = match pic_type_val {
        3 => PictureType::FrontCover,
        4 => PictureType::BackCover,
        _ => PictureType::Other,
    };
    let mime_len = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
    let mut cur = 8usize;
    if cur + mime_len + 4 > data.len() {
        return None;
    }
    let mime_str = String::from_utf8_lossy(&data[cur..cur + mime_len]).to_string();
    cur += mime_len;
    let desc_len = u32::from_be_bytes(data[cur..cur + 4].try_into().unwrap()) as usize;
    cur += 4 + desc_len;
    if cur + 20 > data.len() {
        return None;
    }
    cur += 16;
    let data_len = u32::from_be_bytes(data[cur..cur + 4].try_into().unwrap()) as usize;
    cur += 4;
    if cur + data_len > data.len() || data_len == 0 {
        return None;
    }
    Some(ExtractedPicture {
        picture_type,
        mime_type: if mime_str.is_empty() {
            "image/jpeg".to_string()
        } else {
            mime_str
        },
        data: data[cur..cur + data_len].to_vec(),
    })
}
