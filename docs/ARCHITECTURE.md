# Lumina Audio — 系統架構規劃書

## 已確認的核心決策

1. **技術棧與跨平台 UI**：Rust 核心引擎 + Flutter 全平台 UI（`flutter_rust_bridge` + Impeller + 自訂 GLSL Fragment Shaders），Windows / macOS / iOS / Android 共用一套介面與 120Hz 動畫系統。
2. **部署與連線拓樸**：PC / Mac 桌面內嵌 Core（開 App 即用，亦支援切換獨立 Headless Server）+ 手機區網 mDNS 自動配對 + 外網支援 Tailscale / 自建反代 HTTPS/WSS URL 直連。
3. **Bit-Perfect 與 DSD**：Windows ASIO / WASAPI Exclusive、macOS CoreAudio Hog + Integer Mode，自動切換硬體取樣率；DSD 優先 Native ASIO / DoP，必要時才轉高品質 PCM 並在 Signal Path 如實顯示。
4. **音區抽象與 DSP**：Roon 式多區抽象 + 64-bit 浮點 DSP（PEQ / AutoEQ、Crossfeed、ReplayGain、一鍵 Bypass）；Phase 1/2 專注本機 DAC 與手機串流，DLNA / AirPlay 與跨房間同步排入 Phase 4。
5. **Phase 1 音源整合優先**：同步實作 Local (`FLAC`/`DSD`/`WAV`/`ALAC`) + `SMB/WebDAV` + `Qobuz`（支援 `user_auth_token` / 自訂 `app_id` & `app_secret` / 帳密）+ `Tidal` (OAuth2 PKCE) + `Deezer` (ARL)，待後端穩固後全面推進 Liquid Glass UI 打磨。
6. **Roon 級統合曲庫**：跨五大來源進行 Canonical Album / Work 合併與 Versions 多版本切換，結合檔案 Tag、串流資料、MusicBrainz 與 Discogs 建立樂手／製作人 Credit 圖譜。
7. **Apple Music Liquid Glass 規格**：支援深淺雙色自適應 + 封面流體 Mesh Shader + 邊緣透鏡折射與高光框 + 跟手形變懸浮膠囊 Mini-Player + 逐字歌詞景深模糊 + Signal Path 氣泡彈窗。
8. **Profile 與安全機制**：單一主曲庫 + 輕量切換 Profiles；敏感串流憑證存放於作業系統 Keyring；遠端配對使用一次性 PIN/QR + Bearer Token。

## 開發階段

- **Phase 1**：`core-types` / `core-db` / `core-providers`（五大音源 + Qobuz Token）/ `core-audio`（Windows ASIO & WASAPI Excl + Signal Path）/ `core-server`（Axum API + WebSocket + PIN 配對）。
- **Phase 2**：64-bit DSP 完整管線 + Flutter 桌面 App (`app/`) 與 Impeller Liquid Glass GLSL Shaders + `core-ffi`。
- **Phase 3**：iOS / Android 行動端雙模式（遙控電腦端 + 串流至手機本機與外接 DAC）。
- **Phase 4**：DLNA/UPnP、AirPlay 輸出與多房間時鐘同步。
