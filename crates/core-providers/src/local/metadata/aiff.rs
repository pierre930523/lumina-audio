use std::io::{Read, Seek, SeekFrom};

use super::AiffParsedTags;
use crate::local::dsd_meta::{Id3v2ParsedTags, parse_id3v2_from_slice_with_options};
use crate::local::encoding::{
    decode_bytes_with_encoding, detect_tag_block_encoding, sanitize_tag_text,
};

pub(crate) fn scan_aiff_from_reader<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Option<AiffParsedTags> {
    reader.seek(SeekFrom::Start(0)).ok()?;
    let mut form_hdr = [0u8; 12];
    reader.read_exact(&mut form_hdr).ok()?;
    if &form_hdr[0..4] != b"FORM" || (&form_hdr[8..12] != b"AIFF" && &form_hdr[8..12] != b"AIFC") {
        return None;
    }

    let mut id3: Option<Id3v2ParsedTags> = None;
    let mut staged_form: Vec<(String, Vec<u8>)> = Vec::new();

    loop {
        let mut chunk_hdr = [0u8; 8];
        if reader.read_exact(&mut chunk_hdr).is_err() {
            break;
        }
        let chunk_id = &chunk_hdr[0..4];
        let chunk_size = u32::from_be_bytes(chunk_hdr[4..8].try_into().unwrap()) as u64;

        if chunk_id.eq_ignore_ascii_case(b"id3 ") {
            let to_read = chunk_size.min(16 * 1024 * 1024) as usize;
            let mut buf = vec![0u8; to_read];
            if reader.read_exact(&mut buf).is_err() {
                break;
            }
            if let Some(parsed) = parse_id3v2_from_slice_with_options(&buf, collect_raw) {
                id3 = Some(parsed);
            }
            if chunk_size > to_read as u64 {
                if reader
                    .seek(SeekFrom::Current((chunk_size - to_read as u64) as i64))
                    .is_err()
                {
                    break;
                }
            }
        } else if chunk_id == b"NAME" || chunk_id == b"AUTH" {
            let to_read = chunk_size.min(64 * 1024) as usize;
            let mut buf = vec![0u8; to_read];
            if reader.read_exact(&mut buf).is_err() {
                break;
            }
            staged_form.push((String::from_utf8_lossy(chunk_id).into_owned(), buf));
            if chunk_size > to_read as u64 {
                if reader
                    .seek(SeekFrom::Current((chunk_size - to_read as u64) as i64))
                    .is_err()
                {
                    break;
                }
            }
        } else if reader.seek(SeekFrom::Current(chunk_size as i64)).is_err() {
            break;
        }

        if chunk_size % 2 == 1 {
            let mut pad = [0u8; 1];
            if reader.read_exact(&mut pad).is_ok() && pad[0] != 0 {
                let _ = reader.seek(SeekFrom::Current(-1));
            }
        }
    }

    if id3.is_none() && staged_form.is_empty() {
        return None;
    }

    let samples: Vec<&[u8]> = staged_form.iter().map(|(_, b)| b.as_slice()).collect();
    let form_encoding = detect_tag_block_encoding(&samples);
    let mut form_title = None;
    let mut form_artist = None;
    let mut raw_form_fields = Vec::new();
    for (k, raw) in staged_form {
        let dec = sanitize_tag_text(&decode_bytes_with_encoding(&raw, form_encoding));
        if !dec.is_empty() {
            if k == "NAME" && form_title.is_none() {
                form_title = Some(dec.clone());
            } else if k == "AUTH" && form_artist.is_none() {
                form_artist = Some(dec.clone());
            }
        }
        if collect_raw {
            raw_form_fields.push((k, raw, dec));
        }
    }

    Some(AiffParsedTags {
        id3,
        form_title,
        form_artist,
        form_encoding,
        raw_form_fields,
    })
}
