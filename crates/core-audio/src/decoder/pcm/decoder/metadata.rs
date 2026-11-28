use std::path::Path;

use core_types::{AudioCodec, Endianness, SampleFormatKind, StreamSourceSpec};
use symphonia::core::codecs::CodecType;
use symphonia::core::meta::{MetadataRevision, StandardTagKey};
use symphonia::core::probe::Hint;

use super::super::DecodedTrackMetadata;
use crate::streaming::BlockingStreamBridge;

pub(super) fn collect_revision_metadata(rev: &MetadataRevision, out: &mut DecodedTrackMetadata) {
    for tag in rev.tags() {
        let val = tag.value.to_string();
        if let Some(std_key) = tag.std_key {
            match std_key {
                StandardTagKey::TrackTitle if out.title.is_none() => out.title = Some(val.clone()),
                StandardTagKey::Artist if out.artist.is_none() => out.artist = Some(val.clone()),
                StandardTagKey::AlbumArtist if out.artist.is_none() => {
                    out.artist = Some(val.clone())
                }
                StandardTagKey::Album if out.album.is_none() => out.album = Some(val.clone()),
                StandardTagKey::TrackNumber if out.track_number.is_none() => {
                    out.track_number = val.split('/').next().and_then(|n| n.trim().parse().ok());
                }
                StandardTagKey::ReplayGainTrackGain if out.replaygain_track_db.is_none() => {
                    out.replaygain_track_db = parse_gain_db(&val);
                }
                StandardTagKey::ReplayGainAlbumGain if out.replaygain_album_db.is_none() => {
                    out.replaygain_album_db = parse_gain_db(&val);
                }
                StandardTagKey::ReplayGainTrackPeak if out.replaygain_track_peak.is_none() => {
                    out.replaygain_track_peak = parse_peak(&val);
                }
                StandardTagKey::ReplayGainAlbumPeak if out.replaygain_album_peak.is_none() => {
                    out.replaygain_album_peak = parse_peak(&val);
                }
                _ => {}
            }
        }

        // Also match raw VorbisComment / ID3v2 TXXX / freeform tag keys (notably EBU R128
        // `R128_TRACK_GAIN` / `R128_ALBUM_GAIN`, which Symphonia 0.5 does not map to StandardTagKey).
        let key_upper = tag.key.trim().to_ascii_uppercase();
        match key_upper.as_str() {
            "REPLAYGAIN_TRACK_GAIN" if out.replaygain_track_db.is_none() => {
                out.replaygain_track_db = parse_gain_db(&val);
            }
            "REPLAYGAIN_ALBUM_GAIN" if out.replaygain_album_db.is_none() => {
                out.replaygain_album_db = parse_gain_db(&val);
            }
            "REPLAYGAIN_TRACK_PEAK" if out.replaygain_track_peak.is_none() => {
                out.replaygain_track_peak = parse_peak(&val);
            }
            "REPLAYGAIN_ALBUM_PEAK" if out.replaygain_album_peak.is_none() => {
                out.replaygain_album_peak = parse_peak(&val);
            }
            "R128_TRACK_GAIN" if out.r128_track_gain.is_none() => {
                out.r128_track_gain = parse_r128_q78(&val);
            }
            "R128_ALBUM_GAIN" if out.r128_album_gain.is_none() => {
                out.r128_album_gain = parse_r128_q78(&val);
            }
            _ => {}
        }
    }
}

fn parse_gain_db(raw: &str) -> Option<f64> {
    raw.trim()
        .trim_end_matches("dB")
        .trim_end_matches("db")
        .trim_end_matches("DB")
        .trim()
        .parse::<f64>()
        .ok()
        .filter(|v| v.is_finite())
}

fn parse_peak(raw: &str) -> Option<f32> {
    raw.trim()
        .parse::<f32>()
        .ok()
        .filter(|v| v.is_finite() && *v > 0.0)
}

fn parse_r128_q78(raw: &str) -> Option<i16> {
    raw.trim().parse::<i16>().ok()
}

pub(super) fn classify_codec_and_sample_format(
    codec_type: CodecType,
    declared_bits: u8,
) -> (AudioCodec, SampleFormatKind, u8, u8, Endianness) {
    use symphonia::core::codecs::*;
    match codec_type {
        CODEC_TYPE_FLAC => {
            let vb = declared_bits.clamp(8, 32);
            let sf = if vb <= 16 {
                SampleFormatKind::Int16
            } else if vb <= 24 {
                SampleFormatKind::Int24In32
            } else {
                SampleFormatKind::Int32
            };
            (
                AudioCodec::Flac,
                sf,
                sf.container_bits(),
                vb,
                Endianness::Little,
            )
        }
        CODEC_TYPE_ALAC => {
            let vb = declared_bits.clamp(16, 32);
            let sf = if vb <= 16 {
                SampleFormatKind::Int16
            } else if vb <= 24 {
                SampleFormatKind::Int24In32
            } else {
                SampleFormatKind::Int32
            };
            (
                AudioCodec::Alac,
                sf,
                sf.container_bits(),
                vb,
                Endianness::Big,
            )
        }
        CODEC_TYPE_PCM_S16LE | CODEC_TYPE_PCM_U16LE | CODEC_TYPE_PCM_S8 | CODEC_TYPE_PCM_U8 => (
            AudioCodec::Wav,
            SampleFormatKind::Int16,
            16,
            16,
            Endianness::Little,
        ),
        CODEC_TYPE_PCM_S24LE | CODEC_TYPE_PCM_U24LE => (
            AudioCodec::Wav,
            SampleFormatKind::Int24In32,
            32,
            24,
            Endianness::Little,
        ),
        CODEC_TYPE_PCM_S32LE | CODEC_TYPE_PCM_U32LE => (
            AudioCodec::Wav,
            SampleFormatKind::Int32,
            32,
            32,
            Endianness::Little,
        ),
        CODEC_TYPE_PCM_F32LE => (
            AudioCodec::Wav,
            SampleFormatKind::Float32,
            32,
            32,
            Endianness::Little,
        ),
        CODEC_TYPE_PCM_F64LE => (
            AudioCodec::Wav,
            SampleFormatKind::Float64,
            64,
            64,
            Endianness::Little,
        ),
        CODEC_TYPE_PCM_S16BE | CODEC_TYPE_PCM_U16BE => (
            AudioCodec::Aiff,
            SampleFormatKind::Int16,
            16,
            16,
            Endianness::Big,
        ),
        CODEC_TYPE_PCM_S24BE | CODEC_TYPE_PCM_U24BE => (
            AudioCodec::Aiff,
            SampleFormatKind::Int24In32,
            32,
            24,
            Endianness::Big,
        ),
        CODEC_TYPE_PCM_S32BE | CODEC_TYPE_PCM_U32BE => (
            AudioCodec::Aiff,
            SampleFormatKind::Int32,
            32,
            32,
            Endianness::Big,
        ),
        CODEC_TYPE_PCM_F32BE => (
            AudioCodec::Aiff,
            SampleFormatKind::Float32,
            32,
            32,
            Endianness::Big,
        ),
        CODEC_TYPE_MP3 => (
            AudioCodec::Mp3,
            SampleFormatKind::Float32,
            32,
            32,
            Endianness::Little,
        ),
        CODEC_TYPE_AAC => (
            AudioCodec::Aac,
            SampleFormatKind::Float32,
            32,
            32,
            Endianness::Little,
        ),
        CODEC_TYPE_VORBIS => (
            // Note: core_types::AudioCodec does not have a Vorbis variant;
            // AudioCodec::Opus preserves lossy classification (matching core-providers)
            // while Float32 matches VorbisDecoder's AudioBufferRef::F32 output.
            AudioCodec::Opus,
            SampleFormatKind::Float32,
            32,
            32,
            Endianness::Little,
        ),
        CODEC_TYPE_OPUS => (
            AudioCodec::Opus,
            SampleFormatKind::Float32,
            32,
            32,
            Endianness::Little,
        ),
        _ => (
            AudioCodec::Flac,
            SampleFormatKind::Int16,
            16,
            16,
            Endianness::Little,
        ),
    }
}

/// Maps a MIME type (with optional `; codecs=...` parameters) to a canonical Symphonia file
/// extension hint (`m4a`, `webm`, `mkv`, `mp3`, `ogg`, `flac`, `aac`, `wav`, `aiff`, `caf`).
pub fn extension_from_mime_type(mime: &str) -> Option<&'static str> {
    let base = crate::streaming::normalize_mime_base(mime);
    match base.as_str() {
        "audio/mp4" | "audio/x-m4a" | "audio/m4a" | "video/mp4" | "audio/mp4a-latm"
        | "audio/alac" => Some("m4a"),
        "audio/webm" | "video/webm" => Some("webm"),
        "audio/x-matroska" | "video/x-matroska" | "audio/matroska" => Some("mkv"),
        "audio/mpeg" | "audio/mp3" | "audio/x-mpeg" | "audio/mpeg3" | "audio/x-mpeg-3" => {
            Some("mp3")
        }
        "audio/ogg" | "audio/opus" | "audio/vorbis" | "application/ogg" | "audio/x-ogg" => {
            Some("ogg")
        }
        "audio/flac" | "audio/x-flac" => Some("flac"),
        "audio/aac" | "audio/aacp" | "audio/x-aac" => Some("aac"),
        "audio/wav" | "audio/x-wav" | "audio/wave" | "audio/vnd.wave" => Some("wav"),
        "audio/aiff" | "audio/x-aiff" => Some("aiff"),
        "audio/caf" | "audio/x-caf" => Some("caf"),
        _ => None,
    }
}

pub(super) fn normalize_probe_hints(
    hint_extension: Option<&str>,
    hint_mime: Option<&str>,
) -> (Option<String>, Option<String>) {
    let norm_mime = hint_mime
        .map(crate::streaming::normalize_mime_base)
        .filter(|s| !s.is_empty());
    let norm_ext = hint_extension
        .map(|s| s.trim().trim_start_matches('.').to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            norm_mime
                .as_deref()
                .and_then(extension_from_mime_type)
                .map(str::to_string)
        });
    (norm_ext, norm_mime)
}

/// Builds a Symphonia [`Hint`] populated with both normalized base `mime_type(...)` and
/// `with_extension(...)` (deriving the extension from `mime_type` when `hint_extension` is absent).
pub fn build_probe_hint(hint_extension: Option<&str>, hint_mime: Option<&str>) -> Hint {
    let (norm_ext, norm_mime) = normalize_probe_hints(hint_extension, hint_mime);
    let mut hint = Hint::new();
    if let Some(ext) = norm_ext.as_deref() {
        hint.with_extension(ext);
    }
    if let Some(mime) = norm_mime.as_deref() {
        hint.mime_type(mime);
    }
    hint
}

pub(super) fn bridge_probe_hints(
    bridge: &BlockingStreamBridge,
    spec: &StreamSourceSpec,
) -> (Option<String>, Option<String>, bool) {
    match spec {
        StreamSourceSpec::DirectRange {
            hint_extension,
            mime_type,
            ..
        }
        | StreamSourceSpec::EncryptedRange {
            hint_extension,
            mime_type,
            ..
        } => {
            let raw_ext = hint_extension
                .as_deref()
                .or_else(|| bridge.hint_extension());
            let raw_mime = mime_type.as_deref().or_else(|| bridge.mime_type());
            let (ext, mime) = normalize_probe_hints(raw_ext, raw_mime);
            (ext, mime, false)
        }
        StreamSourceSpec::SegmentedManifest { mime_type, .. } => {
            let raw_ext = bridge.hint_extension();
            let raw_mime = bridge
                .mime_type()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .or_else(|| {
                    mime_type.as_deref().map(str::trim).filter(|m| {
                        !m.is_empty()
                            && !m.eq_ignore_ascii_case("application/dash+xml")
                            && !m.to_ascii_lowercase().contains("mpegurl")
                    })
                });
            let (ext, mime) = normalize_probe_hints(raw_ext, raw_mime);
            (ext, mime, true)
        }
        StreamSourceSpec::LocalFile { path, .. } => {
            let raw_ext = Path::new(path)
                .extension()
                .and_then(|e| e.to_str())
                .or_else(|| bridge.hint_extension());
            let raw_mime = bridge.mime_type();
            let (ext, mime) = normalize_probe_hints(raw_ext, raw_mime);
            (ext, mime, false)
        }
        StreamSourceSpec::ExternalBackend { .. } => (None, None, false),
    }
}

pub(super) fn build_hint(hint_extension: Option<&str>, hint_mime: Option<&str>) -> Hint {
    build_probe_hint(hint_extension, hint_mime)
}
