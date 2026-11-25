use std::borrow::Cow;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat, ExtractedPicture, PictureType};

use super::lyrics::decode_text_cjk;
use crate::error::ProviderError;

#[derive(Debug, Clone, Default)]
pub struct DsdTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub release_year: Option<i32>,
    pub isrc: Option<String>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub lyrics: Option<String>,
    pub pictures: Vec<ExtractedPicture>,
}

#[derive(Debug, Clone)]
pub struct DsdMetadata {
    pub format: AudioFormat,
    pub duration_ms: u64,
    pub tags: DsdTags,
}

#[derive(Debug, Clone, Default)]
pub struct Id3v2ParsedTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub release_year: Option<i32>,
    pub isrc: Option<String>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub txxx_rg_track_db: Option<f64>,
    pub txxx_rg_album_db: Option<f64>,
    pub txxx_rg_track_peak: Option<f64>,
    pub txxx_rg_album_peak: Option<f64>,
    pub rva2_rg_track_db: Option<f64>,
    pub rva2_rg_album_db: Option<f64>,
    pub rva2_rg_track_peak: Option<f64>,
    pub rva2_rg_album_peak: Option<f64>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub lyrics: Option<String>,
    pub pictures: Vec<ExtractedPicture>,
}

impl Id3v2ParsedTags {
    pub fn effective_rg_track_db(&self) -> Option<f64> {
        self.txxx_rg_track_db.or(self.rva2_rg_track_db)
    }

    pub fn effective_rg_album_db(&self) -> Option<f64> {
        self.txxx_rg_album_db.or(self.rva2_rg_album_db)
    }

    pub fn effective_rg_track_peak(&self) -> Option<f64> {
        self.txxx_rg_track_peak.or(self.rva2_rg_track_peak)
    }

    pub fn effective_rg_album_peak(&self) -> Option<f64> {
        self.txxx_rg_album_peak.or(self.rva2_rg_album_peak)
    }
}

pub fn parse_dsf(path: &Path) -> Result<DsdMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_dsf_reader(&mut file)
}

pub fn parse_dsf_reader<R: Read + Seek>(reader: &mut R) -> Result<DsdMetadata, ProviderError> {
    // 1. 'DSD ' chunk (28 bytes)
    let mut dsd_buf = [0u8; 28];
    reader
        .read_exact(&mut dsd_buf)
        .map_err(|e| ProviderError::UnsupportedFormat(format!("Failed to read DSF header: {e}")))?;

    if &dsd_buf[0..4] != b"DSD " {
        return Err(ProviderError::UnsupportedFormat(
            "Not a valid DSF file (missing 'DSD ' header)".into(),
        ));
    }

    let file_size = u64::from_le_bytes(dsd_buf[12..20].try_into().unwrap());
    let metadata_offset = u64::from_le_bytes(dsd_buf[20..28].try_into().unwrap());

    // 2. 'fmt ' chunk (52 bytes)
    let mut fmt_buf = [0u8; 52];
    reader.read_exact(&mut fmt_buf).map_err(|e| {
        ProviderError::UnsupportedFormat(format!("Failed to read DSF fmt chunk: {e}"))
    })?;

    if &fmt_buf[0..4] != b"fmt " {
        return Err(ProviderError::UnsupportedFormat(
            "Missing DSF 'fmt ' chunk".into(),
        ));
    }

    let channel_num = u32::from_le_bytes(fmt_buf[24..28].try_into().unwrap()) as u8;
    let sample_rate = u32::from_le_bytes(fmt_buf[28..32].try_into().unwrap());
    let sample_count = u64::from_le_bytes(fmt_buf[36..44].try_into().unwrap());

    let channels = if (1..=32).contains(&channel_num) {
        channel_num
    } else {
        2
    };

    let sample_rate_hz = if sample_rate > 0 {
        sample_rate
    } else {
        2_822_400
    };

    let format = AudioFormat::dsd(AudioCodec::Dsf, sample_rate_hz, channels)?;

    let duration_ms = if sample_rate_hz > 0 && sample_count > 0 {
        ((sample_count as f64 / sample_rate_hz as f64) * 1000.0).max(1.0) as u64
    } else {
        1000
    };

    let mut tags = DsdTags::default();
    if metadata_offset > 0 && metadata_offset < file_size {
        if reader.seek(SeekFrom::Start(metadata_offset)).is_ok() {
            if let Some(parsed) = parse_id3v2_from_reader(reader) {
                tags = DsdTags {
                    title: parsed.title.clone(),
                    artist: parsed.artist.clone(),
                    album: parsed.album.clone(),
                    album_artist: parsed.album_artist.clone(),
                    track_number: parsed.track_number,
                    disc_number: parsed.disc_number,
                    release_year: parsed.release_year,
                    isrc: parsed.isrc.clone(),
                    upc: parsed.upc.clone(),
                    musicbrainz_release_group_id: parsed.musicbrainz_release_group_id.clone(),
                    edition_label: parsed.edition_label.clone(),
                    replay_gain_track_db: parsed.effective_rg_track_db(),
                    replay_gain_album_db: parsed.effective_rg_album_db(),
                    replay_gain_track_peak: parsed.effective_rg_track_peak(),
                    replay_gain_album_peak: parsed.effective_rg_album_peak(),
                    genre: parsed.genre.clone(),
                    composer: parsed.composer.clone(),
                    lyrics: parsed.lyrics.clone(),
                    pictures: parsed.pictures.clone(),
                };
            }
        }
    }

    Ok(DsdMetadata {
        format,
        duration_ms,
        tags,
    })
}

pub fn parse_dff(path: &Path) -> Result<DsdMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_dff_reader(&mut file)
}

pub fn parse_dff_reader<R: Read + Seek>(reader: &mut R) -> Result<DsdMetadata, ProviderError> {
    // 1. 'FRM8' header (16 bytes)
    let mut header_buf = [0u8; 16];
    reader.read_exact(&mut header_buf).map_err(|e| {
        ProviderError::UnsupportedFormat(format!("Failed to read DSDIFF header: {e}"))
    })?;

    if &header_buf[0..4] != b"FRM8" {
        return Err(ProviderError::UnsupportedFormat(
            "Not a valid DSDIFF file (missing 'FRM8')".into(),
        ));
    }
    if &header_buf[12..16] != b"DSD " {
        return Err(ProviderError::UnsupportedFormat(
            "Not a valid DSDIFF file (missing 'DSD ' format)".into(),
        ));
    }

    let mut sample_rate_hz = 2_822_400u32;
    let mut channels = 2u8;
    let mut data_length = 0u64;

    let mut diin_title: Option<String> = None;
    let mut diin_artist: Option<String> = None;
    let mut id3_parsed: Option<Id3v2ParsedTags> = None;

    loop {
        let mut chunk_hdr = [0u8; 12];
        if reader.read_exact(&mut chunk_hdr).is_err() {
            break;
        }

        let chunk_id = &chunk_hdr[0..4];
        let chunk_size = u64::from_be_bytes(chunk_hdr[4..12].try_into().unwrap());

        if chunk_id == b"PROP" {
            let mut prop_type = [0u8; 4];
            let mut prop_read = 0u64;
            if reader.read_exact(&mut prop_type).is_ok() && &prop_type == b"SND " {
                prop_read = 4u64;
                while prop_read + 12 <= chunk_size {
                    let mut sub_hdr = [0u8; 12];
                    if reader.read_exact(&mut sub_hdr).is_err() {
                        break;
                    }
                    prop_read += 12;
                    let sub_id = &sub_hdr[0..4];
                    let sub_size = u64::from_be_bytes(sub_hdr[4..12].try_into().unwrap());

                    if sub_id == b"FS  " && sub_size >= 4 {
                        let mut fs_buf = [0u8; 4];
                        let _ = reader.read_exact(&mut fs_buf);
                        sample_rate_hz = u32::from_be_bytes(fs_buf);
                        let _ = reader.seek(SeekFrom::Current((sub_size - 4) as i64));
                    } else if sub_id == b"CHNL" && sub_size >= 2 {
                        let mut ch_buf = [0u8; 2];
                        let _ = reader.read_exact(&mut ch_buf);
                        channels = u16::from_be_bytes(ch_buf) as u8;
                        let _ = reader.seek(SeekFrom::Current((sub_size - 2) as i64));
                    } else {
                        let _ = reader.seek(SeekFrom::Current(sub_size as i64));
                    }
                    prop_read += sub_size;
                    if sub_size % 2 == 1 {
                        prop_read += 1;
                        let _ = reader.seek(SeekFrom::Current(1));
                    }
                }
            }
            if chunk_size > prop_read {
                let _ = reader.seek(SeekFrom::Current((chunk_size - prop_read) as i64));
            }
        } else if chunk_id == b"DIIN" {
            let to_read = chunk_size.min(1024 * 1024) as usize;
            let mut diin_buf = vec![0u8; to_read];
            if reader.read_exact(&mut diin_buf).is_ok() {
                let mut offset = 0usize;
                while offset + 12 <= diin_buf.len() {
                    let sub_id = &diin_buf[offset..offset + 4];
                    let sub_size = u64::from_be_bytes(diin_buf[offset + 4..offset + 12].try_into().unwrap()) as usize;
                    offset += 12;
                    if offset + sub_size > diin_buf.len() {
                        break;
                    }
                    let sub_data = &diin_buf[offset..offset + sub_size];
                    let text_bytes = if sub_data.len() >= 4 {
                        let text_len = u32::from_be_bytes(sub_data[0..4].try_into().unwrap()) as usize;
                        if text_len <= sub_data.len() - 4 {
                            &sub_data[4..4 + text_len]
                        } else {
                            sub_data
                        }
                    } else {
                        sub_data
                    };
                    let text = decode_text_cjk(text_bytes).trim_matches('\0').trim().to_string();
                    if !text.is_empty() {
                        if sub_id == b"DITI" {
                            diin_title = Some(text);
                        } else if sub_id == b"DIAR" {
                            diin_artist = Some(text);
                        }
                    }
                    offset += sub_size;
                    if sub_size % 2 == 1 {
                        offset += 1;
                    }
                }
            }
            if chunk_size > to_read as u64 {
                let _ = reader.seek(SeekFrom::Current((chunk_size - to_read as u64) as i64));
            }
        } else if chunk_id == b"ID3 " || chunk_id == b"id3 " {
            let to_read = chunk_size.min(16 * 1024 * 1024) as usize;
            let mut id3_buf = vec![0u8; to_read];
            if reader.read_exact(&mut id3_buf).is_ok() {
                if let Some(parsed) = parse_id3v2_from_slice(&id3_buf) {
                    id3_parsed = Some(parsed);
                }
            }
            if chunk_size > to_read as u64 {
                let _ = reader.seek(SeekFrom::Current((chunk_size - to_read as u64) as i64));
            }
        } else if chunk_id == b"DSD " {
            data_length = chunk_size;
            let _ = reader.seek(SeekFrom::Current(chunk_size as i64));
        } else {
            let _ = reader.seek(SeekFrom::Current(chunk_size as i64));
        }

        if chunk_size % 2 == 1 {
            let _ = reader.seek(SeekFrom::Current(1));
        }
    }

    let channels = if (1..=32).contains(&channels) {
        channels
    } else {
        2
    };
    let sample_rate_hz = if sample_rate_hz > 0 {
        sample_rate_hz
    } else {
        2_822_400
    };

    let format = AudioFormat::dsd(AudioCodec::Dsdiff, sample_rate_hz, channels)?;

    let duration_ms = if data_length > 0 && sample_rate_hz > 0 && channels > 0 {
        ((data_length as f64 * 8.0) / (sample_rate_hz as f64 * channels as f64) * 1000.0).max(1.0)
            as u64
    } else {
        1000
    };

    let tags = if let Some(parsed) = id3_parsed {
        let rg_track_db = parsed.effective_rg_track_db();
        let rg_album_db = parsed.effective_rg_album_db();
        let rg_track_peak = parsed.effective_rg_track_peak();
        let rg_album_peak = parsed.effective_rg_album_peak();
        DsdTags {
            title: parsed.title.or(diin_title),
            artist: parsed.artist.or(diin_artist),
            album: parsed.album,
            album_artist: parsed.album_artist,
            track_number: parsed.track_number,
            disc_number: parsed.disc_number,
            release_year: parsed.release_year,
            isrc: parsed.isrc,
            upc: parsed.upc,
            musicbrainz_release_group_id: parsed.musicbrainz_release_group_id,
            edition_label: parsed.edition_label,
            replay_gain_track_db: rg_track_db,
            replay_gain_album_db: rg_album_db,
            replay_gain_track_peak: rg_track_peak,
            replay_gain_album_peak: rg_album_peak,
            genre: parsed.genre,
            composer: parsed.composer,
            lyrics: parsed.lyrics,
            pictures: parsed.pictures,
        }
    } else {
        DsdTags {
            title: diin_title,
            artist: diin_artist,
            ..Default::default()
        }
    };

    Ok(DsdMetadata {
        format,
        duration_ms,
        tags,
    })
}

pub fn decode_syncsafe(bytes: &[u8]) -> u32 {
    if bytes.len() < 4 {
        return 0;
    }
    ((bytes[0] as u32 & 0x7F) << 21)
        | ((bytes[1] as u32 & 0x7F) << 14)
        | ((bytes[2] as u32 & 0x7F) << 7)
        | (bytes[3] as u32 & 0x7F)
}

/// Parses an ID3v2 tag starting at the current reader position (expects 10-byte `ID3` header).
pub fn parse_id3v2_from_reader<R: Read>(reader: &mut R) -> Option<Id3v2ParsedTags> {
    let mut id3_header = [0u8; 10];
    reader.read_exact(&mut id3_header).ok()?;
    if &id3_header[0..3] != b"ID3" {
        return None;
    }

    let major = id3_header[3];
    if major != 3 && major != 4 {
        return None;
    }

    let flags = id3_header[5];
    let tag_size = decode_syncsafe(&id3_header[6..10]) as usize;
    if tag_size == 0 || tag_size > 16 * 1024 * 1024 {
        return None;
    }

    let mut tag_data = vec![0u8; tag_size];
    reader.read_exact(&mut tag_data).ok()?;
    Some(parse_id3v2_body(&tag_data, major, flags))
}

/// Parses an ID3v2 tag from an in-memory buffer starting with `"ID3"`.
pub fn parse_id3v2_from_slice(data: &[u8]) -> Option<Id3v2ParsedTags> {
    if data.len() < 10 || &data[0..3] != b"ID3" {
        return None;
    }
    let major = data[3];
    if major != 3 && major != 4 {
        return None;
    }
    let flags = data[5];
    let tag_size = decode_syncsafe(&data[6..10]) as usize;
    if tag_size == 0 {
        return None;
    }
    let end = (10 + tag_size).min(data.len());
    Some(parse_id3v2_body(&data[10..end], major, flags))
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

pub fn parse_id3v2_body(raw_body: &[u8], major: u8, tag_flags: u8) -> Id3v2ParsedTags {
    let mut tags = Id3v2ParsedTags::default();
    let tag_unsync = (tag_flags & 0x80) != 0;
    let has_ext = (tag_flags & 0x40) != 0;

    let body_cow: Cow<'_, [u8]> = if major == 3 && tag_unsync {
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

    while offset < data.len() {
        if data[offset] == 0 {
            break;
        }

        let (frame_id, frame_size, header_len, frame_flags) = if major == 2 {
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
                "TXX" => "TXXX",
                "ULT" => "USLT",
                "PIC" => "APIC",
                _ => raw_id,
            };
            (mapped_id, sz, 6, 0u16)
        } else {
            if offset + 10 > data.len() {
                break;
            }
            let raw_id = match std::str::from_utf8(&data[offset..offset + 4]) {
                Ok(id) if id.chars().all(|c| c.is_ascii_alphanumeric()) => id,
                _ => break,
            };
            let sz = if major == 4 {
                decode_syncsafe(&data[offset + 4..offset + 8]) as usize
            } else {
                u32::from_be_bytes(data[offset + 4..offset + 8].try_into().unwrap()) as usize
            };
            let flags = u16::from_be_bytes([data[offset + 8], data[offset + 9]]);
            (raw_id, sz, 10, flags)
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

        let unsync_payload: Cow<'_, [u8]> = if major == 4 && ((frame_flags & 0x0002) != 0 || tag_unsync)
        {
            Cow::Owned(de_unsync(payload))
        } else {
            Cow::Borrowed(payload)
        };
        let frame_payload = unsync_payload.as_ref();

        if frame_payload.is_empty() {
            continue;
        }

        match frame_id {
            "TXXX" => {
                if let Some((desc, val)) = decode_txxx_frame(frame_payload) {
                    apply_txxx_tag(&desc, &val, &mut tags);
                }
            }
            "RVA2" => {
                parse_rva2_frame(frame_payload, &mut tags);
            }
            "TIT2" => {
                let t = decode_id3_text(frame_payload);
                if !t.is_empty() {
                    tags.title = Some(t);
                }
            }
            "TPE1" => {
                let t = decode_id3_text(frame_payload);
                if !t.is_empty() {
                    tags.artist = Some(t);
                }
            }
            "TALB" => {
                let t = decode_id3_text(frame_payload);
                if !t.is_empty() {
                    tags.album = Some(t);
                }
            }
            "TPE2" => {
                let t = decode_id3_text(frame_payload);
                if !t.is_empty() {
                    tags.album_artist = Some(t);
                }
            }
            "TRCK" => {
                let t = decode_id3_text(frame_payload);
                let (trk, disc) = parse_track_and_disc_number(&t);
                if let Some(num) = trk {
                    tags.track_number = Some(num);
                }
                if tags.disc_number.is_none() {
                    if let Some(d) = disc {
                        tags.disc_number = Some(d);
                    }
                }
            }
            "TPOS" => {
                let t = decode_id3_text(frame_payload);
                if let Some(num) = parse_slash_number(&t) {
                    tags.disc_number = Some(num);
                }
            }
            "TDRC" | "TYER" => {
                let t = decode_id3_text(frame_payload);
                if let Some(year) = parse_year(&t) {
                    tags.release_year = Some(year);
                }
            }
            "TSRC" => {
                let t = decode_id3_text(frame_payload);
                let clean = t.trim().replace('-', "");
                if clean.len() == 12 && clean.chars().all(|c| c.is_ascii_alphanumeric()) {
                    tags.isrc = Some(clean.to_ascii_uppercase());
                }
            }
            "TCON" => {
                let t = decode_id3_text(frame_payload);
                if !t.is_empty() {
                    tags.genre = Some(t);
                }
            }
            "TCOM" => {
                let t = decode_id3_text(frame_payload);
                if !t.is_empty() {
                    tags.composer = Some(t);
                }
            }
            "USLT" => {
                if frame_payload.len() > 4 {
                    let enc = frame_payload[0];
                    let rest = &frame_payload[4..];
                    let txt_start = if enc == 1 || enc == 2 {
                        let mut found = None;
                        for i in (0..rest.len().saturating_sub(1)).step_by(2) {
                            if rest[i] == 0 && rest[i + 1] == 0 {
                                found = Some(i + 2);
                                break;
                            }
                        }
                        found.unwrap_or(0)
                    } else {
                        rest.iter().position(|&b| b == 0).map(|p| p + 1).unwrap_or(0)
                    };
                    if txt_start <= rest.len() {
                        let raw_lyrics = &rest[txt_start..];
                        let text = decode_id3_text_with_enc(enc, raw_lyrics);
                        if !text.is_empty() {
                            tags.lyrics = Some(text);
                        }
                    }
                }
            }
            "APIC" if frame_payload.len() > 3 => {
                let enc = frame_payload[0];
                let mut idx = 1;
                if let Some(me) = frame_payload[idx..].iter().position(|&b| b == 0) {
                    let mime_raw = &frame_payload[idx..idx + me];
                    let mime_str = String::from_utf8_lossy(mime_raw).to_ascii_lowercase();
                    let mime_type = if mime_str.is_empty() || mime_str == "image/" || mime_str == "jpg" {
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
                        let data_start = if enc == 1 || enc == 2 {
                            let mut desc_end = desc_bytes.len();
                            for i in (0..desc_bytes.len().saturating_sub(1)).step_by(2) {
                                if desc_bytes[i] == 0 && desc_bytes[i + 1] == 0 {
                                    desc_end = i + 2;
                                    break;
                                }
                            }
                            idx + desc_end
                        } else {
                            let desc_end = desc_bytes.iter().position(|&b| b == 0).map(|p| p + 1).unwrap_or(0);
                            idx + desc_end
                        };
                        if data_start < frame_payload.len() {
                            let img_data = frame_payload[data_start..].to_vec();
                            tags.pictures.push(ExtractedPicture {
                                picture_type: PictureType::from_apic_byte(pic_type_byte),
                                mime_type,
                                data: img_data,
                            });
                        }
                    }
                }
            }
            _ => {}
        }
    }

    tags
}

fn decode_txxx_frame(payload: &[u8]) -> Option<(String, String)> {
    if payload.len() < 2 {
        return None;
    }
    let encoding = payload[0];
    let content = &payload[1..];

    match encoding {
        1 | 2 => {
            // UTF-16: look for 2-byte aligned 0x0000 terminator
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
            let desc = decode_utf16_slice(&content[..idx], encoding == 2);
            let val_bytes = &content[(idx + 2).min(content.len())..];
            let val = decode_utf16_slice(val_bytes, encoding == 2);
            Some((desc, val))
        }
        0 | 3 => {
            let split_idx = content.iter().position(|&b| b == 0)?;
            let desc_bytes = &content[..split_idx];
            let val_bytes = &content[(split_idx + 1).min(content.len())..];
            let desc = if encoding == 0 {
                desc_bytes.iter().map(|&b| b as char).collect::<String>()
            } else {
                String::from_utf8_lossy(desc_bytes).into_owned()
            };
            let val = if encoding == 0 {
                val_bytes
                    .iter()
                    .take_while(|&&b| b != 0)
                    .map(|&b| b as char)
                    .collect::<String>()
            } else {
                String::from_utf8_lossy(val_bytes)
                    .trim_matches('\0')
                    .to_string()
            };
            Some((desc.trim().to_string(), val.trim().to_string()))
        }
        _ => None,
    }
}

fn apply_txxx_tag(desc: &str, val: &str, tags: &mut Id3v2ParsedTags) {
    let key = desc.trim().to_ascii_uppercase();
    let trimmed_val = val.trim();
    if trimmed_val.is_empty() {
        return;
    }
    match key.as_str() {
        "REPLAYGAIN_TRACK_GAIN" => {
            if tags.txxx_rg_track_db.is_none() {
                tags.txxx_rg_track_db = parse_replay_gain_db_str(trimmed_val);
            }
        }
        "REPLAYGAIN_ALBUM_GAIN" => {
            if tags.txxx_rg_album_db.is_none() {
                tags.txxx_rg_album_db = parse_replay_gain_db_str(trimmed_val);
            }
        }
        "REPLAYGAIN_TRACK_PEAK" => {
            if tags.txxx_rg_track_peak.is_none() {
                tags.txxx_rg_track_peak = parse_replay_gain_peak_str(trimmed_val);
            }
        }
        "REPLAYGAIN_ALBUM_PEAK" => {
            if tags.txxx_rg_album_peak.is_none() {
                tags.txxx_rg_album_peak = parse_replay_gain_peak_str(trimmed_val);
            }
        }
        "UPC" | "BARCODE" | "EAN" => {
            if tags.upc.is_none() {
                let clean: String = trimmed_val.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
                if !clean.is_empty() {
                    tags.upc = Some(clean);
                }
            }
        }
        "MUSICBRAINZ RELEASE GROUP ID" | "MUSICBRAINZ_RELEASEGROUPID" => {
            if tags.musicbrainz_release_group_id.is_none() {
                tags.musicbrainz_release_group_id = Some(trimmed_val.to_string());
            }
        }
        "EDITION" | "VERSION" | "RELEASETYPE" if tags.edition_label.is_none() => {
            tags.edition_label = Some(trimmed_val.to_string());
        }
        _ => {}
    }
}

fn parse_rva2_frame(payload: &[u8], tags: &mut Id3v2ParsedTags) {
    let Some(nul_pos) = payload.iter().position(|&b| b == 0) else {
        return;
    };
    let ident = payload[..nul_pos]
        .iter()
        .map(|&b| b as char)
        .collect::<String>()
        .trim()
        .to_ascii_lowercase();

    let mut pos = nul_pos + 1;
    let mut master_gain: Option<f64> = None;
    let mut master_peak: Option<f64> = None;
    let mut first_gain: Option<f64> = None;
    let mut max_peak: Option<f64> = None;

    while pos + 4 <= payload.len() {
        let channel_type = payload[pos];
        let vol_adj = i16::from_be_bytes([payload[pos + 1], payload[pos + 2]]);
        let gain_db = (vol_adj as f64) / 512.0;
        let peak_bits = payload[pos + 3] as usize;
        pos += 4;

        let peak_bytes = peak_bits.div_ceil(8);
        if pos + peak_bytes > payload.len() {
            break;
        }

        let peak = if peak_bits > 0 && peak_bits <= 64 {
            let mut raw_peak: u64 = 0;
            for &b in &payload[pos..pos + peak_bytes] {
                raw_peak = (raw_peak << 8) | (b as u64);
            }
            // Shift if peak_bits is not a multiple of 8 (rare, standard says right-aligned or MSB-padded)
            let denom = (1u64 << (peak_bits - 1)) as f64;
            let val = (raw_peak as f64) / denom;
            (val.is_finite() && val >= 0.0).then_some(val)
        } else {
            None
        };
        pos += peak_bytes;

        if first_gain.is_none() {
            first_gain = Some(gain_db);
        }
        if let Some(p) = peak {
            max_peak = Some(max_peak.map_or(p, |cur| cur.max(p)));
        }
        if channel_type == 0x01 {
            master_gain = Some(gain_db);
            master_peak = peak;
        }
    }

    let chosen_gain = master_gain.or(first_gain);
    let chosen_peak = master_peak.or(max_peak);

    match ident.as_str() {
        "album" => {
            if tags.rva2_rg_album_db.is_none() {
                tags.rva2_rg_album_db = chosen_gain;
            }
            if tags.rva2_rg_album_peak.is_none() {
                tags.rva2_rg_album_peak = chosen_peak;
            }
        }
        "track" => {
            if tags.rva2_rg_track_db.is_none() {
                tags.rva2_rg_track_db = chosen_gain;
            }
            if tags.rva2_rg_track_peak.is_none() {
                tags.rva2_rg_track_peak = chosen_peak;
            }
        }
        "" => {
            if tags.rva2_rg_track_db.is_none() {
                tags.rva2_rg_track_db = chosen_gain;
            }
            if tags.rva2_rg_track_peak.is_none() {
                tags.rva2_rg_track_peak = chosen_peak;
            }
        }
        _ => {}
    }
}

pub fn parse_replay_gain_db_str(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let bytes = trimmed.as_bytes();
    let without_unit = if bytes.len() >= 2 && bytes[bytes.len() - 2..].eq_ignore_ascii_case(b"db") {
        trimmed[..bytes.len() - 2].trim()
    } else {
        trimmed
    };
    let parsed = without_unit.replace(',', ".").parse::<f64>().ok()?;
    parsed.is_finite().then_some(parsed)
}

pub fn parse_replay_gain_peak_str(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parsed = trimmed.replace(',', ".").parse::<f64>().ok()?;
    (parsed.is_finite() && parsed >= 0.0).then_some(parsed)
}

fn decode_utf16_slice(content: &[u8], force_be: bool) -> String {
    if content.len() < 2 {
        return String::new();
    }
    let (is_be, slice) = if !force_be && content[0] == 0xFE && content[1] == 0xFF {
        (true, &content[2..])
    } else if !force_be && content[0] == 0xFF && content[1] == 0xFE {
        (false, &content[2..])
    } else {
        (force_be, content)
    };

    let u16s: Vec<u16> = slice
        .chunks_exact(2)
        .map(|c| {
            if is_be {
                u16::from_be_bytes([c[0], c[1]])
            } else {
                u16::from_le_bytes([c[0], c[1]])
            }
        })
        .take_while(|&u| u != 0)
        .collect();
    String::from_utf16_lossy(&u16s).trim().to_string()
}

fn decode_id3_text(payload: &[u8]) -> String {
    if payload.is_empty() {
        return String::new();
    }
    let encoding = payload[0];
    let content = &payload[1..];
    decode_id3_text_with_enc(encoding, content)
}

fn decode_id3_text_with_enc(encoding: u8, content: &[u8]) -> String {
    match encoding {
        0 => {
            let zero_pos = content.iter().position(|&b| b == 0).unwrap_or(content.len());
            let slice = &content[..zero_pos];
            if slice.iter().all(|&b| b < 128) {
                slice
                    .iter()
                    .map(|&b| b as char)
                    .collect::<String>()
                    .trim()
                    .to_string()
            } else {
                decode_text_cjk(slice).trim().to_string()
            }
        }
        1 => decode_utf16_slice(content, false),
        2 => decode_utf16_slice(content, true),
        3 => String::from_utf8_lossy(content)
            .trim_matches('\0')
            .trim()
            .to_string(),
        _ => decode_text_cjk(content).trim().to_string(),
    }
}

pub fn parse_track_and_disc_number(text: &str) -> (Option<u16>, Option<u16>) {
    let clean = text.trim();
    if clean.is_empty() {
        return (None, None);
    }
    // Disc-Track pattern like "1-02", "01-05", "1.02"
    if let Some((disc_str, trk_str)) = clean.split_once('-').or_else(|| clean.split_once('.')) {
        let disc_trim = disc_str.trim();
        let trk_trim = trk_str.trim().split('/').next().unwrap_or("").trim();
        if let (Ok(disc), Ok(trk)) = (disc_trim.parse::<u16>(), trk_trim.parse::<u16>()) {
            if disc > 0 && trk > 0 {
                return (Some(trk), Some(disc));
            }
        }
    }
    // "02/12" pattern
    let num_part = clean.split('/').next().unwrap_or(clean).trim();
    if let Ok(trk) = num_part.parse::<u16>() {
        return (Some(trk.max(1)), None);
    }
    let digits: String = num_part.chars().filter(|c| c.is_ascii_digit()).collect();
    if let Ok(trk) = digits.parse::<u16>() {
        return (Some(trk.max(1)), None);
    }
    (None, None)
}

pub fn parse_slash_number(text: &str) -> Option<u16> {
    parse_track_and_disc_number(text).0
}

pub fn parse_year(text: &str) -> Option<i32> {
    let mut num_str = String::new();
    for c in text.chars() {
        if c.is_ascii_digit() {
            num_str.push(c);
            if num_str.len() == 4 {
                break;
            }
        } else if !num_str.is_empty() {
            break;
        }
    }
    let year = num_str.parse::<i32>().ok()?;
    if (1000..=3000).contains(&year) {
        Some(year)
    } else {
        None
    }
}
