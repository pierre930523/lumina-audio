"""
Domain audio types, bitrate calculations, duration formatting, and audio format validators.
Provides standard formulas and validation rules aligning with crates/core-types.
"""
from typing import Dict, Any, List, Optional, Tuple

DSD_CODECS = {"dsf", "dsdiff"}
PCM_CODECS = {"flac", "alac", "wav", "aiff", "aac", "mp3", "opus"}


def calculate_uncompressed_bitrate(sample_rate: int, bit_depth: int, channels: int) -> int:
    """Calculates uncompressed PCM audio bitrate in bits per second: sample_rate * bit_depth * channels."""
    return sample_rate * bit_depth * channels


def uncompressed_bitrate(sample_rate: int, bit_depth: int, channels: int) -> int:
    """Alias for calculate_uncompressed_bitrate."""
    return calculate_uncompressed_bitrate(sample_rate, bit_depth, channels)


def format_duration(ms: int) -> str:
    """Formats track duration in milliseconds into human-readable mm:ss format."""
    total_seconds = ms // 1000
    minutes = total_seconds // 60
    seconds = total_seconds % 60
    return f"{minutes}:{seconds:02d}"


def format_track_duration_ms(ms: int) -> str:
    """Alias for format_duration."""
    return format_duration(ms)


def is_hi_res(sample_rate_hz: int, bit_depth: int) -> bool:
    """Classifies audio as Hi-Res if sample rate > 48 kHz or bit depth > 16 bits."""
    return (sample_rate_hz > 48000) or (bit_depth > 16)


def is_hi_res_format(sample_rate_hz: int, bit_depth: int) -> bool:
    """Alias for is_hi_res."""
    return is_hi_res(sample_rate_hz, bit_depth)


def calculate_duration_sec(total_samples: int, sample_rate_hz: int) -> float:
    """Calculates audio playback duration in seconds from sample count and sample rate."""
    return total_samples / sample_rate_hz


def calculate_pcm_duration_sec(total_samples: int, sample_rate_hz: int) -> float:
    """Alias for calculate_duration_sec."""
    return calculate_duration_sec(total_samples, sample_rate_hz)


def validate_sample_rate(sr: int) -> int:
    """Verifies sample rate is a positive integer <= 45,158,400 Hz (DSD1024)."""
    if not isinstance(sr, int) or sr <= 0:
        raise ValueError(f"Sample rate must be positive integer, got {sr}")
    if sr > 45158400:
        raise ValueError(f"Sample rate exceeds maximum supported limit: {sr}")
    return sr


def validate_bit_depth(depth: int, is_dsd: bool) -> None:
    """Verifies bit depth constraints: DSD strictly requires depth=1; PCM requires 8, 16, 24, or 32."""
    if is_dsd:
        if depth != 1:
            raise ValueError(f"DSD stream must have bit_depth=1, got {depth}")
    else:
        if depth not in (8, 16, 24, 32):
            raise ValueError(f"PCM stream unsupported bit depth: {depth}")


def validate_channels(ch: int) -> None:
    """Verifies channel count is an integer between 1 and 32."""
    if not isinstance(ch, int) or ch < 1 or ch > 32:
        raise ValueError(f"Channels must be between 1 and 32, got {ch}")


def validate_codec_format(codec: str, is_dsd: bool) -> None:
    """Verifies consistency between audio codec identifier and is_dsd flag."""
    if is_dsd and codec not in DSD_CODECS:
        raise ValueError(f"Codec {codec} cannot be flagged as is_dsd=True")
    if not is_dsd and codec in DSD_CODECS:
        raise ValueError(f"DSD codec {codec} cannot have is_dsd=False")
