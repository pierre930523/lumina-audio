# AGENTS.md — Lumina Audio

## 1. 專案概覽與技術棧

- **專案目標**：跨平台發燒級無損音樂播放器，支援本地 Hi-Res/DSD、NAS（SMB/WebDAV）、多串流平台、64-bit DSP、Bit-Perfect 硬體輸出與遠端/多房間串流。
- **Rust Core Workspace**（Edition 2024，`Cargo.toml` v0.2.1）：
  - `core-types`：純領域型別、音訊格式、Signal Path 與串流規格契約。
  - `core-db`：SQLite WAL 連線池（上限 8 連線）、Migration、FTS5 全文檢索與 OS Keyring 憑證隔離。
  - `core-providers`：統一 `MusicProvider` / `StreamResolver`、Local/SMB/WebDAV 掃描、Qobuz/Tidal/Deezer 與 MusicBrainz/Discogs 豐富化。
  - `core-audio`：Symphonia PCM/DSD 解碼、64-bit DSP（10 段 PEQ/AutoEQ/Crossfeed/ReplayGain）、SPSC Ring Buffer、WASAPI/ASIO 與雙軌串流代理。
  - `core-server`：Axum HTTP REST + WebSocket、mDNS（`_lumina._tcp.local.`）、PIN/QR 配對、DLNA/AirPlay 與多房間時鐘同步。
  - `core-ffi`：C-ABI 原生橋接層（`cdylib` / `staticlib` / `rlib`），產出 `core_ffi.dll`。
- **核心相依**：
  - 非同步與網路：`tokio`（full）、`reqwest`（rustls + http2 + stream）、`futures-util`、`quick-xml`。
  - 資料與音訊：`sqlx`（SQLite WAL + FTS5）、`opus2`（bundled/static）、`serde`/`serde_json`、`image`、`blowfish`/`cbc`/`sha2`。
- **Flutter App**（`app/pubspec.yaml` v0.2.5+7，Dart SDK `^3.14.0`）：
  - `material_ui`、`ffi: ^2.2.0`、`crypto`、`flutter_lints: ^6.0.0`。
  - Impeller 算繪引擎 + 自訂 GLSL Fragment Shaders（`liquid_glass.frag`、`mesh_fluid_bg.frag`）。
- **執行與測試環境**：
  - 主力桌面目標為 Windows x64（MSVC BuildTools + LLVM + ASIO/WASAPI Exclusive），另支援 Android / iOS / macOS / Linux。
  - Release 內附工具：`app/windows/vendor/bin/{yt-dlp.exe, deno.exe, ffmpeg.exe}`（見 `installer/lumina_setup.nsi`）。
  - E2E 驗收測試：Python 3.11+（`tests/e2e/runner.py`）驅動實機編譯產物與本機 Loopback Mock Server。

---

## 2. 常用指令

- **安裝 / 還原相依**：
  - `cargo fetch`（預載 Rust Workspace 相依）
  - `cd app; flutter pub get`（安裝 Flutter 套件）
- **開發啟動**：
  - `cargo build -p core-ffi`（編譯 Debug 版 `target/debug/core_ffi.dll` 供 Flutter 與 E2E 載入）
  - `cd app; flutter run -d windows`（啟動 Windows 桌面端）
  - `cargo test -p core-ffi`（快速驗證 C-ABI 橋接層與全域引擎行為）
- **建置（Release）**：
  - `cargo build --release -p core-ffi`（編譯 `target/release/core_ffi.dll`）
  - `.\scripts\build_release.ps1`（執行依賴準備、驗證 vendor binaries、建置 `core_ffi.dll` 與 `flutter build windows --release`）
  - `.\scripts\build_release.ps1 -SkipPrepareDeps`（略過重新下載外部執行檔，快速重編 Release）
  - `.\scripts\prepare_release_deps.ps1`（單獨下載/更新 `yt-dlp.exe`、`deno.exe`、`ffmpeg.exe` 與授權檔）
- **測試（Workspace / 單檔 / E2E）**：
  - `cargo test --workspace`（執行全部 Rust 單元與整合測試）
  - `cargo test -p <crate>`（單獨測試指定 crate，如 `core-audio`、`core-db`、`core-ffi`）
  - `cargo test -p core-audio --test <檔名>`（單檔整合測試，例：`player_tests`、`streaming_phase4_tests`）
  - `cd app; flutter test`（執行全部 Dart 測試）
  - `cd app; flutter test test/<路徑>_test.dart`（單檔 Dart 測試，例：`test/services/streaming/streaming_phase4_test.dart`）
  - `.\run_e2e_tests.ps1 -Tier 1 -Suite engine`（PowerShell 統一 E2E 入口，支援 `-Tier all|1|2|3|4`、`-Suite all|engine|flutter`）
  - `python tests/e2e/runner.py --tier all --suite auto --strict`（Python E2E 驗收，支援 `--suite baseline|harness|r1|r2|r3|r1_r3|full`）
- **Lint / 靜態檢查**：
  - `cargo check --workspace`（快速型別與編譯檢查）
  - `cargo clippy --workspace --all-targets --no-deps -- -D warnings`（Rust 零警告檢查）
  - `cd app; flutter analyze`（Dart 靜態分析）
  - `.\run_e2e_tests.ps1 -Tier all -Suite all`（完整 E2E 驗收矩陣）

---

## 3. 專案地圖

| 路徑 | 職責 | 關鍵匯出 / 入口點 |
|---|---|---|
| `Cargo.toml` | Rust Workspace 根設定與共用相依版本 | `members`（6 crates）、`workspace.dependencies` |
| `crates/core-types/src/lib.rs` | 跨 crate 領域型別、音訊格式與 Signal Path | `ProviderKind`、`AudioFormat`、`SignalPath`、`CanonicalAlbum` |
| `crates/core-types/src/ingestion.rs` | Layer 1 匯入層領域 DTO、掃描進度與中繼資料覆寫契約 | `ScanProgressEvent`、`WatchedRoot`、`SkippedFile`、`MetadataOverride`、`CanonicalTrack`、`TocSignature` |
| `crates/core-types/src/streaming.rs` | 多平台串流 L1/L2 快取與動態容量規格 | `StreamSourceSpec`、L2 `.head` 容量與分段型別 |
| `crates/core-db/src/lib.rs` | SQLite WAL 連線池、Migration 與 FTS5 入口 | `open_database()`、`search_library()`、`KeyringStore` |
| `crates/core-db/src/repository/library.rs` | 曲庫、版本合併、Artwork 與 Credit CRUD | `LibraryRepository`、`PruneLocalTracksReport` |
| `crates/core-db/src/repository/ingestion.rs` | 監控目錄、隔離檔案、使用者中繼資料覆寫、內容指紋與標準曲目持久層 | `IngestionRepository` |
| `crates/core-db/src/repository/l2_cache.rs` | L2 SSD 音訊頭段快取紀錄與 LRU 清理 | `L2HeadCacheRepository`、`L2HeadChunkRecord` |
| `crates/core-providers/src/lib.rs` | 音源整合總匯出與錯誤型別 | `MusicProvider`、`StreamResolver`、`ProviderError` |
| `crates/core-providers/src/manager.rs` | 多音源協調、同步與串流解析路由 | `ProviderManager` |
| `crates/core-providers/src/local/pipeline.rs` | 有界並行本地掃描、移動自動重連、隔離與跨平台目錄匯入管線 | `IngestionPipeline`、`IngestionConfig` |
| `crates/core-providers/src/local/watcher.rs` | 雙軌監控（OS 原生 notify 防抖 + NAS/UNC 輕量輪詢與離線復原） | `StorageWatcherManager` |
| `crates/core-providers/src/local/fingerprint.rs` | 與標籤無關的頭/中/尾抽樣 SHA-256 音訊內容指紋 | `compute_content_fingerprint()` |
| `crates/core-providers/src/local/ignore.rs` | 系統/NAS 忽略規則與未切分 CUE/ISO 容器分類 | `should_ignore_relative_path()`、`classify_unsupported_container()` |
| `crates/core-providers/src/local/playlist.rs` | 旁掛 `.m3u`/`.m3u8` 播放清單解析與曲目解析 | `parse_m3u_file()` |
| `crates/core-audio/src/lib.rs` | 音訊引擎、DSP、DSD、Signal Path 匯出 | `AudioDeviceManager`、`DspPipeline`、`global_tap()` |
| `crates/core-audio/src/player.rs` | 雙軌播放核心、8 狀態機與硬體輸出切換 | `AudioPlayer`、`play_stream()`、`select_output_device()` |
| `crates/core-audio/src/streaming/l2_cache.rs` | L2 SSD `.head` 讀寫與原子搬移管理 | L2 快取租約 (`L2FileLease`) 與 LRU 驅逐 |
| `crates/core-audio/src/streaming/chunked_proxy.rs` | Range 緩衝 HTTP 串流代理與 403 恢復 | `ChunkedStreamProxy` |
| `crates/core-server/src/lib.rs` | Axum HTTP/WS 伺服器與 mDNS 廣播入口 | `AppServer`、`ServerConfig` |
| `crates/core-server/src/routes/mod.rs` | REST API 路由聚合（Auth/曲庫/DSP/Zone） | `build_router()` |
| `crates/core-ffi/src/lib.rs` | C-ABI FFI 總匯出（供 Dart `dart:ffi` 呼叫） | `lumina_init()`、`lumina_version()` 與各模組 `lumina_*` |
| `crates/core-ffi/src/engine.rs` | FFI 全域單例引擎與 Tokio Runtime 管理 | `get_engine()`、`EngineState` |
| `app/pubspec.yaml` | Flutter 套件相依與 Shader 資源宣告 | `shaders/liquid_glass.frag`、`shaders/mesh_fluid_bg.frag` |
| `app/lib/main.dart` | Flutter App 進入點、ImageCache 與縮放 Scope | `main()`、`LuminaApp`、`UiScaleScope` |
| `app/lib/models/ingestion_models.dart` | Layer 1 匯入層前端 DTO（掃描進度、監控目錄、隔離檔、中繼資料覆寫與外部目錄批次） | `ScanProgressEvent`、`WatchedRoot`、`SkippedFile`、`MetadataOverride`、`ExternalCatalogIngestBatch` |
| `app/lib/models/recommendation_models.dart` | 跨平台推薦、電台與匹配領域模型 | `TrackMetadata`、`RadioPage`、`FeedSection`、`TrackMatchQuery`、`RecError` |
| `app/lib/services/audio_service.dart` | Dart 音訊服務抽象介面與狀態流契約 | `AudioService` |
| `app/lib/services/ffi_audio_service.dart` | 桌面端 `core_ffi.dll` FFI 綁定實作 | `FfiAudioService` |
| `app/lib/services/server_audio_service.dart` | 遠端/行動端 REST + WebSocket 同步客戶端 | `ServerAudioService` |
| `app/lib/services/recommendation_settings_controller.dart` | 無限接播、跨平台路由與推薦來源設定持久化 | `RecommendationSettingsController` |
| `app/lib/services/streaming/streaming_manager.dart` | 前端多平台串流帳號與曲目解析調度 | `StreamingManager` |
| `app/lib/services/streaming/streaming_playback_coordinator.dart` | 跨後端（FFI / 遠端 / Apple Music）播放協調 | `StreamingPlaybackCoordinator`、`CoordinatingAudioService` |
| `app/lib/services/streaming/recommendation_provider.dart` | 統一串流/外部推薦與曲目匹配介面 | `RecommendationProvider` |
| `app/lib/services/streaming/track_matcher.dart` | 跨平台 ISRC / 標題正規化、相似度評分與音質排序 | `TrackMatcher` |
| `app/lib/services/streaming/autoplay_filter.dart` | 50 首 3 層指紋去重、3 首藝人冷卻、變體過濾與有效種子池 | `AutoplayFilter`、`RecentHistoryWindow`、`EffectiveSeedPool` |
| `app/lib/services/streaming/external_recommendation_providers.dart` | Last.fm、免金鑰 ListenBrainz 推薦與本地無損曲庫匹配 | `LastFmRecommendationProvider`、`ListenBrainzRecommendationProvider`、`LocalLibraryTrackMatcher` |
| `app/lib/services/streaming/cross_platform_track_router.dart` | 依優先順序跨平台高音質路由與 401 斷路器跳過 | `CrossPlatformTrackRouter` |
| `app/lib/services/streaming/autoplay_controller.dart` | 雙軌待播／自動推薦佇列、背景補充與失敗處理核心 | `AutoplayController` |
| `app/lib/ui/common/ambient_dynamic_background.dart` | 全視窗共享動態封面模糊、流體漸層與微粒雜訊背景層 | `AmbientDynamicBackground` |
| `app/lib/ui/common/frosted_glass_container.dart` | 條件式毛玻璃容器與膠囊/圓角方形控制按鈕 | `FrostedGlassContainer`、`FrostedGlassIconButton` |
| `app/lib/ui/home_screen.dart` | Liquid Glass 導覽殼層與主要視圖路由容器 | `HomeScreen` |
| `tests/e2e/runner.py` | 統一 E2E 驗收測試執行器與報表產生器 | CLI `--tier`、`--suite`、`--strict` |

---

## 4. 核心資料流與架構邊界

- **桌面端本地資料流**：
  - `Flutter UI` → `AudioService` (`FfiAudioService`) → `dart:ffi` → `core-ffi` (`EngineState`) → `core-audio` (`AudioPlayer` / `DspPipeline`) → `WASAPI Exclusive` / `ASIO` / `MockBackend`。
  - 曲庫索引、L1/L2 快取與 Profile 狀態經 `core-db`（SQLite WAL + FTS5）持久化。
- **遠端 / 行動端與多房間資料流**：
  - `Flutter UI` → `ServerAudioService`（REST + `/api/v1/ws` Bearer Token `lum_sec_*`）→ `core-server`（Axum + `AppState` + mDNS `_lumina._tcp.local.`）→ 共用 `core-audio` / `core-db` / `core-providers`。
  - 跨區輸出由 `core-server::zones`（`ZoneManager` + DLNA SSDP/SOAP + AirPlay RTSP/RTP + 4-timestamp 時鐘同步）調度。
- **串流解析與雙軌秒播流**：
  - `StreamingManager` / `ProviderManager` → 各 Provider（Local / SMB / WebDAV / Qobuz / Tidal / Deezer / YouTube Music）→ `StreamResolver` 解析 URI 與 Header → 經 `ChunkedStreamProxy` / `SegmentedProxy` 結合 `L1StreamCache` 與 `L2HeadCache`（`.head` 檔）餵入 `AudioPlayer`（Deck A / Deck B）無縫切換。
- **DSP、Signal Path 與曲庫豐富化流**：
  - `AudioPlayer` 解碼後經 `DspPipeline`（64-bit float PEQ / Crossfeed / ReplayGain / `LookaheadLimiter`，支援一鍵 Bypass）→ `build_signal_path()` 產出即時品質節點圖，同時透過 `global_tap()` 寫入 `VisualizerRingBuffer` 供 UI 頻譜使用。
  - `LibrarySyncService` 跨來源匯入曲目後，依標題/藝人/UPC/MBID/ISRC 去重合併為 `CanonicalAlbum` 與 `AlbumVersion`，再由 `enrichment`（MusicBrainz / Discogs 限流客戶端）補齊 `album_credits`。
- **架構邊界（不可越界）**：
  - `core-types` 為純領域契約層，禁止依賴 `core-db`、`core-audio`、`core-server` 或任何 UI/FFI 框架。
  - `core-db` 為唯一資料庫與憑證儲存層，其他 crate 禁止直接寫入 SQLite 檔案或繞過 `Repository` 操作資料表。
  - `core-providers` 與 `core-audio` 僅透過 `ResolvedStream` / `StreamSourceSpec` 傳遞 URI 與 Header，禁止跨層直接持有底層 HTTP/SMB 連線。
  - `core-server` 受保護端點與 `/api/v1/ws` 必須經 `middleware::auth` 驗證 Bearer Token，配對 PIN/QR 限流由 `pairing::rate_limiter` 管控。
  - 敏感串流憑證與配對 Token 必須透過 `core-db::credential`（OS Keyring / Credential Manager）隔離，禁止明文存於曲庫主表或一般設定檔。
  - `core-audio` 即時音訊執行緒透過 SPSC Ring Buffer 與解碼/網路層隔離，音訊回呼內禁止配置記憶體、鎖 Mutex 或執行同步 I/O。
  - Flutter UI 僅透過 `AudioService`、`StreamingManager` 等 Service 層互動，禁止在 Widget 內直接呼叫 `dart:ffi` 原生符號。
  - `core-ffi` 的 `extern "C"` 函式必須包裹 `catch_unwind_ffi`，嚴禁讓 Rust panic 跨越 FFI 邊界。

---

## 5. 忽略清單

- **歷史快照目錄**：`versions/`（`v1.0-baseline`、`v2.0-ixd-redesign`，非目前作用中程式碼）。
- **建置與工具快取目錄**：`target/`、`app/build/`、`app/.dart_tool/`、`app/.idea/`、`node_modules/`、`dist/`、`build/`、`.git/`、`__pycache__/`。
- **平台原生容器目錄**：`app/android/`、`app/ios/`、`app/linux/`、`app/macos/`、`app/web/`、`app/windows/`（除非明確修改平台原生設定或打包）。
- **產出報表與設計資產目錄**：`tests/e2e/reports/`、`installer/`、`docs/assets/`、`design-system/`。
- **鎖檔與編譯產物副檔名**：`*.lock`（`Cargo.lock`、`pubspec.lock`）、`*.pyc`、`*.dll`、`*.exe`、`*.lib`、`*.pdb`。
- **二進位媒體、圖檔與資料庫副檔名**：`*.svg`、`*.png`、`*.jpg`、`*.wav`、`*.flac`、`*.dsf`、`*.db`、`*.sqlite`。

---

## 6. Agent 讀寫與修改規範

1. 記憶優先：已在當前對話讀過的檔案，除非被外部修改，否則禁止整檔重讀。
2. 局部讀取：超過 200 行的檔案，優先查大綱或指定行號區間讀取，不一次讀完全文。
3. 精準修改：一律使用局部替換或 Diff 修改，禁止為了改幾行而重寫整份檔案。
4. 先計畫再動手：跨 3 個以上檔案的修改，先列修改清單確認後再執行。
5. 同步維護：新增、搬移或刪除核心檔案時，順手更新本檔第 3 節。

---

## 7. 已知坑點與慣例

- **FFI DLL 同步問題**：修改 `crates/core-*` 後若未重新執行 `cargo build -p core-ffi`（或 Release 版），`flutter run` / `ffi_harness.py` 會載入舊版 `core_ffi.dll` 導致符號缺失或行為不一致。
- **Windows 鎖檔導致編譯失敗**：`core_ffi.dll` 若被執行中的 Flutter App 或 Python 測試行程鎖住，重編會出現 `Access is denied`；需先關閉殘留行程再編譯。
- **Clippy 嚴格零警告**：CI 與驗收要求 `cargo clippy --workspace --all-targets --no-deps -- -D warnings` 通過；`core-ffi` 與 `core-providers` 頂部已有特定 `allow` 屬性，新增程式碼勿引入未處理的警告。
- **串流 IPv4 與 HTTP 403**：YouTube / Podcast 解析端與 `ChunkedStreamProxy` 下載端若 IPv4/IPv6 混用或遺失 Header 易觸發 HTTP 403；修改串流管線時須保留統一代理路徑與 `RECOVERING_403` 狀態機。
- **SQLite Migration 順序不可變**：`crates/core-db/migrations/0001_init.sql` 至 `0006_ingestion_layer.sql` 為內嵌順序遷移，禁止修改已發布的 Migration 檔，新欄位一律新增下一個編號檔案。
- **L2 快取刪除順序**：LRU 驅逐或清理 `.head` 檔時，必須先檢查 `L2FileLease` 並「先刪 SQLite 紀錄、再刪實體檔案」，避免產生孤兒索引或讀取競態。
- **L2 快取格式與對齊**：`.head` 容量依 `clamp(bitrate_bps / 8 * 8, 512KB, 4MB)` 計算；Deezer 須對齊 `6144`-byte 加密區塊，Tidal `HI_RES` DASH 儲存 `init` + 前 2 個 `.m4s` 分段（`.dash.head`）。
- **SQLite FTS5 檢索淨化**：所有全文檢索查詢一律經 `sanitize_fts5_query()` 處理，禁止將未淨化的使用者輸入直接拼入 `MATCH` 語法。
- **DSD 與 Signal Path 誠實性**：DSD 優先走 Native ASIO / DoP，僅於硬體不支援時降轉 PCM，且必須在 `SignalPath` 如實反映降轉與 DSP 節點。
- **命名與序列化慣例**：`ProviderKind` 序列化為 `snake_case`（`local`、`smb`、`web_dav`、`qobuz`、`tidal`、`deezer`）；FFI C 符號一律以 `lumina_` 為前綴並由呼叫端透過對應 free 函式釋放字串。
- **雙模式服務同步**：桌面端預設走 `FfiAudioService`，遠端/行動端走 `ServerAudioService`（REST + WS）；修改 `PlaybackState` 或曲庫模型時，兩端實作與對應測試須同步更新。
- **外部執行檔依賴**：YouTube Music / Podcast 解析與代理依賴 `yt-dlp.exe`、`deno.exe`、`ffmpeg.exe`，開發與測試須確保其位於 `PATH` 或 `app/windows/vendor/bin/`。
- **Shader 資源宣告**：自訂 GLSL Shader 位於 `app/shaders/` 並於 `app/pubspec.yaml` 宣告，變更檔名或路徑須同步更新 `app/lib/shaders/shader_loader.dart`。
- **FFI 全域單例隔離**：`core-ffi` 的 `EngineState` 為全域單例，Python E2E（`tests/e2e/fixtures/ffi_harness.py`）須透過獨立子程序執行，避免跨測試狀態污染。
- **E2E 基線保護**：`tests/e2e/test_tier{1..4}_features/boundaries/pairwise/scenarios.py` 的 368 個基線測試與 `tests/e2e/fixtures/__init__.py` 匯出介面禁止破壞；設定 `LUMINA_E2E_FULL=1` 可強制啟用完整 R1–R3 測試。
