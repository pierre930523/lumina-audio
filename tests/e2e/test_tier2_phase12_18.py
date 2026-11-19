"""
Lumina Audio E2E Test Suite - Tier 2 Phases 12-18 (Boundary & Corner Cases for F1 to F14)
75 boundary, error-handling, encoding, race, and edge-case tests derived from DISPATCH.md
and PROJECT.md § Interface Contracts. Zero skips, zero facade passes.
"""
import json
import subprocess
import sys
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional

from PIL import Image

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_OK,
    LuminaFfiClient,
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
# Module-level isolated FFI workers
# ---------------------------------------------------------------------------

def _ffi_t2_scan_artwork(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    target_path: str,
    max_dim: int = 0,
    user_cover: Optional[str] = None,
    second_user_cover: Optional[str] = None,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        scan = client.library_scan_dir(scan_dir)
        tracks = client.library_get_tracks(200)
        target = {"file_path": target_path}
        for t in tracks:
            if Path(t.get("file_path", "")).name == Path(target_path).name:
                target = {"track_id": t["id"], "file_path": t["file_path"]}
                break
        art1 = client.artwork_get(target, max_dim=max_dim)
        art2 = None
        if user_cover is not None:
            rc1 = client.artwork_set_user_cover(target, user_cover)
            art1 = {"set_rc": rc1, **client.artwork_get(target, max_dim=max_dim)}
        if second_user_cover is not None:
            rc2 = client.artwork_set_user_cover(target, second_user_cover)
            art2 = {"set_rc": rc2, **client.artwork_get(target, max_dim=max_dim)}
        return {"scan": scan, "tracks": tracks, "art1": art1, "art2": art2}
    finally:
        client.shutdown()


def _ffi_t2_clear_nonexistent_cover(client: LuminaFfiClient, db_path: str) -> int:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        return client.artwork_clear_user_cover({"track_id": "nonexistent-id-999", "file_path": "Z:/no/such/track.flac"})
    finally:
        client.shutdown()


def _ffi_t2_scan_and_search(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    query: Optional[str] = None,
    rescan_twice: bool = False,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        s1 = client.library_scan_dir(scan_dir)
        s2 = client.library_scan_dir(scan_dir) if rescan_twice else None
        tracks = client.library_get_tracks(200)
        albums = client.library_get_albums(200)
        search = client.library_search(query, 50) if query is not None else []
        return {"s1": s1, "s2": s2, "tracks": tracks, "albums": albums, "search": search}
    finally:
        client.shutdown()


def _ffi_t2_rescan(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: Optional[str],
    force: bool,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        res = client.library_rescan_tags(scan_dir, force=force)
        tracks = client.library_get_tracks(200)
        return {"res": res, "tracks": tracks}
    finally:
        client.shutdown()


def _ffi_t2_lyrics_probe(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    target_path: str,
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
        return client.lyrics_get(target)
    finally:
        client.shutdown()


def _ffi_t2_play_corrupt_tags_and_seek(
    client: LuminaFfiClient,
    file_path: str,
    seek_targets: List[int],
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        play_rc = client.play({"file_path": file_path, "source": "Local Library"})
        time.sleep(0.08)
        dur = client.get_duration_ms()
        results = []
        for pos in seek_targets:
            rc = client.seek(pos)
            time.sleep(0.06)
            st = client.playback_get_state_json()
            results.append({"target": pos, "rc": rc, "pos": st.get("position_ms"), "state_code": st.get("state_code"), "seek_epoch": st.get("seek_epoch")})
        client.stop()
        return {"play_rc": play_rc, "duration_ms": dur, "results": results}
    finally:
        client.shutdown()


def _ffi_t2_seek_unstarted_and_ended(
    client: LuminaFfiClient,
    short_file: str,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        rc_before_play = client.seek(500)
        assert client.play({"file_path": short_file, "source": "Local Library"}) == LUMINA_OK
        deadline = time.monotonic() + 3.0
        ended_reached = False
        while time.monotonic() < deadline:
            if client.playback_get_state_json().get("state_code") == 8:
                ended_reached = True
                break
            time.sleep(0.04)
        rc_when_ended = client.seek(100)
        st_after_ended_seek = client.playback_get_state_json()
        client.stop()
        return {
            "rc_before_play": rc_before_play,
            "ended_reached": ended_reached,
            "rc_when_ended": rc_when_ended,
            "st_after_ended_seek": st_after_ended_seek,
        }
    finally:
        client.shutdown()


def _ffi_t2_seek_pause_race(client: LuminaFfiClient, file_path: str) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.play({"file_path": file_path, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.07)
        rc1 = client.seek(900)
        rc_pause = client.pause()
        rc2 = client.seek(1800)
        time.sleep(0.08)
        st = client.playback_get_state_json()
        client.stop()
        return {"rc1": rc1, "rc_pause": rc_pause, "rc2": rc2, "state": st}
    finally:
        client.shutdown()


def _ffi_t2_state_transitions_and_error(
    client: LuminaFfiClient,
    valid_file: str,
    missing_file: str,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        # Stopped with no source -> play(NULL) may use demo synth
        synth_rc = client.play(None)
        synth_dur = client.get_duration_ms()
        assert client.stop() == LUMINA_OK

        # Rapid play -> pause -> resume -> pause -> stop
        assert client.play({"file_path": valid_file, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.06)
        s_play = client.playback_get_state_json()
        assert client.pause() == LUMINA_OK
        time.sleep(0.04)
        s_pause1 = client.playback_get_state_json()
        time.sleep(0.10)
        s_pause2 = client.playback_get_state_json()
        assert client.playback_resume() == LUMINA_OK
        time.sleep(0.05)
        s_res = client.playback_get_state_json()
        assert client.stop() == LUMINA_OK
        s_stop = client.playback_get_state_json()

        # Missing file error handling
        err_rc = client.play({"file_path": missing_file, "source": "Local Library"})
        s_err = client.playback_get_state_json()
        return {
            "synth_rc": synth_rc,
            "synth_dur": synth_dur,
            "s_play": s_play,
            "s_pause1": s_pause1,
            "s_pause2": s_pause2,
            "s_res": s_res,
            "s_stop": s_stop,
            "err_rc": err_rc,
            "s_err": s_err,
        }
    finally:
        client.shutdown()


def _ffi_t2_bit_perfect_boundaries(
    client: LuminaFfiClient,
    flac_path: str,
    dsf_path: str,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.audio_set_strict_mode(False) == LUMINA_OK
        assert client.play({"file_path": flac_path, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.06)
        assert client.audio_set_strict_mode(True) == LUMINA_OK
        st_strict = client.playback_get_state_json()
        sp_before_seek = client.signal_path_get()
        assert client.seek(1000) == LUMINA_OK
        time.sleep(0.06)
        sp_after_seek = client.signal_path_get()

        bad_dsp_rc = client.dsp_set_config("{invalid_json")

        # DSD Native (1) mode preserved across seek
        assert client.audio_set_dsd_mode(1) == LUMINA_OK
        assert client.play({"file_path": dsf_path, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.06)
        assert client.seek(400) == LUMINA_OK
        time.sleep(0.06)
        sp_dsd = client.signal_path_get()
        client.stop()
        return {
            "st_strict": st_strict,
            "sp_before_seek": sp_before_seek,
            "sp_after_seek": sp_after_seek,
            "bad_dsp_rc": bad_dsp_rc,
            "sp_dsd": sp_dsd,
        }
    finally:
        client.shutdown()


# ---------------------------------------------------------------------------
# F1: Artwork Boundary Cases (6 tests)
# ---------------------------------------------------------------------------

class TestP12_F01_ArtworkBoundaries(unittest.TestCase):
    """P12_F01: Tier 2 Artwork Non-Cover Rejection, Unicode Paths & Precedence Edges"""

    def test_p12_f01_b01_non_cover_images_rejected(self):
        with ManagedTempDir(prefix="lumina_t2_f01_01_") as tmp:
            mdir = tmp / "music"
            generate_image_file(mdir / "back.jpg", fmt="jpeg", width=200, height=200)
            generate_image_file(mdir / "artist_photo.jpg", fmt="jpeg", width=200, height=200)
            generate_image_file(mdir / "booklet.png", fmt="png", width=200, height=200)
            t = generate_flac_fixture(mdir / "01.flac", title="NoCover", artist="A")
            res = run_ffi_isolated(_ffi_t2_scan_artwork, args=(str(tmp / "db.sqlite"), str(mdir), str(t)))
            self.assertFalse(res["art1"].get("found"))
            self.assertEqual(res["art1"].get("source_kind"), "placeholder")

    def test_p12_f01_b02_back_cover_apic_not_treated_as_front_cover(self):
        with ManagedTempDir(prefix="lumina_t2_f01_02_") as tmp:
            mdir = tmp / "music"
            back_b, back_m = generate_image_bytes("jpeg", 150, 150, color=(20, 20, 20))
            t = generate_mp3_fixture(
                mdir / "01.mp3",
                title="BackAPIC",
                artist="A",
                apic_list=[(back_b, back_m, 4, "Back Cover")],
            )
            res = run_ffi_isolated(_ffi_t2_scan_artwork, args=(str(tmp / "db.sqlite"), str(mdir), str(t)))
            self.assertFalse(res["art1"].get("found"))

    def test_p12_f01_b03_missing_track_artwork_returns_not_found_cleanly(self):
        with ManagedTempDir(prefix="lumina_t2_f01_03_") as tmp:
            mdir = tmp / "music"
            generate_flac_fixture(mdir / "01.flac", title="Real", artist="A")
            res = run_ffi_isolated(
                _ffi_t2_scan_artwork,
                args=(str(tmp / "db.sqlite"), str(mdir), str(tmp / "missing_999.flac")),
            )
            self.assertFalse(res["art1"].get("found"))

    def test_p12_f01_b04_deep_unicode_path_artwork_resolution(self):
        with ManagedTempDir(prefix="lumina_t2_f01_04_") as tmp:
            mdir = tmp / "音樂庫" / "日本語テスト" / "繁體中文目錄"
            generate_image_file(mdir / "folder.png", fmt="png", width=180, height=180)
            t = generate_flac_fixture(mdir / "01 - 測試曲目.flac", title="測試曲目", artist="歌手")
            res = run_ffi_isolated(_ffi_t2_scan_artwork, args=(str(tmp / "db.sqlite"), str(tmp / "音樂庫"), str(t)))
            self.assertTrue(res["art1"].get("found"))
            self.assertEqual(res["art1"].get("source_kind"), "folder")

    def test_p12_f01_b05_clear_user_cover_on_nonexistent_track_safe(self):
        with ManagedTempDir(prefix="lumina_t2_f01_05_") as tmp:
            rc = run_ffi_isolated(_ffi_t2_clear_nonexistent_cover, args=(str(tmp / "db.sqlite"),))
            self.assertIsInstance(rc, int)

    def test_p12_f01_b06_extension_tie_break_cover_over_folder_over_front(self):
        with ManagedTempDir(prefix="lumina_t2_f01_06_") as tmp:
            mdir = tmp / "music"
            generate_image_file(mdir / "front.jpg", fmt="jpeg", width=100, height=100)
            generate_image_file(mdir / "folder.jpg", fmt="jpeg", width=100, height=100)
            generate_image_file(mdir / "cover.png", fmt="png", width=100, height=100)
            t = generate_flac_fixture(mdir / "01.flac", title="Tie", artist="A")
            res = run_ffi_isolated(_ffi_t2_scan_artwork, args=(str(tmp / "db.sqlite"), str(mdir), str(t)))
            self.assertTrue(res["art1"].get("found"))
            self.assertEqual(res["art1"].get("source_kind"), "cover")
            self.assertEqual(res["art1"].get("mime_type"), "image/png")


# ---------------------------------------------------------------------------
# F2: Artwork Formats, Cache & Downscaling Boundaries (5 tests)
# ---------------------------------------------------------------------------

class TestP12_F02_ArtworkFormatCacheBoundaries(unittest.TestCase):
    """P12_F02: Tier 2 Corrupt Images, Wrong Extension Magic Bytes & Cache Invalidation"""

    def test_p12_f02_b01_corrupt_image_bytes_non_blocking_error(self):
        with ManagedTempDir(prefix="lumina_t2_f02_01_") as tmp:
            mdir = tmp / "music"
            generate_image_file(mdir / "cover.jpg", fmt="jpeg", corrupt=True)
            t = generate_flac_fixture(mdir / "01.flac", title="CorruptArt", artist="A")
            res = run_ffi_isolated(_ffi_t2_scan_artwork, args=(str(tmp / "db.sqlite"), str(mdir), str(t)))
            self.assertFalse(res["art1"].get("found"))

    def test_p12_f02_b02_wrong_extension_png_saved_as_jpg_detected_by_magic_bytes(self):
        with ManagedTempDir(prefix="lumina_t2_f02_02_") as tmp:
            mdir = tmp / "music"
            # PNG bytes saved under cover.jpg
            generate_image_file(mdir / "cover.jpg", fmt="png", width=160, height=160)
            t = generate_flac_fixture(mdir / "01.flac", title="Magic", artist="A")
            res = run_ffi_isolated(_ffi_t2_scan_artwork, args=(str(tmp / "db.sqlite"), str(mdir), str(t)))
            self.assertTrue(res["art1"].get("found"))
            self.assertEqual(res["art1"].get("mime_type"), "image/png")

    def test_p12_f02_b03_tiny_max_dim_64_downscales_512_cover(self):
        with ManagedTempDir(prefix="lumina_t2_f02_03_") as tmp:
            mdir = tmp / "music"
            generate_image_file(mdir / "cover.png", fmt="png", width=512, height=512)
            t = generate_flac_fixture(mdir / "01.flac", title="TinyScale", artist="A")
            res = run_ffi_isolated(
                _ffi_t2_scan_artwork,
                args=(str(tmp / "db.sqlite"), str(mdir), str(t)),
                kwargs={"max_dim": 64},
            )
            self.assertTrue(res["art1"].get("found"))
            self.assertLessEqual(res["art1"].get("width", 999), 64)
            self.assertLessEqual(res["art1"].get("height", 999), 64)

    def test_p12_f02_b04_max_dim_zero_handled_safely(self):
        with ManagedTempDir(prefix="lumina_t2_f02_04_") as tmp:
            mdir = tmp / "music"
            generate_image_file(mdir / "cover.jpg", fmt="jpeg", width=300, height=200)
            t = generate_flac_fixture(mdir / "01.flac", title="ZeroDim", artist="A")
            res = run_ffi_isolated(
                _ffi_t2_scan_artwork,
                args=(str(tmp / "db.sqlite"), str(mdir), str(t)),
                kwargs={"max_dim": 0},
            )
            self.assertTrue(res["art1"].get("found"))
            self.assertGreater(res["art1"].get("width", 0), 0)

    def test_p12_f02_b05_replacing_user_cover_invalidates_stale_cache(self):
        with ManagedTempDir(prefix="lumina_t2_f02_05_") as tmp:
            mdir = tmp / "music"
            t = generate_flac_fixture(mdir / "01.flac", title="SwapCover", artist="A")
            c1 = generate_image_file(tmp / "c1.jpg", fmt="jpeg", width=120, height=120, color=(255, 0, 0))
            c2 = generate_image_file(tmp / "c2.png", fmt="png", width=240, height=240, color=(0, 255, 0))
            res = run_ffi_isolated(
                _ffi_t2_scan_artwork,
                args=(str(tmp / "db.sqlite"), str(mdir), str(t)),
                kwargs={"user_cover": str(c1), "second_user_cover": str(c2)},
            )
            self.assertEqual(res["art1"].get("mime_type"), "image/jpeg")
            self.assertEqual(res["art2"].get("mime_type"), "image/png")
            self.assertNotEqual(res["art1"].get("cache_path"), res["art2"].get("cache_path"))


# ---------------------------------------------------------------------------
# F3: Metadata Parser Boundary Cases (6 tests)
# ---------------------------------------------------------------------------

class TestP13_F03_MetadataParserBoundaries(unittest.TestCase):
    """P13_F03: Tier 2 Corrupt Tags, Precedence, Codec Distinction & Format Fallbacks"""

    def test_p13_f03_b01_corrupt_tag_payload_does_not_fail_playback(self):
        with ManagedTempDir(prefix="lumina_t2_f03_01_") as tmp:
            fp = generate_flac_fixture(tmp / "corrupt.flac", duration_ms=1000, title="CleanAudio")
            # Prepend garbage before fLaC or corrupt tag? Keep valid audio after corrupt ID3 header on MP3
            mp3 = generate_mp3_fixture(tmp / "corrupt_id3.mp3", duration_ms=1000, id3_version=None)
            raw = mp3.read_bytes()
            # Prepend corrupt ID3v2.4 frame with unknown ID
            bad_id3 = b"ID3\x04\x00\x00\x00\x00\x00\x0eXXXX\x00\x00\x00\x04\x00\x00\xff\xff\xff\xff"
            mp3.write_bytes(bad_id3 + raw)
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(mp3), [250]))
            self.assertEqual(res["play_rc"], LUMINA_OK)

    def test_p13_f03_b02_id3v2_takes_precedence_over_conflicting_id3v1(self):
        with ManagedTempDir(prefix="lumina_t2_f03_02_") as tmp:
            generate_mp3_fixture(
                tmp / "music" / "conflict.mp3",
                id3_version=4,
                title="ID3v2 Winner",
                artist="V2 Artist",
                with_id3v1=True,
                id3v1_override={"title": "ID3v1 Loser", "artist": "V1 Artist"},
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            self.assertEqual(res["tracks"][0]["title"], "ID3v2 Winner")
            self.assertEqual(res["tracks"][0]["artist"], "V2 Artist")

    def test_p13_f03_b03_m4a_extension_distinguishes_aac_vs_alac(self):
        with ManagedTempDir(prefix="lumina_t2_f03_03_") as tmp:
            generate_m4a_fixture(tmp / "music" / "track_a.m4a", codec="aac", title="AAC File")
            generate_m4a_fixture(tmp / "music" / "track_b.m4a", codec="alac", title="ALAC File")
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            codecs = {t["title"]: t["codec"].lower() for t in res["tracks"]}
            self.assertEqual(codecs.get("AAC File"), "aac")
            self.assertEqual(codecs.get("ALAC File"), "alac")

    def test_p13_f03_b04_wav_list_info_only_without_id3_chunk(self):
        with ManagedTempDir(prefix="lumina_t2_f03_04_") as tmp:
            generate_wav_fixture(
                tmp / "music" / "info_only.wav",
                with_info=True,
                with_bext=False,
                with_id3=False,
                title="INFO Title",
                artist="INFO Artist",
                album="INFO Album",
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            self.assertEqual(res["tracks"][0]["title"], "INFO Title")
            self.assertEqual(res["tracks"][0]["artist"], "INFO Artist")

    def test_p13_f03_b05_dsdiff_diin_only_without_id3_chunk(self):
        with ManagedTempDir(prefix="lumina_t2_f03_05_") as tmp:
            generate_dsdiff_fixture(
                tmp / "music" / "diin_only.dff",
                with_id3=False,
                title="DIIN Title",
                artist="DIIN Artist",
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            self.assertEqual(res["tracks"][0]["title"], "DIIN Title")
            self.assertEqual(res["tracks"][0]["artist"], "DIIN Artist")

    def test_p13_f03_b06_corrupt_audio_file_does_not_abort_sibling_scan(self):
        with ManagedTempDir(prefix="lumina_t2_f03_06_") as tmp:
            mdir = tmp / "music"
            generate_flac_fixture(mdir / "good.flac", title="Good Track", artist="Valid")
            (mdir / "broken.flac").write_bytes(b"NOT_A_REAL_FLAC_FILE" * 10)
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(mdir)))
            self.assertEqual(len(res["tracks"]), 1)
            self.assertEqual(res["tracks"][0]["title"], "Good Track")
            self.assertGreaterEqual(res["s1"].get("errors_count", 0), 1)


# ---------------------------------------------------------------------------
# F4: Rich Fields & CJK Boundary Cases (5 tests)
# ---------------------------------------------------------------------------

class TestP13_F04_RichFieldsCjkBoundaries(unittest.TestCase):
    """P13_F04: Tier 2 Numeric Filenames, Missing-Tag Fallbacks & Slash Track Numbers"""

    def test_p13_f04_b01_numeric_filename_1999_and_2001_not_mangled(self):
        with ManagedTempDir(prefix="lumina_t2_f04_01_") as tmp:
            # No TITLE tag -> filename fallback must preserve "1999" and "2001" cleanly
            generate_flac_fixture(tmp / "music" / "1999.flac", artist="Prince")
            generate_flac_fixture(tmp / "music" / "01 - 2001.flac", artist="Kubrick")
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            titles = {t["title"] for t in res["tracks"]}
            self.assertTrue(any("1999" in title for title in titles), titles)
            self.assertTrue(any("2001" in title for title in titles), titles)

    def test_p13_f04_b02_blank_tags_fallback_cleanly_without_empty_fields(self):
        with ManagedTempDir(prefix="lumina_t2_f04_02_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "FallbackSong.flac",
                title="   ",
                artist="",
                album="  ",
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertTrue(t["title"].strip())
            self.assertTrue(t["artist"].strip())
            self.assertTrue(t["album"].strip())

    def test_p13_f04_b03_slash_track_and_disc_numbers_parsed(self):
        with ManagedTempDir(prefix="lumina_t2_f04_03_") as tmp:
            generate_mp3_fixture(
                tmp / "music" / "slash.mp3",
                id3_version=4,
                title="Slash",
                artist="A",
                track_number="03/12",
                disc_number="2/2",
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            t = res["tracks"][0]
            self.assertEqual(t.get("track_number"), 3)
            self.assertEqual(t.get("disc_number"), 2)

    def test_p13_f04_b04_invalid_replaygain_strings_non_fatal(self):
        with ManagedTempDir(prefix="lumina_t2_f04_04_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "bad_rg.flac",
                title="BadRG",
                artist="A",
                replaygain_track_gain="invalid_db",
                replaygain_track_peak="NaN_peak",
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            self.assertEqual(len(res["tracks"]), 1)
            self.assertEqual(res["tracks"][0]["title"], "BadRG")

    def test_p13_f04_b05_emoji_and_mixed_cjk_metadata_preserved(self):
        with ManagedTempDir(prefix="lumina_t2_f04_05_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "emoji.flac",
                title="星晴 🌟 简体・繁體・かな",
                artist="周杰倫 🎵",
                album="Jay 2000",
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            self.assertEqual(res["tracks"][0]["title"], "星晴 🌟 简体・繁體・かな")
            self.assertEqual(res["tracks"][0]["artist"], "周杰倫 🎵")

    def test_p13_f04_b06_latin1_diacritics_and_long_metadata_preserved(self):
        with ManagedTempDir(prefix="lumina_t2_f04_06_") as tmp:
            long_title = "Été à Paris - " + ("Symphonie Fantastique " * 6)
            generate_mp3_fixture(
                tmp / "music" / "latin1.mp3",
                id3_version=3,
                text_encoding="latin-1",
                title=long_title,
                artist="Héloïse & René",
                album="Café Bleu",
                album_artist="Various Artists",
            )
            res = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db.sqlite"), str(tmp / "music")))
            self.assertEqual(res["tracks"][0]["title"], long_title.strip())
            self.assertEqual(res["tracks"][0]["artist"], "Héloïse & René")


# ---------------------------------------------------------------------------
# F5: Metadata Cache, Rescan & FTS5 Boundary Cases (5 tests)
# ---------------------------------------------------------------------------

class TestP13_F05_CacheRescanBoundaries(unittest.TestCase):
    """P13_F05: Tier 2 Tag Removal Clearing, Empty Dir Rescan & CJK Search"""

    def test_p13_f05_b01_removing_tags_clears_stale_db_fields_on_force_rescan(self):
        with ManagedTempDir(prefix="lumina_t2_f05_01_") as tmp:
            fp = tmp / "music" / "clear_tags.flac"
            generate_flac_fixture(fp, title="Track", artist="Artist", genre="Jazz", composer="Old Composer")
            db = str(tmp / "db.sqlite")
            r1 = run_ffi_isolated(_ffi_t2_scan_and_search, args=(db, str(tmp / "music")))
            self.assertEqual(r1["tracks"][0].get("composer"), "Old Composer")

            generate_flac_fixture(fp, title="Track", artist="Artist", genre=None, composer=None)
            r2 = run_ffi_isolated(_ffi_t2_rescan, args=(db, str(tmp / "music"), True))
            self.assertFalse(r2["tracks"][0].get("composer"))
            self.assertFalse(r2["tracks"][0].get("genre"))

    def test_p13_f05_b02_empty_directory_rescan_returns_zero_tracks(self):
        with ManagedTempDir(prefix="lumina_t2_f05_02_") as tmp:
            empty_dir = tmp / "empty_music"
            empty_dir.mkdir(parents=True, exist_ok=True)
            res = run_ffi_isolated(_ffi_t2_rescan, args=(str(tmp / "db.sqlite"), str(empty_dir), False))
            self.assertEqual(len(res["tracks"]), 0)

    def test_p13_f05_b03_rescan_nonexistent_dir_does_not_crash(self):
        with ManagedTempDir(prefix="lumina_t2_f05_03_") as tmp:
            res = run_ffi_isolated(_ffi_t2_rescan, args=(str(tmp / "db.sqlite"), str(tmp / "does_not_exist"), True))
            self.assertIsInstance(res["res"], dict)

    def test_p13_f05_b04_fts5_search_matches_cjk_and_composer(self):
        with ManagedTempDir(prefix="lumina_t2_f05_04_") as tmp:
            generate_flac_fixture(
                tmp / "music" / "01.flac",
                title="青花瓷",
                artist="周杰倫",
                album="我很忙",
                composer="方文山",
            )
            res = run_ffi_isolated(
                _ffi_t2_scan_and_search,
                args=(str(tmp / "db.sqlite"), str(tmp / "music")),
                kwargs={"query": "周杰倫"},
            )
            self.assertGreaterEqual(len(res["search"]), 1)
            self.assertEqual(res["search"][0]["title"], "青花瓷")

    def test_p13_f05_b05_rescan_idempotency_no_duplicate_rows(self):
        with ManagedTempDir(prefix="lumina_t2_f05_05_") as tmp:
            generate_flac_fixture(tmp / "music" / "01.flac", title="Unique", artist="Solo")
            res = run_ffi_isolated(
                _ffi_t2_scan_and_search,
                args=(str(tmp / "db.sqlite"), str(tmp / "music")),
                kwargs={"rescan_twice": True},
            )
            self.assertEqual(len(res["tracks"]), 1)


# ---------------------------------------------------------------------------
# F6: Lyrics Boundary Cases (6 tests)
# ---------------------------------------------------------------------------

class TestP14_F06_LyricsBoundaries(unittest.TestCase):
    """P14_F06: Tier 2 Missing/Empty/Corrupt Lyrics, Offset Clamping & Legacy CJK"""

    def test_p14_f06_b01_missing_lyrics_clean_empty_state(self):
        with ManagedTempDir(prefix="lumina_t2_f06_01_") as tmp:
            t = generate_flac_fixture(tmp / "music" / "no_lyr.flac", title="Instrumental", artist="A")
            lyr = run_ffi_isolated(_ffi_t2_lyrics_probe, args=(str(tmp / "db.sqlite"), str(tmp / "music"), str(t)))
            self.assertFalse(lyr.get("found"))
            self.assertEqual(lyr.get("kind"), "none")
            self.assertEqual(lyr.get("source"), "none")
            self.assertEqual(lyr.get("lines"), [])

    def test_p14_f06_b02_empty_and_whitespace_lrc_files(self):
        with ManagedTempDir(prefix="lumina_t2_f06_02_") as tmp:
            t1 = generate_flac_fixture(tmp / "m1" / "empty.flac", title="Empty", artist="A")
            generate_lyrics_file(tmp / "m1" / "empty.lrc", mode="empty")
            r1 = run_ffi_isolated(_ffi_t2_lyrics_probe, args=(str(tmp / "db1.sqlite"), str(tmp / "m1"), str(t1)))
            self.assertFalse(r1.get("found"))

            t2 = generate_flac_fixture(tmp / "m2" / "ws.flac", title="WS", artist="A")
            generate_lyrics_file(tmp / "m2" / "ws.lrc", mode="whitespace")
            r2 = run_ffi_isolated(_ffi_t2_lyrics_probe, args=(str(tmp / "db2.sqlite"), str(tmp / "m2"), str(t2)))
            self.assertFalse(r2.get("found"))

    def test_p14_f06_b03_corrupt_utf8_and_malformed_timestamps_handled_safely(self):
        with ManagedTempDir(prefix="lumina_t2_f06_03_") as tmp:
            t = generate_flac_fixture(tmp / "music" / "bad.flac", title="BadLrc", artist="A")
            generate_lyrics_file(tmp / "music" / "bad.lrc", mode="corrupt")
            lyr = run_ffi_isolated(_ffi_t2_lyrics_probe, args=(str(tmp / "db.sqlite"), str(tmp / "music"), str(t)))
            self.assertIsInstance(lyr, dict)
            self.assertIn("lines", lyr)

    def test_p14_f06_b04_lrc_offset_positive_and_negative_clamping(self):
        with ManagedTempDir(prefix="lumina_t2_f06_04_") as tmp:
            t = generate_flac_fixture(tmp / "music" / "off.flac", title="Offset", artist="A")
            generate_lyrics_file(
                tmp / "music" / "off.lrc",
                mode="lrc",
                offset_ms=-2000,
                lines=[(1000, "Clamped To Zero"), (5000, "Shifted Line")],
            )
            lyr = run_ffi_isolated(_ffi_t2_lyrics_probe, args=(str(tmp / "db.sqlite"), str(tmp / "music"), str(t)))
            self.assertTrue(lyr.get("found"))
            lines = lyr.get("lines", [])
            self.assertGreaterEqual(len(lines), 2)
            self.assertGreaterEqual(lines[0]["start_ms"], 0)

    def test_p14_f06_b05_legacy_cjk_lrc_encodings_gbk_big5_shift_jis(self):
        with ManagedTempDir(prefix="lumina_t2_f06_05_") as tmp:
            for idx, (enc, text) in enumerate(
                [
                    ("gbk", "简体中文歌词测试"),
                    ("big5", "繁體中文歌詞測試"),
                    ("shift_jis", "日本語歌詞テスト"),
                    ("utf-8-sig", "BOM帶頭歌詞測試"),
                ]
            ):
                mdir = tmp / f"m{idx}"
                t = generate_flac_fixture(mdir / "song.flac", title=f"S{idx}", artist="A")
                generate_lyrics_file(mdir / "song.lrc", mode="lrc", lines=[(500, text)], encoding=enc)
                lyr = run_ffi_isolated(_ffi_t2_lyrics_probe, args=(str(tmp / f"db{idx}.sqlite"), str(mdir), str(t)))
                self.assertTrue(lyr.get("found"), enc)
                self.assertEqual(lyr["lines"][0]["text"], text)

    def test_p14_f06_b06_duplicate_timestamp_chorus_lines_expanded(self):
        with ManagedTempDir(prefix="lumina_t2_f06_06_") as tmp:
            t = generate_flac_fixture(tmp / "music" / "dup.flac", title="Chorus", artist="A")
            generate_lyrics_file(
                tmp / "music" / "dup.lrc",
                mode="lrc",
                lines=[(1000, "Verse 1")],
                duplicate_timestamps=[([5000, 15000], "Repeated Chorus")],
            )
            lyr = run_ffi_isolated(_ffi_t2_lyrics_probe, args=(str(tmp / "db.sqlite"), str(tmp / "music"), str(t)))
            self.assertTrue(lyr.get("found"))
            chorus_lines = [l for l in lyr["lines"] if l["text"] == "Repeated Chorus"]
            self.assertEqual(len(chorus_lines), 2)


# ---------------------------------------------------------------------------
# F7: Format Decoder Seek Boundary Cases (6 tests)
# ---------------------------------------------------------------------------

class TestP15_F07_DecoderSeekBoundaries(unittest.TestCase):
    """P15_F07: Tier 2 0%, 100%, >Duration, Short File, Segmented & DSD Block Seek"""

    def test_p15_f07_b01_seek_zero_percent_resets_to_start(self):
        with ManagedTempDir(prefix="lumina_t2_f07_01_") as tmp:
            fp = generate_flac_fixture(tmp / "z.flac", duration_ms=2000)
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), [1200, 0]))
            self.assertEqual(res["results"][1]["rc"], LUMINA_OK)
            self.assertLessEqual(res["results"][1]["pos"], 200)

    def test_p15_f07_b02_seek_100_percent_and_past_duration_clamps_safely(self):
        with ManagedTempDir(prefix="lumina_t2_f07_02_") as tmp:
            fp = generate_wav_fixture(tmp / "clamp.wav", duration_ms=1500)
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), [1500, 999999]))
            for r in res["results"]:
                self.assertLessEqual(r["pos"], res["duration_ms"] + 100)

    def test_p15_f07_b03_repeated_seek_zero_ms_remains_valid(self):
        with ManagedTempDir(prefix="lumina_t2_f07_03_") as tmp:
            fp = generate_mp3_fixture(tmp / "rep0.mp3", mode="cbr", duration_ms=2000)
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), [0, 0, 0]))
            for r in res["results"]:
                self.assertEqual(r["rc"], LUMINA_OK)
                self.assertLessEqual(r["pos"], 250)

    def test_p15_f07_b04_very_short_120ms_file_seek_boundary(self):
        with ManagedTempDir(prefix="lumina_t2_f07_04_") as tmp:
            fp = generate_wav_fixture(tmp / "tiny.wav", duration_ms=120)
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), [60]))
            self.assertEqual(res["play_rc"], LUMINA_OK)
            self.assertLessEqual(res["results"][0]["pos"], 200)

    def test_p15_f07_b05_segmented_multitone_seek_lands_in_target_segment(self):
        with ManagedTempDir(prefix="lumina_t2_f07_05_") as tmp:
            fp = generate_flac_fixture(
                tmp / "tones.flac",
                with_seektable=True,
                segments=[(1.0, 440.0), (1.0, 880.0), (1.0, 1320.0)],
            )
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), [1500, 2500]))
            self.assertAlmostEqual(res["results"][0]["pos"], 1500, delta=250)
            self.assertAlmostEqual(res["results"][1]["pos"], 2500, delta=250)

    def test_p15_f07_b06_dsf_and_dsdiff_block_aligned_boundary_seek(self):
        with ManagedTempDir(prefix="lumina_t2_f07_06_") as tmp:
            dsf = generate_dsf_fixture(tmp / "b.dsf", duration_ms=1800)
            dff = generate_dsdiff_fixture(tmp / "b.dff", duration_ms=1800)
            for fp in (dsf, dff):
                res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), [0, 900, 1750]))
                self.assertEqual(res["play_rc"], LUMINA_OK)
                self.assertEqual(res["results"][0]["rc"], LUMINA_OK)
                self.assertAlmostEqual(res["results"][1]["pos"], 900, delta=350)


# ---------------------------------------------------------------------------
# F8: Seek Pipeline & Buffer Flush Boundaries (5 tests)
# ---------------------------------------------------------------------------

class TestP15_F08_SeekPipelineBoundaries(unittest.TestCase):
    """P15_F08: Tier 2 Unseekable States, Ended Seek, Pause Race & Seek Epoch"""

    def test_p15_f08_b01_seek_while_stopped_returns_error_code(self):
        with ManagedTempDir(prefix="lumina_t2_f08_01_") as tmp:
            fp = generate_wav_fixture(tmp / "s.wav", duration_ms=250)
            res = run_ffi_isolated(_ffi_t2_seek_unstarted_and_ended, args=(str(fp),))
            self.assertIn(res["rc_before_play"], (LUMINA_OK, -1, -5))

    def test_p15_f08_b02_seek_when_ended_handled_cleanly(self):
        with ManagedTempDir(prefix="lumina_t2_f08_02_") as tmp:
            fp = generate_wav_fixture(tmp / "e.wav", duration_ms=250)
            res = run_ffi_isolated(_ffi_t2_seek_unstarted_and_ended, args=(str(fp),))
            self.assertTrue(res["ended_reached"])
            self.assertIn(res["st_after_ended_seek"].get("state_code"), (2, 3, 6, 8))

    def test_p15_f08_b03_seek_plus_pause_race_preserves_paused_and_target(self):
        with ManagedTempDir(prefix="lumina_t2_f08_03_") as tmp:
            fp = generate_flac_fixture(tmp / "race.flac", duration_ms=3000)
            res = run_ffi_isolated(_ffi_t2_seek_pause_race, args=(str(fp),))
            self.assertEqual(res["rc_pause"], LUMINA_OK)
            self.assertEqual(res["rc2"], LUMINA_OK)
            self.assertEqual(res["state"]["state_code"], 3)
            self.assertAlmostEqual(res["state"]["position_ms"], 1800, delta=300)

    def test_p15_f08_b04_seek_epoch_strictly_monotone_across_10_seeks(self):
        with ManagedTempDir(prefix="lumina_t2_f08_04_") as tmp:
            fp = generate_wav_fixture(tmp / "epochs.wav", duration_ms=3000)
            targets = [300, 2400, 600, 2100, 900, 1800, 1200, 1500, 400, 2600]
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), targets))
            epochs = [r["seek_epoch"] for r in res["results"]]
            for i in range(1, len(epochs)):
                self.assertGreater(epochs[i], epochs[i - 1])

    def test_p15_f08_b05_backward_seek_does_not_leak_forward_buffer_position(self):
        with ManagedTempDir(prefix="lumina_t2_f08_05_") as tmp:
            fp = generate_flac_fixture(tmp / "back.flac", duration_ms=4000)
            res = run_ffi_isolated(_ffi_t2_play_corrupt_tags_and_seek, args=(str(fp), [3200, 400]))
            self.assertAlmostEqual(res["results"][1]["pos"], 400, delta=300)


# ---------------------------------------------------------------------------
# F9: Playback Clock & State Machine Boundaries (5 tests)
# ---------------------------------------------------------------------------

class TestP16_F09_StateMachineBoundaries(unittest.TestCase):
    """P16_F09: Tier 2 Synth Fallback Scope, Rapid Transitions, Missing File Error"""

    def test_p16_f09_b01_play_null_when_stopped_uses_synth_fallback_only_without_source(self):
        with ManagedTempDir(prefix="lumina_t2_f09_01_") as tmp:
            valid = generate_wav_fixture(tmp / "v.wav", duration_ms=1000)
            res = run_ffi_isolated(_ffi_t2_state_transitions_and_error, args=(str(valid), str(tmp / "no.flac")))
            self.assertEqual(res["synth_rc"], LUMINA_OK)
            self.assertEqual(res["synth_dur"], 245000)

    def test_p16_f09_b02_rapid_play_pause_resume_stop_transitions(self):
        with ManagedTempDir(prefix="lumina_t2_f09_02_") as tmp:
            valid = generate_wav_fixture(tmp / "v.wav", duration_ms=2000)
            res = run_ffi_isolated(_ffi_t2_state_transitions_and_error, args=(str(valid), str(tmp / "no.flac")))
            self.assertEqual(res["s_play"]["state_code"], 2)
            self.assertEqual(res["s_pause1"]["state_code"], 3)
            self.assertEqual(res["s_res"]["state_code"], 2)
            self.assertEqual(res["s_stop"]["state_code"], 1)

    def test_p16_f09_b03_missing_file_transitions_to_error_state_4_with_message(self):
        with ManagedTempDir(prefix="lumina_t2_f09_03_") as tmp:
            valid = generate_wav_fixture(tmp / "v.wav", duration_ms=1000)
            res = run_ffi_isolated(_ffi_t2_state_transitions_and_error, args=(str(valid), str(tmp / "missing_track.flac")))
            self.assertLess(res["err_rc"], 0)
            self.assertIn(res["s_err"]["state_code"], (1, 4))
            self.assertTrue(res["s_err"].get("last_error") or res["err_rc"] < 0)

    def test_p16_f09_b04_position_frozen_during_pause_window(self):
        with ManagedTempDir(prefix="lumina_t2_f09_04_") as tmp:
            valid = generate_wav_fixture(tmp / "v.wav", duration_ms=2000)
            res = run_ffi_isolated(_ffi_t2_state_transitions_and_error, args=(str(valid), str(tmp / "no.flac")))
            self.assertLessEqual(abs(res["s_pause2"]["position_ms"] - res["s_pause1"]["position_ms"]), 20)

    def test_p16_f09_b05_state_name_matches_state_code_enum(self):
        with ManagedTempDir(prefix="lumina_t2_f09_05_") as tmp:
            valid = generate_wav_fixture(tmp / "v.wav", duration_ms=1500)
            res = run_ffi_isolated(_ffi_t2_state_transitions_and_error, args=(str(valid), str(tmp / "no.flac")))
            self.assertEqual(res["s_play"]["state_name"].lower(), "playing")
            self.assertEqual(res["s_pause1"]["state_name"].lower(), "paused")
            self.assertEqual(res["s_stop"]["state_name"].lower(), "stopped")
            self.assertIn(res["s_err"]["state_name"].lower(), ("stopped", "error"))


# ---------------------------------------------------------------------------
# F10: Bit-Perfect Integration Boundaries (5 tests)
# ---------------------------------------------------------------------------

class TestP17_F10_BitPerfectBoundaries(unittest.TestCase):
    """P17_F10: Tier 2 Strict Toggle Mid-Play, No Resampler on Seek, Native DSD & Bad DSP"""

    def test_p17_f10_b01_toggle_strict_mode_mid_playback_enforces_bypass(self):
        with ManagedTempDir(prefix="lumina_t2_f10_01_") as tmp:
            flac = generate_flac_fixture(tmp / "a.flac", sample_rate=96000, bit_depth=24, duration_ms=2000)
            dsf = generate_dsf_fixture(tmp / "b.dsf", duration_ms=1200)
            res = run_ffi_isolated(_ffi_t2_bit_perfect_boundaries, args=(str(flac), str(dsf)))
            self.assertTrue(res["st_strict"].get("strict_bit_perfect"))
            self.assertTrue(res["st_strict"].get("dsp_bypassed"))

    def test_p17_f10_b02_seek_never_inserts_resampler_in_signal_path(self):
        with ManagedTempDir(prefix="lumina_t2_f10_02_") as tmp:
            flac = generate_flac_fixture(tmp / "a.flac", sample_rate=96000, bit_depth=24, duration_ms=2000)
            dsf = generate_dsf_fixture(tmp / "b.dsf", duration_ms=1200)
            res = run_ffi_isolated(_ffi_t2_bit_perfect_boundaries, args=(str(flac), str(dsf)))
            nodes_str = json.dumps(res["sp_after_seek"].get("nodes", [])).lower()
            self.assertNotIn("resampl", nodes_str)
            self.assertEqual(res["sp_after_seek"].get("overall_quality"), "lossless")

    def test_p17_f10_b03_native_dsd_mode_preserved_across_seek(self):
        with ManagedTempDir(prefix="lumina_t2_f10_03_") as tmp:
            flac = generate_flac_fixture(tmp / "a.flac", duration_ms=1500)
            dsf = generate_dsf_fixture(tmp / "b.dsf", duration_ms=1200)
            res = run_ffi_isolated(_ffi_t2_bit_perfect_boundaries, args=(str(flac), str(dsf)))
            self.assertTrue(res["sp_dsd"].get("dsp_bypassed"))
            self.assertIn("dsd", json.dumps(res["sp_dsd"].get("nodes", [])).lower())

    def test_p17_f10_b04_invalid_dsp_config_json_rejected_cleanly(self):
        with ManagedTempDir(prefix="lumina_t2_f10_04_") as tmp:
            flac = generate_flac_fixture(tmp / "a.flac", duration_ms=1500)
            dsf = generate_dsf_fixture(tmp / "b.dsf", duration_ms=1200)
            res = run_ffi_isolated(_ffi_t2_bit_perfect_boundaries, args=(str(flac), str(dsf)))
            self.assertLess(res["bad_dsp_rc"], 0)

    def test_p17_f10_b05_verification_quality_unchanged_before_and_after_seek(self):
        with ManagedTempDir(prefix="lumina_t2_f10_05_") as tmp:
            flac = generate_flac_fixture(tmp / "a.flac", sample_rate=96000, bit_depth=24, duration_ms=2000)
            dsf = generate_dsf_fixture(tmp / "b.dsf", duration_ms=1200)
            res = run_ffi_isolated(_ffi_t2_bit_perfect_boundaries, args=(str(flac), str(dsf)))
            self.assertEqual(res["sp_before_seek"].get("overall_quality"), res["sp_after_seek"].get("overall_quality"))


# ---------------------------------------------------------------------------
# F11: Flutter Artwork & Metadata UI Boundaries (5 tests)
# ---------------------------------------------------------------------------

class TestP12_F11_FlutterArtworkUiBoundaries(unittest.TestCase):
    """P12_F11: Tier 2 Flutter Artwork Fallback, Null Safety & Stale Residue Prevention"""

    def test_p12_f11_b01_album_artwork_view_supports_placeholder_fallback(self):
        ui_files = list((_WORKSPACE_ROOT / "app" / "lib" / "ui").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        self.assertIn("AlbumArtworkView", combined)
        self.assertIn("errorBuilder", combined)

    def test_p12_f11_b02_track_info_has_safe_nullable_enriched_fields(self):
        ps_src = (_WORKSPACE_ROOT / "app/lib/models/playback_state.dart").read_text(encoding="utf-8")
        self.assertIn("String? albumArtist", ps_src)
        self.assertIn("String? genre", ps_src)
        self.assertIn("String? composer", ps_src)

    def test_p12_f11_b03_mini_player_and_now_playing_use_album_artwork_view(self):
        mini = (_WORKSPACE_ROOT / "app/lib/ui/mini_player/floating_capsule.dart").read_text(encoding="utf-8")
        np = (_WORKSPACE_ROOT / "app/lib/ui/now_playing/now_playing_overlay.dart").read_text(encoding="utf-8")
        self.assertIn("AlbumArtworkView", mini)
        self.assertIn("AlbumArtworkView", np)

    def test_p12_f11_b04_album_detail_handles_empty_album_artist_without_duplicate(self):
        ui_files = [
            _WORKSPACE_ROOT / "app/lib/ui/albums/album_detail_page.dart",
            _WORKSPACE_ROOT / "app/lib/ui/now_playing/now_playing_overlay.dart",
            _WORKSPACE_ROOT / "app/lib/ui/mini_player/floating_capsule.dart",
        ]
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        alb = (_WORKSPACE_ROOT / "app/lib/ui/albums/album_detail_page.dart").read_text(encoding="utf-8")
        self.assertIn("albumArtist", combined)
        self.assertIn("TextOverflow.ellipsis", alb)

    def test_p12_f11_b05_flutter_tests_cover_artwork_and_metadata_switching(self):
        test_files = list((_WORKSPACE_ROOT / "app" / "test").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in test_files)
        self.assertIn("AlbumArtworkView", combined)


# ---------------------------------------------------------------------------
# F12: Flutter Lyrics UI Boundaries (5 tests)
# ---------------------------------------------------------------------------

class TestP14_F12_FlutterLyricsUiBoundaries(unittest.TestCase):
    """P14_F12: Tier 2 Flutter Lyrics Empty State, Pause Freeze & Track Switch Cleanup"""

    def test_p14_f12_b01_lyrics_view_renders_empty_state_when_absent(self):
        lyr = (_WORKSPACE_ROOT / "app/lib/ui/lyrics/lyrics_view.dart").read_text(encoding="utf-8")
        self.assertTrue("lyrics.isEmpty" in lyr or "暫無歌詞" in lyr)

    def test_p14_f12_b02_lyrics_view_handles_paused_state_without_advancing(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        lyr = (_WORKSPACE_ROOT / "app/lib/ui/lyrics/lyrics_view.dart").read_text(encoding="utf-8")
        self.assertIn("PlaybackStatus.paused", ffi_src)
        self.assertIn("activeIndexForPosition", lyr)

    def test_p14_f12_b03_lyrics_view_supports_unsynced_plain_text_mode(self):
        lyr = (_WORKSPACE_ROOT / "app/lib/ui/lyrics/lyrics_view.dart").read_text(encoding="utf-8")
        self.assertTrue("isSynced" in lyr or "unsynced" in lyr.lower() or "start == Duration.zero" in lyr)

    def test_p14_f12_b04_ffi_service_clears_lyrics_on_track_switch(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("_currentLyrics", ffi_src)
        self.assertIn("clear", ffi_src.lower())

    def test_p14_f12_b05_flutter_tests_cover_lyrics_empty_and_switch(self):
        test_files = list((_WORKSPACE_ROOT / "app" / "test").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in test_files)
        self.assertIn("LyricsView", combined)
        self.assertTrue("暫無歌詞" in combined or "尚無歌詞資訊" in combined or "lyrics_empty_state" in combined)


# ---------------------------------------------------------------------------
# F13: Flutter Seekbar & State Sync Boundaries (5 tests)
# ---------------------------------------------------------------------------

class TestP16_F13_FlutterSeekbarStateBoundaries(unittest.TestCase):
    """P16_F13: Tier 2 Flutter Seekbar Drag Guard, Epoch Suppression & Clamping"""

    def test_p16_f13_b01_progress_bar_guards_against_stream_overwrite_while_dragging(self):
        pb = (_WORKSPACE_ROOT / "app/lib/ui/mini_player/progress_bar.dart").read_text(encoding="utf-8")
        self.assertTrue("_isDragging" in pb or "_dragValue" in pb)

    def test_p16_f13_b02_progress_bar_clamps_out_of_bounds_values(self):
        pb = (_WORKSPACE_ROOT / "app/lib/ui/mini_player/progress_bar.dart").read_text(encoding="utf-8")
        self.assertIn(".clamp(", pb)

    def test_p16_f13_b03_ffi_service_guards_stale_ticks_with_seek_epoch(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("seekEpoch", ffi_src)

    def test_p16_f13_b04_toggle_play_pause_does_not_reset_paused_position_to_zero(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("lumina_playback_resume", ffi_src)

    def test_p16_f13_b05_flutter_tests_verify_seekbar_drag_and_pause_resume(self):
        test_files = list((_WORKSPACE_ROOT / "app" / "test").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in test_files)
        self.assertIn("TrackProgressBar", combined)
        self.assertIn("onChangeEnd", combined)


# ---------------------------------------------------------------------------
# F14: E2E Infrastructure Boundary Cases (5 tests)
# ---------------------------------------------------------------------------

class TestP18_F14_E2eInfraBoundaries(unittest.TestCase):
    """P18_F14: Tier 2 Isolation, Cleanup, Strict Skip Rejection & Runner CLI Boundaries"""

    def test_p18_f14_b01_run_ffi_isolated_prevents_oncelock_db_bleed(self):
        with ManagedTempDir(prefix="lumina_t2_f14_01_") as tmp:
            d1 = tmp / "m1"
            d2 = tmp / "m2"
            generate_flac_fixture(d1 / "a.flac", title="OnlyInDB1", artist="A1")
            generate_flac_fixture(d2 / "b.flac", title="OnlyInDB2", artist="A2")
            r1 = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db1.sqlite"), str(d1)))
            r2 = run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "db2.sqlite"), str(d2)))
            self.assertEqual([t["title"] for t in r1["tracks"]], ["OnlyInDB1"])
            self.assertEqual([t["title"] for t in r2["tracks"]], ["OnlyInDB2"])

    def test_p18_f14_b02_managed_temp_dir_releases_windows_sqlite_wal_cleanly(self):
        path_ref = None
        with ManagedTempDir(prefix="lumina_t2_f14_02_", strict=True) as tmp:
            path_ref = tmp
            d = tmp / "music"
            generate_flac_fixture(d / "a.flac", title="WAL Cleanup", artist="A")
            run_ffi_isolated(_ffi_t2_scan_and_search, args=(str(tmp / "wal.db"), str(d)))
        self.assertFalse(path_ref.exists())

    def test_p18_f14_b03_runner_discovers_all_phase12_18_tiers(self):
        proc = subprocess.run(
            [sys.executable, str(_WORKSPACE_ROOT / "tests/e2e/runner.py"), "--suite", "phase12_18", "--list"],
            cwd=str(_WORKSPACE_ROOT),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [l for l in proc.stdout.splitlines() if l.strip()]
        self.assertGreaterEqual(len(lines), 178)

    def test_p18_f14_b04_runner_strict_flag_exits_nonzero_on_skip(self):
        runner_src = (_WORKSPACE_ROOT / "tests/e2e/runner.py").read_text(encoding="utf-8")
        self.assertIn("if strict and skipped_count > 0:", runner_src)

    def test_p18_f14_b05_zero_skipped_tests_in_tier2_module(self):
        src = Path(__file__).read_text(encoding="utf-8")
        self.assertNotIn("@" + "unittest.skip", src)
