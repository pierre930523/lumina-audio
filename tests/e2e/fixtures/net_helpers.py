"""
Network, temporary directory, and tagged audio fixture helpers for E2E tests.
"""
import gc
import io
import os
import shutil
import socket
import stat
import struct
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple, Union

import numpy as np
import requests
import soundfile as sf


def get_free_port(host: str = "127.0.0.1") -> int:
    """Allocate an available ephemeral TCP port on host without SO_REUSEADDR."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((host, 0))
        return int(sock.getsockname()[1])
    finally:
        sock.close()


def get_free_ports(count: int, host: str = "127.0.0.1") -> List[int]:
    """Allocate `count` distinct ephemeral TCP ports simultaneously."""
    if count <= 0:
        return []
    sockets: List[socket.socket] = []
    ports: List[int] = []
    try:
        for _ in range(count):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.bind((host, 0))
            sockets.append(sock)
            ports.append(int(sock.getsockname()[1]))
        return ports
    finally:
        for sock in sockets:
            try:
                sock.close()
            except OSError:
                pass


def _handle_remove_readonly(func, path, exc_info):
    """shutil.rmtree onerror handler for Python 3.11 on Windows."""
    try:
        os.chmod(path, stat.S_IWRITE)
    except OSError:
        pass
    func(path)


class ManagedTempDir:
    """Windows-safe temporary directory lifecycle manager with retry cleanup."""

    _RETRY_DELAYS = (0.02, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4)

    def __init__(
        self,
        prefix: str = "lumina_e2e_",
        base_dir: Optional[Union[str, Path]] = None,
        strict: bool = False,
    ) -> None:
        self.strict = strict
        dir_arg = str(base_dir) if base_dir is not None else None
        self._path = Path(tempfile.mkdtemp(prefix=prefix, dir=dir_arg))
        self._cleaned = False

    @property
    def path(self) -> Path:
        return self._path

    def child(self, *parts: str, mkdir: bool = False) -> Path:
        target = self._path.joinpath(*parts)
        if mkdir:
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
        return target

    def db_path(self, name: str = "lumina.db") -> Path:
        return self.child(name)

    def cleanup(self) -> None:
        if not self._path.exists():
            self._cleaned = True
            return

        gc.collect()
        last_err: Optional[Exception] = None
        for delay in self._RETRY_DELAYS:
            try:
                shutil.rmtree(self._path, onerror=_handle_remove_readonly)
            except (PermissionError, OSError) as exc:
                last_err = exc
            if not self._path.exists():
                self._cleaned = True
                return
            gc.collect()
            time.sleep(delay)

        if self._path.exists():
            try:
                shutil.rmtree(self._path, onerror=_handle_remove_readonly)
            except (PermissionError, OSError) as exc:
                last_err = exc

        if self._path.exists():
            if self.strict:
                self._cleaned = False
                if last_err is not None:
                    raise last_err
                raise PermissionError(f"Failed to remove temporary directory: {self._path}")
            shutil.rmtree(self._path, ignore_errors=True)
            self._cleaned = not self._path.exists()
            return

        self._cleaned = True

    def __enter__(self) -> Path:
        return self._path

    def __exit__(self, exc_type, exc, tb) -> None:
        self.cleanup()


def _generate_sine_wave(
    sample_rate: int,
    channels: int,
    duration_ms: int,
    freq_hz: float,
    amplitude: float = 0.25,
) -> np.ndarray:
    num_frames = max(1, int(round(sample_rate * (duration_ms / 1000.0))))
    t = np.arange(num_frames, dtype=np.float64) / float(sample_rate)
    mono = amplitude * np.sin(2.0 * np.pi * freq_hz * t)
    if channels == 1:
        return mono.reshape(-1, 1)
    return np.column_stack([mono for _ in range(channels)])


def _encode_synchsafe(value: int) -> bytes:
    return bytes(
        [
            (value >> 21) & 0x7F,
            (value >> 14) & 0x7F,
            (value >> 7) & 0x7F,
            value & 0x7F,
        ]
    )


def _build_id3v24_tag(
    text_frames: Dict[str, str], txxx_frames: Dict[str, str]
) -> bytes:
    frames = bytearray()
    for frame_id, value in text_frames.items():
        if not value:
            continue
        payload = b"\x03" + value.encode("utf-8")
        frames.extend(frame_id.encode("ascii")[:4])
        frames.extend(_encode_synchsafe(len(payload)))
        frames.extend(b"\x00\x00")
        frames.extend(payload)

    for desc, value in txxx_frames.items():
        if not value:
            continue
        payload = b"\x03" + desc.encode("utf-8") + b"\x00" + value.encode("utf-8")
        frames.extend(b"TXXX")
        frames.extend(_encode_synchsafe(len(payload)))
        frames.extend(b"\x00\x00")
        frames.extend(payload)

    if not frames:
        return b""

    header = b"ID3\x04\x00\x00" + _encode_synchsafe(len(frames))
    return header + bytes(frames)


def generate_wav_file(
    path: Union[str, Path],
    *,
    sample_rate: int = 44100,
    channels: int = 2,
    bit_depth: int = 16,
    duration_ms: int = 500,
    freq_hz: float = 440.0,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    album_artist: Optional[str] = None,
    track_number: Optional[Union[int, str]] = None,
    disc_number: Optional[Union[int, str]] = None,
    year: Optional[Union[int, str]] = None,
    isrc: Optional[str] = None,
    replaygain_track_gain: Optional[str] = None,
    replaygain_track_peak: Optional[str] = None,
    replaygain_album_gain: Optional[str] = None,
    replaygain_album_peak: Optional[str] = None,
) -> Path:
    """Generate a real PCM WAV file with LIST INFO and optional trailing RIFF id3 chunk."""
    subtype_map = {16: "PCM_16", 24: "PCM_24", 32: "PCM_32"}
    if bit_depth not in subtype_map:
        raise ValueError(f"Unsupported WAV bit_depth={bit_depth}; expected 16, 24, or 32")

    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    audio = _generate_sine_wave(sample_rate, channels, duration_ms, freq_hz)

    buf = io.BytesIO()
    with sf.SoundFile(
        buf,
        mode="w",
        samplerate=sample_rate,
        channels=channels,
        subtype=subtype_map[bit_depth],
        format="WAV",
    ) as wav:
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
        wav.write(audio)

    data = bytearray(buf.getvalue())

    text_frames: Dict[str, str] = {}
    if title is not None:
        text_frames["TIT2"] = str(title)
    if artist is not None:
        text_frames["TPE1"] = str(artist)
    if album is not None:
        text_frames["TALB"] = str(album)
    if album_artist is not None:
        text_frames["TPE2"] = str(album_artist)
    if track_number is not None:
        text_frames["TRCK"] = str(track_number)
    if disc_number is not None:
        text_frames["TPOS"] = str(disc_number)
    if year is not None:
        text_frames["TDRC"] = str(year)
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

    if text_frames or txxx_frames:
        id3_blob = _build_id3v24_tag(text_frames, txxx_frames)
        if id3_blob:
            if len(data) % 2 == 1:
                data.append(0)
            data.extend(b"id3 ")
            data.extend(struct.pack("<I", len(id3_blob)))
            data.extend(id3_blob)
            if len(id3_blob) % 2 == 1:
                data.append(0)
            struct.pack_into("<I", data, 4, len(data) - 8)

    out_path.write_bytes(bytes(data))
    return out_path


def _inject_flac_vorbis_comments(
    flac_bytes: bytes, tags: List[Tuple[str, str]]
) -> bytes:
    if not flac_bytes.startswith(b"fLaC"):
        raise ValueError("Invalid FLAC stream: missing fLaC marker")

    offset = 4
    blocks: List[Tuple[int, bytes]] = []
    while offset + 4 <= len(flac_bytes):
        header_byte = flac_bytes[offset]
        is_last = bool(header_byte & 0x80)
        block_type = header_byte & 0x7F
        length = int.from_bytes(flac_bytes[offset + 1 : offset + 4], "big")
        offset += 4
        payload = flac_bytes[offset : offset + length]
        offset += length
        if block_type != 4:  # replace existing VORBIS_COMMENT
            blocks.append((block_type, payload))
        if is_last:
            break

    audio_frames = flac_bytes[offset:]

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
        # Insert VORBIS_COMMENT immediately after STREAMINFO (index 0)
        insert_idx = 1 if blocks and blocks[0][0] == 0 else 0
        blocks.insert(insert_idx, (4, bytes(vc)))

    out = bytearray(b"fLaC")
    for idx, (btype, payload) in enumerate(blocks):
        is_last_bit = 0x80 if idx == len(blocks) - 1 else 0x00
        out.append(is_last_bit | (btype & 0x7F))
        out.extend(len(payload).to_bytes(3, "big"))
        out.extend(payload)
    out.extend(audio_frames)
    return bytes(out)


def generate_flac_file(
    path: Union[str, Path],
    *,
    sample_rate: int = 44100,
    channels: int = 2,
    bit_depth: int = 16,
    duration_ms: int = 500,
    freq_hz: float = 440.0,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    album_artist: Optional[str] = None,
    track_number: Optional[Union[int, str]] = None,
    disc_number: Optional[Union[int, str]] = None,
    year: Optional[Union[int, str]] = None,
    isrc: Optional[str] = None,
    replaygain_track_gain: Optional[str] = None,
    replaygain_track_peak: Optional[str] = None,
    replaygain_album_gain: Optional[str] = None,
    replaygain_album_peak: Optional[str] = None,
    extra_tags: Optional[Dict[str, str]] = None,
) -> Path:
    """Generate a real FLAC file with a VORBIS_COMMENT metadata block."""
    subtype_map = {16: "PCM_16", 24: "PCM_24"}
    if bit_depth not in subtype_map:
        raise ValueError(f"Unsupported FLAC bit_depth={bit_depth}; expected 16 or 24")

    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    audio = _generate_sine_wave(sample_rate, channels, duration_ms, freq_hz)

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

    tags: List[Tuple[str, str]] = []
    tag_pairs = [
        ("TITLE", title),
        ("ARTIST", artist),
        ("ALBUM", album),
        ("ALBUMARTIST", album_artist),
        ("TRACKNUMBER", track_number),
        ("DISCNUMBER", disc_number),
        ("DATE", year),
        ("ISRC", isrc),
        ("REPLAYGAIN_TRACK_GAIN", replaygain_track_gain),
        ("REPLAYGAIN_TRACK_PEAK", replaygain_track_peak),
        ("REPLAYGAIN_ALBUM_GAIN", replaygain_album_gain),
        ("REPLAYGAIN_ALBUM_PEAK", replaygain_album_peak),
    ]
    for key, val in tag_pairs:
        if val is not None:
            tags.append((key, str(val)))
    if extra_tags:
        for key, val in extra_tags.items():
            if val is not None:
                tags.append((str(key).upper(), str(val)))

    flac_data = _inject_flac_vorbis_comments(buf.getvalue(), tags)
    out_path.write_bytes(flac_data)
    return out_path


def generate_dsf_file(
    path: Union[str, Path],
    *,
    sample_rate: int = 2822400,
    channels: int = 2,
    duration_ms: int = 50,
) -> Path:
    """Generate a minimal valid DSF (DSD64/128) file for local scanner/parser tests."""
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    bits_per_channel = max(4096 * 8, int(sample_rate * (duration_ms / 1000.0)))
    block_size_per_channel = 4096
    byte_count_per_ch = ((bits_per_channel // 8 + block_size_per_channel - 1) // block_size_per_channel) * block_size_per_channel
    sample_count = byte_count_per_ch * 8
    payload = b"\x69" * (byte_count_per_ch * channels)

    data_chunk_size = 12 + len(payload)
    fmt_chunk_size = 52
    dsd_header_size = 28
    total_size = dsd_header_size + fmt_chunk_size + data_chunk_size

    dsd_chunk = struct.pack("<4sQQQ", b"DSD ", dsd_header_size, total_size, 0)
    fmt_chunk = struct.pack(
        "<4sQIIIIIIQII",
        b"fmt ",
        fmt_chunk_size,
        1,  # format version
        0,  # format id (DSD raw)
        2 if channels == 2 else 1,  # channel type
        channels,
        sample_rate,
        1,  # bits per sample
        sample_count,
        block_size_per_channel,
        0,
    )
    data_header = struct.pack("<4sQ", b"data", data_chunk_size)
    out_path.write_bytes(dsd_chunk + fmt_chunk + data_header + payload)
    return out_path


def wait_for_tcp(
    host: str, port: int, timeout_s: float = 5.0, interval_s: float = 0.05
) -> None:
    """Poll TCP socket connection until reachable or raise TimeoutError."""
    deadline = time.monotonic() + timeout_s
    last_err: Optional[Exception] = None
    conn_timeout = min(0.5, max(0.05, interval_s * 4.0))
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=conn_timeout):
                return
        except OSError as exc:
            last_err = exc
            time.sleep(interval_s)
    raise TimeoutError(
        f"Timed out after {timeout_s:.2f}s waiting for TCP {host}:{port} (last error: {last_err})"
    )


def wait_for_http(
    url: str,
    expected_status: Union[int, Sequence[int]] = (200,),
    timeout_s: float = 5.0,
    interval_s: float = 0.05,
    headers: Optional[Dict[str, str]] = None,
) -> requests.Response:
    """Poll HTTP GET until status matches expected_status or raise TimeoutError."""
    expected = (
        (expected_status,)
        if isinstance(expected_status, int)
        else tuple(expected_status)
    )
    deadline = time.monotonic() + timeout_s
    last_detail: str = "no response"
    while time.monotonic() < deadline:
        try:
            resp = requests.get(url, headers=headers, timeout=1.0)
            if resp.status_code in expected:
                return resp
            last_detail = f"HTTP {resp.status_code}"
        except requests.RequestException as exc:
            last_detail = repr(exc)
        time.sleep(interval_s)
    raise TimeoutError(
        f"Timed out after {timeout_s:.2f}s waiting for HTTP {url} in {expected} (last: {last_detail})"
    )
