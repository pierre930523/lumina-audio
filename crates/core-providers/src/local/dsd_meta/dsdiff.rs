use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat};

use super::{DsdMetadata, DsdTags, Id3v2ParsedTags, parse_id3v2_from_slice_ext};
use crate::error::ProviderError;
use crate::local::encoding::{
    decode_bytes_with_encoding, detect_tag_block_encoding, sanitize_tag_text,
};

pub fn parse_dff(path: &Path) -> Result<DsdMetadata, ProviderError> {
    parse_dff_with_extract_options(path, true)
}

pub fn parse_dff_with_extract_options(
    path: &Path,
    include_pictures: bool,
) -> Result<DsdMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_dff_reader_ext(&mut file, false, include_pictures)
}

pub fn parse_dff_with_raw(path: &Path) -> Result<DsdMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_dff_reader_ext(&mut file, true, true)
}

pub fn parse_dff_reader<R: Read + Seek>(reader: &mut R) -> Result<DsdMetadata, ProviderError> {
    parse_dff_reader_ext(reader, false, true)
}

pub fn parse_dff_reader_with_options<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Result<DsdMetadata, ProviderError> {
    parse_dff_reader_ext(reader, collect_raw, true)
}

pub fn parse_dff_reader_ext<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
    include_pictures: bool,
) -> Result<DsdMetadata, ProviderError> {
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

    let mut sample_rate_hz = 0u32;
    let mut channels = 0u8;
    let mut data_length = 0u64;
    let mut saw_fs = false;
    let mut saw_chnl = false;
    let mut saw_audio_data = false;

    let mut diin_raw_entries: Vec<(String, Vec<u8>)> = Vec::new();
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
                        if reader.read_exact(&mut fs_buf).is_ok() {
                            sample_rate_hz = u32::from_be_bytes(fs_buf);
                            if sample_rate_hz > 0 {
                                saw_fs = true;
                            }
                        }
                        let _ = reader.seek(SeekFrom::Current((sub_size - 4) as i64));
                    } else if sub_id == b"CHNL" && sub_size >= 2 {
                        let mut ch_buf = [0u8; 2];
                        if reader.read_exact(&mut ch_buf).is_ok() {
                            let ch = u16::from_be_bytes(ch_buf);
                            if (1..=32).contains(&ch) {
                                channels = ch as u8;
                                saw_chnl = true;
                            }
                        }
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
                    let sub_size =
                        u64::from_be_bytes(diin_buf[offset + 4..offset + 12].try_into().unwrap())
                            as usize;
                    offset += 12;
                    if offset + sub_size > diin_buf.len() {
                        break;
                    }
                    let sub_data = &diin_buf[offset..offset + sub_size];
                    let text_bytes = if sub_data.len() >= 4 {
                        let text_len =
                            u32::from_be_bytes(sub_data[0..4].try_into().unwrap()) as usize;
                        if text_len <= sub_data.len() - 4 {
                            &sub_data[4..4 + text_len]
                        } else {
                            sub_data
                        }
                    } else {
                        sub_data
                    };
                    if sub_id == b"DITI" || sub_id == b"DIAR" {
                        let id_str = String::from_utf8_lossy(sub_id).into_owned();
                        diin_raw_entries.push((id_str, text_bytes.to_vec()));
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
        } else if chunk_id.eq_ignore_ascii_case(b"id3 ") {
            let to_read = chunk_size.min(16 * 1024 * 1024) as usize;
            let mut id3_buf = vec![0u8; to_read];
            if reader.read_exact(&mut id3_buf).is_ok() {
                if let Some(parsed) =
                    parse_id3v2_from_slice_ext(&id3_buf, collect_raw, include_pictures)
                {
                    id3_parsed = Some(parsed);
                }
            }
            if chunk_size > to_read as u64 {
                let _ = reader.seek(SeekFrom::Current((chunk_size - to_read as u64) as i64));
            }
        } else if chunk_id == b"DSD " || chunk_id == b"DST " {
            if chunk_size > 0 {
                data_length = chunk_size;
                saw_audio_data = true;
            }
            let _ = reader.seek(SeekFrom::Current(chunk_size as i64));
        } else {
            let _ = reader.seek(SeekFrom::Current(chunk_size as i64));
        }

        // Verify optional 0x00 odd-size alignment pad byte (avoid skipping next chunk ID if unpadded)
        if chunk_size % 2 == 1 {
            let mut pad = [0u8; 1];
            if reader.read_exact(&mut pad).is_ok() && pad[0] != 0 {
                let _ = reader.seek(SeekFrom::Current(-1));
            }
        }
    }

    if !saw_fs || !saw_chnl || !saw_audio_data {
        return Err(ProviderError::UnsupportedFormat(
            "Truncated or invalid DSDIFF file (missing PROP FS/CHNL or DSD/DST audio data)".into(),
        ));
    }

    let diin_samples: Vec<&[u8]> = diin_raw_entries.iter().map(|(_, b)| b.as_slice()).collect();
    let diin_encoding = detect_tag_block_encoding(&diin_samples);

    let mut diin_title: Option<String> = None;
    let mut diin_artist: Option<String> = None;
    let mut raw_diin_fields = Vec::new();
    for (id_str, raw_bytes) in diin_raw_entries {
        let text = sanitize_tag_text(&decode_bytes_with_encoding(&raw_bytes, diin_encoding));
        if !text.is_empty() {
            if id_str == "DITI" {
                diin_title = Some(text.clone());
            } else if id_str == "DIAR" {
                diin_artist = Some(text.clone());
            }
        }
        if collect_raw {
            raw_diin_fields.push((id_str, raw_bytes, text));
        }
    }

    let format = AudioFormat::dsd(AudioCodec::Dsdiff, sample_rate_hz, channels)?;
    let duration_ms = ((data_length as f64 * 8.0) / (sample_rate_hz as f64 * channels as f64)
        * 1000.0)
        .max(1.0) as u64;

    let tags = if let Some(parsed) = id3_parsed {
        let rg_track_db = parsed.effective_rg_track_db();
        let rg_album_db = parsed.effective_rg_album_db();
        let rg_track_peak = parsed.effective_rg_track_peak();
        let rg_album_peak = parsed.effective_rg_album_peak();
        DsdTags {
            title: parsed.title.or(diin_title),
            artist: parsed.artist.or(diin_artist),
            artists: parsed.artists,
            album: parsed.album,
            album_artist: parsed.album_artist,
            track_number: parsed.track_number,
            disc_number: parsed.disc_number,
            release_year: parsed.release_year,
            isrc: parsed.isrc,
            upc: parsed.upc,
            musicbrainz_release_group_id: parsed.musicbrainz_release_group_id,
            edition_label: parsed.edition_label,
            record_label: parsed.record_label,
            compilation: parsed.compilation,
            replay_gain_track_db: rg_track_db,
            replay_gain_album_db: rg_album_db,
            replay_gain_track_peak: rg_track_peak,
            replay_gain_album_peak: rg_album_peak,
            genre: parsed.genre,
            composer: parsed.composer,
            lyrics: parsed.lyrics,
            pictures: parsed.pictures,
            detected_encoding: parsed.detected_encoding,
            raw_id3_frames: parsed.raw_frames,
            raw_diin_fields,
        }
    } else {
        DsdTags {
            title: diin_title,
            artist: diin_artist,
            detected_encoding: diin_encoding,
            raw_diin_fields,
            ..Default::default()
        }
    };

    Ok(DsdMetadata {
        format,
        duration_ms,
        tags,
    })
}
