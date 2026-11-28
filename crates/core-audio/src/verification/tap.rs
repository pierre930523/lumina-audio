use std::collections::VecDeque;

use sha2::{Digest, Sha256};

use super::analyzer::VerificationConfig;
use super::wire_format::WireSampleFormat;
use super::wire_unpack::unpack_wire_bytes_to_chunk;
use crate::buffer::{Consumer, Producer, RingBufferControl};
use crate::dsd::DopFramer;
use crate::pcm::AudioChunk;

/// Lock-free, zero-allocation Stage 3 wire tap producer used inside real-time audio callbacks.
pub struct VerificationTapProducer {
    pub(super) producer: Producer<u8>,
    pub(super) bytes_per_frame: usize,
}

impl VerificationTapProducer {
    /// Wait-free, zero-allocation, zero-lock push of frame-aligned hardware wire bytes
    /// into the verification SPSC ring buffer.
    #[inline]
    pub fn push_wire(&mut self, wire_bytes: &[u8]) {
        if wire_bytes.is_empty() || self.bytes_per_frame == 0 {
            return;
        }
        if self.producer.has_pending_flush() {
            self.producer.sync_epoch();
        }
        let aligned_len = (wire_bytes.len() / self.bytes_per_frame) * self.bytes_per_frame;
        if aligned_len == 0 {
            return;
        }
        let free = self.producer.available_write();
        let aligned_free = (free / self.bytes_per_frame) * self.bytes_per_frame;
        let to_write = aligned_len.min(aligned_free);
        if to_write > 0 {
            let _ = self.producer.push_slice(&wire_bytes[..to_write]);
        }
    }
}

pub(super) struct RtWireTapConsumer {
    pub(super) consumer: Consumer<u8>,
    pub(super) control: RingBufferControl,
    pub(super) wire: WireSampleFormat,
    pub(super) channels: u16,
    pub(super) sample_rate: u32,
    pub(super) bytes_per_frame: usize,
    pub(super) drain_scratch: Vec<u8>,
}

pub(super) struct VerificationInner {
    pub(super) decoder_sha: Sha256,
    pub(super) processing_sha: Sha256,
    pub(super) backend_sha: Sha256,
    pub(super) pending_decoder_bytes: VecDeque<u8>,
    pub(super) pending_processing_bytes: VecDeque<u8>,
    pub(super) dop_unframer: DopFramer,
    pub(super) frames_verified: u64,
    pub(super) mismatched_samples: u64,
    pub(super) first_mismatch_detail: Option<String>,
    pub(super) config: VerificationConfig,
    pub(super) source_title: Option<String>,
    pub(super) source_artist: Option<String>,
    pub(super) source_album: Option<String>,
    pub(super) rt_tap: Option<RtWireTapConsumer>,
}

pub(super) fn ingest_backend_wire_locked(
    g: &mut VerificationInner,
    raw_bytes: &[u8],
    wire: WireSampleFormat,
    channels: u16,
    sample_rate: u32,
) {
    if raw_bytes.is_empty() {
        return;
    }
    let mut unpacked = match wire {
        WireSampleFormat::Dop24In32MsbLe { .. } => {
            let mut tmp = g.dop_unframer.clone();
            let res =
                unpack_wire_bytes_to_chunk(raw_bytes, wire, channels, sample_rate, Some(&mut tmp));
            g.dop_unframer = tmp;
            res
        }
        _ => unpack_wire_bytes_to_chunk(raw_bytes, wire, channels, sample_rate, None),
    };

    match &mut unpacked {
        Ok(chunk) => {
            // Normalize 16-bit/24-bit promoted into larger containers back to logical source
            // values so SHA-256 compares logical sample integers accurately.
            let src_bits = g.config.source_format.valid_bits;
            let norm_chunk = match (src_bits, chunk) {
                (
                    16,
                    AudioChunk::PcmI24In32 {
                        samples,
                        channels,
                        sample_rate,
                    },
                ) => AudioChunk::PcmI16 {
                    samples: samples.iter().map(|&s| (s >> 8) as i16).collect(),
                    channels: *channels,
                    sample_rate: *sample_rate,
                },
                (
                    16,
                    AudioChunk::PcmI32 {
                        samples,
                        channels,
                        sample_rate,
                    },
                ) => AudioChunk::PcmI16 {
                    samples: samples.iter().map(|&s| (s >> 16) as i16).collect(),
                    channels: *channels,
                    sample_rate: *sample_rate,
                },
                (
                    24,
                    AudioChunk::PcmI32 {
                        samples,
                        channels,
                        sample_rate,
                    },
                ) => AudioChunk::PcmI24In32 {
                    samples: samples.iter().map(|&s| s >> 8).collect(),
                    channels: *channels,
                    sample_rate: *sample_rate,
                },
                (_, c) => c.clone(),
            };

            let mut back_bytes = Vec::new();
            norm_chunk.append_canonical_le_bytes(&mut back_bytes);
            g.backend_sha.update(&back_bytes);
            g.frames_verified += norm_chunk.frames() as u64;

            let n = back_bytes.len();
            if g.pending_processing_bytes.len() >= n {
                let proc_slice: Vec<u8> = g.pending_processing_bytes.drain(..n).collect();
                g.processing_sha.update(&proc_slice);
            } else if !g.pending_processing_bytes.is_empty() {
                let proc_slice: Vec<u8> = g.pending_processing_bytes.drain(..).collect();
                g.processing_sha.update(&proc_slice);
            }

            if g.pending_decoder_bytes.len() >= n {
                let dec_slice: Vec<u8> = g.pending_decoder_bytes.drain(..n).collect();
                g.decoder_sha.update(&dec_slice);
                if dec_slice != back_bytes {
                    g.mismatched_samples += 1;
                    if g.first_mismatch_detail.is_none() {
                        g.first_mismatch_detail = Some(format!(
                            "Sample bytes differ over {n}-byte block at verified frame {}",
                            g.frames_verified
                        ));
                    }
                }
            } else if !g.pending_decoder_bytes.is_empty() {
                // Resampled / altered sample rate means byte lengths don't track 1:1
                let dec_slice: Vec<u8> = g.pending_decoder_bytes.drain(..).collect();
                g.decoder_sha.update(&dec_slice);
            }
        }
        Err(err) => {
            g.mismatched_samples += 1;
            if g.first_mismatch_detail.is_none() {
                g.first_mismatch_detail = Some(err.clone());
            }
        }
    }
}

pub(super) fn drain_rt_tap_locked(g: &mut VerificationInner) {
    let Some(mut tap) = g.rt_tap.take() else {
        return;
    };
    let bpf = tap.bytes_per_frame.max(1);
    let max_pop = (tap.drain_scratch.len() / bpf) * bpf;
    if max_pop > 0 {
        loop {
            let avail = tap.consumer.available_read();
            if avail < bpf {
                break;
            }
            let want = ((avail.min(max_pop)) / bpf) * bpf;
            if want == 0 {
                break;
            }
            let got = tap.consumer.pop_slice(&mut tap.drain_scratch[..want]);
            let aligned = (got / bpf) * bpf;
            if aligned == 0 {
                break;
            }
            ingest_backend_wire_locked(
                g,
                &tap.drain_scratch[..aligned],
                tap.wire,
                tap.channels,
                tap.sample_rate,
            );
        }
    }
    g.rt_tap = Some(tap);
}
