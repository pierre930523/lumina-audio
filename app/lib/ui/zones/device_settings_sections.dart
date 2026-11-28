part of 'device_settings_dialog.dart';

class _DeviceSettingsHeader extends StatelessWidget {
  final AudioDeviceCapabilitiesModel capability;
  final bool isSystemOutput;
  final IconData deviceIcon;
  final VoidCallback onClose;

  const _DeviceSettingsHeader({
    required this.capability,
    required this.isSystemOutput,
    required this.deviceIcon,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: LuminaTokens.glassPillBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            border: Border.all(color: LuminaTokens.glassCardBorder),
          ),
          child: Icon(deviceIcon, color: LuminaTokens.textPrimary, size: 22),
        ),
        const SizedBox(width: LuminaTokens.spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isSystemOutput
                    ? 'System Output (${capability.name})'
                    : capability.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isSystemOutput
                    ? '跟隨 Windows 預設 · ${capability.interfaceLabel}'
                    : capability.interfaceLabel,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('btn_close_device_settings'),
          tooltip: '關閉',
          style: LuminaSettingsStyles.iconButtonStyle(),
          icon: const Icon(
            Icons.close_rounded,
            color: LuminaTokens.textSecondary,
          ),
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _DeviceSettingsErrorBanner extends StatelessWidget {
  final String error;

  const _DeviceSettingsErrorBanner({required this.error});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(LuminaTokens.spaceSm),
        decoration: BoxDecoration(
          color: LuminaTokens.statusError.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(
            color: LuminaTokens.statusError.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: LuminaTokens.statusError,
              size: 16,
            ),
            const SizedBox(width: LuminaTokens.spaceXs),
            Expanded(
              child: Text(
                error,
                style: const TextStyle(
                  color: Color(0xFFFECACA),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputModeSection extends StatelessWidget {
  final AudioDeviceCapabilitiesModel capability;
  final bool isSystemOutput;
  final bool isAsio;
  final bool isShared;
  final bool canToggleExclusive;
  final bool busy;
  final List<DsdOutputModeOption> dsdOptions;
  final DsdOutputModeOption currentDsdMode;
  final String Function(String) formatOutputModeLabel;
  final ValueChanged<bool> onToggleExclusive;
  final ValueChanged<DsdOutputModeOption> onSelectDsdMode;

  const _OutputModeSection({
    required this.capability,
    required this.isSystemOutput,
    required this.isAsio,
    required this.isShared,
    required this.canToggleExclusive,
    required this.busy,
    required this.dsdOptions,
    required this.currentDsdMode,
    required this.formatOutputModeLabel,
    required this.onToggleExclusive,
    required this.onSelectDsdMode,
  });

  @override
  Widget build(BuildContext context) {
    return _SectionBox(
      title: '輸出模式與獨佔控制',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: '目前介面', value: capability.interfaceLabel),
          if (capability.supportedOutputModes.isNotEmpty)
            _InfoRow(
              label: '硬體支援模式',
              value: capability.supportedOutputModes
                  .map(formatOutputModeLabel)
                  .join(' · '),
            ),
          const Divider(
            color: _DeviceSettingsDialogState._borderColor,
            height: LuminaTokens.spaceMd,
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '獨佔模式 (Exclusive Mode)',
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: LuminaTokens.space2xs),
                    Text(
                      isAsio
                          ? 'ASIO 原生獨佔直驅（繞過系統混音器）'
                          : isSystemOutput
                          ? 'System Output 依播放政策自動路由；如需鎖定獨佔請直接啟用 WASAPI Exclusive 卡片'
                          : canToggleExclusive
                          ? (isShared
                                ? '目前為 WASAPI Shared；開啟後將切換至 WASAPI Exclusive'
                                : '已啟用 WASAPI Exclusive 獨佔直出')
                          : (capability.probeNote ?? '此硬體或藍牙連線不支援獨佔模式'),
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
                message: busy || !canToggleExclusive
                    ? '此輸出裝置目前無法切換獨佔模式'
                    : (isShared
                          ? '開啟 WASAPI Exclusive 獨佔模式'
                          : '切換回 WASAPI Shared 模式'),
                child: Switch(
                  key: const Key('switch_device_exclusive_mode'),
                  value: isAsio || !isShared,
                  mouseCursor: LuminaSettingsStyles.switchMouseCursor(
                    enabled: !busy && canToggleExclusive,
                  ),
                  onChanged: busy || !canToggleExclusive
                      ? null
                      : onToggleExclusive,
                ),
              ),
            ],
          ),
          if (capability.supportsNativeDsd || capability.supportsDop) ...[
            const Divider(
              color: _DeviceSettingsDialogState._borderColor,
              height: LuminaTokens.spaceMd,
            ),
            const Text(
              'DSD 輸出模式（僅顯示硬體支援項目）',
              style: TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
            Wrap(
              spacing: LuminaTokens.spaceXs,
              runSpacing: LuminaTokens.spaceXs,
              children: dsdOptions.map((opt) {
                final selected = currentDsdMode == opt;
                return Tooltip(
                  message: '選擇 DSD 輸出模式：${opt.shortLabel}',
                  child: ChoiceChip(
                    label: Text(
                      opt.shortLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: selected
                            ? Colors.white
                            : (busy
                                  ? LuminaTokens.textDisabled
                                  : LuminaTokens.glassTextSecondary),
                      ),
                    ),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: LuminaTokens.glassSegmentSelectedBg,
                    backgroundColor: LuminaTokens.glassSegmentTrackBg,
                    disabledColor: LuminaTokens.glassSegmentTrackBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                    ),
                    side: BorderSide(
                      color: selected
                          ? LuminaTokens.glassSegmentSelectedBorder
                          : (busy
                                ? LuminaTokens.glassCardDivider
                                : LuminaTokens.glassSegmentTrackBorder),
                    ),
                    onSelected: busy ? null : (_) => onSelectDsdMode(opt),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _HardwareCapabilitiesSection extends StatelessWidget {
  final AudioDeviceCapabilitiesModel capability;
  final bool isShared;
  final bool busy;
  final List<int> bufferChoices;
  final int currentBuffer;
  final String Function(int) formatRateChip;
  final ValueChanged<int> onSelectBufferFrames;

  const _HardwareCapabilitiesSection({
    required this.capability,
    required this.isShared,
    required this.busy,
    required this.bufferChoices,
    required this.currentBuffer,
    required this.formatRateChip,
    required this.onSelectBufferFrames,
  });

  @override
  Widget build(BuildContext context) {
    return _SectionBox(
      title: '真實硬體支援能力',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '支援取樣率',
            style: TextStyle(color: LuminaTokens.textMuted, fontSize: 12),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          if (capability.supportedSampleRates.isEmpty)
            const Text(
              '未回報（由裝置驅動程式決定）',
              style: TextStyle(color: LuminaTokens.textMuted, fontSize: 12.5),
            )
          else
            Wrap(
              spacing: LuminaTokens.spaceXs,
              runSpacing: LuminaTokens.spaceXs,
              children: capability.supportedSampleRates
                  .map((r) => _SpecChip(label: formatRateChip(r)))
                  .toList(),
            ),
          const SizedBox(height: LuminaTokens.spaceSm),
          _InfoRow(
            label: '支援位元深度',
            value: capability.supportedBitDepths.isEmpty
                ? '由系統／驅動決定'
                : capability.supportedBitDepths
                      .map((b) => '$b-bit')
                      .join(' · '),
          ),
          _InfoRow(
            label: '支援聲道數',
            value: capability.supportedChannels.isEmpty
                ? '由裝置決定'
                : capability.supportedChannels
                      .map((c) => c == 2 ? '2ch (Stereo)' : '${c}ch')
                      .join(' · '),
          ),
          if (capability.bufferSizeSupported && bufferChoices.isNotEmpty) ...[
            const Divider(
              color: _DeviceSettingsDialogState._borderColor,
              height: LuminaTokens.spaceMd,
            ),
            Text(
              '緩衝區大小（支援範圍：${capability.minBufferFrames}–${capability.maxBufferFrames} frames）',
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
            Wrap(
              spacing: LuminaTokens.spaceXs,
              runSpacing: LuminaTokens.spaceXs,
              children: bufferChoices.map((frames) {
                final selected = currentBuffer == frames;
                final disabled = busy || bufferChoices.length <= 1;
                return Tooltip(
                  message: '設定緩衝區為 $frames frames',
                  child: ChoiceChip(
                    key: Key('btn_buffer_frames_$frames'),
                    label: Text(
                      '$frames',
                      style: TextStyle(
                        fontSize: 12,
                        color: selected
                            ? Colors.white
                            : (disabled
                                  ? LuminaTokens.textDisabled
                                  : LuminaTokens.glassTextSecondary),
                      ),
                    ),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: LuminaTokens.glassSegmentSelectedBg,
                    backgroundColor: LuminaTokens.glassSegmentTrackBg,
                    disabledColor: LuminaTokens.glassSegmentTrackBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                    ),
                    side: BorderSide(
                      color: selected
                          ? LuminaTokens.glassSegmentSelectedBorder
                          : (disabled
                                ? LuminaTokens.glassCardDivider
                                : LuminaTokens.glassSegmentTrackBorder),
                    ),
                    onSelected: disabled
                        ? null
                        : (_) => onSelectBufferFrames(frames),
                  ),
                );
              }).toList(),
            ),
          ] else
            _InfoRow(
              label: '緩衝區大小',
              value: isShared ? '由 Windows 系統混音器管理' : '由硬體驅動程式管理',
            ),
        ],
      ),
    );
  }
}
