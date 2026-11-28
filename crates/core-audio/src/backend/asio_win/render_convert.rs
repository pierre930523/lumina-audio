use crate::verification::WireSampleFormat;

use super::callbacks::fill_asio_buffer_silence;
use super::ffi_types::{
    ASIO_ST_DSD_INT8_LSB1, ASIO_ST_DSD_INT8_LSB8, ASIO_ST_DSD_INT8_MSB1, ASIO_ST_FLOAT32_LSB,
    ASIO_ST_FLOAT64_LSB, ASIO_ST_INT16_LSB, ASIO_ST_INT24_LSB, ASIO_ST_INT32_LSB,
};
use super::render_core::AsioRenderCore;
use super::render_trampoline::asio_sample_bytes;

impl AsioRenderCore {
    pub(super) fn write_interleaved_to_planar(
        &mut self,
        channel_buffers: &[[*mut u8; 2]],
        idx: usize,
        aligned: usize,
        frames_in_callback_bytes: usize,
    ) {
        let ch = self.channels.min(channel_buffers.len());
        let drv_bps = asio_sample_bytes(self.sample_type);
        let src_bps = self.wire.bytes_per_sample();
        let wire_bpf = src_bps * self.channels.max(1);
        let valid_frames = aligned.checked_div(wire_bpf).unwrap_or(0);
        let tail_start_phase = self.dop_silence_phase;
        let mut tail_next_phase = tail_start_phase;

        for (c, pair) in channel_buffers.iter().enumerate().take(ch) {
            let dst_ptr = pair[idx];
            if dst_ptr.is_null() {
                continue;
            }
            let dst = unsafe {
                std::slice::from_raw_parts_mut(dst_ptr, frames_in_callback_bytes * drv_bps)
            };
            match (self.wire, self.sample_type) {
                // Exact bit-identical wire <-> ASIO driver container matches (bit-perfect fast path).
                (WireSampleFormat::Int16Le, ASIO_ST_INT16_LSB)
                | (WireSampleFormat::Int24PackedLe, ASIO_ST_INT24_LSB)
                | (
                    WireSampleFormat::Int24In32MsbLe
                    | WireSampleFormat::Int32Le
                    | WireSampleFormat::Dop24In32MsbLe { .. },
                    ASIO_ST_INT32_LSB,
                )
                | (WireSampleFormat::Float32Le, ASIO_ST_FLOAT32_LSB)
                | (WireSampleFormat::Float64Le, ASIO_ST_FLOAT64_LSB)
                | (
                    WireSampleFormat::NativeDsd { .. },
                    ASIO_ST_DSD_INT8_LSB1 | ASIO_ST_DSD_INT8_MSB1 | ASIO_ST_DSD_INT8_LSB8,
                ) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * src_bps;
                        let d_off = f * drv_bps;
                        dst[d_off..d_off + drv_bps]
                            .copy_from_slice(&self.scratch[s_off..s_off + drv_bps]);
                    }
                }
                // Bit-exact lossless integer container promotions / MSB alignment.
                (WireSampleFormat::Int16Le, ASIO_ST_INT32_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 2;
                        let s16 =
                            i16::from_le_bytes([self.scratch[s_off], self.scratch[s_off + 1]]);
                        let s32 = (s16 as i32) << 16;
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&s32.to_le_bytes());
                    }
                }
                (WireSampleFormat::Int24PackedLe, ASIO_ST_INT32_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 3;
                        let bytes = [
                            0u8,
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                        ];
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&bytes);
                    }
                }
                (WireSampleFormat::Int16Le, ASIO_ST_INT24_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 2;
                        let bytes = [0u8, self.scratch[s_off], self.scratch[s_off + 1]];
                        dst[f * 3..(f + 1) * 3].copy_from_slice(&bytes);
                    }
                }
                (
                    WireSampleFormat::Int24In32MsbLe | WireSampleFormat::Dop24In32MsbLe { .. },
                    ASIO_ST_INT24_LSB,
                ) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 4;
                        let bytes = [
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            self.scratch[s_off + 3],
                        ];
                        dst[f * 3..(f + 1) * 3].copy_from_slice(&bytes);
                    }
                }
                // Proper integer/double -> Float32 conversion (NEVER raw-copy i32 bits as f32!).
                (WireSampleFormat::Int16Le, ASIO_ST_FLOAT32_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 2;
                        let s16 =
                            i16::from_le_bytes([self.scratch[s_off], self.scratch[s_off + 1]]);
                        let sample = (s16 as f32) / 32_768.0;
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                (WireSampleFormat::Int24PackedLe, ASIO_ST_FLOAT32_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 3;
                        let sign = if (self.scratch[s_off + 2] & 0x80) != 0 {
                            0xFF
                        } else {
                            0x00
                        };
                        let s24 = i32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            sign,
                        ]);
                        let sample = (s24 as f64 / 8_388_608.0) as f32;
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                (
                    WireSampleFormat::Int24In32MsbLe | WireSampleFormat::Int32Le,
                    ASIO_ST_FLOAT32_LSB,
                ) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 4;
                        let s32 = i32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            self.scratch[s_off + 3],
                        ]);
                        let sample = (s32 as f64 / 2_147_483_648.0) as f32;
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                (WireSampleFormat::Float64Le, ASIO_ST_FLOAT32_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 8;
                        let s64 =
                            f64::from_le_bytes(self.scratch[s_off..s_off + 8].try_into().unwrap());
                        let sample = s64 as f32;
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                // Proper integer/float -> Float64 conversion.
                (WireSampleFormat::Int16Le, ASIO_ST_FLOAT64_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 2;
                        let s16 =
                            i16::from_le_bytes([self.scratch[s_off], self.scratch[s_off + 1]]);
                        let sample = (s16 as f64) / 32_768.0;
                        dst[f * 8..(f + 1) * 8].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                (WireSampleFormat::Int24PackedLe, ASIO_ST_FLOAT64_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 3;
                        let sign = if (self.scratch[s_off + 2] & 0x80) != 0 {
                            0xFF
                        } else {
                            0x00
                        };
                        let s24 = i32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            sign,
                        ]);
                        let sample = (s24 as f64) / 8_388_608.0;
                        dst[f * 8..(f + 1) * 8].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                (
                    WireSampleFormat::Int24In32MsbLe | WireSampleFormat::Int32Le,
                    ASIO_ST_FLOAT64_LSB,
                ) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 4;
                        let s32 = i32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            self.scratch[s_off + 3],
                        ]);
                        let sample = (s32 as f64) / 2_147_483_648.0;
                        dst[f * 8..(f + 1) * 8].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                (WireSampleFormat::Float32Le, ASIO_ST_FLOAT64_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 4;
                        let s32 = f32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            self.scratch[s_off + 3],
                        ]);
                        let sample = s32 as f64;
                        dst[f * 8..(f + 1) * 8].copy_from_slice(&sample.to_le_bytes());
                    }
                }
                // Proper Float32/Float64 -> integer ASIO quantization (NEVER raw-copy f32 bits as i32!).
                (WireSampleFormat::Float32Le, ASIO_ST_INT32_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 4;
                        let s = f32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            self.scratch[s_off + 3],
                        ]);
                        let clamped = if s.is_finite() {
                            ((s.clamp(-1.0, 1.0) as f64) * 2_147_483_648.0)
                                .round()
                                .clamp(i32::MIN as f64, i32::MAX as f64)
                                as i32
                        } else {
                            0
                        };
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&clamped.to_le_bytes());
                    }
                }
                (WireSampleFormat::Float32Le, ASIO_ST_INT24_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 4;
                        let s = f32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            self.scratch[s_off + 3],
                        ]);
                        let clamped = if s.is_finite() {
                            ((s.clamp(-1.0, 1.0) as f64) * 8_388_608.0)
                                .round()
                                .clamp(-8_388_608.0, 8_388_607.0) as i32
                        } else {
                            0
                        };
                        dst[f * 3..(f + 1) * 3].copy_from_slice(&clamped.to_le_bytes()[0..3]);
                    }
                }
                (WireSampleFormat::Float32Le, ASIO_ST_INT16_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 4;
                        let s = f32::from_le_bytes([
                            self.scratch[s_off],
                            self.scratch[s_off + 1],
                            self.scratch[s_off + 2],
                            self.scratch[s_off + 3],
                        ]);
                        let clamped = if s.is_finite() {
                            ((s.clamp(-1.0, 1.0) as f64) * 32_768.0)
                                .round()
                                .clamp(i16::MIN as f64, i16::MAX as f64)
                                as i16
                        } else {
                            0
                        };
                        dst[f * 2..(f + 1) * 2].copy_from_slice(&clamped.to_le_bytes());
                    }
                }
                (WireSampleFormat::Float64Le, ASIO_ST_INT32_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 8;
                        let s =
                            f64::from_le_bytes(self.scratch[s_off..s_off + 8].try_into().unwrap());
                        let clamped = if s.is_finite() {
                            (s.clamp(-1.0, 1.0) * 2_147_483_648.0)
                                .round()
                                .clamp(i32::MIN as f64, i32::MAX as f64)
                                as i32
                        } else {
                            0
                        };
                        dst[f * 4..(f + 1) * 4].copy_from_slice(&clamped.to_le_bytes());
                    }
                }
                (WireSampleFormat::Float64Le, ASIO_ST_INT24_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 8;
                        let s =
                            f64::from_le_bytes(self.scratch[s_off..s_off + 8].try_into().unwrap());
                        let clamped = if s.is_finite() {
                            (s.clamp(-1.0, 1.0) * 8_388_608.0)
                                .round()
                                .clamp(-8_388_608.0, 8_388_607.0) as i32
                        } else {
                            0
                        };
                        dst[f * 3..(f + 1) * 3].copy_from_slice(&clamped.to_le_bytes()[0..3]);
                    }
                }
                (WireSampleFormat::Float64Le, ASIO_ST_INT16_LSB) => {
                    for f in 0..valid_frames {
                        let s_off = (f * ch + c) * 8;
                        let s =
                            f64::from_le_bytes(self.scratch[s_off..s_off + 8].try_into().unwrap());
                        let clamped = if s.is_finite() {
                            (s.clamp(-1.0, 1.0) * 32_768.0)
                                .round()
                                .clamp(i16::MIN as f64, i16::MAX as f64)
                                as i16
                        } else {
                            0
                        };
                        dst[f * 2..(f + 1) * 2].copy_from_slice(&clamped.to_le_bytes());
                    }
                }
                _ => {
                    // Unsupported wire/driver combination: emit safe silence rather than corrupted audio.
                    let mut ch_phase = tail_start_phase;
                    fill_asio_buffer_silence(
                        &mut dst[..valid_frames * drv_bps],
                        self.wire,
                        drv_bps,
                        &mut ch_phase,
                    );
                }
            }
            if valid_frames < frames_in_callback_bytes {
                let mut ch_phase = tail_start_phase;
                fill_asio_buffer_silence(
                    &mut dst[valid_frames * drv_bps..],
                    self.wire,
                    drv_bps,
                    &mut ch_phase,
                );
                tail_next_phase = ch_phase;
            }
        }
        if valid_frames < frames_in_callback_bytes {
            self.dop_silence_phase = tail_next_phase;
        }
    }
}
