use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat, ExtractedPicture};

use super::dsd_meta::{parse_id3v2_from_slice, parse_slash_number, parse_year, Id3v2ParsedTags};
use super::lyrics::decode_text_cjk;
use crate::error::ProviderError;

#[derive(Debug, Clone)]
pub struct RiffWavMetadata {
    pub format: AudioFormat,
    pub duration_ms: u64,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub release_year: Option<i32>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub isrc: Option<String>,
    pub lyrics: Option<String>,
    pub pictures: Vec<ExtractedPicture>,
}

pub fn parse_wav(path: &Path) -> Result<RiffWavMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_wav_reader(&mut file)
}

pub fn parse_wav_reader<R: Read + Seek>(reader: &mut R) -> Result<RiffWavMetadata, ProviderError> {
    let mut riff_hdr = [0u8; 12];
    reader
        .read_exact(&mut riff_hdr)
        .map_err(|e| ProviderError::UnsupportedFormat(format!("Failed to read WAV RIFF header: {e}")))?;

    let magic = &riff_hdr[0..4];
    if magic != b"RIFF" && magic != b"RF64" {
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

    let mut channels = 2u8;
    let mut sample_rate_hz = 44100u32;
    let mut bit_depth = 16u8;
    let mut data_bytes = 0u64;

    let mut info_title: Option<String> = None;
    let mut info_artist: Option<String> = None;
    let mut info_album: Option<String> = None;
    let mut info_genre: Option<String> = None;
    let mut info_year: Option<i32> = None;
    let mut info_track: Option<u16> = None;

    let mut bext_title: Option<String> = None;
    let mut bext_originator: Option<String> = None;
    let mut bext_year: Option<i32> = None;

    let mut id3_tags: Option<Id3v2ParsedTags> = None;
    let mut id3_pictures: Vec<ExtractedPicture> = Vec::new();
    let mut id3_genre: Option<String> = None;
    let mut id3_composer: Option<String> = None;
    let mut id3_lyrics: Option<String> = None;

    // Scan chunks
    loop {
        let mut chunk_hdr = [0u8; 8];
        if reader.read_exact(&mut chunk_hdr).is_err() {
            break;
        }

        let chunk_id = &chunk_hdr[0..4];
        let chunk_size = u32::from_le_bytes(chunk_hdr[4..8].try_into().unwrap()) as u64;

        match chunk_id {
            b"fmt " => {
                let to_read = chunk_size.min(64) as usize;
                let mut fmt_data = vec![0u8; to_read];
                if reader.read_exact(&mut fmt_data).is_ok() {
                    if fmt_data.len() >= 16 {
                        let ch = u16::from_le_bytes([fmt_data[2], fmt_data[3]]) as u8;
                        let sr = u32::from_le_bytes([fmt_data[4], fmt_data[5], fmt_data[6], fmt_data[7]]);
                        let bits = u16::from_le_bytes([fmt_data[14], fmt_data[15]]) as u8;

                        if (1..=32).contains(&ch) {
                            channels = ch;
                        }
                        if sr > 0 {
                            sample_rate_hz = sr;
                        }
                        if (8..=64).contains(&bits) {
                            bit_depth = bits;
                        }
                    }
                    if chunk_size > to_read as u64 {
                        let _ = reader.seek(SeekFrom::Current((chunk_size - to_read as u64) as i64));
                    }
                }
            }
            b"data" => {
                data_bytes = chunk_size;
                let _ = reader.seek(SeekFrom::Current(chunk_size as i64));
            }
            b"LIST" => {
                let to_read = chunk_size.min(1024 * 1024) as usize;
                let mut list_data = vec![0u8; to_read];
                if reader.read_exact(&mut list_data).is_ok() && list_data.len() >= 4 {
                    let list_type = &list_data[0..4];
                    if list_type == b"INFO" {
                        let mut offset = 4usize;
                        while offset + 8 <= list_data.len() {
                            let sub_id = &list_data[offset..offset + 4];
                            let sub_len = u32::from_le_bytes(
                                list_data[offset + 4..offset + 8].try_into().unwrap(),
                            ) as usize;
                            offset += 8;

                            if offset + sub_len > list_data.len() {
                                break;
                            }

                            let raw_bytes = &list_data[offset..offset + sub_len];
                            let text = decode_text_cjk(raw_bytes).trim_matches('\0').trim().to_string();

                            if !text.is_empty() {
                                match sub_id {
                                    b"INAM" => info_title = Some(text),
                                    b"IART" => info_artist = Some(text),
                                    b"IPRD" => info_album = Some(text),
                                    b"IGNR" => info_genre = Some(text),
                                    b"ICRD" => {
                                        if let Some(y) = parse_year(&text) {
                                            info_year = Some(y);
                                        }
                                    }
                                    b"ITRK" => {
                                        if let Some(n) = parse_slash_number(&text) {
                                            info_track = Some(n);
                                        }
                                    }
                                    _ => {}
                                }
                            }

                            offset += sub_len;
                            if sub_len % 2 == 1 {
                                offset += 1; // Pad byte
                            }
                        }
                    }
                }
                if chunk_size > to_read as u64 {
                    let _ = reader.seek(SeekFrom::Current((chunk_size - to_read as u64) as i64));
                }
            }
            b"bext" => {
                let to_read = chunk_size.min(1024) as usize;
                let mut bext_data = vec![0u8; to_read];
                if reader.read_exact(&mut bext_data).is_ok() {
                    // Description: 256 bytes (0..256)
                    if bext_data.len() >= 256 {
                        let d = decode_text_cjk(&bext_data[0..256])
                            .trim_matches('\0')
                            .trim()
                            .to_string();
                        if !d.is_empty() {
                            bext_title = Some(d);
                        }
                    }
                    // Originator: 32 bytes (256..288)
                    if bext_data.len() >= 288 {
                        let orig = decode_text_cjk(&bext_data[256..288])
                            .trim_matches('\0')
                            .trim()
                            .to_string();
                        if !orig.is_empty() {
                            bext_originator = Some(orig);
                        }
                    }
                    // OriginationDate: 10 bytes (320..330)
                    if bext_data.len() >= 330 {
                        let date_str = decode_text_cjk(&bext_data[320..330])
                            .trim_matches('\0')
                            .trim()
                            .to_string();
                        if let Some(y) = parse_year(&date_str) {
                            bext_year = Some(y);
                        }
                    }
                }
                if chunk_size > to_read as u64 {
                    let _ = reader.seek(SeekFrom::Current((chunk_size - to_read as u64) as i64));
                }
            }
            b"id3 " | b"ID3 " => {
                let to_read = chunk_size.min(16 * 1024 * 1024) as usize;
                let mut tag_data = vec![0u8; to_read];
                if reader.read_exact(&mut tag_data).is_ok() {
                    if let Some(parsed) = parse_id3v2_from_slice(&tag_data) {
                        id3_genre = parsed.genre.clone();
                        id3_composer = parsed.composer.clone();
                        id3_lyrics = parsed.lyrics.clone();
                        id3_pictures = parsed.pictures.clone();
                        id3_tags = Some(parsed);
                    }
                }
                if chunk_size > to_read as u64 {
                    let _ = reader.seek(SeekFrom::Current((chunk_size - to_read as u64) as i64));
                }
            }
            _ => {
                let _ = reader.seek(SeekFrom::Current(chunk_size as i64));
            }
        }

        // 2-byte chunk alignment padding
        if chunk_size % 2 == 1 {
            let _ = reader.seek(SeekFrom::Current(1));
        }
    }

    let bytes_per_sec = (sample_rate_hz as u64)
        * (channels as u64)
        * ((bit_depth as u64).div_ceil(8));
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

    // Merge priority: ID3v2 > INFO > bext
    let id3 = id3_tags.as_ref();
    let title = id3
        .and_then(|t| t.title.clone())
        .or(info_title)
        .or(bext_title);
    let artist = id3
        .and_then(|t| t.artist.clone())
        .or(info_artist)
        .or(bext_originator);
    let album = id3.and_then(|t| t.album.clone()).or(info_album);
    let album_artist = id3.and_then(|t| t.album_artist.clone());
    let genre = id3_genre.or(info_genre);
    let composer = id3_composer;
    let release_year = id3
        .and_then(|t| t.release_year)
        .or(info_year)
        .or(bext_year);
    let track_number = id3.and_then(|t| t.track_number).or(info_track);
    let disc_number = id3.and_then(|t| t.disc_number);
    let isrc = id3.and_then(|t| t.isrc.clone());

    Ok(RiffWavMetadata {
        format,
        duration_ms,
        title,
        artist,
        album,
        album_artist,
        genre,
        composer,
        release_year,
        track_number,
        disc_number,
        isrc,
        lyrics: id3_lyrics,
        pictures: id3_pictures,
    })
}
