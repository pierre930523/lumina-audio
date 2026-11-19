"""
Axum HTTP & WebSocket Server, Mutual PIN Pairing, and mDNS Service Discovery Fixtures.
Provides full reference models for PIN pairing session lifecycle, brute-force rate limiting,
Bearer token authentication, mDNS service announcements, and WebSocket broadcast mailboxes.
"""
import hashlib
import ipaddress
import json
import re
import secrets
import time
from typing import Dict, Any, List, Optional, Tuple, Set, Union
from urllib.parse import urlparse, parse_qs


def generate_six_digit_pin() -> str:
    """Generates random 6-digit numeric PIN matching regex ^[0-9]{6}$."""
    return f"{secrets.randbelow(1000000):06d}"


def generate_pin() -> str:
    """Alias for generate_six_digit_pin."""
    return generate_six_digit_pin()


def validate_pin_format(pin_str: str) -> bool:
    """Validates that PIN string consists of exactly 6 numeric digits."""
    if not isinstance(pin_str, str):
        return False
    return bool(re.match(r"^[0-9]{6}$", pin_str.strip()))


def validate_pin(pin_str: str) -> bool:
    """Alias for validate_pin_format."""
    return validate_pin_format(pin_str)


def generate_qr_pairing_uri(pin: str, host: str, port: int, nonce: Optional[str] = None) -> str:
    """Generates standard pairing URI for QR code presentation."""
    if nonce is not None:
        return f"lumina-pair://pair?server={host}%3A{port}&pin={pin}&nonce={nonce}"
    return f"lumina://pair?pin={pin}&host={host}&port={port}"


def format_qr_pairing_uri(pin: str, host: str, port: int) -> str:
    """Alias for generate_qr_pairing_uri without nonce."""
    return generate_qr_pairing_uri(pin, host, port)


def generate_qr_payload(pin: str, host: str, port: int) -> str:
    """Alias for generate_qr_pairing_uri without nonce."""
    return generate_qr_pairing_uri(pin, host, port)


def validate_qr_pairing_uri(uri: str) -> bool:
    """Validates QR pairing URI scheme and mandatory query parameters."""
    parsed = urlparse(uri)
    if parsed.scheme == "lumina-pair":
        params = parse_qs(parsed.query)
        for req in ("pin", "nonce", "server"):
            if req not in params:
                return False
        return True
    elif parsed.scheme == "lumina":
        params = parse_qs(parsed.query)
        for req in ("pin", "host", "port"):
            if req not in params:
                return False
        return True
    return False


def is_pairing_pin_valid(created_at: float, now: float, ttl_sec: float = 60.0) -> bool:
    """Verifies pairing PIN has not expired based on TTL."""
    return (now - created_at) <= ttl_sec


def is_pin_valid(created_at: float, now: float, ttl_sec: float = 60.0) -> bool:
    """Alias for is_pairing_pin_valid."""
    return is_pairing_pin_valid(created_at, now, ttl_sec)


def consume_pin(pin: str, active_pins: Optional[Dict[str, Any]] = None) -> bool:
    """Consumes an active PIN, returning True if present, False on replay."""
    if active_pins is None:
        return False
    if pin in active_pins:
        del active_pins[pin]
        return True
    return False


class PinRateLimiter:
    """Brute-force protection: locks client after consecutive failed attempts."""

    def __init__(self, max_failures: int = 5):
        self.failures: int = 0
        self.max_failures: int = max_failures
        self.locked: bool = False

    def record_failure(self) -> None:
        self.failures += 1
        if self.failures >= self.max_failures:
            self.locked = True

    def reset(self) -> None:
        self.failures = 0
        self.locked = False


class MutualPinSessionManager:
    """Manages 6-digit mutual pairing PINs, TTL expiration, one-time replay prevention, and rate-limiting."""

    def __init__(self, ttl_sec: float = 60.0, max_failures: int = 5):
        self.ttl_sec = ttl_sec
        self.max_failures = max_failures
        self.active_pins: Dict[str, Tuple[float, str]] = {}  # pin -> (created_at, device_name)
        self.failure_counts: Dict[str, int] = {}
        self.locked_ips: Set[str] = set()
        self.active_sessions: Dict[str, str] = {}  # token_hash -> client_id

    def generate_pin(self, device_name: str = "device") -> str:
        """Generates random 6-digit PIN and records creation timestamp."""
        pin = generate_six_digit_pin()
        self.active_pins[pin] = (time.time(), device_name)
        return pin

    def is_pin_valid(self, pin: str, now: Optional[float] = None) -> bool:
        """Checks if PIN exists and has not expired."""
        if pin not in self.active_pins:
            return False
        now = now if now is not None else time.time()
        created_at, _ = self.active_pins[pin]
        return (now - created_at) <= self.ttl_sec

    def consume_pin(self, pin: str) -> bool:
        """Consumes PIN once; subsequent calls return False (replay prevention)."""
        if pin in self.active_pins:
            del self.active_pins[pin]
            return True
        return False

    def attempt_pairing(
        self, client_ip: str, client_id: str, pin: str, now: Optional[float] = None
    ) -> Tuple[bool, Optional[str], str]:
        """Attempts to pair a remote client, enforcing lockout, format, and TTL."""
        now = now if now is not None else time.time()
        if client_ip in self.locked_ips:
            return False, None, "IP_LOCKED"
        if not validate_pin_format(pin):
            return self._record_failure(client_ip, "INVALID_PIN_FORMAT")
        if pin not in self.active_pins:
            return self._record_failure(client_ip, "PIN_NOT_FOUND")

        created_at, dev_name = self.active_pins[pin]
        del self.active_pins[pin]  # Consume immediately to prevent replay

        if (now - created_at) > self.ttl_sec:
            return False, None, "PIN_EXPIRED"

        # Issue bearer token
        token = f"lum_sec_{secrets.token_hex(24)}"
        token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        self.active_sessions[token_hash] = client_id
        return True, token, "SUCCESS"

    def consume_pin_and_issue_token(
        self, pin: str, client_id: str = "client", now: Optional[float] = None
    ) -> str:
        """Consumes a valid PIN and returns a generated Bearer token."""
        now = now if now is not None else time.time()
        if not self.is_pin_valid(pin, now):
            raise ValueError("Invalid or expired PIN")
        del self.active_pins[pin]
        token = f"lum_sec_{secrets.token_hex(24)}"
        token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        self.active_sessions[token_hash] = client_id
        return token

    def _record_failure(self, client_ip: str, reason: str) -> Tuple[bool, Optional[str], str]:
        self.failure_counts[client_ip] = self.failure_counts.get(client_ip, 0) + 1
        if self.failure_counts[client_ip] >= self.max_failures:
            self.locked_ips.add(client_ip)
            return False, None, "MAX_ATTEMPTS_EXCEEDED"
        return False, None, reason


class PinPairingManager(MutualPinSessionManager):
    """PinPairingManager providing parity with MutualPinSessionManager."""
    pass


def validate_bind_address(addr: str) -> Tuple[str, int]:
    """Validates host IP and port bounds (0..65535)."""
    host, port_str = addr.rsplit(":", 1)
    port = int(port_str)
    if port < 0 or port > 65535:
        raise ValueError("Port out of bounds")
    ipaddress.ip_address(host)
    return host, port


def extract_bearer(header_val: str) -> Optional[str]:
    """Extracts bearer token from Authorization header value."""
    if not header_val or not header_val.startswith("Bearer "):
        return None
    token = header_val[7:].strip()
    return token if token else None


def authenticate_request(
    headers_or_str: Union[Dict[str, str], str],
    paired_tokens: Optional[Union[Set[str], List[str]]] = None,
) -> Union[int, bool]:
    """
    Authenticates HTTP Authorization Bearer token.
    - If headers dict is passed, returns HTTP status 200 or 401.
    - If auth_header string is passed, returns boolean True or False.
    """
    tokens_set = set(paired_tokens) if paired_tokens else set()
    if isinstance(headers_or_str, dict):
        auth = headers_or_str.get("Authorization")
        token = extract_bearer(auth) if auth else None
        if not token or token not in tokens_set:
            return 401
        return 200
    elif isinstance(headers_or_str, str):
        token = extract_bearer(headers_or_str)
        if not token:
            return False
        return token in tokens_set
    return 401


def authenticate_bearer_token(auth_header: str, valid_tokens: List[str]) -> bool:
    """Verifies that auth_header begins with Bearer and token is in valid_tokens."""
    return bool(authenticate_request(auth_header, valid_tokens))


def process_ws_frame(frame_text: str) -> Dict[str, Any]:
    """Processes WebSocket text frame, decoding JSON or returning error dictionary."""
    try:
        data = json.loads(frame_text)
        return {"status": "ok", "payload": data}
    except json.JSONDecodeError:
        return {"status": "error", "error": "Invalid JSON text frame"}


def check_body_size(size_bytes: int, limit: int = 10 * 1024 * 1024) -> int:
    """Returns 413 if body exceeds limit (default 10MB), otherwise 200."""
    return 413 if size_bytes > limit else 200


def check_payload_size(size_bytes: int, limit: int = 10 * 1024 * 1024) -> int:
    """Alias for check_body_size."""
    return check_body_size(size_bytes, limit)


class MockAxumServer:
    """Mock server managing host, port, active paired clients, bearer tokens, and WebSocket events."""

    def __init__(self, host: str = "0.0.0.0", port: int = 9888):
        self.host = host
        self.port = port
        self.paired_tokens: Set[str] = set()
        self.client_mailboxes: Dict[str, List[Any]] = {}

    def register_paired_token(self, token: str) -> None:
        self.paired_tokens.add(token)

    def register_client(self, client_id: str) -> None:
        if client_id not in self.client_mailboxes:
            self.client_mailboxes[client_id] = []

    def authenticate_bearer(self, auth_header: str) -> bool:
        return bool(authenticate_request(auth_header, self.paired_tokens))

    def broadcast_event(self, event: Dict[str, Any]) -> None:
        for mailbox in self.client_mailboxes.values():
            mailbox.append(event)

    def get_client_mailbox(self, client_id: str) -> List[Any]:
        if client_id not in self.client_mailboxes:
            self.client_mailboxes[client_id] = []
        return self.client_mailboxes[client_id]


def validate_service_type(st: str) -> bool:
    """Verifies that mDNS service type strictly matches RFC 6763: '_lumina._tcp.local.'."""
    return st.strip() == "_lumina._tcp.local."


def validate_txt_entry(key: str, val: str) -> bool:
    """Verifies TXT record key length <= 9 bytes and value <= 255 bytes."""
    if len(key.encode("utf-8")) > 9:
        return False
    if len(val.encode("utf-8")) > 255:
        return False
    return True


def resolve_name_collision(name: str, existing_names: Set[str]) -> str:
    """Resolves mDNS service name collision by appending incrementing integer ' (2)'."""
    if name not in existing_names:
        return name
    counter = 2
    while True:
        candidate = f"{name} ({counter})"
        if candidate not in existing_names:
            return candidate
        counter += 1


def resolve_mdns_name_collision(name: str, existing_names: Set[str]) -> str:
    """Alias for resolve_name_collision."""
    return resolve_name_collision(name, existing_names)


def generate_mdns_announcement(server_name: str, port: int, version: str = "0.1.0") -> Dict[str, Any]:
    """Generates standard mDNS announcement record dictionary."""
    return {
        "service_type": "_lumina._tcp.local.",
        "port": port,
        "txt_record": {
            "server_name": server_name,
            "version": version,
            "api_version": "1",
            "pairing_required": "true",
        },
    }
