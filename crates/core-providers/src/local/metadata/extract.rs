use std::fs::File;
use std::io::Cursor;
use std::path::Path;

use core_types::{AudioCodec, AudioFormat};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use super::accumulator::{
    TagAccumulator, build_dff_extracted, build_dsf_extracted, build_wav_extracted,
};
use super::flac::extract_flac_from_reader;
use super::helpers::{append_split_artists, split_artists};
use super::ogg::extract_ogg_from_reader;
use super::preparse::{
    PreParsedTags, map_extension_to_codec, scan_preparsed_tags_from_file,
    scan_preparsed_tags_from_slice,
};
use super::{ExtractOptions, ExtractedMetadata, FlacRawMetadata};
use crate::error::ProviderError;
use crate::local::dsd_meta::{
    parse_dff_reader_ext, parse_dff_with_extract_options, parse_dsf_reader_ext,
    parse_dsf_with_extract_options,
};
use crate::local::riff_meta::{parse_wav_reader_ext, parse_wav_with_extract_options};

/// Unified authoritative audio metadata parser for all supported formats.
///
/// Enforces strict format-specific tag precedence:
/// - **FLAC / OGG / OPUS**: Vorbis Comments / OpusTags ONLY (ignores residual prepended ID3v2 / trailing APEv2 whenever Vorbis Comments are present).
/// - **MP3 / AAC**: `ID3v2.4/2.3/2.2 > APEv2 > ID3v1 > Symphonia` (never overwrites non-empty higher-priority fields).
/// - **WAV / AIFF / DSF / DFF**: Embedded ID3v2 chunk > RIFF `LIST INFO` / AIFF `FORM` / DSDIFF `DIIN` (never promotes `bext` Description/Originator).
/// - **M4A / MP4 / ALAC**: Native MP4 `ilst` (`moov -> [udta ->] meta -> ilst`) > Symphonia container metadata.
pub fn parse_audio_metadata(
    path: &Path,
    options: ExtractOptions,
) -> Result<ExtractedMetadata, ProviderError> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    let mut meta = match ext.as_str() {
        "wav" | "wave" => {
            let wav = parse_wav_with_extract_options(path, options.include_pictures)?;
            build_wav_extracted(wav, path)
        }
        "dsf" => {
            let dsd = parse_dsf_with_extract_options(path, options.include_pictures)?;
            build_dsf_extracted(dsd, path)
        }
        "dff" => {
            let dsd = parse_dff_with_extract_options(path, options.include_pictures)?;
            build_dff_extracted(dsd, path)
        }
        "flac" => {
            if let Ok((meta, _)) =
                MetadataExtractor::extract_flac_with_options(path, options, false)
            {
                meta
            } else {
                MetadataExtractor::extract_symphonia_with_options(path, &ext, options)?
            }
        }
        "ogg" | "opus" => {
            let file = File::open(path)?;
            if let Ok(meta) = extract_ogg_from_reader(file, path, options) {
                meta
            } else {
                MetadataExtractor::extract_symphonia_with_options(path, &ext, options)?
            }
        }
        _ => MetadataExtractor::extract_symphonia_with_options(path, &ext, options)?,
    };

    if !options.include_pictures {
        meta.pictures.clear();
    }
    if meta.artists.is_empty() && !meta.artist.trim().is_empty() {
        meta.artists = split_artists(&meta.artist);
    }
    Ok(meta)
}

pub struct MetadataExtractor;

impl MetadataExtractor {
    pub fn extract(path: &Path) -> Result<ExtractedMetadata, ProviderError> {
        parse_audio_metadata(path, ExtractOptions::default())
    }

    pub fn extract_with_options(
        path: &Path,
        opts: ExtractOptions,
    ) -> Result<ExtractedMetadata, ProviderError> {
        parse_audio_metadata(path, opts)
    }

    pub fn extract_from_bytes(
        bytes: Vec<u8>,
        ext: &str,
        virtual_path: Option<&Path>,
    ) -> Result<ExtractedMetadata, ProviderError> {
        let ext_lower = ext.trim().trim_start_matches('.').to_ascii_lowercase();
        let fallback_path = virtual_path.unwrap_or_else(|| Path::new("Unknown Title"));
        let opts = ExtractOptions::default();

        match ext_lower.as_str() {
            "wav" | "wave" => {
                let mut cursor = Cursor::new(bytes);
                let wav = parse_wav_reader_ext(&mut cursor, false, opts.include_pictures)?;
                Ok(build_wav_extracted(wav, fallback_path))
            }
            "dsf" => {
                let mut cursor = Cursor::new(bytes);
                let dsd = parse_dsf_reader_ext(&mut cursor, false, opts.include_pictures)?;
                Ok(build_dsf_extracted(dsd, fallback_path))
            }
            "dff" => {
                let mut cursor = Cursor::new(bytes);
                let dsd = parse_dff_reader_ext(&mut cursor, false, opts.include_pictures)?;
                Ok(build_dff_extracted(dsd, fallback_path))
            }
            "flac" => {
                let cursor = Cursor::new(bytes.clone());
                if let Ok((meta, _)) = extract_flac_from_reader(cursor, fallback_path, opts, false)
                {
                    Ok(meta)
                } else {
                    let pre = scan_preparsed_tags_from_slice(
                        &bytes,
                        &ext_lower,
                        false,
                        opts.include_pictures,
                    );
                    let cursor = Cursor::new(bytes);
                    Self::extract_symphonia_from_source(
                        Box::new(cursor),
                        &ext_lower,
                        fallback_path,
                        pre,
                        opts,
                    )
                }
            }
            "ogg" | "opus" => {
                let cursor = Cursor::new(bytes.clone());
                if let Ok(meta) = extract_ogg_from_reader(cursor, fallback_path, opts) {
                    Ok(meta)
                } else {
                    let pre = scan_preparsed_tags_from_slice(
                        &bytes,
                        &ext_lower,
                        false,
                        opts.include_pictures,
                    );
                    let cursor = Cursor::new(bytes);
                    Self::extract_symphonia_from_source(
                        Box::new(cursor),
                        &ext_lower,
                        fallback_path,
                        pre,
                        opts,
                    )
                }
            }
            _ => {
                let pre = scan_preparsed_tags_from_slice(
                    &bytes,
                    &ext_lower,
                    false,
                    opts.include_pictures,
                );
                let cursor = Cursor::new(bytes);
                Self::extract_symphonia_from_source(
                    Box::new(cursor),
                    &ext_lower,
                    fallback_path,
                    pre,
                    opts,
                )
            }
        }
    }

    fn extract_flac_with_options(
        path: &Path,
        opts: ExtractOptions,
        collect_raw: bool,
    ) -> Result<(ExtractedMetadata, FlacRawMetadata), ProviderError> {
        let file = File::open(path)?;
        extract_flac_from_reader(file, path, opts, collect_raw)
    }

    pub(crate) fn extract_flac_raw(
        path: &Path,
    ) -> Result<(ExtractedMetadata, FlacRawMetadata), ProviderError> {
        Self::extract_flac_with_options(
            path,
            ExtractOptions {
                include_pictures: false,
            },
            true,
        )
    }

    fn extract_symphonia_with_options(
        path: &Path,
        ext: &str,
        opts: ExtractOptions,
    ) -> Result<ExtractedMetadata, ProviderError> {
        let pre = scan_preparsed_tags_from_file(path, ext, false, opts.include_pictures);
        let file = File::open(path)?;
        Self::extract_symphonia_from_source(Box::new(file), ext, path, pre, opts)
    }

    fn extract_symphonia_from_source(
        source: Box<dyn MediaSource>,
        ext: &str,
        fallback_path: &Path,
        pre: PreParsedTags,
        opts: ExtractOptions,
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
        } else if sym_codec == symphonia::core::codecs::CODEC_TYPE_FLAC {
            AudioCodec::Flac
        } else if sym_codec == symphonia::core::codecs::CODEC_TYPE_MP3 {
            AudioCodec::Mp3
        } else {
            map_extension_to_codec(ext)
        };

        let format = if codec.is_dsd() {
            AudioFormat::dsd(codec, sample_rate, channels)?
        } else {
            AudioFormat::pcm(
                codec,
                sample_rate,
                bit_depth.clamp(8, 32),
                channels.clamp(1, 8),
            )?
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

        let mut acc = TagAccumulator::default();

        if matches!(ext, "mp3" | "aac") {
            // Strict MP3/AAC precedence: ID3v2 > APEv2 > ID3v1 > Symphonia last-resort
            if let Some(id3) = pre.id3v2 {
                acc.apply_id3v2(id3, opts.include_pictures);
            }
            if let Some(ape) = pre.ape {
                acc.apply_ape(ape, opts.include_pictures);
            }
            if let Some(v1) = pre.id3v1 {
                acc.apply_id3v1(v1);
            }
            if let Some(meta) = probed.format.metadata().current() {
                acc.apply_symphonia_revision(meta, opts.include_pictures);
            }
            if let Some(reader) = probed.metadata.get() {
                if let Some(meta) = reader.current() {
                    acc.apply_symphonia_revision(meta, opts.include_pictures);
                }
            }
        } else if matches!(ext, "aiff" | "aif") {
            // Strict AIFF precedence: FORM ID3 chunk > FORM NAME/AUTH > Symphonia
            if let Some(aiff) = pre.aiff {
                if let Some(id3) = aiff.id3 {
                    acc.apply_id3v2(id3, opts.include_pictures);
                }
                if acc.title.is_none() {
                    acc.title = aiff.form_title;
                }
                if acc.artist.is_none() {
                    if let Some(art) = aiff.form_artist {
                        append_split_artists(&mut acc.artists, &art);
                        acc.artist = Some(art);
                    }
                }
            }
            if let Some(meta) = probed.format.metadata().current() {
                acc.apply_symphonia_revision(meta, opts.include_pictures);
            }
            if let Some(reader) = probed.metadata.get() {
                if let Some(meta) = reader.current() {
                    acc.apply_symphonia_revision(meta, opts.include_pictures);
                }
            }
        } else if matches!(ext, "m4a" | "mp4" | "alac") {
            // Strict MP4/M4A precedence: Native ilst FIRST (fixes encoding, 6-byte trkn/disk, multi-value & aART) > Symphonia
            if let Some(mp4) = pre.mp4_ilst {
                acc.apply_mp4_ilst(mp4, opts.include_pictures);
            }
            if let Some(meta) = probed.format.metadata().current() {
                acc.apply_symphonia_revision(meta, opts.include_pictures);
            }
        } else {
            // FLAC / OGG / OPUS / other container metadata FIRST; ignore residual ID3/APE when container tags exist.
            let mut has_container_tags = false;
            if let Some(meta) = probed.format.metadata().current() {
                has_container_tags = !meta.tags().is_empty();
                acc.apply_symphonia_revision(meta, opts.include_pictures);
            }
            let is_vorbis_container = matches!(ext, "flac" | "ogg" | "opus");
            if !(is_vorbis_container && has_container_tags) {
                if let Some(reader) = probed.metadata.get() {
                    if let Some(meta) = reader.current() {
                        acc.apply_symphonia_revision(meta, opts.include_pictures);
                    }
                }
                if let Some(id3) = pre.id3v2 {
                    acc.apply_id3v2(id3, opts.include_pictures);
                }
                if let Some(ape) = pre.ape {
                    acc.apply_ape(ape, opts.include_pictures);
                }
            }
        }

        Ok(acc.finalize(fallback_path, format, duration_ms))
    }
}
