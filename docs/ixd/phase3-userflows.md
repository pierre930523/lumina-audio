# Phase 3: 核心使用者互動流程 (User Flows)

---

## 核心流程 1：雙向專輯/藝人導覽與歷史堆疊 (Album/Artist Bi-directional Navigation & History Stack)

### 1.1 流程背景與痛點根治
在現代音樂軟體中，使用者常從「專輯列表」進入「專輯詳情（P03）」，點擊歌手姓名跳轉至「藝人詳情（P05）」，再由藝人的歷年作品進入另一張「關聯專輯（P03b）」。
- **痛點根治**：以往在詳情頁內部塞入次級返回按鈕（`showInlineBackButton`），會形成「頂部工具列有 `<` `>`，頁面主體又多一層 `← 返回`」的雙重冗餘，且在多層跳轉後歷史堆疊錯亂。
- **解決方案**：落實**「單一導覽錨點」**，所有深層探索完全由頂部全域歷史控制器統管，各頁面掛載 `PageStorageKey` 精確恢復滾動位置。

### 1.2 Mermaid 流程圖

```mermaid
flowchart TD
    Start([使用者位於首頁或曲庫列表]) --> Step1[P02 專輯列表: 點擊專輯卡片]
    Step1 --> Step2[P03 進入專輯詳情頁 A]
    
    subgraph P03_Action [P03 頁面交互]
        Step2 --> CheckScroll{頁面向上滾動?}
        CheckScroll -->|超過 180px| StickyHeader[頂部工具列淡入專輯標題與迷你播放鈕]
        CheckScroll -->|未超過| HeroVisible[完整展示大圖封面與發行版本]
        HeroVisible --> ClickArtist[點擊藝人姓名連結]
        StickyHeader --> ClickArtist
    end

    ClickArtist --> Step3[P05 進入藝人詳情頁]
    
    subgraph P05_Action [P05 頁面交互]
        Step3 --> ViewArtist[獨立藝人頭像 + 代表作列表 + 專輯網格]
        ViewArtist --> ClickAlbumB[點擊該藝人之另一張專輯 B]
    end

    ClickAlbumB --> Step4[P03 進入專輯詳情頁 B]
    
    subgraph History_Back [全域單一導覽回溯流程]
        Step4 --> ClickNavBack1[使用者點擊頂部工具列 < 後退鍵]
        ClickNavBack1 --> ReturnArtist[返回 P05 藝人詳情頁，精準還原滾動錨點]
        ReturnArtist --> ClickNavBack2[再次點擊頂部工具列 < 後退鍵]
        ClickNavBack2 --> ReturnAlbumA[返回 P03 專輯 A，精準還原滾動位置]
        ReturnAlbumA --> ClickNavBack3[第三次點擊 < 後退鍵]
        ClickNavBack3 --> ReturnLibrary[返回 P02 專輯列表]
    end

    ReturnLibrary --> EndFlow([導覽探索完成])
```

### 1.3 步驟表 (Step Table)

| 步驟 | 頁面/組件 | 使用者操作 | 系統響應 | 異常與邊界處理 | 耗時預估 |
|------|----------|-----------|---------|---------------|---------|
| 1 | P02 專輯列表 | 單擊任一專輯卡片 | 觸發 `navController.push(albumId)`，主舞台執行平滑轉場 (`FadeThrough`) | 若快取無中繼資料，顯示骨架屏並後台載入 | < 150ms |
| 2 | P03 專輯詳情 | 向上滾動檢視曲目 | 當滾動量 > 180px，頂部 App Bar 標題插槽淡入專輯名稱與播放按鈕 | 滾動動效維持 60fps+，硬體 GPU 合成無卡頓 | < 16ms |
| 3 | P03 專輯詳情 | 點擊藝人連結文字 | 觸發 `navController.push(artistName)`，進入 P05 藝人詳情頁 | 藝人若無中繼資料，以本機標籤兜底展示 | < 200ms |
| 4 | P05 藝人詳情 | 點擊發行專輯 B | 觸發 `navController.push(albumIdB)`，進入 P03 專輯 B | 歷史棧深度 +1，頂部後退鈕保持高亮 | < 200ms |
| 5 | 全域頂部導覽列 | 點擊 `<` 歷史後退按鈕 (或按 `Alt+Left`) | 呼叫 `navController.goBack()`，依序倒退回 P05、P03(A)、P02 | 自動從 `PageStorage` 還原各層之 `scrollOffset` | < 100ms |

### 1.4 關鍵決策點 (Key Decision Points)
- **決策點 1：次級導覽列移除判定**
  - *條件*：檢測是否進入二級/三級詳情頁面。
  - *規則*：**一律不渲染**舊版 `IconButton(Icons.arrow_back_rounded)` 次級導覽橫條；頂部全域 `<` 鍵透過監聽歷史棧長度自動啟用（`canGoBack == true`）。
- **決策點 2：滾動吸頂（Sticky Header）觸發閾值**
  - *條件*：`scrollController.offset >= 180.0`。
  - *規則*：動態標題插槽以 `Curves.easeOutCubic` 執行透明度（0.0 → 1.0）漸變過渡；若滾動小於 180px，標題插槽保持完全透明。

---

## 核心流程 2：Bit-Perfect 獨占輸出與音區無縫切換 (Bit-Perfect Output & Zones Switch)

### 2.1 流程背景與價值
發燒音訊核心的核心訴求在於**「真實無損（Bit-Perfect）」**。當播放 192kHz/24-bit FLAC 或 DSD 音軌時，播放器必須避開 Windows/macOS 系統層的重取樣混音器，直接以硬體獨占（Exclusive Mode / Hog Mode）鎖定外接 DAC。

### 2.2 Mermaid 流程圖

```mermaid
flowchart TD
    StartPlay([正在播放 192kHz/24-bit 音軌]) --> CheckZone[使用者點擊頂部音區膠囊或底欄發燒綠色徽章]
    CheckZone --> OpenZonesSheet[開啟 P06 音區與信號鏈路浮層面板]
    
    subgraph Zones_Inspection [音區檢查與硬體切換]
        OpenZonesSheet --> ViewSignalPath[檢視當前鏈路: 來源格式 → DSP 狀態 → 輸出端點]
        ViewSignalPath --> ClickSwitchDevice[點擊更換輸出端點: 選擇 USB Hi-Fi DAC]
        ClickSwitchDevice --> ToggleExclusive{是否啟用 Bit-Perfect 獨占模式?}
        
        ToggleExclusive -->|是| ReqExclusive[[Rust 核心請求 WASAPI/ASIO 獨占鎖定]]
        ToggleExclusive -->|否| ReqShared[[使用系統共享音訊混音器]]
    end

    ReqExclusive --> CheckLockSuccess{硬體鎖定成功?}
    
    CheckLockSuccess -->|成功| ApplySampleRate[[硬體自動匹配 192,000 Hz 採樣率]]
    ApplySampleRate --> UpdateBadge[綠色 Bit-Perfect 發燒標章點亮]
    UpdateBadge --> PlayBitPerfect[音訊直通外接 DAC，螢幕顯示訊號直通]

    CheckLockSuccess -.->|失敗: 其他程式占用| HandleConflict[彈出衝突提示: 裝置已被占用，建議釋放]
    HandleConflict --> FallbackOption{使用者選擇}
    FallbackOption -->|重試| ReqExclusive
    FallbackOption -->|降級共享| ReqShared
    
    ReqShared --> YellowBadge[顯示黃色 Shared 混音標章]
    YellowBadge --> EndFlow([流程結束])
    PlayBitPerfect --> EndFlow
```

### 2.3 步驟表 (Step Table)

| 步驟 | 頁面/組件 | 使用者操作 | 系統響應 | 異常與邊界處理 | 耗時預估 |
|------|----------|-----------|---------|---------------|---------|
| 1 | 底欄播放器 | 點擊信號鏈綠色徽章 | 以液態玻璃彈窗平滑展開 P06 音區與 Signal Path 面板 | 播放不中斷，背景保持微高斯模糊 | < 150ms |
| 2 | P06 音區面板 | 點擊切換至「USB DAC 2.0」 | 向音訊核心發送切換指令，檢測支援之採樣率陣列 (44.1k - 768k) | 若裝置離線，置灰並提示「裝置未就緒」 | < 300ms |
| 3 | P06 音區面板 | 開啟「Bit-Perfect 獨占輸出」開關 | 呼叫 Rust FFI 取得 WASAPI Exclusive / ASIO 控制權 | 若發生端點被獨占衝突，彈出無損降級詢問 | < 500ms |
| 4 | 音訊引擎底層 | (系統自動執行) | 自動切換硬體晶片時鐘至 192kHz，無混音直通 | 若有 DSP PEQ 啟用，以 64-bit 浮點計算並在鏈路如實標明 | < 100ms |
| 5 | P06 / 底欄 | 檢視信號鏈圖示 | Signal Path 顯示「Bit-Perfect 直通」字樣，徽章保持祖母綠高光 | 任何重取樣均轉為紫色 Resampled 標示 | < 50ms |

### 2.4 關鍵決策點 (Key Decision Points)
- **決策點 1：硬體獨占鎖定衝突**
  - *條件*：外部播放軟體搶占 WASAPI Exclusive。
  - *處置*：播放器不崩潰、不中斷，自動降級為高品質 Shared 模式，並在 Signal Path 彈出橙色警告提醒使用者關閉衝突程式。
- **決策點 2：DSD 播放模式決策**
  - *條件*：DAC 是否支援 Native DSD (ASIO) 或 DoP (DSD over PCM)。
  - *處置*：優先選擇 Native DSD，若不支援則自動啟用 DoP 封裝；若 DAC 僅支援 PCM，則以高品質 64-bit 浮點轉換為 176.4kHz PCM 並在鏈路明確標註。

---

## 核心流程 3：播放佇列管理與全螢幕沉浸式播放 (Track Queue & Fullscreen Now Playing)

### 3.1 流程背景與沉浸感演繹
使用者在日常欣賞高解析音樂時，需要彈性的播放佇列調度（插播、拖曳排序、清除），以及進入大螢幕沉浸聆聽模式（動態歌詞、液態流體著色器背景、大字體視覺）。

### 3.2 Mermaid 流程圖

```mermaid
flowchart TD
    StartView([使用者正在瀏覽曲目或專輯詳情]) --> RightClickTrack[曲目右鍵點擊 / 點擊更多按鈕]
    RightClickTrack --> OpenContextMenu[P26 開啟上下文選單]
    
    subgraph Queue_Management [佇列操作]
        OpenContextMenu --> SelectAddQueue[選擇: 下一首播放 / 加入佇列尾端]
        SelectAddQueue --> ToastFeedback[底部微提示: 已加入播放佇列]
        ToastFeedback --> ClickQueueBtn[點擊底欄佇列按鈕或按 Cmd/Ctrl+U]
        ClickQueueBtn --> OpenQueuePanel[P27 展開右側播放佇列抽屜]
        OpenQueuePanel --> DragReorder[長按並拖曳曲目調整順序]
        DragReorder --> ReorderSuccess[[即時更新底層音訊服務佇列順序]]
    end

    ReorderSuccess --> ClickFullscreen[點擊底欄歌詞按鈕或按 Cmd/Ctrl+F]
    
    subgraph Fullscreen_Immersion [全螢幕沉浸式模式]
        ClickFullscreen --> EnterP08[P08 進入全螢幕沉浸式播放]
        EnterP08 --> RenderMeshShader[[GLSL 流體著色器基於封面色彩即時渲染背景]]
        RenderMeshShader --> SyncLyrics[滾動展示動態逐字同步歌詞]
        SyncLyrics --> UserSeek[點擊或滑動大波形進度條定位音軌]
        UserSeek --> LyricsJump[[歌詞自動精確尋道至對應時間點]]
    end

    subgraph Exit_Modality [退出模式]
        EnterP08 --> PressEsc[按下 Esc 或點擊收起按鈕]
        PressEsc --> ReturnWorkspace[返回 P00 主工作區]
        EnterP08 --> ClickMiniPlayer[點擊切換至迷你膠囊]
        ClickMiniPlayer --> EnterP07[進入 P07 懸浮液態迷你播放器]
    end

    ReturnWorkspace --> EndFlow([流程結束])
    EnterP07 --> EndFlow
```

### 3.3 步驟表 (Step Table)

| 步驟 | 頁面/組件 | 使用者操作 | 系統響應 | 異常與邊界處理 | 耗時預估 |
|------|----------|-----------|---------|---------------|---------|
| 1 | P03 / P09 曲目項 | 右鍵單擊曲目項 | 彈出 P26 歌曲上下文快捷操作選單 | 靠近邊界時選單自動翻轉朝向防止溢出 | < 50ms |
| 2 | P26 右鍵選單 | 點選「加入播放佇列」 | 音軌追加至佇列，底欄佇列計數角標 +1 動態彈跳 | 重複曲目不重複加入，輕量 Toast 提示 | < 100ms |
| 3 | 底欄右側 | 點擊佇列圖示 (或按 `Cmd+U`) | 右側展開 P27 播放佇列側邊欄 (寬度 360px) | 內容主視圖保持自適應，不擠壓佈局 | < 200ms |
| 4 | P27 佇列側邊欄 | 滑鼠拖曳曲目手柄上下排序 | 插入指示線即時跟手吸附，釋放後立即同步佇列索引 | 拖曳過程維持 60fps+，平滑動畫移位 | < 16ms |
| 5 | 底欄右側 | 點擊歌詞圖示 (或按 `Cmd+F`) | 主舞台以半透明淡入切換至 P08 全螢幕沉浸播放 | 頂部全域工具列與側邊欄平滑隱藏 | < 300ms |
| 6 | P08 全螢幕播放 | 聆聽音樂並滾動歌詞 | GLSL Shader 依照封面調色盤動態微波流動，當前歌詞高亮放大 | 無歌詞時優雅過渡為大封面 + 頻譜儀模式 | 60-120fps |
| 7 | P08 全螢幕播放 | 按下 `Esc` 鍵 | 平滑淡出全螢幕，還原至主工作區此前瀏覽位置 | 歷史位置與播放狀態完全無縫維持 | < 250ms |

### 3.4 關鍵決策點 (Key Decision Points)
- **決策點 1：全螢幕進入/退出時的介面狀態恢復**
  - *條件*：使用者由深層頁面（如 P03 專輯）進入 P08，再退出 P08。
  - *處置*：全螢幕視圖作為獨立 Overlay 層覆蓋於主工作區之上，退出時直接銷毀 Overlay，主工作區的導覽歷史棧（`NavHistoryController`）與各頁面狀態完全不被破壞。
- **決策點 2：動態歌詞無中繼資料兜底**
  - *條件*：當前音軌無內嵌 LRC 且串流服務無逐字歌詞。
  - *處置*：介面自動切換至「發燒封面大圖 + 64-bit 聲道頻譜儀 + 專輯發布故事」視圖，絕不出現大面積突兀的空白報錯。
