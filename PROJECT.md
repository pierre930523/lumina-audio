# Project: Lumina Audio

## Architecture
- **Rust Core Workspace**:
  - `core-types`: Foundational domain types, audio format descriptors, signal path structures, canonical library entities.
  - `core-db`: SQLite WAL connection pool (max 8 connections), relational schema for music library, FTS5 full-text search (`search_fts`), OS Keyring secret isolation.
  - `core-audio`: Symphonia demuxing/decoding (PCM), custom DSD parser (DSF/DSDIFF), 64-bit float DSP (PEQ, Crossfeed, ReplayGain, Bypass), hardware backends (Windows ASIO, WASAPI Exclusive), lock-free SPSC ring buffer, real-time Signal Path classifier.
  - `core-providers`: Unified `MusicProvider` trait, Local file scanner, SMB/WebDAV share scanner, Qobuz provider (supporting direct `user_auth_token`), Tidal PKCE, Deezer ARL.
  - `core-server`: Axum HTTP REST + WebSocket server, mDNS discovery (`_lumina._tcp.local.`), one-time 6-digit PIN / QR pairing with Bearer tokens.
  - `core-ffi`: C/Dart native bridge compiled as `cdylib`/`staticlib`/`rlib` for `flutter_rust_bridge`.
- **Flutter Application (`app/`)**:
  - Flutter Desktop & Mobile with Impeller rendering backend.
  - Custom GLSL Fragment Shaders: `liquid_glass.frag` (SDF rounded box, edge lens refraction, specular rim), `mesh_fluid_bg.frag` (4-point dynamic fluid mesh gradient).
  - Apple Music-inspired floating capsule mini-player, word-by-word synchronized lyrics with depth-of-field blur, Signal Path inspection modal.

## Code Layout
- Rust Core Workspace Root: `c:\Users\pierre\.gemini\antigravity\scratch\lumina-audio\Cargo.toml`
  - Crates: `crates/core-types/`, `crates/core-db/`, `crates/core-providers/`, `crates/core-audio/`, `crates/core-server/`, `crates/core-ffi/`
- Flutter Application: `c:\Users\pierre\.gemini\antigravity\scratch\lumina-audio\app/`
  - Shaders: `app/shaders/liquid_glass.frag`, `app/shaders/mesh_fluid_bg.frag`
  - Dart Source: `app/lib/`
  - Tests: `app/test/`
- Documentation & Progress: `docs/ARCHITECTURE.md`, `docs/PROGRESS.md`, `README.md`

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Rust & C++ Toolchain Setup | Install Rustup (stable MSVC, 2024 edition), MSVC/BuildTools, CMake, Ninja, LLVM. | M1 | Survey |
| 2 | Flutter & Android SDK Setup | Install Flutter SDK, link Android SDK & JBR JDK, configure env paths. | M1 | Survey |
| 3 | Flutter App Scaffolding | Initialize Flutter multi-platform project in `app/`, preserving shaders. | M1 | Survey |
| 4 | Toolchain Verification | Verify `cargo check`, `cargo test`, `flutter doctor`, `flutter analyze`, `flutter test`. | M1 | Survey |
| 5 | Quota Monitoring Integration | Operationalize `inspect_antigravity.py` and document progress handoff routine. | M1 | Survey |
| 6 | `ProviderKind` Enumeration | Canonical identifiers for local, smb, web_dav, qobuz, tidal, deezer. | M2 | Survey |
| 7 | `QobuzAuthMode` Structure | Dual-mode Qobuz auth supporting `user_auth_token` or credentials. | M2 | Survey |
| 8 | Audio Format & Codec Models | AudioCodec and AudioFormat structs with sample rate, bit depth, channels, is_dsd. | M2 | Survey |
| 9 | Canonical Album Merging Models | CanonicalAlbum and AlbumVersion structs across sources. | M2 | Survey |
| 10 | Track Source Abstraction | Uniform track representation across local files and streaming providers. | M2 | Survey |
| 11 | SQLite WAL Pool & Migrations | Concurrency-optimized SQLite connection pool applying `0001_init.sql`. | M2 | Survey |
| 12 | Relational Library Repositories | CRUD data access layer for albums, versions, tracks, artists, credits. | M2 | Survey |
| 13 | FTS5 Full-Text Search Engine | FTS5 virtual table queries with unicode61 tokenizer and input sanitization. | M2 | Survey |
| 14 | OS Keyring Credential Storage | Separation of sensitive auth secrets into OS Keyring / Credential Manager. | M2 | Survey |
| 15 | Symphonia PCM Audio Demuxing | Demuxing and decoding for FLAC, ALAC, WAV, AIFF, AAC, MP3, Opus. | M3 | Survey |
| 16 | DSD Bitstream Parser | DSF/DSDIFF parsing supporting Native ASIO DSD, DoP framing, and PCM fallback. | M3 | Survey |
| 17 | 64-bit Parametric EQ (PEQ) | High-precision 64-bit float PEQ filters with AutoEQ support. | M3 | Survey |
| 18 | Headphone Crossfeed Filter | Acoustic binaural crossfeed simulating speaker soundstage. | M3 | Survey |
| 19 | ReplayGain & Peak Limiter | Track/album gain normalization with headroom protection. | M3 | Survey |
| 20 | DSP One-Click Bypass | Instant zero-cost bypass preserving pure bit-perfect playback. | M3 | Survey |
| 21 | Bit-Perfect Hardware Backends | Windows ASIO and WASAPI Exclusive hardware output backends. | M3 | Survey |
| 22 | Transparent Signal Path Engine | Real-time quality classification (`Lossless` purple, `Enhanced` green, `HighQuality` yellow). | M3 | Survey |
| 23 | Lock-Free Audio Buffer | SPSC ring buffer isolating decoding from real-time audio thread. | M3 | Survey |
| 24 | Unified `MusicProvider` Trait | Async trait for capabilities, authentication, catalog search, stream resolution. | M4 | Survey |
| 25 | Local Filesystem Scanner | Recursive directory scanner extracting audio metadata and tags. | M4 | Survey |
| 26 | SMB / WebDAV Remote Scanner | Network share file tag ingestion and streaming resolver. | M4 | Survey |
| 27 | Qobuz Direct Token Provider | Qobuz streaming integration supporting direct `user_auth_token` login. | M4 | Survey |
| 28 | Tidal & Deezer Provider Stubs | OAuth2 PKCE Tidal and ARL Deezer provider integration interfaces. | M4 | Survey |
| 29 | Axum HTTP & WebSocket Server | Core server exposing playback control, library search, and state broadcast. | M5 | Survey |
| 30 | mDNS LAN Service Discovery | Automatic zero-config discovery broadcasting `_lumina._tcp.local.`. | M5 | Survey |
| 31 | One-Time PIN / QR Pairing | 6-digit mutual pairing generating authenticated Bearer tokens. | M5 | Survey |
| 32 | Flutter FFI Bridge & Shaders UI | `core-ffi` bridge, Impeller shaders, floating capsule mini-player, and Signal Path modal. | M5 | Survey |
| 33 | Workspace Clippy Hygiene | Resolve 13 pre-existing clippy warnings across `core-types`, `core-db`, and `core-providers` so `--workspace --all-targets --no-deps -- -D warnings` passes cleanly. | M7 | Survey |
| 34 | Live Provider Transports (Qobuz/Tidal/Deezer/WebDAV/SMB) | `reqwest` HTTP transport, Tidal OAuth2 PKCE, Deezer ARL, WebDAV `PROPFIND`, and trait-abstracted SMB client. | M7 | Survey |
| 35 | HTTP Stream Playback (`ProviderManager` → `AudioPlayer`) | Range-buffered HTTP `MediaSource` for Symphonia/DSD, `AudioPlayer::play_stream`, `ProviderManager` wired into `AppState` & `EngineState`. | M7 | Survey |
| 36 | ReplayGain Tag Extraction & Runtime DSP Wiring | Extract ReplayGain tags in `MetadataExtractor`, persist in `core-db`, wire runtime 10-band PEQ / AutoEQ / Crossfeed / ReplayGain in `AudioPlayer` & `SignalPath`. | M7 | Survey |
| 37 | Canonical Album Cross-Source Deduplication & Merging | Match & merge albums across Local/SMB/WebDAV/Qobuz/Tidal/Deezer via normalized title+artist, UPC, MBID, and ISRC; expose album detail + versions REST/FFI APIs. | M7 | Survey |
| 38 | MusicBrainz & Discogs Credit Enrichment | Rate-limited MusicBrainz & Discogs HTTP clients, credit enrichment pipeline populating `artists` & `album_credits`, REST/FFI endpoints for artist & credits graph. | M7 | Survey |
| 39 | Profiles CRUD & Switching over REST & FFI | Active profile tracking in `AppState` & `EngineState`, REST `/api/v1/profiles*`, `/favorites*`, `/history*`, and FFI `lumina_profile_*` exports. | M7 | Survey |
| 40 | Audio Output Device Enumeration & Selection | Real `cpal` / WASAPI / ASIO device listing & target switching in `AudioPlayer`, plus REST `/api/v1/audio/devices*`, `/api/v1/dsp*`, and FFI `lumina_audio_*`, `lumina_dsp_*`, `lumina_server_*`. | M7 | Survey |
| 41 | Flutter Navigation Shell, Album Grid, Versions & Credits Graph UI | Responsive Liquid Glass navigation shell, Album grid, Canonical Album detail with `Versions` switcher, Artist & `Credits` graph view, real lyrics & cover art. | M8 | Survey |
| 42 | Flutter DSP, Output, Provider, Pairing & Profiles UI | 10-band PEQ/AutoEQ/Crossfeed/ReplayGain DSP panel, Output/Zone selector, Provider login/config (Qobuz/Tidal PKCE/Deezer/SMB/WebDAV), Host PIN/QR pairing UI, `Profiles` switcher. | M8 | Survey |
| 43 | Phase 3 `ServerAudioService` & WebSocket Remote Sync | Authenticated `/api/v1/ws` wired to `AudioPlayer` + initial snapshot + periodic ticker + DB token reload; Flutter `ServerAudioService` REST/WS client. | M9 | Survey |
| 44 | Phase 3 LAN mDNS Client & PIN/QR Pairing Client | Flutter `MdnsDiscoveryClient` (`_lumina._tcp.local.`), PIN/QR pairing client handshake (`lumina://pair...`), secure token persistence, server picker UI. | M9 | Survey |
| 45 | Phase 3 WAN HTTPS/WSS & Mobile Local / USB DAC Mode | Server `/api/v1/health` & `/info` + TLS/reverse-proxy readiness; Flutter WAN HTTPS/WSS direct connect, dual-mode switcher, mobile local & virtual/Android/iOS USB DAC mode + OS manifests. | M9 | Survey |
| 46 | Phase 4 Zone Abstraction & Persistence | `ZoneManager`, per-zone routing, zone grouping, SQLite persistence, REST `/api/v1/zones*`, FFI & UI hooks. | M10 | Survey |
| 47 | Phase 4 DLNA/UPnP Output Target | SSDP `M-SEARCH` discovery, UPnP Device/SCPD XML parsing, `AVTransport`/`RenderingControl` SOAP control, HTTP media proxy, mock DLNA server verification. | M10 | Survey |
| 48 | Phase 4 AirPlay Output Target | `_raop._tcp`/`_airplay._tcp` mDNS discovery, RTSP (`ANNOUNCE`/`SETUP`/`RECORD`/`SET_PARAMETER`/`TEARDOWN`) + ALAC/PCM RTP streamer, mock AirPlay server verification. | M10 | Survey |
| 49 | Phase 4 Multi-Room Clock Sync & UI | 4-timestamp NTP-like clock offset/RTT/drift estimator, `start_at_master_pts_us` aligned playback & drift compensation, Zone grouping & sync status UI. | M10 | Survey |
| 50 | Expanded E2E Suite & Final Verification | Preserve 368 baseline E2E tests + add real-integration Tiers 1–4 E2E coverage for F33–F49 + Tier 5 adversarial coverage hardening + checkpoint `docs/PROGRESS.md` & `HANDOFF.md`. | M11 | Survey |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Dev Environment & Toolchains | Toolchain installations (Rust, MSVC/LLVM, Flutter SDK, Android SDK config), App project scaffolding, Verification of cargo check/test & flutter doctor/analyze/test | none | DONE |
| M2 | Domain Core & SQLite Persistence | `core-types` validation & contracts, `core-db` SQLite WAL pool, relational repositories, FTS5 search, OS Keyring abstraction | M1 | DONE |
| M3 | Hi-Fi Audio Engine, DSP & Signal Path | `core-audio` Symphonia PCM decoding, DSD DSF parsing, 64-bit DSP (PEQ, Crossfeed, ReplayGain, Bypass), WASAPI/ASIO backends, SPSC ring buffer, Signal Path | M2 | DONE |
| M4 | Music Providers & Streaming Sources | `core-providers` unified trait, Local scanner, SMB/WebDAV, Qobuz direct token auth & stream resolution, Tidal/Deezer interfaces | M2 | DONE |
| M5 | Core Server, FFI & Flutter App UI | `core-server` Axum REST & WebSocket, mDNS, PIN pairing; `core-ffi` bridge; Flutter desktop app with Impeller shaders, mini-player, Signal Path popover | M3, M4 | DONE |
| M6 | E2E Integration & Roadmap Handoff | Full E2E suite validation (Tiers 1-4), adversarial test hardening, comprehensive `docs/PROGRESS.md` update | M5 | DONE |
| M7 | R1 Rust Core, Providers, Enrichment, Profiles & Devices | Clippy cleanup (F33), live HTTP/WebDAV/SMB transports (F34), HTTP stream playback in `AudioPlayer` (F35), ReplayGain tags & runtime DSP wiring (F36), Canonical Album cross-source dedup (F37), MusicBrainz/Discogs enrichment (F38), Profiles REST/FFI (F39), Output device enum/selection & DSP REST/FFI (F40) | M6 | DONE |
| M8 | R1 Flutter Desktop UI & FFI Bindings | Bind all FFI exports, Liquid Glass navigation shell, Album grid + Canonical Album `Versions` switcher, Artist & `Credits` graph (F41); DSP panel (10-band PEQ/AutoEQ/Crossfeed/ReplayGain), Output/Zone selector, Provider login/config, Host PIN/QR pairing UI, `Profiles` switcher (F42) | M7 | DONE |
| M9 | Phase 3 Mobile / Remote Dual-Mode | Authenticated WS remote control & initial snapshot/ticker, `load_tokens_from_db()` (F43); Flutter LAN mDNS discovery + PIN/QR pairing client + `ServerAudioService` (F44); WAN HTTPS/WSS direct connect + mobile local/USB DAC playback mode & OS manifests (F45) | M7, M8 | DONE |
| M10 | Phase 4 Output Targets & Multi-Room Sync | `ZoneManager` (F46), DLNA/UPnP SSDP/SOAP + HTTP proxy (F47), AirPlay RTSP/RTP (F48), Multi-room clock offset/drift sync + Zone grouping & sync UI (F49) | M7, M8 | DONE |
| M11 | Final Milestone: Full E2E Tiers 1–4 & Tier 5 Adversarial | Phase 1: pass 100% E2E suite (368 baseline + new R1–R3 Tiers 1–4) + workspace clippy/tests/flutter checks; Phase 2: Tier 5 adversarial coverage hardening; checkpoint `docs/PROGRESS.md` & `HANDOFF.md` (F50) | M7, M8, M9, M10, E2E Track | DONE |

## Interface Contracts
### `core-types` ↔ All Downstream Crates
- `ProviderKind`: Enum serialized to snake_case (`local`, `smb`, `web_dav`, `qobuz`, `tidal`, `deezer`).
- `AudioFormat`: `{ codec: AudioCodec, sample_rate_hz: u32, bit_depth: u16, channels: u16, is_dsd: bool }`.
- `SignalQuality`: Enum `{ Lossless, Enhanced, HighQuality }`.
- `SignalPath`: Struct containing `overall_quality: SignalQuality`, `nodes: Vec<SignalPathNode>`.
- `CanonicalAlbum`: Struct with `id: Uuid`, `title: String`, `artist: String`, `versions: Vec<AlbumVersion>`.

### `core-db` ↔ `core-server` / `core-providers`
- `open_database(path: &Path) -> Result<SqlitePool>`: Initializes WAL mode with foreign keys and applies migrations.
- `search_library(pool: &SqlitePool, query: &str) -> Result<Vec<SearchResult>>`: Sanitizes input and queries `search_fts`.

### `core-providers` ↔ `core-audio`
- `resolve_stream(track: &TrackSource) -> Result<ResolvedStream>`: Returns direct file path or HTTP stream URL with authorization headers.

### `core-audio` ↔ `core-ffi` / `core-server`
- `build_signal_path(source_format: &AudioFormat, dsp: &DspPipelineConfig, target_rate: u32, backend: OutputBackendKind) -> SignalPath`: Returns transparent quality node graph.
- `AudioPlayer::play_stream(stream: StreamSource, source_label: &str) -> Result<()>` (accepts local files or HTTP/HTTPS range-buffered streams with custom auth headers).
- `AudioPlayer::list_output_devices() -> Vec<AudioDeviceDescription>`, `select_output_device(device_id: &str, backend: OutputBackendKind) -> Result<()>`.
- `AudioPlayer::set_dsp_config(config: DspPipelineConfig) -> Result<()>` (updates 10-band PEQ / AutoEQ, Crossfeed, ReplayGain mode/preamp, bypass at runtime).

### `core-server` REST & WebSocket API Contracts (R1–R3)
- **Auth & Health**: `GET /api/v1/health`, `GET /api/v1/info`, `POST /api/v1/pair/initiate`, `POST /api/v1/pair/verify` (returns Bearer `lum_sec_*` token), `GET /api/v1/ws` (requires Bearer token via `Authorization` header or `?token=`).
- **Library, Canonical Albums & Credits**: `GET /api/v1/library/albums`, `GET /api/v1/library/albums/:id` (with `versions` & tracks), `GET /api/v1/library/albums/:id/credits`, `GET /api/v1/library/artists/:id`, `POST /api/v1/library/enrich` (MusicBrainz/Discogs enrichment), `POST /api/v1/library/deduplicate`.
- **Profiles**: `GET/POST /api/v1/profiles`, `PUT/DELETE /api/v1/profiles/:id`, `POST /api/v1/profiles/:id/activate`, `GET/POST/DELETE /api/v1/profiles/:id/favorites`, `GET /api/v1/profiles/:id/history`.
- **Providers**: `GET /api/v1/providers`, `POST /api/v1/providers/qobuz`, `POST /api/v1/providers/tidal/pkce/start`, `POST /api/v1/providers/tidal/pkce/exchange`, `POST /api/v1/providers/deezer`, `POST /api/v1/providers/webdav`, `POST /api/v1/providers/smb`, `POST /api/v1/providers/:kind/sync`.
- **Playback, DSP & Zones**: `GET /api/v1/playback/state`, `POST /api/v1/playback/{play,pause,stop,seek,next,previous,volume}`, `GET/PUT /api/v1/dsp/config`, `POST /api/v1/dsp/autoeq`, `GET /api/v1/signal-path`, `GET /api/v1/audio/devices`, `POST /api/v1/audio/devices/select`, `GET/POST /api/v1/zones`, `POST /api/v1/zones/discover`, `POST /api/v1/zones/group`, `POST /api/v1/zones/:id/sync`.

### `core-ffi` ↔ `app/` C-ABI Contracts
- Existing exports + `lumina_server_{start,stop,get_port}`, `lumina_last_error_message`, `lumina_library_{get_albums,get_album_detail,get_artist_detail,enrich_credits,deduplicate}`, `lumina_profile_{list,create,update,delete,switch,get_active}`, `lumina_audio_{list_devices,select_device}`, `lumina_dsp_{get_config,set_config,import_autoeq}`, `lumina_provider_{configure,sync,tidal_pkce_start,tidal_pkce_complete}`, `lumina_zone_{list,discover,group,set_volume,sync_status}`.
