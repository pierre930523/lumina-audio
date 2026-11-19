"""
Lumina Audio E2E Test Suite - Tier 4 R1-R3 (Real-World Scenarios S17 to S26)
End-to-end application workflows executing real compiled artifacts across Rust FFI,
Axum REST/WS, Flutter/Dart verification, and all loopback mock servers.
"""
import json
import os
import shutil
import socket
import subprocess
import time
import unittest
from typing import Any, Dict

import httpx
from websockets.sync.client import connect as ws_sync_connect

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_OK,
    LuminaFfiClient,
    LuminaLiveServer,
    OPTIONAL_M7_M10_SIGNATURES,
    _WORKSPACE_ROOT,
)
from tests.e2e.fixtures.mock_servers import (
    AirPlayMockServer,
    ClockSyncMockServer,
    DiscogsMockServer,
    DlnaMediaRendererMock,
    MdnsLoopbackMock,
    MusicBrainzMockServer,
    StreamingAudioMockServer,
    WanTlsProxyMockServer,
)
from tests.e2e.fixtures.net_helpers import ManagedTempDir, generate_flac_file
from tests.e2e.fixtures.server_fixtures import validate_qr_pairing_uri


class TestScenario17(unittest.TestCase):
    """S17: Cross-Source Library Ingest, Deduplication & Credit Graph Enrichment"""

    def test_s17_cross_source_ingest_dedup_and_enrichment(self):
        with (
            ManagedTempDir(prefix="lumina_s17_") as tmp,
            MusicBrainzMockServer() as mb,
            DiscogsMockServer() as dg,
        ):
            music_dir = tmp / "music"
            generate_flac_file(
                music_dir / "Pink Floyd" / "Dark Side (24-96)" / "01 - Time.flac",
                sample_rate=96000,
                bit_depth=24,
                duration_ms=500,
                title="Time",
                artist="Pink Floyd",
                album="The Dark Side of the Moon",
                album_artist="Pink Floyd",
                isrc="GBAYE0300592",
            )
            with LuminaLiveServer(db_path=tmp / "s17.db", scan_dir=music_dir) as srv:
                tok = srv.pair(device_name="S17-Desktop")
                ded = srv.request("POST", "/api/v1/library/deduplicate", token=tok)
                self.assertEqual(ded.status_code, 200)
                enr = srv.request(
                    "POST",
                    "/api/v1/library/enrich",
                    token=tok,
                    json={"musicbrainz_base_url": f"{mb.base_url}/ws/2", "discogs_base_url": dg.base_url, "discogs_token": "e2e_dg_tok", "force_refresh": True},
                )
                self.assertEqual(enr.status_code, 200)
                self.assertGreater(enr.json()["credits_added"], 0)
                albs = srv.request("GET", "/api/v1/library/albums", token=tok).json()
                credits = srv.request("GET", f"/api/v1/library/albums/{albs[0]['id']}/credits", token=tok).json()
                self.assertGreater(len(credits), 0)
                art = srv.request("GET", f"/api/v1/library/artists/{credits[0]['artist_id']}", token=tok)
                self.assertEqual(art.status_code, 200)


class TestScenario18(unittest.TestCase):
    """S18: Range-Buffered HTTP FLAC Streaming with ReplayGain & 10-Band PEQ/Crossfeed"""

    def test_s18_http_stream_replaygain_peq_crossfeed(self):
        with (
            ManagedTempDir(prefix="lumina_s18_") as tmp,
            StreamingAudioMockServer() as ss,
        ):
            with LuminaLiveServer(db_path=tmp / "s18.db") as srv:
                tok = srv.pair(device_name="S18-DSP")
                autoeq = srv.request(
                    "POST",
                    "/api/v1/dsp/autoeq",
                    token=tok,
                    json={"text": "Preamp: -4.0 dB\nFilter 1: ON PK Fc 125 Hz Gain 3.0 dB Q 0.8\n", "apply": True},
                )
                self.assertEqual(autoeq.status_code, 200)
                cfg = srv.request("GET", "/api/v1/dsp/config", token=tok).json()
                cfg["crossfeed"]["enabled"] = True
                cfg["replay_gain"]["mode"] = "track"
                srv.request("PUT", "/api/v1/dsp/config", token=tok, json=cfg)

                play = srv.request(
                    "POST",
                    "/api/v1/playback/play",
                    token=tok,
                    json={"stream_url": f"{ss.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a", "source": "Qobuz", "hint_extension": "flac"},
                )
                self.assertEqual(play.status_code, 200)
                sp = srv.request("GET", "/api/v1/signal-path", token=tok).json()
                self.assertEqual(sp.get("quality") or sp.get("overall_quality"), "enhanced")
                srv.request("POST", "/api/v1/playback/stop", token=tok)


class TestScenario19(unittest.TestCase):
    """S19: Multi-Profile Switching with Independent Favorites, History & Signal Path"""

    def test_s19_multi_profile_favorites_history_isolation(self):
        with ManagedTempDir(prefix="lumina_s19_") as tmp:
            music_dir = tmp / "music"
            generate_flac_file(
                music_dir / "Artist" / "Album" / "01 - Track.flac",
                duration_ms=400,
                title="TrackOne",
                artist="Artist",
                album="Album",
            )
            with LuminaLiveServer(db_path=tmp / "s19.db", scan_dir=music_dir) as srv:
                tok = srv.pair(device_name="S19-Profiles")
                p1 = srv.request("POST", "/api/v1/profiles", token=tok, json={"name": "Daytime"}).json()
                p2 = srv.request("POST", "/api/v1/profiles", token=tok, json={"name": "Midnight"}).json()
                tracks = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                tid = tracks[0]["id"]

                srv.request("POST", f"/api/v1/profiles/{p1['id']}/activate", token=tok)
                srv.request("POST", f"/api/v1/profiles/{p1['id']}/favorites", token=tok, json={"item_type": "track", "item_id": tid})
                srv.request("POST", f"/api/v1/profiles/{p2['id']}/activate", token=tok)
                srv.request("POST", f"/api/v1/profiles/{p2['id']}/history", token=tok, json={"track_source_id": tid, "duration_listened_ms": 1200})

                favs1 = srv.request("GET", f"/api/v1/profiles/{p1['id']}/favorites", token=tok).json()
                favs2 = srv.request("GET", f"/api/v1/profiles/{p2['id']}/favorites", token=tok).json()
                self.assertEqual(len(favs1), 1)
                self.assertEqual(len(favs2), 0)
                hist2 = srv.request("GET", f"/api/v1/profiles/{p2['id']}/history", token=tok).json()
                self.assertEqual(len(hist2), 1)


class TestScenario20(unittest.TestCase):
    """S20: Desktop Flutter UI & FFI Bridge Artifact Verification"""

    def test_s20_desktop_flutter_ui_and_ffi_contracts(self):
        client = LuminaFfiClient()
        for sym in OPTIONAL_M7_M10_SIGNATURES:
            self.assertTrue(client.has_symbol(sym))
        ui_test_file = _WORKSPACE_ROOT / "app/test/m8_m9_m10_ui_and_remote_test.dart"
        content = ui_test_file.read_text(encoding="utf-8")
        for marker in (
            "Desktop UI: Albums/Versions switcher, Credits Graph, DSP panel, Zones, Providers, Remote & Profiles",
            "Live ServerAudioService pairs via PIN, syncs WebSocket & controls embedded Rust FFI server",
        ):
            self.assertIn(marker, content)


class TestScenario21(unittest.TestCase):
    """S21: Mobile Remote Dual-Mode: mDNS Discovery -> PIN/QR Pair -> WS Control & Live Sync"""

    def test_s21_mdns_qr_pair_and_dual_client_ws_sync(self):
        with ManagedTempDir(prefix="lumina_s21_") as tmp:
            with LuminaLiveServer(db_path=tmp / "s21.db") as srv:
                with MdnsLoopbackMock(hostname="Lumina-Host", service_port=srv.port) as mdns:
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                        s.settimeout(2.0)
                        s.sendto(MdnsLoopbackMock.build_ptr_query(), (mdns.host, mdns.port))
                        parsed = MdnsLoopbackMock.parse_dns_sd_packet(s.recvfrom(4096)[0])
                    port = parsed["srv"]["port"]
                    init_d = srv.pair_initiate(device_name="Mobile-S21")
                    self.assertTrue(validate_qr_pairing_uri(init_d["qr_payload"]))
                    tok = srv.pair_verify(init_d["pin"], client_id="mob-s21")["token"]
                    with ws_sync_connect(f"ws://127.0.0.1:{port}/api/v1/ws?snapshot=1&token={tok}") as ws:
                        msg = json.loads(ws.recv(timeout=2.0))
                        self.assertIn(msg["type"], ("PlaybackStateChanged", "SignalPathUpdated"))


class TestScenario22(unittest.TestCase):
    """S22: Mobile WAN HTTPS/WSS Direct Connect + Local / Virtual USB DAC Fallback Mode"""

    def test_s22_wan_tls_remote_plus_local_usb_dac_manifests(self):
        with ManagedTempDir(prefix="lumina_s22_") as tmp:
            with LuminaLiveServer(db_path=tmp / "s22.db") as srv:
                with WanTlsProxyMockServer(target_port=srv.port) as tls_proxy:
                    ssl_ctx = tls_proxy.client_ssl_context()
                    with httpx.Client(verify=str(tls_proxy.ca_cert_path), timeout=5.0) as client:
                        p_init = client.post(
                            f"{tls_proxy.https_base_url}/api/v1/pair/initiate",
                            json={"device_name": "Phone-WAN", "host": "127.0.0.1", "port": tls_proxy.port},
                        ).json()
                        p_ver = client.post(
                            f"{tls_proxy.https_base_url}/api/v1/pair/verify",
                            json={"pin": p_init["pin"], "client_id": "wan-s22"},
                        ).json()
                        tok = p_ver["token"]
                        with ws_sync_connect(
                            tls_proxy.wss_url(f"/api/v1/ws?token={tok}"), ssl=ssl_ctx
                        ) as wss:
                            client.post(
                                f"{tls_proxy.https_base_url}/api/v1/playback/volume",
                                headers={"Authorization": f"Bearer {tok}"},
                                json={"volume": 0.58},
                            )
                            evt = json.loads(wss.recv(timeout=2.0))
                            self.assertAlmostEqual(evt["volume"], 0.58, places=2)
            xml = (_WORKSPACE_ROOT / "app/android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
            self.assertIn("hardware.usb.host", xml)


class TestScenario23(unittest.TestCase):
    """S23: DLNA/UPnP Discovery, Media Proxy Streaming & Transport/Volume Control"""

    def test_s23_dlna_full_casting_scenario(self):
        with (
            ManagedTempDir(prefix="lumina_s23_") as tmp,
            StreamingAudioMockServer() as ss,
            DlnaMediaRendererMock() as dlna,
        ):
            dlna.fetch_uri_on_play = True
            with LuminaLiveServer(db_path=tmp / "s23.db") as srv:
                tok = srv.pair(device_name="S23-DLNA")
                zones = srv.request(
                    "POST",
                    "/api/v1/zones/discover",
                    token=tok,
                    json={"ssdp_addr": f"{dlna.ssdp_host}:{dlna.ssdp_port}", "timeout_ms": 600},
                ).json()
                zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
                media = f"{ss.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a"
                play_r = srv.request("POST", f"/api/v1/zones/{zid}/cast", token=tok, json={"action": "play", "media_uri": media})
                self.assertEqual(play_r.status_code, 200)
                self.assertEqual(dlna.fetched_media_status, 200)
                srv.request("POST", f"/api/v1/zones/{zid}/volume", token=tok, json={"volume": 0.70})
                self.assertEqual(dlna.volume, 70)
                srv.request("POST", f"/api/v1/zones/{zid}/cast", token=tok, json={"action": "stop"})
                self.assertEqual(dlna.transport_state, "STOPPED")


class TestScenario24(unittest.TestCase):
    """S24: AirPlay RTSP/RTP Discovery, Streaming, Volume & Teardown Lifecycle"""

    def test_s24_airplay_rtsp_rtp_scenario(self):
        with (
            ManagedTempDir(prefix="lumina_s24_") as tmp,
            AirPlayMockServer() as ap,
        ):
            with LuminaLiveServer(db_path=tmp / "s24.db") as srv:
                tok = srv.pair(device_name="S24-AirPlay")
                zones = srv.request(
                    "POST",
                    "/api/v1/zones/discover",
                    token=tok,
                    json={"airplay_addrs": [f"127.0.0.1:{ap.rtsp_port}"], "timeout_ms": 500},
                ).json()
                zid = next(z["id"] for z in zones if z["backend"] == "network_airplay")
                cast_play = srv.request("POST", f"/api/v1/zones/{zid}/cast", token=tok, json={"action": "play"})
                self.assertEqual(cast_play.status_code, 200)
                deadline = time.monotonic() + 2.0
                while not ap.rtp_packets and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertGreaterEqual(len(ap.rtp_packets), 2)
                srv.request("POST", f"/api/v1/zones/{zid}/volume", token=tok, json={"volume": 0.8})
                srv.request("POST", f"/api/v1/zones/{zid}/cast", token=tok, json={"action": "stop"})
                self.assertTrue(ap.teardown_called)


class TestScenario25(unittest.TestCase):
    """S25: Multi-Room Zone Grouping with Simulated Clock Drift & Synchronized Start"""

    def test_s25_multiroom_clock_drift_sync_and_aligned_group(self):
        with (
            ManagedTempDir(prefix="lumina_s25_") as tmp,
            ClockSyncMockServer(simulated_offset_us=25000, drift_ppm=80.0) as z1_clk,
            ClockSyncMockServer(simulated_offset_us=-35000, drift_ppm=-110.0) as z2_clk,
        ):
            with LuminaLiveServer(db_path=tmp / "s25.db") as srv:
                tok = srv.pair(device_name="S25-MultiRoom")
                for zid, clk in (("z-room-1", z1_clk), ("z-room-2", z2_clk)):
                    srv.request(
                        "POST",
                        "/api/v1/zones",
                        token=tok,
                        json={"id": zid, "name": zid, "backend": "network_dlna", "exclusive_mode": False, "dsp_bypass": True, "volume": 0.9, "is_active": True, "clock_sync_addr": f"{clk.host}:{clk.port}"},
                    )
                    m = srv.request("POST", f"/api/v1/zones/{zid}/sync", token=tok, json={"samples": 5}).json()
                    self.assertEqual(len(m["samples"]), 5)
                grp = srv.request(
                    "POST",
                    "/api/v1/zones/group",
                    token=tok,
                    json={"group_id": "party-mode", "zone_ids": ["z-room-1", "z-room-2"]},
                ).json()
                delays = grp["scheduled_delays_us"]
                self.assertNotEqual(delays["z-room-1"], delays["z-room-2"])


class TestScenario26(unittest.TestCase):
    """S26: Full Release Gate: Workspace Cargo Check & Flutter Analyze Verification"""

    def test_s26_cargo_check_and_flutter_analyze_clean(self):
        cargo = shutil.which("cargo")
        flutter = shutil.which("flutter")
        self.assertIsNotNone(cargo)
        self.assertIsNotNone(flutter)
        res_rust = subprocess.run(
            [cargo, "check", "--workspace", "-q"],
            cwd=str(_WORKSPACE_ROOT),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(res_rust.returncode, 0, res_rust.stderr)
        res_fl = subprocess.run(
            [flutter, "analyze", "--no-pub"],
            cwd=str(_WORKSPACE_ROOT / "app"),
            shell=(os.name == "nt"),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(res_fl.returncode, 0, res_fl.stdout + res_fl.stderr)
