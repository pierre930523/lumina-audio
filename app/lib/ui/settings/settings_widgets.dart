import 'package:material_ui/material_ui.dart';

import '../theme/lumina_tokens.dart';

/// Shared WCAG AA-compliant control styles for Settings, DSP, and Output Zones.
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
        if (states.contains(WidgetState.hovered)) {
          return LuminaTokens.cardHoverBg.withValues(alpha: 0.7);
        }
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing.withValues(alpha: 0.14);
        }
        return Colors.transparent;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return LuminaTokens.accentBlue.withValues(alpha: 0.18);
        }
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing.withValues(alpha: 0.16);
        }
        if (states.contains(WidgetState.hovered)) {
          return LuminaTokens.cardHoverBg.withValues(alpha: 0.5);
        }
        return null;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return const BorderSide(color: LuminaTokens.borderSubtle, width: 1.0);
        }
        if (states.contains(WidgetState.focused)) {
          return const BorderSide(color: LuminaTokens.focusRing, width: 1.0);
        }
        if (states.contains(WidgetState.hovered) || activeHighlight) {
          return const BorderSide(color: LuminaTokens.accentBlue, width: 1.0);
        }
        return const BorderSide(color: LuminaTokens.borderControl, width: 1.0);
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
    Color backgroundColor = LuminaTokens.accentBlue,
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
          return LuminaTokens.cardElevatedBg;
        }
        if (states.contains(WidgetState.hovered)) {
          return Color.lerp(backgroundColor, Colors.white, 0.08)!;
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
          return const BorderSide(color: LuminaTokens.borderSubtle, width: 1.0);
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
        return foregroundColor ?? LuminaTokens.textSecondary;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return LuminaTokens.focusRing.withValues(alpha: 0.22);
        }
        if (states.contains(WidgetState.hovered)) {
          return LuminaTokens.cardHoverBg.withValues(alpha: 0.75);
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
          return LuminaTokens.borderSubtle;
        }
        if (states.contains(WidgetState.selected)) {
          return LuminaTokens.accentBlueStrong;
        }
        return LuminaTokens.borderControl;
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
        color: LuminaTokens.accentBlue,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      hintText: hintText,
      hintStyle: const TextStyle(color: LuminaTokens.textMuted, fontSize: 12.5),
      filled: true,
      fillColor: LuminaTokens.cardElevatedBg,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd,
        vertical: LuminaTokens.spaceSm,
      ),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.borderControl),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.borderControl),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.focusRing, width: 1.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: LuminaTokens.borderSubtle),
      ),
    );
  }
}

class SettingsGroupCard extends StatelessWidget {
  final String title;
  final String? description;
  final List<Widget> children;

  const SettingsGroupCard({
    super.key,
    required this.title,
    this.description,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: LuminaTokens.cardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        border: Border.all(color: LuminaTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              LuminaTokens.spaceMd + LuminaTokens.space2xs,
              LuminaTokens.spaceMd,
              LuminaTokens.spaceMd + LuminaTokens.space2xs,
              description != null ? LuminaTokens.space2xs : LuminaTokens.spaceSm,
            ),
            child: Text(
              title,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LuminaTokens.spaceMd + LuminaTokens.space2xs,
                0,
                LuminaTokens.spaceMd + LuminaTokens.space2xs,
                LuminaTokens.spaceSm,
              ),
              child: Text(
                description!,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ...children,
          const SizedBox(height: LuminaTokens.space2xs),
        ],
      ),
    );
  }
}

class SettingsSwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? helperNote;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.helperNote,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final statusTip = enabled
        ? '$title：${value ? '已開啟' : '已關閉'}'
        : '$title（已停用）';

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.45),
        focusColor: LuminaTokens.focusRing.withValues(alpha: 0.16),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
            vertical: LuminaTokens.spaceSm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: enabled
                            ? LuminaTokens.textPrimary
                            : LuminaTokens.textDisabled,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: LuminaTokens.space2xs),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: enabled
                            ? LuminaTokens.textMuted
                            : LuminaTokens.textDisabled,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    if (helperNote != null) ...[
                      const SizedBox(height: LuminaTokens.spaceXs),
                      Text(
                        helperNote!,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceMd),
              Tooltip(
                message: statusTip,
                child: Switch(
                  value: value,
                  activeTrackColor: LuminaTokens.accentBlueStrong,
                  activeThumbColor: LuminaTokens.textPrimary,
                  inactiveTrackColor: LuminaTokens.cardElevatedBg,
                  inactiveThumbColor: enabled
                      ? LuminaTokens.textSecondary
                      : LuminaTokens.textDisabled,
                  trackOutlineColor:
                      LuminaSettingsStyles.switchTrackOutlineColor,
                  mouseCursor: LuminaSettingsStyles.switchMouseCursor(
                    enabled: enabled,
                  ),
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const SettingsInfoRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
        vertical: LuminaTokens.spaceSm,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceMd),
          Flexible(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsActionRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String buttonLabel;
  final Key? buttonKey;
  final VoidCallback? onPressed;

  const SettingsActionRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.buttonLabel,
    this.buttonKey,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
        vertical: LuminaTokens.spaceSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: LuminaTokens.space2xs),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceMd),
          Tooltip(
            message: buttonLabel,
            child: OutlinedButton(
              key: buttonKey,
              onPressed: onPressed,
              style: LuminaSettingsStyles.outlinedButtonStyle(),
              child: Text(buttonLabel, style: const TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsDropdownRow<T> extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Key? dropdownKey;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const SettingsDropdownRow({
    super.key,
    required this.title,
    this.subtitle,
    this.dropdownKey,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
        vertical: LuminaTokens.spaceSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: LuminaTokens.space2xs),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceMd),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceSm,
              ),
              decoration: BoxDecoration(
                color: LuminaTokens.cardElevatedBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(color: LuminaTokens.borderControl),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<T>(
                  key: dropdownKey,
                  value: value,
                  dropdownColor: LuminaTokens.cardElevatedBg,
                  focusColor: LuminaTokens.focusRing.withValues(alpha: 0.18),
                  iconEnabledColor: LuminaTokens.textSecondary,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  items: items,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
