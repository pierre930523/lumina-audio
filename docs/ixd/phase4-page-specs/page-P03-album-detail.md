# P03 專輯詳情頁 (Album Detail) 交互規格書

## 1. 頁面概述 (Page Overview)

- **功能定位**：呈現單張專輯的母帶級完整中繼資料、發行版本切換（多來源 Versions Switcher）、高品質封面藝術、發燒格式規格、曲目清單、參與名錄（Credits）與評論背景。
- **所屬模組**：典藏曲庫模組 (Library / Album Detail)
- **上游頁面**：P01 首頁推薦/最近聆聽、P02 專輯列表點擊、P05 藝人詳情之「歷年專輯」點擊、全域搜尋（P12）結果
- **下游頁面**：P05 藝人詳情頁（點擊藝人名稱/頭像連結）、P06 音區與信號鏈路（點擊音軌取樣率徽章）、P08 全螢幕播放、P27 播放佇列側欄
- **核心設計革新 (Key Interaction Innovations)**：
  1. **徹底移除次級返回列 (Elimination of Redundant Secondary Back Bar)**：廢除舊版在內容區頂部注入的 `← 返回專輯列表` 次級工具條，將歷史回溯權威完全交回全域頂部導覽列（`<` `>`），消除視線雜訊與空間浪費。
  2. **動態吸頂標題機制 (Sticky Header on Scroll)**：頁面向上滾動超過臨界閾值（180px）時，頂部工具列優雅淡入「迷你封面 + 專輯名稱 + 快捷播放鈕」，消滅雙重標題衝突，維持滾動時的操控與位置感知。

---

## 2. 頁面布局 (Layout Structure)

```
┌────────────────────────────────────────────────────────────────────────┐
│  頂部全域導覽列 (單一導覽錨點):                                         │
│  [< 歷史後退] [> 歷史前進] │ [動態吸頂標題插槽: (未滾動時透明 / 滾動後淡入)]│
│                             │ 滾動後: [迷你封面] [專輯名 - 藝人] [▶ 播放]    │
├────────────┬───────────────────────────────────────────────────────────┤
│  左側導覽列 │  主視圖內容區 (單一 CustomScrollView + Sliver 協同渲染):   │
│  (可折疊)   │                                                           │
│  • 主頁     │  區域 A: Hero 典藏區 (寬螢幕雙欄 / 窄螢幕上下排列)         │
│  • 關係圖   │  ┌───────────┐  專輯標題 (大字體 28px, 緊密字距)           │
│  • 專輯 (●) │  │           │  藝人名稱 (藍色可點擊連結，單擊跳轉 P05)   │
│  • 藝術家   │  │ 高清封面  │  發燒中繼: 1小時42分 · FLAC · 192kHz/24-bit│
│  • 曲目     │  │ 200×200px │  [全部播放 ▶] [隨機播放 🔀] [加到佇列 ＋]  │
│  • 智慧歌單 │  │ (母帶標章)│                                           │
│  • 偏好設定 │  └───────────┘  發行版本切換 (Versions Switcher Chips):   │
│             │                 (● Local FLAC) (○ Qobuz 192k) (○ Tidal MQA)│
│             │                                                           │
│             │  區域 B: 規格與製作名錄折疊列 (Audio Specs & Credits Bar)  │
│  220px/56px │  動態範圍: DR14 │ 編碼器: libFLAC 1.4.2 │ 聲道: 2.0 Stereo│
│             │                                                           │
│             │  區域 C: 曲目清單列表 (Tracklist SliverList)               │
│             │  #  標題            藝人        時長     規格     操作    │
│             │  ──────────────────────────────────────────────────────── │
│             │  01 序曲 (Overture) 樂團名稱    04:12   192k/24   [···]   │
│             │  02 主題變奏曲      樂團名稱    06:35   192k/24   [···]   │
│             │  03 終章小協奏曲    樂團名稱    08:19   192k/24   [···]   │
├────────────┴───────────────────────────────────────────────────────────┤
│  底部全功能播放器：[當前音軌]  [播放控制組]  [波形進度條]  [發燒徽章]  [佇列/歌詞]│
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 組件清單 (Component Inventory)

| 編號 | 組件名稱 | 組件類型 | 所在區域 | 交互行為 | 觸發條件 | 備註 |
|------|---------|---------|---------|---------|---------|------|
| C301 | 頂部動態吸頂標題 (Sticky Header Bar) | 動態標題組件 | 頂部全域導覽列中央 | 隨內容滾動自動透明度淡入/淡出；點擊播放鈕播放整張專輯 | 頁面滾動距離 > 180px | 徹底取代舊版重複次級返回條 |
| C302 | 專輯封面展示 (Album Artwork Hero) | 大圖視圖 | Hero 區左側 | 單擊放大檢視原始母帶大圖，懸浮出現封面光斑折射 | 始終展示 | 支援快取重繪 ValueKey 最佳化 |
| C303 | 藝人跳轉連結 (Artist Link) | 文字連結按鈕 | Hero 區標題下方 | 單擊觸發 `navController.push(artistName)` 進入 P05 | 點擊文字 | Hover 出現底線與發燒金光 |
| C304 | 發行版本切換器 (Versions Switcher) | 晶片標籤群組 (Chips) | Hero 區按鈕上方 | 單擊不同發行來源（Local / Qobuz / Tidal / Deezer）即時無縫重載曲目表 | 存在多版本時展示 | 標註來源圖標與音訊規格 |
| C305 | 全部播放主按鈕 (Play All Button) | 主操作按鈕 (CTA) | Hero 操作按鈕列 | 單擊立即清空佇列並自第 1 首曲目起播放整張專輯 | 始終可用 | 琥珀金色高光，40px 高度 |
| C306 | 隨機播放按鈕 (Shuffle Button) | 次級圖標按鈕 | Hero 操作按鈕列 | 單擊打亂整張專輯順序並載入播放 | 始終可用 | 帶隨機圖標 |
| C307 | 曲目列表行 (Tracklist Item Row) | 列表行組件 | 區域 C 曲目清單 | 單擊選中；雙擊立即播放此曲；右鍵彈出 P26 上下文選單 | 每行曲目 | 支援滑鼠 Hover 整行微高亮 |
| C308 | 曲目操作更多按鈕 (Track More Button) | 圖標按鈕 | 曲目行右側 | 單擊彈出 P26 曲目操作選單 (加入佇列/收藏/分享) | 懸浮或選中行時 | 44×44px 易觸摸/點擊熱區 |

---

## 4. 交互行為詳述 (Interaction Behaviors)

### A. 次級導覽列移除與頂部動態吸頂機制 (Sticky Header Integration)
- **歷史回溯操作**：
  - 使用者回退只需點擊頂部全域工具列之 `<` 按鈕（`btn_nav_back`）或使用鍵盤快速鍵 `Alt + LeftArrow`（macOS 為 `Cmd + [`）。
  - 取消原有頁面內部 `showInlineBackButton`，內容頂部邊距緊湊優雅，有效節省 48px 垂直視線空間。
- **動態吸頂過渡邏輯 (Sticky Threshold Behavior)**：
  - 當 `_scrollController.offset < 140px` 時：頂部動態標題插槽完全透明（`opacity: 0.0`）。
  - 當 `140px <= _scrollController.offset <= 220px` 時：插槽執行線性插值淡入，封面縮圖以 `scale(0.8)` 放大至 `1.0`。
  - 當 `_scrollController.offset > 220px` 時：頂部吸頂條完全固定顯示（`opacity: 1.0`），包含「迷你封面 + 專輯名稱 + 藝術家」以及常駐的小型「播放/暫停」膠囊按鈕，方便使用者深入檢視數十首曲目時隨時發起播放。

### B. C304 發行版本切換器 (Versions Switcher)
- **單擊 (Tap)**：點選不同版本晶片（如從 `Local FLAC` 切換至 `Qobuz Hi-Res 192k`）。
- **即時響應**：
  - 晶片以 150ms 執行背景反白動畫。
  - 下方曲目清單立即切換對應版本曲目，取樣率與格式標籤即時更新。
  - 當前正在播放之音軌若在新版本中有對應曲目，保持播放狀態並提示「已切換為 Qobuz 192kHz/24-bit 版本播放」。

### C. C307 曲目列表行 (Tracklist Row)
- **雙擊 (Double Click)**：立即中斷目前播放，播放該曲目並將整張專輯排入佇列。
- **懸浮 (Hover)**：
  - 整行背景淡入 4% 白色高光（`var(--color-surface-hover)`）。
  - 最左側序號（如 `01`）平滑替換為小型播放三角形圖示。
- **右鍵選單 (Context Menu)**：
  - 彈出 P26 選單：下一首播放、加入佇列、加入歌單、顯示檔案位置、編輯標籤。
- **鍵盤控制 (Keyboard)**：
  - `Up / Down` 移動行選中焦點；`Enter` 播放選中曲目；`Space` 播放/暫停。

---

## 5. 頁面狀態流轉 (State Machine)

| 狀態 | 觸發條件 | 視覺表現 | 可執行操作 |
|------|---------|---------|-----------|
| **預設態 (Default)** | 專輯與曲目資料快取完整載入 | 完整呈現 Hero 區、版本晶片與完整曲目清單 | 所有播放、切換、右鍵與滾動吸頂操作 |
| **加載態 (Loading)** | 進入頁面且本地 SQLite 正在解析發行版本 | Hero 區顯示圓角封面占位骨架，曲目區呈現 8 條模擬骨架線 | 頂部全域後退鍵可用，可直接返回 |
| **空態 (Empty)** | 該專輯實體檔案已自磁碟移除，或串流專輯已下架 | 封面暗化展示警告圖標 + 提示「此專輯已自曲庫或串流來源中移除」+「自曲庫清理」CTA | 單擊 CTA 自索引資料庫抹除 |
| **錯誤態 (Error)** | 中繼資料解析異常或網路磁碟逾時 | 頁面中央展示錯誤提示「無法載入專輯中繼資料」+「重試」按鈕 | 單擊重試重新拉取資料 |
| **無權限態 (No Access)** | 檔案位於受系統保護資料夾或串流憑證過期 | 標註「憑證無效」提示列 +「前往重新授權」按鈕 | 點擊跳轉至 P14 重新驗證 |
| **部分加載態 (Partial)** | 本地曲目加載完成，但線上製作名錄（Credits）查詢逾時 | 曲目清單正常可用，底部 Credits 折疊區顯示「名錄離線不可用」灰字 | 核心聽歌完全不受影響 |
| **編輯態 (Edit)** | 點擊「編輯中繼資料」進入標籤修訂模式 | 曲目列表文字轉換為行內編輯輸入框 | 修改曲名、音軌序號、藝術家並儲存寫入 FLAC Tag |

---

## 6. 動效說明 (Motion Specs)

### 轉場與吸頂曲線
- **頁面進入轉場**：`FadeThrough`（時長 200ms），曲目列表依序以 `delay: index * 15ms` 進行 6px 輕微向上交錯淡入（Staggered Animation）。
- **頂部吸頂淡入**：
  - 動態插值：`Opacity = ((offset - 140) / 80).clamp(0.0, 1.0)`。
  - 縮放曲線：`Transform.scale(scale: 0.85 + 0.15 * progress)`。

---

## 7. 數據策略 (Data Loading Strategy)

- **單一虛擬滾動樹 (Single Virtualized CustomScrollView)**：
  - Hero 區作為 `SliverToBoxAdapter`，曲目清單作為 `SliverList`。
  - 滾動過程中維持單一渲染管線，徹底根除多層嵌套滾動條造成的滑動卡頓。
- **滾動偏移量精確記憶 (Scroll Restoration)**：
  - 頁面綁定 `PageStorageKey<String>('album_detail_${albumId}')`。
  - 當使用者點擊藝人名稱跳轉 P05 再返回時，透過 `initialScrollOffset` 精準定位至跳出前的像素位置，零跳變。

---

## 8. 適配說明 (Adaptation Rules)

### 桌面端寬窄佈局自適應
- **分界閾值 (Breakpoint)**：`560px`。
  - **寬螢幕模式 (≥ 560px)**：Hero 區採用水平雙欄佈局（左側 200×200px 封面，右側中繼資料與操作按鈕）。
  - **窄視窗模式 (< 560px)**：Hero 區自適應為垂直堆疊佈局（封面居中縮至 148×148px，下方為居中文本與按鈕）。
- **深色模式對比度**：
  - 標題使用最高純度白色 `var(--color-text-primary)`（對比度 > 12:1）。
  - 取樣率規格徽章採用發燒金色漸變底色，文字反黑確保母帶規格清晰可辨。

---

## 9. 交互走查 (Interaction Walkthrough)

| 走查維度 | 走查項目 | 判定結果 | 備註 |
|---------|---------|---------|------|
| 雙重導覽消除 | 確認無任何二級 `IconButton(Icons.arrow_back)` 返回橫條 | ✅ 通過 | 徹底消除視覺雜訊與雙重標題衝突 |
| 吸頂導航體驗 | 滾動超過 180px 頂部工具列平滑淡入標題與播放膠囊 | ✅ 通過 | 滾動回頂部時自動隱匿，無跳變感 |
| 雙向歷史堆疊 | 進入藝人詳情再進入其他專輯，頂部 `<` 鍵逐層正確回退 | ✅ 通過 | 歷史回溯完全符合瀏覽器權威直覺 |
| 列表滾動效能 | 滾動曲目列表與切換發行版本維持 60fps+ 絲滑度 | ✅ 通過 | SliverList 協同渲染，無掉幀 |
| 鍵盤導航支援 | 支援鍵盤箭頭移動選中曲目、Enter 播放與 Space 暫停 | ✅ 通過 | 焦點指示清楚符合桌面無障礙標準 |

---

## 10. 特定場景微交互說明 (Micro-interaction Specifications)

**微交互場景：發行版本切換標籤 (Version Switcher Chip Selection)**
1. **觸發條件**：滑鼠單擊另一版本標籤（例如從 `Local` 點擊 `Qobuz Hi-Res`）。
2. **視覺變化**：
   - 被點擊的晶片背景自透明以 150ms 展開金色高光外圈（`border: 1px solid var(--color-accent-amber)`），文字由淡白轉為亮金。
   - 原選中之晶片平滑淡出邊框並降級為次級灰階。
   - 下方曲目規格標籤（Sample Rate Badges）進行微幅數值翻轉動畫（如從 `44.1 kHz` 旋轉刷新為 `192 kHz`）。
3. **動效參數**：時長 180ms，曲線 `Curves.easeInOutCubic`。
4. **反饋**：底欄狀態微型提示：「已切換為 Qobuz 192kHz/24-bit 母帶版本」。
5. **程式碼偽代碼**：
```dart
AnimatedContainer(
  duration: const Duration(milliseconds: 180),
  curve: Curves.easeInOutCubic,
  decoration: BoxDecoration(
    color: isSelected ? LuminaTokens.accentAmber.withOpacity(0.15) : LuminaTokens.surfaceGlass,
    border: Border.all(
      color: isSelected ? LuminaTokens.accentAmber : LuminaTokens.borderSubtle,
    ),
    borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
  ),
  child: VersionChipContent(...),
)
```
