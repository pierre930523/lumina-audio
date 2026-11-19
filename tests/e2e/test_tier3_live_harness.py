"""
Tier 3 Live Harness E2E Tests: Pairwise interactions combining real core_ffi.dll,
live core-server REST/WS, WAN TLS proxy, streaming 206, DLNA media fetch, SMB, SNTP, and mDNS.
"""
import json
import socket
import time
import unittest

import httpx
from websockets.sync.client import connect as ws_sync_connect

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_OK,
    LuminaFfiClient,
    LuminaLiveServer,
    run_ffi_isolated,
)
from tests.e2e.fixtures.mock_servers import (
    ClockSyncMockServer,
    DlnaMediaRendererMock,
    MdnsLoopbackMock,
    SmbLoopbackFixture,
    StreamingAudioMockServer,
    WanTlsProxyMockServer,
)
from tests.e2e.fixtures.net_helpers import ManagedTempDir, generate_flac_file
import requests


def _ffi_scan_db_only(client: LuminaFfiClient, db_path: str, music_dir: str) -> dict:
    assert client.library_init(db_path) == LUMINA_OK
    try:
        return client.library_scan_dir(music_dir)
    finally:
        client.shutdown()


class TestTier3LiveHarness(unittest.TestCase):
    """Tier 3 pairwise real integration tests across FFI, core-server, and mock servers."""

    def test_lh3_01_ffi_scan_with_server_rest_search(self):
        """Tracks scanned via core_ffi.dll into SQLite WAL are served via core-server REST /search & /tracks."""
        with ManagedTempDir(prefix="lumina_lh3_01_") as tmp:
            music_dir = tmp / "music"
            db_path = tmp / "shared.db"
            generate_flac_file(
                music_dir / "Pink Floyd" / "Animals" / "01 - Dogs.flac",
                sample_rate=96000,
                bit_depth=24,
                duration_ms=400,
                title="Dogs",
                artist="Pink Floyd",
                album="Animals",
                track_number=1,
            )
            scan = run_ffi_isolated(
                _ffi_scan_db_only, args=(str(db_path), str(music_dir))
            )
            self.assertGreaterEqual(scan["tracks_count"], 1)

            with LuminaLiveServer(db_path=db_path) as srv:
                token = srv.pair(device_name="RestReader")
                tracks_resp = srv.request("GET", "/api/v1/library/tracks", token=token)
                self.assertEqual(tracks_resp.status_code, 200)
                tracks = tracks_resp.json()
                self.assertTrue(any(t["title"] == "Dogs" for t in tracks))

                search_resp = srv.request(
                    "GET", "/api/v1/library/search", params={"q": "Dogs"}, token=token
                )
                self.assertEqual(search_resp.status_code, 200)
                hits = search_resp.json()
                self.assertTrue(any("Dogs" in h["title"] for h in hits))

    def test_lh3_02_server_rest_playback_with_ws_events(self):
        """REST playback/volume mutations broadcast WsMessage frames; invalid WS JSON emits error frame."""
        with ManagedTempDir(prefix="lumina_lh3_02_") as tmp:
            wav_path = tmp / "track.wav"
            from tests.e2e.fixtures.net_helpers import generate_wav_file

            generate_wav_file(
                wav_path,
                sample_rate=44100,
                bit_depth=16,
                duration_ms=2000,
                title="WS Test",
            )
            with LuminaLiveServer(db_path=tmp / "ws.db") as srv:
                token = srv.pair(device_name="WsClient")
                with srv.ws_connect(token=token) as ws:
                    r_play = srv.request(
                        "POST",
                        "/api/v1/playback/play",
                        token=token,
                        json={"file_path": str(wav_path)},
                    )
                    self.assertEqual(r_play.status_code, 200)

                    received_types = set()
                    deadline = time.monotonic() + 3.0
                    while time.monotonic() < deadline and "PlaybackStateChanged" not in received_types:
                        frame = json.loads(ws.recv(timeout=2.0))
                        received_types.add(frame.get("type"))
                    self.assertIn("PlaybackStateChanged", received_types)

                    r_vol = srv.request(
                        "POST",
                        "/api/v1/playback/volume",
                        token=token,
                        json={"volume": 0.35},
                    )
                    self.assertEqual(r_vol.status_code, 200)
                    vol_msg = json.loads(ws.recv(timeout=2.0))
                    self.assertEqual(vol_msg.get("type"), "state_changed")
                    self.assertAlmostEqual(vol_msg.get("volume", 0.0), 0.35, places=2)

                    ws.send("{invalid-json")
                    err_msg = json.loads(ws.recv(timeout=2.0))
                    self.assertEqual(err_msg.get("status"), "error")
                    self.assertIn("Invalid JSON", err_msg.get("error", ""))

    def test_lh3_03_wan_tls_proxy_with_core_server(self):
        """WanTlsProxyMockServer terminates TLS and forwards HTTPS pairing/REST and WSS frames to core-server."""
        with ManagedTempDir(prefix="lumina_lh3_03_") as tmp:
            with LuminaLiveServer(db_path=tmp / "wan.db") as srv:
                with WanTlsProxyMockServer(target_port=srv.port) as tls_proxy:
                    ssl_ctx = tls_proxy.client_ssl_context()
                    with httpx.Client(verify=str(tls_proxy.ca_cert_path), timeout=5.0) as client:
                        init_r = client.post(
                            f"{tls_proxy.https_base_url}/api/v1/pair/initiate",
                            json={"device_name": "MobileWan", "host": "127.0.0.1", "port": tls_proxy.port},
                        )
                        self.assertEqual(init_r.status_code, 200)
                        pin = init_r.json()["pin"]

                        ver_r = client.post(
                            f"{tls_proxy.https_base_url}/api/v1/pair/verify",
                            json={"pin": pin, "client_id": "wan-mobile", "platform": "android"},
                        )
                        self.assertEqual(ver_r.status_code, 200)
                        token = ver_r.json()["token"]

                        with ws_sync_connect(
                            tls_proxy.wss_url("/api/v1/ws"),
                            ssl=ssl_ctx,
                            additional_headers={"Authorization": f"Bearer {token}"},
                        ) as wss:
                            play_r = client.post(
                                f"{tls_proxy.https_base_url}/api/v1/playback/play",
                                headers={"Authorization": f"Bearer {token}"},
                                json={"track_id": "trk-wan-1"},
                            )
                            self.assertEqual(play_r.status_code, 200)
                            evt = json.loads(wss.recv(timeout=3.0))
                            self.assertEqual(evt.get("type"), "PlaybackStateChanged")
                            self.assertEqual(evt["payload"]["status"], "playing")

                    self.assertGreaterEqual(len(tls_proxy.requests_log), 2)
                    self.assertTrue(
                        any(r["path"] == "/api/v1/ws" for r in tls_proxy.requests_log)
                    )

    def test_lh3_04_streaming_206_with_dlna_media_fetch(self):
        """Qobuz mock stream URL passed to DLNA SetAVTransportURI triggers real HTTP media fetch on Play."""
        with StreamingAudioMockServer() as stream_srv, DlnaMediaRendererMock() as dlna:
            q_hdr = {
                "X-App-Id": "lumina-app",
                "X-User-Auth-Token": "qb_usr_tok_99182371",
            }
            url_resp = requests.get(
                f"{stream_srv.base_url}/api.json/0.2/track/getFileUrl",
                params={"track_id": "12049182"},
                headers=q_hdr,
                timeout=3.0,
            )
            self.assertEqual(url_resp.status_code, 200)
            media_url = url_resp.json()["url"]

            soap_set = (
                '<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                '<s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
                f"<InstanceID>0</InstanceID><CurrentURI>{media_url}</CurrentURI>"
                "<CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>"
            )
            self.assertEqual(
                requests.post(
                    f"{dlna.base_url}/upnp/control/AVTransport",
                    data=soap_set,
                    headers={"SOAPAction": '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"'},
                    timeout=3.0,
                ).status_code,
                200,
            )

            soap_play = (
                '<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                '<s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
                "<InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>"
            )
            self.assertEqual(
                requests.post(
                    f"{dlna.base_url}/upnp/control/AVTransport",
                    data=soap_play,
                    headers={"SOAPAction": '"urn:schemas-upnp-org:service:AVTransport:1#Play"'},
                    timeout=3.0,
                ).status_code,
                200,
            )
            self.assertEqual(dlna.fetched_media_status, 200)
            self.assertTrue(dlna.fetched_media_bytes.startswith(b"fLaC"))

    def test_lh3_05_mdns_sntp_and_smb_loopback_pairwise(self):
        """mDNS wire discovery, SMB loopback URI/TCP probe/file resolution, and SNTP offset/drift work together."""
        with (
            MdnsLoopbackMock(hostname="Zone-Living", service_port=19888) as mdns,
            ClockSyncMockServer(simulated_offset_us=42000, drift_ppm=150.0) as clk,
            SmbLoopbackFixture() as smb,
        ):
            # Discover host:port via mDNS
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as m_sock:
                m_sock.settimeout(2.0)
                m_sock.sendto(MdnsLoopbackMock.build_ptr_query(), (mdns.host, mdns.port))
                raw_mdns, _ = m_sock.recvfrom(4096)
                parsed = MdnsLoopbackMock.parse_dns_sd_packet(raw_mdns)
                self.assertEqual(parsed["srv"]["port"], 19888)
                self.assertEqual(parsed["a"], "127.0.0.1")

            # SMB URI credential validation + TCP SMB2 probe + local FLAC header
            uri = smb.smb_uri("Miles Davis/Kind of Blue/01 - So What.flac")
            self.assertTrue(smb.validate_credentials(uri))
            self.assertFalse(
                smb.validate_credentials(smb.smb_uri("Miles Davis/Kind of Blue/01 - So What.flac", authenticated=False))
            )
            resolved_file = smb.resolve_local_file(uri)
            self.assertTrue(resolved_file.read_bytes().startswith(b"fLaC"))
            with socket.create_connection(("127.0.0.1", smb.port), timeout=2.0) as tcp:
                tcp.sendall(b"\x00\x00\x00\x04\xfeSMB")
                neg_resp = tcp.recv(1024)
                self.assertIn(b"\xfeSMB", neg_resp)

            # SNTP offset ~ +42,000 us
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c_sock:
                c_sock.settimeout(2.0)
                t1 = int(time.time() * 1_000_000)
                c_sock.sendto(json.dumps({"t1_us": t1}).encode("utf-8"), (clk.host, clk.port))
                raw_clk, _ = c_sock.recvfrom(4096)
                t4 = int(time.time() * 1_000_000)
                resp = json.loads(raw_clk.decode("utf-8"))
                offset = ((resp["t2_us"] - t1) + (resp["t3_us"] - t4)) / 2.0
                self.assertAlmostEqual(offset, 42000.0, delta=15000.0)
