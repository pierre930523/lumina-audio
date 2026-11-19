# Lumina Audio

跨平台發燒級 Hi-Fi 音樂管理與多區播放系統，結合：

- **Roon 級曲庫與透明音訊管線**：跨來源統合專輯（Canonical Merging）、多版本切換（Versions）、樂手／製作人關聯（Credits）與即時 **Signal Path** 顯示。
- **Music Assistant 式開放音源架構**：統一 `MusicProvider` 介面，原生支援本機無損庫、`SMB/WebDAV`、`Qobuz`（支援 `user_auth_token` 直連、自訂 `app_id`/`app_secret` 或帳密）、`Tidal`（OAuth2 PKCE）與 `Deezer`（ARL）。
- **Bit-Perfect 硬體獨佔引擎**：Windows **ASIO / WASAPI Exclusive**、macOS **CoreAudio Hog Mode** 自動切換取樣率與 Native DSD / DoP，搭配 64-bit 浮點 DSP（PEQ / AutoEQ / Crossfeed / ReplayGain，可一鍵 Bypass）。
- **Apple Music Liquid Glass 全端 UI**：以 Flutter Impeller + 自訂 GLSL Fragment Shader 打造 Windows、macOS、iOS 與 Android 共用介面（封面流體背景、邊緣折射高光玻璃、跟手形變懸浮膠囊 Mini-Player 與景深模糊逐字歌詞）。

---

## 專案架構

```text
lumina-audio/
├── Cargo.toml                  # Rust Core Workspace
├── crates/
│   ├── core-types/             # 共用領域模型 (Album, Version, SignalPath, Zone, Provider)
│   ├── core-db/                # SQLite (WAL + FTS5) 曲庫與多 Profile 資料層
│   ├── core-providers/         # Local, SMB/WebDAV, Qobuz, Tidal, Deezer, MusicBrainz
│   ├── core-audio/             # Symphonia/DSD 解碼、64-bit DSP、ASIO/WASAPI/CoreAudio
│   ├── core-server/            # Axum HTTP/WS API、mDNS 自動探索、PIN 配對認證
│   └── core-ffi/               # flutter_rust_bridge 桌面內嵌橋接層
├── app/                        # Flutter 全平台 App (Win / Mac / iOS / Android)
│   └── shaders/                # Impeller GLSL Fragment Shaders (Liquid Glass / Fluid Mesh)
└── docs/
    └── ARCHITECTURE.md         # 完整架構設計書
```

詳細系統設計請參閱 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。
