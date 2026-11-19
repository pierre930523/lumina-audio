# P06 音區管理與信號鏈路 (Zones & Signal Path) 交互規格書

## 1. 頁面概述 (Page Overview)

- **功能定位**：Lumina Audio 的專業 Hi-Fi 硬體調度中樞與信號鏈透視鏡。負責外接 USB DAC / 內建音訊端點選擇、WASAPI Exclusive / ASIO / CoreAudio Hog 獨占模式啟用、硬體採樣率即時匹配、64-bit 浮點 DSP 旁路（Bypass）控制，以及視覺化檢視從來源檔案到 DAC 類比輸出的端到端「真實信號鏈路（Signal Path）」。
- **所屬模組**：硬體音訊模組 (Hardware Audio Engine / Zones)
- **上游頁面**：頂部全域工具列「音區膠囊」、底部播放器右側「綠色 Bit-Perfect 發燒標章」點擊、全域快捷鍵 `Cmd/Ctrl+Z`
- **下游頁面**：P16 輸出硬體選擇器、P28 獨立 DSP 音訊設定、底層 Rust 音訊引擎
- **使用者目標**：一目了然驗證外接 DAC 是否處於 Bit-Perfect 無損直通狀態，快速在耳機、音響與串流音區之間無縫切換。

---

## 2. 頁面布局 (Layout Structure)

```
┌────────────────────────────────────────────────────────────────────────┐
│  音區管理與 Signal Path 彈窗面板 (液態玻璃半透明浮層 480×620px):        │
│                                                                        │
│  [面板標題: 音訊輸出區與信號路徑]                             [✕ 關閉] │
├────────────────────────────────────────────────────────────────────────┤
│  區域 A: 當前活動音區與輸出端點 (Active Zone Card)                     │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  ● 本機 USB 音訊區 (Local USB DAC)          [切換裝置 ▼]         │  │
│  │  硬體端點: Topping D90 III Sabre (ASIO)                          │  │
│  │  鎖定狀態: 192,000 Hz · 24-bit · 2 聲道                          │  │
│  │  [開關: Bit-Perfect 硬體獨占輸出] ━━━━━━━━━● (已啟用 / 綠光高亮) │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  區域 B: 可視化端到端信號鏈路 (End-to-End Signal Path)                  │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  [① 音源] FLAC 192kHz/24-bit (無損無混音解碼)                    │  │
│  │    │                                                             │  │
│  │    ▼ (綠色直通指示線)                                             │  │
│  │  [② 引擎] 64-bit 浮點 DSP (PEQ 已旁路 Bypass)                    │  │
│  │    │                                                             │  │
│  │    ▼ (綠色直通指示線)                                             │  │
│  │  [③ 輸出] WASAPI Exclusive / ASIO (硬體時鐘完美同步)              │  │
│  │    │                                                             │  │
│  │    ▼                                                             │  │
│  │  [④ DAC] ESS ES9038PRO 類比輸出: ★ BIT-PERFECT 直通              │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  區域 C: 可用音區快速切換列表 (Available Zones Switcher)                │
│  • [● 桌面發燒 DAC (當前)]   • [○ 客廳 Hi-Fi 串流區]   • [○ 藍牙耳機] │
├────────────────────────────────────────────────────────────────────────┤
│  底部輔助操作：[開啟進階 DSP 設置...]               [音訊硬體診斷日誌] │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 組件清單 (Component Inventory)

| 編號 | 組件名稱 | 組件類型 | 所在區域 | 交互行為 | 觸發條件 | 備註 |
|------|---------|---------|---------|---------|---------|------|
| C601 | 音區切換卡片 (Active Zone Card) | 狀態卡片 | 區域 A | 顯示當前驅動與端點名稱；支援懸浮點擊更換端點 | 始終展示 | 邊框具備翡翠綠呼吸高光 |
| C602 | 獨占直通開關 (Bit-Perfect Switch) | 滑動切換開關 (Switch) | 區域 A 右側 | 單擊開啟/關閉獨占模式；關閉時降級為系統共享混音器 | 點擊切換 | 開啟時觸發 Rust 底層硬體鎖定 |
| C603 | 信號鏈節點卡片 (Signal Path Node) | 流程節點 | 區域 B | 懸浮展開該步驟詳情（如具體 PEQ 濾波曲線、混音增益） | 始終展示 | 顏色：綠色(直通)/黃色(混音)/紫色(轉碼) |
| C604 | 旁路開關 (DSP Bypass Button) | 文字切換鈕 | 區域 B 第②節點 | 單擊一鍵旁路所有軟體等化器與聲道增益，還原純淨直通 | DSP 啟用時可見 | 點擊發出純直通提示 |
| C605 | 可用音區選擇列 (Zone Selector Row) | 單選分段卡片 | 區域 C | 單擊無縫將當前播放音訊路由至新音區 | 存在多音區時展示 | 支援淡入淡出無爆音轉移 |
| C606 | 面板關閉按鈕 (Close Button) | 圖標按鈕 | 頂部右上角 | 單擊關閉浮層面板；鍵盤 `Esc` 亦可關閉 | 始終展示 | 40×40px 熱區 |

---

## 4. 交互行為詳述 (Interaction Behaviors)

### C602 獨占直通開關 (Bit-Perfect Exclusive Toggle)
- **單擊啟用 (Toggle ON)**：
  - 開關滑塊以 160ms 滑向右側，底色轉為翡翠綠（`var(--color-status-success)`）。
  - Rust 核心向作業系統請求 ASIO / WASAPI Exclusive 鎖定。
  - 信號鏈路中央的連接線由虛線平滑變為實線祖母綠高光，底部標章變更為「★ BIT-PERFECT 直通」。
- **單擊關閉 (Toggle OFF)**：
  - 釋放硬體獨占，音訊路由回系統混音器（Shared Mode）。
  - 信號鏈路節點顯示黃色「OS Shared Mixer (48kHz 重新取樣)」警告標記。

### C603 信號鏈節點卡片 (Signal Path Node Hover)
- **懸浮 (Hover)**：
  - 節點背景微高亮，右側彈出 Tooltip，詳細展示取樣率變換公式（例如：`Source: 192000Hz/24bit -> Process: 64bit Float -> Output: 192000Hz/24bit (Lossless)`）。

### C605 音區快速切換
- **單擊切換音區**：
  - 音訊在 100ms 內執行餘弦淡出（Cosine Fade Out），音訊核心重新配置新音區端點時鐘，隨後以 100ms 淡入，保證無爆音（Pop-free）。

---

## 5. 頁面狀態流轉 (State Machine)

| 狀態 | 觸發條件 | 視覺表現 | 可執行操作 |
|------|---------|---------|-----------|
| **預設態 (Default)** | DAC 連線正常且處於 Bit-Perfect 狀態 | 綠色直通鏈路、端點參數完整顯示 | 所有開關、音區切換、DSP 旁路操作 |
| **加載態 (Loading)** | 正在重置音訊時鐘或切換輸出端點 | 節點鏈路呈現微光波紋流動，開關呈現不可點擊載入態 | 可按 Esc 關閉面板 |
| **無裝置空態 (Empty)** | 系統未偵測到任何可用 DAC 或本機音效卡 | 顯示「未偵測到音訊輸出裝置」警告 +「重新掃描」按鈕 | 單擊重新掃描硬體連接 |
| **端點衝突錯誤態 (Error)** | 外接 DAC 被其他程式（如 DAW）獨占鎖定 | 節點變紅，彈出警告「DAC 端點已被其他應用程式鎖定」+「降級共享」按鈕 | 點擊降級為共享模式播放 |
| **非直通共享態 (Partial)** | 使用者關閉獨占模式或啟用有失真 DSP | 節點鏈路呈淡黃色/紫色，標註「Shared 混音模式」或「DSP 處理中」 | 可點擊「一鍵還原直通」復原 |

---

## 6. 動效說明 (Motion Specs)

### 浮層展開與信號流波紋
- **面板展開**：採用 `Scale + FadeIn`，自點擊點（頂部音區膠囊或底欄徽章）向外擴散展開，時長 `var(--motion-duration-overlay)` (200ms)，曲線 `Curves.easeOutBack`。
- **信號鏈路流動動畫**：節點之間的實線指示箭頭呈現極微弱的能量流動光點循環（週期 2.5s），表示音訊正在無損流動。

---

## 7. 數據策略 (Data Loading Strategy)

- **FFI 硬體監聽事件流 (Hardware Event Stream)**：
  - Flutter 透過 `flutter_rust_bridge` 訂閱 Rust `AudioEngine` 的即時狀態廣播。
  - 當外接 DAC 拔出或硬體採樣率變動時，狀態在 20ms 內零延遲推播至 UI。

---

## 8. 適配說明 (Adaptation Rules)

### 桌面端多型態適配
- **大螢幕/標準視窗 (≥ 960px)**：作為錨定在頂部音區膠囊下方的 Popover 液態玻璃氣泡面板（寬度 480px）。
- **窄視窗 (< 960px)**：自動升級為底部抽屜式半透明 Modal Sheet（從底欄上方滑出，寬度 100%）。
- **深色模式對比**：純黑底色搭配綠色 `#10B981` 與金色 `#F59E0B`，高對比度且護眼。

---

## 9. 交互走查 (Interaction Walkthrough)

| 走查維度 | 走查項目 | 判定結果 | 備註 |
|---------|---------|---------|------|
| 專業發燒展示 | 信號鏈路節點從解碼、DSP 到硬體輸出真實透明無造假 | ✅ 通過 | 徹底消除音訊鏈路黑箱疑慮 |
| 獨占模式防爆音 | 開啟/關閉 Bit-Perfect 獨占輸出無刺耳爆音與閃退 | ✅ 通過 | 核心內建淡入淡出保護 |
| 操作反饋及時性 | 切換音區與旁路 DSP 在 50ms 內完成畫面反饋 | ✅ 通過 | 響應迅速無拖泥帶水 |
| 鍵盤控制 | 支援 Esc 鍵一鍵退出面板，Tab 鍵在開關與按鈕間游走 | ✅ 通過 | 完全符合桌面標準 |

---

## 10. 特定場景微交互說明 (Micro-interaction Specifications)

**微交互場景：Bit-Perfect 翡翠綠徽章點亮 (Bit-Perfect Emerald Glow Pulse)**
1. **觸發條件**：獨占模式鎖定成功且硬體採樣率完美匹配當前母帶。
2. **視覺變化**：
   - 信號鏈底部出現直徑 10px 的祖母綠光點。
   - 光點外圍以 300ms 釋放一圈柔和的綠色光暈光環（`box-shadow: 0 0 16px rgba(16, 185, 129, 0.6)`）。
   - 文字標記「★ BIT-PERFECT」以金色高光掃過一次（Shimmer Effect）。
3. **動效參數**：時長 300ms，曲線 `Curves.easeOutCubic`。
4. **反饋**：底欄常駐徽章同步轉為高光亮綠色。
5. **程式碼偽代碼**：
```dart
TweenAnimationBuilder<double>(
  tween: Tween(begin: 0.0, end: 1.0),
  duration: const Duration(milliseconds: 300),
  builder: (context, value, child) {
    return Container(
      decoration: BoxDecoration(
        color: LuminaTokens.statusSuccess,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: LuminaTokens.statusSuccess.withOpacity(0.6 * (1 - value)),
            blurRadius: 16 * value,
            spreadRadius: 4 * value,
          ),
        ],
      ),
    );
  },
)
```
