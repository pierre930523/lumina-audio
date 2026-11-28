mod decode;
mod metadata;
mod seek;
mod sources;

use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use core_types::{AudioFormat, ChannelLayout, Interleaving, StreamSourceSpec, UnifiedAudioFormat};
use symphonia::core::codecs::{CODEC_TYPE_NULL, CodecRegistry, Decoder, DecoderOptions};
use symphonia::core::formats::{FormatOptions, FormatReader};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;

use super::DecodedTrackMetadata;
use crate::error::DecoderError;
use crate::streaming::BlockingStreamBridge;

pub use metadata::{build_probe_hint, extension_from_mime_type};
pub use seek::SeekOutcome;

use metadata::{
    bridge_probe_hints, build_hint, classify_codec_and_sample_format, collect_revision_metadata,
    normalize_probe_hints,
};
use sources::{
    ErrorTrackingMediaSource, GenericSource, SharedBridgeMediaSource, clear_tracked_io_error,
    map_typed_stream_error, take_tracked_io_error, take_typed_bridge_error,
};

/// Minimum `MediaSourceStreamOptions::buffer_len` permitted by Symphonia 0.5.5
/// (`MediaSourceStream::new` asserts `buffer_len.is_power_of_two() && buffer_len > 32 * 1024`).
const LOW_LATENCY_MSS_BUFFER_LEN: usize = 64 * 1024;

fn codec_registry() -> &'static CodecRegistry {
    static REGISTRY: OnceLock<CodecRegistry> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        let mut registry = CodecRegistry::new();
        symphonia::default::register_enabled_codecs(&mut registry);
        super::opus::register_opus_codec(&mut registry);
        registry
    })
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
    pub(super) reader: Option<Box<dyn FormatReader>>,
    pub(super) decoder: Box<dyn Decoder>,
    pub(super) track_id: u32,
    pub(super) format: AudioFormat,
    pub(super) unified_format: UnifiedAudioFormat,
    pub(super) metadata: DecodedTrackMetadata,
    pub(super) valid_bits: u8,
    pub(super) sample_rate: u32,
    pub(super) time_base: Option<symphonia::core::units::TimeBase>,
    pub(super) duration: Option<Duration>,
    pub(super) total_frames: Option<u64>,
    pub(super) is_seekable: bool,
    pub(super) hint_extension: Option<String>,
    pub(super) hint_mime: Option<String>,
    pub(super) mss_buffer_len: usize,
    pub(super) bridge: Option<Arc<Mutex<BlockingStreamBridge>>>,
    pub(super) is_segmented: bool,
    pub(super) base_timestamp_ms: u64,
    pub(super) last_packet_end_ts: u64,
    pub(super) pending_seek_target_ts: Option<u64>,
    pub(super) pending_seek_skip_frames: u64,
    pub(super) at_eof: bool,
    pub(super) last_seek_outcome: Option<SeekOutcome>,
    pub(super) last_io_error: Arc<Mutex<Option<(std::io::ErrorKind, String)>>>,
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
                if let Some(typed) = bridge
                    .take_last_stream_error()
                    .and_then(map_typed_stream_error)
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
                    && let Some(magic_ext) =
                        crate::player::infer_extension_from_magic(&probe_buf[..n])
                {
                    hint_extension = Some(magic_ext.to_string());
                }
                bridge.seek(SeekFrom::Start(0)).map_err(DecoderError::Io)?;
            }
            Err(e) => {
                if let Some(typed) = bridge
                    .take_last_stream_error()
                    .and_then(map_typed_stream_error)
                {
                    return Err(typed);
                }
                return Err(DecoderError::Io(e));
            }
        }

        let bridge_arc = Arc::new(Mutex::new(bridge));
        let source: Box<dyn MediaSource> =
            Box::new(SharedBridgeMediaSource(Arc::clone(&bridge_arc)));
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
            .or_else(|| {
                manifest_duration_ms
                    .filter(|&ms| ms > 0)
                    .map(Duration::from_millis)
            });

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

    /// Returns a handle to the backing `BlockingStreamBridge`, if this decoder reads from a stream.
    pub fn stream_bridge(&self) -> Option<Arc<Mutex<BlockingStreamBridge>>> {
        self.bridge.as_ref().map(Arc::clone)
    }
}
