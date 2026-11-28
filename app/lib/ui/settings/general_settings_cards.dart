import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/recommendation_settings_controller.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

class RecommendationAutoplayCard extends StatelessWidget {
  final RecommendationSettingsController rec;
  final TextEditingController lastFmApiKeyController;
  final bool obscureLastFmKey;
  final bool lastFmSaved;
  final VoidCallback onKeyChanged;
  final VoidCallback onToggleObscure;
  final VoidCallback onSave;

  const RecommendationAutoplayCard({
    super.key,
    required this.rec,
    required this.lastFmApiKeyController,
    required this.obscureLastFmKey,
    required this.lastFmSaved,
    required this.onKeyChanged,
    required this.onToggleObscure,
    required this.onSave,
  });

  static String _platformLabel(String id) => switch (id) {
    'local' => '本地無損曲庫',
    'tidal' => 'Tidal (HI_RES / LOSSLESS)',
    'qobuz' => 'Qobuz',
    'deezer' => 'Deezer',
    'youtube_music' => 'YouTube Music (Guest 兜底)',
    _ => id,
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: rec,
      builder: (context, _) {
        final priority = rec.platformPriority;
        return SettingsGroupCard(
          title: '自動推薦與無限接播',
          children: [
            SettingsSwitchRow(
              key: const Key('switch_autoplay_enabled'),
              title: '啟用無限自動接播（Autoplay）',
              subtitle: '待播佇列即將播畢時，自動依據近期聆聽曲目接續推薦相似音樂。',
              value: rec.autoplayEnabled,
              onChanged: rec.setAutoplayEnabled,
            ),
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            SettingsSwitchRow(
              key: const Key('switch_cross_platform_routing'),
              title: '跨平台高音質自動路由',
              subtitle: '自動依下方優先順序匹配本地無損或已登入之高解析串流版本播放，遇 401 授權失效時自動跳過。',
              value: rec.crossPlatformRoutingEnabled,
              onChanged: rec.setCrossPlatformRoutingEnabled,
            ),
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
                vertical: LuminaTokens.spaceSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '跨平台音源優先順序',
                              style: TextStyle(
                                color: LuminaTokens.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '進行跨平台匹配時由上而下依序嘗試取得最高音質來源。',
                              style: TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      OutlinedButton(
                        key: const Key('btn_priority_reset'),
                        style: LuminaSettingsStyles.outlinedButtonStyle(),
                        onPressed: rec.resetPlatformPriority,
                        child: const Text(
                          '重設預設',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: LuminaTokens.spaceSm),
                  for (var index = 0; index < priority.length; index++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.glassPillBg,
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusSm,
                          ),
                          border: Border.all(
                            color: LuminaTokens.glassCardBorder,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: LuminaTokens.glassNavActiveBg,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  color: LuminaTokens.glassTextPrimary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _platformLabel(priority[index]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            IconButton(
                              key: Key('btn_priority_up_${priority[index]}'),
                              tooltip: '上移優先順序',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              padding: EdgeInsets.zero,
                              style: LuminaSettingsStyles.iconButtonStyle(),
                              icon: const Icon(
                                Icons.keyboard_arrow_up_rounded,
                                size: 18,
                              ),
                              onPressed: index > 0
                                  ? () => rec.movePlatformPriority(
                                      index,
                                      index - 1,
                                    )
                                  : null,
                            ),
                            IconButton(
                              key: Key('btn_priority_down_${priority[index]}'),
                              tooltip: '下移優先順序',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              padding: EdgeInsets.zero,
                              style: LuminaSettingsStyles.iconButtonStyle(),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 18,
                              ),
                              onPressed: index < priority.length - 1
                                  ? () => rec.movePlatformPriority(
                                      index,
                                      index + 1,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            SettingsSwitchRow(
              key: const Key('switch_listenbrainz_enabled'),
              title: 'ListenBrainz 相似曲目推薦（免金鑰）',
              subtitle: '使用 MusicBrainz 與 ListenBrainz 開放音樂圖譜進行無金鑰跨平台推薦。',
              value: rec.listenBrainzEnabled,
              onChanged: rec.setListenBrainzEnabled,
            ),
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
                vertical: LuminaTokens.spaceSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Last.fm API Key',
                    style: TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    '選填：設定 Last.fm API Key 以在播放本地無損曲庫或離線音源時補充外部相似推薦。',
                    style: TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceSm),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('input_lastfm_api_key'),
                          controller: lastFmApiKeyController,
                          obscureText: obscureLastFmKey,
                          onChanged: (_) => onKeyChanged(),
                          onSubmitted: (_) => onSave(),
                          style: const TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: 13,
                          ),
                          decoration: LuminaSettingsStyles.inputDecoration(
                            hintText: '輸入 Last.fm API Key（留空則停用）',
                          ).copyWith(
                            suffixIcon: IconButton(
                              tooltip: obscureLastFmKey ? '顯示金鑰' : '隱藏金鑰',
                              icon: Icon(
                                obscureLastFmKey
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 17,
                                color: LuminaTokens.glassTextSecondary,
                              ),
                              onPressed: onToggleObscure,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      ElevatedButton(
                        key: const Key('btn_save_lastfm_api_key'),
                        style: LuminaSettingsStyles.filledButtonStyle(),
                        onPressed: onSave,
                        child: const Text(
                          '儲存金鑰',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (lastFmSaved) ...[
                    const SizedBox(height: 6),
                    const Text(
                      '已儲存 Last.fm API Key',
                      style: TextStyle(
                        color: LuminaTokens.statusSuccess,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class LoudnessNormalizationCard extends StatelessWidget {
  final bool strictLocked;
  final ReplayGainModeOption currentMode;
  final ValueChanged<ReplayGainModeOption> onSelectMode;

  const LoudnessNormalizationCard({
    super.key,
    required this.strictLocked,
    required this.currentMode,
    required this.onSelectMode,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = strictLocked
        ? LuminaTokens.textDisabled
        : LuminaTokens.textPrimary;
    final secondaryColor = strictLocked
        ? LuminaTokens.textDisabled
        : LuminaTokens.textSecondary;

    return SettingsGroupCard(
      title: '響度標準化（-14 LUFS）',
      children: [
        Padding(
          key: const Key('loudness_normalization_row'),
          padding: const EdgeInsets.symmetric(
            horizontal: LuminaTokens.spaceMd,
            vertical: LuminaTokens.spaceSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '跨平台響度標準化模式',
                          style: TextStyle(
                            color: primaryColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '統一 YouTube Music、Tidal、Deezer、Qobuz 與本地 ReplayGain 音量至 -14 LUFS 基準，並自動啟用峰值防削波保護。',
                          style: TextStyle(
                            color: secondaryColor,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (strictLocked) ...[
                    const SizedBox(width: LuminaTokens.spaceSm),
                    Tooltip(
                      message:
                          '嚴格位元完美模式作用中，響度標準化與 DSP 已強制旁通以確保 100% 位元直出',
                      child: Container(
                        key: const Key('badge_loudness_strict_locked'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.statusWarning.withValues(
                            alpha: 0.14,
                          ),
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusSm,
                          ),
                          border: Border.all(
                            color: LuminaTokens.statusWarning.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 13,
                              color: LuminaTokens.statusWarning,
                            ),
                            SizedBox(width: 4),
                            Text(
                              '嚴格模式已鎖定',
                              style: TextStyle(
                                color: LuminaTokens.statusWarning,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: LuminaTokens.spaceSm),
              Tooltip(
                message: strictLocked
                    ? '嚴格位元完美模式作用中，停用嚴格模式後方可調整響度標準化'
                    : '選擇 -14 LUFS 響度標準化模式（關閉／單曲增益／專輯增益）',
                child: DecoratedBox(
                  decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final mode in ReplayGainModeOption.values)
                          LuminaSettingsStyles.frostedSegmentChip(
                            key: Key('chip_loudness_mode_${mode.apiValue}'),
                            label: mode.label,
                            selected: currentMode == mode,
                            disabled: strictLocked,
                            onSelected: strictLocked
                                ? null
                                : (_) => onSelectMode(mode),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
