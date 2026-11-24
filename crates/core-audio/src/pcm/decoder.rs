use std::fs::File;
use std::io::{Cursor, IoSliceMut, Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use core_types::{
    AudioCodec, AudioFormat, ChannelLayout, Endianness, Interleaving, SampleFormatKind,
    StreamSourceSpec, UnifiedAudioFormat,
};
use symphonia::core::audio::{AudioBuffer, AudioBufferRef, Signal};
use symphonia::core::codecs::{CodecRegistry, CodecType, Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, MetadataRevision, StandardTagKey};
use symphonia::core::probe::Hint;

use super::{AudioChunk, AudioDecoder, DecodedTrackMetadata};
use crate::error::DecoderError;
use crate::streaming::{BlockingStreamBridge, StreamError};

/// Minimum `MediaSourceStreamOptions::buffer_len` permitted by Symphonia 0.5.5
/// (`MediaSourceStream::new` asserts `buffer_len.is_power_of_two() && buffer_len > 32 * 1024`).
const LOW_LATENCY_MSS_BUFFER_LEN: usize = 64 * 1024;

fn codec_registry() -> &'static CodecRegistry {
    static REGISTRY: OnceLock<CodecRegistry> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        let mut registry = CodecRegistry::new();
        symphonia::default::register_enabled_codecs(&mut registry);
        crate::pcm::opus::register_opus_codec(&mut registry);
        registry
    })
}

struct SharedBridgeMediaSource(Arc<Mutex<BlockingStreamBridge>>);

impl Read for SharedBridgeMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let mut guard = self
            .0
            .lock()
            .map_err(|_| std::io::Error::other("BlockingStreamBridge lock poisoned"))?;
        guard.read(buf)
    }
}

impl Seek for SharedBridgeMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let mut guard = self
            .0
            .lock()
            .map_err(|_| std::io::Error::other("BlockingStreamBridge lock poisoned"))?;
        guard.seek(pos)
    }
}

impl MediaSource for SharedBridgeMediaSource {
    fn is_seekable(&self) -> bool {
        self.0
            .lock()
            .map(|guard| guard.is_seekable())
            .unwrap_or(false)
    }

    fn byte_len(&self) -> Option<u64> {
        self.0.lock().ok().and_then(|guard| guard.byte_len())
    }
}

struct GenericSource<R> {
    inner: R,
    byte_len: Option<u64>,
}

impl<R: Read + Seek> GenericSource<R> {
    fn new(mut inner: R) -> Self {
        let byte_len = inner.stream_position().ok().and_then(|pos| {
            let end = inner.seek(SeekFrom::End(0)).ok();
            let _ = inner.seek(SeekFrom::Start(pos));
            end
        });
        Self { inner, byte_len }
    }
}

impl<R: Read> Read for GenericSource<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl<R: Seek> Seek for GenericSource<R> {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        self.inner.seek(pos)
    }
}

impl<R: Read + Seek + Send + Sync + 'static> MediaSource for GenericSource<R> {
    fn is_seekable(&self) -> bool {
        true
    }
    fn byte_len(&self) -> Option<u64> {
        self.byte_len
    }
}

/// Preserves underlying non-EOF I/O errors (such as `HTTP 403`) across Symphonia's
/// `Probe::next` / `MediaSourceStream` loops that otherwise downgrade `Err` into
/// `UnexpectedEof` or `no suitable format reader found`.
struct ErrorTrackingMediaSource {
    inner: Box<dyn MediaSource>,
    last_io_error: Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
}

impl ErrorTrackingMediaSource {
    fn record_error(&self, err: &std::io::Error) {
        if err.kind() == std::io::ErrorKind::UnexpectedEof {
            return;
        }
        if let Ok(mut guard) = self.last_io_error.lock()
            && guard.is_none()
        {
            *guard = Some((err.kind(), err.to_string()));
        }
    }
}

impl Read for ErrorTrackingMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let res = self.inner.read(buf);
        if let Err(ref e) = res {
            self.record_error(e);
        }
        res
    }

    fn read_vectored(&mut self, bufs: &mut [IoSliceMut<'_>]) -> std::io::Result<usize> {
        let res = self.inner.read_vectored(bufs);
        if let Err(ref e) = res {
            self.record_error(e);
        }
        res
    }
}

impl Seek for ErrorTrackingMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let res = self.inner.seek(pos);
        if let Err(ref e) = res {
            self.record_error(e);
        }
        res
    }
}

impl MediaSource for ErrorTrackingMediaSource {
    fn is_seekable(&self) -> bool {
        self.inner.is_seekable()
    }

    fn byte_len(&self) -> Option<u64> {
        self.inner.byte_len()
    }
}

fn clear_tracked_io_error(slot: &Arc<Mutex<Option<(std::io::ErrorKind, String)>>>) {
    if let Ok(mut guard) = slot.lock() {
        *guard = None;
    }
}

fn take_tracked_io_error(
    slot: &Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
) -> Option<(std::io::ErrorKind, String)> {
    slot.lock().ok().and_then(|mut g| g.take())
}

fn format_with_tracked_io_error(
    base: impl std::fmt::Display,
    slot: &Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
) -> String {
    let base_str = base.to_string();
    match take_tracked_io_error(slot) {
        Some((_, io_err)) if !base_str.contains(&io_err) => format!("{io_err} ({base_str})"),
        _ => base_str,
    }
}

fn map_typed_stream_error(err: StreamError) -> Option<DecoderError> {
    match err {
        StreamError::AuthRequired {
            provider_id,
            status,
        } => Some(DecoderError::StreamAuthRequired {
            provider_id,
            status,
        }),
        StreamError::FormatChanged(spec) => Some(DecoderError::StreamFormatChanged(spec)),
        _ => None,
    }
}

fn take_typed_bridge_error(
    bridge: Option<&Arc<Mutex<BlockingStreamBridge>>>,
) -> Option<DecoderError> {
    bridge
        .and_then(|b| b.lock().ok())
        .and_then(|guard| guard.take_last_stream_error())
        .and_then(map_typed_stream_error)
}

/// Detailed result of a `SymphoniaDecoder` seek operation, including demuxer
/// snap position (`actual_ts`) vs requested target (`required_ts`) and the
/// number of pre-target PCM frames scheduled to be trimmed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SeekOutcome {
    pub requested_ms: u64,
    pub actual_ms: u64,
    pub required_ts: u64,
    pub actual_ts: u64,
    pub trimmed_frames: u64,
}

/// Symphonia 0.5.5 decoder wrapper with sample-accurate `SeekedTo` pre-target
/// frame trimming and clean EOF seek clamping.
///
/// ## Third-party Symphonia 0.5.5 limitations
/// - **MP3 Xing/VBRI TOC**: `symphonia-bundle-mp3` parses `Xing`/`Info`/`VBRI`
///   headers for frame counts and encoder delay/padding only, not for O(1) TOC
///   seeking. `SeekMode::Accurate` performs an `O(N)` linear MPEG frame-header
///   scan from the start of the audio stream on backward seeks (while decoding
///   up to `MAX_REF_FRAMES = 4` bit-reservoir reference frames when
///   `main_data_begin > 0`).
/// - **MP4/M4A edit lists (`edts`/`elst`)**: `symphonia-format-isomp4` does not
///   parse `edts`/`elst` encoder-delay boxes; timestamps follow `mdhd.timescale`
///   and `stts` directly.
/// - **FLAC `SEEKTABLE` `soft_reset` bug**: `symphonia-bundle-flac` skips
///   `PacketParser::soft_reset()` when `resync()` lands directly on a frame
///   boundary (`init_pos == reader.pos()`), leaving `last_header` stale across
///   backward seeks onto `SEEKTABLE` entries. `SymphoniaDecoder` guards against
///   this by refreshing the `FlacReader` from `into_inner()` at offset `0` on
///   backward FLAC seeks when the underlying source is seekable.
pub struct SymphoniaDecoder {
    reader: Option<Box<dyn FormatReader>>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    format: AudioFormat,
    unified_format: UnifiedAudioFormat,
    metadata: DecodedTrackMetadata,
    valid_bits: u8,
    sample_rate: u32,
    time_base: Option<symphonia::core::units::TimeBase>,
    duration: Option<Duration>,
    total_frames: Option<u64>,
    is_seekable: bool,
    hint_extension: Option<String>,
    hint_mime: Option<String>,
    mss_buffer_len: usize,
    bridge: Option<Arc<Mutex<BlockingStreamBridge>>>,
    is_segmented: bool,
    base_timestamp_ms: u64,
    last_packet_end_ts: u64,
    pending_seek_target_ts: Option<u64>,
    pending_seek_skip_frames: u64,
    at_eof: bool,
    last_seek_outcome: Option<SeekOutcome>,
    last_io_error: Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
}

fn interleave_planes<T: Copy + symphonia::core::sample::Sample, U, F: FnMut(T) -> U>(
    buf: &AudioBuffer<T>,
    mut convert: F,
) -> Vec<U> {
    let ch = buf.spec().channels.count();
    let frames = buf.frames();
    let mut out = Vec::with_capacity(frames * ch);
    for f in 0..frames {
        for c in 0..ch {
            out.push(convert(buf.chan(c)[f]));
        }
    }
    out
}

fn extract_interleaved_chunk(decoded: AudioBufferRef<'_>, declared_valid_bits: u8) -> AudioChunk {
    let spec = *decoded.spec();
    let ch = spec.channels.count().max(1) as u16;
    let rate = spec.rate;

    match decoded {
        AudioBufferRef::S16(buf) => AudioChunk::PcmI16 {
            samples: interleave_planes(buf.as_ref(), |s| s),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::U16(buf) => AudioChunk::PcmI16 {
            samples: interleave_planes(buf.as_ref(), |s| (s ^ 0x8000) as i16),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::S8(buf) => AudioChunk::PcmI16 {
            samples: interleave_planes(buf.as_ref(), |s| (s as i16) << 8),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::U8(buf) => AudioChunk::PcmI16 {
            samples: interleave_planes(buf.as_ref(), |s| ((s ^ 0x80) as i8 as i16) << 8),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::S24(buf) => AudioChunk::PcmI24In32 {
            samples: interleave_planes(buf.as_ref(), |s| s.inner()),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::U24(buf) => AudioChunk::PcmI24In32 {
            samples: interleave_planes(buf.as_ref(), |s| {
                let signed = (s.inner() as i32).wrapping_sub(0x0080_0000);
                (signed << 8) >> 8
            }),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::S32(buf) => {
            if declared_valid_bits <= 16 {
                AudioChunk::PcmI16 {
                    samples: interleave_planes(buf.as_ref(), |s| (s >> 16) as i16),
                    channels: ch,
                    sample_rate: rate,
                }
            } else if declared_valid_bits <= 24 {
                AudioChunk::PcmI24In32 {
                    samples: interleave_planes(buf.as_ref(), |s| s >> 8),
                    channels: ch,
                    sample_rate: rate,
                }
            } else {
                AudioChunk::PcmI32 {
                    samples: interleave_planes(buf.as_ref(), |s| s),
                    channels: ch,
                    sample_rate: rate,
                }
            }
        }
        AudioBufferRef::U32(buf) => AudioChunk::PcmI32 {
            samples: interleave_planes(buf.as_ref(), |s| (s ^ 0x8000_0000) as i32),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::F32(buf) => AudioChunk::PcmF32 {
            samples: interleave_planes(buf.as_ref(), |s| s),
            channels: ch,
            sample_rate: rate,
        },
        AudioBufferRef::F64(buf) => AudioChunk::PcmF64 {
            samples: interleave_planes(buf.as_ref(), |s| s),
            channels: ch,
            sample_rate: rate,
        },
    }
}

fn collect_revision_metadata(rev: &MetadataRevision, out: &mut DecodedTrackMetadata) {
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

fn classify_codec_and_sample_format(
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
            (AudioCodec::Flac, sf, sf.container_bits(), vb, Endianness::Little)
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
            (AudioCodec::Alac, sf, sf.container_bits(), vb, Endianness::Big)
        }
        CODEC_TYPE_PCM_S16LE | CODEC_TYPE_PCM_U16LE | CODEC_TYPE_PCM_S8 | CODEC_TYPE_PCM_U8 => {
            (AudioCodec::Wav, SampleFormatKind::Int16, 16, 16, Endianness::Little)
        }
        CODEC_TYPE_PCM_S24LE | CODEC_TYPE_PCM_U24LE => (
            AudioCodec::Wav,
            SampleFormatKind::Int24In32,
            32,
            24,
            Endianness::Little,
        ),
        CODEC_TYPE_PCM_S32LE | CODEC_TYPE_PCM_U32LE => {
            (AudioCodec::Wav, SampleFormatKind::Int32, 32, 32, Endianness::Little)
        }
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
        CODEC_TYPE_PCM_S16BE | CODEC_TYPE_PCM_U16BE => {
            (AudioCodec::Aiff, SampleFormatKind::Int16, 16, 16, Endianness::Big)
        }
        CODEC_TYPE_PCM_S24BE | CODEC_TYPE_PCM_U24BE => (
            AudioCodec::Aiff,
            SampleFormatKind::Int24In32,
            32,
            24,
            Endianness::Big,
        ),
        CODEC_TYPE_PCM_S32BE | CODEC_TYPE_PCM_U32BE => {
            (AudioCodec::Aiff, SampleFormatKind::Int32, 32, 32, Endianness::Big)
        }
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

fn ts_delta_to_frames(
    delta_ts: u64,
    time_base: Option<symphonia::core::units::TimeBase>,
    sample_rate: u32,
) -> u64 {
    if delta_ts == 0 {
        return 0;
    }
    match time_base {
        Some(tb) if tb.denom > 0 => {
            ((delta_ts as u128 * tb.numer as u128 * sample_rate.max(1) as u128)
                / tb.denom as u128) as u64
        }
        _ => delta_ts,
    }
}

fn ts_to_ms(
    ts: u64,
    time_base: Option<symphonia::core::units::TimeBase>,
    sample_rate: u32,
) -> u64 {
    let frames = ts_delta_to_frames(ts, time_base, sample_rate);
    ((frames as u128 * 1000) / (sample_rate.max(1) as u128)) as u64
}

fn ms_to_ts(
    ms: u64,
    time_base: Option<symphonia::core::units::TimeBase>,
    sample_rate: u32,
) -> u64 {
    if ms == 0 {
        return 0;
    }
    match time_base {
        Some(tb) if tb.denom > 0 && tb.numer > 0 => {
            ((ms as u128 * tb.denom as u128) / (1000u128 * tb.numer as u128)) as u64
        }
        _ => ((ms as u128 * sample_rate.max(1) as u128) / 1000u128) as u64,
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

fn normalize_probe_hints(
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

fn bridge_probe_hints(
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
            let raw_ext = hint_extension.as_deref().or_else(|| bridge.hint_extension());
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

fn build_hint(hint_extension: Option<&str>, hint_mime: Option<&str>) -> Hint {
    build_probe_hint(hint_extension, hint_mime)
}

fn trim_chunk_front(chunk: &mut AudioChunk, trim_frames: usize) {
    if trim_frames == 0 {
        return;
    }
    let ch = chunk.channels().max(1) as usize;
    let drop_samples = trim_frames.saturating_mul(ch);
    match chunk {
        AudioChunk::PcmI16 { samples, .. } => {
            let n = drop_samples.min(samples.len());
            samples.drain(..n);
        }
        AudioChunk::PcmI24In32 { samples, .. } | AudioChunk::PcmI32 { samples, .. } => {
            let n = drop_samples.min(samples.len());
            samples.drain(..n);
        }
        AudioChunk::PcmF32 { samples, .. } => {
            let n = drop_samples.min(samples.len());
            samples.drain(..n);
        }
        AudioChunk::PcmF64 { samples, .. } => {
            let n = drop_samples.min(samples.len());
            samples.drain(..n);
        }
        AudioChunk::DsdBitstream { .. } => {}
    }
}

impl SymphoniaDecoder {
    pub fn try_new<R>(
        source: R,
        hint_extension: Option<&str>,
        hint_mime: Option<&str>,
    ) -> Result<Self, DecoderError>
    where
        R: Read + Seek + Send + Sync + 'static,
    {
        Self::from_media_source(
            Box::new(GenericSource::new(source)),
            hint_extension,
            hint_mime,
        )
    }

    pub fn from_media_source(
        source: Box<dyn MediaSource>,
        hint_extension: Option<&str>,
        hint_mime: Option<&str>,
    ) -> Result<Self, DecoderError> {
        Self::open_internal(
            source,
            hint_extension,
            hint_mime,
            MediaSourceStreamOptions::default().buffer_len,
            None,
            false,
            None,
        )
    }

    /// Opens a decoder backed by a [`BlockingStreamBridge`] and [`StreamSourceSpec`], configuring
    /// exact format hints, low-latency buffering, `prebuild_seek_index: false`, and segmented DASH
    /// seek support.
    pub fn from_blocking_bridge(
        bridge: BlockingStreamBridge,
        spec: &StreamSourceSpec,
    ) -> Result<Self, DecoderError> {
        Self::from_blocking_bridge_with_duration(bridge, spec, None)
    }

    /// Opens a decoder backed by a [`BlockingStreamBridge`] with an optional manifest duration hint
    /// (used when fragmented MP4 `mdhd.duration` is `0`).
    pub fn from_blocking_bridge_with_duration(
        mut bridge: BlockingStreamBridge,
        spec: &StreamSourceSpec,
        manifest_duration_ms: Option<u64>,
    ) -> Result<Self, DecoderError> {
        if let StreamSourceSpec::ExternalBackend {
            key, provider_id, ..
        } = spec
        {
            return Err(DecoderError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter SymphoniaDecoder",
                key.track_id
            )));
        }

        let (mut hint_extension, hint_mime, is_segmented) = bridge_probe_hints(&bridge, spec);

        // Pre-read and validate the initial chunk at `offset = 0` BEFORE handing the stream to
        // Symphonia `probe()` (even when `content_length` is already known). This guarantees:
        // 1. `ChunkedStreamProxy` executes HTTP 403/410 in-place self-healing (up to 2 retries)
        //    and populates `Content-Length` + RAM LRU chunk 0 before `MediaSourceStream` caches
        //    `is_seekable()`.
        // 2. Unrecoverable HTTP 403 / 401 / network / timeout / empty-body errors surface cleanly
        //    instead of falling into Symphonia `probe()` as `no suitable format reader found`.
        let mut probe_buf = [0u8; 32];
        match bridge.read(&mut probe_buf) {
            Ok(0) => {
                if let Some(typed) =
                    bridge.take_last_stream_error().and_then(map_typed_stream_error)
                {
                    return Err(typed);
                }
                return Err(DecoderError::Io(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "Empty audio stream (0 bytes received at offset 0)",
                )));
            }
            Ok(n) => {
                if hint_extension.is_none()
                    && let Some(magic_ext) = crate::player::infer_extension_from_magic(&probe_buf[..n])
                {
                    hint_extension = Some(magic_ext.to_string());
                }
                bridge.seek(SeekFrom::Start(0)).map_err(DecoderError::Io)?;
            }
            Err(e) => {
                if let Some(typed) =
                    bridge.take_last_stream_error().and_then(map_typed_stream_error)
                {
                    return Err(typed);
                }
                return Err(DecoderError::Io(e));
            }
        }

        let bridge_arc = Arc::new(Mutex::new(bridge));
        let source: Box<dyn MediaSource> = Box::new(SharedBridgeMediaSource(Arc::clone(&bridge_arc)));
        Self::open_internal(
            source,
            hint_extension.as_deref(),
            hint_mime.as_deref(),
            LOW_LATENCY_MSS_BUFFER_LEN,
            Some(bridge_arc),
            is_segmented,
            manifest_duration_ms,
        )
    }

    fn open_internal(
        source: Box<dyn MediaSource>,
        hint_extension: Option<&str>,
        hint_mime: Option<&str>,
        mss_buffer_len: usize,
        bridge: Option<Arc<Mutex<BlockingStreamBridge>>>,
        is_segmented: bool,
        manifest_duration_ms: Option<u64>,
    ) -> Result<Self, DecoderError> {
        let (norm_ext, norm_mime) = normalize_probe_hints(hint_extension, hint_mime);
        let hint = build_hint(norm_ext.as_deref(), norm_mime.as_deref());
        let is_seekable = source.is_seekable();
        let last_io_error = Arc::new(Mutex::new(None));
        let tracked_source = Box::new(ErrorTrackingMediaSource {
            inner: source,
            last_io_error: Arc::clone(&last_io_error),
        });

        let mss = MediaSourceStream::new(
            tracked_source,
            MediaSourceStreamOptions {
                buffer_len: mss_buffer_len,
            },
        );

        let format_opts = FormatOptions {
            enable_gapless: true,
            prebuild_seek_index: false,
            ..Default::default()
        };
        let meta_opts = MetadataOptions::default();

        let mut probed = symphonia::default::get_probe()
            .format(&hint, mss, &format_opts, &meta_opts)
            .map_err(|e| {
                if let Some(typed) = take_typed_bridge_error(bridge.as_ref()) {
                    return typed;
                }
                if let Some((kind, io_err)) = take_tracked_io_error(&last_io_error) {
                    return DecoderError::Io(std::io::Error::new(kind, io_err));
                }
                DecoderError::ProbeFailed(e.to_string())
            })?;
        clear_tracked_io_error(&last_io_error);

        let mut metadata = DecodedTrackMetadata::default();
        if let Some(mut container_meta) = probed.metadata.get()
            && let Some(rev) = container_meta.skip_to_latest()
        {
            collect_revision_metadata(rev, &mut metadata);
        }
        let mut reader = probed.format;
        if let Some(rev) = reader.metadata().current() {
            collect_revision_metadata(rev, &mut metadata);
        }

        let track = reader
            .default_track()
            .or_else(|| {
                reader
                    .tracks()
                    .iter()
                    .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            })
            .ok_or(DecoderError::NoAudioTrack)?
            .clone();

        let track_id = track.id;
        let params = &track.codec_params;

        let decoder_opts = DecoderOptions::default();
        let decoder = codec_registry()
            .make(params, &decoder_opts)
            .map_err(|e| DecoderError::CodecInitFailed(e.to_string()))?;
        let dec_params = decoder.codec_params();

        let sample_rate = dec_params
            .sample_rate
            .or(params.sample_rate)
            .unwrap_or(44_100);
        // Preserve the container's time base so packet timestamps and seeks match `FormatReader`.
        let time_base = params.time_base;
        let alac_cookie = if params.codec == symphonia::core::codecs::CODEC_TYPE_ALAC {
            params
                .extra_data
                .as_deref()
                .filter(|ed| ed.len() == 24 || ed.len() == 48)
        } else {
            None
        };
        let channels = dec_params
            .channels
            .or(params.channels)
            .map(|c| c.count() as u8)
            .or_else(|| alac_cookie.map(|ed| ed[9]))
            .unwrap_or(2);
        let declared_bits = dec_params
            .bits_per_sample
            .or(params.bits_per_sample)
            .or_else(|| alac_cookie.map(|ed| ed[5] as u32))
            .unwrap_or(16)
            .min(64) as u8;

        let total_frames = if is_segmented && params.n_frames == Some(0) {
            None
        } else {
            params.n_frames
        };
        let duration = total_frames
            .map(|f| {
                if let Some(tb) = time_base {
                    let t = tb.calc_time(f);
                    Duration::new(t.seconds, (t.frac * 1_000_000_000.0).round() as u32)
                } else {
                    Duration::from_secs_f64(f as f64 / sample_rate.max(1) as f64)
                }
            })
            .filter(|d| !is_segmented || *d > Duration::ZERO)
            .or_else(|| manifest_duration_ms.filter(|&ms| ms > 0).map(Duration::from_millis));

        let (codec, sample_format, container_bits, valid_bits, endianness) =
            classify_codec_and_sample_format(params.codec, declared_bits);

        let format = AudioFormat::pcm(codec, sample_rate, valid_bits, channels)
            .map_err(|e| DecoderError::UnsupportedFormat(e.to_string()))?;

        let unified_format = UnifiedAudioFormat {
            codec,
            sample_rate,
            channels: (channels as u16).max(1),
            channel_layout: ChannelLayout::from_channels((channels as u16).max(1)),
            sample_format,
            container_bits,
            valid_bits,
            endianness,
            interleaving: Interleaving::Interleaved,
            dsd_rate: None,
        };

        tracing::trace!(
            "SymphoniaDecoder initialized: {:?}, unified={:?}",
            format,
            unified_format
        );

        Ok(Self {
            reader: Some(reader),
            decoder,
            track_id,
            format,
            unified_format,
            metadata,
            valid_bits,
            sample_rate,
            time_base,
            duration,
            total_frames,
            is_seekable,
            hint_extension: norm_ext,
            hint_mime: norm_mime,
            mss_buffer_len,
            bridge,
            is_segmented,
            base_timestamp_ms: 0,
            last_packet_end_ts: 0,
            pending_seek_target_ts: None,
            pending_seek_skip_frames: 0,
            at_eof: false,
            last_seek_outcome: None,
            last_io_error,
        })
    }

    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self, DecoderError> {
        let file = File::open(path.as_ref())?;
        let ext = path.as_ref().extension().and_then(|e| e.to_str());
        Self::from_media_source(Box::new(file), ext, None)
    }

    pub fn from_bytes(bytes: Vec<u8>, hint_extension: Option<&str>) -> Result<Self, DecoderError> {
        let cursor = Cursor::new(bytes);
        Self::from_media_source(Box::new(cursor), hint_extension, None)
    }

    /// Returns the timeline base offset in milliseconds (non-zero after segmented DASH seeks).
    pub fn base_timestamp_ms(&self) -> u64 {
        self.base_timestamp_ms
    }

    pub fn seek_with_outcome(&mut self, time: Duration) -> Result<SeekOutcome, DecoderError> {
        self.at_eof = false;
        self.pending_seek_target_ts = None;
        self.pending_seek_skip_frames = 0;

        let requested_ms = time.as_millis() as u64;
        let exact_ts = self.time_base.and_then(|tb| {
            if tb.denom > 0 && tb.numer > 0 {
                let ts = (time.as_nanos().saturating_mul(tb.denom as u128))
                    / (1_000_000_000u128.saturating_mul(tb.numer as u128));
                u64::try_from(ts).ok()
            } else {
                None
            }
        });
        let is_eof_seek = (!self.is_segmented && self.total_frames == Some(0))
            || self
                .duration
                .is_some_and(|d| d > Duration::ZERO && time >= d)
            || (!self.is_segmented
                && self
                    .total_frames
                    .is_some_and(|tf| exact_ts.is_some_and(|ts| ts >= tf)));

        if is_eof_seek {
            self.decoder.reset();
            self.at_eof = true;
            let eof_ts = self.total_frames.unwrap_or(0);
            let actual_ms = self
                .duration
                .map(|d| d.as_millis() as u64)
                .unwrap_or(requested_ms);
            let outcome = SeekOutcome {
                requested_ms,
                actual_ms,
                required_ts: eof_ts,
                actual_ts: eof_ts,
                trimmed_frames: 0,
            };
            self.last_seek_outcome = Some(outcome);
            return Ok(outcome);
        }

        if self.is_segmented
            && let Some(ref bridge_arc) = self.bridge
        {
            return self.seek_segmented(Arc::clone(bridge_arc), requested_ms);
        }

        let is_backward_flac_seek = !self.is_segmented
            && self.format.codec == AudioCodec::Flac
            && self.is_seekable
            && exact_ts.is_some_and(|ts| ts < self.last_packet_end_ts);

        if is_backward_flac_seek
            && let Some(old_reader) = self.reader.take()
        {
            clear_tracked_io_error(&self.last_io_error);
            let mut mss = old_reader.into_inner();
            mss.seek(SeekFrom::Start(0))
                .map_err(|e| {
                    DecoderError::SeekError(format_with_tracked_io_error(e, &self.last_io_error))
                })?;
            let hint = build_hint(self.hint_extension.as_deref(), self.hint_mime.as_deref());
            let format_opts = FormatOptions {
                enable_gapless: true,
                prebuild_seek_index: false,
                ..Default::default()
            };
            let meta_opts = MetadataOptions::default();
            let probed = symphonia::default::get_probe()
                .format(&hint, mss, &format_opts, &meta_opts)
                .map_err(|e| {
                    take_typed_bridge_error(self.bridge.as_ref()).unwrap_or_else(|| {
                        DecoderError::SeekError(format_with_tracked_io_error(
                            e,
                            &self.last_io_error,
                        ))
                    })
                })?;
            clear_tracked_io_error(&self.last_io_error);
            self.reader = Some(probed.format);
            self.last_packet_end_ts = 0;
        }

        let seek_to = match exact_ts {
            Some(ts) => SeekTo::TimeStamp {
                ts,
                track_id: self.track_id,
            },
            None => SeekTo::Time {
                time: symphonia::core::units::Time::from(time),
                track_id: Some(self.track_id),
            },
        };
        clear_tracked_io_error(&self.last_io_error);
        let seek_res = {
            let reader = self
                .reader
                .as_mut()
                .ok_or_else(|| DecoderError::SeekError("Missing format reader".to_string()))?;
            reader.seek(SeekMode::Accurate, seek_to)
        };
        let seeked = match seek_res {
            Ok(s) => s,
            Err(symphonia::core::errors::Error::SeekError(
                symphonia::core::errors::SeekErrorKind::OutOfRange,
            )) if !self.is_segmented && self.is_seekable && requested_ms == 0 => {
                // Containers like WebM/Opus can have a first CuePoint timestamp > 0 (e.g. CodecDelay).
                // Rewinding the underlying MediaSourceStream to offset 0 cleanly restarts playback at 0.
                if let Some(old_reader) = self.reader.take() {
                    clear_tracked_io_error(&self.last_io_error);
                    let mut mss = old_reader.into_inner();
                    mss.seek(SeekFrom::Start(0)).map_err(|e| {
                        DecoderError::SeekError(format_with_tracked_io_error(
                            e,
                            &self.last_io_error,
                        ))
                    })?;
                    let hint = build_hint(self.hint_extension.as_deref(), self.hint_mime.as_deref());
                    let format_opts = FormatOptions {
                        enable_gapless: true,
                        prebuild_seek_index: false,
                        ..Default::default()
                    };
                    let meta_opts = MetadataOptions::default();
                    let probed = symphonia::default::get_probe()
                        .format(&hint, mss, &format_opts, &meta_opts)
                        .map_err(|e| {
                            take_typed_bridge_error(self.bridge.as_ref()).unwrap_or_else(|| {
                                DecoderError::SeekError(format_with_tracked_io_error(
                                    e,
                                    &self.last_io_error,
                                ))
                            })
                        })?;
                    clear_tracked_io_error(&self.last_io_error);
                    self.reader = Some(probed.format);
                }
                self.decoder.reset();
                self.last_packet_end_ts = 0;
                let outcome = SeekOutcome {
                    requested_ms: 0,
                    actual_ms: 0,
                    required_ts: 0,
                    actual_ts: 0,
                    trimmed_frames: 0,
                };
                self.last_seek_outcome = Some(outcome);
                return Ok(outcome);
            }
            Err(e) => {
                return Err(take_typed_bridge_error(self.bridge.as_ref()).unwrap_or_else(|| {
                    DecoderError::SeekError(format_with_tracked_io_error(e, &self.last_io_error))
                }));
            }
        };
        if let Some(typed) = take_typed_bridge_error(self.bridge.as_ref()) {
            return Err(typed);
        }
        if let Some((_, io_err)) = take_tracked_io_error(&self.last_io_error) {
            return Err(DecoderError::SeekError(io_err));
        }
        self.decoder.reset();
        self.last_packet_end_ts = seeked.actual_ts;

        if seeked.actual_ts <= seeked.required_ts {
            self.pending_seek_target_ts = Some(seeked.required_ts);
        }

        let trimmed_frames = ts_delta_to_frames(
            seeked.required_ts.saturating_sub(seeked.actual_ts),
            self.time_base,
            self.sample_rate,
        );
        let effective_ts = seeked.actual_ts.max(seeked.required_ts);
        let actual_ms = ts_to_ms(effective_ts, self.time_base, self.sample_rate);
        let outcome = SeekOutcome {
            requested_ms,
            actual_ms,
            required_ts: seeked.required_ts,
            actual_ts: seeked.actual_ts,
            trimmed_frames,
        };
        self.last_seek_outcome = Some(outcome);
        Ok(outcome)
    }

    fn seek_segmented(
        &mut self,
        bridge_arc: Arc<Mutex<BlockingStreamBridge>>,
        requested_ms: u64,
    ) -> Result<SeekOutcome, DecoderError> {
        self.reader = None;
        clear_tracked_io_error(&self.last_io_error);

        let target = {
            let mut br = bridge_arc
                .lock()
                .map_err(|_| DecoderError::SeekError("Segmented bridge lock poisoned".into()))?;
            br.seek_to_time_ms(requested_ms)
                .map_err(|e| {
                    let msg = e.to_string();
                    map_typed_stream_error(e).unwrap_or(DecoderError::SeekError(msg))
                })?
                .ok_or_else(|| {
                    DecoderError::SeekError("Segmented stream returned no seek target".to_string())
                })?
        };

        let tracked_source = Box::new(ErrorTrackingMediaSource {
            inner: Box::new(SharedBridgeMediaSource(Arc::clone(&bridge_arc))),
            last_io_error: Arc::clone(&self.last_io_error),
        });
        let mss = MediaSourceStream::new(
            tracked_source,
            MediaSourceStreamOptions {
                buffer_len: self.mss_buffer_len,
            },
        );
        let hint = build_hint(self.hint_extension.as_deref(), self.hint_mime.as_deref());
        let format_opts = FormatOptions {
            enable_gapless: true,
            prebuild_seek_index: false,
            ..Default::default()
        };
        let meta_opts = MetadataOptions::default();
        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &format_opts, &meta_opts)
            .map_err(|e| {
                take_typed_bridge_error(Some(&bridge_arc)).unwrap_or_else(|| {
                    DecoderError::SeekError(format_with_tracked_io_error(e, &self.last_io_error))
                })
            })?;
        clear_tracked_io_error(&self.last_io_error);

        let reader = probed.format;
        let track = reader
            .default_track()
            .or_else(|| {
                reader
                    .tracks()
                    .iter()
                    .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            })
            .ok_or(DecoderError::NoAudioTrack)?;

        self.track_id = track.id;
        self.time_base = track.codec_params.time_base;
        self.reader = Some(reader);
        self.decoder.reset();
        self.last_packet_end_ts = 0;
        self.base_timestamp_ms = target.segment_start_ms;

        let intra_ms = requested_ms.saturating_sub(target.segment_start_ms);
        let local_target_ts = ms_to_ts(intra_ms, self.time_base, self.sample_rate);
        let trimmed_frames =
            ((intra_ms as u128 * self.sample_rate.max(1) as u128) / 1000u128) as u64;
        // Trim intra-segment leading samples by decoded frame count so trimming works accurately
        // regardless of whether fMP4 `tfdt` timestamps are segment-relative (0) or absolute timeline ticks.
        self.pending_seek_target_ts = None;
        self.pending_seek_skip_frames = trimmed_frames;

        let actual_ms = self
            .base_timestamp_ms
            .saturating_add(intra_ms);
        let outcome = SeekOutcome {
            requested_ms,
            actual_ms,
            required_ts: local_target_ts,
            actual_ts: 0,
            trimmed_frames,
        };
        self.last_seek_outcome = Some(outcome);
        Ok(outcome)
    }

    pub fn last_seek_outcome(&self) -> Option<SeekOutcome> {
        self.last_seek_outcome
    }

    /// Returns a handle to the backing `BlockingStreamBridge`, if this decoder reads from a stream.
    pub fn stream_bridge(&self) -> Option<Arc<Mutex<BlockingStreamBridge>>> {
        self.bridge.as_ref().map(Arc::clone)
    }
}

impl AudioDecoder for SymphoniaDecoder {
    fn format(&self) -> &AudioFormat {
        &self.format
    }

    fn unified_format(&self) -> UnifiedAudioFormat {
        self.unified_format.clone()
    }

    fn metadata(&self) -> Option<&DecodedTrackMetadata> {
        Some(&self.metadata)
    }

    fn decoder_name(&self) -> &'static str {
        match self.format.codec {
            AudioCodec::Flac => "Symphonia Lossless FLAC Decoder",
            AudioCodec::Wav => "Symphonia Direct PCM WAV Decoder",
            AudioCodec::Mp3 => "Symphonia MPEG-1/2 Layer III Decoder",
            AudioCodec::Alac => "Symphonia Apple Lossless ALAC Decoder",
            AudioCodec::Aiff => "Symphonia AIFF PCM Decoder",
            AudioCodec::Opus => "Symphonia Opus Decoder (libopus)",
            _ => "Symphonia Decoder",
        }
    }

    fn duration(&self) -> Option<Duration> {
        self.duration
    }

    fn total_frames(&self) -> Option<u64> {
        self.total_frames
    }

    fn next_chunk(&mut self) -> Result<Option<AudioChunk>, DecoderError> {
        if self.at_eof {
            return Ok(None);
        }

        loop {
            let reader = match self.reader.as_mut() {
                Some(r) => r,
                None => return Ok(None),
            };
            clear_tracked_io_error(&self.last_io_error);
            let packet = match reader.next_packet() {
                Ok(p) => p,
                Err(symphonia::core::errors::Error::IoError(e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    if let Some(typed) = take_typed_bridge_error(self.bridge.as_ref()) {
                        return Err(typed);
                    }
                    if let Some((_, io_err)) = take_tracked_io_error(&self.last_io_error) {
                        return Err(DecoderError::DecodeError(io_err));
                    }
                    self.at_eof = true;
                    return Ok(None);
                }
                Err(e) => {
                    if let Some(typed) = take_typed_bridge_error(self.bridge.as_ref()) {
                        return Err(typed);
                    }
                    return Err(DecoderError::DecodeError(format_with_tracked_io_error(
                        e,
                        &self.last_io_error,
                    )));
                }
            };

            if packet.track_id() != self.track_id {
                continue;
            }

            let pkt_ts = packet.ts();
            let pkt_dur = packet.dur();
            self.last_packet_end_ts = self
                .last_packet_end_ts
                .max(pkt_ts.saturating_add(pkt_dur));

            // Always decode every post-seek packet so MP3 BitResevoir reference frames
            // and Vorbis MDCT overlap-add state prime properly before target playback.
            let decoded = self
                .decoder
                .decode(&packet)
                .map_err(|e| DecoderError::DecodeError(e.to_string()))?;

            let decoded_frames = decoded.frames();
            if decoded_frames == 0 {
                // E.g. first Vorbis packet after open/reset priming MDCT lapping state.
                continue;
            }

            if self.pending_seek_skip_frames > 0 {
                let frames_u64 = decoded_frames as u64;
                if self.pending_seek_skip_frames >= frames_u64 {
                    self.pending_seek_skip_frames -= frames_u64;
                    continue;
                }
                let trim_frames = self.pending_seek_skip_frames as usize;
                self.pending_seek_skip_frames = 0;
                let mut chunk = extract_interleaved_chunk(decoded, self.valid_bits);
                trim_chunk_front(&mut chunk, trim_frames);
                if chunk.is_empty() {
                    continue;
                }
                return Ok(Some(chunk));
            }

            if let Some(target_ts) = self.pending_seek_target_ts {
                if pkt_dur > 0 && pkt_ts.saturating_add(pkt_dur) <= target_ts {
                    continue;
                }

                let decoded_rate = decoded.spec().rate;
                if target_ts > pkt_ts {
                    let trim_frames =
                        ts_delta_to_frames(target_ts - pkt_ts, self.time_base, decoded_rate)
                            as usize;
                    if trim_frames >= decoded_frames {
                        // Keep `pending_seek_target_ts` active: containers like Matroska/WebM
                        // often emit `pkt_dur == 0`, so we must keep decoding and discarding
                        // whole pre-target packets until a packet actually straddles `target_ts`.
                        continue;
                    }
                    self.pending_seek_target_ts = None;
                    let mut chunk = extract_interleaved_chunk(decoded, self.valid_bits);
                    trim_chunk_front(&mut chunk, trim_frames);
                    if chunk.is_empty() {
                        continue;
                    }
                    return Ok(Some(chunk));
                }

                self.pending_seek_target_ts = None;
                let chunk = extract_interleaved_chunk(decoded, self.valid_bits);
                return Ok(Some(chunk));
            }

            let chunk = extract_interleaved_chunk(decoded, self.valid_bits);
            return Ok(Some(chunk));
        }
    }

    fn seek(&mut self, time: Duration) -> Result<(), DecoderError> {
        self.seek_with_outcome(time).map(|_| ())
    }

    fn reclaim_idle_memory(&mut self) -> usize {
        self.bridge
            .as_ref()
            .and_then(|b| b.lock().ok())
            .map(|guard| guard.reclaim_idle_memory())
            .unwrap_or(0)
    }
}
