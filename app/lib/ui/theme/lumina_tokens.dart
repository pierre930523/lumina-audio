import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'lumina_glass_theme.dart';

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
  // Minimalist Dark Frosted Glass + Ambient + Gold Hi-Res Tokens
  // ---------------------------------------------------------------------------
  static const Color ambientScrimColor = Color(0x850E1014);
  static const double ambientBlurSigma = 80.0;
  static const double ambientCoverScale = 1.2;
  static const double ambientCoverSaturation = 1.35;
  static const double ambientNoiseOpacity = 0.035;
  static const Duration ambientTransitionDuration = Duration(milliseconds: 800);

  static const Color glassSidebarBg = Color(0x7A101216);
  static const double glassSidebarBlur = 28.0;
  static const Color glassSidebarBorder = Color(0x14FFFFFF);

  static const Color glassPillBg = Color(0x12FFFFFF);
  static const Color glassPillHoverBg = Color(0x24FFFFFF);
  static const double glassPillBlur = 16.0;
  static const Color glassPillBorder = Color(0x1FFFFFFF);

  static const Color glassPlayerBarBg = Color(0x94121418);
  static const double glassPlayerBarBlur = 32.0;
  static const Color glassPlayerBarBorder = Color(0x1AFFFFFF);

  static const Color glassNavActiveBg = Color(0x1FFFFFFF);
  static const Color glassRowHoverBg = Color(0x0FFFFFFF);
  static const Color glassDrawerBg = Color(0xA8101216);
  static const Color glassCoverRim = Color(0x29FFFFFF);
  static const Color glassTrackUnplayed = Color(0x38FFFFFF);

  static const Color hiResGoldBorder = Color(0xC7D4AF37);
  static const Color hiResGoldText = Color(0xFFE5C158);
  static const Color hiResGoldGlow = Color(0x40D4AF37);
  static const Color hiResGoldBg = Color(0x14D4AF37);

  // 4-tier dynamic <AudioQualityBadge /> & <AudioInfoPopover /> tokens
  static const Color badgeHiResBorder = Color.fromRGBO(229, 193, 88, 0.78);
  static const Color badgeHiResText = Color(0xFFE5C158);
  static const Color badgeHiResGlow = Color.fromRGBO(229, 193, 88, 0.22);
  static const Color badgeHiResBg = Color.fromRGBO(229, 193, 88, 0.08);
  static const double badgeHiResGlowBlur = 10.0;

  static const Color badgeLosslessBorder = Color.fromRGBO(255, 255, 255, 0.45);
  static const Color badgeLosslessText = Color(0xFFFFFFFF);
  static const Color badgeLosslessGlow = Color.fromRGBO(255, 255, 255, 0.15);
  static const Color badgeLosslessBg = Color.fromRGBO(255, 255, 255, 0.10);
  static const double badgeLosslessGlowBlur = 8.0;

  static const Color badgeHqBorder = Color.fromRGBO(255, 255, 255, 0.22);
  static const Color badgeHqText = Color.fromRGBO(255, 255, 255, 0.85);
  static const Color badgeHqBg = Color.fromRGBO(255, 255, 255, 0.06);

  static const Color badgeStandardBorder = Color.fromRGBO(255, 255, 255, 0.12);
  static const Color badgeStandardText = Color.fromRGBO(255, 255, 255, 0.50);
  static const Color badgeStandardBg = Colors.transparent;

  static const double qualityBadgeRadius = 4.0;
  static const Duration qualityBadgeTransitionDuration =
      Duration(milliseconds: 200);

  static const Color audioInfoPopoverBg = Color.fromRGBO(20, 22, 28, 0.85);
  static const Color audioInfoPopoverBorder =
      Color.fromRGBO(255, 255, 255, 0.12);
  static const double audioInfoPopoverBlur = 20.0;
  static const double audioInfoPopoverRadius = 10.0;

  static const Color glassTextPrimary = Color(0xF2FFFFFF);
  static const Color glassTextSecondary = Color(0xB8FFFFFF);
  static const Color glassTextTertiary = Color(0x80FFFFFF);

  static const Color glassSettingsRailBg = Color(0x3D101216);
  static const double glassSettingsRailBlur = 20.0;
  static const Color glassSettingsRailBorder = Color(0x14FFFFFF);

  static const Color glassCardBg = Color(0x0DFFFFFF);
  static const Color glassCardActiveBg = Color(0x1FFFFFFF);
  static const double glassCardBlur = 20.0;
  static const Color glassCardBorder = Color(0x1AFFFFFF);
  static const double glassCardRadius = 14.0;
  static const Color glassCardDivider = Color(0x0FFFFFFF);

  static const Color glassDialogBg = Color(0xCC14161B);
  static const double glassDialogBlur = 24.0;
  static const Color glassMenuBg = Color(0xE0121418);

  static const Color glassSwitchOffTrack = Color(0x24FFFFFF);
  static const Color glassSwitchOffBorder = Color(0x47FFFFFF);
  static const Color glassSwitchOffThumb = Color(0xF2FFFFFF);
  static const Color glassSwitchOnTrack = Color(0xE0FFFFFF);
  static const Color glassSwitchOnThumb = Color(0xFF141518);

  static const Color glassSegmentTrackBg = Color(0x0DFFFFFF);
  static const Color glassSegmentTrackBorder = Color(0x1AFFFFFF);
  static const Color glassSegmentSelectedBg = Color(0x29FFFFFF);
  static const Color glassSegmentSelectedBorder = Color(0x33FFFFFF);

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
  /// Semi-transparent [fg] colors are composited over [bg] first; if [bg] is
  /// semi-transparent, it is composited over [fallbackBg].
  static double contrastRatio(
    Color fg,
    Color bg, {
    Color fallbackBg = canvasBg,
  }) {
    final resolvedBg = bg.a < 1.0 ? compositeOver(bg, fallbackBg) : bg;
    final resolvedFg = fg.a < 1.0 ? compositeOver(fg, resolvedBg) : fg;
    final lum1 = relativeLuminance(resolvedFg);
    final lum2 = relativeLuminance(resolvedBg);
    final lighter = math.max(lum1, lum2);
    final darker = math.min(lum1, lum2);
    return (lighter + 0.05) / (darker + 0.05);
  }

  static ScrollbarThemeData _buildScrollbarTheme({
    required Color idleThumb,
    required Color activeThumb,
  }) {
    return ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith<double?>((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.dragged)) {
          return 6.5;
        }
        return 5.0;
      }),
      radius: const Radius.circular(999),
      thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.dragged)) {
          return activeThumb;
        }
        return idleThumb;
      }),
      trackColor: const WidgetStatePropertyAll<Color?>(Colors.transparent),
      trackBorderColor: const WidgetStatePropertyAll<Color?>(
        Colors.transparent,
      ),
    );
  }

  static SwitchThemeData _buildSwitchTheme({
    required Color disabledTrack,
    required Color selectedTrack,
    required Color unselectedTrack,
    required Color disabledThumb,
    required Color selectedThumb,
    required Color unselectedThumb,
    required Color disabledBorder,
    required Color focusBorder,
    required Color unselectedBorder,
    required Color hoverOverlay,
  }) {
    return SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.disabled)) return disabledTrack;
        if (states.contains(WidgetState.selected)) return selectedTrack;
        return unselectedTrack;
      }),
      thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.disabled)) return disabledThumb;
        if (states.contains(WidgetState.selected)) return selectedThumb;
        return unselectedThumb;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.disabled)) return disabledBorder;
        if (states.contains(WidgetState.focused)) return focusBorder;
        if (states.contains(WidgetState.selected)) return Colors.transparent;
        return unselectedBorder;
      }),
      trackOutlineWidth: WidgetStateProperty.resolveWith<double?>((states) {
        if (states.contains(WidgetState.focused)) return 1.5;
        if (states.contains(WidgetState.selected)) return 0.0;
        return 1.0;
      }),
      overlayColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.focused)) {
          return focusBorder.withValues(alpha: 0.22);
        }
        if (states.contains(WidgetState.hovered)) return hoverOverlay;
        return null;
      }),
    );
  }

  /// Shared dark [ThemeData] configured with Lumina Audio tokens.
  static ThemeData buildDarkTheme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      extensions: const [LuminaGlassTheme.dark],
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
      scrollbarTheme: _buildScrollbarTheme(
        idleThumb: const Color(0x2EFFFFFF),
        activeThumb: const Color(0x5CFFFFFF),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      switchTheme: _buildSwitchTheme(
        disabledTrack: glassPillBg,
        selectedTrack: glassSwitchOnTrack,
        unselectedTrack: glassSwitchOffTrack,
        disabledThumb: textDisabled,
        selectedThumb: glassSwitchOnThumb,
        unselectedThumb: glassSwitchOffThumb,
        disabledBorder: glassSidebarBorder,
        focusBorder: focusRing,
        unselectedBorder: glassSwitchOffBorder,
        hoverOverlay: glassRowHoverBg,
      ),
    );
  }

  /// Shared light [ThemeData] configured with Bright Frosted Glass tokens.
  static ThemeData buildLightTheme() {
    final base = ThemeData.light(useMaterial3: true);
    const light = LuminaGlassTheme.light;
    const cardSurface = Color(0xFFFFFFFF);
    return base.copyWith(
      extensions: const [LuminaGlassTheme.light],
      scaffoldBackgroundColor: light.canvasBg,
      canvasColor: light.canvasBg,
      cardColor: cardSurface,
      dividerColor: light.glassBorder,
      focusColor: light.accent.withValues(alpha: 0.20),
      hoverColor: light.pillHoverBg,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.light,
        primary: light.accent,
        onPrimary: Colors.white,
        secondary: const Color(0xFF7C3AED),
        onSecondary: Colors.white,
        surface: cardSurface,
        onSurface: light.textPrimary,
        onSurfaceVariant: light.textSecondary,
        outline: const Color(0xFF64748B),
        outlineVariant: const Color(0xFFCBD5E1),
        error: const Color(0xFFDC2626),
        onError: Colors.white,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 350),
        decoration: BoxDecoration(
          color: light.menuBg,
          borderRadius: BorderRadius.circular(radiusSm),
          border: Border.all(color: light.glassBorderStrong),
          boxShadow: light.glassShadow,
        ),
        textStyle: TextStyle(
          color: light.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: light.menuBg,
        contentTextStyle: TextStyle(color: light.textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          side: BorderSide(color: light.glassBorderStrong),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      scrollbarTheme: _buildScrollbarTheme(
        idleThumb: const Color(0x280F172A),
        activeThumb: const Color(0x520F172A),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: light.textPrimary,
        displayColor: light.textPrimary,
      ),
      switchTheme: _buildSwitchTheme(
        disabledTrack: light.pillBg,
        selectedTrack: light.accent,
        unselectedTrack: const Color(0x240F172A),
        disabledThumb: light.textDisabled,
        selectedThumb: Colors.white,
        unselectedThumb: light.textSecondary,
        disabledBorder: light.sidebarBorder,
        focusBorder: light.accent,
        unselectedBorder: const Color(0x470F172A),
        hoverOverlay: light.pillBg,
      ),
    );
  }
}
