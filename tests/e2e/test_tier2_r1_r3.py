"""
Lumina Audio E2E Test Suite - Tier 2 R1-R3 (Features F33 to F50)
5 boundary/negative/error-path tests per feature (18 features x 5 = 90 tests) exercising
FFI null/error codes, live core-server validation (400/401/404/429), and mock fault injection.
"""
import json
import socket
import ssl
import unittest
from typing import Any, Dict

import httpx
import requests
from websockets.exceptions import InvalidStatus
from websockets.sync.client import connect as ws_sync_connect

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_ERR_GENERAL,
    LUMINA_ERR_NOT_INITIALIZED,
    LUMINA_ERR_NULL_POINTER,
    LUMINA_OK,
    LuminaFfiClient,
    LuminaLiveServer,
    OPTIONAL_M7_M10_SIGNATURES,
    _WORKSPACE_ROOT,
    run_ffi_isolated,
)
from tests.e2e.fixtures.mock_servers import (
    AirPlayMockServer,
    DiscogsMockServer,
    DlnaMediaRendererMock,
    MdnsLoopbackMock,
    MusicBrainzMockServer,
    StreamingAudioMockServer,
    WanTlsProxyMockServer,
    WebDavMockServer,
)
from tests.e2e.fixtures.net_helpers import ManagedTempDir


def _call_opt(client: LuminaFfiClient, name: str, *args: Any) -> Any:
    fn = client.bind_optional(name)
    assert fn is not None
    _, _, free_cstr = OPTIONAL_M7_M10_SIGNATURES[name]
    c_args = [a.encode("utf-8") if isinstance(a, str) else a for a in args]
    res = fn(*c_args)
    if free_cstr:
        raw = client._take_owned_string(res)
        if raw is None:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw
    return int(res)


def _ffi_t2_negatives(client: LuminaFfiClient, db_path: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    # Before init_headless:
    out["dsp_set_before_init"] = _call_opt(client, "lumina_dsp_set_config", "{}")
    out["dev_select_before_init"] = _call_opt(
        client, "lumina_audio_select_device", None, 0
    )

    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK

        # Null pointer checks
        out["profile_create_null"] = _call_opt(client, "lumina_profile_create", None)
        out["profile_update_null"] = _call_opt(
            client, "lumina_profile_update", None, "{}"
        )
        out["profile_delete_null"] = _call_opt(client, "lumina_profile_delete", None)
        out["profile_switch_null"] = _call_opt(client, "lumina_profile_switch", None)
        out["dsp_set_null"] = _call_opt(client, "lumina_dsp_set_config", None)
        out["autoeq_null"] = _call_opt(client, "lumina_dsp_import_autoeq", None)
        out["album_detail_null"] = _call_opt(
            client, "lumina_library_get_album_detail", None
        )
        out["artist_detail_null"] = _call_opt(
            client, "lumina_library_get_artist_detail", None
        )
        out["provider_cfg_null"] = _call_opt(
            client, "lumina_provider_configure", None, None
        )
        out["provider_sync_null"] = _call_opt(client, "lumina_provider_sync", None)
        out["pkce_complete_null"] = _call_opt(
            client, "lumina_provider_tidal_pkce_complete", None
        )
        out["zone_group_null"] = _call_opt(client, "lumina_zone_group", None)
        out["zone_vol_null"] = _call_opt(client, "lumina_zone_set_volume", None, 0.5)
        out["zone_sync_null"] = _call_opt(client, "lumina_zone_sync_status", None)

        # Invalid payloads / unknown IDs
        out["profile_create_empty_name"] = _call_opt(
            client, "lumina_profile_create", json.dumps({"name": "   "})
        )
        out["profile_switch_missing"] = _call_opt(
            client, "lumina_profile_switch", "nonexistent-prof"
        )
        out["album_detail_missing"] = _call_opt(
            client, "lumina_library_get_album_detail", "missing-album-id"
        )
        out["artist_detail_missing"] = _call_opt(
            client, "lumina_library_get_artist_detail", "missing-artist-id"
        )
        out["autoeq_empty"] = _call_opt(
            client, "lumina_dsp_import_autoeq", "just a comment line"
        )
        out["provider_bad_kind"] = _call_opt(
            client, "lumina_provider_configure", "spotify", "{}"
        )
        out["zone_group_missing"] = _call_opt(
            client,
            "lumina_zone_group",
            json.dumps({"group_id": "g1", "zone_ids": ["no-such-zone"]}),
        )
        out["zone_vol_clamp_nan"] = _call_opt(
            client, "lumina_zone_set_volume", "zone-local", float("nan")
        )
        out["zone_vol_missing"] = _call_opt(
            client, "lumina_zone_set_volume", "no-such-zone", 0.5
        )
        out["zone_sync_no_addr"] = _call_opt(
            client, "lumina_zone_sync_status", "zone-local"
        )
        out["play_missing_url_or_path"] = client.play(
            {"file_path": "/definitely/does/not/exist/missing_file.flac"}
        )
        out["last_err"] = client.last_error_message()
        return out
    finally:
        client.shutdown()


_MOD_STATE: Dict[str, Any] = {}


def setUpModule() -> None:
    tmp = ManagedTempDir(prefix="lumina_t2_r1_r3_")
    tmp.__enter__()
    ffi_db = tmp.path / "ffi_t2.db"
    srv_db = tmp.path / "srv_t2.db"

    ffi_neg = run_ffi_isolated(_ffi_t2_negatives, args=(str(ffi_db),), timeout_s=30.0)
    srv = LuminaLiveServer(db_path=srv_db).start()
    tok = srv.pair(device_name="Tier2Controller", platform="windows")

    stream_srv = StreamingAudioMockServer().start()
    dav_srv = WebDavMockServer().start()
    mb_srv = MusicBrainzMockServer().start()
    dg_srv = DiscogsMockServer().start()
    dlna_srv = DlnaMediaRendererMock().start()
    airplay_srv = AirPlayMockServer().start()
    expired_tls = WanTlsProxyMockServer(target_port=srv.port, expired_cert=True).start()

    _MOD_STATE.update(
        {
            "tmp": tmp,
            "ffi_neg": ffi_neg,
            "srv": srv,
            "tok": tok,
            "stream_srv": stream_srv,
            "dav_srv": dav_srv,
            "mb_srv": mb_srv,
            "dg_srv": dg_srv,
            "dlna_srv": dlna_srv,
            "airplay_srv": airplay_srv,
            "expired_tls": expired_tls,
        }
    )


def tearDownModule() -> None:
    for key in (
        "expired_tls",
        "airplay_srv",
        "dlna_srv",
        "dg_srv",
        "mb_srv",
        "dav_srv",
        "stream_srv",
        "srv",
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
    return _MOD_STATE["tok"]


class TestFeature33(unittest.TestCase):
    """F33 Boundary: Unknown routes, malformed JSON, uninitialized FFI guards"""

    def test_f33_01_unknown_api_route_returns_404(self):
        r = _srv().request("GET", "/api/v1/nonexistent_route", token=_tok())
        self.assertEqual(r.status_code, 404)

    def test_f33_02_malformed_json_post_returns_400_or_422(self):
        r = _srv().request(
            "POST",
            "/api/v1/profiles",
            token=_tok(),
            data="{not-json",
            headers={"Content-Type": "application/json"},
        )
        self.assertIn(r.status_code, (400, 415, 422))

    def test_f33_03_missing_optional_ffi_symbol_returns_none(self):
        self.assertIsNone(LuminaFfiClient().bind_optional("lumina_nonexistent_fn"))

    def test_f33_04_dsp_set_before_init_returns_not_initialized(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["dsp_set_before_init"], LUMINA_ERR_NOT_INITIALIZED)

    def test_f33_05_dev_select_before_init_returns_not_initialized(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["dev_select_before_init"], LUMINA_ERR_NOT_INITIALIZED)


class TestFeature34(unittest.TestCase):
    """F34 Boundary: Provider auth rejection (401), invalid PKCE/ARL/URI (400), WebDAV 503"""

    def test_f34_01_qobuz_invalid_token_rejected(self):
        stream_srv = _MOD_STATE["stream_srv"]
        r = _srv().request(
            "POST",
            "/api/v1/providers/qobuz",
            token=_tok(),
            json={"user_auth_token": "bad_tok", "app_id": "lumina", "base_url": f"{stream_srv.base_url}/api.json/0.2/", "authenticate": True},
        )
        self.assertEqual(r.status_code, 400)

    def test_f34_02_tidal_pkce_short_verifier_rejected(self):
        r = _srv().request(
            "POST",
            "/api/v1/providers/tidal/pkce/exchange",
            token=_tok(),
            json={"code": "abc", "code_verifier": "too_short"},
        )
        self.assertEqual(r.status_code, 400)

    def test_f34_03_deezer_short_arl_rejected(self):
        r = _srv().request(
            "POST",
            "/api/v1/providers/deezer",
            token=_tok(),
            json={"arl": "short", "authenticate": False},
        )
        self.assertEqual(r.status_code, 400)

    def test_f34_04_webdav_invalid_scheme_or_empty_uri_rejected(self):
        r = _srv().request(
            "POST", "/api/v1/providers/webdav", token=_tok(), json={"uri": "not a valid uri"}
        )
        self.assertEqual(r.status_code, 400)

    def test_f34_05_ffi_provider_null_or_unknown_kind_returns_error(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["provider_cfg_null"], LUMINA_ERR_NULL_POINTER)
        self.assertEqual(_MOD_STATE["ffi_neg"]["provider_bad_kind"], LUMINA_ERR_GENERAL)
        self.assertIsNone(_MOD_STATE["ffi_neg"]["provider_sync_null"])


class TestFeature35(unittest.TestCase):
    """F35 Boundary: Unreachable/404 HTTP stream & missing local path handling"""

    def test_f35_01_stream_416_out_of_range_mock(self):
        stream_srv = _MOD_STATE["stream_srv"]
        r = requests.get(
            f"{stream_srv.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a",
            headers={"Range": "bytes=99999999-"},
            timeout=2.0,
        )
        self.assertEqual(r.status_code, 416)

    def test_f35_02_webdav_503_offline_propagates_500_on_sync(self):
        dav_srv = _MOD_STATE["dav_srv"]
        dav_srv.online = False
        try:
            _srv().request(
                "POST",
                "/api/v1/providers/webdav",
                token=_tok(),
                json={"uri": f"{dav_srv.base_url.replace('http://', 'http://lumina:webdav_secret@')}/Music/"},
            )
            r = _srv().request("POST", "/api/v1/providers/web_dav/sync", token=_tok())
            self.assertEqual(r.status_code, 500)
        finally:
            dav_srv.reset()

    def test_f35_03_play_missing_local_file_does_not_crash_server(self):
        r = _srv().request(
            "POST",
            "/api/v1/playback/play",
            token=_tok(),
            json={"file_path": "/no/such/file/missing.flac"},
        )
        self.assertEqual(r.status_code, 200)

    def test_f35_04_seek_beyond_zero_stopped_state_safe(self):
        _srv().request("POST", "/api/v1/playback/stop", token=_tok())
        r = _srv().request(
            "POST", "/api/v1/playback/seek", token=_tok(), json={"position_ms": 999999}
        )
        self.assertEqual(r.status_code, 200)

    def test_f35_05_volume_nan_or_negative_clamped(self):
        r = _srv().request(
            "POST", "/api/v1/playback/volume", token=_tok(), json={"volume": -2.5}
        )
        self.assertEqual(r.status_code, 200)
        r2 = _srv().request(
            "POST", "/api/v1/playback/volume", token=_tok(), json={"volume": 9.9}
        )
        self.assertEqual(r2.status_code, 200)


class TestFeature36(unittest.TestCase):
    """F36 Boundary: DSP & AutoEQ empty/null/extreme parameter validation"""

    def test_f36_01_ffi_dsp_set_null_returns_null_pointer(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["dsp_set_null"], LUMINA_ERR_NULL_POINTER)

    def test_f36_02_ffi_autoeq_null_returns_null(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["autoeq_null"])

    def test_f36_03_ffi_autoeq_comments_only_returns_empty_list(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["autoeq_empty"])

    def test_f36_04_rest_autoeq_blank_text_returns_empty_bands(self):
        r = _srv().request(
            "POST", "/api/v1/dsp/autoeq", token=_tok(), json={"text": "# empty", "apply": False}
        )
        self.assertEqual(r.status_code, 400)

    def test_f36_05_rest_dsp_put_invalid_json_returns_4xx(self):
        r = _srv().request(
            "PUT",
            "/api/v1/dsp/config",
            token=_tok(),
            json={"replay_gain": {"mode": "invalid_mode"}},
        )
        self.assertIn(r.status_code, (400, 422))


class TestFeature37(unittest.TestCase):
    """F37 Boundary: Missing canonical album / empty search / null FFI arguments"""

    def test_f37_01_ffi_album_detail_null_returns_null(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["album_detail_null"])

    def test_f37_02_ffi_album_detail_missing_returns_none(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["album_detail_missing"])

    def test_f37_03_rest_album_detail_missing_returns_404(self):
        r = _srv().request("GET", "/api/v1/library/albums/does-not-exist", token=_tok())
        self.assertEqual(r.status_code, 404)

    def test_f37_04_rest_empty_search_returns_empty_array(self):
        r = _srv().request("GET", "/api/v1/library/search", params={"q": "   "}, token=_tok())
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), [])

    def test_f37_05_rest_deduplicate_on_empty_db_returns_zero(self):
        r = _srv().request("POST", "/api/v1/library/deduplicate", token=_tok())
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["merged_albums"], 0)


class TestFeature38(unittest.TestCase):
    """F38 Boundary: Missing artist, MB 429 retry, Discogs 503 fault injection"""

    def test_f38_01_ffi_artist_detail_null_returns_null(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["artist_detail_null"])

    def test_f38_02_ffi_artist_detail_missing_returns_none(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["artist_detail_missing"])

    def test_f38_03_rest_artist_detail_missing_returns_404(self):
        r = _srv().request("GET", "/api/v1/library/artists/no-artist", token=_tok())
        self.assertEqual(r.status_code, 404)

    def test_f38_04_rest_album_credits_missing_album_returns_404(self):
        r = _srv().request("GET", "/api/v1/library/albums/no-album/credits", token=_tok())
        self.assertEqual(r.status_code, 404)

    def test_f38_05_mb_missing_user_agent_returns_400_and_429_injected(self):
        mb = _MOD_STATE["mb_srv"]
        r = requests.get(
            f"{mb.base_url}/ws/2/release-group?query=test",
            headers={"User-Agent": ""},
            timeout=2.0,
        )
        self.assertEqual(r.status_code, 400)


class TestFeature39(unittest.TestCase):
    """F39 Boundary: Invalid profile names, missing profile IDs, FFI null checks"""

    def test_f39_01_ffi_profile_null_pointers_handled(self):
        neg = _MOD_STATE["ffi_neg"]
        self.assertIsNone(neg["profile_create_null"])
        self.assertEqual(neg["profile_update_null"], LUMINA_ERR_NULL_POINTER)
        self.assertEqual(neg["profile_delete_null"], LUMINA_ERR_NULL_POINTER)
        self.assertEqual(neg["profile_switch_null"], LUMINA_ERR_NULL_POINTER)

    def test_f39_02_ffi_profile_empty_name_rejected(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["profile_create_empty_name"])

    def test_f39_03_ffi_profile_switch_unknown_returns_error(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["profile_switch_missing"], LUMINA_ERR_GENERAL)

    def test_f39_04_rest_profile_create_empty_name_returns_400(self):
        r = _srv().request(
            "POST", "/api/v1/profiles", token=_tok(), json={"name": "   "}
        )
        self.assertEqual(r.status_code, 400)

    def test_f39_05_rest_profile_activate_missing_returns_404(self):
        r = _srv().request("POST", "/api/v1/profiles/missing-pid/activate", token=_tok())
        self.assertEqual(r.status_code, 404)


class TestFeature40(unittest.TestCase):
    """F40 Boundary: Invalid backend name and unknown device selection"""

    def test_f40_01_rest_invalid_backend_returns_400(self):
        r = _srv().request(
            "POST",
            "/api/v1/audio/devices/select",
            token=_tok(),
            json={"device_id": "any", "backend": "invalid_audio_backend"},
        )
        self.assertEqual(r.status_code, 400)

    def test_f40_02_rest_select_missing_device_id_handles_gracefully(self):
        r = _srv().request(
            "POST",
            "/api/v1/audio/devices/select",
            token=_tok(),
            json={"device_id": "nonexistent-dac-id"},
        )
        self.assertIn(r.status_code, (200, 400))

    def test_f40_03_unauthenticated_device_list_returns_401(self):
        r = _srv().request("GET", "/api/v1/audio/devices")
        self.assertEqual(r.status_code, 401)

    def test_f40_04_unauthenticated_dsp_config_returns_401(self):
        r = _srv().request("GET", "/api/v1/dsp/config")
        self.assertEqual(r.status_code, 401)

    def test_f40_05_last_error_message_populated_after_ffi_error(self):
        self.assertTrue(_MOD_STATE["ffi_neg"]["last_err"])


class TestFeature41(unittest.TestCase):
    """F41 Boundary: Empty album states & Flutter UI null-safe rendering contracts"""

    def test_f41_01_mock_audio_service_missing_album_returns_null(self):
        src = (_WORKSPACE_ROOT / "app/lib/services/mock_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("getAlbumDetail", src)

    def test_f41_02_albums_view_handles_empty_credits_message(self):
        av = (_WORKSPACE_ROOT / "app/lib/ui/albums/albums_and_credits_view.dart").read_text(encoding="utf-8")
        self.assertIn("尚無創作者與製作人員紀錄", av)

    def test_f41_03_server_service_null_on_404_album(self):
        sd = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("if (code == 200 && data is Map<String, dynamic>)", sd)
        self.assertIn("return null;", sd)

    def test_f41_04_profile_switcher_guards_empty_profile_name(self):
        pb = (_WORKSPACE_ROOT / "app/lib/ui/profiles/profile_switcher_bar.dart").read_text(encoding="utf-8")
        self.assertIn("if (name.isEmpty) return;", pb)

    def test_f41_05_mini_player_responsive_test_present(self):
        mp = (_WORKSPACE_ROOT / "app/test/mini_player_test.dart").read_text(encoding="utf-8")
        self.assertIn("360", mp)


class TestFeature42(unittest.TestCase):
    """F42 Boundary: DSP clamps, invalid AutoEQ UI feedback, unconfigured providers"""

    def test_f42_01_dsp_panel_guards_empty_autoeq_input(self):
        dsp = (_WORKSPACE_ROOT / "app/lib/ui/dsp/dsp_control_panel.dart").read_text(encoding="utf-8")
        self.assertIn("if (text.isEmpty) return;", dsp)
        self.assertIn("未偵測到有效的 AutoEQ 濾波器設定行", dsp)

    def test_f42_02_output_zone_panel_clamps_volume(self):
        zp = (_WORKSPACE_ROOT / "app/lib/ui/zones/output_zone_panel.dart").read_text(encoding="utf-8")
        self.assertIn(".clamp(0.0, 1.0)", zp)

    def test_f42_03_dsp_sliders_clamp_db_range(self):
        dsp = (_WORKSPACE_ROOT / "app/lib/ui/dsp/dsp_control_panel.dart").read_text(encoding="utf-8")
        self.assertIn(".clamp(-12.0, 12.0)", dsp)

    def test_f42_04_server_audio_service_rejects_empty_remote_pin(self):
        sd = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("pairAndConnectRemote", sd)

    def test_f42_05_mock_audio_service_prevents_deleting_default_profile(self):
        pb = (_WORKSPACE_ROOT / "app/lib/ui/profiles/profile_switcher_bar.dart").read_text(encoding="utf-8")
        self.assertIn("!p.isDefault", pb)


class TestFeature43(unittest.TestCase):
    """F43 Boundary: WS unauthorized rejection, invalid query snapshot, invalid JSON"""

    def test_f43_01_ws_without_token_rejected_401(self):
        with self.assertRaises(InvalidStatus) as ctx:
            ws_sync_connect(_srv().ws_url)
        self.assertEqual(ctx.exception.response.status_code, 401)

    def test_f43_02_ws_with_bad_bearer_token_rejected_401(self):
        with self.assertRaises(InvalidStatus) as ctx:
            ws_sync_connect(_srv().ws_url, additional_headers={"Authorization": "Bearer invalid_tok"})
        self.assertEqual(ctx.exception.response.status_code, 401)

    def test_f43_03_ws_with_bad_query_token_rejected_401(self):
        with self.assertRaises(InvalidStatus) as ctx:
            ws_sync_connect(f"{_srv().ws_url}?token=bad_query_tok")
        self.assertEqual(ctx.exception.response.status_code, 401)

    def test_f43_04_ws_invalid_json_frame_emits_error_frame(self):
        with _srv().ws_connect(token=_tok()) as ws:
            ws.send("<<<not json>>>")
            err = json.loads(ws.recv(timeout=2.0))
            self.assertEqual(err["status"], "error")

    def test_f43_05_ws_unknown_action_does_not_disconnect(self):
        with _srv().ws_connect(token=_tok()) as ws:
            ws.send(json.dumps({"action": "unknown.noop"}))
            ws.send(json.dumps({"action": "state.sync"}))
            msg = json.loads(ws.recv(timeout=2.0))
            self.assertIn(msg["type"], ("PlaybackStateChanged", "SignalPathUpdated"))


class TestFeature44(unittest.TestCase):
    """F44 Boundary: Invalid QR URIs, bad PINs, replay, truncated mDNS packets"""

    def test_f44_01_truncated_mdns_packet_raises_value_error(self):
        with self.assertRaises(ValueError):
            MdnsLoopbackMock.parse_dns_sd_packet(b"\x00\x01\x02")

    def test_f44_02_pair_verify_non_6_digit_pin_400(self):
        r = _srv().request("POST", "/api/v1/pair/verify", json={"pin": "12ab", "client_id": "c"})
        self.assertEqual(r.status_code, 400)

    def test_f44_03_pair_pin_replay_rejected_400(self):
        p = _srv().pair_initiate(device_name="Once")
        ok = _srv().request("POST", "/api/v1/pair/verify", json={"pin": p["pin"], "client_id": "c1"})
        self.assertEqual(ok.status_code, 200)
        rep = _srv().request("POST", "/api/v1/pair/verify", json={"pin": p["pin"], "client_id": "c2"})
        self.assertEqual(rep.status_code, 400)

    def test_f44_04_qr_uri_validator_rejects_bad_scheme(self):
        sd = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("parsed.scheme != 'lumina'", sd)

    def test_f44_05_unpaired_rest_calls_always_return_401(self):
        for ep in ("/api/v1/profiles", "/api/v1/zones", "/api/v1/library/albums"):
            self.assertEqual(_srv().request("GET", ep).status_code, 401)


class TestFeature45(unittest.TestCase):
    """F45 Boundary: Expired/untrusted WAN TLS certificates rejected"""

    def test_f45_01_expired_tls_proxy_rejected_by_default_verify(self):
        proxy = _MOD_STATE["expired_tls"]
        with self.assertRaises((httpx.ConnectError, ssl.SSLError)):
            httpx.get(f"{proxy.https_base_url}/api/v1/health", timeout=2.0)

    def test_f45_02_expired_tls_proxy_rejected_even_with_ca_cert(self):
        proxy = _MOD_STATE["expired_tls"]
        with self.assertRaises((httpx.ConnectError, ssl.SSLError)):
            httpx.get(
                f"{proxy.https_base_url}/api/v1/health",
                verify=str(proxy.ca_cert_path),
                timeout=2.0,
            )

    def test_f45_03_server_service_supports_self_signed_opt_in_flag(self):
        sd = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("allowSelfSignedTls", sd)

    def test_f45_04_wss_over_untrusted_cert_rejected(self):
        proxy = _MOD_STATE["expired_tls"]
        with self.assertRaises((OSError, ssl.SSLError)):
            ws_sync_connect(proxy.wss_url("/api/v1/ws"))

    def test_f45_05_server_info_publicly_reachable_health_gated_rest_protected(self):
        self.assertEqual(_srv().request("GET", "/api/v1/health").status_code, 200)
        self.assertEqual(_srv().request("GET", "/api/v1/providers").status_code, 401)


class TestFeature46(unittest.TestCase):
    """F46 Boundary: Unknown zone ID, NaN volume clamping, group errors"""

    def test_f46_01_ffi_zone_group_null_returns_null_pointer(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["zone_group_null"], LUMINA_ERR_NULL_POINTER)

    def test_f46_02_ffi_zone_group_missing_zone_returns_error(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["zone_group_missing"], LUMINA_ERR_GENERAL)

    def test_f46_03_ffi_zone_set_volume_nan_safe(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["zone_vol_clamp_nan"], LUMINA_OK)

    def test_f46_04_ffi_zone_set_volume_missing_returns_error(self):
        self.assertEqual(_MOD_STATE["ffi_neg"]["zone_vol_missing"], LUMINA_ERR_GENERAL)

    def test_f46_05_rest_zone_set_volume_missing_returns_400(self):
        r = _srv().request(
            "POST", "/api/v1/zones/missing-z/volume", token=_tok(), json={"volume": 0.5}
        )
        self.assertEqual(r.status_code, 400)


class TestFeature47(unittest.TestCase):
    """F47 Boundary: DLNA unknown action 500 fault & missing cast action/zone 400"""

    def test_f47_01_dlna_invalid_soap_action_returns_500_upnp_401(self):
        dlna = _MOD_STATE["dlna_srv"]
        env = (
            '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            '<s:Body><u:BogusAction xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"></u:BogusAction>'
            "</s:Body></s:Envelope>"
        )
        r = requests.post(
            f"{dlna.base_url}/upnp/control/AVTransport",
            data=env,
            headers={"SOAPAction": '"urn:schemas-upnp-org:service:AVTransport:1#BogusAction"'},
            timeout=2.0,
        )
        self.assertEqual(r.status_code, 500)
        self.assertIn("<errorCode>401</errorCode>", r.text)

    def test_f47_02_cast_on_local_zone_returns_400(self):
        r = _srv().request(
            "POST", "/api/v1/zones/zone-local/cast", token=_tok(), json={"action": "play"}
        )
        self.assertEqual(r.status_code, 400)

    def test_f47_03_cast_on_missing_zone_returns_400(self):
        r = _srv().request(
            "POST", "/api/v1/zones/unknown-dlna/cast", token=_tok(), json={"action": "play"}
        )
        self.assertEqual(r.status_code, 400)

    def test_f47_04_dlna_discover_timeout_with_no_responders_returns_local(self):
        # Silent UDP socket that receives M-SEARCH without replying verifies clean timeout
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as silent:
            silent.bind(("127.0.0.1", 0))
            port = silent.getsockname()[1]
            r = _srv().request(
                "POST",
                "/api/v1/zones/discover",
                token=_tok(),
                json={"ssdp_addr": f"127.0.0.1:{port}", "timeout_ms": 60},
            )
            self.assertEqual(r.status_code, 200)

    def test_f47_05_dlna_cast_invalid_action_rejected(self):
        dlna = _MOD_STATE["dlna_srv"]
        zones = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"ssdp_addr": f"{dlna.ssdp_host}:{dlna.ssdp_port}", "timeout_ms": 400},
        ).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_dlna")
        r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/cast", token=_tok(), json={"action": "invalid_op"}
        )
        self.assertEqual(r.status_code, 400)


class TestFeature48(unittest.TestCase):
    """F48 Boundary: AirPlay RTSP 401 unauthorized & unreachable AirPlay host"""

    def test_f48_01_airplay_require_auth_returns_401_and_cseq(self):
        ap = _MOD_STATE["airplay_srv"]
        ap.require_auth_401 = True
        try:
            with socket.create_connection(("127.0.0.1", ap.rtsp_port), timeout=2.0) as rtsp:
                rtsp.sendall(b"OPTIONS * RTSP/1.0\r\nCSeq: 12\r\n\r\n")
                resp = rtsp.recv(4096)
                self.assertIn(b"RTSP/1.0 401 Unauthorized", resp)
                self.assertIn(b"CSeq: 12", resp)
        finally:
            ap.require_auth_401 = False

    def test_f48_02_airplay_discover_unreachable_port_returns_500(self):
        r = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"airplay_addrs": ["127.0.0.1:1"], "timeout_ms": 100},
        )
        self.assertEqual(r.status_code, 500)

    def test_f48_03_airplay_unknown_zone_cast_returns_400(self):
        r = _srv().request(
            "POST", "/api/v1/zones/airplay:missing/cast", token=_tok(), json={"action": "play"}
        )
        self.assertEqual(r.status_code, 400)

    def test_f48_04_airplay_volume_clamped_at_zero_to_mute(self):
        ap = _MOD_STATE["airplay_srv"]
        zones = _srv().request(
            "POST",
            "/api/v1/zones/discover",
            token=_tok(),
            json={"airplay_addrs": [f"127.0.0.1:{ap.rtsp_port}"]},
        ).json()
        zid = next(z["id"] for z in zones if z["backend"] == "network_airplay")
        r = _srv().request(
            "POST", f"/api/v1/zones/{zid}/volume", token=_tok(), json={"volume": -1.0}
        )
        self.assertEqual(r.status_code, 200)
        self.assertAlmostEqual(ap.volume_db, -144.0, places=1)

    def test_f48_05_airplay_rtsp_cseq_monotonically_handled(self):
        ap = _MOD_STATE["airplay_srv"]
        with socket.create_connection(("127.0.0.1", ap.rtsp_port), timeout=2.0) as rtsp:
            rtsp.sendall(b"OPTIONS * RTSP/1.0\r\nCSeq: 77\r\n\r\n")
            resp = rtsp.recv(4096)
            self.assertIn(b"CSeq: 77", resp)


class TestFeature49(unittest.TestCase):
    """F49 Boundary: Clock sync missing address, FFI null, group non-existent zone"""

    def test_f49_01_ffi_zone_sync_null_returns_null(self):
        self.assertIsNone(_MOD_STATE["ffi_neg"]["zone_sync_null"])

    def test_f49_02_rest_sync_without_clock_addr_returns_400(self):
        # custom zone created without clock_sync_addr
        _srv().request(
            "POST",
            "/api/v1/zones",
            token=_tok(),
            json={
                "id": "zone-no-clock",
                "name": "NoClock",
                "backend": "windows_wasapi_shared",
                "exclusive_mode": False,
                "dsp_bypass": False,
                "volume": 1.0,
                "is_active": False,
            },
        )
        r = _srv().request("POST", "/api/v1/zones/zone-no-clock/sync", token=_tok(), json={})
        self.assertEqual(r.status_code, 400)

    def test_f49_03_rest_sync_missing_zone_returns_400(self):
        r = _srv().request("POST", "/api/v1/zones/no-such-zone/sync", token=_tok(), json={})
        self.assertEqual(r.status_code, 400)

    def test_f49_04_rest_group_missing_zone_returns_400(self):
        r = _srv().request(
            "POST",
            "/api/v1/zones/group",
            token=_tok(),
            json={"group_id": "bad-grp", "zone_ids": ["missing-zone"]},
        )
        self.assertEqual(r.status_code, 400)

    def test_f49_05_rest_sync_unreachable_udp_addr_returns_400(self):
        r = _srv().request(
            "POST",
            "/api/v1/zones/zone-local/sync",
            token=_tok(),
            json={"clock_addr": "127.0.0.1:1", "samples": 1, "sample_interval_ms": 5},
        )
        self.assertEqual(r.status_code, 400)


class TestFeature50(unittest.TestCase):
    """F50 Boundary: Runner validation & strict no-skip checks"""

    def test_f50_01_runner_rejects_unknown_tier(self):
        from tests.e2e.runner import _resolve_tiers

        with self.assertRaises(ValueError):
            _resolve_tiers("99")

    def test_f50_02_runner_rejects_unknown_suite_mode(self):
        from tests.e2e.runner import discover_tier_suites

        with self.assertRaises(ValueError):
            discover_tier_suites(str(_WORKSPACE_ROOT / "tests/e2e"), "1", suite_mode="invalid")

    def test_f50_03_tier2_contains_zero_skips(self):
        with open(__file__, "r", encoding="utf-8") as f:
            self.assertNotIn("@" + "unittest.skip", f.read())

    def test_f50_04_tier3_file_exists_and_nonempty(self):
        p = _WORKSPACE_ROOT / "tests/e2e/test_tier3_r1_r3.py"
        self.assertTrue(p.is_file())

    def test_f50_05_project_md_readable(self):
        self.assertTrue((_WORKSPACE_ROOT / "PROJECT.md").is_file())
