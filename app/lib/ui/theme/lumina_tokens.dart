import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Design tokens for Lumina Audio dark-mode desktop UI.
///
/// Matches `design-system/lumina-audio/MASTER.md` and enforces WCAG 2.1 AA
/// contrast ratios (`>= 4.5:1` for normal readable text, `>= 3.0:1` for
/// non-text interactive control borders and accents).
abstract final class LuminaTokens {
  // ---------------------------------------------------------------------------
  // Surfaces
  // ---------------------------------------------------------------------------
  static const Color canvasBg = Color(0xFF141518);
  static const Color sidebarBg = Color(0xFF181A1F);
  static const Color cardBg = Color(0xFF1D1E22);
  static const Color cardElevatedBg = Color(0xFF242731);
  static const Color cardHoverBg = Color(0xFF282C38);
  static const Color scrimBg = Color(0xD90A0B0E);

  // ---------------------------------------------------------------------------
  // Borders & Focus
  // ---------------------------------------------------------------------------
  /// Decorative hairline divider between passive containers.
  static const Color borderSubtle = Color(0xFF2D313D);

  /// Interactive control border (chips, inputs, cards, toggles).
  /// Verified >= 3.0:1 non-text contrast against [canvasBg] (3.75:1),
  /// [cardBg] (3.42:1), and [cardElevatedBg] (3.06:1).
  static const Color borderControl = Color(0xFF687189);

  /// High-visibility keyboard focus ring (>= 7.3:1 on cards & canvas).
  static const Color focusRing = Color(0xFF93A8FF);

  // ---------------------------------------------------------------------------
  // Typography Colors (WCAG 2.1 AA verified)
  // ---------------------------------------------------------------------------
  /// Primary headings and titles (~17.45:1 on canvasBg, ~15.92:1 on cardBg).
  static const Color textPrimary = Color(0xFFF8FAFC);

  /// Secondary readable text (~10.02:1 on canvasBg, ~9.14:1 on cardBg).
  static const Color textSecondary = Color(0xFFB8C0D4);

  /// Muted readable captions & metadata (~7.12:1 on canvasBg, ~6.49:1 on cardBg).
  /// Guaranteed >= 4.5:1 WCAG AA across all dark surfaces.
  static const Color textMuted = Color(0xFF94A3B8);

  /// Strictly ONLY for genuinely disabled controls (`onPressed == null`,
  /// disabled nav buttons, or bypassed DSP controls). Never for readable text.
  static const Color textDisabled = Color(0xFF5E6472);

  // ---------------------------------------------------------------------------
  // Accents & Semantic Status
  // ---------------------------------------------------------------------------
  /// Primary interactive accent (~6.35:1 on canvasBg, ~5.80:1 on cardBg).
  static const Color accentBlue = Color(0xFF7B92F8);

  /// Strong accent fill / active border (~5.52:1 on canvasBg, ~5.04:1 on cardBg).
  static const Color accentBlueStrong = Color(0xFF6B85F7);

  /// Brand purple accent for badges/icons/borders (~4.61:1 on canvasBg, ~4.21:1 on cardBg).
  static const Color accentPurple = Color(0xFFA855F7);

  /// High-contrast purple for small readable labels (~6.91:1 on canvasBg, ~6.30:1 on cardBg).
  static const Color accentPurpleText = Color(0xFFC084FC);

  /// Dark ink for text placed directly on bright accent fills (>= 5.8:1 on accentBlue).
  static const Color onAccentDark = Color(0xFF0F172A);

  /// Semantic status colors (>= 6.0:1 on canvasBg & cardBg).
  static const Color statusSuccess = Color(0xFF34D399);
  static const Color statusWarning = Color(0xFFFBBF24);
  static const Color statusError = Color(0xFFF87171);
  static const Color statusErrorBg = Color(0xFF31191D);

  // ---------------------------------------------------------------------------
  // 4/8dp Spacing Rhythm
  // ---------------------------------------------------------------------------
  static const double space2xs = 4.0;
  static const double spaceXs = 8.0;
  static const double spaceSm = 12.0;
  static const double spaceMd = 16.0;
  static const double spaceLg = 24.0;
  static const double spaceXl = 32.0;
  static const double space2xl = 48.0;

  /// Minimum bottom scroll clearance for padded scroll containers.
  static const double bottomScrollClearance = 32.0;

  /// Bottom clearance when content scrolls underneath the floating mini-player bar.
  static const double floatingPlayerClearance = 104.0;

  // ---------------------------------------------------------------------------
  // Radii & Motion
  // ---------------------------------------------------------------------------
  static const double radiusSm = 8.0;
  static const double radiusMd = 12.0;
  static const double radiusLg = 16.0;
  static const double radiusPill = 999.0;

  static const Duration hoverDuration = Duration(milliseconds: 140);
  static const Duration focusDuration = Duration(milliseconds: 120);
  static const Curve motionCurve = Curves.easeOutCubic;

  // ---------------------------------------------------------------------------
  // WCAG 2.1 Contrast Utilities
  // ---------------------------------------------------------------------------
  static double _linearizeChannel(double c) {
    return c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  /// Alpha-composites [fg] over opaque [bg].
  static Color compositeOver(Color fg, Color bg) {
    if (fg.a >= 1.0) return fg;
    final a = fg.a;
    final invA = 1.0 - a;
    return Color.from(
      alpha: 1.0,
      red: fg.r * a + bg.r * invA,
      green: fg.g * a + bg.g * invA,
      blue: fg.b * a + bg.b * invA,
    );
  }

  /// Computes WCAG 2.1 relative luminance in `[0.0, 1.0]`.
  static double relativeLuminance(Color color) {
    final r = _linearizeChannel(color.r);
    final g = _linearizeChannel(color.g);
    final b = _linearizeChannel(color.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  /// Computes WCAG 2.1 contrast ratio between [fg] and [bg] (in `[1.0, 21.0]`).
  /// Semi-transparent [fg] colors are composited over [bg] first.
  static double contrastRatio(Color fg, Color bg) {
    final resolvedBg = bg.a < 1.0 ? compositeOver(bg, canvasBg) : bg;
    final resolvedFg = fg.a < 1.0 ? compositeOver(fg, resolvedBg) : fg;
    final lum1 = relativeLuminance(resolvedFg);
    final lum2 = relativeLuminance(resolvedBg);
    final lighter = math.max(lum1, lum2);
    final darker = math.min(lum1, lum2);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Shared dark [ThemeData] configured with Lumina Audio tokens.
  static ThemeData buildDarkTheme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: canvasBg,
      canvasColor: canvasBg,
      cardColor: cardBg,
      dividerColor: borderSubtle,
      focusColor: focusRing.withValues(alpha: 0.22),
      hoverColor: cardHoverBg.withValues(alpha: 0.7),
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: accentBlue,
        onPrimary: onAccentDark,
        secondary: accentPurple,
        onSecondary: textPrimary,
        surface: cardBg,
        onSurface: textPrimary,
        onSurfaceVariant: textSecondary,
        outline: borderControl,
        outlineVariant: borderSubtle,
        error: statusError,
        onError: onAccentDark,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 350),
        decoration: BoxDecoration(
          color: cardElevatedBg,
          borderRadius: BorderRadius.circular(radiusSm),
          border: Border.all(color: borderControl),
        ),
        textStyle: const TextStyle(
          color: textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cardElevatedBg,
        contentTextStyle: const TextStyle(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          side: const BorderSide(color: borderControl),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
    );
  }
}
