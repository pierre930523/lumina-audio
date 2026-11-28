import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/audio_output_info.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../settings/settings_widgets.dart';
import '../theme/lumina_tokens.dart';

part 'device_settings_sections.dart';
part 'device_settings_widgets.dart';

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
          ? (caps.where((c) => c.isOsDefault && c.isSharedMode).firstOrNull ??
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

  Future<void> _setDsdOutputMode(DsdOutputModeOption opt) async {
    await widget.audioService.setDsdOutputMode(opt);
    if (mounted) setState(() {});
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
              _DeviceSettingsHeader(
                capability: _cap,
                isSystemOutput: widget.isSystemOutput,
                deviceIcon: widget.deviceIcon,
                onClose: () => Navigator.of(context).pop(),
              ),
              if (_error != null) ...[
                const SizedBox(height: LuminaTokens.spaceSm),
                _DeviceSettingsErrorBanner(error: _error!),
              ],
              const SizedBox(height: LuminaTokens.spaceMd),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _OutputModeSection(
                        capability: _cap,
                        isSystemOutput: widget.isSystemOutput,
                        isAsio: isAsio,
                        isShared: isShared,
                        canToggleExclusive: canToggleExclusive,
                        busy: _busy,
                        dsdOptions: dsdOptions,
                        currentDsdMode: widget.audioService.dsdOutputMode,
                        formatOutputModeLabel: _formatOutputModeLabel,
                        onToggleExclusive: _toggleExclusiveMode,
                        onSelectDsdMode: _setDsdOutputMode,
                      ),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      _HardwareCapabilitiesSection(
                        capability: _cap,
                        isShared: isShared,
                        busy: _busy,
                        bufferChoices: bufferChoices,
                        currentBuffer: currentBuffer,
                        formatRateChip: _formatRateChip,
                        onSelectBufferFrames: _setBufferFrames,
                      ),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      _VolumeStrategySection(
                        isShared: isShared,
                        strictOn: strictOn,
                        busy: _busy,
                        volPct: volPct,
                        safeVerificationStatus: safeVerificationStatus,
                        outputInfo: _outputInfo,
                        onSetStrictMode: _setStrictMode,
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
