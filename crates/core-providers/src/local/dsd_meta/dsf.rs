use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat};

use super::{DsdMetadata, DsdTags, parse_id3v2_from_reader_ext};
use crate::error::ProviderError;

pub fn parse_dsf(path: &Path) -> Result<DsdMetadata, ProviderError> {
    parse_dsf_with_extract_options(path, true)
}

pub fn parse_dsf_with_extract_options(
    path: &Path,
    include_pictures: bool,
) -> Result<DsdMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_dsf_reader_ext(&mut file, false, include_pictures)
}

pub fn parse_dsf_with_raw(path: &Path) -> Result<DsdMetadata, ProviderError> {
    let mut file = File::open(path)?;
    parse_dsf_reader_ext(&mut file, true, true)
}

pub fn parse_dsf_reader<R: Read + Seek>(reader: &mut R) -> Result<DsdMetadata, ProviderError> {
    parse_dsf_reader_ext(reader, false, true)
}

pub fn parse_dsf_reader_with_options<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Result<DsdMetadata, ProviderError> {
    parse_dsf_reader_ext(reader, collect_raw, true)
}

pub fn parse_dsf_reader_ext<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
    include_pictures: bool,
) -> Result<DsdMetadata, ProviderError> {
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

    let channel_num = u32::from_le_bytes(fmt_buf[24..28].try_into().unwrap());
    let sample_rate = u32::from_le_bytes(fmt_buf[28..32].try_into().unwrap());
    let sample_count = u64::from_le_bytes(fmt_buf[36..44].try_into().unwrap());

    if !(1..=32).contains(&channel_num) || sample_rate == 0 || sample_count == 0 {
        return Err(ProviderError::UnsupportedFormat(
            "Invalid DSF fmt audio properties (channels/sample_rate/sample_count)".into(),
        ));
    }

    // 3. 'data' chunk header (12 bytes) — reject truncated header-only stubs without audio payload
    let mut data_hdr = [0u8; 12];
    reader.read_exact(&mut data_hdr).map_err(|e| {
        ProviderError::UnsupportedFormat(format!("Missing DSF 'data' chunk header: {e}"))
    })?;
    if &data_hdr[0..4] != b"data" {
        return Err(ProviderError::UnsupportedFormat(
            "Missing DSF 'data' chunk".into(),
        ));
    }
    let data_chunk_size = u64::from_le_bytes(data_hdr[4..12].try_into().unwrap());
    if data_chunk_size <= 12 {
        return Err(ProviderError::UnsupportedFormat(
            "DSF 'data' chunk contains no audio payload".into(),
        ));
    }

    let channels = channel_num as u8;
    let format = AudioFormat::dsd(AudioCodec::Dsf, sample_rate, channels)?;
    let duration_ms = ((sample_count as f64 / sample_rate as f64) * 1000.0).max(1.0) as u64;

    let mut tags = DsdTags::default();
    // Compare against actual EOF rather than header's stored `file_size`, since some DSF taggers
    // append ID3v2 blocks without updating the 64-bit file_size field in the 'DSD ' chunk.
    let actual_file_len = reader.seek(SeekFrom::End(0)).unwrap_or(file_size);
    if metadata_offset > 0 && metadata_offset < actual_file_len {
        if reader.seek(SeekFrom::Start(metadata_offset)).is_ok() {
            if let Some(parsed) = parse_id3v2_from_reader_ext(reader, collect_raw, include_pictures)
            {
                tags = DsdTags {
                    title: parsed.title.clone(),
                    artist: parsed.artist.clone(),
                    artists: parsed.artists.clone(),
                    album: parsed.album.clone(),
                    album_artist: parsed.album_artist.clone(),
                    track_number: parsed.track_number,
                    disc_number: parsed.disc_number,
                    release_year: parsed.release_year,
                    isrc: parsed.isrc.clone(),
                    upc: parsed.upc.clone(),
                    musicbrainz_release_group_id: parsed.musicbrainz_release_group_id.clone(),
                    edition_label: parsed.edition_label.clone(),
                    record_label: parsed.record_label.clone(),
                    compilation: parsed.compilation,
                    replay_gain_track_db: parsed.effective_rg_track_db(),
                    replay_gain_album_db: parsed.effective_rg_album_db(),
                    replay_gain_track_peak: parsed.effective_rg_track_peak(),
                    replay_gain_album_peak: parsed.effective_rg_album_peak(),
                    genre: parsed.genre.clone(),
                    composer: parsed.composer.clone(),
                    lyrics: parsed.lyrics.clone(),
                    pictures: parsed.pictures.clone(),
                    detected_encoding: parsed.detected_encoding,
                    raw_id3_frames: parsed.raw_frames,
                    raw_diin_fields: Vec::new(),
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
