# Phase 1: 產品上下文與設計概要 (Product Context)

## 產品設計摘要 (Product Design Summary)

**Lumina Audio** 是一款面向 **發燒級音響玩家（Audiophiles）**、**高解析音樂收藏家（Collectors）** 與 **現代高品質數位聆聽者** 的桌面級專業 Hi-Fi 音訊管理與 Bit-Perfect 音樂播放工作區（Desktop Hi-Fi Audiophile Player & Library Workspace）。

核心解決傳統發燒播放軟體（如 Foobar2000 等）介面老舊割裂、現代串流軟體音訊鏈路黑箱混音（非 Bit-Perfect 混音重取樣）、本地無損（FLAC/DSD）與多串流（Qobuz/Tidal/Deezer）曲庫割裂、以及前期原型中出現的**「雙重返回列與雙重標題衝突」**等互動混亂問題。

產品基於 **Rust 音訊核心（64-bit 浮點 DSP / ASIO / WASAPI Exclusive / CoreAudio Hog）** 與 **Flutter Desktop（Windows / macOS，Impeller GLSL Shaders）** 構建，遵循 **迪特·拉姆斯（Dieter Rams）「少，即是更好」（Less, but better）** 簡約功能主義，並吸納 Apple Music 與 Spotify 的現代桌面互動標準，主要包含 5 大功能模組：
1. **聚合首頁 (Home Hub)**：智慧推薦、最近播放、精選版本、即時動態與聽音洞察。
2. **統合曲庫 (Unified Library)**：Canonical 專輯庫、藝術家圖譜、單曲與智慧歌單（支援本機、SMB/WebDAV、Qobuz、Tidal、Deezer 無縫整合）。
3. **專業發燒音訊引擎與音區 (Bit-Perfect Audio Engine & Zones)**：硬體獨占輸出、自動取樣率匹配、原生 DSD/DoP、可視化 Signal Path 信號鏈路與 64-bit PEQ/AutoEQ。
4. **播放控制與沉浸式體驗 (Playback & Immersive Experience)**：底欄全功能播放器、跟手液態玻璃懸浮膠囊（Mini-Player）、全螢幕動態歌詞與封面流體著色器（Fullscreen Now Playing）。
5. **跨來源與版本管理 (Multi-Source & Version Switching)**：同一專輯多來源/多規格版本（MQA/Hi-Res/CD/Vinyl）一鍵無縫對比切換。

---

## 設計挑戰 (Design Challenges)

1. **單一導覽錨點與雙重返回列衝突 (Navigation Anchor vs. Inline Redundancy)**
   - *問題描述*：在桌面寬螢幕環境下，頂部全域工具列已具備標準瀏覽器式 `<` `>` 歷史導覽鍵；二級詳情頁（如專輯、藝術家）過去常在頁首左側再次塞入 `← 返回` 按鈕，並在下方重複大字體標題，導致垂直空間浪費、視線焦點分散與心理模型混淆。
   - *設計難點*：如何在保持使用者強大歷史回溯能力的同時，徹底消除次級導覽雜訊，並讓內容區域在滾動時自然無縫過渡（動態吸頂）。

2. **發燒級硬體透明度 vs. 極簡克制介面 (Audiophile Transparency vs. Minimalism)**
   - *問題描述*：發燒友強烈要求即時掌握 DAC 當前鎖定頻率、音訊編碼格式、位元深度與 DSP 增益鏈路（Bit-Perfect 驗證），但大量專業技術參數極易演變成視覺雜訊。
   - *設計難點*：如何將硬體級信號鏈路收納為優雅簡約的互動微徽章（Signal Path Badge），並在點擊時以液態玻璃彈窗提供詳盡無遺的信號流程圖。

3. **龐大本地與串流曲庫的極速渲染與層次組織 (Heterogeneous Library & Performance)**
   - *問題描述*：使用者曲庫規模通常在數萬至數十萬首曲目之間，涵蓋不同來源（本地磁碟、NAS、串流平台），元數據結構存在差異。
   - *設計難點*：需保證 120Hz 絲滑滾動、流暢虛擬化列表，並在同一視圖中優雅呈現多發行版本切換（Versions Switcher）與樂手製作群名錄（Credits Graph）。

4. **桌面多面板自適應與多型態流轉 (Desktop Multi-Panel & Modality Adaptability)**
   - *問題描述*：桌面軟體需應對使用者自 800×600 迷你懸浮窗、1280×800 筆電螢幕到 4K 超寬螢幕的自由拖曳縮放，甚至從主工作區剝離為獨立懸浮 Mini-Player。
   - *設計難點*：側邊欄收合折疊、主內容區柵格自適應、佇列側邊抽屜與懸浮膠囊的雙向平滑過渡。

---

## 設計原則 (Design Principles)

1. **單一導覽錨點 (Single Navigation Anchor)**
   - 全域頂部工具列統管所有歷史棧（`<` 前進、`>` 後退、全域捷徑 `Alt+Left/Right`）；各內容詳情頁嚴禁出現重複的次級返回列。使用者在任何層級均有一致且可預期的導覽認知。

2. **內容優先與動態吸頂 (Content-First & Sticky Hierarchy)**
   - 頁面進入時呈現震撼且沉浸的大圖 Hero 標題區；當內容向上滾動超過臨界閾值時，專輯/藝人核心標題與播放快捷鍵優雅淡入頂部 App Bar（Sticky Header），消滅雙重標題，最大化長列表閱讀視野。

3. **信號真實透明 (Bit-Perfect Transparency)**
   - 音訊路徑絕不造假。綠色發燒標章嚴格對應硬體直通狀態（WASAPI Exclusive / ASIO / CoreAudio Hog），每一步 DSP 與硬體轉態均在 Signal Path 彈窗中精準呈現，滿足發燒玩家的嚴苛掌控欲。

4. **功能至簡與非阻塞反饋 (Rams Functional Purism & Responsive Feedback)**
   - 剔除所有非必要的裝飾性外框與漸變重影，以 4px 網格建立嚴謹韻律。所有互動操作（換曲、音區切換、篩選）必須在 50ms 內給予可視化動態反饋，60fps+ 絲滑無阻。

---

## 設計參考 (Design References)

| 參考產品 | 參考維度 | 借鑒理由 |
|---------|---------|---------|
| **Roon** | 資訊架構 & 發燒信號鏈 (IA & Signal Path) | 借鑒其成熟的音區切換（Audio Zones）、硬體取樣率鏈路展示與跨音源版本（Versions）整合模型，但改進其過於厚重幽暗的介面階層。 |
| **Apple Music (macOS)** | 導覽互動與液態視覺 (Navigation & Liquid UI) | 借鑒頂部統一歷史導覽、側欄分類架構、懸浮膠囊 Mini-Player 與半透明材質景深層次。 |
| **Spotify (Desktop)** | 佇列抽屜與鍵盤互動 (Queue Panel & Shortcuts) | 借鑒右側抽屜式播放佇列、全域鍵盤導航體系與列表右鍵上下文快捷操作。 |
| **Braun / Dieter Rams** | 產品哲學與功能純粹 (Functional Purism) | 貫徹 Braun ET66 / T3 收音機的實體質感，旋鈕與滑桿具備嚴謹物理阻尼感，等寬數字（tabular-nums）精準排版。 |

---

## 視覺方向建議 (Visual Direction Suggestions)

- **色彩傾向**：曜石暗黑（Obsidian Charcoal `var(--color-bg-canvas)`）為基底，搭配低反射金屬灰階，輔以發燒金色（Hi-Fi Amber Gold `var(--color-accent-amber)`）作為主強調色，信號直通指示採用精確的晶體綠（Bit-Perfect Emerald `var(--color-status-success)`）。
- **字體氣質**：現代克制、高清晰度無襯線字體（Inter / PingFang SC / Segoe UI Variable），時間與取樣率數值全面採用等寬數字（`tabular-nums`），營造專業精密儀器感。
- **視覺風格關鍵詞**：克制 (Restrained)、通透 (Translucent Liquid Glass)、精密 (Instrument-grade)、流暢 (120Hz Fluid Motion)、純粹 (Purist)。

---

> **[For Reference Only — Input for Phase 2-4]**
> - 詳情頁（P03, P05）必須徹底拆除 `showInlineBackButton`，將返回邏輯完全收歸全域 `NavHistoryController`。
> - 頂部 App Bar 需支援動態標題插槽，由滾動監聽器（ScrollController）驅動透明度變化。
> - Mini-Player 需支援系統頂層置頂（Pin to Top）與滑鼠穿透模式切換。
