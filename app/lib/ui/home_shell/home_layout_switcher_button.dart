import 'package:material_ui/material_ui.dart';

import '../../models/home_layout_preset.dart';
import '../../services/ui_scale_controller.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';
import 'home_layout_wireframe.dart';
import 'library_overflow_drawer.dart';

/// Top toolbar button and viewport-clamped frosted-glass popover for live
/// switching across the home layout presets, light/dark glass theme, and
/// cover-aura / minimal-cover preferences.
class HomeLayoutSwitcherButton extends StatelessWidget {
  final UiScaleController scaleController;
  final VoidCallback? onOpenAppearanceSettings;

  const HomeLayoutSwitcherButton({
    super.key,
    required this.scaleController,
    this.onOpenAppearanceSettings,
  });

  static const _options = <({HomeLayoutPreset preset, String keyName, String title})>[
    (preset: HomeLayoutPreset.auraQuickResume, keyName: 'layout_option_aura_quick_resume', title: '光暈快速續播 (AJ)'),
    (preset: HomeLayoutPreset.topbarMinimal, keyName: 'layout_option_topbar_minimal', title: '無側欄極簡 (AI)'),
    (preset: HomeLayoutPreset.classic, keyName: 'layout_option_classic', title: '經典排版'),
  ];

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    return ClampedGlassPopoverAnchor(
      barrierKey: const Key('home_layout_switcher_barrier'),
      popoverKey: const Key('home_layout_switcher_popover'),
      preferredWidth: 348.0,
      preferredMaxHeight: 560.0,
      anchorBuilder: (ctx, isOpen, toggle) => ListenableBuilder(
        listenable: scaleController,
        builder: (context, _) => FrostedGlassContainer(
          blurSigma: LuminaTokens.glassPillBlur,
          color: isOpen ? glass.glassBgActive : glass.pillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(
            color: isOpen ? glass.glassBorderStrong : glass.pillBorder,
          ),
          child: IconButton(
            key: const Key('btn_home_layout_switcher'),
            tooltip: '排版外觀',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            hoverColor: glass.pillHoverBg,
            icon: Icon(
              isOpen
                  ? Icons.dashboard_customize_rounded
                  : Icons.dashboard_customize_outlined,
              size: 17,
              color: isOpen ? glass.textPrimary : glass.textSecondary,
            ),
            onPressed: toggle,
          ),
        ),
      ),
      popoverBuilder: (ctx, close) => ListenableBuilder(
        listenable: scaleController,
        builder: (innerCtx, _) => _buildPopoverBody(innerCtx, close),
      ),
    );
  }

  Widget _buildPopoverBody(BuildContext context, VoidCallback close) {
    final glass = LuminaGlassTheme.of(context);
    final activePreset = scaleController.homeLayoutPreset;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(LuminaTokens.spaceMd),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '排版外觀',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: glass.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                key: const Key('btn_home_layout_switcher_close'),
                tooltip: '關閉排版外觀',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  foregroundColor: glass.textSecondary,
                  hoverColor: glass.glassBgHover,
                ),
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: close,
              ),
            ],
          ),
          Divider(color: glass.glassBorder, height: LuminaTokens.spaceMd),
          for (var i = 0; i < _options.length; i += 2) ...[
            if (i > 0) const SizedBox(height: LuminaTokens.spaceXs),
            Row(
              children: [
                Expanded(
                  child: _WireframePresetCard(
                    key: Key(_options[i].keyName),
                    preset: _options[i].preset,
                    title: _options[i].title,
                    selected: activePreset == _options[i].preset,
                    onTap: () =>
                        scaleController.setHomeLayoutPreset(_options[i].preset),
                  ),
                ),
                const SizedBox(width: LuminaTokens.spaceXs),
                if (i + 1 < _options.length)
                  Expanded(
                    child: _WireframePresetCard(
                      key: Key(_options[i + 1].keyName),
                      preset: _options[i + 1].preset,
                      title: _options[i + 1].title,
                      selected: activePreset == _options[i + 1].preset,
                      onTap: () => scaleController.setHomeLayoutPreset(
                        _options[i + 1].preset,
                      ),
                    ),
                  )
                else
                  const Spacer(),
              ],
            ),
          ],
          Divider(color: glass.glassBorder, height: LuminaTokens.spaceLg),
          Text(
            '毛玻璃主題',
            style: TextStyle(
              color: glass.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          Row(
            children: [
              Expanded(
                child: _ThemeQuickPill(
                  key: const Key('switcher_theme_light'),
                  icon: Icons.light_mode_rounded,
                  label: '明亮毛玻璃',
                  selected: scaleController.themeMode == ThemeMode.light,
                  onTap: () => scaleController.setThemeMode(ThemeMode.light),
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceXs),
              Expanded(
                child: _ThemeQuickPill(
                  key: const Key('switcher_theme_dark'),
                  icon: Icons.dark_mode_rounded,
                  label: '柔霧深灰',
                  selected: scaleController.themeMode == ThemeMode.dark,
                  onTap: () => scaleController.setThemeMode(ThemeMode.dark),
                ),
              ),
            ],
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          _switchRow(
            glass,
            key: const Key('switcher_switch_aura_follow_cover'),
            label: '動態光暈跟隨封面',
            value: scaleController.auraFollowCover,
            onChanged: scaleController.setAuraFollowCover,
          ),
          _switchRow(
            glass,
            key: const Key('switcher_switch_minimal_cover_mode'),
            label: '極簡封面模式',
            value: scaleController.minimalCoverMode,
            onChanged: scaleController.setMinimalCoverMode,
          ),
          if (onOpenAppearanceSettings != null) ...[
            const SizedBox(height: LuminaTokens.spaceSm),
            OutlinedButton.icon(
              key: const Key('btn_switcher_open_appearance'),
              style: OutlinedButton.styleFrom(
                backgroundColor: glass.pillBg,
                foregroundColor: glass.textPrimary,
                side: BorderSide(color: glass.pillBorder),
                padding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceSm,
                  vertical: LuminaTokens.spaceXs,
                ),
              ),
              onPressed: () {
                close();
                onOpenAppearanceSettings!();
              },
              icon: const Icon(Icons.tune_rounded, size: 15),
              label: const Text('更多外觀與縮放設定', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _switchRow(
    LuminaGlassTheme glass, {
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: glass.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Transform.scale(
          scale: 0.86,
          alignment: Alignment.centerRight,
          child: Switch(key: key, value: value, onChanged: onChanged),
        ),
      ],
    );
  }
}

class _WireframePresetCard extends StatefulWidget {
  final HomeLayoutPreset preset;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _WireframePresetCard({
    super.key,
    required this.preset,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_WireframePresetCard> createState() => _WireframePresetCardState();
}

class _WireframePresetCardState extends State<_WireframePresetCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: LuminaTokens.hoverDuration,
          curve: LuminaTokens.motionCurve,
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: widget.selected
                ? glass.glassBgActive
                : (_hovered ? glass.glassBgHover : glass.glassBg),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? glass.accent
                  : (_hovered ? glass.glassBorderStrong : glass.glassBorder),
              width: widget.selected ? 1.4 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HomeLayoutWireframe(
                preset: widget.preset,
                selected: widget.selected,
                height: 50,
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.selected
                            ? glass.textPrimary
                            : glass.textSecondary,
                        fontSize: 11.5,
                        fontWeight: widget.selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 13,
                      color: glass.accent,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeQuickPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeQuickPill({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    return Material(
      color: selected ? glass.glassBgActive : glass.pillBg,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        hoverColor: glass.pillHoverBg,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            border: Border.all(color: selected ? glass.accent : glass.pillBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? glass.textPrimary : glass.textSecondary,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? glass.textPrimary : glass.textSecondary,
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
