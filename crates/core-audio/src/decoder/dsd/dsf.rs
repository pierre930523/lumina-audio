use std::io::{Read, Seek, SeekFrom};
use std::time::Duration;

use super::super::pcm::{AudioChunk, AudioDecoder};
use crate::error::DsdError;
use core_types::{AudioCodec, AudioFormat};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DsfHeader {
    pub file_size: u64,
    pub metadata_offset: u64,
    pub channel_num: u16,
    pub sample_rate: u32,
    pub sample_count: u64,
    pub block_size: u32,
    pub data_offset: u64,
    pub data_length: u64,
}

pub struct DsfParser;

impl DsfParser {
    pub fn parse<R: Read + Seek>(reader: &mut R) -> Result<DsfHeader, DsdError> {
        // 1. 'DSD ' chunk (28 bytes)
        let mut dsd_buf = [0u8; 28];
        reader.read_exact(&mut dsd_buf)?;
        if &dsd_buf[0..4] != b"DSD " {
            return Err(DsdError::InvalidDsf("Missing 'DSD ' magic header".into()));
        }
        let chunk_size = u64::from_le_bytes(dsd_buf[4..12].try_into().unwrap());
        if chunk_size != 28 {
            return Err(DsdError::InvalidDsf(format!(
                "Invalid DSD chunk size: {chunk_size}"
            )));
        }
        let file_size = u64::from_le_bytes(dsd_buf[12..20].try_into().unwrap());
        let metadata_offset = u64::from_le_bytes(dsd_buf[20..28].try_into().unwrap());

        // 2. 'fmt ' chunk (52 bytes)
        let mut fmt_buf = [0u8; 52];
        reader.read_exact(&mut fmt_buf)?;
        if &fmt_buf[0..4] != b"fmt " {
            return Err(DsdError::InvalidDsf("Missing 'fmt ' chunk".into()));
        }
        let fmt_chunk_size = u64::from_le_bytes(fmt_buf[4..12].try_into().unwrap());
        if fmt_chunk_size != 52 {
            return Err(DsdError::InvalidDsf(format!(
                "Invalid fmt chunk size: {fmt_chunk_size}"
            )));
        }
        let format_version = u32::from_le_bytes(fmt_buf[12..16].try_into().unwrap());
        if format_version != 1 {
            return Err(DsdError::InvalidDsf(format!(
                "Unsupported format version: {format_version}"
            )));
        }
        let format_id = u32::from_le_bytes(fmt_buf[16..20].try_into().unwrap());
        if format_id != 0 {
            return Err(DsdError::InvalidDsf(format!(
                "Unsupported format ID (expected 0 DSD raw): {format_id}"
            )));
        }
        let channel_type = u32::from_le_bytes(fmt_buf[20..24].try_into().unwrap());
        let channel_num = u32::from_le_bytes(fmt_buf[24..28].try_into().unwrap()) as u16;
        if channel_num == 0 || channel_num > 8 {
            return Err(DsdError::UnsupportedChannels(channel_num));
        }
        let sample_rate = u32::from_le_bytes(fmt_buf[28..32].try_into().unwrap());
        if sample_rate == 0 {
            return Err(DsdError::UnsupportedSampleRate(sample_rate));
        }
        let bits_per_sample = u32::from_le_bytes(fmt_buf[32..36].try_into().unwrap());
        if bits_per_sample != 1 {
            return Err(DsdError::InvalidDsf(format!(
                "Invalid bits per sample (expected 1): {bits_per_sample}"
            )));
        }
        let sample_count = u64::from_le_bytes(fmt_buf[36..44].try_into().unwrap());
        let block_size = u32::from_le_bytes(fmt_buf[44..48].try_into().unwrap());
        if block_size == 0 {
            return Err(DsdError::InvalidDsf(
                "Block size per channel cannot be 0".into(),
            ));
        }

        // 3. 'data' chunk header (12 bytes)
        let mut data_buf = [0u8; 12];
        reader.read_exact(&mut data_buf)?;
        if &data_buf[0..4] != b"data" {
            return Err(DsdError::InvalidDsf("Missing 'data' chunk".into()));
        }
        let data_chunk_size = u64::from_le_bytes(data_buf[4..12].try_into().unwrap());
        if data_chunk_size < 12 {
            return Err(DsdError::InvalidDsf(format!(
                "Invalid data chunk size: {data_chunk_size}"
            )));
        }
        let data_length = data_chunk_size - 12;
        let data_offset = reader.stream_position()?;

        let _ = channel_type;

        Ok(DsfHeader {
            file_size,
            metadata_offset,
            channel_num,
            sample_rate,
            sample_count,
            block_size,
            data_offset,
            data_length,
        })
    }
}

/// Native DSF bitstream decoder.
///
/// ## Native DSD Seek Precision Limit
/// DSF stores planar channel blocks of `block_size` bytes per channel (8 1-bit
/// DSD samples per byte). Native DSD seeking without DSD-to-PCM conversion is
/// physically quantized to whole DSF blocks of `block_size * 8` 1-bit samples
/// (e.g., `4096 * 8 = 32,768` samples ≈ `11.61 ms` at DSD64, `5.80 ms` at DSD128).
pub struct DsfReader<R> {
    reader: R,
    header: DsfHeader,
    format: AudioFormat,
    current_block: u64,
    total_blocks: u64,
    bytes_read: u64,
}

impl<R: Read + Seek + Send> DsfReader<R> {
    pub fn new(mut reader: R) -> Result<Self, DsdError> {
        let header = DsfParser::parse(&mut reader)?;
        let format = AudioFormat::dsd(
            AudioCodec::Dsf,
            header.sample_rate,
            header.channel_num as u8,
        )
        .map_err(|e| DsdError::InvalidDsf(e.to_string()))?;

        let block_bytes_all_channels = (header.block_size as u64) * (header.channel_num as u64);
        let total_blocks = if block_bytes_all_channels != 0 {
            header.data_length.div_ceil(block_bytes_all_channels)
        } else {
            0
        };

        Ok(Self {
            reader,
            header,
            format,
            current_block: 0,
            total_blocks,
            bytes_read: 0,
        })
    }

    pub fn header(&self) -> &DsfHeader {
        &self.header
    }

    /// Native DSD seek alignment quantum in 1-bit DSD frames (`block_size * 8`).
    pub fn seek_precision_frames(&self) -> u64 {
        (self.header.block_size as u64).saturating_mul(8)
    }
}

impl<R: Read + Seek + Send> AudioDecoder for DsfReader<R> {
    fn format(&self) -> &AudioFormat {
        &self.format
    }

    fn duration(&self) -> Option<Duration> {
        if self.header.sample_rate > 0 {
            Some(Duration::from_secs_f64(
                self.header.sample_count as f64 / self.header.sample_rate as f64,
            ))
        } else {
            None
        }
    }

    fn total_frames(&self) -> Option<u64> {
        Some(self.header.sample_count)
    }

    fn next_chunk(&mut self) -> Result<Option<AudioChunk>, crate::error::DecoderError> {
        if self.current_block >= self.total_blocks || self.bytes_read >= self.header.data_length {
            return Ok(None);
        }

        let block_bytes = (self.header.block_size as usize) * (self.header.channel_num as usize);
        let remaining = (self.header.data_length - self.bytes_read) as usize;
        let to_read = block_bytes.min(remaining);

        let mut buffer = vec![0u8; to_read];
        match self.reader.read_exact(&mut buffer) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                return Ok(None);
            }
            Err(e) => return Err(crate::error::DecoderError::Io(e)),
        }

        self.bytes_read += to_read as u64;
        self.current_block += 1;

        // DSF stores channel blocks planar per block_size: [ch0_0..B][ch1_0..B]...
        // Interleave into canonical byte-interleaved [ch0_0, ch1_0, ch0_1, ch1_1, ...]
        let ch = (self.header.channel_num as usize).max(1);
        let bsize = (self.header.block_size as usize).min(buffer.len() / ch);
        let interleaved = if ch == 1 || bsize == 0 || buffer.len() < ch * bsize {
            buffer
        } else {
            let mut out = Vec::with_capacity(ch * bsize);
            for i in 0..bsize {
                for c in 0..ch {
                    out.push(buffer[c * bsize + i]);
                }
            }
            out
        };

        Ok(Some(AudioChunk::DsdBitstream {
            bytes: interleaved,
            channels: self.header.channel_num,
            sample_rate: self.header.sample_rate,
            is_lsb_first: true, // DSF is LSB first
        }))
    }

    fn seek(&mut self, time: Duration) -> Result<(), crate::error::DecoderError> {
        let target_frame = ((time
            .as_nanos()
            .saturating_mul(self.header.sample_rate as u128))
            / 1_000_000_000) as u64;
        let clamped_frame = target_frame.min(self.header.sample_count);
        let samples_per_block = (self.header.block_size as u64).saturating_mul(8).max(1);
        let block_bytes =
            (self.header.block_size as u64).saturating_mul(self.header.channel_num as u64);

        let at_eof = self.header.sample_count == 0
            || self.duration().is_some_and(|d| time >= d)
            || clamped_frame >= self.header.sample_count;

        let target_block = if at_eof {
            self.total_blocks
        } else {
            (clamped_frame / samples_per_block).min(self.total_blocks)
        };
        let bytes_read = target_block
            .saturating_mul(block_bytes)
            .min(self.header.data_length);
        let offset = self.header.data_offset.saturating_add(bytes_read);

        self.reader
            .seek(SeekFrom::Start(offset))
            .map_err(crate::error::DecoderError::Io)?;

        self.current_block = target_block;
        self.bytes_read = bytes_read;
        Ok(())
    }
}
