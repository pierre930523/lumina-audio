import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/signal_path.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_settings_controller.dart';
import '../../services/recommendation_settings_controller.dart';
import '../../services/ui_scale_controller.dart';
import '../theme/lumina_tokens.dart';
import 'general_settings_cards.dart';
import 'settings_widgets.dart';

export 'about_settings_panel.dart';

class GeneralSettingsPanel extends StatefulWidget {
  final AudioService audioService;
  final UiScaleController scaleController;
  final RecommendationSettingsController? recommendationSettings;
  final LibrarySettingsController? librarySettings;

  const GeneralSettingsPanel({
    super.key,
    required this.audioService,
    required this.scaleController,
    this.recommendationSettings,
    this.librarySettings,
  });

  @override
  State<GeneralSettingsPanel> createState() => _GeneralSettingsPanelState();
}

class _GeneralSettingsPanelState extends State<GeneralSettingsPanel> {
  DspPipelineConfigModel _dspConfig = const DspPipelineConfigModel();
  StreamSubscription<SignalPath>? _signalPathSub;
  late final TextEditingController _lastFmApiKeyController;
  bool _obscureLastFmKey = true;
  bool _lastFmSaved = false;
  String _lastSyncedLastFmKey = '';

  @override
  void initState() {
    super.initState();
    final initialKey = widget.recommendationSettings?.lastFmApiKey ?? '';
    _lastSyncedLastFmKey = initialKey;
    _lastFmApiKeyController = TextEditingController(text: initialKey);
    widget.recommendationSettings?.addListener(_onRecommendationSettingsChanged);
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
    if (!identical(
      oldWidget.recommendationSettings,
      widget.recommendationSettings,
    )) {
      oldWidget.recommendationSettings?.removeListener(
        _onRecommendationSettingsChanged,
      );
      widget.recommendationSettings?.addListener(
        _onRecommendationSettingsChanged,
      );
      final nextKey = widget.recommendationSettings?.lastFmApiKey ?? '';
      if (nextKey != _lastSyncedLastFmKey) {
        _lastSyncedLastFmKey = nextKey;
        _lastFmApiKeyController.text = nextKey;
      }
    }
  }

  void _onRecommendationSettingsChanged() {
    final rec = widget.recommendationSettings;
    if (!mounted || rec == null) return;
    if (rec.lastFmApiKey != _lastSyncedLastFmKey) {
      _lastSyncedLastFmKey = rec.lastFmApiKey;
      _lastFmApiKeyController.text = rec.lastFmApiKey;
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
    widget.recommendationSettings?.removeListener(
      _onRecommendationSettingsChanged,
    );
    _lastFmApiKeyController.dispose();
    _signalPathSub?.cancel();
    _signalPathSub = null;
    super.dispose();
  }

  Future<void> _saveLastFmApiKey(RecommendationSettingsController rec) async {
    final trimmed = _lastFmApiKeyController.text.trim();
    _lastSyncedLastFmKey = trimmed;
    await rec.setLastFmApiKey(trimmed);
    if (!mounted) return;
    setState(() {
      _lastFmSaved = true;
    });
  }

  Widget _buildRecommendationAutoplayCard(RecommendationSettingsController rec) {
    return RecommendationAutoplayCard(
      rec: rec,
      lastFmApiKeyController: _lastFmApiKeyController,
      obscureLastFmKey: _obscureLastFmKey,
      lastFmSaved: _lastFmSaved,
      onKeyChanged: () {
        if (_lastFmSaved) {
          setState(() => _lastFmSaved = false);
        }
      },
      onToggleObscure: () {
        setState(() => _obscureLastFmKey = !_obscureLastFmKey);
      },
      onSave: () => _saveLastFmApiKey(rec),
    );
  }

  Widget _buildLoudnessNormalizationCard() {
    return LoudnessNormalizationCard(
      strictLocked: widget.audioService.isStrictBitPerfect,
      currentMode: _dspConfig.replayGainMode,
      onSelectMode: _setLoudnessMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaleController = widget.scaleController;
    final audioService = widget.audioService;
    final listenable = widget.librarySettings != null
        ? Listenable.merge([scaleController, widget.librarySettings!])
        : scaleController;
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final libSettings = widget.librarySettings;
        return SettingsScrollBody(
          panelKey: const Key('general_settings_panel'),
          maxWidth: 780,
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
                    const Divider(color: LuminaTokens.glassCardDivider, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_notify_resample'),
                      title: '重取樣時顯示提示',
                      subtitle: '當輸出音訊路徑發生系統取樣率轉換或 DSP 處理時呈現標示通知。',
                      value: scaleController.notifyOnResample,
                      onChanged: scaleController.setNotifyOnResample,
                    ),
                    const Divider(color: LuminaTokens.glassCardDivider, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_minimize_to_tray_on_close'),
                      title: '關閉視窗時縮小至系統匣並繼續背景播放',
                      subtitle:
                          '開啟後，點擊右上角關閉按鈕將隱藏視窗並保持音樂播放，可從右下角系統匣還原或完全結束程式',
                      value: scaleController.minimizeToTrayOnClose,
                      onChanged: scaleController.setMinimizeToTrayOnClose,
                    ),
                    if (libSettings != null) ...[
                      const Divider(
                        color: LuminaTokens.glassCardDivider,
                        height: 1,
                      ),
                      SettingsSwitchRow(
                        key: const Key('switch_auto_mark_listen_later'),
                        title: '播放後自動標記稍後收聽為已聽',
                        subtitle:
                            '單曲播放超過 70% 或專輯播放超過 50% 曲目時，自動將待聽項目移至已聽。',
                        value: libSettings.autoMarkListenLaterListened,
                        onChanged: libSettings.setAutoMarkListenLaterListened,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildLoudnessNormalizationCard(),
                if (widget.recommendationSettings != null) ...[
                  const SizedBox(height: LuminaTokens.spaceMd),
                  _buildRecommendationAutoplayCard(
                    widget.recommendationSettings!,
                  ),
                ],
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
                    const Divider(color: LuminaTokens.glassCardDivider, height: 1),
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
                    const Divider(color: LuminaTokens.glassCardDivider, height: 1),
                    SettingsInfoRow(
                      label: '目前連線架構',
                      value: audioService.connectionMode.label,
                    ),
                  ],
                ),
              ],
            ),
          );
      },
    );
  }
}
