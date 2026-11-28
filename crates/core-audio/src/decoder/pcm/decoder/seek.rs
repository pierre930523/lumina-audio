use std::io::{Seek, SeekFrom};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use core_types::AudioCodec;
use symphonia::core::codecs::CODEC_TYPE_NULL;
use symphonia::core::formats::{FormatOptions, SeekMode, SeekTo};
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;

use super::SymphoniaDecoder;
use super::metadata::build_hint;
use super::sources::{
    ErrorTrackingMediaSource, SharedBridgeMediaSource, clear_tracked_io_error,
    format_with_tracked_io_error, map_typed_stream_error, take_tracked_io_error,
    take_typed_bridge_error,
};
use crate::error::DecoderError;
use crate::streaming::BlockingStreamBridge;

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

pub(super) fn ts_delta_to_frames(
    delta_ts: u64,
    time_base: Option<symphonia::core::units::TimeBase>,
    sample_rate: u32,
) -> u64 {
    if delta_ts == 0 {
        return 0;
    }
    match time_base {
        Some(tb) if tb.denom > 0 => {
            ((delta_ts as u128 * tb.numer as u128 * sample_rate.max(1) as u128) / tb.denom as u128)
                as u64
        }
        _ => delta_ts,
    }
}

fn ts_to_ms(ts: u64, time_base: Option<symphonia::core::units::TimeBase>, sample_rate: u32) -> u64 {
    let frames = ts_delta_to_frames(ts, time_base, sample_rate);
    ((frames as u128 * 1000) / (sample_rate.max(1) as u128)) as u64
}

fn ms_to_ts(ms: u64, time_base: Option<symphonia::core::units::TimeBase>, sample_rate: u32) -> u64 {
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

impl SymphoniaDecoder {
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

        if is_backward_flac_seek && let Some(old_reader) = self.reader.take() {
            clear_tracked_io_error(&self.last_io_error);
            let mut mss = old_reader.into_inner();
            mss.seek(SeekFrom::Start(0)).map_err(|e| {
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
                    let hint =
                        build_hint(self.hint_extension.as_deref(), self.hint_mime.as_deref());
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
                return Err(
                    take_typed_bridge_error(self.bridge.as_ref()).unwrap_or_else(|| {
                        DecoderError::SeekError(format_with_tracked_io_error(
                            e,
                            &self.last_io_error,
                        ))
                    }),
                );
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

        let actual_ms = self.base_timestamp_ms.saturating_add(intra_ms);
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
}
