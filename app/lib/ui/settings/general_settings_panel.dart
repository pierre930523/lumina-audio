import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/signal_path.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/streaming/yt_dlp_service.dart';
import '../../services/ui_scale_controller.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';
import 'third_party_licenses_dialog.dart';

class GeneralSettingsPanel extends StatefulWidget {
  final AudioService audioService;
  final UiScaleController scaleController;

  const GeneralSettingsPanel({
    super.key,
    required this.audioService,
    required this.scaleController,
  });

  @override
  State<GeneralSettingsPanel> createState() => _GeneralSettingsPanelState();
}

class _GeneralSettingsPanelState extends State<GeneralSettingsPanel> {
  DspPipelineConfigModel _dspConfig = const DspPipelineConfigModel();
  StreamSubscription<SignalPath>? _signalPathSub;

  @override
  void initState() {
    super.initState();
    _loadDspConfig();
    _subscribeSignalPath();
  }

  @override
  void didUpdateWidget(covariant GeneralSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      _signalPathSub?.cancel();
      _subscribeSignalPath();
      _loadDspConfig();
    }
  }

  void _subscribeSignalPath() {
    _signalPathSub = widget.audioService.signalPathStream.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _loadDspConfig() async {
    try {
      final cfg = await widget.audioService.getDspConfig();
      if (!mounted) return;
      setState(() {
        _dspConfig = cfg;
      });
    } catch (_) {}
  }

  Future<void> _setLoudnessMode(ReplayGainModeOption mode) async {
    if (widget.audioService.isStrictBitPerfect) return;
    if (_dspConfig.replayGainMode == mode) return;
    final next = _dspConfig.copyWith(replayGainMode: mode);
    setState(() {
      _dspConfig = next;
    });
    try {
      await widget.audioService.setDspConfig(next);
    } catch (_) {}
  }

  @override
  void dispose() {
    _signalPathSub?.cancel();
    _signalPathSub = null;
    super.dispose();
  }

  Widget _buildLoudnessNormalizationCard() {
    final strictLocked = widget.audioService.isStrictBitPerfect;
    final currentMode = _dspConfig.replayGainMode;
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
                child: Wrap(
                  spacing: LuminaTokens.spaceXs,
                  runSpacing: LuminaTokens.spaceXs,
                  children: [
                    for (final mode in ReplayGainModeOption.values)
                      ChoiceChip(
                        key: Key('chip_loudness_mode_${mode.apiValue}'),
                        label: Text(
                          mode.label,
                          style: TextStyle(
                            color: strictLocked
                                ? LuminaTokens.textDisabled
                                : (currentMode == mode
                                      ? LuminaTokens.textPrimary
                                      : LuminaTokens.textSecondary),
                            fontSize: 12.5,
                            fontWeight: currentMode == mode
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        selected: currentMode == mode,
                        showCheckmark: false,
                        selectedColor: strictLocked
                            ? LuminaTokens.cardElevatedBg
                            : LuminaTokens.accentBlueStrong.withValues(
                                alpha: 0.28,
                              ),
                        backgroundColor: LuminaTokens.cardElevatedBg,
                        disabledColor: LuminaTokens.cardElevatedBg,
                        side: BorderSide(
                          color: strictLocked
                              ? LuminaTokens.borderSubtle
                              : (currentMode == mode
                                    ? LuminaTokens.accentBlue
                                    : LuminaTokens.borderControl),
                        ),
                        onSelected: strictLocked
                            ? null
                            : (_) => _setLoudnessMode(mode),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaleController = widget.scaleController;
    final audioService = widget.audioService;
    return ListenableBuilder(
      listenable: scaleController,
      builder: (context, _) {
        return SingleChildScrollView(
          key: const Key('general_settings_panel'),
          padding: const EdgeInsets.only(
            bottom: LuminaTokens.bottomScrollClearance,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsGroupCard(
                  title: '播放行為',
                  children: [
                    SettingsSwitchRow(
                      key: const Key('switch_remember_playback_pos'),
                      title: '記住播放位置',
                      subtitle: '重新開啟曲目或恢復工作階段時從上次停止處接續播放。',
                      value: scaleController.rememberPlaybackPosition,
                      onChanged: scaleController.setRememberPlaybackPosition,
                    ),
                    const Divider(color: LuminaTokens.borderSubtle, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_notify_resample'),
                      title: '重取樣時顯示提示',
                      subtitle: '當輸出音訊路徑發生系統取樣率轉換或 DSP 處理時呈現標示通知。',
                      value: scaleController.notifyOnResample,
                      onChanged: scaleController.setNotifyOnResample,
                    ),
                    const Divider(color: LuminaTokens.borderSubtle, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_minimize_to_tray_on_close'),
                      title: '關閉視窗時縮小至系統匣並繼續背景播放',
                      subtitle:
                          '開啟後，點擊右上角關閉按鈕將隱藏視窗並保持音樂播放，可從右下角系統匣還原或完全結束程式',
                      value: scaleController.minimizeToTrayOnClose,
                      onChanged: scaleController.setMinimizeToTrayOnClose,
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildLoudnessNormalizationCard(),
                const SizedBox(height: LuminaTokens.spaceMd),
                SettingsGroupCard(
                  title: '裝置與啟動恢復',
                  children: [
                    SettingsSwitchRow(
                      key: const Key('switch_general_restore_output'),
                      title: '啟動時恢復輸出裝置',
                      subtitle: '開啟 Lumina Audio 時自動連接上次選擇之 ASIO / WASAPI DAC 裝置。',
                      value: scaleController.restoreOutputOnStartup,
                      onChanged: scaleController.setRestoreOutputOnStartup,
                    ),
                    const Divider(color: LuminaTokens.borderSubtle, height: 1),
                    SettingsSwitchRow(
                      title: '啟動時恢復介面縮放比例',
                      subtitle: '保留目前設定的全域介面縮放比例（目前：${scaleController.percentage}%）。',
                      value: scaleController.restoreOnStartup,
                      onChanged: scaleController.setRestoreOnStartup,
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                SettingsGroupCard(
                  title: '音訊核心狀態',
                  children: [
                    SettingsInfoRow(
                      label: '原生核心鏈結（Rust FFI）',
                      value: audioService.isNativeBound
                          ? '已連結原生 core_ffi 引擎'
                          : '模擬工作室模式（Mock）',
                    ),
                    const Divider(color: LuminaTokens.borderSubtle, height: 1),
                    SettingsInfoRow(
                      label: '目前連線架構',
                      value: audioService.connectionMode.label,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class AboutSettingsPanel extends StatelessWidget {
  final AudioService audioService;
  final YtDlpService? ytDlpService;

  const AboutSettingsPanel({
    super.key,
    required this.audioService,
    this.ytDlpService,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('about_settings_panel'),
      padding: const EdgeInsets.only(
        bottom: LuminaTokens.bottomScrollClearance,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: SettingsGroupCard(
          title: '關於 Lumina Audio',
          children: [
            const SettingsInfoRow(
              label: '應用程式版本',
              value: 'v1.0.0 Studio Edition',
            ),
            const Divider(color: LuminaTokens.borderSubtle, height: 1),
            SettingsInfoRow(
              label: 'DSP 與音訊核心',
              value: audioService.isNativeBound
                  ? 'Rust 64-bit Float Core (FFI Active)'
                  : 'Rust Core Engine (Standby / Mock)',
            ),
            const Divider(color: LuminaTokens.borderSubtle, height: 1),
            const SettingsInfoRow(
              label: '支援協定與格式',
              value:
                  'FLAC · ALAC · WAV · DSD64/128 · DLNA · AirPlay · Apple Music · YouTube Music · Qobuz · Tidal',
            ),
            const Divider(color: LuminaTokens.borderSubtle, height: 1),
            SettingsActionRow(
              title: '第三方開源授權（yt-dlp / Deno / FFmpeg）',
              subtitle:
                  '檢視內建串流解析與無損轉碼工具之完整開源授權條款（Unlicense / MIT / LGPL）。',
              buttonLabel: '檢視開源授權',
              buttonKey: const Key('btn_about_third_party_licenses'),
              onPressed: () => ThirdPartyLicensesDialog.show(
                context,
                ytDlpService: ytDlpService ?? YtDlpService.instance,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
