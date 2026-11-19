import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/audio_output_info.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../settings/settings_widgets.dart';
import '../theme/lumina_tokens.dart';
import 'device_settings_dialog.dart';

class OutputZonePanel extends StatefulWidget {
  final AudioService audioService;

  const OutputZonePanel({super.key, required this.audioService});

  @override
  State<OutputZonePanel> createState() => _OutputZonePanelState();
}

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

class _OutputZonePanelState extends State<OutputZonePanel>
    with WidgetsBindingObserver {
  // Preserved exact card background colors asserted by output_zone_redesign_test.dart
  static const _activeCardBg = Color(0xFF2E323C);
  static const _activeCardBorder = LuminaTokens.accentBlue;
  static const _inactiveCardBg = Color(0xFF191B21);
  static const _inactiveCardBorder = LuminaTokens.borderSubtle;
  static const _purpleAccent = Color(0xFF7C4DFF);

  List<AudioDeviceCapabilitiesModel> _capabilities = const [];
  AudioEngineOutputInfoModel _outputInfo = const AudioEngineOutputInfoModel();
  List<AudioZoneInfo> _zones = const [];
  final Set<String> _selectedGroupZones = {};

  bool _loading = true;
  bool _refreshing = false;
  String? _activatingCardKey;
  String? _errorMessage;
  String? _statusMessage;
  String? _lastKnownOsDefaultPhysicalId;

  StreamSubscription<PlaybackState>? _stateSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stateSub = widget.audioService.stateStream.listen((state) {
      if (!mounted) return;
      if (state.deviceLost &&
          (state.lastError != null && state.lastError!.isNotEmpty)) {
        _errorMessage = state.lastError;
        _refreshDevices(userInitiated: false);
      } else {
        setState(() {});
      }
    });
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshDevices(userInitiated: false);
    }
  }

  Future<void> _load() async {
    await _fetchAll(isInitial: true);
  }

  Future<void> _refreshDevices({bool userInitiated = true}) async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      if (userInitiated) {
        _errorMessage = null;
      }
    });
    await _fetchAll(isInitial: false, userInitiated: userInitiated);
  }

  Future<void> _fetchAll({
    required bool isInitial,
    bool userInitiated = false,
  }) async {
    try {
      final results = await Future.wait<dynamic>([
        widget.audioService.listDeviceCapabilities(),
        widget.audioService.listAudioDevices(),
        widget.audioService.getOutputInfo(),
        widget.audioService.listZones(),
      ]);

      if (!mounted) return;
      final rawCaps = results[0] as List<AudioDeviceCapabilitiesModel>;
      final devs = results[1] as List<AudioDeviceInfo>;
      final info = results[2] as AudioEngineOutputInfoModel;
      final zones = results[3] as List<AudioZoneInfo>;

      final normalizedCaps = _buildDedupedCapabilities(rawCaps, devs);
      final osDefault = _resolveOsDefaultCapability(normalizedCaps, info);
      final nextOsDefaultPhysical = osDefault?.physicalEndpointId;

      final osDefaultChanged =
          !isInitial &&
          _lastKnownOsDefaultPhysicalId != null &&
          nextOsDefaultPhysical != null &&
          _lastKnownOsDefaultPhysicalId != nextOsDefaultPhysical;

      if (osDefaultChanged &&
          widget.audioService.isSystemOutputActive &&
          widget.audioService.currentState.status == PlaybackStatus.playing) {
        await widget.audioService.selectAudioDevice(null);
      }

      if (!mounted) return;
      setState(() {
        _capabilities = normalizedCaps;
        _outputInfo = info;
        _zones = zones;
        _lastKnownOsDefaultPhysicalId = nextOsDefaultPhysical;
        _loading = false;
        _refreshing = false;
        if (userInitiated && _errorMessage == null) {
          _statusMessage = '已更新裝置清單（共 ${normalizedCaps.length} 個硬體輸出介面）';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _errorMessage = '重新整理裝置清單失敗：$e';
      });
    }
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
    if (widget.audioService.isSystemOutputActive) {
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
        widget.audioService.isStrictBitPerfect ||
        widget.audioService.currentSignalPath.dspBypassed;
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

  List<_OutputCardEntry> _buildCardEntries() {
    final osDefault = _resolveOsDefaultCapability(_capabilities, _outputInfo);
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

    for (final cap in _capabilities) {
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

  bool _isCardActive(_OutputCardEntry entry) {
    final systemActive = widget.audioService.isSystemOutputActive;
    if (entry.isSystemOutput) {
      return systemActive;
    }
    if (systemActive) {
      return false;
    }
    final activeId = widget.audioService.activeDeviceId;
    if (activeId == null || activeId.isEmpty) {
      return entry.capability.isDefault;
    }
    return entry.capability.deviceId == activeId;
  }

  IconData _iconForEntry(_OutputCardEntry entry) {
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

  Future<void> _activateCard(_OutputCardEntry entry) async {
    setState(() {
      _activatingCardKey = entry.cardKey;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      if (entry.isSystemOutput) {
        await widget.audioService.selectAudioDevice(null);
      } else {
        await widget.audioService.selectAudioDevice(
          entry.capability.deviceId,
          backendIndex: entry.capability.backendIndex,
        );
      }

      final err = widget.audioService.lastError;
      if (!mounted) return;
      if (err != null && err.isNotEmpty) {
        setState(() {
          _activatingCardKey = null;
          _errorMessage = err;
        });
        await _fetchAll(isInitial: false, userInitiated: false);
        return;
      }

      final info = await widget.audioService.getOutputInfo();
      if (!mounted) return;
      setState(() {
        _activatingCardKey = null;
        _outputInfo = info;
        _statusMessage = entry.isSystemOutput
            ? '已切換至 System Output（跟隨 Windows 預設）'
            : '已啟用 ${entry.capability.name}（${entry.capability.interfaceLabel}）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _activatingCardKey = null;
        _errorMessage = '啟用輸出裝置失敗：$e';
      });
    }
  }

  Future<void> _openSettingsForCard(_OutputCardEntry entry) async {
    final cap = entry.capability;
    final physicalId = cap.physicalEndpointId;
    final exclSibling = entry.isSystemOutput
        ? null
        : _capabilities
              .where(
                (c) =>
                    c.physicalEndpointId == physicalId &&
                    c.backend == 'windows_wasapi_exclusive',
              )
              .firstOrNull;
    final sharedSibling = entry.isSystemOutput
        ? null
        : _capabilities
              .where(
                (c) =>
                    c.physicalEndpointId == physicalId &&
                    c.backend == 'windows_wasapi_shared',
              )
              .firstOrNull;

    await DeviceSettingsDialog.show(
      context,
      audioService: widget.audioService,
      capability: cap,
      exclusiveSibling: exclSibling,
      sharedSibling: sharedSibling,
      isSystemOutput: entry.isSystemOutput,
      deviceIcon: _iconForEntry(entry),
      onDeviceSwitched: () {
        if (mounted) {
          _fetchAll(isInitial: false, userInitiated: false);
        }
      },
    );
    if (mounted) {
      await _fetchAll(isInitial: false, userInitiated: false);
    }
  }

  Future<void> _toggleZone(AudioZoneInfo z) async {
    await widget.audioService.toggleZonePlayPause(z.id);
    if (mounted) setState(() {});
  }

  String _zoneStatusText(AudioZoneInfo z) {
    final s = widget.audioService.zonePlaybackStates[z.id];
    if (s == null || s.status == PlaybackStatus.stopped) return '待機中';
    final prefix = s.status == PlaybackStatus.playing ? '播放中' : '已暫停';
    return s.track != null ? '$prefix · ${s.track!.title}' : prefix;
  }

  Future<void> _discoverZones() async {
    final discovered = await widget.audioService.discoverZones();
    if (!mounted) return;
    setState(() {
      _zones = discovered;
      _statusMessage = '已探索到 ${discovered.length} 個輸出音區';
    });
  }

  Future<void> _groupSelected() async {
    final targets = _selectedGroupZones.isNotEmpty
        ? _selectedGroupZones.toList()
        : _zones.map((z) => z.id).toList();
    if (targets.isEmpty) return;
    await widget.audioService.groupZones('multi-room-group', targets);
    await _fetchAll(isInitial: false, userInitiated: false);
    if (!mounted) return;
    setState(() => _statusMessage = '已建立 ${targets.length} 個同期播放音區群組');
  }

  Future<void> _syncAllZones() async {
    for (final z in _zones) {
      await widget.audioService.syncZoneClock(z.id);
    }
    await _fetchAll(isInitial: false, userInitiated: false);
    if (!mounted) return;
    setState(() => _statusMessage = '已完成 ${_zones.length} 個音區的精準時脈同步');
  }

  @override
  Widget build(BuildContext context) {
    final cards = _buildCardEntries();
    return SingleChildScrollView(
      key: const Key('output_zone_panel'),
      padding: const EdgeInsets.only(
        bottom: LuminaTokens.bottomScrollClearance,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: LuminaTokens.spaceSm,
            runSpacing: LuminaTokens.spaceXs,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '音訊輸出裝置',
                    style: TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: LuminaTokens.space2xs),
                  Text(
                    '選擇此裝置要啟用的實體輸出介面（WASAPI Exclusive / WASAPI Shared / ASIO）',
                    style: TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: '重新整理並偵測實體音訊輸出裝置',
                child: OutlinedButton.icon(
                  key: const Key('btn_refresh_audio_devices'),
                  onPressed: _refreshing
                      ? null
                      : () => _refreshDevices(userInitiated: true),
                  style: LuminaSettingsStyles.outlinedButtonStyle(),
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 17,
                    color: _refreshing
                        ? LuminaTokens.textDisabled
                        : LuminaTokens.textSecondary,
                  ),
                  label: Text(
                    _refreshing ? '重新整理中...' : '重新整理裝置清單',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: LuminaTokens.spaceSm),
            Semantics(
              liveRegion: true,
              label: '音訊裝置錯誤：$_errorMessage',
              child: Container(
                key: const Key('output_device_error_banner'),
                padding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceMd,
                  vertical: LuminaTokens.spaceSm,
                ),
                decoration: BoxDecoration(
                  color: LuminaTokens.statusErrorBg,
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                  border: Border.all(color: LuminaTokens.statusError),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: LuminaTokens.statusError,
                      size: 18,
                    ),
                    const SizedBox(width: LuminaTokens.spaceSm),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: Color(0xFFFECACA),
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    Tooltip(
                      message: '重新偵測音訊輸出裝置並重試連線',
                      child: TextButton(
                        onPressed: () => _refreshDevices(userInitiated: true),
                        style: TextButton.styleFrom(
                          foregroundColor: LuminaTokens.textPrimary,
                          backgroundColor: LuminaTokens.statusError.withValues(
                            alpha: 0.16,
                          ),
                          side: BorderSide(
                            color: LuminaTokens.statusError.withValues(
                              alpha: 0.55,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: LuminaTokens.spaceSm,
                            vertical: LuminaTokens.spaceXs,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              LuminaTokens.radiusSm,
                            ),
                          ),
                        ),
                        child: const Text(
                          '重新偵測',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: LuminaTokens.spaceMd),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: LuminaTokens.space2xl),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.2)),
            )
          else
            LayoutBuilder(
              key: const Key('output_devices_grid'),
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final isTwoCol = width >= 560;
                final isWide = width >= 720;
                final gap = isWide ? LuminaTokens.spaceMd : LuminaTokens.spaceSm;
                final cardPadding = isWide
                    ? LuminaTokens.spaceMd
                    : LuminaTokens.spaceSm;

                if (!isTwoCol) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < cards.length; i++) ...[
                        if (i > 0) SizedBox(height: gap),
                        _buildDeviceCard(cards[i], cardPadding: cardPadding),
                      ],
                    ],
                  );
                }

                final rows = <Widget>[];
                for (var i = 0; i < cards.length; i += 2) {
                  final left = cards[i];
                  final right = i + 1 < cards.length ? cards[i + 1] : null;
                  if (i > 0) rows.add(SizedBox(height: gap));
                  rows.add(
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _buildDeviceCard(
                              left,
                              cardPadding: cardPadding,
                            ),
                          ),
                          SizedBox(width: gap),
                          Expanded(
                            child: right != null
                                ? _buildDeviceCard(
                                    right,
                                    cardPadding: cardPadding,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                );
              },
            ),
          if (_statusMessage != null) ...[
            const SizedBox(height: LuminaTokens.spaceSm),
            Semantics(
              liveRegion: true,
              child: Text(
                _statusMessage!,
                key: const Key('output_panel_status_text'),
                style: const TextStyle(
                  color: LuminaTokens.statusSuccess,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          const SizedBox(height: LuminaTokens.spaceLg),
          const Divider(color: LuminaTokens.borderSubtle, height: 1),
          const SizedBox(height: LuminaTokens.spaceMd),
          _buildMultiRoomZonesSection(),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(_OutputCardEntry entry, {required double cardPadding}) {
    final active = _isCardActive(entry);
    final cap = entry.capability;
    final pbState = widget.audioService.currentState;
    final isPlaying = active && pbState.status == PlaybackStatus.playing;
    final isPaused = active && pbState.status == PlaybackStatus.paused;
    final isActivating = _activatingCardKey == entry.cardKey;
    final iconData = _iconForEntry(entry);

    final title = entry.isSystemOutput ? 'System Output' : cap.name;
    final subtitle = entry.isSystemOutput
        ? '跟隨 Windows 預設 · ${cap.name} (${cap.interfaceLabel})'
        : cap.interfaceLabel;

    final statusLabel = isPlaying
        ? (pbState.track != null ? '正在播放 · ${pbState.track!.title}' : '正在播放')
        : (isPaused ? '已暫停 · 使用中' : '使用中');

    final showBitPerfectBadge =
        active &&
        !cap.isSharedMode &&
        _outputInfo.verification.status == 'BIT-PERFECT';

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 136),
      child: Container(
        key: Key('output_card_${entry.cardKey}'),
        padding: EdgeInsets.all(cardPadding),
        decoration: BoxDecoration(
          color: active ? _activeCardBg : _inactiveCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          border: Border.all(
            color: active ? _activeCardBorder : _inactiveCardBorder,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: active
                        ? LuminaTokens.textPrimary.withValues(alpha: 0.12)
                        : LuminaTokens.cardElevatedBg,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                  ),
                  child: Icon(
                    iconData,
                    color: active
                        ? LuminaTokens.textPrimary
                        : LuminaTokens.textSecondary,
                    size: 21,
                  ),
                ),
                const SizedBox(width: LuminaTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: LuminaTokens.space2xs),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: LuminaTokens.spaceMd),
            Row(
              children: [
                if (active) ...[
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isPlaying
                                ? LuminaTokens.statusSuccess
                                : LuminaTokens.accentPurpleText,
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        Flexible(
                          child: Text(
                            statusLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isPlaying
                                  ? LuminaTokens.statusSuccess
                                  : LuminaTokens.textSecondary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (showBitPerfectBadge) ...[
                          const SizedBox(width: LuminaTokens.spaceXs),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LuminaTokens.spaceXs,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _purpleAccent.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusSm,
                              ),
                              border: Border.all(
                                color: LuminaTokens.accentPurpleText.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                            child: const Text(
                              'BIT-PERFECT',
                              style: TextStyle(
                                color: LuminaTokens.accentPurpleText,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('btn_device_settings_${entry.cardKey}'),
                    tooltip: '裝置設定',
                    visualDensity: VisualDensity.compact,
                    style: LuminaSettingsStyles.iconButtonStyle(
                      foregroundColor: LuminaTokens.textPrimary,
                    ),
                    onPressed: () => _openSettingsForCard(entry),
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: LuminaTokens.textPrimary,
                      size: 20,
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: Text(
                      entry.isSystemOutput
                          ? '動態跟隨作業系統預設輸出'
                          : (cap.isSharedMode
                                ? '系統混音器模式'
                                : (cap.backend == 'windows_asio'
                                      ? '硬體原生 ASIO 通道'
                                      : '獨佔位元直出通道')),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: LuminaTokens.spaceSm),
                  Tooltip(
                    message: '啟用 ${entry.isSystemOutput ? 'System Output' : cap.name}',
                    child: FilledButton(
                      key: Key('btn_activate_device_${entry.cardKey}'),
                      onPressed: isActivating
                          ? null
                          : () => _activateCard(entry),
                      style: LuminaSettingsStyles.filledButtonStyle(
                        backgroundColor: _purpleAccent,
                        foregroundColor: LuminaTokens.textPrimary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: LuminaTokens.spaceMd,
                          vertical: LuminaTokens.spaceXs,
                        ),
                        minimumSize: const Size(64, 34),
                      ),
                      child: Text(
                        isActivating ? '啟用中...' : '啟用',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMultiRoomZonesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '多房間與網路音區',
          style: TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        Wrap(
          spacing: LuminaTokens.spaceXs,
          runSpacing: LuminaTokens.spaceXs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: '探索區域網路內的 DLNA 與 AirPlay 播放音區',
              child: FilledButton.icon(
                key: const Key('btn_discover_zones'),
                onPressed: _discoverZones,
                style: LuminaSettingsStyles.filledButtonStyle(),
                icon: const Icon(Icons.radar_rounded, size: 18),
                label: const Text('搜尋 DLNA / AirPlay 設備'),
              ),
            ),
            Tooltip(
              message: '將勾選的多個音區組成同步播放群組',
              child: OutlinedButton.icon(
                key: const Key('btn_group_zones'),
                onPressed: _groupSelected,
                style: LuminaSettingsStyles.outlinedButtonStyle(),
                icon: const Icon(Icons.speaker_group_rounded, size: 18),
                label: const Text('群組同步播放'),
              ),
            ),
            Tooltip(
              message: '對所有網路音區執行精準時脈校準',
              child: OutlinedButton.icon(
                key: const Key('btn_sync_zones'),
                onPressed: _syncAllZones,
                style: LuminaSettingsStyles.outlinedButtonStyle(),
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text('校準時脈同步'),
              ),
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        ..._zones.map((z) {
          final checked = _selectedGroupZones.contains(z.id) || z.groupId != null;
          final zState = widget.audioService.zonePlaybackStates[z.id];
          final zPlaying = zState?.status == PlaybackStatus.playing;
          return Padding(
            padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
            child: Container(
              key: Key('zone_card_${z.id}'),
              padding: const EdgeInsets.all(LuminaTokens.spaceSm),
              decoration: BoxDecoration(
                color: _inactiveCardBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                border: Border.all(color: _inactiveCardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Tooltip(
                        message: '選取「${z.name}」加入多房間群組',
                        child: Semantics(
                          label: '選取 ${z.name}',
                          child: Checkbox(
                            value: checked,
                            activeColor: LuminaTokens.accentBlue,
                            checkColor: LuminaTokens.onAccentDark,
                            side: const BorderSide(
                              color: LuminaTokens.borderControl,
                              width: 1.5,
                            ),
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _selectedGroupZones.add(z.id);
                                } else {
                                  _selectedGroupZones.remove(z.id);
                                }
                              });
                            },
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              z.name,
                              style: const TextStyle(
                                color: LuminaTokens.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_zoneStatusText(z)} • ${z.backend} • 偏移 ${z.clockOffsetUs} µs • 往返延遲 ${z.rttUs} µs • 時脈漂移 ${z.driftPpm.toStringAsFixed(1)} ppm${z.groupId != null ? ' • 群組：${z.groupId}' : ''}',
                              style: const TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 11.5,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: Key('btn_zone_play_${z.id}'),
                        tooltip: zPlaying ? '暫停此音區' : '播放此音區',
                        style: LuminaSettingsStyles.iconButtonStyle(
                          foregroundColor: zPlaying
                              ? LuminaTokens.accentBlue
                              : LuminaTokens.textSecondary,
                        ),
                        icon: Icon(
                          zPlaying
                              ? Icons.pause_circle_outline_rounded
                              : Icons.play_circle_outline_rounded,
                          color: zPlaying
                              ? LuminaTokens.accentBlue
                              : LuminaTokens.textSecondary,
                        ),
                        onPressed: () => _toggleZone(z),
                      ),
                      if (z.backend.startsWith('network_'))
                        IconButton(
                          key: Key('btn_cast_zone_${z.id}'),
                          tooltip: '投放至 ${z.name}',
                          style: LuminaSettingsStyles.iconButtonStyle(
                            foregroundColor: LuminaTokens.accentPurpleText,
                          ),
                          icon: const Icon(
                            Icons.cast_rounded,
                            color: LuminaTokens.accentPurpleText,
                          ),
                          onPressed: () async {
                            await widget.audioService.castToZone(z.id, 'play');
                            if (!mounted) return;
                            setState(
                              () => _statusMessage = '已開始投放至「${z.name}」',
                            );
                          },
                        ),
                    ],
                  ),
                  Row(
                    children: [
                      const Icon(
                        Icons.volume_up_rounded,
                        color: LuminaTokens.textMuted,
                        size: 16,
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: LuminaTokens.accentBlue,
                            inactiveTrackColor: LuminaTokens.borderControl,
                            thumbColor: LuminaTokens.textPrimary,
                            overlayColor: LuminaTokens.focusRing.withValues(
                              alpha: 0.2,
                            ),
                          ),
                          child: Semantics(
                            label: '${z.name} 音量',
                            child: Slider(
                              key: Key('zone_volume_${z.id}'),
                              min: 0.0,
                              max: 1.0,
                              value: z.volume.clamp(0.0, 1.0),
                              onChanged: (v) async {
                                await widget.audioService.setZoneVolume(z.id, v);
                                await _fetchAll(
                                  isInitial: false,
                                  userInitiated: false,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${(z.volume * 100).round()}%',
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
