# Lumina Audio — 全視窗無縫一體化、毛玻璃視覺升級、播放狀態持久化與 Windows Release 交付

## 1. 任務目標 (Task Goal)
針對 Lumina Audio Flutter 桌面端（`app/`）完成 7 大項功能新增與視覺交互升級，並支援 100% / 150% DPI 縮放倍率、多種螢幕長寬比與視窗尺寸，解決截圖中反饋的問題：
1. **全視窗「無縫一體化」設計**：
   - 移除 Windows 原生深色系統標題列（去除 `lumina_app` 系統條）。
   - 將最小化、最大化/還原、關閉按鈕整合進 App 頂部透明覆蓋層右側，頂部空白區支援滑鼠拖曳移動視窗與雙擊最大化。
   - 全螢幕播放頁與主介面無縫融合，消除實心深色橫切切痕，讓動態流光光影從視窗最頂端無縫延展至最底端。
2. **整體介面與播放背景「提亮」與通透質感優化**：
   - 大幅降低播放頁底層黑色壓暗遮罩，調升專輯封面提取色彩的明度與飽和度（1.25x~1.45x boost），營造通透呼吸感。
3. **播放狀態持久化（關閉重開記住上次曲目與進度）**：
   - 本地 JSON 持久化，記錄上次曲目、進度 ms、佇列與 index、音量。
   - 切歌/暫停/seek 即時存、播放期間每 3.5 秒節流存、關閉視窗強制存。
   - 啟動自動恢復曲目與進度，維持暫停狀態，避免突發爆音。
4. **封面 ↔ 歌詞「絲滑水平滑移」切換動畫與音訊律動**：
   - 純封面模式在視窗正中央；點擊封面或歌詞按鈕時，封面由中央滑移至左側，歌詞淡入；點擊封面可切換回中央。
   - 視窗底邊增加柔和、低透明度、隨播放起伏的動態波形頻譜裝飾條（不干擾 Bit-Perfect 輸出）。
5. **跨螢幕與不同視窗比例下封面強制置中**：
   - 純封面模式下完全居中，消除偏左邏輯。
6. **跨螢幕歌詞自適應精準居中與工具列交互優化**：
   - 上下留白設為 `viewportHeight * 0.5`，唱到的歌詞行永遠精準垂直置中於 50%。
   - 使用者手動滾動歌詞時暫停自動滾動 4 秒後平滑恢復。
   - 歌詞設定工具列預設收合為單一精簡按鈕（`Aa`），點擊展開，4.5 秒無操作或點擊外部自動收合，不再遮擋歌詞。
7. **全站滑鼠滾輪平滑阻尼動畫（Smooth Scroll Physics）**：
   - 桌面端自訂平滑滾輪控制器（`SmoothScrollWrapper`），消除階梯跳格感。

## 2. 修改檔案清單 (Modified Files)
- `app/windows/runner/flutter_window.h` & `flutter_window.cpp`: 實現 `lumina/window` 原生視窗控制 MethodChannel。
- `app/windows/runner/win32_window.cpp`: 攔截 `WM_NCCALCSIZE` 去除 Windows 系統原生標題欄，保留 DWM 視窗陰影與 Aero Snap 邊界。
- `app/lib/services/desktop_window_controller.dart`: 封裝 Windows 視窗操作，Web/Test/非 Windows 平台安全降級為 no-op。
- `app/lib/ui/common/desktop_window_caption.dart`: 實現 Windows 11 風格之最小化、最大化/向下還原、關閉按鈕。
- `app/lib/services/playback_persistence_service.dart`: 支援曲目、進度、音量、佇列之快照序列化、節流儲存、即時儲存、錯誤容錯與恢復。
- `app/lib/ui/theme/smooth_scroll.dart`: 實現 `SmoothScrollWrapper`，桌面端平滑阻尼曲線插值滾動。
- `app/lib/ui/now_playing/dynamic_waveform_bar.dart`: 底部多諧波低透明度動態波形律動條。
- `app/lib/ui/lyrics/lyrics_view.dart`: 50% 垂直中心自動滾動、手動滾動 4 秒阻斷恢復、平滑滾動阻尼。
- `app/lib/ui/now_playing/now_playing_overlay.dart`: 整合無邊框標題欄、封面點擊切換、動態波形、色彩提亮。
- `app/lib/ui/home_screen.dart`: 修正主欄寬度自適應計算，整合標題欄按鈕與播放狀態自動儲存/恢復。
- `app/test/playback_persistence_service_test.dart`: 播放狀態持久化單元測試。
- `app/test/now_playing_enhancement_test.dart`: 播放介面增強功能 Widget 測試。

## 3. 驗證結果 (Verification Status)
- `cd app; flutter analyze`: **No issues found!** (0 errors, 0 warnings)。
- `cd app; flutter test -j 1`: **154 / 154 tests passed** (100% 通過率)。
- `cd app; flutter build windows --release`: **成功產出 Release 執行檔**：
  `app/build/windows/x64/runner/Release/lumina_app.exe`

## 4. 執行與測試方式 (How to Run)
在終端機執行或雙擊開啟：
`C:\Users\pierre\.gemini\antigravity\scratch\lumina-audio\app\build\windows\x64\runner\Release\lumina_app.exe`
