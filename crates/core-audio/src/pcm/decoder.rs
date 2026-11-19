use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::path::Path;
use std::time::Duration;

use core_types::{
    AudioCodec, AudioFormat, ChannelLayout, Endianness, Interleaving, SampleFormatKind,
    UnifiedAudioFormat,
};
use symphonia::core::audio::{AudioBuffer, AudioBufferRef, Signal};
use symphonia::core::codecs::{CodecType, Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, MetadataRevision, StandardTagKey};
use symphonia::core::probe::Hint;

use super::{AudioChunk, AudioDecoder, DecodedTrackMetadata};
use crate::error::DecoderError;

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
    last_packet_end_ts: u64,
    pending_seek_target_ts: Option<u64>,
    at_eof: bool,
    last_seek_outcome: Option<SeekOutcome>,
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
                StandardTagKey::TrackTitle if out.title.is_none() => out.title = Some(val),
                StandardTagKey::Artist if out.artist.is_none() => out.artist = Some(val),
                StandardTagKey::AlbumArtist if out.artist.is_none() => out.artist = Some(val),
                StandardTagKey::Album if out.album.is_none() => out.album = Some(val),
                StandardTagKey::TrackNumber if out.track_number.is_none() => {
                    out.track_number = val.split('/').next().and_then(|n| n.trim().parse().ok());
                }
                StandardTagKey::ReplayGainTrackGain if out.replaygain_track_db.is_none() => {
                    out.replaygain_track_db = parse_gain_db(&val);
                }
                StandardTagKey::ReplayGainAlbumGain if out.replaygain_album_db.is_none() => {
                    out.replaygain_album_db = parse_gain_db(&val);
                }
                _ => {}
            }
        }
    }
}

fn parse_gain_db(raw: &str) -> Option<f64> {
    raw.trim()
        .trim_end_matches("dB")
        .trim_end_matches("db")
        .trim()
        .parse::<f64>()
        .ok()
        .filter(|v| v.is_finite())
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
        let mut hint = Hint::new();
        if let Some(ext) = hint_extension {
            hint.with_extension(ext);
        }
        if let Some(mime) = hint_mime {
            hint.mime_type(mime);
        }
        let is_seekable = source.is_seekable();

        let mss = MediaSourceStream::new(source, MediaSourceStreamOptions::default());

        let format_opts = FormatOptions {
            enable_gapless: true,
            ..Default::default()
        };
        let meta_opts = MetadataOptions::default();

        let mut probed = symphonia::default::get_probe()
            .format(&hint, mss, &format_opts, &meta_opts)
            .map_err(|e| DecoderError::ProbeFailed(e.to_string()))?;

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

        let sample_rate = params.sample_rate.unwrap_or(44_100);
        let time_base = params.time_base;
        let alac_cookie = if params.codec == symphonia::core::codecs::CODEC_TYPE_ALAC {
            params
                .extra_data
                .as_deref()
                .filter(|ed| ed.len() == 24 || ed.len() == 48)
        } else {
            None
        };
        let channels = params
            .channels
            .map(|c| c.count() as u8)
            .or_else(|| alac_cookie.map(|ed| ed[9]))
            .unwrap_or(2);
        let declared_bits = params
            .bits_per_sample
            .or_else(|| alac_cookie.map(|ed| ed[5] as u32))
            .unwrap_or(16)
            .min(64) as u8;
        let total_frames = params.n_frames;
        let duration = total_frames.map(|f| {
            if let Some(tb) = time_base {
                let t = tb.calc_time(f);
                Duration::new(t.seconds, (t.frac * 1_000_000_000.0).round() as u32)
            } else {
                Duration::from_secs_f64(f as f64 / sample_rate.max(1) as f64)
            }
        });

        if params.codec == symphonia::core::codecs::CODEC_TYPE_OPUS {
            return Err(DecoderError::UnsupportedFormat(
                "Opus codec is not supported by the built-in Symphonia decoder".to_string(),
            ));
        }

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

        let decoder_opts = DecoderOptions::default();
        let decoder = symphonia::default::get_codecs()
            .make(params, &decoder_opts)
            .map_err(|e| DecoderError::CodecInitFailed(e.to_string()))?;

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
            hint_extension: hint_extension.map(str::to_string),
            hint_mime: hint_mime.map(str::to_string),
            last_packet_end_ts: 0,
            pending_seek_target_ts: None,
            at_eof: false,
            last_seek_outcome: None,
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

    pub fn seek_with_outcome(&mut self, time: Duration) -> Result<SeekOutcome, DecoderError> {
        self.at_eof = false;
        self.pending_seek_target_ts = None;

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
        let is_eof_seek = self.total_frames == Some(0)
            || self.duration.is_some_and(|d| time >= d)
            || self
                .total_frames
                .is_some_and(|tf| exact_ts.is_some_and(|ts| ts >= tf));

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

        let is_backward_flac_seek = self.format.codec == AudioCodec::Flac
            && self.is_seekable
            && exact_ts.is_some_and(|ts| ts < self.last_packet_end_ts);

        if is_backward_flac_seek
            && let Some(old_reader) = self.reader.take()
        {
            let mut mss = old_reader.into_inner();
            mss.seek(SeekFrom::Start(0))
                .map_err(|e| DecoderError::SeekError(e.to_string()))?;
            let mut hint = Hint::new();
            if let Some(ref ext) = self.hint_extension {
                hint.with_extension(ext);
            }
            if let Some(ref mime) = self.hint_mime {
                hint.mime_type(mime);
            }
            let format_opts = FormatOptions {
                enable_gapless: true,
                ..Default::default()
            };
            let meta_opts = MetadataOptions::default();
            let probed = symphonia::default::get_probe()
                .format(&hint, mss, &format_opts, &meta_opts)
                .map_err(|e| DecoderError::SeekError(e.to_string()))?;
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
        let reader = self
            .reader
            .as_mut()
            .ok_or_else(|| DecoderError::SeekError("Missing format reader".to_string()))?;
        let seeked = reader
            .seek(SeekMode::Accurate, seek_to)
            .map_err(|e| DecoderError::SeekError(e.to_string()))?;
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

    pub fn last_seek_outcome(&self) -> Option<SeekOutcome> {
        self.last_seek_outcome
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
            let packet = match reader.next_packet() {
                Ok(p) => p,
                Err(symphonia::core::errors::Error::IoError(e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    self.at_eof = true;
                    return Ok(None);
                }
                Err(e) => return Err(DecoderError::DecodeError(e.to_string())),
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

            if let Some(target_ts) = self.pending_seek_target_ts {
                if pkt_dur > 0 && pkt_ts.saturating_add(pkt_dur) <= target_ts {
                    continue;
                }
                self.pending_seek_target_ts = None;

                let decoded_rate = decoded.spec().rate;
                let mut chunk = extract_interleaved_chunk(decoded, self.valid_bits);
                if target_ts > pkt_ts {
                    let trim_frames =
                        ts_delta_to_frames(target_ts - pkt_ts, self.time_base, decoded_rate)
                            as usize;
                    if trim_frames >= chunk.frames() {
                        continue;
                    }
                    trim_chunk_front(&mut chunk, trim_frames);
                    if chunk.is_empty() {
                        continue;
                    }
                }
                return Ok(Some(chunk));
            }

            let chunk = extract_interleaved_chunk(decoded, self.valid_bits);
            return Ok(Some(chunk));
        }
    }

    fn seek(&mut self, time: Duration) -> Result<(), DecoderError> {
        self.seek_with_outcome(time).map(|_| ())
    }
}
