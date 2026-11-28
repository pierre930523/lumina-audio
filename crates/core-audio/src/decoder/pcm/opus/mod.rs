use std::sync::{Mutex, PoisonError};

use opus2::{Channels as OpusChannels, Decoder as OpusDecoder};
use symphonia::core as symphonia_core;
use symphonia_core::audio::{
    AsAudioBufferRef, AudioBuffer, AudioBufferRef, Channels as SymphoniaChannels, Signal,
    SignalSpec,
};
use symphonia_core::codecs::{
    CODEC_TYPE_OPUS, CodecDescriptor, CodecParameters, CodecRegistry, Decoder, DecoderOptions,
    FinalizeResult,
};
use symphonia_core::errors::{
    Error as SymphoniaError, Result as SymphoniaResult, decode_error, unsupported_error,
};
use symphonia_core::formats::Packet;
use symphonia_core::support_codec;
use symphonia_core::units::TimeBase;

#[cfg(test)]
mod tests;

/// Canonical Opus output sample rate in Hz (RFC 6716 / RFC 7845).
pub const OPUS_SAMPLE_RATE_HZ: u32 = 48_000;

/// Maximum frames per channel a single Opus packet can contain (120 ms at 48 kHz).
const MAX_OPUS_FRAMES_PER_PACKET: usize = 5760;

const OPUS_HEAD_SIGNATURE: &[u8; 8] = b"OpusHead";
const OPUS_HEAD_MIN_LEN: usize = 19;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct OpusHeadConfig {
    channels: usize,
    pre_skip: u32,
    output_gain_q8_db: i16,
}

fn parse_opus_head(extra_data: &[u8]) -> SymphoniaResult<OpusHeadConfig> {
    if extra_data.len() < OPUS_HEAD_MIN_LEN || &extra_data[..8] != OPUS_HEAD_SIGNATURE {
        return unsupported_error("opus: invalid or truncated OpusHead header");
    }

    let version = extra_data[8];
    // RFC 7845 §5.1: major version (upper 4 bits) must be 0.
    if (version >> 4) != 0 {
        return unsupported_error("opus: unsupported OpusHead major version");
    }

    let channels = extra_data[9] as usize;
    if channels == 0 || channels > 2 {
        return unsupported_error("opus: only mono and stereo streams are supported");
    }

    let pre_skip = u32::from(u16::from_le_bytes([extra_data[10], extra_data[11]]));
    let output_gain_q8_db = i16::from_le_bytes([extra_data[16], extra_data[17]]);
    let mapping_family = extra_data[18];

    match mapping_family {
        0 => {}
        1 => {
            if extra_data.len() < 21 + channels {
                return unsupported_error("opus: truncated Vorbis channel mapping in OpusHead");
            }
        }
        _ => return unsupported_error("opus: unsupported channel mapping family"),
    }

    Ok(OpusHeadConfig {
        channels,
        pre_skip,
        output_gain_q8_db,
    })
}

/// Registers [`OpusSymphoniaDecoder`] into a Symphonia [`CodecRegistry`] for `CODEC_TYPE_OPUS`.
pub fn register_opus_codec(registry: &mut CodecRegistry) {
    registry.register_all::<OpusSymphoniaDecoder>();
}

/// Symphonia [`Decoder`] implementation for `CODEC_TYPE_OPUS` powered by [`opus2`] (`libopus`).
///
/// Decodes 48 kHz mono and stereo Opus packets, parses RFC 7845 `OpusHead` pre-skip, channel count,
/// and output gain from `CodecParameters::extra_data`, and outputs `AudioBufferRef::F32`.
pub struct OpusSymphoniaDecoder {
    params: CodecParameters,
    // Mutex provides safe Send+Sync for Symphonia's Decoder bound; &mut methods use get_mut() lock-free.
    decoder: Mutex<OpusDecoder>,
    channels: usize,
    pre_skip: u32,
    remaining_pre_skip: u32,
    just_reset: bool,
    buf: AudioBuffer<f32>,
    interleaved_scratch: Vec<f32>,
}

impl OpusSymphoniaDecoder {
    fn decoder_mut(decoder: &mut Mutex<OpusDecoder>) -> &mut OpusDecoder {
        decoder.get_mut().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Decoder for OpusSymphoniaDecoder {
    fn try_new(params: &CodecParameters, _options: &DecoderOptions) -> SymphoniaResult<Self> {
        if params.codec != CODEC_TYPE_OPUS {
            return unsupported_error("opus: invalid codec type");
        }

        let head = if let Some(extra) = params.extra_data.as_deref() {
            parse_opus_head(extra)?
        } else {
            let ch = params.channels.map(|c| c.count()).unwrap_or(2);
            if ch == 0 || ch > 2 {
                return unsupported_error("opus: only mono and stereo streams are supported");
            }
            OpusHeadConfig {
                channels: ch,
                pre_skip: params.delay.unwrap_or(0),
                output_gain_q8_db: 0,
            }
        };

        let (opus_channels, symphonia_channels) = if head.channels == 1 {
            (OpusChannels::Mono, SymphoniaChannels::FRONT_LEFT)
        } else {
            (
                OpusChannels::Stereo,
                SymphoniaChannels::FRONT_LEFT | SymphoniaChannels::FRONT_RIGHT,
            )
        };

        let mut decoder = OpusDecoder::new(OPUS_SAMPLE_RATE_HZ, opus_channels).map_err(|_| {
            SymphoniaError::Unsupported("opus: failed to initialize libopus decoder")
        })?;
        if head.output_gain_q8_db != 0 {
            decoder
                .set_gain(i32::from(head.output_gain_q8_db))
                .map_err(|_| SymphoniaError::Unsupported("opus: failed to apply output gain"))?;
        }

        let mut normalized_params = params.clone();
        normalized_params
            .for_codec(CODEC_TYPE_OPUS)
            .with_sample_rate(OPUS_SAMPLE_RATE_HZ)
            .with_time_base(TimeBase::new(1, OPUS_SAMPLE_RATE_HZ))
            .with_channels(symphonia_channels)
            .with_delay(head.pre_skip);

        let spec = SignalSpec::new(OPUS_SAMPLE_RATE_HZ, symphonia_channels);
        let buf = AudioBuffer::new(MAX_OPUS_FRAMES_PER_PACKET as u64, spec);
        let interleaved_scratch = vec![0.0f32; MAX_OPUS_FRAMES_PER_PACKET * head.channels];

        Ok(Self {
            params: normalized_params,
            decoder: Mutex::new(decoder),
            channels: head.channels,
            pre_skip: head.pre_skip,
            remaining_pre_skip: head.pre_skip,
            just_reset: false,
            buf,
            interleaved_scratch,
        })
    }

    fn supported_codecs() -> &'static [CodecDescriptor] {
        &[support_codec!(
            CODEC_TYPE_OPUS,
            "opus",
            "Opus (RFC 6716 / libopus)"
        )]
    }

    fn reset(&mut self) {
        let _ = Self::decoder_mut(&mut self.decoder).reset_state();
        self.buf.clear();
        self.just_reset = true;
    }

    fn codec_params(&self) -> &CodecParameters {
        &self.params
    }

    fn decode(&mut self, packet: &Packet) -> SymphoniaResult<AudioBufferRef<'_>> {
        self.buf.clear();

        let data = packet.buf();
        if data.is_empty() {
            return decode_error("opus: empty packet");
        }

        let decoded_frames = Self::decoder_mut(&mut self.decoder)
            .decode_float(data, &mut self.interleaved_scratch, false)
            .map_err(|_| SymphoniaError::DecodeError("opus: packet decode failed"))?;

        if self.just_reset {
            self.just_reset = false;
            self.remaining_pre_skip = if packet.ts() == 0 { self.pre_skip } else { 0 };
        }

        let mut trim_start = packet.trim_start() as usize;
        if trim_start > 0 {
            let consumed = self.remaining_pre_skip.min(trim_start as u32);
            self.remaining_pre_skip -= consumed;
        } else if self.remaining_pre_skip > 0 {
            let skip = (self.remaining_pre_skip as usize).min(decoded_frames);
            self.remaining_pre_skip -= skip as u32;
            trim_start = skip;
        }

        let trim_end = packet.trim_end() as usize;
        let out_start = trim_start.min(decoded_frames);
        let out_end = decoded_frames.saturating_sub(trim_end).max(out_start);
        let out_frames = out_end - out_start;

        if out_frames > 0 {
            self.buf.render_reserved(Some(out_frames));
            if self.channels == 1 {
                self.buf
                    .chan_mut(0)
                    .copy_from_slice(&self.interleaved_scratch[out_start..out_end]);
            } else {
                let (left, right) = self.buf.chan_pair_mut(0, 1);
                let (pairs, _) =
                    self.interleaved_scratch[out_start * 2..out_end * 2].as_chunks::<2>();
                for (i, frame) in pairs.iter().enumerate() {
                    left[i] = frame[0];
                    right[i] = frame[1];
                }
            }
        }

        Ok(self.buf.as_audio_buffer_ref())
    }

    fn finalize(&mut self) -> FinalizeResult {
        FinalizeResult::default()
    }

    fn last_decoded(&self) -> AudioBufferRef<'_> {
        self.buf.as_audio_buffer_ref()
    }
}
