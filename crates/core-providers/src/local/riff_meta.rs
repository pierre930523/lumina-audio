use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat, ExtractedPicture};

use super::dsd_meta::{
    Id3v2ParsedTags, parse_disc_number, parse_id3v2_from_slice_ext, parse_track_and_disc_number,
    parse_year,
};
use super::encoding::{
    DetectedEncoding, decode_bytes_with_encoding, detect_tag_block_encoding, sanitize_tag_text,
};
use crate::error::ProviderError;

#[derive(Debug, Clone)]
pub struct RawRiffField {
    pub chunk: String,
    pub key: String,
    pub raw_bytes: Vec<u8>,
    pub decoded: String,
}

#[derive(Debug, Clone)]
pub struct RiffWavMetadata {
    pub format: AudioFormat,
    pub duration_ms: u64,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub release_year: Option<i32>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub isrc: Option<String>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub record_label: Option<String>,
    pub compilation: Option<bool>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
    pub lyrics: Option<String>,
    pub pictures: Vec<ExtractedPicture>,
    pub detected_encoding: DetectedEncoding,
    pub info_detected_encoding: Option<DetectedEncoding>,
    pub id3_tags: Option<Id3v2ParsedTags>,
    pub raw_info_fields: Vec<RawRiffField>,
    pub raw_bext_fields: Vec<RawRiffField>,
}

pub fn parse_wav(path: &Path) -> Result<RiffWavMetadata, ProviderError> {
    parse_wav_with_extract_options(path, true)
}

pub fn parse_wav_with_extract_options(
    path: &Path,
    include_pictures: bool,
) -> Result<RiffWavMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_wav_reader_ext(&mut file, false, include_pictures)
}

pub fn parse_wav_with_raw(path: &Path) -> Result<RiffWavMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_wav_reader_ext(&mut file, true, true)
}

pub fn parse_wav_reader<R: Read + Seek>(reader: &mut R) -> Result<RiffWavMetadata, ProviderError> {
    parse_wav_reader_ext(reader, false, true)
}

pub fn parse_wav_reader_with_options<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Result<RiffWavMetadata, ProviderError> {
    parse_wav_reader_ext(reader, collect_raw, true)
}

pub fn parse_wav_reader_ext<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
    include_pictures: bool,
) -> Result<RiffWavMetadata, ProviderError> {
    let mut riff_hdr = [0u8; 12];
    reader.read_exact(&mut riff_hdr).map_err(|e| {
        ProviderError::UnsupportedFormat(format!("Failed to read WAV RIFF header: {e}"))
    })?;

    let magic = &riff_hdr[0..4];
    let is_rf64 = magic == b"RF64";
    if magic != b"RIFF" && !is_rf64 {
        return Err(ProviderError::UnsupportedFormat(
            "Not a valid WAV file (missing RIFF/RF64 header)".into(),
        ));
    }

    let format_id = &riff_hdr[8..12];
    if format_id != b"WAVE" {
        return Err(ProviderError::UnsupportedFormat(
            "Not a valid WAV file (missing WAVE format)".into(),
        ));
    }

    let mut channels = 0u8;
    let mut sample_rate_hz = 0u32;
    let mut bit_depth = 16u8;
    let mut data_bytes = 0u64;
    let mut saw_fmt = false;
    let mut saw_data = false;
    let mut rf64_data_size: Option<u64> = None;

    let mut staged_info: Vec<(String, Vec<u8>)> = Vec::new();
    let mut staged_bext: Vec<(String, Vec<u8>)> = Vec::new();
    let mut id3_tags: Option<Id3v2ParsedTags> = None;

    // Scan chunks
    loop {
        let mut chunk_hdr = [0u8; 8];
        if reader.read_exact(&mut chunk_hdr).is_err() {
            break;
        }

        let chunk_id = &chunk_hdr[0..4];
        let raw_chunk_size = u32::from_le_bytes(chunk_hdr[4..8].try_into().unwrap()) as u64;
        let chunk_size = if is_rf64 && chunk_id == b"data" && raw_chunk_size == 0xFFFF_FFFF {
            rf64_data_size.unwrap_or(raw_chunk_size)
        } else {
            raw_chunk_size
        };

        if chunk_id == b"ds64" && is_rf64 {
            let to_read = chunk_size.min(64) as usize;
            let mut ds64_data = vec![0u8; to_read];
            if reader.read_exact(&mut ds64_data).is_err() {
                break;
            }
            if ds64_data.len() >= 16 {
                rf64_data_size = Some(u64::from_le_bytes(ds64_data[8..16].try_into().unwrap()));
            }
            if chunk_size > to_read as u64 {
                if reader
                    .seek(SeekFrom::Current((chunk_size - to_read as u64) as i64))
                    .is_err()
                {
                    break;
                }
            }
        } else if chunk_id == b"fmt " {
            let to_read = chunk_size.min(64) as usize;
            let mut fmt_data = vec![0u8; to_read];
            if reader.read_exact(&mut fmt_data).is_err() {
                break;
            }
            if fmt_data.len() >= 16 {
                let ch = u16::from_le_bytes([fmt_data[2], fmt_data[3]]);
                let sr = u32::from_le_bytes([fmt_data[4], fmt_data[5], fmt_data[6], fmt_data[7]]);
                let bits = u16::from_le_bytes([fmt_data[14], fmt_data[15]]);

                if (1..=32).contains(&ch) && sr > 0 {
                    channels = ch as u8;
                    sample_rate_hz = sr;
                    if (8..=64).contains(&bits) {
                        bit_depth = bits as u8;
                    }
                    saw_fmt = true;
                }
            }
            if chunk_size > to_read as u64 {
                if reader
                    .seek(SeekFrom::Current((chunk_size - to_read as u64) as i64))
                    .is_err()
                {
                    break;
                }
            }
        } else if chunk_id == b"data" {
            if chunk_size > 0 {
                data_bytes = chunk_size;
                saw_data = true;
            }
            if reader.seek(SeekFrom::Current(chunk_size as i64)).is_err() {
                break;
            }
        } else if chunk_id == b"LIST" {
            let to_read = chunk_size.min(1024 * 1024) as usize;
            let mut list_data = vec![0u8; to_read];
            if reader.read_exact(&mut list_data).is_err() {
                break;
            }
            if list_data.len() >= 4 && &list_data[0..4] == b"INFO" {
                let mut offset = 4usize;
                while offset + 8 <= list_data.len() {
                    let sub_id = &list_data[offset..offset + 4];
                    let sub_len =
                        u32::from_le_bytes(list_data[offset + 4..offset + 8].try_into().unwrap())
                            as usize;
                    offset += 8;

                    if offset + sub_len > list_data.len() {
                        break;
                    }

                    let raw_bytes = list_data[offset..offset + sub_len].to_vec();
                    let sub_key = String::from_utf8_lossy(sub_id).into_owned();
                    staged_info.push((sub_key, raw_bytes));

                    offset += sub_len;
                    if sub_len % 2 == 1 {
                        offset += 1;
                    }
                }
            }
            if chunk_size > to_read as u64 {
                if reader
                    .seek(SeekFrom::Current((chunk_size - to_read as u64) as i64))
                    .is_err()
                {
                    break;
                }
            }
        } else if chunk_id == b"bext" {
            let to_read = chunk_size.min(1024) as usize;
            let mut bext_data = vec![0u8; to_read];
            if reader.read_exact(&mut bext_data).is_err() {
                break;
            }
            if bext_data.len() >= 256 {
                staged_bext.push(("Description".to_string(), bext_data[0..256].to_vec()));
            }
            if bext_data.len() >= 288 {
                staged_bext.push(("Originator".to_string(), bext_data[256..288].to_vec()));
            }
            if bext_data.len() >= 330 {
                staged_bext.push(("OriginationDate".to_string(), bext_data[320..330].to_vec()));
            }
            if chunk_size > to_read as u64 {
                if reader
                    .seek(SeekFrom::Current((chunk_size - to_read as u64) as i64))
                    .is_err()
                {
                    break;
                }
            }
        } else if chunk_id.eq_ignore_ascii_case(b"id3 ") {
            let to_read = chunk_size.min(16 * 1024 * 1024) as usize;
            let mut tag_data = vec![0u8; to_read];
            if reader.read_exact(&mut tag_data).is_err() {
                break;
            }
            // Some WAV editors prepend a single padding byte before "ID3"
            let slice = if tag_data.len() >= 10 && &tag_data[0..3] == b"ID3" {
                &tag_data[..]
            } else if tag_data.len() >= 11 && tag_data[0] == 0 && &tag_data[1..4] == b"ID3" {
                &tag_data[1..]
            } else {
                &tag_data[..]
            };
            if let Some(parsed) = parse_id3v2_from_slice_ext(slice, collect_raw, include_pictures) {
                id3_tags = Some(parsed);
            }
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

        // 2-byte chunk alignment padding with odd-size unpadded recovery:
        // Only consume the trailing byte if it is actually a 0x00 pad byte.
        if chunk_size % 2 == 1 {
            let mut pad = [0u8; 1];
            if reader.read_exact(&mut pad).is_ok() && pad[0] != 0 {
                let _ = reader.seek(SeekFrom::Current(-1));
            }
        }
    }

    if !saw_fmt || !saw_data {
        return Err(ProviderError::UnsupportedFormat(
            "Truncated or invalid WAV file (missing valid fmt or data chunk)".into(),
        ));
    }

    // Two-pass tag-wide encoding detection for LIST INFO
    let info_samples: Vec<&[u8]> = staged_info.iter().map(|(_, b)| b.as_slice()).collect();
    let info_encoding = if staged_info.is_empty() {
        None
    } else {
        Some(detect_tag_block_encoding(&info_samples))
    };

    let mut info_title: Option<String> = None;
    let mut info_artist: Option<String> = None;
    let mut info_album: Option<String> = None;
    let mut info_album_artist: Option<String> = None;
    let mut info_genre: Option<String> = None;
    let mut info_year: Option<i32> = None;
    let mut info_track: Option<u16> = None;
    let mut info_disc: Option<u16> = None;
    let mut info_record_label: Option<String> = None;
    let mut raw_info_fields = Vec::new();

    if let Some(enc) = info_encoding {
        for (sub_key, raw_bytes) in staged_info {
            let text = sanitize_tag_text(&decode_bytes_with_encoding(&raw_bytes, enc));
            if !text.is_empty() {
                match sub_key.as_str() {
                    "INAM" if info_title.is_none() => info_title = Some(text.clone()),
                    "IART" if info_artist.is_none() => info_artist = Some(text.clone()),
                    "IPRD" if info_album.is_none() => info_album = Some(text.clone()),
                    "IAAR" | "TPE2" if info_album_artist.is_none() => {
                        info_album_artist = Some(text.clone());
                    }
                    "IGNR" if info_genre.is_none() => info_genre = Some(text.clone()),
                    "ICRD" if info_year.is_none() => {
                        info_year = parse_year(&text);
                    }
                    "ITRK" | "TRCK" if info_track.is_none() => {
                        let (trk, disc) = parse_track_and_disc_number(&text);
                        info_track = trk;
                        if info_disc.is_none() {
                            info_disc = disc;
                        }
                    }
                    "IPRT" | "TPRT" if info_disc.is_none() => {
                        info_disc = parse_disc_number(&text);
                    }
                    "IPUB" | "TORG" if info_record_label.is_none() => {
                        info_record_label = Some(text.clone());
                    }
                    _ => {}
                }
            }
            if collect_raw {
                raw_info_fields.push(RawRiffField {
                    chunk: "LIST/INFO".to_string(),
                    key: sub_key,
                    raw_bytes,
                    decoded: text,
                });
            }
        }
    }

    // Two-pass tag-wide encoding detection for bext (diagnostics only; never promoted to title/artist)
    let bext_samples: Vec<&[u8]> = staged_bext.iter().map(|(_, b)| b.as_slice()).collect();
    let bext_encoding = detect_tag_block_encoding(&bext_samples);
    let mut raw_bext_fields = Vec::new();

    if collect_raw {
        for (key, raw_bytes) in staged_bext {
            let zero_pos = raw_bytes
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(raw_bytes.len());
            let text = sanitize_tag_text(&decode_bytes_with_encoding(
                &raw_bytes[..zero_pos],
                bext_encoding,
            ));
            raw_bext_fields.push(RawRiffField {
                chunk: "bext".to_string(),
                key,
                raw_bytes: raw_bytes[..zero_pos].to_vec(),
                decoded: text,
            });
        }
    }

    let bytes_per_sec =
        (sample_rate_hz as u64) * (channels as u64) * ((bit_depth as u64).div_ceil(8));
    let duration_ms = if bytes_per_sec > 0 && data_bytes > 0 {
        ((data_bytes as f64 / bytes_per_sec as f64) * 1000.0).max(1.0) as u64
    } else {
        1000
    };

    let format = AudioFormat::pcm(
        AudioCodec::Wav,
        sample_rate_hz,
        bit_depth.clamp(8, 32),
        channels.clamp(1, 8),
    )?;

    // Strict merge priority: ID3v2 > LIST INFO (NEVER promote bext Description/Originator to title/artist)
    let id3 = id3_tags.as_ref();
    let title = id3.and_then(|t| t.title.clone()).or(info_title);
    let artist = id3.and_then(|t| t.artist.clone()).or(info_artist);
    let artists = id3.map(|t| t.artists.clone()).unwrap_or_default();
    let album = id3.and_then(|t| t.album.clone()).or(info_album);
    let album_artist = id3
        .and_then(|t| t.album_artist.clone())
        .or(info_album_artist);
    let genre = id3.and_then(|t| t.genre.clone()).or(info_genre);
    let composer = id3.and_then(|t| t.composer.clone());
    let release_year = id3.and_then(|t| t.release_year).or(info_year);
    let track_number = id3.and_then(|t| t.track_number).or(info_track);
    let disc_number = id3.and_then(|t| t.disc_number).or(info_disc);
    let isrc = id3.and_then(|t| t.isrc.clone());
    let upc = id3.and_then(|t| t.upc.clone());
    let musicbrainz_release_group_id = id3.and_then(|t| t.musicbrainz_release_group_id.clone());
    let edition_label = id3.and_then(|t| t.edition_label.clone());
    let record_label = id3
        .and_then(|t| t.record_label.clone())
        .or(info_record_label);
    let compilation = id3.and_then(|t| t.compilation);
    let replay_gain_track_db = id3.and_then(|t| t.effective_rg_track_db());
    let replay_gain_album_db = id3.and_then(|t| t.effective_rg_album_db());
    let replay_gain_track_peak = id3.and_then(|t| t.effective_rg_track_peak());
    let replay_gain_album_peak = id3.and_then(|t| t.effective_rg_album_peak());
    let lyrics = id3.and_then(|t| t.lyrics.clone());
    let pictures = id3.map(|t| t.pictures.clone()).unwrap_or_default();
    let detected_encoding = id3
        .map(|t| t.detected_encoding)
        .or(info_encoding)
        .unwrap_or(bext_encoding);

    Ok(RiffWavMetadata {
        format,
        duration_ms,
        title,
        artist,
        artists,
        album,
        album_artist,
        genre,
        composer,
        release_year,
        track_number,
        disc_number,
        isrc,
        upc,
        musicbrainz_release_group_id,
        edition_label,
        record_label,
        compilation,
        replay_gain_track_db,
        replay_gain_album_db,
        replay_gain_track_peak,
        replay_gain_album_peak,
        lyrics,
        pictures,
        detected_encoding,
        info_detected_encoding: info_encoding,
        id3_tags: if collect_raw { id3_tags } else { None },
        raw_info_fields,
        raw_bext_fields,
    })
}
