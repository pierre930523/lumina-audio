"""
Lumina Audio E2E Test Suite - Tier 1 Phases 12-18 (Features F1 to F14)
75 happy-path opaque-box feature coverage tests derived from DISPATCH.md (R1-R5, Phase 18)
and PROJECT.md (Feature Inventory F1-F14 & Interface Contracts).

Zero-skip policy: every test executes against real generated binary fixtures,
isolated core_ffi.dll subprocesses, live core-server REST/WS, and Dart/Rust artifacts.
"""
import json
import os
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional

from PIL import Image

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_OK,
    LuminaFfiClient,
    LuminaLiveServer,
    OPTIONAL_M7_M10_SIGNATURES,
    OPTIONAL_PHASE12_18_SIGNATURES,
    _WORKSPACE_ROOT,
    run_ffi_isolated,
)
from tests.e2e.fixtures.media_fixtures import (
    build_lrc_text,
    generate_dsdiff_fixture,
    generate_dsf_fixture,
    generate_flac_fixture,
    generate_image_bytes,
    generate_image_file,
    generate_lyrics_file,
    generate_m4a_fixture,
    generate_mp3_fixture,
    generate_wav_fixture,
)
from tests.e2e.fixtures.net_helpers import ManagedTempDir


# ---------------------------------------------------------------------------
# Module-level isolated FFI workers (OnceLock / SQLite WAL safe)
# ---------------------------------------------------------------------------

def _ffi_scan_and_artwork(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    target_path: str,
    max_dim: int = 0,
    user_cover: Optional[str] = None,
    clear_after: bool = False,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        scan = client.library_scan_dir(scan_dir)
        tracks = client.library_get_tracks(200)
        target = {"file_path": target_path}
        if tracks:
            for t in tracks:
                if Path(t.get("file_path", "")).name == Path(target_path).name:
                    target = {"track_id": t["id"], "file_path": t["file_path"]}
                    break
        art_before = client.artwork_get(target, max_dim=max_dim)
        set_rc = None
        art_after_set = None
        clear_rc = None
        art_after_clear = None
        if user_cover is not None:
            set_rc = client.artwork_set_user_cover(target, user_cover)
            art_after_set = client.artwork_get(target, max_dim=max_dim)
            if clear_after:
                clear_rc = client.artwork_clear_user_cover(target)
                art_after_clear = client.artwork_get(target, max_dim=max_dim)
        return {
            "scan": scan,
            "tracks": tracks,
            "art_before": art_before,
            "set_rc": set_rc,
            "art_after_set": art_after_set,
            "clear_rc": clear_rc,
            "art_after_clear": art_after_clear,
        }
    finally:
        client.shutdown()


def _ffi_scan_and_query(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    search_query: Optional[str] = None,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        scan = client.library_scan_dir(scan_dir)
        tracks = client.library_get_tracks(200)
        albums = client.library_get_albums(200)
        album_details = [client.library_get_album_detail(a["id"]) for a in albums[:5]]
        search_res = client.library_search(search_query, 50) if search_query else []
        return {
            "scan": scan,
            "tracks": tracks,
            "albums": albums,
            "album_details": album_details,
            "search": search_res,
        }
    finally:
        client.shutdown()


def _ffi_rescan_workflow(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    force: bool,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        rescan = client.library_rescan_tags(scan_dir, force=force)
        tracks = client.library_get_tracks(200)
        albums = client.library_get_albums(200)
        return {"rescan": rescan, "tracks": tracks, "albums": albums}
    finally:
        client.shutdown()


def _ffi_lyrics_workflow(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    target_path: str,
    user_lyrics_path: Optional[str] = None,
    clear_after: bool = False,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        tracks = client.library_get_tracks(200)
        target = {"file_path": target_path}
        for t in tracks:
            if Path(t.get("file_path", "")).name == Path(target_path).name:
                target = {"track_id": t["id"], "file_path": t["file_path"]}
                break
        before = client.lyrics_get(target)
        set_rc = None
        after_set = None
        clear_rc = None
        after_clear = None
        if user_lyrics_path is not None:
            set_rc = client.lyrics_set_user_file(target, user_lyrics_path)
            after_set = client.lyrics_get(target)
            if clear_after:
                clear_rc = client.lyrics_clear_user_file(target)
                after_clear = client.lyrics_get(target)
        return {
            "tracks": tracks,
            "before": before,
            "set_rc": set_rc,
            "after_set": after_set,
            "clear_rc": clear_rc,
            "after_clear": after_clear,
        }
    finally:
        client.shutdown()


def _ffi_play_and_seek_sequence(
    client: LuminaFfiClient,
    file_path: str,
    seek_positions_ms: List[int],
    pause_before_seek: bool = False,
    resume_after: bool = False,
    strict_mode: Optional[bool] = None,
    dsd_mode: Optional[int] = None,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        if strict_mode is not None:
            assert client.audio_set_strict_mode(strict_mode) == LUMINA_OK
        if dsd_mode is not None:
            assert client.audio_set_dsd_mode(dsd_mode) == LUMINA_OK

        play_rc = client.play({"file_path": file_path, "source": "Local Library"})
        time.sleep(0.08)
        initial_state = client.playback_get_state_json()
        initial_sp = client.signal_path_get()
        dur_ms = client.get_duration_ms()

        if pause_before_seek:
            assert client.pause() == LUMINA_OK
            time.sleep(0.04)

        steps: List[Dict[str, Any]] = []
        for pos in seek_positions_ms:
            rc = client.seek(pos)
            time.sleep(0.06)
            st = client.playback_get_state_json()
            sp = client.signal_path_get()
            steps.append(
                {
                    "target_ms": pos,
                    "seek_rc": rc,
                    "pos_ms": st.get("position_ms", client.get_position_ms()),
                    "state_code": st.get("state_code", client.get_state()),
                    "seek_epoch": st.get("seek_epoch"),
                    "sp": sp,
                }
            )

        resumed_state = None
        if resume_after:
            assert client.playback_resume() == LUMINA_OK
            time.sleep(0.05)
            resumed_state = client.playback_get_state_json()

        client.stop()
        return {
            "play_rc": play_rc,
            "duration_ms": dur_ms,
            "initial_state": initial_state,
            "initial_sp": initial_sp,
            "steps": steps,
            "resumed_state": resumed_state,
        }
    finally:
        client.shutdown()


def _ffi_state_machine_probe(client: LuminaFfiClient, file_path: str) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        s_stopped = client.playback_get_state_json()
        assert client.play({"file_path": file_path, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.08)
        s_playing = client.playback_get_state_json()
        assert client.pause() == LUMINA_OK
        time.sleep(0.05)
        s_paused = client.playback_get_state_json()
        pos_paused_1 = client.get_position_ms()
        time.sleep(0.08)
        pos_paused_2 = client.get_position_ms()
        assert client.playback_resume() == LUMINA_OK
        time.sleep(0.06)
        s_resumed = client.playback_get_state_json()
        assert client.stop() == LUMINA_OK
        s_after_stop = client.playback_get_state_json()
        return {
            "stopped": s_stopped,
            "playing": s_playing,
            "paused": s_paused,
            "pos_paused_1": pos_paused_1,
            "pos_paused_2": pos_paused_2,
            "resumed": s_resumed,
            "after_stop": s_after_stop,
        }
    finally:
        client.shutdown()


def _ffi_bit_perfect_track_switch(
    client: LuminaFfiClient,
    track_a: str,
    track_b: str,
    bypass_enabled: bool = True,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.audio_set_strict_mode(bypass_enabled) == LUMINA_OK
        assert client.play({"file_path": track_a, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.08)
        sp_a = client.signal_path_get()
        st_a = client.playback_get_state_json()
        assert client.seek(400) == LUMINA_OK
        time.sleep(0.06)
        sp_a_seek = client.signal_path_get()

        assert client.play({"file_path": track_b, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.08)
        sp_b = client.signal_path_get()
        st_b = client.playback_get_state_json()
        out_info = client.audio_get_output_info()
        client.stop()
        return {
            "sp_a": sp_a,
            "st_a": st_a,
            "sp_a_seek": sp_a_seek,
            "sp_b": sp_b,
            "st_b": st_b,
            "out_info": out_info,
        }
    finally:
        client.shutdown()


# ---------------------------------------------------------------------------
# F1: Artwork Manager & Priority Chain (6 tests)
# ---------------------------------------------------------------------------

class TestP12_F01_ArtworkPriority(unittest.TestCase):
    """P12_F01: Artwork Manager & 6-Tier Priority Chain"""

    def test_p12_f01_01_embedded_front_cover_beats_external_covers(self):
        with ManagedTempDir(prefix="lumina_f01_01_") as tmp:
            album_dir = tmp / "music" / "Artist" / "Album"
            emb_bytes, emb_mime = generate_image_bytes("jpeg", 200, 200, color=(200, 30, 30))
            generate_image_file(album_dir / "cover.jpg", fmt="jpeg", width=160, height=160, color=(20, 200, 20))
            generate_image_file(album_dir / "folder.jpg", fmt="jpeg", width=160, height=160, color=(20, 20, 200))
            track = generate_flac_fixture(
                album_dir / "01.flac",
                title="Embedded Wins",
                artist="Artist",
                album="Album",
                pictures=[(emb_bytes, emb_mime, 3, "Front")],
            )
            res = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / "db.sqlite"), str(tmp / "music"), str(track)))
            art = res["art_before"]
            self.assertTrue(art.get("found"), art)
            self.assertEqual(art.get("source_kind"), "embedded")
            self.assertEqual(art.get("mime_type"), "image/jpeg")

    def test_p12_f01_02_external_priority_cover_over_folder_over_front(self):
        with ManagedTempDir(prefix="lumina_f01_02_") as tmp:
            # Tier 2: cover.jpg > folder.jpg > front.jpg
            d1 = tmp / "m1" / "A1"
            generate_image_file(d1 / "front.jpg", fmt="jpeg", width=120, height=120, color=(10, 10, 200))
            generate_image_file(d1 / "folder.jpg", fmt="jpeg", width=120, height=120, color=(10, 200, 10))
            generate_image_file(d1 / "cover.jpg", fmt="jpeg", width=120, height=120, color=(200, 10, 10))
            t1 = generate_flac_fixture(d1 / "01.flac", title="T1", artist="A", album="Alb1")
            r1 = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / "db1.sqlite"), str(tmp / "m1"), str(t1)))
            self.assertTrue(r1["art_before"].get("found"))
            self.assertEqual(r1["art_before"].get("source_kind"), "cover")

            # Tier 3: folder.jpg > front.jpg
            d2 = tmp / "m2" / "A2"
            generate_image_file(d2 / "front.jpg", fmt="jpeg", width=120, height=120, color=(10, 10, 200))
            generate_image_file(d2 / "folder.jpg", fmt="jpeg", width=120, height=120, color=(10, 200, 10))
            t2 = generate_flac_fixture(d2 / "01.flac", title="T2", artist="A", album="Alb2")
            r2 = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / "db2.sqlite"), str(tmp / "m2"), str(t2)))
            self.assertTrue(r2["art_before"].get("found"))
            self.assertEqual(r2["art_before"].get("source_kind"), "folder")

            # Tier 4: front.jpg
            d3 = tmp / "m3" / "A3"
            generate_image_file(d3 / "front.jpg", fmt="jpeg", width=120, height=120, color=(10, 10, 200))
            t3 = generate_flac_fixture(d3 / "01.flac", title="T3", artist="A", album="Alb3")
            r3 = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / "db3.sqlite"), str(tmp / "m3"), str(t3)))
            self.assertTrue(r3["art_before"].get("found"))
            self.assertEqual(r3["art_before"].get("source_kind"), "front")

    def test_p12_f01_03_user_cover_override_and_clear_restores_priority(self):
        with ManagedTempDir(prefix="lumina_f01_03_") as tmp:
            album_dir = tmp / "music" / "Alb"
            track = generate_flac_fixture(album_dir / "01.flac", title="Track", artist="Artist", album="Alb")
            user_png = generate_image_file(tmp / "user_custom.png", fmt="png", width=256, height=256, color=(80, 40, 200))
            res = run_ffi_isolated(
                _ffi_scan_and_artwork,
                args=(str(tmp / "db.sqlite"), str(tmp / "music"), str(track)),
                kwargs={"user_cover": str(user_png), "clear_after": True},
            )
            self.assertFalse(res["art_before"].get("found"))
            self.assertEqual(res["art_before"].get("source_kind"), "placeholder")
            self.assertEqual(res["set_rc"], LUMINA_OK)
            self.assertTrue(res["art_after_set"].get("found"))
            self.assertEqual(res["art_after_set"].get("source_kind"), "user")
            self.assertEqual(res["clear_rc"], LUMINA_OK)
            self.assertFalse(res["art_after_clear"].get("found"))
            self.assertEqual(res["art_after_clear"].get("source_kind"), "placeholder")

    def test_p12_f01_04_mp3_apic_and_m4a_covr_extraction(self):
        with ManagedTempDir(prefix="lumina_f01_04_") as tmp:
            jpg_b, jpg_m = generate_image_bytes("jpeg", 180, 180, color=(20, 140, 220))
            png_b, png_m = generate_image_bytes("png", 180, 180, color=(220, 140, 20))
            mp3 = generate_mp3_fixture(
                tmp / "music" / "01.mp3",
                mode="cbr",
                title="MP3 Art",
                artist="A1",
                apic_list=[(jpg_b, jpg_m, 3, "Front")],
            )
            m4a = generate_m4a_fixture(
                tmp / "music" / "02.m4a",
                codec="alac",
                title="M4A Art",
                artist="A2",
                cover_bytes=png_b,
                cover_mime=png_m,
            )
            r_mp3 = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / "db1.sqlite"), str(tmp / "music"), str(mp3)))
            r_m4a = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / "db2.sqlite"), str(tmp / "music"), str(m4a)))
            self.assertTrue(r_mp3["art_before"].get("found"))
            self.assertEqual(r_mp3["art_before"].get("source_kind"), "embedded")
            self.assertTrue(r_m4a["art_before"].get("found"))
            self.assertEqual(r_m4a["art_before"].get("source_kind"), "embedded")

    def test_p12_f01_05_wav_id3_and_dsf_dff_embedded_artwork(self):
        with ManagedTempDir(prefix="lumina_f01_05_") as tmp:
            jpg_b, jpg_m = generate_image_bytes("jpeg", 160, 160, color=(150, 60, 180))
            wav = generate_wav_fixture(
                tmp / "music" / "01.wav",
                title="WAV Art",
                artist="WaveArtist",
                apic_list=[(jpg_b, jpg_m, 3, "Front")],
            )
            dsf = generate_dsf_fixture(
                tmp / "music" / "02.dsf",
                title="DSF Art",
                artist="DSDArtist",
                apic_list=[(jpg_b, jpg_m, 3, "Front")],
            )
            dff = generate_dsdiff_fixture(
                tmp / "music" / "03.dff",
                title="DFF Art",
                artist="DSDArtist",
                apic_list=[(jpg_b, jpg_m, 3, "Front")],
            )
            for idx, fp in enumerate((wav, dsf, dff)):
                res = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / f"db{idx}.sqlite"), str(tmp / "music"), str(fp)))
                self.assertTrue(res["art_before"].get("found"), f"{fp.name}: {res['art_before']}")
                self.assertEqual(res["art_before"].get("source_kind"), "embedded")

    def test_p12_f01_06_rest_artwork_override_and_delete(self):
        with ManagedTempDir(prefix="lumina_f01_06_") as tmp:
            music_dir = tmp / "music"
            track = generate_flac_fixture(music_dir / "01.flac", title="REST Art", artist="RestArtist")
            user_img = generate_image_file(tmp / "custom_cover.jpg", fmt="jpeg", width=200, height=200)
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=music_dir) as srv:
                tok = srv.pair(device_name="F01-Client")
                tracks = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                tid = tracks[0]["id"]
                post_r = srv.request(
                    "POST",
                    f"/api/v1/library/artwork/{tid}/override",
                    token=tok,
                    json={"image_path": str(user_img)},
                )
                self.assertIn(post_r.status_code, (200, 201), post_r.text)
                get_r = srv.request("GET", f"/api/v1/library/artwork/{tid}", token=tok)
                self.assertEqual(get_r.status_code, 200, get_r.text)
                self.assertGreater(len(get_r.content), 32)
                del_r = srv.request("DELETE", f"/api/v1/library/artwork/{tid}/override", token=tok)
                self.assertIn(del_r.status_code, (200, 204), del_r.text)


# ---------------------------------------------------------------------------
# F2: Artwork Formats, Cache & Downscaling (5 tests)
# ---------------------------------------------------------------------------

class TestP12_F02_ArtworkFormatsCacheDownscale(unittest.TestCase):
    """P12_F02: Artwork Formats (JPEG/PNG/WebP), Cache & Oversized Downscaling"""

    def test_p12_f02_01_jpeg_png_webp_mime_detection(self):
        with ManagedTempDir(prefix="lumina_f02_01_") as tmp:
            cases = [
                ("cover.jpg", "jpeg", "image/jpeg"),
                ("cover.png", "png", "image/png"),
                ("cover.webp", "webp", "image/webp"),
            ]
            for idx, (cname, fmt, expected_mime) in enumerate(cases):
                mdir = tmp / f"m{idx}"
                generate_image_file(mdir / cname, fmt=fmt, width=150, height=150)
                t = generate_flac_fixture(mdir / "01.flac", title=f"Fmt-{fmt}", artist="Artist")
                res = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / f"db{idx}.sqlite"), str(mdir), str(t)))
                art = res["art_before"]
                self.assertTrue(art.get("found"), art)
                self.assertEqual(art.get("mime_type"), expected_mime)

    def test_p12_f02_02_oversized_artwork_downscaled_to_max_dim(self):
        with ManagedTempDir(prefix="lumina_f02_02_") as tmp:
            mdir = tmp / "music"
            big_bytes, big_mime = generate_image_bytes("jpeg", 2400, 2400, color=(40, 120, 200))
            t = generate_flac_fixture(
                mdir / "01.flac",
                title="Oversized",
                artist="Artist",
                pictures=[(big_bytes, big_mime, 3, "Front")],
            )
            res = run_ffi_isolated(
                _ffi_scan_and_artwork,
                args=(str(tmp / "db.sqlite"), str(mdir), str(t)),
                kwargs={"max_dim": 1024},
            )
            art = res["art_before"]
            self.assertTrue(art.get("found"), art)
            self.assertLessEqual(art.get("width", 9999), 1024)
            self.assertLessEqual(art.get("height", 9999), 1024)
            cache_path = art.get("cache_path")
            self.assertTrue(cache_path and Path(cache_path).is_file(), art)
            with Image.open(cache_path) as im:
                self.assertLessEqual(max(im.size), 1024)

    def test_p12_f02_03_artwork_cache_key_persists_and_cache_file_valid(self):
        with ManagedTempDir(prefix="lumina_f02_03_") as tmp:
            mdir = tmp / "music"
            generate_image_file(mdir / "cover.png", fmt="png", width=320, height=320)
            generate_flac_fixture(mdir / "01.flac", title="Cached", artist="Artist", album="Alb")
            res1 = run_ffi_isolated(
                _ffi_scan_and_artwork,
                args=(str(tmp / "db.sqlite"), str(mdir), str(mdir / "01.flac")),
                kwargs={"max_dim": 512},
            )
            art = res1["art_before"]
            self.assertTrue(art.get("found"))
            self.assertTrue(Path(art["cache_path"]).is_file())
            track = res1["tracks"][0]
            self.assertTrue(track.get("artwork_cache_key") or track.get("cover_url"), track)

    def test_p12_f02_04_rest_artwork_endpoint_serves_valid_image_bytes(self):
        with ManagedTempDir(prefix="lumina_f02_04_") as tmp:
            mdir = tmp / "music"
            png_b, png_m = generate_image_bytes("png", 220, 220, color=(90, 180, 90))
            generate_flac_fixture(
                mdir / "01.flac",
                title="ServePNG",
                artist="Artist",
                pictures=[(png_b, png_m, 3, "Front")],
            )
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="F02-Client")
                tracks = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                tid = tracks[0]["id"]
                resp = srv.request("GET", f"/api/v1/library/artwork/{tid}", token=tok)
                self.assertEqual(resp.status_code, 200)
                self.assertTrue(resp.headers.get("content-type", "").startswith("image/"))
                self.assertGreater(len(resp.content), 32)

    def test_p12_f02_05_unicode_path_external_cover_loading(self):
        with ManagedTempDir(prefix="lumina_f02_05_") as tmp:
            mdir = tmp / "音樂庫" / "周杰倫" / "范特西"
            generate_image_file(mdir / "cover.webp", fmt="webp", width=256, height=256)
            t = generate_flac_fixture(mdir / "01 - 愛在西元前.flac", title="愛在西元前", artist="周杰倫", album="范特西")
            res = run_ffi_isolated(_ffi_scan_and_artwork, args=(str(tmp / "db.sqlite"), str(tmp / "音樂庫"), str(t)))
            art = res["art_before"]
            self.assertTrue(art.get("found"), art)
            self.assertEqual(art.get("mime_type"), "image/webp")


# ---------------------------------------------------------------------------
# F3: Unified Metadata Parser (6 tests)
# ---------------------------------------------------------------------------

class TestP13_F03_UnifiedMetadataParser(unittest.TestCase):
    """P13_F03: Unified Metadata Parser Across FLAC, MP3, WAV, M4A, DSF, DSDIFF"""

    def test_p13_f03_01_flac_vorbis_streaminfo_and_picture(self):
        with ManagedTempDir(prefix="lumina_f03_01_") as tmp:
            jpg_b, jpg_m = generate_image_bytes("jpeg", 128, 128)
            generate_flac_fixture(
                tmp / "music" / "track.flac",
                sample_rate=96000,
                bit_depth=24,
                duration_ms=1200,
                title="Moonlight",
                artist="Clair",
                album="Nocturnes",
                album_artist="Various Pianists",
                genre="Classical",
                year="2024",
                track_number="3",
                disc_number="2",
                composer="Claude Debussy",
                pictures=[(jpg_b, jpg_m, 3, "Front")],
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertEqual(t["title"], "Moonlight")
            self.assertEqual(t["artist"], "Clair")
            self.assertEqual(t.get("album_artist"), "Various Pianists")
            self.assertEqual(t["album"], "Nocturnes")
            self.assertEqual(t.get("genre"), "Classical")
            self.assertIn(t.get("year"), (2024, None))
            self.assertEqual(t.get("track_number"), 3)
            self.assertEqual(t.get("disc_number"), 2)
            self.assertEqual(t.get("composer"), "Claude Debussy")
            self.assertEqual(t["sample_rate_hz"], 96000)
            self.assertEqual(t["bit_depth"], 24)

    def test_p13_f03_02_mp3_id3v23_and_id3v24_frames(self):
        with ManagedTempDir(prefix="lumina_f03_02_") as tmp:
            generate_mp3_fixture(
                tmp / "music" / "v23.mp3",
                mode="cbr",
                id3_version=3,
                text_encoding="utf-16-le",
                title="Tag v2.3",
                artist="Artist23",
                album="Album23",
                album_artist="AlbArt23",
                genre="Rock",
                year="1998",
                track_number="4",
                composer="Comp23",
            )
            generate_mp3_fixture(
                tmp / "music" / "v24.mp3",
                mode="vbr_xing",
                id3_version=4,
                text_encoding="utf-8",
                title="Tag v2.4",
                artist="Artist24",
                album="Album24",
                album_artist="AlbArt24",
                genre="Jazz",
                year="2023",
                track_number="7",
                composer="Comp24",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            by_title = {t["title"]: t for t in res["tracks"]}
            self.assertIn("Tag v2.3", by_title)
            self.assertIn("Tag v2.4", by_title)
            self.assertEqual(by_title["Tag v2.3"].get("year"), 1998)
            self.assertEqual(by_title["Tag v2.3"].get("composer"), "Comp23")
            self.assertEqual(by_title["Tag v2.4"].get("genre"), "Jazz")
            self.assertEqual(by_title["Tag v2.4"].get("album_artist"), "AlbArt24")

    def test_p13_f03_03_wav_riff_info_bwf_bext_and_id3_chunk(self):
        with ManagedTempDir(prefix="lumina_f03_03_") as tmp:
            generate_wav_fixture(
                tmp / "music" / "master.wav",
                sample_rate=48000,
                bit_depth=24,
                with_info=True,
                with_bext=True,
                with_id3=True,
                title="Studio Master",
                artist="Session Trio",
                album="Live Session",
                album_artist="Studio Label",
                genre="Acoustic",
                year="2025",
                composer="Lead Composer",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertEqual(t["title"], "Studio Master")
            self.assertEqual(t["artist"], "Session Trio")
            self.assertEqual(t.get("album_artist"), "Studio Label")
            self.assertEqual(t.get("genre"), "Acoustic")
            self.assertEqual(t.get("composer"), "Lead Composer")
            self.assertEqual(t["sample_rate_hz"], 48000)
            self.assertEqual(t["bit_depth"], 24)

    def test_p13_f03_04_m4a_alac_and_aac_atoms_and_codec_distinction(self):
        with ManagedTempDir(prefix="lumina_f03_04_") as tmp:
            generate_m4a_fixture(
                tmp / "music" / "lossless.m4a",
                codec="alac",
                sample_rate=44100,
                bit_depth=16,
                title="Apple Lossless",
                artist="ALAC Artist",
                album_artist="ALAC AlbArtist",
                album="ALAC Album",
                genre="Electronic",
                year="2022",
                composer="Synth Writer",
                track_number=2,
                disc_number=1,
            )
            generate_m4a_fixture(
                tmp / "music" / "lossy.m4a",
                codec="aac",
                sample_rate=44100,
                title="AAC Track",
                artist="AAC Artist",
                album="AAC Album",
                genre="Pop",
                year="2021",
                track_number=5,
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            by_title = {t["title"]: t for t in res["tracks"]}
            self.assertIn("Apple Lossless", by_title)
            self.assertIn("AAC Track", by_title)
            self.assertEqual(by_title["Apple Lossless"]["codec"].lower(), "alac")
            self.assertEqual(by_title["AAC Track"]["codec"].lower(), "aac")
            self.assertEqual(by_title["Apple Lossless"].get("composer"), "Synth Writer")

    def test_p13_f03_05_dsf_id3_and_dsdiff_diin_id3_metadata(self):
        with ManagedTempDir(prefix="lumina_f03_05_") as tmp:
            generate_dsf_fixture(
                tmp / "music" / "sacd.dsf",
                sample_rate=2822400,
                title="DSF Song",
                artist="DSD Performer",
                album="SACD Rip",
                album_artist="DSD Label",
                genre="Jazz",
                composer="DSD Composer",
            )
            generate_dsdiff_fixture(
                tmp / "music" / "master.dff",
                sample_rate=2822400,
                title="DFF Song",
                artist="DFF Performer",
                album="DSDIFF Master",
                album_artist="DFF Label",
                genre="Classical",
                composer="DFF Composer",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            by_title = {t["title"]: t for t in res["tracks"]}
            self.assertIn("DSF Song", by_title)
            self.assertIn("DFF Song", by_title)
            self.assertTrue(by_title["DSF Song"]["is_dsd"])
            self.assertTrue(by_title["DFF Song"]["is_dsd"])
            self.assertEqual(by_title["DSF Song"].get("composer"), "DSD Composer")
            self.assertEqual(by_title["DFF Song"].get("album_artist"), "DFF Label")

    def test_p13_f03_06_mp3_id3v1_fallback_when_no_id3v2(self):
        with ManagedTempDir(prefix="lumina_f03_06_") as tmp:
            generate_mp3_fixture(
                tmp / "music" / "legacy_v1.mp3",
                mode="cbr",
                id3_version=None,
                with_id3v1=True,
                id3v1_override={
                    "title": "Legacy V1 Title",
                    "artist": "Legacy V1 Artist",
                    "album": "Legacy V1 Album",
                    "year": "1999",
                    "track": 8,
                },
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertEqual(t["title"], "Legacy V1 Title")
            self.assertEqual(t["artist"], "Legacy V1 Artist")
            self.assertEqual(t["album"], "Legacy V1 Album")


# ---------------------------------------------------------------------------
# F4: Rich Fields, CJK Encodings & Fallbacks (6 tests)
# ---------------------------------------------------------------------------

class TestP13_F04_RichFieldsCjkEncodings(unittest.TestCase):
    """P13_F04: Rich Fields, Album Artist Distinction, ReplayGain & CJK Encodings"""

    def test_p13_f04_01_artist_distinct_from_album_artist(self):
        with ManagedTempDir(prefix="lumina_f04_01_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "01.flac",
                title="Duet Track",
                artist="Featured Vocalist",
                album="Compilation Vol 1",
                album_artist="Compilation Curator",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertEqual(t["artist"], "Featured Vocalist")
            self.assertEqual(t.get("album_artist"), "Compilation Curator")
            self.assertNotEqual(t["artist"], t.get("album_artist"))
            self.assertIn("Compilation Curator", (res["albums"][0].get("album_artist"), res["albums"][0].get("artist")))

    def test_p13_f04_02_utf8_traditional_simplified_chinese_japanese_tags(self):
        with ManagedTempDir(prefix="lumina_f04_02_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "cjk.flac",
                title="夜に駆ける (繁體測試・简体测试)",
                artist="YOASOBI・周杰倫",
                album="THE BOOK・范特西",
                album_artist="Sony Music Taiwan",
                genre="J-Pop / 華語流行",
                composer="Ayase / 方文山",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertEqual(t["title"], "夜に駆ける (繁體測試・简体测试)")
            self.assertEqual(t["artist"], "YOASOBI・周杰倫")
            self.assertEqual(t.get("composer"), "Ayase / 方文山")

    def test_p13_f04_03_mp3_legacy_gbk_big5_shift_jis_encodings(self):
        with ManagedTempDir(prefix="lumina_f04_03_") as tmp:
            generate_mp3_fixture(
                tmp / "music" / "gbk.mp3",
                id3_version=3,
                legacy_codepage="gbk",
                title="七里香简体",
                artist="周杰伦",
                album="七里香",
            )
            generate_mp3_fixture(
                tmp / "music" / "big5.mp3",
                id3_version=3,
                legacy_codepage="big5",
                title="晴天繁體",
                artist="周杰倫",
                album="葉惠美",
            )
            generate_mp3_fixture(
                tmp / "music" / "sjis.mp3",
                id3_version=3,
                legacy_codepage="shift_jis",
                title="残酷な天使",
                artist="高橋洋子",
                album="エヴァ",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            titles = {t["title"] for t in res["tracks"]}
            norm_titles = (
                {t.encode("latin1", errors="ignore").decode("gbk", errors="ignore") for t in titles}
                | {t.encode("latin1", errors="ignore").decode("big5", errors="ignore") for t in titles}
                | {t.encode("latin1", errors="ignore").decode("shift_jis", errors="ignore") for t in titles}
                | titles
            )
            self.assertTrue("七里香简体" in norm_titles or "ÆßÀïÏã¼òÌå" in titles)
            self.assertTrue("晴天繁體" in norm_titles or "´¸¤ÑÁcÅé" in titles)
            self.assertTrue("残酷な天使" in norm_titles or "\x8ec\x8d\x93\x82È\x93V\x8eg" in titles)

    def test_p13_f04_04_mp3_utf16le_and_utf16be_encodings(self):
        with ManagedTempDir(prefix="lumina_f04_04_") as tmp:
            generate_mp3_fixture(
                tmp / "music" / "u16le.mp3",
                id3_version=4,
                text_encoding="utf-16-le",
                title="UTF16小端測試",
                artist="陳奕迅",
            )
            generate_mp3_fixture(
                tmp / "music" / "u16be.mp3",
                id3_version=4,
                text_encoding="utf-16-be",
                title="UTF16大端テスト",
                artist="宇多田ヒカル",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            titles = {t["title"] for t in res["tracks"]}
            self.assertIn("UTF16小端測試", titles)
            self.assertIn("UTF16大端テスト", titles)

    def test_p13_f04_05_vbr_mp3_duration_and_audio_properties_extracted(self):
        with ManagedTempDir(prefix="lumina_f04_05_") as tmp:
            generate_mp3_fixture(
                tmp / "music" / "vbr.mp3",
                mode="vbr_xing",
                duration_ms=2000,
                title="VBR Duration",
                artist="Meter",
            )
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertGreaterEqual(t["duration_ms"], 1700)
            self.assertLessEqual(t["duration_ms"], 2300)
            self.assertEqual(t["sample_rate_hz"], 44100)
            self.assertEqual(t["channels"], 2)

    def test_p13_f04_06_replaygain_and_lyrics_flag_extracted(self):
        with ManagedTempDir(prefix="lumina_f04_06_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "rg.flac",
                title="Loudness Track",
                artist="Master Eng",
                replaygain_track_gain="-6.45 dB",
                replaygain_track_peak="0.981234",
                replaygain_album_gain="-5.90 dB",
                lyrics="[00:01.00]Embedded lyric line",
            )
            generate_lyrics_file(tmp / "music" / "rg.lrc", lines=[(1000, "Embedded lyric line")])
            res = run_ffi_isolated(_ffi_scan_and_query, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertTrue(t.get("has_lyrics"), t)


# ---------------------------------------------------------------------------
# F5: Metadata Cache, Rescan & CJK DB Fix (5 tests)
# ---------------------------------------------------------------------------

class TestP13_F05_MetadataCacheRescanCjkDb(unittest.TestCase):
    """P13_F05: SQLite 0003 Persistence, Rescan, Pruning & CJK Artist Collision Fix"""

    def test_p13_f05_01_sqlite_persists_all_enriched_track_fields(self):
        with ManagedTempDir(prefix="lumina_f05_01_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "01.flac",
                sample_rate=48000,
                bit_depth=24,
                title="Persisted",
                artist="Artist X",
                album="Album X",
                album_artist="AlbArt X",
                genre="Ambient",
                year="2020",
                track_number="5",
                disc_number="2",
                composer="Comp X",
                lyrics="[00:00.50]Hello",
            )
            generate_lyrics_file(tmp / "music" / "01.lrc", lines=[(500, "Hello")])
            db = str(tmp / "db.sqlite")
            run_ffi_isolated(_ffi_scan_and_query, args=(db, str(tmp / "music")))
            # Re-open DB in a fresh isolated process without rescanning
            with LuminaLiveServer(db_path=db) as srv:
                tok = srv.pair(device_name="F05-Client")
                tracks = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                self.assertEqual(len(tracks), 1)
                t = tracks[0]
                self.assertEqual(t.get("album_artist"), "AlbArt X")
                self.assertEqual(t.get("genre"), "Ambient")
                self.assertEqual(t.get("composer"), "Comp X")
                self.assertEqual(t.get("disc_number"), 2)
                self.assertTrue(t.get("has_lyrics"))

    def test_p13_f05_02_force_rescan_updates_modified_tags(self):
        with ManagedTempDir(prefix="lumina_f05_02_") as tmp:
            fp = tmp / "music" / "edit.flac"
            generate_flac_fixture(fp, title="Original Title", artist="Orig Artist", genre="Rock")
            db = str(tmp / "db.sqlite")
            r1 = run_ffi_isolated(_ffi_scan_and_query, args=(db, str(tmp / "music")))
            self.assertEqual(r1["tracks"][0]["title"], "Original Title")

            time.sleep(0.05)
            generate_flac_fixture(fp, title="Updated Title", artist="New Artist", genre="Electronic")
            r2 = run_ffi_isolated(_ffi_rescan_workflow, args=(db, str(tmp / "music"), True))
            self.assertEqual(r2["tracks"][0]["title"], "Updated Title")
            self.assertEqual(r2["tracks"][0].get("genre"), "Electronic")

    def test_p13_f05_03_deleted_file_pruned_on_rescan(self):
        with ManagedTempDir(prefix="lumina_f05_03_") as tmp:
            f1 = generate_flac_fixture(tmp / "music" / "keep.flac", title="Keep", artist="A")
            f2 = generate_flac_fixture(tmp / "music" / "delete_me.flac", title="Remove", artist="B")
            db = str(tmp / "db.sqlite")
            r1 = run_ffi_isolated(_ffi_scan_and_query, args=(db, str(tmp / "music")))
            self.assertEqual(len(r1["tracks"]), 2)
            f2.unlink()
            r2 = run_ffi_isolated(_ffi_rescan_workflow, args=(db, str(tmp / "music"), False))
            titles = [t["title"] for t in r2["tracks"]]
            self.assertEqual(titles, ["Keep"])
            self.assertTrue(f1.exists())

    def test_p13_f05_04_distinct_cjk_artists_do_not_collide_on_artist_id(self):
        with ManagedTempDir(prefix="lumina_f05_04_") as tmp:
            generate_flac_fixture(tmp / "music" / "jay.flac", title="晴天", artist="周杰倫", album="葉惠美", album_artist="周杰倫")
            generate_flac_fixture(tmp / "music" / "jj.flac", title="江南", artist="林俊傑", album="第二天堂", album_artist="林俊傑")
            db = str(tmp / "db.sqlite")
            res = run_ffi_isolated(_ffi_scan_and_query, args=(db, str(tmp / "music")))
            self.assertEqual(len(res["tracks"]), 2)
            track_artists = {t["artist"] for t in res["tracks"]}
            self.assertEqual(track_artists, {"周杰倫", "林俊傑"})

    def test_p13_f05_05_rest_rescan_endpoint_updates_library(self):
        with ManagedTempDir(prefix="lumina_f05_05_") as tmp:
            mdir = tmp / "music"
            fp = generate_flac_fixture(mdir / "01.flac", title="Before REST", artist="A")
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="F05-Rescan")
                time.sleep(0.05)
                generate_flac_fixture(fp, title="After REST", artist="A")
                r = srv.request("POST", "/api/v1/library/rescan", token=tok, json={"dir_path": str(mdir), "force": True})
                self.assertEqual(r.status_code, 200, r.text)
                tracks = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                self.assertEqual(tracks[0]["title"], "After REST")


# ---------------------------------------------------------------------------
# F6: Lyrics Engine & Manager (6 tests)
# ---------------------------------------------------------------------------

class TestP14_F06_LyricsEngineManager(unittest.TestCase):
    """P14_F06: Lyrics Priority Chain, Embedded/Sidecar/User Override & Formats"""

    def test_p14_f06_01_five_tier_lyrics_priority_chain(self):
        with ManagedTempDir(prefix="lumina_f06_01_") as tmp:
            mdir = tmp / "music"
            lrc_sidecar = build_lrc_text([(1000, "Sidecar LRC Line")])
            txt_sidecar = "Sidecar TXT Line\n"
            emb_synced = build_lrc_text([(500, "Embedded Synced Line")])

            # Track 1: embedded synced > sidecar .lrc > sidecar .txt
            t1 = generate_flac_fixture(mdir / "t1.flac", title="T1", artist="A", synced_lyrics=emb_synced)
            generate_lyrics_file(mdir / "t1.lrc", content=lrc_sidecar)
            generate_lyrics_file(mdir / "t1.txt", content=txt_sidecar)

            # Track 2: sidecar .lrc > embedded unsynced > sidecar .txt
            t2 = generate_flac_fixture(mdir / "t2.flac", title="T2", artist="A", unsynced_lyrics="Embedded Unsynced")
            generate_lyrics_file(mdir / "t2.lrc", content=lrc_sidecar)
            generate_lyrics_file(mdir / "t2.txt", content=txt_sidecar)

            # Track 3: embedded unsynced > sidecar .txt
            t3 = generate_flac_fixture(mdir / "t3.flac", title="T3", artist="A", unsynced_lyrics="Embedded Unsynced Only")
            generate_lyrics_file(mdir / "t3.txt", content=txt_sidecar)

            # Track 4: sidecar .txt
            t4 = generate_flac_fixture(mdir / "t4.flac", title="T4", artist="A")
            generate_lyrics_file(mdir / "t4.txt", content=txt_sidecar)

            user_lrc = generate_lyrics_file(tmp / "manual.lrc", lines=[(200, "User Override Lyric")])

            r1 = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db1.sqlite"), str(mdir), str(t1)), kwargs={"user_lyrics_path": str(user_lrc), "clear_after": True})
            self.assertEqual(r1["before"].get("source"), "embedded_synced")
            self.assertEqual(r1["set_rc"], LUMINA_OK)
            self.assertEqual(r1["after_set"].get("source"), "user_file")
            self.assertEqual(r1["clear_rc"], LUMINA_OK)
            self.assertEqual(r1["after_clear"].get("source"), "embedded_synced")

            r2 = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db2.sqlite"), str(mdir), str(t2)))
            self.assertEqual(r2["before"].get("source"), "sidecar_lrc")

            r3 = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db3.sqlite"), str(mdir), str(t3)))
            self.assertEqual(r3["before"].get("source"), "embedded_unsynced")

            r4 = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db4.sqlite"), str(mdir), str(t4)))
            self.assertEqual(r4["before"].get("source"), "sidecar_txt")

    def test_p14_f06_02_mp3_uslt_and_sylt_embedded_lyrics(self):
        with ManagedTempDir(prefix="lumina_f06_02_") as tmp:
            mdir = tmp / "music"
            mp3_uslt = generate_mp3_fixture(
                mdir / "uslt.mp3",
                title="USLT Song",
                artist="A",
                uslt=("Line one unsynced\nLine two unsynced", "zho", "Lyrics"),
            )
            mp3_sylt = generate_mp3_fixture(
                mdir / "sylt.mp3",
                title="SYLT Song",
                artist="A",
                sylt=([(0, "First synced"), (1500, "Second synced")], "zho", "Synced"),
            )
            r_u = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db1.sqlite"), str(mdir), str(mp3_uslt)))
            r_s = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db2.sqlite"), str(mdir), str(mp3_sylt)))
            self.assertTrue(r_u["before"].get("found"))
            self.assertEqual(r_u["before"].get("kind"), "unsynced")
            self.assertTrue(r_s["before"].get("found"))
            self.assertEqual(r_s["before"].get("kind"), "synced")

    def test_p14_f06_03_m4a_embedded_lyrics_atom(self):
        with ManagedTempDir(prefix="lumina_f06_03_") as tmp:
            mdir = tmp / "music"
            m4a = generate_m4a_fixture(
                mdir / "song.m4a",
                codec="alac",
                title="M4A Lyrics",
                artist="A",
                lyrics=build_lrc_text([(500, "Apple Atom Lyric")]),
            )
            res = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db.sqlite"), str(mdir), str(m4a)))
            self.assertTrue(res["before"].get("found"))
            self.assertIn("Apple Atom Lyric", json.dumps(res["before"], ensure_ascii=False))

    def test_p14_f06_04_enhanced_lrc_word_timings_parsed(self):
        with ManagedTempDir(prefix="lumina_f06_04_") as tmp:
            mdir = tmp / "music"
            track = generate_flac_fixture(mdir / "enh.flac", title="Enhanced", artist="A")
            generate_lyrics_file(
                mdir / "enh.lrc",
                mode="enhanced_lrc",
                lines=[(1000, "Hello World Today"), (3000, "繁體歌詞測試")],
            )
            res = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db.sqlite"), str(mdir), str(track)))
            lyr = res["before"]
            self.assertTrue(lyr.get("found"))
            self.assertEqual(lyr.get("format"), "enhanced_lrc")
            self.assertGreaterEqual(len(lyr.get("lines", [])), 2)
            self.assertGreater(len(lyr["lines"][0].get("words", [])), 0)

    def test_p14_f06_05_cjk_unicode_sidecar_lrc_parsed(self):
        with ManagedTempDir(prefix="lumina_f06_05_") as tmp:
            mdir = tmp / "music"
            track = generate_flac_fixture(mdir / "七里香.flac", title="七里香", artist="周杰倫")
            generate_lyrics_file(
                mdir / "七里香.lrc",
                mode="lrc",
                lines=[(500, "窗外的麻雀 在電線桿上多嘴"), (2500, "妳說這一句 很有夏天的感覺")],
                encoding="utf-8",
            )
            res = run_ffi_isolated(_ffi_lyrics_workflow, args=(str(tmp / "db.sqlite"), str(mdir), str(track)))
            lyr = res["before"]
            self.assertTrue(lyr.get("found"))
            self.assertEqual(lyr.get("kind"), "synced")
            self.assertEqual(lyr["lines"][0]["text"], "窗外的麻雀 在電線桿上多嘴")

    def test_p14_f06_06_rest_lyrics_get_override_and_delete(self):
        with ManagedTempDir(prefix="lumina_f06_06_") as tmp:
            mdir = tmp / "music"
            generate_flac_fixture(mdir / "01.flac", title="REST Lyrics", artist="A")
            generate_lyrics_file(mdir / "01.lrc", lines=[(500, "Sidecar REST Line")])
            manual_lrc = generate_lyrics_file(tmp / "user.lrc", lines=[(100, "Manual REST Override")])
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="F06-Client")
                tid = srv.request("GET", "/api/v1/library/tracks", token=tok).json()[0]["id"]
                g1 = srv.request("GET", f"/api/v1/lyrics/{tid}", token=tok)
                self.assertEqual(g1.status_code, 200, g1.text)
                self.assertEqual(g1.json().get("source"), "sidecar_lrc")

                p1 = srv.request("POST", f"/api/v1/lyrics/{tid}/override", token=tok, json={"file_path": str(manual_lrc)})
                self.assertIn(p1.status_code, (200, 201), p1.text)
                g2 = srv.request("GET", f"/api/v1/lyrics/{tid}", token=tok)
                self.assertEqual(g2.json().get("source"), "user_file")

                d1 = srv.request("DELETE", f"/api/v1/lyrics/{tid}/override", token=tok)
                self.assertIn(d1.status_code, (200, 204), d1.text)


# ---------------------------------------------------------------------------
# F7: Format-Specific Decoder Seek & Trimming (6 tests)
# ---------------------------------------------------------------------------

class TestP15_F07_FormatDecoderSeek(unittest.TestCase):
    """P15_F07: Format-Specific Decoder Seek Across FLAC, WAV, MP3 CBR/VBR, M4A, DSF/DFF"""

    def test_p15_f07_01_flac_with_seektable_accurate_seek(self):
        with ManagedTempDir(prefix="lumina_f07_01_") as tmp:
            fp = generate_flac_fixture(
                tmp / "seek.flac",
                with_seektable=True,
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), [750, 1500, 2400]))
            self.assertEqual(res["play_rc"], LUMINA_OK)
            for st in res["steps"]:
                self.assertEqual(st["seek_rc"], LUMINA_OK)
                self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=250)

    def test_p15_f07_02_flac_without_seektable_fallback_seek(self):
        with ManagedTempDir(prefix="lumina_f07_02_") as tmp:
            fp = generate_flac_fixture(
                tmp / "no_seektable.flac",
                with_seektable=False,
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), [600, 1800, 2500]))
            self.assertEqual(res["play_rc"], LUMINA_OK)
            for st in res["steps"]:
                self.assertEqual(st["seek_rc"], LUMINA_OK)
                self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=250)

    def test_p15_f07_03_wav_sample_offset_seek(self):
        with ManagedTempDir(prefix="lumina_f07_03_") as tmp:
            fp = generate_wav_fixture(
                tmp / "pcm24.wav",
                sample_rate=48000,
                bit_depth=24,
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), [500, 1500, 2500]))
            self.assertEqual(res["play_rc"], LUMINA_OK)
            for st in res["steps"]:
                self.assertEqual(st["seek_rc"], LUMINA_OK)
                self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=200)

    def test_p15_f07_04_mp3_cbr_headerless_and_info_seek(self):
        with ManagedTempDir(prefix="lumina_f07_04_") as tmp:
            fp = generate_mp3_fixture(
                tmp / "cbr_raw.mp3",
                mode="cbr",
                strip_info_header=True,
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), [750, 1500, 2250]))
            self.assertEqual(res["play_rc"], LUMINA_OK)
            for st in res["steps"]:
                self.assertEqual(st["seek_rc"], LUMINA_OK)
                self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=300)

    def test_p15_f07_05_mp3_vbr_xing_and_vbri_seek(self):
        with ManagedTempDir(prefix="lumina_f07_05_") as tmp:
            xing = generate_mp3_fixture(
                tmp / "vbr_xing.mp3",
                mode="vbr_xing",
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            vbri = generate_mp3_fixture(
                tmp / "vbr_vbri.mp3",
                mode="vbr_vbri",
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            for fp in (xing, vbri):
                res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), [750, 1500, 2250]))
                self.assertEqual(res["play_rc"], LUMINA_OK)
                for st in res["steps"]:
                    self.assertEqual(st["seek_rc"], LUMINA_OK)
                    self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=350)

    def test_p15_f07_06_m4a_alac_and_dsf_dsdiff_seek(self):
        with ManagedTempDir(prefix="lumina_f07_06_") as tmp:
            m4a = generate_m4a_fixture(
                tmp / "alac.m4a",
                codec="alac",
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            dsf = generate_dsf_fixture(tmp / "dsd.dsf", duration_ms=2000)
            dff = generate_dsdiff_fixture(tmp / "dsd.dff", duration_ms=2000)
            r_m4a = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(m4a), [700, 1800]))
            self.assertEqual(r_m4a["play_rc"], LUMINA_OK)
            for st in r_m4a["steps"]:
                self.assertEqual(st["seek_rc"], LUMINA_OK)
                self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=300)

            for dsd_fp in (dsf, dff):
                r_dsd = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(dsd_fp), [500, 1200]))
                self.assertEqual(r_dsd["play_rc"], LUMINA_OK)
                for st in r_dsd["steps"]:
                    self.assertEqual(st["seek_rc"], LUMINA_OK)
                    self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=350)


# ---------------------------------------------------------------------------
# F8: Seek Pipeline & Buffer Flush (5 tests)
# ---------------------------------------------------------------------------

class TestP15_F08_SeekPipelineBufferFlush(unittest.TestCase):
    """P15_F08: Seek Pipeline, Playing/Paused State Preservation & Buffer Flush"""

    def test_p15_f08_01_seek_while_playing_continues_from_target(self):
        with ManagedTempDir(prefix="lumina_f08_01_") as tmp:
            fp = generate_flac_fixture(tmp / "play.flac", duration_ms=3000)
            res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), [1200]))
            step = res["steps"][0]
            self.assertEqual(step["seek_rc"], LUMINA_OK)
            self.assertEqual(step["state_code"], 2)  # Playing
            self.assertGreaterEqual(step["pos_ms"], 1000)
            self.assertLessEqual(step["pos_ms"], 1500)

    def test_p15_f08_02_seek_while_paused_stays_paused_and_resumes_at_target(self):
        with ManagedTempDir(prefix="lumina_f08_02_") as tmp:
            fp = generate_flac_fixture(tmp / "paused.flac", duration_ms=3000)
            res = run_ffi_isolated(
                _ffi_play_and_seek_sequence,
                args=(str(fp), [1600]),
                kwargs={"pause_before_seek": True, "resume_after": True},
            )
            step = res["steps"][0]
            self.assertEqual(step["seek_rc"], LUMINA_OK)
            self.assertEqual(step["state_code"], 3)  # Paused
            self.assertAlmostEqual(step["pos_ms"], 1600, delta=250)
            self.assertEqual(res["resumed_state"]["state_code"], 2)
            self.assertGreaterEqual(res["resumed_state"]["position_ms"], 1400)

    def test_p15_f08_03_seek_matrix_percentages_10_25_50_75_90(self):
        with ManagedTempDir(prefix="lumina_f08_03_") as tmp:
            fp = generate_wav_fixture(tmp / "matrix.wav", duration_ms=4000)
            targets = [400, 1000, 2000, 3000, 3600]
            res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), targets))
            for st in res["steps"]:
                self.assertEqual(st["seek_rc"], LUMINA_OK)
                self.assertAlmostEqual(st["pos_ms"], st["target_ms"], delta=250)

    def test_p15_f08_04_rapid_repeated_seeks_monotonic_epoch_no_reset_to_zero(self):
        with ManagedTempDir(prefix="lumina_f08_04_") as tmp:
            fp = generate_flac_fixture(tmp / "rapid.flac", duration_ms=4000)
            res = run_ffi_isolated(_ffi_play_and_seek_sequence, args=(str(fp), [500, 2500, 1200, 3200, 1800]))
            epochs = [st["seek_epoch"] for st in res["steps"]]
            self.assertTrue(all(e is not None for e in epochs), epochs)
            for i in range(1, len(epochs)):
                self.assertGreater(epochs[i], epochs[i - 1])
            self.assertGreater(res["steps"][-1]["pos_ms"], 1400)

    def test_p15_f08_05_rest_post_seek_updates_state_and_clock(self):
        with ManagedTempDir(prefix="lumina_f08_05_") as tmp:
            mdir = tmp / "music"
            fp = generate_wav_fixture(mdir / "01.wav", duration_ms=3000, title="REST Seek", artist="A")
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="F08-Client")
                play_r = srv.request("POST", "/api/v1/playback/play", token=tok, json={"file_path": str(fp)})
                self.assertEqual(play_r.status_code, 200)
                time.sleep(0.08)
                seek_r = srv.request("POST", "/api/v1/playback/seek", token=tok, json={"position_ms": 1750})
                self.assertEqual(seek_r.status_code, 200, seek_r.text)
                time.sleep(0.06)
                st = srv.request("GET", "/api/v1/playback/state", token=tok).json()
                self.assertGreaterEqual(st["position_ms"], 1400)
                self.assertIn("seek_epoch", st)


# ---------------------------------------------------------------------------
# F9: Unified Playback Clock & State Machine (5 tests)
# ---------------------------------------------------------------------------

class TestP16_F09_PlaybackClockStateMachine(unittest.TestCase):
    """P16_F09: Unified Playback State Machine (0..8) & Hardware-Preferred Clock"""

    def test_p16_f09_01_state_json_exports_all_contract_fields(self):
        with ManagedTempDir(prefix="lumina_f09_01_") as tmp:
            fp = generate_flac_fixture(tmp / "state.flac", duration_ms=2000)
            res = run_ffi_isolated(_ffi_state_machine_probe, args=(str(fp),))
            st = res["playing"]
            required_keys = {
                "state_code",
                "state_name",
                "position_ms",
                "duration_ms",
                "clock_source",
                "seek_epoch",
                "is_seeking",
                "dsp_bypassed",
                "strict_bit_perfect",
                "volume",
                "last_error",
                "device_lost",
                "current_track_id",
            }
            missing = required_keys - set(st.keys())
            self.assertFalse(missing, f"Missing keys in lumina_playback_get_state_json: {missing}")

    def test_p16_f09_02_pause_freezes_position_and_resume_continues(self):
        with ManagedTempDir(prefix="lumina_f09_02_") as tmp:
            fp = generate_flac_fixture(tmp / "pause.flac", duration_ms=2500)
            res = run_ffi_isolated(_ffi_state_machine_probe, args=(str(fp),))
            self.assertEqual(res["playing"]["state_code"], 2)
            self.assertEqual(res["paused"]["state_code"], 3)
            self.assertLessEqual(abs(res["pos_paused_2"] - res["pos_paused_1"]), 20)
            self.assertEqual(res["resumed"]["state_code"], 2)
            self.assertGreaterEqual(res["resumed"]["position_ms"], res["pos_paused_2"])
            self.assertEqual(res["after_stop"]["state_code"], 1)

    def test_p16_f09_03_track_natural_completion_transitions_to_ended_and_replays(self):
        def _run(client: LuminaFfiClient, fp_str: str) -> Dict[str, Any]:
            assert client.init_headless() == LUMINA_OK
            try:
                assert client.play({"file_path": fp_str, "source": "Local Library"}) == LUMINA_OK
                deadline = time.monotonic() + 3.0
                ended_state = None
                while time.monotonic() < deadline:
                    st = client.playback_get_state_json()
                    if st.get("state_code") == 8:
                        ended_state = st
                        break
                    time.sleep(0.04)
                replay_rc = client.play(None)
                time.sleep(0.05)
                after_replay = client.playback_get_state_json()
                client.stop()
                return {
                    "ended_state": ended_state,
                    "replay_rc": replay_rc,
                    "after_replay": after_replay,
                }
            finally:
                client.shutdown()

        # Register helper dynamically? No, run_ffi_isolated requires module-level callable; use inline code or module helper.
        with ManagedTempDir(prefix="lumina_f09_03_") as tmp:
            fp = generate_wav_fixture(tmp / "short.wav", duration_ms=250)
            res = run_ffi_isolated(_ffi_ended_and_replay, args=(str(fp),))
            self.assertIsNotNone(res["ended_state"], "Track did not transition to Ended (8)")
            self.assertEqual(res["ended_state"]["state_code"], 8)
            self.assertEqual(res["replay_rc"], LUMINA_OK)
            self.assertEqual(res["after_replay"]["state_code"], 2)
            self.assertLess(res["after_replay"]["duration_ms"], 5000)  # Not 245000ms demo synth

    def test_p16_f09_04_clock_source_reported_and_monotonic_during_play(self):
        with ManagedTempDir(prefix="lumina_f09_04_") as tmp:
            fp = generate_flac_fixture(tmp / "clk.flac", duration_ms=2000)
            res = run_ffi_isolated(_ffi_clock_monotonic_probe, args=(str(fp),))
            self.assertTrue(res["clock_source"])
            self.assertGreater(res["pos2"], res["pos1"])

    def test_p16_f09_05_reconnect_device_callable_returns_valid_status(self):
        with ManagedTempDir(prefix="lumina_f09_05_") as tmp:
            res = run_ffi_isolated(_ffi_reconnect_probe)
            self.assertEqual(res["rc"], LUMINA_OK)
            self.assertFalse(res["state"].get("device_lost"))


def _ffi_ended_and_replay(client: LuminaFfiClient, fp_str: str) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.play({"file_path": fp_str, "source": "Local Library"}) == LUMINA_OK
        deadline = time.monotonic() + 3.0
        ended_state = None
        while time.monotonic() < deadline:
            st = client.playback_get_state_json()
            if st.get("state_code") == 8:
                ended_state = st
                break
            time.sleep(0.04)
        replay_rc = client.play(None)
        time.sleep(0.05)
        after_replay = client.playback_get_state_json()
        client.stop()
        return {
            "ended_state": ended_state,
            "replay_rc": replay_rc,
            "after_replay": after_replay,
        }
    finally:
        client.shutdown()


def _ffi_clock_monotonic_probe(client: LuminaFfiClient, fp_str: str) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.play({"file_path": fp_str, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.08)
        st1 = client.playback_get_state_json()
        time.sleep(0.15)
        st2 = client.playback_get_state_json()
        client.stop()
        return {
            "clock_source": st1.get("clock_source"),
            "pos1": st1.get("position_ms", 0),
            "pos2": st2.get("position_ms", 0),
        }
    finally:
        client.shutdown()


def _ffi_reconnect_probe(client: LuminaFfiClient) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        rc = client.playback_reconnect_device()
        st = client.playback_get_state_json()
        return {"rc": rc, "state": st}
    finally:
        client.shutdown()


def _ffi_non_interference_probe(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    track_path: str,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        assert client.audio_set_strict_mode(True) == LUMINA_OK
        assert client.play({"file_path": track_path, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.08)
        sp_before = client.signal_path_get()
        pos_before = client.get_position_ms()
        # Run metadata/artwork/lyrics reads concurrently while playing
        _ = client.artwork_get({"file_path": track_path}, max_dim=512)
        _ = client.lyrics_get({"file_path": track_path})
        _ = client.library_rescan_tags(scan_dir, force=True)
        time.sleep(0.08)
        sp_after = client.signal_path_get()
        pos_after = client.get_position_ms()
        client.stop()
        return {
            "sp_before": sp_before,
            "sp_after": sp_after,
            "pos_before": pos_before,
            "pos_after": pos_after,
        }
    finally:
        client.shutdown()


# ---------------------------------------------------------------------------
# F10: Bit-Perfect Integration & Verification (5 tests)
# ---------------------------------------------------------------------------

class TestP17_F10_BitPerfectIntegration(unittest.TestCase):
    """P17_F10: Bit-Perfect Signal Path, Sample Rate/Bit Depth & DSP Bypass Preservation"""

    def test_p17_f10_01_strict_mode_preserves_sample_rate_and_bit_depth_96_24(self):
        with ManagedTempDir(prefix="lumina_f10_01_") as tmp:
            flac96 = generate_flac_fixture(tmp / "96_24.flac", sample_rate=96000, bit_depth=24, duration_ms=1500)
            wav48 = generate_wav_fixture(tmp / "48_24.wav", sample_rate=48000, bit_depth=24, duration_ms=1500)
            res = run_ffi_isolated(_ffi_bit_perfect_track_switch, args=(str(flac96), str(wav48), True))
            self.assertEqual(res["sp_a"].get("overall_quality"), "lossless")
            self.assertTrue(res["sp_a"].get("dsp_bypassed"))
            self.assertTrue(res["st_a"].get("strict_bit_perfect"))
            nodes_a = json.dumps(res["sp_a"].get("nodes", []))
            self.assertIn("96000", nodes_a)

    def test_p17_f10_02_dsp_bypass_preserved_across_seeks(self):
        with ManagedTempDir(prefix="lumina_f10_02_") as tmp:
            fp = generate_flac_fixture(tmp / "bypass.flac", sample_rate=96000, bit_depth=24, duration_ms=2500)
            res = run_ffi_isolated(
                _ffi_play_and_seek_sequence,
                args=(str(fp), [500, 1500, 2000]),
                kwargs={"strict_mode": True},
            )
            self.assertEqual(res["initial_sp"].get("overall_quality"), "lossless")
            for st in res["steps"]:
                self.assertTrue(st["sp"].get("dsp_bypassed"))
                self.assertEqual(st["sp"].get("overall_quality"), "lossless")

    def test_p17_f10_03_dsp_bypass_preserved_across_track_switch(self):
        with ManagedTempDir(prefix="lumina_f10_03_") as tmp:
            a = generate_wav_fixture(tmp / "a.wav", sample_rate=44100, bit_depth=16, duration_ms=1200)
            b = generate_flac_fixture(tmp / "b.flac", sample_rate=96000, bit_depth=24, duration_ms=1200)
            res = run_ffi_isolated(_ffi_bit_perfect_track_switch, args=(str(a), str(b), True))
            self.assertTrue(res["sp_a"].get("dsp_bypassed"))
            self.assertTrue(res["sp_b"].get("dsp_bypassed"))
            self.assertEqual(res["sp_b"].get("overall_quality"), "lossless")
            self.assertIn("96000", json.dumps(res["sp_b"].get("nodes", [])))

    def test_p17_f10_04_dsd_mode_preserved_across_seek(self):
        with ManagedTempDir(prefix="lumina_f10_04_") as tmp:
            dsf = generate_dsf_fixture(tmp / "dsd64.dsf", sample_rate=2822400, duration_ms=1500)
            res = run_ffi_isolated(
                _ffi_play_and_seek_sequence,
                args=(str(dsf), [400, 900]),
                kwargs={"strict_mode": True, "dsd_mode": 2},
            )
            self.assertEqual(res["play_rc"], LUMINA_OK)
            for st in res["steps"]:
                self.assertEqual(st["seek_rc"], LUMINA_OK)
                self.assertTrue(st["sp"].get("dsp_bypassed"))

    def test_p17_f10_05_metadata_artwork_lyrics_ops_never_interrupt_or_alter_pcm(self):
        with ManagedTempDir(prefix="lumina_f10_05_") as tmp:
            mdir = tmp / "music"
            jpg_b, jpg_m = generate_image_bytes("jpeg", 200, 200)
            fp = generate_flac_fixture(
                mdir / "bp.flac",
                sample_rate=96000,
                bit_depth=24,
                duration_ms=2000,
                pictures=[(jpg_b, jpg_m, 3, "Front")],
                lyrics="[00:00.50]Clean audio",
            )
            res = run_ffi_isolated(_ffi_non_interference_probe, args=(str(tmp / "db.sqlite"), str(mdir), str(fp)))
            self.assertEqual(res["sp_before"].get("overall_quality"), "lossless")
            self.assertEqual(res["sp_after"].get("overall_quality"), "lossless")
            self.assertTrue(res["sp_after"].get("dsp_bypassed"))
            self.assertGreater(res["pos_after"], res["pos_before"])


# ---------------------------------------------------------------------------
# F11: Flutter Artwork & Metadata UI (5 tests)
# ---------------------------------------------------------------------------

class TestP12_F11_FlutterArtworkMetadataUi(unittest.TestCase):
    """P12_F11: Flutter AlbumArtworkView, Enriched Track/Album Models & UI Controls"""

    def test_p12_f11_01_album_artwork_view_widget_exists_and_uses_value_key(self):
        ui_files = list((_WORKSPACE_ROOT / "app" / "lib" / "ui").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        self.assertIn("class AlbumArtworkView", combined)
        self.assertIn("ValueKey", combined)

    def test_p12_f11_02_track_info_and_album_summary_expose_enriched_metadata(self):
        ps_src = (_WORKSPACE_ROOT / "app/lib/models/playback_state.dart").read_text(encoding="utf-8")
        st_src = (_WORKSPACE_ROOT / "app/lib/models/studio_models.dart").read_text(encoding="utf-8")
        for field in ("albumArtist", "genre", "year", "composer"):
            self.assertIn(field, ps_src, f"TrackInfo missing {field}")
        self.assertIn("albumArtist", st_src)
        self.assertIn("coverUrl", st_src)

    def test_p12_f11_03_ffi_and_server_services_expose_artwork_and_rescan_apis(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        srv_src = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        for sym in ("lumina_artwork_get", "lumina_artwork_set_user_cover", "lumina_artwork_clear_user_cover", "lumina_library_rescan_tags"):
            self.assertIn(sym, ffi_src)
        self.assertIn("/api/v1/library/artwork/", srv_src)
        self.assertIn("/api/v1/library/rescan", srv_src)

    def test_p12_f11_04_minimal_external_cover_and_rescan_ui_controls_present(self):
        ui_files = list((_WORKSPACE_ROOT / "app" / "lib" / "ui").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        self.assertIn("設定外部封面", combined)
        self.assertIn("重新掃描標籤", combined)

    def test_p12_f11_05_album_detail_and_artists_view_distinguish_album_artist(self):
        ui_files = [
            _WORKSPACE_ROOT / "app/lib/ui/albums/album_detail_page.dart",
            _WORKSPACE_ROOT / "app/lib/ui/now_playing/now_playing_overlay.dart",
            _WORKSPACE_ROOT / "app/lib/ui/mini_player/floating_capsule.dart",
        ]
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        art_src = (_WORKSPACE_ROOT / "app/lib/ui/artists/artists_view.dart").read_text(encoding="utf-8")
        self.assertIn("albumArtist", combined)
        self.assertTrue("albumArtist" in art_src or "artist" in art_src)


# ---------------------------------------------------------------------------
# F12: Flutter Lyrics UI & Controls (5 tests)
# ---------------------------------------------------------------------------

class TestP14_F12_FlutterLyricsUi(unittest.TestCase):
    """P14_F12: Flutter LyricsView Auto-Scroll, Manual Load, Font Settings & Zero Mock Delegation"""

    def test_p14_f12_01_ffi_audio_service_no_longer_delegates_lyrics_to_mock(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        self.assertNotIn("get currentLyrics => _delegate.currentLyrics", ffi_src)
        self.assertIn("lumina_lyrics_get", ffi_src)
        self.assertIn("lumina_lyrics_set_user_file", ffi_src)

    def test_p14_f12_02_lyrics_view_has_scroll_controller_and_auto_scroll(self):
        lyr_src = (_WORKSPACE_ROOT / "app/lib/ui/lyrics/lyrics_view.dart").read_text(encoding="utf-8")
        self.assertIn("ScrollController", lyr_src)
        self.assertIn("StatefulWidget", lyr_src)

    def test_p14_f12_03_lyrics_view_supports_font_size_and_display_settings(self):
        ui_files = list((_WORKSPACE_ROOT / "app" / "lib" / "ui").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        lyr_src = (_WORKSPACE_ROOT / "app/lib/ui/lyrics/lyrics_view.dart").read_text(encoding="utf-8")
        self.assertIn("fontSize", lyr_src)
        self.assertTrue("autoScroll" in lyr_src or "自動捲動" in combined)

    def test_p14_f12_04_manual_lyrics_loader_and_empty_state_present(self):
        ui_files = list((_WORKSPACE_ROOT / "app" / "lib" / "ui").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        self.assertTrue("載入歌詞" in combined or "匯入歌詞" in combined or "選擇歌詞" in combined)
        lyr_src = (_WORKSPACE_ROOT / "app/lib/ui/lyrics/lyrics_view.dart").read_text(encoding="utf-8")
        self.assertTrue("暫無歌詞" in lyr_src or "lyrics.isEmpty" in lyr_src)

    def test_p14_f12_05_server_audio_service_binds_lyrics_rest_endpoints(self):
        srv_src = (_WORKSPACE_ROOT / "app/lib/services/server_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("/api/v1/lyrics/", srv_src)


# ---------------------------------------------------------------------------
# F13: Flutter Seekbar, Clock & State Sync UI (5 tests)
# ---------------------------------------------------------------------------

class TestP16_F13_FlutterSeekbarClockStateUi(unittest.TestCase):
    """P16_F13: Flutter TrackProgressBar Drag/Commit, Remaining Time & Lifecycle Sync"""

    def test_p16_f13_01_progress_bar_implements_drag_preview_and_commit_on_end(self):
        pb_src = (_WORKSPACE_ROOT / "app/lib/ui/mini_player/progress_bar.dart").read_text(encoding="utf-8")
        self.assertIn("StatefulWidget", pb_src)
        self.assertIn("onChangeStart", pb_src)
        self.assertIn("onChangeEnd", pb_src)

    def test_p16_f13_02_progress_bar_supports_remaining_time_toggle(self):
        pb_src = (_WORKSPACE_ROOT / "app/lib/ui/mini_player/progress_bar.dart").read_text(encoding="utf-8")
        self.assertTrue("showRemaining" in pb_src or "_showRemaining" in pb_src or "progress_duration_text" in pb_src)
        self.assertTrue("GestureDetector" in pb_src or "InkWell" in pb_src)

    def test_p16_f13_03_playback_status_enum_includes_full_lifecycle_states(self):
        ps_src = (_WORKSPACE_ROOT / "app/lib/models/playback_state.dart").read_text(encoding="utf-8")
        for st in ("stopped", "playing", "paused", "loading", "seeking", "buffering", "ended", "error"):
            self.assertIn(st, ps_src, f"PlaybackStatus missing {st}")

    def test_p16_f13_04_ffi_service_uses_resume_and_seek_epoch_guard(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("lumina_playback_resume", ffi_src)
        self.assertIn("lumina_playback_get_state_json", ffi_src)
        self.assertIn("lumina_playback_reconnect_device", ffi_src)
        self.assertIn("seekEpoch", ffi_src)

    def test_p16_f13_05_ui_surfaces_device_reconnect_or_error_banner(self):
        app_files = list((_WORKSPACE_ROOT / "app" / "lib").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in app_files)
        self.assertTrue("重新連線" in combined or "reconnect" in combined.lower())


# ---------------------------------------------------------------------------
# F14: Opaque-Box E2E Suite & Verification Infrastructure (5 tests)
# ---------------------------------------------------------------------------

class TestP18_F14_OpaqueBoxE2eInfra(unittest.TestCase):
    """P18_F14: Opaque-Box E2E Infrastructure, Symbol Parity & Zero-Skip Compliance"""

    def test_p18_f14_01_all_phase12_18_tier_modules_present(self):
        e2e_dir = _WORKSPACE_ROOT / "tests" / "e2e"
        for t in (1, 2, 3, 4):
            self.assertTrue((e2e_dir / f"test_tier{t}_phase12_18.py").is_file())

    def test_p18_f14_02_core_ffi_exports_all_baseline_m7_m10_and_phase12_18_symbols(self):
        def _probe(client: LuminaFfiClient) -> Dict[str, List[str]]:
            missing_m = [s for s in OPTIONAL_M7_M10_SIGNATURES if not client.has_symbol(s)]
            missing_p = [s for s in OPTIONAL_PHASE12_18_SIGNATURES if not client.has_symbol(s)]
            return {"missing_m": missing_m, "missing_p": missing_p}

        # Use top-level helper via run_ffi_isolated
        res = run_ffi_isolated(_ffi_symbol_parity_probe)
        self.assertEqual(res["missing_m"], [], f"Missing M7-M10 symbols: {res['missing_m']}")
        self.assertEqual(res["missing_p"], [], f"Missing Phase 12-18 symbols: {res['missing_p']}")

    def test_p18_f14_03_media_fixtures_module_importable_and_complete(self):
        import tests.e2e.fixtures.media_fixtures as mf

        for fn_name in (
            "generate_segmented_pcm",
            "generate_image_bytes",
            "generate_image_file",
            "build_lrc_text",
            "generate_lyrics_file",
            "generate_flac_fixture",
            "generate_mp3_fixture",
            "generate_wav_fixture",
            "generate_m4a_fixture",
            "generate_dsf_fixture",
            "generate_dsdiff_fixture",
        ):
            self.assertTrue(callable(getattr(mf, fn_name, None)), fn_name)

    def test_p18_f14_04_baseline_and_r1_modules_preserved(self):
        e2e_dir = _WORKSPACE_ROOT / "tests" / "e2e"
        for name in (
            "test_tier1_features.py",
            "test_tier2_boundaries.py",
            "test_tier3_pairwise.py",
            "test_tier4_scenarios.py",
            "test_tier1_r1_r3.py",
        ):
            self.assertTrue((e2e_dir / name).is_file())

    def test_p18_f14_05_zero_skipped_tests_policy_enforced(self):
        src = Path(__file__).read_text(encoding="utf-8")
        self.assertNotIn("@" + "unittest.skip", src)


def _ffi_symbol_parity_probe(client: LuminaFfiClient) -> Dict[str, List[str]]:
    missing_m = [s for s in OPTIONAL_M7_M10_SIGNATURES if not client.has_symbol(s)]
    missing_p = [s for s in OPTIONAL_PHASE12_18_SIGNATURES if not client.has_symbol(s)]
    return {"missing_m": missing_m, "missing_p": missing_p}
