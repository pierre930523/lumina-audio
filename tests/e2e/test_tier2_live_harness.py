"""
Tier 2 Live Harness E2E Tests: Boundary, error, rate-limit, auth lockout, and fault-injection
tests against live core-server and loopback mock servers.
"""
import socket
import ssl
import unittest

import httpx
import requests

from tests.e2e.fixtures.ffi_harness import LuminaLiveServer
from tests.e2e.fixtures.mock_servers import (
    AirPlayMockServer,
    DiscogsMockServer,
    DlnaMediaRendererMock,
    MusicBrainzMockServer,
    StreamingAudioMockServer,
    WanTlsProxyMockServer,
    WebDavMockServer,
)
from tests.e2e.fixtures.net_helpers import ManagedTempDir


class TestTier2LiveHarness(unittest.TestCase):
    """Tier 2 real negative & fault-injection tests against live server and mocks."""

    def test_lh2_01_server_auth_and_pin_lockout(self):
        """Live core-server enforces 401 Bearer auth, 400 PIN format/replay, and 429 IP lockout."""
        with ManagedTempDir(prefix="lumina_lh2_01_") as tmp:
            with LuminaLiveServer(db_path=tmp / "auth.db") as srv:
                # 1. Missing and invalid Bearer tokens -> 401
                r_no_auth = srv.request("GET", "/api/v1/playback/state")
                self.assertEqual(r_no_auth.status_code, 401)
                r_bad_auth = srv.request(
                    "GET", "/api/v1/playback/state", token="lum_sec_invalid_token"
                )
                self.assertEqual(r_bad_auth.status_code, 401)

                # 2. Bad PIN format -> 400
                r_fmt = srv.request(
                    "POST",
                    "/api/v1/pair/verify",
                    json={"pin": "abc", "client_id": "bad-fmt"},
                )
                self.assertEqual(r_fmt.status_code, 400)

                # 3. Valid PIN consumed once, replay rejected -> 400
                init_data = srv.pair_initiate(device_name="ReplayCheck")
                valid_pin = init_data["pin"]
                r_ok = srv.request(
                    "POST",
                    "/api/v1/pair/verify",
                    json={"pin": valid_pin, "client_id": "c1"},
                )
                self.assertEqual(r_ok.status_code, 200)
                r_replay = srv.request(
                    "POST",
                    "/api/v1/pair/verify",
                    json={"pin": valid_pin, "client_id": "c2"},
                )
                self.assertEqual(r_replay.status_code, 400)

                # 4. 5 consecutive wrong PINs lock out the IP; the 6th returns 429 IpLockedOut
                lock_hdr = {"X-Forwarded-For": "10.99.88.77"}
                for i in range(5):
                    r_fail = srv.request(
                        "POST",
                        "/api/v1/pair/verify",
                        headers=lock_hdr,
                        json={"pin": "000000", "client_id": f"brute-{i}"},
                    )
                    self.assertEqual(r_fail.status_code, 400)

                r_lockout = srv.request(
                    "POST",
                    "/api/v1/pair/verify",
                    headers=lock_hdr,
                    json={"pin": "000000", "client_id": "brute-5"},
                )
                self.assertEqual(r_lockout.status_code, 429)

    def test_lh2_02_streaming_401_416_and_drm(self):
        """StreamingAudioMockServer enforces 401 auth, 400 PKCE, 416 Range, and DRM restrictions."""
        with StreamingAudioMockServer() as srv:
            # Bad Qobuz token -> 401
            r_qb = requests.get(
                f"{srv.base_url}/api.json/0.2/user/get",
                headers={"X-App-Id": "lumina", "X-User-Auth-Token": "wrong"},
                timeout=3.0,
            )
            self.assertEqual(r_qb.status_code, 401)

            # Short Tidal PKCE verifier -> 400
            r_tid = requests.post(
                f"{srv.base_url}/oauth2/token",
                data={"grant_type": "authorization_code", "code_verifier": "short"},
                timeout=3.0,
            )
            self.assertEqual(r_tid.status_code, 400)
            self.assertEqual(r_tid.json()["error"], "invalid_grant")

            # Bad Deezer ARL -> 401
            r_dz = requests.get(
                f"{srv.base_url}/ajax/gw-light.php",
                headers={"Cookie": "arl=too_short"},
                timeout=3.0,
            )
            self.assertEqual(r_dz.status_code, 401)

            # Out-of-bounds Range -> 416
            r_range = requests.get(
                f"{srv.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a",
                headers={"Range": "bytes=999999999-"},
                timeout=3.0,
            )
            self.assertEqual(r_range.status_code, 416)

            # DRM restriction injection
            srv.drm_restricted_ids.add("12049182")
            r_drm = requests.get(
                f"{srv.base_url}/api.json/0.2/track/getFileUrl",
                params={"track_id": "12049182"},
                headers={"X-App-Id": "lumina", "X-User-Auth-Token": "qb_usr_tok_99182371"},
                timeout=3.0,
            )
            self.assertEqual(r_drm.status_code, 200)
            self.assertTrue(len(r_drm.json()["restrictions"]) > 0)
            self.assertEqual(r_drm.json()["url"], "")

    def test_lh2_03_webdav_401_404_and_offline_503(self):
        """WebDavMockServer returns 401 Basic challenge, 404 missing file, 503 offline, and resets cleanly."""
        with WebDavMockServer() as dav:
            r_401 = requests.request(
                "PROPFIND",
                f"{dav.base_url}/Music/",
                headers={"Depth": "1"},
                timeout=3.0,
            )
            self.assertEqual(r_401.status_code, 401)
            self.assertIn("Basic", r_401.headers.get("WWW-Authenticate", ""))

            r_404 = requests.get(
                f"{dav.base_url}/Music/DoesNotExist.flac",
                auth=("lumina", "webdav_secret"),
                timeout=3.0,
            )
            self.assertEqual(r_404.status_code, 404)

            dav.online = False
            r_503 = requests.request(
                "PROPFIND",
                f"{dav.base_url}/Music/",
                auth=("lumina", "webdav_secret"),
                timeout=3.0,
            )
            self.assertEqual(r_503.status_code, 503)

            dav.reset()
            r_207 = requests.request(
                "PROPFIND",
                f"{dav.base_url}/Music/",
                auth=("lumina", "webdav_secret"),
                headers={"Depth": "1"},
                timeout=3.0,
            )
            self.assertEqual(r_207.status_code, 207)

    def test_lh2_04_metadata_429_retry_after_503(self):
        """MusicBrainz and Discogs mocks enforce User-Agent 400 and injected 429/503 faults."""
        with MusicBrainzMockServer() as mb, DiscogsMockServer() as dg:
            # Missing User-Agent -> 400
            r_no_ua = requests.get(
                f"{mb.base_url}/ws/2/artist/83d91898-7763-47d7-b03b-b92132375c47",
                headers={"User-Agent": ""},
                timeout=3.0,
            )
            self.assertEqual(r_no_ua.status_code, 400)

            ua = {"User-Agent": "LuminaAudioE2E/0.1"}
            mb.inject_429_count = 2
            mb.retry_after_sec = 1
            for _ in range(2):
                r_429 = requests.get(
                    f"{mb.base_url}/ws/2/release-group?query=Dark",
                    headers=ua,
                    timeout=3.0,
                )
                self.assertEqual(r_429.status_code, 429)
                self.assertEqual(r_429.headers.get("Retry-After"), "1")

            r_200 = requests.get(
                f"{mb.base_url}/ws/2/release-group?query=Dark",
                headers=ua,
                timeout=3.0,
            )
            self.assertEqual(r_200.status_code, 200)

            dg.inject_503_count = 1
            r_503 = requests.get(
                f"{dg.base_url}/releases/10293", headers=ua, timeout=3.0
            )
            self.assertEqual(r_503.status_code, 503)
            r_dg_ok = requests.get(
                f"{dg.base_url}/releases/10293", headers=ua, timeout=3.0
            )
            self.assertEqual(r_dg_ok.status_code, 200)

    def test_lh2_05_tls_reject_and_dlna_airplay_faults(self):
        """Untrusted/expired TLS proxy cert is rejected; DLNA SOAP Fault 500 and AirPlay RTSP 401 work."""
        with (
            WanTlsProxyMockServer(target_port=0, expired_cert=True) as tls_proxy,
            DlnaMediaRendererMock() as dlna,
            AirPlayMockServer() as airplay,
        ):
            # Untrusted / expired self-signed TLS cert rejected by httpx default verification
            with self.assertRaises((httpx.ConnectError, ssl.SSLError)):
                httpx.get(f"{tls_proxy.https_base_url}/api/v1/playback/state", timeout=2.0)

            # Even when trusting the expired CA cert, TLS handshake/validation rejects expired cert
            with self.assertRaises((httpx.ConnectError, ssl.SSLError)):
                httpx.get(
                    f"{tls_proxy.https_base_url}/api/v1/playback/state",
                    verify=str(tls_proxy.ca_cert_path),
                    timeout=2.0,
                )

            # DLNA invalid SOAP action -> 500 UPnPError 401
            bad_soap = (
                '<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                "<s:Body><u:UnknownAction xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                "</u:UnknownAction></s:Body></s:Envelope>"
            )
            r_dlna = requests.post(
                f"{dlna.base_url}/upnp/control/AVTransport",
                data=bad_soap,
                headers={"SOAPAction": '"urn:schemas-upnp-org:service:AVTransport:1#UnknownAction"'},
                timeout=2.0,
            )
            self.assertEqual(r_dlna.status_code, 500)
            self.assertIn("<errorCode>401</errorCode>", r_dlna.text)

            # AirPlay require_auth_401 -> RTSP 401 with echoed CSeq
            airplay.require_auth_401 = True
            with socket.create_connection(("127.0.0.1", airplay.rtsp_port), timeout=2.0) as rtsp:
                rtsp.sendall(b"OPTIONS * RTSP/1.0\r\nCSeq: 9\r\n\r\n")
                resp = rtsp.recv(4096)
                self.assertIn(b"RTSP/1.0 401 Unauthorized", resp)
                self.assertIn(b"CSeq: 9", resp)
