# Lumina Audio — Handoff State [COMPLETED]

## Task Goal
依照 `ixd-design` 技能規範全面升級 Lumina Audio 桌面端互動架構，並落實**零終端機版本隔開（Zero-Terminal Version Separation）**：
1. **徹底根除截圖瑕疵**：消除專輯與歌手詳情頁中頂欄 `<` `>` 下方多餘的次級返回列與重複標題（如截圖中的 `← DROP - EP`），實作單一導覽錨點（Single-Anchor Navigation）與頂欄動態微吸頂標題（Dynamic Sticky Title）。
2. **零終端機版本隔離（實體硬碟資料夾）**：將 v1.0 與 v2.0 分置於獨立實體目錄，使用者無需使用命令列切換 Git 分支，直接在檔案總管或 IDE 即可開啟對比。
3. **軟體內介面版本即時切換鈕**：在桌面端頂部工具列直接提供「版本切換」選單（`v2.0 重構新版` ↔ `v1.0 原始舊版`），在運行中即可點擊即時無縫比對前後視覺與交互差異。
4. **桌面級微交互**：曲目清單曲目編號 30ms 懸停變形為播放圖示；滑鼠側鍵與全域桌面鍵盤快捷鍵（`Space`, `Alt+Left/Right`, `Backspace`, `Ctrl+F`, `M`, `Escape`）。
5. **完整互動設計文件**：依據 `ixd-design` 產出 Phase 1~4 共 12 份規格文件與前後對比報告。

---

## 零終端機版本對比指南（無需使用命令列）

### 1. 實體檔案目錄（可直接在檔案總管 / IDE 點擊開啟）
- **v1.0 原始版專案目錄**：
  [`versions/v1.0-baseline/`](file:///c:/Users/pierre/.gemini/antigravity/scratch/lumina-audio/versions/v1.0-baseline/)
  - 保留修改前的原始佈局。
  - 含有次級返回列與重複標題（如 `← DROP - EP`）。
- **v2.0 互動重構版專案目錄**：
  [`versions/v2.0-ixd-redesign/`](file:///c:/Users/pierre/.gemini/antigravity/scratch/lumina-audio/versions/v2.0-ixd-redesign/)
  - 徹底移除次級返回列，統一由頂欄 `<` `>` 控制歷史。
  - 滾動超過 200px 平滑淡入頂欄黏貼標題。
  - 30ms 懸停播放按鈕與全域桌面快捷鍵。

### 2. 運行中介面即時切換（In-App UI Switcher）
- 在執行中的 Lumina Audio 頂部工具列右側，點擊 **`v2.0 新版`** 標籤膠囊按鈕：
  - 選擇 **`v1.0 原始舊版`**：立即切換為舊版佈局，重現次級返回列與重複標題。
  - 選擇 **`v2.0 重構新版`**：立即切換為重構新版，享受無重複標題、單一導覽與動態微吸頂。
  - 全程零終端機輸入、無重啟延遲、播放音樂不中斷。

### 3. 詳細差異比對文件
- 完整對比說明文件：
  [`docs/ixd/DIFF_COMPARISON.md`](file:///c:/Users/pierre/.gemini/antigravity/scratch/lumina-audio/docs/ixd/DIFF_COMPARISON.md)

---

## Current Status & Verification
- **靜態分析**：`cd app; flutter analyze` → 0 issues found（0 錯誤、0 警告）。
- **測試套件**：`cd app; flutter test` → 130 / 130 tests passed（100% 通過，0 失敗）。
- **Git 標籤記錄**：
  - `v1.0-baseline`：commit `d36d33e`
  - `v2.0-ixd-redesign`：commit `18fe2e6`
