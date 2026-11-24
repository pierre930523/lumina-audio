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
use symphonia_core::errors::{Error as SymphoniaError, Result as SymphoniaResult, decode_error, unsupported_error};
use symphonia_core::formats::Packet;
use symphonia_core::support_codec;
use symphonia_core::units::TimeBase;

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
            self.remaining_pre_skip = if packet.ts() == 0 {
                self.pre_skip
            } else {
                0
            };
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
                let (pairs, _) = self.interleaved_scratch[out_start * 2..out_end * 2].as_chunks::<2>();
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;
    use std::io::Cursor;

    use opus2::{Application, Bitrate, Encoder};
    use symphonia_core::formats::FormatOptions;
    use symphonia_core::io::{MediaSourceStream, MediaSourceStreamOptions};
    use symphonia_core::meta::MetadataOptions;
    use symphonia_core::probe::Hint;

    fn make_opus_head(channels: u8, pre_skip: u16, gain_q8_db: i16) -> Vec<u8> {
        let mut head = Vec::with_capacity(19);
        head.extend_from_slice(b"OpusHead");
        head.push(1); // version
        head.push(channels);
        head.extend_from_slice(&pre_skip.to_le_bytes());
        head.extend_from_slice(&48_000u32.to_le_bytes());
        head.extend_from_slice(&gain_q8_db.to_le_bytes());
        head.push(0); // channel mapping family 0
        head
    }

    fn encode_sine_packets(channels: OpusChannels, packet_count: usize) -> Vec<Vec<u8>> {
        let mut encoder = Encoder::new(48_000, channels, Application::Audio).unwrap();
        let ch = channels as usize;
        let frame_size = 960; // 20 ms at 48 kHz
        let mut packets = Vec::with_capacity(packet_count);
        for p_idx in 0..packet_count {
            let mut pcm = Vec::with_capacity(frame_size * ch);
            for i in 0..frame_size {
                let sample_idx = p_idx * frame_size + i;
                let t = sample_idx as f32 / 48_000.0;
                let s = (2.0 * PI * 440.0 * t).sin() * 0.4;
                for _ in 0..ch {
                    pcm.push(s);
                }
            }
            let mut out = vec![0u8; 4000];
            let len = encoder.encode_float(&pcm, &mut out).unwrap();
            out.truncate(len);
            packets.push(out);
        }
        packets
    }

    fn ogg_crc32(data: &[u8]) -> u32 {
        let mut crc: u32 = 0;
        for &b in data {
            crc ^= (b as u32) << 24;
            for _ in 0..8 {
                if (crc & 0x8000_0000) != 0 {
                    crc = (crc << 1) ^ 0x04c1_1db7;
                } else {
                    crc <<= 1;
                }
            }
        }
        crc
    }

    fn build_ogg_page(
        header_type: u8,
        granule_pos: u64,
        serial: u32,
        seq: u32,
        payload: &[u8],
    ) -> Vec<u8> {
        let mut lacing = Vec::new();
        let mut rem = payload.len();
        while rem >= 255 {
            lacing.push(255u8);
            rem -= 255;
        }
        lacing.push(rem as u8);

        let mut page = Vec::with_capacity(27 + lacing.len() + payload.len());
        page.extend_from_slice(b"OggS");
        page.push(0);
        page.push(header_type);
        page.extend_from_slice(&granule_pos.to_le_bytes());
        page.extend_from_slice(&serial.to_le_bytes());
        page.extend_from_slice(&seq.to_le_bytes());
        page.extend_from_slice(&0u32.to_le_bytes());
        page.push(lacing.len() as u8);
        page.extend_from_slice(&lacing);
        page.extend_from_slice(payload);

        let crc = ogg_crc32(&page);
        page[22..26].copy_from_slice(&crc.to_le_bytes());
        page
    }

    #[test]
    fn test_opus_decoder_stereo_pre_skip_and_reset() {
        let mut registry = CodecRegistry::new();
        register_opus_codec(&mut registry);

        let extra = make_opus_head(2, 312, 0);
        let mut params = CodecParameters::new();
        params
            .for_codec(CODEC_TYPE_OPUS)
            .with_extra_data(extra.into_boxed_slice());

        let mut decoder = registry.make(&params, &DecoderOptions::default()).unwrap();
        assert_eq!(decoder.codec_params().sample_rate, Some(48_000));
        assert_eq!(
            decoder.codec_params().channels,
            Some(SymphoniaChannels::FRONT_LEFT | SymphoniaChannels::FRONT_RIGHT)
        );

        let packets = encode_sine_packets(OpusChannels::Stereo, 5);

        // First packet trims 312 pre-skip samples -> 960 - 312 = 648 frames.
        let pkt0 = Packet::new_from_slice(0, 0, 960, &packets[0]);
        let buf0 = decoder.decode(&pkt0).unwrap();
        assert_eq!(buf0.spec().rate, 48_000);
        assert_eq!(buf0.spec().channels.count(), 2);
        assert_eq!(buf0.frames(), 648);

        // Subsequent packets yield full 960 frames with audible signal energy.
        let pkt1 = Packet::new_from_slice(0, 960, 960, &packets[1]);
        let buf1 = decoder.decode(&pkt1).unwrap();
        assert_eq!(buf1.frames(), 960);
        match buf1 {
            AudioBufferRef::F32(f32_buf) => {
                let rms = (f32_buf.chan(0).iter().map(|&s| s * s).sum::<f32>()
                    / f32_buf.frames() as f32)
                    .sqrt();
                assert!(rms > 0.05, "Expected decoded 440Hz Opus RMS > 0.05, got {rms}");
            }
            _ => panic!("expected AudioBufferRef::F32"),
        }

        // Reset after seeking to non-zero timestamp does NOT re-skip pre_skip.
        decoder.reset();
        let pkt_seek = Packet::new_from_slice(0, 1920, 960, &packets[2]);
        let buf_seek = decoder.decode(&pkt_seek).unwrap();
        assert_eq!(buf_seek.frames(), 960);

        // Reset back to ts == 0 re-applies RFC 7845 pre_skip.
        decoder.reset();
        let pkt_restart = Packet::new_from_slice(0, 0, 960, &packets[0]);
        let buf_restart = decoder.decode(&pkt_restart).unwrap();
        assert_eq!(buf_restart.frames(), 648);

        // Decode error clears last_decoded buffer per Symphonia Decoder contract.
        let bad_pkt = Packet::new_from_slice(0, 2880, 960, &[]);
        assert!(decoder.decode(&bad_pkt).is_err());
        assert_eq!(decoder.last_decoded().frames(), 0);
    }

    #[test]
    fn test_opus_decoder_mono_and_ogg_container_end_to_end() {
        let mut registry = CodecRegistry::new();
        register_opus_codec(&mut registry);

        let opus_head = make_opus_head(1, 0, 0);
        let mut opus_tags = Vec::new();
        opus_tags.extend_from_slice(b"OpusTags");
        opus_tags.extend_from_slice(&6u32.to_le_bytes());
        opus_tags.extend_from_slice(b"Lumina");
        opus_tags.extend_from_slice(&0u32.to_le_bytes());

        let packets = encode_sine_packets(OpusChannels::Mono, 4);
        let mut ogg = Vec::new();
        ogg.extend_from_slice(&build_ogg_page(0x02, 0, 1, 0, &opus_head));
        ogg.extend_from_slice(&build_ogg_page(0x00, 0, 1, 1, &opus_tags));
        for (i, pkt) in packets.iter().enumerate() {
            let hdr_type = if i + 1 == packets.len() { 0x04 } else { 0x00 };
            let granule = ((i + 1) * 960) as u64;
            ogg.extend_from_slice(&build_ogg_page(hdr_type, granule, 1, (i + 2) as u32, pkt));
        }

        let mss = MediaSourceStream::new(Box::new(Cursor::new(ogg)), MediaSourceStreamOptions::default());
        let mut hint = Hint::new();
        hint.with_extension("ogg");
        let mut probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
            .unwrap();

        let track = probed.format.default_track().unwrap().clone();
        assert_eq!(track.codec_params.codec, CODEC_TYPE_OPUS);

        let mut decoder = registry
            .make(&track.codec_params, &DecoderOptions::default())
            .unwrap();

        let mut total_frames = 0usize;
        while let Ok(pkt) = probed.format.next_packet() {
            let buf = decoder.decode(&pkt).unwrap();
            assert_eq!(buf.spec().rate, 48_000);
            assert_eq!(buf.spec().channels.count(), 1);
            total_frames += buf.frames();
        }
        assert_eq!(total_frames, 4 * 960);
    }

    #[test]
    fn test_opus_decoder_rejects_invalid_headers() {
        let mut bad_sig = CodecParameters::new();
        bad_sig
            .for_codec(CODEC_TYPE_OPUS)
            .with_extra_data(Box::from(*b"BadHeader0123456789"));
        assert!(OpusSymphoniaDecoder::try_new(&bad_sig, &DecoderOptions::default()).is_err());

        let mut too_many_ch = CodecParameters::new();
        let mut head_6ch = make_opus_head(6, 0, 0);
        head_6ch[18] = 1;
        too_many_ch
            .for_codec(CODEC_TYPE_OPUS)
            .with_extra_data(head_6ch.into_boxed_slice());
        assert!(OpusSymphoniaDecoder::try_new(&too_many_ch, &DecoderOptions::default()).is_err());
    }

    fn snr_db(reference: &[f32], decoded: &[f32]) -> f64 {
        assert_eq!(reference.len(), decoded.len());
        let mut sig_power = 0.0f64;
        let mut err_power = 0.0f64;
        for (&r, &d) in reference.iter().zip(decoded.iter()) {
            let rf = f64::from(r);
            let df = f64::from(d);
            sig_power += rf * rf;
            let err = rf - df;
            err_power += err * err;
        }
        if err_power <= 1e-18 {
            return 180.0;
        }
        10.0 * (sig_power / err_power).log10()
    }

    fn encode_multitone_stereo_packets(
        packet_count: usize,
        bitrate_bps: i32,
        amplitude_scale: f32,
    ) -> (Vec<Vec<u8>>, u16, Vec<f32>, Vec<f32>) {
        let mut encoder = Encoder::new(48_000, OpusChannels::Stereo, Application::Audio).unwrap();
        encoder.set_bitrate(Bitrate::Bits(bitrate_bps)).unwrap();
        encoder.set_vbr(true).unwrap();
        let pre_skip = encoder.get_lookahead().unwrap() as u16;

        let frame_size = 960usize;
        let mut packets = Vec::with_capacity(packet_count);
        let mut ref_left = Vec::with_capacity(packet_count * frame_size);
        let mut ref_right = Vec::with_capacity(packet_count * frame_size);

        for p_idx in 0..packet_count {
            let mut pcm = Vec::with_capacity(frame_size * 2);
            for i in 0..frame_size {
                let t = (p_idx * frame_size + i) as f32 / 48_000.0;
                let l = amplitude_scale
                    * (0.35 * (2.0 * PI * 220.0 * t).sin()
                        + 0.25 * (2.0 * PI * 660.0 * t).sin()
                        + 0.20 * (2.0 * PI * 2_500.0 * t).sin()
                        + 0.12 * (2.0 * PI * 6_500.0 * t).sin());
                let r = amplitude_scale
                    * (0.30 * (2.0 * PI * 330.0 * t).sin()
                        + 0.25 * (2.0 * PI * 880.0 * t).sin()
                        + 0.20 * (2.0 * PI * 3_200.0 * t).sin()
                        + 0.12 * (2.0 * PI * 7_500.0 * t).sin());
                ref_left.push(l);
                ref_right.push(r);
                pcm.push(l);
                pcm.push(r);
            }
            let mut out = vec![0u8; 4000];
            let len = encoder.encode_float(&pcm, &mut out).unwrap();
            out.truncate(len);
            packets.push(out);
        }

        (packets, pre_skip, ref_left, ref_right)
    }

    fn make_test_decoder(channels: u8, pre_skip: u16, gain_q8_db: i16) -> OpusSymphoniaDecoder {
        let extra = make_opus_head(channels, pre_skip, gain_q8_db);
        let mut params = CodecParameters::new();
        params
            .for_codec(CODEC_TYPE_OPUS)
            .with_extra_data(extra.into_boxed_slice());
        OpusSymphoniaDecoder::try_new(&params, &DecoderOptions::default()).unwrap()
    }

    #[test]
    fn test_opus_decoder_stereo_160kbps_vbr_complex_multitone_parity() {
        let frame_size = 960usize;
        let (packets, pre_skip, ref_left, ref_right) =
            encode_multitone_stereo_packets(100, 160_000, 1.0);
        let mut decoder = make_test_decoder(2, pre_skip, 0);

        let mut decoded_left = Vec::with_capacity(ref_left.len());
        let mut decoded_right = Vec::with_capacity(ref_right.len());

        for (idx, pkt_bytes) in packets.iter().enumerate() {
            let ts = (idx * frame_size) as u64;
            let pkt = Packet::new_from_slice(0, ts, frame_size as u64, pkt_bytes);
            let buf = decoder.decode(&pkt).unwrap();
            let expected_frames = if idx == 0 {
                frame_size - usize::from(pre_skip)
            } else {
                frame_size
            };
            assert_eq!(buf.frames(), expected_frames);
            match buf {
                AudioBufferRef::F32(f32_buf) => {
                    let l = f32_buf.chan(0);
                    let r = f32_buf.chan(1);
                    assert!(l.iter().all(|s| s.is_finite()));
                    assert!(r.iter().all(|s| s.is_finite()));
                    decoded_left.extend_from_slice(l);
                    decoded_right.extend_from_slice(r);
                }
                _ => panic!("expected AudioBufferRef::F32"),
            }
        }

        let left_snr = snr_db(&ref_left[..decoded_left.len()], &decoded_left);
        let right_snr = snr_db(&ref_right[..decoded_right.len()], &decoded_right);
        assert!(
            left_snr > 25.0,
            "Expected stereo L 160 kbps VBR SNR > 25 dB, got {left_snr:.2} dB"
        );
        assert!(
            right_snr > 25.0,
            "Expected stereo R 160 kbps VBR SNR > 25 dB, got {right_snr:.2} dB"
        );
    }

    #[test]
    fn test_opus_decoder_output_gain_exceeds_zero_dbfs_as_finite_f32() {
        let frame_size = 960usize;
        let (packets, pre_skip, _, _) = encode_multitone_stereo_packets(12, 160_000, 0.95);
        let mut dec_flat = make_test_decoder(2, pre_skip, 0);
        // +6.0 dB in Q8 format -> linear gain ~1.995, pushing 0.87 peak above 1.0 (0 dBFS).
        let mut dec_boost = make_test_decoder(2, pre_skip, 6 * 256);

        let mut flat_samples = Vec::new();
        let mut boost_samples = Vec::new();

        for (idx, pkt_bytes) in packets.iter().enumerate() {
            let pkt = Packet::new_from_slice(0, (idx * frame_size) as u64, frame_size as u64, pkt_bytes);
            if let AudioBufferRef::F32(b) = dec_flat.decode(&pkt).unwrap() {
                flat_samples.extend_from_slice(b.chan(0));
            }
            if let AudioBufferRef::F32(b) = dec_boost.decode(&pkt).unwrap() {
                let ch0 = b.chan(0);
                let ch1 = b.chan(1);
                assert!(ch0.iter().all(|s| s.is_finite()));
                assert!(ch1.iter().all(|s| s.is_finite()));
                boost_samples.extend_from_slice(ch0);
            }
        }

        let boost_peak = boost_samples.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
        assert!(
            boost_peak > 1.2,
            "Expected +6 dB output gain peak > 1.2 (above 0 dBFS without clipping), got {boost_peak}"
        );

        let flat_rms =
            (flat_samples.iter().map(|&s| s * s).sum::<f32>() / flat_samples.len() as f32).sqrt();
        let boost_rms =
            (boost_samples.iter().map(|&s| s * s).sum::<f32>() / boost_samples.len() as f32).sqrt();
        let ratio = boost_rms / flat_rms;
        assert!(
            (1.9..=2.1).contains(&ratio),
            "Expected +6 dB gain RMS ratio near 1.995, got {ratio:.3}"
        );
    }

    #[test]
    fn test_opus_decoder_midstream_reset_yields_clean_post_seek_decode() {
        let frame_size = 960usize;
        let (packets, pre_skip, ref_left, ref_right) =
            encode_multitone_stereo_packets(40, 160_000, 1.0);
        let mut decoder = make_test_decoder(2, pre_skip, 0);

        // Decode initial packets before seeking.
        for (idx, pkt_bytes) in packets[..8].iter().enumerate() {
            let pkt = Packet::new_from_slice(0, (idx * frame_size) as u64, frame_size as u64, pkt_bytes);
            let _ = decoder.decode(&pkt).unwrap();
        }

        // Simulate mid-stream seek: reset decoder state and jump to non-zero packet timestamp.
        decoder.reset();
        assert_eq!(decoder.last_decoded().frames(), 0);

        let seek_idx = 12usize;
        // RFC 7845 / WebM SeekPreRoll = 80 ms (4 x 20 ms Opus packets) for CELT state convergence.
        let preroll_packets = 4usize;
        let mut post_seek_left = Vec::new();
        let mut post_seek_right = Vec::new();
        for (offset, pkt_bytes) in packets[seek_idx..].iter().enumerate() {
            let idx = seek_idx + offset;
            let pkt = Packet::new_from_slice(0, (idx * frame_size) as u64, frame_size as u64, pkt_bytes);
            let buf = decoder.decode(&pkt).unwrap();
            assert_eq!(buf.frames(), frame_size);
            match buf {
                AudioBufferRef::F32(f32_buf) => {
                    let l = f32_buf.chan(0);
                    let r = f32_buf.chan(1);
                    assert!(l.iter().all(|s| s.is_finite() && s.abs() <= 1.25));
                    assert!(r.iter().all(|s| s.is_finite() && s.abs() <= 1.25));
                    if offset >= preroll_packets {
                        post_seek_left.extend_from_slice(l);
                        post_seek_right.extend_from_slice(r);
                    }
                }
                _ => panic!("expected AudioBufferRef::F32"),
            }
        }

        // After the 80 ms WebM/RFC 7845 SeekPreRoll, post-seek PCM converges cleanly to reference
        // (shifted by encoder lookahead `pre_skip` since non-zero seek does not trim pre_skip).
        let ref_start = (seek_idx + preroll_packets) * frame_size - usize::from(pre_skip);
        let ref_end = ref_start + post_seek_left.len();
        let snr_l = snr_db(&ref_left[ref_start..ref_end], &post_seek_left);
        let snr_r = snr_db(&ref_right[ref_start..ref_end], &post_seek_right);
        assert!(snr_l > 25.0, "Expected clean post-seek L SNR > 25 dB, got {snr_l:.2} dB");
        assert!(snr_r > 25.0, "Expected clean post-seek R SNR > 25 dB, got {snr_r:.2} dB");
    }
}
