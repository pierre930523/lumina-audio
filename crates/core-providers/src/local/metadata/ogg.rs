use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat};

use super::accumulator::TagAccumulator;
use super::vorbis_comments::apply_vorbis_comments;
use super::{ExtractOptions, ExtractedMetadata};
use crate::error::ProviderError;
use crate::local::ape_meta::parse_ape_from_reader;
use crate::local::dsd_meta::{Id3v2ParsedTags, decode_syncsafe, parse_id3v2_body_ext};

const MAX_COMMENT_PACKET_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OggStreamKind {
    Opus,
    Vorbis,
    Flac,
}

struct OggStreamInfo {
    kind: OggStreamKind,
    codec: AudioCodec,
    sample_rate: u32,
    channels: u8,
    bit_depth: u8,
    pre_skip: u64,
    flac_total_samples: u64,
}

/// Native OGG / OPUS (Ogg Vorbis, Ogg Opus, Ogg FLAC) metadata parser.
///
/// Strictly prioritizes Vorbis Comments / OpusTags over any non-standard prepended ID3v2 or
/// trailing APEv2: whenever a valid VorbisComment / OpusTags packet is present, residual ID3v2
/// and APEv2 blocks are completely ignored.
pub(super) fn extract_ogg_from_reader<R: Read + Seek>(
    mut reader: R,
    fallback_path: &Path,
    opts: ExtractOptions,
) -> Result<ExtractedMetadata, ProviderError> {
    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic)?;

    let mut id3_fallback: Option<Id3v2ParsedTags> = None;
    if &magic[0..3] == b"ID3" {
        let mut hdr_tail = [0u8; 6];
        reader.read_exact(&mut hdr_tail)?;
        let major = magic[3];
        let flags = hdr_tail[1];
        let tag_size = decode_syncsafe(&hdr_tail[2..6]) as usize;
        if tag_size > 16 * 1024 * 1024 {
            return Err(ProviderError::UnsupportedFormat(
                "OGG prepended ID3v2 tag exceeds maximum size".to_string(),
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
                false,
                opts.include_pictures,
            ));
        }

        // Advance past optional zero padding to "OggS"
        let mut b = [0u8; 1];
        let mut found = false;
        while reader.read_exact(&mut b).is_ok() {
            if b[0] != 0 {
                let mut rest = [0u8; 3];
                reader.read_exact(&mut rest)?;
                magic = [b[0], rest[0], rest[1], rest[2]];
                found = true;
                break;
            }
        }
        if !found {
            return Err(ProviderError::UnsupportedFormat(
                "Missing OggS stream marker after prepended ID3v2".to_string(),
            ));
        }
    }

    if &magic != b"OggS" {
        return Err(ProviderError::UnsupportedFormat(
            "Not a valid Ogg container (missing OggS magic)".to_string(),
        ));
    }

    // Rewind 4 bytes so packet reader starts at the first OggS page
    reader.seek(SeekFrom::Current(-4))?;

    let (serial, packets) = read_initial_ogg_packets(&mut reader, 2)?;
    let ident = packets.first().ok_or_else(|| {
        ProviderError::UnsupportedFormat("Ogg stream missing identification packet".to_string())
    })?;

    let info = parse_ogg_ident_packet(ident)?;

    let mut staged_comments: Vec<(String, Vec<u8>)> = Vec::new();
    let mut saw_comment_packet = false;

    if let Some(comment_pkt) = packets.get(1) {
        if let Some(parsed) = parse_ogg_comment_packet(info.kind, comment_pkt) {
            saw_comment_packet = true;
            staged_comments = parsed;
        }
    }

    let duration_ms = match info.kind {
        OggStreamKind::Flac if info.flac_total_samples > 0 && info.sample_rate > 0 => {
            ((info.flac_total_samples * 1000) / u64::from(info.sample_rate)).max(1)
        }
        _ => estimate_ogg_duration_ms(&mut reader, serial, info.sample_rate, info.pre_skip),
    };

    let mut acc = TagAccumulator::default();
    if saw_comment_packet {
        apply_vorbis_comments(&staged_comments, &mut acc, opts.include_pictures);
    } else {
        // Fallback to prepended ID3v2 / trailing APEv2 ONLY when VorbisComment/OpusTags is absent
        if let Some(id3) = id3_fallback {
            acc.apply_id3v2(id3, opts.include_pictures);
        }
        if let Some(ape) = parse_ape_from_reader(&mut reader) {
            acc.apply_ape(ape, opts.include_pictures);
        }
    }

    let format = AudioFormat::pcm(
        info.codec,
        info.sample_rate.max(8000),
        info.bit_depth.clamp(8, 32),
        info.channels.clamp(1, 8),
    )?;

    Ok(acc.finalize(fallback_path, format, duration_ms))
}

fn read_initial_ogg_packets<R: Read>(
    reader: &mut R,
    max_packets: usize,
) -> Result<(u32, Vec<Vec<u8>>), ProviderError> {
    let mut packets: Vec<Vec<u8>> = Vec::with_capacity(max_packets);
    let mut current: Vec<u8> = Vec::new();
    let mut target_serial: Option<u32> = None;

    for _ in 0..512 {
        let mut hdr = [0u8; 27];
        if reader.read_exact(&mut hdr).is_err() {
            break;
        }
        if &hdr[0..4] != b"OggS" {
            break;
        }
        let header_type = hdr[5];
        let serial = u32::from_le_bytes(hdr[14..18].try_into().unwrap());
        let page_segments = hdr[26] as usize;

        let mut lace = vec![0u8; page_segments];
        reader.read_exact(&mut lace)?;
        let body_len: usize = lace.iter().map(|&b| b as usize).sum();

        if let Some(ts) = target_serial {
            if serial != ts {
                let mut skip = vec![0u8; body_len];
                reader.read_exact(&mut skip)?;
                continue;
            }
        } else {
            target_serial = Some(serial);
        }

        let mut body = vec![0u8; body_len];
        reader.read_exact(&mut body)?;

        if (header_type & 0x01) == 0 && !current.is_empty() {
            packets.push(std::mem::take(&mut current));
            if packets.len() >= max_packets {
                break;
            }
        }

        let mut pos = 0usize;
        for &seg_len in &lace {
            let sl = seg_len as usize;
            if pos + sl > body.len() {
                break;
            }
            if current.len() + sl <= MAX_COMMENT_PACKET_BYTES {
                current.extend_from_slice(&body[pos..pos + sl]);
            }
            pos += sl;
            if seg_len < 255 {
                packets.push(std::mem::take(&mut current));
                if packets.len() >= max_packets {
                    return Ok((target_serial.unwrap_or(0), packets));
                }
            }
        }
    }

    if !current.is_empty() && packets.len() < max_packets {
        packets.push(current);
    }
    Ok((target_serial.unwrap_or(0), packets))
}

fn parse_ogg_ident_packet(pkt: &[u8]) -> Result<OggStreamInfo, ProviderError> {
    if pkt.len() >= 19 && &pkt[0..8] == b"OpusHead" {
        let channels = pkt[9].clamp(1, 8);
        let pre_skip = u64::from(u16::from_le_bytes([pkt[10], pkt[11]]));
        return Ok(OggStreamInfo {
            kind: OggStreamKind::Opus,
            codec: AudioCodec::Opus,
            sample_rate: 48_000,
            channels,
            bit_depth: 16,
            pre_skip,
            flac_total_samples: 0,
        });
    }

    if pkt.len() >= 16 && &pkt[0..7] == b"\x01vorbis" {
        let channels = pkt[11].clamp(1, 8);
        let sample_rate = u32::from_le_bytes(pkt[12..16].try_into().unwrap());
        if sample_rate == 0 {
            return Err(ProviderError::UnsupportedFormat(
                "Invalid Ogg Vorbis sample rate (0)".to_string(),
            ));
        }
        return Ok(OggStreamInfo {
            kind: OggStreamKind::Vorbis,
            codec: AudioCodec::Opus,
            sample_rate,
            channels,
            bit_depth: 16,
            pre_skip: 0,
            flac_total_samples: 0,
        });
    }

    if pkt.len() >= 51 && &pkt[0..5] == b"\x7fFLAC" && &pkt[9..13] == b"fLaC" {
        let b = &pkt[27..35];
        let sr = ((b[0] as u32) << 12) | ((b[1] as u32) << 4) | ((b[2] as u32) >> 4);
        let ch = ((b[2] >> 1) & 0x07) + 1;
        let bps = (((b[2] & 0x01) << 4) | (b[3] >> 4)) + 1;
        let total_samples = (((b[3] & 0x0F) as u64) << 32)
            | ((b[4] as u64) << 24)
            | ((b[5] as u64) << 16)
            | ((b[6] as u64) << 8)
            | (b[7] as u64);
        if sr > 0 {
            return Ok(OggStreamInfo {
                kind: OggStreamKind::Flac,
                codec: AudioCodec::Flac,
                sample_rate: sr,
                channels: ch,
                bit_depth: bps,
                pre_skip: 0,
                flac_total_samples: total_samples,
            });
        }
    }

    Err(ProviderError::UnsupportedFormat(
        "Unrecognized Ogg audio codec identification packet".to_string(),
    ))
}

fn parse_ogg_comment_packet(kind: OggStreamKind, pkt: &[u8]) -> Option<Vec<(String, Vec<u8>)>> {
    let payload = match kind {
        OggStreamKind::Opus => {
            if pkt.len() >= 16 && &pkt[0..8] == b"OpusTags" {
                &pkt[8..]
            } else {
                return None;
            }
        }
        OggStreamKind::Vorbis => {
            if pkt.len() >= 15 && &pkt[0..7] == b"\x03vorbis" {
                &pkt[7..]
            } else {
                return None;
            }
        }
        OggStreamKind::Flac => {
            if pkt.len() >= 12 && (pkt[0] & 0x7F) == 4 {
                &pkt[4..]
            } else {
                return None;
            }
        }
    };

    if payload.len() < 8 {
        return None;
    }
    let vendor_len = u32::from_le_bytes(payload[0..4].try_into().unwrap()) as usize;
    let mut cursor = 4usize.checked_add(vendor_len)?;
    if cursor + 4 > payload.len() {
        return None;
    }
    let count = u32::from_le_bytes(payload[cursor..cursor + 4].try_into().unwrap()) as usize;
    cursor += 4;

    let mut entries = Vec::with_capacity(count.min(64));
    for _ in 0..count {
        if cursor + 4 > payload.len() {
            break;
        }
        let c_len = u32::from_le_bytes(payload[cursor..cursor + 4].try_into().unwrap()) as usize;
        cursor += 4;
        if cursor + c_len > payload.len() {
            break;
        }
        let raw_entry = &payload[cursor..cursor + c_len];
        cursor += c_len;
        if let Some(eq_pos) = raw_entry.iter().position(|&b| b == b'=') {
            let raw_k = String::from_utf8_lossy(&raw_entry[..eq_pos]).into_owned();
            let raw_v = raw_entry[eq_pos + 1..].to_vec();
            entries.push((raw_k, raw_v));
        }
    }
    Some(entries)
}

fn estimate_ogg_duration_ms<R: Read + Seek>(
    reader: &mut R,
    target_serial: u32,
    sample_rate: u32,
    pre_skip: u64,
) -> u64 {
    let Ok(file_len) = reader.seek(SeekFrom::End(0)) else {
        return 1000;
    };
    let tail_len = file_len.min(64 * 1024) as usize;
    if reader
        .seek(SeekFrom::Start(file_len - tail_len as u64))
        .is_err()
    {
        return 1000;
    }
    let mut tail = vec![0u8; tail_len];
    if reader.read_exact(&mut tail).is_err() {
        return 1000;
    }

    // Scan backwards for the last valid OggS page belonging to `target_serial`
    let mut pos = tail.len().saturating_sub(27);
    loop {
        if pos + 27 <= tail.len() && &tail[pos..pos + 4] == b"OggS" {
            let serial = u32::from_le_bytes(tail[pos + 14..pos + 18].try_into().unwrap());
            let granule = i64::from_le_bytes(tail[pos + 6..pos + 14].try_into().unwrap());
            if serial == target_serial && granule > 0 && sample_rate > 0 {
                let effective = (granule as u64).saturating_sub(pre_skip);
                return ((effective * 1000) / u64::from(sample_rate)).max(1);
            }
        }
        if pos == 0 {
            break;
        }
        pos -= 1;
    }
    1000
}
