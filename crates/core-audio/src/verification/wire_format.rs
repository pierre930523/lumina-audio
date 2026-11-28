use crate::dsd::DopFramer;
use crate::pcm::AudioChunk;

/// Wire / hardware container format fed directly to the output backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireSampleFormat {
    Int16Le,
    Int24PackedLe,
    /// Sign-aligned 24-bit integer stored in top 24 bits of 32-bit container (`sample << 8`).
    Int24In32MsbLe,
    Int32Le,
    Float32Le,
    Float64Le,
    /// DoP v1.1 24-bit in 32-bit MSB-aligned frames (`[Marker, DSD0, DSD1, 0]`).
    Dop24In32MsbLe {
        channels: u16,
        is_lsb_first: bool,
    },
    /// Native raw 1-bit packed DSD bytes `[L0, R0, ...]`.
    NativeDsd {
        channels: u16,
    },
}

impl WireSampleFormat {
    pub const fn bytes_per_sample(self) -> usize {
        match self {
            Self::Int16Le => 2,
            Self::Int24PackedLe => 3,
            Self::Int24In32MsbLe
            | Self::Int32Le
            | Self::Float32Le
            | Self::Dop24In32MsbLe { .. } => 4,
            Self::Float64Le => 8,
            Self::NativeDsd { .. } => 1,
        }
    }

    pub const fn container_bits(self) -> u8 {
        match self {
            Self::Int16Le => 16,
            Self::Int24PackedLe => 24,
            Self::Int24In32MsbLe
            | Self::Int32Le
            | Self::Float32Le
            | Self::Dop24In32MsbLe { .. } => 32,
            Self::Float64Le => 64,
            Self::NativeDsd { .. } => 8,
        }
    }

    pub const fn valid_bits(self) -> u8 {
        match self {
            Self::Int16Le => 16,
            Self::Int24PackedLe | Self::Int24In32MsbLe | Self::Dop24In32MsbLe { .. } => 24,
            Self::Int32Le | Self::Float32Le => 32,
            Self::Float64Le => 64,
            Self::NativeDsd { .. } => 1,
        }
    }

    pub const fn wire_tag(self) -> u8 {
        match self {
            Self::Int16Le => 1,
            Self::Int24PackedLe => 2,
            Self::Int24In32MsbLe => 3,
            Self::Int32Le => 4,
            Self::Float32Le => 5,
            Self::Float64Le => 6,
            Self::Dop24In32MsbLe { .. } => 7,
            Self::NativeDsd { .. } => 8,
        }
    }
}

/// Bit-packed 64-bit hardware wire format stamp shared via `AtomicU64` between the decode/control
/// layer and real-time WASAPI Exclusive / ASIO callbacks to prevent raw PCM format mismatches.
///
/// Layout (LSB -> MSB):
/// - bits `0..32`  (`u32`): `sample_rate`
/// - bits `32..40` (`u8`):  `channels`
/// - bits `40..48` (`u8`):  `wire_tag`
/// - bits `48..56` (`u8`):  `valid_bits`
/// - bits `56..64` (`u8`):  `flags`
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct WireFormatStamp(pub u64);

impl WireFormatStamp {
    pub const FLAG_DOP: u8 = 1 << 0;
    pub const FLAG_NATIVE_DSD: u8 = 1 << 1;

    #[inline]
    pub const fn pack(
        sample_rate: u32,
        channels: u8,
        wire_tag: u8,
        valid_bits: u8,
        flags: u8,
    ) -> Self {
        let bits = (sample_rate as u64)
            | ((channels as u64) << 32)
            | ((wire_tag as u64) << 40)
            | ((valid_bits as u64) << 48)
            | ((flags as u64) << 56);
        Self(bits)
    }

    #[inline]
    pub const fn from_wire(sample_rate: u32, channels: u16, wire: WireSampleFormat) -> Self {
        let flags = match wire {
            WireSampleFormat::Dop24In32MsbLe { .. } => Self::FLAG_DOP,
            WireSampleFormat::NativeDsd { .. } => Self::FLAG_NATIVE_DSD,
            _ => 0,
        };
        let ch = if channels > u8::MAX as u16 {
            u8::MAX
        } else {
            channels as u8
        };
        Self::pack(sample_rate, ch, wire.wire_tag(), wire.valid_bits(), flags)
    }

    #[inline]
    pub const fn matches(self, other: Self) -> bool {
        self.0 != 0 && self.0 == other.0
    }

    #[inline]
    pub const fn sample_rate(self) -> u32 {
        (self.0 & 0xFFFF_FFFF) as u32
    }

    #[inline]
    pub const fn channels(self) -> u8 {
        ((self.0 >> 32) & 0xFF) as u8
    }

    #[inline]
    pub const fn wire_tag(self) -> u8 {
        ((self.0 >> 40) & 0xFF) as u8
    }

    #[inline]
    pub const fn valid_bits(self) -> u8 {
        ((self.0 >> 48) & 0xFF) as u8
    }

    #[inline]
    pub const fn flags(self) -> u8 {
        ((self.0 >> 56) & 0xFF) as u8
    }

    #[inline]
    pub const fn raw(self) -> u64 {
        self.0
    }
}

const fn build_bit_reverse_lut() -> [u8; 256] {
    let mut lut = [0u8; 256];
    let mut i = 0usize;
    while i < 256 {
        lut[i] = (i as u8).reverse_bits();
        i += 1;
    }
    lut
}

/// Compile-time 256-entry bit-reversal LUT for zero-branch Native DSD bit-order conversion
/// (DSF LSB-first <-> DSDIFF/ASIO MSB-first).
pub const BIT_REVERSE_LUT: [u8; 256] = build_bit_reverse_lut();

/// Appends Native DSD bitstream bytes into `out`, applying [`BIT_REVERSE_LUT`] only when
/// `source_is_lsb_first != target_is_lsb_first`.
#[inline]
pub fn pack_native_dsd_bytes_into(
    bytes: &[u8],
    source_is_lsb_first: bool,
    target_is_lsb_first: bool,
    out: &mut Vec<u8>,
) {
    if source_is_lsb_first == target_is_lsb_first {
        out.extend_from_slice(bytes);
    } else {
        out.reserve(bytes.len());
        for &b in bytes {
            out.push(BIT_REVERSE_LUT[b as usize]);
        }
    }
}

/// Converts a logical [`AudioChunk`] verbatim into hardware wire bytes appended into `out`,
/// reusing `out`'s existing capacity (zero heap allocation once warmed up).
///
/// - For [`WireSampleFormat::Dop24In32MsbLe`], routes through [`DopFramer::pack_dsd_to_wire_le`]
///   so odd trailing DSD bytes across chunk boundaries are carried cleanly in `dop_framer` instead
///   of being silently dropped.
/// - For [`WireSampleFormat::NativeDsd`], copies bytes verbatim when `native_dsd_target_lsb_first`
///   is `None` or matches `chunk.is_lsb_first`, and bit-reverses via [`BIT_REVERSE_LUT`] when the
///   target hardware bit order differs from the source container (`DSF` LSB-first vs `DSDIFF` MSB-first).
pub fn pack_chunk_to_wire_bytes_with_dsd_order_into(
    chunk: &AudioChunk,
    wire: WireSampleFormat,
    dop_framer: Option<&mut DopFramer>,
    native_dsd_target_lsb_first: Option<bool>,
    out: &mut Vec<u8>,
) {
    out.clear();
    match (chunk, wire) {
        (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int16Le) => {
            out.reserve(samples.len() * 2);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
        }
        // Bit-exact promotion of 16-bit integer into higher integer containers (left-aligned, zero-padded LSBs)
        (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int24In32MsbLe)
        | (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int32Le) => {
            out.reserve(samples.len() * 4);
            for &s in samples {
                out.extend_from_slice(&((s as i32) << 16).to_le_bytes());
            }
        }
        (AudioChunk::PcmI16 { samples, .. }, WireSampleFormat::Int24PackedLe) => {
            out.reserve(samples.len() * 3);
            for &s in samples {
                let shifted = (s as i32) << 8;
                out.extend_from_slice(&shifted.to_le_bytes()[0..3]);
            }
        }
        (AudioChunk::PcmI24In32 { samples, .. }, WireSampleFormat::Int24In32MsbLe)
        | (AudioChunk::PcmI24In32 { samples, .. }, WireSampleFormat::Int32Le) => {
            out.reserve(samples.len() * 4);
            for &s in samples {
                // `s` is sign-extended 24-bit integer; place in top 24 bits (`s << 8`)
                out.extend_from_slice(&(s << 8).to_le_bytes());
            }
        }
        (AudioChunk::PcmI24In32 { samples, .. }, WireSampleFormat::Int24PackedLe) => {
            out.reserve(samples.len() * 3);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes()[0..3]);
            }
        }
        (AudioChunk::PcmI32 { samples, .. }, WireSampleFormat::Int32Le) => {
            out.reserve(samples.len() * 4);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
        }
        (AudioChunk::PcmF32 { samples, .. }, WireSampleFormat::Float32Le) => {
            out.reserve(samples.len() * 4);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
        }
        (AudioChunk::PcmF64 { samples, .. }, WireSampleFormat::Float64Le) => {
            out.reserve(samples.len() * 8);
            for &s in samples {
                out.extend_from_slice(&s.to_le_bytes());
            }
        }
        (
            AudioChunk::DsdBitstream {
                bytes,
                channels,
                is_lsb_first,
                ..
            },
            WireSampleFormat::Dop24In32MsbLe { .. },
        ) => {
            if let Some(framer) = dop_framer {
                framer.pack_dsd_to_wire_le(bytes, *channels, *is_lsb_first, out);
            }
        }
        (
            AudioChunk::DsdBitstream {
                bytes,
                is_lsb_first,
                ..
            },
            WireSampleFormat::NativeDsd { .. },
        ) => {
            let target_lsb = native_dsd_target_lsb_first.unwrap_or(*is_lsb_first);
            pack_native_dsd_bytes_into(bytes, *is_lsb_first, target_lsb, out);
        }
        // Fallback through normalized float when DSP or sample format conversion is active
        (chunk, WireSampleFormat::Float32Le) => {
            let floats = chunk.to_f32_interleaved();
            out.reserve(floats.len() * 4);
            for s in floats {
                out.extend_from_slice(&s.to_le_bytes());
            }
        }
        (chunk, WireSampleFormat::Float64Le) => {
            let floats = chunk.to_f64_interleaved();
            out.reserve(floats.len() * 8);
            for s in floats {
                out.extend_from_slice(&s.to_le_bytes());
            }
        }
        (chunk, WireSampleFormat::Int16Le) => {
            let floats = chunk.to_f64_interleaved();
            out.reserve(floats.len() * 2);
            for s in floats {
                let q = (s.clamp(-1.0, 0.999969482421875) * 32768.0).round() as i16;
                out.extend_from_slice(&q.to_le_bytes());
            }
        }
        (chunk, WireSampleFormat::Int24PackedLe) => {
            let floats = chunk.to_f64_interleaved();
            out.reserve(floats.len() * 3);
            for s in floats {
                let q = (s.clamp(-1.0, 0.99999988) * 8_388_608.0).round() as i32;
                out.extend_from_slice(&q.clamp(-8_388_608, 8_388_607).to_le_bytes()[0..3]);
            }
        }
        (chunk, WireSampleFormat::Int24In32MsbLe) => {
            let floats = chunk.to_f64_interleaved();
            out.reserve(floats.len() * 4);
            for s in floats {
                let q = (s.clamp(-1.0, 0.99999988) * 8_388_608.0).round() as i32;
                let word = q.clamp(-8_388_608, 8_388_607) << 8;
                out.extend_from_slice(&word.to_le_bytes());
            }
        }
        (chunk, WireSampleFormat::Int32Le) => {
            let floats = chunk.to_f64_interleaved();
            out.reserve(floats.len() * 4);
            for s in floats {
                let q = (s.clamp(-1.0, 0.9999999995) * 2_147_483_648.0).round() as i64;
                let clamped = q.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                out.extend_from_slice(&clamped.to_le_bytes());
            }
        }
        _ => {}
    }
}

/// Appends packed hardware wire bytes for `chunk` into `out` (reusing `out`'s capacity).
pub fn pack_chunk_to_wire_bytes_into(
    chunk: &AudioChunk,
    wire: WireSampleFormat,
    dop_framer: Option<&mut DopFramer>,
    out: &mut Vec<u8>,
) {
    pack_chunk_to_wire_bytes_with_dsd_order_into(chunk, wire, dop_framer, None, out);
}

/// Converts a logical [`AudioChunk`] verbatim into hardware wire bytes for the target [`WireSampleFormat`],
/// assuming matching sample rate, channels, and DSP/volume bypass when bit-perfect.
pub fn pack_chunk_to_wire_bytes(
    chunk: &AudioChunk,
    wire: WireSampleFormat,
    dop_framer: Option<&mut DopFramer>,
) -> Vec<u8> {
    let mut out = Vec::new();
    pack_chunk_to_wire_bytes_into(chunk, wire, dop_framer, &mut out);
    out
}

/// Stateful, reusable wire-format packer for background decode threads.
///
/// Owns a [`DopFramer`] (preserving marker phase and carrying odd trailing DSD bytes across
/// chunk boundaries) and a reusable `Vec<u8>` output scratch buffer so hot decode loops avoid
/// per-chunk heap allocations.
#[derive(Debug, Clone)]
pub struct WirePacker {
    dop_framer: DopFramer,
    native_dsd_target_lsb_first: Option<bool>,
    scratch: Vec<u8>,
}

impl Default for WirePacker {
    fn default() -> Self {
        Self::new()
    }
}

impl WirePacker {
    pub fn new() -> Self {
        Self {
            dop_framer: DopFramer::new(),
            native_dsd_target_lsb_first: None,
            scratch: Vec::with_capacity(64 * 1024),
        }
    }

    pub fn with_capacity(bytes: usize) -> Self {
        Self {
            dop_framer: DopFramer::new(),
            native_dsd_target_lsb_first: None,
            scratch: Vec::with_capacity(bytes),
        }
    }

    pub fn with_native_dsd_target_lsb_first(mut self, target_lsb_first: Option<bool>) -> Self {
        self.native_dsd_target_lsb_first = target_lsb_first;
        self
    }

    pub fn set_native_dsd_target_lsb_first(&mut self, target_lsb_first: Option<bool>) {
        self.native_dsd_target_lsb_first = target_lsb_first;
    }

    /// Resets stateful DoP marker phase and pending boundary bytes (call on seek or track change).
    pub fn reset(&mut self) {
        self.dop_framer.reset();
        self.scratch.clear();
    }

    /// Number of trailing DSD bytes buffered across chunk boundaries waiting for the next DoP frame.
    pub fn pending_dop_bytes(&self) -> usize {
        self.dop_framer.pending_byte_count()
    }

    pub fn dop_framer_mut(&mut self) -> &mut DopFramer {
        &mut self.dop_framer
    }

    /// Packs `chunk` into `self`'s internal reusable buffer and returns the packed byte slice.
    pub fn pack<'a>(&'a mut self, chunk: &AudioChunk, wire: WireSampleFormat) -> &'a [u8] {
        pack_chunk_to_wire_bytes_with_dsd_order_into(
            chunk,
            wire,
            Some(&mut self.dop_framer),
            self.native_dsd_target_lsb_first,
            &mut self.scratch,
        );
        &self.scratch
    }

    /// Packs `chunk` directly into caller-owned `out` buffer (clearing `out` first).
    pub fn pack_into(&mut self, chunk: &AudioChunk, wire: WireSampleFormat, out: &mut Vec<u8>) {
        pack_chunk_to_wire_bytes_with_dsd_order_into(
            chunk,
            wire,
            Some(&mut self.dop_framer),
            self.native_dsd_target_lsb_first,
            out,
        );
    }
}
