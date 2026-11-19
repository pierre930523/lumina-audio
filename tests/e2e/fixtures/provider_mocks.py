"""
Mock provider payloads, responses, and network models for:
- Qobuz (direct token auth, hi-res stream resolution, search)
- Tidal (OAuth2 PKCE verifier/challenge generation, Bearer token)
- Deezer (ARL cookie authentication)
- SMB / WebDAV URI parsing and stream resolving
- Filesystem scanner path normalization and cover artwork discovery
"""
import base64
import hashlib
import json
import os
import re
import secrets
import time
from typing import Dict, Any, List, Optional, Tuple
from urllib.parse import urlparse


def get_mock_qobuz_login_response(user_auth_token: str = "qb_usr_tok_99182371") -> Dict[str, Any]:
    """Generates mock response from Qobuz /api.json/0.2/user/login or user/get."""
    return {
        "status": "success",
        "user": {
            "id": 1083921,
            "public_id": "qb-user-paris",
            "login": "audiophile@lumina.io",
            "email": "audiophile@lumina.io",
            "credential": {
                "id": 19482,
                "label": "Studio Sublime",
                "description": "24-bit Hi-Res Streaming up to 192 kHz",
                "parameters": {
                    "hires": True,
                    "lossless": True,
                    "max_streaming_quality": 27,  # 27 = 24-bit / 192 kHz FLAC
                }
            },
            "user_auth_token": user_auth_token,
        }
    }


def get_mock_qobuz_stream_response(
    track_id: str = "12049182",
    sample_rate: int = 192000,
    bit_depth: int = 24,
) -> Dict[str, Any]:
    """Generates mock response for Qobuz track/getFileUrl with authentication."""
    return {
        "track_id": int(track_id) if track_id.isdigit() else 12049182,
        "format_id": 27,
        "mime_type": "audio/flac",
        "sampling_rate": sample_rate / 1000.0,
        "bit_depth": bit_depth,
        "sample_rate_hz": sample_rate,
        "url": f"https://streaming-qobuz.akamaized.net/stream/{track_id}.flac?token=mock_sig_991a",
        "restrictions": [],
        "duration": 348,
    }


def get_mock_tidal_pkce() -> Tuple[str, str, str]:
    """
    Generates standard OAuth2 PKCE challenge pair according to RFC 7636.
    Returns (code_verifier, code_challenge, authorization_url).
    """
    code_verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(code_verifier.encode("ascii")).digest()
    code_challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    auth_url = (
        f"https://login.tidal.com/authorize?response_type=code"
        f"&client_id=lumina_desktop_client&redirect_uri=http%3A%2F%2Flocalhost%3A9888%2Fcallback"
        f"&code_challenge={code_challenge}&code_challenge_method=S256"
    )
    return code_verifier, code_challenge, auth_url


def get_mock_tidal_token_response(code_verifier: str) -> Dict[str, Any]:
    """Generates mock OAuth2 token response for Tidal."""
    return {
        "access_token": f"tid_acc_{secrets.token_hex(16)}",
        "refresh_token": f"tid_ref_{secrets.token_hex(20)}",
        "token_type": "Bearer",
        "expires_in": 86400,
        "user_id": 992831,
    }


def get_mock_deezer_arl(arl_cookie: str = "deezer_arl_cookie_abcdef1234567890") -> Dict[str, Any]:
    """Generates mock Deezer session payload using ARL cookie."""
    return {
        "arl": arl_cookie,
        "session_id": "sid_mock_deezer_session_482910",
        "user": {
            "id": 482910,
            "name": "HiFi Subscriber",
            "offer": "Deezer HiFi (FLAC 16/44.1)",
            "can_stream_hq": True,
            "can_stream_lossless": True,
        },
    }


def parse_remote_share_uri(uri: str) -> Dict[str, Any]:
    """
    Parses remote share URI (smb:// or https:// WebDAV) into component parts:
    protocol, host, port, share_name, relative_path, username, password.
    """
    parsed = urlparse(uri)
    if parsed.scheme not in ("smb", "dav", "davs", "http", "https"):
        raise ValueError(f"Unsupported remote share URI scheme: {parsed.scheme}")

    protocol = "smb" if parsed.scheme == "smb" else "web_dav"
    host = parsed.hostname or ""
    port = parsed.port or (445 if protocol == "smb" else (443 if parsed.scheme in ("https", "davs") else 80))

    path = parsed.path.lstrip("/")
    parts = path.split("/", 1)
    share_name = parts[0] if parts else ""
    relative_path = parts[1] if len(parts) > 1 else ""

    username = parsed.username
    password = parsed.password
    is_authenticated = bool(username and password)

    return {
        "protocol": protocol,
        "scheme": parsed.scheme,
        "host": host,
        "port": port,
        "share_name": share_name,
        "relative_path": relative_path,
        "username": username,
        "password": password,
        "is_authenticated": is_authenticated,
        "raw_uri": uri,
    }


def validate_isrc(code: str) -> bool:
    """Verifies standard 12-character ISRC format (e.g. GBAYE7300021)."""
    isrc_regex = re.compile(r"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$")
    return bool(isrc_regex.match(code.strip()))


def find_folder_cover(filenames: List[str]) -> Optional[str]:
    """Finds album cover art image filename from directory file list."""
    candidates = {"cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg"}
    for name in filenames:
        if name.lower() in candidates:
            return name
    return None


def find_folder_artwork_candidate(filenames: List[str]) -> Optional[str]:
    """Alias for find_folder_cover."""
    return find_folder_cover(filenames)


def normalize_path(p: str) -> str:
    """Normalizes filesystem path for duplicate track detection across operating systems."""
    return os.path.normcase(os.path.abspath(p))


def normalize_audio_file_path(p: str) -> str:
    """Alias for normalize_path."""
    return normalize_path(p)


def make_basic_auth(user: str, secret: str) -> str:
    """Generates standard HTTP Basic authentication header string."""
    token = base64.b64encode(f"{user}:{secret}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def generate_basic_auth_header(user: str, secret: str) -> str:
    """Alias for make_basic_auth."""
    return make_basic_auth(user, secret)


def mock_search(query: str, limit: int = 20) -> List[Dict[str, Any]]:
    """Simulates provider catalog search returning results matching query."""
    return [{"title": f"Result for {query}"}] * min(limit, 5)


def mock_provider_search(query: str, limit: int = 20) -> List[Dict[str, Any]]:
    """Alias for mock_search."""
    return mock_search(query, limit)


class MockProvider:
    """Mock streaming provider checking authentication before stream resolution."""

    def __init__(self, authenticated: bool = False):
        self.authenticated = authenticated

    def resolve_stream(self, track_id: str) -> Dict[str, Any]:
        if not self.authenticated:
            raise PermissionError("Provider unauthenticated: login required")
        return {"stream_url": f"https://streaming.example.com/{track_id}.flac"}


class MockStreamingProvider(MockProvider):
    """Alias for MockProvider."""
    pass


class MockMusicProvider(MockProvider):
    """Alias for MockProvider."""
    pass


class ReferenceLocalScannerProvider:
    """Reference implementation of unified MusicProvider for local audio files."""

    def __init__(self, base_dir: str):
        self.kind = "local"
        self.base_dir = base_dir
        self.capabilities = {
            "supports_token_login": False,
            "supports_oauth": False,
            "supports_word_lyrics": True,
            "supports_hi_res": True,
        }

    def resolve_stream(self, relative_path: str) -> Dict[str, Any]:
        full_path = os.path.join(self.base_dir, relative_path)
        ext = os.path.splitext(relative_path)[1].lstrip(".").lower()
        return {
            "url_or_path": full_path,
            "format": {
                "codec": ext,
                "sample_rate_hz": 96000,
                "bit_depth": 24,
                "channels": 2,
                "is_dsd": ext in ("dsf", "dsdiff"),
            },
            "headers": [],
        }


def is_scannable_audio(filename: str) -> bool:
    """Verifies that filename has a valid supported audio extension and is not a hidden file."""
    if filename.startswith("."):
        return False
    valid_exts = {".flac", ".wav", ".dsf", ".aiff", ".mp3", ".aac", ".opus", ".dff", ".alac", ".m4a"}
    _, ext = os.path.splitext(filename.lower())
    return ext in valid_exts


def is_scannable_audio_file(filename: str) -> bool:
    """Alias for is_scannable_audio."""
    return is_scannable_audio(filename)


def check_qobuz_response(resp: Dict[str, Any]) -> None:
    """Checks Qobuz API response status, raising PermissionError on error status."""
    if resp.get("status") == "error":
        raise PermissionError(resp.get("message", "Qobuz authentication error"))


def resolve_qobuz_url(resp: Dict[str, Any]) -> str:
    """Validates and extracts stream URL from Qobuz response."""
    if resp.get("restrictions"):
        raise ValueError(f"Track restricted: {resp['restrictions']}")
    url = resp.get("url")
    if not url:
        raise ValueError("Missing stream URL")
    return url


def resolve_qobuz_format(fmt_id: int) -> Tuple[int, int]:
    """Resolves Qobuz format_id to (sample_rate_hz, bit_depth)."""
    format_map = {
        5: (44100, 16),
        6: (96000, 24),
        7: (96000, 24),
        27: (192000, 24),
    }
    return format_map.get(fmt_id, (44100, 16))


def resolve_format(fmt_id: int) -> Tuple[int, int]:
    """Alias for resolve_qobuz_format."""
    return resolve_qobuz_format(fmt_id)


def normalize_sample_rate(val: Any) -> int:
    """Normalizes Qobuz sampling_rate (float kHz or integer Hz or numeric string) into integer Hz."""
    f = float(val)
    if f < 1000.0:
        f *= 1000.0
    return int(round(f))


def validate_pkce_verifier(verifier: str) -> bool:
    """Verifies PKCE code_verifier length (43 <= len <= 128) and unreserved characters."""
    if not verifier:
        return False
    n = len(verifier)
    if n < 43 or n > 128:
        return False
    return bool(re.match(r"^[A-Za-z0-9_-]+$", verifier))


def validate_arl_cookie(arl: str) -> bool:
    """Verifies Deezer ARL cookie format (hex characters, length >= 32)."""
    if not arl or len(arl) < 32:
        return False
    return bool(re.match(r"^[0-9a-fA-F_]+$", arl))


def is_token_expired(issued_at: float, expires_in: int, skew_sec: int = 60) -> bool:
    """Checks whether access token is expired considering clock skew."""
    now = time.time()
    return now >= (issued_at + expires_in - skew_sec)
