# E2E Test Infra: Lumina Audio (R1–R3 Expansion: F33–F50)

## Test Philosophy
- Opaque-box, requirement-driven verification derived from `orchestrator_r1/DISPATCH.md` (R1–R4), `docs/ARCHITECTURE.md`, and `PROJECT.md § Feature Inventory` & `§ Interface Contracts`, with zero coupling to internal Rust/Dart module structure.
- **Baseline Preservation**: All **368 baseline E2E tests** (`test_tier1_features.py`, `test_tier2_boundaries.py`, `test_tier3_pairwise.py`, `test_tier4_scenarios.py`) and existing `tests/e2e/fixtures/__init__.py` exports remain untouched and must pass 100%.
- **Zero Fakes / Zero Skips**: Every test in Tiers 1–4 executes genuinely against real compiled artifacts (`target/debug/core_ffi.dll`, `core-server` Axum HTTP/WS/mDNS, `cargo`, `flutter`) and real loopback local mock servers (`127.0.0.1:0`). No `@unittest.skip` padding or Python-only re-implementations for R1–R3 targets.
- **Methodology**: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World Application Workload Testing.

## Feature Inventory (F33–F50)
| # | Feature | Source (requirement) | Tier 1 | Tier 2 | Tier 3 |
|---|---------|---------------------|:------:|:------:|:------:|
| F33 | Workspace Clippy Hygiene | R4 (`cargo clippy --workspace --all-targets --no-deps -- -D warnings`) | 5 | 5 | ✓ |
| F34 | Live Provider Transports (Qobuz/Tidal/Deezer/WebDAV/SMB) | R1, R4 | 5 | 5 | ✓ |
| F35 | HTTP Stream Playback (`ProviderManager` → `AudioPlayer`) | R1 | 5 | 5 | ✓ |
| F36 | ReplayGain Tag Extraction & Runtime DSP Wiring | R1 | 5 | 5 | ✓ |
| F37 | Canonical Album Cross-Source Deduplication & Merging | R1 | 5 | 5 | ✓ |
| F38 | MusicBrainz & Discogs Credit Enrichment | R1, R4 | 5 | 5 | ✓ |
| F39 | Profiles CRUD & Switching over REST & FFI | R1 | 5 | 5 | ✓ |
| F40 | Audio Output Device Enumeration & Selection | R1, R4 | 5 | 5 | ✓ |
| F41 | Flutter Navigation Shell, Album Grid, Versions & Credits Graph UI | R1 | 5 | 5 | ✓ |
| F42 | Flutter DSP, Output, Provider, Pairing & Profiles UI | R1 | 5 | 5 | ✓ |
| F43 | Phase 3 `ServerAudioService` & WebSocket Remote Sync | R2 | 5 | 5 | ✓ |
| F44 | Phase 3 LAN mDNS Client & PIN/QR Pairing Client | R2, R4 | 5 | 5 | ✓ |
| F45 | Phase 3 WAN HTTPS/WSS & Mobile Local / USB DAC Mode | R2, R4 | 5 | 5 | ✓ |
| F46 | Phase 4 Zone Abstraction & Persistence | R3 | 5 | 5 | ✓ |
| F47 | Phase 4 DLNA/UPnP Output Target | R3, R4 | 5 | 5 | ✓ |
| F48 | Phase 4 AirPlay Output Target | R3, R4 | 5 | 5 | ✓ |
| F49 | Phase 4 Multi-Room Clock Sync & UI | R3, R4 | 5 | 5 | ✓ |
| F50 | Expanded E2E Suite & Final Verification | R4 | 5 | 5 | ✓ |

## Test Architecture
- **Test Runner**: `tests/e2e/runner.py`
  - Preserves CLI: `python tests/e2e/runner.py --tier {1,2,3,4,all} [--verbose] [--report PATH]`
  - Adds `--suite {auto,baseline,harness,r1,r2,r3,r1_r3,full}` (default `auto`), `--strict` (exit non-zero on any skipped test), and `--list` (enumerate discovered tests without executing).
  - In `--suite auto` (default for `--tier all`):
    - Always runs the 368 baseline tests + the live M6/mock-server harness tests (`test_tier*_live_harness.py`) that exercise already-built `core_ffi.dll`, `core-server`, and loopback mock servers with 0 skips and 100% pass rate.
    - Automatically activates `test_tier*_r1_r3.py` when M7–M10 are marked `DONE` in `PROJECT.md` or when `LUMINA_E2E_FULL=1` is set (and individual milestone suites can always be invoked directly via `--suite r1|r2|r3|r1_r3|full`).
  - Report output: `tests/e2e/reports/e2e_results.json` preserving exact schema (`timestamp`, `tier`, `total`, `passed`, `failed`, `errors`, `skipped`, `pass_rate`, `duration_seconds`, `tests`).
- **Shared Harnesses & Local Mock Servers (`tests/e2e/fixtures/`)**:
  - `net_helpers.py`: Ephemeral port allocator (`127.0.0.1:0`), isolated `TempDir` lifecycle, tagged WAV/FLAC/DSF fixture generators (`soundfile` + Vorbis/ID3v2 ReplayGain tags), TCP/HTTP readiness polling.
  - `ffi_harness.py`: `ctypes` wrapper for `target/debug/core_ffi.dll` covering existing 28 C-ABI symbols and M7–M10 C-ABI contracts (`lumina_profile_*`, `lumina_audio_*`, `lumina_dsp_*`, `lumina_library_*`, `lumina_provider_*`, `lumina_zone_*`), safe string/byte freeing, and isolated subprocess execution to prevent global engine singleton leakage across tests.
  - `mock_servers.py`: Real local network mock servers bound to `127.0.0.1:0`:
    1. **Streaming & Range Audio HTTP Mock** (Qobuz API `/track/getFileUrl`, `/album/get`, Tidal OAuth2 PKCE `/oauth2/token` + `/v1/tracks/{id}/stream`, Deezer API + ARL validation, HTTP `206 Partial Content` range-serving FLAC/WAV audio).
    2. **WebDAV Mock Server** (`PROPFIND` XML multistatus directory listing + `GET`/`Range` audio retrieval + Basic auth).
    3. **SMB / UNC Loopback Fixture** (local share directory / UNC path helper + auth credential validation).
    4. **MusicBrainz & Discogs JSON API Mocks** (release-group, recordings, artist credits, discography + configurable HTTP `429 Retry-After` / `503` rate-limit injection).
    5. **WAN HTTPS/WSS TLS Reverse-Proxy Mock** (`ssl` + `cryptography` ephemeral self-signed X.509 cert forwarding REST + WSS frames to local `core-server`).
    6. **DLNA/UPnP MediaRenderer Mock** (UDP SSDP `M-SEARCH` responder + HTTP Device Description XML + `AVTransport`/`RenderingControl` SCPD & SOAP `SetAVTransportURI`, `Play`, `Pause`, `Stop`, `Seek`, `SetVolume`, `GetPositionInfo`).
    7. **AirPlay (`_raop._tcp` / `_airplay._tcp`) Mock** (RTSP TCP server handling `OPTIONS`, `ANNOUNCE`, `SETUP`, `RECORD`, `SET_PARAMETER`, `TEARDOWN` + UDP/TCP RTP audio packet sink & header verification).
    8. **Multi-Room SNTP Clock Sync & mDNS Loopback Mock** (UDP 4-timestamp `t1,t2,t3,t4` ping-pong responder with configurable simulated clock offset & drift rate, plus RFC 6762/6763 `_lumina._tcp.local.` DNS-SD packet responder/parser).
- **Test Case Format & Directory Layout**:
  - `tests/e2e/test_tier{1..4}_features/boundaries/pairwise/scenarios.py` — **[UNTOUCHED]** 368 baseline tests
  - `tests/e2e/test_tier{1..4}_live_harness.py` — Live M6 `core_ffi.dll` + `core-server` + local mock-server protocol E2E tests (active immediately in `--tier all`)
  - `tests/e2e/test_tier{1..4}_r1_r3.py` — Full R1–R3 E2E suite covering Features F33–F50 across Tiers 1–4

## Real-World Application Scenarios (Tier 4 — R1–R3)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| S17 | Cross-Source Library Ingest, Deduplication & Credit Graph Enrichment | F34, F37, F38 | High |
| S18 | Range-Buffered HTTP FLAC Streaming with ReplayGain & 10-Band PEQ/Crossfeed | F34, F35, F36, F40 | High |
| S19 | Multi-Profile Switching with Independent Favorites, History & Signal Path | F39, F40, F41, F42 | Medium |
| S20 | Desktop Flutter UI End-to-End Verification (Shell, Versions, Credits, DSP, Providers, Profiles) | F33, F41, F42 | High |
| S21 | Mobile Remote Dual-Mode: mDNS Discovery → PIN/QR Pair → WS Control & Live Sync | F43, F44 | High |
| S22 | Mobile WAN HTTPS/WSS Direct Connect + Local / Virtual USB DAC Fallback Mode | F43, F45 | High |
| S23 | DLNA/UPnP Discovery, Media Proxy Streaming & Transport/Volume Control | F46, F47 | High |
| S24 | AirPlay RTSP/RTP Discovery, Streaming, Volume & Teardown Lifecycle | F46, F48 | High |
| S25 | Multi-Room Zone Grouping with Simulated Clock Drift & Synchronized Start | F46, F49 | High |
| S26 | Full Release Gate: Workspace Clippy + Cargo Test + Flutter Analyze/Test + Full E2E Suite | F33, F50 | High |

## Coverage Thresholds
- **Baseline**: 368 / 368 tests preserved (100% pass).
- **Tier 1 (R1–R3)**: ≥5 isolated happy-path tests per feature × 18 features (F33–F50) = **≥90 tests**.
- **Tier 2 (R1–R3)**: ≥5 boundary/corner/negative tests per feature × 18 features (F33–F50) = **≥90 tests**.
- **Tier 3 (R1–R3)**: **≥20 pairwise tests** covering critical R1–R3 feature interactions (shared DB, audio DSP/stream pipeline, WS/REST auth, zone/clock sync).
- **Tier 4 (R1–R3)**: **10 realistic end-to-end application scenarios** (exceeds `max(5, 18 // 2) = 9`).
- **Minimum Total Expanded R1–R3 Coverage**: ≥210 new R1–R3 tests (+ live harness tests + 368 baseline = **~600+ total E2E tests**).
