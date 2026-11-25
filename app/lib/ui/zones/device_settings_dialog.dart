import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/audio_output_info.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../settings/settings_widgets.dart';
import '../theme/lumina_tokens.dart';

class DeviceSettingsDialog extends StatefulWidget {
  final AudioService audioService;
  final AudioDeviceCapabilitiesModel capability;
  final AudioDeviceCapabilitiesModel? exclusiveSibling;
  final AudioDeviceCapabilitiesModel? sharedSibling;
  final bool isSystemOutput;
  final IconData deviceIcon;
  final VoidCallback? onDeviceSwitched;

  const DeviceSettingsDialog({
    super.key,
    required this.audioService,
    required this.capability,
    this.exclusiveSibling,
    this.sharedSibling,
    this.isSystemOutput = false,
    required this.deviceIcon,
    this.onDeviceSwitched,
  });

  static Future<void> show(
    BuildContext context, {
    required AudioService audioService,
    required AudioDeviceCapabilitiesModel capability,
    AudioDeviceCapabilitiesModel? exclusiveSibling,
    AudioDeviceCapabilitiesModel? sharedSibling,
    bool isSystemOutput = false,
    required IconData deviceIcon,
    VoidCallback? onDeviceSwitched,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (_) => DeviceSettingsDialog(
        audioService: audioService,
        capability: capability,
        exclusiveSibling: exclusiveSibling,
        sharedSibling: sharedSibling,
        isSystemOutput: isSystemOutput,
        deviceIcon: deviceIcon,
        onDeviceSwitched: onDeviceSwitched,
      ),
    );
  }

  @override
  State<DeviceSettingsDialog> createState() => _DeviceSettingsDialogState();
}

class _DeviceSettingsDialogState extends State<DeviceSettingsDialog> {
  static const _borderColor = LuminaTokens.glassCardDivider;

  late AudioDeviceCapabilitiesModel _cap;
  AudioEngineOutputInfoModel _outputInfo = const AudioEngineOutputInfoModel();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cap = widget.capability;
    _refreshInfo();
  }

  Future<void> _refreshInfo() async {
    final info = await widget.audioService.getOutputInfo();
    if (!mounted) return;
    if (widget.isSystemOutput) {
      final caps = await widget.audioService.listDeviceCapabilities();
      if (!mounted) return;
      final apiLower = info.output.audioApi.toLowerCase();
      final isExclApi =
          apiLower == 'windowswasapiexclusive' ||
          apiLower == 'windows_wasapi_exclusive';
      final isSharedApi =
          apiLower == 'windowswasapishared' ||
          apiLower == 'windows_wasapi_shared';
      final matched = isExclApi
          ? (caps.where((c) => c.isOsDefault && !c.isSharedMode).firstOrNull ??
                caps.where((c) => c.isOsDefault).firstOrNull)
          : isSharedApi
              ? (caps
                        .where((c) => c.isOsDefault && c.isSharedMode)
                        .firstOrNull ??
                    caps.where((c) => c.isOsDefault).firstOrNull)
              : null;
      if (matched != null) {
        _cap = matched;
      }
    }
    setState(() {
      _outputInfo = info;
    });
  }

  String _formatRateChip(int hz) {
    if (hz >= 2822400) {
      if (hz == 2822400 || hz == 3072000) return 'DSD64';
      if (hz == 5644800 || hz == 6144000) return 'DSD128';
      if (hz == 11289600) return 'DSD256';
      if (hz == 22579200) return 'DSD512';
      return '${(hz / 1000000).toStringAsFixed(2)} MHz';
    }
    return AudioFormat.formatSampleRateKhz(hz);
  }

  String _formatOutputModeLabel(String raw) => switch (raw) {
    'wasapi_exclusive' => 'WASAPI Exclusive',
    'wasapi_shared' => 'WASAPI Shared',
    'asio_pcm' => 'ASIO Native PCM',
    'asio_native_dsd' => 'ASIO Native DSD',
    'dop_over_wasapi_exclusive' => 'DoP over WASAPI Exclusive',
    'dop_over_asio' => 'DoP over ASIO',
    'dsd_to_pcm' => 'DSD-to-PCM',
    'virtual_mock' => 'Virtual Exclusive',
    _ => raw,
  };

  List<DsdOutputModeOption> _supportedDsdOptions() {
    final opts = <DsdOutputModeOption>[DsdOutputModeOption.auto];
    if (_cap.supportsNativeDsd) {
      opts.add(DsdOutputModeOption.nativeDsd);
    }
    if (_cap.supportsDop) {
      opts.add(DsdOutputModeOption.dop);
    }
    opts.add(DsdOutputModeOption.dsdToPcm);
    return opts;
  }

  List<int> _supportedBufferChoices() {
    if (!_cap.bufferSizeSupported) return const [];
    final minF = _cap.minBufferFrames;
    final maxF = _cap.maxBufferFrames;
    final defF = _cap.defaultBufferFrames;
    if (minF == null || maxF == null) return const [];
    if (minF >= maxF) return [minF];

    const candidates = [64, 128, 256, 480, 512, 1024, 2048, 4096, 8192];
    final choices = <int>{minF, maxF};
    if (defF != null && defF >= minF && defF <= maxF) {
      choices.add(defF);
    }
    for (final c in candidates) {
      if (c >= minF && c <= maxF) {
        choices.add(c);
      }
    }
    final sorted = choices.toList()..sort();
    return sorted;
  }

  Future<void> _toggleExclusiveMode(bool enableExclusive) async {
    final target = enableExclusive
        ? widget.exclusiveSibling
        : widget.sharedSibling;
    if (target == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.audioService.selectAudioDevice(
      target.deviceId,
      backendIndex: target.backendIndex,
    );
    final err = widget.audioService.lastError;
    if (!mounted) return;
    if (err != null && err.isNotEmpty) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    setState(() {
      _cap = target;
      _busy = false;
    });
    widget.onDeviceSwitched?.call();
    await _refreshInfo();
  }

  Future<void> _setStrictMode(bool enabled) async {
    if (_cap.isSharedMode) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.audioService.setStrictBitPerfect(enabled);
    final err = widget.audioService.lastError;
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null && err.isNotEmpty) {
        _error = err;
      }
    });
    widget.onDeviceSwitched?.call();
    await _refreshInfo();
  }

  Future<void> _setBufferFrames(int frames) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.audioService.setBufferFrames(frames);
    final err = widget.audioService.lastError;
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok && err != null && err.isNotEmpty) {
        _error = err;
      }
    });
    await _refreshInfo();
  }

  @override
  Widget build(BuildContext context) {
    final isAsio = _cap.backend == 'windows_asio';
    final isShared = _cap.isSharedMode;
    final canToggleExclusive =
        !widget.isSystemOutput &&
        !isAsio &&
        ((isShared && widget.exclusiveSibling != null) ||
            (!isShared && widget.sharedSibling != null));
    final strictOn = !isShared && widget.audioService.isStrictBitPerfect;
    final dsdOptions = _supportedDsdOptions();
    final bufferChoices = _supportedBufferChoices();
    final currentBuffer = _outputInfo.output.bufferSizeFrames > 0
        ? _outputInfo.output.bufferSizeFrames
        : (_cap.defaultBufferFrames ?? widget.audioService.preferredBufferFrames);
    final verificationStatus = _outputInfo.verification.status;
    final safeVerificationStatus = isShared && verificationStatus == 'BIT-PERFECT'
        ? 'NOT BIT-PERFECT'
        : verificationStatus;
    final volPct = (widget.audioService.currentState.volume * 100).round();

    return Dialog(
      key: const Key('device_settings_dialog'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(LuminaTokens.spaceLg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: LuminaTokens.glassPillBg,
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      border: Border.all(color: LuminaTokens.glassCardBorder),
                    ),
                    child: Icon(
                      widget.deviceIcon,
                      color: LuminaTokens.textPrimary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: LuminaTokens.spaceSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isSystemOutput
                              ? 'System Output (${_cap.name})'
                              : _cap.name,
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
                          widget.isSystemOutput
                              ? '跟隨 Windows 預設 · ${_cap.interfaceLabel}'
                              : _cap.interfaceLabel,
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
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: LuminaTokens.spaceSm),
                Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                    decoration: BoxDecoration(
                      color: LuminaTokens.statusError.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
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
                            _error!,
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
                ),
              ],
              const SizedBox(height: LuminaTokens.spaceMd),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SectionBox(
                        title: '輸出模式與獨佔控制',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _InfoRow(
                              label: '目前介面',
                              value: _cap.interfaceLabel,
                            ),
                            if (_cap.supportedOutputModes.isNotEmpty)
                              _InfoRow(
                                label: '硬體支援模式',
                                value: _cap.supportedOutputModes
                                    .map(_formatOutputModeLabel)
                                    .join(' · '),
                              ),
                            const Divider(
                              color: _borderColor,
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
                                      const SizedBox(
                                        height: LuminaTokens.space2xs,
                                      ),
                                      Text(
                                        isAsio
                                            ? 'ASIO 原生獨佔直驅（繞過系統混音器）'
                                            : widget.isSystemOutput
                                                ? 'System Output 依播放政策自動路由；如需鎖定獨佔請直接啟用 WASAPI Exclusive 卡片'
                                                : canToggleExclusive
                                                    ? (isShared
                                                        ? '目前為 WASAPI Shared；開啟後將切換至 WASAPI Exclusive'
                                                        : '已啟用 WASAPI Exclusive 獨佔直出')
                                                    : (_cap.probeNote ??
                                                        '此硬體或藍牙連線不支援獨佔模式'),
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
                                  message: _busy || !canToggleExclusive
                                      ? '此輸出裝置目前無法切換獨佔模式'
                                      : (isShared
                                            ? '開啟 WASAPI Exclusive 獨佔模式'
                                            : '切換回 WASAPI Shared 模式'),
                                  child: Switch(
                                    key: const Key('switch_device_exclusive_mode'),
                                    value: isAsio || !isShared,
                                    mouseCursor: LuminaSettingsStyles
                                        .switchMouseCursor(
                                          enabled: !_busy && canToggleExclusive,
                                        ),
                                    onChanged: _busy || !canToggleExclusive
                                        ? null
                                        : _toggleExclusiveMode,
                                  ),
                                ),
                              ],
                            ),
                            if (_cap.supportsNativeDsd || _cap.supportsDop) ...[
                              const Divider(
                                color: _borderColor,
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
                                  final selected =
                                      widget.audioService.dsdOutputMode == opt;
                                  return Tooltip(
                                    message: '選擇 DSD 輸出模式：${opt.shortLabel}',
                                    child: ChoiceChip(
                                      label: Text(
                                        opt.shortLabel,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: selected
                                              ? Colors.white
                                              : (_busy
                                                    ? LuminaTokens.textDisabled
                                                    : LuminaTokens
                                                          .glassTextSecondary),
                                        ),
                                      ),
                                      selected: selected,
                                      showCheckmark: false,
                                      selectedColor:
                                          LuminaTokens.glassSegmentSelectedBg,
                                      backgroundColor:
                                          LuminaTokens.glassSegmentTrackBg,
                                      disabledColor:
                                          LuminaTokens.glassSegmentTrackBg,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          LuminaTokens.radiusSm,
                                        ),
                                      ),
                                      side: BorderSide(
                                        color: selected
                                            ? LuminaTokens
                                                  .glassSegmentSelectedBorder
                                            : (_busy
                                                  ? LuminaTokens
                                                        .glassCardDivider
                                                  : LuminaTokens
                                                        .glassSegmentTrackBorder),
                                      ),
                                      onSelected: _busy
                                          ? null
                                          : (_) async {
                                              await widget.audioService
                                                  .setDsdOutputMode(opt);
                                              if (mounted) setState(() {});
                                              await _refreshInfo();
                                            },
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      _SectionBox(
                        title: '真實硬體支援能力',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '支援取樣率',
                              style: TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: LuminaTokens.spaceXs),
                            if (_cap.supportedSampleRates.isEmpty)
                              const Text(
                                '未回報（由裝置驅動程式決定）',
                                style: TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12.5,
                                ),
                              )
                            else
                              Wrap(
                                spacing: LuminaTokens.spaceXs,
                                runSpacing: LuminaTokens.spaceXs,
                                children: _cap.supportedSampleRates
                                    .map(
                                      (r) => _SpecChip(label: _formatRateChip(r)),
                                    )
                                    .toList(),
                              ),
                            const SizedBox(height: LuminaTokens.spaceSm),
                            _InfoRow(
                              label: '支援位元深度',
                              value: _cap.supportedBitDepths.isEmpty
                                  ? '由系統／驅動決定'
                                  : _cap.supportedBitDepths
                                        .map((b) => '$b-bit')
                                        .join(' · '),
                            ),
                            _InfoRow(
                              label: '支援聲道數',
                              value: _cap.supportedChannels.isEmpty
                                  ? '由裝置決定'
                                  : _cap.supportedChannels
                                        .map(
                                          (c) => c == 2 ? '2ch (Stereo)' : '${c}ch',
                                        )
                                        .join(' · '),
                            ),
                            if (_cap.bufferSizeSupported &&
                                bufferChoices.isNotEmpty) ...[
                              const Divider(
                                color: _borderColor,
                                height: LuminaTokens.spaceMd,
                              ),
                              Text(
                                '緩衝區大小（支援範圍：${_cap.minBufferFrames}–${_cap.maxBufferFrames} frames）',
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
                                  final disabled =
                                      _busy || bufferChoices.length <= 1;
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
                                                    : LuminaTokens
                                                          .glassTextSecondary),
                                        ),
                                      ),
                                      selected: selected,
                                      showCheckmark: false,
                                      selectedColor:
                                          LuminaTokens.glassSegmentSelectedBg,
                                      backgroundColor:
                                          LuminaTokens.glassSegmentTrackBg,
                                      disabledColor:
                                          LuminaTokens.glassSegmentTrackBg,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          LuminaTokens.radiusSm,
                                        ),
                                      ),
                                      side: BorderSide(
                                        color: selected
                                            ? LuminaTokens
                                                  .glassSegmentSelectedBorder
                                            : (disabled
                                                  ? LuminaTokens
                                                        .glassCardDivider
                                                  : LuminaTokens
                                                        .glassSegmentTrackBorder),
                                      ),
                                      onSelected: disabled
                                          ? null
                                          : (_) => _setBufferFrames(frames),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ] else
                              _InfoRow(
                                label: '緩衝區大小',
                                value: isShared
                                    ? '由 Windows 系統混音器管理'
                                    : '由硬體驅動程式管理',
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      _SectionBox(
                        title: '音量規則與 Bit-Perfect 策略',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isShared)
                              Container(
                                key: const Key('shared_not_bit_perfect_notice'),
                                width: double.infinity,
                                padding: const EdgeInsets.all(
                                  LuminaTokens.spaceSm,
                                ),
                                decoration: BoxDecoration(
                                  color: LuminaTokens.statusWarning.withValues(
                                    alpha: 0.14,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusSm,
                                  ),
                                  border: Border.all(
                                    color: LuminaTokens.statusWarning
                                        .withValues(alpha: 0.6),
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Strict Bit-Perfect Mode（嚴格位元完美）',
                                          style: TextStyle(
                                            color: LuminaTokens.textPrimary,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(
                                          height: LuminaTokens.space2xs,
                                        ),
                                        Text(
                                          strictOn
                                              ? '已鎖定 Unity 1.0x (100%) 軟體音量與 DSP 硬旁通，請使用硬體／DAC 旋鈕調整音量'
                                              : '啟用後將鎖定 100% 軟體音量並旁通所有 DSP 處理',
                                          key: strictOn
                                              ? const Key(
                                                  'volume_rule_unity_locked',
                                                )
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
                                      key: const Key(
                                        'switch_device_strict_bit_perfect',
                                      ),
                                      value: strictOn,
                                      mouseCursor: LuminaSettingsStyles
                                          .switchMouseCursor(enabled: !_busy),
                                      onChanged: _busy ? null : _setStrictMode,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: LuminaTokens.spaceXs),
                            ] else
                              const SizedBox(height: LuminaTokens.spaceXs),
                            _InfoRow(
                              label: '軟體音量狀態',
                              value: strictOn
                                  ? '已鎖定 100% (Unity 1.0x)'
                                  : '$volPct%（軟體音量可用）',
                            ),
                            _InfoRow(
                              label: '驗證狀態',
                              value: safeVerificationStatus,
                            ),
                            if (_outputInfo.output.sampleRateHz > 0)
                              _InfoRow(
                                label: '目前輸出串流',
                                value:
                                    '${AudioFormat.formatSampleRateKhz(_outputInfo.output.sampleRateHz)} · ${_outputInfo.output.validBits}/${_outputInfo.output.containerBits}-bit · ${_outputInfo.output.channels}ch',
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
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
