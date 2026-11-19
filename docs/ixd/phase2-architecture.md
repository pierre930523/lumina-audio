# Phase 2: 資訊架構與頁面全譜盤點 (Information Architecture)

## 1. 22 類頁面全譜盤點表 (Page Inventory Table)

依照 `ixd-design` 技能規範之 22 種頁面分類體系，針對 Lumina Audio 桌面端完整架構進行全面對應與盤點：

| 編號 | 頁面/組件名稱 | 所屬模組 | 層級 | 平台類型 | 頁面類型 (22類) | 入口來源 | 簡要說明 |
|------|-------------|---------|------|---------|----------------|---------|---------|
| **P00** | 桌面端主工作區容器 (Main Workspace Shell) | 核心框架 | L0 | PC端 | 19. Workspace (主窗口/工作區) | 系統啟動進入 | 承載左側導覽、頂部工具列、主視圖舞台與底欄播放器 |
| **P01** | 首頁儀表板 (Home Dashboard) | 聚合推薦 | L1 | PC端 | 1. Hub (聚合頁) | 側邊欄「主頁」/ 快捷鍵 `Cmd/Ctrl+1` | 最近播放、常聽專輯、發燒精選推薦與版本更新動態 |
| **P02** | 專輯曲庫 (Albums Library) | 典藏曲庫 | L1 | PC端 | 2. List (列表頁) | 側邊欄「專輯」/ 快捷鍵 `Cmd/Ctrl+2` | 虛擬化專輯網格/清單，支援格式標章、拼音/年代排序與自訂視圖 |
| **P03** | 專輯詳情頁 (Album Detail) | 典藏曲庫 | L2 | PC端 | 3. Detail (詳情頁) | 專輯卡片點擊 / 搜尋結果點擊 | 專輯封面 Hero、版本切換器、發燒中繼資訊、完整曲目列表與製作群名錄 |
| **P04** | 藝術家曲庫 (Artists Library) | 典藏曲庫 | L1 | PC端 | 2. List (列表頁) | 側邊欄「藝術家」/ 快捷鍵 `Cmd/Ctrl+3` | 藝術家圓形網格/字母索引條，展示發行數量與演出類別 |
| **P05** | 藝術家詳情頁 (Artist Detail) | 典藏曲庫 | L2 | PC端 | 3. Detail (詳情頁) | 藝術家卡片點擊 / 曲目歌手連結 | 獨立藝人頭像、代表作快速播放、歷年專輯分類（錄音室/EP/Live）與參與名錄 |
| **P06** | 音區管理與信號鏈路 (Zones & Signal Path) | 硬體音訊 | L2 | PC端 | 18. Overlay (彈窗/浮層) | 頂部音區膠囊 / 底欄發燒徽章點擊 | DAC 輸出裝置切換、WASAPI/ASIO 獨占切換、即時取樣率匹配與端到端信號流檢視 |
| **P07** | 懸浮液態迷你播放器 (Mini-Player) | 播放控制 | L1 | PC端 | 18. Overlay / 獨立懸浮 | 底欄切換鍵 / 快捷鍵 `Cmd/Ctrl+M` | 輕量跟手液態玻璃膠囊，精簡控制、置頂懸浮、桌面角落停靠 |
| **P08** | 全螢幕沉浸式播放 (Fullscreen Now Playing) | 播放控制 | L1 | PC端 | 19. Workspace (全螢幕沉浸) | 底欄封面/展開鍵 / 快捷鍵 `Cmd/Ctrl+F` | 封面流體著色器背景、逐字對齊動態歌詞、波形進度條與大字體排版 |
| **P09** | 單曲曲目列表 (Tracks List) | 典藏曲庫 | L1 | PC端 | 2. List (列表頁) | 側邊欄「曲目」/ 快捷鍵 `Cmd/Ctrl+4` | 全域數十萬首單曲虛擬化清單，支援多欄位排序與即時過濾 |
| **P10** | 智慧歌單 (Smart Playlists) | 歌單管理 | L1 | PC端 | 2. List (列表頁) | 側邊欄「智慧歌單」 | 依取樣率（如 Hi-Res >96kHz）、風格、流派、年份自動歸納之動態歌單 |
| **P11** | 歌單詳情頁 (Playlist Detail) | 歌單管理 | L2 | PC端 | 3. Detail (詳情頁) | 歌單卡片點擊 | 歌單曲目編排、拖曳排序、離線快取狀態與共享操作 |
| **P12** | 全域搜索與即時過濾 (Search Hub) | 搜索探索 | L2 | PC端 | 4. Search (搜索頁) | 頂部搜尋欄 / 快捷鍵 `Cmd/Ctrl+K` | 跨本地、Qobuz、Tidal 即時搜尋提示，分類聚合結果（專輯/歌手/曲目） |
| **P13** | 高級格式與音訊篩選器 (Hi-Res Audio Filter) | 典藏曲庫 | L2 | PC端 | 5. Filter (篩選/排序頁) | 專輯/曲目列表工具列篩選鈕 | 按格式（DSD/FLAC/MQA）、取樣率（44.1k-768k）、位元深度（16/24/32）過濾 |
| **P14** | 串流服務帳號綁定 (Streaming Provider Form) | 帳號系統 | L2 | PC端 | 6. Form (表單頁) | 設定頁「串流服務」 | Qobuz Token、Tidal PKCE、Deezer ARL 憑證輸入與測試連線 |
| **P15** | 音樂庫與網路掛載嚮導 (Library & Storage Wizard) | 系統存儲 | L2 | PC端 | 7. Wizard (多步表單) | 首次啟動 / 設定頁「新增音樂目錄」 | 1.選擇目錄(本地/SMB/WebDAV) → 2.掃描策略 → 3.中繼資料來源比對 → 4.完成匯入 |
| **P16** | 輸出硬體與音訊格式選擇器 (Audio Device Picker) | 硬體音訊 | L2 | PC端 | 8. Picker (選擇器頁) | 音區設定中「更換 DAC 裝置」 | 列舉系統可用 ASIO/WASAPI 驅動，選擇位元緩衝大小與時鐘源 |
| **P17** | 曲庫掃描同步結果 (Library Sync Result) | 系統存儲 | L2 | PC端 | 9. Result (結果頁) | 掃描完成系統通知 / 狀態指示列 | 顯示新發現專輯數、衝突中繼資料比對統計與失敗日誌回報 |
| **P18** | 空狀態提示視圖 (Empty State View) | 核心框架 | L2 | PC端 | 10. Empty (空態頁) | 搜尋無結果 / 空歌單 / 新增帳號前 | 簡約向量插圖、友善引導文案與快捷動作 CTA 按鈕 |
| **P19** | 串流授權與配對視圖 (OAuth & Pairing View) | 帳號系統 | L2 | PC端 | 11. Auth (登錄/認證頁) | 啟用串流 / 行動端遠端配對 | 顯示一次性配對 PIN 碼、QR Code 及網頁授權等待中狀態 |
| **P20** | 聽音個人檔案與統計 (Profile & Listening Stats) | 帳號系統 | L1 | PC端 | 12. Profile (個人中心) | 頂部使用者頭像點擊 | 當前活動 Profile 切換、聆聽時長統計、最常播放格式與喜好風格分佈 |
| **P21** | 偏好設置頁面 (Preferences) | 系統設置 | L1 | PC端 | 13. Settings (設置頁) | 側欄「設定」/ 快捷鍵 `Cmd/Ctrl+,` | 通用設定、外觀主題與 UI 縮放比、音樂庫管理與快捷鍵清單 |
| **P22** | 關於與開源授權 (About & License) | 系統設置 | L2 | PC端 | 14. About (關於/協議頁) | 設定頁「關於 Lumina」 | 版本號、Rust 核心與 Flutter 引擎資訊、開源協議與製作感謝名冊 |
| **P23** | 桌面啟動載入過渡 (Splash & Engine Init) | 核心框架 | L0 | PC端 | 15. Splash (啟動頁) | 程式冷啟動 | Lumina 品牌標誌、Rust Audio Engine 初始化、音訊端點偵測與快取預熱 |
| **P24** | 首次啟動硬體嚮導 (First-Run Hardware Guide) | 核心框架 | L1 | PC端 | 16. Onboarding (引導頁) | 首次安裝運行偵測 | 偵測 Hi-Fi DAC、建議 Exclusive 輸出設定、建立第一個音樂資料庫 |
| **P25** | 音訊流緩衝與取樣率轉態 (Stream Transition Buffer) | 播放控制 | L2 | PC端 | 17. Transition (過渡/載入頁) | 切換硬體採樣率或遠端串流載入 | 緩衝環形動畫、硬體取樣率重新鎖定倒數與防爆音淡入過渡 |
| **P26** | 歌曲上下文操作選單 (Track Context Menu) | 播放控制 | L2 | PC端 | 18. Overlay (彈窗/浮層) | 曲目右鍵點擊 | 下一首播放、加入佇列、加入歌單、查看專輯、查看藝人、顯示檔案路徑 |
| **P27** | 播放佇列側邊面板 (Queue Side Panel) | 播放控制 | L1 | PC端 | 20. Side Panel (側邊面板) | 底欄佇列按鈕 / 快捷鍵 `Cmd/Ctrl+U` | 右側展開之播放清單，支援即時拖曳重新排序、移除與一鍵清空 |
| **P28** | 獨立 DSP 音訊引擎設定 (Dedicated DSP Preferences) | 硬體音訊 | L2 | PC端 | 21. Preferences (獨立偏好設置窗口) | 設定頁「DSP 進階」/ 快捷鍵 `Cmd/Ctrl+Shift+D` | 64-bit 浮點 PEQ 圖形等化器、AutoEQ 耳機校正曲線載入、Crossfeed 與聲道平衡 |
| **P29** | 系統托盤與選單列控制器 (System Tray & Menu Bar) | 系統整合 | L0 | PC端 | 22. Tray/Menu Bar (托盤/選單欄) | 系統右下角托盤 / macOS 頂部選單 | 迷你播放/暫停控制、切歌、當前音軌資訊、一鍵喚醒或靜音退出 |

---

## 2. 網站與頁面層級架構圖 (Sitemap)

```mermaid
graph TD
    classDef workspace fill:#161618,stroke:#3b82f6,stroke-width:2px,color:#fff;
    classDef listPage fill:#22242a,stroke:#555,stroke-width:1px,color:#fff;
    classDef detailPage fill:#2a2b33,stroke:#eab308,stroke-width:1.5px,color:#fff;
    classDef overlayPage fill:#33261e,stroke:#f97316,stroke-width:1.5px,color:#fff;
    classDef panelPage fill:#1a2333,stroke:#06b6d4,stroke-width:1.5px,color:#fff;

    P00[P00 桌面端主工作區容器]:::workspace

    subgraph TopBar [全域頂部導覽列]
        NavBack[< 歷史後退]
        NavForward[> 歷史前進]
        SearchTrigger[P12 全域搜索]
        ZoneTrigger[P06 音區與信號鏈]
        ProfileTrigger[P20 個人檔案]
    end

    subgraph SideNav [左側導航列]
        T1[P01 首頁儀表板]:::listPage
        T2[P02 專輯曲庫]:::listPage
        T3[P04 藝術家曲庫]:::listPage
        T4[P09 單曲清單]:::listPage
        T5[P10 智慧歌單]:::listPage
        T6[P21 偏好設置]:::listPage
    end

    subgraph StageView [主視圖舞台 (單一導覽錨點)]
        T1 --> P01Detail[推薦專輯/最新曲目]
        T2 --> P03[P03 專輯詳情頁]:::detailPage
        T3 --> P05[P05 藝術家詳情頁]:::detailPage
        T5 --> P11[P11 歌單詳情頁]:::detailPage
        T6 --> P28[P28 獨立DSP設定]:::detailPage
        T6 --> P14[P14 串流綁定]
        T6 --> P15[P15 音樂庫嚮導]
        T6 --> P22[P22 關於]

        %% 雙向導覽關鍵鏈路 (無冗餘返回列)
        P03 -. 點擊藝人連結 .-> P05
        P05 -. 點擊唱片發行 .-> P03
    end

    subgraph BottomPlayer [底部全功能播放器]
        NowPlayingMini[當前音軌資訊]
        TransportControls[播放/暫停/跳曲]
        WaveSeekBar[波形進度條]
        SignalBadge[Bit-Perfect 綠色徽章]
        BtnQueue[佇列按鈕]
        BtnLyrics[全螢幕歌詞按鈕]
        BtnMiniPlayer[懸浮膠囊按鈕]
    end

    subgraph FloatingAndPanels [浮層與獨立模式]
        BtnQueue --> P27[P27 播放佇列側邊欄]:::panelPage
        BtnLyrics --> P08[P08 全螢幕沉浸式播放]:::workspace
        BtnMiniPlayer --> P07[P07 懸浮液態迷你播放器]:::overlayPage
        SignalBadge --> P06[P06 音區與信號鏈路]:::overlayPage
        ZoneTrigger --> P06
    end

    P00 --> TopBar
    P00 --> SideNav
    P00 --> StageView
    P00 --> BottomPlayer

    %% 歷史棧回溯關係
    NavBack -. 回溯歷史棧 .-> StageView
```

---

## 3. 桌面端導覽結構規格 (Desktop Navigation Patterns)

### A. 頂部全域工具列 (Global Top Bar)
- **高度**：44px 固定高度，支援自繪視窗控制區域（Windows 右側最小/最大/關閉按鈕；macOS 左側預留 72px 交通燈空隙）。
- **歷史導航控制器**：
  - 核心組件：`<`（`btn_nav_back`）、`>`（`btn_nav_forward`）。
  - 狀態管理：直接綁定全域 `NavHistoryController`，具備堆疊深度判斷與防抖機制。
  - 快捷鍵：全域綁定 `Alt + LeftArrow`（後退）、`Alt + RightArrow`（前進）。
- **動態標題插槽 (Dynamic Sticky Header Slot)**：
  - 在 L1 主頁面（如專輯清單、首頁）時顯示當前分頁名稱或搜尋框。
  - 當 L2 詳情頁（如 P03 專輯、P05 藝術家）頁面內容向上滾動超過 180px 閾值時，Hero 標題自動淡出，頂部工具列中央優雅平滑淡入「小型封面 + 專輯名稱 + 藝術家」與「迷你播放/暫停」按鈕。
  - **核心準則：徹底廢除次級二級導覽條（Secondary Back Bar），禁止在內容區域頂部出現重複的返回箭頭。**

### B. 左側邊欄導航 (Collapsible Left Sidebar)
- **展開寬度**：220px；**折疊寬度**：56px（圖標模式，Tooltips 延遲 300ms 浮動顯示名稱）。
- **分組階層**：
  1. *探索發現 (Browse)*：主頁 (Home)、關係圖 (Credits)。
  2. *典藏曲庫 (Library)*：專輯 (Albums)、藝術家 (Artists)、曲目 (Tracks)、智慧歌單 (Smart Playlists)。
  3. *多媒體音訊 (Media)*：有聲書 (Audiobooks)、播客 (Podcasts)、廣播 (Radio)。
  4. *系統工具 (System)*：設定 (Settings)。
- **切換動畫**：寬度變化過渡使用 `var(--motion-duration-sidebar)` (240ms) 及 `var(--motion-easing-standard)`。

### C. 底部全功能播放器 (Bottom Playback Bar)
- **高度**：72px 固定底欄，背景採用 `var(--color-surface-glass)` 高斯模糊半透明材質。
- **左側區域**：專輯封面縮圖 (48×48px)、曲目名稱、藝術家可點擊文字、音軌格式微標籤（如 `FLAC 96/24` 或 `DSD256`）。
- **中央區域**：播放控制按鈕組（隨機、上一首、播放/暫停、下一首、循環）、即時波形進度條與等寬時間指示（`03:24 / 05:41`）。
- **右側區域**：Bit-Perfect 信號鏈綠色徽章（點擊直達 P06）、音區切換按鈕、音量推桿滑塊、播放佇列展開鈕（P27）、動態歌詞按鈕（P08）、迷你膠囊切換鈕（P07）。

---

## 4. 全域快捷鍵配置規範 (Global Keyboard Shortcuts)

| 快捷鍵 (macOS / Windows) | 觸發行為 | 對應模組/頁面 |
|-------------------------|---------|-------------|
| `Space` | 播放 / 暫停切換 | 全域底欄播放器 |
| `Cmd/Ctrl + RightArrow` | 下一首曲目 | 全域底欄播放器 |
| `Cmd/Ctrl + LeftArrow` | 上一首曲目 | 全域底欄播放器 |
| `Alt + LeftArrow` / `Cmd + [` | 歷史導覽：後退上一頁 | 全域頂部導覽列 |
| `Alt + RightArrow` / `Cmd + ]`| 歷史導覽：前進下一頁 | 全域頂部導覽列 |
| `Cmd/Ctrl + K` | 開啟全域搜尋焦點 | P12 全域搜索 |
| `Cmd/Ctrl + U` | 展開 / 收合播放佇列側邊欄 | P27 播放佇列側邊欄 |
| `Cmd/Ctrl + L` / `Cmd + F` | 進入 / 退出全螢幕沉浸式播放 | P08 全螢幕播放 |
| `Cmd/Ctrl + M` | 切換為懸浮液態迷你膠囊播放器 | P07 迷你播放器 |
| `Cmd/Ctrl + ,` | 開啟偏好設置頁面 | P21 偏好設置 |
| `Cmd/Ctrl + Shift + D` | 開啟 64-bit DSP 等化器設定 | P28 獨立 DSP 設定 |
| `Cmd/Ctrl + Up/Down` | 音量微調 (±5%) | 底欄音量控制 |
| `Esc` | 關閉當前浮層 / 退出全螢幕 | P06 / P08 / 搜尋浮層 |
