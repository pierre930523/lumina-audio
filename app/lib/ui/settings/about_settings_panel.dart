import 'package:material_ui/material_ui.dart';

import '../../services/audio_service.dart';
import '../../services/streaming/yt_dlp_service.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';
import 'third_party_licenses_dialog.dart';

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
    return SettingsScrollBody(
      panelKey: const Key('about_settings_panel'),
      maxWidth: 780,
      child: SettingsGroupCard(
        title: '關於 Lumina Audio',
        children: [
          const SettingsInfoRow(
            label: '應用程式版本',
            value: 'v1.0.0 Studio Edition',
          ),
          const Divider(color: LuminaTokens.glassCardDivider, height: 1),
          SettingsInfoRow(
            label: 'DSP 與音訊核心',
            value: audioService.isNativeBound
                ? 'Rust 64-bit Float Core (FFI Active)'
                : 'Rust Core Engine (Standby / Mock)',
          ),
          const Divider(color: LuminaTokens.glassCardDivider, height: 1),
          const SettingsInfoRow(
            label: '支援協定與格式',
            value:
                'FLAC · ALAC · WAV · DSD64/128 · DLNA · AirPlay · Apple Music · YouTube Music · Qobuz · Tidal',
          ),
          const Divider(color: LuminaTokens.glassCardDivider, height: 1),
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
    );
  }
}
