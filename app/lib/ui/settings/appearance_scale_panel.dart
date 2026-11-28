import 'package:material_ui/material_ui.dart';

import '../../models/home_layout_preset.dart';
import '../../services/ui_scale_controller.dart';
import '../common/frosted_glass_container.dart';
import '../home_shell/home_layout_wireframe.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

class AppearanceAndScalePanel extends StatelessWidget {
  final UiScaleController scaleController;

  const AppearanceAndScalePanel({
    super.key,
    required this.scaleController,
  });

  static const _layoutOptions = <({HomeLayoutPreset preset, String keyName, String title})>[
    (preset: HomeLayoutPreset.auraQuickResume, keyName: 'settings_layout_option_aura_quick_resume', title: '光暈快速續播 (AJ)'),
    (preset: HomeLayoutPreset.topbarMinimal, keyName: 'settings_layout_option_topbar_minimal', title: '無側欄極簡 (AI)'),
    (preset: HomeLayoutPreset.classic, keyName: 'settings_layout_option_classic', title: '經典排版'),
  ];

  static const _themeModes = <({ThemeMode mode, String keyName, String label, IconData icon})>[
    (mode: ThemeMode.dark, keyName: 'theme_mode_dark', label: '柔霧深灰', icon: Icons.dark_mode_rounded),
    (mode: ThemeMode.light, keyName: 'theme_mode_light', label: '明亮毛玻璃', icon: Icons.light_mode_rounded),
    (mode: ThemeMode.system, keyName: 'theme_mode_system', label: '跟隨系統', icon: Icons.brightness_auto_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: scaleController,
      builder: (context, _) {
        final glass = LuminaGlassTheme.of(context);
        return SettingsScrollBody(
          panelKey: const Key('appearance_scale_panel'),
          standalonePadding: const EdgeInsets.fromLTRB(
            LuminaTokens.spaceLg,
            LuminaTokens.spaceMd,
            LuminaTokens.spaceLg,
            LuminaTokens.bottomScrollClearance,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHomeLayoutCard(context, glass),
              const SizedBox(height: LuminaTokens.spaceMd),
              _buildUiScaleCard(context, glass),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHomeLayoutCard(BuildContext context, LuminaGlassTheme glass) {
    final activePreset = scaleController.homeLayoutPreset;
    final activeTheme = scaleController.themeMode;

    return _glassCard(
      glass,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '主頁排版與外觀',
            style: TextStyle(color: glass.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: LuminaTokens.space2xs),
          Text(
            '即時切換主頁視覺骨架、毛玻璃明暗主題與封面氛圍效果，切換時不會中斷播放或重複載入曲庫',
            style: TextStyle(color: glass.textTertiary, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: LuminaTokens.spaceMd),
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 480
                  ? 3
                  : (constraints.maxWidth >= 280 ? 2 : 1);
              const gap = 10.0;
              final itemW = ((constraints.maxWidth - gap * (cols - 1)) / cols)
                  .clamp(110.0, 260.0);
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final opt in _layoutOptions)
                    SizedBox(
                      width: itemW,
                      child: _SettingsLayoutPresetCard(
                        key: Key(opt.keyName),
                        preset: opt.preset,
                        title: opt.title,
                        selected: activePreset == opt.preset,
                        onTap: () => scaleController.setHomeLayoutPreset(opt.preset),
                      ),
                    ),
                ],
              );
            },
          ),
          Divider(color: glass.glassBorder, height: LuminaTokens.spaceLg),
          Text(
            '主題色彩模式',
            style: TextStyle(color: glass.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          DecoratedBox(
            decoration: BoxDecoration(
              color: glass.pillBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: glass.pillBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final tm in _themeModes)
                    _segmentChip(
                      glass,
                      key: Key(tm.keyName),
                      icon: tm.icon,
                      label: tm.label,
                      selected: activeTheme == tm.mode,
                      onTap: () => scaleController.setThemeMode(tm.mode),
                    ),
                ],
              ),
            ),
          ),
          Divider(color: glass.glassBorder, height: LuminaTokens.spaceLg),
          _buildSwitchTile(
            glass,
            tileKey: const Key('switch_aura_follow_cover'),
            title: '動態光暈跟隨目前播放封面取色',
            subtitle: '於「光暈快速續播 (AJ)」頂部顯示低飽和動態色彩氛圍',
            value: scaleController.auraFollowCover,
            onChanged: scaleController.setAuraFollowCover,
          ),
          _buildSwitchTile(
            glass,
            tileKey: const Key('switch_minimal_cover_mode'),
            title: '極簡封面模式（隱藏卡片下方文字，僅懸停顯示）',
            subtitle: '讓主頁正方形封面牆呈現純粹視覺留白，滑鼠移入時優雅浮現資訊',
            value: scaleController.minimalCoverMode,
            onChanged: scaleController.setMinimalCoverMode,
          ),
        ],
      ),
    );
  }

  Widget _buildUiScaleCard(BuildContext context, LuminaGlassTheme glass) {
    final pct = scaleController.percentage;
    final current = scaleController.scale;
    final canDecrease = current > UiScaleController.minScale;
    final canIncrease = current < UiScaleController.maxScale;

    return _glassCard(
      glass,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '全域介面比例縮放',
                      style: TextStyle(color: glass.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: LuminaTokens.space2xs),
                    Text(
                      '等比例調整文字、封面、側欄與播放列大小，專為 2K / 4K 高解析螢幕設計',
                      style: TextStyle(color: glass.textTertiary, fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceSm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: LuminaTokens.spaceSm, vertical: LuminaTokens.spaceXs),
                decoration: BoxDecoration(
                  color: glass.glassBgActive,
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                  border: Border.all(color: glass.glassBorderStrong),
                ),
                child: Text(
                  '$pct%',
                  key: const Key('text_current_scale_pct'),
                  style: TextStyle(color: glass.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: LuminaTokens.spaceMd),
          Row(
            children: [
              IconButton(
                key: const Key('btn_scale_decrease'),
                tooltip: '縮小介面（Ctrl + -）',
                onPressed: canDecrease ? () => scaleController.stepBy(-0.05) : null,
                icon: Icon(
                  Icons.remove_circle_outline_rounded,
                  color: canDecrease ? glass.textSecondary : glass.textDisabled,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: glass.textPrimary,
                    inactiveTrackColor: glass.textDisabled.withValues(alpha: 0.35),
                    thumbColor: glass.textPrimary,
                    overlayColor: glass.accent.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    key: const Key('slider_ui_scale'),
                    min: UiScaleController.minScale,
                    max: UiScaleController.maxScale,
                    divisions: 17,
                    value: current.clamp(UiScaleController.minScale, UiScaleController.maxScale),
                    onChanged: scaleController.setScale,
                  ),
                ),
              ),
              IconButton(
                key: const Key('btn_scale_increase'),
                tooltip: '放大介面（Ctrl + =）',
                onPressed: canIncrease ? () => scaleController.stepBy(0.05) : null,
                icon: Icon(
                  Icons.add_circle_outline_rounded,
                  color: canIncrease ? glass.textSecondary : glass.textDisabled,
                ),
              ),
            ],
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          Wrap(
            spacing: LuminaTokens.spaceXs,
            runSpacing: LuminaTokens.spaceXs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: glass.pillBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: glass.pillBorder),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final preset in UiScaleController.presets)
                        Tooltip(
                          message: '將介面縮放設為 ${(preset * 100).round()}%',
                          child: _segmentChip(
                            glass,
                            key: Key('btn_scale_preset_${(preset * 100).round()}'),
                            label: preset == 1.0 ? '100% (預設)' : '${(preset * 100).round()}%',
                            selected: (current - preset).abs() < 0.02,
                            onTap: () => scaleController.setScale(preset),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Tooltip(
                message: '重設介面縮放回 100%（Ctrl + 0）',
                child: OutlinedButton.icon(
                  key: const Key('btn_scale_reset'),
                  onPressed: scaleController.reset,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: glass.pillBg,
                    foregroundColor: glass.textPrimary,
                    side: BorderSide(color: glass.pillBorder),
                    padding: const EdgeInsets.symmetric(horizontal: LuminaTokens.spaceMd, vertical: LuminaTokens.spaceSm),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LuminaTokens.radiusSm)),
                  ),
                  icon: const Icon(Icons.restart_alt_rounded, size: 16),
                  label: const Text('重設 100%'),
                ),
              ),
            ],
          ),
          Divider(color: glass.glassBorder, height: LuminaTokens.spaceLg),
          _buildSwitchTile(
            glass,
            tileKey: const Key('switch_restore_scale_startup'),
            title: '啟動時恢復縮放比例',
            subtitle: '下次開啟 Lumina Audio 時自動套用目前介面縮放設定',
            value: scaleController.restoreOnStartup,
            onChanged: scaleController.setRestoreOnStartup,
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          Text(
            '桌面快捷鍵：Ctrl + = 放大  •  Ctrl + - 縮小  •  Ctrl + 0 重設回 100%',
            style: TextStyle(color: glass.textTertiary, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _glassCard(LuminaGlassTheme glass, {required Widget child}) {
    final radius = BorderRadius.circular(LuminaTokens.glassCardRadius);
    return ClipRRect(
      borderRadius: radius,
      child: FrostedGlassContainer(
        blurSigma: glass.glassCardBlur,
        enableBackdropBlur: false,
        color: glass.glassBg,
        borderRadius: radius,
        border: Border.all(color: glass.glassBorder),
        padding: const EdgeInsets.all(LuminaTokens.spaceMd),
        child: child,
      ),
    );
  }

  Widget _buildSwitchTile(
    LuminaGlassTheme glass, {
    required Key tileKey,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        key: tileKey,
        contentPadding: EdgeInsets.zero,
        hoverColor: glass.glassBgHover,
        title: Text(
          title,
          style: TextStyle(color: glass.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: glass.textTertiary, fontSize: 12, height: 1.4),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  Widget _segmentChip(
    LuminaGlassTheme glass, {
    required Key key,
    IconData? icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      key: key,
      avatar: icon != null
          ? Icon(icon, size: 15, color: selected ? glass.textPrimary : glass.textSecondary)
          : null,
      label: Text(
        label,
        style: TextStyle(
          color: selected ? glass.textPrimary : glass.textSecondary,
          fontSize: 12.5,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      selected: selected,
      showCheckmark: false,
      backgroundColor: Colors.transparent,
      selectedColor: glass.glassBgActive,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      pressElevation: 0,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LuminaTokens.radiusSm)),
      side: BorderSide(color: selected ? glass.glassBorderStrong : Colors.transparent),
      onSelected: (_) => onTap(),
    );
  }
}

class _SettingsLayoutPresetCard extends StatefulWidget {
  final HomeLayoutPreset preset;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsLayoutPresetCard({
    super.key,
    required this.preset,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SettingsLayoutPresetCard> createState() =>
      _SettingsLayoutPresetCardState();
}

class _SettingsLayoutPresetCardState extends State<_SettingsLayoutPresetCard> {
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
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.selected
                ? glass.glassBgActive
                : (_hovered ? glass.glassBgHover : glass.pillBg),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? glass.accent
                  : (_hovered ? glass.glassBorderStrong : glass.pillBorder),
              width: widget.selected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HomeLayoutWireframe(preset: widget.preset, selected: widget.selected, height: 54),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.selected ? glass.textPrimary : glass.textSecondary,
                        fontSize: 12,
                        fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.selected)
                    Icon(Icons.check_circle_rounded, size: 14, color: glass.accent),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
