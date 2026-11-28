use super::wire_format::WireSampleFormat;
use crate::dsd::DopFramer;
use crate::pcm::AudioChunk;

/// Decodes hardware backend wire bytes back into canonical logical sample values
/// (`Int16` as `i16`, `Int24` as sign-extended `i32`, etc.) for exact sample-level comparison
/// against the decoder output.
pub fn unpack_wire_bytes_to_chunk(
    raw: &[u8],
    wire: WireSampleFormat,
    channels: u16,
    sample_rate: u32,
    dop_unframer: Option<&mut DopFramer>,
) -> Result<AudioChunk, String> {
    match wire {
        WireSampleFormat::Int16Le => {
            let samples = raw
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| i16::from_le_bytes(*c))
                .collect();
            Ok(AudioChunk::PcmI16 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Int24PackedLe => {
            let samples = raw
                .as_chunks::<3>()
                .0
                .iter()
                .map(|c| {
                    let sign_byte = if c[2] & 0x80 != 0 { 0xFF } else { 0x00 };
                    i32::from_le_bytes([c[0], c[1], c[2], sign_byte])
                })
                .collect();
            Ok(AudioChunk::PcmI24In32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Int24In32MsbLe => {
            let samples = raw
                .as_chunks::<4>()
                .0
                .iter()
                .map(|c| i32::from_le_bytes(*c) >> 8)
                .collect();
            Ok(AudioChunk::PcmI24In32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Int32Le => {
            let samples = raw
                .as_chunks::<4>()
                .0
                .iter()
                .map(|c| i32::from_le_bytes(*c))
                .collect();
            Ok(AudioChunk::PcmI32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Float32Le => {
            let samples = raw
                .as_chunks::<4>()
                .0
                .iter()
                .map(|c| f32::from_le_bytes(*c))
                .collect();
            Ok(AudioChunk::PcmF32 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Float64Le => {
            let samples = raw
                .as_chunks::<8>()
                .0
                .iter()
                .map(|c| f64::from_le_bytes(*c))
                .collect();
            Ok(AudioChunk::PcmF64 {
                samples,
                channels,
                sample_rate,
            })
        }
        WireSampleFormat::Dop24In32MsbLe {
            channels: ch,
            is_lsb_first,
        } => {
            let unframer = dop_unframer.ok_or_else(|| "Missing DoP unframer".to_string())?;
            let ch_usize = ch.max(1) as usize;
            let frame_bytes = ch_usize * 4;
            let mut out = Vec::with_capacity((raw.len() / 4) * 2);
            for frame in raw.chunks_exact(frame_bytes) {
                let expected = unframer.next_marker();
                let mut frame_dsd = vec![[0u8; 2]; ch_usize];
                for c in 0..ch_usize {
                    let word = i32::from_le_bytes(frame[c * 4..(c + 1) * 4].try_into().unwrap());
                    let marker = ((word >> 24) & 0xFF) as u8;
                    if marker != expected {
                        return Err(format!(
                            "DoP marker corruption: expected 0x{expected:02X}, got 0x{marker:02X}"
                        ));
                    }
                    let mut b0 = ((word >> 16) & 0xFF) as u8;
                    let mut b1 = ((word >> 8) & 0xFF) as u8;
                    if is_lsb_first {
                        b0 = b0.reverse_bits();
                        b1 = b1.reverse_bits();
                    }
                    frame_dsd[c] = [b0, b1];
                }
                for pair in &frame_dsd {
                    out.push(pair[0]);
                }
                for pair in &frame_dsd {
                    out.push(pair[1]);
                }
            }
            Ok(AudioChunk::DsdBitstream {
                bytes: out,
                channels: ch,
                sample_rate,
                is_lsb_first,
            })
        }
        WireSampleFormat::NativeDsd { channels: ch } => Ok(AudioChunk::DsdBitstream {
            bytes: raw.to_vec(),
            channels: ch,
            sample_rate,
            is_lsb_first: true,
        }),
    }
}
