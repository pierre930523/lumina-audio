import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

/// Semantic frosted-glass and surface tokens supporting both Soft Misty Dark
/// Gray (`Brightness.dark`) and Light Frosted Glass (`Brightness.light`).
@immutable
class LuminaGlassTheme extends ThemeExtension<LuminaGlassTheme> {
  final Brightness brightness;
  final Color canvasBg;
  final Color glassBg;
  final Color glassBgElevated;
  final Color glassBgHover;
  final Color glassBgActive;
  final Color glassBorder;
  final Color glassBorderStrong;
  final double glassBlur;
  final double glassCardBlur;
  final List<BoxShadow> glassShadow;
  final List<BoxShadow> coverShadow;
  final List<BoxShadow> coverHoverShadow;
  final Color sidebarBg;
  final Color sidebarBorder;
  final Color playerBarBg;
  final Color playerBarBorder;
  final Color dialogBg;
  final Color menuBg;
  final Color scrimColor;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textDisabled;
  final Color accent;
  final Color pillBg;
  final Color pillHoverBg;
  final Color pillBorder;
  final List<Color> emptyCoverGradient;
  final Color emptyCoverIconColor;
  final Color auraDefaultPrimary;
  final Color auraDefaultSecondary;

  const LuminaGlassTheme({
    required this.brightness,
    required this.canvasBg,
    required this.glassBg,
    required this.glassBgElevated,
    required this.glassBgHover,
    required this.glassBgActive,
    required this.glassBorder,
    required this.glassBorderStrong,
    required this.glassBlur,
    required this.glassCardBlur,
    required this.glassShadow,
    required this.coverShadow,
    required this.coverHoverShadow,
    required this.sidebarBg,
    required this.sidebarBorder,
    required this.playerBarBg,
    required this.playerBarBorder,
    required this.dialogBg,
    required this.menuBg,
    required this.scrimColor,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.accent,
    required this.pillBg,
    required this.pillHoverBg,
    required this.pillBorder,
    required this.emptyCoverGradient,
    required this.emptyCoverIconColor,
    required this.auraDefaultPrimary,
    required this.auraDefaultSecondary,
  });

  bool get isDark => brightness == Brightness.dark;

  /// Soft Misty Dark Gray palette with WCAG 2.1 AA contrast (`>= 4.5:1`).
  static const LuminaGlassTheme dark = LuminaGlassTheme(
    brightness: Brightness.dark,
    canvasBg: Color(0xFF141518),
    glassBg: Color(0x12FFFFFF),
    glassBgElevated: Color(0x1EFFFFFF),
    glassBgHover: Color(0x24FFFFFF),
    glassBgActive: Color(0x29FFFFFF),
    glassBorder: Color(0x1AFFFFFF),
    glassBorderStrong: Color(0x2EFFFFFF),
    glassBlur: 28.0,
    glassCardBlur: 20.0,
    glassShadow: [
      BoxShadow(
        color: Color(0x47000000),
        blurRadius: 28,
        offset: Offset(0, 10),
      ),
    ],
    coverShadow: [
      BoxShadow(
        color: Color(0x4D000000),
        blurRadius: 22,
        offset: Offset(0, 8),
      ),
    ],
    coverHoverShadow: [
      BoxShadow(
        color: Color(0x6B000000),
        blurRadius: 30,
        offset: Offset(0, 12),
      ),
    ],
    sidebarBg: Color(0x7A101216),
    sidebarBorder: Color(0x14FFFFFF),
    playerBarBg: Color(0x94121418),
    playerBarBorder: Color(0x1AFFFFFF),
    dialogBg: Color(0xCC14161B),
    menuBg: Color(0xE0121418),
    scrimColor: Color(0x850E1014),
    textPrimary: Color(0xF2FFFFFF),
    textSecondary: Color(0xB8FFFFFF),
    textTertiary: Color(0x99FFFFFF),
    textDisabled: Color(0xFF5E6472),
    accent: Color(0xFF7B92F8),
    pillBg: Color(0x12FFFFFF),
    pillHoverBg: Color(0x24FFFFFF),
    pillBorder: Color(0x1FFFFFFF),
    emptyCoverGradient: [Color(0xFF232732), Color(0xFF171A22)],
    emptyCoverIconColor: Color(0x75FFFFFF),
    auraDefaultPrimary: Color(0xFF2B3A55),
    auraDefaultSecondary: Color(0xFF3A2E4D),
  );

  /// Bright Frosted Glass palette with WCAG 2.1 AA contrast (`>= 4.5:1`).
  static const LuminaGlassTheme light = LuminaGlassTheme(
    brightness: Brightness.light,
    canvasBg: Color(0xFFF3F5F9),
    glassBg: Color(0xB8FFFFFF),
    glassBgElevated: Color(0xCCFFFFFF),
    glassBgHover: Color(0xE0FFFFFF),
    glassBgActive: Color(0xF2FFFFFF),
    glassBorder: Color(0x180F172A),
    glassBorderStrong: Color(0x2E0F172A),
    glassBlur: 28.0,
    glassCardBlur: 20.0,
    glassShadow: [
      BoxShadow(
        color: Color(0x140F172A),
        blurRadius: 24,
        offset: Offset(0, 8),
      ),
    ],
    coverShadow: [
      BoxShadow(
        color: Color(0x1A0F172A),
        blurRadius: 20,
        offset: Offset(0, 8),
      ),
    ],
    coverHoverShadow: [
      BoxShadow(
        color: Color(0x290F172A),
        blurRadius: 28,
        offset: Offset(0, 12),
      ),
    ],
    sidebarBg: Color(0xB8FFFFFF),
    sidebarBorder: Color(0x160F172A),
    playerBarBg: Color(0xCCFFFFFF),
    playerBarBorder: Color(0x1E0F172A),
    dialogBg: Color(0xEBFFFFFF),
    menuBg: Color(0xF2FFFFFF),
    scrimColor: Color(0x9EF3F5F9),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF334155),
    textTertiary: Color(0xFF475569),
    textDisabled: Color(0xFF94A3B8),
    accent: Color(0xFF3B52D8),
    pillBg: Color(0x0C0F172A),
    pillHoverBg: Color(0x180F172A),
    pillBorder: Color(0x1A0F172A),
    emptyCoverGradient: [Color(0xFFE5E9F2), Color(0xFFD5DCE8)],
    emptyCoverIconColor: Color(0xFF64748B),
    auraDefaultPrimary: Color(0xFFC7D8F8),
    auraDefaultSecondary: Color(0xFFDCD3F5),
  );

  static LuminaGlassTheme of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<LuminaGlassTheme>() ??
        (theme.brightness == Brightness.light ? light : dark);
  }

  @override
  LuminaGlassTheme copyWith({
    Brightness? brightness,
    Color? canvasBg,
    Color? glassBg,
    Color? glassBgElevated,
    Color? glassBgHover,
    Color? glassBgActive,
    Color? glassBorder,
    Color? glassBorderStrong,
    double? glassBlur,
    double? glassCardBlur,
    List<BoxShadow>? glassShadow,
    List<BoxShadow>? coverShadow,
    List<BoxShadow>? coverHoverShadow,
    Color? sidebarBg,
    Color? sidebarBorder,
    Color? playerBarBg,
    Color? playerBarBorder,
    Color? dialogBg,
    Color? menuBg,
    Color? scrimColor,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textDisabled,
    Color? accent,
    Color? pillBg,
    Color? pillHoverBg,
    Color? pillBorder,
    List<Color>? emptyCoverGradient,
    Color? emptyCoverIconColor,
    Color? auraDefaultPrimary,
    Color? auraDefaultSecondary,
  }) {
    return LuminaGlassTheme(
      brightness: brightness ?? this.brightness,
      canvasBg: canvasBg ?? this.canvasBg,
      glassBg: glassBg ?? this.glassBg,
      glassBgElevated: glassBgElevated ?? this.glassBgElevated,
      glassBgHover: glassBgHover ?? this.glassBgHover,
      glassBgActive: glassBgActive ?? this.glassBgActive,
      glassBorder: glassBorder ?? this.glassBorder,
      glassBorderStrong: glassBorderStrong ?? this.glassBorderStrong,
      glassBlur: glassBlur ?? this.glassBlur,
      glassCardBlur: glassCardBlur ?? this.glassCardBlur,
      glassShadow: glassShadow ?? this.glassShadow,
      coverShadow: coverShadow ?? this.coverShadow,
      coverHoverShadow: coverHoverShadow ?? this.coverHoverShadow,
      sidebarBg: sidebarBg ?? this.sidebarBg,
      sidebarBorder: sidebarBorder ?? this.sidebarBorder,
      playerBarBg: playerBarBg ?? this.playerBarBg,
      playerBarBorder: playerBarBorder ?? this.playerBarBorder,
      dialogBg: dialogBg ?? this.dialogBg,
      menuBg: menuBg ?? this.menuBg,
      scrimColor: scrimColor ?? this.scrimColor,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textDisabled: textDisabled ?? this.textDisabled,
      accent: accent ?? this.accent,
      pillBg: pillBg ?? this.pillBg,
      pillHoverBg: pillHoverBg ?? this.pillHoverBg,
      pillBorder: pillBorder ?? this.pillBorder,
      emptyCoverGradient: emptyCoverGradient ?? this.emptyCoverGradient,
      emptyCoverIconColor: emptyCoverIconColor ?? this.emptyCoverIconColor,
      auraDefaultPrimary: auraDefaultPrimary ?? this.auraDefaultPrimary,
      auraDefaultSecondary: auraDefaultSecondary ?? this.auraDefaultSecondary,
    );
  }

  @override
  LuminaGlassTheme lerp(
    covariant ThemeExtension<LuminaGlassTheme>? other,
    double t,
  ) {
    if (other is! LuminaGlassTheme) return this;
    return LuminaGlassTheme(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvasBg: Color.lerp(canvasBg, other.canvasBg, t) ?? canvasBg,
      glassBg: Color.lerp(glassBg, other.glassBg, t) ?? glassBg,
      glassBgElevated:
          Color.lerp(glassBgElevated, other.glassBgElevated, t) ??
          glassBgElevated,
      glassBgHover:
          Color.lerp(glassBgHover, other.glassBgHover, t) ?? glassBgHover,
      glassBgActive:
          Color.lerp(glassBgActive, other.glassBgActive, t) ?? glassBgActive,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t) ?? glassBorder,
      glassBorderStrong:
          Color.lerp(glassBorderStrong, other.glassBorderStrong, t) ??
          glassBorderStrong,
      glassBlur: lerpDouble(glassBlur, other.glassBlur, t) ?? glassBlur,
      glassCardBlur:
          lerpDouble(glassCardBlur, other.glassCardBlur, t) ?? glassCardBlur,
      glassShadow:
          BoxShadow.lerpList(glassShadow, other.glassShadow, t) ?? glassShadow,
      coverShadow:
          BoxShadow.lerpList(coverShadow, other.coverShadow, t) ?? coverShadow,
      coverHoverShadow:
          BoxShadow.lerpList(coverHoverShadow, other.coverHoverShadow, t) ??
          coverHoverShadow,
      sidebarBg: Color.lerp(sidebarBg, other.sidebarBg, t) ?? sidebarBg,
      sidebarBorder:
          Color.lerp(sidebarBorder, other.sidebarBorder, t) ?? sidebarBorder,
      playerBarBg: Color.lerp(playerBarBg, other.playerBarBg, t) ?? playerBarBg,
      playerBarBorder:
          Color.lerp(playerBarBorder, other.playerBarBorder, t) ??
          playerBarBorder,
      dialogBg: Color.lerp(dialogBg, other.dialogBg, t) ?? dialogBg,
      menuBg: Color.lerp(menuBg, other.menuBg, t) ?? menuBg,
      scrimColor: Color.lerp(scrimColor, other.scrimColor, t) ?? scrimColor,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t) ?? textPrimary,
      textSecondary:
          Color.lerp(textSecondary, other.textSecondary, t) ?? textSecondary,
      textTertiary:
          Color.lerp(textTertiary, other.textTertiary, t) ?? textTertiary,
      textDisabled:
          Color.lerp(textDisabled, other.textDisabled, t) ?? textDisabled,
      accent: Color.lerp(accent, other.accent, t) ?? accent,
      pillBg: Color.lerp(pillBg, other.pillBg, t) ?? pillBg,
      pillHoverBg: Color.lerp(pillHoverBg, other.pillHoverBg, t) ?? pillHoverBg,
      pillBorder: Color.lerp(pillBorder, other.pillBorder, t) ?? pillBorder,
      emptyCoverGradient: _lerpColorList(
        emptyCoverGradient,
        other.emptyCoverGradient,
        t,
      ),
      emptyCoverIconColor:
          Color.lerp(emptyCoverIconColor, other.emptyCoverIconColor, t) ??
          emptyCoverIconColor,
      auraDefaultPrimary:
          Color.lerp(auraDefaultPrimary, other.auraDefaultPrimary, t) ??
          auraDefaultPrimary,
      auraDefaultSecondary:
          Color.lerp(auraDefaultSecondary, other.auraDefaultSecondary, t) ??
          auraDefaultSecondary,
    );
  }

  static List<Color> _lerpColorList(
    List<Color> a,
    List<Color> b,
    double t,
  ) {
    if (a.isEmpty && b.isEmpty) return const [];
    final maxLen = a.length > b.length ? a.length : b.length;
    return List<Color>.generate(maxLen, (i) {
      final ca = i < a.length ? a[i] : a.last;
      final cb = i < b.length ? b[i] : b.last;
      return Color.lerp(ca, cb, t) ?? ca;
    }, growable: false);
  }
}
