# Lumina Audio — 全螢幕播放頁與歌詞頁交互修正與毛玻璃背景升級接續進度

## 1. 任務目標 (Task Goal)
修正 Lumina Audio Flutter 桌面端（`app/lib/`）全螢幕「正在播放」與「歌詞」頁面的 4 項 UI 排版、交互與視覺問題，並確保跨解析度與 100%/150% DPI 縮放自適應：
1. **移除全螢幕播放頁重複顯示的歌名與專輯資訊**：全螢幕開啟時，隱藏底部迷你播放控制列左下角的迷你封面、歌名與歌手區塊，僅保留畫面主體區的曲目資訊；返回主頁時自動恢復。
2. **歌詞設定工具列自動收合交互**：預設收合為精簡半透明毛玻璃圖示按鈕（`Aa` / `tune`，放置於右下角不干擾歌詞閱讀）；點擊展開完整工具列，支援收合按鈕、點擊外部空白、或無操作 4.5 秒後自動平滑收合，Hover 或調整字體/秒數期間不提前收合。
3. **歌詞垂直動態置中與消除硬切痕**：
   - 上下動態計算 `viewportHeight * 0.42` 留白，自動平滑滾動至 47% 視覺黃金中心。
   - 套用 `ShaderMask`（`BlendMode.dstIn`）讓頂部 0%~12% 與底部 84%~100% 平滑淡出至透明，消除文字硬切斷。
   - 全螢幕下底部播放控制列（`FloatingCapsuleMiniPlayer`）改為完全透明背景並移除頂部邊框，消除橫切硬線。
4. **全幅通透毛玻璃動態背景（Glassmorphism）升級**：
   - 底層結合 4 點動態流體光斑（`MeshFluidBgPainter`）與高半徑毛玻璃模糊。
   - 頂層加入通透高光與層次深度微調漸層，徹底擺脫死黑沉悶感。
   - 頂部收合按鈕（`btn_collapse_now_playing`）、模式切換膠囊（`_ModeIconButton`）與歌詞設定工具列全面採用半透明毛玻璃質感。

## 2. 修改檔案清單 (Modified Files)
- `app/lib/ui/mini_player/floating_capsule.dart`:
  - `_buildNowPlayingTrigger`: `widget.isNowPlayingExpanded` 時將左側迷你封面與曲目文字收合/隱藏，寬螢幕維持佔位寬度以保持中央控制項居中。
  - `liquid_glass_capsule`: `isExpanded` 時背景改為 `Colors.transparent`，移除頂部硬邊切痕 `border: null`。
- `app/lib/ui/lyrics/lyrics_view.dart`:
  - 新增 `Timer? _autoCollapseTimer` 與 `bool _toolbarHovered`，展開後滑鼠離開 4.5 秒無操作自動收合，互動或 hover 時重置/暫停。
  - 預設收合為右下角精簡半透明毛玻璃圖示膠囊（`Aa` + `tune`，`Key('btn_lyrics_toolbar_toggle')`）。
  - 展開工具列新增獨立收合按鈕（`Key('btn_lyrics_toolbar_close')`），背景新增全幅點擊監聽以支援點擊外部立即收合。
  - 外層套用 `ShaderMask(BlendMode.dstIn)` 頂底漸變淡出遮罩。
  - 上下動態內距 `viewportHeight * 0.42`，`_autoScrollTo` 滾動目標對齊至 47% 視覺黃金中心。
- `app/lib/ui/now_playing/now_playing_overlay.dart`:
  - 頂部收合按鈕與模式切換膠囊升級為半透明通透毛玻璃樣式（`BackdropFilter`、微弱白邊與半透明底色）。
  - 背景加入輕透玻璃高光與深淺自適應漸層遮罩，避免死黑沉悶。
- `app/test/now_playing_enhancement_test.dart`:
  - 新增 2 項完整 Widget 測試，驗證全螢幕下底部資訊隱藏、無硬邊框、歌詞 `ShaderMask`、單一膠囊按鈕、展開與收合、以及 4.5 秒自動收合邏輯。

## 3. 驗證現況 (Verification Status)
- `cd app; flutter analyze`: **0 issues found**。
- `cd app; flutter test test/now_playing_enhancement_test.dart`: **9 / 9 passed**。
- `cd app; flutter test test/lyrics_test.dart`: **2 / 2 passed**。
- `cd app; flutter test test/player_layout_fix_test.dart`: **10 / 10 passed**。

## 4. 下一步 (Next Steps)
1. 等候完整測試套件執行完畢（150 / 150 通過）。
2. 執行 Windows Release 建置產出最新執行檔：`cd app; flutter build windows --release`。
3. 驗證新版二進位檔可正常啟動無報錯，回報完整執行成果給使用者。
