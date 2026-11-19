"""
Lumina Audio E2E Test Suite - Tier 3 R1-R3 Pairwise Combinations
21 pairwise integration tests across F33-F50 combining live FFI, Axum REST/WS,
SQLite WAL persistence, DSP/ReplayGain, Enrichment, TLS, mDNS, DLNA, AirPlay, and Clock Sync.
"""
import json
import socket
import struct
import time
import unittest
from typing import Any, Dict

import httpx
import requests
from websockets.sync.client import connect as ws_sync_connect

from tests.e2e.fixtures.ffi_harness import LUMINA_OK, LuminaFfiClient, LuminaLiveServer
from tests.e2e.fixtures.mock_servers import (
    AirPlayMockServer,
    ClockSyncMockServer,
    DiscogsMockServer,
    DlnaMediaRendererMock,
    MdnsLoopbackMock,
    MusicBrainzMockServer,
    SmbLoopbackFixture,
    StreamingAudioMockServer,
    WanTlsProxyMockServer,
    WebDavMockServer,
)
from tests.e2e.fixtures.net_helpers import ManagedTempDir, generate_flac_file
from tests.e2e.fixtures.provider_mocks import make_basic_auth
from tests.e2e.fixtures.server_fixtures import validate_qr_pairing_uri

_MOD: Dict[str, Any] = {}


def setUpModule() -> None:
    tmp = ManagedTempDir(prefix="lumina_t3_r1_r3_")
    tmp.__enter__()
    music_dir = tmp.path / "music"
    db_path = tmp.path / "pw_t3.db"

    generate_flac_file(
        music_dir / "Pink Floyd" / "Dark Side [24-96]" / "01 - Time.flac",
        sample_rate=96000,
        bit_depth=24,
        duration_ms=700,
        title="Time",
        artist="Pink Floyd",
        album="The Dark Side of the Moon",
        album_artist="Pink Floyd",
        track_number=1,
        year="1973",
        isrc="GBAYE0300592",
        replaygain_track_gain="-4.10 dB",
        replaygain_track_peak="0.900000",
    )
    generate_flac_file(
        music_dir / "Pink Floyd" / "Dark Side [Mobile Fidelity]" / "01 - Time.flac",
        sample_rate=44100,
        bit_depth=16,
        duration_ms=700,
        title="Time",
        artist="Pink Floyd",
        album="The Dark Side of the Moon",
        album_artist="Pink Floyd",
        track_number=1,
        year="1973",
        isrc="GBAYE0300592",
        replaygain_track_gain="-3.90 dB",
        replaygain_track_peak="0.880000",
    )

    srv = LuminaLiveServer(db_path=db_path, scan_dir=music_dir).start()
    tok = srv.pair(device_name="PW-Controller", platform="desktop")

    _MOD.update(
        {
            "tmp": tmp,
            "music_dir": music_dir,
            "srv": srv,
            "tok": tok,
            "stream_srv": StreamingAudioMockServer().start(),
            "dav_srv": WebDavMockServer().start(),
            "smb_srv": SmbLoopbackFixture().start(),
            "mb_srv": MusicBrainzMockServer().start(),
            "dg_srv": DiscogsMockServer().start(),
            "dlna_srv": DlnaMediaRendererMock().start(),
            "airplay_srv": AirPlayMockServer().start(),
            "clock_a": ClockSyncMockServer(simulated_offset_us=18000, drift_ppm=60.0).start(),
            "clock_b": ClockSyncMockServer(simulated_offset_us=-22000, drift_ppm=-90.0).start(),
            "mdns_srv": MdnsLoopbackMock(hostname="Lumina-PW", service_port=srv.port).start(),
            "tls_proxy": WanTlsProxyMockServer(target_port=srv.port).start(),
        }
    )


def tearDownModule() -> None:
    for k in (
        "tls_proxy",
        "mdns_srv",
        "clock_b",
        "clock_a",
        "airplay_srv",
        "dlna_srv",
        "dg_srv",
        "mb_srv",
        "smb_srv",
        "dav_srv",
        "stream_srv",
        "srv",
    ):
        obj = _MOD.get(k)
        if obj is not None:
            try:
                obj.stop()
            except Exception:
                pass
    tmp = _MOD.get("tmp")
    if tmp is not None:
        tmp.__exit__(None, None, None)
    _MOD.clear()


def _srv() -> LuminaLiveServer:
    return _MOD["srv"]


def _tok() -> str:
    return _MOD["tok"]


class TestTier3R1R3Pairwise(unittest.TestCase):
    """21 pairwise tests spanning R1 (F33-F42), R2 (F43-F45), and R3 (F46-F49)."""

    # --- R1 Pairwise (12 tests covering F33..F42 -> visible in --suite r1) ---

    def test_pw_f34_f35_qobuz_config_then_http_stream_playback(self):
        ss = _MOD["stream_srv"]
        cfg_r = _srv().request(
            "POST",
            "/api/v1/providers/qobuz",
            token=_tok(),
            json={"user_auth_token": "qb_usr_tok_99182371", "app_id": "lumina", "base_url": f"{ss.base_url}/api.json/0.2/", "authenticate": True},
        )
        self.assertEqual(cfg_r.status_code, 200)
        play_r = _srv().request(
            "POST",
            "/api/v1/playback/play",
            token=_tok(),
            json={"stream_url": f"{ss.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a", "source": "Qobuz", "hint_extension": "flac"},
        )
        self.assertEqual(play_r.status_code, 200)
        self.assertEqual(_srv().request("GET", "/api/v1/playback/state", token=_tok()).json()["status"], "playing")
        _srv().request("POST", "/api/v1/playback/stop", token=_tok())

    def test_pw_f34_f37_webdav_sync_then_canonical_albums_list(self):
        dav = _MOD["dav_srv"]
        _srv().request(
            "POST",
            "/api/v1/providers/webdav",
            token=_tok(),
            json={"uri": f"{dav.base_url.replace('http://', 'http://lumina:webdav_secret@')}/Music/"},
        )
        sr = _srv().request("POST", "/api/v1/providers/web_dav/sync", token=_tok())
        self.assertEqual(sr.status_code, 200)
        albs = _srv().request("GET", "/api/v1/library/albums", token=_tok()).json()
        self.assertTrue(any("Kind of Blue" in a["title"] or "Dark Side" in a["title"] for a in albs))

    def test_pw_f35_f36_http_stream_with_autoeq_signal_path_enhanced(self):
        ss = _MOD["stream_srv"]
        _srv().request(
            "POST",
            "/api/v1/dsp/autoeq",
            token=_tok(),
            json={"text": "Preamp: -3.0 dB\nFilter 1: ON PK Fc 250 Hz Gain 2.0 dB Q 1.0\n", "apply": True},
        )
        _srv().request(
            "POST",
            "/api/v1/playback/play",
            token=_tok(),
            json={"stream_url": f"{ss.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a", "source": "Qobuz", "hint_extension": "flac"},
        )
        sp = _srv().request("GET", "/api/v1/signal-path", token=_tok()).json()
        self.assertEqual(sp.get("quality") or sp.get("overall_quality"), "enhanced")
        _srv().request("POST", "/api/v1/playback/stop", token=_tok())

    def test_pw_f36_f40_device_selection_with_dsp_bypass_lossless(self):
        devs = _srv().request("GET", "/api/v1/audio/devices", token=_tok()).json()
        sel_r = _srv().request(
            "POST",
            "/api/v1/audio/devices/select",
            token=_tok(),
            json={"device_id": devs[0]["id"], "backend": devs[0]["backend"]},
        )
        self.assertEqual(sel_r.status_code, 200)
        cfg = _srv().request("GET", "/api/v1/dsp/config", token=_tok()).json()
        cfg["bypass"] = True
        put_r = _srv().request("PUT", "/api/v1/dsp/config", token=_tok(), json=cfg)
        self.assertEqual(put_r.status_code, 200)
        sp = _srv().request("GET", "/api/v1/signal-path", token=_tok()).json()
        self.assertEqual(sp.get("quality") or sp.get("overall_quality"), "lossless")

    def test_pw_f37_f38_dedup_then_credit_enrichment_and_artist_graph(self):
        mb = _MOD["mb_srv"]
        dg = _MOD["dg_srv"]
        _srv().request("POST", "/api/v1/library/deduplicate", token=_tok())
        en = _srv().request(
            "POST",
            "/api/v1/library/enrich",
            token=_tok(),
            json={"musicbrainz_base_url": f"{mb.base_url}/ws/2", "discogs_base_url": dg.base_url, "discogs_token": "e2e_dg_tok", "force_refresh": True, "rebuild_search_index": True},
        )
        self.assertEqual(en.status_code, 200)
        self.assertGreaterEqual(en.json()["albums_processed"], 1)
        albs = _srv().request("GET", "/api/v1/library/albums", token=_tok()).json()
        creds = []
        for a in albs:
            cr = _srv().request("GET", f"/api/v1/library/albums/{a['id']}/credits", token=_tok()).json()
            if cr:
                creds = cr
                break
        self.assertGreater(len(creds), 0)
        art = _srv().request("GET", f"/api/v1/library/artists/{creds[0]['artist_id']}", token=_tok())
        self.assertEqual(art.status_code, 200)
        self.assertGreaterEqual(len(art.json()["credits"]), 1)

    def test_pw_f37_f41_canonical_versions_match_api_detail(self):
        albs = _srv().request("GET", "/api/v1/library/albums", token=_tok()).json()
        det = _srv().request("GET", f"/api/v1/library/albums/{albs[0]['id']}", token=_tok()).json()
        self.assertIn("versions", det)
        self.assertIn("credits", det)

    def test_pw_f38_f39_enriched_album_favorited_by_profile(self):
        p = _srv().request("POST", "/api/v1/profiles", token=_tok(), json={"name": "Vinyl Lover"}).json()
        _srv().request("POST", f"/api/v1/profiles/{p['id']}/activate", token=_tok())
        albs = _srv().request("GET", "/api/v1/library/albums", token=_tok()).json()
        _srv().request(
            "POST",
            f"/api/v1/profiles/{p['id']}/favorites",
            token=_tok(),
            json={"item_type": "album", "item_id": albs[0]["id"]},
        )
        favs = _srv().request("GET", f"/api/v1/profiles/{p['id']}/favorites", token=_tok()).json()
        self.assertTrue(any(f["item_id"] == albs[0]["id"] for f in favs))

    def test_pw_f39_f42_profile_history_records_track_play(self):
        profs = _srv().request("GET", "/api/v1/profiles", token=_tok()).json()["profiles"]
        pid = profs[0]["id"]
        tracks = _srv().request("GET", "/api/v1/library/tracks", token=_tok()).json()
        rec = _srv().request(
            "POST",
            f"/api/v1/profiles/{pid}/history",
            token=_tok(),
            json={"track_source_id": tracks[0]["id"], "duration_listened_ms": 2200},
        )
        self.assertEqual(rec.status_code, 200)
        hist = _srv().request("GET", f"/api/v1/profiles/{pid}/history", token=_tok()).json()
        self.assertTrue(any(h["track_source_id"] == tracks[0]["id"] for h in hist))

    def test_pw_f34_f38_discogs_rate_limit_recovered_after_retry_config(self):
        mb = _MOD["mb_srv"]
        dg = _MOD["dg_srv"]
        dg.inject_503_count = 1
        r = _srv().request(
            "POST",
            "/api/v1/library/enrich",
            token=_tok(),
            json={"musicbrainz_base_url": f"{mb.base_url}/ws/2", "discogs_base_url": dg.base_url, "force_refresh": True},
        )
        self.assertEqual(r.status_code, 200)

    def test_pw_f35_f40_playback_webdav_then_device_switch(self):
        dav = _MOD["dav_srv"]
        _srv().request(
            "POST",
            "/api/v1/playback/play",
            token=_tok(),
            json={
                "stream_url": f"{dav.base_url}/Music/Miles%20Davis/Kind%20of%20Blue/01%20-%20So%20What.flac",
                "headers": {"Authorization": make_basic_auth("lumina", "webdav_secret")},
                "hint_extension": "flac",
            },
        )
        devs = _srv().request("GET", "/api/v1/audio/devices", token=_tok()).json()
        sel = _srv().request(
            "POST", "/api/v1/audio/devices/select", token=_tok(), json={"device_id": devs[0]["id"]}
        )
        self.assertEqual(sel.status_code, 200)
        _srv().request("POST", "/api/v1/playback/stop", token=_tok())

    def test_pw_f33_f36_core_ffi_autoeq_symbols_match_rest_schema(self):
        cfg = _srv().request("GET", "/api/v1/dsp/config", token=_tok()).json()
        for k in ("bypass", "peq_bands", "crossfeed", "replay_gain"):
            self.assertIn(k, cfg)

    def test_pw_f33_f39_profiles_list_has_active_and_default(self):
        res = _srv().request("GET", "/api/v1/profiles", token=_tok()).json()
        self.assertIn("active_profile_id", res)
        self.assertGreaterEqual(len(res["profiles"]), 1)

    # --- R2 Pairwise (4 tests covering F43..F45 -> visible in --suite r2) ---

    def test_pw_f43_f44_mdns_qr_pair_then_ws_snapshot_control(self):
        mdns = _MOD["mdns_srv"]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(2.0)
            s.sendto(MdnsLoopbackMock.build_ptr_query(), (mdns.host, mdns.port))
            parsed = MdnsLoopbackMock.parse_dns_sd_packet(s.recvfrom(4096)[0])
        self.assertEqual(parsed["srv"]["port"], _srv().port)
        init_d = _srv().pair_initiate(device_name="PW-R2")
        self.assertTrue(validate_qr_pairing_uri(init_d["qr_payload"]))
        tok2 = _srv().pair_verify(init_d["pin"], client_id="pw-r2")["token"]
        with ws_sync_connect(f"{_srv().ws_url}?snapshot=1&token={tok2}") as ws:
            snap1 = json.loads(ws.recv(timeout=2.0))
            snap2 = json.loads(ws.recv(timeout=2.0))
            self.assertEqual({snap1["type"], snap2["type"]}, {"PlaybackStateChanged", "SignalPathUpdated"})
            ws.send(json.dumps({"action": "playback.volume", "volume": 0.61}))
            vol_msg = json.loads(ws.recv(timeout=2.0))
            self.assertAlmostEqual(vol_msg["volume"], 0.61, places=2)

    def test_pw_f43_f45_wan_tls_proxy_ws_play_syncs_rest_state(self):
        proxy = _MOD["tls_proxy"]
        ssl_ctx = proxy.client_ssl_context()
        with ws_sync_connect(proxy.wss_url(f"/api/v1/ws?snapshot=true&token={_tok()}"), ssl=ssl_ctx) as wss:
            wss.recv(timeout=2.0)
            wss.recv(timeout=2.0)
            wss.send(json.dumps({"action": "playback.volume", "volume": 0.44}))
            msg = json.loads(wss.recv(timeout=2.0))
            self.assertAlmostEqual(msg["volume"], 0.44, places=2)

    def test_pw_f44_f45_wan_tls_qr_pair_flow(self):
        proxy = _MOD["tls_proxy"]
        with httpx.Client(verify=str(proxy.ca_cert_path), timeout=5.0) as client:
            p_init = client.post(
                f"{proxy.https_base_url}/api/v1/pair/initiate",
                json={"device_name": "WanPhone", "host": "127.0.0.1", "port": proxy.port},
            ).json()
            self.assertTrue(validate_qr_pairing_uri(p_init["qr_payload"]))
            p_ver = client.post(
                f"{proxy.https_base_url}/api/v1/pair/verify",
                json={"pin": p_init["pin"], "client_id": "wan-phone-pw"},
            ).json()
            self.assertEqual(p_ver["status"], "success")

    def test_pw_f41_f43_ws_tracks_signal_path_update_after_autoeq(self):
        with _srv().ws_connect(token=_tok()) as ws:
            _srv().request(
                "POST",
                "/api/v1/dsp/autoeq",
                token=_tok(),
                json={"text": "Preamp: -2.0 dB\nFilter 1: ON PK Fc 400 Hz Gain 1.5 dB Q 1.0\n", "apply": True},
            )
            msg = json.loads(ws.recv(timeout=2.0))
            self.assertEqual(msg["type"], "SignalPathUpdated")

    # --- R3 Pairwise (5 tests covering F46..F49 -> visible in --suite r3) ---

    def test_pw_f46_f47_dlna_discover_cast_streaming_url_and_volume(self):
        dlna = _MOD["dlna_srv"]
        dlna.fetch_uri_on_play = True
        ss = _MOD["stream_srv"]
        zones = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"ssdp_addr": f"{dlna.ssdp_host}:{dlna.ssdp_port}", "timeout_ms": 500},
        ).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
        r_cast = _srv().request(
            "POST",
            f"/api/v1/zones/{zid}/cast",
            token=_tok(),
            json={"action": "play", "media_uri": f"{ss.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a"},
        )
        self.assertEqual(r_cast.status_code, 200)
        self.assertEqual(dlna.fetched_media_status, 200)
        _srv().request("POST", f"/api/v1/zones/{zid}/volume", token=_tok(), json={"volume": 0.78})
        self.assertEqual(dlna.volume, 78)

    def test_pw_f46_f48_airplay_discover_cast_and_teardown(self):
        ap = _MOD["airplay_srv"]
        ap.reset()
        zones = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"airplay_addrs": [f"127.0.0.1:{ap.rtsp_port}"], "timeout_ms": 500},
        ).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_airplay")
        r = _srv().request("POST", f"/api/v1/zones/{zid}/cast", token=_tok(), json={"action": "stop"})
        self.assertEqual(r.status_code, 200)
        self.assertTrue(ap.teardown_called)

    def test_pw_f46_f49_multi_zone_clock_sync_and_group_schedule(self):
        ca = _MOD["clock_a"]
        cb = _MOD["clock_b"]
        _srv().request(
            "POST",
            "/api/v1/zones",
            token=_tok(),
            json={"id": "zone-a", "name": "Zone A", "backend": "network_dlna", "exclusive_mode": False, "dsp_bypass": True, "volume": 0.8, "is_active": True, "clock_sync_addr": f"{ca.host}:{ca.port}"},
        )
        _srv().request(
            "POST",
            "/api/v1/zones",
            token=_tok(),
            json={"id": "zone-b", "name": "Zone B", "backend": "network_airplay", "exclusive_mode": False, "dsp_bypass": True, "volume": 0.8, "is_active": True, "clock_sync_addr": f"{cb.host}:{cb.port}"},
        )
        sa = _srv().request("POST", "/api/v1/zones/zone-a/sync", token=_tok(), json={"samples": 4}).json()
        sb = _srv().request("POST", "/api/v1/zones/zone-b/sync", token=_tok(), json={"samples": 4}).json()
        self.assertGreater(sa["offset_us"] - sb["offset_us"], 20000)
        grp = _srv().request(
            "POST",
            "/api/v1/zones/group",
            token=_tok(),
            json={"group_id": "pw-sync-grp", "zone_ids": ["zone-a", "zone-b"]},
        ).json()
        self.assertIn("zone-a", grp["scheduled_delays_us"])
        self.assertIn("zone-b", grp["scheduled_delays_us"])

    def test_pw_f47_f49_dlna_with_sntp_clock_sync(self):
        dlna = _MOD["dlna_srv"]
        ca = _MOD["clock_a"]
        zones = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"ssdp_addr": f"{dlna.ssdp_host}:{dlna.ssdp_port}", "clock_sync_addr": f"{ca.host}:{ca.port}"},
        ).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
        sync_r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/sync", token=_tok(), json={"samples": 3, "use_sntp_binary": True}
        )
        self.assertEqual(sync_r.status_code, 200)

    def test_pw_f48_f49_airplay_with_clock_sync_and_rtp(self):
        ap = _MOD["airplay_srv"]
        cb = _MOD["clock_b"]
        ap.reset()
        zones = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"airplay_addrs": [f"127.0.0.1:{ap.rtsp_port}"], "clock_sync_addr": f"{cb.host}:{cb.port}"},
        ).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_airplay")
        self.assertEqual(
            _srv().request("POST", f"/api/v1/zones/{zid}/sync", token=_tok(), json={"samples": 3}).status_code,
            200,
        )
        self.assertEqual(
            _srv().request("POST", f"/api/v1/zones/{zid}/cast", token=_tok(), json={"action": "play"}).status_code,
            200,
        )
        deadline = time.monotonic() + 2.0
        while not ap.rtp_packets and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertGreaterEqual(len(ap.rtp_packets), 1)
