use std::io::{Read, Seek, SeekFrom};

use core_types::{ExtractedPicture, PictureType};

use super::{Mp4IlstParsedTags, normalize_custom_tag_key};
use crate::local::dsd_meta::parse_year;
use crate::local::encoding::{
    DetectedEncoding, decode_bytes_with_encoding, detect_tag_block_encoding,
    sanitize_multiline_tag_text, sanitize_tag_text,
};

/// Lightweight MP4/M4A `moov -> [udta ->] meta -> ilst` parser that handles both
/// `moov -> udta -> meta -> ilst` and direct `moov -> meta -> ilst`, 6-byte and 8-byte
/// `trkn`/`disk` atoms, multi-value `data` atoms, strict `ALBUMARTIST` precedence
/// (`----:ALBUMARTIST > ----:ALBUM ARTIST > aART`), tag-wide encoding detection, and `covr` extraction.
pub(crate) fn scan_mp4_ilst_from_reader<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Option<Mp4IlstParsedTags> {
    scan_mp4_ilst_from_reader_ext(reader, collect_raw, false)
}

pub(crate) fn scan_mp4_ilst_from_reader_ext<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
    include_pictures: bool,
) -> Option<Mp4IlstParsedTags> {
    let file_len = reader.seek(SeekFrom::End(0)).ok()?;
    reader.seek(SeekFrom::Start(0)).ok()?;

    let (moov_start, moov_end) = find_mp4_child_box(reader, 0, file_len, b"moov")?;
    let meta_range = find_mp4_child_box(reader, moov_start, moov_end, b"udta")
        .and_then(|(us, ue)| find_mp4_child_box(reader, us, ue, b"meta"))
        .or_else(|| find_mp4_child_box(reader, moov_start, moov_end, b"meta"))?;
    let (meta_start, meta_end) = meta_range;

    // `meta` is normally a FullBox (4-byte version+flags prefix), though QuickTime sometimes omits it.
    let ilst_range = find_mp4_child_box(reader, meta_start + 4, meta_end, b"ilst")
        .or_else(|| find_mp4_child_box(reader, meta_start, meta_end, b"ilst"))?;

    let ilst_len = ilst_range.1.saturating_sub(ilst_range.0) as usize;
    if ilst_len == 0 || ilst_len > 16 * 1024 * 1024 {
        return None;
    }

    reader.seek(SeekFrom::Start(ilst_range.0)).ok()?;
    let mut buf = vec![0u8; ilst_len];
    reader.read_exact(&mut buf).ok()?;

    Some(parse_mp4_ilst_bytes(&buf, collect_raw, include_pictures))
}

fn find_mp4_child_box<R: Read + Seek>(
    reader: &mut R,
    start: u64,
    end: u64,
    target: &[u8; 4],
) -> Option<(u64, u64)> {
    let mut pos = start;
    while pos + 8 <= end {
        reader.seek(SeekFrom::Start(pos)).ok()?;
        let mut hdr = [0u8; 8];
        reader.read_exact(&mut hdr).ok()?;
        let size32 = u32::from_be_bytes(hdr[0..4].try_into().unwrap()) as u64;
        let box_type = &hdr[4..8];

        let (box_size, hdr_len) = if size32 == 0 {
            (end.saturating_sub(pos), 8u64)
        } else if size32 == 1 {
            let mut ext = [0u8; 8];
            reader.read_exact(&mut ext).ok()?;
            (u64::from_be_bytes(ext), 16u64)
        } else {
            (size32, 8u64)
        };

        if box_size < hdr_len || pos + box_size > end {
            break;
        }
        let payload_start = pos + hdr_len;
        let box_end = pos + box_size;

        if box_type == target {
            return Some((payload_start, box_end));
        }

        pos = box_end;
    }
    None
}

struct StagedMp4Atom<'a> {
    atom_id: &'a [u8],
    mean_str: Option<String>,
    name_str: Option<String>,
    data_entries: Vec<(u32, &'a [u8])>,
}

fn parse_mp4_ilst_bytes(
    buf: &[u8],
    collect_raw: bool,
    include_pictures: bool,
) -> Mp4IlstParsedTags {
    // Pass 1: Stage all atoms so we can detect ONE shared tag-wide encoding across text atoms.
    let mut staged: Vec<StagedMp4Atom<'_>> = Vec::new();
    let mut text_samples: Vec<&[u8]> = Vec::new();

    let mut pos = 0usize;
    while pos + 8 <= buf.len() {
        let size = u32::from_be_bytes(buf[pos..pos + 4].try_into().unwrap()) as usize;
        if size < 8 || pos + size > buf.len() {
            break;
        }
        let atom_id = &buf[pos + 4..pos + 8];
        let body = &buf[pos + 8..pos + size];
        pos += size;

        let mut mean_str: Option<String> = None;
        let mut name_str: Option<String> = None;
        let mut data_entries: Vec<(u32, &[u8])> = Vec::new();

        let mut cpos = 0usize;
        while cpos + 8 <= body.len() {
            let csize = u32::from_be_bytes(body[cpos..cpos + 4].try_into().unwrap()) as usize;
            if csize < 8 || cpos + csize > body.len() {
                break;
            }
            let ctype = &body[cpos + 4..cpos + 8];
            let cbody = &body[cpos + 8..cpos + csize];
            cpos += csize;

            match ctype {
                b"mean" if cbody.len() > 4 => {
                    mean_str = Some(String::from_utf8_lossy(&cbody[4..]).into_owned());
                }
                b"name" if cbody.len() > 4 => {
                    name_str = Some(String::from_utf8_lossy(&cbody[4..]).into_owned());
                }
                b"data" if cbody.len() >= 8 => {
                    let type_ind = u32::from_be_bytes([0, cbody[1], cbody[2], cbody[3]]);
                    data_entries.push((type_ind, &cbody[8..]));
                }
                _ => {}
            }
        }

        if data_entries.is_empty() {
            continue;
        }

        let is_text_atom = matches!(
            atom_id,
            b"aART"
                | b"\xa9nam"
                | b"\xa9ART"
                | b"\xa9alb"
                | b"\xa9day"
                | b"\xa9gen"
                | b"\xa9wrt"
                | b"\xa9lyr"
                | b"\xa9pub"
                | b"----"
        );
        if is_text_atom {
            for &(dt, p) in &data_entries {
                if !matches!(dt, 2 | 3 | 5) && !p.is_empty() {
                    text_samples.push(p);
                }
            }
        }

        staged.push(StagedMp4Atom {
            atom_id,
            mean_str,
            name_str,
            data_entries,
        });
    }

    let block_encoding = if text_samples.is_empty() {
        DetectedEncoding::Utf8
    } else {
        let enc = detect_tag_block_encoding(&text_samples);
        if enc == DetectedEncoding::Ascii {
            DetectedEncoding::Utf8
        } else {
            enc
        }
    };

    let mut out = Mp4IlstParsedTags {
        detected_encoding: block_encoding,
        ..Default::default()
    };

    let mut freeform_aa_exact: Option<String> = None;
    let mut freeform_aa_alias: Option<String> = None;
    let mut aart_album_artist: Option<String> = None;
    let mut cpub_record_label: Option<String> = None;
    let mut freeform_label: Option<String> = None;
    let mut freeform_publisher: Option<String> = None;
    let mut artist_values: Vec<String> = Vec::new();

    for atom in staged {
        let &(data_type, payload) = &atom.data_entries[0];
        let atom_label = format_atom_label(
            atom.atom_id,
            atom.mean_str.as_deref(),
            atom.name_str.as_deref(),
        );

        let decode_text = |dt: u32, p: &[u8], multiline: bool| -> String {
            let raw = match dt {
                2 | 5 => encoding_rs::UTF_16BE.decode(p).0.into_owned(),
                3 => encoding_rs::SHIFT_JIS.decode(p).0.into_owned(),
                _ => decode_bytes_with_encoding(p, block_encoding),
            };
            if multiline {
                sanitize_multiline_tag_text(&raw)
            } else {
                sanitize_tag_text(&raw)
            }
        };

        let mut summary = String::new();
        match atom.atom_id {
            b"trkn" => {
                if payload.len() >= 4 {
                    let num = u16::from_be_bytes([payload[2], payload[3]]);
                    let total = if payload.len() >= 6 {
                        u16::from_be_bytes([payload[4], payload[5]])
                    } else {
                        0
                    };
                    summary = if total > 0 {
                        format!("{num}/{total}")
                    } else {
                        num.to_string()
                    };
                    if num > 0 && out.track_number.is_none() {
                        out.track_number = Some(num);
                    }
                }
            }
            b"disk" => {
                if payload.len() >= 4 {
                    let num = u16::from_be_bytes([payload[2], payload[3]]);
                    let total = if payload.len() >= 6 {
                        u16::from_be_bytes([payload[4], payload[5]])
                    } else {
                        0
                    };
                    summary = if total > 0 {
                        format!("{num}/{total}")
                    } else {
                        num.to_string()
                    };
                    if num > 0 && out.disc_number.is_none() {
                        out.disc_number = Some(num);
                    }
                }
            }
            b"aART" => {
                let vals = decode_all_text(&atom.data_entries, &decode_text);
                if !vals.is_empty() {
                    let joined = vals.join("; ");
                    summary = joined.clone();
                    if aart_album_artist.is_none() {
                        aart_album_artist = Some(joined);
                    }
                }
            }
            b"\xa9nam" => {
                let s = decode_text(data_type, payload, false);
                summary = s.clone();
                if !s.is_empty() && out.title.is_none() {
                    out.title = Some(s);
                }
            }
            b"\xa9ART" => {
                let vals = decode_all_text(&atom.data_entries, &decode_text);
                if !vals.is_empty() {
                    summary = vals.join("; ");
                    for v in vals {
                        if !artist_values.iter().any(|e| e.eq_ignore_ascii_case(&v)) {
                            artist_values.push(v);
                        }
                    }
                }
            }
            b"\xa9alb" => {
                let s = decode_text(data_type, payload, false);
                summary = s.clone();
                if !s.is_empty() && out.album.is_none() {
                    out.album = Some(s);
                }
            }
            b"\xa9day" => {
                let s = decode_text(data_type, payload, false);
                summary = s.clone();
                if out.release_year.is_none() {
                    out.release_year = parse_year(&s);
                }
            }
            b"\xa9gen" => {
                let s = decode_text(data_type, payload, false);
                summary = s.clone();
                if !s.is_empty() && out.genre.is_none() {
                    out.genre = Some(s);
                }
            }
            b"\xa9wrt" => {
                let vals = decode_all_text(&atom.data_entries, &decode_text);
                if !vals.is_empty() {
                    let joined = vals.join("; ");
                    summary = joined.clone();
                    if out.composer.is_none() {
                        out.composer = Some(joined);
                    }
                }
            }
            b"\xa9lyr" => {
                let clean = decode_text(data_type, payload, true);
                if !clean.is_empty() {
                    summary = format!("[lyrics, {} chars]", clean.chars().count());
                    if out.lyrics.is_none() {
                        out.lyrics = Some(clean);
                    }
                }
            }
            b"\xa9pub" => {
                let s = decode_text(data_type, payload, false);
                summary = s.clone();
                if !s.is_empty() && cpub_record_label.is_none() {
                    cpub_record_label = Some(s);
                }
            }
            b"cpil" => {
                if let Some(&b) = payload.first() {
                    summary = b.to_string();
                    if out.compilation.is_none() {
                        out.compilation = Some(b != 0);
                    }
                }
            }
            b"covr" => {
                summary = format!("[cover art, {} bytes]", payload.len());
                if include_pictures {
                    for &(dt, p) in &atom.data_entries {
                        if !p.is_empty() {
                            let mime = match dt {
                                14 => "image/png",
                                13 => "image/jpeg",
                                _ if p.starts_with(&[0x89, b'P', b'N', b'G']) => "image/png",
                                _ => "image/jpeg",
                            };
                            out.pictures.push(ExtractedPicture {
                                picture_type: PictureType::FrontCover,
                                mime_type: mime.to_string(),
                                data: p.to_vec(),
                            });
                        }
                    }
                }
            }
            b"----" => {
                let vals = decode_all_text(&atom.data_entries, &decode_text);
                let s = vals.join("; ");
                summary = s.clone();
                if let Some(ref name) = atom.name_str {
                    let upper = name.trim().to_ascii_uppercase();
                    let norm = normalize_custom_tag_key(name);
                    if !s.is_empty() && matches!(norm.as_str(), "ALBUMARTIST" | "ALBUMARTISTS") {
                        if upper == "ALBUMARTIST" {
                            if freeform_aa_exact.is_none() {
                                freeform_aa_exact = Some(s);
                            }
                        } else if freeform_aa_alias.is_none() {
                            freeform_aa_alias = Some(s);
                        }
                    } else if !s.is_empty() && matches!(norm.as_str(), "LABEL" | "RECORDLABEL") {
                        if freeform_label.is_none() {
                            freeform_label = Some(s);
                        }
                    } else if !s.is_empty() && norm == "PUBLISHER" && freeform_publisher.is_none() {
                        freeform_publisher = Some(s);
                    }
                }
            }
            _ => {
                if collect_raw && matches!(data_type, 0..=5) {
                    summary = decode_text(data_type, payload, false);
                }
            }
        }

        if collect_raw {
            let raw_store = if atom.atom_id == b"covr" {
                Vec::new()
            } else {
                payload[..payload.len().min(256)].to_vec()
            };
            out.raw_atoms.push((atom_label, raw_store, summary));
        }
    }

    if !artist_values.is_empty() {
        out.artist = Some(artist_values.join("; "));
        out.artists = artist_values;
    }

    // Strict ALBUMARTIST precedence: ----:ALBUMARTIST > ----:ALBUM ARTIST > aART
    out.album_artist = freeform_aa_exact
        .or(freeform_aa_alias)
        .or(aart_album_artist);
    out.record_label = freeform_label.or(cpub_record_label).or(freeform_publisher);
    out
}

fn decode_all_text<F>(entries: &[(u32, &[u8])], decode_fn: &F) -> Vec<String>
where
    F: Fn(u32, &[u8], bool) -> String,
{
    let mut vals = Vec::new();
    for &(dt, p) in entries {
        let s = decode_fn(dt, p, false);
        if !s.is_empty() && !vals.iter().any(|e: &String| e.eq_ignore_ascii_case(&s)) {
            vals.push(s);
        }
    }
    vals
}

fn format_atom_label(atom_id: &[u8], mean: Option<&str>, name: Option<&str>) -> String {
    if atom_id == b"----" {
        format!("----:{}:{}", mean.unwrap_or(""), name.unwrap_or(""))
    } else {
        atom_id
            .iter()
            .map(|&b| {
                if b == 0xA9 {
                    '©'
                } else if b.is_ascii_graphic() || b == b' ' {
                    b as char
                } else {
                    '?'
                }
            })
            .collect()
    }
}
