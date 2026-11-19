"""
OS Keyring credential storage fixtures and secret isolation models.
Provides simulated OS Keyring store with failure mode, fallback session vault,
token redaction, and Qobuz authentication mode validation.
"""
from typing import Dict, Any, Optional, Tuple


def validate_keyring_keys(service: str, account: str) -> None:
    """Verifies that service name and account identifier are non-empty and non-whitespace strings."""
    if not service or not service.strip():
        raise ValueError("Keyring service name cannot be empty")
    if not account or not account.strip():
        raise ValueError("Keyring account name cannot be empty")


def redact_token(tok: str) -> str:
    """Redacts sensitive token for safe logging, preserving prefix and suffix."""
    if not tok:
        return ""
    if len(tok) <= 4:
        return "*" * len(tok)
    if len(tok) <= 8:
        return tok[:2] + "****" + tok[-2:]
    return tok[:4] + "*" * (len(tok) - 8) + tok[-4:]


def redact_auth_token(token: str) -> str:
    """Alias for redact_token."""
    return redact_token(token)


def check_token_characters(tok: str) -> bool:
    """Verifies auth token contains only printable ASCII characters without whitespace."""
    for ch in tok:
        code = ord(ch)
        if code < 33 or code > 126:
            return False
    return True


def validate_token_mode(token: str) -> str:
    """Validates that token string is non-empty and non-whitespace."""
    if not token or not token.strip():
        raise ValueError("user_auth_token cannot be empty")
    return token.strip()


def parse_auth_mode_json(payload: Dict[str, Any]) -> str:
    """Extracts and validates 'mode' tag from JSON payload ('token' or 'credentials')."""
    mode = payload.get("mode")
    if not mode:
        raise ValueError("Missing 'mode' discriminator tag")
    if mode not in ("token", "credentials"):
        raise ValueError(f"Unknown auth mode: {mode}")
    return mode


def validate_credentials(user: str, pwd: str) -> None:
    """Validates username and password are not empty or blank."""
    if not user or not user.strip():
        raise ValueError("Username cannot be empty")
    if not pwd or not pwd.strip():
        raise ValueError("Password cannot be empty")


class MockKeyringService:
    """In-memory reference model of OS Keyring credential storage with failure simulation."""

    def __init__(self, fail_mode: bool = False):
        self.fail_mode: bool = fail_mode
        self._vault: Dict[Tuple[str, str], str] = {}

    def set_password(self, service: str, account: str, secret: str) -> None:
        if self.fail_mode:
            raise OSError("OS Keyring daemon unavailable (service disabled)")
        validate_keyring_keys(service, account)
        self._vault[(service, account)] = secret

    def get_password(self, service: str, account: str) -> Optional[str]:
        if self.fail_mode:
            raise OSError("OS Keyring daemon unavailable (service disabled)")
        return self._vault.get((service, account))

    def delete_password(self, service: str, account: str) -> bool:
        if self.fail_mode:
            raise OSError("OS Keyring daemon unavailable (service disabled)")
        return self._vault.pop((service, account), None) is not None

    def set_secret(self, service: str, account: str, secret: str) -> None:
        self.set_password(service, account, secret)

    def get_secret(self, service: str, account: str) -> Optional[str]:
        return self.get_password(service, account)

    def delete_secret(self, service: str, account: str) -> bool:
        return self.delete_password(service, account)


class SimulatedKeyringStore(MockKeyringService):
    """SimulatedKeyringStore alias for MockKeyringService."""
    pass


class KeyringStore(MockKeyringService):
    """KeyringStore alias for MockKeyringService."""
    pass


class FallbackSessionVault:
    """In-memory ephemeral fallback session vault when OS Keyring is unavailable."""

    def __init__(self):
        self._store: Dict[str, str] = {}

    def store(self, key: str, value: str) -> None:
        self._store[key] = value

    def get(self, key: str) -> Optional[str]:
        return self._store.get(key)

    def has(self, key: str) -> bool:
        return key in self._store

    def delete(self, key: str) -> bool:
        return self._store.pop(key, None) is not None
