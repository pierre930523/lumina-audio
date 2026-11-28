# Lumina Audio — Cross-Platform Task Runner (Windows PowerShell & macOS/Unix)
#
# Prerequisites:
#   - Rust toolchain (Edition 2024, rustfmt, clippy) + MSVC BuildTools (Windows) or Xcode CLT (macOS)
#   - Flutter / Dart SDK (^3.14.0)
#   - Python 3.11+ (`python` on Windows, `python3` on macOS/Unix)
#   - Windows Release runtime dependencies (staged via `just deps-prepare` into `app/windows/vendor/bin/`):
#     yt-dlp.exe, deno.exe, ffmpeg.exe (LGPL), THIRD_PARTY_LICENSES.txt
#
# Manual `dart:ffi` Workflow (no codegen; hand-maintained C-ABI surface):
#   1. Dart loads `core_ffi.dll` (Windows) / `libcore_ffi.dylib` (macOS) / `libcore_ffi.so` (Linux) at runtime
#      via `DynamicLibrary.open(...)` in `app/lib/services/ffi/ffi_native_binding_mixin.dart`.
#   2. Rebuild trigger: ANY change under `crates/` MUST be followed by `just ffi-build` (or `just ffi-build-release`)
#      before running `flutter run` or Python E2E tests, otherwise Flutter/E2E loads a stale `core_ffi.dll`.
#      On Windows, close running Flutter/Python processes holding `core_ffi.dll` first to avoid Access Denied.
#   3. Always run `just ffi-check` after adding/renaming any `lumina_*` symbol in Dart or `crates/core-ffi`.

set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

python := if os_family() == "windows" { "python" } else { "python3" }

# List available recipes
default:
    @just --list

# ==============================================================================
# Rust Workspace (Edition 2024)
# Platform audio backend notes:
#   - Windows (`cfg(target_os = "windows")`): Win32 WASAPI Exclusive (`backend::wasapi_win`),
#     ASIO (`backend::asio_win`), MMDevice hotplug watcher (`backend::device_watcher_win`),
#     and `windows` crate audio/COM features; optional crate features `wasapi` / `asio` in `core-audio`.
#   - macOS (`cfg(target_os = "macos")`): CoreAudio (`backend::coreaudio::CoreAudioBackend`) + `cpal`;
#     Windows-only WASAPI/ASIO modules are compiled out automatically via `#[cfg(target_os = "windows")]`.
# ==============================================================================

# Format all Rust crates in the workspace
fmt:
    cargo fmt --all

# Check Rust formatting without modifying files
fmt-check:
    cargo fmt --all -- --check

# Type-check all Rust workspace crates
rust-check:
    cargo check --workspace

# Run Clippy across all workspace targets with warnings denied
rust-lint:
    cargo clippy --workspace --all-targets --no-deps -- -D warnings

# Run all Rust workspace unit and integration tests
rust-test:
    cargo test --workspace

# Verify workspace crate DAG boundaries:
#   - `core-audio` has zero dependency on `core-db` or `sqlx`
#   - `core-providers` and `core-server` have no direct `sqlx` dependency (`core-db` is sole `sqlx` holder)
#   - `core-providers` has zero dependency on `core-audio` or `core-server`
rust-dag:
    cargo tree --workspace --depth 2
    {{python}} -c "import subprocess, sys; audio = subprocess.check_output(['cargo', 'tree', '-p', 'core-audio'], text=True); assert 'core-db ' not in audio and 'sqlx ' not in audio, 'DAG violation: core-audio depends on core-db or sqlx'; [sys.exit(f'DAG violation: {c} depends directly on sqlx') for c in ('core-providers', 'core-server') if 'sqlx ' in subprocess.check_output(['cargo', 'tree', '-p', c, '--depth', '1'], text=True)]; prov = subprocess.check_output(['cargo', 'tree', '-p', 'core-providers'], text=True); assert 'core-audio ' not in prov and 'core-server ' not in prov, 'DAG violation: core-providers depends on core-audio or core-server'; print('DAG OK: Layer 0..3 crate boundaries verified.')"

# ==============================================================================
# Native FFI Bridge (`core-ffi` <-> `app/lib/services/ffi/`)
# ==============================================================================

# Build Debug `core_ffi` shared library (`target/debug/core_ffi.dll` / `.dylib` / `.so`)
ffi-build:
    cargo build -p core-ffi

# Build Release `core_ffi` shared library (`target/release/core_ffi.dll` / `.dylib` / `.so`)
ffi-build-release:
    cargo build --release -p core-ffi

# Verify every Dart `lookup` / `lookupFunction` for `lumina_*` exists in `crates/core-ffi/src`
ffi-check:
    {{python}} scripts/check_ffi_symbols.py

# ==============================================================================
# Flutter App (`app/`, Dart SDK ^3.14.0, Impeller + GLSL shaders)
# ==============================================================================

# Install / resolve Flutter package dependencies
flutter-get:
    cd app; flutter pub get

# Run Dart static analyzer on `app/`
flutter-analyze:
    cd app; flutter analyze

# Run Flutter test suite (single-threaded expanded output, 30s per-test timeout)
flutter-test:
    cd app; flutter test -r expanded -j 1 --timeout 30s

# Build Debug `core_ffi` and launch Flutter app on Windows desktop
flutter-run-win: ffi-build
    cd app; flutter run -d windows

# Build Debug `core_ffi` and launch Flutter app on macOS desktop
flutter-run-mac: ffi-build
    cd app; flutter run -d macos

# ==============================================================================
# Vendored Runtime Dependencies, Verification & Release
# ==============================================================================

# Download & SHA256-verify Windows x64 runtime binaries into `app/windows/vendor/bin/`:
#   yt-dlp.exe, deno.exe, ffmpeg.exe (LGPL), THIRD_PARTY_LICENSES.txt
deps-prepare:
    powershell.exe -NoLogo -ExecutionPolicy Bypass -File scripts/prepare_release_deps.ps1

# Run full local verification suite across Rust, DAG boundaries, FFI parity, and Flutter
verify-all: fmt-check rust-check rust-lint rust-dag ffi-check rust-test flutter-analyze flutter-test

# Build Release `core_ffi.dll` and assemble verified Windows x64 Release bundle (skips re-downloading vendor deps)
release-win:
    cargo build --release -p core-ffi
    powershell.exe -NoLogo -ExecutionPolicy Bypass -File scripts/build_release.ps1 -SkipPrepareDeps
