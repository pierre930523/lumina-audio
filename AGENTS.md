# AGENTS.md — Lumina Audio

## 1. Project Overview & Tech Stack

- **Goal**: Cross-platform audiophile lossless music player supporting local Hi-Res/DSD, NAS (SMB/WebDAV), streaming platforms (Qobuz, Tidal, Deezer, Apple Music, YouTube Music), 64-bit DSP, Bit-Perfect hardware output, and remote/multi-room playback.
- **Rust Core Workspace** (`Cargo.toml`, Edition `2024`, `v0.2.1`):
  - Six crates: `core-types`, `core-db`, `core-providers`, `core-audio`, `core-server`, `core-ffi`.
  - Key deps: `tokio` (`full`), `sqlx` (`0.8`, SQLite WAL + FTS5), `axum` (`0.8`, REST + WS), `symphonia` (`0.5.4`), `cpal` (`0.18`), `opus2` (bundled/static), `reqwest` (`0.12`, rustls + http2 + stream), `keyring` (`3`), `windows` (`0.62.2` on Windows).
- **Flutter App** (`app/pubspec.yaml`, `v0.2.6+8`, Dart SDK `^3.14.0`):
  - `material_ui`, `ffi: ^2.2.0`, `crypto`, `flutter_lints: ^6.0.0`.
  - **Impeller** rendering engine with custom GLSL fragment shaders (`app/shaders/liquid_glass.frag`, `app/shaders/mesh_fluid_bg.frag`).
- **Platforms & Verification**:
  - Primary desktop targets: Windows x64 (MSVC BuildTools + WASAPI Exclusive / ASIO) and macOS (CoreAudio Hog Mode), plus Linux & remote mobile/desktop clients.
  - E2E suite: Python 3.11+ (`tests/e2e/runner.py`, `run_e2e_tests.ps1`) + `scripts/check_ffi_symbols.py`.

---

## 2. Refactored Architecture & Directory Map

```text
crates/
├── core-types/src/          # Layer 0: pure domain DTOs, AudioFormat, SignalPath, ingestion & unified protocol contracts
├── core-db/
│   ├── migrations/          # Immutable SQLite migrations 0001_init.sql .. 0006_ingestion_layer.sql
│   └── src/
│       ├── credential/      # OS Keyring (CredentialStore / KeyringStore) & fallback secret isolation
│       ├── repository/      # Library, ingestion, L1/L2 cache, profile, pairing & zone SQLite repositories
│       └── search/          # FTS5 indexing & sanitize_fts5_query()
├── core-audio/src/
│   ├── backend/             # PullAudioBackend, OutputDeviceFsm, AudioDeviceManager, wasapi_win, asio_win, coreaudio, cpal_shared, mock
│   ├── decoder/             # Unified PCM (Symphonia/Opus) & DSD (DSF/DSDIFF/DoP) decoders + source_opener
│   ├── dsp/                 # 64-bit DspPipeline (PEQ, Biquad, Crossfeed, ReplayGain, LookaheadLimiter, AutoEQ, Sinc resampler)
│   ├── engine/              # AudioPlayer coordinator, dual_deck lock-free feeder & Strict Bit-Perfect session state
│   ├── pipeline/            # Hard-RT SpscRingBuffer, UnderrunGuard, RtTelemetry, audio fade & decode_worker
│   ├── signal_path/         # Roon-style transparent SignalPathEngine
│   ├── streaming/           # L2 `.head` SSD cache, chunked_proxy, segmented_proxy & hybrid stream recovery
│   └── visualizer/          # Global lock-free VisualizerRingBuffer tap
├── core-providers/src/
│   ├── providers/           # Isolated streaming integrations: tidal, qobuz, deezer, apple_music, ytmusic
│   ├── local/               # Bounded ingestion pipeline, dual-track watcher, fingerprint, encoding/ape_meta, tag_debug, playlist
│   ├── remote/              # NAS SMB & WebDAV transports
│   ├── enrichment/          # Rate-limited MusicBrainz & Discogs credit enrichment
│   ├── process_guard/       # Windows Job Object / Unix process group ProcessGuard, BinaryLocator & RingLogBuffer
│   ├── stream_cache/        # L1 stream URL cache with TTL margin, single-flight dedup & 403/410 refresh
│   └── prefetcher.rs        # Lookahead queue prefetch & cancellation
├── core-server/src/         # Axum HTTP REST + `/api/v1/ws` server, mDNS (`_lumina._tcp.local.`), PIN/QR pairing, auth middleware & multi-room zones
└── core-ffi/src/            # C-ABI bridge (`core_ffi.dll`): engine, library, playback, streaming_bridge, l1/l2 cache, profiles, zones, server

app/lib/
├── main.dart                # App entrypoint, ImageCache & UiScaleScope
├── models/                  # Strongly typed Dart DTOs (`protocol/`, `ingestion/`, `podcast/`, `streaming/`, `stream_source/`, `studio/`)
├── services/
│   ├── audio_service.dart   # Abstract AudioService contract
│   ├── ffi/                 # Native `dart:ffi` loader, typedefs, mixins & worker isolate (desktop local engine)
│   ├── server/              # Remote REST + WebSocket AudioService client
│   ├── mock/                # Deterministic in-memory AudioService for tests
│   ├── playback/            # Unified `PlaybackBackend` (`FfiPlaybackBackend`, `RemotePlaybackBackend`, `MockPlaybackBackend`), `PlaybackController`, `AppServiceBootstrapper`
│   └── streaming/           # `StreamingManager`, `StreamingPlaybackCoordinator`, `CrossPlatformTrackRouter`, `AutoplayController`, `StreamResolver`, `providers/`
├── shaders/                 # `shader_loader.dart`, `liquid_glass_painter.dart`, `mesh_fluid_painter.dart`
└── ui/                      # Pure presentation layer (`common/`, `home_shell/`, `home/`, `library/`, `albums/`, `artists/`, `now_playing/`, `mini_player/`, `dsp/`, `signal_path/`, `settings/`, `zones/`, `podcasts/`, `audiobooks/`, `playlists/`, `radio/`, `search/`, `lyrics/`, `profiles/`, `theme/`)

scripts/
├── check_ffi_symbols.py     # Verifies every Dart `lumina_*` lookup exists in `crates/core-ffi/src`
├── prepare_release_deps.ps1 # Downloads & SHA256-verifies Windows x64 vendor binaries + THIRD_PARTY_LICENSES.txt
└── build_release.ps1        # Assembles & verifies `app/build/windows/x64/runner/Release/`
```

---

## 3. Hard Architectural Boundaries & Redlines

1. **Strict Crate Dependency DAG (Layer 0 → Layer 3)**:
   - **Layer 0 (`core-types`)**: Pure domain types & protocol contracts. Zero dependencies on any other workspace crate, SQLite, audio hardware, HTTP server, or UI/FFI.
   - **Layer 1 (`core-audio`, `core-db`)**: Mutually independent. **`core-audio` MUST NOT depend on `core-db` or `sqlx`**. **`core-db` is the sole `sqlx` holder** in the workspace (`core-providers` and `core-server` MUST NOT depend directly on `sqlx`).
   - **Layer 2 (`core-providers`)**: Depends only on `core-types` and `core-db`; **forbidden from depending on `core-audio` or `core-server`**. Cross-layer audio handoff uses `StreamSourceSpec` / `ResolvedStream` DTOs only.
   - **Layer 3 (`core-server`, `core-ffi`)**: Top-level composition crates wiring Layers 0–2.
   - Verify anytime with `just rust-dag`.
2. **`core-audio` Real-Time Callback Redline**:
   - Audio hardware render callbacks (`PullAudioBackend` / WASAPI / ASIO / CoreAudio IOProc / `cpal`) consume from lock-free `SpscRingBuffer` and report atomically via `RtTelemetry`.
   - **Strict No-Alloc / No-Lock / No-I/O** inside real-time audio callbacks: no heap allocations, no `Mutex`/`RwLock`, no logging, and no blocking I/O.
3. **`core-providers` Child Process Isolation**:
   - Every external executable (`yt-dlp`, `deno`, `ffmpeg`, sidecars) MUST be spawned via `process_guard::ProcessGuard` (Windows Job Objects / Unix process groups) with bounded stderr `RingLogBuffer` so child processes never leak or orphan.
4. **`core-ffi` C-ABI Safety**:
   - Every `#[unsafe(no_mangle)] pub extern "C" fn lumina_*` entrypoint (outside trivial static/allocator/free helpers) MUST wrap execution in `catch_unwind_ffi` — **Rust panics MUST NEVER unwind across FFI**.
   - Returned Rust pointers MUST be released via `lumina_string_free` / `lumina_bytes_free`.
   - Every `lumina_*` lookup in `app/lib` MUST match an exported symbol in `crates/core-ffi/src` (`just ffi-check`).
5. **`core-db` Migrations, FTS5 & Secrets**:
   - Migrations `0001_init.sql` through `0006_ingestion_layer.sql` are **immutable**; schema updates require a new numbered migration (`0007_*.sql`).
   - All FTS5 queries MUST pass through `sanitize_fts5_query()` before hitting `MATCH`.
   - Streaming credentials & pairing tokens MUST be stored via `credential::KeyringStore` (OS Keyring), never plaintext in library tables.
   - L2 `.head` cache eviction MUST check `L2FileLease` and delete the SQLite record **before** deleting the physical file.
6. **Flutter UI Isolation & Glassmorphism Preservation**:
   - `app/lib/ui/**` is **strictly forbidden** from importing `dart:ffi`, `package:http/`, `HttpClient`, `WebSocket`, or concrete backend/coordinator classes (`FfiAudioService`, `ServerAudioService`, `MockAudioService`, `CoordinatingAudioService`, `StreamingPlaybackCoordinator`), enforced by `app/test/ui/ui_isolation_test.dart`.
   - UI widgets interact solely through `AudioService`, `PlaybackBackend`, and Service controllers.
   - **100% preserve the Liquid Glass / Frosted Glass visual architecture** (`FrostedGlassContainer`, `AmbientDynamicBackground`, custom GLSL shaders) and desktop window chrome (`DesktopWindowCaption`, `WindowDragBar`).

---

## 4. Standard Dev Commands Cheatsheet

> **Rebuild Trigger**: After ANY edit under `crates/`, rebuild `core-ffi` (`just ffi-build` / `cargo build -p core-ffi`) before running Flutter or E2E tests, otherwise `core_ffi.dll` will be stale. On Windows, close running Flutter/Python processes locking `core_ffi.dll` before rebuilding.

| Task | `just` Recipe | Direct CLI Equivalent |
|---|---|---|
| Format / Check Rust | `just fmt` / `just fmt-check` | `cargo fmt --all` / `cargo fmt --all -- --check` |
| Type-check & Lint Rust | `just rust-check` / `just rust-lint` | `cargo check --workspace` / `cargo clippy --workspace --all-targets --no-deps -- -D warnings` |
| Test Rust Workspace | `just rust-test` | `cargo test --workspace` |
| Verify Crate DAG | `just rust-dag` | `cargo tree --workspace --depth 2` + DAG check (`core-audio` ≠ `core-db`; no direct `sqlx` outside `core-db`) |
| Build FFI (Debug / Release) | `just ffi-build` / `just ffi-build-release` | `cargo build -p core-ffi` / `cargo build --release -p core-ffi` |
| Verify FFI Symbol Parity | `just ffi-check` | `python scripts/check_ffi_symbols.py` |
| Flutter Deps & Analyze | `just flutter-get` / `just flutter-analyze` | `cd app; flutter pub get` / `cd app; flutter analyze` |
| Run Flutter Tests | `just flutter-test` | `cd app; flutter test -r expanded -j 1 --timeout 30s` |
| Launch Desktop App | `just flutter-run-win` / `just flutter-run-mac` | `cargo build -p core-ffi` then `cd app; flutter run -d windows` (or `macos`) |
| Full Verification Gate | `just verify-all` | Runs `fmt-check`, `rust-check`, `rust-lint`, `rust-dag`, `ffi-check`, `rust-test`, `flutter-analyze`, `flutter-test` |
| Prepare Vendor Deps (Win) | `just deps-prepare` | `powershell.exe -NoLogo -ExecutionPolicy Bypass -File scripts/prepare_release_deps.ps1` |
| Build Windows Release | `just release-win` | `cargo build --release -p core-ffi` then `.\scripts\build_release.ps1 -SkipPrepareDeps` |
| Run E2E Acceptance Suite | — | `.\run_e2e_tests.ps1 -Tier all -Suite all` / `python tests/e2e/runner.py --tier all --suite auto --strict` |

- **Vendored Windows Runtime Assets** (`app/windows/vendor/bin/`, staged by `prepare_release_deps.ps1` and bundled into `app/build/windows/x64/runner/Release/bin/` by `build_release.ps1`):
  - `yt-dlp.exe`, `deno.exe`, `ffmpeg.exe` (official `BtbN/FFmpeg-Builds` Windows x64 LGPL static build only — never GPL, never `ffplay`/`ffprobe`), and merged `THIRD_PARTY_LICENSES.txt`.

---

## 5. Code Style & Scale Guidelines

- **500-Line Hard Ceiling**: Every `.rs` and `.dart` source file MUST stay **<= 500 lines**. Split larger modules cleanly via Rust submodules (`mod.rs` + cohesive submodules) or Dart `part`/`part of` + barrel exports while keeping public APIs intact.
- **Zero Warnings**: `cargo clippy --workspace --all-targets --no-deps -- -D warnings` and `cd app; flutter analyze` (`flutter_lints: ^6.0.0`) must pass with 0 warnings/issues.
- **Cross-Platform `#[cfg]` Hygiene**: Keep OS-specific implementations isolated inside `crates/core-audio/src/backend/` (`wasapi_win`/`asio_win`/`device_watcher_win` for Windows; `coreaudio` for macOS) and `crates/core-providers/src/process_guard/` (`win_job` vs Unix process groups) so all targets compile cleanly without `#[cfg]` clutter in `engine/` or UI code.
- **Test & E2E Preservation**: Never modify published SQL migrations (`0001..0006`) or break baseline E2E exports (`tests/e2e/fixtures/__init__.py`) and `tests/e2e/test_tier{1..4}_features/boundaries/pairwise/scenarios.py`.
