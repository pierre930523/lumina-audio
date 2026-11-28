use crate::error::DsdError;

/// Encapsulates 16-bit DSD payload into 24-bit PCM container with alternating 0x05 / 0xFA marker bytes
/// in compliance with the DSD over PCM (DoP) Standard v1.1.
///
/// ## Cross-Chunk Buffering & M2.3 Integration
/// DoP v1.1 packs 2 DSD bytes per channel per PCM frame. When an odd number of bytes per channel
/// is delivered at a chunk boundary or after an unaligned DSDIFF seek, [`DopFramer::pack_dsd_to_wire_le`]
/// retains the trailing `< channels * 2` MSB-normalized bytes in `pending_bytes` instead of
/// dropping them, and consumes them at the start of the next chunk.
///
/// Callers in M2.3 (`verification/mod.rs::pack_chunk_to_wire_bytes` and `player.rs::decode_wire_loop`)
/// should route DoP chunk packing through `pack_dsd_to_wire_le` and invoke `dop_framer.reset()` on
/// every seek (optionally emitting `generate_silence_preroll_bytes`) so both `marker_phase` and
/// `pending_bytes` are cleared before decoding from the new seek target.
#[derive(Debug, Clone)]
pub struct DopFramer {
    marker_phase: bool,
    pending_bytes: Vec<u8>,
}

impl Default for DopFramer {
    fn default() -> Self {
        Self::new()
    }
}

impl DopFramer {
    pub const MARKER_EVEN: u8 = 0x05;
    pub const MARKER_ODD: u8 = 0xFA;

    pub fn new() -> Self {
        Self {
            marker_phase: false,
            pending_bytes: Vec::new(),
        }
    }

    pub fn reset(&mut self) {
        self.marker_phase = false;
        self.pending_bytes.clear();
    }

    /// Number of buffered MSB-normalized trailing DSD bytes awaiting completion of the next DoP frame.
    pub fn pending_byte_count(&self) -> usize {
        self.pending_bytes.len()
    }

    #[inline]
    pub fn next_marker(&mut self) -> u8 {
        let m = if self.marker_phase {
            Self::MARKER_ODD
        } else {
            Self::MARKER_EVEN
        };
        self.marker_phase = !self.marker_phase;
        m
    }

    /// Packs a stereo 16-bit DSD frame (2 bytes L, 2 bytes R) into a 32-bit integer PCM frame.
    /// In MSB-aligned 24-in-32 format: [Marker (8), DSD0 (8), DSD1 (8), 0 (8)]
    #[inline]
    pub fn frame_stereo_i32(
        &mut self,
        left_dsd: (u8, u8),
        right_dsd: (u8, u8),
        source_is_lsb_first: bool,
    ) -> (i32, i32) {
        let marker = self.next_marker() as i32;

        let (l0, l1) = if source_is_lsb_first {
            (
                left_dsd.0.reverse_bits() as i32,
                left_dsd.1.reverse_bits() as i32,
            )
        } else {
            (left_dsd.0 as i32, left_dsd.1 as i32)
        };

        let (r0, r1) = if source_is_lsb_first {
            (
                right_dsd.0.reverse_bits() as i32,
                right_dsd.1.reverse_bits() as i32,
            )
        } else {
            (right_dsd.0 as i32, right_dsd.1 as i32)
        };

        let left_sample = (marker << 24) | (l0 << 16) | (l1 << 8);
        let right_sample = (marker << 24) | (r0 << 16) | (r1 << 8);

        (left_sample, right_sample)
    }

    /// Packs a stereo 16-bit DSD frame into 24-bit PCM integer containers (bits 23..0).
    #[inline]
    pub fn frame_stereo_24bit(
        &mut self,
        left_dsd: (u8, u8),
        right_dsd: (u8, u8),
        source_is_lsb_first: bool,
    ) -> (i32, i32) {
        let marker = self.next_marker() as i32;

        let (l0, l1) = if source_is_lsb_first {
            (
                left_dsd.0.reverse_bits() as i32,
                left_dsd.1.reverse_bits() as i32,
            )
        } else {
            (left_dsd.0 as i32, left_dsd.1 as i32)
        };

        let (r0, r1) = if source_is_lsb_first {
            (
                right_dsd.0.reverse_bits() as i32,
                right_dsd.1.reverse_bits() as i32,
            )
        } else {
            (right_dsd.0 as i32, right_dsd.1 as i32)
        };

        let left_sample = (marker << 16) | (l0 << 8) | l1;
        let right_sample = (marker << 16) | (r0 << 8) | r1;

        (left_sample, right_sample)
    }

    /// Unframes 24-in-32 bit PCM samples back to raw 16-bit DSD payload words per channel.
    /// Validates DoP marker sequence (0x05 / 0xFA alternating).
    pub fn unframe_stereo_i32(
        &mut self,
        left_pcm: i32,
        right_pcm: i32,
    ) -> Result<(u16, u16), DsdError> {
        let expected_marker = if self.marker_phase {
            Self::MARKER_ODD
        } else {
            Self::MARKER_EVEN
        };

        let left_marker = ((left_pcm >> 24) & 0xFF) as u8;
        let right_marker = ((right_pcm >> 24) & 0xFF) as u8;

        if left_marker != expected_marker {
            return Err(DsdError::InvalidDopMarker(left_marker));
        }
        if right_marker != expected_marker {
            return Err(DsdError::InvalidDopMarker(right_marker));
        }

        self.marker_phase = !self.marker_phase;

        let left_dsd = (((left_pcm >> 16) & 0xFF) as u16) << 8 | (((left_pcm >> 8) & 0xFF) as u16);
        let right_dsd =
            (((right_pcm >> 16) & 0xFF) as u16) << 8 | (((right_pcm >> 8) & 0xFF) as u16);

        Ok((left_dsd, right_dsd))
    }

    /// Generates pre-roll silence frames (0x69 pattern) to prime the DAC's DoP detector.
    pub fn generate_silence_preroll(frames: usize) -> Vec<i32> {
        let mut framer = Self::new();
        let mut buffer = Vec::with_capacity(frames * 2);
        for _ in 0..frames {
            let (l, r) = framer.frame_stereo_i32((0x69, 0x69), (0x69, 0x69), false);
            buffer.push(l);
            buffer.push(r);
        }
        buffer
    }

    /// Generates `frames` of DoP-encapsulated DSD silence (`0x69`) as little-endian
    /// 24-in-32 wire bytes while advancing `self.marker_phase` continuously.
    pub fn generate_silence_preroll_bytes(&mut self, channels: u16, frames: usize) -> Vec<u8> {
        let ch = (channels as usize).max(1);
        let mut out = Vec::with_capacity(frames * ch * 4);
        for _ in 0..frames {
            let marker = self.next_marker() as i32;
            let sample = (marker << 24) | (0x69i32 << 16) | (0x69i32 << 8);
            let bytes = sample.to_le_bytes();
            for _ in 0..ch {
                out.extend_from_slice(&bytes);
            }
        }
        out
    }

    /// Packs byte-interleaved DSD data into DoP v1.1 24-in-32 little-endian wire bytes,
    /// buffering any odd trailing bytes (`< channels * 2`) across chunk boundaries in
    /// `self.pending_bytes` rather than silently dropping them.
    pub fn pack_dsd_to_wire_le(
        &mut self,
        bytes: &[u8],
        channels: u16,
        is_lsb_first: bool,
        out: &mut Vec<u8>,
    ) {
        let ch = (channels as usize).max(1);
        let step = ch * 2;
        let normalize = |b: u8| if is_lsb_first { b.reverse_bits() } else { b };

        let mut rem = bytes;
        if !self.pending_bytes.is_empty() {
            if self.pending_bytes.len() > step {
                // Defensive guard if channel count shrunk between calls without reset()
                self.pending_bytes.clear();
            } else {
                let need = step - self.pending_bytes.len();
                let take = need.min(rem.len());
                self.pending_bytes
                    .extend(rem[..take].iter().copied().map(normalize));
                rem = &rem[take..];

                if self.pending_bytes.len() == step {
                    if ch == 2 {
                        let (l_pcm, r_pcm) = self.frame_stereo_i32(
                            (self.pending_bytes[0], self.pending_bytes[2]),
                            (self.pending_bytes[1], self.pending_bytes[3]),
                            false,
                        );
                        out.extend_from_slice(&l_pcm.to_le_bytes());
                        out.extend_from_slice(&r_pcm.to_le_bytes());
                    } else {
                        let marker = self.next_marker() as i32;
                        for c in 0..ch {
                            let b0 = self.pending_bytes[c];
                            let b1 = self.pending_bytes[ch + c];
                            let sample = (marker << 24) | ((b0 as i32) << 16) | ((b1 as i32) << 8);
                            out.extend_from_slice(&sample.to_le_bytes());
                        }
                    }
                    self.pending_bytes.clear();
                } else {
                    return;
                }
            }
        }

        let groups = rem.len() / step;
        if ch == 2 {
            out.reserve(groups * 8);
            for g in 0..groups {
                let base = g * 4;
                let (l_pcm, r_pcm) = self.frame_stereo_i32(
                    (rem[base], rem[base + 2]),
                    (rem[base + 1], rem[base + 3]),
                    is_lsb_first,
                );
                out.extend_from_slice(&l_pcm.to_le_bytes());
                out.extend_from_slice(&r_pcm.to_le_bytes());
            }
        } else {
            out.reserve(groups * ch * 4);
            for g in 0..groups {
                let marker = self.next_marker() as i32;
                let base = g * step;
                for c in 0..ch {
                    let b0 = normalize(rem[base + c]);
                    let b1 = normalize(rem[base + ch + c]);
                    let sample = (marker << 24) | ((b0 as i32) << 16) | ((b1 as i32) << 8);
                    out.extend_from_slice(&sample.to_le_bytes());
                }
            }
        }

        let tail = &rem[groups * step..];
        if !tail.is_empty() {
            self.pending_bytes
                .extend(tail.iter().copied().map(normalize));
        }
    }
}
