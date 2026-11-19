"""
ctypes C-ABI harness, subprocess isolator, and live core-server controller for Lumina Audio.
"""
import ctypes
import importlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Sequence, Tuple, Union

import requests
from websockets.sync.client import connect as ws_sync_connect

from .net_helpers import get_free_port, wait_for_tcp

LUMINA_OK = 0
LUMINA_ERR_GENERAL = -1
LUMINA_ERR_NULL_POINTER = -2
LUMINA_ERR_INVALID_UTF8 = -3
LUMINA_ERR_NOT_INITIALIZED = -4
LUMINA_ERR_AUDIO_BACKEND = -5
LUMINA_ERR_DATABASE = -6

_WORKSPACE_ROOT = Path(__file__).resolve().parents[3]

# Signature registry for planned M7-M10 C-ABI exports (bound dynamically via bind_optional)
OPTIONAL_M7_M10_SIGNATURES: Dict[str, Tuple[Tuple[Any, ...], Any, bool]] = {
    # (argtypes, restype, free_returned_c_char)
    "lumina_library_get_albums": ((ctypes.c_uint,), ctypes.c_void_p, True),
    "lumina_library_get_album_detail": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_library_get_artist_detail": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_library_enrich_credits": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_library_deduplicate": ((), ctypes.c_void_p, True),
    "lumina_profile_list": ((), ctypes.c_void_p, True),
    "lumina_profile_create": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_profile_update": ((ctypes.c_char_p, ctypes.c_char_p), ctypes.c_int, False),
    "lumina_profile_delete": ((ctypes.c_char_p,), ctypes.c_int, False),
    "lumina_profile_switch": ((ctypes.c_char_p,), ctypes.c_int, False),
    "lumina_profile_get_active": ((), ctypes.c_void_p, True),
    "lumina_audio_list_devices": ((), ctypes.c_void_p, True),
    "lumina_audio_select_device": ((ctypes.c_char_p, ctypes.c_int), ctypes.c_int, False),
    "lumina_dsp_get_config": ((), ctypes.c_void_p, True),
    "lumina_dsp_set_config": ((ctypes.c_char_p,), ctypes.c_int, False),
    "lumina_dsp_import_autoeq": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_provider_configure": ((ctypes.c_char_p, ctypes.c_char_p), ctypes.c_int, False),
    "lumina_provider_sync": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_provider_tidal_pkce_start": ((), ctypes.c_void_p, True),
    "lumina_provider_tidal_pkce_complete": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_zone_list": ((), ctypes.c_void_p, True),
    "lumina_zone_discover": ((), ctypes.c_void_p, True),
    "lumina_zone_group": ((ctypes.c_char_p,), ctypes.c_int, False),
    "lumina_zone_set_volume": ((ctypes.c_char_p, ctypes.c_float), ctypes.c_int, False),
    "lumina_zone_sync_status": ((ctypes.c_char_p,), ctypes.c_void_p, True),
}

# Signature registry for Phase 12-18 C-ABI exports (PROJECT.md § Interface Contracts)
OPTIONAL_PHASE12_18_SIGNATURES: Dict[str, Tuple[Tuple[Any, ...], Any, bool]] = {
    # (argtypes, restype, free_returned_c_char)
    "lumina_playback_resume": ((), ctypes.c_int, False),
    "lumina_playback_get_state_json": ((), ctypes.c_void_p, True),
    "lumina_playback_reconnect_device": ((), ctypes.c_int, False),
    "lumina_artwork_get": ((ctypes.c_char_p, ctypes.c_uint32), ctypes.c_void_p, True),
    "lumina_artwork_set_user_cover": ((ctypes.c_char_p, ctypes.c_char_p), ctypes.c_int, False),
    "lumina_artwork_clear_user_cover": ((ctypes.c_char_p,), ctypes.c_int, False),
    "lumina_library_rescan_tags": ((ctypes.c_char_p, ctypes.c_int), ctypes.c_void_p, True),
    "lumina_lyrics_get": ((ctypes.c_char_p,), ctypes.c_void_p, True),
    "lumina_lyrics_set_user_file": ((ctypes.c_char_p, ctypes.c_char_p), ctypes.c_int, False),
    "lumina_lyrics_clear_user_file": ((ctypes.c_char_p,), ctypes.c_int, False),
    # Also include existing M10 audio/signal-path helpers not in baseline-28
    "lumina_audio_get_output_info": ((), ctypes.c_void_p, True),
    "lumina_audio_list_device_capabilities": ((), ctypes.c_void_p, True),
    "lumina_audio_set_strict_mode": ((ctypes.c_int,), ctypes.c_int, False),
    "lumina_audio_set_dsd_mode": ((ctypes.c_int,), ctypes.c_int, False),
}


def resolve_core_ffi_path(explicit_path: Optional[Union[str, Path]] = None) -> Path:
    """Locate compiled core_ffi shared library (debug first, then release)."""
    if explicit_path is not None:
        p = Path(explicit_path)
        if p.is_file():
            return p
        raise FileNotFoundError(f"Explicit core_ffi library not found: {p}")

    env_path = os.environ.get("LUMINA_CORE_FFI_DLL")
    if env_path:
        p = Path(env_path)
        if p.is_file():
            return p
        raise FileNotFoundError(
            f"LUMINA_CORE_FFI_DLL points to missing file: {p}"
        )

    if sys.platform.startswith("win"):
        names = ("core_ffi.dll",)
    elif sys.platform == "darwin":
        names = ("libcore_ffi.dylib", "core_ffi.dylib")
    else:
        names = ("libcore_ffi.so", "core_ffi.so")

    candidates = []
    for profile in ("debug", "release"):
        for name in names:
            candidates.append(_WORKSPACE_ROOT / "target" / profile / name)

    for candidate in candidates:
        if candidate.is_file():
            return candidate

    searched = ", ".join(str(c) for c in candidates)
    raise FileNotFoundError(
        f"Could not find compiled core_ffi library (searched: {searched}). "
        "Run `cargo build -p core-ffi` first."
    )


def _encode_cstr(value: Optional[str]) -> Optional[bytes]:
    if value is None:
        return None
    return value.encode("utf-8")


class LuminaFfiClient:
    """Safe ctypes wrapper around core_ffi.dll covering all 28 baseline + optional M7-M10 exports."""

    def __init__(self, dll_path: Optional[Union[str, Path]] = None) -> None:
        self.dll_path = resolve_core_ffi_path(dll_path)
        self._lib = ctypes.CDLL(str(self.dll_path))
        self._bind_baseline()

    def _bind_baseline(self) -> None:
        lib = self._lib

        # Static constant string - NEVER pass to lumina_string_free
        lib.lumina_version.argtypes = []
        lib.lumina_version.restype = ctypes.c_char_p

        lib.lumina_init.argtypes = []
        lib.lumina_init.restype = ctypes.c_int

        lib.lumina_init_headless.argtypes = []
        lib.lumina_init_headless.restype = ctypes.c_int

        lib.lumina_shutdown.argtypes = []
        lib.lumina_shutdown.restype = ctypes.c_int

        lib.lumina_bytes_alloc.argtypes = [ctypes.c_size_t]
        lib.lumina_bytes_alloc.restype = ctypes.c_void_p

        lib.lumina_bytes_free.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        lib.lumina_bytes_free.restype = None

        lib.lumina_string_free.argtypes = [ctypes.c_void_p]
        lib.lumina_string_free.restype = None

        lib.lumina_last_error_message.argtypes = []
        lib.lumina_last_error_message.restype = ctypes.c_void_p

        lib.lumina_playback_play.argtypes = [ctypes.c_char_p]
        lib.lumina_playback_play.restype = ctypes.c_int

        lib.lumina_playback_pause.argtypes = []
        lib.lumina_playback_pause.restype = ctypes.c_int

        lib.lumina_playback_stop.argtypes = []
        lib.lumina_playback_stop.restype = ctypes.c_int

        lib.lumina_playback_seek.argtypes = [ctypes.c_uint64]
        lib.lumina_playback_seek.restype = ctypes.c_int

        lib.lumina_playback_set_volume.argtypes = [ctypes.c_float]
        lib.lumina_playback_set_volume.restype = ctypes.c_int

        lib.lumina_playback_get_volume.argtypes = []
        lib.lumina_playback_get_volume.restype = ctypes.c_float

        lib.lumina_playback_get_state.argtypes = []
        lib.lumina_playback_get_state.restype = ctypes.c_int

        lib.lumina_playback_get_position_ms.argtypes = []
        lib.lumina_playback_get_position_ms.restype = ctypes.c_uint64

        lib.lumina_playback_get_duration_ms.argtypes = []
        lib.lumina_playback_get_duration_ms.restype = ctypes.c_uint64

        lib.lumina_signal_path_get.argtypes = []
        lib.lumina_signal_path_get.restype = ctypes.c_void_p

        lib.lumina_signal_path_get_quality.argtypes = []
        lib.lumina_signal_path_get_quality.restype = ctypes.c_int

        lib.lumina_signal_path_toggle_dsp_bypass.argtypes = []
        lib.lumina_signal_path_toggle_dsp_bypass.restype = ctypes.c_int

        lib.lumina_signal_path_inspect.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_char_p,
        ]
        lib.lumina_signal_path_inspect.restype = ctypes.c_void_p

        lib.lumina_library_init.argtypes = [ctypes.c_char_p]
        lib.lumina_library_init.restype = ctypes.c_int

        lib.lumina_library_scan_dir.argtypes = [ctypes.c_char_p]
        lib.lumina_library_scan_dir.restype = ctypes.c_void_p

        lib.lumina_library_get_tracks.argtypes = [ctypes.c_uint]
        lib.lumina_library_get_tracks.restype = ctypes.c_void_p

        lib.lumina_library_search.argtypes = [ctypes.c_char_p, ctypes.c_uint]
        lib.lumina_library_search.restype = ctypes.c_void_p

        lib.lumina_server_start.argtypes = [ctypes.c_uint16, ctypes.c_int]
        lib.lumina_server_start.restype = ctypes.c_int

        lib.lumina_server_stop.argtypes = []
        lib.lumina_server_stop.restype = ctypes.c_int

        lib.lumina_server_get_port.argtypes = []
        lib.lumina_server_get_port.restype = ctypes.c_uint16

    def _take_owned_string(self, ptr: Optional[int]) -> Optional[str]:
        """Read UTF-8 string from heap-allocated *mut c_char and free via lumina_string_free."""
        if not ptr:
            return None
        try:
            raw = ctypes.cast(ptr, ctypes.c_char_p).value
            return raw.decode("utf-8") if raw is not None else ""
        finally:
            self._lib.lumina_string_free(ptr)

    def has_symbol(self, name: str) -> bool:
        try:
            return getattr(self._lib, name, None) is not None
        except AttributeError:
            return False

    def bind_optional(
        self,
        name: str,
        argtypes: Optional[Sequence[Any]] = None,
        restype: Any = None,
    ) -> Optional[Callable[..., Any]]:
        """Bind an optional M7-M10 or Phase 12-18 symbol if exported by the loaded DLL, else return None."""
        if not self.has_symbol(name):
            return None
        fn = getattr(self._lib, name)
        if argtypes is None and name in OPTIONAL_M7_M10_SIGNATURES:
            sig_args, sig_ret, _ = OPTIONAL_M7_M10_SIGNATURES[name]
            fn.argtypes = list(sig_args)
            fn.restype = sig_ret
        elif argtypes is None and name in OPTIONAL_PHASE12_18_SIGNATURES:
            sig_args, sig_ret, _ = OPTIONAL_PHASE12_18_SIGNATURES[name]
            fn.argtypes = list(sig_args)
            fn.restype = sig_ret
        else:
            if argtypes is not None:
                fn.argtypes = list(argtypes)
            if restype is not None:
                fn.restype = restype
        return fn

    def _require_optional(self, name: str) -> Callable[..., Any]:
        fn = self.bind_optional(name)
        if fn is None:
            raise RuntimeError(f"Required FFI symbol is not exported by {self.dll_path}: {name}")
        return fn

    # --- Baseline 28 C-ABI wrappers ---

    def version(self) -> str:
        raw = self._lib.lumina_version()
        return raw.decode("utf-8") if raw else ""

    def init(self) -> int:
        return int(self._lib.lumina_init())

    def init_headless(self) -> int:
        return int(self._lib.lumina_init_headless())

    def shutdown(self) -> int:
        return int(self._lib.lumina_shutdown())

    def bytes_alloc(self, length: int) -> int:
        ptr = self._lib.lumina_bytes_alloc(length)
        return int(ptr or 0)

    def bytes_free(self, ptr: int, length: int) -> None:
        self._lib.lumina_bytes_free(ptr, length)

    def last_error_message(self) -> Optional[str]:
        return self._take_owned_string(self._lib.lumina_last_error_message())

    def play(self, track_json_or_path: Optional[Union[str, Dict[str, Any]]] = None) -> int:
        if isinstance(track_json_or_path, dict):
            payload = json.dumps(track_json_or_path)
        else:
            payload = track_json_or_path
        return int(self._lib.lumina_playback_play(_encode_cstr(payload)))

    def pause(self) -> int:
        return int(self._lib.lumina_playback_pause())

    def stop(self) -> int:
        return int(self._lib.lumina_playback_stop())

    def seek(self, position_ms: int) -> int:
        return int(self._lib.lumina_playback_seek(int(position_ms)))

    def set_volume(self, volume: float) -> int:
        return int(self._lib.lumina_playback_set_volume(float(volume)))

    def get_volume(self) -> float:
        return float(self._lib.lumina_playback_get_volume())

    def get_state(self) -> int:
        return int(self._lib.lumina_playback_get_state())

    def get_position_ms(self) -> int:
        return int(self._lib.lumina_playback_get_position_ms())

    def get_duration_ms(self) -> int:
        return int(self._lib.lumina_playback_get_duration_ms())

    def signal_path_get(self) -> Dict[str, Any]:
        text = self._take_owned_string(self._lib.lumina_signal_path_get())
        return json.loads(text) if text else {}

    def signal_path_get_quality(self) -> int:
        return int(self._lib.lumina_signal_path_get_quality())

    def signal_path_toggle_dsp_bypass(self) -> int:
        return int(self._lib.lumina_signal_path_toggle_dsp_bypass())

    def signal_path_inspect(
        self,
        source_label: Optional[str],
        format_info: Optional[Union[str, Dict[str, Any]]],
        dsp_bypass: bool,
        backend_kind: int,
        device_name: Optional[str],
    ) -> Dict[str, Any]:
        fmt_str = (
            json.dumps(format_info)
            if isinstance(format_info, dict)
            else format_info
        )
        ptr = self._lib.lumina_signal_path_inspect(
            _encode_cstr(source_label),
            _encode_cstr(fmt_str),
            1 if dsp_bypass else 0,
            int(backend_kind),
            _encode_cstr(device_name),
        )
        text = self._take_owned_string(ptr)
        return json.loads(text) if text else {}

    def library_init(self, db_path: Optional[Union[str, Path]]) -> int:
        p_str = str(db_path) if db_path is not None else None
        return int(self._lib.lumina_library_init(_encode_cstr(p_str)))

    def library_scan_dir(self, dir_path: Optional[Union[str, Path]]) -> Optional[Dict[str, Any]]:
        p_str = str(dir_path) if dir_path is not None else None
        text = self._take_owned_string(
            self._lib.lumina_library_scan_dir(_encode_cstr(p_str))
        )
        return json.loads(text) if text is not None else None

    def library_get_tracks(self, limit: int = 200) -> list:
        text = self._take_owned_string(self._lib.lumina_library_get_tracks(int(limit)))
        return json.loads(text) if text else []

    def library_search(self, query: Optional[str], limit: int = 20) -> list:
        text = self._take_owned_string(
            self._lib.lumina_library_search(_encode_cstr(query), int(limit))
        )
        return json.loads(text) if text else []

    def server_start(self, port: int, enable_mdns: bool = False) -> int:
        return int(self._lib.lumina_server_start(int(port), 1 if enable_mdns else 0))

    def server_stop(self) -> int:
        return int(self._lib.lumina_server_stop())

    def server_get_port(self) -> int:
        return int(self._lib.lumina_server_get_port())

    # --- Phase 12-18 Contract Helpers (PROJECT.md § Interface Contracts) ---

    @staticmethod
    def _encode_target(target: Union[str, Dict[str, Any]]) -> Optional[bytes]:
        if isinstance(target, dict):
            return _encode_cstr(json.dumps(target))
        return _encode_cstr(target)

    def playback_resume(self) -> int:
        fn = self._require_optional("lumina_playback_resume")
        return int(fn())

    def playback_get_state_json(self) -> Dict[str, Any]:
        fn = self._require_optional("lumina_playback_get_state_json")
        text = self._take_owned_string(fn())
        return json.loads(text) if text else {}

    def playback_reconnect_device(self) -> int:
        fn = self._require_optional("lumina_playback_reconnect_device")
        return int(fn())

    def artwork_get(
        self,
        target: Union[str, Dict[str, Any]],
        max_dim: int = 0,
    ) -> Dict[str, Any]:
        fn = self._require_optional("lumina_artwork_get")
        text = self._take_owned_string(fn(self._encode_target(target), int(max_dim)))
        return json.loads(text) if text else {}

    def artwork_set_user_cover(
        self,
        target: Union[str, Dict[str, Any]],
        image_path: Union[str, Path],
    ) -> int:
        fn = self._require_optional("lumina_artwork_set_user_cover")
        return int(fn(self._encode_target(target), _encode_cstr(str(image_path))))

    def artwork_clear_user_cover(self, target: Union[str, Dict[str, Any]]) -> int:
        fn = self._require_optional("lumina_artwork_clear_user_cover")
        return int(fn(self._encode_target(target)))

    def library_rescan_tags(
        self,
        dir_path: Optional[Union[str, Path]] = None,
        force: bool = False,
    ) -> Dict[str, Any]:
        fn = self._require_optional("lumina_library_rescan_tags")
        p_str = str(dir_path) if dir_path is not None else None
        text = self._take_owned_string(fn(_encode_cstr(p_str), 1 if force else 0))
        return json.loads(text) if text else {}

    def lyrics_get(self, target: Union[str, Dict[str, Any]]) -> Dict[str, Any]:
        fn = self._require_optional("lumina_lyrics_get")
        text = self._take_owned_string(fn(self._encode_target(target)))
        return json.loads(text) if text else {}

    def lyrics_set_user_file(
        self,
        target: Union[str, Dict[str, Any]],
        file_path: Union[str, Path],
    ) -> int:
        fn = self._require_optional("lumina_lyrics_set_user_file")
        return int(fn(self._encode_target(target), _encode_cstr(str(file_path))))

    def lyrics_clear_user_file(self, target: Union[str, Dict[str, Any]]) -> int:
        fn = self._require_optional("lumina_lyrics_clear_user_file")
        return int(fn(self._encode_target(target)))

    def audio_get_output_info(self) -> Dict[str, Any]:
        fn = self._require_optional("lumina_audio_get_output_info")
        text = self._take_owned_string(fn())
        return json.loads(text) if text else {}

    def audio_set_strict_mode(self, enabled: bool) -> int:
        fn = self._require_optional("lumina_audio_set_strict_mode")
        return int(fn(1 if enabled else 0))

    def audio_set_dsd_mode(self, mode: int) -> int:
        fn = self._require_optional("lumina_audio_set_dsd_mode")
        return int(fn(int(mode)))

    def library_get_albums(self, limit: int = 200) -> list:
        fn = self._require_optional("lumina_library_get_albums")
        text = self._take_owned_string(fn(int(limit)))
        return json.loads(text) if text else []

    def library_get_album_detail(self, album_id: str) -> Dict[str, Any]:
        fn = self._require_optional("lumina_library_get_album_detail")
        text = self._take_owned_string(fn(_encode_cstr(album_id)))
        return json.loads(text) if text else {}

    def dsp_get_config(self) -> Dict[str, Any]:
        fn = self._require_optional("lumina_dsp_get_config")
        text = self._take_owned_string(fn())
        return json.loads(text) if text else {}

    def dsp_set_config(self, cfg: Union[str, Dict[str, Any]]) -> int:
        fn = self._require_optional("lumina_dsp_set_config")
        payload = json.dumps(cfg) if isinstance(cfg, dict) else cfg
        return int(fn(_encode_cstr(payload)))


_ISOLATED_RUNNER_CODE = r"""
import importlib, json, sys
payload = json.loads(sys.stdin.read())
mod = importlib.import_module(payload["module"])
obj = mod
for attr in payload["qualname"].split("."):
    obj = getattr(obj, attr)
from tests.e2e.fixtures.ffi_harness import LuminaFfiClient
client = LuminaFfiClient(payload.get("dll_path"))
res = obj(client, *payload["args"], **payload["kwargs"])
print("__LUMINA_FFI_RESULT__:" + json.dumps(res))
"""

_RESULT_MARKER = "__LUMINA_FFI_RESULT__:"


def run_ffi_isolated(
    callable_or_code: Union[str, Callable[..., Any]],
    args: Tuple[Any, ...] = (),
    kwargs: Optional[Dict[str, Any]] = None,
    timeout_s: float = 30.0,
    env: Optional[Dict[str, str]] = None,
    dll_path: Optional[Union[str, Path]] = None,
) -> Any:
    """
    Execute an FFI test function (receiving `client: LuminaFfiClient`) or Python snippet
    in a fresh subprocess so Rust's OnceLock GLOBAL_ENGINE and SQLite WAL locks never leak.
    """
    proc_env = os.environ.copy()
    existing_pp = proc_env.get("PYTHONPATH", "")
    root_str = str(_WORKSPACE_ROOT)
    proc_env["PYTHONPATH"] = (
        f"{root_str}{os.pathsep}{existing_pp}" if existing_pp else root_str
    )
    if env:
        proc_env.update(env)

    if isinstance(callable_or_code, str):
        proc = subprocess.run(
            [sys.executable, "-c", callable_or_code],
            cwd=root_str,
            env=proc_env,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"Isolated FFI script failed (exit={proc.returncode}):\n"
                f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
            )
        for line in reversed(proc.stdout.splitlines()):
            if line.startswith(_RESULT_MARKER):
                return json.loads(line[len(_RESULT_MARKER) :])
        return proc.stdout

    if not callable(callable_or_code):
        raise TypeError("callable_or_code must be a callable or Python code string")

    if "<locals>" in callable_or_code.__qualname__:
        raise ValueError(
            "run_ffi_isolated requires a module-level callable (not a local nested function)"
        )

    if getattr(callable_or_code, "__module__", None) == "__main__":
        raise ValueError(
            "run_ffi_isolated cannot invoke a callable defined in '__main__' "
            "(define it in an importable module or pass a Python code string)"
        )

    payload = json.dumps(
        {
            "module": callable_or_code.__module__,
            "qualname": callable_or_code.__qualname__,
            "args": list(args),
            "kwargs": kwargs or {},
            "dll_path": str(dll_path) if dll_path is not None else None,
        }
    )
    proc = subprocess.run(
        [sys.executable, "-c", _ISOLATED_RUNNER_CODE],
        input=payload,
        cwd=root_str,
        env=proc_env,
        capture_output=True,
        text=True,
        timeout=timeout_s,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Isolated FFI callable '{callable_or_code.__qualname__}' failed "
            f"(exit={proc.returncode}):\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    for line in reversed(proc.stdout.splitlines()):
        if line.startswith(_RESULT_MARKER):
            return json.loads(line[len(_RESULT_MARKER) :])
    raise RuntimeError(
        f"Isolated FFI callable '{callable_or_code.__qualname__}' did not emit result marker.\n"
        f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
    )


_SERVER_CHILD_CODE = r"""
import json, sys
cfg = json.loads(sys.stdin.readline())
from tests.e2e.fixtures.ffi_harness import LuminaFfiClient, LUMINA_OK
client = LuminaFfiClient(cfg.get("dll_path"))
if cfg.get("headless", True):
    rc = client.init_headless()
    if rc != LUMINA_OK:
        raise RuntimeError(f"lumina_init_headless failed: {rc}")
if cfg.get("db_path"):
    rc = client.library_init(cfg["db_path"])
    if rc != LUMINA_OK:
        raise RuntimeError(f"lumina_library_init failed: {rc}")
if cfg.get("scan_dir"):
    client.library_scan_dir(cfg["scan_dir"])
rc = client.server_start(cfg["port"], enable_mdns=cfg.get("enable_mdns", False))
if rc != LUMINA_OK:
    raise RuntimeError(f"lumina_server_start failed: {rc}")
bound_port = client.server_get_port()
print(f"READY:{bound_port}", flush=True)
try:
    sys.stdin.readline()
finally:
    client.server_stop()
    client.shutdown()
"""


class LuminaLiveServer:
    """
    Context-managed live Rust core-server controller.
    Runs in an isolated child process by default so ports, OnceLock state, and SQLite WAL
    file handles are deterministically released on stop().
    """

    def __init__(
        self,
        port: Optional[int] = None,
        db_path: Optional[Union[str, Path]] = None,
        scan_dir: Optional[Union[str, Path]] = None,
        headless: bool = True,
        enable_mdns: bool = False,
        in_process: bool = False,
        dll_path: Optional[Union[str, Path]] = None,
    ) -> None:
        self._requested_port = port
        self._db_path = str(db_path) if db_path is not None else None
        self._scan_dir = str(scan_dir) if scan_dir is not None else None
        self._headless = headless
        self._enable_mdns = enable_mdns
        self._in_process = in_process
        self._dll_path = str(dll_path) if dll_path is not None else None
        self._proc: Optional[subprocess.Popen] = None
        self._client: Optional[LuminaFfiClient] = None
        self._port: int = 0

    @property
    def port(self) -> int:
        return self._port

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self._port}"

    @property
    def ws_url(self) -> str:
        return f"ws://127.0.0.1:{self._port}/api/v1/ws"

    def start(self, timeout_s: float = 10.0) -> "LuminaLiveServer":
        req_port = self._requested_port or get_free_port()
        if self._in_process:
            client = LuminaFfiClient(self._dll_path)
            if self._headless:
                rc = client.init_headless()
                if rc != LUMINA_OK:
                    raise RuntimeError(f"lumina_init_headless failed: {rc}")
            if self._db_path:
                rc = client.library_init(self._db_path)
                if rc != LUMINA_OK:
                    raise RuntimeError(f"lumina_library_init failed: {rc}")
            if self._scan_dir:
                client.library_scan_dir(self._scan_dir)
            rc = client.server_start(req_port, enable_mdns=self._enable_mdns)
            if rc != LUMINA_OK:
                raise RuntimeError(f"lumina_server_start failed: {rc}")
            self._client = client
            self._port = client.server_get_port()
            try:
                wait_for_tcp("127.0.0.1", self._port, timeout_s=timeout_s)
            except BaseException:
                self.stop()
                raise
            return self

        proc_env = os.environ.copy()
        existing_pp = proc_env.get("PYTHONPATH", "")
        root_str = str(_WORKSPACE_ROOT)
        proc_env["PYTHONPATH"] = (
            f"{root_str}{os.pathsep}{existing_pp}" if existing_pp else root_str
        )

        self._proc = subprocess.Popen(
            [sys.executable, "-u", "-c", _SERVER_CHILD_CODE],
            cwd=root_str,
            env=proc_env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        cfg = {
            "port": req_port,
            "db_path": self._db_path,
            "scan_dir": self._scan_dir,
            "headless": self._headless,
            "enable_mdns": self._enable_mdns,
            "dll_path": self._dll_path,
        }
        try:
            assert self._proc.stdin is not None and self._proc.stdout is not None
            self._proc.stdin.write(json.dumps(cfg) + "\n")
            self._proc.stdin.flush()

            ready_line = self._proc.stdout.readline().strip()
            if not ready_line.startswith("READY:"):
                stderr_out = ""
                try:
                    self._proc.kill()
                    _, stderr_out = self._proc.communicate(timeout=2.0)
                except Exception:
                    pass
                finally:
                    self._proc = None
                raise RuntimeError(
                    f"LuminaLiveServer failed to start (line={ready_line!r}): {stderr_out}"
                )
            self._port = int(ready_line.split(":", 1)[1])
            wait_for_tcp("127.0.0.1", self._port, timeout_s=timeout_s)
        except BaseException:
            self.stop()
            raise
        return self

    def stop(self) -> None:
        if self._in_process and self._client is not None:
            try:
                self._client.server_stop()
                self._client.shutdown()
            finally:
                self._client = None
                self._port = 0
            return

        if self._proc is not None:
            try:
                if self._proc.stdin and not self._proc.stdin.closed:
                    try:
                        self._proc.stdin.write("STOP\n")
                        self._proc.stdin.flush()
                        self._proc.stdin.close()
                    except OSError:
                        pass
                try:
                    self._proc.wait(timeout=3.0)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
                    self._proc.wait(timeout=2.0)
            finally:
                for pipe in (self._proc.stdout, self._proc.stderr):
                    if pipe and not pipe.closed:
                        try:
                            pipe.close()
                        except OSError:
                            pass
                self._proc = None
                self._port = 0

    def __enter__(self) -> "LuminaLiveServer":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()

    def auth_headers(self, token: str) -> Dict[str, str]:
        return {"Authorization": f"Bearer {token}"}

    def pair_initiate(self, device_name: str = "E2E-Client") -> Dict[str, Any]:
        resp = requests.post(
            f"{self.base_url}/api/v1/pair/initiate",
            json={
                "device_name": device_name,
                "host": "127.0.0.1",
                "port": self._port,
            },
            timeout=5.0,
        )
        resp.raise_for_status()
        return resp.json()

    def pair_verify(
        self,
        pin: str,
        client_id: Optional[str] = None,
        device_name: str = "E2E-Client",
        platform: str = "python",
    ) -> Dict[str, Any]:
        resp = requests.post(
            f"{self.base_url}/api/v1/pair/verify",
            json={
                "pin": pin,
                "client_id": client_id or f"e2e-{pin}",
                "device_name": device_name,
                "platform": platform,
            },
            timeout=5.0,
        )
        resp.raise_for_status()
        return resp.json()

    def pair(
        self,
        device_name: str = "E2E-Client",
        client_id: Optional[str] = None,
        platform: str = "python",
    ) -> str:
        init_data = self.pair_initiate(device_name=device_name)
        pin = init_data["pin"]
        verify_data = self.pair_verify(
            pin=pin,
            client_id=client_id,
            device_name=device_name,
            platform=platform,
        )
        if verify_data.get("status") != "success" or not verify_data.get("token"):
            raise RuntimeError(f"Pairing verification failed: {verify_data}")
        return str(verify_data["token"])

    def request(
        self,
        method: str,
        path: str,
        token: Optional[str] = None,
        timeout: float = 5.0,
        **kwargs: Any,
    ) -> requests.Response:
        headers = dict(kwargs.pop("headers", {}) or {})
        if token is not None:
            headers.setdefault("Authorization", f"Bearer {token}")
        url = f"{self.base_url}{path if path.startswith('/') else '/' + path}"
        return requests.request(method, url, headers=headers, timeout=timeout, **kwargs)

    def ws_connect(self, token: Optional[str] = None, **kwargs: Any):
        headers = dict(kwargs.pop("additional_headers", {}) or {})
        if token is not None:
            headers.setdefault("Authorization", f"Bearer {token}")
        return ws_sync_connect(
            self.ws_url,
            additional_headers=headers or None,
            **kwargs,
        )
