import 'package:material_ui/material_ui.dart';

import '../../services/audio_service.dart';
import '../../services/ui_scale_controller.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

class GeneralSettingsPanel extends StatelessWidget {
  final AudioService audioService;
  final UiScaleController scaleController;

  const GeneralSettingsPanel({
    super.key,
    required this.audioService,
    required this.scaleController,
  });

  @override
  Widget build(BuildContext context) {
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
                  ],
                ),
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

  const AboutSettingsPanel({super.key, required this.audioService});

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
          ],
        ),
      ),
    );
  }
}
