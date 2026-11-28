use std::time::Duration;

use core_types::{AudioCodec, AudioFormat, UnifiedAudioFormat};
use symphonia::core::audio::{AudioBuffer, AudioBufferRef, Signal};

use super::super::{AudioChunk, AudioDecoder, DecodedTrackMetadata};
use super::SymphoniaDecoder;
use super::seek::ts_delta_to_frames;
use super::sources::{
    clear_tracked_io_error, format_with_tracked_io_error, take_tracked_io_error,
    take_typed_bridge_error,
};
use crate::error::DecoderError;

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
            self.last_packet_end_ts = self.last_packet_end_ts.max(pkt_ts.saturating_add(pkt_dur));

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
