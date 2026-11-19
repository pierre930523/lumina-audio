# Lumina Audio — Handoff State

## Task Goal
依照 `ixd-design` 技能標準，為 Lumina Audio 桌面端（Flutter Desktop）打造全方位專業級互動設計（IxD）規範與重構升級方案，徹底解決現有介面中導覽冗餘、雙重返回列、雙重標題衝突、層次割裂與操作反饋不一致等問題，產出完整互動方案供使用者過目審查。

---

## Current Status & Completed Work
1. **問題診斷完成**：
   - 使用者上傳截圖明確暴露了「雙重返回列與雙重標題」衝突問題（頂部工具列已有 `<` `>` 歷史鍵，下方又出現 `← DROP - EP` 次級導覽列，緊接著下方 Hero 區塊又出現巨型專輯標題 `DROP - EP`）。
   - 審視全站導覽架構，發現二級詳情頁（專輯、歌手）在有頂部全域導覽的情況下，缺乏統一的導覽層級與吸頂互動規範。
2. **`ixd-design` 技能標準對齊**：
   - 採用 Rams 簡約功能主義與現代桌面音樂軟體（Apple Music / Spotify / Roon）標準。
   - 規劃 8 大核心交互模組、22 種頁面分類覆蓋、全域鍵盤導航、微交互反饋與非阻塞式 60fps+ 渲染架構。
3. **完成互動設計全案架構撰寫**：
   - 產出詳細的互動設計重構方案供使用者過目審查。

---

## Unfinished / Next Action Steps
1. **等待使用者過目並審查交互設計方案**（若有特定調整要求，即時吸收修正）。
2. **審查通過後執行實施流程**：
   - 建立 `docs/ixd/` 目錄與 `progress.json` 追蹤結構。
   - 輸出 Phase 1（上下文與平台）、Phase 2（資訊架構）、Phase 3（使用者流程）、Phase 4（頁面規格）。
   - 啟動 Swarm 分工落實 Flutter 桌面端程式碼重構（移除重複導覽條、實現吸頂標題、健全全域鍵盤與微交互）。
   - 執行 `flutter analyze` 與 `flutter test` 完整驗證。

---

## Key Context & Commands
- Workspace: `c:\Users\pierre\.gemini\antigravity\scratch\lumina-audio`
- Skill Reference: `C:\Users\pierre\.gemini\config\skills\ixd-design\SKILL.md`
- Token System: `app/lib/ui/theme/lumina_tokens.dart`
- Navigation Controller: `app/lib/models/nav_entry.dart` & `app/lib/ui/home_screen.dart`
