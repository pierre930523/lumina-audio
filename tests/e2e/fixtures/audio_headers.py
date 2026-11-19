"""
Audio format header generators, parsers, and test vector fixtures.
Supports:
- RIFF/WAVE PCM headers (16-bit, 24-bit, 32-bit, multi-rate)
- Sony DSF (1-bit DSD) format headers (DSD64, DSD128, DSD256)
- FLAC STREAMINFO metadata block headers
- DoP (DSD over PCM, marker 0x05 / 0xFA) frame pack/unpack
"""
import struct
from typing import Dict, Any, List, Tuple


def generate_wav_header(
    channels: int = 2,
    sample_rate: int = 44100,
    bit_depth: int = 16,
    num_samples: int = 1000,
) -> bytes:
    """Generates standard canonical RIFF/WAVE PCM header bytes."""
    bytes_per_sample = bit_depth // 8
    block_align = channels * bytes_per_sample
    byte_rate = sample_rate * block_align
    data_size = num_samples * block_align
    riff_chunk_size = 36 + data_size

    header = bytearray()
    # RIFF header
    header.extend(b"RIFF")
    header.extend(struct.pack("<I", riff_chunk_size))
    header.extend(b"WAVE")

    # fmt subchunk
    header.extend(b"fmt ")
    header.extend(struct.pack("<I", 16))  # subchunk1 size for PCM = 16
    header.extend(struct.pack("<H", 1))   # audio format = 1 (PCM)
    header.extend(struct.pack("<H", channels))
    header.extend(struct.pack("<I", sample_rate))
    header.extend(struct.pack("<I", byte_rate))
    header.extend(struct.pack("<H", block_align))
    header.extend(struct.pack("<H", bit_depth))

    # data subchunk header
    header.extend(b"data")
    header.extend(struct.pack("<I", data_size))

    return bytes(header)


def parse_wav_header(data: bytes) -> Dict[str, Any]:
    """Parses RIFF/WAVE header and extracts audio format parameters."""
    if len(data) < 44:
        raise ValueError(f"WAV header too short: {len(data)} bytes (expected >= 44)")
    if data[0:4] != b"RIFF":
        raise ValueError(f"Invalid RIFF magic: {data[0:4]}")
    if data[8:12] != b"WAVE":
        raise ValueError(f"Invalid WAVE format identifier: {data[8:12]}")
    if data[12:16] != b"fmt ":
        raise ValueError(f"Expected fmt subchunk, found: {data[12:16]}")

    subchunk1_size = struct.unpack("<I", data[16:20])[0]
    audio_format = struct.unpack("<H", data[20:22])[0]
    channels = struct.unpack("<H", data[22:24])[0]
    sample_rate = struct.unpack("<I", data[24:28])[0]
    byte_rate = struct.unpack("<I", data[28:32])[0]
    block_align = struct.unpack("<H", data[32:34])[0]
    bits_per_sample = struct.unpack("<H", data[34:36])[0]

    # Find data chunk
    offset = 20 + subchunk1_size
    data_size = None
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset+4]
        chunk_size = struct.unpack("<I", data[offset+4:offset+8])[0]
        if chunk_id == b"data":
            data_size = chunk_size
            break
        offset += 8 + chunk_size

    return {
        "format": audio_format,
        "is_pcm": audio_format == 1,
        "channels": channels,
        "sample_rate": sample_rate,
        "byte_rate": byte_rate,
        "block_align": block_align,
        "bit_depth": bits_per_sample,
        "data_size": data_size,
    }


def generate_dsf_header(
    channels: int = 2,
    sample_rate: int = 2822400,
    sample_count: int = 4096,
    block_size_per_channel: int = 4096,
) -> bytes:
    """
    Generates Sony DSF (DSD Stream File) header bytes.
    Default: DSD64 (2,822,400 Hz), stereo, 4096 samples.
    """
    fmt_chunk_size = 52
    dsd_chunk_size = 28
    data_header_size = 12
    # In DSF, 1 sample per channel = 1 bit per channel
    # Payload bytes per channel = ceil(sample_count / 8)
    bytes_per_ch = (sample_count + 7) // 8
    # Padded to block size
    blocks = (bytes_per_ch + block_size_per_channel - 1) // block_size_per_channel
    payload_size = blocks * block_size_per_channel * channels
    data_chunk_size = data_header_size + payload_size
    total_file_size = dsd_chunk_size + fmt_chunk_size + data_chunk_size

    buf = bytearray()

    # 1. 'DSD ' chunk (28 bytes)
    buf.extend(b"DSD ")
    buf.extend(struct.pack("<Q", dsd_chunk_size))
    buf.extend(struct.pack("<Q", total_file_size))
    buf.extend(struct.pack("<Q", 0))  # metadata offset (0 = no ID3)

    # 2. 'fmt ' chunk (52 bytes)
    buf.extend(b"fmt ")
    buf.extend(struct.pack("<Q", fmt_chunk_size))
    buf.extend(struct.pack("<I", 1))            # format version = 1
    buf.extend(struct.pack("<I", 0))            # format id = 0 (DSD raw)
    buf.extend(struct.pack("<I", 2 if channels == 2 else 1))  # channel type: 1=mono, 2=stereo
    buf.extend(struct.pack("<I", channels))     # channel count
    buf.extend(struct.pack("<I", sample_rate))  # sampling frequency (2822400, 5644800, etc.)
    buf.extend(struct.pack("<I", 1))            # bits per sample = 1
    buf.extend(struct.pack("<Q", sample_count)) # sample count per channel
    buf.extend(struct.pack("<I", block_size_per_channel)) # block size per channel (4096)
    buf.extend(struct.pack("<I", 0))            # reserved

    # 3. 'data' chunk header (12 bytes)
    buf.extend(b"data")
    buf.extend(struct.pack("<Q", data_chunk_size))

    return bytes(buf)


def parse_dsf_header(data: bytes) -> Dict[str, Any]:
    """Parses Sony DSF header chunks ('DSD ', 'fmt ', 'data')."""
    if len(data) < 92:
        raise ValueError(f"DSF header too short: {len(data)} bytes (expected >= 92)")
    if data[0:4] != b"DSD ":
        raise ValueError(f"Invalid DSF magic: {data[0:4]}")

    dsd_chunk_size = struct.unpack("<Q", data[4:12])[0]
    total_file_size = struct.unpack("<Q", data[12:20])[0]
    metadata_offset = struct.unpack("<Q", data[20:28])[0]

    if data[28:32] != b"fmt ":
        raise ValueError(f"Expected fmt chunk at offset 28, found {data[28:32]}")

    fmt_chunk_size = struct.unpack("<Q", data[32:40])[0]
    format_version = struct.unpack("<I", data[40:44])[0]
    format_id = struct.unpack("<I", data[44:48])[0]
    channel_type = struct.unpack("<I", data[48:52])[0]
    channel_count = struct.unpack("<I", data[52:56])[0]
    sampling_frequency = struct.unpack("<I", data[56:60])[0]
    bits_per_sample = struct.unpack("<I", data[60:64])[0]
    sample_count = struct.unpack("<Q", data[64:72])[0]
    block_size = struct.unpack("<I", data[72:76])[0]

    data_offset = 28 + fmt_chunk_size
    data_magic = data[data_offset:data_offset+4]
    data_chunk_size = struct.unpack("<Q", data[data_offset+4:data_offset+12])[0]

    return {
        "format_version": format_version,
        "format_id": format_id,
        "is_dsd_raw": format_id == 0,
        "channel_type": channel_type,
        "channels": channel_count,
        "sample_rate": sampling_frequency,
        "bit_depth": bits_per_sample,
        "sample_count": sample_count,
        "block_size": block_size,
        "total_file_size": total_file_size,
        "metadata_offset": metadata_offset,
        "data_chunk_size": data_chunk_size,
    }


def generate_flac_header(
    channels: int = 2,
    sample_rate: int = 96000,
    bit_depth: int = 24,
    total_samples: int = 10000,
) -> bytes:
    """Generates standard FLAC stream header with STREAMINFO metadata block."""
    buf = bytearray()
    # 4-byte marker
    buf.extend(b"fLaC")

    # METADATA_BLOCK_HEADER (4 bytes):
    # 1 bit is_last (1 for last block), 7 bits block_type (0 = STREAMINFO)
    # 24 bits length = 34 bytes
    header_byte0 = 0x80 | 0x00  # last metadata block, type 0
    buf.append(header_byte0)
    buf.extend(struct.pack(">I", 34)[1:])  # 3 bytes: 0x00, 0x00, 0x22

    # STREAMINFO block (34 bytes):
    # min block size (16 bits)
    buf.extend(struct.pack(">H", 4096))
    # max block size (16 bits)
    buf.extend(struct.pack(">H", 4096))
    # min frame size (24 bits)
    buf.extend(struct.pack(">I", 14)[1:])
    # max frame size (24 bits)
    buf.extend(struct.pack(">I", 8192)[1:])

    # 20 bits sample_rate, 3 bits (channels - 1), 5 bits (bit_depth - 1), 36 bits total_samples
    # Packed into 8 bytes (64 bits):
    # [sample_rate: 20] [channels-1: 3] [bit_depth-1: 5] [total_samples upper: 4] -> 32 bits
    # [total_samples lower: 32] -> 32 bits
    ch_bits = (channels - 1) & 0x07
    bd_bits = (bit_depth - 1) & 0x1F
    ts_upper = (total_samples >> 32) & 0x0F
    ts_lower = total_samples & 0xFFFFFFFF

    first_32 = (sample_rate << 12) | (ch_bits << 9) | (bd_bits << 4) | ts_upper
    buf.extend(struct.pack(">I", first_32))
    buf.extend(struct.pack(">I", ts_lower))

    # 16-byte MD5 signature (zeros for mock stream)
    buf.extend(b"\x00" * 16)

    return bytes(buf)


def parse_flac_header(data: bytes) -> Dict[str, Any]:
    """Parses FLAC stream header and STREAMINFO metadata block."""
    if len(data) < 42:
        raise ValueError(f"FLAC data too short: {len(data)} (expected >= 42)")
    if data[0:4] != b"fLaC":
        raise ValueError(f"Invalid FLAC magic: {data[0:4]}")

    is_last = bool(data[4] & 0x80)
    block_type = data[4] & 0x7F
    length = (data[5] << 16) | (data[6] << 8) | data[7]

    if block_type != 0:
        raise ValueError(f"Expected STREAMINFO block (0), found {block_type}")

    min_block = struct.unpack(">H", data[8:10])[0]
    max_block = struct.unpack(">H", data[10:12])[0]
    min_frame = (data[12] << 16) | (data[13] << 8) | data[14]
    max_frame = (data[15] << 16) | (data[16] << 8) | data[17]

    first_32 = struct.unpack(">I", data[18:22])[0]
    sample_rate = first_32 >> 12
    channels = ((first_32 >> 9) & 0x07) + 1
    bit_depth = ((first_32 >> 4) & 0x1F) + 1
    ts_upper = first_32 & 0x0F
    ts_lower = struct.unpack(">I", data[22:26])[0]
    total_samples = (ts_upper << 32) | ts_lower

    return {
        "is_last_metadata": is_last,
        "sample_rate": sample_rate,
        "channels": channels,
        "bit_depth": bit_depth,
        "total_samples": total_samples,
        "min_block_size": min_block,
        "max_block_size": max_block,
        "min_frame_size": min_frame,
        "max_frame_size": max_frame,
    }


def frame_dop(dsd_bytes: bytes) -> List[int]:
    """
    Packs 1-bit DSD stream bytes into 24-bit PCM DoP (DSD over PCM) words.
    Uses alternating 0x05 / 0xFA marker bytes in the upper 8 bits.
    Format of 24-bit DoP word:
    [Marker: 8 bits] [DSD Byte 0: 8 bits] [DSD Byte 1: 8 bits]
    """
    words = []
    marker_state = False  # False: 0x05, True: 0xFA
    # Process 2 DSD bytes (16 bits) per 24-bit PCM frame
    for i in range(0, len(dsd_bytes), 2):
        b0 = dsd_bytes[i]
        b1 = dsd_bytes[i+1] if (i + 1) < len(dsd_bytes) else 0x00
        marker = 0xFA if marker_state else 0x05
        marker_state = not marker_state
        word = (marker << 16) | (b0 << 8) | b1
        words.append(word)
    return words


def unframe_dop(pcm_words: List[int]) -> Tuple[bytes, bool]:
    """
    Unpacks 24-bit DoP words back into raw 1-bit DSD bytes.
    Validates that alternating 0x05 and 0xFA markers are strictly preserved.
    Returns (dsd_bytes, markers_valid).
    """
    dsd_bytes = bytearray()
    markers_valid = True
    marker_state = False

    for word in pcm_words:
        marker = (word >> 16) & 0xFF
        expected_marker = 0xFA if marker_state else 0x05
        if marker != expected_marker:
            markers_valid = False
        marker_state = not marker_state

        b0 = (word >> 8) & 0xFF
        b1 = word & 0xFF
        dsd_bytes.append(b0)
        dsd_bytes.append(b1)

    return bytes(dsd_bytes), markers_valid
