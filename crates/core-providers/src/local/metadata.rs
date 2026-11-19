use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::path::Path;

use core_types::{AudioCodec, AudioFormat};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, StandardTagKey, Value};
use symphonia::core::probe::Hint;

use super::dsd_meta::{
    parse_dff, parse_dff_reader, parse_dsf, parse_dsf_reader, parse_id3v2_from_reader,
    parse_id3v2_from_slice, parse_replay_gain_db_str, parse_replay_gain_peak_str,
    parse_slash_number, parse_year, Id3v2ParsedTags,
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
                            if let Some(num) = parse_slash_number(&tag_str) {
                                raw_track_number = Some(num);
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
                        "ALBUMARTIST" | "ALBUM_ARTIST" if raw_album_artist.is_none() => {
                            raw_album_artist = Some(tag_str)
                        }
                        "TRACKNUMBER" | "TRACK" if raw_track_number.is_none() => {
                            raw_track_number = parse_slash_number(&tag_str);
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
                        "REPLAYGAIN_TRACK_GAIN" if raw_rg_track_db.is_none() => {
                            raw_rg_track_db = parse_replay_gain_db_value(&tag.value);
                        }
                        "REPLAYGAIN_ALBUM_GAIN" if raw_rg_album_db.is_none() => {
                            raw_rg_album_db = parse_replay_gain_db_value(&tag.value);
                        }
                        "REPLAYGAIN_TRACK_PEAK" if raw_rg_track_peak.is_none() => {
                            raw_rg_track_peak = parse_replay_gain_peak_value(&tag.value);
                        }
                        "REPLAYGAIN_ALBUM_PEAK" if raw_rg_album_peak.is_none() => {
                            raw_rg_album_peak = parse_replay_gain_peak_value(&tag.value);
                        }
                        "UPC" | "BARCODE" | "EAN" if raw_upc.is_none() => {
                            raw_upc = normalize_upc(&tag_str);
                        }
                        "MUSICBRAINZ_RELEASEGROUPID" | "MUSICBRAINZ RELEASE GROUP ID"
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
    tail.to_ascii_uppercase()
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

pub fn derive_album_and_artist_from_dir(path: &Path) -> (String, String) {
    let parent = path.parent();
    let raw_album = parent
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("Unknown Album");
    let album_name = if raw_album.trim().is_empty() {
        "Unknown Album".to_string()
    } else {
        raw_album.to_string()
    };

    let raw_artist = parent
        .and_then(|p| p.parent())
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("Unknown Artist");
    let artist_name = if raw_artist.trim().is_empty() {
        "Unknown Artist".to_string()
    } else {
        raw_artist.to_string()
    };

    (album_name, artist_name)
}
