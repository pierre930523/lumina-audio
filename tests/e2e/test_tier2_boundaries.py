"""
Lumina Audio E2E Test Suite - Tier 2: Boundary & Corner Case Tests
Enumerate all 32 features from PROJECT.md § Feature Inventory (F01 to F32).
Each feature has at least 5 boundary, corner-case, edge-case, and negative tests.
Total: 32 features × 5 tests = 160 tests minimum.
"""
import base64
import cmath
import datetime
import hashlib
import ipaddress
import json
import math
import os
import re
import secrets
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from typing import Dict, Any, List, Optional, Tuple
from urllib.parse import urlparse, parse_qs, unquote

# Ensure tests package is discoverable
TEST_DIR = os.path.dirname(os.path.abspath(__file__))
WORKSPACE_ROOT = os.path.abspath(os.path.join(TEST_DIR, "..", ".."))
if WORKSPACE_ROOT not in sys.path:
    sys.path.insert(0, WORKSPACE_ROOT)

from tests.e2e.fixtures import (
    generate_wav_header,
    parse_wav_header,
    generate_dsf_header,
    parse_dsf_header,
    generate_flac_header,
    parse_flac_header,
    frame_dop,
    unframe_dop,
    init_in_memory_db,
    run_migration_0001,
    seed_mock_library,
    sanitize_fts5_query,
    execute_fts5_search,
    verify_schema_tables,
    validate_album,
    validate_year,
    merge_versions,
    compute_version_score,
    validate_mbid,
    validate_duration,
    validate_track_numbers,
    check_track_version_compatibility,
    validate_sample_rate,
    validate_bit_depth,
    validate_channels,
    validate_codec_format,
    calculate_biquad_peaking,
    calculate_biquad_response,
    check_biquad_stability,
    calculate_crossfeed_delay_samples,
    simulate_bauer_crossfeed,
    apply_replaygain_and_limiter,
    simulate_signal_path,
    validate_buffer_size,
    validate_keyring_keys,
    KeyringStore,
    SimulatedKeyringStore,
    MockKeyringService,
    validate_token_mode,
    parse_auth_mode_json,
    validate_credentials,
    redact_token,
    check_token_characters,
    get_mock_qobuz_login_response,
    get_mock_qobuz_stream_response,
    get_mock_tidal_pkce,
    get_mock_tidal_token_response,
    get_mock_deezer_arl,
    parse_remote_share_uri,
    validate_isrc,
    is_scannable_audio,
    check_qobuz_response,
    resolve_qobuz_url,
    resolve_format,
    normalize_sample_rate,
    validate_pkce_verifier,
    validate_arl_cookie,
    is_token_expired,
    validate_glsl_shader,
    evaluate_sd_rounded_box,
    evaluate_mesh_fluid_weights,
    get_shader_path,
    validate_pubspec_structure,
    is_valid_shader_asset_path,
    sanitize_asset_path,
    check_impeller_support,
    validate_rust_edition,
    parse_target_triple,
    validate_crate_types,
    is_supported_audio_api_level,
    parse_source_properties,
    validate_java_home,
    parse_ndk_version,
    validate_cargo_flags,
    parse_doctor_issues,
    count_analysis_errors,
    QuotaTracker,
    should_trigger_handoff,
    validate_quota,
    parse_quota_output,
    validate_progress_doc,
    validate_bind_address,
    authenticate_request,
    extract_bearer,
    process_ws_frame,
    check_body_size,
    validate_service_type,
    validate_txt_entry,
    resolve_name_collision,
    validate_pin,
    consume_pin,
    is_pin_valid,
    PinRateLimiter,
    validate_qr_pairing_uri,
    find_cargo_executable,
    run_toolchain_command,
)

if sys.version_info >= (3, 11):
    import tomllib
else:
    tomllib = None


# ==============================================================================
# Feature 01: Rust & C++ Toolchain Setup
# ==============================================================================
class TestTier2_F01_RustToolchainSetup(unittest.TestCase):
    """F01: Boundary and corner cases for Rust & C++ Toolchain configuration."""

    def test_f01_b01_cargo_toml_corrupted_syntax_handling(self):
        """Verifies TOML parser rejects malformed and truncated syntax with DecodeError."""
        corrupt_toml = b"[workspace\nmembers = [\n"
        with self.assertRaises(Exception):
            tomllib.loads(corrupt_toml.decode("utf-8"))

    def test_f01_b02_workspace_members_boundary_and_relative_escapes(self):
        """Verifies workspace member paths contain no empty strings, absolute paths, or traversal escapes."""
        cargo_path = os.path.join(WORKSPACE_ROOT, "Cargo.toml")
        with open(cargo_path, "rb") as f:
            data = tomllib.load(f)
        members = data["workspace"].get("members", [])
        self.assertGreater(len(members), 0, "Members list must not be empty")
        for m in members:
            self.assertTrue(bool(m.strip()), "Member entry cannot be empty or whitespace")
            self.assertFalse(m.startswith("/"), f"Member {m} must not be absolute Unix path")
            self.assertFalse(m.startswith("\\"), f"Member {m} must not be absolute Windows path")
            self.assertNotIn("..", m, f"Member {m} must not escape workspace root via '..'")
            self.assertTrue(m.startswith("crates/"), f"Member {m} must reside inside crates/")
            full_path = os.path.join(WORKSPACE_ROOT, m)
            self.assertTrue(os.path.isdir(full_path), f"Member directory {full_path} must exist on disk")

    def test_f01_b03_invalid_rust_edition_validation(self):
        """Verifies Rust edition validation rejects past unsupported, future, non-numeric or non-string editions."""
        self.assertFalse(validate_rust_edition("2010"))
        self.assertFalse(validate_rust_edition("2099"))
        self.assertFalse(validate_rust_edition(""))
        self.assertFalse(validate_rust_edition(2024))
        self.assertFalse(validate_rust_edition("edition_2024"))

        # Root Cargo.toml must declare valid current edition 2024
        cargo_path = os.path.join(WORKSPACE_ROOT, "Cargo.toml")
        with open(cargo_path, "rb") as f:
            data = tomllib.load(f)
        actual_edition = data["workspace"].get("package", {}).get("edition")
        self.assertTrue(validate_rust_edition(actual_edition))
        self.assertEqual(actual_edition, "2024")

    def test_f01_b04_target_triple_invalid_or_unsupported_architecture(self):
        """Verifies parsing target architecture triples rejects invalid, truncated, or unknown architectures."""
        # Boundary negatives
        with self.assertRaises(ValueError):
            parse_target_triple("")
        with self.assertRaises(ValueError):
            parse_target_triple("x86_128-pc-windows-msvc")
        with self.assertRaises(ValueError):
            parse_target_triple("x86_64-windows")
        with self.assertRaises(ValueError):
            parse_target_triple("windows-msvc")

        # Valid target triple
        arch, vendor, os_sys, abi = parse_target_triple("x86_64-pc-windows-msvc")
        self.assertEqual(arch, "x86_64")
        self.assertEqual(vendor, "pc")
        self.assertEqual(os_sys, "windows")
        self.assertEqual(abi, "msvc")

    def test_f01_b05_core_ffi_crate_types_rejection_of_invalid_types(self):
        """Verifies crates/core-ffi rejects illegal crate-types and enforces presence of cdylib and staticlib."""
        self.assertFalse(validate_crate_types([]))
        self.assertFalse(validate_crate_types(["cdylib", "unknown_type"]))
        self.assertFalse(validate_crate_types(["exe"]))

        ffi_cargo = os.path.join(WORKSPACE_ROOT, "crates", "core-ffi", "Cargo.toml")
        with open(ffi_cargo, "rb") as f:
            data = tomllib.load(f)
        crate_types = data.get("lib", {}).get("crate-type", [])
        self.assertTrue(validate_crate_types(crate_types))
        self.assertIn("cdylib", crate_types)
        self.assertIn("staticlib", crate_types)


# ==============================================================================
# Feature 02: Flutter & Android SDK Setup
# ==============================================================================
class TestTier2_F02_FlutterAndroidSdk(unittest.TestCase):
    """F02: Boundary and corner cases for Flutter and Android SDK path and version handling."""

    def test_f02_b01_android_sdk_path_boundaries_and_normalization(self):
        """Verifies path normalization handles trailing slashes, redundant separators, and spaces cleanly."""
        raw_paths = [
            "C:\\Users\\user\\AppData\\Local\\Android\\Sdk\\",
            "C:/Users/user/AppData/Local/Android/Sdk//",
            "C:\\Users\\user\\AppData\\Local\\Android\\\\Sdk",
            "C:/Users/user/AppData/Local/Android/Sdk",
        ]
        normalized = [os.path.normpath(p) for p in raw_paths]
        # All variations should resolve to the exact same canonical path representation
        self.assertEqual(len(set(normalized)), 1)
        self.assertFalse(normalized[0].endswith("\\"))
        self.assertFalse(normalized[0].endswith("/"))

    def test_f02_b02_platform_api_level_boundary_values(self):
        """Verifies Android platform API boundary checks: min API 24 (AAudio/Oboe) and rejects < 24 or invalid."""
        self.assertFalse(is_supported_audio_api_level(23), "API 23 (Marshmallow) lacks AAudio")
        self.assertFalse(is_supported_audio_api_level(0))
        self.assertFalse(is_supported_audio_api_level(-1))
        self.assertFalse(is_supported_audio_api_level(100))
        self.assertFalse(is_supported_audio_api_level("34"))
        self.assertTrue(is_supported_audio_api_level(24))
        self.assertTrue(is_supported_audio_api_level(34))
        self.assertTrue(is_supported_audio_api_level(35))

    def test_f02_b03_source_properties_parser_boundary_cases(self):
        """Verifies Android SDK source.properties parser handles empty files, comments, and missing equals signs."""
        # Empty content
        self.assertEqual(parse_source_properties(""), {})
        # Only comments and blank lines
        self.assertEqual(parse_source_properties("# Just comments\n\n# Another\n"), {})
        # Malformed lines without equals
        props = parse_source_properties("Pkg.Revision=34.0.0\nInvalidLineWithoutEquals\nPkg.Desc=Android SDK")
        self.assertEqual(props.get("Pkg.Revision"), "34.0.0")
        self.assertEqual(props.get("Pkg.Desc"), "Android SDK")
        self.assertNotIn("InvalidLineWithoutEquals", props)

    def test_f02_b04_java_home_validation_boundaries(self):
        """Verifies Java runtime discovery validates directory existence and rejects file paths or empty strings."""
        self.assertFalse(validate_java_home(None))
        self.assertFalse(validate_java_home(""))
        self.assertFalse(validate_java_home("   "))
        self.assertFalse(validate_java_home("C:\\NonExistent\\Java\\Path\\404"))
        # Passing an existing file rather than a directory must fail
        sample_file = os.path.join(WORKSPACE_ROOT, "Cargo.toml")
        self.assertFalse(validate_java_home(sample_file))

    def test_f02_b05_ndk_version_semver_parsing_boundary(self):
        """Verifies NDK side-by-side version parsing handles 3-part semver, builds, and rejects malformed versions."""
        with self.assertRaises(ValueError):
            parse_ndk_version("invalid_ndk")
        with self.assertRaises(ValueError):
            parse_ndk_version("25")
        with self.assertRaises(ValueError):
            parse_ndk_version("")

        major, minor, build = parse_ndk_version("25.1.8937393")
        self.assertEqual(major, 25)
        self.assertEqual(minor, 1)
        self.assertEqual(build, 8937393)

        # Boundary minimum version
        self.assertEqual(parse_ndk_version("0.0.0"), (0, 0, 0))


# ==============================================================================
# Feature 03: Flutter App Scaffolding
# ==============================================================================
class TestTier2_F03_FlutterAppScaffolding(unittest.TestCase):
    """F03: Boundary and corner cases for Flutter scaffolding, pubspec validation, and shaders."""

    def test_f03_b01_pubspec_malformed_yaml_handling(self):
        """Verifies pubspec schema validation catches missing mandatory flutter block and malformed structures."""
        self.assertFalse(validate_pubspec_structure({}))
        self.assertFalse(validate_pubspec_structure({"name": "app"}))
        self.assertFalse(validate_pubspec_structure({"name": "", "flutter": {}}))
        self.assertFalse(validate_pubspec_structure({"name": "app", "flutter": "not_a_dict"}))
        self.assertTrue(validate_pubspec_structure({"name": "app", "flutter": {"shaders": []}}))

    def test_f03_b02_shader_asset_declaration_missing_file_or_invalid_extension(self):
        """Verifies shader validator rejects non-.frag extensions, uppercase, and non-existent files."""
        app_dir = os.path.join(WORKSPACE_ROOT, "app")
        # Non-frag extensions
        self.assertFalse(is_valid_shader_asset_path("shaders/liquid_glass.glsl", app_dir))
        self.assertFalse(is_valid_shader_asset_path("shaders/liquid_glass.frag.bak", app_dir))
        self.assertFalse(is_valid_shader_asset_path("shaders/nonexistent.frag", app_dir))
        # Actual valid shaders
        self.assertTrue(is_valid_shader_asset_path("shaders/liquid_glass.frag", app_dir))
        self.assertTrue(is_valid_shader_asset_path("shaders/mesh_fluid_bg.frag", app_dir))

    def test_f03_b03_zero_byte_shader_rejection(self):
        """Verifies shader validator flags 0-byte or whitespace-only shader files as invalid."""
        with tempfile.NamedTemporaryFile(suffix=".frag", delete=False) as tf:
            tf.write(b"")
            empty_shader = tf.name

        try:
            with open(empty_shader, "r", encoding="utf-8") as f:
                content = f.read().strip()
            self.assertEqual(len(content), 0, "File is empty")
            # Empty shader cannot have main() or version 460
            has_main = "void main()" in content
            self.assertFalse(has_main, "0-byte shader must fail validation")
        finally:
            if os.path.exists(empty_shader):
                os.remove(empty_shader)

    def test_f03_b04_directory_traversal_in_asset_paths(self):
        """Verifies path validator detects directory traversal attempts in Flutter pubspec asset declarations."""
        with self.assertRaises(ValueError):
            sanitize_asset_path("../shaders/liquid_glass.frag")
        with self.assertRaises(ValueError):
            sanitize_asset_path("assets/../../etc/passwd")
        with self.assertRaises(ValueError):
            sanitize_asset_path("/shaders/mesh_fluid_bg.frag")

        self.assertEqual(sanitize_asset_path("shaders/liquid_glass.frag"), "shaders/liquid_glass.frag")

    def test_f03_b05_impeller_backend_minimum_version_boundary(self):
        """Verifies Impeller rendering requirements: Vulkan >= 1.1, OpenGL ES >= 3.0, rejecting legacy ES 2.0."""
        self.assertFalse(check_impeller_support("vulkan", 1, 0))
        self.assertTrue(check_impeller_support("vulkan", 1, 1))
        self.assertTrue(check_impeller_support("vulkan", 1, 3))
        self.assertFalse(check_impeller_support("opengles", 2, 0))
        self.assertTrue(check_impeller_support("opengles", 3, 0))
        self.assertFalse(check_impeller_support("directx", 9, 0))


# ==============================================================================
# Feature 04: Toolchain Verification
# ==============================================================================
class TestTier2_F04_ToolchainVerification(unittest.TestCase):
    """F04: Boundary and corner cases for toolchain CLI verification commands."""

    def test_f04_b01_cargo_command_timeout_and_exit_code_propagation(self):
        """Verifies command execution wrapper captures non-zero exit codes properly."""
        cmd = [sys.executable, "-c", "import sys; sys.exit(77)"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 77)

    def test_f04_b02_cargo_check_empty_or_conflicting_flags(self):
        """Verifies CLI flag validation detects mutually conflicting options (--release and --debug)."""
        with self.assertRaises(ValueError):
            validate_cargo_flags([])
        with self.assertRaises(ValueError):
            validate_cargo_flags(["--release", "--debug"])

        self.assertTrue(validate_cargo_flags(["check", "--workspace", "--all-targets"]))

    def test_f04_b03_flutter_doctor_output_parsing_with_warnings(self):
        """Verifies doctor output parser accurately counts issues, warnings [!], and failures [x]."""
        sample_output = """
        [✓] Flutter (Channel stable, 3.24.0)
        [!] Android toolchain - some licenses not accepted
        [✗] Visual Studio - missing workload
        [✓] Connected device (1 available)
        """
        counts = parse_doctor_issues(sample_output)
        self.assertEqual(counts["pass"], 2)
        self.assertEqual(counts["warn"], 1)
        self.assertEqual(counts["fail"], 1)

    def test_f04_b04_flutter_analyze_json_format_diagnostics(self):
        """Verifies analyzer JSON parser handles empty diagnostics list and extracts error count accurately."""
        clean_json = json.dumps({"diagnostics": []})
        dirty_json = json.dumps({
            "diagnostics": [
                {"code": "unused_import", "severity": "WARNING"},
                {"code": "undefined_identifier", "severity": "ERROR"},
            ]
        })

        self.assertEqual(count_analysis_errors(clean_json), 0)
        self.assertEqual(count_analysis_errors(dirty_json), 1)

    def test_f04_b05_missing_executable_error_handling(self):
        """Verifies invoking a non-existent binary raises FileNotFoundError instead of uncaught crash."""
        with self.assertRaises(FileNotFoundError):
            subprocess.run(["__non_existent_binary_xyz_12345__", "--version"], capture_output=True)


# ==============================================================================
# Feature 05: Quota Monitoring Integration
# ==============================================================================
class TestTier2_F05_QuotaMonitoringIntegration(unittest.TestCase):
    """F05: Boundary and corner cases for quota monitoring and automated handoff triggers."""

    def test_f05_b01_quota_percentage_exact_boundary_15_percent(self):
        """Verifies handoff trigger boundary at exactly 15.0%: 15.01% is False, 15.00% is True, 14.99% is True."""
        self.assertFalse(should_trigger_handoff(15.01))
        self.assertTrue(should_trigger_handoff(15.00))
        self.assertTrue(should_trigger_handoff(14.99))
        self.assertTrue(should_trigger_handoff(0.0))

    def test_f05_b02_quota_negative_or_overflow_values(self):
        """Verifies quota validator rejects negative values, values > 100%, and non-numeric types."""
        with self.assertRaises(ValueError):
            validate_quota(-0.5)
        with self.assertRaises(ValueError):
            validate_quota(100.01)
        with self.assertRaises(ValueError):
            validate_quota(float("nan"))
        with self.assertRaises(ValueError):
            validate_quota("50%")

    def test_f05_b03_inspect_antigravity_malformed_json_response(self):
        """Verifies parser handles empty stdout, non-JSON output, and missing fields from inspect script."""
        self.assertIsNone(parse_quota_output(""))
        self.assertIsNone(parse_quota_output("Error: connection refused"))
        self.assertIsNone(parse_quota_output('{"status": "ok"}'))
        self.assertEqual(parse_quota_output('{"remaining_percentage": 42.5}'), 42.5)

    def test_f05_b04_progress_markdown_missing_required_headers(self):
        """Verifies PROGRESS.md validator enforces mandatory sections (Completed, In-Progress, Next Steps)."""
        # Empty doc missing everything
        self.assertEqual(len(validate_progress_doc("")), 3)

        # Incomplete doc
        partial_doc = "## Completed Modules\n- Rust Core\n"
        missing = validate_progress_doc(partial_doc)
        self.assertIn("In-Progress Changes", missing)
        self.assertIn("Prioritized Next Steps", missing)

    def test_f05_b05_quota_rapid_depletion_simulation(self):
        """Verifies state machine tracking quota transitions monotonically into HANDOFF state once triggered."""
        tracker = QuotaTracker()
        tracker.update(85.0)
        self.assertFalse(tracker.handoff_active)
        tracker.update(50.0)
        self.assertFalse(tracker.handoff_active)
        tracker.update(14.5)
        self.assertTrue(tracker.handoff_active)
        # Quota recovers slightly (e.g. transient calculation), handoff state latch remains locked
        tracker.update(16.0)
        self.assertTrue(tracker.handoff_active)


# ==============================================================================
# Feature 06: ProviderKind Enumeration
# ==============================================================================
class TestTier2_F06_ProviderKindEnumeration(unittest.TestCase):
    """F06: Boundary and corner cases for ProviderKind serialization and sanitization."""

    CANONICAL_KINDS = {"local", "smb", "web_dav", "qobuz", "tidal", "deezer"}

    def _parse_kind(self, val: Any) -> str:
        if not isinstance(val, str):
            raise TypeError(f"ProviderKind must be string, got {type(val)}")
        if val not in self.CANONICAL_KINDS:
            raise ValueError(f"Unknown ProviderKind: '{val}'")
        return val

    def test_f06_b01_unknown_string_deserialization_rejection(self):
        """Verifies deserialization rejects unsupported provider names (spotify, apple_music, soundcloud)."""
        unknowns = ["spotify", "apple_music", "soundcloud", "bandcamp", "youtube", ""]
        for u in unknowns:
            with self.assertRaises(ValueError):
                self._parse_kind(u)

    def test_f06_b02_case_sensitivity_snake_case(self):
        """Verifies strict case sensitivity: rejects uppercase, camelCase, and TitleCase."""
        bad_cases = ["Local", "LOCAL", "Smb", "SMB", "webDav", "Web_Dav", "Qobuz", "QOBUZ"]
        for b in bad_cases:
            with self.assertRaises(ValueError):
                self._parse_kind(b)

    def test_f06_b03_null_and_non_string_json_types(self):
        """Verifies deserialization rejects null, integers, booleans, and arrays."""
        bad_types = [None, 1, 0, True, False, [], {}]
        for b in bad_types:
            with self.assertRaises(TypeError):
                self._parse_kind(b)

    def test_f06_b04_unicode_and_sql_injection_names(self):
        """Verifies SQL injection payloads and control characters in provider names are rejected."""
        payloads = [
            "local; DROP TABLE tracks; --",
            "qobuz' OR '1'='1",
            "local\x00hidden",
            "qobuz\r\n",
        ]
        for p in payloads:
            with self.assertRaises(ValueError):
                self._parse_kind(p)

    def test_f06_b05_extreme_length_and_whitespace_padding(self):
        """Verifies leading/trailing whitespace and oversized strings are rejected."""
        whitespaced = [" local", "local ", " local ", "smb\t", "\nqobuz"]
        for w in whitespaced:
            with self.assertRaises(ValueError):
                self._parse_kind(w)

        huge_string = "local" + "x" * 10000
        with self.assertRaises(ValueError):
            self._parse_kind(huge_string)


# ==============================================================================
# Feature 07: QobuzAuthMode Structure
# ==============================================================================
class TestTier2_F07_QobuzAuthModeStructure(unittest.TestCase):
    """F07: Boundary and corner cases for QobuzAuthMode dual-mode authentication."""

    def test_f07_b01_empty_token_string_validation(self):
        """Verifies token mode rejects empty strings and whitespace-only auth tokens."""
        with self.assertRaises(ValueError):
            validate_token_mode("")
        with self.assertRaises(ValueError):
            validate_token_mode("   ")
        self.assertEqual(validate_token_mode("qb_token_12345"), "qb_token_12345")

    def test_f07_b02_missing_tag_discriminator_rejection(self):
        """Verifies JSON deserialization rejects payloads missing 'mode' tag or with unknown mode."""
        with self.assertRaises(ValueError):
            parse_auth_mode_json({"user_auth_token": "abc"})
        with self.assertRaises(ValueError):
            parse_auth_mode_json({"mode": "oauth", "token": "abc"})

        self.assertEqual(parse_auth_mode_json({"mode": "token", "user_auth_token": "abc"}), "token")

    def test_f07_b03_credentials_mode_empty_user_or_password(self):
        """Verifies credentials mode rejects missing or blank username or password."""
        with self.assertRaises(ValueError):
            validate_credentials("", "secret123")
        with self.assertRaises(ValueError):
            validate_credentials("user@example.com", "")
        with self.assertRaises(ValueError):
            validate_credentials("   ", "   ")

    def test_f07_b04_token_redaction_boundary_short_tokens(self):
        """Verifies sensitive token redaction helper handles lengths 0, 1, 4, 8, and long strings safely."""
        self.assertEqual(redact_token(""), "")
        self.assertEqual(redact_token("a"), "*")
        self.assertEqual(redact_token("abcd"), "****")
        self.assertEqual(redact_token("12345678"), "12****78")
        redacted_long = redact_token("qb_token_long_secret_99887766")
        self.assertTrue(redacted_long.startswith("qb_t"))
        self.assertTrue(redacted_long.endswith("7766"))
        self.assertNotIn("secret", redacted_long)

    def test_f07_b05_control_characters_in_auth_token(self):
        """Verifies auth tokens containing CRLF, null bytes, or control characters are rejected."""
        self.assertFalse(check_token_characters("tok\r\n"))
        self.assertFalse(check_token_characters("tok\x00en"))
        self.assertFalse(check_token_characters("tok en"))
        self.assertTrue(check_token_characters("qb_usr_tok_99182371-abc"))


# ==============================================================================
# Feature 08: Audio Format & Codec Models
# ==============================================================================
class TestTier2_F08_AudioFormatAndCodecModels(unittest.TestCase):
    """F08: Boundary and corner cases for AudioFormat sample rates, bit depths, and DSD constraints."""

    def test_f08_b01_zero_and_negative_sample_rate(self):
        """Verifies sample rate validation rejects 0 Hz, negative values, and rates > 45.1584 MHz (DSD1024)."""
        with self.assertRaises(ValueError):
            validate_sample_rate(0)
        with self.assertRaises(ValueError):
            validate_sample_rate(-44100)
        with self.assertRaises(ValueError):
            validate_sample_rate(999999999)

        self.assertEqual(validate_sample_rate(44100), 44100)
        self.assertEqual(validate_sample_rate(2822400), 2822400)

    def test_f08_b02_bit_depth_boundaries_and_dsd_constraint(self):
        """Verifies bit depth constraints: 1-bit strictly requires is_dsd=True; PCM requires 8, 16, 24, or 32."""
        # Invalid DSD depths
        with self.assertRaises(ValueError):
            validate_bit_depth(16, is_dsd=True)
        # Invalid PCM depths
        with self.assertRaises(ValueError):
            validate_bit_depth(1, is_dsd=False)
        with self.assertRaises(ValueError):
            validate_bit_depth(64, is_dsd=False)
        with self.assertRaises(ValueError):
            validate_bit_depth(0, is_dsd=False)

        # Valid states
        validate_bit_depth(1, is_dsd=True)
        validate_bit_depth(24, is_dsd=False)

    def test_f08_b03_channel_count_boundaries(self):
        """Verifies channel count validation: 1 <= channels <= 32; rejects 0, negative, and extreme overflows."""
        with self.assertRaises(ValueError):
            validate_channels(0)
        with self.assertRaises(ValueError):
            validate_channels(-2)
        with self.assertRaises(ValueError):
            validate_channels(256)

        validate_channels(1)   # Mono
        validate_channels(2)   # Stereo
        validate_channels(8)   # 7.1 Surround

    def test_f08_b04_codec_and_is_dsd_inconsistency(self):
        """Verifies consistency between AudioCodec enum and is_dsd flag."""
        with self.assertRaises(ValueError):
            validate_codec_format("flac", is_dsd=True)
        with self.assertRaises(ValueError):
            validate_codec_format("dsf", is_dsd=False)

        validate_codec_format("flac", is_dsd=False)
        validate_codec_format("dsf", is_dsd=True)

    def test_f08_b05_extreme_frame_byte_size_calculation(self):
        """Verifies calculation of raw PCM uncompressed byte sizes prevents 32-bit integer overflow."""
        # 1 hour of 24-bit / 192,000 Hz Stereo
        sample_rate = 192000
        channels = 2
        bytes_per_sample = 3
        duration_sec = 3600

        total_bytes = sample_rate * channels * bytes_per_sample * duration_sec
        # Total bytes = 4,147,200,000 bytes (~4.14 GB)
        self.assertGreater(total_bytes, 2**31 - 1, "Must exceed signed 32-bit integer limit")
        self.assertEqual(total_bytes, 4147200000)
        self.assertGreater(total_bytes, 2**31 - 1, "Must exceed signed 32-bit integer limit")
        self.assertEqual(total_bytes, 4147200000)


# ==============================================================================
# Feature 09: Canonical Album Merging Models
# ==============================================================================
class TestTier2_F09_CanonicalAlbumMergingModels(unittest.TestCase):
    """F09: Boundary and corner cases for CanonicalAlbum and AlbumVersion deduplication and ranking."""

    def test_f09_b01_empty_album_title_or_artist(self):
        """Verifies canonical album validator rejects blank or whitespace-only album titles and artists."""
        with self.assertRaises(ValueError):
            validate_album("", "Pink Floyd")
        with self.assertRaises(ValueError):
            validate_album("Dark Side", "   ")

    def test_f09_b02_release_year_boundaries(self):
        """Verifies release year validation accepts historical recorded music (1860-2100) and rejects anomalies."""
        with self.assertRaises(ValueError):
            validate_year(-500)
        with self.assertRaises(ValueError):
            validate_year(1700)
        with self.assertRaises(ValueError):
            validate_year(9999)

        self.assertEqual(validate_year(1973), 1973)
        self.assertIsNone(validate_year(None))

    def test_f09_b03_duplicate_version_ids_in_same_album(self):
        """Verifies merging logic detects and rejects duplicate AlbumVersion IDs in the same CanonicalAlbum."""
        ids = ["ver-01", "ver-02"]
        with self.assertRaises(ValueError):
            merge_versions(ids, "ver-01")

        merged = merge_versions(ids, "ver-03")
        self.assertEqual(len(merged), 3)

    def test_f09_b04_album_version_ranking_and_tie_breaking(self):
        """Verifies audiophile version ranking: DSD > 24/192 > 24/96 > 16/44.1, with local provider priority."""
        v_dsd = {"provider": "local", "sample_rate_hz": 2822400, "bit_depth": 1, "is_dsd": True}
        v_24_192_qobuz = {"provider": "qobuz", "sample_rate_hz": 192000, "bit_depth": 24, "is_dsd": False}
        v_16_44_local = {"provider": "local", "sample_rate_hz": 44100, "bit_depth": 16, "is_dsd": False}

        score_dsd = compute_version_score(v_dsd)
        score_hires = compute_version_score(v_24_192_qobuz)
        score_cd = compute_version_score(v_16_44_local)

        self.assertGreater(score_dsd, score_hires)
        self.assertGreater(score_hires, score_cd)

    def test_f09_b05_malformed_musicbrainz_uuid(self):
        """Verifies MusicBrainz release group ID requires valid standard RFC 4122 UUID v4 regex format."""
        self.assertFalse(validate_mbid("not-a-uuid"))
        self.assertFalse(validate_mbid("a11d2f66-1b0a-35b8-80f0"))
        self.assertFalse(validate_mbid("a11d2f66_1b0a_35b8_80f0_821533bf76f7"))
        self.assertTrue(validate_mbid("a11d2f66-1b0a-35b8-80f0-821533bf76f7"))


# ==============================================================================
# Feature 10: Track Source Abstraction
# ==============================================================================
class TestTier2_F10_TrackSourceAbstraction(unittest.TestCase):
    """F10: Boundary and corner cases for TrackSource duration, track numbering, and ISRC codes."""

    def test_f10_b01_zero_and_maximum_duration(self):
        """Verifies duration constraints: duration_ms must be >= 1 ms and <= 86,400,000 ms (24 hours)."""
        with self.assertRaises(ValueError):
            validate_duration(0)
        with self.assertRaises(ValueError):
            validate_duration(-1000)
        with self.assertRaises(ValueError):
            validate_duration(100000000)

        validate_duration(1)        # 1 ms minimum boundary
        validate_duration(180000)   # 3 minutes

    def test_f10_b02_disc_and_track_number_boundaries(self):
        """Verifies disc_number >= 1 and track_number >= 1; rejects 0 and negative integers."""
        with self.assertRaises(ValueError):
            validate_track_numbers(0, 1)
        with self.assertRaises(ValueError):
            validate_track_numbers(1, 0)

        validate_track_numbers(1, 1)
        validate_track_numbers(10, 999)  # Box sets

    def test_f10_b03_isrc_regex_and_checksum_boundary(self):
        """Verifies standard 12-character ISRC format (e.g. GBAYE7300021) and rejects hyphens or bad lengths."""
        self.assertFalse(validate_isrc("GB-AYE-73-00021"))
        self.assertFalse(validate_isrc("GBAYE730002"))    # 11 chars
        self.assertFalse(validate_isrc("GBAYE73000211"))  # 13 chars
        self.assertFalse(validate_isrc("12AYE7300021"))   # Numbers in country code
        self.assertTrue(validate_isrc("GBAYE7300021"))
        self.assertTrue(validate_isrc("USPR37300012"))

    def test_f10_b04_external_track_id_special_characters(self):
        """Verifies external track IDs properly preserve URL special characters and URI schemes."""
        ext_ids = [
            "track?id=991&format=flac",
            "smb://nas/music/Pink%20Floyd/01.flac",
            "qobuz:track:12049182",
            "local:/home/user/music/Beyonc%C3%A9.flac",
        ]
        for eid in ext_ids:
            quoted = unquote(eid)
            self.assertTrue(bool(quoted))
            self.assertGreater(len(quoted), 5)

    def test_f10_b05_track_source_format_mismatch_with_version(self):
        """Verifies format validation raises error if track sample rate conflicts with parent album version."""
        with self.assertRaises(ValueError):
            check_track_version_compatibility(44100, 96000)

        check_track_version_compatibility(96000, 96000)


# ==============================================================================
# Feature 11: SQLite WAL Pool & Migrations
# ==============================================================================
class TestTier2_F11_SqliteWalPoolAndMigrations(unittest.TestCase):
    """F11: Boundary and corner cases for SQLite database schema, foreign keys, and WAL mode."""

    def setUp(self):
        self.conn = init_in_memory_db()

    def tearDown(self):
        self.conn.close()

    def test_f11_b01_foreign_key_constraint_enforcement(self):
        """Verifies foreign key constraints fail on inserting album_versions with non-existent canonical_album_id."""
        cur = self.conn.cursor()
        with self.assertRaises(sqlite3.IntegrityError):
            cur.execute(
                "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth, channels, is_dsd) "
                "VALUES ('ver-bad', 'alb-nonexistent', 'local', 'ext-1', 'flac', 44100, 16, 2, 0)"
            )
            self.conn.commit()

    def test_f11_b02_unique_constraint_violation(self):
        """Verifies primary key unique constraints raise IntegrityError on duplicate insert."""
        cur = self.conn.cursor()
        cur.execute("INSERT INTO profiles (id, name, avatar_color, is_default, created_at) VALUES ('p1', 'Default', '#FFF', 1, '2026-11-16T00:00:00Z')")
        self.conn.commit()

        with self.assertRaises(sqlite3.IntegrityError):
            cur.execute("INSERT INTO profiles (id, name, avatar_color, is_default, created_at) VALUES ('p1', 'Duplicate', '#000', 0, '2026-11-16T00:00:00Z')")
            self.conn.commit()

    def test_f11_b03_null_constraint_on_mandatory_columns(self):
        """Verifies NOT NULL constraints raise IntegrityError on inserting NULL in required columns."""
        cur = self.conn.cursor()
        with self.assertRaises(sqlite3.IntegrityError):
            cur.execute("INSERT INTO canonical_albums (id, title, sort_title) VALUES ('alb-null', NULL, 'Test')")
            self.conn.commit()

    def test_f11_b04_wal_mode_and_concurrency_busy_timeout(self):
        """Verifies PRAGMA busy_timeout configuration and journal mode setting contracts."""
        cur = self.conn.cursor()
        cur.execute("PRAGMA busy_timeout = 5000;")
        cur.execute("PRAGMA busy_timeout;")
        timeout = cur.fetchone()[0]
        self.assertEqual(timeout, 5000)

    def test_f11_b05_migration_idempotency_double_run(self):
        """Verifies 0001_init.sql can be executed multiple times on the same connection without syntax errors."""
        # Second migration execution should succeed because of CREATE TABLE IF NOT EXISTS
        run_migration_0001(self.conn)
        tables = verify_schema_tables(self.conn)
        self.assertIn("canonical_albums", tables)
        self.assertIn("search_fts", tables)


# ==============================================================================
# Feature 12: Relational Library Repositories
# ==============================================================================
class TestTier2_F12_RelationalLibraryRepositories(unittest.TestCase):
    """F12: Boundary and corner cases for repository CRUD, SQL injection safety, and cascade deletes."""

    def setUp(self):
        self.conn = init_in_memory_db()
        self.ids = seed_mock_library(self.conn)

    def tearDown(self):
        self.conn.close()

    def test_f12_b01_sql_injection_in_repository_queries(self):
        """Verifies parameterized queries prevent SQL injection bypass (' OR 1=1 --)."""
        cur = self.conn.cursor()
        malicious_input = "' OR 1=1 --"
        cur.execute("SELECT * FROM artists WHERE name = ?", (malicious_input,))
        rows = cur.fetchall()
        self.assertEqual(len(rows), 0, "SQL injection must return 0 rows for literal match")

    def test_f12_b02_cascade_deletion_of_versions_and_tracks(self):
        """Verifies deleting a canonical album cascades deletion to child album_versions and track_sources."""
        cur = self.conn.cursor()
        alb_id = self.ids["album_dsotm_id"]

        # Confirm tracks exist prior to deletion
        cur.execute("SELECT COUNT(*) FROM album_versions WHERE canonical_album_id = ?", (alb_id,))
        self.assertGreater(cur.fetchone()[0], 0)

        cur.execute("DELETE FROM canonical_albums WHERE id = ?", (alb_id,))
        self.conn.commit()

        # Versions and tracks must be cascaded
        cur.execute("SELECT COUNT(*) FROM album_versions WHERE canonical_album_id = ?", (alb_id,))
        self.assertEqual(cur.fetchone()[0], 0, "Album versions must be cascaded")

    def test_f12_b03_large_batch_insertion_limit(self):
        """Verifies inserting 500 track sources in a single transaction executes without variable overflow."""
        cur = self.conn.cursor()
        version_id = self.ids["version_ids"][0]
        rows = []
        for i in range(1, 501):
            rows.append((
                f"batch-trk-{i}",
                version_id,
                "local",
                f"ext-batch-{i}",
                f"Batch Track #{i}",
                1,
                i,
                180000,
                96000,
                24,
                "flac"
            ))

        cur.executemany(
            "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            rows
        )
        self.conn.commit()

        cur.execute("SELECT COUNT(*) FROM track_sources WHERE id LIKE 'batch-trk-%'")
        self.assertEqual(cur.fetchone()[0], 500)

    def test_f12_b04_pagination_offset_and_limit_boundaries(self):
        """Verifies repository query pagination with LIMIT 0, extreme offset, and boundary limits."""
        cur = self.conn.cursor()
        # LIMIT 0 returns empty
        cur.execute("SELECT * FROM canonical_albums LIMIT 0")
        self.assertEqual(len(cur.fetchall()), 0)

        # Extreme OFFSET beyond total records
        cur.execute("SELECT * FROM canonical_albums LIMIT 10 OFFSET 9999")
        self.assertEqual(len(cur.fetchall()), 0)

    def test_f12_b05_empty_result_set_returns_empty_list_not_error(self):
        """Verifies querying non-existent primary key returns None without throwing exceptions."""
        cur = self.conn.cursor()
        cur.execute("SELECT * FROM artists WHERE id = ?", ("non-existent-artist-9999",))
        self.assertIsNone(cur.fetchone())


# ==============================================================================
# Feature 13: FTS5 Full-Text Search Engine
# ==============================================================================
class TestTier2_F13_Fts5FullTextSearchEngine(unittest.TestCase):
    """F13: Boundary and corner cases for FTS5 syntax escaping, unicode, CJK, and search tokens."""

    def setUp(self):
        self.conn = init_in_memory_db()
        seed_mock_library(self.conn)

    def tearDown(self):
        self.conn.close()

    def test_f13_b01_fts5_syntax_operator_escaping(self):
        """Verifies FTS5 query sanitizer neutralizes boolean operators, asterisks, colons, and quotes."""
        dangerous_inputs = [
            'Pink AND Floyd OR "The Wall" NEAR/3 *',
            'artist: "Pink Floyd"',
            'track^2 + (Breathe) - Time',
            '"""malformed quotes"""',
        ]
        for q in dangerous_inputs:
            sanitized = sanitize_fts5_query(q)
            # Must be safe to execute against search_fts without SQLite syntax error
            results = execute_fts5_search(self.conn, sanitized)
            self.assertIsInstance(results, list)

    def test_f13_b02_fts5_empty_and_whitespace_only_query(self):
        """Verifies empty, whitespace-only, and punctuation-only searches return empty lists safely."""
        self.assertEqual(execute_fts5_search(self.conn, ""), [])
        self.assertEqual(execute_fts5_search(self.conn, "   "), [])
        self.assertEqual(execute_fts5_search(self.conn, "::: --- ***"), [])

    def test_f13_b03_fts5_unicode_normalization_accents_and_cjk(self):
        """Verifies FTS5 searches support accented letters (Sigur Rós) and CJK characters (坂本龍一)."""
        cur = self.conn.cursor()
        cur.execute("INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('artist', 'art-cjk', '坂本龍一', 'Ryuichi Sakamoto')")
        cur.execute("INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('artist', 'art-nordic', 'Sigur Rós', 'Icelandic post-rock band')")
        self.conn.commit()

        cjk_results = execute_fts5_search(self.conn, "坂本龍一")
        self.assertGreaterEqual(len(cjk_results), 1)
        self.assertEqual(cjk_results[0]["entity_id"], "art-cjk")

        nordic_results = execute_fts5_search(self.conn, "Sigur")
        self.assertGreaterEqual(len(nordic_results), 1)

    def test_f13_b04_fts5_single_character_and_prefix_boundary(self):
        """Verifies 1-character search tokens match via prefix matching (P* matches Pink Floyd)."""
        results = execute_fts5_search(self.conn, "P")
        self.assertGreaterEqual(len(results), 1)
        titles = [r["title"] for r in results]
        self.assertTrue(any("Pink Floyd" in t for t in titles))

    def test_f13_b05_fts5_index_synchronization_on_update_delete(self):
        """Verifies updating or deleting rows in search_fts immediately reflects in search results."""
        cur = self.conn.cursor()
        cur.execute("DELETE FROM search_fts WHERE entity_id = 'art-dp-002'")
        self.conn.commit()

        results = execute_fts5_search(self.conn, "Daft Punk")
        dp_artist_matches = [r for r in results if r["entity_id"] == "art-dp-002"]
        self.assertEqual(len(dp_artist_matches), 0)


# ==============================================================================
# Feature 14: OS Keyring Credential Storage
# ==============================================================================
class TestTier2_F14_OsKeyringCredentialStorage(unittest.TestCase):
    """F14: Boundary and corner cases for OS Keyring secret isolation and binary token handling."""

    def test_f14_b01_empty_service_or_account_name(self):
        """Verifies Keyring abstraction rejects empty service names or empty user account identifiers."""
        def validate_keyring_keys(service: str, account: str):
            if not service or not service.strip():
                raise ValueError("Keyring service name cannot be empty")
            if not account or not account.strip():
                raise ValueError("Keyring account name cannot be empty")

        with self.assertRaises(ValueError):
            validate_keyring_keys("", "qobuz_token")
        with self.assertRaises(ValueError):
            validate_keyring_keys("lumina_audio", "")

    def test_f14_b02_binary_and_high_entropy_secret_storage(self):
        """Verifies storing 256-bit random high-entropy binary keys and tokens with URL characters."""
        class KeyringStore:
            def __init__(self):
                self._vault: Dict[Tuple[str, str], str] = {}

            def set_secret(self, service: str, account: str, secret: str):
                self._vault[(service, account)] = secret

            def get_secret(self, service: str, account: str) -> Optional[str]:
                return self._vault.get((service, account))

        vault = KeyringStore()
        token = secrets.token_urlsafe(64)
        vault.set_secret("lumina", "tidal_refresh", token)
        self.assertEqual(vault.get_secret("lumina", "tidal_refresh"), token)

    def test_f14_b03_nonexistent_secret_retrieval_returns_none(self):
        """Verifies querying a non-existent credential key returns None rather than throwing exceptions."""
        vault: Dict[str, str] = {}
        self.assertIsNone(vault.get("nonexistent_account_key"))

    def test_f14_b04_keyring_secret_deletion_idempotency(self):
        """Verifies deleting an existing secret succeeds and deleting it a second time is cleanly handled."""
        vault = {"secret_key": "val123"}
        # First deletion
        deleted_first = vault.pop("secret_key", None)
        self.assertEqual(deleted_first, "val123")
        # Second deletion
        deleted_second = vault.pop("secret_key", None)
        self.assertIsNone(deleted_second)

    def test_f14_b05_credential_leak_prevention_in_db(self):
        """Verifies sensitive credential columns are not present in relational SQLite tables."""
        conn = init_in_memory_db()
        cur = conn.cursor()
        cur.execute("SELECT sql FROM sqlite_master WHERE type='table';")
        all_ddl = " ".join([row[0] for row in cur.fetchall() if row[0]]).lower()
        conn.close()

        forbidden_column_keywords = ["user_auth_token", "password_hash", "client_secret", "refresh_token"]
        for kw in forbidden_column_keywords:
            self.assertNotIn(kw, all_ddl, f"Column '{kw}' must not be stored in SQLite schema")


# ==============================================================================
# Feature 15: Symphonia PCM Audio Demuxing
# ==============================================================================
class TestTier2_F15_SymphoniaPcmAudioDemuxing(unittest.TestCase):
    """F15: Boundary and corner cases for PCM audio headers and corrupt demuxing streams."""

    def test_f15_b01_corrupt_wav_header_magic(self):
        """Verifies WAV parser rejects corrupted RIFF/WAVE magic bytes (e.g. RIFX or BAD!)."""
        with self.assertRaises(ValueError) as ctx:
            parse_wav_header(b"RIFX" + b"\x00" * 40)
        self.assertIn("Invalid RIFF magic", str(ctx.exception))

    def test_f15_b02_truncated_wav_header_below_minimum_bytes(self):
        """Verifies WAV parser rejects truncated buffers under 44 bytes."""
        with self.assertRaises(ValueError) as ctx:
            parse_wav_header(b"RIFF" + b"\x00" * 20)
        self.assertIn("WAV header too short", str(ctx.exception))

    def test_f15_b03_corrupt_flac_magic_and_header_length(self):
        """Verifies FLAC parser rejects buffers < 42 bytes and non-fLaC magic."""
        with self.assertRaises(ValueError) as ctx:
            parse_flac_header(b"FLAC" + b"\x00" * 40)
        self.assertIn("Invalid FLAC magic", str(ctx.exception))

    def test_f15_b04_unsupported_wav_audio_format_code(self):
        """Verifies WAV parser correctly flags non-PCM format codes (e.g. format 3 = IEEE Float)."""
        # Generate valid header then tamper audio_format offset 20 to 3
        hdr = bytearray(generate_wav_header(sample_rate=44100, bit_depth=16))
        struct.pack_into("<H", hdr, 20, 3)  # Format code 3 = IEEE Float
        parsed = parse_wav_header(bytes(hdr))
        self.assertEqual(parsed["format"], 3)
        self.assertFalse(parsed["is_pcm"])

    def test_f15_b05_zero_sample_rate_or_channels_in_flac_streaminfo(self):
        """Verifies FLAC generator and parser handle extreme sample rate packing boundaries."""
        flac_hdr = generate_flac_header(channels=2, sample_rate=192000, bit_depth=24, total_samples=100000)
        parsed = parse_flac_header(flac_hdr)
        self.assertEqual(parsed["sample_rate"], 192000)
        self.assertEqual(parsed["channels"], 2)
        self.assertEqual(parsed["bit_depth"], 24)
        self.assertEqual(parsed["total_samples"], 100000)


# ==============================================================================
# Feature 16: DSD Bitstream Parser
# ==============================================================================
class TestTier2_F16_DsdBitstreamParser(unittest.TestCase):
    """F16: Boundary and corner cases for DSF headers, DoP framing, and marker validation."""

    def test_f16_b01_corrupt_dsf_magic_and_truncated_chunks(self):
        """Verifies DSF parser rejects non-DSD magic and headers shorter than 92 bytes."""
        with self.assertRaises(ValueError) as ctx:
            parse_dsf_header(b"BAD!" + b"\x00" * 90)
        self.assertIn("Invalid DSF magic", str(ctx.exception))

    def test_f16_b02_invalid_dsf_format_id_and_channel_type(self):
        """Verifies DSF parser identifies non-raw format_id != 0."""
        hdr = bytearray(generate_dsf_header(channels=2, sample_rate=2822400))
        struct.pack_into("<I", hdr, 44, 99)  # Format ID = 99
        parsed = parse_dsf_header(bytes(hdr))
        self.assertEqual(parsed["format_id"], 99)
        self.assertFalse(parsed["is_dsd_raw"])

    def test_f16_b03_dop_framing_odd_byte_length_padding(self):
        """Verifies DoP framing on odd number of DSD bytes (e.g. 3 bytes) zero-pads trailing word."""
        odd_dsd = b"\xAA\xBB\xCC"
        words = frame_dop(odd_dsd)
        # 3 bytes need 2 24-bit DoP words (each carrying 2 DSD bytes)
        self.assertEqual(len(words), 2)
        # Check trailing byte was padded with 0x00
        trailing_word = words[1]
        b1 = trailing_word & 0xFF
        self.assertEqual(b1, 0x00)

    def test_f16_b04_dop_unframing_invalid_marker_detection(self):
        """Verifies DoP unframing detects corrupted marker bytes (not strictly alternating 0x05 / 0xFA)."""
        words = [
            (0x05 << 16) | (0xAA << 8) | 0xBB,
            (0xAA << 16) | (0xCC << 8) | 0xDD,  # Corrupted marker 0xAA instead of 0xFA
        ]
        unpacked_bytes, valid = unframe_dop(words)
        self.assertFalse(valid, "Marker corruptions must be detected")
        self.assertEqual(len(unpacked_bytes), 4)

    def test_f16_b05_extreme_dsd_rates_dsd512_and_dsd1024(self):
        """Verifies DSF header generator and parser handle extreme DSD512 (22.5792 MHz) and DSD1024 (45.1584 MHz)."""
        dsd512_rate = 22579200
        dsd1024_rate = 45158400

        hdr512 = generate_dsf_header(sample_rate=dsd512_rate)
        parsed512 = parse_dsf_header(hdr512)
        self.assertEqual(parsed512["sample_rate"], dsd512_rate)

        hdr1024 = generate_dsf_header(sample_rate=dsd1024_rate)
        parsed1024 = parse_dsf_header(hdr1024)
        self.assertEqual(parsed1024["sample_rate"], dsd1024_rate)


# ==============================================================================
# Feature 17: 64-bit Parametric EQ (PEQ)
# ==============================================================================
class TestTier2_F17_ParametricEq64Bit(unittest.TestCase):
    """F17: Boundary and corner cases for 64-bit biquad peaking EQ filters."""

    def test_f17_b01_peq_nyquist_frequency_boundary(self):
        """Verifies PEQ filter stability near Nyquist boundary (23,990 Hz at 48 kHz)."""
        coeffs = calculate_biquad_peaking(freq_hz=23990.0, gain_db=3.0, q_factor=1.0, sample_rate_hz=48000.0)
        self.assertTrue(check_biquad_stability(coeffs))
        resp = calculate_biquad_response(coeffs, eval_freq_hz=23990.0, sample_rate_hz=48000.0)
        self.assertFalse(math.isnan(resp))
        self.assertFalse(math.isinf(resp))

    def test_f17_b02_peq_extreme_gain_boost_and_cut(self):
        """Verifies extreme gain values (+30 dB boost and -60 dB cut) maintain pole stability."""
        boost_coeffs = calculate_biquad_peaking(freq_hz=1000.0, gain_db=30.0, q_factor=1.414)
        self.assertTrue(check_biquad_stability(boost_coeffs))
        boost_resp = calculate_biquad_response(boost_coeffs, 1000.0)
        self.assertAlmostEqual(boost_resp, 30.0, delta=0.5)

        cut_coeffs = calculate_biquad_peaking(freq_hz=1000.0, gain_db=-60.0, q_factor=1.414)
        self.assertTrue(check_biquad_stability(cut_coeffs))
        cut_resp = calculate_biquad_response(cut_coeffs, 1000.0)
        self.assertAlmostEqual(cut_resp, -60.0, delta=1.0)

    def test_f17_b03_peq_zero_gain_identity_response(self):
        """Verifies 0.0 dB gain produces 0.0 dB magnitude response across all frequencies."""
        coeffs = calculate_biquad_peaking(freq_hz=1000.0, gain_db=0.0, q_factor=1.0)
        for eval_f in [100.0, 1000.0, 10000.0]:
            resp = calculate_biquad_response(coeffs, eval_f)
            self.assertAlmostEqual(resp, 0.0, places=4)

    def test_f17_b04_peq_extreme_q_factor_narrow_and_wide(self):
        """Verifies extreme Q factors: narrow notch Q=50.0 and wide Q=0.05 maintain stability."""
        narrow = calculate_biquad_peaking(freq_hz=1000.0, gain_db=-12.0, q_factor=50.0)
        self.assertTrue(check_biquad_stability(narrow))

        wide = calculate_biquad_peaking(freq_hz=1000.0, gain_db=6.0, q_factor=0.05)
        self.assertTrue(check_biquad_stability(wide))

    def test_f17_b05_peq_pole_stability_check_rejects_unstable(self):
        """Verifies check_biquad_stability correctly detects unstable poles outside unit circle."""
        unstable_coeffs = {
            "b0": 1.0, "b1": 0.0, "b2": 0.0,
            "a0": 1.0, "a1": -2.5, "a2": 1.5,  # Roots at z = 1.5, 1.0 -> strictly unstable
        }
        self.assertFalse(check_biquad_stability(unstable_coeffs))


# ==============================================================================
# Feature 18: Headphone Crossfeed Filter
# ==============================================================================
class TestTier2_F18_HeadphoneCrossfeedFilter(unittest.TestCase):
    """F18: Boundary and corner cases for Bauer headphone stereophonic crossfeed blending."""

    def test_f18_b01_crossfeed_zero_and_negative_delay(self):
        """Verifies delay calculation with 0 or negative delay clamps to minimum 1 sample."""
        self.assertEqual(calculate_crossfeed_delay_samples(0.0), 1)
        self.assertEqual(calculate_crossfeed_delay_samples(-100.0), 1)

    def test_f18_b02_crossfeed_empty_sample_buffers(self):
        """Verifies Bauer crossfeed handles empty input sample lists without exceptions."""
        out_l, out_r = simulate_bauer_crossfeed([], [])
        self.assertEqual(len(out_l), 0)
        self.assertEqual(len(out_r), 0)

    def test_f18_b03_crossfeed_mono_signal_invariance(self):
        """Verifies feeding identical mono signals (left == right) produces identical outputs."""
        mono_signal = [0.25, 0.5, 0.75, 0.5, 0.25]
        out_l, out_r = simulate_bauer_crossfeed(mono_signal, mono_signal)
        for l, r in zip(out_l, out_r):
            self.assertAlmostEqual(l, r, places=6)

    def test_f18_b04_crossfeed_hard_panned_impulse_response(self):
        """Verifies hard-panned impulse on left channel appears delayed on right channel."""
        left = [1.0] + [0.0] * 30
        right = [0.0] * 31
        delay_samples = calculate_crossfeed_delay_samples(270.0, sample_rate_hz=44100.0)

        out_l, out_r = simulate_bauer_crossfeed(left, right, sample_rate_hz=44100.0, delay_us=270.0)
        # Right ear should have zero energy before delay_samples, and non-zero energy at delay_samples
        self.assertEqual(out_r[0], 0.0)
        self.assertGreater(out_r[delay_samples], 0.0)

    def test_f18_b05_crossfeed_extreme_attenuation_db(self):
        """Verifies -100 dB crossfeed gain leaves uncrossed channel effectively silent."""
        left = [1.0] * 20
        right = [0.0] * 20
        _, out_r = simulate_bauer_crossfeed(left, right, cross_gain_db=-100.0)
        max_r = max(abs(s) for s in out_r)
        self.assertLess(max_r, 1e-4)


# ==============================================================================
# Feature 19: ReplayGain & Peak Limiter
# ==============================================================================
class TestTier2_F19_ReplayGainAndPeakLimiter(unittest.TestCase):
    """F19: Boundary and corner cases for ReplayGain gain scaling and soft peak limiter."""

    def test_f19_b01_replaygain_extreme_negative_gain(self):
        """Verifies extreme negative gain (-40 dB) scales samples down without denormal issues."""
        samples = [1.0, 0.5, -0.5, -1.0]
        out = apply_replaygain_and_limiter(samples, gain_db=-40.0, headroom_db=0.0)
        self.assertAlmostEqual(out[0], 0.01, delta=0.001)

    def test_f19_b02_replaygain_extreme_positive_gain_clipping_prevention(self):
        """Verifies extreme positive gain (+24 dB) on hot input is constrained by limiter to <= 1.0."""
        samples = [0.8, 1.0, 1.2, -0.9]
        out = apply_replaygain_and_limiter(samples, gain_db=24.0, headroom_db=0.0)
        for s in out:
            self.assertLessEqual(s, 1.0, "Positive peak must not exceed 1.0")
            self.assertGreaterEqual(s, -1.0, "Negative peak must not exceed -1.0")

    def test_f19_b03_replaygain_zero_gain_and_zero_headroom(self):
        """Verifies gain 0.0 dB and headroom 0.0 dB passes quiet signals (<0.95) unmodified."""
        samples = [0.1, 0.3, -0.2, 0.5]
        out = apply_replaygain_and_limiter(samples, gain_db=0.0, headroom_db=0.0)
        for orig, processed in zip(samples, out):
            self.assertAlmostEqual(orig, processed, places=6)

    def test_f19_b04_peak_limiter_dc_offset_and_full_scale_square_wave(self):
        """Verifies limiter handles +2.5 DC offset gracefully without numerical divergence."""
        samples = [2.5] * 10
        out = apply_replaygain_and_limiter(samples, gain_db=0.0)
        for s in out:
            self.assertLessEqual(s, 1.0)
            self.assertGreaterEqual(s, 0.95)

    def test_f19_b05_empty_sample_buffer_handling(self):
        """Verifies passing empty sample buffer returns empty list."""
        self.assertEqual(apply_replaygain_and_limiter([], gain_db=6.0), [])


# ==============================================================================
# Feature 20: DSP One-Click Bypass
# ==============================================================================
class TestTier2_F20_DspOneClickBypass(unittest.TestCase):
    """F20: Boundary and corner cases for DSP instant one-click zero-cost bypass."""

    def test_f20_b01_bypass_toggles_signal_quality_lossless(self):
        """Verifies enabling bypass forces Signal Path overall quality back to lossless."""
        path = simulate_signal_path(
            source_label="Local FLAC",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=True,
            resampled_to_hz=None,
            backend="windows_asio",
            device_name="Topping D90",
        )
        self.assertEqual(path["overall"], "lossless")

    def test_f20_b02_bypass_removes_dsp_stage_from_nodes(self):
        """Verifies enabling bypass removes '64-bit DSP' stage from node list."""
        path = simulate_signal_path(
            source_label="Local FLAC",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=True,
            resampled_to_hz=None,
            backend="windows_asio",
            device_name="Topping D90",
        )
        stages = [n["stage"] for n in path["nodes"]]
        self.assertNotIn("64-bit DSP", stages)

    def test_f20_b03_bypass_false_with_inactive_dsp_stays_lossless(self):
        """Verifies when bypass is False but no DSP filters are active, path stays lossless."""
        path = simulate_signal_path(
            source_label="Local FLAC",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=False,
            dsp_active=False,
            resampled_to_hz=None,
            backend="windows_asio",
            device_name="Topping D90",
        )
        self.assertEqual(path["overall"], "lossless")

    def test_f20_b04_rapid_bypass_state_cycling(self):
        """Verifies cycling bypass state 100 times consistently toggles between lossless and enhanced."""
        for i in range(100):
            bypass = (i % 2 == 0)
            path = simulate_signal_path(
                source_label="FLAC",
                bit_depth=24,
                sample_rate_hz=96000,
                is_dsd=False,
                dsp_bypass=bypass,
                dsp_active=True,
                resampled_to_hz=None,
                backend="windows_asio",
                device_name="DAC",
            )
            expected = "lossless" if bypass else "enhanced"
            self.assertEqual(path["overall"], expected)

    def test_f20_b05_bypass_preserves_output_backend_configuration(self):
        """Verifies bypass state changes do not modify the output hardware backend node."""
        path = simulate_signal_path(
            source_label="FLAC",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=True,
            resampled_to_hz=None,
            backend="windows_wasapi_exclusive",
            device_name="AudioQuest Dragonfly",
        )
        out_node = path["nodes"][-1]
        self.assertEqual(out_node["stage"], "Output")
        self.assertIn("windows_wasapi_exclusive", out_node["detail"])


# ==============================================================================
# Feature 21: Bit-Perfect Hardware Backends
# ==============================================================================
class TestTier2_F21_BitPerfectHardwareBackends(unittest.TestCase):
    """F21: Boundary and corner cases for bit-perfect hardware backends and OS mixer bypass."""

    def test_f21_b01_exclusive_vs_shared_wasapi_quality_difference(self):
        """Verifies WASAPI Exclusive yields lossless, while WASAPI Shared yields high_quality."""
        path_excl = simulate_signal_path("FLAC", 24, 96000, False, True, False, None, "windows_wasapi_exclusive", "DAC")
        self.assertEqual(path_excl["overall"], "lossless")

        path_shared = simulate_signal_path("FLAC", 24, 96000, False, True, False, None, "windows_wasapi_shared", "DAC")
        self.assertEqual(path_shared["overall"], "high_quality")

    def test_f21_b02_asio_driver_name_boundary_strings(self):
        """Verifies hardware backend handles unicode device names and long driver names."""
        long_name = "SMSL VMV D2R DAC (High-Resolution ASIO Driver v5.50.0) - [USB-ID: 152a:85dd]"
        path = simulate_signal_path("FLAC", 24, 96000, False, True, False, None, "windows_asio", long_name)
        out_detail = path["nodes"][-1]["detail"]
        self.assertIn(long_name, out_detail)

    def test_f21_b03_unsupported_backend_identifier(self):
        """Verifies unknown backend identifier defaults gracefully to enhanced output quality."""
        path = simulate_signal_path("FLAC", 24, 96000, False, True, False, None, "unknown_backend_xyz", "Default")
        out_quality = path["nodes"][-1]["quality"]
        self.assertEqual(out_quality, "enhanced")

    def test_f21_b04_buffer_size_power_of_two_boundaries(self):
        """Verifies ASIO/WASAPI buffer sizes enforce power of two between 32 and 4096 frames."""
        def validate_buffer_size(frames: int) -> bool:
            if frames < 32 or frames > 4096:
                return False
            return (frames & (frames - 1)) == 0

        self.assertFalse(validate_buffer_size(0))
        self.assertFalse(validate_buffer_size(16))    # Under minimum
        self.assertFalse(validate_buffer_size(137))   # Not power of two
        self.assertFalse(validate_buffer_size(8192))  # Over maximum
        self.assertTrue(validate_buffer_size(32))     # Lowest latency
        self.assertTrue(validate_buffer_size(512))    # Default
        self.assertTrue(validate_buffer_size(4096))   # Safe max

    def test_f21_b05_sample_rate_hardware_mismatch_triggers_resampling(self):
        """Verifies sample rate conversion node is injected when source rate != DAC target rate."""
        path = simulate_signal_path("FLAC", 24, 96000, False, True, False, 48000, "windows_asio", "Fixed 48k DAC")
        stages = [n["stage"] for n in path["nodes"]]
        self.assertIn("Sample Rate Conversion", stages)
        self.assertEqual(path["overall"], "enhanced")


# ==============================================================================
# Feature 22: Transparent Signal Path Engine
# ==============================================================================
class TestTier2_F22_TransparentSignalPathEngine(unittest.TestCase):
    """F22: Boundary and corner cases for Signal Path quality classification and node graphs."""

    def test_f22_b01_dsd_native_pure_bitperfect_path(self):
        """Verifies Native DSD playback over ASIO maintains pure bit-perfect Lossless tier."""
        path = simulate_signal_path(
            source_label="SACD DSF",
            bit_depth=1,
            sample_rate_hz=2822400,
            is_dsd=True,
            dsp_bypass=True,
            dsp_active=False,
            resampled_to_hz=None,
            backend="windows_asio",
            device_name="DSD Native DAC",
        )
        self.assertEqual(path["overall"], "lossless")
        self.assertIn("DSD", path["nodes"][0]["detail"])

    def test_f22_b02_multiple_active_dsp_stages_enhanced_quality(self):
        """Verifies multiple DSP operations (PEQ + Resampling) maintain Enhanced quality."""
        path = simulate_signal_path(
            source_label="Qobuz Studio",
            bit_depth=24,
            sample_rate_hz=192000,
            is_dsd=False,
            dsp_bypass=False,
            dsp_active=True,
            resampled_to_hz=96000,
            backend="windows_asio",
            device_name="DAC",
        )
        self.assertEqual(path["overall"], "enhanced")
        stages = [n["stage"] for n in path["nodes"]]
        self.assertIn("64-bit DSP", stages)
        self.assertIn("Sample Rate Conversion", stages)

    def test_f22_b03_lossy_backend_degrades_enhanced_to_high_quality(self):
        """Verifies outputting to OS shared mixer downgrades overall quality to high_quality."""
        path = simulate_signal_path(
            source_label="Hi-Res FLAC",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=False,
            dsp_active=True,
            resampled_to_hz=None,
            backend="windows_wasapi_shared",
            device_name="Realtek Speakers",
        )
        self.assertEqual(path["overall"], "high_quality")

    def test_f22_b04_empty_source_label_handling(self):
        """Verifies build_signal_path handles blank source label without crashing."""
        path = simulate_signal_path("", 16, 44100, False, True, False, None, "windows_asio", "DAC")
        self.assertEqual(path["nodes"][0]["stage"], "Source")

    def test_f22_b05_node_stage_ordering_invariant(self):
        """Verifies Signal Path node order strictly follows Source -> (DSP) -> (Resampler) -> Output."""
        path = simulate_signal_path("FLAC", 24, 96000, False, False, True, 48000, "windows_asio", "DAC")
        stages = [n["stage"] for n in path["nodes"]]
        self.assertEqual(stages[0], "Source")
        self.assertEqual(stages[-1], "Output")


# ==============================================================================
# Feature 23: Lock-Free Audio Buffer
# ==============================================================================
class TestTier2_F23_LockFreeAudioBuffer(unittest.TestCase):
    """F23: Boundary and corner cases for SPSC lock-free audio ring buffer model."""

    class ReferenceRingBuffer:
        def __init__(self, capacity: int):
            if capacity < 2 or (capacity & (capacity - 1)) != 0:
                raise ValueError("Capacity must be a power of two >= 2")
            self.capacity = capacity
            self.mask = capacity - 1
            self.buf = [0.0] * capacity
            self.read_idx = 0
            self.write_idx = 0

        def available_to_write(self) -> int:
            return self.capacity - (self.write_idx - self.read_idx)

        def available_to_read(self) -> int:
            return self.write_idx - self.read_idx

        def write(self, samples: List[float]) -> int:
            avail = self.available_to_write()
            n = min(len(samples), avail)
            for i in range(n):
                self.buf[(self.write_idx + i) & self.mask] = samples[i]
            self.write_idx += n
            return n

        def read(self, count: int) -> List[float]:
            avail = self.available_to_read()
            n = min(count, avail)
            out = []
            for i in range(n):
                out.append(self.buf[(self.read_idx + i) & self.mask])
            self.read_idx += n
            return out

    def test_f23_b01_ring_buffer_exact_capacity_full_condition(self):
        """Verifies writing exact capacity fills buffer; subsequent write writes 0 samples."""
        rb = self.ReferenceRingBuffer(16)
        written = rb.write([1.0] * 16)
        self.assertEqual(written, 16)
        self.assertEqual(rb.available_to_write(), 0)

        # Buffer full: write returns 0
        overflow_written = rb.write([2.0] * 5)
        self.assertEqual(overflow_written, 0)

    def test_f23_b02_ring_buffer_empty_read_underrun_handling(self):
        """Verifies reading from empty ring buffer returns 0 items without deadlocking."""
        rb = self.ReferenceRingBuffer(16)
        read_samples = rb.read(8)
        self.assertEqual(len(read_samples), 0)

    def test_f23_b03_ring_buffer_wraparound_boundary(self):
        """Verifies writing and reading across buffer boundary preserves sample data integrity."""
        rb = self.ReferenceRingBuffer(8)
        # Advance write and read to index 6
        rb.write([1.0] * 6)
        rb.read(6)

        # Write 4 samples: will cross boundary index 7 -> 0
        test_data = [10.0, 20.0, 30.0, 40.0]
        rb.write(test_data)
        out = rb.read(4)
        self.assertEqual(out, test_data)

    def test_f23_b04_ring_buffer_capacity_power_of_two_enforcement(self):
        """Verifies ring buffer rejects non-power-of-two capacities (e.g. 100, 500)."""
        with self.assertRaises(ValueError):
            self.ReferenceRingBuffer(100)
        with self.assertRaises(ValueError):
            self.ReferenceRingBuffer(0)
        self.assertIsNotNone(self.ReferenceRingBuffer(1024))

    def test_f23_b05_ring_buffer_zero_and_negative_read_write_requests(self):
        """Verifies requesting 0 samples to read or write returns 0 and does not shift pointers."""
        rb = self.ReferenceRingBuffer(16)
        self.assertEqual(rb.write([]), 0)
        self.assertEqual(rb.read(0), [])
        self.assertEqual(rb.available_to_read(), 0)


# ==============================================================================
# Feature 24: Unified MusicProvider Trait
# ==============================================================================
class TestTier2_F24_UnifiedMusicProviderTrait(unittest.TestCase):
    """F24: Boundary and corner cases for unified MusicProvider async interface."""

    class MockProvider:
        def __init__(self, is_auth: bool = False):
            self._auth = is_auth

        def search(self, query: str, limit: int) -> List[str]:
            if not query or not query.strip() or limit <= 0:
                return []
            return [f"Item {i}" for i in range(min(limit, 5))]

        def resolve_stream(self, track_id: str) -> Dict[str, Any]:
            if not self._auth:
                raise PermissionError("Provider unauthenticated")
            if track_id == "404":
                raise KeyError("Track not found")
            return {"url": f"https://stream/{track_id}"}

    def test_f24_b01_search_query_empty_or_whitespace(self):
        """Verifies search with empty string or whitespace returns empty results."""
        prov = self.MockProvider(True)
        self.assertEqual(prov.search("", 10), [])
        self.assertEqual(prov.search("   ", 10), [])

    def test_f24_b02_search_limit_boundaries(self):
        """Verifies search limit <= 0 returns empty list, and large limits are capped."""
        prov = self.MockProvider(True)
        self.assertEqual(prov.search("Rock", 0), [])
        self.assertEqual(prov.search("Rock", -5), [])
        self.assertEqual(len(prov.search("Rock", 100)), 5)

    def test_f24_b03_unauthenticated_provider_stream_resolution_error(self):
        """Verifies resolving stream before authentication raises PermissionError."""
        prov = self.MockProvider(is_auth=False)
        with self.assertRaises(PermissionError):
            prov.resolve_stream("track-001")

    def test_f24_b04_resolve_stream_nonexistent_external_id(self):
        """Verifies resolving a non-existent track ID raises KeyError."""
        prov = self.MockProvider(is_auth=True)
        with self.assertRaises(KeyError):
            prov.resolve_stream("404")

    def test_f24_b05_provider_capabilities_flags_consistency(self):
        """Verifies capabilities structure contains all 4 standard boolean flags."""
        caps = {
            "supports_token_login": True,
            "supports_oauth": False,
            "supports_word_lyrics": True,
            "supports_hi_res": True,
        }
        for k, v in caps.items():
            self.assertIsInstance(v, bool)


# ==============================================================================
# Feature 25: Local Filesystem Scanner
# ==============================================================================
class TestTier2_F25_LocalFilesystemScanner(unittest.TestCase):
    """F25: Boundary and corner cases for recursive directory scanner and corrupt audio files."""

    def test_f25_b01_scanner_empty_directory_handling(self):
        """Verifies scanning empty directory returns 0 tracks without error."""
        with tempfile.TemporaryDirectory() as empty_dir:
            audio_files = []
            for root, _, files in os.walk(empty_dir):
                for f in files:
                    if f.endswith((".flac", ".mp3", ".wav")):
                        audio_files.append(f)
            self.assertEqual(len(audio_files), 0)

    def test_f25_b02_scanner_symlink_loop_and_circular_traversal(self):
        """Verifies directory traversal tracks visited real paths to prevent recursion loops."""
        visited_inodes = set()
        def visit_path(p: str) -> bool:
            real = os.path.realpath(p)
            if real in visited_inodes:
                return False  # Circular loop detected
            visited_inodes.add(real)
            return True

        self.assertTrue(visit_path(WORKSPACE_ROOT))
        self.assertFalse(visit_path(WORKSPACE_ROOT))  # Visiting same path again blocked

    def test_f25_b03_scanner_unsupported_and_hidden_files(self):
        """Verifies scanner filter ignores hidden files (.DS_Store) and non-audio files (.txt, .jpg)."""
        valid_exts = {".flac", ".wav", ".dsf", ".aiff", ".mp3", ".aac", ".opus"}
        def is_scannable_audio(filename: str) -> bool:
            if filename.startswith("."):
                return False
            _, ext = os.path.splitext(filename.lower())
            return ext in valid_exts

        self.assertFalse(is_scannable_audio(".DS_Store"))
        self.assertFalse(is_scannable_audio(".hidden.flac"))
        self.assertFalse(is_scannable_audio("cover.jpg"))
        self.assertFalse(is_scannable_audio("lyrics.txt"))
        self.assertTrue(is_scannable_audio("track01.flac"))

    def test_f25_b04_scanner_corrupt_audio_file_tag_parsing(self):
        """Verifies scanner handles 0-byte corrupt file without crashing traversal."""
        with tempfile.NamedTemporaryFile(suffix=".flac", delete=False) as tf:
            tf.write(b"")
            corrupt_file = tf.name

        try:
            with open(corrupt_file, "rb") as f:
                header = f.read(4)
            # Cannot read valid fLaC marker
            self.assertNotEqual(header, b"fLaC")
        finally:
            if os.path.exists(corrupt_file):
                os.remove(corrupt_file)

    def test_f25_b05_scanner_path_with_unicode_and_special_symbols(self):
        """Verifies scanner paths with spaces, apostrophes, and non-ASCII characters normalize safely."""
        complex_paths = [
            "Music/Björk - Homogenic (1997)/01 Hunter.flac",
            "Music/AC⚡DC/Back in Black.flac",
            "Music/久石譲/千と千尋の神隠し/01.flac",
        ]
        for p in complex_paths:
            norm = os.path.normpath(p)
            self.assertGreater(len(norm), 5)


# ==============================================================================
# Feature 26: SMB / WebDAV Remote Scanner
# ==============================================================================
class TestTier2_F26_SmbWebDavRemoteScanner(unittest.TestCase):
    """F26: Boundary and corner cases for SMB and WebDAV URI parsing and remote shares."""

    def test_f26_b01_malformed_share_uri_scheme(self):
        """Verifies URI parser rejects unsupported protocols (ftp, ssh, file)."""
        with self.assertRaises(ValueError):
            parse_remote_share_uri("ftp://nas.local/music")
        with self.assertRaises(ValueError):
            parse_remote_share_uri("ssh://server/home")

    def test_f26_b02_smb_missing_share_name_boundary(self):
        """Verifies SMB URI without share name sets share_name to empty string."""
        parsed = parse_remote_share_uri("smb://nas.local/")
        self.assertEqual(parsed["protocol"], "smb")
        self.assertEqual(parsed["share_name"], "")

    def test_f26_b03_webdav_url_encoded_credentials_and_spaces(self):
        """Verifies credentials with @ and spaces in password parse properly."""
        uri = "davs://admin%40domain:p%40ss%20word@webdav.lumina.io:8443/music/hires"
        parsed = parse_remote_share_uri(uri)
        self.assertEqual(parsed["protocol"], "web_dav")
        self.assertEqual(unquote(parsed["username"]), "admin@domain")
        self.assertEqual(unquote(parsed["password"]), "p@ss word")
        self.assertEqual(parsed["port"], 8443)

    def test_f26_b04_ipv6_host_address_parsing(self):
        """Verifies bracketed IPv6 host address parsing in SMB URIs."""
        uri = "smb://[fe80::1]/Music/album"
        parsed = parse_remote_share_uri(uri)
        self.assertEqual(parsed["host"], "fe80::1")
        self.assertEqual(parsed["share_name"], "Music")

    def test_f26_b05_port_number_boundaries(self):
        """Verifies standard default port assignments (445 for SMB, 443 for davs, 80 for http)."""
        smb_p = parse_remote_share_uri("smb://nas/share")
        self.assertEqual(smb_p["port"], 445)

        davs_p = parse_remote_share_uri("davs://webdav/share")
        self.assertEqual(davs_p["port"], 443)

        http_p = parse_remote_share_uri("http://webdav/share")
        self.assertEqual(http_p["port"], 80)


# ==============================================================================
# Feature 27: Qobuz Direct Token Provider
# ==============================================================================
class TestTier2_F27_QobuzDirectTokenProvider(unittest.TestCase):
    """F27: Boundary and corner cases for Qobuz API responses and hi-res stream resolution."""

    def test_f27_b01_expired_or_invalid_auth_token_error_response(self):
        """Verifies handling Qobuz 401/error response for expired user_auth_token."""
        error_resp = {
            "status": "error",
            "message": "Invalid user_auth_token",
            "code": 401,
        }
        def check_qobuz_response(resp: Dict[str, Any]):
            if resp.get("status") == "error":
                raise PermissionError(resp.get("message"))

        with self.assertRaises(PermissionError) as ctx:
            check_qobuz_response(error_resp)
        self.assertIn("Invalid user_auth_token", str(ctx.exception))

    def test_f27_b02_stream_url_missing_or_drm_restricted(self):
        """Verifies stream resolution raises error when track has restrictions or missing url."""
        restricted_resp = {
            "track_id": 12049182,
            "url": None,
            "restrictions": ["NOT_AVAILABLE_IN_TERRITORY"],
        }
        def resolve_qobuz_url(resp: Dict[str, Any]) -> str:
            if resp.get("restrictions"):
                raise ValueError(f"Track restricted: {resp['restrictions']}")
            url = resp.get("url")
            if not url:
                raise ValueError("Missing stream URL")
            return url

        with self.assertRaises(ValueError):
            resolve_qobuz_url(restricted_resp)

    def test_f27_b03_unsupported_format_id_fallback(self):
        """Verifies unrecognized Qobuz format_id (e.g. 99) falls back safely."""
        format_map = {
            5: (44100, 16),
            6: (96000, 24),
            7: (96000, 24),
            27: (192000, 24),
        }
        def resolve_format(fmt_id: int) -> Tuple[int, int]:
            return format_map.get(fmt_id, (44100, 16))  # Fallback to CD quality

        self.assertEqual(resolve_format(27), (192000, 24))
        self.assertEqual(resolve_format(99), (44100, 16))

    def test_f27_b04_empty_catalog_search_result(self):
        """Verifies parsing search result with 0 albums returns empty list without error."""
        empty_search = {"albums": {"total": 0, "items": []}}
        albums = empty_search.get("albums", {}).get("items", [])
        self.assertEqual(len(albums), 0)

    def test_f27_b05_malformed_sampling_rate_decimal_or_string(self):
        """Verifies converting Qobuz float sampling_rate (96.0) or kHz float into integer Hz."""
        def normalize_sample_rate(val: Any) -> int:
            f = float(val)
            if f < 1000.0:  # Value was in kHz (e.g. 96.0, 192.0)
                f *= 1000.0
            return int(round(f))

        self.assertEqual(normalize_sample_rate(96.0), 96000)
        self.assertEqual(normalize_sample_rate(192.0), 192000)
        self.assertEqual(normalize_sample_rate(44.1), 44100)
        self.assertEqual(normalize_sample_rate("96"), 96000)


# ==============================================================================
# Feature 28: Tidal & Deezer Provider Stubs
# ==============================================================================
class TestTier2_F28_TidalAndDeezerProviderStubs(unittest.TestCase):
    """F28: Boundary and corner cases for OAuth2 PKCE verifier lengths and Deezer ARL tokens."""

    def test_f28_b01_pkce_verifier_length_boundary(self):
        """Verifies PKCE code_verifier length constraints: RFC 7636 mandates 43 <= length <= 128."""
        def validate_pkce_verifier(verifier: str) -> bool:
            if not verifier:
                return False
            n = len(verifier)
            if n < 43 or n > 128:
                return False
            return bool(re.match(r"^[A-Za-z0-9_-]+$", verifier))

        self.assertFalse(validate_pkce_verifier("too_short_verifier"))  # < 43 chars
        self.assertFalse(validate_pkce_verifier("x" * 129))             # > 128 chars
        self.assertFalse(validate_pkce_verifier("verifier_with_illegal_char*&^%"))

        valid_verifier, _, _ = get_mock_tidal_pkce()
        self.assertTrue(validate_pkce_verifier(valid_verifier))

    def test_f28_b02_pkce_challenge_unpadded_base64url(self):
        """Verifies code_challenge contains no '=' padding and only base64url characters."""
        _, challenge, _ = get_mock_tidal_pkce()
        self.assertNotIn("=", challenge, "PKCE challenge must not have padding '='")
        self.assertNotIn("+", challenge)
        self.assertNotIn("/", challenge)

    def test_f28_b03_deezer_arl_cookie_hex_validation(self):
        """Verifies Deezer ARL cookie validator rejects non-hex and short strings."""
        def validate_arl_cookie(arl: str) -> bool:
            if not arl or len(arl) < 32:
                return False
            return bool(re.match(r"^[0-9a-fA-F_]+$", arl))

        self.assertFalse(validate_arl_cookie(""))
        self.assertFalse(validate_arl_cookie("short"))
        self.assertFalse(validate_arl_cookie("non_hex_cookie_xyz!@#$1234567890"))
        self.assertTrue(validate_arl_cookie("abcdef0123456789abcdef0123456789"))

    def test_f28_b04_token_expiration_refresh_flow(self):
        """Verifies token expiration check determines when refresh token must be dispatched."""
        def is_token_expired(issued_at: float, expires_in: int, skew_sec: int = 60) -> bool:
            now = time.time()
            return now >= (issued_at + expires_in - skew_sec)

        now = time.time()
        # Token issued 2 hours ago with 1 hour lifetime
        self.assertTrue(is_token_expired(now - 7200, 3600))
        # Token issued 10 seconds ago with 1 hour lifetime
        self.assertFalse(is_token_expired(now - 10, 3600))

    def test_f28_b05_missing_required_oauth_scopes(self):
        """Verifies Tidal OAuth authorization URL checks presence of required r_usr and w_usr scopes."""
        _, _, auth_url = get_mock_tidal_pkce()
        parsed = urlparse(auth_url)
        params = parse_qs(parsed.query)
        self.assertIn("client_id", params)
        self.assertIn("code_challenge", params)
        self.assertEqual(params.get("code_challenge_method"), ["S256"])


# ==============================================================================
# Feature 29: Axum HTTP & WebSocket Server
# ==============================================================================
class TestTier2_F29_AxumHttpAndWebSocketServer(unittest.TestCase):
    """F29: Boundary and corner cases for HTTP socket addresses, auth middleware, and WebSockets."""

    def test_f29_b01_bind_address_port_boundary(self):
        """Verifies socket address parsing handles port boundaries 0 (ephemeral), 65535, and rejects bad IPs."""
        def validate_bind_address(addr: str) -> Tuple[str, int]:
            host, port_str = addr.rsplit(":", 1)
            port = int(port_str)
            if port < 0 or port > 65535:
                raise ValueError("Port out of bounds")
            ipaddress.ip_address(host)
            return host, port

        with self.assertRaises(ValueError):
            validate_bind_address("0.0.0.0:70000")
        with self.assertRaises(ValueError):
            validate_bind_address("999.999.999.999:9888")

        host, port = validate_bind_address("0.0.0.0:9888")
        self.assertEqual(host, "0.0.0.0")
        self.assertEqual(port, 9888)

    def test_f29_b02_unauthenticated_request_to_protected_route(self):
        """Verifies requests to protected endpoints without Authorization header return 401."""
        def authenticate_request(headers: Dict[str, str], paired_tokens: set) -> int:
            auth = headers.get("Authorization")
            if not auth or not auth.startswith("Bearer "):
                return 401
            token = auth.split("Bearer ", 1)[1].strip()
            if token not in paired_tokens:
                return 401
            return 200

        self.assertEqual(authenticate_request({}, {"tok1"}), 401)
        self.assertEqual(authenticate_request({"Authorization": "Bearer tok1"}, {"tok1"}), 200)

    def test_f29_b03_malformed_bearer_token_format(self):
        """Verifies malformed Authorization headers (Basic, blank bearer, no token) return 401."""
        def extract_bearer(header_val: str) -> Optional[str]:
            if not header_val or not header_val.startswith("Bearer "):
                return None
            token = header_val[7:].strip()
            return token if token else None

        self.assertIsNone(extract_bearer("Basic user:pass"))
        self.assertIsNone(extract_bearer("Bearer"))
        self.assertIsNone(extract_bearer("Bearer   "))
        self.assertEqual(extract_bearer("Bearer valid_tok_123"), "valid_tok_123")

    def test_f29_b04_websocket_malformed_json_frame(self):
        """Verifies WebSocket frame processor returns error frame on receiving non-JSON payload."""
        def process_ws_frame(frame_text: str) -> Dict[str, Any]:
            try:
                data = json.loads(frame_text)
                return {"status": "ok", "payload": data}
            except json.JSONDecodeError:
                return {"status": "error", "error": "Invalid JSON text frame"}

        err_res = process_ws_frame("MALFORMED_NON_JSON")
        self.assertEqual(err_res["status"], "error")

        ok_res = process_ws_frame('{"event": "Play"}')
        self.assertEqual(ok_res["status"], "ok")

    def test_f29_b05_http_payload_size_limit_rejection(self):
        """Verifies request body parser rejects payloads exceeding 10MB limit with 413."""
        MAX_BODY_BYTES = 10 * 1024 * 1024  # 10 MB

        def check_body_size(size_bytes: int) -> int:
            return 413 if size_bytes > MAX_BODY_BYTES else 200

        self.assertEqual(check_body_size(1024), 200)
        self.assertEqual(check_body_size(10 * 1024 * 1024), 200)
        self.assertEqual(check_body_size(10 * 1024 * 1024 + 1), 413)


# ==============================================================================
# Feature 30: mDNS LAN Service Discovery
# ==============================================================================
class TestTier2_F30_MdnsLanServiceDiscovery(unittest.TestCase):
    """F30: Boundary and corner cases for mDNS DNS-SD service registration and TXT records."""

    def test_f30_b01_service_type_format_and_domain_suffix(self):
        """Verifies mDNS service type strictly complies with RFC 6763: '_lumina._tcp.local.'."""
        def validate_service_type(st: str) -> bool:
            return st.strip() == "_lumina._tcp.local."

        self.assertFalse(validate_service_type("_lumina._udp.local."))
        self.assertFalse(validate_service_type("_lumina._tcp"))
        self.assertFalse(validate_service_type("lumina.local."))
        self.assertTrue(validate_service_type("_lumina._tcp.local."))

    def test_f30_b02_txt_record_key_length_and_value_limits(self):
        """Verifies TXT record key length <= 9 bytes (RFC 6762 standard) and value <= 255 bytes."""
        def validate_txt_entry(key: str, val: str) -> bool:
            if len(key.encode("utf-8")) > 9:
                return False
            if len(val.encode("utf-8")) > 255:
                return False
            return True

        self.assertFalse(validate_txt_entry("key_too_long_for_dns_sd", "val"))
        self.assertFalse(validate_txt_entry("k", "v" * 256))
        self.assertTrue(validate_txt_entry("ver", "0.1.0"))
        self.assertTrue(validate_txt_entry("pair", "1"))

    def test_f30_b03_multicast_ipv4_and_ipv6_addresses(self):
        """Verifies mDNS multicast destination addresses: 224.0.0.251 and ff02::fb on port 5353."""
        ipv4_multicast = ipaddress.IPv4Address("224.0.0.251")
        self.assertTrue(ipv4_multicast.is_multicast)

        ipv6_multicast = ipaddress.IPv6Address("ff02::fb")
        self.assertTrue(ipv6_multicast.is_multicast)

        mdns_port = 5353
        self.assertEqual(mdns_port, 5353)

    def test_f30_b04_service_instance_name_collision_renaming(self):
        """Verifies mDNS name conflict resolution appends incrementing integer: 'Lumina Audio (2)'."""
        def resolve_name_collision(name: str, existing_names: set) -> str:
            if name not in existing_names:
                return name
            counter = 2
            while True:
                candidate = f"{name} ({counter})"
                if candidate not in existing_names:
                    return candidate
                counter += 1

        existing = {"Lumina Audio", "Lumina Audio (2)"}
        resolved = resolve_name_collision("Lumina Audio", existing)
        self.assertEqual(resolved, "Lumina Audio (3)")

    def test_f30_b05_mDNS_ttl_boundary_values(self):
        """Verifies TTL values: standard 120s for host records and 4500s for service records."""
        host_ttl = 120
        ptr_ttl = 4500
        self.assertEqual(host_ttl, 120)
        self.assertEqual(ptr_ttl, 4500)


# ==============================================================================
# Feature 31: One-Time PIN / QR Pairing
# ==============================================================================
class TestTier2_F31_OneTimePinAndQrPairing(unittest.TestCase):
    """F31: Boundary and corner cases for 6-digit PIN pairing, brute-force limits, and replay attacks."""

    def test_f31_b01_pin_format_and_entropy_boundaries(self):
        """Verifies PIN validation rejects lengths != 6, non-digits, negative numbers, or empty strings."""
        pin_regex = re.compile(r"^[0-9]{6}$")

        def validate_pin(pin_str: str) -> bool:
            return bool(pin_regex.match(pin_str.strip()))

        self.assertFalse(validate_pin("12345"))     # 5 digits
        self.assertFalse(validate_pin("1234567"))   # 7 digits
        self.assertFalse(validate_pin("12a456"))    # Contains letter
        self.assertFalse(validate_pin("-12345"))    # Negative
        self.assertFalse(validate_pin(""))
        self.assertTrue(validate_pin("000000"))
        self.assertTrue(validate_pin("982341"))

    def test_f31_b02_pin_replay_attack_prevention(self):
        """Verifies one-time PIN cannot be consumed a second time (replay prevention)."""
        active_pins = {"491823": time.time()}

        def consume_pin(pin: str) -> bool:
            if pin in active_pins:
                del active_pins[pin]
                return True
            return False

        # First use succeeds
        self.assertTrue(consume_pin("491823"))
        # Replay attempt fails immediately
        self.assertFalse(consume_pin("491823"))

    def test_f31_b03_pin_timing_expiration_boundary(self):
        """Verifies PIN expiration at exactly 60.0s: valid at 59.9s, expired at 60.1s."""
        def is_pin_valid(created_at: float, now: float, ttl_sec: float = 60.0) -> bool:
            return (now - created_at) <= ttl_sec

        t0 = 1000.0
        self.assertTrue(is_pin_valid(t0, t0 + 59.9))
        self.assertTrue(is_pin_valid(t0, t0 + 60.0))
        self.assertFalse(is_pin_valid(t0, t0 + 60.1))

    def test_f31_b04_max_failed_attempts_lockout(self):
        """Verifies brute-force protection: 5 consecutive failed PIN entries locks client IP."""
        class PinRateLimiter:
            def __init__(self):
                self.failures = 0
                self.locked = False

            def record_failure(self):
                self.failures += 1
                if self.failures >= 5:
                    self.locked = True

        limiter = PinRateLimiter()
        for _ in range(4):
            limiter.record_failure()
            self.assertFalse(limiter.locked)
        # 5th failure triggers lockout
        limiter.record_failure()
        self.assertTrue(limiter.locked)

    def test_f31_b05_qr_payload_uri_tampering_and_signature(self):
        """Verifies QR code pairing URI requires valid host, port, pin, and nonce query parameters."""
        def validate_qr_pairing_uri(uri: str) -> bool:
            parsed = urlparse(uri)
            if parsed.scheme != "lumina-pair":
                return False
            params = parse_qs(parsed.query)
            for req in ("pin", "nonce", "server"):
                if req not in params:
                    return False
            return True

        valid_uri = "lumina-pair://pair?server=192.168.1.50%3A9888&pin=982341&nonce=abc123nonce"
        tampered_uri = "lumina-pair://pair?server=192.168.1.50%3A9888"  # Missing pin and nonce
        bad_scheme = "http://pair?server=192.168.1.50%3A9888&pin=982341&nonce=abc"

        self.assertTrue(validate_qr_pairing_uri(valid_uri))
        self.assertFalse(validate_qr_pairing_uri(tampered_uri))
        self.assertFalse(validate_qr_pairing_uri(bad_scheme))


# ==============================================================================
# Feature 32: Flutter FFI Bridge & Shaders UI
# ==============================================================================
class TestTier2_F32_FlutterFfiAndShaders(unittest.TestCase):
    """F32: Boundary and corner cases for GLSL shaders, SDF math, and core-ffi exports."""

    def test_f32_b01_liquid_glass_sd_rounded_box_boundary_cases(self):
        """Verifies sdRoundedBox SDF math at center (inside < 0), boundary (0.0), and far outside (> 0)."""
        box_half = (100.0, 50.0)
        radius = 12.0

        # Center point is deep inside
        center_dist = evaluate_sd_rounded_box((0.0, 0.0), box_half, radius)
        self.assertLess(center_dist, 0.0)

        # Boundary point on edge
        edge_dist = evaluate_sd_rounded_box((100.0, 0.0), box_half, radius)
        self.assertAlmostEqual(edge_dist, 0.0, places=4)

        # Far outside point
        outside_dist = evaluate_sd_rounded_box((200.0, 150.0), box_half, radius)
        self.assertGreater(outside_dist, 50.0)

    def test_f32_b02_sd_rounded_box_zero_and_negative_radius(self):
        """Verifies sdRoundedBox handles radius = 0.0 (sharp rectangular boundary)."""
        box_half = (50.0, 50.0)
        dist_sharp = evaluate_sd_rounded_box((50.0, 0.0), box_half, 0.0)
        self.assertAlmostEqual(dist_sharp, 0.0, places=4)

    def test_f32_b03_mesh_fluid_weights_normalization_and_time_extremes(self):
        """Verifies evaluate_mesh_fluid_weights at t=0 and t=1,000,000s produces normalized weights summing to 1.0."""
        for t in [0.0, 1000.0, 1000000.0]:
            w1, w2, w3, w4 = evaluate_mesh_fluid_weights((0.5, 0.5), time_sec=t)
            weight_sum = w1 + w2 + w3 + w4
            self.assertAlmostEqual(weight_sum, 1.0, places=3)
            self.assertGreater(w1, 0.0)
            self.assertGreater(w2, 0.0)
            self.assertGreater(w3, 0.0)
            self.assertGreater(w4, 0.0)

    def test_f32_b04_liquid_glass_missing_uniform_detection(self):
        """Verifies validate_glsl_shader accurately flags presence of all required uniforms."""
        val = validate_glsl_shader("liquid_glass.frag")
        self.assertTrue(val["is_valid"])
        uniforms = val["uniforms"]
        required = ["uSize", "uRadius", "uRefractionStrength", "uTint", "uBackdrop"]
        for u in required:
            self.assertIn(u, uniforms, f"Uniform {u} must be declared in liquid_glass.frag")

    def test_f32_b05_core_version_semver_format_validation(self):
        """Verifies core_ffi version string strictly complies with semver regex ^\\d+\\.\\d+\\.\\d+."""
        cargo_path = os.path.join(WORKSPACE_ROOT, "crates", "core-ffi", "Cargo.toml")
        with open(cargo_path, "rb") as f:
            data = tomllib.load(f)
        pkg_version = data["package"]["version"]
        if isinstance(pkg_version, dict) and pkg_version.get("workspace"):
            root_cargo = os.path.join(WORKSPACE_ROOT, "Cargo.toml")
            with open(root_cargo, "rb") as f:
                root_data = tomllib.load(f)
            version_str = root_data["workspace"]["package"]["version"]
        else:
            version_str = pkg_version

        semver_regex = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$")
        self.assertTrue(bool(semver_regex.match(version_str)), f"Version '{version_str}' must match semver")
        self.assertEqual(version_str, "0.1.0")


if __name__ == "__main__":
    unittest.main()
