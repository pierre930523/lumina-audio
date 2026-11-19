"""
Programmatic, zero-external-asset real binary fixture generators for Lumina Audio E2E tests (Phases 12-18).

Uses installed numpy, soundfile, Pillow (PIL), and pure-Python binary writers (struct)
to produce genuine, spec-compliant audio, image, and lyrics files across:
- Segmented multi-tone PCM
- FLAC (STREAMINFO, optional SEEKTABLE, VORBIS_COMMENT, PICTURE)
- MP3 (CBR w/ or w/o Info frame, VBR Xing, VBR VBRI; ID3v1, ID3v2.3, ID3v2.4)
- WAV (PCM 16/24/32, LIST/INFO, Broadcast Wave bext, trailing RIFF id3 )
- M4A / MP4 (ALAC & AAC-LC ISO BMFF with udta/meta/ilst atoms & covr)
- DSD (DSF with trailing ID3v2 + metadata_offset; DSDIFF FRM8/FVER/PROP/DIIN/DSD/ID3 )
- Images (JPEG, PNG, WebP, oversized >2048px, wrong-extension, non-cover, corrupt)
- Lyrics (standard LRC, offset LRC, enhanced LRC, plain .txt, CJK/legacy encodings, empty, corrupt)
"""
from __future__ import annotations

import io
import os
import struct
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

import numpy as np
import soundfile as sf
from PIL import Image, ImageDraw

PathLike = Union[str, Path]


# ---------------------------------------------------------------------------
# 1. Segmented Multi-Tone PCM
# ---------------------------------------------------------------------------

def generate_segmented_pcm(
    sample_rate: int = 44100,
    channels: int = 2,
    segments: Sequence[Tuple[float, float]] = ((1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)),
    amplitude: float = 0.35,
) -> np.ndarray:
    """
    Generate contiguous sine-wave segments `(duration_s, freq_hz)` as float64 array
    of shape `(total_frames, channels)`.
    """
    if sample_rate <= 0:
        raise ValueError(f"sample_rate must be > 0, got {sample_rate}")
    if channels <= 0:
        raise ValueError(f"channels must be > 0, got {channels}")
    if not segments:
        raise ValueError("segments must not be empty")

    chunks: List[np.ndarray] = []
    phase = 0.0
    for duration_s, freq_hz in segments:
        n_frames = max(1, int(round(float(sample_rate) * float(duration_s))))
        t = np.arange(n_frames, dtype=np.float64) / float(sample_rate)
        if freq_hz > 0.0:
            mono = amplitude * np.sin(phase + 2.0 * np.pi * float(freq_hz) * t)
            phase = (phase + 2.0 * np.pi * float(freq_hz) * (n_frames / float(sample_rate))) % (2.0 * np.pi)
        else:
            mono = np.zeros(n_frames, dtype=np.float64)
        chunks.append(mono)

    full_mono = np.concatenate(chunks)
    if channels == 1:
        return full_mono.reshape(-1, 1)
    return np.column_stack([full_mono for _ in range(channels)])


# ---------------------------------------------------------------------------
# 2. Images (JPEG, PNG, WebP, Oversized, Corrupt, Wrong Extension)
# ---------------------------------------------------------------------------

def generate_image_bytes(
    fmt: str = "jpeg",
    width: int = 128,
    height: int = 128,
    color: Tuple[int, int, int] = (64, 128, 224),
    corrupt: bool = False,
    accent_color: Tuple[int, int, int] = (240, 200, 80),
) -> Tuple[bytes, str]:
    """
    Generate real image bytes and canonical MIME type via Pillow, or corrupt bytes.
    Supports `fmt` in {"jpeg", "jpg", "png", "webp"}.
    """
    norm = fmt.lower().strip()
    if norm == "jpg":
        norm = "jpeg"
    mime_map = {
        "jpeg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
    }
    if norm not in mime_map:
        raise ValueError(f"Unsupported image format: {fmt}")

    mime = mime_map[norm]
    if corrupt:
        if norm == "jpeg":
            return b"\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xDB\x00", mime
        if norm == "png":
            return b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00", mime
        return b"RIFF\x20\x00\x00\x00WEBPVP8 \x10\x00\x00\x00\xDE\xAD\xBE\xEF", mime

    img = Image.new("RGB", (int(width), int(height)), color)
    draw = ImageDraw.Draw(img)
    # Deterministic distinct visual pattern so hashes differ by geometry/color
    w, h = img.size
    draw.rectangle([w // 8, h // 8, (7 * w) // 8, (7 * h) // 8], outline=accent_color, width=max(2, min(w, h) // 32))
    draw.line([(0, 0), (w - 1, h - 1)], fill=accent_color, width=max(1, min(w, h) // 48))

    buf = io.BytesIO()
    if norm == "jpeg":
        img.save(buf, format="JPEG", quality=85)
    elif norm == "png":
        img.save(buf, format="PNG", compress_level=1)
    elif norm == "webp":
        img.save(buf, format="WEBP", quality=80)
    return buf.getvalue(), mime


def generate_image_file(
    path: PathLike,
    *,
    fmt: str = "jpeg",
    width: int = 128,
    height: int = 128,
    color: Tuple[int, int, int] = (64, 128, 224),
    corrupt: bool = False,
) -> Path:
    """Write real (or corrupt) image bytes to `path` (supports Unicode paths and mismatched extensions)."""
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    raw, _ = generate_image_bytes(
        fmt=fmt,
        width=width,
        height=height,
        color=color,
        corrupt=corrupt,
    )
    out.write_bytes(raw)
    return out


# ---------------------------------------------------------------------------
# 3. Lyrics (.lrc, Enhanced .lrc, .txt, CJK/legacy encodings, empty, corrupt)
# ---------------------------------------------------------------------------

def _fmt_lrc_ts(ms: int, precision: int = 2) -> str:
    ms = max(0, int(ms))
    total_s, rem_ms = divmod(ms, 1000)
    mins, secs = divmod(total_s, 60)
    if precision == 3:
        return f"{mins:02d}:{secs:02d}.{rem_ms:03d}"
    cs = min(99, rem_ms // 10)
    return f"{mins:02d}:{secs:02d}.{cs:02d}"


def build_lrc_text(
    lines: Sequence[Tuple[int, str]],
    *,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    offset_ms: int = 0,
    enhanced: bool = False,
    precision: int = 2,
    duplicate_timestamps: Optional[Sequence[Tuple[Sequence[int], str]]] = None,
) -> str:
    """
    Build standard or enhanced LRC text.
    `lines` is a sequence of `(timestamp_ms, text)`.
    """
    out: List[str] = []
    if title is not None:
        out.append(f"[ti:{title}]")
    if artist is not None:
        out.append(f"[ar:{artist}]")
    if offset_ms != 0:
        sign = "+" if offset_ms > 0 else ""
        out.append(f"[offset:{sign}{int(offset_ms)}]")

    for idx, (ts_ms, text) in enumerate(lines):
        tag = _fmt_lrc_ts(ts_ms, precision=precision)
        if enhanced:
            words = text.split(" ") if " " in text else list(text)
            if not words:
                words = [text]
            step_ms = 350
            next_ms = lines[idx + 1][0] if idx + 1 < len(lines) else ts_ms + len(words) * 400
            avail = max(100, next_ms - ts_ms)
            step_ms = max(50, avail // max(1, len(words)))
            parts = []
            for w_idx, w in enumerate(words):
                w_ts = _fmt_lrc_ts(ts_ms + w_idx * step_ms, precision=precision)
                parts.append(f"<{w_ts}>{w}")
            joiner = " " if " " in text else ""
            out.append(f"[{tag}]{joiner.join(parts)}")
        else:
            out.append(f"[{tag}]{text}")

    if duplicate_timestamps:
        for ts_list, text in duplicate_timestamps:
            tags = "".join(f"[{_fmt_lrc_ts(t, precision=precision)}]" for t in ts_list)
            out.append(f"{tags}{text}")

    return "\n".join(out) + "\n"


def generate_lyrics_file(
    path: PathLike,
    *,
    mode: str = "lrc",
    lines: Optional[Sequence[Tuple[int, str]]] = None,
    plain_lines: Optional[Sequence[str]] = None,
    content: Optional[str] = None,
    encoding: str = "utf-8",
    title: Optional[str] = None,
    artist: Optional[str] = None,
    offset_ms: int = 0,
    precision: int = 2,
    duplicate_timestamps: Optional[Sequence[Tuple[Sequence[int], str]]] = None,
) -> Path:
    """
    Generate a lyrics file at `path`.
    `mode` in {"lrc", "enhanced_lrc", "txt", "empty", "whitespace", "corrupt"}.
    """
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    m = mode.lower().strip()

    if m == "empty":
        out.write_bytes(b"")
        return out
    if m == "whitespace":
        out.write_text("   \n\t\r\n  \n", encoding="utf-8")
        return out
    if m == "corrupt":
        out.write_bytes(b"\xff\xfe\xfd\x80[99:zz]malformed_corrupt_bytes\x81\x82\n")
        return out

    if content is not None:
        out.write_bytes(content.encode(encoding, errors="strict"))
        return out

    default_lines: List[Tuple[int, str]] = [
        (0, "Opening Instrumental"),
        (1000, "First lyric line"),
        (2000, "Second lyric line"),
    ]
    if m in ("lrc", "enhanced_lrc"):
        txt = build_lrc_text(
            lines if lines is not None else default_lines,
            title=title,
            artist=artist,
            offset_ms=offset_ms,
            enhanced=(m == "enhanced_lrc"),
            precision=precision,
            duplicate_timestamps=duplicate_timestamps,
        )
        out.write_bytes(txt.encode(encoding, errors="strict"))
        return out

    if m == "txt":
        if plain_lines is not None:
            txt = "\n".join(plain_lines) + "\n"
        elif lines is not None:
            txt = "\n".join(t for _, t in lines) + "\n"
        else:
            txt = "Plain line one\nPlain line two\nPlain line three\n"
        out.write_bytes(txt.encode(encoding, errors="strict"))
        return out

    raise ValueError(f"Unsupported lyrics mode: {mode}")


# ---------------------------------------------------------------------------
# 4. ID3v1 & ID3v2.3 / ID3v2.4 Builders
# ---------------------------------------------------------------------------

def encode_synchsafe(value: int) -> bytes:
    return bytes(
        [
            (value >> 21) & 0x7F,
            (value >> 14) & 0x7F,
            (value >> 7) & 0x7F,
            value & 0x7F,
        ]
    )


def build_id3v1_tag(
    *,
    title: str = "",
    artist: str = "",
    album: str = "",
    year: str = "",
    comment: str = "",
    track: int = 0,
    genre_id: int = 12,
    encoding: str = "latin-1",
) -> bytes:
    """Build a strict 128-byte ID3v1 / ID3v1.1 trailing tag block."""
    def _pad(text: str, width: int) -> bytes:
        raw = text.encode(encoding, errors="replace")[:width]
        return raw + b"\x00" * (width - len(raw))

    if track > 0:
        comment_block = _pad(comment, 28) + b"\x00" + bytes([track & 0xFF])
    else:
        comment_block = _pad(comment, 30)

    tag = (
        b"TAG"
        + _pad(title, 30)
        + _pad(artist, 30)
        + _pad(album, 30)
        + _pad(year, 4)
        + comment_block
        + bytes([genre_id & 0xFF])
    )
    assert len(tag) == 128
    return tag


def _encode_id3_text_bytes(
    text: str,
    text_encoding: str = "utf-8",
    legacy_codepage: Optional[str] = None,
) -> Tuple[int, bytes, bytes]:
    """
    Returns `(encoding_byte, encoded_bytes_without_terminator, terminator_bytes)`.
    """
    enc = text_encoding.lower().strip()
    if legacy_codepage:
        return 0x00, text.encode(legacy_codepage, errors="replace"), b"\x00"
    if enc in ("latin-1", "iso-8859-1", "ascii"):
        return 0x00, text.encode("latin-1", errors="replace"), b"\x00"
    if enc in ("utf-16", "utf-16-le", "utf16le", "utf-16le"):
        return 0x01, b"\xff\xfe" + text.encode("utf-16-le"), b"\x00\x00"
    if enc in ("utf-16-be", "utf16be", "utf-16be"):
        return 0x02, text.encode("utf-16-be"), b"\x00\x00"
    # Default UTF-8 (0x03)
    return 0x03, text.encode("utf-8"), b"\x00"


def build_id3v2_tag(
    *,
    version: int = 4,
    text_encoding: str = "utf-8",
    legacy_codepage: Optional[str] = None,
    text_frames: Optional[Dict[str, str]] = None,
    txxx_frames: Optional[Dict[str, str]] = None,
    apic_list: Optional[Sequence[Tuple[bytes, str, int, str]]] = None,
    uslt: Optional[Tuple[str, str, str]] = None,
    sylt: Optional[Tuple[Sequence[Tuple[int, str]], str, str]] = None,
) -> bytes:
    """
    Build a complete ID3v2.3 (`version=3`) or ID3v2.4 (`version=4`) tag block.
    - `apic_list`: sequence of `(image_bytes, mime_type, pic_type, description)` where `pic_type=3` is Front Cover, `4` is Back Cover.
    - `uslt`: `(lyrics_text, lang3, description)`
    - `sylt`: `(lines_of_ms_text, lang3, description)`
    """
    if version not in (3, 4):
        raise ValueError(f"Unsupported ID3v2 version: {version}")

    if version == 3 and text_encoding.lower().strip() in ("utf-8", "utf-16-be", "utf16be"):
        effective_enc = "utf-16-le" if not legacy_codepage else "latin-1"
    else:
        effective_enc = text_encoding

    def _pack_frame(frame_id: str, payload: bytes) -> bytes:
        fid = frame_id.encode("ascii")[:4]
        size_bytes = struct.pack(">I", len(payload)) if version == 3 else encode_synchsafe(len(payload))
        return fid + size_bytes + b"\x00\x00" + payload

    frames = bytearray()

    for fid, val in (text_frames or {}).items():
        if val is None or val == "":
            continue
        actual_fid = fid
        if version == 3 and fid == "TDRC":
            actual_fid = "TYER"
        elif version == 4 and fid == "TYER":
            actual_fid = "TDRC"
        enc_b, raw, _ = _encode_id3_text_bytes(str(val), effective_enc, legacy_codepage)
        frames.extend(_pack_frame(actual_fid, bytes([enc_b]) + raw))

    for desc, val in (txxx_frames or {}).items():
        if val is None or val == "":
            continue
        enc_b, d_raw, term = _encode_id3_text_bytes(str(desc), effective_enc, legacy_codepage)
        _, v_raw, _ = _encode_id3_text_bytes(str(val), effective_enc, legacy_codepage)
        payload = bytes([enc_b]) + d_raw + term + v_raw
        frames.extend(_pack_frame("TXXX", payload))

    for img_bytes, mime, pic_type, desc in (apic_list or ()):
        enc_b, d_raw, term = _encode_id3_text_bytes(desc or "", effective_enc, legacy_codepage)
        mime_b = mime.encode("ascii") + b"\x00"
        payload = bytes([enc_b]) + mime_b + bytes([pic_type & 0xFF]) + d_raw + term + img_bytes
        frames.extend(_pack_frame("APIC", payload))

    if uslt is not None:
        lyrics_text, lang, desc = uslt
        lang_b = (lang or "und").encode("ascii", errors="replace")[:3].ljust(3, b" ")
        enc_b, d_raw, term = _encode_id3_text_bytes(desc or "", effective_enc, legacy_codepage)
        _, l_raw, _ = _encode_id3_text_bytes(lyrics_text, effective_enc, legacy_codepage)
        payload = bytes([enc_b]) + lang_b + d_raw + term + l_raw
        frames.extend(_pack_frame("USLT", payload))

    if sylt is not None:
        sylt_lines, lang, desc = sylt
        lang_b = (lang or "und").encode("ascii", errors="replace")[:3].ljust(3, b" ")
        enc_b, d_raw, term = _encode_id3_text_bytes(desc or "", effective_enc, legacy_codepage)
        body = bytearray()
        body.append(enc_b)
        body.extend(lang_b)
        body.append(0x02)  # timestamp format: milliseconds
        body.append(0x01)  # content type: lyrics
        body.extend(d_raw)
        body.extend(term)
        for ts_ms, line_text in sylt_lines:
            _, t_raw, t_term = _encode_id3_text_bytes(line_text, effective_enc, legacy_codepage)
            body.extend(t_raw)
            body.extend(t_term)
            body.extend(struct.pack(">I", max(0, int(ts_ms))))
        frames.extend(_pack_frame("SYLT", bytes(body)))

    if not frames:
        return b""

    header = b"ID3" + bytes([version, 0, 0]) + encode_synchsafe(len(frames))
    return header + bytes(frames)


# ---------------------------------------------------------------------------
# 5. FLAC Generator (STREAMINFO, real SEEKTABLE, VORBIS_COMMENT, PICTURE)
# ---------------------------------------------------------------------------

def _flac_crc8(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


def _decode_utf8_uint64(buf: bytes, pos: int) -> Optional[Tuple[int, int]]:
    if pos >= len(buf):
        return None
    first = buf[pos]
    if first < 0x80:
        return first, pos + 1
    if (first & 0xE0) == 0xC0:
        n = 2
        val = first & 0x1F
    elif (first & 0xF0) == 0xE0:
        n = 3
        val = first & 0x0F
    elif (first & 0xF8) == 0xF0:
        n = 4
        val = first & 0x07
    elif (first & 0xFC) == 0xF8:
        n = 5
        val = first & 0x03
    elif (first & 0xFE) == 0xFC:
        n = 6
        val = first & 0x01
    elif first == 0xFE:
        n = 7
        val = 0
    else:
        return None

    if pos + n > len(buf):
        return None
    for i in range(1, n):
        b = buf[pos + i]
        if (b & 0xC0) != 0x80:
            return None
        val = (val << 6) | (b & 0x3F)
    return val, pos + n


def _parse_flac_frame_offsets(
    audio_frames: bytes, streaminfo: bytes
) -> List[Tuple[int, int, int]]:
    """
    Scan raw FLAC audio frames using header sync + CRC-8 validation to extract
    exact `(sample_offset, byte_offset_from_audio_start, block_samples)` tuples.
    """
    # STREAMINFO: bytes 10..18 store sample_rate(20b), channels-1(3b), bps-1(5b), total_samples(36b)
    if len(streaminfo) < 34:
        return []
    si_sr = ((streaminfo[10] << 12) | (streaminfo[11] << 4) | (streaminfo[12] >> 4))

    bs_table = {
        1: 192,
        2: 576, 3: 1152, 4: 2304, 5: 4608,
        8: 256, 9: 512, 10: 1024, 11: 2048, 12: 4096, 13: 8192, 14: 16384, 15: 32768,
    }

    points: List[Tuple[int, int, int]] = []
    pos = 0
    n = len(audio_frames)
    expected_sample = 0

    while pos + 6 <= n:
        if audio_frames[pos] == 0xFF and (audio_frames[pos + 1] & 0xFC) == 0xF8:
            b1 = audio_frames[pos + 1]
            b2 = audio_frames[pos + 2]
            b3 = audio_frames[pos + 3]
            bs_code = (b2 >> 4) & 0x0F
            sr_code = b2 & 0x0F
            reserved = b3 & 0x01
            if bs_code != 0 and sr_code != 15 and reserved == 0:
                blocking_strategy = b1 & 0x01
                utf8_res = _decode_utf8_uint64(audio_frames, pos + 4)
                if utf8_res is not None:
                    coded_val, cursor = utf8_res
                    block_samples = bs_table.get(bs_code)
                    valid = True
                    if bs_code == 6:
                        if cursor + 1 <= n:
                            block_samples = audio_frames[cursor] + 1
                            cursor += 1
                        else:
                            valid = False
                    elif bs_code == 7:
                        if cursor + 2 <= n:
                            block_samples = int.from_bytes(audio_frames[cursor : cursor + 2], "big") + 1
                            cursor += 2
                        else:
                            valid = False
                    if valid:
                        if sr_code == 12:
                            cursor += 1
                        elif sr_code in (13, 14):
                            cursor += 2
                        if cursor < n:
                            hdr_crc = audio_frames[cursor]
                            if _flac_crc8(audio_frames[pos:cursor]) == hdr_crc:
                                sample_off = coded_val if blocking_strategy == 1 else expected_sample
                                if block_samples and (not points or sample_off >= expected_sample):
                                    points.append((sample_off, pos, block_samples))
                                    expected_sample = sample_off + block_samples
                                    pos = cursor + 1
                                    continue
        pos += 1

    _ = si_sr
    return points


def generate_flac_fixture(
    path: PathLike,
    *,
    sample_rate: int = 44100,
    channels: int = 2,
    bit_depth: int = 16,
    duration_ms: int = 1500,
    freq_hz: float = 440.0,
    segments: Optional[Sequence[Tuple[float, float]]] = None,
    with_seektable: bool = True,
    seek_interval_ms: int = 250,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    album_artist: Optional[str] = None,
    genre: Optional[str] = None,
    year: Optional[Union[int, str]] = None,
    track_number: Optional[Union[int, str]] = None,
    disc_number: Optional[Union[int, str]] = None,
    composer: Optional[str] = None,
    isrc: Optional[str] = None,
    replaygain_track_gain: Optional[str] = None,
    replaygain_track_peak: Optional[str] = None,
    replaygain_album_gain: Optional[str] = None,
    replaygain_album_peak: Optional[str] = None,
    lyrics: Optional[str] = None,
    unsynced_lyrics: Optional[str] = None,
    synced_lyrics: Optional[str] = None,
    extra_tags: Optional[Dict[str, str]] = None,
    pictures: Optional[Sequence[Tuple[bytes, str, int, str]]] = None,
) -> Path:
    """
    Generate a genuine libFLAC file with STREAMINFO, optional real SEEKTABLE (type 3),
    VORBIS_COMMENT (type 4), and PICTURE (type 6) blocks.
    `pictures`: sequence of `(image_bytes, mime_type, pic_type, description)` where `pic_type=3` is Front Cover.
    """
    subtype_map = {16: "PCM_16", 24: "PCM_24"}
    if bit_depth not in subtype_map:
        raise ValueError(f"Unsupported FLAC bit_depth={bit_depth}; expected 16 or 24")

    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if segments is not None:
        audio = generate_segmented_pcm(sample_rate, channels, segments)
    else:
        audio = generate_segmented_pcm(sample_rate, channels, ((duration_ms / 1000.0, freq_hz),))

    buf = io.BytesIO()
    with sf.SoundFile(
        buf,
        mode="w",
        samplerate=sample_rate,
        channels=channels,
        subtype=subtype_map[bit_depth],
        format="FLAC",
    ) as flac:
        flac.write(audio)

    flac_bytes = buf.getvalue()
    if not flac_bytes.startswith(b"fLaC"):
        raise RuntimeError("soundfile did not produce valid fLaC stream")

    offset = 4
    streaminfo_payload: Optional[bytes] = None
    while offset + 4 <= len(flac_bytes):
        hdr = flac_bytes[offset]
        is_last = bool(hdr & 0x80)
        btype = hdr & 0x7F
        blen = int.from_bytes(flac_bytes[offset + 1 : offset + 4], "big")
        offset += 4
        payload = flac_bytes[offset : offset + blen]
        offset += blen
        if btype == 0 and streaminfo_payload is None:
            streaminfo_payload = payload
        if is_last:
            break

    if streaminfo_payload is None:
        raise RuntimeError("Missing FLAC STREAMINFO block")
    audio_frames = flac_bytes[offset:]

    blocks: List[Tuple[int, bytes]] = [(0, streaminfo_payload)]

    if with_seektable:
        frame_pts = _parse_flac_frame_offsets(audio_frames, streaminfo_payload)
        interval_samples = max(1, int(sample_rate * (seek_interval_ms / 1000.0)))
        selected: List[Tuple[int, int, int]] = []
        next_target = 0
        for s_off, b_off, b_samples in frame_pts:
            if s_off >= next_target:
                selected.append((s_off, b_off, b_samples))
                next_target = s_off + interval_samples
        if frame_pts and not selected:
            selected.append(frame_pts[0])
        if selected:
            st_buf = bytearray()
            for s_off, b_off, b_samples in selected:
                st_buf.extend(struct.pack(">QQH", s_off, b_off, b_samples))
            blocks.append((3, bytes(st_buf)))

    tags: List[Tuple[str, str]] = []
    for k, v in (
        ("TITLE", title),
        ("ARTIST", artist),
        ("ALBUM", album),
        ("ALBUMARTIST", album_artist),
        ("GENRE", genre),
        ("DATE", year),
        ("TRACKNUMBER", track_number),
        ("DISCNUMBER", disc_number),
        ("COMPOSER", composer),
        ("ISRC", isrc),
        ("REPLAYGAIN_TRACK_GAIN", replaygain_track_gain),
        ("REPLAYGAIN_TRACK_PEAK", replaygain_track_peak),
        ("REPLAYGAIN_ALBUM_GAIN", replaygain_album_gain),
        ("REPLAYGAIN_ALBUM_PEAK", replaygain_album_peak),
        ("LYRICS", lyrics),
        ("UNSYNCEDLYRICS", unsynced_lyrics),
        ("SYNCEDLYRICS", synced_lyrics),
    ):
        if v is not None:
            tags.append((k, str(v)))
    if extra_tags:
        for k, v in extra_tags.items():
            if v is not None:
                tags.append((str(k).upper(), str(v)))

    if tags:
        vendor = b"Lumina E2E Fixture"
        vc = bytearray()
        vc.extend(struct.pack("<I", len(vendor)))
        vc.extend(vendor)
        vc.extend(struct.pack("<I", len(tags)))
        for k, v in tags:
            entry = f"{k}={v}".encode("utf-8")
            vc.extend(struct.pack("<I", len(entry)))
            vc.extend(entry)
        blocks.append((4, bytes(vc)))

    for img_bytes, mime, pic_type, desc in (pictures or ()):
        mime_b = mime.encode("ascii")
        desc_b = (desc or "").encode("utf-8")
        w, h = 0, 0
        try:
            with Image.open(io.BytesIO(img_bytes)) as im:
                w, h = im.size
        except Exception:
            pass
        pic = bytearray()
        pic.extend(struct.pack(">I", pic_type))
        pic.extend(struct.pack(">I", len(mime_b)))
        pic.extend(mime_b)
        pic.extend(struct.pack(">I", len(desc_b)))
        pic.extend(desc_b)
        pic.extend(struct.pack(">IIII", w, h, 24, 0))
        pic.extend(struct.pack(">I", len(img_bytes)))
        pic.extend(img_bytes)
        blocks.append((6, bytes(pic)))

    out = bytearray(b"fLaC")
    for idx, (btype, payload) in enumerate(blocks):
        last_flag = 0x80 if idx == len(blocks) - 1 else 0x00
        out.append(last_flag | (btype & 0x7F))
        out.extend(len(payload).to_bytes(3, "big"))
        out.extend(payload)
    out.extend(audio_frames)

    out_path.write_bytes(bytes(out))
    return out_path


# ---------------------------------------------------------------------------
# 6. MP3 Generator (CBR, VBR Xing, VBR VBRI; ID3v1, ID3v2.3, ID3v2.4)
# ---------------------------------------------------------------------------

_MPEG1_L3_BITRATES = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
_MPEG1_SAMPLERATES = [44100, 48000, 32000, 0]


def _split_mpeg1_l3_frames(mp3_bytes: bytes) -> List[bytes]:
    frames: List[bytes] = []
    pos = 0
    n = len(mp3_bytes)
    while pos + 4 <= n:
        b0, b1, b2, _b3 = mp3_bytes[pos : pos + 4]
        if b0 == 0xFF and (b1 & 0xE0) == 0xE0:
            version_id = (b1 >> 3) & 0x03
            layer_id = (b1 >> 1) & 0x03
            br_idx = (b2 >> 4) & 0x0F
            sr_idx = (b2 >> 2) & 0x03
            pad = (b2 >> 1) & 0x01
            if version_id == 3 and layer_id == 1 and br_idx not in (0, 15) and sr_idx != 3:
                br = _MPEG1_L3_BITRATES[br_idx]
                sr = _MPEG1_SAMPLERATES[sr_idx]
                flen = (144 * br * 1000) // sr + pad
                if pos + flen <= n:
                    frames.append(mp3_bytes[pos : pos + flen])
                    pos += flen
                    continue
        pos += 1
    return frames


def _build_vbri_frame(sample_rate: int, channels: int, audio_frames: Sequence[bytes]) -> bytes:
    """Construct a valid MPEG-1 Layer III 160kbps frame 0 containing a VBRI TOC."""
    if sample_rate == 48000:
        sr_idx = 1
    elif sample_rate == 32000:
        sr_idx = 2
    else:
        sample_rate = 44100
        sr_idx = 0

    br_idx = 10  # 160 kbps
    ch_mode = 0 if channels >= 2 else 3
    flen = (144 * 160 * 1000) // sample_rate
    hdr = bytes(
        [
            0xFF,
            0xFB,  # MPEG1, Layer III, no CRC
            (br_idx << 4) | (sr_idx << 2),
            (ch_mode << 6),
        ]
    )
    frame = bytearray(flen)
    frame[0:4] = hdr

    # VBRI sits at byte 36 (after 4B header + 32B side-info) for MPEG-1
    vbri_off = 36
    total_frames = len(audio_frames)
    total_bytes = sum(len(f) for f in audio_frames)

    # Build up to 20 TOC entries with 4-byte sizes
    toc_count = min(20, max(1, total_frames))
    frames_per_entry = max(1, (total_frames + toc_count - 1) // toc_count)
    toc_sizes: List[int] = []
    idx = 0
    while idx < total_frames:
        chunk_bytes = sum(len(f) for f in audio_frames[idx : idx + frames_per_entry])
        toc_sizes.append(chunk_bytes)
        idx += frames_per_entry

    # Ensure VBRI + TOC fits inside the 160kbps frame; shrink toc_count if needed
    max_toc = max(1, (flen - vbri_off - 26) // 4)
    if len(toc_sizes) > max_toc:
        frames_per_entry = max(1, (total_frames + max_toc - 1) // max_toc)
        toc_sizes = []
        idx = 0
        while idx < total_frames:
            toc_sizes.append(sum(len(f) for f in audio_frames[idx : idx + frames_per_entry]))
            idx += frames_per_entry

    vbri_hdr = b"VBRI" + struct.pack(
        ">HHHIIHHHH",
        1,  # version
        0,  # delay
        50,  # quality
        total_bytes,
        total_frames,
        len(toc_sizes),
        1,  # scale
        4,  # entry size
        frames_per_entry,
    )
    frame[vbri_off : vbri_off + len(vbri_hdr)] = vbri_hdr
    cursor = vbri_off + len(vbri_hdr)
    for sz in toc_sizes:
        frame[cursor : cursor + 4] = struct.pack(">I", sz)
        cursor += 4
    return bytes(frame)


def generate_mp3_fixture(
    path: PathLike,
    *,
    mode: str = "cbr",
    strip_info_header: bool = False,
    sample_rate: int = 44100,
    channels: int = 2,
    duration_ms: int = 1500,
    freq_hz: float = 440.0,
    segments: Optional[Sequence[Tuple[float, float]]] = None,
    id3_version: Optional[int] = 4,
    text_encoding: str = "utf-8",
    legacy_codepage: Optional[str] = None,
    with_id3v1: bool = False,
    id3v1_override: Optional[Dict[str, Any]] = None,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    album_artist: Optional[str] = None,
    genre: Optional[str] = None,
    year: Optional[Union[int, str]] = None,
    track_number: Optional[Union[int, str]] = None,
    disc_number: Optional[Union[int, str]] = None,
    composer: Optional[str] = None,
    isrc: Optional[str] = None,
    replaygain_track_gain: Optional[str] = None,
    replaygain_track_peak: Optional[str] = None,
    replaygain_album_gain: Optional[str] = None,
    replaygain_album_peak: Optional[str] = None,
    apic_list: Optional[Sequence[Tuple[bytes, str, int, str]]] = None,
    uslt: Optional[Tuple[str, str, str]] = None,
    sylt: Optional[Tuple[Sequence[Tuple[int, str]], str, str]] = None,
) -> Path:
    """
    Generate a genuine MPEG-1 Layer III MP3 file (`mode` in {"cbr", "vbr_xing", "vbr_vbri"})
    with optional ID3v2.3 / ID3v2.4 and trailing ID3v1 tags.
    """
    m = mode.lower().strip()
    if m not in ("cbr", "vbr_xing", "vbr_vbri"):
        raise ValueError(f"Unsupported MP3 mode: {mode}")

    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if segments is not None:
        audio = generate_segmented_pcm(sample_rate, channels, segments)
    else:
        audio = generate_segmented_pcm(sample_rate, channels, ((duration_ms / 1000.0, freq_hz),))

    buf = io.BytesIO()
    bitrate_mode = "CONSTANT" if m == "cbr" else "VARIABLE"
    with sf.SoundFile(
        buf,
        mode="w",
        samplerate=sample_rate,
        channels=channels,
        subtype="MPEG_LAYER_III",
        format="MP3",
        bitrate_mode=bitrate_mode,
    ) as mp3:
        mp3.write(audio)

    raw_mp3 = buf.getvalue()
    frames = _split_mpeg1_l3_frames(raw_mp3)
    if not frames:
        raise RuntimeError("soundfile produced no MPEG-1 Layer III frames")

    if m == "cbr":
        if strip_info_header and len(frames) > 1 and (b"Info" in frames[0] or b"Xing" in frames[0]):
            audio_blob = b"".join(frames[1:])
        else:
            audio_blob = b"".join(frames)
    elif m == "vbr_xing":
        audio_blob = b"".join(frames)
    else:
        # vbr_vbri: replace frame 0 (Xing) with valid VBRI TOC frame
        body_frames = frames[1:] if len(frames) > 1 and (b"Xing" in frames[0] or b"Info" in frames[0]) else frames
        vbri_frame = _build_vbri_frame(sample_rate, channels, body_frames)
        audio_blob = vbri_frame + b"".join(body_frames)

    id3v2_blob = b""
    if id3_version is not None:
        text_frames: Dict[str, str] = {}
        if title is not None:
            text_frames["TIT2"] = str(title)
        if artist is not None:
            text_frames["TPE1"] = str(artist)
        if album is not None:
            text_frames["TALB"] = str(album)
        if album_artist is not None:
            text_frames["TPE2"] = str(album_artist)
        if genre is not None:
            text_frames["TCON"] = str(genre)
        if year is not None:
            text_frames["TDRC" if id3_version == 4 else "TYER"] = str(year)
        if track_number is not None:
            text_frames["TRCK"] = str(track_number)
        if disc_number is not None:
            text_frames["TPOS"] = str(disc_number)
        if composer is not None:
            text_frames["TCOM"] = str(composer)
        if isrc is not None:
            text_frames["TSRC"] = str(isrc)

        txxx_frames: Dict[str, str] = {}
        if replaygain_track_gain is not None:
            txxx_frames["REPLAYGAIN_TRACK_GAIN"] = str(replaygain_track_gain)
        if replaygain_track_peak is not None:
            txxx_frames["REPLAYGAIN_TRACK_PEAK"] = str(replaygain_track_peak)
        if replaygain_album_gain is not None:
            txxx_frames["REPLAYGAIN_ALBUM_GAIN"] = str(replaygain_album_gain)
        if replaygain_album_peak is not None:
            txxx_frames["REPLAYGAIN_ALBUM_PEAK"] = str(replaygain_album_peak)

        id3v2_blob = build_id3v2_tag(
            version=id3_version,
            text_encoding=text_encoding,
            legacy_codepage=legacy_codepage,
            text_frames=text_frames,
            txxx_frames=txxx_frames,
            apic_list=apic_list,
            uslt=uslt,
            sylt=sylt,
        )

    id3v1_blob = b""
    if with_id3v1:
        ov = id3v1_override or {}
        id3v1_blob = build_id3v1_tag(
            title=str(ov.get("title", title or "")),
            artist=str(ov.get("artist", artist or "")),
            album=str(ov.get("album", album or "")),
            year=str(ov.get("year", year or "")),
            comment=str(ov.get("comment", "")),
            track=int(ov.get("track", 0) or 0),
            genre_id=int(ov.get("genre_id", 12)),
            encoding=str(ov.get("encoding", legacy_codepage or "latin-1")),
        )

    out_path.write_bytes(id3v2_blob + audio_blob + id3v1_blob)
    return out_path


# ---------------------------------------------------------------------------
# 7. WAV Generator (PCM 16/24/32, LIST/INFO, Broadcast Wave bext, id3 )
# ---------------------------------------------------------------------------

def _build_bext_chunk(
    description: str = "Lumina Broadcast Wave",
    originator: str = "Lumina E2E",
    origination_date: str = "2026-11-18",
    origination_time: str = "12:00:00",
    coding_history: str = "A=PCM,F=44100,W=16,M=stereo\r\n",
) -> bytes:
    """Build a valid Broadcast Wave Format (EBU Tech 3285) `bext` payload (602B fixed + history)."""
    def _fix(s: str, n: int) -> bytes:
        b = s.encode("ascii", errors="replace")[:n]
        return b + b"\x00" * (n - len(b))

    fixed = (
        _fix(description, 256)
        + _fix(originator, 32)
        + _fix("LUMINA_REF_001", 32)
        + _fix(origination_date, 10)
        + _fix(origination_time, 8)
        + struct.pack("<II", 0, 0)  # TimeReferenceLow, TimeReferenceHigh
        + struct.pack("<H", 1)  # BWF Version 1
        + b"\x00" * 64  # UMID
        + struct.pack("<HHHHH", 0, 0, 0, 0, 0)  # Loudness fields
        + b"\x00" * 180  # Reserved
    )
    assert len(fixed) == 602
    hist = coding_history.encode("ascii", errors="replace")
    if not hist.endswith(b"\x00"):
        hist += b"\x00"
    return fixed + hist


def generate_wav_fixture(
    path: PathLike,
    *,
    sample_rate: int = 44100,
    channels: int = 2,
    bit_depth: int = 16,
    duration_ms: int = 1500,
    freq_hz: float = 440.0,
    segments: Optional[Sequence[Tuple[float, float]]] = None,
    with_info: bool = True,
    with_bext: bool = False,
    with_id3: bool = True,
    id3_version: int = 4,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    album_artist: Optional[str] = None,
    genre: Optional[str] = None,
    year: Optional[Union[int, str]] = None,
    track_number: Optional[Union[int, str]] = None,
    disc_number: Optional[Union[int, str]] = None,
    composer: Optional[str] = None,
    isrc: Optional[str] = None,
    replaygain_track_gain: Optional[str] = None,
    replaygain_track_peak: Optional[str] = None,
    replaygain_album_gain: Optional[str] = None,
    replaygain_album_peak: Optional[str] = None,
    apic_list: Optional[Sequence[Tuple[bytes, str, int, str]]] = None,
    uslt: Optional[Tuple[str, str, str]] = None,
    bext_description: str = "Lumina Broadcast Wave",
    bext_originator: str = "Lumina E2E",
) -> Path:
    """
    Generate a real PCM RIFF/WAVE file with optional LIST/INFO, Broadcast Wave `bext`,
    and trailing even-padded `id3 ` chunk.
    """
    subtype_map = {16: "PCM_16", 24: "PCM_24", 32: "PCM_32"}
    if bit_depth not in subtype_map:
        raise ValueError(f"Unsupported WAV bit_depth={bit_depth}; expected 16, 24, or 32")

    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if segments is not None:
        audio = generate_segmented_pcm(sample_rate, channels, segments)
    else:
        audio = generate_segmented_pcm(sample_rate, channels, ((duration_ms / 1000.0, freq_hz),))

    buf = io.BytesIO()
    with sf.SoundFile(
        buf,
        mode="w",
        samplerate=sample_rate,
        channels=channels,
        subtype=subtype_map[bit_depth],
        format="WAV",
    ) as wav:
        if with_info:
            if title is not None:
                wav.title = str(title)
            if artist is not None:
                wav.artist = str(artist)
            if album is not None:
                wav.album = str(album)
            if year is not None:
                wav.date = str(year)
            if track_number is not None:
                wav.tracknumber = str(track_number)
            if genre is not None:
                wav.genre = str(genre)
        wav.write(audio)

    data = bytearray(buf.getvalue())

    def _append_riff_chunk(chunk_id: bytes, payload: bytes) -> None:
        if len(data) % 2 == 1:
            data.append(0)
        data.extend(chunk_id[:4])
        data.extend(struct.pack("<I", len(payload)))
        data.extend(payload)
        if len(payload) % 2 == 1:
            data.append(0)

    if with_bext:
        bext_payload = _build_bext_chunk(
            description=bext_description,
            originator=bext_originator,
        )
        _append_riff_chunk(b"bext", bext_payload)

    if with_id3:
        text_frames: Dict[str, str] = {}
        if title is not None:
            text_frames["TIT2"] = str(title)
        if artist is not None:
            text_frames["TPE1"] = str(artist)
        if album is not None:
            text_frames["TALB"] = str(album)
        if album_artist is not None:
            text_frames["TPE2"] = str(album_artist)
        if genre is not None:
            text_frames["TCON"] = str(genre)
        if year is not None:
            text_frames["TDRC" if id3_version == 4 else "TYER"] = str(year)
        if track_number is not None:
            text_frames["TRCK"] = str(track_number)
        if disc_number is not None:
            text_frames["TPOS"] = str(disc_number)
        if composer is not None:
            text_frames["TCOM"] = str(composer)
        if isrc is not None:
            text_frames["TSRC"] = str(isrc)

        txxx_frames: Dict[str, str] = {}
        if replaygain_track_gain is not None:
            txxx_frames["REPLAYGAIN_TRACK_GAIN"] = str(replaygain_track_gain)
        if replaygain_track_peak is not None:
            txxx_frames["REPLAYGAIN_TRACK_PEAK"] = str(replaygain_track_peak)
        if replaygain_album_gain is not None:
            txxx_frames["REPLAYGAIN_ALBUM_GAIN"] = str(replaygain_album_gain)
        if replaygain_album_peak is not None:
            txxx_frames["REPLAYGAIN_ALBUM_PEAK"] = str(replaygain_album_peak)

        id3_blob = build_id3v2_tag(
            version=id3_version,
            text_frames=text_frames,
            txxx_frames=txxx_frames,
            apic_list=apic_list,
            uslt=uslt,
        )
        if id3_blob:
            _append_riff_chunk(b"id3 ", id3_blob)

    struct.pack_into("<I", data, 4, len(data) - 8)
    out_path.write_bytes(bytes(data))
    return out_path


# ---------------------------------------------------------------------------
# 8. M4A / MP4 Generator (ALAC & AAC-LC + udta/meta/ilst + covr)
# ---------------------------------------------------------------------------

def _bmff_box(tag: bytes, payload: bytes) -> bytes:
    assert len(tag) == 4
    return struct.pack(">I", 8 + len(payload)) + tag + payload


def _bmff_fullbox(tag: bytes, version: int, flags: int, payload: bytes) -> bytes:
    hdr = bytes([version & 0xFF]) + (flags & 0xFFFFFF).to_bytes(3, "big")
    return _bmff_box(tag, hdr + payload)


class _MsbBitWriter:
    def __init__(self) -> None:
        self._buf = bytearray()
        self._cur = 0
        self._bits = 0

    def write_bits(self, value: int, num_bits: int) -> None:
        for i in range(num_bits - 1, -1, -1):
            self._cur = (self._cur << 1) | ((value >> i) & 1)
            self._bits += 1
            if self._bits == 8:
                self._buf.append(self._cur)
                self._cur = 0
                self._bits = 0

    def finish(self) -> bytes:
        if self._bits > 0:
            self._cur <<= 8 - self._bits
            self._buf.append(self._cur)
            self._cur = 0
            self._bits = 0
        return bytes(self._buf)


def _encode_alac_uncompressed_packet(pcm_chunk: np.ndarray, bit_depth: int) -> bytes:
    """
    Encode stereo (or mono) float64 PCM chunk (`<= 4096` frames) into a valid
    uncompressed ALAC frame matching Symphonia's ALAC decoder (`symphonia-codec-alac`).
    """
    n_samples, channels = pcm_chunk.shape
    bw = _MsbBitWriter()
    if channels == 1:
        bw.write_bits(0, 3)  # SCE
    elif channels == 2:
        bw.write_bits(1, 3)  # CPE
    else:
        raise ValueError("ALAC fixture supports 1 or 2 channels")

    bw.write_bits(0, 4)   # element instance tag
    bw.write_bits(0, 12)  # unused
    is_partial = 1 if n_samples != 4096 else 0
    bw.write_bits(is_partial, 1)
    bw.write_bits(0, 2)   # shift = 0
    bw.write_bits(1, 1)   # is_uncompressed = 1
    if is_partial:
        bw.write_bits(n_samples, 32)

    scale = float((1 << (bit_depth - 1)) - 1)
    mask = (1 << bit_depth) - 1
    clipped = np.clip(pcm_chunk, -1.0, 1.0)
    ints = np.round(clipped * scale).astype(np.int64)

    for i in range(n_samples):
        for ch in range(channels):
            bw.write_bits(int(ints[i, ch]) & mask, bit_depth)

    bw.write_bits(7, 3)  # ALAC_ELEM_TAG_END
    return bw.finish()


def _encode_aac_audio_specific_config(sample_rate: int, channels: int) -> bytes:
    sr_table = [
        96000, 88200, 64000, 48000, 44100, 32000,
        24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ]
    sr_idx = sr_table.index(sample_rate) if sample_rate in sr_table else 4
    aot = 2  # AAC-LC
    val = (aot << 11) | (sr_idx << 7) | (channels << 3)
    return struct.pack(">H", val)


def _build_esds_box(sample_rate: int, channels: int) -> bytes:
    asc = _encode_aac_audio_specific_config(sample_rate, channels)
    dec_spec_info = bytes([0x05, len(asc)]) + asc
    dec_cfg_body = (
        bytes([0x40, 0x15])  # objectTypeIndication=0x40 (MPEG-4 Audio), streamType=0x05<<2|1
        + b"\x00\x00\x00"    # bufferSizeDB
        + struct.pack(">II", 128000, 128000)
        + dec_spec_info
    )
    dec_cfg = bytes([0x04, len(dec_cfg_body)]) + dec_cfg_body
    sl_cfg = bytes([0x06, 0x01, 0x02])
    es_body = struct.pack(">H", 1) + b"\x00" + dec_cfg + sl_cfg
    es_desc = bytes([0x03, len(es_body)]) + es_body
    return _bmff_fullbox(b"esds", 0, 0, es_desc)


def _build_ilst_atoms(
    *,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album_artist: Optional[str] = None,
    album: Optional[str] = None,
    genre: Optional[str] = None,
    year: Optional[Union[int, str]] = None,
    composer: Optional[str] = None,
    lyrics: Optional[str] = None,
    track_number: Optional[int] = None,
    track_total: int = 0,
    disc_number: Optional[int] = None,
    disc_total: int = 0,
    cover_bytes: Optional[bytes] = None,
    cover_mime: str = "image/jpeg",
    replaygain_tags: Optional[Dict[str, str]] = None,
) -> bytes:
    items = bytearray()

    def _data_box(data_type: int, payload: bytes) -> bytes:
        return _bmff_box(b"data", struct.pack(">II", data_type, 0) + payload)

    def _add_utf8(tag: bytes, val: Optional[str]) -> None:
        if val is not None:
            items.extend(_bmff_box(tag, _data_box(1, str(val).encode("utf-8"))))

    _add_utf8(b"\xa9nam", title)
    _add_utf8(b"\xa9ART", artist)
    _add_utf8(b"aART", album_artist)
    _add_utf8(b"\xa9alb", album)
    _add_utf8(b"\xa9gen", genre)
    _add_utf8(b"\xa9day", str(year) if year is not None else None)
    _add_utf8(b"\xa9wrt", composer)
    _add_utf8(b"\xa9lyr", lyrics)

    if track_number is not None:
        trkn_payload = struct.pack(">HHHH", 0, int(track_number), int(track_total), 0)
        items.extend(_bmff_box(b"trkn", _data_box(0, trkn_payload)))

    if disc_number is not None:
        disk_payload = struct.pack(">HHH", 0, int(disc_number), int(disc_total))
        items.extend(_bmff_box(b"disk", _data_box(0, disk_payload)))

    if cover_bytes is not None:
        covr_type = 14 if "png" in cover_mime.lower() else 13
        items.extend(_bmff_box(b"covr", _data_box(covr_type, cover_bytes)))

    for k, v in (replaygain_tags or {}).items():
        if v is None:
            continue
        mean_box = _bmff_fullbox(b"mean", 0, 0, b"com.apple.iTunes")
        name_box = _bmff_fullbox(b"name", 0, 0, k.encode("utf-8"))
        val_box = _data_box(1, str(v).encode("utf-8"))
        items.extend(_bmff_box(b"----", mean_box + name_box + val_box))

    return bytes(items)


def generate_m4a_fixture(
    path: PathLike,
    *,
    codec: str = "alac",
    sample_rate: int = 44100,
    channels: int = 2,
    bit_depth: int = 16,
    duration_ms: int = 1500,
    freq_hz: float = 440.0,
    segments: Optional[Sequence[Tuple[float, float]]] = None,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album_artist: Optional[str] = None,
    album: Optional[str] = None,
    genre: Optional[str] = None,
    year: Optional[Union[int, str]] = None,
    composer: Optional[str] = None,
    lyrics: Optional[str] = None,
    track_number: Optional[int] = None,
    track_total: int = 0,
    disc_number: Optional[int] = None,
    disc_total: int = 0,
    cover_bytes: Optional[bytes] = None,
    cover_mime: str = "image/jpeg",
    replaygain_track_gain: Optional[str] = None,
    replaygain_track_peak: Optional[str] = None,
    replaygain_album_gain: Optional[str] = None,
    replaygain_album_peak: Optional[str] = None,
) -> Path:
    """
    Generate a genuine ISO BMFF M4A file (`codec="alac"` or `codec="aac"`)
    with valid `stsd`, `stts`, `stsc`, `stsz`, `stco`, `mdat`, and `udta/meta/ilst` atoms.
    """
    c = codec.lower().strip()
    if c not in ("alac", "aac"):
        raise ValueError(f"Unsupported M4A codec: {codec}; expected 'alac' or 'aac'")

    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    ftyp = _bmff_box(b"ftyp", b"M4A \x00\x00\x00\x00M4A mp42isom")

    packets: List[bytes] = []
    sample_deltas: List[int] = []
    total_samples = 0

    if c == "alac":
        if bit_depth not in (16, 24):
            raise ValueError(f"ALAC bit_depth must be 16 or 24, got {bit_depth}")
        if segments is not None:
            pcm = generate_segmented_pcm(sample_rate, channels, segments)
        else:
            pcm = generate_segmented_pcm(sample_rate, channels, ((duration_ms / 1000.0, freq_hz),))
        total_samples = int(pcm.shape[0])
        frame_len = 4096
        for start in range(0, total_samples, frame_len):
            chunk = pcm[start : start + frame_len]
            packets.append(_encode_alac_uncompressed_packet(chunk, bit_depth))
            sample_deltas.append(int(chunk.shape[0]))

        # ALACSpecificConfig inside alac fullbox (24 bytes payload + 4 bytes version/flags)
        max_frame_bytes = max(len(p) for p in packets) if packets else 0
        avg_bitrate = int((sum(len(p) for p in packets) * 8 * sample_rate) // max(1, total_samples))
        alac_cfg = struct.pack(
            ">IBBBBBBHIII",
            frame_len,
            0,  # compatibleVersion
            bit_depth,
            40,  # pb
            10,  # mb
            14,  # kb
            channels,
            255,  # maxRun
            max_frame_bytes,
            avg_bitrate,
            sample_rate,
        )
        alac_box = _bmff_fullbox(b"alac", 0, 0, alac_cfg)
        sample_entry_body = (
            b"\x00" * 6
            + struct.pack(">H", 1)  # data_reference_index
            + b"\x00" * 8
            + struct.pack(">HH", channels, bit_depth)
            + b"\x00" * 4
            + struct.pack(">I", (sample_rate & 0xFFFF) << 16)
            + alac_box
        )
        sample_entry = _bmff_box(b"alac", sample_entry_body)
    else:
        # AAC-LC: valid 6-byte stereo silent frame (1024 samples/frame)
        # Note: 0x21 0x10 0x04 0x60 0x8C 0x1C is a valid raw AAC-LC CPE silent block
        # For mono, SCE silent frame is 0x01 0x18 0x20 0x07
        aac_frame = b"\x21\x10\x04\x60\x8c\x1c" if channels >= 2 else b"\x01\x18\x20\x07"
        n_frames = max(1, int(round((sample_rate * (duration_ms / 1000.0)) / 1024.0)))
        packets = [aac_frame] * n_frames
        sample_deltas = [1024] * n_frames
        total_samples = n_frames * 1024
        esds_box = _build_esds_box(sample_rate, channels)
        sample_entry_body = (
            b"\x00" * 6
            + struct.pack(">H", 1)
            + b"\x00" * 8
            + struct.pack(">HH", channels, 16)
            + b"\x00" * 4
            + struct.pack(">I", (sample_rate & 0xFFFF) << 16)
            + esds_box
        )
        sample_entry = _bmff_box(b"mp4a", sample_entry_body)

    stsd = _bmff_fullbox(b"stsd", 0, 0, struct.pack(">I", 1) + sample_entry)

    # Run-length encode stts
    stts_runs: List[Tuple[int, int]] = []
    for d in sample_deltas:
        if stts_runs and stts_runs[-1][1] == d:
            stts_runs[-1] = (stts_runs[-1][0] + 1, d)
        else:
            stts_runs.append((1, d))
    stts_body = bytearray(struct.pack(">I", len(stts_runs)))
    for cnt, d in stts_runs:
        stts_body.extend(struct.pack(">II", cnt, d))
    stts = _bmff_fullbox(b"stts", 0, 0, bytes(stts_body))

    # stsc: 1 entry mapping all samples to chunk 1
    stsc = _bmff_fullbox(b"stsc", 0, 0, struct.pack(">IIII", 1, 1, len(packets), 1))

    # stsz
    stsz_body = bytearray(struct.pack(">II", 0, len(packets)))
    for p in packets:
        stsz_body.extend(struct.pack(">I", len(p)))
    stsz = _bmff_fullbox(b"stsz", 0, 0, bytes(stsz_body))

    # Build udta/meta/ilst before stco so we know exact moov size and mdat payload offset
    rg_tags: Dict[str, str] = {}
    if replaygain_track_gain is not None:
        rg_tags["REPLAYGAIN_TRACK_GAIN"] = str(replaygain_track_gain)
    if replaygain_track_peak is not None:
        rg_tags["REPLAYGAIN_TRACK_PEAK"] = str(replaygain_track_peak)
    if replaygain_album_gain is not None:
        rg_tags["REPLAYGAIN_ALBUM_GAIN"] = str(replaygain_album_gain)
    if replaygain_album_peak is not None:
        rg_tags["REPLAYGAIN_ALBUM_PEAK"] = str(replaygain_album_peak)

    ilst_raw = _build_ilst_atoms(
        title=title,
        artist=artist,
        album_artist=album_artist,
        album=album,
        genre=genre,
        year=year,
        composer=composer,
        lyrics=lyrics,
        track_number=track_number,
        track_total=track_total,
        disc_number=disc_number,
        disc_total=disc_total,
        cover_bytes=cover_bytes,
        cover_mime=cover_mime,
        replaygain_tags=rg_tags,
    )
    udta_box = b""
    if ilst_raw:
        meta_hdlr = _bmff_fullbox(b"hdlr", 0, 0, b"\x00" * 4 + b"mdir" + b"appl" + b"\x00" * 9)
        ilst_box = _bmff_box(b"ilst", ilst_raw)
        meta_box = _bmff_fullbox(b"meta", 0, 0, meta_hdlr + ilst_box)
        udta_box = _bmff_box(b"udta", meta_box)

    def _assemble_moov(chunk_offset: int) -> bytes:
        stco = _bmff_fullbox(b"stco", 0, 0, struct.pack(">II", 1, chunk_offset))
        stbl = _bmff_box(b"stbl", stsd + stts + stsc + stsz + stco)
        url_box = _bmff_fullbox(b"url ", 0, 1, b"")
        dref = _bmff_fullbox(b"dref", 0, 0, struct.pack(">I", 1) + url_box)
        dinf = _bmff_box(b"dinf", dref)
        smhd = _bmff_fullbox(b"smhd", 0, 0, struct.pack(">HH", 0, 0))
        minf = _bmff_box(b"minf", smhd + dinf + stbl)

        mdhd = _bmff_fullbox(
            b"mdhd",
            0,
            0,
            struct.pack(">IIIIHH", 0, 0, sample_rate, total_samples, 0x55C4, 0),
        )
        mdia_hdlr = _bmff_fullbox(b"hdlr", 0, 0, b"\x00" * 4 + b"soun" + b"\x00" * 12 + b"SoundHandler\x00")
        mdia = _bmff_box(b"mdia", mdhd + mdia_hdlr + minf)

        dur_1000 = max(1, int(round((total_samples * 1000.0) / float(sample_rate))))
        identity_matrix = struct.pack(">9I", 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000)
        tkhd = _bmff_fullbox(
            b"tkhd",
            0,
            7,
            struct.pack(">IIIIIIHH", 0, 0, 1, 0, dur_1000, 0, 0, 0)
            + struct.pack(">HH", 0x0100, 0)
            + identity_matrix
            + struct.pack(">II", 0, 0),
        )
        trak = _bmff_box(b"trak", tkhd + mdia)

        mvhd = _bmff_fullbox(
            b"mvhd",
            0,
            0,
            struct.pack(">IIII", 0, 0, 1000, dur_1000)
            + struct.pack(">IH", 0x00010000, 0x0100)
            + b"\x00" * 10
            + identity_matrix
            + b"\x00" * 24
            + struct.pack(">I", 2),
        )
        return _bmff_box(b"moov", mvhd + trak + udta_box)

    # Two-pass offset calculation: moov sits immediately before mdat
    moov_placeholder = _assemble_moov(0)
    mdat_payload_offset = len(ftyp) + len(moov_placeholder) + 8
    moov = _assemble_moov(mdat_payload_offset)
    assert len(moov) == len(moov_placeholder)

    mdat_payload = b"".join(packets)
    mdat = _bmff_box(b"mdat", mdat_payload)

    out_path.write_bytes(ftyp + moov + mdat)
    return out_path


# ---------------------------------------------------------------------------
# 9. DSF & DSDIFF (.dsf / .dff) Generators
# ---------------------------------------------------------------------------

def generate_dsf_fixture(
    path: PathLike,
    *,
    sample_rate: int = 2822400,
    channels: int = 2,
    duration_ms: int = 1000,
    id3_version: int = 4,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    album_artist: Optional[str] = None,
    genre: Optional[str] = None,
    year: Optional[Union[int, str]] = None,
    track_number: Optional[Union[int, str]] = None,
    disc_number: Optional[Union[int, str]] = None,
    composer: Optional[str] = None,
    replaygain_track_gain: Optional[str] = None,
    apic_list: Optional[Sequence[Tuple[bytes, str, int, str]]] = None,
    uslt: Optional[Tuple[str, str, str]] = None,
) -> Path:
    """
    Generate a genuine DSF (DSD64/DSD128) file with optional trailing ID3v2 tag
    referenced by `metadata_offset` in the `DSD ` chunk.
    """
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    block_size = 4096
    bits_per_ch = max(block_size * 8, int(round(sample_rate * (duration_ms / 1000.0))))
    bytes_per_ch = ((bits_per_ch // 8 + block_size - 1) // block_size) * block_size
    n_blocks = bytes_per_ch // block_size
    sample_count = bytes_per_ch * 8

    # Interleaved blocks per channel with varying valid bit patterns per block
    payload_parts: List[bytes] = []
    for blk in range(n_blocks):
        fill = 0x69 if blk % 2 == 0 else 0x96
        for _ch in range(channels):
            payload_parts.append(bytes([fill]) * block_size)
    payload = b"".join(payload_parts)

    text_frames: Dict[str, str] = {}
    if title is not None:
        text_frames["TIT2"] = str(title)
    if artist is not None:
        text_frames["TPE1"] = str(artist)
    if album is not None:
        text_frames["TALB"] = str(album)
    if album_artist is not None:
        text_frames["TPE2"] = str(album_artist)
    if genre is not None:
        text_frames["TCON"] = str(genre)
    if year is not None:
        text_frames["TDRC" if id3_version == 4 else "TYER"] = str(year)
    if track_number is not None:
        text_frames["TRCK"] = str(track_number)
    if disc_number is not None:
        text_frames["TPOS"] = str(disc_number)
    if composer is not None:
        text_frames["TCOM"] = str(composer)

    txxx_frames: Dict[str, str] = {}
    if replaygain_track_gain is not None:
        txxx_frames["REPLAYGAIN_TRACK_GAIN"] = str(replaygain_track_gain)

    id3_blob = build_id3v2_tag(
        version=id3_version,
        text_frames=text_frames,
        txxx_frames=txxx_frames,
        apic_list=apic_list,
        uslt=uslt,
    )

    dsd_header_size = 28
    fmt_chunk_size = 52
    data_chunk_size = 12 + len(payload)
    audio_end = dsd_header_size + fmt_chunk_size + data_chunk_size
    metadata_offset = audio_end if id3_blob else 0
    total_size = audio_end + len(id3_blob)

    dsd_chunk = struct.pack("<4sQQQ", b"DSD ", dsd_header_size, total_size, metadata_offset)
    fmt_chunk = struct.pack(
        "<4sQIIIIIIQII",
        b"fmt ",
        fmt_chunk_size,
        1,  # format version
        0,  # DSD raw
        2 if channels == 2 else 1,
        channels,
        sample_rate,
        1,  # bits per sample
        sample_count,
        block_size,
        0,
    )
    data_hdr = struct.pack("<4sQ", b"data", data_chunk_size)

    out_path.write_bytes(dsd_chunk + fmt_chunk + data_hdr + payload + id3_blob)
    return out_path


def _dff_chunk(ck_id: bytes, payload: bytes) -> bytes:
    assert len(ck_id) == 4
    pad = b"\x00" if (len(payload) % 2 == 1) else b""
    return ck_id + struct.pack(">Q", len(payload)) + payload + pad


def generate_dsdiff_fixture(
    path: PathLike,
    *,
    sample_rate: int = 2822400,
    channels: int = 2,
    duration_ms: int = 1000,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    album_artist: Optional[str] = None,
    genre: Optional[str] = None,
    composer: Optional[str] = None,
    apic_list: Optional[Sequence[Tuple[bytes, str, int, str]]] = None,
    uslt: Optional[Tuple[str, str, str]] = None,
    with_id3: bool = True,
) -> Path:
    """
    Generate a genuine DSDIFF (.dff) file (`FRM8`/`FVER`/`PROP`/`DIIN`/`DSD ` + optional `ID3 `).
    """
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    fver = _dff_chunk(b"FVER", struct.pack(">I", 0x01050000))

    fs_ck = _dff_chunk(b"FS  ", struct.pack(">I", sample_rate))
    ch_names = b"SLFTSRGT" if channels == 2 else b"C   " * channels
    chnl_ck = _dff_chunk(b"CHNL", struct.pack(">H", channels) + ch_names)
    cmpr_desc = b"not compressed "
    cmpr_ck = _dff_chunk(b"CMPR", b"DSD " + bytes([len(cmpr_desc)]) + cmpr_desc)
    prop = _dff_chunk(b"PROP", b"SND " + fs_ck + chnl_ck + cmpr_ck)

    diin_sub = bytearray()
    if title is not None:
        tb = str(title).encode("utf-8")
        diin_sub.extend(_dff_chunk(b"DITI", struct.pack(">I", len(tb)) + tb))
    if artist is not None:
        ab = str(artist).encode("utf-8")
        diin_sub.extend(_dff_chunk(b"DIAR", struct.pack(">I", len(ab)) + ab))
    diin = _dff_chunk(b"DIIN", bytes(diin_sub)) if diin_sub else b""

    byte_count_per_ch = max(4096, int(round((sample_rate * (duration_ms / 1000.0)) / 8.0)))
    total_dsd_bytes = byte_count_per_ch * channels
    if total_dsd_bytes % 2 == 1:
        total_dsd_bytes += 1
    dsd_audio = _dff_chunk(b"DSD ", b"\x69" * total_dsd_bytes)

    id3_chunk = b""
    if with_id3:
        tf: Dict[str, str] = {}
        if title is not None:
            tf["TIT2"] = str(title)
        if artist is not None:
            tf["TPE1"] = str(artist)
        if album is not None:
            tf["TALB"] = str(album)
        if album_artist is not None:
            tf["TPE2"] = str(album_artist)
        if genre is not None:
            tf["TCON"] = str(genre)
        if composer is not None:
            tf["TCOM"] = str(composer)
        id3_blob = build_id3v2_tag(
            version=4,
            text_frames=tf,
            apic_list=apic_list,
            uslt=uslt,
        )
        if id3_blob:
            id3_chunk = _dff_chunk(b"ID3 ", id3_blob)

    form_body = b"DSD " + fver + prop + diin + dsd_audio + id3_chunk
    frm8 = b"FRM8" + struct.pack(">Q", len(form_body)) + form_body
    out_path.write_bytes(frm8)
    return out_path
