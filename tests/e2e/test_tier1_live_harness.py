"""
Tier 1 Live Harness E2E Tests: Happy-path real execution of core_ffi.dll, core-server,
and all 8 loopback mock servers on 127.0.0.1:0.
"""
import hashlib
import json
import socket
import struct
import unittest
from pathlib import Path

import defusedxml.ElementTree as SafeET
import requests

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
    WebDavMockServer,
)
from tests.e2e.fixtures.net_helpers import (
    ManagedTempDir,
    generate_flac_file,
    generate_wav_file,
)
from tests.e2e.fixtures.provider_mocks import (
    get_mock_tidal_pkce,
    make_basic_auth,
)
from tests.e2e.fixtures.server_fixtures import validate_qr_pairing_uri


def _ffi_scan_and_search(
    client: LuminaFfiClient, db_path: str, music_dir: str
) -> dict:
    assert client.version() == "0.1.0"
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        scan_summary = client.library_scan_dir(music_dir)
        tracks = client.library_get_tracks(50)
        search_hits = client.library_search("Miles", 10)
        return {
            "scan": scan_summary,
            "tracks": tracks,
            "search": search_hits,
        }
    finally:
        client.shutdown()


def _ffi_playback_and_signal_path(client: LuminaFfiClient, wav_path: str) -> dict:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.play(wav_path) == LUMINA_OK
        state_playing = client.get_state()
        duration_ms = client.get_duration_ms()
        sp_initial = client.signal_path_get()
        q_initial = client.signal_path_get_quality()

        assert client.signal_path_toggle_dsp_bypass() == LUMINA_OK
        sp_bypassed = client.signal_path_get()
        q_bypassed = client.signal_path_get_quality()

        assert client.pause() == LUMINA_OK
        state_paused = client.get_state()
        assert client.stop() == LUMINA_OK
        state_stopped = client.get_state()
        return {
            "state_playing": state_playing,
            "duration_ms": duration_ms,
            "sp_initial": sp_initial,
            "q_initial": q_initial,
            "sp_bypassed": sp_bypassed,
            "q_bypassed": q_bypassed,
            "state_paused": state_paused,
            "state_stopped": state_stopped,
        }
    finally:
        client.shutdown()


class TestTier1LiveHarness(unittest.TestCase):
    """Tier 1 real integration tests against core_ffi.dll, core-server, and mock servers."""

    def test_lh1_01_ffi_library_scan_and_fts5_search(self):
        """Real core_ffi.dll scans tagged WAV/FLAC files into SQLite WAL and queries via FTS5."""
        with ManagedTempDir(prefix="lumina_lh1_01_") as tmp:
            music_dir = tmp / "music"
            db_path = tmp / "library.db"
            generate_flac_file(
                music_dir / "Miles Davis" / "Kind of Blue" / "01 - So What.flac",
                sample_rate=96000,
                bit_depth=24,
                duration_ms=400,
                title="So What",
                artist="Miles Davis",
                album="Kind of Blue",
                album_artist="Miles Davis",
                track_number=1,
                disc_number=1,
                year="1959",
                isrc="USSM15900112",
                replaygain_track_gain="-4.20 dB",
                replaygain_track_peak="0.891251",
            )
            generate_wav_file(
                music_dir / "Miles Davis" / "Kind of Blue" / "02 - Freddie Freeloader.wav",
                sample_rate=44100,
                bit_depth=16,
                duration_ms=400,
                title="Freddie Freeloader",
                artist="Miles Davis",
                album="Kind of Blue",
                track_number=2,
                year="1959",
            )

            res = run_ffi_isolated(
                _ffi_scan_and_search, args=(str(db_path), str(music_dir))
            )
            scan = res["scan"]
            self.assertIsNotNone(scan)
            self.assertGreaterEqual(scan["scanned_files"], 2)
            self.assertGreaterEqual(scan["tracks_count"], 2)
            self.assertEqual(scan["errors_count"], 0)

            tracks = res["tracks"]
            self.assertGreaterEqual(len(tracks), 2)
            flac_tracks = [t for t in tracks if t.get("sample_rate_hz") == 96000]
            self.assertTrue(flac_tracks, f"Expected 96kHz FLAC track in {tracks}")
            self.assertEqual(flac_tracks[0]["bit_depth"], 24)

            search_hits = res["search"]
            self.assertGreaterEqual(len(search_hits), 2)
            self.assertTrue(
                any("So What" in t.get("title", "") for t in search_hits),
                f"Expected 'So What' in FTS5 search hits: {search_hits}",
            )

    def test_lh1_02_ffi_playback_and_signal_path(self):
        """Real core_ffi.dll plays WAV through headless AudioPlayer and toggles DSP bypass signal path."""
        with ManagedTempDir(prefix="lumina_lh1_02_") as tmp:
            wav_path = generate_wav_file(
                tmp / "tone.wav",
                sample_rate=44100,
                bit_depth=16,
                duration_ms=2000,
                title="Test Tone",
                artist="Lumina",
                album="Calibration",
            )
            res = run_ffi_isolated(
                _ffi_playback_and_signal_path, args=(str(wav_path),)
            )
            self.assertEqual(res["state_playing"], 2)
            self.assertGreater(res["duration_ms"], 0)
            self.assertEqual(res["q_initial"], 1)  # Enhanced (DSP active by default)
            self.assertEqual(res["sp_initial"]["overall_quality"], "enhanced")
            self.assertEqual(res["q_bypassed"], 0)  # Lossless after DSP bypass toggle
            self.assertEqual(res["sp_bypassed"]["overall_quality"], "lossless")
            self.assertEqual(res["state_paused"], 3)
            self.assertEqual(res["state_stopped"], 1)

    def test_lh1_03_live_server_pin_pair_and_rest(self):
        """Live Axum core-server executes PIN initiate, QR validation, verify, and Bearer REST."""
        with ManagedTempDir(prefix="lumina_lh1_03_") as tmp:
            db_path = tmp / "server.db"
            with LuminaLiveServer(db_path=db_path) as srv:
                init_payload = srv.pair_initiate(device_name="Phone-1")
                pin = init_payload["pin"]
                qr = init_payload["qr_payload"]
                self.assertEqual(len(pin), 6)
                self.assertTrue(pin.isdigit())
                self.assertTrue(validate_qr_pairing_uri(qr))
                self.assertIn(f"pin={pin}", qr)

                verify_payload = srv.pair_verify(
                    pin=pin, client_id="lh1-client", device_name="Phone-1", platform="ios"
                )
                self.assertEqual(verify_payload["status"], "success")
                token = verify_payload["token"]
                self.assertTrue(token.startswith("lum_sec_"))

                st_resp = srv.request("GET", "/api/v1/playback/state", token=token)
                self.assertEqual(st_resp.status_code, 200)
                vol_resp = srv.request(
                    "POST", "/api/v1/playback/volume", token=token, json={"volume": 0.42}
                )
                self.assertEqual(vol_resp.status_code, 200)
                self.assertEqual(vol_resp.json()["status"], "success")

                prov_resp = srv.request("GET", "/api/v1/providers", token=token)
                self.assertEqual(prov_resp.status_code, 200)

    def test_lh1_04_provider_webdav_metadata_mocks(self):
        """Streaming, WebDAV, MusicBrainz, and Discogs mock servers handle full happy-path requests."""
        with (
            StreamingAudioMockServer() as stream_srv,
            WebDavMockServer() as dav_srv,
            MusicBrainzMockServer() as mb_srv,
            DiscogsMockServer() as dg_srv,
        ):
            # Qobuz user/get + track/getFileUrl + 206 Range FLAC
            q_headers = {
                "X-App-Id": "lumina-app",
                "X-User-Auth-Token": "qb_usr_tok_99182371",
            }
            u_resp = requests.get(
                f"{stream_srv.base_url}/api.json/0.2/user/get",
                headers=q_headers,
                timeout=3.0,
            )
            self.assertEqual(u_resp.status_code, 200)
            self.assertEqual(u_resp.json()["status"], "success")

            f_resp = requests.get(
                f"{stream_srv.base_url}/api.json/0.2/track/getFileUrl",
                params={"track_id": "12049182", "format_id": "27"},
                headers=q_headers,
                timeout=3.0,
            )
            self.assertEqual(f_resp.status_code, 200)
            stream_url = f_resp.json()["url"]
            r_resp = requests.get(
                stream_url, headers={"Range": "bytes=0-127"}, timeout=3.0
            )
            self.assertEqual(r_resp.status_code, 206)
            self.assertEqual(len(r_resp.content), 128)
            self.assertTrue(r_resp.content.startswith(b"fLaC"))

            # Tidal PKCE token + stream
            verifier, _, _ = get_mock_tidal_pkce()
            t_resp = requests.post(
                f"{stream_srv.base_url}/oauth2/token",
                data={"grant_type": "authorization_code", "code_verifier": verifier},
                timeout=3.0,
            )
            self.assertEqual(t_resp.status_code, 200)
            t_token = t_resp.json()["access_token"]
            t_stream = requests.get(
                f"{stream_srv.base_url}/v1/tracks/7788192/stream",
                headers={"Authorization": f"Bearer {t_token}", "Range": "bytes=0-63"},
                timeout=3.0,
            )
            self.assertEqual(t_stream.status_code, 206)
            self.assertTrue(t_stream.content.startswith(b"fLaC"))

            # Deezer ARL auth + stream
            arl = "a" * 32
            d_resp = requests.get(
                f"{stream_srv.base_url}/ajax/gw-light.php",
                headers={"Cookie": f"arl={arl}"},
                timeout=3.0,
            )
            self.assertEqual(d_resp.status_code, 200)
            d_stream = requests.get(
                d_resp.json()["stream_url"],
                headers={"Cookie": f"arl={arl}"},
                timeout=3.0,
            )
            self.assertEqual(d_stream.status_code, 200)
            self.assertTrue(d_stream.content.startswith(b"fLaC"))

            # WebDAV PROPFIND 207 + Range GET
            dav_auth = make_basic_auth("lumina", "webdav_secret")
            pf_resp = requests.request(
                "PROPFIND",
                f"{dav_srv.base_url}/Music/Miles%20Davis/Kind%20of%20Blue/",
                headers={"Authorization": dav_auth, "Depth": "1"},
                timeout=3.0,
            )
            self.assertEqual(pf_resp.status_code, 207)
            dav_xml = SafeET.fromstring(pf_resp.text)
            self.assertTrue(dav_xml.tag.endswith("multistatus"))

            dav_get = requests.get(
                f"{dav_srv.base_url}/Music/Miles%20Davis/Kind%20of%20Blue/01%20-%20So%20What.flac",
                headers={"Authorization": dav_auth, "Range": "bytes=0-31"},
                timeout=3.0,
            )
            self.assertEqual(dav_get.status_code, 206)
            self.assertTrue(dav_get.content.startswith(b"fLaC"))

            # MusicBrainz & Discogs JSON APIs
            ua = {"User-Agent": "LuminaAudioE2E/0.1 (e2e@lumina.audio)"}
            mb_resp = requests.get(
                f"{mb_srv.base_url}/ws/2/release/b84ee12a-09ef-421b-82de-0441a926375b",
                headers=ua,
                timeout=3.0,
            )
            self.assertEqual(mb_resp.status_code, 200)
            self.assertEqual(mb_resp.json()["barcode"], "077774600125")

            dg_resp = requests.get(
                f"{dg_srv.base_url}/releases/10293", headers=ua, timeout=3.0
            )
            self.assertEqual(dg_resp.status_code, 200)
            self.assertTrue(
                any(ea["name"] == "Alan Parsons" for ea in dg_resp.json()["extraartists"])
            )

            self.assertGreater(len(stream_srv.requests_log), 0)
            stream_srv.reset()
            self.assertEqual(len(stream_srv.requests_log), 0)

    def test_lh1_05_dlna_airplay_sntp_mdns_mocks(self):
        """DLNA SSDP/SOAP, AirPlay RTSP/RTP, SNTP clock sync, and mDNS mocks execute end-to-end."""
        with (
            DlnaMediaRendererMock() as dlna,
            AirPlayMockServer() as airplay,
            ClockSyncMockServer(simulated_offset_us=12000) as clock_srv,
            MdnsLoopbackMock(hostname="Lumina-Host", service_port=9888) as mdns,
        ):
            # 1. DLNA SSDP M-SEARCH + description + SetAVTransportURI + Play + SetVolume
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.settimeout(2.0)
                msearch = (
                    "M-SEARCH * HTTP/1.1\r\n"
                    f"HOST: {dlna.ssdp_host}:{dlna.ssdp_port}\r\n"
                    'MAN: "ssdp:discover"\r\n'
                    "MX: 1\r\n"
                    "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
                ).encode("utf-8")
                udp.sendto(msearch, (dlna.ssdp_host, dlna.ssdp_port))
                ssdp_reply, _ = udp.recvfrom(4096)
                self.assertIn(b"200 OK", ssdp_reply)
                self.assertIn(f"{dlna.base_url}/description.xml".encode(), ssdp_reply)

            desc = requests.get(f"{dlna.base_url}/description.xml", timeout=2.0)
            self.assertEqual(desc.status_code, 200)
            self.assertIn("MediaRenderer:1", desc.text)

            soap_set = (
                '<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                "<s:Body><u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                "<InstanceID>0</InstanceID><CurrentURI>http://127.0.0.1/mock.flac</CurrentURI>"
                "<CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>"
            )
            dlna.fetch_uri_on_play = False
            r_set = requests.post(
                f"{dlna.base_url}/upnp/control/AVTransport",
                data=soap_set,
                headers={"SOAPAction": '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"'},
                timeout=2.0,
            )
            self.assertEqual(r_set.status_code, 200)

            soap_play = (
                '<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                "<s:Body><u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                "<InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>"
            )
            self.assertEqual(
                requests.post(
                    f"{dlna.base_url}/upnp/control/AVTransport",
                    data=soap_play,
                    headers={"SOAPAction": '"urn:schemas-upnp-org:service:AVTransport:1#Play"'},
                    timeout=2.0,
                ).status_code,
                200,
            )
            self.assertEqual(dlna.transport_state, "PLAYING")

            soap_vol = (
                '<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                "<s:Body><u:SetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">"
                "<InstanceID>0</InstanceID><Channel>Master</Channel>"
                "<DesiredVolume>77</DesiredVolume></u:SetVolume></s:Body></s:Envelope>"
            )
            self.assertEqual(
                requests.post(
                    f"{dlna.base_url}/upnp/control/RenderingControl",
                    data=soap_vol,
                    headers={"SOAPAction": '"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume"'},
                    timeout=2.0,
                ).status_code,
                200,
            )
            self.assertEqual(dlna.volume, 77)

            # 2. AirPlay RTSP handshake + UDP RTP packet capture
            with socket.create_connection(("127.0.0.1", airplay.rtsp_port), timeout=2.0) as rtsp:
                for idx, (meth, extra, body) in enumerate(
                    [
                        ("OPTIONS", "", b""),
                        ("ANNOUNCE", "Content-Type: application/sdp\r\n", b"v=0\r\nm=audio 0 RTP/AVP 96\r\n"),
                        ("SETUP", "Transport: RTP/AVP/UDP;unicast;mode=record\r\n", b""),
                        ("RECORD", "", b""),
                    ],
                    start=1,
                ):
                    msg = f"{meth} rtsp://127.0.0.1/stream RTSP/1.0\r\nCSeq: {idx}\r\n{extra}"
                    if body:
                        msg += f"Content-Length: {len(body)}\r\n"
                    msg += "\r\n"
                    rtsp.sendall(msg.encode("ascii") + body)
                    resp = rtsp.recv(4096)
                    self.assertIn(b"RTSP/1.0 200 OK", resp)
                    self.assertIn(f"CSeq: {idx}".encode("ascii"), resp)

            payload = b"\xaa\xbb\xcc\xdd" * 16
            rtp_pkt = struct.pack("!BBHII", 0x80, 96, 1, 44100, 0x12345678) + payload
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rtp_tx:
                rtp_tx.sendto(rtp_pkt, (airplay.rtp_host, airplay.rtp_port))

            # Wait briefly for RTP receiver thread
            import time
            deadline = time.monotonic() + 2.0
            while not airplay.rtp_packets and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertEqual(len(airplay.rtp_packets), 1)
            self.assertEqual(
                airplay.rtp_packets[0]["payload_sha256"],
                hashlib.sha256(payload).hexdigest(),
            )

            # 3. SNTP 4-timestamp packet
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sntp:
                sntp.settimeout(2.0)
                t1_us = int(time.time() * 1_000_000)
                sntp.sendto(json.dumps({"t1_us": t1_us}).encode("utf-8"), (clock_srv.host, clock_srv.port))
                raw_clk, _ = sntp.recvfrom(4096)
                t4_us = int(time.time() * 1_000_000)
                clk = json.loads(raw_clk.decode("utf-8"))
                offset = ((clk["t2_us"] - t1_us) + (clk["t3_us"] - t4_us)) / 2.0
                self.assertAlmostEqual(offset, 12000.0, delta=15000.0)

            # 4. mDNS wire query & 0x8400 4-RR parse
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as m_sock:
                m_sock.settimeout(2.0)
                m_sock.sendto(MdnsLoopbackMock.build_ptr_query(), (mdns.host, mdns.port))
                m_reply, _ = m_sock.recvfrom(4096)
                parsed_mdns = MdnsLoopbackMock.parse_dns_sd_packet(m_reply)
                self.assertEqual(parsed_mdns["header"]["flags"], 0x8400)
                self.assertEqual(parsed_mdns["header"]["ancount"], 4)
                self.assertEqual(parsed_mdns["srv"]["port"], 9888)
                self.assertEqual(parsed_mdns["a"], "127.0.0.1")
                self.assertEqual(parsed_mdns["txt"]["server_name"], "Lumina-Host")
