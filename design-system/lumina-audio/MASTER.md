# Lumina Audio Design System (MASTER)

**Target:** Lumina Audio (Desktop Audiophile Music Player — Windows / Flutter 3.50)
**Theme Direction:** High-Contrast OLED/Studio Dark Mode (`ui-ux-pro-max` compliant, Density 7/10)
**Source of Truth in Code:** `app/lib/ui/theme/lumina_tokens.dart` (`class LuminaTokens`)

---

## 1. Color Palette & WCAG AA Contrast Matrix

All normal readable text MUST achieve `>= 4.5:1` WCAG 2.1 AA contrast against its rendered background surface. Meaningful icons, active indicators, and interactive control borders MUST achieve `>= 3.0:1` non-text contrast.

### Surface Hierarchy
| Token | Hex | Role |
|---|---|---|
| `canvasBg` | `#141518` | Primary application background canvas |
| `sidebarBg` | `#181A1F` | Left navigation rail and secondary sidebar |
| `cardBg` | `#1D1E22` | Standard cards, rows, list containers |
| `cardElevatedBg` | `#242731` | Floating capsule, dialogs, popovers, active panels |
| `cardHoverBg` | `#282C38` | Hover/selected surface tint (no layout shift) |
| `scrimBg` | `#D90A0B0E` | Modal/overlay backdrop scrim (85% opacity) |

### Borders & Focus
| Token | Hex | Contrast vs `canvasBg` | Contrast vs `cardBg` | Role |
|---|---|---|---|---|
| `borderSubtle` | `#2D313D` | 1.41:1 | 1.28:1 | Decorative dividers & passive card outlines |
| `borderControl` | `#687189` | **3.75:1** | **3.42:1** | Interactive control borders, sliders, chips, toggles (`>= 3.0:1` AA; `3.06:1` on `cardElevatedBg`) |
| `focusRing` | `#93A8FF` | **8.07:1** | **7.36:1** | Keyboard focus outline (`2px` perimeter) |

### Typography Colors
| Token | Hex | Contrast vs `canvasBg` | Contrast vs `cardBg` | Contrast vs `cardElevatedBg` | Usage Rule |
|---|---|---|---|---|---|
| `textPrimary` | `#F8FAFC` | **17.45:1** | **15.92:1** | **14.24:1** | Headings, track/album titles, primary labels |
| `textSecondary` | `#B8C0D4` | **10.02:1** | **9.14:1** | **8.18:1** | Artist names, body descriptions, table values |
| `textMuted` | `#94A3B8` | **7.12:1** | **6.49:1** | **5.81:1** | Captions, metadata, timestamps, empty-state hints (replaces `Colors.white38`/`0xFF7E828E`) |
| `textDisabled` | `#5E6472` | 3.08:1 | 2.81:1 | 2.51:1 | **STRICTLY** for genuinely disabled controls (`onPressed: null`, bypassed DSP). Never for readable text. |

### Brand Accents & Semantic Status
| Token | Hex | Contrast vs `canvasBg` | Contrast vs `cardBg` | Role |
|---|---|---|---|---|
| `accentBlue` | `#7B92F8` | **6.35:1** | **5.80:1** | Primary interactive accent, active nav indicator, seekbar |
| `accentBlueStrong` | `#6B85F7` | **5.52:1** | **5.04:1** | Accent border/fill (pair dark text `onAccentDark` `#0F172A` on light fills, or use tinted dark fill `#1E2540` with `#F8FAFC` text) |
| `accentPurple` | `#A855F7` | **4.61:1** | **4.21:1** | Hi-Res / DSP accent badges & large borders (`>= 3.0:1`) |
| `accentPurpleText` | `#C084FC` | **6.91:1** | **6.30:1** | Small purple readable labels (`>= 4.5:1`) |
| `statusSuccess` | `#34D399` | **9.50:1** | **8.66:1** | Bit-perfect / Lossless / Connected status |
| `statusWarning` | `#FBBF24` | **10.94:1** | **9.98:1** | DSD / Format conversion / Caution states |
| `statusError` | `#F87171` | **6.60:1** | **6.02:1** | Audio device errors, validation failures |
| `onAccentDark` | `#0F172A` | — | — | Ink for bright solid accent buttons (`#0F172A` on `#7B92F8` = **5.86:1**) |

---

## 2. Spacing, Layout & Scroll Rhythm (4/8dp Scale)

- `space2xs = 4.0` — Tight icon-to-label gap, badge inner vertical padding
- `spaceXs = 8.0` — Compact gap between inline chips/controls
- `spaceSm = 12.0` — Card inner gap, list row spacing
- `spaceMd = 16.0` — Standard card padding, panel gutters
- `spaceLg = 24.0` — Section vertical spacing, page horizontal gutter
- `spaceXl = 32.0` — Major section break & `bottomScrollClearance` (`>= 24–32px`)
- `space2xl = 48.0` — Hero / empty-state breathing room

### Scroll & Virtualization Rules
1. **No unbounded `shrinkWrap: true` in scrollable pages**: Use `CustomScrollView` + `SliverList`/`SliverGrid` (or `ListView.builder` inside bounded `Expanded` containers) so large libraries virtualize cleanly.
2. **Bottom Scroll Clearance**: Every scrollable view MUST include bottom padding (`>= LuminaTokens.bottomScrollClearance`, and `>= 104px` where the floating bottom player capsule overlaps the scroll viewport) so fixed/floating bottom bars never obscure the last card or keyboard-focused item.
3. **HiDPI Scale Resilience**: All pages and overlays must render cleanly at both `100%` (`1.0x`) and `150%` (`1.5x`) UI scale with zero `RenderFlex` overflow.

---

## 3. Interaction, Cursor & Accessibility Standards

- **No Emojis as Structural Icons**: Use Material/Cupertino vector icons consistently (`Icons.*`).
- **Standalone Icon Controls**: Every `IconButton` or icon-only interactive target MUST provide a descriptive `tooltip` (or `Semantics(label: ..., button: true)`) and maintain a comfortable hit target (`>= 36–40px` desktop dense, `>= 44px` primary transport).
- **Cursor & Stable Hover/Focus States**: Interactive cards, chips, and list rows MUST use `SystemMouseCursors.click` (`MouseRegion` / `InkWell`) and animate color/border/opacity over `120–140ms` (`Curves.easeOutCubic`) **without** altering layout bounds, margins, or padding (no layout jitter).
- **Keyboard Focus Visibility**: Focusable controls must expose a visible `focusRing` (`#93A8FF`) or high-contrast surface tint.
- **Locale & Test Contract Integrity**: Preserve all existing Chinese UI copy and all widget `Key`s across refactors.
