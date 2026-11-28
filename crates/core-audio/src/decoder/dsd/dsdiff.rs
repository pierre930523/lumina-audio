use std::io::{Read, Seek, SeekFrom};
use std::time::Duration;

use super::super::pcm::{AudioChunk, AudioDecoder};
use crate::error::DsdError;
use core_types::{AudioCodec, AudioFormat};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DsdiffHeader {
    pub channel_num: u16,
    pub sample_rate: u32,
    pub data_offset: u64,
    pub data_length: u64,
}

pub struct DsdiffParser;

impl DsdiffParser {
    pub fn parse<R: Read + Seek>(reader: &mut R) -> Result<DsdiffHeader, DsdError> {
        let mut frm8_buf = [0u8; 16];
        reader.read_exact(&mut frm8_buf)?;
        if &frm8_buf[0..4] != b"FRM8" || &frm8_buf[12..16] != b"DSD " {
            return Err(DsdError::InvalidDsdiff(
                "Invalid FRM8/DSD root chunk".into(),
            ));
        }
        let frm8_size = u64::from_be_bytes(frm8_buf[4..12].try_into().unwrap());

        let mut channel_num = None;
        let mut sample_rate = None;
        let mut data_offset = None;
        let mut data_length = None;

        let end_pos = 12 + frm8_size;

        while reader.stream_position()? < end_pos {
            let mut header = [0u8; 12];
            if reader.read_exact(&mut header).is_err() {
                break;
            }
            let ck_id = &header[0..4];
            let ck_size = u64::from_be_bytes(header[4..12].try_into().unwrap());

            match ck_id {
                b"PROP" => {
                    let mut prop_type = [0u8; 4];
                    reader.read_exact(&mut prop_type)?;
                    if &prop_type == b"SND " {
                        let prop_end = reader.stream_position()? + ck_size.saturating_sub(4);
                        while reader.stream_position()? < prop_end {
                            let mut sub_hdr = [0u8; 12];
                            if reader.read_exact(&mut sub_hdr).is_err() {
                                break;
                            }
                            let sub_id = &sub_hdr[0..4];
                            let sub_size = u64::from_be_bytes(sub_hdr[4..12].try_into().unwrap());
                            match sub_id {
                                b"FS  " => {
                                    let mut fs_buf = [0u8; 4];
                                    reader.read_exact(&mut fs_buf)?;
                                    let fs = u32::from_be_bytes(fs_buf);
                                    if fs == 0 {
                                        return Err(DsdError::UnsupportedSampleRate(0));
                                    }
                                    sample_rate = Some(fs);
                                    let pad = if sub_size > 4 {
                                        (sub_size - 4) as i64
                                    } else {
                                        0
                                    };
                                    if pad > 0 {
                                        reader.seek(SeekFrom::Current(pad))?;
                                    }
                                }
                                b"CHNL" => {
                                    let mut ch_buf = [0u8; 2];
                                    reader.read_exact(&mut ch_buf)?;
                                    let ch = u16::from_be_bytes(ch_buf);
                                    if ch == 0 || ch > 8 {
                                        return Err(DsdError::UnsupportedChannels(ch));
                                    }
                                    channel_num = Some(ch);
                                    let pad = if sub_size > 2 {
                                        (sub_size - 2) as i64
                                    } else {
                                        0
                                    };
                                    if pad > 0 {
                                        reader.seek(SeekFrom::Current(pad))?;
                                    }
                                }
                                b"CMPR" => {
                                    let mut cmpr_id = [0u8; 4];
                                    reader.read_exact(&mut cmpr_id)?;
                                    if &cmpr_id != b"DSD " {
                                        let name = String::from_utf8_lossy(&cmpr_id).into_owned();
                                        return Err(DsdError::UnsupportedCompression(name));
                                    }
                                    let pad = if sub_size > 4 {
                                        (sub_size - 4) as i64
                                    } else {
                                        0
                                    };
                                    if pad > 0 {
                                        reader.seek(SeekFrom::Current(pad))?;
                                    }
                                }
                                _ => {
                                    let pad = if sub_size % 2 != 0 { 1 } else { 0 };
                                    reader.seek(SeekFrom::Current((sub_size + pad) as i64))?;
                                }
                            }
                        }
                    } else {
                        let pad = if ck_size > 4 { (ck_size - 4) as i64 } else { 0 };
                        reader.seek(SeekFrom::Current(pad))?;
                    }
                }
                b"DSD " => {
                    data_offset = Some(reader.stream_position()?);
                    data_length = Some(ck_size);
                    break;
                }
                _ => {
                    let pad = if ck_size % 2 != 0 { 1 } else { 0 };
                    reader.seek(SeekFrom::Current((ck_size + pad) as i64))?;
                }
            }
        }

        let channel_num =
            channel_num.ok_or_else(|| DsdError::InvalidDsdiff("Missing CHNL chunk".into()))?;
        let sample_rate =
            sample_rate.ok_or_else(|| DsdError::InvalidDsdiff("Missing FS chunk".into()))?;
        let data_offset =
            data_offset.ok_or_else(|| DsdError::InvalidDsdiff("Missing DSD chunk".into()))?;
        let data_length = data_length.unwrap_or(0);

        Ok(DsdiffHeader {
            channel_num,
            sample_rate,
            data_offset,
            data_length,
        })
    }
}

/// Native DSDIFF (DFF) bitstream decoder.
///
/// ## Native DSD Seek Precision Limit
/// DSDIFF stores byte-interleaved 1-bit DSD samples (8 samples per byte per
/// channel). Native DSD seeking without DSD-to-PCM conversion is physically
/// quantized to:
/// - **8 1-bit DSD frames** (1 byte/channel ≈ `2.83 µs` at DSD64) in native
///   bitstream mode (`dop_aligned == false`), or
/// - **16 1-bit DSD frames** (2 bytes/channel ≈ `5.67 µs` at DSD64) when
///   DoP v1.1 pair alignment is active (`dop_aligned == true` or
///   [`DsdiffReader::seek_dop_aligned`]).
pub struct DsdiffReader<R> {
    reader: R,
    header: DsdiffHeader,
    format: AudioFormat,
    bytes_read: u64,
    dop_aligned: bool,
}

impl<R: Read + Seek + Send> DsdiffReader<R> {
    pub fn new(mut reader: R) -> Result<Self, DsdError> {
        let header = DsdiffParser::parse(&mut reader)?;
        let format = AudioFormat::dsd(
            AudioCodec::Dsdiff,
            header.sample_rate,
            header.channel_num as u8,
        )
        .map_err(|e| DsdError::InvalidDsdiff(e.to_string()))?;

        Ok(Self {
            reader,
            header,
            format,
            bytes_read: 0,
            dop_aligned: false,
        })
    }

    pub fn header(&self) -> &DsdiffHeader {
        &self.header
    }

    /// Enables or disables 2-byte-per-channel (16 DSD frames) alignment in `AudioDecoder::seek`
    /// so DoP v1.1 carriers maintain even byte boundaries across seeks.
    pub fn set_dop_aligned(&mut self, aligned: bool) {
        self.dop_aligned = aligned;
    }

    /// Seeks with explicit 2-byte-per-channel (16 DSD frames) DoP v1.1 alignment
    /// without converting DSD to PCM.
    pub fn seek_dop_aligned(&mut self, time: Duration) -> Result<(), crate::error::DecoderError> {
        self.seek_inner(time, true)
    }

    /// Current seek alignment quantum in 1-bit DSD frames (`16` when DoP-aligned, `8` otherwise).
    pub fn seek_precision_frames(&self) -> u64 {
        if self.dop_aligned { 16 } else { 8 }
    }

    fn seek_inner(
        &mut self,
        time: Duration,
        dop_aligned: bool,
    ) -> Result<(), crate::error::DecoderError> {
        let ch = (self.header.channel_num as u64).max(1);
        let max_bytes_per_ch = self.header.data_length / ch;
        let total_frames = max_bytes_per_ch.saturating_mul(8);
        let target_frame = ((time
            .as_nanos()
            .saturating_mul(self.header.sample_rate as u128))
            / 1_000_000_000) as u64;
        let clamped_frame = target_frame.min(total_frames);

        let at_eof = total_frames == 0
            || self.duration().is_some_and(|d| time >= d)
            || clamped_frame >= total_frames;

        let bytes_read = if at_eof {
            self.header.data_length
        } else {
            let raw_byte = (clamped_frame / 8).min(max_bytes_per_ch);
            let target_byte_per_ch = if dop_aligned && max_bytes_per_ch >= 2 {
                raw_byte & !1
            } else {
                raw_byte
            };
            target_byte_per_ch
                .saturating_mul(ch)
                .min(self.header.data_length)
        };

        let offset = self.header.data_offset.saturating_add(bytes_read);

        self.reader
            .seek(SeekFrom::Start(offset))
            .map_err(crate::error::DecoderError::Io)?;

        self.bytes_read = bytes_read;
        Ok(())
    }
}

impl<R: Read + Seek + Send> AudioDecoder for DsdiffReader<R> {
    fn format(&self) -> &AudioFormat {
        &self.format
    }

    fn duration(&self) -> Option<Duration> {
        if self.header.sample_rate > 0 && self.header.channel_num > 0 {
            let total_samples_per_ch =
                (self.header.data_length * 8) / (self.header.channel_num as u64);
            Some(Duration::from_secs_f64(
                total_samples_per_ch as f64 / self.header.sample_rate as f64,
            ))
        } else {
            None
        }
    }

    fn total_frames(&self) -> Option<u64> {
        if self.header.channel_num > 0 {
            Some((self.header.data_length * 8) / (self.header.channel_num as u64))
        } else {
            None
        }
    }

    fn next_chunk(&mut self) -> Result<Option<AudioChunk>, crate::error::DecoderError> {
        let ch = (self.header.channel_num as usize).max(1);
        if self.bytes_read >= self.header.data_length {
            return Ok(None);
        }

        let remaining = (self.header.data_length - self.bytes_read) as usize;
        if remaining < ch {
            self.bytes_read = self.header.data_length;
            return Ok(None);
        }

        // Read up to 4096 interleaved frames (whole channel-aligned bytes)
        let block_bytes = 4096 * ch;
        let aligned_remaining = remaining - (remaining % ch);
        let to_read = block_bytes.min(aligned_remaining);

        let mut buffer = vec![0u8; to_read];
        match self.reader.read_exact(&mut buffer) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                self.bytes_read = self.header.data_length;
                return Ok(None);
            }
            Err(e) => return Err(crate::error::DecoderError::Io(e)),
        }

        self.bytes_read += to_read as u64;

        Ok(Some(AudioChunk::DsdBitstream {
            bytes: buffer,
            channels: self.header.channel_num,
            sample_rate: self.header.sample_rate,
            is_lsb_first: false, // DSDIFF is MSB first
        }))
    }

    fn seek(&mut self, time: Duration) -> Result<(), crate::error::DecoderError> {
        self.seek_inner(time, self.dop_aligned)
    }
}
