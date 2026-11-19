"""
Toolchain discovery, execution, verification, and quota monitoring fixtures.
Provides genuine discovery for Cargo and Flutter, toolchain command execution,
CLI flag validation, diagnostic parsing, and QuotaTracker state machines.
"""
import json
import math
import os
import re
import shutil
import subprocess
import sys
from typing import Dict, Any, List, Optional, Tuple

SUPPORTED_ARCHS = {"x86_64", "aarch64", "i686", "armv7"}
VALID_EDITIONS = {"2015", "2018", "2021", "2024"}
ALLOWED_CRATE_TYPES = {"bin", "lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"}


def find_cargo_executable() -> str:
    """Discovers cargo executable on system PATH or standard installation locations."""
    found = shutil.which("cargo") or shutil.which("cargo.exe")
    if found and os.path.isfile(found):
        return found
    candidates = [
        os.path.join(os.path.expanduser("~"), ".cargo", "bin", "cargo.exe"),
        os.path.join(os.environ.get("USERPROFILE", ""), ".cargo", "bin", "cargo.exe"),
        os.path.join(os.environ.get("CARGO_HOME", ""), "bin", "cargo.exe"),
    ]
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    raise FileNotFoundError("Cargo executable not found on PATH or in ~/.cargo/bin/cargo.exe")


def find_flutter_executable() -> str:
    """Discovers flutter executable on system PATH or standard installation locations."""
    found = shutil.which("flutter") or shutil.which("flutter.bat")
    if found and os.path.isfile(found):
        return found
    candidates = [
        os.path.join(os.path.expanduser("~"), "flutter", "bin", "flutter.bat"),
        os.path.join(os.path.expanduser("~"), "flutter", "bin", "flutter"),
        r"C:\flutter\bin\flutter.bat",
        r"C:\src\flutter\bin\flutter.bat",
        os.path.join(os.environ.get("FLUTTER_ROOT", ""), "bin", "flutter.bat"),
    ]
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    raise FileNotFoundError("Flutter executable not found on PATH or in ~/flutter/bin/flutter.bat")


def run_toolchain_command(
    cmd: List[str],
    cwd: Optional[str] = None,
    timeout: float = 60.0,
) -> subprocess.CompletedProcess:
    """Executes a toolchain subprocess command, capturing output with timeout and text decoding."""
    return subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def validate_cargo_flags(flags: List[str]) -> bool:
    """Verifies CLI flag validation detects mutually conflicting options (--release and --debug) and empty lists."""
    if not flags:
        raise ValueError("Flag list cannot be empty")
    if "--release" in flags and "--debug" in flags:
        raise ValueError("Conflicting flags: cannot specify both --release and --debug")
    return True


def parse_doctor_issues(text: str) -> Dict[str, int]:
    """Parses flutter doctor output text and counts passes [✓], warnings [!], and failures [✗]."""
    passes = len(re.findall(r"\[[✓v]\]", text))
    warnings = len(re.findall(r"\[!\]", text))
    failures = len(re.findall(r"\[[✗x]\]", text))
    return {"pass": passes, "warn": warnings, "fail": failures}


def parse_flutter_doctor(text: str) -> Dict[str, int]:
    """Alias for parse_doctor_issues."""
    return parse_doctor_issues(text)


def count_analysis_errors(json_str: str) -> int:
    """Parses flutter analyze diagnostics JSON and counts diagnostics with severity == 'ERROR'."""
    data = json.loads(json_str)
    diagnostics = data.get("diagnostics", [])
    return sum(1 for d in diagnostics if d.get("severity") == "ERROR")


def parse_analyzer_diagnostics(json_str: str) -> int:
    """Alias for count_analysis_errors."""
    return count_analysis_errors(json_str)


def validate_rust_edition(edition: Any) -> bool:
    """Verifies Rust edition is a valid string in {'2015', '2018', '2021', '2024'}."""
    if not isinstance(edition, str):
        return False
    return edition in VALID_EDITIONS


def validate_edition(edition: Any) -> bool:
    """Alias for validate_rust_edition."""
    return validate_rust_edition(edition)


def parse_target_triple(triple: str) -> Tuple[str, str, str, Optional[str]]:
    """Parses target architecture triple (e.g. x86_64-pc-windows-msvc) into arch, vendor, os, abi."""
    if not triple or not isinstance(triple, str):
        raise ValueError("Triple must be a non-empty string")
    parts = triple.strip().split("-")
    if len(parts) < 3 or len(parts) > 4:
        raise ValueError(f"Invalid target triple format: {triple}")
    arch, vendor, sys_part = parts[0], parts[1], parts[2]
    abi = parts[3] if len(parts) == 4 else None
    if arch not in SUPPORTED_ARCHS:
        raise ValueError(f"Unsupported architecture: {arch}")
    return arch, vendor, sys_part, abi


def validate_crate_types(types_list: List[str]) -> bool:
    """Verifies that all entries in types_list are valid Cargo crate types."""
    if not types_list:
        return False
    for t in types_list:
        if t not in ALLOWED_CRATE_TYPES:
            return False
    return True


def is_supported_audio_api_level(level: Any) -> bool:
    """Verifies Android platform API boundary checks: min API 24 (AAudio/Oboe), max API 40."""
    if not isinstance(level, int):
        return False
    if level < 24:
        return False
    if level > 40:
        return False
    return True


def parse_source_properties(text: str) -> Dict[str, str]:
    """Parses Android SDK source.properties file into key-value dictionary, ignoring comments."""
    props = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, val = line.split("=", 1)
            props[key.strip()] = val.strip()
    return props


def validate_java_home(path_str: Optional[str]) -> bool:
    """Validates that JAVA_HOME path exists and points to an actual directory."""
    if not path_str or not isinstance(path_str, str):
        return False
    clean = path_str.strip()
    if not clean or not os.path.exists(clean):
        return False
    return os.path.isdir(clean)


def parse_ndk_version(version_str: str) -> Tuple[int, int, int]:
    """Parses NDK semver string (e.g. '25.1.8937393') into (major, minor, build)."""
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", version_str.strip())
    if not m:
        raise ValueError(f"Malformed NDK version: {version_str}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


class QuotaTracker:
    """Tracks LLM / Antigravity quota consumption and latches handoff trigger when threshold crossed."""

    def __init__(self, initial_pct: float = 100.0, threshold_percent: float = 15.0):
        self.current_percent: float = initial_pct
        self.threshold_percent: float = threshold_percent
        self.handoff_active: bool = False
        if initial_pct <= threshold_percent:
            self.handoff_active = True

    def update(self, remaining: float) -> bool:
        """Updates remaining quota percentage. Latches handoff_active to True once below threshold."""
        if remaining < 0.0 or remaining > 100.0:
            raise ValueError(f"Quota percentage out of bounds: {remaining}")
        self.current_percent = remaining
        if remaining <= self.threshold_percent:
            self.handoff_active = True
        return self.handoff_active

    def record_reading(self, remaining_percent: float) -> bool:
        """Alias for update."""
        return self.update(remaining_percent)

    def is_depleted(self) -> bool:
        """Returns True if handoff state is active."""
        return self.handoff_active


def should_trigger_handoff(remaining_percentage: float, threshold_percentage: float = 15.0) -> bool:
    """Evaluates whether remaining quota percentage should trigger handoff (< threshold)."""
    if not isinstance(remaining_percentage, (int, float)):
        raise TypeError("Quota must be numeric")
    if remaining_percentage < 0.0 or remaining_percentage > 100.0:
        raise ValueError("Quota percentage must be between 0.0 and 100.0")
    return remaining_percentage <= threshold_percentage


def evaluate_quota_handoff_threshold(remaining_percentage: float, threshold_percentage: float = 15.0) -> bool:
    """Alias for should_trigger_handoff."""
    return should_trigger_handoff(remaining_percentage, threshold_percentage)


def validate_quota(val: Any) -> float:
    """Validates numeric quota value, rejecting negatives, > 100, NaN, inf, or non-numeric types."""
    if not isinstance(val, (int, float)) or math.isnan(val) or math.isinf(val):
        raise ValueError(f"Invalid quota value: {val}")
    if val < 0.0 or val > 100.0:
        raise ValueError(f"Quota out of bounds: {val}")
    return float(val)


def validate_quota_value(val: Any) -> float:
    """Alias for validate_quota."""
    return validate_quota(val)


def parse_quota_output(raw: str) -> Optional[float]:
    """Parses JSON stdout from quota inspection script, returning remaining_percentage or None."""
    if not raw or not raw.strip():
        return None
    try:
        data = json.loads(raw)
        return float(data.get("remaining_percentage"))
    except (json.JSONDecodeError, TypeError, KeyError):
        return None


def validate_progress_doc(md_text: str, required_headers: Optional[List[str]] = None) -> List[str]:
    """Enforces mandatory sections in PROGRESS.md ('Completed Modules', 'In-Progress Changes', 'Prioritized Next Steps')."""
    if required_headers is None:
        required_headers = [
            "Completed Modules",
            "In-Progress Changes",
            "Prioritized Next Steps",
        ]
    missing = []
    for h in required_headers:
        if not re.search(rf"##\s+.*{re.escape(h)}", md_text, re.IGNORECASE):
            missing.append(h)
    return missing


def validate_progress_document(md_text: str, required_headers: Optional[List[str]] = None) -> List[str]:
    """Alias for validate_progress_doc."""
    return validate_progress_doc(md_text, required_headers)
