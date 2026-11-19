"""
Real local loopback mock servers (127.0.0.1:0) for E2E testing of Lumina Audio:
- StreamingAudioMockServer (Qobuz, Tidal PKCE, Deezer ARL, HTTP 206 Range audio)
- WebDavMockServer (PROPFIND 207 XML + Basic Auth + Range GET)
- SmbLoopbackFixture (isolated share dir + SMB2 probe TCP listener + URI/cred validators)
- MusicBrainzMockServer & DiscogsMockServer (JSON APIs + 429 Retry-After / 503 injection)
- WanTlsProxyMockServer (ephemeral X.509 cert + asyncio HTTPS/WSS reverse proxy)
- DlnaMediaRendererMock (UDP SSDP M-SEARCH + UPnP XML/SCPD/SOAP AVTransport & RenderingControl)
- AirPlayMockServer (RTSP TCP server + UDP RTP/control/timing receiver)
- ClockSyncMockServer (UDP SNTPv4 & JSON 4-timestamp offset/drift simulator)
- MdnsLoopbackMock (RFC 6762/6763 _lumina._tcp.local. wire responder & parser)
"""
import asyncio
import datetime
import hashlib
import http.server
import ipaddress
import json
import mimetypes
import os
import socket
import socketserver
import ssl
import struct
import sys
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple
from urllib.parse import parse_qs, quote, unquote, urlparse
from xml.sax.saxutils import escape as xml_escape

import defusedxml.ElementTree as SafeET
import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from .net_helpers import (
    ManagedTempDir,
    generate_flac_file,
    generate_wav_file,
    wait_for_tcp,
)
from .provider_mocks import (
    get_mock_deezer_arl,
    get_mock_qobuz_login_response,
    get_mock_qobuz_stream_response,
    get_mock_tidal_token_response,
    make_basic_auth,
    parse_remote_share_uri,
    validate_arl_cookie,
    validate_pkce_verifier,
)


_CACHED_UDP_HOST: Optional[str] = None
_UDP_HOST_LOCK = threading.Lock()


def _resolve_udp_loopback_host() -> str:
    """Return a working local IPv4 address for UDP loopback (falls back if 127.0.0.1 UDP is filtered)."""
    global _CACHED_UDP_HOST
    with _UDP_HOST_LOCK:
        if _CACHED_UDP_HOST is not None:
            return _CACHED_UDP_HOST

        candidates = ["127.0.0.1"]
        try:
            for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
                if ip not in candidates and not ip.startswith("169.254."):
                    candidates.append(ip)
        except OSError:
            pass

        for ip in candidates:
            srv_sock = None
            cli_sock = None
            try:
                srv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                srv_sock.settimeout(0.15)
                srv_sock.bind((ip, 0))
                port = srv_sock.getsockname()[1]
                cli_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                cli_sock.sendto(b"lumina_udp_probe", (ip, port))
                data, _ = srv_sock.recvfrom(64)
                if data == b"lumina_udp_probe":
                    _CACHED_UDP_HOST = ip
                    return ip
            except OSError:
                pass
            finally:
                for s in (cli_sock, srv_sock):
                    if s is not None:
                        try:
                            s.close()
                        except OSError:
                            pass

        _CACHED_UDP_HOST = "127.0.0.1"
        return _CACHED_UDP_HOST


def _disable_udp_connreset(sock: socket.socket) -> None:
    """Disable Windows WSAECONNRESET (10054) ICMP Port Unreachable errors on UDP sockets."""
    if hasattr(socket, "SIO_UDP_CONNRESET"):
        try:
            sock.ioctl(socket.SIO_UDP_CONNRESET, False)
        except (AttributeError, OSError):
            pass


def _parse_http_range(range_header: str, total_len: int) -> Tuple[str, int, int]:
    """
    Parse HTTP Range header.
    Returns ("206", start, end) or ("416", 0, 0).
    """
    if total_len <= 0:
        return ("416", 0, 0)
    val = range_header.strip()
    if not val.lower().startswith("bytes="):
        return ("416", 0, 0)
    spec = val[6:].split(",", 1)[0].strip()
    if "-" not in spec:
        return ("416", 0, 0)
    start_s, end_s = spec.split("-", 1)
    try:
        if start_s == "":
            suffix_len = int(end_s)
            if suffix_len <= 0:
                return ("416", 0, 0)
            start = max(0, total_len - suffix_len)
            end = total_len - 1
            return ("206", start, end)
        start = int(start_s)
        if start < 0 or start >= total_len:
            return ("416", 0, 0)
        if end_s == "":
            end = total_len - 1
        else:
            end = min(int(end_s), total_len - 1)
        if end < start:
            return ("416", 0, 0)
        return ("206", start, end)
    except ValueError:
        return ("416", 0, 0)


class _LoopbackThreadingHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, server_address, RequestHandlerClass, owner_server):
        self.owner_server = owner_server
        super().__init__(server_address, RequestHandlerClass)

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        super().server_bind()

    def handle_error(self, request, client_address) -> None:
        _, exc, _ = sys.exc_info() if "sys" in globals() else (None, None, None)
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError)):
            return
        super().handle_error(request, client_address)


class _LoopbackHTTPHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:
        return  # suppress noisy stderr logging during E2E runs

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _record_request(self, body: bytes) -> Dict[str, Any]:
        parsed = urlparse(self.path)
        entry = {
            "timestamp": time.time(),
            "method": self.command,
            "path": parsed.path,
            "query": parse_qs(parsed.query, keep_blank_values=True),
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
        }
        self.server.owner_server._append_log(entry)
        return entry

    def _send_bytes(
        self,
        status: int,
        data: bytes,
        content_type: str = "application/octet-stream",
        extra_headers: Optional[Dict[str, str]] = None,
        head_only: bool = False,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        if not head_only and data:
            self.wfile.write(data)
        self.wfile.flush()

    def _send_json(
        self,
        status: int,
        payload: Any,
        extra_headers: Optional[Dict[str, str]] = None,
    ) -> None:
        body = json.dumps(payload).encode("utf-8")
        self._send_bytes(
            status,
            body,
            content_type="application/json",
            extra_headers=extra_headers,
        )


class _BaseLoopbackHttpServer:
    """Base lifecycle, logging, and reset mixin for HTTP-based loopback mocks."""

    _handler_cls = _LoopbackHTTPHandler

    def __init__(self) -> None:
        self._host = "127.0.0.1"
        self._port = 0
        self._httpd: Optional[_LoopbackThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._log: List[Dict[str, Any]] = []

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._port

    @property
    def base_url(self) -> str:
        return f"http://{self._host}:{self._port}"

    @property
    def requests_log(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._log)

    @property
    def raw_requests_log(self) -> List[Dict[str, Any]]:
        return self.requests_log

    def _append_log(self, entry: Dict[str, Any]) -> None:
        with self._lock:
            self._log.append(entry)

    def reset(self) -> None:
        with self._lock:
            self._log.clear()

    def start(self) -> "_BaseLoopbackHttpServer":
        if self._httpd is not None:
            return self
        self._httpd = _LoopbackThreadingHTTPServer(
            (self._host, 0), self._handler_cls, self
        )
        self._port = int(self._httpd.server_address[1])
        self._thread = threading.Thread(
            target=self._httpd.serve_forever,
            kwargs={"poll_interval": 0.05},
            daemon=True,
        )
        self._thread.start()
        wait_for_tcp(self._host, self._port, timeout_s=3.0)
        return self

    def stop(self) -> None:
        if self._httpd is not None:
            try:
                self._httpd.shutdown()
                self._httpd.server_close()
            finally:
                self._httpd = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        self._port = 0

    def __enter__(self):
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()


# ---------------------------------------------------------------------------
# 1. StreamingAudioMockServer (Qobuz, Tidal PKCE, Deezer ARL, Range 206)
# ---------------------------------------------------------------------------


class _StreamingHandler(_LoopbackHTTPHandler):
    def do_GET(self) -> None:
        self._handle(head_only=False)

    def do_HEAD(self) -> None:
        self._handle(head_only=True)

    def do_POST(self) -> None:
        self._handle(head_only=False)

    def _handle(self, head_only: bool) -> None:
        srv: StreamingAudioMockServer = self.server.owner_server
        body = self._read_body()
        req = self._record_request(body)
        path = req["path"]
        query = req["query"]
        headers = req["headers"]

        if srv.latency_ms > 0:
            time.sleep(srv.latency_ms / 1000.0)

        should_fail_503 = False
        with srv._lock:
            if srv.fail_next_n > 0:
                srv.fail_next_n -= 1
                should_fail_503 = True
        if should_fail_503:
            self._send_json(503, {"status": "error", "message": "Injected transient 503"})
            return

        if srv.inject_status is not None:
            self._send_json(
                srv.inject_status,
                {"status": "error", "message": f"Injected HTTP {srv.inject_status}"},
            )
            return

        # Qobuz: GET /api.json/0.2/user/get
        if path == "/api.json/0.2/user/get":
            token = headers.get("x-user-auth-token", "")
            app_id = headers.get("x-app-id", "")
            if not app_id or token not in srv.valid_qobuz_tokens:
                self._send_json(
                    401, {"status": "error", "message": "Invalid user_auth_token"}
                )
                return
            self._send_json(200, get_mock_qobuz_login_response(token))
            return

        # Qobuz: GET /api.json/0.2/user/login
        if path == "/api.json/0.2/user/login":
            user = (query.get("username") or [""])[0]
            pw = (query.get("password") or [""])[0]
            app_id = headers.get("x-app-id", "")
            if not app_id or srv.valid_qobuz_credentials.get(user) != pw:
                self._send_json(
                    401, {"status": "error", "message": "Invalid username or password"}
                )
                return
            tok = next(iter(srv.valid_qobuz_tokens))
            self._send_json(200, get_mock_qobuz_login_response(tok))
            return

        # Qobuz: GET /api.json/0.2/catalog/search
        if path == "/api.json/0.2/catalog/search":
            q_text = (query.get("query") or [""])[0].lower()
            items = [
                {
                    "id": "qb-alb-1",
                    "title": "Kind of Blue",
                    "artist": {"name": "Miles Davis"},
                    "maximum_sampling_rate": 192.0,
                    "maximum_bit_depth": 24,
                },
                {
                    "id": "qb-alb-2",
                    "title": "The Dark Side of the Moon",
                    "artist": {"name": "Pink Floyd"},
                    "maximum_sampling_rate": 96.0,
                    "maximum_bit_depth": 24,
                },
            ]
            if q_text:
                filtered = [
                    it
                    for it in items
                    if q_text in it["title"].lower()
                    or q_text in it["artist"]["name"].lower()
                ]
            else:
                filtered = items
            self._send_json(
                200, {"albums": {"total": len(filtered), "items": filtered}}
            )
            return

        # Qobuz: GET /api.json/0.2/album/get
        if path == "/api.json/0.2/album/get":
            album_id = (query.get("album_id") or ["qb-alb-1"])[0]
            self._send_json(
                200,
                {
                    "id": album_id,
                    "title": "Kind of Blue",
                    "artist": {"name": "Miles Davis"},
                    "release_date_original": "1959-08-17",
                    "upc": "886443927384",
                    "tracks": {
                        "items": [
                            {
                                "id": 12049182,
                                "title": "So What",
                                "track_number": 1,
                                "duration": 562,
                                "isrc": "USSM15900112",
                                "maximum_sampling_rate": 96.0,
                                "maximum_bit_depth": 24,
                            }
                        ]
                    },
                },
            )
            return

        # Qobuz: GET /api.json/0.2/track/getFileUrl
        if path == "/api.json/0.2/track/getFileUrl":
            token = headers.get("x-user-auth-token", "")
            app_id = headers.get("x-app-id", "")
            if not app_id or token not in srv.valid_qobuz_tokens:
                self._send_json(
                    401, {"status": "error", "message": "Invalid user_auth_token"}
                )
                return
            track_id = (query.get("track_id") or ["12049182"])[0]
            if track_id in srv.drm_restricted_ids:
                self._send_json(
                    200,
                    {
                        "track_id": int(track_id) if track_id.isdigit() else track_id,
                        "restrictions": ["not_available_in_country"],
                        "url": "",
                    },
                )
                return
            _, _, meta = srv.tracks.get(
                track_id, srv.tracks["12049182"]
            )
            payload = get_mock_qobuz_stream_response(
                track_id=track_id,
                sample_rate=meta["sample_rate"],
                bit_depth=meta["bit_depth"],
            )
            payload["url"] = (
                f"{srv.base_url}/stream/qobuz/{track_id}.flac?token=mock_sig_991a"
            )
            self._send_json(200, payload)
            return

        # Tidal: POST /oauth2/token
        if path == "/oauth2/token" and self.command == "POST":
            form = parse_qs(body.decode("utf-8", errors="replace"))
            grant_type = (form.get("grant_type") or [""])[0]
            if grant_type == "authorization_code":
                verifier = (form.get("code_verifier") or [""])[0]
                if not validate_pkce_verifier(verifier):
                    self._send_json(
                        400,
                        {
                            "error": "invalid_grant",
                            "error_description": "Invalid PKCE code_verifier",
                        },
                    )
                    return
                tok_resp = get_mock_tidal_token_response(verifier)
                srv.valid_tidal_tokens.add(tok_resp["access_token"])
                srv.valid_refresh_tokens.add(tok_resp["refresh_token"])
                self._send_json(200, tok_resp)
                return
            if grant_type == "refresh_token":
                ref = (form.get("refresh_token") or [""])[0]
                if ref not in srv.valid_refresh_tokens:
                    self._send_json(400, {"error": "invalid_grant"})
                    return
                tok_resp = get_mock_tidal_token_response("refresh_" + "a" * 40)
                srv.valid_tidal_tokens.add(tok_resp["access_token"])
                self._send_json(200, tok_resp)
                return
            self._send_json(400, {"error": "unsupported_grant_type"})
            return

        # Tidal: GET /v1/tracks/{id}/playbackinfo
        if path.startswith("/v1/tracks/") and path.endswith("/playbackinfo"):
            auth = headers.get("authorization", "")
            token = auth[7:].strip() if auth.startswith("Bearer ") else ""
            if token not in srv.valid_tidal_tokens:
                self._send_json(401, {"status": 401, "userMessage": "Unauthorized"})
                return
            track_id = path.split("/")[3]
            self._send_json(
                200,
                {
                    "trackId": int(track_id) if track_id.isdigit() else track_id,
                    "assetPresentation": "FULL",
                    "audioMode": "STEREO",
                    "audioQuality": "HI_RES_LOSSLESS",
                    "manifestMimeType": "application/dash+xml",
                    "manifest": "e30=",
                    "streamUrl": f"{srv.base_url}/v1/tracks/{track_id}/stream",
                },
            )
            return

        # Deezer: POST /api/deezer/auth or GET /ajax/gw-light.php
        if path in ("/api/deezer/auth", "/ajax/gw-light.php"):
            arl = ""
            cookie_hdr = headers.get("cookie", "")
            for part in cookie_hdr.split(";"):
                k, _, v = part.strip().partition("=")
                if k.strip() == "arl":
                    arl = v.strip()
            if not arl and body:
                try:
                    arl = str(json.loads(body.decode("utf-8")).get("arl", ""))
                except Exception:
                    pass
            if not validate_arl_cookie(arl):
                self._send_json(401, {"error": "INVALID_ARL", "results": {}})
                return
            track_id = (query.get("track_id") or ["3135556"])[0]
            resp = get_mock_deezer_arl(arl)
            resp["status"] = "VALID"
            resp["stream_url"] = f"{srv.base_url}/stream/deezer/{track_id}"
            resp["error"] = []
            resp["results"] = {
                "USER": {
                    "USER_ID": resp["user"]["id"],
                    "BLOG_NAME": resp["user"]["name"],
                    "OPTIONS": {"web_hq": True, "web_lossless": True},
                },
                "OFFER_NAME": resp["user"]["offer"],
            }
            self._send_json(200, resp)
            return

        # Audio stream endpoints with auth + 206 Partial Content
        stream_provider: Optional[str] = None
        track_id = "12049182"
        if path.startswith("/stream/qobuz/"):
            stream_provider = "qobuz"
            track_id = path.rsplit("/", 1)[-1].split(".", 1)[0]
        elif path.startswith("/v1/tracks/") and path.endswith("/stream"):
            stream_provider = "tidal"
            track_id = path.split("/")[3]
        elif path.startswith("/stream/deezer/"):
            stream_provider = "deezer"
            track_id = path.rsplit("/", 1)[-1].split(".", 1)[0]
        elif path.startswith("/stream/"):
            stream_provider = "generic"
            track_id = path.rsplit("/", 1)[-1].split(".", 1)[0]

        if stream_provider is not None:
            if srv.enforce_stream_auth:
                if stream_provider == "qobuz":
                    q_sig = (query.get("token") or [""])[0]
                    hdr_tok = headers.get("x-user-auth-token", "")
                    if (
                        hdr_tok not in srv.valid_qobuz_tokens
                        and q_sig not in srv.valid_stream_tokens
                    ):
                        self._send_json(401, {"error": "Unauthorized Qobuz stream"})
                        return
                elif stream_provider == "tidal":
                    auth = headers.get("authorization", "")
                    tok = auth[7:].strip() if auth.startswith("Bearer ") else ""
                    if tok not in srv.valid_tidal_tokens:
                        self._send_json(401, {"error": "Unauthorized Tidal stream"})
                        return
                elif stream_provider == "deezer":
                    arl = ""
                    for part in headers.get("cookie", "").split(";"):
                        k, _, v = part.strip().partition("=")
                        if k.strip() == "arl":
                            arl = v.strip()
                    if not validate_arl_cookie(arl):
                        self._send_json(401, {"error": "Unauthorized Deezer stream"})
                        return

            if track_id not in srv.tracks:
                self._send_json(404, {"error": f"Unknown track_id: {track_id}"})
                return

            audio_bytes, mime_type, _ = srv.tracks[track_id]
            total_len = len(audio_bytes)
            range_hdr = headers.get("range")

            if srv.drop_after_bytes is not None and not head_only:
                n = max(0, min(srv.drop_after_bytes, total_len))
                self.send_response(200)
                self.send_header("Content-Type", mime_type)
                self.send_header("Content-Length", str(total_len))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                if n > 0:
                    self.wfile.write(audio_bytes[:n])
                    self.wfile.flush()
                self.close_connection = True
                return

            if range_hdr and not srv.disable_range:
                status_str, start, end = _parse_http_range(range_hdr, total_len)
                if status_str == "416":
                    self._send_bytes(
                        416,
                        b"",
                        content_type=mime_type,
                        extra_headers={
                            "Content-Range": f"bytes */{total_len}",
                            "Accept-Ranges": "bytes",
                        },
                        head_only=head_only,
                    )
                    return
                chunk = audio_bytes[start : end + 1]
                self._send_bytes(
                    206,
                    chunk,
                    content_type=mime_type,
                    extra_headers={
                        "Content-Range": f"bytes {start}-{end}/{total_len}",
                        "Accept-Ranges": "bytes",
                    },
                    head_only=head_only,
                )
                return

            self._send_bytes(
                200,
                audio_bytes,
                content_type=mime_type,
                extra_headers={"Accept-Ranges": "bytes"},
                head_only=head_only,
            )
            return

        self._send_json(404, {"error": "Not Found", "path": path})


class StreamingAudioMockServer(_BaseLoopbackHttpServer):
    """Loopback Qobuz/Tidal/Deezer API + HTTP 206 Range audio streaming server."""

    _handler_cls = _StreamingHandler

    def __init__(self) -> None:
        super().__init__()
        self._tmp = ManagedTempDir(prefix="lumina_stream_mock_")
        self.tracks: Dict[str, Tuple[bytes, str, Dict[str, Any]]] = {}
        self._seed_default_tracks()
        self.valid_qobuz_tokens: Set[str] = {"qb_usr_tok_99182371"}
        self.valid_qobuz_credentials: Dict[str, str] = {
            "audiophile@lumina.io": "lumina_pass"
        }
        self.valid_stream_tokens: Set[str] = {"mock_sig_991a"}
        self.valid_tidal_tokens: Set[str] = {"tid_acc_initial_valid_token"}
        self.valid_refresh_tokens: Set[str] = {"tid_ref_initial_valid_refresh"}
        self.inject_status: Optional[int] = None
        self.fail_next_n: int = 0
        self.latency_ms: float = 0.0
        self.drop_after_bytes: Optional[int] = None
        self.disable_range: bool = False
        self.drm_restricted_ids: Set[str] = set()
        self.enforce_stream_auth: bool = True

    def _seed_default_tracks(self) -> None:
        flac_96 = generate_flac_file(
            self._tmp.child("12049182.flac"),
            sample_rate=96000,
            bit_depth=24,
            duration_ms=400,
            title="So What",
            artist="Miles Davis",
            album="Kind of Blue",
            track_number=1,
            replaygain_track_gain="-4.20 dB",
            replaygain_track_peak="0.891251",
        ).read_bytes()
        flac_44 = generate_flac_file(
            self._tmp.child("12049183.flac"),
            sample_rate=44100,
            bit_depth=16,
            duration_ms=400,
            title="Freddie Freeloader",
            artist="Miles Davis",
            album="Kind of Blue",
            track_number=2,
            replaygain_track_gain="-3.50 dB",
            replaygain_track_peak="0.912000",
        ).read_bytes()
        wav_192 = generate_wav_file(
            self._tmp.child("wav-192.wav"),
            sample_rate=192000,
            bit_depth=24,
            duration_ms=250,
            title="Blue in Green",
            artist="Miles Davis",
            album="Kind of Blue",
            track_number=3,
        ).read_bytes()
        self.register_track(
            "12049182", flac_96, "audio/flac", 96000, 24, "So What"
        )
        self.register_track(
            "12049183", flac_44, "audio/flac", 44100, 16, "Freddie Freeloader"
        )
        self.register_track(
            "7788192", flac_44, "audio/flac", 44100, 16, "Tidal Track"
        )
        self.register_track(
            "3135556", flac_44, "audio/flac", 44100, 16, "Deezer Track"
        )
        self.register_track(
            "wav-192", wav_192, "audio/wav", 192000, 24, "Blue in Green"
        )

    def register_track(
        self,
        track_id: str,
        data: bytes,
        mime_type: str = "audio/flac",
        sample_rate: int = 44100,
        bit_depth: int = 16,
        title: str = "Mock Track",
    ) -> None:
        self.tracks[str(track_id)] = (
            data,
            mime_type,
            {"sample_rate": sample_rate, "bit_depth": bit_depth, "title": title},
        )

    def reset(self) -> None:
        super().reset()
        with self._lock:
            self.fail_next_n = 0
        self.inject_status = None
        self.latency_ms = 0.0
        self.drop_after_bytes = None
        self.disable_range = False
        self.drm_restricted_ids.clear()
        self.enforce_stream_auth = True

    def stop(self) -> None:
        try:
            super().stop()
        finally:
            self._tmp.cleanup()


# ---------------------------------------------------------------------------
# 2. WebDavMockServer
# ---------------------------------------------------------------------------


class _WebDavHandler(_LoopbackHTTPHandler):
    def do_OPTIONS(self) -> None:
        srv: WebDavMockServer = self.server.owner_server
        body = self._read_body()
        self._record_request(body)
        if not self._check_online_and_auth(srv):
            return
        self._send_bytes(
            200,
            b"",
            content_type="text/plain",
            extra_headers={
                "DAV": "1, 2",
                "Allow": "OPTIONS, GET, HEAD, PROPFIND",
            },
        )

    def do_PROPFIND(self) -> None:
        srv: WebDavMockServer = self.server.owner_server
        body = self._read_body()
        req = self._record_request(body)
        if not self._check_online_and_auth(srv):
            return

        if srv.malformed_xml:
            self._send_bytes(
                207,
                b"<D:multistatus xmlns:D='DAV:'><broken>",
                content_type='application/xml; charset="utf-8"',
            )
            return

        rel = unquote(req["path"]).lstrip("/")
        target = srv._resolve_path(rel)
        if target is None or not target.exists():
            self._send_bytes(404, b"Not Found", content_type="text/plain")
            return

        depth = req["headers"].get("depth", "1").strip()
        entries: List[Path] = [target]
        if target.is_dir() and depth != "0":
            for child in sorted(target.iterdir()):
                entries.append(child)

        xml_parts = ['<?xml version="1.0" encoding="utf-8"?>', '<D:multistatus xmlns:D="DAV:">']
        for item in entries:
            rel_item = item.relative_to(srv.root_dir).as_posix()
            href = "/" + rel_item if rel_item != "." else "/"
            if item.is_dir() and not href.endswith("/"):
                href += "/"
            xml_parts.append("  <D:response>")
            xml_parts.append(f"    <D:href>{xml_escape(quote(href, safe='/'))}</D:href>")
            xml_parts.append("    <D:propstat>")
            xml_parts.append("      <D:prop>")
            if item.is_dir():
                xml_parts.append("        <D:resourcetype><D:collection/></D:resourcetype>")
            else:
                st = item.stat()
                mime, _ = mimetypes.guess_type(item.name)
                mime_str = mime or ("audio/flac" if item.suffix == ".flac" else "application/octet-stream")
                etag = hashlib.md5(f"{rel_item}:{st.st_size}".encode("utf-8")).hexdigest()
                xml_parts.append("        <D:resourcetype/>")
                xml_parts.append(f"        <D:getcontentlength>{st.st_size}</D:getcontentlength>")
                xml_parts.append(f"        <D:getcontenttype>{xml_escape(mime_str)}</D:getcontenttype>")
                xml_parts.append(f'        <D:getetag>"{etag}"</D:getetag>')
            xml_parts.append("      </D:prop>")
            xml_parts.append("      <D:status>HTTP/1.1 200 OK</D:status>")
            xml_parts.append("    </D:propstat>")
            xml_parts.append("  </D:response>")
        xml_parts.append("</D:multistatus>")

        self._send_bytes(
            207,
            "\n".join(xml_parts).encode("utf-8"),
            content_type='application/xml; charset="utf-8"',
        )

    def do_GET(self) -> None:
        self._serve_file(head_only=False)

    def do_HEAD(self) -> None:
        self._serve_file(head_only=True)

    def _check_online_and_auth(self, srv: "WebDavMockServer") -> bool:
        if srv.latency_ms > 0:
            time.sleep(srv.latency_ms / 1000.0)
        if not srv.online:
            self._send_bytes(503, b"Service Unavailable", content_type="text/plain")
            return False
        if srv.require_auth:
            expected = make_basic_auth(srv.username, srv.password)
            got = self.headers.get("Authorization", "")
            if got != expected:
                self._send_bytes(
                    401,
                    b"",
                    content_type="text/plain",
                    extra_headers={'WWW-Authenticate': 'Basic realm="Lumina-WebDAV"'},
                )
                return False
        return True

    def _serve_file(self, head_only: bool) -> None:
        srv: WebDavMockServer = self.server.owner_server
        body = self._read_body()
        req = self._record_request(body)
        if not self._check_online_and_auth(srv):
            return

        rel = unquote(req["path"]).lstrip("/")
        target = srv._resolve_path(rel)
        if target is None or not target.is_file():
            self._send_bytes(404, b"Not Found", content_type="text/plain")
            return

        data = target.read_bytes()
        mime, _ = mimetypes.guess_type(target.name)
        mime_str = mime or ("audio/flac" if target.suffix == ".flac" else "application/octet-stream")
        range_hdr = req["headers"].get("range")
        total_len = len(data)
        if range_hdr:
            status_str, start, end = _parse_http_range(range_hdr, total_len)
            if status_str == "416":
                self._send_bytes(
                    416,
                    b"",
                    content_type=mime_str,
                    extra_headers={
                        "Content-Range": f"bytes */{total_len}",
                        "Accept-Ranges": "bytes",
                    },
                    head_only=head_only,
                )
                return
            self._send_bytes(
                206,
                data[start : end + 1],
                content_type=mime_str,
                extra_headers={
                    "Content-Range": f"bytes {start}-{end}/{total_len}",
                    "Accept-Ranges": "bytes",
                },
                head_only=head_only,
            )
            return

        self._send_bytes(
            200,
            data,
            content_type=mime_str,
            extra_headers={"Accept-Ranges": "bytes"},
            head_only=head_only,
        )


class WebDavMockServer(_BaseLoopbackHttpServer):
    """Loopback WebDAV server supporting PROPFIND 207 XML, Basic Auth, and Range GET."""

    _handler_cls = _WebDavHandler

    def __init__(
        self,
        root_dir: Optional[Path] = None,
        username: str = "lumina",
        password: str = "webdav_secret",
    ) -> None:
        super().__init__()
        self._owns_tmp = root_dir is None
        self._tmp = ManagedTempDir(prefix="lumina_webdav_") if root_dir is None else None
        self.root_dir: Path = Path(root_dir) if root_dir is not None else self._tmp.path
        self.username = username
        self.password = password
        self.online: bool = True
        self.require_auth: bool = True
        self.malformed_xml: bool = False
        self.latency_ms: float = 0.0
        self._seed_defaults()

    def _seed_defaults(self) -> None:
        album_dir = self.root_dir / "Music" / "Miles Davis" / "Kind of Blue"
        album_dir.mkdir(parents=True, exist_ok=True)
        flac_path = album_dir / "01 - So What.flac"
        if not flac_path.exists():
            generate_flac_file(
                flac_path,
                sample_rate=44100,
                bit_depth=16,
                duration_ms=300,
                title="So What",
                artist="Miles Davis",
                album="Kind of Blue",
                track_number=1,
            )
        cover_path = album_dir / "cover.jpg"
        if not cover_path.exists():
            cover_path.write_bytes(b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9")

    def add_file(self, rel_path: str, data_bytes: bytes) -> Path:
        target = self._resolve_path(rel_path.lstrip("/"))
        if target is None:
            raise ValueError(f"Invalid relative path: {rel_path}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data_bytes)
        return target

    def _resolve_path(self, rel: str) -> Optional[Path]:
        try:
            candidate = (self.root_dir / rel).resolve()
            root_resolved = self.root_dir.resolve()
            if candidate == root_resolved or root_resolved in candidate.parents:
                return candidate
        except OSError:
            return None
        return None

    def reset(self) -> None:
        super().reset()
        self.online = True
        self.require_auth = True
        self.malformed_xml = False
        self.latency_ms = 0.0

    def stop(self) -> None:
        try:
            super().stop()
        finally:
            if self._owns_tmp and self._tmp is not None:
                self._tmp.cleanup()


# ---------------------------------------------------------------------------
# 3. SmbLoopbackFixture
# ---------------------------------------------------------------------------


class _SmbProbeTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address, RequestHandlerClass, owner):
        self.owner = owner
        super().__init__(server_address, RequestHandlerClass)

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        super().server_bind()

    def handle_error(self, request, client_address) -> None:
        _, exc, _ = sys.exc_info() if "sys" in globals() else (None, None, None)
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError)):
            return
        super().handle_error(request, client_address)


class _SmbProbeHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        owner: SmbLoopbackFixture = self.server.owner
        self.request.settimeout(0.05)
        data = b""
        recv_deadline = time.monotonic() + 1.0
        while not owner._stop_event.is_set() and time.monotonic() < recv_deadline:
            try:
                data = self.request.recv(4096)
                break
            except socket.timeout:
                continue
            except OSError:
                data = b""
                break
        owner._append_log(
            {
                "timestamp": time.time(),
                "method": "TCP_SMB",
                "path": f"/{owner.share_name}",
                "query": {},
                "headers": {},
                "body": data,
            }
        )
        if not owner.online or owner._stop_event.is_set():
            return
        if b"\xfeSMB" in data:
            # Minimal NetBIOS + SMB2 Negotiate response header marker
            smb2_hdr = b"\xfeSMB" + b"\x40\x00" + (b"\x00" * 58)
            frame = struct.pack(">I", len(smb2_hdr)) + smb2_hdr
            try:
                self.request.sendall(frame)
            except OSError:
                return
            # Wait gracefully for client EOF (or stop/timeout) so Windows loopback
            # does not reset the connection before the client calls recv().
            close_deadline = time.monotonic() + 0.5
            while not owner._stop_event.is_set() and time.monotonic() < close_deadline:
                try:
                    trailing = self.request.recv(1024)
                    if not trailing:
                        break
                    if b"\xfeSMB" in trailing:
                        self.request.sendall(frame)
                        close_deadline = time.monotonic() + 0.5
                except socket.timeout:
                    continue
                except OSError:
                    break


class SmbLoopbackFixture:
    """Isolated SMB loopback share directory, URI/credential validator, and TCP probe server."""

    def __init__(
        self,
        share_name: str = "music",
        username: str = "lumina",
        password: str = "smb_secret",
    ) -> None:
        self._tmp = ManagedTempDir(prefix="lumina_smb_")
        self.share_name = share_name
        self.username = username
        self.password = password
        self.share_dir: Path = self._tmp.child(share_name, mkdir=True)
        self.online: bool = True
        self.require_auth: bool = True
        self._host = "127.0.0.1"
        self._port = 0
        self._tcp: Optional[_SmbProbeTCPServer] = None
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._lock = threading.Lock()
        self._log: List[Dict[str, Any]] = []
        self._seed_defaults()

    def _seed_defaults(self) -> None:
        album_dir = self.share_dir / "Miles Davis" / "Kind of Blue"
        album_dir.mkdir(parents=True, exist_ok=True)
        generate_flac_file(
            album_dir / "01 - So What.flac",
            sample_rate=96000,
            bit_depth=24,
            duration_ms=300,
            title="So What",
            artist="Miles Davis",
            album="Kind of Blue",
            track_number=1,
        )
        (album_dir / "cover.jpg").write_bytes(
            b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9"
        )

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._port

    @property
    def base_url(self) -> str:
        return self.smb_uri(authenticated=False)

    @property
    def requests_log(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._log)

    def _append_log(self, entry: Dict[str, Any]) -> None:
        with self._lock:
            self._log.append(entry)

    def start(self) -> "SmbLoopbackFixture":
        if self._tcp is not None:
            return self
        self._stop_event.clear()
        self._tcp = _SmbProbeTCPServer(
            (self._host, 0), _SmbProbeHandler, self
        )
        self._port = int(self._tcp.server_address[1])
        self._thread = threading.Thread(
            target=self._tcp.serve_forever,
            kwargs={"poll_interval": 0.05},
            daemon=True,
        )
        self._thread.start()
        wait_for_tcp(self._host, self._port, timeout_s=3.0)
        return self

    def stop(self) -> None:
        self._stop_event.set()
        if self._tcp is not None:
            try:
                self._tcp.shutdown()
                self._tcp.server_close()
            finally:
                self._tcp = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        self._port = 0
        self._tmp.cleanup()

    def reset(self) -> None:
        with self._lock:
            self._log.clear()
        self.online = True
        self.require_auth = True

    def __enter__(self) -> "SmbLoopbackFixture":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()

    def smb_uri(self, rel_path: str = "", authenticated: bool = True) -> str:
        rel = rel_path.lstrip("/\\").replace("\\", "/")
        auth = f"{self.username}:{self.password}@" if authenticated else ""
        port_part = f":{self._port}" if self._port else ""
        suffix = f"/{rel}" if rel else ""
        return f"smb://{auth}{self._host}{port_part}/{self.share_name}{suffix}"

    def unc_path(self, rel_path: str = "") -> str:
        rel = rel_path.lstrip("/\\").replace("/", "\\")
        suffix = f"\\{rel}" if rel else ""
        return f"\\\\{self._host}\\{self.share_name}{suffix}"

    def local_path(self, rel_path: str = "") -> Path:
        return self.resolve_local_file(rel_path)

    def validate_credentials(
        self,
        uri: str,
        expected_user: Optional[str] = None,
        expected_password: Optional[str] = None,
    ) -> bool:
        parsed = parse_remote_share_uri(uri)
        if parsed["protocol"] != "smb":
            return False
        if not self.require_auth:
            return True
        user = expected_user if expected_user is not None else self.username
        pw = expected_password if expected_password is not None else self.password
        return parsed.get("username") == user and parsed.get("password") == pw

    def resolve_local_file(self, uri_or_rel: str) -> Path:
        if uri_or_rel.startswith("smb://"):
            parsed = parse_remote_share_uri(uri_or_rel)
            share_name = parsed.get("share_name", "")
            if share_name and share_name != self.share_name:
                raise ValueError(
                    f"SMB share mismatch: expected {self.share_name!r}, got {share_name!r}"
                )
            rel = unquote(parsed.get("relative_path", "")).lstrip("/\\")
        else:
            rel = uri_or_rel.lstrip("/\\")
        root_resolved = self.share_dir.resolve()
        candidate = (root_resolved / rel).resolve()
        if candidate != root_resolved and root_resolved not in candidate.parents:
            raise ValueError(f"Path traversal rejected: {uri_or_rel}")
        return candidate


# ---------------------------------------------------------------------------
# 4. MusicBrainzMockServer & DiscogsMockServer
# ---------------------------------------------------------------------------


class _MetadataRateLimitMixin:
    def _init_rate_limit(self) -> None:
        if not hasattr(self, "_lock"):
            self._lock = threading.Lock()
        self.require_user_agent: bool = True
        self.inject_429_count: int = 0
        self.retry_after_sec: int = 1
        self.inject_503_count: int = 0
        self.max_requests_per_sec: Optional[float] = None
        self._req_timestamps: List[float] = []

    def _reset_rate_limit(self) -> None:
        with self._lock:
            self.require_user_agent = True
            self.inject_429_count = 0
            self.retry_after_sec = 1
            self.inject_503_count = 0
            self.max_requests_per_sec = None
            self._req_timestamps.clear()

    def check_faults(self, headers: Dict[str, str]) -> Optional[Tuple[int, Dict[str, Any], Dict[str, str]]]:
        with self._lock:
            if self.require_user_agent and not headers.get("user-agent", "").strip():
                return (
                    400,
                    {"error": "Missing required User-Agent header"},
                    {},
                )
            if self.inject_429_count > 0:
                self.inject_429_count -= 1
                return (
                    429,
                    {"error": "Rate limit exceeded (injected)"},
                    {"Retry-After": str(self.retry_after_sec)},
                )
            if self.inject_503_count > 0:
                self.inject_503_count -= 1
                return (
                    503,
                    {"error": "Service temporarily unavailable (injected)"},
                    {},
                )
            if self.max_requests_per_sec is not None and self.max_requests_per_sec > 0:
                now = time.monotonic()
                self._req_timestamps = [t for t in self._req_timestamps if now - t < 1.0]
                if len(self._req_timestamps) >= self.max_requests_per_sec:
                    return (
                        429,
                        {"error": "Sliding-window rate limit exceeded"},
                        {"Retry-After": str(self.retry_after_sec)},
                    )
                self._req_timestamps.append(now)
            return None


class _MusicBrainzHandler(_LoopbackHTTPHandler):
    def do_GET(self) -> None:
        srv: MusicBrainzMockServer = self.server.owner_server
        body = self._read_body()
        req = self._record_request(body)
        fault = srv.check_faults(req["headers"])
        if fault is not None:
            status, payload, extra = fault
            self._send_json(status, payload, extra_headers=extra)
            return

        path = req["path"]
        if path == "/ws/2/release-group":
            q = (req["query"].get("query") or ["Dark Side"])[0]
            self._send_json(
                200,
                {
                    "created": "2026-01-01T00:00:00Z",
                    "count": 1,
                    "offset": 0,
                    "release-groups": [
                        {
                            "id": "f5093c06-23e3-404f-aeaa-40f72885ee3a",
                            "title": "The Dark Side of the Moon" if "dark" in q.lower() else q,
                            "primary-type": "Album",
                            "first-release-date": "1973-03-01",
                            "artist-credit": [
                                {
                                    "name": "Pink Floyd",
                                    "artist": {
                                        "id": "83d91898-7763-47d7-b03b-b92132375c47",
                                        "name": "Pink Floyd",
                                        "sort-name": "Pink Floyd",
                                    },
                                }
                            ],
                        }
                    ],
                },
            )
            return

        if path.startswith("/ws/2/release-group/"):
            mbid = path.rsplit("/", 1)[-1]
            self._send_json(
                200,
                {
                    "id": mbid,
                    "title": "The Dark Side of the Moon",
                    "primary-type": "Album",
                    "first-release-date": "1973-03-01",
                    "artist-credit": [
                        {
                            "name": "Pink Floyd",
                            "artist": {
                                "id": "83d91898-7763-47d7-b03b-b92132375c47",
                                "name": "Pink Floyd",
                                "sort-name": "Pink Floyd",
                            },
                        }
                    ],
                    "releases": [
                        {
                            "id": "b84ee12a-09ef-421b-82de-0441a926375b",
                            "title": "The Dark Side of the Moon",
                            "date": "1973-03-01",
                        }
                    ],
                },
            )
            return

        if path.startswith("/ws/2/release/"):
            mbid = path.rsplit("/", 1)[-1]
            self._send_json(
                200,
                {
                    "id": mbid,
                    "title": "The Dark Side of the Moon",
                    "barcode": "077774600125",
                    "date": "1973-03-01",
                    "media": [
                        {
                            "position": 1,
                            "tracks": [
                                {
                                    "number": "1",
                                    "title": "Time",
                                    "length": 425000,
                                    "recording": {
                                        "id": "rec-time-001",
                                        "title": "Time",
                                        "artist-credit": [
                                            {
                                                "name": "Pink Floyd",
                                                "artist": {
                                                    "id": "83d91898-7763-47d7-b03b-b92132375c47",
                                                    "name": "Pink Floyd",
                                                },
                                            }
                                        ],
                                        "relations": [
                                            {
                                                "type": "engineer",
                                                "artist": {
                                                    "id": "art-alan-parsons",
                                                    "name": "Alan Parsons",
                                                    "sort-name": "Parsons, Alan",
                                                },
                                            }
                                        ],
                                    },
                                }
                            ],
                        }
                    ],
                },
            )
            return

        if path.startswith("/ws/2/recording/"):
            mbid = path.rsplit("/", 1)[-1]
            self._send_json(
                200,
                {
                    "id": mbid,
                    "title": "Time",
                    "length": 425000,
                    "artist-credit": [
                        {
                            "name": "Pink Floyd",
                            "artist": {
                                "id": "83d91898-7763-47d7-b03b-b92132375c47",
                                "name": "Pink Floyd",
                            },
                        }
                    ],
                    "relations": [
                        {
                            "type": "engineer",
                            "artist": {
                                "id": "art-alan-parsons",
                                "name": "Alan Parsons",
                                "sort-name": "Parsons, Alan",
                            },
                        },
                        {
                            "type": "producer",
                            "artist": {
                                "id": "83d91898-7763-47d7-b03b-b92132375c47",
                                "name": "Pink Floyd",
                                "sort-name": "Pink Floyd",
                            },
                        },
                    ],
                },
            )
            return

        if path.startswith("/ws/2/artist/"):
            mbid = path.rsplit("/", 1)[-1]
            self._send_json(
                200,
                {
                    "id": mbid,
                    "name": "Pink Floyd",
                    "sort-name": "Pink Floyd",
                    "type": "Group",
                    "disambiguation": "English rock band",
                    "release-groups": [
                        {
                            "id": "f5093c06-23e3-404f-aeaa-40f72885ee3a",
                            "title": "The Dark Side of the Moon",
                            "first-release-date": "1973-03-01",
                        }
                    ],
                },
            )
            return

        self._send_json(404, {"error": "Not Found", "path": path})


class MusicBrainzMockServer(_BaseLoopbackHttpServer, _MetadataRateLimitMixin):
    """Loopback MusicBrainz /ws/2 JSON API mock with 429/503 rate-limit fault injection."""

    _handler_cls = _MusicBrainzHandler

    def __init__(self) -> None:
        super().__init__()
        self._init_rate_limit()

    def reset(self) -> None:
        super().reset()
        self._reset_rate_limit()


class _DiscogsHandler(_LoopbackHTTPHandler):
    def do_GET(self) -> None:
        srv: DiscogsMockServer = self.server.owner_server
        body = self._read_body()
        req = self._record_request(body)
        fault = srv.check_faults(req["headers"])
        if fault is not None:
            status, payload, extra = fault
            self._send_json(status, payload, extra_headers=extra)
            return

        path = req["path"]
        if path == "/database/search":
            self._send_json(
                200,
                {
                    "pagination": {"page": 1, "pages": 1, "items": 1},
                    "results": [
                        {
                            "id": 10293,
                            "master_id": 10362,
                            "title": "Pink Floyd - The Dark Side Of The Moon",
                            "year": "1973",
                            "catno": "SHVL 804",
                            "barcode": ["077774600125"],
                            "type": "release",
                        }
                    ],
                },
            )
            return

        if path.startswith("/releases/"):
            rid = path.rsplit("/", 1)[-1]
            self._send_json(
                200,
                {
                    "id": int(rid) if rid.isdigit() else rid,
                    "title": "The Dark Side Of The Moon",
                    "year": 1973,
                    "artists": [{"id": 45467, "name": "Pink Floyd"}],
                    "extraartists": [
                        {"id": 2001, "name": "Alan Parsons", "role": "Engineer"},
                        {"id": 2002, "name": "Storm Thorgerson", "role": "Design"},
                    ],
                    "tracklist": [
                        {"position": "A1", "title": "Speak To Me", "duration": "1:30"},
                        {"position": "A4", "title": "Time", "duration": "7:05"},
                    ],
                    "identifiers": [{"type": "Barcode", "value": "077774600125"}],
                },
            )
            return

        if path.startswith("/masters/"):
            mid = path.rsplit("/", 1)[-1]
            self._send_json(
                200,
                {
                    "id": int(mid) if mid.isdigit() else mid,
                    "title": "The Dark Side Of The Moon",
                    "year": 1973,
                    "main_release": 10293,
                    "artists": [{"id": 45467, "name": "Pink Floyd"}],
                },
            )
            return

        if path.startswith("/artists/"):
            aid = path.rsplit("/", 1)[-1]
            self._send_json(
                200,
                {
                    "id": int(aid) if aid.isdigit() else aid,
                    "name": "Pink Floyd",
                    "profile": "English progressive rock band formed in London in 1965.",
                },
            )
            return

        self._send_json(404, {"error": "Not Found", "path": path})


class DiscogsMockServer(_BaseLoopbackHttpServer, _MetadataRateLimitMixin):
    """Loopback Discogs JSON API mock with 429 Retry-After / 503 injection."""

    _handler_cls = _DiscogsHandler

    def __init__(self) -> None:
        super().__init__()
        self._init_rate_limit()

    def reset(self) -> None:
        super().reset()
        self._reset_rate_limit()


# ---------------------------------------------------------------------------
# 5. WanTlsProxyMockServer
# ---------------------------------------------------------------------------


def _generate_ephemeral_cert(
    cert_path: Path, key_path: Path, expired: bool = False
) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name(
        [x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")]
    )
    now = datetime.datetime.now(datetime.timezone.utc)
    if expired:
        not_before = datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)
        not_after = datetime.datetime(2021, 1, 1, tzinfo=datetime.timezone.utc)
    else:
        not_before = now - datetime.timedelta(minutes=5)
        not_after = now + datetime.timedelta(days=7)

    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(
            x509.SubjectAlternativeName(
                [
                    x509.DNSName("localhost"),
                    x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
                ]
            ),
            critical=False,
        )
        .add_extension(
            x509.BasicConstraints(ca=True, path_length=None), critical=True
        )
        .sign(key, hashes.SHA256())
    )
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )


class WanTlsProxyMockServer:
    """Ephemeral-cert TLS reverse proxy forwarding HTTPS REST + WSS frames to local core-server."""

    def __init__(
        self,
        target_host: str = "127.0.0.1",
        target_port: int = 0,
        expired_cert: bool = False,
    ) -> None:
        self.target_host = target_host
        self.target_port = target_port
        self.expired_cert = expired_cert
        self._tmp = ManagedTempDir(prefix="lumina_tls_proxy_")
        self._cert_path = self._tmp.child("cert.pem")
        self._key_path = self._tmp.child("key.pem")
        _generate_ephemeral_cert(self._cert_path, self._key_path, expired=expired_cert)

        self._host = "127.0.0.1"
        self._port = 0
        self.force_502: bool = False
        self.force_401: bool = False
        self.latency_ms: float = 0.0
        self._lock = threading.Lock()
        self._log: List[Dict[str, Any]] = []
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._server: Optional[asyncio.AbstractServer] = None
        self._tasks: Set[asyncio.Task] = set()
        self._started = threading.Event()
        self._start_err: Optional[BaseException] = None

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._port

    @property
    def cert_pem_path(self) -> Path:
        return self._cert_path

    @property
    def ca_cert_path(self) -> Path:
        return self._cert_path

    @property
    def base_url(self) -> str:
        return self.https_base_url

    @property
    def https_base_url(self) -> str:
        return f"https://{self._host}:{self._port}"

    def wss_url(self, path: str = "/api/v1/ws") -> str:
        p = path if path.startswith("/") else "/" + path
        return f"wss://{self._host}:{self._port}{p}"

    @property
    def requests_log(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._log)

    def client_ssl_context(self) -> ssl.SSLContext:
        return ssl.create_default_context(cafile=str(self._cert_path))

    def reset(self) -> None:
        with self._lock:
            self._log.clear()
        self.force_502 = False
        self.force_401 = False
        self.latency_ms = 0.0

    async def _read_http_head_and_body(
        self,
        reader: asyncio.StreamReader,
        initial_buf: bytes = b"",
        is_response: bool = False,
        req_method: str = "GET",
    ) -> Optional[Tuple[bytes, Dict[str, str], bytes, bytes, bool]]:
        """
        Read one complete HTTP/1.x head + body (if framed) from `reader`.
        Returns (raw_head, hdr_dict, body_bytes, trailing_bytes, eof_after_body) or None on EOF before head.
        """
        buf = bytearray(initial_buf)
        while b"\r\n\r\n" not in buf:
            chunk = await reader.read(4096)
            if not chunk:
                return None
            buf.extend(chunk)
            if len(buf) > 131072:
                return None

        sep_idx = buf.index(b"\r\n\r\n")
        raw_head = bytes(buf[:sep_idx])
        rest = bytearray(buf[sep_idx + 4 :])
        lines = raw_head.split(b"\r\n")
        hdr_dict: Dict[str, str] = {}
        for line in lines[1:]:
            if b":" in line:
                k, v = line.split(b":", 1)
                hdr_dict[k.decode("latin-1").strip().lower()] = v.decode("latin-1").strip()

        # Check WebSocket upgrade or 101/204/304/HEAD bodyless messages
        if not is_response and hdr_dict.get("upgrade", "").lower() == "websocket":
            return raw_head, hdr_dict, b"", bytes(rest), False

        if is_response:
            status_parts = lines[0].decode("latin-1", errors="replace").split(" ", 2)
            try:
                status_code = int(status_parts[1]) if len(status_parts) > 1 else 200
            except ValueError:
                status_code = 200
            if (
                req_method.upper() == "HEAD"
                or (100 <= status_code < 200)
                or status_code in (204, 304)
            ):
                return raw_head, hdr_dict, b"", bytes(rest), False

        te_val = hdr_dict.get("transfer-encoding", "").lower()
        if "chunked" in te_val:
            body = bytearray()
            eof_hit = False
            while True:
                while b"\r\n" not in rest:
                    chunk = await reader.read(4096)
                    if not chunk:
                        eof_hit = True
                        break
                    rest.extend(chunk)
                if b"\r\n" not in rest:
                    body.extend(rest)
                    rest.clear()
                    break
                crlf_idx = rest.index(b"\r\n")
                size_line = bytes(rest[:crlf_idx])
                del rest[: crlf_idx + 2]
                body.extend(size_line + b"\r\n")
                try:
                    chunk_sz = int(size_line.split(b";", 1)[0].strip(), 16)
                except ValueError:
                    eof_hit = True
                    break
                if chunk_sz == 0:
                    # Read optional trailers until empty CRLF line
                    while True:
                        while b"\r\n" not in rest:
                            chunk = await reader.read(4096)
                            if not chunk:
                                eof_hit = True
                                break
                            rest.extend(chunk)
                        if b"\r\n" not in rest:
                            break
                        t_idx = rest.index(b"\r\n")
                        t_line = bytes(rest[: t_idx + 2])
                        del rest[: t_idx + 2]
                        body.extend(t_line)
                        if t_idx == 0:
                            break
                    break
                while len(rest) < chunk_sz + 2:
                    chunk = await reader.read(4096)
                    if not chunk:
                        eof_hit = True
                        break
                    rest.extend(chunk)
                take = min(len(rest), chunk_sz + 2)
                body.extend(rest[:take])
                del rest[:take]
                if eof_hit:
                    break
            return raw_head, hdr_dict, bytes(body), bytes(rest), eof_hit

        if "content-length" in hdr_dict:
            try:
                clen = max(0, int(hdr_dict["content-length"]))
            except ValueError:
                clen = 0
            while len(rest) < clen:
                chunk = await reader.read(4096)
                if not chunk:
                    break
                rest.extend(chunk)
            body = bytes(rest[:clen])
            trailing = bytes(rest[clen:])
            return raw_head, hdr_dict, body, trailing, False

        if is_response:
            # No Content-Length and not chunked: read until upstream EOF
            while True:
                chunk = await reader.read(16384)
                if not chunk:
                    break
                rest.extend(chunk)
            return raw_head, hdr_dict, bytes(rest), b"", True

        return raw_head, hdr_dict, b"", bytes(rest), False

    async def _handle_client(
        self, client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter
    ) -> None:
        task = asyncio.current_task()
        if task is not None:
            self._tasks.add(task)
        upstream_reader: Optional[asyncio.StreamReader] = None
        upstream_writer: Optional[asyncio.StreamWriter] = None
        client_extra = b""
        try:
            while True:
                msg = await self._read_http_head_and_body(
                    client_reader, initial_buf=client_extra, is_response=False
                )
                if msg is None:
                    return
                raw_head, hdr_dict, req_body, client_extra, _ = msg

                lines = raw_head.split(b"\r\n")
                req_line = lines[0].decode("latin-1", errors="replace")
                parts = req_line.split(" ", 2)
                method = parts[0] if len(parts) > 0 else "GET"
                target_path = parts[1] if len(parts) > 1 else "/"
                parsed = urlparse(target_path)

                filtered_lines: List[bytes] = [lines[0]]
                for line in lines[1:]:
                    if b":" in line:
                        k, _ = line.split(b":", 1)
                        k_lower = k.decode("latin-1").strip().lower()
                        if k_lower not in ("x-forwarded-proto", "x-forwarded-for"):
                            filtered_lines.append(line)

                is_ws_upgrade = hdr_dict.get("upgrade", "").lower() == "websocket"

                with self._lock:
                    self._log.append(
                        {
                            "timestamp": time.time(),
                            "method": method,
                            "path": parsed.path,
                            "query": parse_qs(parsed.query, keep_blank_values=True),
                            "headers": hdr_dict,
                            "body": req_body,
                        }
                    )

                if self.latency_ms > 0:
                    await asyncio.sleep(self.latency_ms / 1000.0)

                if self.force_401:
                    body = b'{"status":"error","error":"Proxy injected 401"}'
                    resp = (
                        f"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n"
                        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
                    ).encode("ascii") + body
                    client_writer.write(resp)
                    await client_writer.drain()
                    return

                if self.force_502 or not self.target_port:
                    body = b'{"status":"error","error":"Bad Gateway"}'
                    resp = (
                        f"HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\n"
                        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
                    ).encode("ascii") + body
                    client_writer.write(resp)
                    await client_writer.drain()
                    return

                if is_ws_upgrade:
                    if upstream_writer is not None:
                        try:
                            upstream_writer.close()
                        except Exception:
                            pass
                        upstream_writer = None
                        upstream_reader = None
                    upstream_reader, upstream_writer = await asyncio.open_connection(
                        self.target_host, self.target_port
                    )
                    sock = upstream_writer.get_extra_info("socket")
                    if sock is not None:
                        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

                    filtered_lines.append(b"X-Forwarded-Proto: https")
                    filtered_lines.append(b"X-Forwarded-For: 127.0.0.1")
                    rebuilt_head = b"\r\n".join(filtered_lines) + b"\r\n\r\n"
                    upstream_writer.write(rebuilt_head + client_extra)
                    await upstream_writer.drain()

                    async def _pipe(
                        src: asyncio.StreamReader, dst: asyncio.StreamWriter
                    ) -> None:
                        try:
                            while True:
                                data = await src.read(16384)
                                if not data:
                                    break
                                dst.write(data)
                                await dst.drain()
                        except (OSError, asyncio.CancelledError):
                            pass
                        finally:
                            try:
                                dst.close()
                            except Exception:
                                pass

                    await asyncio.gather(
                        _pipe(client_reader, upstream_writer),
                        _pipe(upstream_reader, client_writer),
                        return_exceptions=True,
                    )
                    return

                filtered_lines.append(b"X-Forwarded-Proto: https")
                filtered_lines.append(b"X-Forwarded-For: 127.0.0.1")
                wire_req = b"\r\n".join(filtered_lines) + b"\r\n\r\n" + req_body

                resp_msg = None
                for attempt in range(2):
                    if upstream_writer is None or upstream_writer.is_closing():
                        upstream_reader, upstream_writer = await asyncio.open_connection(
                            self.target_host, self.target_port
                        )
                        sock = upstream_writer.get_extra_info("socket")
                        if sock is not None:
                            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    try:
                        upstream_writer.write(wire_req)
                        await upstream_writer.drain()
                        assert upstream_reader is not None
                        resp_msg = await self._read_http_head_and_body(
                            upstream_reader,
                            initial_buf=b"",
                            is_response=True,
                            req_method=method,
                        )
                    except OSError:
                        resp_msg = None

                    if resp_msg is not None:
                        break
                    # Stale upstream connection closed before response; reconnect once
                    try:
                        upstream_writer.close()
                    except Exception:
                        pass
                    upstream_writer = None
                    upstream_reader = None
                    if attempt == 1:
                        return

                assert resp_msg is not None
                resp_head, resp_hdrs, resp_body, _, eof_after_body = resp_msg
                client_writer.write(resp_head + b"\r\n\r\n" + resp_body)
                await client_writer.drain()

                req_conn = hdr_dict.get("connection", "").lower()
                resp_conn = resp_hdrs.get("connection", "").lower()
                if eof_after_body or "close" in resp_conn:
                    try:
                        upstream_writer.close()
                    except Exception:
                        pass
                    upstream_writer = None
                    upstream_reader = None
                if "close" in req_conn or eof_after_body:
                    return
        except (Exception, asyncio.CancelledError):
            pass
        finally:
            if task is not None:
                self._tasks.discard(task)
            for writer in (client_writer, upstream_writer):
                if writer is not None:
                    try:
                        writer.close()
                    except Exception:
                        pass

    def _run_loop(self) -> None:
        loop = asyncio.SelectorEventLoop() if hasattr(asyncio, "SelectorEventLoop") else asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self._loop = loop
        try:
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ssl_ctx.load_cert_chain(
                certfile=str(self._cert_path), keyfile=str(self._key_path)
            )

            async def _boot():
                self._server = await asyncio.start_server(
                    self._handle_client,
                    self._host,
                    0,
                    ssl=ssl_ctx,
                    reuse_address=True,
                )
                sock = self._server.sockets[0]
                self._port = int(sock.getsockname()[1])

            loop.run_until_complete(_boot())
            self._started.set()
            loop.run_forever()
        except BaseException as exc:
            self._start_err = exc
            self._started.set()
        finally:
            async def _shutdown_async() -> None:
                if self._server is not None:
                    self._server.close()
                    try:
                        await asyncio.wait_for(self._server.wait_closed(), timeout=1.0)
                    except Exception:
                        pass
                pending = [t for t in list(self._tasks) if not t.done()]
                for t in pending:
                    t.cancel()
                if pending:
                    await asyncio.gather(*pending, return_exceptions=True)

            try:
                loop.run_until_complete(_shutdown_async())
            except Exception:
                pass
            loop.close()

    def start(self) -> "WanTlsProxyMockServer":
        if self._thread is not None:
            return self
        self._started.clear()
        self._start_err = None
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()
        self._started.wait(timeout=5.0)
        if self._start_err is not None:
            raise RuntimeError(f"WanTlsProxyMockServer failed to start: {self._start_err}")
        wait_for_tcp(self._host, self._port, timeout_s=3.0)
        return self

    def stop(self) -> None:
        if self._loop is not None and self._loop.is_running():
            self._loop.call_soon_threadsafe(self._loop.stop)
        if self._thread is not None:
            self._thread.join(timeout=3.0)
            self._thread = None
        self._loop = None
        self._server = None
        self._port = 0
        self._tmp.cleanup()

    def __enter__(self) -> "WanTlsProxyMockServer":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()


# ---------------------------------------------------------------------------
# 6. DlnaMediaRendererMock (HTTP UPnP/SOAP + UDP SSDP M-SEARCH responder)
# ---------------------------------------------------------------------------

_AVTRANSPORT_SCPD = """<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>SetAVTransportURI</name></action>
    <action><name>Play</name></action>
    <action><name>Pause</name></action>
    <action><name>Stop</name></action>
    <action><name>Seek</name></action>
    <action><name>GetPositionInfo</name></action>
    <action><name>GetTransportInfo</name></action>
  </actionList>
</scpd>"""

_RENDERING_SCPD = """<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>GetVolume</name></action>
    <action><name>SetVolume</name></action>
    <action><name>GetMute</name></action>
    <action><name>SetMute</name></action>
  </actionList>
</scpd>"""


def _format_hms(seconds: int) -> str:
    s = max(0, int(seconds))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{sec:02d}"


def _parse_hms(hms: str) -> int:
    parts = [int(p) for p in hms.strip().split(":")]
    if any(p < 0 for p in parts):
        raise ValueError(f"Negative HMS component: {hms!r}")
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 1:
        return parts[0]
    raise ValueError(f"Invalid HMS time format: {hms!r}")


def _find_xml_text(root: Any, tag_suffix: str, default: str = "") -> str:
    for elem in root.iter():
        tag = elem.tag.rsplit("}", 1)[-1]
        if tag == tag_suffix:
            return (elem.text or "").strip()
    return default


class _DlnaHttpHandler(_LoopbackHTTPHandler):
    def do_GET(self) -> None:
        srv: DlnaMediaRendererMock = self.server.owner_server
        body = self._read_body()
        req = self._record_request(body)
        path = req["path"]

        if path == "/description.xml":
            xml = (
                '<?xml version="1.0" encoding="utf-8"?>'
                '<root xmlns="urn:schemas-upnp-org:device-1-0">'
                "<specVersion><major>1</major><minor>0</minor></specVersion>"
                "<device>"
                "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
                "<friendlyName>Lumina Mock DLNA Renderer</friendlyName>"
                "<manufacturer>Lumina Audio</manufacturer>"
                "<modelName>MockRenderer</modelName>"
                f"<UDN>{srv.udn}</UDN>"
                "<serviceList>"
                "<service>"
                "<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>"
                "<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>"
                "<SCPDURL>/upnp/scpd/AVTransport.xml</SCPDURL>"
                "<controlURL>/upnp/control/AVTransport</controlURL>"
                "</service>"
                "<service>"
                "<serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>"
                "<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>"
                "<SCPDURL>/upnp/scpd/RenderingControl.xml</SCPDURL>"
                "<controlURL>/upnp/control/RenderingControl</controlURL>"
                "</service>"
                "</serviceList>"
                "</device>"
                "</root>"
            )
            self._send_bytes(
                200, xml.encode("utf-8"), content_type='text/xml; charset="utf-8"'
            )
            return

        if path == "/upnp/scpd/AVTransport.xml":
            self._send_bytes(
                200,
                _AVTRANSPORT_SCPD.encode("utf-8"),
                content_type='text/xml; charset="utf-8"',
            )
            return

        if path == "/upnp/scpd/RenderingControl.xml":
            self._send_bytes(
                200,
                _RENDERING_SCPD.encode("utf-8"),
                content_type='text/xml; charset="utf-8"',
            )
            return

        self._send_bytes(404, b"Not Found", content_type="text/plain")

    def do_POST(self) -> None:
        srv: DlnaMediaRendererMock = self.server.owner_server
        body = self._read_body()
        req = self._record_request(body)
        path = req["path"]

        soap_action = req["headers"].get("soapaction", "").strip('"')
        action = soap_action.rsplit("#", 1)[-1] if "#" in soap_action else ""

        try:
            xml_root = SafeET.fromstring(body.decode("utf-8"))
        except Exception:
            self._send_soap_fault(402, "Invalid XML")
            return

        if not action:
            # Infer action from first element inside SOAP Body
            for elem in xml_root.iter():
                if elem.tag.rsplit("}", 1)[-1] == "Body":
                    for child in elem:
                        action = child.tag.rsplit("}", 1)[-1]
                        break

        if srv.soap_fault_action and srv.soap_fault_action == action:
            self._send_soap_fault(401, f"Injected SOAP fault for {action}")
            return

        if path == "/upnp/control/AVTransport":
            ns = "urn:schemas-upnp-org:service:AVTransport:1"
            if action == "SetAVTransportURI":
                srv.current_uri = _find_xml_text(xml_root, "CurrentURI")
                srv.current_metadata = _find_xml_text(xml_root, "CurrentURIMetaData")
                srv.transport_state = "STOPPED"
                self._send_soap_ok(ns, action, "")
                return

            if action == "Play":
                srv.transport_state = "PLAYING"
                srv.play_started_at = time.monotonic()
                if srv.fetch_uri_on_play and srv.current_uri.startswith(
                    ("http://", "https://")
                ):
                    try:
                        r = requests.get(srv.current_uri, timeout=3.0)
                        srv.fetched_media_status = r.status_code
                        srv.fetched_media_bytes = r.content
                    except requests.RequestException:
                        srv.fetched_media_status = 0
                        srv.fetched_media_bytes = b""
                self._send_soap_ok(ns, action, "")
                return

            if action == "Pause":
                srv.transport_state = "PAUSED_PLAYBACK"
                self._send_soap_ok(ns, action, "")
                return

            if action == "Stop":
                srv.transport_state = "STOPPED"
                srv.position_sec = 0
                self._send_soap_ok(ns, action, "")
                return

            if action == "Seek":
                target = _find_xml_text(xml_root, "Target", "00:00:00")
                try:
                    srv.position_sec = _parse_hms(target)
                except ValueError:
                    self._send_soap_fault(402, "Invalid Args")
                    return
                self._send_soap_ok(ns, action, "")
                return

            if action == "GetPositionInfo":
                hms = _format_hms(srv.position_sec)
                inner = (
                    "<Track>1</Track>"
                    "<TrackDuration>00:04:05</TrackDuration>"
                    f"<TrackMetaData>{xml_escape(srv.current_metadata)}</TrackMetaData>"
                    f"<TrackURI>{xml_escape(srv.current_uri)}</TrackURI>"
                    f"<RelTime>{hms}</RelTime>"
                    f"<AbsTime>{hms}</AbsTime>"
                    "<RelCount>2147483647</RelCount>"
                    "<AbsCount>2147483647</AbsCount>"
                )
                self._send_soap_ok(ns, action, inner)
                return

            if action == "GetTransportInfo":
                inner = (
                    f"<CurrentTransportState>{srv.transport_state}</CurrentTransportState>"
                    "<CurrentTransportStatus>OK</CurrentTransportStatus>"
                    "<CurrentSpeed>1</CurrentSpeed>"
                )
                self._send_soap_ok(ns, action, inner)
                return

            self._send_soap_fault(401, f"Invalid Action: {action}")
            return

        if path == "/upnp/control/RenderingControl":
            ns = "urn:schemas-upnp-org:service:RenderingControl:1"
            if action == "SetVolume":
                vol_str = _find_xml_text(xml_root, "DesiredVolume", "50")
                try:
                    vol = int(vol_str)
                except ValueError:
                    self._send_soap_fault(402, "Invalid Args")
                    return
                srv.volume = max(0, min(100, vol))
                self._send_soap_ok(ns, action, "")
                return

            if action == "GetVolume":
                self._send_soap_ok(ns, action, f"<CurrentVolume>{srv.volume}</CurrentVolume>")
                return

            if action == "SetMute":
                mute_str = _find_xml_text(xml_root, "DesiredMute", "0")
                srv.muted = mute_str in ("1", "true", "True")
                self._send_soap_ok(ns, action, "")
                return

            if action == "GetMute":
                self._send_soap_ok(
                    ns, action, f"<CurrentMute>{1 if srv.muted else 0}</CurrentMute>"
                )
                return

            self._send_soap_fault(401, f"Invalid Action: {action}")
            return

        self._send_soap_fault(401, f"Unknown control path: {path}")

    def _send_soap_ok(self, service_ns: str, action: str, inner_xml: str) -> None:
        env = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            "<s:Body>"
            f'<u:{action}Response xmlns:u="{service_ns}">{inner_xml}</u:{action}Response>'
            "</s:Body>"
            "</s:Envelope>"
        )
        self._send_bytes(
            200, env.encode("utf-8"), content_type='text/xml; charset="utf-8"'
        )

    def _send_soap_fault(self, error_code: int, error_desc: str) -> None:
        env = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            "<s:Body><s:Fault>"
            "<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>"
            "<detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\">"
            f"<errorCode>{error_code}</errorCode>"
            f"<errorDescription>{xml_escape(error_desc)}</errorDescription>"
            "</UPnPError></detail>"
            "</s:Fault></s:Body></s:Envelope>"
        )
        self._send_bytes(
            500, env.encode("utf-8"), content_type='text/xml; charset="utf-8"'
        )


class DlnaMediaRendererMock(_BaseLoopbackHttpServer):
    """Loopback UPnP/DLNA MediaRenderer mock (UDP SSDP M-SEARCH + HTTP XML/SOAP)."""

    _handler_cls = _DlnaHttpHandler

    def __init__(self) -> None:
        super().__init__()
        self.udn = "uuid:lumina-mock-dlna-renderer-0001"
        self.current_uri: str = ""
        self.current_metadata: str = ""
        self.transport_state: str = "NO_MEDIA_PRESENT"
        self.position_sec: int = 0
        self.volume: int = 50
        self.muted: bool = False
        self.play_started_at: Optional[float] = None
        self.fetch_uri_on_play: bool = True
        self.fetched_media_bytes: bytes = b""
        self.fetched_media_status: int = 0
        self.soap_fault_action: Optional[str] = None
        self._ssdp_sock: Optional[socket.socket] = None
        self._ssdp_host: str = _resolve_udp_loopback_host()
        self._ssdp_port: int = 0
        self._ssdp_thread: Optional[threading.Thread] = None
        self._ssdp_stop = threading.Event()

    @property
    def http_port(self) -> int:
        return self._port

    @property
    def ssdp_host(self) -> str:
        return self._ssdp_host

    @property
    def ssdp_port(self) -> int:
        return self._ssdp_port

    def _ssdp_loop(self) -> None:
        sock = self._ssdp_sock
        if sock is None:
            return
        while not self._ssdp_stop.is_set():
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            text = data.decode("utf-8", errors="replace")
            self._append_log(
                {
                    "timestamp": time.time(),
                    "method": "SSDP",
                    "path": "/",
                    "query": {},
                    "headers": {},
                    "body": data,
                }
            )
            if "M-SEARCH" in text and "ssdp:discover" in text.lower():
                st = "urn:schemas-upnp-org:device:MediaRenderer:1"
                for line in text.splitlines():
                    if line.lower().startswith("st:"):
                        req_st = line.split(":", 1)[1].strip()
                        if req_st in (
                            "ssdp:all",
                            "upnp:rootdevice",
                            "urn:schemas-upnp-org:device:MediaRenderer:1",
                        ):
                            st = req_st
                        break
                resp = (
                    "HTTP/1.1 200 OK\r\n"
                    "CACHE-CONTROL: max-age=1800\r\n"
                    "EXT:\r\n"
                    f"LOCATION: {self.base_url}/description.xml\r\n"
                    "SERVER: Windows/10 UPnP/1.1 LuminaMock/1.0\r\n"
                    f"ST: {st}\r\n"
                    f"USN: {self.udn}::{st}\r\n\r\n"
                ).encode("utf-8")
                try:
                    sock.sendto(resp, addr)
                except OSError:
                    pass

    def start(self) -> "DlnaMediaRendererMock":
        super().start()
        self._ssdp_stop.clear()
        self._ssdp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        _disable_udp_connreset(self._ssdp_sock)
        self._ssdp_sock.settimeout(0.1)
        self._ssdp_sock.bind((self._ssdp_host, 0))
        self._ssdp_port = int(self._ssdp_sock.getsockname()[1])
        self._ssdp_thread = threading.Thread(target=self._ssdp_loop, daemon=True)
        self._ssdp_thread.start()
        return self

    def stop(self) -> None:
        self._ssdp_stop.set()
        if self._ssdp_sock is not None:
            try:
                self._ssdp_sock.close()
            except OSError:
                pass
            self._ssdp_sock = None
        if self._ssdp_thread is not None:
            self._ssdp_thread.join(timeout=2.0)
            self._ssdp_thread = None
        self._ssdp_port = 0
        super().stop()

    def reset(self) -> None:
        super().reset()
        self.current_uri = ""
        self.current_metadata = ""
        self.transport_state = "NO_MEDIA_PRESENT"
        self.position_sec = 0
        self.volume = 50
        self.muted = False
        self.play_started_at = None
        self.fetch_uri_on_play = True
        self.fetched_media_bytes = b""
        self.fetched_media_status = 0
        self.soap_fault_action = None


# ---------------------------------------------------------------------------
# 7. AirPlayMockServer (RTSP TCP + UDP RTP/Control/Timing)
# ---------------------------------------------------------------------------


class _AirPlayRtspTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, server_address, RequestHandlerClass, owner):
        self.owner = owner
        super().__init__(server_address, RequestHandlerClass)

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        super().server_bind()

    def handle_error(self, request, client_address) -> None:
        _, exc, _ = sys.exc_info() if "sys" in globals() else (None, None, None)
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError)):
            return
        super().handle_error(request, client_address)


class _AirPlayRtspHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        srv: AirPlayMockServer = self.server.owner
        self.request.settimeout(2.0)
        buf = bytearray()
        while True:
            while b"\r\n\r\n" not in buf:
                try:
                    chunk = self.request.recv(4096)
                except OSError:
                    return
                if not chunk:
                    return
                buf.extend(chunk)

            sep = buf.index(b"\r\n\r\n")
            head_bytes = bytes(buf[:sep])
            del buf[: sep + 4]
            lines = head_bytes.decode("latin-1", errors="replace").split("\r\n")
            req_line = lines[0]
            parts = req_line.split(" ", 2)
            method = parts[0] if len(parts) > 0 else "OPTIONS"
            uri = parts[1] if len(parts) > 1 else "*"

            headers: Dict[str, str] = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()

            cseq = headers.get("cseq", "1")
            try:
                clen = int(headers.get("content-length", "0") or "0")
                if clen < 0:
                    raise ValueError("Negative Content-Length")
            except ValueError:
                self._send_rtsp(400, "Bad Request", cseq)
                try:
                    self.request.shutdown(socket.SHUT_WR)
                    self.request.settimeout(0.2)
                    while self.request.recv(1024):
                        pass
                except OSError:
                    pass
                return

            while len(buf) < clen:
                try:
                    chunk = self.request.recv(4096)
                except OSError:
                    return
                if not chunk:
                    return
                buf.extend(chunk)
            body = bytes(buf[:clen])
            del buf[:clen]

            srv._append_log(
                {
                    "timestamp": time.time(),
                    "method": method,
                    "path": uri,
                    "query": {},
                    "headers": headers,
                    "body": body,
                }
            )

            if srv.require_auth_401:
                self._send_rtsp(401, "Unauthorized", cseq, {"WWW-Authenticate": 'Digest realm="AirPlay"'})
                continue

            if method == "OPTIONS":
                self._send_rtsp(
                    200,
                    "OK",
                    cseq,
                    {
                        "Public": (
                            "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, "
                            "TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER"
                        )
                    },
                )
            elif method == "ANNOUNCE":
                if srv.reject_announce:
                    self._send_rtsp(453, "Not Enough Bandwidth", cseq)
                else:
                    srv.sdp_text = body.decode("utf-8", errors="replace")
                    self._send_rtsp(200, "OK", cseq)
            elif method == "SETUP":
                transport = (
                    f"RTP/AVP/UDP;unicast;mode=record;"
                    f"source={srv.rtp_host};"
                    f"server_port={srv.rtp_port};"
                    f"control_port={srv.control_port};"
                    f"timing_port={srv.timing_port}"
                )
                self._send_rtsp(
                    200,
                    "OK",
                    cseq,
                    {"Session": "1", "Transport": transport},
                )
            elif method == "RECORD":
                srv.recording = True
                self._send_rtsp(200, "OK", cseq, {"Audio-Latency": "11025"})
            elif method == "SET_PARAMETER":
                text = body.decode("utf-8", errors="replace")
                for line in text.splitlines():
                    if line.lower().startswith("volume:"):
                        try:
                            srv.volume_db = float(line.split(":", 1)[1].strip())
                        except ValueError:
                            pass
                self._send_rtsp(200, "OK", cseq)
            elif method == "FLUSH":
                srv.flushed = True
                self._send_rtsp(200, "OK", cseq)
            elif method == "TEARDOWN":
                srv.recording = False
                srv.teardown_called = True
                self._send_rtsp(200, "OK", cseq)
            else:
                self._send_rtsp(501, "Not Implemented", cseq)

    def _send_rtsp(
        self,
        code: int,
        reason: str,
        cseq: str,
        extra_headers: Optional[Dict[str, str]] = None,
    ) -> None:
        lines = [
            f"RTSP/1.0 {code} {reason}",
            f"CSeq: {cseq}",
            "Server: AirTunes/220.68",
        ]
        if extra_headers:
            for k, v in extra_headers.items():
                lines.append(f"{k}: {v}")
        raw = ("\r\n".join(lines) + "\r\n\r\n").encode("utf-8")
        try:
            self.request.sendall(raw)
        except OSError:
            pass


class AirPlayMockServer:
    """Loopback AirPlay (_raop._tcp / _airplay._tcp) RTSP TCP + UDP RTP mock server."""

    def __init__(self) -> None:
        self._host = "127.0.0.1"
        self._rtp_host = _resolve_udp_loopback_host()
        self._rtsp_port = 0
        self._rtp_port = 0
        self._control_port = 0
        self._timing_port = 0
        self._rtsp_srv: Optional[_AirPlayRtspTCPServer] = None
        self._rtsp_thread: Optional[threading.Thread] = None
        self._rtp_sock: Optional[socket.socket] = None
        self._ctrl_sock: Optional[socket.socket] = None
        self._timing_sock: Optional[socket.socket] = None
        self._rtp_thread: Optional[threading.Thread] = None
        self._stop_evt = threading.Event()
        self._lock = threading.Lock()
        self._log: List[Dict[str, Any]] = []
        self.rtp_packets: List[Dict[str, Any]] = []
        self.sdp_text: str = ""
        self.recording: bool = False
        self.flushed: bool = False
        self.teardown_called: bool = False
        self.volume_db: float = -15.0
        self.require_auth_401: bool = False
        self.reject_announce: bool = False
        self.drop_rtp: bool = False

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._rtsp_port

    @property
    def rtsp_port(self) -> int:
        return self._rtsp_port

    @property
    def rtp_host(self) -> str:
        return self._rtp_host

    @property
    def rtp_port(self) -> int:
        return self._rtp_port

    @property
    def control_port(self) -> int:
        return self._control_port

    @property
    def timing_port(self) -> int:
        return self._timing_port

    @property
    def base_url(self) -> str:
        return f"rtsp://{self._host}:{self._rtsp_port}"

    @property
    def requests_log(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._log)

    def _append_log(self, entry: Dict[str, Any]) -> None:
        with self._lock:
            self._log.append(entry)

    def _rtp_loop(self) -> None:
        sock = self._rtp_sock
        if sock is None:
            return
        while not self._stop_evt.is_set():
            try:
                data, _ = sock.recvfrom(8192)
            except socket.timeout:
                continue
            except OSError:
                break
            if self.drop_rtp or len(data) < 12:
                continue
            v_p_x_cc, m_pt, seq, ts, ssrc = struct.unpack("!BBHII", data[:12])
            payload = data[12:]
            pkt_info = {
                "version": (v_p_x_cc >> 6) & 0x03,
                "marker": bool(m_pt & 0x80),
                "payload_type": m_pt & 0x7F,
                "seq": seq,
                "timestamp": ts,
                "ssrc": ssrc,
                "payload_len": len(payload),
                "payload_sha256": hashlib.sha256(payload).hexdigest(),
            }
            with self._lock:
                self.rtp_packets.append(pkt_info)

    def start(self) -> "AirPlayMockServer":
        if self._rtsp_srv is not None:
            return self
        self._stop_evt.clear()
        self._rtp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._ctrl_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._timing_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for s in (self._rtp_sock, self._ctrl_sock, self._timing_sock):
            _disable_udp_connreset(s)
            s.settimeout(0.1)
            s.bind((self._rtp_host, 0))
        self._rtp_port = int(self._rtp_sock.getsockname()[1])
        self._control_port = int(self._ctrl_sock.getsockname()[1])
        self._timing_port = int(self._timing_sock.getsockname()[1])

        self._rtp_thread = threading.Thread(target=self._rtp_loop, daemon=True)
        self._rtp_thread.start()

        self._rtsp_srv = _AirPlayRtspTCPServer(
            (self._host, 0), _AirPlayRtspHandler, self
        )
        self._rtsp_port = int(self._rtsp_srv.server_address[1])
        self._rtsp_thread = threading.Thread(
            target=self._rtsp_srv.serve_forever,
            kwargs={"poll_interval": 0.05},
            daemon=True,
        )
        self._rtsp_thread.start()
        wait_for_tcp(self._host, self._rtsp_port, timeout_s=3.0)
        return self

    def stop(self) -> None:
        self._stop_evt.set()
        if self._rtsp_srv is not None:
            try:
                self._rtsp_srv.shutdown()
                self._rtsp_srv.server_close()
            finally:
                self._rtsp_srv = None
        if self._rtsp_thread is not None:
            self._rtsp_thread.join(timeout=2.0)
            self._rtsp_thread = None
        for s in (self._rtp_sock, self._ctrl_sock, self._timing_sock):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
        self._rtp_sock = None
        self._ctrl_sock = None
        self._timing_sock = None
        if self._rtp_thread is not None:
            self._rtp_thread.join(timeout=2.0)
            self._rtp_thread = None
        self._rtsp_port = 0

    def reset(self) -> None:
        with self._lock:
            self._log.clear()
            self.rtp_packets.clear()
        self.sdp_text = ""
        self.recording = False
        self.flushed = False
        self.teardown_called = False
        self.volume_db = -15.0
        self.require_auth_401 = False
        self.reject_announce = False
        self.drop_rtp = False

    def __enter__(self) -> "AirPlayMockServer":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()


# ---------------------------------------------------------------------------
# 8. ClockSyncMockServer & MdnsLoopbackMock
# ---------------------------------------------------------------------------

_NTP_EPOCH_DELTA = 2208988800


class ClockSyncMockServer:
    """UDP SNTPv4 & JSON 4-timestamp clock sync mock with configurable offset & drift ppm."""

    def __init__(
        self,
        simulated_offset_us: int = 0,
        drift_ppm: float = 0.0,
        processing_delay_us: int = 50,
    ) -> None:
        self._host = _resolve_udp_loopback_host()
        self._port = 0
        self.simulated_offset_us = simulated_offset_us
        self.drift_ppm = drift_ppm
        self.processing_delay_us = processing_delay_us
        self.drop_every_n: int = 0
        self._pkt_count: int = 0
        self._started_mono: float = time.monotonic()
        self._sock: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop_evt = threading.Event()
        self._lock = threading.Lock()
        self._log: List[Dict[str, Any]] = []

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._port

    @property
    def base_url(self) -> str:
        return f"udp://{self._host}:{self._port}"

    @property
    def requests_log(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._log)

    def server_now_us(self) -> int:
        elapsed = time.monotonic() - self._started_mono
        drift_us = int(elapsed * self.drift_ppm)
        return int(time.time() * 1_000_000) + self.simulated_offset_us + drift_us

    @staticmethod
    def us_to_ntp_ts(unix_us: int) -> Tuple[int, int]:
        sec = (unix_us // 1_000_000) + _NTP_EPOCH_DELTA
        rem_us = unix_us % 1_000_000
        frac = int((rem_us * (1 << 32)) / 1_000_000)
        return sec & 0xFFFFFFFF, frac & 0xFFFFFFFF

    @staticmethod
    def ntp_ts_to_us(sec: int, frac: int) -> int:
        unix_sec = sec - _NTP_EPOCH_DELTA
        rem_us = int((frac * 1_000_000) / (1 << 32))
        return unix_sec * 1_000_000 + rem_us

    def _loop(self) -> None:
        sock = self._sock
        if sock is None:
            return
        while not self._stop_evt.is_set():
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break

            t2_us = self.server_now_us()
            self._pkt_count += 1
            with self._lock:
                self._log.append(
                    {
                        "timestamp": time.time(),
                        "method": "UDP_CLOCK",
                        "path": "/",
                        "query": {},
                        "headers": {},
                        "body": data,
                    }
                )
            if self.drop_every_n > 0 and (self._pkt_count % self.drop_every_n) == 0:
                continue

            if len(data) == 48 and (data[0] & 0x07) == 3:
                # RFC 4330 SNTPv4 client request (Mode 3) -> Server response (Mode 4)
                t3_us = t2_us + self.processing_delay_us
                resp = bytearray(48)
                resp[0] = 0x24  # LI=0, VN=4, Mode=4
                resp[1] = 1     # Stratum 1
                resp[2] = data[2]
                resp[3] = 0xEC  # precision (-20)
                resp[12:16] = b"LUMN"
                resp[24:32] = data[40:48]  # Originate Timestamp = client Transmit
                t2_sec, t2_frac = self.us_to_ntp_ts(t2_us)
                t3_sec, t3_frac = self.us_to_ntp_ts(t3_us)
                struct.pack_into("!II", resp, 32, t2_sec, t2_frac)
                struct.pack_into("!II", resp, 40, t3_sec, t3_frac)
                try:
                    sock.sendto(bytes(resp), addr)
                except OSError:
                    pass
                continue

            try:
                req = json.loads(data.decode("utf-8"))
                t3_us = t2_us + self.processing_delay_us
                resp_json = json.dumps(
                    {
                        "t1_us": req.get("t1_us", 0),
                        "t2_us": t2_us,
                        "t3_us": t3_us,
                    }
                ).encode("utf-8")
                sock.sendto(resp_json, addr)
            except Exception:
                pass

    def start(self) -> "ClockSyncMockServer":
        if self._sock is not None:
            return self
        self._stop_evt.clear()
        self._started_mono = time.monotonic()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        _disable_udp_connreset(self._sock)
        self._sock.settimeout(0.1)
        self._sock.bind((self._host, 0))
        self._port = int(self._sock.getsockname()[1])
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop_evt.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        self._port = 0

    def reset(self) -> None:
        with self._lock:
            self._log.clear()
        self._pkt_count = 0
        self._started_mono = time.monotonic()
        self.drop_every_n = 0

    def __enter__(self) -> "ClockSyncMockServer":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()


class MdnsLoopbackMock:
    """RFC 6762/6763 _lumina._tcp.local. mDNS loopback responder and DNS-SD wire codec."""

    def __init__(
        self,
        hostname: str = "Lumina-Desktop",
        service_type: str = "_lumina._tcp.local.",
        service_port: int = 9888,
        ipv4: str = "127.0.0.1",
        txt_records: Optional[Dict[str, str]] = None,
    ) -> None:
        self._host = _resolve_udp_loopback_host()
        self._port = 0
        self.hostname = hostname
        self.service_type = service_type
        self.service_port = service_port
        self.ipv4 = ipv4
        self.txt_records: Dict[str, str] = txt_records or {
            "server_name": hostname,
            "version": "0.1.0",
            "api_version": "1",
            "pairing_required": "true",
        }
        self._sock: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop_evt = threading.Event()
        self._lock = threading.Lock()
        self._log: List[Dict[str, Any]] = []

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._port

    @property
    def base_url(self) -> str:
        return f"udp://{self._host}:{self._port}"

    @property
    def requests_log(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._log)

    @staticmethod
    def encode_dns_name(name: str) -> bytes:
        out = bytearray()
        for label in name.strip(".").split("."):
            if not label:
                continue
            raw = label.encode("utf-8")
            out.append(len(raw))
            out.extend(raw)
        out.append(0)
        return bytes(out)

    @staticmethod
    def decode_dns_name(pkt: bytes, offset: int) -> Tuple[str, int]:
        labels: List[str] = []
        jumped = False
        orig_next = offset
        seen_offsets: Set[int] = set()
        pos = offset
        while pos < len(pkt):
            if pos in seen_offsets:
                raise ValueError("DNS compression pointer loop")
            seen_offsets.add(pos)
            length = pkt[pos]
            if length == 0:
                if not jumped:
                    orig_next = pos + 1
                break
            if (length & 0xC0) == 0xC0:
                if pos + 1 >= len(pkt):
                    raise ValueError("Truncated DNS pointer")
                ptr = ((length & 0x3F) << 8) | pkt[pos + 1]
                if not jumped:
                    orig_next = pos + 2
                jumped = True
                pos = ptr
                continue
            pos += 1
            labels.append(pkt[pos : pos + length].decode("utf-8", errors="replace"))
            pos += length
        return ".".join(labels) + ".", orig_next

    @classmethod
    def build_ptr_query(cls, service_type: str = "_lumina._tcp.local.") -> bytes:
        pkt = bytearray(struct.pack("!HHHHHH", 0x0000, 0x0000, 1, 0, 0, 0))
        pkt.extend(cls.encode_dns_name(service_type))
        pkt.extend(struct.pack("!HH", 12, 0x0001))  # PTR, IN
        return bytes(pkt)

    @classmethod
    def build_announcement_packet(
        cls,
        hostname: str = "Lumina-Desktop",
        service_type: str = "_lumina._tcp.local.",
        port: int = 9888,
        ipv4: str = "127.0.0.1",
        txt_records: Optional[Dict[str, str]] = None,
    ) -> bytes:
        txt = txt_records or {
            "api_version": "1",
            "pairing_required": "true",
            "server_name": hostname,
            "version": "0.1.0",
        }
        instance_name = f"{hostname}.{service_type.strip('.')}."
        host_fqdn = f"{hostname}.local."
        ttl = 120

        pkt = bytearray(struct.pack("!HHHHHH", 0x0000, 0x8400, 0, 4, 0, 0))

        # 1. PTR
        ptr_rdata = cls.encode_dns_name(instance_name)
        pkt.extend(cls.encode_dns_name(service_type))
        pkt.extend(struct.pack("!HHIH", 12, 0x0001, ttl, len(ptr_rdata)))
        pkt.extend(ptr_rdata)

        # 2. SRV
        srv_rdata = struct.pack("!HHH", 0, 0, port) + cls.encode_dns_name(host_fqdn)
        pkt.extend(cls.encode_dns_name(instance_name))
        pkt.extend(struct.pack("!HHIH", 33, 0x8001, ttl, len(srv_rdata)))
        pkt.extend(srv_rdata)

        # 3. TXT
        txt_rdata = bytearray()
        for k in sorted(txt.keys()):
            entry = f"{k}={txt[k]}".encode("utf-8")
            txt_rdata.append(len(entry))
            txt_rdata.extend(entry)
        pkt.extend(cls.encode_dns_name(instance_name))
        pkt.extend(struct.pack("!HHIH", 16, 0x8001, ttl, len(txt_rdata)))
        pkt.extend(txt_rdata)

        # 4. A
        ip_bytes = socket.inet_aton(ipv4)
        pkt.extend(cls.encode_dns_name(host_fqdn))
        pkt.extend(struct.pack("!HHIH", 1, 0x8001, ttl, 4))
        pkt.extend(ip_bytes)

        return bytes(pkt)

    @classmethod
    def parse_dns_sd_packet(cls, pkt: bytes) -> Dict[str, Any]:
        if len(pkt) < 12:
            raise ValueError("Packet shorter than 12-byte DNS header")
        tx_id, flags, qdcount, ancount, nscount, arcount = struct.unpack(
            "!HHHHHH", pkt[:12]
        )
        pos = 12
        questions = []
        for _ in range(qdcount):
            qname, pos = cls.decode_dns_name(pkt, pos)
            qtype, qclass = struct.unpack("!HH", pkt[pos : pos + 4])
            pos += 4
            questions.append({"name": qname, "type": qtype, "class": qclass})

        records = []
        parsed: Dict[str, Any] = {
            "header": {
                "id": tx_id,
                "flags": flags,
                "qdcount": qdcount,
                "ancount": ancount,
                "nscount": nscount,
                "arcount": arcount,
            },
            "questions": questions,
            "records": records,
            "ptr": None,
            "srv": None,
            "txt": {},
            "a": None,
        }

        total_rr = ancount + nscount + arcount
        for _ in range(total_rr):
            name, pos = cls.decode_dns_name(pkt, pos)
            rtype, rclass, ttl, rdlen = struct.unpack("!HHIH", pkt[pos : pos + 10])
            pos += 10
            rdata_start = pos
            rdata = pkt[pos : pos + rdlen]
            pos += rdlen

            rec: Dict[str, Any] = {
                "name": name,
                "type": rtype,
                "class": rclass,
                "ttl": ttl,
            }
            if rtype == 12:  # PTR
                target, _ = cls.decode_dns_name(pkt, rdata_start)
                rec["target"] = target
                parsed["ptr"] = target
            elif rtype == 33:  # SRV
                prio, weight, srv_port = struct.unpack("!HHH", rdata[:6])
                target, _ = cls.decode_dns_name(pkt, rdata_start + 6)
                srv_info = {
                    "priority": prio,
                    "weight": weight,
                    "port": srv_port,
                    "target": target,
                }
                rec.update(srv_info)
                parsed["srv"] = srv_info
            elif rtype == 16:  # TXT
                txt_map: Dict[str, str] = {}
                tpos = 0
                while tpos < len(rdata):
                    slen = rdata[tpos]
                    tpos += 1
                    item = rdata[tpos : tpos + slen].decode("utf-8", errors="replace")
                    tpos += slen
                    if "=" in item:
                        k, v = item.split("=", 1)
                        txt_map[k] = v
                rec["txt"] = txt_map
                parsed["txt"] = txt_map
            elif rtype == 1 and len(rdata) == 4:  # A
                ip_str = socket.inet_ntoa(rdata)
                rec["ipv4"] = ip_str
                parsed["a"] = ip_str
            records.append(rec)

        return parsed

    def _loop(self) -> None:
        sock = self._sock
        if sock is None:
            return
        while not self._stop_evt.is_set():
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            with self._lock:
                self._log.append(
                    {
                        "timestamp": time.time(),
                        "method": "MDNS_QUERY",
                        "path": self.service_type,
                        "query": {},
                        "headers": {},
                        "body": data,
                    }
                )
            if b"_lumina" in data.lower():
                pkt = self.build_announcement_packet(
                    hostname=self.hostname,
                    service_type=self.service_type,
                    port=self.service_port,
                    ipv4=self.ipv4,
                    txt_records=self.txt_records,
                )
                try:
                    sock.sendto(pkt, addr)
                except OSError:
                    pass

    def start(self) -> "MdnsLoopbackMock":
        if self._sock is not None:
            return self
        self._stop_evt.clear()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        _disable_udp_connreset(self._sock)
        self._sock.settimeout(0.1)
        self._sock.bind((self._host, 0))
        self._port = int(self._sock.getsockname()[1])
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop_evt.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        self._port = 0

    def reset(self) -> None:
        with self._lock:
            self._log.clear()

    def __enter__(self) -> "MdnsLoopbackMock":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()
