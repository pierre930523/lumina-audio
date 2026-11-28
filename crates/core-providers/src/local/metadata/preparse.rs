use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::path::Path;

use core_types::AudioCodec;

use super::aiff::scan_aiff_from_reader;
use super::id3v1::{parse_id3v1_from_reader, parse_id3v1_from_slice};
use super::mp4::scan_mp4_ilst_from_reader_ext;
use super::{AiffParsedTags, Id3v1ParsedTags, Mp4IlstParsedTags};
use crate::local::ape_meta::{ApeParsedTags, parse_ape_from_reader, parse_ape_from_slice};
use crate::local::dsd_meta::{
    Id3v2ParsedTags, parse_id3v2_footer_from_reader_ext, parse_id3v2_footer_from_slice_ext,
    parse_id3v2_from_reader_ext, parse_id3v2_from_slice_ext,
};

#[derive(Default)]
pub(super) struct PreParsedTags {
    pub(super) id3v2: Option<Id3v2ParsedTags>,
    pub(super) ape: Option<ApeParsedTags>,
    pub(super) id3v1: Option<Id3v1ParsedTags>,
    pub(super) mp4_ilst: Option<Mp4IlstParsedTags>,
    pub(super) aiff: Option<AiffParsedTags>,
}

pub(crate) fn scan_id3v2_from_reader<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Option<Id3v2ParsedTags> {
    scan_id3v2_from_reader_ext(reader, collect_raw, true)
}

pub(super) fn scan_id3v2_from_reader_ext<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
    include_pictures: bool,
) -> Option<Id3v2ParsedTags> {
    if reader.seek(SeekFrom::Start(0)).is_ok() {
        let mut magic = [0u8; 3];
        if reader.read_exact(&mut magic).is_ok() && &magic == b"ID3" {
            let _ = reader.seek(SeekFrom::Start(0));
            if let Some(tags) = parse_id3v2_from_reader_ext(reader, collect_raw, include_pictures) {
                return Some(tags);
            }
        }
    }
    parse_id3v2_footer_from_reader_ext(reader, collect_raw, include_pictures)
}

pub(super) fn scan_preparsed_tags_from_file(
    path: &Path,
    ext: &str,
    collect_raw: bool,
    include_pictures: bool,
) -> PreParsedTags {
    let mut pre = PreParsedTags::default();
    let Ok(mut file) = File::open(path) else {
        return pre;
    };

    match ext {
        "mp3" | "aac" => {
            pre.id3v2 = scan_id3v2_from_reader_ext(&mut file, collect_raw, include_pictures);
            pre.ape = parse_ape_from_reader(&mut file);
            if ext == "mp3" {
                pre.id3v1 = parse_id3v1_from_reader(&mut file, collect_raw);
            }
        }
        "aiff" | "aif" => {
            pre.aiff = scan_aiff_from_reader(&mut file, collect_raw);
        }
        "m4a" | "mp4" | "alac" => {
            pre.mp4_ilst = scan_mp4_ilst_from_reader_ext(&mut file, collect_raw, include_pictures);
        }
        "flac" | "ogg" | "opus" => {
            pre.id3v2 = scan_id3v2_from_reader_ext(&mut file, collect_raw, include_pictures);
            pre.ape = parse_ape_from_reader(&mut file);
        }
        _ => {}
    }

    pre
}

pub(super) fn scan_preparsed_tags_from_slice(
    bytes: &[u8],
    ext: &str,
    collect_raw: bool,
    include_pictures: bool,
) -> PreParsedTags {
    let mut pre = PreParsedTags::default();
    let mut cursor = Cursor::new(bytes);

    match ext {
        "mp3" | "aac" => {
            pre.id3v2 =
                parse_id3v2_from_slice_ext(bytes, collect_raw, include_pictures).or_else(|| {
                    parse_id3v2_footer_from_slice_ext(bytes, collect_raw, include_pictures)
                });
            pre.ape = parse_ape_from_slice(bytes);
            if ext == "mp3" {
                pre.id3v1 = parse_id3v1_from_slice(bytes, collect_raw);
            }
        }
        "aiff" | "aif" => {
            pre.aiff = scan_aiff_from_reader(&mut cursor, collect_raw);
        }
        "m4a" | "mp4" | "alac" => {
            pre.mp4_ilst =
                scan_mp4_ilst_from_reader_ext(&mut cursor, collect_raw, include_pictures);
        }
        "flac" | "ogg" | "opus" => {
            pre.id3v2 = parse_id3v2_from_slice_ext(bytes, collect_raw, include_pictures);
            pre.ape = parse_ape_from_slice(bytes);
        }
        _ => {}
    }

    pre
}

pub(super) fn map_extension_to_codec(ext: &str) -> AudioCodec {
    match ext.to_ascii_lowercase().as_str() {
        "flac" => AudioCodec::Flac,
        "alac" => AudioCodec::Alac,
        "m4a" => AudioCodec::Alac,
        "wav" | "wave" => AudioCodec::Wav,
        "aiff" | "aif" => AudioCodec::Aiff,
        "dsf" => AudioCodec::Dsf,
        "dff" => AudioCodec::Dsdiff,
        "mp3" => AudioCodec::Mp3,
        "aac" => AudioCodec::Aac,
        "ogg" => AudioCodec::Opus,
        "opus" => AudioCodec::Opus,
        _ => AudioCodec::Flac,
    }
}
