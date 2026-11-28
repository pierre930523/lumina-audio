import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../settings/settings_widgets.dart';
import '../theme/lumina_tokens.dart';

class DspPeqCard extends StatelessWidget {
  final List<PeqBandModel> tenBands;
  final bool strictBypassed;
  final Color primaryTextColor;
  final Color secondaryTextColor;
  final void Function(int index, double gainDb) onBandChanged;

  const DspPeqCard({
    super.key,
    required this.tenBands,
    required this.strictBypassed,
    required this.primaryTextColor,
    required this.secondaryTextColor,
    required this.onBandChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(LuminaTokens.spaceMd),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '10 段參數等化器（PEQ）',
            style: TextStyle(
              color: primaryTextColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: strictBypassed
                  ? LuminaTokens.glassCardDivider
                  : LuminaTokens.glassTextPrimary,
              inactiveTrackColor: strictBypassed
                  ? LuminaTokens.glassCardDivider
                  : LuminaTokens.glassTrackUnplayed,
              thumbColor: strictBypassed
                  ? LuminaTokens.textDisabled
                  : Colors.white,
              overlayColor: LuminaTokens.focusRing.withValues(alpha: 0.2),
            ),
            child: Column(
              children: List.generate(10, (i) {
                final band = tenBands[i];
                final freqLabel = band.frequencyHz >= 1000
                    ? '${(band.frequencyHz / 1000).toStringAsFixed(1)}k'
                    : '${band.frequencyHz.round()}Hz';
                return Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        freqLabel,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        key: Key('peq_band_$i'),
                        min: -12.0,
                        max: 12.0,
                        value: band.gainDb.clamp(-12.0, 12.0),
                        onChanged: strictBypassed
                            ? null
                            : (v) => onBandChanged(i, v),
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(
                        '${band.gainDb >= 0 ? '+' : ''}${band.gainDb.toStringAsFixed(1)} dB',
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: primaryTextColor,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class DspAutoEqImportCard extends StatelessWidget {
  final TextEditingController controller;
  final bool strictBypassed;
  final Color primaryTextColor;
  final VoidCallback onImport;

  const DspAutoEqImportCard({
    super.key,
    required this.controller,
    required this.strictBypassed,
    required this.primaryTextColor,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(LuminaTokens.spaceMd),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '匯入 AutoEQ 耳機校正曲線檔（.txt）',
            style: TextStyle(
              color: primaryTextColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          TextField(
            key: const Key('autoeq_import_input'),
            controller: controller,
            enabled: !strictBypassed,
            maxLines: 3,
            style: TextStyle(
              color: primaryTextColor,
              fontSize: 12,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              hintText:
                  '貼上 AutoEQ 格式文字，例如：\nPreamp: -4.5 dB\nFilter 1: ON PK Fc 105 Hz Gain 3.2 dB Q 0.71',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          Tooltip(
            message: strictBypassed
                ? '嚴格位元完美模式作用中，AutoEQ 匯入已停用'
                : '解析並套用貼上的 AutoEQ 濾波器參數',
            child: FilledButton.icon(
              key: const Key('btn_import_autoeq'),
              onPressed: strictBypassed ? null : onImport,
              style: LuminaSettingsStyles.filledButtonStyle(),
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: const Text('匯入 AutoEQ'),
            ),
          ),
        ],
      ),
    );
  }
}
