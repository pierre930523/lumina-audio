# Lumina Audio — v0.2.1 Release & GitHub Synchronization

## 1. 任務目標 (Task Goal)
將 Lumina Audio 更新版本（v0.2.1）同步發布至 GitHub Repository（`pierre930523/lumina-audio`），包含全視窗 100% 寬度頂部雙層拖曳條（`WindowDragBar`）、雙擊最大化／還原修復、無拖影「封面 ↔ 歌詞」切換動畫重構，並更新版本號至 `v0.2.1`，重新建置 Release 產物並建立 GitHub Release。

## 2. 完成修復與升級里程碑 (Completed Milestones)
1. **全視窗 100% 寬度頂部雙層拖曳條 (`WindowDragBar`)**：
   - 建立覆蓋全視窗最頂端（高度 48px）的統一雙層 Stack 標題列組件。
   - 底層：100% 滿版透明 `GestureDetector`，使用 `onPanStart` 避免搶佔事件，支援隨處點擊拖曳與流暢雙擊最大化／還原。
   - 頂層：保留左側返回／收合鍵、中間標題（`IgnorePointer` 穿透）、右側縮放選單與視窗三鍵，點擊互不干擾。
2. **無拖影「封面 ↔ 歌詞」切換動畫重構**：
   - 嚴格遵守 GPU Transform 規範，採用單一不銷毀的封面與曲目資訊元件（固定 Key）。
   - 外層由單一 `AnimationController`（`420ms`, `Curves.easeInOutCubic`）驅動，平滑位移與縮放，徹底消除雙重封面與文字拖影。
   - 歌詞檢視本體使用 `FadeTransition` 單向漸變淡入，背景層隔離於獨立 `RepaintBoundary`。
3. **版本號升級至 v0.2.1**：
   - `Cargo.toml`: `0.2.1`
   - `app/pubspec.yaml`: `0.2.1+3`
   - `installer/lumina_setup.iss`: `MyAppVersion "0.2.1"`, `OutputBaseFilename=Lumina-Audio-Setup-v0.2.1`
   - `README.md`: 更新版本徽章為 `v0.2.1`。
4. **視窗按鈕狀態自動同步**：
   - `DesktopWindowCaptionButtons` 混入 `WidgetsBindingObserver`，即時同步 Aero Snap 與快捷鍵最大化狀態。

## 3. 驗證與建置狀態 (Verification Status)
- `cd app; flutter analyze`: 執行中 (0 warnings, 0 errors 預期)
- `cd app; flutter test`: 167 / 167 passed (100%)
- 待執行步驟：
  1. `cd app; flutter build windows --release`
  2. 編譯 Inno Setup 安裝檔：`dist/Lumina-Audio-Setup-v0.2.1.exe`
  3. 壓縮綠色版：`dist/Lumina-Audio-v0.2.1-Windows-x64.zip`
  4. Git commit & tag `v0.2.1`，推送至 `origin main`
  5. 透過 `gh release create v0.2.1` 發布至 GitHub Releases

## 4. 異動檔案清單 (Modified Files)
- `Cargo.toml`
- `app/pubspec.yaml`
- `installer/lumina_setup.iss`
- `README.md`
- `HANDOFF.md`
- `app/lib/services/desktop_window_controller.dart`
- `app/lib/ui/common/desktop_window_caption.dart`
- `app/lib/ui/common/window_drag_bar.dart` (全新)
- `app/lib/ui/home_screen.dart`
- `app/lib/ui/now_playing/now_playing_overlay.dart`
- `app/test/now_playing_transition_test.dart` (全新)
- `app/test/ui/window_drag_bar_test.dart` (全新)
