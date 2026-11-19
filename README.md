# Lumina Audio 🎵

<p align="center">
  <strong>專為發燒友與音樂愛好者打造的現代化 Windows 桌面端無損音樂播放器</strong>
  <br />
  <em>Audiophile Lossless Music Player for Windows — Powered by Rust & Flutter Desktop</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.1.0-blue.svg?style=flat-square" alt="Version" />
  <img src="https://img.shields.io/badge/platform-Windows%20x64-0078D6.svg?style=flat-square&logo=windows" alt="Platform" />
  <img src="https://img.shields.io/badge/audio-WASAPI%20Exclusive%20%7C%20ASIO-brightgreen.svg?style=flat-square" alt="Audio Engine" />
  <img src="https://img.shields.io/badge/DSP-64--bit%20Float-orange.svg?style=flat-square" alt="DSP" />
  <img src="https://img.shields.io/badge/UI-Flutter%20Desktop-02569B.svg?style=flat-square&logo=flutter" alt="Flutter" />
  <img src="https://img.shields.io/badge/Core-Rust%202024-black.svg?style=flat-square&logo=rust" alt="Rust" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg?style=flat-square" alt="License" />
</p>

---

## 🌟 軟體簡介 (About Lumina Audio)

**Lumina Audio** 是一款兼具頂級 Hi-Fi 聲音表現與現代桌面端美學的無損音樂播放器。底層採用高效能 **Rust** 打造低延遲、無鎖（Lock-Free）架構的專業音訊直通引擎，上層由 **Flutter Desktop** 提供流暢、優雅且符合高對比度規範（WCAG 2.1 AA）的暗色系沉浸式介面。

無論您是追求極致「Bit-Perfect」硬體直出的發燒友，還是需要管理大量高解析無損音樂庫的愛好者，Lumina Audio 皆能為您提供無懈可擊的聆聽與視覺體驗。

---

## ✨ 核心特色與技術亮點 (Key Features)

### 1. 🎧 Bit-Perfect 頂級硬體音訊直出 (Bit-Perfect Native Audio Engine)
- **WASAPI Exclusive & ASIO 雙核心驅動**：深度實作 Windows 原生 WASAPI 獨佔模式以及 Win64 Clean-Room COM ASIO 驅動，繞過 Windows 系統混音器（Audio Engine / APO），杜絕二次重取樣失真。
- **硬體能力自動協商**：智慧偵測 DAC 裝置硬體支援之真實取樣率（44.1kHz ~ 768kHz）與位元深度（16-bit, 24-bit, 32-bit Integer / Float），自動切換輸出規格。
- **Native DSD & DoP (DSD over PCM) 直通**：支援 Native DSD64 ~ DSD512 與 DoP v1.1 封裝標準，直達解碼晶片。
- **無鎖環形緩衝區（Epoch-based Lock-Free RingBuffer）**：獨家 Epoch 序號機制，在毫秒級 Seek、曲目切換時徹底消除切歌爆音與資料撕裂。

### 2. 🎛️ 64-bit 浮點錄音室級 DSP 引擎 (Studio-Grade 64-bit DSP)
- **10-Band ISO 標準參量均衡器 (PEQ)**：支援高精度頻點調整與 Q 值微調。
- **AutoEQ 整合**：一鍵解析並套用超過數千款耳機的 AutoEQ 校準設定檔。
- **Crossfeed 雙耳串擾處理**：模擬自然監聽喇叭聲場，大幅減輕耳機長時間佩戴產生的「頭中效應」聽覺疲勞。
- **ReplayGain 2.0 音量自動標準化**：內建智慧防削波限制器（Protection Limiter），在平滑動態音量的同時絕不產生失真。
- **透明 Signal Path 視覺化與一鍵 Bypass**：介面直觀呈現目前音訊處理鏈（解碼 → DSP → 輸出硬體），並支援一鍵完全繞過 DSP 實現純粹 Bit-Perfect。

### 3. 🎨 極致桌面美學與互動打磨 (Audiophile-First UI/UX)
- **無框極簡專輯網格 (Frameless Minimalist)**：封面圖片與資訊自然融入暗黑底色，支援自訂欄數、間距、卡片底框開關與網格／清單視圖無縫切換，設定自動記憶保存。
- **Apple Music 風格光影微交互**：專輯懸停時呈現動態環境溢色光暈（Ambient Glow）與 32×32 低載 GPU 合成模糊層，搭配進場微升降的毛玻璃（Frosted Glass）浮動播放鈕，細緻且保持 60fps+ 極致流暢。
- **單一錨點雙向聯動導覽 (Single-Anchor Navigation)**：
  - 專輯詳情 ↔ 藝人主頁雙向無縫穿透跳轉。
  - 支援全域瀏覽歷史（`<` 與 `>` 歷史棧）、滑鼠側鍵與桌面快捷鍵（`Space`, `Alt+Left/Right`, `Backspace`, `Ctrl+F`, `M`, `Escape`）。
  - 徹底剔除多餘重疊次級標題列，平滑動態微吸頂標題（Sticky Title）優雅呈現。
- **高畫質原圖封面與動態頭像**：原圖無損提取，杜絕低畫質壓縮模糊；藝人頭像採用專屬精緻圓形動態質感漸層。
- **LRC 逐行與逐詞平滑滾動歌詞**：高精度時間軸對齊與即時高亮。

### 4. 🖥️ Windows Per-Monitor V2 多螢幕與高 DPI 自適應
- **完美適配多螢幕混用**：1080p、2K、4K、8K 螢幕間隨意拖曳，即時響應 `WM_DPICHANGED` 與 `WM_DISPLAYCHANGE`。
- **支援 100% ~ 200% Windows 系統縮放**：文字、圖示與邊框毫無鋸齒、不失真、不模糊，杜絕封面圖片雙重縮放問題。
- **智慧邊界夾緊（Clamped Popovers）與自適應斷點**：視窗縮放至任何邊界均不產生組件截斷或溢位錯誤（RenderFlex Overflow）。

---

## 🏛️ 系統架構 (System Architecture)

```text
lumina-audio/
├── Cargo.toml                       # Rust Workspace 配置 (Rust 2024 Edition)
├── crates/
│   ├── core-types/                  # 共用資料模型 (Album, Track, Version, SignalPath, Zone)
│   ├── core-db/                     # SQLite (WAL + FTS5) 本機高效能資料庫與搜尋引擎
│   ├── core-providers/              # 本機目錄掃描、CJK 編碼修正、內嵌封面提取
│   ├── core-audio/                  # Symphonia 解碼、64-bit DSP、WASAPI Exclusive、ASIO、DSD/DoP
│   ├── core-server/                 # 核心後台服務與內部通訊架構
│   └── core-ffi/                    # 高效能 FFI 橋接層 (提供 C-ABI 動態庫 core_ffi.dll)
├── app/                             # Flutter Desktop 跨平台前端應用程式
│   ├── lib/
│   │   ├── core/                    # FFI 綁定、音訊控制服務、快捷鍵控制器
│   │   ├── data/                    # 本機儲存、曲庫索引快取、版面偏好設定
│   │   ├── ui/                      # 現代化深色 UI (主題 Tokens、響應式斷點、Sliver 虛擬滾動)
│   │   │   ├── albums/              # 專輯網格、無框佈局、獨立詳情頁
│   │   │   ├── artists/             # 藝人主頁、動態質感頭像、關係圖
│   │   │   ├── player/              # 底部迷你控制列、Now Playing 展開頁、LRC 滾動歌詞
│   │   │   ├── settings/            # 裝置管理與輸出音區卡片、DSP 效果器設定
│   │   │   └── theme/               # WCAG 2.1 AA 規範 LuminaTokens 顏色系統
│   │   └── main.dart                # DPI 監聽與桌面初始化入口
│   └── test/                        # 129+ 項全域單元、元件與整合測試套件
└── tests/
    └── e2e/                         # 116+ 項 Python 端到端全覆蓋自動化驗證
```

---

## 🚀 建置與執行指南 (Build & Run Guide)

### 必備環境需求 (Prerequisites)
1. **Windows 10 / 11 64-bit**
2. **Flutter SDK**：3.14.0 或更高版本 (`flutter --version`)
3. **Rust Toolchain**：1.80+ (`rustup default stable-x86_64-pc-windows-msvc`)
4. **Visual Studio 2022**：安裝「使用 C++ 的桌面開發」工作負載（包含 MSVC 編譯器與 Windows SDK）

### 1. 複製專案庫 (Clone Repository)
```bash
git clone https://github.com/pierre930523/lumina-audio.git
cd lumina-audio
```

### 2. 編譯 Rust 核心音訊庫 (`core_ffi.dll`)
```bash
# 編譯發行版本動態庫
cargo build --release -p core-ffi

# 將動態連結庫複製至 Flutter 執行路徑（或在偵錯時確保環境變數包含 target 目錄）
copy target\release\core_ffi.dll app\
```

### 3. 安裝 Flutter 依賴項
```bash
cd app
flutter pub get
```

### 4. 執行與測試 (Run & Test)
```bash
# 靜態代碼分析 (0 issues)
flutter analyze

# 執行 Flutter 全域測試套件
flutter test -j 1

# 以桌面模式本機偵錯執行
flutter run -d windows

# 建置 Windows Release 發行安裝套件
flutter build windows --release
```

---

## 🧪 測試驗證矩陣 (Quality & Test Matrix)

Lumina Audio 採用嚴格的測試驅動開發與多層驗證機制：

| 測試層級 | 執行指令 | 測試案例數 | 通過率 |
| :--- | :--- | :---: | :---: |
| **Rust Core Workspace** | `cargo test --workspace` | 246 / 246 | **100%** |
| **Flutter Widget & UI Suite** | `cd app; flutter test -j 1` | 129 / 129 | **100%** |
| **Static Code Analysis** | `cd app; flutter analyze` | 0 issues | **100%** |
| **Python E2E Automation** | `python tests/e2e/runner.py --suite r1` | 116 / 116 | **100%** |
| **Per-Monitor V2 DPI Suite** | `flutter test test/multi_monitor_dpi_responsive_test.dart` | 6 / 6 scenarios | **100%** |

---

## 🗺️ 版本里程碑 (Roadmap)

- **v0.1.0 (當前版本 - Initial Release)**：
  - [x] 原生 WASAPI Exclusive 與 Win64 ASIO 雙引擎直出。
  - [x] Native DSD / DoP (v1.1) 硬體直通輸出。
  - [x] 64-bit 浮點 DSP 引擎（10-Band PEQ、AutoEQ、Crossfeed、ReplayGain 2.0、一鍵 Bypass）。
  - [x] 全站 WCAG 2.1 AA 規範深色主題與微交互。
  - [x] 無框極簡專輯網格、動態環境光暈與毛玻璃懸浮按鈕。
  - [x] 單一錨點雙向聯動導覽歷史棧（`<` / `>`）與平滑微吸頂標題。
  - [x] Windows Per-Monitor V2 多螢幕混用與 100% ~ 200% 高 DPI 即時自適應。
  - [x] 本機多目錄掃描、CJK 標籤編碼修復、原圖無損封面萃取與 LRC 滾動歌詞。
- **v0.2.0 (規劃中)**：
  - [ ] 雲端無損串流音源整合（Qobuz, Tidal, WebDAV/SMB）。
  - [ ] 區域網路多音區同步播放與 mDNS 裝置廣播串流。
  - [ ] macOS (CoreAudio Hog Mode) 與 Linux (ALSA Direct) 跨平台移植。

---

## 📄 授權條款 (License)

本專案採用 [MIT License](LICENSE) 開源授權，歡迎音樂發燒友與開源社群共同交流與改進！
