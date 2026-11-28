import 'package:material_ui/material_ui.dart';

import '../theme/lumina_tokens.dart';

/// Shared WCAG AA-compliant frosted-glass control styles for Settings, DSP,
/// and Output Zones.
abstract final class LuminaSettingsStyles {
  static ButtonStyle outlinedButtonStyle({bool activeHighlight = false}) {
    return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return LuminaTokens.textDisabled;
        }
        return LuminaTokens.textPrimary;
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return LuminaTokens.glassPillBg.withValues(alpha: 0.04);
        }
        if (states.contains(WidgetState.hovered)) {
          return LuminaTokens.glassPillHoverBg;
        }
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing.withValues(alpha: 0.14);
        }
        if (activeHighlight) {
          return LuminaTokens.glassNavActiveBg;
        }
        return LuminaTokens.glassPillBg;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return LuminaTokens.glassNavActiveBg;
        }
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing.withValues(alpha: 0.16);
        }
        if (states.contains(WidgetState.hovered)) {
          return LuminaTokens.glassRowHoverBg;
        }
        return null;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return const BorderSide(
            color: LuminaTokens.glassSidebarBorder,
            width: 1.0,
          );
        }
        if (states.contains(WidgetState.focused)) {
          return const BorderSide(color: LuminaTokens.focusRing, width: 1.0);
        }
        if (states.contains(WidgetState.hovered) || activeHighlight) {
          return const BorderSide(
            color: LuminaTokens.glassCoverRim,
            width: 1.0,
          );
        }
        return const BorderSide(
          color: LuminaTokens.glassPillBorder,
          width: 1.0,
        );
      }),
      mouseCursor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return SystemMouseCursors.basic;
        }
        return SystemMouseCursors.click;
      }),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceMd,
          vertical: LuminaTokens.spaceSm,
        ),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        ),
      ),
    );
  }

  static ButtonStyle filledButtonStyle({
    Color backgroundColor = LuminaTokens.glassSwitchOnTrack,
    Color foregroundColor = LuminaTokens.onAccentDark,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: LuminaTokens.spaceMd,
      vertical: LuminaTokens.spaceSm,
    ),
    Size? minimumSize,
  }) {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return LuminaTokens.glassPillBg;
        }
        if (states.contains(WidgetState.hovered)) {
          return Color.lerp(backgroundColor, Colors.white, 0.12)!;
        }
        return backgroundColor;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return LuminaTokens.textDisabled;
        }
        return foregroundColor;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing.withValues(alpha: 0.24);
        }
        if (states.contains(WidgetState.pressed)) {
          return Colors.black.withValues(alpha: 0.14);
        }
        return null;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return const BorderSide(color: LuminaTokens.focusRing, width: 1.5);
        }
        if (states.contains(WidgetState.disabled)) {
          return const BorderSide(
            color: LuminaTokens.glassSidebarBorder,
            width: 1.0,
          );
        }
        return BorderSide.none;
      }),
      mouseCursor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return SystemMouseCursors.basic;
        }
        return SystemMouseCursors.click;
      }),
      padding: WidgetStatePropertyAll(padding),
      minimumSize: minimumSize != null ? WidgetStatePropertyAll(minimumSize) : null,
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        ),
      ),
    );
  }

  static ButtonStyle iconButtonStyle({Color? foregroundColor}) {
    return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return LuminaTokens.textDisabled;
        }
        return foregroundColor ?? LuminaTokens.glassTextSecondary;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing.withValues(alpha: 0.22);
        }
        if (states.contains(WidgetState.hovered)) {
          return LuminaTokens.glassPillHoverBg;
        }
        return null;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return const BorderSide(color: LuminaTokens.focusRing, width: 1.5);
        }
        return BorderSide.none;
      }),
      mouseCursor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return SystemMouseCursors.basic;
        }
        return SystemMouseCursors.click;
      }),
    );
  }

  static final WidgetStateProperty<Color?> switchTrackOutlineColor =
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return LuminaTokens.glassSidebarBorder;
        }
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing;
        }
        if (states.contains(WidgetState.selected)) {
          return Colors.transparent;
        }
        return LuminaTokens.glassSwitchOffBorder;
      });

  static MouseCursor switchMouseCursor({required bool enabled}) =>
      enabled ? SystemMouseCursors.click : SystemMouseCursors.basic;

  static InputDecoration inputDecoration({
    String? labelText,
    String? hintText,
    double borderRadius = LuminaTokens.radiusMd,
  }) {
    final radius = BorderRadius.circular(borderRadius);
    return InputDecoration(
      labelText: labelText,
      labelStyle: const TextStyle(color: LuminaTokens.textMuted, fontSize: 12),
      floatingLabelStyle: const TextStyle(
        color: LuminaTokens.glassTextPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      hintText: hintText,
      hintStyle: const TextStyle(color: LuminaTokens.textMuted, fontSize: 12.5),
      filled: true,
      fillColor: LuminaTokens.glassCardBg,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd,
        vertical: LuminaTokens.spaceSm,
      ),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.focusRing, width: 1.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.glassSidebarBorder),
      ),
    );
  }

  /// Frosted-glass capsule container decoration for segmented `ChoiceChip` rows.
  static BoxDecoration segmentedCapsuleDecoration({double radius = 10.0}) {
    return BoxDecoration(
      color: LuminaTokens.glassSegmentTrackBg,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: LuminaTokens.glassSegmentTrackBorder),
    );
  }

  /// Shared frosted-glass [ChoiceChip] builder for segmented controls.
  static ChoiceChip frostedSegmentChip({
    Key? key,
    required String label,
    required bool selected,
    required ValueChanged<bool>? onSelected,
    bool disabled = false,
    double fontSize = 12.5,
  }) {
    final bool isDisabled = disabled || onSelected == null;
    return ChoiceChip(
      key: key,
      label: Text(
        label,
        style: TextStyle(
          color: isDisabled
              ? LuminaTokens.textDisabled
              : (selected ? Colors.white : LuminaTokens.glassTextSecondary),
          fontSize: fontSize,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      selected: selected,
      showCheckmark: false,
      backgroundColor: Colors.transparent,
      disabledColor: Colors.transparent,
      selectedColor: isDisabled
          ? LuminaTokens.glassCardBg
          : LuminaTokens.glassSegmentSelectedBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      pressElevation: 0,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      ),
      side: BorderSide(
        color: isDisabled
            ? Colors.transparent
            : (selected
                  ? LuminaTokens.glassSegmentSelectedBorder
                  : Colors.transparent),
      ),
      onSelected: isDisabled ? null : onSelected,
    );
  }
}
