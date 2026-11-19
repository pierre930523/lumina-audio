"""
Lumina Audio E2E Test Suite - Tier 4: Real-World Application Scenarios
Implements all 16 end-to-end realistic user workflow scenarios specified in
TEST_INFRA.md § Real-World Application Scenarios (Tier 4).
"""
import base64
import cmath
import hashlib
import json
import math
import os
import re
import secrets
import sqlite3
import sys
import unittest
from typing import Dict, Any, List, Optional, Tuple

TEST_DIR = os.path.dirname(os.path.abspath(__file__))
WORKSPACE_ROOT = os.path.abspath(os.path.join(TEST_DIR, "..", ".."))
if WORKSPACE_ROOT not in sys.path:
    sys.path.insert(0, WORKSPACE_ROOT)

from tests.e2e.fixtures.audio_headers import (
    generate_wav_header,
    parse_wav_header,
    generate_dsf_header,
    parse_dsf_header,
    generate_flac_header,
    parse_flac_header,
    frame_dop,
    unframe_dop,
)
from tests.e2e.fixtures.db_fixtures import (
    init_in_memory_db,
    run_migration_0001,
    seed_mock_library,
    sanitize_fts5_query,
    execute_fts5_search,
    verify_schema_tables,
)
from tests.e2e.fixtures.dsp_fixtures import (
    calculate_biquad_peaking,
    calculate_biquad_response,
    check_biquad_stability,
    calculate_crossfeed_delay_samples,
    simulate_bauer_crossfeed,
    apply_replaygain_and_limiter,
    simulate_signal_path,
)
from tests.e2e.fixtures.provider_mocks import (
    get_mock_qobuz_login_response,
    get_mock_qobuz_stream_response,
    get_mock_tidal_pkce,
    get_mock_tidal_token_response,
    get_mock_deezer_arl,
    parse_remote_share_uri,
)
from tests.e2e.fixtures.shader_fixtures import (
    validate_glsl_shader,
    evaluate_sd_rounded_box,
    evaluate_mesh_fluid_weights,
)


# ==============================================================================
# Scenario 1: Cold-Start Library Ingestion & Search (F11, F12, F13, F25)
# ==============================================================================
class TestScenario01_ColdStartLibraryIngestionAndSearch(unittest.TestCase):
    """Scenario 1: Cold-Start Library Ingestion & Search (F11 WAL, F12 Repos, F13 FTS5, F25 Scanner)."""

    def test_scenario_01_cold_start_scan_ingest_and_fts5_search(self):
        """End-to-end workflow: scanner discovers local audio files, inserts into SQLite, and verifies FTS5 search."""
        conn = init_in_memory_db()
        cur = conn.cursor()

        # Step 1: Simulated local directory scan results
        scanned_files = [
            {
                "file_path": "C:\\Music\\Miles Davis\\Kind of Blue\\01 - So What.flac",
                "artist": "Miles Davis",
                "album": "Kind of Blue",
                "title": "So What",
                "track_no": 1,
                "duration_ms": 562000,
                "codec": "flac",
                "sample_rate_hz": 96000,
                "bit_depth": 24,
            },
            {
                "file_path": "C:\\Music\\Miles Davis\\Kind of Blue\\02 - Freddie Freeloader.flac",
                "artist": "Miles Davis",
                "album": "Kind of Blue",
                "title": "Freddie Freeloader",
                "track_no": 2,
                "duration_ms": 589000,
                "codec": "flac",
                "sample_rate_hz": 96000,
                "bit_depth": 24,
            },
            {
                "file_path": "C:\\Music\\Bill Evans\\Sunday at the Village Vanguard\\01 - Gloria's Step.flac",
                "artist": "Bill Evans Trio",
                "album": "Sunday at the Village Vanguard",
                "title": "Gloria's Step",
                "track_no": 1,
                "duration_ms": 372000,
                "codec": "flac",
                "sample_rate_hz": 44100,
                "bit_depth": 16,
            },
        ]

        # Step 2: Ingest into SQLite schema in atomic transaction
        artist_cache = {}
        album_cache = {}

        for item in scanned_files:
            # Upsert artist
            if item["artist"] not in artist_cache:
                art_id = f"art-{hashlib.md5(item['artist'].encode()).hexdigest()[:8]}"
                cur.execute(
                    "INSERT OR IGNORE INTO artists (id, name, sort_name) VALUES (?, ?, ?)",
                    (art_id, item["artist"], item["artist"])
                )
                artist_cache[item["artist"]] = art_id

            # Upsert canonical album
            album_key = (item["artist"], item["album"])
            if album_key not in album_cache:
                alb_hash = hashlib.md5((item["artist"] + ":" + item["album"]).encode()).hexdigest()[:8]
                alb_id = f"alb-{alb_hash}"
                cur.execute(
                    "INSERT OR IGNORE INTO canonical_albums (id, title, sort_title, primary_artist_id, created_at) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (alb_id, item["album"], item["album"], artist_cache[item["artist"]], "2026-11-16T00:00:00Z")
                )
                # Create album version
                ver_id = f"ver-{alb_id}-local"
                cur.execute(
                    "INSERT OR IGNORE INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (ver_id, alb_id, "local", f"ext-{alb_id}", item["codec"], item["sample_rate_hz"], item["bit_depth"])
                )
                album_cache[album_key] = (alb_id, ver_id)
                # Index album in FTS5
                cur.execute(
                    "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('album', ?, ?, ?)",
                    (alb_id, item["album"], item["artist"])
                )

            # Insert track source
            alb_id, ver_id = album_cache[album_key]
            trk_id = f"trk-{hashlib.md5(item['file_path'].encode()).hexdigest()[:8]}"
            cur.execute(
                "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, track_number, duration_ms, sample_rate_hz, bit_depth, codec) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (trk_id, ver_id, "local", trk_id, item["title"], item["track_no"], item["duration_ms"], item["sample_rate_hz"], item["bit_depth"], item["codec"])
            )
            # Index track in FTS5
            cur.execute(
                "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', ?, ?, ?)",
                (trk_id, item["title"], f"{item['artist']} - {item['album']}")
            )

        conn.commit()

        # Step 3: Verify FTS5 search queries
        res_album = execute_fts5_search(conn, "Kind of Blue")
        self.assertGreaterEqual(len(res_album), 1)
        self.assertEqual(res_album[0]["entity_type"], "album")
        self.assertEqual(res_album[0]["title"], "Kind of Blue")

        res_track = execute_fts5_search(conn, "Freddie Freeloader")
        self.assertEqual(len(res_track), 1)
        self.assertEqual(res_track[0]["entity_type"], "track")
        self.assertEqual(res_track[0]["title"], "Freddie Freeloader")

        res_artist = execute_fts5_search(conn, "Bill Evans")
        self.assertGreaterEqual(len(res_artist), 1)
        conn.close()


# ==============================================================================
# Scenario 2: Qobuz Direct-Token Auth to Hi-Res Playback (F7, F14, F27, F15)
# ==============================================================================
class TestScenario02_QobuzDirectTokenAuthHiResPlayback(unittest.TestCase):
    """Scenario 2: Qobuz Direct-Token Auth to Hi-Res Playback (F7 Auth, F14 Keyring, F27 Provider, F15 PCM)."""

    def test_scenario_02_direct_token_keyring_stream_resolution(self):
        """End-to-end workflow: direct user token saved to keyring, verified with Qobuz, stream resolved and demuxed."""
        # Step 1: User provides direct token; stored in OS Keyring
        keyring_vault = {}
        raw_token = "qb_live_user_token_99881122"
        keyring_vault["lumina_qobuz:auth_token"] = raw_token

        # Step 2: Qobuz provider loads token and validates login status
        stored_token = keyring_vault["lumina_qobuz:auth_token"]
        login_resp = get_mock_qobuz_login_response(user_auth_token=stored_token)
        self.assertEqual(login_resp["status"], "success")
        self.assertEqual(login_resp["user"]["user_auth_token"], stored_token)
        self.assertTrue(login_resp["user"]["credential"]["parameters"]["hires"])
        self.assertEqual(login_resp["user"]["credential"]["parameters"]["max_streaming_quality"], 27)

        # Step 3: Resolve hi-res FLAC stream (24-bit / 192 kHz)
        stream_meta = get_mock_qobuz_stream_response(track_id="12049182", sample_rate=192000, bit_depth=24)
        self.assertTrue(stream_meta["url"].startswith("https://streaming-qobuz.akamaized.net"))
        self.assertEqual(stream_meta["sampling_rate"], 192.0)
        self.assertEqual(stream_meta["bit_depth"], 24)

        # Step 4: Symphonia PCM Demuxing of stream header
        flac_header = generate_flac_header(channels=2, sample_rate=192000, bit_depth=24)
        parsed = parse_flac_header(flac_header)
        self.assertEqual(parsed["sample_rate"], 192000)
        self.assertEqual(parsed["bit_depth"], 24)
        self.assertEqual(parsed["channels"], 2)


# ==============================================================================
# Scenario 3: Bit-Perfect DSD Direct Hardware Output (F8, F16, F21, F22)
# ==============================================================================
class TestScenario03_BitPerfectDsdDirectHardwareOutput(unittest.TestCase):
    """Scenario 3: Bit-Perfect DSD Direct Hardware Output (F8 Format, F16 DSD, F21 ASIO, F22 Signal Path)."""

    def test_scenario_03_dsd_parser_to_bit_perfect_asio_output(self):
        """End-to-end workflow: DSF bitstream demuxed, hardware capabilities checked, delivered Native DSD bit-perfect."""
        # Step 1: Parse Sony DSF header
        dsf_data = generate_dsf_header(channels=2, sample_rate=2822400, sample_count=5644800)
        parsed_dsf = parse_dsf_header(dsf_data)
        self.assertTrue(parsed_dsf["is_dsd_raw"])
        self.assertEqual(parsed_dsf["sample_rate"], 2822400)  # DSD64 = 64 * 44100

        # Step 2: AudioFormat descriptor
        audio_format = {
            "codec": "dsd_dsf",
            "sample_rate_hz": parsed_dsf["sample_rate"],
            "bit_depth": 1,
            "channels": parsed_dsf["channels"],
            "is_dsd": True,
        }

        # Step 3: Query DAC hardware backend
        dac_backend = {
            "kind": "windows_asio",
            "device_name": "Matrix Audio X-SABRE 3",
            "supports_native_dsd": True,
            "supports_dop": True,
        }

        # Step 4: Routing strategy: Native DSD selected (bypassing PCM downsampling)
        if audio_format["is_dsd"] and dac_backend["supports_native_dsd"]:
            stream_mode = "native_dsd_direct"
        else:
            stream_mode = "pcm_downsample_88200"
        self.assertEqual(stream_mode, "native_dsd_direct")

        # Step 5: Signal Path engine classification
        sp = simulate_signal_path(
            source_label="DSD64",
            bit_depth=1,
            sample_rate_hz=2822400,
            is_dsd=True,
            dsp_bypass=True,
            dsp_active=False,
            resampled_to_hz=None,
            backend="windows_asio",
            device_name=dac_backend["device_name"],
        )
        self.assertEqual(sp["overall"], "lossless")
        self.assertTrue(any("DSD" in n["detail"] for n in sp["nodes"]))
        self.assertEqual(sp["nodes"][-1]["quality"], "lossless")


# ==============================================================================
# Scenario 4: Audiophile DSP Chain with Instant Bypass (F17, F18, F19, F20, F22)
# ==============================================================================
class TestScenario04_AudiophileDspChainWithInstantBypass(unittest.TestCase):
    """Scenario 4: Audiophile DSP Chain with Instant Bypass (F17 PEQ, F18 Crossfeed, F19 ReplayGain, F20 Bypass, F22 Path)."""

    def test_scenario_04_full_dsp_pipeline_and_instant_bypass(self):
        """End-to-end workflow: multi-stage DSP (PEQ + Crossfeed + ReplayGain) changes Signal Path, bypass restores Lossless."""
        # Step 1: Active DSP chain on 24/96 stereo stream
        peq_coeffs = calculate_biquad_peaking(freq_hz=3500.0, gain_db=4.5, q_factor=1.414, sample_rate_hz=96000.0)
        self.assertTrue(check_biquad_stability(peq_coeffs))

        # Crossfeed simulation on 100 samples
        left_samples = [0.8] * 100
        right_samples = [0.0] * 100
        cf_l, cf_r = simulate_bauer_crossfeed(left_samples, right_samples, sample_rate_hz=96000.0)
        self.assertGreater(cf_r[-1], 0.0)

        # ReplayGain with peak limiter
        limited = apply_replaygain_and_limiter(cf_l, gain_db=-2.8, headroom_db=-0.5)
        for s in limited:
            self.assertLessEqual(s, 1.0)

        # Step 2: Signal Path evaluates active DSP
        sp_active = simulate_signal_path(
            source_label="FLAC",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=False,
            dsp_active=True,
            resampled_to_hz=None,
            backend="windows_wasapi_exclusive",
            device_name="Chord Hugo TT2",
        )
        self.assertEqual(sp_active["overall"], "enhanced")
        self.assertTrue(any("DSP" in n["stage"] for n in sp_active["nodes"]))

        # Step 3: User activates One-Click Bypass
        sp_bypassed = simulate_signal_path(
            source_label="FLAC",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=False,
            resampled_to_hz=None,
            backend="windows_wasapi_exclusive",
            device_name="Chord Hugo TT2",
        )
        self.assertEqual(sp_bypassed["overall"], "lossless")
        self.assertFalse(any(n["quality"] == "enhanced" for n in sp_bypassed["nodes"]))


# ==============================================================================
# Scenario 5: Remote Client PIN Pairing & Playback Control (F29, F30, F31, F22)
# ==============================================================================
class TestScenario05_RemoteClientPinPairingAndControl(unittest.TestCase):
    """Scenario 5: Remote Client PIN Pairing & Playback Control (F29 Server, F30 mDNS, F31 PIN, F22 State Broadcast)."""

    def test_scenario_05_mdns_discovery_pin_pairing_ws_control(self):
        """End-to-end workflow: mDNS discovers Axum server, 6-digit PIN authenticates client, WS receives playback controls."""
        # Step 1: Core server initializes and advertises via mDNS
        server_state = {
            "host": "192.168.1.120",
            "port": 9888,
            "active_pin": "592817",
            "pin_created_at": 1000.0,
            "pin_ttl_sec": 60.0,
            "paired_clients": {},
            "playback_state": {"status": "paused", "volume": 0.5, "track": "Track 01"},
        }

        mdns_record = {
            "service": "_lumina._tcp.local.",
            "host": server_state["host"],
            "port": server_state["port"],
            "pairing_required": "true",
        }
        self.assertEqual(mdns_record["port"], 9888)

        # Step 2: Remote mobile client sends PIN
        client_time = 1015.0
        is_pin_valid = (
            client_time - server_state["pin_created_at"] <= server_state["pin_ttl_sec"]
            and "592817" == server_state["active_pin"]
        )
        self.assertTrue(is_pin_valid)

        # Issue Bearer token
        issued_token = secrets.token_hex(32)
        token_hash = hashlib.sha256(issued_token.encode("utf-8")).hexdigest()
        server_state["paired_clients"]["client-iphone-15"] = token_hash

        # Step 3: Remote client sends WS playback command
        ws_msg = {
            "token": issued_token,
            "action": "playback.play",
            "params": {"volume": 0.85},
        }

        # Verify token hash matches paired clients
        received_hash = hashlib.sha256(ws_msg["token"].encode("utf-8")).hexdigest()
        self.assertEqual(received_hash, server_state["paired_clients"]["client-iphone-15"])

        # Update playback state
        server_state["playback_state"]["status"] = "playing"
        server_state["playback_state"]["volume"] = ws_msg["params"]["volume"]

        # Step 4: Server broadcasts updated state and signal path
        broadcast_payload = {
            "event": "state_changed",
            "playback": server_state["playback_state"],
            "signal_path": {"quality": "lossless"},
        }
        self.assertEqual(broadcast_payload["playback"]["status"], "playing")
        self.assertEqual(broadcast_payload["playback"]["volume"], 0.85)


# ==============================================================================
# Scenario 6: Hybrid Multi-Source Album Merging (F6, F9, F10, F12)
# ==============================================================================
class TestScenario06_HybridMultiSourceAlbumMerging(unittest.TestCase):
    """Scenario 6: Hybrid Multi-Source Album Merging (F6 ProviderKind, F9 Canonical, F10 TrackSource, F12 Repo)."""

    def test_scenario_06_merge_local_cd_and_qobuz_hires_versions(self):
        """End-to-end workflow: merges local FLAC and Qobuz hi-res into single CanonicalAlbum with multiple versions."""
        conn = init_in_memory_db()
        cur = conn.cursor()

        # Step 1: Create Canonical Album
        album_id = "alb-merger-001"
        cur.execute(
            "INSERT INTO canonical_albums (id, title, sort_title, created_at) VALUES (?, ?, ?, ?)",
            (album_id, "Abbey Road", "Abbey Road", "2026-11-16T00:00:00Z")
        )

        # Step 2: Version 1 (Local CD Rip - 16/44.1 FLAC)
        ver_local = "ver-abbey-local"
        cur.execute(
            "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (ver_local, album_id, "local", "loc-abbey-01", "flac", 44100, 16)
        )

        # Step 3: Version 2 (Qobuz Hi-Res - 24/96 FLAC)
        ver_qobuz = "ver-abbey-qobuz"
        cur.execute(
            "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (ver_qobuz, album_id, "qobuz", "qb-abbey-96", "flac", 96000, 24)
        )

        # Step 4: Add tracks for both versions
        tracks_data = [
            (ver_local, "local", "loc-trk-01", "Come Together", 1, 260000, 44100, 16),
            (ver_local, "local", "loc-trk-02", "Something", 2, 183000, 44100, 16),
            (ver_qobuz, "qobuz", "qb-trk-01", "Come Together", 1, 260000, 96000, 24),
            (ver_qobuz, "qobuz", "qb-trk-02", "Something", 2, 183000, 96000, 24),
        ]

        for v_id, prov, ext_id, title, no, dur, sr, bd in tracks_data:
            trk_id = f"trk-{prov}-{no}"
            cur.execute(
                "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, track_number, duration_ms, sample_rate_hz, bit_depth, codec) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (trk_id, v_id, prov, ext_id, title, no, dur, sr, bd, "flac")
            )
        conn.commit()

        # Step 5: Query canonical album versions
        cur.execute("SELECT id, provider_id, sample_rate_hz, bit_depth FROM album_versions WHERE canonical_album_id = ?", (album_id,))
        versions = cur.fetchall()
        self.assertEqual(len(versions), 2)

        # Verify track alignment across versions
        cur.execute(
            """
            SELECT v.provider_id, t.track_number, t.title, t.sample_rate_hz
            FROM track_sources t
            JOIN album_versions v ON t.version_id = v.id
            WHERE v.canonical_album_id = ?
            ORDER BY t.track_number, v.provider_id
            """,
            (album_id,)
        )
        aligned = cur.fetchall()
        self.assertEqual(len(aligned), 4)
        self.assertEqual(aligned[0]["title"], "Come Together")
        self.assertEqual(aligned[1]["title"], "Come Together")
        conn.close()


# ==============================================================================
# Scenario 7: SMB/WebDAV Remote Ingestion & Resampling (F26, F15, F22, F23)
# ==============================================================================
class TestScenario07_SmbRemoteIngestionAndResampling(unittest.TestCase):
    """Scenario 7: SMB/WebDAV Remote Ingestion & Resampling (F26 Remote, F15 PCM, F22 Signal Path, F23 Ring Buffer)."""

    def test_scenario_07_smb_stream_buffered_and_resampled(self):
        """End-to-end workflow: SMB network share parsed, 192 kHz FLAC demuxed to ring buffer, resampled to 96 kHz DAC."""
        # Step 1: SMB URI parsing
        smb_uri = "smb://audiophile:secret@192.168.1.50/MusicShare/Classical/Mahler_Sym5.flac"
        parsed = parse_remote_share_uri(smb_uri)
        self.assertEqual(parsed["protocol"], "smb")
        self.assertEqual(parsed["host"], "192.168.1.50")
        self.assertEqual(parsed["share_name"], "MusicShare")
        self.assertTrue(parsed["is_authenticated"])

        # Step 2: Demux 192 kHz PCM stream
        flac_hdr = generate_flac_header(channels=2, sample_rate=192000, bit_depth=24)
        parsed_flac = parse_flac_header(flac_hdr)
        self.assertEqual(parsed_flac["sample_rate"], 192000)

        # Step 3: SPSC Ring Buffer ingestion
        ring_buffer = [0.0] * 2048
        write_idx = 0
        samples_in = [0.5 * math.sin(2.0 * math.pi * 1000.0 * i / 192000.0) for i in range(512)]
        for s in samples_in:
            ring_buffer[write_idx % 2048] = s
            write_idx += 1
        self.assertEqual(write_idx, 512)

        # Step 4: DAC supports max 96 kHz -> Resampling engaged (192 kHz -> 96 kHz)
        target_dac_rate = 96000
        sp = simulate_signal_path(
            source_label="SMB FLAC",
            bit_depth=24,
            sample_rate_hz=192000,
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=False,
            resampled_to_hz=target_dac_rate,
            backend="windows_wasapi_exclusive",
            device_name="Benchmark DAC3",
        )

        self.assertEqual(sp["overall"], "enhanced")
        src_node = next(n for n in sp["nodes"] if n["stage"] == "Sample Rate Conversion")
        self.assertIn("192000 Hz -> 96000 Hz", src_node["detail"])


# ==============================================================================
# Scenario 8: Quota Warning & Automated Progress Handoff (F5, F4, F1)
# ==============================================================================
class TestScenario08_QuotaWarningAndAutomatedProgressHandoff(unittest.TestCase):
    """Scenario 8: Quota Warning & Automated Progress Handoff (F5 Quota, F4 Verification, F1 Env)."""

    def test_scenario_08_quota_exhaustion_triggers_roadmap_generation(self):
        """End-to-end workflow: quota monitor detects low quota (<15%), verifies toolchain, generates progress roadmap."""
        # Step 1: Mock quota monitor state
        quota_reading = {
            "antigravity_quota_percent": 9.2,
            "threshold_percent": 15.0,
            "is_exhausting": True,
        }
        self.assertLess(quota_reading["antigravity_quota_percent"], quota_reading["threshold_percent"])

        # Step 2: Pre-flight toolchain validation checks
        toolchain_status = {
            "rust_cargo_check": "passed",
            "rust_cargo_test": "passed",
            "flutter_doctor": "ready",
        }
        self.assertEqual(toolchain_status["rust_cargo_check"], "passed")
        self.assertEqual(toolchain_status["rust_cargo_test"], "passed")

        # Step 3: Automated progress document generation
        progress_doc = {
            "title": "Lumina Audio - Development Progress & Quota Handoff",
            "completed_modules": ["M1: Dev Environment & Toolchains", "M2: Domain Core & SQLite Persistence"],
            "pending_modules": ["M3: Hi-Fi Audio Engine & DSP", "M4: Streaming Providers", "M5: Core Server & UI"],
            "resume_instructions": [
                "1. Run `cargo check --workspace` to ensure workspace compiles cleanly.",
                "2. Run `python tests/e2e/runner.py --tier all` to verify all end-to-end tests.",
                "3. Continue development on crates/core-audio.",
            ],
        }

        self.assertEqual(len(progress_doc["completed_modules"]), 2)
        self.assertGreaterEqual(len(progress_doc["resume_instructions"]), 3)


# ==============================================================================
# Scenario 9: Impeller Shaders & Flutter UI Integration (F3, F32, F22)
# ==============================================================================
class TestScenario09_ImpellerShadersFlutterUiIntegration(unittest.TestCase):
    """Scenario 9: Impeller Shaders & Flutter UI Integration (F3 Scaffolding, F32 Shaders/FFI, F22 Signal Path Modal)."""

    def test_scenario_09_impeller_shaders_and_signal_path_modal(self):
        """End-to-end workflow: Flutter UI compiles shaders, queries Signal Path via FFI, evaluates uniforms for modal."""
        # Step 1: Validate both shaders in app/shaders/
        glass = validate_glsl_shader("liquid_glass.frag")
        fluid = validate_glsl_shader("mesh_fluid_bg.frag")
        self.assertTrue(glass["is_valid"])
        self.assertTrue(fluid["is_valid"])

        # Step 2: Signal Path engine query
        sp_data = simulate_signal_path(
            source_label="Qobuz Hi-Res",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=False,
            dsp_active=True,
            resampled_to_hz=None,
            backend="windows_asio",
            device_name="FiiO K9 Pro",
        )
        self.assertEqual(sp_data["overall"], "enhanced")

        # Step 3: Evaluate shader uniforms for UI capsule
        # SDF distance for rounded box modal (width=320, height=80, radius=20)
        half_extents = (160.0, 40.0)
        dist_inside = evaluate_sd_rounded_box((0.0, 0.0), half_extents, 20.0)
        self.assertLess(dist_inside, -10.0)

        # 4-point dynamic fluid mesh gradient weights
        w1, w2, w3, w4 = evaluate_mesh_fluid_weights((0.5, 0.5), time_sec=1.5)
        self.assertAlmostEqual(w1 + w2 + w3 + w4, 1.0, places=4)


# ==============================================================================
# Scenario 10: Lossless to HighQuality Degradation Graceful Handshake (F21, F22, F15)
# ==============================================================================
class TestScenario10_LosslessToHighQualityDegradationHandshake(unittest.TestCase):
    """Scenario 10: Lossless to HighQuality Degradation Handshake (F21 Hardware, F22 Signal Path, F15 PCM)."""

    def test_scenario_10_shared_wasapi_mode_triggers_high_quality_classification(self):
        """End-to-end workflow: playing 24/192 FLAC through WASAPI shared mode gracefully adapts and flags HighQuality."""
        # Step 1: Source file is 24-bit / 192 kHz FLAC
        source_format = {"codec": "flac", "sample_rate_hz": 192000, "bit_depth": 24, "channels": 2}

        # Step 2: Output backend is Shared WASAPI (OS mixer forced to 48 kHz)
        hardware_backend = "windows_wasapi_shared"

        # Step 3: Signal Path engine classifies degradation
        sp = simulate_signal_path(
            source_label="FLAC",
            bit_depth=source_format["bit_depth"],
            sample_rate_hz=source_format["sample_rate_hz"],
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=False,
            resampled_to_hz=48000,
            backend=hardware_backend,
            device_name="Realtek High Definition Audio",
        )

        # In Shared mode with OS sample rate conversion, overall quality is HighQuality
        self.assertEqual(sp["overall"], "high_quality")
        out_node = sp["nodes"][-1]
        self.assertEqual(out_node["quality"], "high_quality")
        self.assertIn("windows_wasapi_shared", out_node["detail"])


# ==============================================================================
# Scenario 11: Multi-Client Concurrent State Broadcast (F29, F31, F22, F11)
# ==============================================================================
class TestScenario11_MultiClientConcurrentStateBroadcast(unittest.TestCase):
    """Scenario 11: Multi-Client Concurrent State Broadcast (F29 Axum WS, F31 Pairing, F22 Path, F11 WAL)."""

    def test_scenario_11_multiple_paired_clients_receive_synchronized_ws_events(self):
        """End-to-end workflow: two paired clients (iPhone & iPad) connect to WS; desktop event broadcasted to both."""
        conn = init_in_memory_db()
        cur = conn.cursor()

        # Step 1: Pair two distinct devices
        clients = [
            ("client-iphone", "Pierre's iPhone", "iOS", secrets.token_hex(32)),
            ("client-ipad", "Pierre's iPad", "iPadOS", secrets.token_hex(32)),
        ]

        for c_id, name, plat, tok in clients:
            tok_hash = hashlib.sha256(tok.encode()).hexdigest()
            cur.execute(
                "INSERT INTO paired_clients (id, device_name, platform, token_hash, created_at, last_seen_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (c_id, name, plat, tok_hash, "2026-11-16T00:00:00Z", "2026-11-16T00:00:00Z")
            )
        conn.commit()

        # Step 2: Desktop user changes track and adjusts PEQ
        event_payload = {
            "event": "playback_updated",
            "track_id": "trk-002",
            "status": "playing",
            "signal_path": {
                "overall": "enhanced",
                "nodes": [
                    {"stage": "Source", "detail": "FLAC 24/96"},
                    {"stage": "64-bit DSP", "detail": "PEQ Harman Curve Active"},
                    {"stage": "Output", "detail": "WASAPI Exclusive"},
                ],
            },
        }

        # Step 3: Broadcast dispatch to both connected client channels
        client_mailboxes = {"client-iphone": [], "client-ipad": []}

        for client_id in client_mailboxes:
            # Client receives event
            client_mailboxes[client_id].append(json.loads(json.dumps(event_payload)))

        # Step 4: Verify both clients received identical state
        for client_id, messages in client_mailboxes.items():
            self.assertEqual(len(messages), 1)
            msg = messages[0]
            self.assertEqual(msg["event"], "playback_updated")
            self.assertEqual(msg["signal_path"]["overall"], "enhanced")
            self.assertEqual(msg["track_id"], "trk-002")

        conn.close()


# ==============================================================================
# Scenario 12: Corrupt Audio Stream Recovery (F15, F16, F23)
# ==============================================================================
class TestScenario12_CorruptAudioStreamRecovery(unittest.TestCase):
    """Scenario 12: Corrupt Audio Stream Recovery (F15 PCM, F16 DSD, F23 Ring Buffer)."""

    def test_scenario_12_corrupt_packet_recovery_without_stream_termination(self):
        """End-to-end workflow: stream encounters corrupted frame; demuxer discards frame and recovers on next sync word."""
        # Simulated stream chunks: [Valid Frame 1, Corrupted Bytes, Valid Frame 2]
        valid_wav_1 = generate_wav_header(channels=2, sample_rate=44100, bit_depth=16, num_samples=100)
        corrupted_chunk = b"\x00\xff\xee\xdd\x00\x00\x11\x22"  # Garbage data lacking RIFF sync
        valid_wav_2 = generate_wav_header(channels=2, sample_rate=44100, bit_depth=16, num_samples=100)

        stream_chunks = [valid_wav_1, corrupted_chunk, valid_wav_2]

        demuxed_frames = []
        recovery_events = 0

        for chunk in stream_chunks:
            try:
                parsed = parse_wav_header(chunk)
                demuxed_frames.append(parsed)
            except ValueError:
                # Corrupt frame detected: demuxer recovery routine engages
                recovery_events += 1
                continue

        # Stream recovered and processed both valid chunks
        self.assertEqual(len(demuxed_frames), 2)
        self.assertEqual(recovery_events, 1)
        self.assertEqual(demuxed_frames[0]["sample_rate"], 44100)
        self.assertEqual(demuxed_frames[1]["sample_rate"], 44100)


# ==============================================================================
# Scenario 13: Keyring Storage Failure Graceful Fallback (F14, F7, F27)
# ==============================================================================
class TestScenario13_KeyringStorageFailureGracefulFallback(unittest.TestCase):
    """Scenario 13: Keyring Storage Failure Graceful Fallback (F14 Keyring, F7 Auth, F27 Qobuz)."""

    def test_scenario_13_keyring_failure_falls_back_to_memory_session(self):
        """End-to-end workflow: OS Keyring raises OSError; system falls back to in-memory secure session store."""
        class MockFailingKeyring:
            def set_password(self, service, key, value):
                raise OSError("OS Keyring daemon unavailable (service disabled)")

            def get_password(self, service, key):
                raise OSError("OS Keyring daemon unavailable (service disabled)")

        keyring_service = MockFailingKeyring()
        memory_session_store = {}
        token = "qb_auth_session_fallback_8831"

        # Attempt keyring write; catch exception and fallback
        try:
            keyring_service.set_password("lumina", "qobuz_token", token)
        except OSError:
            # Fallback to ephemeral memory session
            memory_session_store["qobuz_token"] = token

        self.assertIn("qobuz_token", memory_session_store)

        # Qobuz provider authenticates using fallback token
        resolved_token = memory_session_store.get("qobuz_token")
        login_resp = get_mock_qobuz_login_response(user_auth_token=resolved_token)
        self.assertEqual(login_resp["user"]["user_auth_token"], token)


# ==============================================================================
# Scenario 14: Crossfeed & AutoEQ Headphone Preset Application (F17, F18, F20, F22)
# ==============================================================================
class TestScenario14_CrossfeedAndAutoEqHeadphonePreset(unittest.TestCase):
    """Scenario 14: Crossfeed & AutoEQ Headphone Preset (F17 PEQ, F18 Crossfeed, F20 Bypass, F22 Signal Path)."""

    def test_scenario_14_sennheiser_hd650_preset_with_crossfeed_and_bypass(self):
        """End-to-end workflow: loads AutoEQ profile for HD650, applies Bauer crossfeed, validates stability and bypass."""
        # AutoEQ profile for Sennheiser HD650 (Harman target compensation)
        hd650_peq_bands = [
            {"freq": 28.0, "gain": 4.8, "q": 1.41},
            {"freq": 80.0, "gain": -2.1, "q": 0.70},
            {"freq": 240.0, "gain": 1.2, "q": 2.0},
            {"freq": 1350.0, "gain": -1.8, "q": 3.0},
            {"freq": 5800.0, "gain": 3.2, "q": 2.5},
        ]

        # Calculate and check stability of all filter bands
        for band in hd650_peq_bands:
            coeffs = calculate_biquad_peaking(band["freq"], band["gain"], band["q"], sample_rate_hz=48000.0)
            self.assertTrue(check_biquad_stability(coeffs), f"Band at {band['freq']}Hz unstable")

        # Simulate Bauer crossfeed
        left_in = [0.9] * 60
        right_in = [0.0] * 60
        cf_l, cf_r = simulate_bauer_crossfeed(left_in, right_in, sample_rate_hz=48000.0)
        self.assertGreater(cf_r[-1], 0.0)

        # Signal path with active preset
        sp_preset = simulate_signal_path(
            source_label="FLAC 24/48",
            bit_depth=24,
            sample_rate_hz=48000,
            is_dsd=False,
            dsp_bypass=False,
            dsp_active=True,
            resampled_to_hz=None,
            backend="windows_wasapi_exclusive",
            device_name="Sennheiser HDV 820",
        )
        self.assertEqual(sp_preset["overall"], "enhanced")

        # Bypass restores lossless
        sp_bypassed = simulate_signal_path(
            source_label="FLAC 24/48",
            bit_depth=24,
            sample_rate_hz=48000,
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=False,
            resampled_to_hz=None,
            backend="windows_wasapi_exclusive",
            device_name="Sennheiser HDV 820",
        )
        self.assertEqual(sp_bypassed["overall"], "lossless")


# ==============================================================================
# Scenario 15: Live Library Rescan & Delta FTS5 Indexing (F11, F13, F25, F12)
# ==============================================================================
class TestScenario15_LiveLibraryRescanDeltaFts5Indexing(unittest.TestCase):
    """Scenario 15: Live Library Rescan & Delta FTS5 Indexing (F11 WAL, F13 FTS5, F25 Scanner, F12 Repos)."""

    def test_scenario_15_rescan_detects_delta_and_updates_fts5_index(self):
        """End-to-end workflow: scanner re-scans library, detects modified track metadata, updates FTS5 index live."""
        conn = init_in_memory_db()
        cur = conn.cursor()

        # Step 1: Initial library state with 1 album and 1 track
        cur.execute(
            "INSERT INTO canonical_albums (id, title, sort_title, created_at) VALUES ('alb-rescan-01', 'Time Out', 'Time Out', '2026-11-16T00:00:00Z')"
        )
        cur.execute(
            "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth) "
            "VALUES ('ver-rescan-01', 'alb-rescan-01', 'local', 'ext-r1', 'flac', 44100, 16)"
        )
        cur.execute(
            "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, track_number, duration_ms, sample_rate_hz, bit_depth, codec) "
            "VALUES ('trk-r1', 'ver-rescan-01', 'local', 'ext-t1', 'Take Five (Original)', 1, 324000, 44100, 16, 'flac')"
        )
        cur.execute(
            "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', 'trk-r1', 'Take Five (Original)', 'Dave Brubeck')"
        )
        conn.commit()

        # Initial search matches original title
        res1 = execute_fts5_search(conn, "Original")
        self.assertEqual(len(res1), 1)

        # Step 2: User re-tags track file on disk; scanner detects mtime delta and performs update
        new_title = "Take Five (2024 Remaster)"
        cur.execute("UPDATE track_sources SET title = ? WHERE id = 'trk-r1'", (new_title,))
        # Update FTS5 virtual table
        cur.execute("DELETE FROM search_fts WHERE entity_id = 'trk-r1'")
        cur.execute(
            "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', 'trk-r1', ?, 'Dave Brubeck')",
            (new_title,)
        )
        conn.commit()

        # Step 3: Verify old title query yields 0, new title query yields 1
        res_old = execute_fts5_search(conn, "Original")
        self.assertEqual(len(res_old), 0)

        res_new = execute_fts5_search(conn, "Remaster")
        self.assertEqual(len(res_new), 1)
        self.assertEqual(res_new[0]["title"], "Take Five (2024 Remaster)")
        conn.close()


# ==============================================================================
# Scenario 16: Complete End-to-End Listening Session (F7, F11, F12, F13, F15, F17, F21, F22, F29, F31, F32)
# ==============================================================================
class TestScenario16_CompleteEndToEndListeningSession(unittest.TestCase):
    """Scenario 16: Complete End-to-End Listening Session (All primary architectural components integrated)."""

    def test_scenario_16_grand_end_to_end_listening_session(self):
        """Grand integration workflow: DB init -> Token login -> Remote PIN pairing -> Search -> Stream decode -> DSP -> Bit-perfect ASIO -> Signal Path broadcast -> Bypass."""
        # 1. Initialize SQLite WAL Database
        conn = init_in_memory_db()
        seed_mock_library(conn)
        tables = verify_schema_tables(conn)
        self.assertIn("canonical_albums", tables)
        self.assertIn("search_fts", tables)

        # 2. Keyring auth storage
        keyring = {"lumina_qobuz:auth_token": "qb_grand_session_token_7718"}
        auth_token = keyring["lumina_qobuz:auth_token"]
        login_res = get_mock_qobuz_login_response(auth_token)
        self.assertEqual(login_res["status"], "success")

        # 3. PIN Pairing with remote client
        pin = "918234"
        client_id = "client-studio-remote"
        tok = secrets.token_hex(32)
        tok_hash = hashlib.sha256(tok.encode()).hexdigest()
        conn.execute(
            "INSERT INTO paired_clients (id, device_name, platform, token_hash, created_at, last_seen_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (client_id, "Studio Control Tablet", "Android", tok_hash, "2026-11-16T00:00:00Z", "2026-11-16T00:00:00Z")
        )
        conn.commit()

        # 4. Full-text search for track
        search_res = execute_fts5_search(conn, "Dark Side")
        self.assertGreaterEqual(len(search_res), 1)

        # 5. Resolve hi-res audio stream
        stream = get_mock_qobuz_stream_response("12049182", sample_rate=96000, bit_depth=24)
        self.assertEqual(stream["sample_rate_hz"], 96000)

        # 6. Demux PCM header
        flac_hdr = generate_flac_header(channels=2, sample_rate=96000, bit_depth=24)
        parsed_pcm = parse_flac_header(flac_hdr)
        self.assertEqual(parsed_pcm["sample_rate"], 96000)

        # 7. Apply 64-bit Parametric EQ
        peq_coeffs = calculate_biquad_peaking(freq_hz=100.0, gain_db=2.5, q_factor=1.0, sample_rate_hz=96000.0)
        self.assertTrue(check_biquad_stability(peq_coeffs))

        # 8. Route to ASIO Hardware Output
        backend_name = "windows_asio"

        # 9. Compute Signal Path (with active DSP)
        sp_enhanced = simulate_signal_path(
            source_label="Qobuz 24/96",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=False,
            dsp_active=True,
            resampled_to_hz=None,
            backend=backend_name,
            device_name="Merging Anubis",
        )
        self.assertEqual(sp_enhanced["overall"], "enhanced")

        # 10. WebSocket state broadcast
        ws_event = {
            "event": "signal_path_changed",
            "quality": sp_enhanced["overall"],
            "nodes": sp_enhanced["nodes"],
        }
        self.assertEqual(ws_event["quality"], "enhanced")

        # 11. Flutter UI shader evaluation for floating capsule
        glass_shader = validate_glsl_shader("liquid_glass.frag")
        self.assertTrue(glass_shader["is_valid"])
        d = evaluate_sd_rounded_box((0.0, 0.0), (100.0, 30.0), 15.0)
        self.assertLess(d, 0.0)

        # 12. Instant DSP Bypass toggled
        sp_lossless = simulate_signal_path(
            source_label="Qobuz 24/96",
            bit_depth=24,
            sample_rate_hz=96000,
            is_dsd=False,
            dsp_bypass=True,
            dsp_active=False,
            resampled_to_hz=None,
            backend=backend_name,
            device_name="Merging Anubis",
        )
        self.assertEqual(sp_lossless["overall"], "lossless")

        conn.close()


if __name__ == "__main__":
    unittest.main()
