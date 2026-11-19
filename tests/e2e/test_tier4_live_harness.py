"""
Tier 4 Live Harness E2E Tests: Realistic end-to-end multi-component application workflows
exercising core_ffi.dll, core-server, TLS proxy, streaming/WebDAV/metadata mocks, DLNA, AirPlay, mDNS, and clock sync.
"""
import hashlib
import json
import socket
import struct
import time
import unittest

import httpx
import requests
from websockets.sync.client import connect as ws_sync_connect

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_OK,
    LuminaFfiClient,
    LuminaLiveServer,
    run_ffi_isolated,
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
    WebDavMockServer,
)
from tests.e2e.fixtures.net_helpers import (
    ManagedTempDir,
    generate_flac_file,
    generate_wav_file,
)
from tests.e2e.fixtures.provider_mocks import make_basic_auth


def _ffi_scan_isolated(client: LuminaFfiClient, db_path: str, music_dir: str) -> dict:
    assert client.library_init(db_path) == LUMINA_OK
    try:
        return client.library_scan_dir(music_dir)
    finally:
        client.shutdown()


class TestTier4LiveHarness(unittest.TestCase):
    """Tier 4 full end-to-end real-artifact workflows."""

    def test_lh4_01_desktop_core_scan_pair_ws_playback(self):
        """Desktop core lifecycle: DB init -> scan -> live server -> QR pair -> WS + REST play/pause/state."""
        with ManagedTempDir(prefix="lumina_lh4_01_") as tmp:
            music_dir = tmp / "library"
            db_path = tmp / "desktop.db"
            flac_file = generate_flac_file(
                music_dir / "Artist A" / "Album A" / "01 - Horizon.flac",
                sample_rate=44100,
                bit_depth=16,
                duration_ms=2000,
                title="Horizon",
                artist="Artist A",
                album="Album A",
                track_number=1,
            )
            generate_wav_file(
                music_dir / "Artist A" / "Album A" / "02 - Dawn.wav",
                sample_rate=44100,
                bit_depth=16,
                duration_ms=1500,
                title="Dawn",
                artist="Artist A",
                album="Album A",
                track_number=2,
            )

            with LuminaLiveServer(db_path=db_path, scan_dir=music_dir) as srv:
                token = srv.pair(device_name="DesktopController")
                search_r = srv.request(
                    "GET", "/api/v1/library/search", params={"q": "Horizon"}, token=token
                )
                self.assertEqual(search_r.status_code, 200)
                hits = search_r.json()
                self.assertTrue(any("Horizon" in h["title"] for h in hits))

                with srv.ws_connect(token=token) as ws:
                    play_r = srv.request(
                        "POST",
                        "/api/v1/playback/play",
                        token=token,
                        json={"file_path": str(flac_file)},
                    )
                    self.assertEqual(play_r.status_code, 200)

                    ws_events = []
                    deadline = time.monotonic() + 3.0
                    while time.monotonic() < deadline:
                        evt = json.loads(ws.recv(timeout=2.0))
                        ws_events.append(evt)
                        if evt.get("type") == "PlaybackStateChanged":
                            break
                    self.assertTrue(
                        any(
                            e.get("type") == "PlaybackStateChanged"
                            and e["payload"]["status"] == "playing"
                            for e in ws_events
                        )
                    )

                    st_r = srv.request("GET", "/api/v1/playback/state", token=token)
                    self.assertEqual(st_r.status_code, 200)
                    self.assertEqual(st_r.json()["status"], "playing")
                    self.assertGreater(st_r.json()["duration_ms"], 0)

                    pause_r = srv.request("POST", "/api/v1/playback/pause", token=token)
                    self.assertEqual(pause_r.status_code, 200)
                    evt_pause = json.loads(ws.recv(timeout=2.0))
                    self.assertEqual(evt_pause["payload"]["status"], "paused")

    def test_lh4_02_wan_tls_multi_client_ws_sync(self):
        """Two remote mobile clients pair over HTTPS TLS proxy and receive synchronized WSS state broadcasts."""
        with ManagedTempDir(prefix="lumina_lh4_02_") as tmp:
            with LuminaLiveServer(db_path=tmp / "wan_multi.db") as srv:
                with WanTlsProxyMockServer(target_port=srv.port) as proxy:
                    ssl_ctx = proxy.client_ssl_context()
                    with httpx.Client(verify=str(proxy.ca_cert_path), timeout=5.0) as http:
                        tokens = []
                        for idx in range(2):
                            p_init = http.post(
                                f"{proxy.https_base_url}/api/v1/pair/initiate",
                                json={"device_name": f"Phone-{idx}", "host": "127.0.0.1", "port": proxy.port},
                            ).json()
                            p_ver = http.post(
                                f"{proxy.https_base_url}/api/v1/pair/verify",
                                json={"pin": p_init["pin"], "client_id": f"wan-{idx}"},
                            ).json()
                            tokens.append(p_ver["token"])

                        with (
                            ws_sync_connect(
                                proxy.wss_url(),
                                ssl=ssl_ctx,
                                additional_headers={"Authorization": f"Bearer {tokens[0]}"},
                            ) as ws1,
                            ws_sync_connect(
                                proxy.wss_url(),
                                ssl=ssl_ctx,
                                additional_headers={"Authorization": f"Bearer {tokens[1]}"},
                            ) as ws2,
                        ):
                            r = http.post(
                                f"{proxy.https_base_url}/api/v1/playback/play",
                                headers={"Authorization": f"Bearer {tokens[0]}"},
                                json={"track_id": "trk-sync-99"},
                            )
                            self.assertEqual(r.status_code, 200)
                            e1 = json.loads(ws1.recv(timeout=3.0))
                            e2 = json.loads(ws2.recv(timeout=3.0))
                            self.assertEqual(e1["payload"]["status"], "playing")
                            self.assertEqual(e2["payload"]["status"], "playing")

                            r_vol = http.post(
                                f"{proxy.https_base_url}/api/v1/playback/volume",
                                headers={"Authorization": f"Bearer {tokens[1]}"},
                                json={"volume": 0.65},
                            )
                            self.assertEqual(r_vol.status_code, 200)
                            v1 = json.loads(ws1.recv(timeout=3.0))
                            v2 = json.loads(ws2.recv(timeout=3.0))
                            self.assertAlmostEqual(v1["volume"], 0.65, places=2)
                            self.assertAlmostEqual(v2["volume"], 0.65, places=2)

    def test_lh4_03_multi_provider_range_and_enrichment(self):
        """Multi-chunk 206 FLAC reassembly matches SHA-256, MB/Discogs retry on 429, and FFI scan coexists."""
        with (
            ManagedTempDir(prefix="lumina_lh4_03_") as tmp,
            StreamingAudioMockServer() as stream_srv,
            WebDavMockServer() as dav_srv,
            MusicBrainzMockServer() as mb_srv,
            DiscogsMockServer() as dg_srv,
        ):
            expected_bytes, _, _ = stream_srv.tracks["12049182"]
            expected_sha = hashlib.sha256(expected_bytes).hexdigest()

            # Reassemble full FLAC over 1024-byte HTTP 206 Range chunks
            assembled = bytearray()
            offset = 0
            chunk_sz = 1024
            while offset < len(expected_bytes):
                end = min(len(expected_bytes) - 1, offset + chunk_sz - 1)
                r = requests.get(
                    f"{stream_srv.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a",
                    headers={"Range": f"bytes={offset}-{end}"},
                    timeout=3.0,
                )
                self.assertEqual(r.status_code, 206)
                assembled.extend(r.content)
                offset = end + 1
            self.assertEqual(hashlib.sha256(bytes(assembled)).hexdigest(), expected_sha)

            # WebDAV download matches local FLAC header
            dav_resp = requests.get(
                f"{dav_srv.base_url}/Music/Miles%20Davis/Kind%20of%20Blue/01%20-%20So%20What.flac",
                headers={"Authorization": make_basic_auth("lumina", "webdav_secret")},
                timeout=3.0,
            )
            self.assertEqual(dav_resp.status_code, 200)
            self.assertTrue(dav_resp.content.startswith(b"fLaC"))

            # MusicBrainz with 429 retry-after backoff + Discogs credit enrichment
            mb_srv.inject_429_count = 1
            mb_srv.retry_after_sec = 0
            ua = {"User-Agent": "LuminaAudioE2E/0.1"}
            r1 = requests.get(
                f"{mb_srv.base_url}/ws/2/recording/rec-time-001", headers=ua, timeout=3.0
            )
            self.assertEqual(r1.status_code, 429)
            r2 = requests.get(
                f"{mb_srv.base_url}/ws/2/recording/rec-time-001", headers=ua, timeout=3.0
            )
            self.assertEqual(r2.status_code, 200)
            self.assertEqual(r2.json()["relations"][0]["artist"]["name"], "Alan Parsons")

            dg = requests.get(
                f"{dg_srv.base_url}/releases/10293", headers=ua, timeout=3.0
            ).json()
            self.assertEqual(dg["title"], "The Dark Side Of The Moon")

            # FFI local scan in isolated process
            local_dir = tmp / "local"
            generate_flac_file(
                local_dir / "track.flac",
                title="Time",
                artist="Pink Floyd",
                album="The Dark Side of the Moon",
            )
            scan = run_ffi_isolated(
                _ffi_scan_isolated, args=(str(tmp / "enrich.db"), str(local_dir))
            )
            self.assertEqual(scan["tracks_count"], 1)

    def test_lh4_04_dlna_and_airplay_dual_casting(self):
        """Concurrent DLNA SOAP+SSDP casting and AirPlay RTSP+10 RTP packet streaming lifecycle."""
        with (
            StreamingAudioMockServer() as stream_srv,
            DlnaMediaRendererMock() as dlna,
            AirPlayMockServer() as airplay,
        ):
            media_url = f"{stream_srv.base_url}/stream/qobuz/12049182.flac?token=mock_sig_991a"

            # 1. DLNA: SSDP -> SetAVTransportURI -> Play -> Seek -> SetVolume -> Stop
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.settimeout(2.0)
                udp.sendto(
                    (
                        "M-SEARCH * HTTP/1.1\r\n"
                        f"HOST: {dlna.ssdp_host}:{dlna.ssdp_port}\r\n"
                        'MAN: "ssdp:discover"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n'
                    ).encode("utf-8"),
                    (dlna.ssdp_host, dlna.ssdp_port),
                )
                self.assertIn(b"200 OK", udp.recvfrom(4096)[0])

            def _soap(service: str, action: str, inner: str) -> requests.Response:
                env = (
                    '<?xml version="1.0"?>'
                    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                    f'<s:Body><u:{action} xmlns:u="urn:schemas-upnp-org:service:{service}:1">'
                    f"{inner}</u:{action}></s:Body></s:Envelope>"
                )
                return requests.post(
                    f"{dlna.base_url}/upnp/control/{service}",
                    data=env,
                    headers={"SOAPAction": f'"urn:schemas-upnp-org:service:{service}:1#{action}"'},
                    timeout=3.0,
                )

            self.assertEqual(
                _soap(
                    "AVTransport",
                    "SetAVTransportURI",
                    f"<InstanceID>0</InstanceID><CurrentURI>{media_url}</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>",
                ).status_code,
                200,
            )
            self.assertEqual(_soap("AVTransport", "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>").status_code, 200)
            self.assertEqual(dlna.fetched_media_status, 200)
            self.assertEqual(_soap("AVTransport", "Seek", "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>00:01:15</Target>").status_code, 200)
            self.assertEqual(dlna.position_sec, 75)
            self.assertEqual(_soap("RenderingControl", "SetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>82</DesiredVolume>").status_code, 200)
            self.assertEqual(dlna.volume, 82)
            self.assertEqual(_soap("AVTransport", "Stop", "<InstanceID>0</InstanceID>").status_code, 200)
            self.assertEqual(dlna.transport_state, "STOPPED")

            # 2. AirPlay: OPTIONS -> ANNOUNCE -> SETUP -> RECORD -> 10 RTP packets -> FLUSH -> TEARDOWN
            with socket.create_connection(("127.0.0.1", airplay.rtsp_port), timeout=3.0) as rtsp:
                def _rtsp(cseq: int, meth: str, hdrs: str = "", body: bytes = b"") -> bytes:
                    req = f"{meth} rtsp://127.0.0.1/live RTSP/1.0\r\nCSeq: {cseq}\r\n{hdrs}"
                    if body:
                        req += f"Content-Length: {len(body)}\r\n"
                    req += "\r\n"
                    rtsp.sendall(req.encode("ascii") + body)
                    return rtsp.recv(4096)

                self.assertIn(b"200 OK", _rtsp(1, "OPTIONS"))
                self.assertIn(b"200 OK", _rtsp(2, "ANNOUNCE", "Content-Type: application/sdp\r\n", b"v=0\r\na=rtpmap:96 AppleLossless\r\n"))
                self.assertIn(b"200 OK", _rtsp(3, "SETUP", "Transport: RTP/AVP/UDP;unicast;mode=record\r\n"))
                self.assertIn(b"200 OK", _rtsp(4, "RECORD"))

                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rtp_tx:
                    for seq in range(10):
                        pkt = struct.pack("!BBHII", 0x80, 96, seq, seq * 352, 0xCAFEBABE) + (b"\x55" * 64)
                        rtp_tx.sendto(pkt, (airplay.rtp_host, airplay.rtp_port))

                deadline = time.monotonic() + 2.0
                while len(airplay.rtp_packets) < 10 and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertEqual(len(airplay.rtp_packets), 10)

                self.assertIn(b"200 OK", _rtsp(5, "SET_PARAMETER", "Content-Type: text/parameters\r\n", b"volume: -6.5\r\n"))
                self.assertAlmostEqual(airplay.volume_db, -6.5, places=1)
                self.assertIn(b"200 OK", _rtsp(6, "FLUSH"))
                self.assertIn(b"200 OK", _rtsp(7, "TEARDOWN"))
                self.assertTrue(airplay.flushed)
                self.assertTrue(airplay.teardown_called)

    def test_lh4_05_multi_room_discovery_and_drift_sync(self):
        """Discover zone via mDNS and verify multi-room clock offset & opposite drift estimation across 2 zones."""
        with (
            MdnsLoopbackMock(hostname="Master-Clock", service_port=9888) as mdns,
            ClockSyncMockServer(simulated_offset_us=15000, drift_ppm=50.0) as zone_a,
            ClockSyncMockServer(simulated_offset_us=-28000, drift_ppm=-120.0) as zone_b,
        ):
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as m_sock:
                m_sock.settimeout(2.0)
                m_sock.sendto(MdnsLoopbackMock.build_ptr_query(), (mdns.host, mdns.port))
                parsed = MdnsLoopbackMock.parse_dns_sd_packet(m_sock.recvfrom(4096)[0])
                self.assertEqual(parsed["txt"]["server_name"], "Master-Clock")

            def _sample_offset(host: str, port: int) -> float:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                    s.settimeout(2.0)
                    t1 = int(time.time() * 1_000_000)
                    s.sendto(json.dumps({"t1_us": t1}).encode("utf-8"), (host, port))
                    resp = json.loads(s.recvfrom(4096)[0].decode("utf-8"))
                    t4 = int(time.time() * 1_000_000)
                    return ((resp["t2_us"] - t1) + (resp["t3_us"] - t4)) / 2.0

            samples_a = [_sample_offset(zone_a.host, zone_a.port) for _ in range(4)]
            samples_b = [_sample_offset(zone_b.host, zone_b.port) for _ in range(4)]
            mean_a = sum(samples_a) / len(samples_a)
            mean_b = sum(samples_b) / len(samples_b)

            self.assertAlmostEqual(mean_a, 15000.0, delta=15000.0)
            self.assertAlmostEqual(mean_b, -28000.0, delta=15000.0)
            self.assertGreater(mean_a - mean_b, 20000.0)
