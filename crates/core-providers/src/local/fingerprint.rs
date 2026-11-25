use std::fmt::Write as _;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

use core_types::ContentFingerprint;
use sha2::{Digest, Sha256};

use super::dsd_meta::decode_syncsafe;

const WINDOW_BYTES: u64 = 64 * 1024;
const FULL_HASH_THRESHOLD: u64 = WINDOW_BYTES * 3; // 192 KB

/// Computes a lightweight, tag-independent content fingerprint over an audio file's
/// audio payload range: SHA-256 of `audio_byte_len` (LE u64) + head/mid/tail 64 KB
/// payload windows (or the entire payload when `<= 192 KB`).
///
/// Skipping container metadata headers/footers (FLAC metadata blocks, ID3v2/ID3v1/APEv2,
/// WAV non-`data` chunks, DSF metadata tail) ensures tag/artwork edits keep the same identity.
pub fn compute_content_fingerprint(path: &Path) -> io::Result<ContentFingerprint> {
    let mut file = File::open(path)?;
    let file_len = file.metadata()?.len();
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    let (mut start, mut end) = locate_audio_payload_range(&mut file, file_len, &ext);
    if end <= start || end > file_len {
        start = 0;
        end = file_len;
    }

    let audio_byte_len = end.saturating_sub(start);
    let mut hasher = Sha256::new();
    hasher.update(audio_byte_len.to_le_bytes());

    if audio_byte_len > 0 {
        if audio_byte_len <= FULL_HASH_THRESHOLD {
            hash_window(&mut file, start, audio_byte_len, &mut hasher)?;
        } else {
            let mid_start = start + (audio_byte_len - WINDOW_BYTES) / 2;
            let tail_start = end - WINDOW_BYTES;
            hash_window(&mut file, start, WINDOW_BYTES, &mut hasher)?;
            hash_window(&mut file, mid_start, WINDOW_BYTES, &mut hasher)?;
            hash_window(&mut file, tail_start, WINDOW_BYTES, &mut hasher)?;
        }
    }

    let digest = hasher.finalize();
    let mut hash_hex = String::with_capacity(64);
    for b in digest {
        let _ = write!(&mut hash_hex, "{b:02x}");
    }

    Ok(ContentFingerprint {
        hash_hex,
        audio_byte_len,
    })
}

fn hash_window(
    file: &mut File,
    offset: u64,
    len: u64,
    hasher: &mut Sha256,
) -> io::Result<()> {
    file.seek(SeekFrom::Start(offset))?;
    let mut remaining = len as usize;
    let mut buf = [0u8; 16 * 1024];
    while remaining > 0 {
        let to_read = remaining.min(buf.len());
        let n = file.read(&mut buf[..to_read])?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        remaining -= n;
    }
    Ok(())
}

fn locate_audio_payload_range(file: &mut File, file_len: u64, ext: &str) -> (u64, u64) {
    if file_len == 0 {
        return (0, 0);
    }

    match ext {
        "flac" => {
            if let Some(range) = locate_flac_payload(file, file_len) {
                return range;
            }
        }
        "wav" | "wave" => {
            if let Some(range) = locate_wav_data_payload(file, file_len) {
                return range;
            }
        }
        "dsf" => {
            if let Some(range) = locate_dsf_data_payload(file, file_len) {
                return range;
            }
        }
        _ => {}
    }

    let start = skip_leading_id3v2(file, file_len);
    let end = strip_trailing_tags(file, start, file_len);
    if end > start {
        (start, end)
    } else {
        (0, file_len)
    }
}

fn skip_leading_id3v2(file: &mut File, file_len: u64) -> u64 {
    if file_len < 10 {
        return 0;
    }
    if file.seek(SeekFrom::Start(0)).is_err() {
        return 0;
    }
    let mut hdr = [0u8; 10];
    if file.read_exact(&mut hdr).is_err() || &hdr[0..3] != b"ID3" {
        return 0;
    }
    let flags = hdr[5];
    let body_len = u64::from(decode_syncsafe(&hdr[6..10]));
    let footer_len = if (flags & 0x10) != 0 { 10 } else { 0 };
    let end_pos = 10u64.saturating_add(body_len).saturating_add(footer_len);
    if end_pos < file_len {
        end_pos
    } else {
        0
    }
}

fn strip_trailing_tags(file: &mut File, min_start: u64, mut end: u64) -> u64 {
    // Strip ID3v1 (128 bytes starting with "TAG")
    if end >= min_start + 128 && file.seek(SeekFrom::Start(end - 128)).is_ok() {
        let mut magic = [0u8; 3];
        if file.read_exact(&mut magic).is_ok() && &magic == b"TAG" {
            end -= 128;
        }
    }

    // Strip APEv2 footer (32 bytes starting with "APETAGEX")
    if end >= min_start + 32 && file.seek(SeekFrom::Start(end - 32)).is_ok() {
        let mut footer = [0u8; 32];
        if file.read_exact(&mut footer).is_ok() && &footer[0..8] == b"APETAGEX" {
            let tag_size = u64::from(u32::from_le_bytes(footer[12..16].try_into().unwrap()));
            let flags = u32::from_le_bytes(footer[20..24].try_into().unwrap());
            let has_header = (flags & (1 << 31)) != 0;
            let total = tag_size.saturating_add(if has_header { 32 } else { 0 });
            if total >= 32 && end >= min_start + total {
                end -= total;
            }
        }
    }

    end
}

fn locate_flac_payload(file: &mut File, file_len: u64) -> Option<(u64, u64)> {
    let mut pos = skip_leading_id3v2(file, file_len);
    file.seek(SeekFrom::Start(pos)).ok()?;

    // Skip any zero padding between ID3v2 and fLaC marker
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).ok()?;
    pos += 4;
    if &magic != b"fLaC" {
        return None;
    }

    loop {
        let mut hdr = [0u8; 4];
        file.read_exact(&mut hdr).ok()?;
        let is_last = (hdr[0] & 0x80) != 0;
        let block_len =
            ((u64::from(hdr[1])) << 16) | ((u64::from(hdr[2])) << 8) | u64::from(hdr[3]);
        pos = pos.checked_add(4)?.checked_add(block_len)?;
        if pos > file_len {
            return None;
        }
        file.seek(SeekFrom::Start(pos)).ok()?;
        if is_last {
            break;
        }
    }

    let end = strip_trailing_tags(file, pos, file_len);
    (end > pos).then_some((pos, end))
}

fn locate_wav_data_payload(file: &mut File, file_len: u64) -> Option<(u64, u64)> {
    if file_len < 12 {
        return None;
    }
    file.seek(SeekFrom::Start(0)).ok()?;
    let mut hdr = [0u8; 12];
    file.read_exact(&mut hdr).ok()?;
    if (&hdr[0..4] != b"RIFF" && &hdr[0..4] != b"RF64") || &hdr[8..12] != b"WAVE" {
        return None;
    }

    let mut pos = 12u64;
    while pos + 8 <= file_len {
        file.seek(SeekFrom::Start(pos)).ok()?;
        let mut chunk_hdr = [0u8; 8];
        if file.read_exact(&mut chunk_hdr).is_err() {
            break;
        }
        let chunk_size = u64::from(u32::from_le_bytes(chunk_hdr[4..8].try_into().unwrap()));
        let payload_start = pos + 8;
        if &chunk_hdr[0..4] == b"data" {
            let payload_end = payload_start.saturating_add(chunk_size).min(file_len);
            if payload_end > payload_start {
                return Some((payload_start, payload_end));
            }
            return None;
        }
        let padded = chunk_size + (chunk_size % 2);
        pos = payload_start.checked_add(padded)?;
    }

    None
}

fn locate_dsf_data_payload(file: &mut File, file_len: u64) -> Option<(u64, u64)> {
    if file_len < 92 {
        return None;
    }
    file.seek(SeekFrom::Start(0)).ok()?;
    let mut dsd_hdr = [0u8; 28];
    file.read_exact(&mut dsd_hdr).ok()?;
    if &dsd_hdr[0..4] != b"DSD " {
        return None;
    }
    let metadata_offset = u64::from_le_bytes(dsd_hdr[20..28].try_into().unwrap());

    // DSF 'fmt ' chunk is 52 bytes starting at offset 28 -> 'data' chunk at offset 80
    file.seek(SeekFrom::Start(80)).ok()?;
    let mut data_hdr = [0u8; 12];
    file.read_exact(&mut data_hdr).ok()?;
    if &data_hdr[0..4] != b"data" {
        return None;
    }
    let chunk_size = u64::from_le_bytes(data_hdr[4..12].try_into().unwrap());
    let payload_start = 92u64;
    let mut payload_end = 80u64.saturating_add(chunk_size).min(file_len);
    if metadata_offset > payload_start && metadata_offset < payload_end {
        payload_end = metadata_offset;
    }
    (payload_end > payload_start).then_some((payload_start, payload_end))
}
