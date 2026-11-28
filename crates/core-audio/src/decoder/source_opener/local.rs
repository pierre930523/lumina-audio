use std::fs::File;
use std::path::Path;

use crate::decoder::dsd::{DsdiffReader, DsfReader};
use crate::decoder::pcm::{AudioDecoder, SymphoniaDecoder};
use crate::error::CoreAudioError;

pub fn open_decoder_for_path(path: &Path) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    match ext.as_str() {
        "dsf" => {
            let file = File::open(path)?;
            let reader = DsfReader::new(file)?;
            Ok(Box::new(reader))
        }
        "dff" | "dsdiff" => {
            let file = File::open(path)?;
            let reader = DsdiffReader::new(file)?;
            Ok(Box::new(reader))
        }
        _ => {
            let decoder = SymphoniaDecoder::from_file(path)?;
            Ok(Box::new(decoder))
        }
    }
}

pub(super) fn infer_extension_from_url(url: &str) -> Option<String> {
    let without_frag = url.split('#').next().unwrap_or(url);
    let without_query = without_frag.split('?').next().unwrap_or(without_frag);
    let last_seg = without_query.rsplit('/').next()?;
    let dot_idx = last_seg.rfind('.')?;
    let ext = &last_seg[dot_idx + 1..];
    if (1..=6).contains(&ext.len()) && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        Some(ext.to_ascii_lowercase())
    } else {
        None
    }
}

pub fn infer_extension_from_magic(magic: &[u8]) -> Option<&'static str> {
    if magic.starts_with(b"fLaC") {
        Some("flac")
    } else if magic.len() >= 12 && &magic[0..4] == b"RIFF" && &magic[8..12] == b"WAVE" {
        Some("wav")
    } else if magic.starts_with(b"FORM") {
        Some("aiff")
    } else if magic.starts_with(b"OggS") {
        Some("ogg")
    } else if magic.len() >= 2 && magic[0] == 0xFF && (magic[1] & 0xF6) == 0xF0 {
        Some("aac")
    } else if magic.starts_with(b"ID3")
        || (magic.len() >= 2
            && magic[0] == 0xFF
            && (magic[1] & 0xE0) == 0xE0
            && (magic[1] & 0x06) != 0)
    {
        Some("mp3")
    } else if magic.len() >= 8 && &magic[4..8] == b"ftyp" {
        Some("m4a")
    } else if magic.starts_with(b"\x1A\x45\xDF\xA3") {
        Some("webm")
    } else {
        None
    }
}
