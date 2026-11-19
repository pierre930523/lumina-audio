"""
Lumina Audio E2E Test Suite - Tier 4 Phases 12-18 (10 Real-World Application Scenarios)
Full multi-component workflows spanning programmatic real binary media fixtures,
isolated core_ffi.dll subprocesses, live core-server REST/WS, Flutter `flutter test -j 1`,
Rust `cargo check/test`, `flutter analyze`, and Windows Debug & Release `.exe` smoke launches.
"""
import json
import os
import random
import shutil
import subprocess
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
from tests.e2e.fixtures.toolchain_fixtures import (
    find_cargo_executable,
    find_flutter_executable,
)


# ---------------------------------------------------------------------------
# Module-level isolated FFI workers
# ---------------------------------------------------------------------------

def _ffi_t4_01_scan_and_rescan(
    client: LuminaFfiClient, db_path: str, scan_dir: str, edited_flac: str
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        scan1 = client.library_scan_dir(scan_dir)
        tracks1 = client.library_get_tracks(200)
        albums1 = client.library_get_albums(200)
        search_cjk = client.library_search("周杰倫", 20)
        return {
            "scan1": scan1,
            "tracks1": tracks1,
            "albums1": albums1,
            "search_cjk": search_cjk,
        }
    finally:
        client.shutdown()


def _ffi_t4_02_artwork_lifecycle(
    client: LuminaFfiClient, db_path: str, scan_dir: str, track_path: str, user_png: str
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        tid = client.library_get_tracks(50)[0]["id"]
        target = {"track_id": tid, "file_path": track_path}
        art_initial = client.artwork_get(target, max_dim=2048)
        set_rc = client.artwork_set_user_cover(target, user_png)
        art_user = client.artwork_get(target, max_dim=2048)
        clr_rc = client.artwork_clear_user_cover(target)
        art_restored = client.artwork_get(target, max_dim=2048)
        return {
            "tid": tid,
            "art_initial": art_initial,
            "set_rc": set_rc,
            "art_user": art_user,
            "clr_rc": clr_rc,
            "art_restored": art_restored,
        }
    finally:
        client.shutdown()


def _ffi_t4_04_full_seek_matrix(
    client: LuminaFfiClient, file_paths: List[str]
) -> List[Dict[str, Any]]:
    assert client.init_headless() == LUMINA_OK
    rng = random.Random(42)
    report: List[Dict[str, Any]] = []
    try:
        for fp in file_paths:
            play_rc = client.play({"file_path": fp, "source": "Local Library"})
            time.sleep(0.08)
            dur = client.get_duration_ms()
            pcts = [0, 10, 25, 50, 75, 90, 100]
            rand_targets = [int(dur * rng.uniform(0.15, 0.85)) for _ in range(2)]
            targets = [int(dur * p / 100.0) for p in pcts] + rand_targets

            playing_steps = []
            for pos in targets:
                rc = client.seek(pos)
                time.sleep(0.05)
                st = client.playback_get_state_json()
                playing_steps.append(
                    {
                        "target": pos,
                        "rc": rc,
                        "pos": st.get("position_ms"),
                        "state": st.get("state_code"),
                        "epoch": st.get("seek_epoch"),
                    }
                )

            assert client.pause() == LUMINA_OK
            time.sleep(0.04)
            paused_target = int(dur * 0.45)
            p_rc = client.seek(paused_target)
            time.sleep(0.05)
            st_paused = client.playback_get_state_json()
            assert client.playback_resume() == LUMINA_OK
            time.sleep(0.05)
            st_resumed = client.playback_get_state_json()
            client.stop()

            report.append(
                {
                    "file": Path(fp).name,
                    "play_rc": play_rc,
                    "dur": dur,
                    "playing_steps": playing_steps,
                    "paused_target": paused_target,
                    "p_rc": p_rc,
                    "st_paused": st_paused,
                    "st_resumed": st_resumed,
                }
            )
        return report
    finally:
        client.shutdown()


def _ffi_t4_05_bit_perfect_scenario(
    client: LuminaFfiClient,
    db_path: str,
    scan_dir: str,
    flac96: str,
    wav48: str,
    dsf64: str,
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        assert client.library_init(db_path) == LUMINA_OK
        client.library_scan_dir(scan_dir)
        assert client.audio_set_strict_mode(True) == LUMINA_OK

        assert client.play({"file_path": flac96, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.07)
        sp_flac_0 = client.signal_path_get()
        for t in (300, 900, 600):
            assert client.seek(t) == LUMINA_OK
            time.sleep(0.05)
        sp_flac_seek = client.signal_path_get()

        # Non-interference metadata/artwork/lyrics reads mid-stream
        _ = client.artwork_get({"file_path": flac96}, max_dim=512)
        _ = client.lyrics_get({"file_path": flac96})
        sp_flac_after_meta = client.signal_path_get()

        assert client.play({"file_path": wav48, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.07)
        sp_wav = client.signal_path_get()

        assert client.audio_set_dsd_mode(2) == LUMINA_OK
        assert client.play({"file_path": dsf64, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.07)
        sp_dsf = client.signal_path_get()
        client.stop()
        return {
            "sp_flac_0": sp_flac_0,
            "sp_flac_seek": sp_flac_seek,
            "sp_flac_after_meta": sp_flac_after_meta,
            "sp_wav": sp_wav,
            "sp_dsf": sp_dsf,
        }
    finally:
        client.shutdown()


def _ffi_t4_06_state_machine_lifecycle(
    client: LuminaFfiClient, short_wav: str, missing_file: str
) -> Dict[str, Any]:
    assert client.init_headless() == LUMINA_OK
    try:
        s_stopped = client.playback_get_state_json()
        assert client.play({"file_path": short_wav, "source": "Local Library"}) == LUMINA_OK
        time.sleep(0.05)
        s_playing = client.playback_get_state_json()
        assert client.seek(80) == LUMINA_OK
        assert client.pause() == LUMINA_OK
        time.sleep(0.04)
        s_paused = client.playback_get_state_json()
        assert client.playback_resume() == LUMINA_OK

        deadline = time.monotonic() + 3.0
        s_ended = None
        while time.monotonic() < deadline:
            st = client.playback_get_state_json()
            if st.get("state_code") == 8:
                s_ended = st
                break
            time.sleep(0.04)

        replay_rc = client.play(None)
        time.sleep(0.04)
        s_replayed = client.playback_get_state_json()
        err_rc = client.play({"file_path": missing_file, "source": "Local Library"})
        s_error = client.playback_get_state_json()
        rec_rc = client.playback_reconnect_device()
        client.stop()
        return {
            "s_stopped": s_stopped,
            "s_playing": s_playing,
            "s_paused": s_paused,
            "s_ended": s_ended,
            "replay_rc": replay_rc,
            "s_replayed": s_replayed,
            "err_rc": err_rc,
            "s_error": s_error,
            "rec_rc": rec_rc,
        }
    finally:
        client.shutdown()


# ---------------------------------------------------------------------------
# Tier 4 Scenarios (10 Scenarios)
# ---------------------------------------------------------------------------

class TestP18_F14_Tier4Scenarios(unittest.TestCase):
    """P18_F14: Real-World Multi-Component Application Scenarios T4-01 .. T4-10"""

    def test_t4_01_p13_f03_p13_f04_p13_f05_multiformat_ingest_cjk_and_rescan(self):
        with ManagedTempDir(prefix="lumina_t4_01_") as tmp:
            mdir = tmp / "music"
            jpg_b, jpg_m = generate_image_bytes("jpeg", 200, 200)
            cjk_dir = mdir / "周杰倫" / "范特西"
            flac_fp = generate_flac_fixture(
                cjk_dir / "01 - 愛在西元前.flac",
                with_seektable=True,
                title="愛在西元前",
                artist="周杰倫",
                album="范特西",
                album_artist="周杰倫",
                genre="華語流行",
                composer="周杰倫",
                pictures=[(jpg_b, jpg_m, 3, "Front")],
            )
            generate_mp3_fixture(
                mdir / "cbr_gbk.mp3",
                mode="cbr",
                id3_version=3,
                legacy_codepage="gbk",
                title="七里香",
                artist="周杰伦",
                album="七里香",
                album_artist="杰威尔",
            )
            generate_mp3_fixture(
                mdir / "vbr_xing.mp3",
                mode="vbr_xing",
                id3_version=4,
                title="稻香",
                artist="周杰倫",
                album="魔杰座",
            )
            generate_wav_fixture(mdir / "bwf.wav", with_bext=True, with_id3=True, title="WaveMaster", artist="林俊傑", album="江南")
            generate_m4a_fixture(mdir / "alac.m4a", codec="alac", title="ALAC Song", artist="A1", album="Alb1")
            generate_m4a_fixture(mdir / "aac.m4a", codec="aac", title="AAC Song", artist="A2", album="Alb2")
            generate_dsf_fixture(mdir / "sacd.dsf", title="DSF Song", artist="DSD1", album="SACD")
            generate_dsdiff_fixture(mdir / "master.dff", title="DFF Song", artist="DSD2", album="DFF")

            db = tmp / "t4_01.db"
            res = run_ffi_isolated(_ffi_t4_01_scan_and_rescan, args=(str(db), str(mdir), str(flac_fp)))
            self.assertEqual(len(res["tracks1"]), 8, f"Expected 8 tracks across all formats, got {len(res['tracks1'])}")
            self.assertGreaterEqual(len(res["search_cjk"]), 1)

            with LuminaLiveServer(db_path=db) as srv:
                tok = srv.pair(device_name="T4-01")
                rest_tracks = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                self.assertEqual(len(rest_tracks), 8)
                time.sleep(0.05)
                generate_flac_fixture(flac_fp, title="愛在西元前 (Remaster)", artist="周杰倫", album="范特西", genre="Classic Pop")
                r_rescan = srv.request("POST", "/api/v1/library/rescan", token=tok, json={"dir_path": str(mdir), "force": True})
                self.assertEqual(r_rescan.status_code, 200)
                updated = srv.request("GET", "/api/v1/library/tracks", token=tok).json()
                self.assertTrue(any(t["title"] == "愛在西元前 (Remaster)" for t in updated))

    def test_t4_02_p12_f01_p12_f02_artwork_priority_downscale_and_user_override(self):
        with ManagedTempDir(prefix="lumina_t4_02_") as tmp:
            mdir = tmp / "music" / "Alb"
            back_b, back_m = generate_image_bytes("jpeg", 160, 160, color=(10, 10, 10))
            generate_image_file(mdir / "front.jpg", fmt="jpeg", width=200, height=200, color=(0, 0, 200))
            generate_image_file(mdir / "folder.jpg", fmt="jpeg", width=200, height=200, color=(0, 200, 0))
            generate_image_file(mdir / "cover.jpg", fmt="jpeg", width=2400, height=2400, color=(200, 0, 0))
            fp = generate_mp3_fixture(
                mdir / "01.mp3",
                title="ArtLife",
                artist="A",
                apic_list=[(back_b, back_m, 4, "Back")],
            )
            user_png = generate_image_file(tmp / "user_override.png", fmt="png", width=320, height=320, color=(255, 200, 0))
            res = run_ffi_isolated(
                _ffi_t4_02_artwork_lifecycle,
                args=(str(tmp / "t4_02.db"), str(tmp / "music"), str(fp), str(user_png)),
            )
            self.assertTrue(res["art_initial"].get("found"))
            self.assertEqual(res["art_initial"].get("source_kind"), "cover")
            self.assertLessEqual(res["art_initial"].get("width", 9999), 2048)
            self.assertEqual(res["set_rc"], LUMINA_OK)
            self.assertEqual(res["art_user"].get("source_kind"), "user")
            self.assertEqual(res["clr_rc"], LUMINA_OK)
            self.assertEqual(res["art_restored"].get("source_kind"), "cover")

    def test_t4_03_p14_f06_p15_f08_p16_f09_lyrics_priority_seek_pause_via_server_ws(self):
        with ManagedTempDir(prefix="lumina_t4_03_") as tmp:
            mdir = tmp / "music"
            fp = generate_flac_fixture(
                mdir / "01.flac",
                duration_ms=3000,
                title="LyricsWS",
                artist="A",
                unsynced_lyrics="Embedded Unsynced",
            )
            generate_lyrics_file(mdir / "01.lrc", lines=[(0, "Intro"), (1200, "Middle"), (2400, "Outro")])
            enh_lrc = generate_lyrics_file(tmp / "manual_enh.lrc", mode="enhanced_lrc", lines=[(0, "Manual Word Sync")])

            with LuminaLiveServer(db_path=tmp / "t4_03.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="T4-03")
                tid = srv.request("GET", "/api/v1/library/tracks", token=tok).json()[0]["id"]
                lyr1 = srv.request("GET", f"/api/v1/lyrics/{tid}", token=tok)
                self.assertEqual(lyr1.status_code, 200)
                self.assertEqual(lyr1.json().get("source"), "sidecar_lrc")

                with srv.ws_connect(token=tok) as ws:
                    srv.request("POST", "/api/v1/playback/play", token=tok, json={"file_path": str(fp)})
                    time.sleep(0.08)
                    srv.request("POST", "/api/v1/playback/seek", token=tok, json={"position_ms": 1500})
                    time.sleep(0.06)
                    srv.request("POST", "/api/v1/playback/pause", token=tok)
                    st = srv.request("GET", "/api/v1/playback/state", token=tok).json()
                    self.assertEqual(st["status"], "paused")
                    self.assertGreaterEqual(st["position_ms"], 1200)
                    _ = json.loads(ws.recv(timeout=2.0))

                ov = srv.request("POST", f"/api/v1/lyrics/{tid}/override", token=tok, json={"file_path": str(enh_lrc)})
                self.assertIn(ov.status_code, (200, 201))
                lyr2 = srv.request("GET", f"/api/v1/lyrics/{tid}", token=tok).json()
                self.assertEqual(lyr2.get("source"), "user_file")
                self.assertEqual(lyr2.get("format"), "enhanced_lrc")

    def test_t4_04_p15_f07_p15_f08_p16_f09_full_seek_matrix_across_5_real_formats(self):
        with ManagedTempDir(prefix="lumina_t4_04_") as tmp:
            files = [
                str(generate_flac_fixture(tmp / "st.flac", with_seektable=True, duration_ms=2500)),
                str(generate_flac_fixture(tmp / "nost.flac", with_seektable=False, duration_ms=2500)),
                str(generate_wav_fixture(tmp / "pcm.wav", duration_ms=2500)),
                str(generate_mp3_fixture(tmp / "cbr.mp3", mode="cbr", duration_ms=2500)),
                str(generate_mp3_fixture(tmp / "vbr.mp3", mode="vbr_xing", duration_ms=2500)),
                str(generate_dsf_fixture(tmp / "dsd.dsf", duration_ms=1600)),
            ]
            reports = run_ffi_isolated(_ffi_t4_04_full_seek_matrix, args=(files,))
            for rep in reports:
                self.assertEqual(rep["play_rc"], LUMINA_OK, rep)
                self.assertEqual(rep["p_rc"], LUMINA_OK, rep)
                self.assertEqual(rep["st_paused"]["state_code"], 3, rep)
                self.assertEqual(rep["st_resumed"]["state_code"], 2, rep)
                epochs = [s["epoch"] for s in rep["playing_steps"]]
                self.assertEqual(epochs, sorted(epochs))
                for s in rep["playing_steps"]:
                    self.assertEqual(s["rc"], LUMINA_OK, rep)
                    if s["target"] > 0 and s["target"] < rep["dur"]:
                        self.assertGreater(s["pos"], 0, rep)

    def test_t4_05_p15_f07_p15_f08_p17_f10_bit_perfect_preservation_across_seeks_and_switches(self):
        with ManagedTempDir(prefix="lumina_t4_05_") as tmp:
            mdir = tmp / "music"
            flac96 = generate_flac_fixture(mdir / "96_24.flac", sample_rate=96000, bit_depth=24, duration_ms=2000)
            wav48 = generate_wav_fixture(mdir / "48_24.wav", sample_rate=48000, bit_depth=24, duration_ms=1500)
            dsf64 = generate_dsf_fixture(mdir / "64.dsf", sample_rate=2822400, duration_ms=1200)
            res = run_ffi_isolated(
                _ffi_t4_05_bit_perfect_scenario,
                args=(str(tmp / "t4_05.db"), str(mdir), str(flac96), str(wav48), str(dsf64)),
            )
            for key in ("sp_flac_0", "sp_flac_seek", "sp_flac_after_meta", "sp_wav", "sp_dsf"):
                self.assertTrue(res[key].get("dsp_bypassed"), key)
                self.assertEqual(res[key].get("overall_quality"), "lossless", key)
            self.assertIn("96000", json.dumps(res["sp_flac_seek"].get("nodes", [])))
            self.assertIn("48000", json.dumps(res["sp_wav"].get("nodes", [])))

    def test_t4_06_p15_f08_p16_f09_unified_state_machine_and_recovery(self):
        with ManagedTempDir(prefix="lumina_t4_06_") as tmp:
            short_wav = generate_wav_fixture(tmp / "short.wav", duration_ms=250)
            res = run_ffi_isolated(_ffi_t4_06_state_machine_lifecycle, args=(str(short_wav), str(tmp / "missing.flac")))
            self.assertEqual(res["s_stopped"]["state_code"], 1)
            self.assertEqual(res["s_playing"]["state_code"], 2)
            self.assertEqual(res["s_paused"]["state_code"], 3)
            self.assertIsNotNone(res["s_ended"])
            self.assertEqual(res["s_ended"]["state_code"], 8)
            self.assertEqual(res["replay_rc"], LUMINA_OK)
            self.assertEqual(res["s_replayed"]["state_code"], 2)
            self.assertLess(res["err_rc"], 0)
            self.assertIn(res["s_error"]["state_code"], (2, 4))
            self.assertEqual(res["rec_rc"], LUMINA_OK)

    def test_t4_07_p12_f01_p13_f05_p14_f06_p15_f08_remote_rest_and_ws_sync(self):
        with ManagedTempDir(prefix="lumina_t4_07_") as tmp:
            mdir = tmp / "music"
            jpg_b, jpg_m = generate_image_bytes("jpeg", 180, 180)
            fp = generate_flac_fixture(
                mdir / "remote.flac",
                duration_ms=3000,
                title="RemoteSong",
                artist="RemoteArtist",
                pictures=[(jpg_b, jpg_m, 3, "Front")],
            )
            generate_lyrics_file(mdir / "remote.lrc", lines=[(500, "Remote Lyric")])

            with LuminaLiveServer(db_path=tmp / "t4_07.db", scan_dir=mdir) as srv:
                tok = srv.pair(device_name="RemotePhone")
                tid = srv.request("GET", "/api/v1/library/tracks", token=tok).json()[0]["id"]
                self.assertEqual(srv.request("GET", f"/api/v1/library/artwork/{tid}", token=tok).status_code, 200)
                self.assertEqual(srv.request("GET", f"/api/v1/lyrics/{tid}", token=tok).status_code, 200)
                with srv.ws_connect(token=tok) as ws:
                    srv.request("POST", "/api/v1/playback/play", token=tok, json={"file_path": str(fp)})
                    srv.request("POST", "/api/v1/playback/seek", token=tok, json={"position_ms": 1400})
                    evt = json.loads(ws.recv(timeout=2.0))
                    self.assertIn("type", evt)
                self.assertEqual(srv.request("POST", "/api/v1/library/rescan", token=tok, json={"dir_path": str(mdir), "force": False}).status_code, 200)

    def test_t4_08_p12_f11_p14_f12_p16_f13_p18_f14_flutter_widget_and_ffi_suite(self):
        flutter = find_flutter_executable()
        proc = subprocess.run(
            [flutter, "test", "-j", "1"],
            cwd=str(_WORKSPACE_ROOT / "app"),
            shell=(os.name == "nt"),
            capture_output=True,
            text=True,
            timeout=240,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)

    def test_t4_09_p18_f14_windows_debug_and_release_exe_smoke_launch(self):
        for profile in ("Debug", "Release"):
            exe_path = _WORKSPACE_ROOT / "app" / "build" / "windows" / "x64" / "runner" / profile / "lumina_app.exe"
            dll_path = exe_path.parent / "core_ffi.dll"
            self.assertTrue(exe_path.is_file(), f"Missing {profile} executable: {exe_path}")
            self.assertTrue(dll_path.is_file(), f"Missing colocated {profile} core_ffi.dll: {dll_path}")

            proc = subprocess.Popen(
                [str(exe_path)],
                cwd=str(exe_path.parent),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                time.sleep(2.0)
                rc = proc.poll()
                if rc is not None:
                    out, err = proc.communicate(timeout=2.0)
                    self.fail(
                        f"{profile} lumina_app.exe exited prematurely with code {rc} (0x{rc & 0xFFFFFFFF:08X}):\n"
                        f"STDOUT: {out.decode('utf-8', errors='replace')}\n"
                        f"STDERR: {err.decode('utf-8', errors='replace')}"
                    )
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5.0)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=2.0)

    def test_t4_10_p18_f14_full_rust_and_flutter_static_and_unit_gate(self):
        cargo = find_cargo_executable()
        flutter = find_flutter_executable()

        res_check = subprocess.run(
            [cargo, "check", "--workspace", "-q"],
            cwd=str(_WORKSPACE_ROOT),
            capture_output=True,
            text=True,
            timeout=180,
        )
        self.assertEqual(res_check.returncode, 0, res_check.stderr)

        res_test = subprocess.run(
            [cargo, "test", "--workspace"],
            cwd=str(_WORKSPACE_ROOT),
            capture_output=True,
            text=True,
            timeout=300,
        )
        self.assertEqual(res_test.returncode, 0, res_test.stdout + "\n" + res_test.stderr)

        res_analyze = subprocess.run(
            [flutter, "analyze", "--no-pub"],
            cwd=str(_WORKSPACE_ROOT / "app"),
            shell=(os.name == "nt"),
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(res_analyze.returncode, 0, res_analyze.stdout + "\n" + res_analyze.stderr)
