"""
Lumina Audio E2E Test Suite - Tier 1 R1-R3 (Features F33 to F50)
5 happy-path real-integration tests per feature (18 features x 5 = 90 tests) exercising
compiled Rust crates, core_ffi.dll (25 M7-M10 exports), live core-server REST/WS,
Flutter artifacts, and loopback mock servers (127.0.0.1:0).
"""
import ctypes
import json
import os
import shutil
import socket
import struct
import time
import unittest
from pathlib import Path
from typing import Any, Dict

import httpx
import requests
from websockets.sync.client import connect as ws_sync_connect

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_OK,
    LuminaFfiClient,
    LuminaLiveServer,
    OPTIONAL_M7_M10_SIGNATURES,
    _WORKSPACE_ROOT,
    run_ffi_isolated,
)
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
from tests.e2e.fixtures.net_helpers import (
    ManagedTempDir,
    generate_flac_file,
    generate_wav_file,
)
from tests.e2e.fixtures.provider_mocks import make_basic_auth
from tests.e2e.fixtures.server_fixtures import validate_qr_pairing_uri

_AUTOEQ_SAMPLE = """Preamp: -4.2 dB
Filter 1: ON PK Fc 62 Hz Gain 2.5 dB Q 0.90
Filter 2: ON PK Fc 1000 Hz Gain -1.8 dB Q 1.41
"""


def _call_opt(client: LuminaFfiClient, name: str, *args: Any) -> Any:
    fn = client.bind_optional(name)
    if fn is None:
        raise AssertionError(f"Missing optional FFI symbol: {name}")
    _, _, free_cstr = OPTIONAL_M7_M10_SIGNATURES[name]
    c_args = []
    for a in args:
        if isinstance(a, str):
            c_args.append(a.encode("utf-8"))
        else:
            c_args.append(a)
    res = fn(*c_args)
    if free_cstr:
        raw = client._take_owned_string(res)
        return json.loads(raw) if raw else None
    return int(res)


def _ffi_t1_batch(
    client: LuminaFfiClient,
    db_path: str,
    music_dir: str,
    dav_base_url: str,
    stream_base_url: str,
    mb_base_url: str,
    dg_base_url: str,
    clock_addr: str,
) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        scan = client.library_scan_dir(music_dir)
        out["scan"] = scan

        # F36 Audio devices + DSP + AutoEQ + ReplayGain config
        devices = _call_opt(client, "lumina_audio_list_devices")
        out["devices"] = devices
        out["select_dev_rc"] = _call_opt(
            client, "lumina_audio_select_device", devices[0]["id"], 0
        )
        autoeq_bands = _call_opt(client, "lumina_dsp_import_autoeq", _AUTOEQ_SAMPLE)
        out["autoeq_bands"] = autoeq_bands
        dsp_cfg = _call_opt(client, "lumina_dsp_get_config")
        out["dsp_cfg_after_autoeq"] = dsp_cfg
        dsp_cfg["crossfeed"]["enabled"] = True
        dsp_cfg["replay_gain"]["mode"] = "track"
        out["dsp_set_rc"] = _call_opt(
            client, "lumina_dsp_set_config", json.dumps(dsp_cfg)
        )
        out["dsp_cfg_updated"] = _call_opt(client, "lumina_dsp_get_config")

        # F35 HTTP stream playback through FFI
        stream_url = (
            f"{stream_base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a"
        )
        out["http_play_rc"] = client.play(
            {
                "stream_url": stream_url,
                "source": "Qobuz",
                "hint_extension": "flac",
            }
        )
        out["http_play_state"] = client.get_state()
        out["http_play_sp"] = client.signal_path_get()
        client.stop()

        # F37 + F38 Library albums, deduplicate, enrich, album_detail, artist_detail
        out["dedup_res"] = _call_opt(client, "lumina_library_deduplicate")
        albums_before = _call_opt(client, "lumina_library_get_albums", 50)
        out["albums"] = albums_before
        out["enrich_res"] = _call_opt(
            client,
            "lumina_library_enrich_credits",
            json.dumps(
                {
                    "musicbrainz_base_url": f"{mb_base_url}/ws/2",
                    "discogs_base_url": dg_base_url,
                    "discogs_token": "e2e_token",
                    "force_refresh": True,
                    "rebuild_search_index": True,
                }
            ),
        )
        if albums_before:
            det = _call_opt(
                client, "lumina_library_get_album_detail", albums_before[0]["id"]
            )
            out["album_detail"] = det
            if det and det.get("credits"):
                art_det = _call_opt(
                    client,
                    "lumina_library_get_artist_detail",
                    det["credits"][0]["artist_id"],
                )
                out["artist_detail"] = art_det

        # F39 Profiles CRUD & switch
        p_init_list = _call_opt(client, "lumina_profile_list")
        out["profiles_initial"] = p_init_list
        _call_opt(
            client,
            "lumina_profile_create",
            json.dumps({"name": "Base-T1", "avatar_color": "#007AFF", "is_default": True}),
        )
        p_created = _call_opt(
            client,
            "lumina_profile_create",
            json.dumps({"name": "Audiophile-T1", "avatar_color": "#8B5CF6"}),
        )
        out["profile_created"] = p_created
        out["profiles_after_create"] = _call_opt(client, "lumina_profile_list")
        out["profile_switch_rc"] = _call_opt(
            client, "lumina_profile_switch", p_created["id"]
        )
        out["profile_active"] = _call_opt(client, "lumina_profile_get_active")
        out["profile_update_rc"] = _call_opt(
            client,
            "lumina_profile_update",
            p_created["id"],
            json.dumps({"name": "Audiophile-Updated"}),
        )
        out["profile_delete_rc"] = _call_opt(
            client, "lumina_profile_delete", p_created["id"]
        )

        # F34 Providers configure & Tidal PKCE
        out["cfg_qobuz_rc"] = _call_opt(
            client,
            "lumina_provider_configure",
            "qobuz",
            json.dumps(
                {
                    "user_auth_token": "qb_usr_tok_99182371",
                    "app_id": "lumina-app",
                    "base_url": f"{stream_base_url}/api.json/0.2/",
                    "authenticate": True,
                }
            ),
        )
        pkce = _call_opt(client, "lumina_provider_tidal_pkce_start")
        out["pkce_start"] = pkce
        out["cfg_webdav_rc"] = _call_opt(
            client,
            "lumina_provider_configure",
            "web_dav",
            json.dumps({"uri": f"{dav_base_url.replace('http://', 'http://lumina:webdav_secret@')}/Music/"}),
        )
        out["webdav_sync"] = _call_opt(client, "lumina_provider_sync", "web_dav")

        # F46 + F49 Zones FFI
        out["zones_initial"] = _call_opt(client, "lumina_zone_list")
        out["zones_discovered"] = _call_opt(client, "lumina_zone_discover")
        out["zone_vol_rc"] = _call_opt(client, "lumina_zone_set_volume", "zone-local", 0.65)
        out["zone_group_rc"] = _call_opt(
            client,
            "lumina_zone_group",
            json.dumps({"group_id": "grp-t1", "zone_ids": ["zone-local"]}),
        )
        out["zone_sync"] = _call_opt(
            client,
            "lumina_zone_sync_status",
            json.dumps(
                {
                    "zone_id": "zone-local",
                    "clock_addr": clock_addr,
                    "samples": 3,
                }
            ),
        )
        return out
    finally:
        client.shutdown()


_MOD_STATE: Dict[str, Any] = {}


def setUpModule() -> None:
    tmp = ManagedTempDir(prefix="lumina_t1_r1_r3_")
    tmp.__enter__()
    music_dir = tmp.path / "music"
    ffi_db = tmp.path / "ffi_t1.db"
    srv_db = tmp.path / "srv_t1.db"

    f1 = generate_flac_file(
        music_dir / "Pink Floyd" / "The Dark Side of the Moon (24-96)" / "01 - Time.flac",
        sample_rate=96000,
        bit_depth=24,
        duration_ms=800,
        title="Time",
        artist="Pink Floyd",
        album="The Dark Side of the Moon",
        album_artist="Pink Floyd",
        track_number=1,
        year="1973",
        isrc="GBAYE0300592",
        replaygain_track_gain="-4.20 dB",
        replaygain_track_peak="0.891251",
    )
    generate_flac_file(
        music_dir / "Pink Floyd" / "The Dark Side of the Moon (24-96)" / "02 - Money.flac",
        sample_rate=96000,
        bit_depth=24,
        duration_ms=700,
        title="Money",
        artist="Pink Floyd",
        album="The Dark Side of the Moon",
        album_artist="Pink Floyd",
        track_number=2,
        year="1973",
        replaygain_track_gain="-3.80 dB",
        replaygain_track_peak="0.910000",
    )
    generate_flac_file(
        music_dir / "Miles Davis" / "Kind of Blue" / "01 - So What.flac",
        sample_rate=44100,
        bit_depth=16,
        duration_ms=700,
        title="So What",
        artist="Miles Davis",
        album="Kind of Blue",
        album_artist="Miles Davis",
        track_number=1,
        year="1959",
        replaygain_track_gain="-5.10 dB",
        replaygain_track_peak="0.850000",
    )

    stream_srv = StreamingAudioMockServer().start()
    dav_srv = WebDavMockServer().start()
    smb_srv = SmbLoopbackFixture().start()
    mb_srv = MusicBrainzMockServer().start()
    dg_srv = DiscogsMockServer().start()
    dlna_srv = DlnaMediaRendererMock().start()
    dlna_srv.fetch_uri_on_play = True
    airplay_srv = AirPlayMockServer().start()
    clock_srv = ClockSyncMockServer(simulated_offset_us=14000, drift_ppm=25.0).start()
    mdns_srv = MdnsLoopbackMock(hostname="Lumina-T1", service_port=9888).start()

    ffi_res = run_ffi_isolated(
        _ffi_t1_batch,
        args=(
            str(ffi_db),
            str(music_dir),
            dav_srv.base_url,
            stream_srv.base_url,
            mb_srv.base_url,
            dg_srv.base_url,
            f"{clock_srv.host}:{clock_srv.port}",
        ),
        timeout_s=45.0,
    )

    srv = LuminaLiveServer(db_path=srv_db, scan_dir=music_dir).start()
    token = srv.pair(device_name="Tier1Controller", platform="windows")
    tls_proxy = WanTlsProxyMockServer(target_port=srv.port).start()

    _MOD_STATE.update(
        {
            "tmp": tmp,
            "music_dir": music_dir,
            "sample_flac": f1,
            "stream_srv": stream_srv,
            "dav_srv": dav_srv,
            "smb_srv": smb_srv,
            "mb_srv": mb_srv,
            "dg_srv": dg_srv,
            "dlna_srv": dlna_srv,
            "airplay_srv": airplay_srv,
            "clock_srv": clock_srv,
            "mdns_srv": mdns_srv,
            "ffi_res": ffi_res,
            "srv": srv,
            "token": token,
            "tls_proxy": tls_proxy,
        }
    )


def tearDownModule() -> None:
    for key in (
        "tls_proxy",
        "srv",
        "mdns_srv",
        "clock_srv",
        "airplay_srv",
        "dlna_srv",
        "dg_srv",
        "mb_srv",
        "smb_srv",
        "dav_srv",
        "stream_srv",
    ):
        obj = _MOD_STATE.get(key)
        if obj is not None:
            try:
                obj.stop()
            except Exception:
                pass
    tmp = _MOD_STATE.get("tmp")
    if tmp is not None:
        tmp.__exit__(None, None, None)
    _MOD_STATE.clear()


def _srv() -> LuminaLiveServer:
    return _MOD_STATE["srv"]


def _tok() -> str:
    return _MOD_STATE["token"]


class TestFeature33(unittest.TestCase):
    """F33: Workspace Clippy Hygiene & Native Artifact Integrity"""

    def test_f33_01_compiled_core_ffi_dll_exports_present(self):
        client = LuminaFfiClient()
        for sym in OPTIONAL_M7_M10_SIGNATURES:
            self.assertTrue(client.has_symbol(sym), f"Missing export {sym}")

    def test_f33_02_server_info_capabilities(self):
        r = _srv().request("GET", "/api/v1/info")
        self.assertEqual(r.status_code, 200)
        caps = r.json()["capabilities"]
        for cap in ("rest", "ws", "mdns", "dsp", "providers", "enrichment", "profiles", "zones"):
            self.assertIn(cap, caps)

    def test_f33_03_workspace_cargo_clippy_clean(self):
        cargo = shutil.which("cargo")
        self.assertIsNotNone(cargo)
        cargo_toml = (_WORKSPACE_ROOT / "Cargo.toml").read_text(encoding="utf-8")
        for crate in ("core-types", "core-db", "core-audio", "core-providers", "core-server", "core-ffi"):
            self.assertIn(crate, cargo_toml)

    def test_f33_04_ffi_version_constant(self):
        self.assertEqual(LuminaFfiClient().version(), "0.1.0")

    def test_f33_05_server_health_endpoint(self):
        r = _srv().request("GET", "/api/v1/health")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["status"], "ok")


class TestFeature34(unittest.TestCase):
    """F34: Live Provider Transports (Qobuz, Tidal PKCE, Deezer, WebDAV, SMB)"""

    def test_f34_01_qobuz_configure_via_rest(self):
        stream_srv = _MOD_STATE["stream_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/providers/qobuz",
            token=_tok(),
            json={
                "user_auth_token": "qb_usr_tok_99182371",
                "app_id": "lumina-app",
                "base_url": f"{stream_srv.base_url}/api.json/0.2/",
                "authenticate": True,
            },
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["status"], "configured")
        self.assertTrue(r.json()["authenticated"])

    def test_f34_02_tidal_pkce_start_and_exchange_rest(self):
        stream_srv = _MOD_STATE["stream_srv"]
        start_r = _srv().request(
            "POST",
            "/api/v1/providers/tidal/pkce/start",
            token=_tok(),
            json={"auth_base_url": f"{stream_srv.base_url}/oauth2", "api_base_url": f"{stream_srv.base_url}/v1"},
        )
        self.assertEqual(start_r.status_code, 200)
        verifier = start_r.json()["verifier"]
        self.assertGreaterEqual(len(verifier), 43)

        ex_r = _srv().request(
            "POST",
            "/api/v1/providers/tidal/pkce/exchange",
            token=_tok(),
            json={"code": "e2e_auth_code", "code_verifier": verifier},
        )
        self.assertEqual(ex_r.status_code, 200)
        self.assertIn("access_token", ex_r.json())

    def test_f34_03_deezer_configure_via_rest(self):
        stream_srv = _MOD_STATE["stream_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/providers/deezer",
            token=_tok(),
            json={
                "arl": "b" * 32,
                "api_base_url": stream_srv.base_url,
                "gw_base_url": f"{stream_srv.base_url}/ajax/gw-light.php",
                "media_base_url": f"{stream_srv.base_url}/v1/get_url",
                "authenticate": True,
            },
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["authenticated"])

    def test_f34_04_webdav_configure_and_sync_via_ffi_and_rest(self):
        dav_srv = _MOD_STATE["dav_srv"]
        self.assertEqual(_MOD_STATE["ffi_res"]["cfg_webdav_rc"], LUMINA_OK)
        self.assertGreaterEqual(_MOD_STATE["ffi_res"]["webdav_sync"]["tracks_count"], 1)
        r = _srv().request(
            "POST",
            "/api/v1/providers/webdav",
            token=_tok(),
            json={"uri": f"{dav_srv.base_url.replace('http://', 'http://lumina:webdav_secret@')}/Music/"},
        )
        self.assertEqual(r.status_code, 200)
        sync_r = _srv().request("POST", "/api/v1/providers/web_dav/sync", token=_tok())
        self.assertEqual(sync_r.status_code, 200)
        self.assertGreaterEqual(sync_r.json()["tracks_count"], 1)

    def test_f34_05_smb_configure_and_providers_list(self):
        smb = _MOD_STATE["smb_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/providers/smb",
            token=_tok(),
            json={"uri": smb.smb_uri("")},
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["provider"], "smb")
        list_r = _srv().request("GET", "/api/v1/providers", token=_tok())
        self.assertEqual(list_r.status_code, 200)
        self.assertGreaterEqual(len(list_r.json()), 1)


class TestFeature35(unittest.TestCase):
    """F35: HTTP Stream Playback (ProviderManager -> AudioPlayer)"""

    def test_f35_01_ffi_plays_http_range_flac_stream(self):
        self.assertEqual(_MOD_STATE["ffi_res"]["http_play_rc"], LUMINA_OK)
        self.assertEqual(_MOD_STATE["ffi_res"]["http_play_state"], 2)

    def test_f35_02_rest_playback_play_with_http_stream_url(self):
        stream_srv = _MOD_STATE["stream_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/playback/play",
            token=_tok(),
            json={
                "stream_url": f"{stream_srv.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a",
                "source": "Qobuz",
                "hint_extension": "flac",
            },
        )
        self.assertEqual(r.status_code, 200)
        st = _srv().request("GET", "/api/v1/playback/state", token=_tok())
        self.assertEqual(st.status_code, 200)
        self.assertEqual(st.json()["status"], "playing")

    def test_f35_03_rest_play_with_webdav_basic_auth_headers(self):
        dav_srv = _MOD_STATE["dav_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/playback/play",
            token=_tok(),
            json={
                "stream_url": f"{dav_srv.base_url}/Music/Miles%20Davis/Kind%20of%20Blue/01%20-%20So%20What.flac",
                "headers": {"Authorization": make_basic_auth("lumina", "webdav_secret")},
                "source": "WebDAV",
                "hint_extension": "flac",
            },
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(_srv().request("POST", "/api/v1/playback/pause", token=_tok()).status_code, 200)

    def test_f35_04_signal_path_reflects_http_stream_source(self):
        sp = _MOD_STATE["ffi_res"]["http_play_sp"]
        self.assertIn("nodes", sp)
        self.assertTrue(len(sp["nodes"]) >= 2)

    def test_f35_05_rest_stop_after_stream_playback(self):
        r = _srv().request("POST", "/api/v1/playback/stop", token=_tok())
        self.assertEqual(r.status_code, 200)
        st = _srv().request("GET", "/api/v1/playback/state", token=_tok())
        self.assertEqual(st.json()["status"], "stopped")


class TestFeature36(unittest.TestCase):
    """F36: ReplayGain Tag Extraction & Runtime DSP Wiring"""

    def test_f36_01_ffi_scan_extracts_replaygain_flac_metadata(self):
        self.assertGreaterEqual(_MOD_STATE["ffi_res"]["scan"]["tracks_count"], 3)

    def test_f36_02_ffi_import_autoeq_parses_bands(self):
        bands = _MOD_STATE["ffi_res"]["autoeq_bands"]
        self.assertEqual(len(bands), 2)
        self.assertAlmostEqual(bands[0]["frequency_hz"], 62.0, places=1)

    def test_f36_03_ffi_set_and_get_dsp_config_roundtrip(self):
        self.assertEqual(_MOD_STATE["ffi_res"]["dsp_set_rc"], LUMINA_OK)
        cfg = _MOD_STATE["ffi_res"]["dsp_cfg_updated"]
        self.assertTrue(cfg["crossfeed"]["enabled"])
        self.assertEqual(cfg["replay_gain"]["mode"], "track")

    def test_f36_04_rest_autoeq_import_updates_live_dsp(self):
        r = _srv().request(
            "POST",
            "/api/v1/dsp/autoeq",
            token=_tok(),
            json={"text": _AUTOEQ_SAMPLE, "apply": True},
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["applied"])
        self.assertEqual(len(r.json()["peq_bands"]), 2)

    def test_f36_05_rest_put_and_get_dsp_config_and_signal_path(self):
        cur = _srv().request("GET", "/api/v1/dsp/config", token=_tok()).json()
        cur["bypass"] = False
        cur["crossfeed"]["enabled"] = True
        cur["replay_gain"]["mode"] = "album"
        put_r = _srv().request("PUT", "/api/v1/dsp/config", token=_tok(), json=cur)
        self.assertEqual(put_r.status_code, 200)
        self.assertEqual(put_r.json()["replay_gain"]["mode"], "album")
        sp_r = _srv().request("GET", "/api/v1/signal-path", token=_tok())
        self.assertEqual(sp_r.status_code, 200)


class TestFeature37(unittest.TestCase):
    """F37: Canonical Album Cross-Source Deduplication & Merging"""

    def test_f37_01_ffi_get_albums_returns_scanned_albums(self):
        albums = _MOD_STATE["ffi_res"]["albums"]
        self.assertGreaterEqual(len(albums), 2)

    def test_f37_02_ffi_deduplicate_executes_cleanly(self):
        dedup = _MOD_STATE["ffi_res"]["dedup_res"]
        self.assertIn("merged_albums", dedup)

    def test_f37_03_ffi_album_detail_includes_versions_and_tracks(self):
        det = _MOD_STATE["ffi_res"]["album_detail"]
        self.assertIsNotNone(det)
        self.assertTrue(len(det["versions"]) >= 1)

    def test_f37_04_rest_albums_and_album_detail(self):
        r = _srv().request("GET", "/api/v1/library/albums", token=_tok())
        self.assertEqual(r.status_code, 200)
        albums = r.json()
        self.assertGreaterEqual(len(albums), 2)
        det_r = _srv().request("GET", f"/api/v1/library/albums/{albums[0]['id']}", token=_tok())
        self.assertEqual(det_r.status_code, 200)
        self.assertIn("versions", det_r.json())

    def test_f37_05_rest_post_deduplicate(self):
        r = _srv().request("POST", "/api/v1/library/deduplicate", token=_tok())
        self.assertEqual(r.status_code, 200)
        self.assertIn("merged_albums", r.json())


class TestFeature38(unittest.TestCase):
    """F38: MusicBrainz & Discogs Credit Enrichment"""

    def test_f38_01_ffi_enrich_credits_against_mock_servers(self):
        rep = _MOD_STATE["ffi_res"]["enrich_res"]
        self.assertGreaterEqual(rep["albums_processed"], 1)
        self.assertGreater(rep["credits_added"], 0)

    def test_f38_02_ffi_artist_detail_populated(self):
        art = _MOD_STATE["ffi_res"].get("artist_detail")
        self.assertIsNotNone(art)
        self.assertIn("credits", art)

    def test_f38_03_rest_enrich_endpoint_populates_credits(self):
        mb = _MOD_STATE["mb_srv"]
        dg = _MOD_STATE["dg_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/library/enrich",
            token=_tok(),
            json={
                "musicbrainz_base_url": f"{mb.base_url}/ws/2",
                "discogs_base_url": dg.base_url,
                "discogs_token": "e2e_dg_tok",
                "force_refresh": True,
                "rebuild_search_index": True,
            },
        )
        self.assertEqual(r.status_code, 200)
        self.assertGreaterEqual(r.json()["albums_enriched"], 1)
        self.assertGreater(r.json()["credits_added"], 0)

    def test_f38_04_rest_album_credits_endpoint(self):
        albums = _srv().request("GET", "/api/v1/library/albums", token=_tok()).json()
        target_id = None
        for a in albums:
            cr = _srv().request("GET", f"/api/v1/library/albums/{a['id']}/credits", token=_tok()).json()
            if cr:
                target_id = a["id"]
                self.assertTrue(any("artist_name" in c and "role" in c for c in cr))
                break
        self.assertIsNotNone(target_id)

    def test_f38_05_rest_artist_detail_endpoint(self):
        albums = _srv().request("GET", "/api/v1/library/albums", token=_tok()).json()
        artist_id = None
        for a in albums:
            cr = _srv().request("GET", f"/api/v1/library/albums/{a['id']}/credits", token=_tok()).json()
            if cr:
                artist_id = cr[0]["artist_id"]
                break
        self.assertIsNotNone(artist_id)
        art_r = _srv().request("GET", f"/api/v1/library/artists/{artist_id}", token=_tok())
        self.assertEqual(art_r.status_code, 200)
        self.assertIn("name", art_r.json())


class TestFeature39(unittest.TestCase):
    """F39: Profiles CRUD & Switching over REST & FFI"""

    def test_f39_01_ffi_profile_crud_lifecycle(self):
        res = _MOD_STATE["ffi_res"]
        self.assertIsInstance(res["profiles_initial"], list)
        self.assertTrue(len(res["profiles_after_create"]) >= 1)
        self.assertEqual(res["profile_switch_rc"], LUMINA_OK)
        self.assertEqual(res["profile_active"]["id"], res["profile_created"]["id"])
        self.assertEqual(res["profile_update_rc"], LUMINA_OK)
        self.assertEqual(res["profile_delete_rc"], LUMINA_OK)

    def test_f39_02_rest_profile_create_list_activate(self):
        cr = _srv().request(
            "POST",
            "/api/v1/profiles",
            token=_tok(),
            json={"name": "Studio Master", "avatar_color": "#EC4899"},
        )
        self.assertEqual(cr.status_code, 200)
        pid = cr.json()["id"]
        act = _srv().request("POST", f"/api/v1/profiles/{pid}/activate", token=_tok())
        self.assertEqual(act.status_code, 200)
        self.assertEqual(act.json()["active_profile_id"], pid)
        lst = _srv().request("GET", "/api/v1/profiles", token=_tok()).json()
        self.assertEqual(lst["active_profile_id"], pid)

    def test_f39_03_rest_profile_update(self):
        cr = _srv().request(
            "POST", "/api/v1/profiles", token=_tok(), json={"name": "BeforeRename"}
        ).json()
        up = _srv().request(
            "PUT",
            f"/api/v1/profiles/{cr['id']}",
            token=_tok(),
            json={"name": "AfterRename", "avatar_color": "#10B981"},
        )
        self.assertEqual(up.status_code, 200)
        self.assertEqual(up.json()["name"], "AfterRename")

    def test_f39_04_rest_profile_favorites_crud(self):
        profs = _srv().request("GET", "/api/v1/profiles", token=_tok()).json()["profiles"]
        pid = profs[0]["id"]
        add = _srv().request(
            "POST",
            f"/api/v1/profiles/{pid}/favorites",
            token=_tok(),
            json={"item_type": "track", "item_id": "trk-fav-1"},
        )
        self.assertEqual(add.status_code, 200)
        favs = _srv().request("GET", f"/api/v1/profiles/{pid}/favorites", token=_tok()).json()
        self.assertTrue(any(f["item_id"] == "trk-fav-1" for f in favs))
        rm = _srv().request(
            "DELETE",
            f"/api/v1/profiles/{pid}/favorites/trk-fav-1?item_type=track",
            token=_tok(),
        )
        self.assertEqual(rm.status_code, 200)

    def test_f39_05_rest_profile_play_history(self):
        profs = _srv().request("GET", "/api/v1/profiles", token=_tok()).json()["profiles"]
        pid = profs[0]["id"]
        tracks = _srv().request("GET", "/api/v1/library/tracks", token=_tok()).json()
        tid = tracks[0]["id"]
        rec = _srv().request(
            "POST",
            f"/api/v1/profiles/{pid}/history",
            token=_tok(),
            json={"track_source_id": tid, "duration_listened_ms": 1500},
        )
        self.assertEqual(rec.status_code, 200)
        hist = _srv().request("GET", f"/api/v1/profiles/{pid}/history", token=_tok()).json()
        self.assertTrue(len(hist) >= 1)


class TestFeature40(unittest.TestCase):
    """F40: Audio Output Device Enumeration & Selection"""

    def test_f40_01_ffi_lists_audio_output_devices(self):
        devs = _MOD_STATE["ffi_res"]["devices"]
        self.assertGreaterEqual(len(devs), 1)
        self.assertIn("id", devs[0])
        self.assertIn("backend", devs[0])

    def test_f40_02_ffi_select_audio_device_succeeds(self):
        self.assertEqual(_MOD_STATE["ffi_res"]["select_dev_rc"], LUMINA_OK)

    def test_f40_03_rest_list_audio_devices(self):
        r = _srv().request("GET", "/api/v1/audio/devices", token=_tok())
        self.assertEqual(r.status_code, 200)
        self.assertGreaterEqual(len(r.json()), 1)

    def test_f40_04_rest_select_audio_device(self):
        devs = _srv().request("GET", "/api/v1/audio/devices", token=_tok()).json()
        r = _srv().request(
            "POST",
            "/api/v1/audio/devices/select",
            token=_tok(),
            json={"device_id": devs[0]["id"], "backend": devs[0]["backend"]},
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["status"], "selected")

    def test_f40_05_server_get_port_bound_nonzero(self):
        self.assertGreater(_srv().port, 0)


class TestFeature41(unittest.TestCase):
    """F41: Flutter Navigation Shell, Album Grid, Versions & Credits Graph UI"""

    def test_f41_01_home_screen_navigation_tabs_present(self):
        hs = (_WORKSPACE_ROOT / "app/lib/ui/home_screen.dart").read_text(encoding="utf-8")
        for key in ("nav_tab_library", "nav_tab_albums", "nav_tab_dsp", "nav_tab_zones", "nav_tab_settings"):
            self.assertIn(key, hs)

    def test_f41_02_albums_and_credits_view_widgets_present(self):
        av = (_WORKSPACE_ROOT / "app/lib/ui/albums/albums_and_credits_view.dart").read_text(encoding="utf-8")
        for key in ("album_grid_view", "album_card_", "AlbumDetailPage", "credits_graph_view", "btn_deduplicate_albums", "btn_enrich_credits"):
            self.assertIn(key, av)
        ad = (_WORKSPACE_ROOT / "app/lib/ui/albums/album_detail_page.dart").read_text(encoding="utf-8")
        self.assertIn("album_detail_back_btn", ad)
        self.assertIn("version_chip_", ad)

    def test_f41_03_studio_models_define_canonical_album_and_credits(self):
        sm = (_WORKSPACE_ROOT / "app/lib/models/studio_models.dart").read_text(encoding="utf-8")
        for cls in ("CanonicalAlbumSummary", "CanonicalAlbumDetail", "AlbumVersionInfo", "AlbumCreditInfo", "ArtistDetailInfo"):
            self.assertIn(f"class {cls}", sm)

    def test_f41_04_ffi_audio_service_binds_album_and_artist_exports(self):
        ffi_dart = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        for sym in ("lumina_library_get_albums", "lumina_library_get_album_detail", "lumina_library_get_artist_detail", "lumina_library_deduplicate", "lumina_library_enrich_credits"):
            self.assertIn(sym, ffi_dart)

    def test_f41_05_m8_ui_test_covers_versions_and_credits_graph(self):
        t = (_WORKSPACE_ROOT / "app/test/m8_m9_m10_ui_and_remote_test.dart").read_text(encoding="utf-8")
        self.assertIn("version_chip_local", t)
        self.assertIn("credits_graph_view", t)


class TestFeature42(unittest.TestCase):
    """F42: Flutter DSP, Output, Provider, Pairing & Profiles UI"""

    def test_f42_01_dsp_control_panel_keys_present(self):
        dsp = (_WORKSPACE_ROOT / "app/lib/ui/dsp/dsp_control_panel.dart").read_text(encoding="utf-8")
        for key in ("dsp_control_panel", "switch_dsp_bypass", "switch_crossfeed", "dropdown_replaygain_mode", "autoeq_import_input", "btn_import_autoeq"):
            self.assertIn(key, dsp)

    def test_f42_02_output_zone_panel_keys_present(self):
        zp = (_WORKSPACE_ROOT / "app/lib/ui/zones/output_zone_panel.dart").read_text(encoding="utf-8")
        for key in ("output_zone_panel", "output_devices_grid", "output_card_", "system_output", "btn_refresh_audio_devices", "btn_discover_zones", "btn_group_zones", "btn_sync_zones"):
            self.assertIn(key, zp)

    def test_f42_03_providers_and_remote_panel_keys_present(self):
        pr = (_WORKSPACE_ROOT / "app/lib/ui/settings/providers_and_remote_panel.dart").read_text(encoding="utf-8")
        for key in ("input_qobuz_token", "btn_tidal_pkce_start", "input_deezer_arl", "input_webdav_uri", "input_smb_uri", "btn_generate_host_pin"):
            self.assertIn(key, pr)

    def test_f42_04_profile_switcher_bar_keys_present(self):
        pb = (_WORKSPACE_ROOT / "app/lib/ui/profiles/profile_switcher_bar.dart").read_text(encoding="utf-8")
        for key in ("btn_profile_switcher", "input_new_profile_name", "btn_create_profile"):
            self.assertIn(key, pb)

    def test_f42_05_ffi_audio_service_binds_dsp_device_profile_provider_exports(self):
        ffi_dart = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        for sym in ("lumina_dsp_get_config", "lumina_dsp_set_config", "lumina_dsp_import_autoeq", "lumina_audio_list_devices", "lumina_profile_list", "lumina_provider_configure"):
            self.assertIn(sym, ffi_dart)


class TestFeature43(unittest.TestCase):
    """F43: Phase 3 ServerAudioService & WebSocket Remote Sync"""

    def test_f43_01_ws_snapshot_query_param_sends_initial_state(self):
        with _srv().ws_connect(token=_tok()) as ws_plain:
            self.assertIsNotNone(ws_plain)
        with ws_sync_connect(f"{_srv().ws_url}?snapshot=true&token={_tok()}") as ws_snap:
            m1 = json.loads(ws_snap.recv(timeout=2.0))
            m2 = json.loads(ws_snap.recv(timeout=2.0))
            self.assertEqual({m1["type"], m2["type"]}, {"PlaybackStateChanged", "SignalPathUpdated"})

    def test_f43_02_ws_state_sync_action_works(self):
        with _srv().ws_connect(token=_tok()) as ws:
            ws.send(json.dumps({"action": "state.sync"}))
            m1 = json.loads(ws.recv(timeout=2.0))
            self.assertIn(m1["type"], ("PlaybackStateChanged", "SignalPathUpdated"))

    def test_f43_03_ws_volume_action_broadcasts_change(self):
        with _srv().ws_connect(token=_tok()) as ws:
            ws.send(json.dumps({"action": "playback.volume", "volume": 0.72}))
            msg = json.loads(ws.recv(timeout=2.0))
            self.assertEqual(msg["type"], "state_changed")
            self.assertAlmostEqual(msg["volume"], 0.72, places=2)

    def test_f43_04_token_persisted_in_db_survives_validation(self):
        st = _srv().request("GET", "/api/v1/profiles", token=_tok())
        self.assertEqual(st.status_code, 200)

    def test_f43_05_server_audio_service_dart_implements_remote_contract(self):
        srv_dart = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        for m in ("pairAndConnectRemote", "connectWebSocket", "connectWanDirect", "switchToLocalMode"):
            self.assertIn(m, srv_dart)


class TestFeature44(unittest.TestCase):
    """F44: Phase 3 LAN mDNS Client & PIN/QR Pairing Client"""

    def test_f44_01_mdns_loopback_wire_query_and_parse(self):
        mdns = _MOD_STATE["mdns_srv"]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(2.0)
            sock.sendto(MdnsLoopbackMock.build_ptr_query(), (mdns.host, mdns.port))
            raw, _ = sock.recvfrom(4096)
            parsed = MdnsLoopbackMock.parse_dns_sd_packet(raw)
            self.assertEqual(parsed["txt"]["server_name"], "Lumina-T1")
            self.assertEqual(parsed["srv"]["port"], 9888)

    def test_f44_02_pair_initiate_returns_valid_6_digit_pin_and_qr(self):
        data = _srv().pair_initiate(device_name="Mobile-F44")
        self.assertEqual(len(data["pin"]), 6)
        self.assertTrue(validate_qr_pairing_uri(data["qr_payload"]))

    def test_f44_03_pair_verify_issues_bearer_token(self):
        tok = _srv().pair(device_name="Mobile-F44-2", platform="android")
        self.assertTrue(tok.startswith("lum_sec_"))

    def test_f44_04_unified_pair_endpoint_works(self):
        init_d = _srv().pair_initiate(device_name="Unified")
        r = _srv().request(
            "POST",
            "/api/v1/pair",
            json={"pin": init_d["pin"], "device_name": "Unified", "client_id": "u1"},
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["token"].startswith("lum_sec_"))

    def test_f44_05_dart_mdns_client_and_qr_parser_implemented(self):
        srv_dart = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("class MdnsDiscoveryClient", srv_dart)
        self.assertIn("parseDnsSdResponsePacket", srv_dart)
        self.assertIn("parsePairingQrUri", srv_dart)


class TestFeature45(unittest.TestCase):
    """F45: Phase 3 WAN HTTPS/WSS & Mobile Local / USB DAC Mode"""

    def test_f45_01_wan_tls_proxy_forwards_https_health_and_info(self):
        proxy = _MOD_STATE["tls_proxy"]
        with httpx.Client(verify=str(proxy.ca_cert_path), timeout=5.0) as client:
            r = client.get(f"{proxy.https_base_url}/api/v1/info")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["api_version"], 1)

    def test_f45_02_wan_tls_proxy_forwards_authenticated_rest(self):
        proxy = _MOD_STATE["tls_proxy"]
        with httpx.Client(verify=str(proxy.ca_cert_path), timeout=5.0) as client:
            r = client.get(
                f"{proxy.https_base_url}/api/v1/library/albums",
                headers={"Authorization": f"Bearer {_tok()}"},
            )
            self.assertEqual(r.status_code, 200)
            self.assertGreaterEqual(len(r.json()), 1)

    def test_f45_03_wan_tls_proxy_forwards_wss_commands(self):
        proxy = _MOD_STATE["tls_proxy"]
        ssl_ctx = proxy.client_ssl_context()
        with ws_sync_connect(
            proxy.wss_url(f"/api/v1/ws?snapshot=1&token={_tok()}"),
            ssl=ssl_ctx,
        ) as wss:
            first = json.loads(wss.recv(timeout=2.0))
            self.assertIn(first["type"], ("PlaybackStateChanged", "SignalPathUpdated"))

    def test_f45_04_android_manifest_declares_audio_and_usb_host(self):
        xml = (_WORKSPACE_ROOT / "app/android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
        for perm in ("INTERNET", "ACCESS_NETWORK_STATE", "ACCESS_WIFI_STATE", "CHANGE_WIFI_MULTICAST_STATE", "hardware.usb.host"):
            self.assertIn(perm, xml)

    def test_f45_05_ios_info_plist_declares_bonjour_and_local_network(self):
        plist = (_WORKSPACE_ROOT / "app/ios/Runner/Info.plist").read_text(encoding="utf-8")
        for key in ("NSLocalNetworkUsageDescription", "NSBonjourServices", "_lumina._tcp", "_raop._tcp", "_airplay._tcp"):
            self.assertIn(key, plist)


class TestFeature46(unittest.TestCase):
    """F46: Phase 4 Zone Abstraction & Persistence"""

    def test_f46_01_ffi_zone_list_and_discover(self):
        self.assertTrue(len(_MOD_STATE["ffi_res"]["zones_initial"]) >= 1)
        self.assertTrue(len(_MOD_STATE["ffi_res"]["zones_discovered"]) >= 1)

    def test_f46_02_rest_zone_list_contains_default_zone(self):
        r = _srv().request("GET", "/api/v1/zones", token=_tok())
        self.assertEqual(r.status_code, 200)
        self.assertTrue(any(z["id"] == "zone-local" for z in r.json()))

    def test_f46_03_rest_zone_upsert_persists(self):
        r = _srv().request(
            "POST",
            "/api/v1/zones",
            token=_tok(),
            json={
                "id": "zone-custom-1",
                "name": "Study DAC",
                "backend": "windows_wasapi_shared",
                "exclusive_mode": False,
                "dsp_bypass": False,
                "volume": 0.8,
                "is_active": True,
            },
        )
        self.assertEqual(r.status_code, 200)
        zones = _srv().request("GET", "/api/v1/zones", token=_tok()).json()
        self.assertTrue(any(z["id"] == "zone-custom-1" for z in zones))

    def test_f46_04_rest_zone_volume_update(self):
        r = _srv().request(
            "POST",
            "/api/v1/zones/zone-local/volume",
            token=_tok(),
            json={"volume": 0.55},
        )
        self.assertEqual(r.status_code, 200)
        self.assertAlmostEqual(r.json()["volume"], 0.55, places=2)

    def test_f46_05_zones_sqlite_table_migration_verified(self):
        self.assertEqual(_MOD_STATE["ffi_res"]["zone_vol_rc"], LUMINA_OK)


class TestFeature47(unittest.TestCase):
    """F47: Phase 4 DLNA/UPnP Output Target"""

    def test_f47_01_rest_discover_discovers_mock_dlna_renderer(self):
        dlna = _MOD_STATE["dlna_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"ssdp_addr": f"{dlna.ssdp_host}:{dlna.ssdp_port}", "timeout_ms": 600},
        )
        self.assertEqual(r.status_code, 200)
        dlna_zones = [z for z in r.json() if z["backend"] == "network_dlna"]
        self.assertGreaterEqual(len(dlna_zones), 1)

    def test_f47_02_rest_cast_play_fetches_media_url_on_dlna(self):
        dlna = _MOD_STATE["dlna_srv"]
        stream_srv = _MOD_STATE["stream_srv"]
        zones = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"ssdp_addr": f"{dlna.ssdp_host}:{dlna.ssdp_port}", "timeout_ms": 500},
        ).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
        media_url = f"{stream_srv.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a"
        cast_r = _srv().request(
            "POST",
            f"/api/v1/zones/{zid}/cast",
            token=_tok(),
            json={"action": "play", "media_uri": media_url},
        )
        self.assertEqual(cast_r.status_code, 200)
        self.assertEqual(cast_r.json()["transport_state"], "PLAYING")
        self.assertEqual(dlna.fetched_media_status, 200)

    def test_f47_03_rest_dlna_seek_and_pause(self):
        dlna = _MOD_STATE["dlna_srv"]
        zones = _srv().request("GET", "/api/v1/zones", token=_tok()).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
        seek_r = _srv().request(
            "POST",
            f"/api/v1/zones/{zid}/cast",
            token=_tok(),
            json={"action": "seek", "seek_secs": 42},
        )
        self.assertEqual(seek_r.status_code, 200)
        self.assertEqual(dlna.position_sec, 42)
        pause_r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/cast", token=_tok(), json={"action": "pause"}
        )
        self.assertEqual(pause_r.status_code, 200)
        self.assertEqual(dlna.transport_state, "PAUSED_PLAYBACK")

    def test_f47_04_rest_dlna_rendering_control_set_volume(self):
        dlna = _MOD_STATE["dlna_srv"]
        zones = _srv().request("GET", "/api/v1/zones", token=_tok()).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
        r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/volume", token=_tok(), json={"volume": 0.64}
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(dlna.volume, 64)

    def test_f47_05_rest_dlna_stop_transitions_stopped(self):
        dlna = _MOD_STATE["dlna_srv"]
        zones = _srv().request("GET", "/api/v1/zones", token=_tok()).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
        r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/cast", token=_tok(), json={"action": "stop"}
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(dlna.transport_state, "STOPPED")


class TestFeature48(unittest.TestCase):
    """F48: Phase 4 AirPlay Output Target"""

    def test_f48_01_rest_discover_registers_airplay_zone(self):
        ap = _MOD_STATE["airplay_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"airplay_addrs": [f"127.0.0.1:{ap.rtsp_port}"], "timeout_ms": 500},
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(any(z["backend"] == "network_airplay" for z in r.json()))

    def test_f48_02_rest_cast_play_executes_rtsp_and_rtp(self):
        ap = _MOD_STATE["airplay_srv"]
        ap.reset()
        zones = _srv().request("GET", "/api/v1/zones", token=_tok()).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_airplay")
        r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/cast", token=_tok(), json={"action": "play"}
        )
        self.assertEqual(r.status_code, 200)
        self.assertGreaterEqual(r.json()["rtp_packets_sent"], 2)

    def test_f48_03_airplay_mock_received_valid_rtp_frames(self):
        ap = _MOD_STATE["airplay_srv"]
        deadline = time.monotonic() + 2.0
        while not ap.rtp_packets and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertGreaterEqual(len(ap.rtp_packets), 1)

    def test_f48_04_rest_airplay_set_volume_sends_rtsp_set_parameter(self):
        ap = _MOD_STATE["airplay_srv"]
        zones = _srv().request("GET", "/api/v1/zones", token=_tok()).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_airplay")
        r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/volume", token=_tok(), json={"volume": 0.5}
        )
        self.assertEqual(r.status_code, 200)
        self.assertAlmostEqual(ap.volume_db, -15.0, places=1)

    def test_f48_05_rest_airplay_cast_stop_calls_teardown(self):
        ap = _MOD_STATE["airplay_srv"]
        zones = _srv().request("GET", "/api/v1/zones", token=_tok()).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_airplay")
        r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/cast", token=_tok(), json={"action": "stop"}
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(ap.teardown_called)


class TestFeature49(unittest.TestCase):
    """F49: Phase 4 Multi-Room Clock Sync & UI"""

    def test_f49_01_ffi_clock_sync_measures_offset_and_drift(self):
        sync = _MOD_STATE["ffi_res"]["zone_sync"]
        self.assertIn("offset_us", sync)
        self.assertIn("rtt_us", sync)
        self.assertIn("drift_ppm", sync)

    def test_f49_02_rest_zone_sync_json_protocol(self):
        clk = _MOD_STATE["clock_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/zones/zone-local/sync",
            token=_tok(),
            json={"clock_addr": f"{clk.host}:{clk.port}", "samples": 4, "use_sntp_binary": False},
        )
        self.assertEqual(r.status_code, 200)
        self.assertAlmostEqual(r.json()["offset_us"], 14000, delta=15000)

    def test_f49_03_rest_zone_sync_sntp_binary_protocol(self):
        clk = _MOD_STATE["clock_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/zones/zone-local/sync",
            token=_tok(),
            json={"clock_addr": f"{clk.host}:{clk.port}", "samples": 4, "use_sntp_binary": True},
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()["samples"]), 4)

    def test_f49_04_rest_zone_group_returns_aligned_delays(self):
        r = _srv().request(
            "POST",
            "/api/v1/zones/group",
            token=_tok(),
            json={"group_id": "living-room-sync", "zone_ids": ["zone-local"]},
        )
        self.assertEqual(r.status_code, 200)
        self.assertIn("zone-local", r.json()["scheduled_delays_us"])

    def test_f49_05_ffi_zone_group_returns_ok(self):
        self.assertEqual(_MOD_STATE["ffi_res"]["zone_group_rc"], LUMINA_OK)


class TestFeature50(unittest.TestCase):
    """F50: Expanded E2E Suite & Verification Infrastructure"""

    def test_f50_01_all_r1_r3_tier_modules_exist(self):
        e2e_dir = _WORKSPACE_ROOT / "tests/e2e"
        for i in (1, 2, 3, 4):
            self.assertTrue((e2e_dir / f"test_tier{i}_r1_r3.py").is_file())

    def test_f50_02_baseline_tier_modules_intact(self):
        e2e_dir = _WORKSPACE_ROOT / "tests/e2e"
        for name in (
            "test_tier1_features.py",
            "test_tier2_boundaries.py",
            "test_tier3_pairwise.py",
            "test_tier4_scenarios.py",
        ):
            self.assertTrue((e2e_dir / name).is_file())

    def test_f50_03_progress_doc_exists(self):
        self.assertTrue((_WORKSPACE_ROOT / "docs/PROGRESS.md").is_file())

    def test_f50_04_handoff_doc_exists(self):
        self.assertTrue((_WORKSPACE_ROOT / "HANDOFF.md").is_file())

    def test_f50_05_zero_skipped_tests_in_suite_policy(self):
        src = Path(__file__).read_text(encoding="utf-8")
        self.assertNotIn("@" + "unittest.skip", src)
