part of 'device_settings_dialog.dart';

class _VolumeStrategySection extends StatelessWidget {
  final bool isShared;
  final bool strictOn;
  final bool busy;
  final int volPct;
  final String safeVerificationStatus;
  final AudioEngineOutputInfoModel outputInfo;
  final ValueChanged<bool> onSetStrictMode;

  const _VolumeStrategySection({
    required this.isShared,
    required this.strictOn,
    required this.busy,
    required this.volPct,
    required this.safeVerificationStatus,
    required this.outputInfo,
    required this.onSetStrictMode,
  });

  @override
  Widget build(BuildContext context) {
    return _SectionBox(
      title: '音量規則與 Bit-Perfect 策略',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isShared)
            Container(
              key: const Key('shared_not_bit_perfect_notice'),
              width: double.infinity,
              padding: const EdgeInsets.all(LuminaTokens.spaceSm),
              decoration: BoxDecoration(
                color: LuminaTokens.statusWarning.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(
                  color: LuminaTokens.statusWarning.withValues(alpha: 0.6),
                ),
              ),
              child: const Text(
                'WASAPI Shared 經過 Windows 系統混音器，無法進行 BIT-PERFECT 位元完美輸出；軟體音量可正常調整。',
                style: TextStyle(
                  color: LuminaTokens.statusWarning,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          if (!isShared) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Strict Bit-Perfect Mode（嚴格位元完美）',
                        style: TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: LuminaTokens.space2xs),
                      Text(
                        strictOn
                            ? '已鎖定 Unity 1.0x (100%) 軟體音量與 DSP 硬旁通，請使用硬體／DAC 旋鈕調整音量'
                            : '啟用後將鎖定 100% 軟體音量並旁通所有 DSP 處理',
                        key: strictOn
                            ? const Key('volume_rule_unity_locked')
                            : null,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: LuminaTokens.spaceSm),
                Tooltip(
                  message: strictOn
                      ? '關閉嚴格位元完美模式（恢復軟體音量與 DSP）'
                      : '開啟嚴格位元完美模式（鎖定 100% 音量並旁通 DSP）',
                  child: Switch(
                    key: const Key('switch_device_strict_bit_perfect'),
                    value: strictOn,
                    mouseCursor: LuminaSettingsStyles.switchMouseCursor(
                      enabled: !busy,
                    ),
                    onChanged: busy ? null : onSetStrictMode,
                  ),
                ),
              ],
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
          ] else
            const SizedBox(height: LuminaTokens.spaceXs),
          _InfoRow(
            label: '軟體音量狀態',
            value: strictOn ? '已鎖定 100% (Unity 1.0x)' : '$volPct%（軟體音量可用）',
          ),
          _InfoRow(label: '驗證狀態', value: safeVerificationStatus),
          if (outputInfo.output.sampleRateHz > 0)
            _InfoRow(
              label: '目前輸出串流',
              value:
                  '${AudioFormat.formatSampleRateKhz(outputInfo.output.sampleRateHz)} · ${outputInfo.output.validBits}/${outputInfo.output.containerBits}-bit · ${outputInfo.output.channels}ch',
            ),
        ],
      ),
    );
  }
}

class _SectionBox extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionBox({required this.title, required this.child});

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
            title,
            style: const TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LuminaTokens.space2xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpecChip extends StatelessWidget {
  final String label;

  const _SpecChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceXs + 2,
        vertical: LuminaTokens.space2xs,
      ),
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.glassPillBorder),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: LuminaTokens.textPrimary,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
