import 'package:material_ui/material_ui.dart';

import '../../services/ui_scale_controller.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

class AppearanceAndScalePanel extends StatelessWidget {
  final UiScaleController scaleController;

  const AppearanceAndScalePanel({
    super.key,
    required this.scaleController,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: scaleController,
      builder: (context, _) {
        final pct = scaleController.percentage;
        final current = scaleController.scale;
        final canDecrease = current > UiScaleController.minScale;
        final canIncrease = current < UiScaleController.maxScale;

        return SingleChildScrollView(
          key: const Key('appearance_scale_panel'),
          padding: const EdgeInsets.fromLTRB(
            LuminaTokens.spaceLg,
            LuminaTokens.spaceMd,
            LuminaTokens.spaceLg,
            LuminaTokens.bottomScrollClearance,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(LuminaTokens.spaceMd),
                decoration: BoxDecoration(
                  color: LuminaTokens.cardBg,
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  border: Border.all(color: LuminaTokens.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '全域介面比例縮放',
                                style: TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: LuminaTokens.space2xs),
                              Text(
                                '等比例調整文字、封面、側欄與播放列大小，專為 2K / 4K 高解析螢幕設計',
                                style: TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceSm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: LuminaTokens.spaceSm,
                            vertical: LuminaTokens.spaceXs,
                          ),
                          decoration: BoxDecoration(
                            color: LuminaTokens.accentBlueStrong.withValues(
                              alpha: 0.18,
                            ),
                            borderRadius: BorderRadius.circular(
                              LuminaTokens.radiusSm,
                            ),
                            border: Border.all(color: LuminaTokens.accentBlue),
                          ),
                          child: Text(
                            '$pct%',
                            key: const Key('text_current_scale_pct'),
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
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
                          style: LuminaSettingsStyles.iconButtonStyle(
                            foregroundColor: LuminaTokens.textSecondary,
                          ),
                          onPressed: canDecrease
                              ? () => scaleController.stepBy(-0.05)
                              : null,
                          icon: Icon(
                            Icons.remove_circle_outline_rounded,
                            color: canDecrease
                                ? LuminaTokens.textSecondary
                                : LuminaTokens.textDisabled,
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: LuminaTokens.accentBlue,
                              inactiveTrackColor: LuminaTokens.borderControl,
                              thumbColor: LuminaTokens.textPrimary,
                              overlayColor: LuminaTokens.focusRing.withValues(
                                alpha: 0.2,
                              ),
                            ),
                            child: Slider(
                              key: const Key('slider_ui_scale'),
                              min: UiScaleController.minScale,
                              max: UiScaleController.maxScale,
                              divisions: 17,
                              value: current.clamp(
                                UiScaleController.minScale,
                                UiScaleController.maxScale,
                              ),
                              onChanged: scaleController.setScale,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('btn_scale_increase'),
                          tooltip: '放大介面（Ctrl + =）',
                          style: LuminaSettingsStyles.iconButtonStyle(
                            foregroundColor: LuminaTokens.textSecondary,
                          ),
                          onPressed: canIncrease
                              ? () => scaleController.stepBy(0.05)
                              : null,
                          icon: Icon(
                            Icons.add_circle_outline_rounded,
                            color: canIncrease
                                ? LuminaTokens.textSecondary
                                : LuminaTokens.textDisabled,
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
                        for (final preset in UiScaleController.presets)
                          Tooltip(
                            message:
                                '將介面縮放設為 ${(preset * 100).round()}%',
                            child: ChoiceChip(
                              key: Key(
                                'btn_scale_preset_${(preset * 100).round()}',
                              ),
                              label: Text(
                                preset == 1.0
                                    ? '100% (預設)'
                                    : '${(preset * 100).round()}%',
                                style: TextStyle(
                                  color: (current - preset).abs() < 0.02
                                      ? LuminaTokens.textPrimary
                                      : LuminaTokens.textSecondary,
                                  fontSize: 12.5,
                                  fontWeight: (current - preset).abs() < 0.02
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                              selected: (current - preset).abs() < 0.02,
                              showCheckmark: false,
                              selectedColor: LuminaTokens.accentBlueStrong
                                  .withValues(alpha: 0.28),
                              backgroundColor: LuminaTokens.cardElevatedBg,
                              side: BorderSide(
                                color: (current - preset).abs() < 0.02
                                    ? LuminaTokens.accentBlue
                                    : LuminaTokens.borderControl,
                              ),
                              onSelected: (_) =>
                                  scaleController.setScale(preset),
                            ),
                          ),
                        Tooltip(
                          message: '重設介面縮放回 100%（Ctrl + 0）',
                          child: OutlinedButton.icon(
                            key: const Key('btn_scale_reset'),
                            onPressed: scaleController.reset,
                            style: LuminaSettingsStyles.outlinedButtonStyle(),
                            icon: const Icon(
                              Icons.restart_alt_rounded,
                              size: 16,
                            ),
                            label: const Text('重設 100%'),
                          ),
                        ),
                      ],
                    ),
                    const Divider(
                      color: LuminaTokens.borderSubtle,
                      height: LuminaTokens.spaceLg,
                    ),
                    Material(
                      type: MaterialType.transparency,
                      child: SwitchListTile(
                        key: const Key('switch_restore_scale_startup'),
                        contentPadding: EdgeInsets.zero,
                        hoverColor: LuminaTokens.cardHoverBg.withValues(
                          alpha: 0.45,
                        ),
                        activeTrackColor: LuminaTokens.accentBlueStrong,
                        activeThumbColor: LuminaTokens.textPrimary,
                        inactiveTrackColor: LuminaTokens.cardElevatedBg,
                        inactiveThumbColor: LuminaTokens.textSecondary,
                        trackOutlineColor:
                            LuminaSettingsStyles.switchTrackOutlineColor,
                        title: const Text(
                          '啟動時恢復縮放比例',
                          style: TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: const Text(
                          '下次開啟 Lumina Audio 時自動套用目前介面縮放設定',
                          style: TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                        value: scaleController.restoreOnStartup,
                        onChanged: scaleController.setRestoreOnStartup,
                      ),
                    ),
                    const SizedBox(height: LuminaTokens.spaceXs),
                    const Text(
                      '桌面快捷鍵：Ctrl + = 放大  •  Ctrl + - 縮小  •  Ctrl + 0 重設回 100%',
                      style: TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
