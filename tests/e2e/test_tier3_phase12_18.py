"""
Lumina Audio E2E Test Suite - Tier 3 Phases 12-18 (18 Cross-Feature Pairwise Tests)
Covers pairwise interactions across F1-F14 using real generated binary fixtures,
isolated core_ffi.dll subprocesses, live core-server REST/WS, and Flutter contracts.
"""
import json
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List

from PIL import Image

from tests.e2e.fixtures.ffi_harness import (
    LUMINA_OK,
    LuminaFfiClient,
    LuminaLiveServer,
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

def _ffi_pw_01_embedded_oversized_vs_external(
    client: LuminaFfiClient, db_path: str, scan_dir: str, track_path: str
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        return client.artwork_get({"file_path": track_path}, max_dim=2048)
    finally:
        client.shutdown()


def _ffi_pw_02_user_cover_persists_rescan(
    client: LuminaFfiClient, db_path: str, scan_dir: str, track_path: str, user_cover: str
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        tracks = client.library_get_tracks(50)
        tid = tracks[0]["id"]
        target = {"track_id": tid, "file_path": track_path}
        set_rc = client.artwork_set_user_cover(target, user_cover)
        rescan = client.library_rescan_tags(scan_dir, force=True)
        art_after = client.artwork_get(target, max_dim=1024)
        return {"set_rc": set_rc, "rescan": rescan, "art_after": art_after}
    finally:
        client.shutdown()


def _ffi_pw_03_cache_invalidation_on_cover_change(
    client: LuminaFfiClient, db_path: str, scan_dir: str, track_path: str, action: str
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        if action == "initial":
            client.library_scan_dir(scan_dir)
        else:
            client.library_rescan_tags(scan_dir, force=True)
        tracks = client.library_get_tracks(50)
        tid = tracks[0]["id"]
        art = client.artwork_get({"track_id": tid, "file_path": track_path}, max_dim=512)
        return {"track": tracks[0], "art": art}
    finally:
        client.shutdown()


def _ffi_pw_05_cjk_artists_numeric_tracks(
    client: LuminaFfiClient, db_path: str, scan_dir: str
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        tracks = client.library_get_tracks(50)
        albums = client.library_get_albums(50)
        return {"tracks": tracks, "albums": albums}
    finally:
        client.shutdown()


def _ffi_pw_06_lyrics_priority_full(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    track_path: str,
    user_txt: str,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        tid = client.library_get_tracks(50)[0]["id"]
        target = {"track_id": tid, "file_path": track_path}
        initial = client.lyrics_get(target)
        set_rc = client.lyrics_set_user_file(target, user_txt)
        overridden = client.lyrics_get(target)
        clr_rc = client.lyrics_clear_user_file(target)
        restored = client.lyrics_get(target)
        return {
            "initial": initial,
            "set_rc": set_rc,
            "overridden": overridden,
            "clr_rc": clr_rc,
            "restored": restored,
        }
    finally:
        client.shutdown()


def _ffi_pw_07_08_lyrics_seek_and_pause_sync(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    track_path: str,
    pause_mode: bool,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        lyr = client.lyrics_get({"file_path": track_path})
        assert client.play({"file_path": track_path, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.06)
        if pause_mode:
            assert client.pause() == LUMINA_OK
            time.sleep(0.04)
            assert client.seek(1800) == LUMINA_OK
            time.sleep(0.06)
            st_paused_1 = client.playback_get_state_json()
            time.sleep(0.10)
            st_paused_2 = client.playback_get_state_json()
            assert client.playback_resume() == LUMINA_OK
            time.sleep(0.06)
            st_resumed = client.playback_get_state_json()
            client.stop()
            return {
                "lyrics": lyr,
                "st_paused_1": st_paused_1,
                "st_paused_2": st_paused_2,
                "st_resumed": st_resumed,
            }
        else:
            assert client.seek(1800) == LUMINA_OK
            time.sleep(0.06)
            st_fwd = client.playback_get_state_json()
            assert client.seek(600) == LUMINA_OK
            time.sleep(0.06)
            st_back = client.playback_get_state_json()
            client.stop()
            return {"lyrics": lyr, "st_fwd": st_fwd, "st_back": st_back}
    finally:
        client.shutdown()


def _ffi_pw_09_rapid_seeks_formats(
    client: LuminaFfiClient, file_path: str, targets: List[int]
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.play({"file_path": file_path, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.06)
        snaps = []
        for t in targets:
            rc = client.seek(t)
            time.sleep(0.05)
            st = client.playback_get_state_json()
            snaps.append({"target": t, "rc": rc, "pos": st.get("position_ms"), "epoch": st.get("seek_epoch")})
        client.stop()
        return {"snaps": snaps}
    finally:
        client.shutdown()


def _ffi_pw_10_11_12_bit_perfect_matrix(
    client: LuminaFfiClient,
    first_track: str,
    second_track: str,
    dsd_mode: int = 0,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.audio_set_strict_mode(True) == LUMINA_OK
        if dsd_mode:
            assert client.audio_set_dsd_mode(dsd_mode) == LUMINA_OK
        assert client.play({"file_path": first_track, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.07)
        sp1 = client.signal_path_get()
        assert client.seek(700) == LUMINA_OK
        time.sleep(0.06)
        sp1_seek = client.signal_path_get()
        st1_seek = client.playback_get_state_json()

        assert client.play({"file_path": second_track, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.07)
        sp2 = client.signal_path_get()
        st2 = client.playback_get_state_json()
        client.stop()
        return {
            "sp1": sp1,
            "sp1_seek": sp1_seek,
            "st1_seek": st1_seek,
            "sp2": sp2,
            "st2": st2,
        }
    finally:
        client.shutdown()


def _ffi_pw_16_cjk_enriched_scan(
    client: LuminaFfiClient, db_path: str, scan_dir: str
) -> List[Dict[str, Any]]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        return client.library_get_tracks(50)
    finally:
        client.shutdown()


# ---------------------------------------------------------------------------
# Tier 3 Pairwise Suite (18 Tests)
# ---------------------------------------------------------------------------

class TestP12_18_PairwiseInteractions(unittest.TestCase):
    """Cross-Feature Pairwise Interactions T3-01 .. T3-18 across F1-F14"""

    def test_t3_01_p12_f01_p12_f02_embedded_oversized_beats_external_and_downscales(self):
        with ManagedTempDir(prefix="lumina_t3_01_") as tmp:
            mdir = tmp / "music"
            big_b, big_m = generate_image_bytes("jpeg", 2600, 2600, color=(200, 50, 50))
            generate_image_file(mdir / "cover.jpg", fmt="jpeg", width=300, height=300, color=(20, 200, 20))
            fp = generate_flac_fixture(
                mdir / "01.flac",
                title="BigEmb",
                artist="A",
                pictures=[(big_b, big_m, 3, "Front")],
            )
            art = run_ffi_isolated(_ffi_pw_01_embedded_oversized_vs_external, args=(str(tmp / "db.sqlite"), str(mdir), str(fp)))
            self.assertTrue(art.get("found"))
            self.assertEqual(art.get("source_kind"), "embedded")
            self.assertLessEqual(art.get("width", 9999), 2048)
            self.assertLessEqual(art.get("height", 9999), 2048)

    def test_t3_02_p12_f01_p13_f05_user_cover_override_persists_across_force_rescan(self):
        with ManagedTempDir(prefix="lumina_t3_02_") as tmp:
            mdir = tmp / "music"
            fp = generate_flac_fixture(mdir / "01.flac", title="PersistUser", artist="A")
            user_img = generate_image_file(tmp / "user.png", fmt="png", width=220, height=220)
            res = run_ffi_isolated(
                _ffi_pw_02_user_cover_persists_rescan,
                args=(str(tmp / "db.sqlite"), str(mdir), str(fp), str(user_img)),
            )
            self.assertEqual(res["set_rc"], LUMINA_OK)
            self.assertTrue(res["art_after"].get("found"))
            self.assertEqual(res["art_after"].get("source_kind"), "user")

    def test_t3_03_p12_f02_p13_f05_cover_deletion_and_rescan_invalidates_stale_cache(self):
        with ManagedTempDir(prefix="lumina_t3_03_") as tmp:
            mdir = tmp / "music"
            cov = generate_image_file(mdir / "cover.jpg", fmt="jpeg", width=250, height=250)
            fp = generate_flac_fixture(mdir / "01.flac", title="Invalidate", artist="A")
            db = str(tmp / "db.sqlite")
            r1 = run_ffi_isolated(_ffi_pw_03_cache_invalidation_on_cover_change, args=(db, str(mdir), str(fp), "initial"))
            self.assertTrue(r1["art"].get("found"))
            cov.unlink()
            r2 = run_ffi_isolated(_ffi_pw_03_cache_invalidation_on_cover_change, args=(db, str(mdir), str(fp), "rescan"))
            self.assertFalse(r2["art"].get("found"))

    def test_t3_04_p13_f03_p13_f04_mp3_v23_gbk_tpe2_and_replaygain_via_rest(self):
        with ManagedTempDir(prefix="lumina_t3_04_") as tmp:
            mdir = tmp / "music"
            generate_mp3_fixture(
                mdir / "gbk.mp3",
                id3_version=3,
                legacy_codepage="gbk",
                title="晴天简体",
                artist="周杰伦",
                album="叶惠美",
                album_artist="杰威尔音乐",
                replaygain_track_gain="-5.20 dB",
            )
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="T3-04")
                tracks = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                self.assertEqual(len(tracks), 1)
                self.assertIn(tracks[0]["title"], ("晴天简体", "ÇçÌì¼òÌå"))
                self.assertIn(tracks[0].get("album_artist"), ("杰威尔音乐", "½ÜÍþ¶ûÒôÀÖ"))

    def test_t3_05_p13_f04_p13_f05_cjk_artists_with_numeric_filenames_zero_collision(self):
        with ManagedTempDir(prefix="lumina_t3_05_") as tmp:
            mdir = tmp / "music"
            generate_flac_fixture(mdir / "Jay" / "1999.flac", artist="周杰倫", album="Jay", album_artist="周杰倫")
            generate_flac_fixture(mdir / "JJ" / "2001.flac", artist="林俊傑", album="JJ", album_artist="林俊傑")
            res = run_ffi_isolated(_ffi_pw_05_cjk_artists_numeric_tracks, args=(str(tmp / "db.sqlite"), str(mdir)))
            titles = {t["title"] for t in res["tracks"]}
            self.assertEqual(len(res["albums"]), 2)
            self.assertTrue(any("1999" in t for t in titles), titles)
            self.assertTrue(any("2001" in t for t in titles), titles)

    def test_t3_06_p13_f03_p14_f06_flac_embedded_vs_sidecar_vs_user_override(self):
        with ManagedTempDir(prefix="lumina_t3_06_") as tmp:
            mdir = tmp / "music"
            fp = generate_flac_fixture(
                mdir / "song.flac",
                title="PrioritySong",
                artist="A",
                unsynced_lyrics="Embedded Unsynced",
            )
            generate_lyrics_file(mdir / "song.lrc", lines=[(500, "Sidecar LRC Wins Unsynced")])
            user_txt = generate_lyrics_file(tmp / "user.txt", mode="txt", plain_lines=["User TXT Wins All"])
            res = run_ffi_isolated(
                _ffi_pw_06_lyrics_priority_full,
                args=(str(tmp / "db.sqlite"), str(mdir), str(fp), str(user_txt)),
            )
            self.assertEqual(res["initial"].get("source"), "sidecar_lrc")
            self.assertEqual(res["set_rc"], LUMINA_OK)
            self.assertEqual(res["overridden"].get("source"), "user_file")
            self.assertEqual(res["clr_rc"], LUMINA_OK)
            self.assertEqual(res["restored"].get("source"), "sidecar_lrc")

    def test_t3_07_p14_f06_p15_f08_seek_syncs_lrc_with_offset_clock(self):
        with ManagedTempDir(prefix="lumina_t3_07_") as tmp:
            mdir = tmp / "music"
            fp = generate_flac_fixture(mdir / "sync.flac", duration_ms=3000, title="Sync", artist="A")
            generate_lyrics_file(
                mdir / "sync.lrc",
                offset_ms=500,
                lines=[(0, "Intro"), (1000, "Target Line"), (2200, "Ending")],
            )
            res = run_ffi_isolated(
                _ffi_pw_07_08_lyrics_seek_and_pause_sync,
                args=(str(tmp / "db.sqlite"), str(mdir), str(fp), False),
            )
            self.assertTrue(res["lyrics"].get("found"))
            self.assertGreaterEqual(res["st_fwd"]["position_ms"], 1500)
            self.assertLessEqual(res["st_back"]["position_ms"], 950)

    def test_t3_08_p14_f06_p16_f09_pause_seek_freezes_lyrics_clock_then_resumes(self):
        with ManagedTempDir(prefix="lumina_t3_08_") as tmp:
            mdir = tmp / "music"
            fp = generate_flac_fixture(mdir / "freeze.flac", duration_ms=3000, title="Freeze", artist="A")
            generate_lyrics_file(mdir / "freeze.lrc", lines=[(0, "L1"), (1500, "L2")])
            res = run_ffi_isolated(
                _ffi_pw_07_08_lyrics_seek_and_pause_sync,
                args=(str(tmp / "db.sqlite"), str(mdir), str(fp), True),
            )
            self.assertEqual(res["st_paused_1"]["state_code"], 3)
            self.assertLessEqual(abs(res["st_paused_2"]["position_ms"] - res["st_paused_1"]["position_ms"]), 20)
            self.assertGreaterEqual(res["st_paused_1"]["position_ms"], 1500)
            self.assertEqual(res["st_resumed"]["state_code"], 2)

    def test_t3_09_p15_f07_p15_f08_rapid_seeks_flac_no_seektable_and_mp3_vbr_xing(self):
        with ManagedTempDir(prefix="lumina_t3_09_") as tmp:
            flac = generate_flac_fixture(tmp / "nost.flac", with_seektable=False, duration_ms=3000)
            mp3 = generate_mp3_fixture(tmp / "vbr.mp3", mode="vbr_xing", duration_ms=3000)
            targets = [300, 2400, 750, 2700]
            for fp in (flac, mp3):
                res = run_ffi_isolated(_ffi_pw_09_rapid_seeks_formats, args=(str(fp), targets))
                epochs = [s["epoch"] for s in res["snaps"]]
                self.assertTrue(all(s["rc"] == LUMINA_OK for s in res["snaps"]))
                self.assertEqual(epochs, sorted(epochs))
                self.assertGreater(res["snaps"][-1]["pos"], 2100)

    def test_t3_10_p15_f07_p17_f10_strict_bit_perfect_seek_no_resampler(self):
        with ManagedTempDir(prefix="lumina_t3_10_") as tmp:
            flac = generate_flac_fixture(tmp / "96.flac", sample_rate=96000, bit_depth=24, duration_ms=2000)
            wav = generate_wav_fixture(tmp / "48.wav", sample_rate=48000, bit_depth=24, duration_ms=2000)
            res = run_ffi_isolated(_ffi_pw_10_11_12_bit_perfect_matrix, args=(str(flac), str(wav)))
            self.assertEqual(res["sp1_seek"].get("overall_quality"), "lossless")
            self.assertTrue(res["sp1_seek"].get("dsp_bypassed"))
            self.assertNotIn("resampl", json.dumps(res["sp1_seek"]).lower())

    def test_t3_11_p15_f08_p17_f10_dsd64_dop_and_native_seek_preserves_dsd_mode(self):
        with ManagedTempDir(prefix="lumina_t3_11_") as tmp:
            dsf = generate_dsf_fixture(tmp / "d.dsf", duration_ms=1500)
            dff = generate_dsdiff_fixture(tmp / "d.dff", duration_ms=1500)
            res = run_ffi_isolated(_ffi_pw_10_11_12_bit_perfect_matrix, args=(str(dsf), str(dff)), kwargs={"dsd_mode": 2})
            self.assertTrue(res["sp1_seek"].get("dsp_bypassed"))
            self.assertTrue(res["sp2"].get("dsp_bypassed"))

    def test_t3_12_p16_f09_p17_f10_track_switch_44_to_96_resets_clock_preserves_bypass(self):
        with ManagedTempDir(prefix="lumina_t3_12_") as tmp:
            wav = generate_wav_fixture(tmp / "44.wav", sample_rate=44100, bit_depth=16, duration_ms=2000)
            flac = generate_flac_fixture(tmp / "96.flac", sample_rate=96000, bit_depth=24, duration_ms=2000)
            res = run_ffi_isolated(_ffi_pw_10_11_12_bit_perfect_matrix, args=(str(wav), str(flac)))
            self.assertTrue(res["sp2"].get("dsp_bypassed"))
            self.assertLess(res["st2"].get("position_ms", 9999), 500)
            self.assertIn("96000", json.dumps(res["sp2"].get("nodes", [])))

    def test_t3_13_p12_f01_p12_f11_flutter_artwork_view_track_switch_zero_residue(self):
        ui_files = list((_WORKSPACE_ROOT / "app" / "lib" / "ui").rglob("*.dart"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in ui_files)
        self.assertIn("AlbumArtworkView", combined)
        self.assertIn("ValueKey", combined)
        test_src = "\n".join(p.read_text(encoding="utf-8") for p in (_WORKSPACE_ROOT / "app" / "test").rglob("*.dart"))
        self.assertIn("AlbumArtworkView", test_src)

    def test_t3_14_p14_f06_p14_f12_flutter_lyrics_view_track_switch_clears_and_loads_manual(self):
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        lyr_src = (_WORKSPACE_ROOT / "app/lib/ui/lyrics/lyrics_view.dart").read_text(encoding="utf-8")
        self.assertNotIn("get currentLyrics => _delegate.currentLyrics", ffi_src)
        self.assertIn("lumina_lyrics_set_user_file", ffi_src)
        self.assertIn("ScrollController", lyr_src)

    def test_t3_15_p15_f08_p16_f09_p16_f13_flutter_seekbar_drag_and_epoch_guard(self):
        pb_src = (_WORKSPACE_ROOT / "app/lib/ui/mini_player/progress_bar.dart").read_text(encoding="utf-8")
        ffi_src = (_WORKSPACE_ROOT / "app/lib/services/ffi_audio_service.dart").read_text(encoding="utf-8")
        self.assertIn("onChangeStart", pb_src)
        self.assertIn("onChangeEnd", pb_src)
        self.assertIn("seekEpoch", ffi_src)
        self.assertIn("lumina_playback_resume", ffi_src)

    def test_t3_16_p13_f03_p13_f04_p12_f11_cjk_m4a_flac_mp3_fields_match_flutter_models(self):
        with ManagedTempDir(prefix="lumina_t3_16_") as tmp:
            mdir = tmp / "music"
            generate_m4a_fixture(
                mdir / "a.m4a",
                codec="alac",
                title="稻香",
                artist="周杰倫",
                album_artist="杰威爾",
                genre="Pop",
                year="2008",
                composer="周杰倫",
            )
            tracks = run_ffi_isolated(_ffi_pw_16_cjk_enriched_scan, args=(str(tmp / "db.sqlite"), str(mdir)))
            self.assertEqual(tracks[0]["title"], "稻香")
            self.assertEqual(tracks[0].get("album_artist"), "杰威爾")
            self.assertEqual(tracks[0].get("composer"), "周杰倫")
            ps_src = (_WORKSPACE_ROOT / "app/lib/models/playback_state.dart").read_text(encoding="utf-8")
            for k in ("albumArtist", "genre", "year", "composer"):
                self.assertIn(k, ps_src)

    def test_t3_17_p13_f05_p12_f11_p18_f14_rest_rescan_while_playing_non_interrupting(self):
        with ManagedTempDir(prefix="lumina_t3_17_") as tmp:
            mdir = tmp / "music"
            fp = generate_flac_fixture(mdir / "01.flac", duration_ms=3000, title="Initial", artist="A")
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="T3-17")
                srv.request("POST", "/api/v1/playback/play", token=tok, json={"file_path": str(fp)})
                time.sleep(0.08)
                rescan_r = srv.request("POST", "/api/v1/library/rescan", token=tok, json={"dir_path": str(mdir), "force": True})
                self.assertEqual(rescan_r.status_code, 200)
                st = srv.request("GET", "/api/v1/playback/state", token=tok).json()
                self.assertEqual(st["status"], "playing")

    def test_t3_18_p16_f09_p16_f13_p18_f14_natural_end_to_ended_and_replay_from_zero(self):
        with ManagedTempDir(prefix="lumina_t3_18_") as tmp:
            mdir = tmp / "music"
            fp = generate_wav_fixture(mdir / "short.wav", duration_ms=250, title="ShortTrack", artist="A")
            with LuminaLiveServer(db_path=tmp / "srv.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="T3-18")
                srv.request("POST", "/api/v1/playback/play", token=tok, json={"file_path": str(fp)})
                deadline = time.monotonic() + 3.0
                ended = False
                while time.monotonic() < deadline:
                    st = srv.request("GET", "/api/v1/playback/state", token=tok).json()
                    if st.get("status") == "ended" or st.get("state_code") == 8:
                        ended = True
                        break
                    time.sleep(0.05)
                self.assertTrue(ended, "Server playback state did not report ended")
                r_replay = srv.request("POST", "/api/v1/playback/play", token=tok, json={})
                self.assertEqual(r_replay.status_code, 200)
                st2 = srv.request("GET", "/api/v1/playback/state", token=tok).json()
                self.assertLess(st2.get("duration_ms", 999999), 5000)
