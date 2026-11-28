import 'package:material_ui/material_ui.dart';

import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'settings_styles.dart';

export 'settings_styles.dart';

class SettingsGroupCard extends StatelessWidget {
  final String title;
  final String? description;
  final List<Widget> children;
  final bool enableBackdropBlur;

  const SettingsGroupCard({
    super.key,
    required this.title,
    this.description,
    required this.children,
    this.enableBackdropBlur = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(LuminaTokens.glassCardRadius);
    return ClipRRect(
      borderRadius: radius,
      child: FrostedGlassContainer(
        blurSigma: LuminaTokens.glassCardBlur,
        enableBackdropBlur: enableBackdropBlur,
        color: LuminaTokens.glassCardBg,
        borderRadius: radius,
        border: Border.all(color: LuminaTokens.glassCardBorder),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                LuminaTokens.spaceMd + LuminaTokens.space2xs,
                LuminaTokens.spaceMd,
                LuminaTokens.spaceMd + LuminaTokens.space2xs,
                description != null
                    ? LuminaTokens.space2xs
                    : LuminaTokens.spaceSm,
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
        hoverColor: LuminaTokens.glassRowHoverBg,
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
                color: LuminaTokens.glassPillBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(color: LuminaTokens.glassPillBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<T>(
                  key: dropdownKey,
                  value: value,
                  dropdownColor: LuminaTokens.glassMenuBg,
                  focusColor: LuminaTokens.focusRing.withValues(alpha: 0.18),
                  iconEnabledColor: LuminaTokens.glassTextSecondary,
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

/// Marks settings panels hosted inside `_HomeSettingsWorkspace`'s centered outer
/// scroll viewport so individual panels skip duplicate inner scrollbars.
class SettingsWorkspaceScope extends InheritedWidget {
  final bool managedByWorkspace;

  const SettingsWorkspaceScope({
    super.key,
    required this.managedByWorkspace,
    required super.child,
  });

  static bool isManaged(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<SettingsWorkspaceScope>()
            ?.managedByWorkspace ??
        false;
  }

  @override
  bool updateShouldNotify(SettingsWorkspaceScope oldWidget) =>
      managedByWorkspace != oldWidget.managedByWorkspace;
}

/// Wraps a settings panel body: delegates scrolling to the outer workspace
/// viewport when hosted inside Settings, while preserving standalone
/// `SingleChildScrollView` scrolling for isolated widget tests.
class SettingsScrollBody extends StatefulWidget {
  final Key? panelKey;
  final Key? scrollKey;
  final double? maxWidth;
  final EdgeInsetsGeometry standalonePadding;
  final Widget child;

  const SettingsScrollBody({
    super.key,
    this.panelKey,
    this.scrollKey,
    this.maxWidth,
    this.standalonePadding = const EdgeInsets.only(
      bottom: LuminaTokens.bottomScrollClearance,
    ),
    required this.child,
  });

  @override
  State<SettingsScrollBody> createState() => _SettingsScrollBodyState();
}

class _SettingsScrollBodyState extends State<SettingsScrollBody> {
  final GlideScrollController _scrollController = GlideScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final managed = SettingsWorkspaceScope.isManaged(context);
    if (managed) {
      return KeyedSubtree(
        key: widget.panelKey ?? widget.scrollKey,
        child: widget.child,
      );
    }
    final constrained = widget.maxWidth != null
        ? ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth!),
            child: widget.child,
          )
        : widget.child;
    return KeyedSubtree(
      key: widget.panelKey,
      child: SmoothScrollWrapper(
        controller: _scrollController,
        child: SingleChildScrollView(
          key: widget.panelKey == null ? widget.scrollKey : null,
          controller: _scrollController,
          padding: widget.standalonePadding,
          child: constrained,
        ),
      ),
    );
  }
}
