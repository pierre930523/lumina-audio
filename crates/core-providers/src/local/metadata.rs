use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, StandardTagKey, Value};
use symphonia::core::probe::Hint;

use super::dsd_meta::{
    decode_syncsafe, parse_dff, parse_dff_reader, parse_dsf, parse_dsf_reader,
    parse_id3v2_from_reader, parse_id3v2_from_slice, parse_replay_gain_db_str,
    parse_replay_gain_peak_str, parse_slash_number, parse_track_and_disc_number, parse_year,
    Id3v2ParsedTags,
};
use crate::error::ProviderError;

#[derive(Debug, Clone)]
pub struct ExtractedMetadata {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub track_number: u16,
    pub disc_number: u16,
    pub release_year: Option<i32>,
    pub isrc: Option<String>,
    pub duration_ms: u64,
    pub format: AudioFormat,
    pub cover_url: Option<String>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub embedded_lyrics: Option<String>,
    pub pictures: Vec<core_types::ExtractedPicture>,
}

impl Default for ExtractedMetadata {
    fn default() -> Self {
        Self {
            title: String::new(),
            artist: String::new(),
            album: String::new(),
            album_artist: None,
            track_number: 1,
            disc_number: 1,
            release_year: None,
            isrc: None,
            duration_ms: 1000,
            format: AudioFormat::cd_quality(),
            cover_url: None,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
            upc: None,
            musicbrainz_release_group_id: None,
            edition_label: None,
            genre: None,
            composer: None,
            embedded_lyrics: None,
            pictures: Vec::new(),
        }
    }
}

pub struct MetadataExtractor;

impl MetadataExtractor {
    pub fn extract(path: &Path) -> Result<ExtractedMetadata, ProviderError> {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();

        match ext.as_str() {
            "wav" | "wave" => Self::extract_wav(path),
            "dsf" => Self::extract_dsf(path),
            "dff" => Self::extract_dff(path),
            "flac" => {
                if let Ok(meta) = Self::extract_flac(path) {
                    Ok(meta)
                } else {
                    Self::extract_symphonia(path, &ext)
                }
            }
            _ => Self::extract_symphonia(path, &ext),
        }
    }

    pub fn extract_from_bytes(
        bytes: Vec<u8>,
        ext: &str,
        virtual_path: Option<&Path>,
    ) -> Result<ExtractedMetadata, ProviderError> {
        let ext_lower = ext.trim().trim_start_matches('.').to_ascii_lowercase();
        let fallback_path = virtual_path.unwrap_or_else(|| Path::new("Unknown Title"));

        match ext_lower.as_str() {
            "wav" | "wave" => {
                let mut cursor = Cursor::new(bytes);
                let wav = super::riff_meta::parse_wav_reader(&mut cursor)?;
                Ok(build_wav_extracted(wav, fallback_path))
            }
            "dsf" => {
                let mut cursor = Cursor::new(bytes);
                let dsd = parse_dsf_reader(&mut cursor)?;
                Ok(build_dsf_extracted(dsd, fallback_path))
            }
            "dff" => {
                let mut cursor = Cursor::new(bytes);
                let dsd = parse_dff_reader(&mut cursor)?;
                Ok(build_dff_extracted(dsd, fallback_path))
            }
            "flac" => {
                let cursor = Cursor::new(bytes.clone());
                if let Ok(meta) = extract_flac_from_reader(cursor, fallback_path) {
                    Ok(meta)
                } else {
                    let id3_fallback = scan_id3v2_from_slice(&bytes, &ext_lower);
                    let cursor = Cursor::new(bytes);
                    Self::extract_symphonia_from_source(
                        Box::new(cursor),
                        &ext_lower,
                        fallback_path,
                        id3_fallback,
                    )
                }
            }
            _ => {
                let id3_fallback = scan_id3v2_from_slice(&bytes, &ext_lower);
                let cursor = Cursor::new(bytes);
                Self::extract_symphonia_from_source(
                    Box::new(cursor),
                    &ext_lower,
                    fallback_path,
                    id3_fallback,
                )
            }
        }
    }

    fn extract_flac(path: &Path) -> Result<ExtractedMetadata, ProviderError> {
        let file = File::open(path)?;
        extract_flac_from_reader(file, path)
    }

    fn extract_wav(path: &Path) -> Result<ExtractedMetadata, ProviderError> {
        let wav = super::riff_meta::parse_wav(path)?;
        Ok(build_wav_extracted(wav, path))
    }

    fn extract_dsf(path: &Path) -> Result<ExtractedMetadata, ProviderError> {
        let dsd = parse_dsf(path)?;
        Ok(build_dsf_extracted(dsd, path))
    }

    fn extract_dff(path: &Path) -> Result<ExtractedMetadata, ProviderError> {
        let dsd = parse_dff(path)?;
        Ok(build_dff_extracted(dsd, path))
    }

    fn extract_symphonia(path: &Path, ext: &str) -> Result<ExtractedMetadata, ProviderError> {
        let id3_fallback = scan_id3v2_from_file(path, ext);
        let file = File::open(path)?;
        Self::extract_symphonia_from_source(Box::new(file), ext, path, id3_fallback)
    }

    fn extract_symphonia_from_source(
        source: Box<dyn MediaSource>,
        ext: &str,
        fallback_path: &Path,
        id3_fallback: Option<Id3v2ParsedTags>,
    ) -> Result<ExtractedMetadata, ProviderError> {
        let mss = MediaSourceStream::new(source, MediaSourceStreamOptions::default());

        let mut hint = Hint::new();
        if !ext.is_empty() {
            hint.with_extension(ext);
        }

        let format_opts = FormatOptions::default();
        let meta_opts = MetadataOptions::default();

        let mut probed = symphonia::default::get_probe()
            .format(&hint, mss, &format_opts, &meta_opts)
            .map_err(|e| {
                ProviderError::UnsupportedFormat(format!(
                    "Failed to probe audio file {fallback_path:?}: {e}"
                ))
            })?;

        let track = probed
            .format
            .default_track()
            .or_else(|| probed.format.tracks().first())
            .ok_or_else(|| {
                ProviderError::UnsupportedFormat(format!("No audio tracks in {fallback_path:?}"))
            })?;

        let codec_params = &track.codec_params;

        let sample_rate = codec_params.sample_rate.unwrap_or(44100);
        let channels = codec_params.channels.map(|c| c.count() as u8).unwrap_or(2);
        let bit_depth = codec_params
            .bits_per_sample
            .or(codec_params.bits_per_coded_sample)
            .unwrap_or(16) as u8;

        let sym_codec = codec_params.codec;
        let codec = if sym_codec == symphonia::core::codecs::CODEC_TYPE_AAC {
            AudioCodec::Aac
        } else if sym_codec == symphonia::core::codecs::CODEC_TYPE_ALAC {
            AudioCodec::Alac
        } else {
            map_extension_to_codec(ext)
        };

        let format = if codec.is_dsd() {
            AudioFormat::dsd(codec, sample_rate, channels)?
        } else {
            AudioFormat::pcm(codec, sample_rate, bit_depth.clamp(8, 32), channels.clamp(1, 8))?
        };

        let duration_ms = if let Some(n_frames) = codec_params.n_frames {
            if sample_rate > 0 {
                ((n_frames as f64 / sample_rate as f64) * 1000.0).max(1.0) as u64
            } else {
                1000
            }
        } else {
            1000
        };

        let mut raw_title: Option<String> = None;
        let mut raw_artist: Option<String> = None;
        let mut raw_album: Option<String> = None;
        let mut raw_album_artist: Option<String> = None;
        let mut raw_track_number: Option<u16> = None;
        let mut raw_disc_number: Option<u16> = None;
        let mut raw_year: Option<i32> = None;
        let mut raw_isrc: Option<String> = None;
        let mut raw_rg_track_db: Option<f64> = None;
        let mut raw_rg_album_db: Option<f64> = None;
        let mut raw_rg_track_peak: Option<f64> = None;
        let mut raw_rg_album_peak: Option<f64> = None;
        let mut raw_upc: Option<String> = None;
        let mut raw_mb_rg_id: Option<String> = None;
        let mut raw_edition: Option<String> = None;
        let mut raw_genre: Option<String> = None;
        let mut raw_composer: Option<String> = None;
        let mut raw_lyrics: Option<String> = None;
        let mut extracted_pictures: Vec<core_types::ExtractedPicture> = Vec::new();

        let mut check_meta = |meta: &symphonia::core::meta::MetadataRevision| {
            for vis in meta.visuals() {
                let pt = match vis.usage {
                    Some(symphonia::core::meta::StandardVisualKey::FrontCover) => {
                        core_types::PictureType::FrontCover
                    }
                    Some(symphonia::core::meta::StandardVisualKey::BackCover) => {
                        core_types::PictureType::BackCover
                    }
                    _ => core_types::PictureType::Other,
                };
                extracted_pictures.push(core_types::ExtractedPicture {
                    picture_type: pt,
                    mime_type: vis.media_type.clone(),
                    data: vis.data.to_vec(),
                });
            }

            for tag in meta.tags() {
                let tag_str = match &tag.value {
                    Value::String(s) => s.clone(),
                    Value::UnsignedInt(u) => u.to_string(),
                    Value::SignedInt(i) => i.to_string(),
                    Value::Float(f) => f.to_string(),
                    _ => continue,
                };

                if let Some(std_key) = tag.std_key {
                    match std_key {
                        StandardTagKey::TrackTitle => raw_title = Some(tag_str),
                        StandardTagKey::Artist => raw_artist = Some(tag_str),
                        StandardTagKey::Album => raw_album = Some(tag_str),
                        StandardTagKey::AlbumArtist => raw_album_artist = Some(tag_str),
                        StandardTagKey::Genre => {
                            if raw_genre.is_none() {
                                raw_genre = Some(tag_str);
                            }
                        }
                        StandardTagKey::Composer => {
                            if raw_composer.is_none() {
                                raw_composer = Some(tag_str);
                            }
                        }
                        StandardTagKey::Lyrics => {
                            if raw_lyrics.is_none() {
                                raw_lyrics = Some(tag_str);
                            }
                        }
                        StandardTagKey::TrackNumber => {
                            let (trk, disc) = parse_track_and_disc_number(&tag_str);
                            if let Some(num) = trk {
                                raw_track_number = Some(num);
                            }
                            if raw_disc_number.is_none() {
                                if let Some(d) = disc {
                                    raw_disc_number = Some(d);
                                }
                            }
                        }
                        StandardTagKey::DiscNumber => {
                            if let Some(num) = parse_slash_number(&tag_str) {
                                raw_disc_number = Some(num);
                            }
                        }
                        StandardTagKey::ReleaseDate => {
                            if let Some(yr) = parse_year(&tag_str) {
                                raw_year = Some(yr);
                            }
                        }
                        StandardTagKey::IdentIsrc => {
                            if let Some(clean) = normalize_isrc(&tag_str) {
                                raw_isrc = Some(clean);
                            }
                        }
                        StandardTagKey::IdentBarcode
                        | StandardTagKey::IdentUpc
                        | StandardTagKey::IdentEanUpn => {
                            if raw_upc.is_none() {
                                raw_upc = normalize_upc(&tag_str);
                            }
                        }
                        StandardTagKey::MusicBrainzReleaseGroupId => {
                            if raw_mb_rg_id.is_none() && !tag_str.trim().is_empty() {
                                raw_mb_rg_id = Some(tag_str.trim().to_string());
                            }
                        }
                        StandardTagKey::ReplayGainTrackGain => {
                            if raw_rg_track_db.is_none() {
                                raw_rg_track_db = parse_replay_gain_db_value(&tag.value);
                            }
                        }
                        StandardTagKey::ReplayGainAlbumGain => {
                            if raw_rg_album_db.is_none() {
                                raw_rg_album_db = parse_replay_gain_db_value(&tag.value);
                            }
                        }
                        StandardTagKey::ReplayGainTrackPeak => {
                            if raw_rg_track_peak.is_none() {
                                raw_rg_track_peak = parse_replay_gain_peak_value(&tag.value);
                            }
                        }
                        StandardTagKey::ReplayGainAlbumPeak if raw_rg_album_peak.is_none() => {
                            raw_rg_album_peak = parse_replay_gain_peak_value(&tag.value);
                        }
                        _ => {}
                    }
                } else {
                    let norm_key = normalize_custom_tag_key(&tag.key);
                    match norm_key.as_str() {
                        "TITLE" if raw_title.is_none() => raw_title = Some(tag_str),
                        "ARTIST" if raw_artist.is_none() => raw_artist = Some(tag_str),
                        "ALBUM" if raw_album.is_none() => raw_album = Some(tag_str),
                        "ALBUMARTIST" if raw_album_artist.is_none() => {
                            raw_album_artist = Some(tag_str)
                        }
                        "TRACKNUMBER" | "TRACK" if raw_track_number.is_none() => {
                            let (trk, disc) = parse_track_and_disc_number(&tag_str);
                            if let Some(num) = trk {
                                raw_track_number = Some(num);
                            }
                            if raw_disc_number.is_none() {
                                if let Some(d) = disc {
                                    raw_disc_number = Some(d);
                                }
                            }
                        }
                        "DISCNUMBER" | "DISC" if raw_disc_number.is_none() => {
                            raw_disc_number = parse_slash_number(&tag_str);
                        }
                        "DATE" | "YEAR" if raw_year.is_none() => {
                            raw_year = parse_year(&tag_str);
                        }
                        "ISRC" if raw_isrc.is_none() => {
                            raw_isrc = normalize_isrc(&tag_str);
                        }
                        "REPLAYGAINTRACKGAIN" | "REPLAYGAIN_TRACK_GAIN" if raw_rg_track_db.is_none() => {
                            raw_rg_track_db = parse_replay_gain_db_value(&tag.value);
                        }
                        "REPLAYGAINALBUMGAIN" | "REPLAYGAIN_ALBUM_GAIN" if raw_rg_album_db.is_none() => {
                            raw_rg_album_db = parse_replay_gain_db_value(&tag.value);
                        }
                        "REPLAYGAINTRACKPEAK" | "REPLAYGAIN_TRACK_PEAK" if raw_rg_track_peak.is_none() => {
                            raw_rg_track_peak = parse_replay_gain_peak_value(&tag.value);
                        }
                        "REPLAYGAINALBUMPEAK" | "REPLAYGAIN_ALBUM_PEAK" if raw_rg_album_peak.is_none() => {
                            raw_rg_album_peak = parse_replay_gain_peak_value(&tag.value);
                        }
                        "UPC" | "BARCODE" | "EAN" if raw_upc.is_none() => {
                            raw_upc = normalize_upc(&tag_str);
                        }
                        "MUSICBRAINZRELEASEGROUPID" | "MUSICBRAINZ_RELEASEGROUPID" | "MUSICBRAINZ RELEASE GROUP ID"
                            if raw_mb_rg_id.is_none() =>
                        {
                            let trimmed = tag_str.trim();
                            if !trimmed.is_empty() {
                                raw_mb_rg_id = Some(trimmed.to_string());
                            }
                        }
                        "EDITION" | "VERSION" | "RELEASETYPE" if raw_edition.is_none() => {
                            let trimmed = tag_str.trim();
                            if !trimmed.is_empty() {
                                raw_edition = Some(trimmed.to_string());
                            }
                        }
                        "GENRE" if raw_genre.is_none() => raw_genre = Some(tag_str),
                        "COMPOSER" if raw_composer.is_none() => raw_composer = Some(tag_str),
                        "LYRICS" | "UNSYNCEDLYRICS" | "UNSYNCED LYRICS" if raw_lyrics.is_none() => {
                            raw_lyrics = Some(tag_str);
                        }
                        _ => {}
                    }
                }
            }
        };

        if let Some(meta) = probed.format.metadata().current() {
            check_meta(meta);
        }
        if let Some(reader) = probed.metadata.get() {
            if let Some(meta) = reader.current() {
                check_meta(meta);
            }
        }

        // Apply ID3v2 fallback (TXXX precedence already applied inside Id3v2ParsedTags,
        // and Symphonia-extracted values take precedence over ID3v2 fallback).
        if let Some(id3) = id3_fallback {
            let id3_rg_track_db = id3.effective_rg_track_db();
            let id3_rg_album_db = id3.effective_rg_album_db();
            let id3_rg_track_peak = id3.effective_rg_track_peak();
            let id3_rg_album_peak = id3.effective_rg_album_peak();
            if raw_title.is_none() {
                raw_title = id3.title;
            }
            if raw_artist.is_none() {
                raw_artist = id3.artist;
            }
            if raw_album.is_none() {
                raw_album = id3.album;
            }
            if raw_album_artist.is_none() {
                raw_album_artist = id3.album_artist;
            }
            if raw_track_number.is_none() {
                raw_track_number = id3.track_number;
            }
            if raw_disc_number.is_none() {
                raw_disc_number = id3.disc_number;
            }
            if raw_year.is_none() {
                raw_year = id3.release_year;
            }
            if raw_rg_track_db.is_none() {
                raw_rg_track_db = id3_rg_track_db;
            }
            if raw_rg_album_db.is_none() {
                raw_rg_album_db = id3_rg_album_db;
            }
            if raw_rg_track_peak.is_none() {
                raw_rg_track_peak = id3_rg_track_peak;
            }
            if raw_rg_album_peak.is_none() {
                raw_rg_album_peak = id3_rg_album_peak;
            }
            if raw_isrc.is_none() {
                raw_isrc = id3.isrc;
            }
            if raw_upc.is_none() {
                raw_upc = id3.upc;
            }
            if raw_mb_rg_id.is_none() {
                raw_mb_rg_id = id3.musicbrainz_release_group_id;
            }
            if raw_edition.is_none() {
                raw_edition = id3.edition_label;
            }
            if raw_genre.is_none() {
                raw_genre = id3.genre;
            }
            if raw_composer.is_none() {
                raw_composer = id3.composer;
            }
            if raw_lyrics.is_none() {
                raw_lyrics = id3.lyrics;
            }
            if extracted_pictures.is_empty() {
                extracted_pictures = id3.pictures;
            }
        }

        // ID3v1 fallback for MP3 if title or artist are still missing
        if (raw_title.is_none() || raw_artist.is_none()) && ext == "mp3" {
            if let Ok(mut f) = File::open(fallback_path) {
                if let Ok(meta_len) = f.metadata() {
                    if meta_len.len() >= 128 {
                        if f.seek(SeekFrom::End(-128)).is_ok() {
                            let mut v1_buf = [0u8; 128];
                            if f.read_exact(&mut v1_buf).is_ok() && &v1_buf[0..3] == b"TAG" {
                                let v1_title = super::lyrics::decode_text_cjk(&v1_buf[3..33])
                                    .trim_matches('\0')
                                    .trim()
                                    .to_string();
                                let v1_artist = super::lyrics::decode_text_cjk(&v1_buf[33..63])
                                    .trim_matches('\0')
                                    .trim()
                                    .to_string();
                                let v1_album = super::lyrics::decode_text_cjk(&v1_buf[63..93])
                                    .trim_matches('\0')
                                    .trim()
                                    .to_string();
                                let v1_year = super::lyrics::decode_text_cjk(&v1_buf[93..97])
                                    .trim_matches('\0')
                                    .trim()
                                    .to_string();
                                if raw_title.is_none() && !v1_title.is_empty() {
                                    raw_title = Some(v1_title);
                                }
                                if raw_artist.is_none() && !v1_artist.is_empty() {
                                    raw_artist = Some(v1_artist);
                                }
                                if raw_album.is_none() && !v1_album.is_empty() {
                                    raw_album = Some(v1_album);
                                }
                                if raw_year.is_none() {
                                    raw_year = parse_year(&v1_year);
                                }
                            }
                        }
                    }
                }
            }
        }

        let (title_fallback, track_num_fallback) = derive_title_and_track_from_filename(fallback_path);
        let (album_fallback, artist_fallback) = derive_album_and_artist_from_dir(fallback_path);

        let title = raw_title
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(title_fallback);
        let title = if title.trim().is_empty() {
            "Unknown Title".to_string()
        } else {
            title
        };

        let artist = raw_artist
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(artist_fallback);
        let artist = if artist.trim().is_empty() {
            "Unknown Artist".to_string()
        } else {
            artist
        };

        let album = raw_album
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(album_fallback);
        let album = if album.trim().is_empty() {
            "Unknown Album".to_string()
        } else {
            album
        };

        let album_artist = raw_album_artist.filter(|s| !s.trim().is_empty());
        let track_number = raw_track_number.unwrap_or(track_num_fallback).max(1);
        let disc_number = raw_disc_number.unwrap_or(1).max(1);

        Ok(ExtractedMetadata {
            title,
            artist,
            album,
            album_artist,
            track_number,
            disc_number,
            release_year: raw_year,
            isrc: raw_isrc,
            duration_ms: duration_ms.max(1),
            format,
            cover_url: None,
            replay_gain_track_db: raw_rg_track_db,
            replay_gain_album_db: raw_rg_album_db,
            replay_gain_track_peak: raw_rg_track_peak,
            replay_gain_album_peak: raw_rg_album_peak,
            upc: raw_upc,
            musicbrainz_release_group_id: raw_mb_rg_id,
            edition_label: raw_edition,
            genre: raw_genre,
            composer: raw_composer,
            embedded_lyrics: raw_lyrics,
            pictures: extracted_pictures,
        })
    }
}

fn build_wav_extracted(wav: super::riff_meta::RiffWavMetadata, path: &Path) -> ExtractedMetadata {
    let (title_fallback, track_num_fallback) = derive_title_and_track_from_filename(path);
    let (album_fallback, artist_fallback) = derive_album_and_artist_from_dir(path);

    let title = wav
        .title
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(title_fallback);
    let title = if title.trim().is_empty() {
        "Unknown Title".to_string()
    } else {
        title
    };

    let artist = wav
        .artist
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(artist_fallback);
    let artist = if artist.trim().is_empty() {
        "Unknown Artist".to_string()
    } else {
        artist
    };

    let album = wav
        .album
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(album_fallback);
    let album = if album.trim().is_empty() {
        "Unknown Album".to_string()
    } else {
        album
    };

    let album_artist = wav.album_artist.filter(|s| !s.trim().is_empty());
    let track_number = wav.track_number.unwrap_or(track_num_fallback).max(1);
    let disc_number = wav.disc_number.unwrap_or(1).max(1);

    ExtractedMetadata {
        title,
        artist,
        album,
        album_artist,
        track_number,
        disc_number,
        release_year: wav.release_year,
        isrc: wav.isrc,
        duration_ms: wav.duration_ms.max(1),
        format: wav.format,
        cover_url: None,
        replay_gain_track_db: None,
        replay_gain_album_db: None,
        replay_gain_track_peak: None,
        replay_gain_album_peak: None,
        upc: None,
        musicbrainz_release_group_id: None,
        edition_label: None,
        genre: wav.genre,
        composer: wav.composer,
        embedded_lyrics: wav.lyrics,
        pictures: wav.pictures,
    }
}

fn build_dsf_extracted(dsd: super::dsd_meta::DsdMetadata, path: &Path) -> ExtractedMetadata {
    let (title_fallback, track_num_fallback) = derive_title_and_track_from_filename(path);
    let (album_fallback, artist_fallback) = derive_album_and_artist_from_dir(path);

    let title = dsd
        .tags
        .title
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(title_fallback);
    let title = if title.trim().is_empty() {
        "Unknown Title".to_string()
    } else {
        title
    };

    let artist = dsd
        .tags
        .artist
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(artist_fallback);
    let artist = if artist.trim().is_empty() {
        "Unknown Artist".to_string()
    } else {
        artist
    };

    let album = dsd
        .tags
        .album
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(album_fallback);
    let album = if album.trim().is_empty() {
        "Unknown Album".to_string()
    } else {
        album
    };

    let album_artist = dsd.tags.album_artist.filter(|s| !s.trim().is_empty());
    let track_number = dsd.tags.track_number.unwrap_or(track_num_fallback).max(1);
    let disc_number = dsd.tags.disc_number.unwrap_or(1).max(1);

    ExtractedMetadata {
        title,
        artist,
        album,
        album_artist,
        track_number,
        disc_number,
        release_year: dsd.tags.release_year,
        isrc: dsd.tags.isrc,
        duration_ms: dsd.duration_ms.max(1),
        format: dsd.format,
        cover_url: None,
        replay_gain_track_db: dsd.tags.replay_gain_track_db,
        replay_gain_album_db: dsd.tags.replay_gain_album_db,
        replay_gain_track_peak: dsd.tags.replay_gain_track_peak,
        replay_gain_album_peak: dsd.tags.replay_gain_album_peak,
        upc: dsd.tags.upc,
        musicbrainz_release_group_id: dsd.tags.musicbrainz_release_group_id,
        edition_label: dsd.tags.edition_label,
        genre: dsd.tags.genre,
        composer: dsd.tags.composer,
        embedded_lyrics: dsd.tags.lyrics,
        pictures: dsd.tags.pictures,
    }
}

fn build_dff_extracted(dsd: super::dsd_meta::DsdMetadata, path: &Path) -> ExtractedMetadata {
    let (title_fallback, track_num_fallback) = derive_title_and_track_from_filename(path);
    let (album_fallback, artist_fallback) = derive_album_and_artist_from_dir(path);

    let title = dsd
        .tags
        .title
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(title_fallback);
    let title = if title.trim().is_empty() {
        "Unknown Title".to_string()
    } else {
        title
    };

    let artist = dsd
        .tags
        .artist
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(artist_fallback);
    let artist = if artist.trim().is_empty() {
        "Unknown Artist".to_string()
    } else {
        artist
    };

    let album = dsd
        .tags
        .album
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(album_fallback);
    let album = if album.trim().is_empty() {
        "Unknown Album".to_string()
    } else {
        album
    };

    let album_artist = dsd.tags.album_artist.filter(|s| !s.trim().is_empty());
    let track_number = dsd.tags.track_number.unwrap_or(track_num_fallback).max(1);
    let disc_number = dsd.tags.disc_number.unwrap_or(1).max(1);

    ExtractedMetadata {
        title,
        artist,
        album,
        album_artist,
        track_number,
        disc_number,
        release_year: dsd.tags.release_year,
        isrc: dsd.tags.isrc,
        duration_ms: dsd.duration_ms.max(1),
        format: dsd.format,
        cover_url: None,
        replay_gain_track_db: dsd.tags.replay_gain_track_db,
        replay_gain_album_db: dsd.tags.replay_gain_album_db,
        replay_gain_track_peak: dsd.tags.replay_gain_track_peak,
        replay_gain_album_peak: dsd.tags.replay_gain_album_peak,
        upc: dsd.tags.upc,
        musicbrainz_release_group_id: dsd.tags.musicbrainz_release_group_id,
        edition_label: dsd.tags.edition_label,
        genre: dsd.tags.genre,
        composer: dsd.tags.composer,
        embedded_lyrics: dsd.tags.lyrics,
        pictures: dsd.tags.pictures,
    }
}

fn normalize_custom_tag_key(raw_key: &str) -> String {
    let trimmed = raw_key.trim();
    let tail = trimmed.rsplit(':').next().unwrap_or(trimmed).trim();
    tail.to_ascii_uppercase().replace([' ', '_', '-'], "")
}

fn parse_replay_gain_db_value(value: &Value) -> Option<f64> {
    match value {
        Value::Float(f) => f.is_finite().then_some(*f),
        Value::SignedInt(i) => Some(*i as f64),
        Value::UnsignedInt(u) => Some(*u as f64),
        Value::String(s) => parse_replay_gain_db_str(s),
        _ => None,
    }
}

fn parse_replay_gain_peak_value(value: &Value) -> Option<f64> {
    match value {
        Value::Float(f) => (f.is_finite() && *f >= 0.0).then_some(*f),
        Value::String(s) => parse_replay_gain_peak_str(s),
        _ => None,
    }
}

fn normalize_isrc(raw: &str) -> Option<String> {
    let clean = raw.trim().replace('-', "").to_ascii_uppercase();
    if clean.len() == 12 && clean.chars().all(|c| c.is_ascii_alphanumeric()) {
        Some(clean)
    } else {
        None
    }
}

fn normalize_upc(raw: &str) -> Option<String> {
    let clean: String = raw.trim().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if clean.is_empty() {
        None
    } else {
        Some(clean)
    }
}

fn scan_id3v2_from_file(path: &Path, ext: &str) -> Option<Id3v2ParsedTags> {
    if !matches!(ext, "mp3" | "wav" | "wave" | "aiff" | "aif" | "aac") {
        return None;
    }
    let mut file = File::open(path).ok()?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).ok()?;
    file.seek(SeekFrom::Start(0)).ok()?;
    if &magic[0..3] == b"ID3" {
        return parse_id3v2_from_reader(&mut file);
    }
    None
}

fn scan_id3v2_from_slice(bytes: &[u8], ext: &str) -> Option<Id3v2ParsedTags> {
    if !matches!(ext, "mp3" | "wav" | "wave" | "aiff" | "aif" | "aac") {
        return None;
    }
    if bytes.len() >= 10 && &bytes[0..3] == b"ID3" {
        return parse_id3v2_from_slice(bytes);
    }
    None
}

fn map_extension_to_codec(ext: &str) -> AudioCodec {
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

pub fn derive_title_and_track_from_filename(path: &Path) -> (String, u16) {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Unknown Title");

    let trimmed = stem.trim();
    if trimmed.is_empty() {
        return ("Unknown Title".to_string(), 1);
    }

    // Purely numeric stem (e.g. "1999" or "2001") is the title itself, not a track number!
    if trimmed.chars().all(|c| c.is_ascii_digit()) {
        return (trimmed.to_string(), 1);
    }

    let mut num_str = String::new();
    let mut rest = trimmed;

    for (idx, ch) in trimmed.char_indices() {
        if ch.is_ascii_digit() && num_str.len() < 3 {
            num_str.push(ch);
        } else {
            rest = &trimmed[idx..];
            break;
        }
    }

    let track_num = num_str.parse::<u16>().unwrap_or(1).max(1);

    let clean_title = rest
        .trim_start_matches(|c: char| c == '-' || c == '.' || c == '_' || c.is_whitespace())
        .trim();

    let final_title = if clean_title.trim().is_empty() {
        trimmed.to_string()
    } else {
        clean_title.to_string()
    };

    let final_title = if final_title.trim().is_empty() {
        "Unknown Title".to_string()
    } else {
        final_title
    };

    (final_title, track_num)
}

pub fn is_generic_directory_name(name: &str) -> bool {
    let lower = name.trim().to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "" | "music"
            | "mymusic"
            | "my music"
            | "desktop"
            | "downloads"
            | "download"
            | "documents"
            | "mydocuments"
            | "my documents"
            | "flac"
            | "mp3"
            | "hi-res"
            | "hires"
            | "audio"
            | "sound"
            | "tracks"
            | "songs"
            | "album"
            | "albums"
            | "artist"
            | "artists"
            | "various"
            | "various artists"
            | "unknown"
            | "unknown artist"
            | "unknown album"
            | "users"
            | "user"
            | "home"
    ) || lower.starts_with("cd")
        || lower.starts_with("disc")
        || lower.starts_with("disk")
}

pub fn derive_album_and_artist_from_dir(path: &Path) -> (String, String) {
    let parent = path.parent();
    let mut album_dir = parent.and_then(|p| p.file_name()).and_then(|n| n.to_str()).unwrap_or("");
    let mut artist_dir = parent.and_then(|p| p.parent()).and_then(|p| p.file_name()).and_then(|n| n.to_str()).unwrap_or("");

    // Detect multi-disc subfolders (CD1, Disc 2, etc.)
    let lower_album = album_dir.trim().to_ascii_lowercase();
    if lower_album.starts_with("cd") || lower_album.starts_with("disc") || lower_album.starts_with("disk") {
        album_dir = artist_dir;
        artist_dir = parent
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
    }

    let album_name = if album_dir.trim().is_empty() || is_generic_directory_name(album_dir) {
        "Unknown Album".to_string()
    } else {
        album_dir.trim().to_string()
    };

    let artist_name = if artist_dir.trim().is_empty() || is_generic_directory_name(artist_dir) {
        "Unknown Artist".to_string()
    } else {
        artist_dir.trim().to_string()
    };

    (album_name, artist_name)
}

fn extract_flac_from_reader<R: Read + Seek>(
    mut reader: R,
    fallback_path: &Path,
) -> Result<ExtractedMetadata, ProviderError> {
    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic)?;

    let mut id3_fallback = None;
    if &magic[0..3] == b"ID3" {
        let mut hdr_tail = [0u8; 6];
        reader.read_exact(&mut hdr_tail)?;
        let major = hdr_tail[1];
        let flags = hdr_tail[2];
        let tag_size = decode_syncsafe(&hdr_tail[2..6]) as usize;
        let mut body = vec![0u8; tag_size];
        let _ = reader.read_exact(&mut body);
        id3_fallback = Some(super::dsd_meta::parse_id3v2_body(&body, major, flags));

        let mut b = [0u8; 1];
        while reader.read_exact(&mut b).is_ok() {
            if b[0] != 0 {
                let mut rest = [0u8; 3];
                reader.read_exact(&mut rest)?;
                magic = [b[0], rest[0], rest[1], rest[2]];
                break;
            }
        }
    }

    if &magic != b"fLaC" {
        return Err(ProviderError::UnsupportedFormat(
            "Invalid FLAC stream marker".to_string(),
        ));
    }

    let mut sample_rate = 44100u32;
    let mut channels = 2u8;
    let mut bit_depth = 16u8;
    let mut duration_ms = 1000u64;

    let mut raw_title: Option<String> = None;
    let mut raw_artist: Option<String> = None;
    let mut raw_album: Option<String> = None;
    let mut raw_album_artist: Option<String> = None;
    let mut raw_track_number: Option<u16> = None;
    let mut raw_disc_number: Option<u16> = None;
    let mut raw_year: Option<i32> = None;
    let mut raw_isrc: Option<String> = None;
    let mut raw_rg_track_db: Option<f64> = None;
    let mut raw_rg_album_db: Option<f64> = None;
    let mut raw_rg_track_peak: Option<f64> = None;
    let mut raw_rg_album_peak: Option<f64> = None;
    let mut raw_upc: Option<String> = None;
    let mut raw_mb_rg_id: Option<String> = None;
    let mut raw_edition: Option<String> = None;
    let mut raw_genre: Option<String> = None;
    let mut raw_composer: Option<String> = None;
    let mut raw_lyrics: Option<String> = None;
    let mut extracted_pictures: Vec<core_types::ExtractedPicture> = Vec::new();

    loop {
        let mut hdr = [0u8; 4];
        if reader.read_exact(&mut hdr).is_err() {
            break;
        }
        let is_last = (hdr[0] & 0x80) != 0;
        let block_type = hdr[0] & 0x7F;
        let block_len = ((hdr[1] as usize) << 16) | ((hdr[2] as usize) << 8) | (hdr[3] as usize);

        match block_type {
            0 => {
                let mut data = vec![0u8; block_len];
                if reader.read_exact(&mut data).is_ok() && block_len >= 18 {
                    let b = &data[10..18];
                    sample_rate = ((b[0] as u32) << 12) | ((b[1] as u32) << 4) | ((b[2] as u32) >> 4);
                    channels = (((b[2] >> 1) & 0x07) + 1) as u8;
                    bit_depth = ((((b[2] & 0x01) << 4) | (b[3] >> 4)) + 1) as u8;
                    let total_samples = (((b[3] & 0x0F) as u64) << 32)
                        | ((b[4] as u64) << 24)
                        | ((b[5] as u64) << 16)
                        | ((b[6] as u64) << 8)
                        | (b[7] as u64);
                    if sample_rate > 0 {
                        duration_ms = ((total_samples * 1000) / sample_rate as u64).max(1);
                    }
                }
            }
            4 => {
                let mut data = vec![0u8; block_len];
                if reader.read_exact(&mut data).is_ok() && data.len() >= 8 {
                    let vendor_len = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
                    let mut cursor = 4 + vendor_len;
                    if cursor + 4 <= data.len() {
                        let count = u32::from_le_bytes(data[cursor..cursor + 4].try_into().unwrap()) as usize;
                        cursor += 4;
                        for _ in 0..count {
                            if cursor + 4 > data.len() {
                                break;
                            }
                            let c_len = u32::from_le_bytes(data[cursor..cursor + 4].try_into().unwrap()) as usize;
                            cursor += 4;
                            if cursor + c_len > data.len() {
                                break;
                            }
                            let comment_str = String::from_utf8_lossy(&data[cursor..cursor + c_len]);
                            cursor += c_len;

                            if let Some((raw_k, raw_v)) = comment_str.split_once('=') {
                                let norm_k = normalize_custom_tag_key(raw_k);
                                let val = raw_v.trim().to_string();
                                if val.is_empty() {
                                    continue;
                                }
                                match norm_k.as_str() {
                                    "TITLE" if raw_title.is_none() => raw_title = Some(val),
                                    "ARTIST" if raw_artist.is_none() => raw_artist = Some(val),
                                    "ALBUM" if raw_album.is_none() => raw_album = Some(val),
                                    "ALBUMARTIST" if raw_album_artist.is_none() => {
                                        raw_album_artist = Some(val)
                                    }
                                    "TRACKNUMBER" | "TRACK" if raw_track_number.is_none() => {
                                        let (t, d) = parse_track_and_disc_number(&val);
                                        raw_track_number = t;
                                        if raw_disc_number.is_none() {
                                            raw_disc_number = d;
                                        }
                                    }
                                    "DISCNUMBER" | "DISC" if raw_disc_number.is_none() => {
                                        raw_disc_number = parse_slash_number(&val);
                                    }
                                    "DATE" | "YEAR" if raw_year.is_none() => {
                                        raw_year = parse_year(&val);
                                    }
                                    "GENRE" if raw_genre.is_none() => raw_genre = Some(val),
                                    "COMPOSER" if raw_composer.is_none() => raw_composer = Some(val),
                                    "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS" if raw_lyrics.is_none() => {
                                        raw_lyrics = Some(val);
                                    }
                                    "ISRC" if raw_isrc.is_none() => {
                                        raw_isrc = normalize_isrc(&val);
                                    }
                                    "UPC" | "BARCODE" | "EAN" if raw_upc.is_none() => {
                                        raw_upc = normalize_upc(&val);
                                    }
                                    "MUSICBRAINZRELEASEGROUPID" if raw_mb_rg_id.is_none() => {
                                        raw_mb_rg_id = Some(val);
                                    }
                                    "EDITION" | "VERSION" | "RELEASETYPE" if raw_edition.is_none() => {
                                        raw_edition = Some(val);
                                    }
                                    "REPLAYGAINTRACKGAIN" if raw_rg_track_db.is_none() => {
                                        raw_rg_track_db = parse_replay_gain_db_str(&val);
                                    }
                                    "REPLAYGAINALBUMGAIN" if raw_rg_album_db.is_none() => {
                                        raw_rg_album_db = parse_replay_gain_db_str(&val);
                                    }
                                    "REPLAYGAINTRACKPEAK" if raw_rg_track_peak.is_none() => {
                                        raw_rg_track_peak = parse_replay_gain_peak_str(&val);
                                    }
                                    "REPLAYGAINALBUMPEAK" if raw_rg_album_peak.is_none() => {
                                        raw_rg_album_peak = parse_replay_gain_peak_str(&val);
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                }
            }
            6 => {
                let mut data = vec![0u8; block_len];
                if reader.read_exact(&mut data).is_ok() && data.len() >= 32 {
                    let pic_type_val = u32::from_be_bytes(data[0..4].try_into().unwrap());
                    let pic_type = match pic_type_val {
                        3 => core_types::PictureType::FrontCover,
                        4 => core_types::PictureType::BackCover,
                        _ => core_types::PictureType::Other,
                    };
                    let mime_len = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
                    let mut cur = 8;
                    if cur + mime_len <= data.len() {
                        let mime_str = String::from_utf8_lossy(&data[cur..cur + mime_len]).to_string();
                        cur += mime_len;
                        if cur + 4 <= data.len() {
                            let desc_len = u32::from_be_bytes(data[cur..cur + 4].try_into().unwrap()) as usize;
                            cur += 4 + desc_len;
                            if cur + 20 <= data.len() {
                                cur += 16;
                                let data_len = u32::from_be_bytes(data[cur..cur + 4].try_into().unwrap()) as usize;
                                cur += 4;
                                if cur + data_len <= data.len() {
                                    extracted_pictures.push(core_types::ExtractedPicture {
                                        picture_type: pic_type,
                                        mime_type: if mime_str.is_empty() { "image/jpeg".to_string() } else { mime_str },
                                        data: data[cur..cur + data_len].to_vec(),
                                    });
                                }
                            }
                        }
                    }
                }
            }
            _ => {
                let _ = reader.seek(SeekFrom::Current(block_len as i64));
            }
        }

        if is_last {
            break;
        }
    }

    if let Some(id3) = id3_fallback {
        if raw_title.is_none() { raw_title = id3.title; }
        if raw_artist.is_none() { raw_artist = id3.artist; }
        if raw_album.is_none() { raw_album = id3.album; }
        if raw_album_artist.is_none() { raw_album_artist = id3.album_artist; }
        if raw_track_number.is_none() { raw_track_number = id3.track_number; }
        if raw_disc_number.is_none() { raw_disc_number = id3.disc_number; }
        if raw_year.is_none() { raw_year = id3.release_year; }
        if raw_isrc.is_none() { raw_isrc = id3.isrc; }
        if extracted_pictures.is_empty() { extracted_pictures = id3.pictures; }
    }

    let format = AudioFormat::pcm(
        AudioCodec::Flac,
        sample_rate.max(8000),
        bit_depth.clamp(8, 32),
        channels.clamp(1, 8),
    )?;

    let (title_fallback, track_num_fallback) = derive_title_and_track_from_filename(fallback_path);
    let (album_fallback, artist_fallback) = derive_album_and_artist_from_dir(fallback_path);

    let title = raw_title.filter(|s| !s.trim().is_empty()).unwrap_or(title_fallback);
    let title = if title.trim().is_empty() { "Unknown Title".to_string() } else { title };

    let artist = raw_artist.filter(|s| !s.trim().is_empty()).unwrap_or(artist_fallback);
    let artist = if artist.trim().is_empty() { "Unknown Artist".to_string() } else { artist };

    let album = raw_album.filter(|s| !s.trim().is_empty()).unwrap_or(album_fallback);
    let album = if album.trim().is_empty() { "Unknown Album".to_string() } else { album };

    let album_artist = raw_album_artist.filter(|s| !s.trim().is_empty());
    let track_number = raw_track_number.unwrap_or(track_num_fallback).max(1);
    let disc_number = raw_disc_number.unwrap_or(1).max(1);

    Ok(ExtractedMetadata {
        title,
        artist,
        album,
        album_artist,
        track_number,
        disc_number,
        release_year: raw_year,
        isrc: raw_isrc,
        duration_ms: duration_ms.max(1),
        format,
        cover_url: None,
        replay_gain_track_db: raw_rg_track_db,
        replay_gain_album_db: raw_rg_album_db,
        replay_gain_track_peak: raw_rg_track_peak,
        replay_gain_album_peak: raw_rg_album_peak,
        upc: raw_upc,
        musicbrainz_release_group_id: raw_mb_rg_id,
        edition_label: raw_edition,
        genre: raw_genre,
        composer: raw_composer,
        embedded_lyrics: raw_lyrics,
        pictures: extracted_pictures,
    })
}
