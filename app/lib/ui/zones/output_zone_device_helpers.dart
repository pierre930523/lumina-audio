part of 'output_zone_panel.dart';

class _OutputCardEntry {
  final String cardKey;
  final bool isSystemOutput;
  final AudioDeviceCapabilitiesModel capability;

  const _OutputCardEntry({
    required this.cardKey,
    required this.isSystemOutput,
    required this.capability,
  });
}

List<AudioDeviceCapabilitiesModel> _buildDedupedCapabilities(
  List<AudioDeviceCapabilitiesModel> rawCaps,
  List<AudioDeviceInfo> devs,
) {
  final source = rawCaps.isNotEmpty
      ? rawCaps
      : devs
            .map(
              (d) => AudioDeviceCapabilitiesModel(
                deviceId: d.id,
                name: d.name,
                backend: d.backend,
                transport: d.backend == 'windows_asio'
                    ? 'asio'
                    : (d.backend == 'windows_wasapi_shared'
                          ? 'speakers'
                          : 'internal'),
                isDefault: d.isDefault,
                isOsDefault: d.isDefault,
                isExclusive: d.isExclusive,
                hardwareSupportsExclusive: d.isExclusive,
                supportedSampleRates: d.supportedSampleRates,
                asioAvailable: d.backend == 'windows_asio',
                exclusiveAvailable: d.isExclusive,
              ),
            )
            .toList();

  final seen = <String>{};
  final out = <AudioDeviceCapabilitiesModel>[];
  for (final cap in source) {
    if (cap.backend == 'windows_asio' && !cap.asioAvailable) {
      continue;
    }
    final dedupKey = '${cap.physicalEndpointId}::${cap.backend}';
    if (seen.add(dedupKey)) {
      out.add(cap);
    }
  }
  return out;
}

AudioDeviceCapabilitiesModel? _resolveOsDefaultCapability(
  AudioService audioService,
  List<AudioDeviceCapabilitiesModel> caps,
  AudioEngineOutputInfoModel info,
) {
  if (caps.isEmpty) return null;
  final apiLower = info.output.audioApi.toLowerCase();
  final isExclApi =
      apiLower == 'windowswasapiexclusive' ||
      apiLower == 'windows_wasapi_exclusive';
  final isSharedApi =
      apiLower == 'windowswasapishared' ||
      apiLower == 'windows_wasapi_shared';
  if (audioService.isSystemOutputActive) {
    if (isExclApi) {
      return caps
              .where((c) => c.isOsDefault && !c.isSharedMode)
              .firstOrNull ??
          caps.where((c) => c.isOsDefault).firstOrNull ??
          caps.where((c) => c.isDefault).firstOrNull ??
          caps.first;
    }
    if (isSharedApi) {
      return caps
              .where((c) => c.isOsDefault && c.isSharedMode)
              .firstOrNull ??
          caps.where((c) => c.isOsDefault).firstOrNull ??
          caps.where((c) => c.isDefault).firstOrNull ??
          caps.first;
    }
  }
  final preferExcl =
      audioService.isStrictBitPerfect ||
      audioService.currentSignalPath.dspBypassed;
  if (preferExcl) {
    return caps.where((c) => c.isOsDefault && !c.isSharedMode).firstOrNull ??
        caps.where((c) => c.isOsDefault).firstOrNull ??
        caps.where((c) => c.isDefault).firstOrNull ??
        caps.first;
  }
  return caps.where((c) => c.isOsDefault && c.isSharedMode).firstOrNull ??
      caps.where((c) => c.isOsDefault).firstOrNull ??
      caps.where((c) => c.isDefault).firstOrNull ??
      caps.first;
}

List<_OutputCardEntry> _buildOutputCardEntries(
  AudioService audioService,
  List<AudioDeviceCapabilitiesModel> capabilities,
  AudioEngineOutputInfoModel outputInfo,
) {
  final osDefault = _resolveOsDefaultCapability(
    audioService,
    capabilities,
    outputInfo,
  );
  final systemCap = AudioDeviceCapabilitiesModel(
    deviceId: AudioService.systemOutputId,
    name: osDefault?.name ?? 'Windows 系統預設音訊裝置',
    backend: osDefault?.backend ?? 'windows_wasapi_shared',
    transport: osDefault?.transport ?? 'internal',
    isDefault: true,
    isOsDefault: true,
    isExclusive: osDefault?.isExclusive ?? false,
    isHdmi: osDefault?.isHdmi ?? false,
    hardwareSupportsExclusive: osDefault?.hardwareSupportsExclusive ?? false,
    supportedSampleRates: osDefault?.supportedSampleRates ?? const [],
    supportedBitDepths: osDefault?.supportedBitDepths ?? const [],
    supportedContainerBits: osDefault?.supportedContainerBits ?? const [],
    supportedChannels: osDefault?.supportedChannels ?? const [],
    supportedOutputModes: osDefault?.supportedOutputModes ?? const [],
    supportsNativeDsd: osDefault?.supportsNativeDsd ?? false,
    supportsDop: osDefault?.supportsDop ?? false,
    supportsFloat32: osDefault?.supportsFloat32 ?? true,
    maxDsdRate: osDefault?.maxDsdRate,
    asioAvailable: osDefault?.asioAvailable ?? false,
    exclusiveAvailable: osDefault?.exclusiveAvailable ?? false,
    bufferSizeSupported: osDefault?.bufferSizeSupported ?? false,
    minBufferFrames: osDefault?.minBufferFrames,
    maxBufferFrames: osDefault?.maxBufferFrames,
    defaultBufferFrames: osDefault?.defaultBufferFrames,
    bufferGranularity: osDefault?.bufferGranularity,
    probeNote: osDefault?.probeNote,
  );

  final cards = <_OutputCardEntry>[
    _OutputCardEntry(
      cardKey: 'system_output',
      isSystemOutput: true,
      capability: systemCap,
    ),
  ];

  for (final cap in capabilities) {
    cards.add(
      _OutputCardEntry(
        cardKey: '${cap.deviceId}__${cap.backend}',
        isSystemOutput: false,
        capability: cap,
      ),
    );
  }
  return cards;
}

bool _isOutputCardActive(AudioService audioService, _OutputCardEntry entry) {
  final systemActive = audioService.isSystemOutputActive;
  if (entry.isSystemOutput) {
    return systemActive;
  }
  if (systemActive) {
    return false;
  }
  final activeId = audioService.activeDeviceId;
  if (activeId == null || activeId.isEmpty) {
    return entry.capability.isDefault;
  }
  return entry.capability.deviceId == activeId;
}

IconData _iconForOutputEntry(_OutputCardEntry entry) {
  if (entry.isSystemOutput) {
    return Icons.desktop_windows_rounded;
  }
  final cap = entry.capability;
  final lowerName = cap.name.toLowerCase();
  if (cap.isHdmi ||
      lowerName.contains('hdmi') ||
      lowerName.contains('displayport') ||
      lowerName.contains('display audio') ||
      lowerName.contains('nvidia high definition') ||
      lowerName.contains('amd high definition')) {
    return Icons.settings_input_hdmi_rounded;
  }
  return switch (cap.transport) {
    'usb_dac' => Icons.usb_rounded,
    'headphones' => Icons.headphones_rounded,
    'speakers' => Icons.speaker_rounded,
    'bluetooth' => Icons.bluetooth_audio_rounded,
    'asio' => Icons.tune_rounded,
    _ => cap.backend == 'windows_asio'
        ? Icons.tune_rounded
        : Icons.developer_board_rounded,
  };
}
