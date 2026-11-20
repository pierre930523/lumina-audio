# Lumina Audio — v0.2.0 Release & Distribution Notes

## 1. 任務目標 (Task Goal)
發布 Lumina Audio v0.2.0 版本並同步更新至 GitHub Repository（`pierre930523/lumina-audio`），包含全螢幕無框流光播放介面重構、封面與歌詞平滑轉場殘影修復、Win32 頂部視窗拖曳修正、閒置凍結與記憶體漏逸排查修復、全域背景提亮與原生 FLAC/複合音軌 Metadata 解析引擎升級，並提供最新安裝包與免安裝綠色版。

## 2. 完成修復與升級里程碑 (Completed Milestones)
1. **徹底消除播放控制區與專輯顯示區之間的明顯水平底線**：
   - 全螢幕播放頁的動態毛玻璃 Shader 與波形背景（`now_playing_ambient_bg`）貫穿整屏（`Positioned.fill`，從最頂端延伸至視窗最底緣 `height: 100%`）。
   - 全螢幕展開時，底部播放控制欄（`FloatingCapsuleMiniPlayer`）背景強制透明化（`Colors.transparent`），移除所有邊框線與陰影，懸浮於動態背景之上。
   - 底部控制列隱藏左下角重複顯示的封面與歌曲標題，全畫面保持單一資訊主體。
2. **徹底修正「封面 ↔ 歌詞」切換動畫的雙重拖影／殘影**：
   - 移除 `AnimatedSwitcher`，改採 `_modeAnimController` 單一狀態動畫驅動。
   - 封面卡片與曲目資訊保持固定 ValueKey，切換時不銷毀重建，只進行平滑連續位移與尺寸過渡。
   - 歌詞檢視本體使用 `FadeTransition` 單向漸變，徹底根除雙重封面與文字拖影。
3. **修復無邊框視窗無法正常拖動**：
   - Win32 C++ 端（`flutter_window.cpp`）修復 `startDragging`：透過 `GetCursorPos(&pt)` 獲取真實滑鼠座標並傳遞 `MAKELPARAM(pt.x, pt.y)`。
   - Flutter 端頂部全空白拖曳區統一採用 `Listener(onPointerDown)` 與 `GestureDetector(onDoubleTap)`，支援單擊拖動與雙擊最大化／還原。
4. **徹底排查並修復軟體放置一段時間後卡死（Freeze / Hang）**：
   - 暫停時取消 `_positionTimer`，杜絕每 200ms 空轉 FFI。
   - `PlaybackPersistenceService` 移除無限制的 `_saveChain`，改為單一執行標記 `_isSaving` 與 `_pendingSnapshot` 佇列機制，僅在狀態實質改變時儲存。
   - 暫停時自動停止 Shader 動態渲染計時器。
5. **再次大幅「提亮」全螢幕播放介面背景**：
   - 明度（Lightness）提升至 `0.32 ~ 0.72`，飽和度拉升至 `0.35 ~ 0.88`。
   - 頂部疊加輕量柔白高光層（`LinearGradient`），營造通透毛玻璃質感。
6. **專項排查與修復：整張專輯內嵌標籤（Metadata）全部讀錯**：
   - Rust 端（`dsd_meta.rs`）實作 `parse_track_and_disc_number`，全面支援 `1-02`、`01-05`、`1.02`、`03/12` 等音軌與光碟號格式。
   - `metadata.rs` 實作原生 FLAC 二進制解析器 `extract_flac_from_reader`，跳過非標準前置 ID3 檔頭精確命中 `fLaC`，直接解析 `VORBIS_COMMENT` 與 `METADATA_BLOCK_PICTURE`。
   - 排除常見系統目錄名稱（`desktop`、`music`、`downloads` 等），遇到 `CD1`、`Disc 2` 等子目錄時自動向上提取真實專輯目錄。
   - 新增專項單元測試 `test_flac_native_metadata_and_track_disc_parsing`（實測《空から降ってきた少女》/ 久石譲 / 天空の城ラピュタ ハイテック系列 / `1-02`），13 項測試全數 PASS。

## 3. 測試與建置驗證結果 (Verification Status)
- `cargo test -p core-providers`: **71 / 71 passed (100%)**
- `cd app; flutter analyze`: **No issues found! (0 warnings, 0 errors)**
- `cd app; flutter test`: **154 / 154 passed (100%)**
- `cd app; flutter build windows --release`: **成功建置 `lumina_app.exe`**
- Inno Setup 6: **成功編譯 `Lumina-Audio-Setup-v0.2.0.exe` (18.7 MB)**
- PowerShell: **成功打包 `Lumina-Audio-v0.2.0-Windows-x64.zip` (24.6 MB)**

## 4. GitHub Release 發布資訊 (GitHub Release Info)
- **Repository**: `https://github.com/pierre930523/lumina-audio`
- **Release Tag**: `v0.2.0`
- **安裝包 (Setup .exe)**: `dist/Lumina-Audio-Setup-v0.2.0.exe`
- **免安裝綠色包 (Portable .zip)**: `dist/Lumina-Audio-v0.2.0-Windows-x64.zip`
