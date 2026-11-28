import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/audio_output_info.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../settings/settings_widgets.dart';
import '../theme/lumina_tokens.dart';
import 'device_settings_dialog.dart';

part 'output_zone_device_helpers.dart';
part 'output_zone_device_card.dart';
part 'output_zone_multi_room_section.dart';

class OutputZonePanel extends StatefulWidget {
  final AudioService audioService;

  const OutputZonePanel({super.key, required this.audioService});

  @override
  State<OutputZonePanel> createState() => _OutputZonePanelState();
}

class _OutputZonePanelState extends State<OutputZonePanel>
    with WidgetsBindingObserver {
  // Glass card tokens aligned with output_zone_redesign_test.dart
  static const _activeCardBg = LuminaTokens.glassCardActiveBg;
  static const _activeCardBorder = LuminaTokens.glassCoverRim;
  static const _inactiveCardBg = LuminaTokens.glassCardBg;
  static const _inactiveCardBorder = LuminaTokens.glassCardBorder;

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
      final osDefault = _resolveOsDefaultCapability(
        widget.audioService,
        normalizedCaps,
        info,
      );
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
      deviceIcon: _iconForOutputEntry(entry),
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

  Future<void> _castToZone(AudioZoneInfo z) async {
    await widget.audioService.castToZone(z.id, 'play');
    if (!mounted) return;
    setState(() => _statusMessage = '已開始投放至「${z.name}」');
  }

  Future<void> _setZoneVolume(AudioZoneInfo z, double v) async {
    await widget.audioService.setZoneVolume(z.id, v);
    await _fetchAll(isInitial: false, userInitiated: false);
  }

  @override
  Widget build(BuildContext context) {
    final cards = _buildOutputCardEntries(
      widget.audioService,
      _capabilities,
      _outputInfo,
    );
    return SettingsScrollBody(
      panelKey: const Key('output_zone_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _OutputDevicesHeader(
            refreshing: _refreshing,
            onRefresh: () => _refreshDevices(userInitiated: true),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: LuminaTokens.spaceSm),
            _OutputErrorBanner(
              errorMessage: _errorMessage!,
              onRetry: () => _refreshDevices(userInitiated: true),
            ),
          ],
          const SizedBox(height: LuminaTokens.spaceMd),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: LuminaTokens.space2xl),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.2)),
            )
          else
            _OutputDevicesGrid(
              cards: cards,
              audioService: widget.audioService,
              outputInfo: _outputInfo,
              activatingCardKey: _activatingCardKey,
              onOpenSettings: _openSettingsForCard,
              onActivate: _activateCard,
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
          const Divider(color: LuminaTokens.glassCardDivider, height: 1),
          const SizedBox(height: LuminaTokens.spaceMd),
          _MultiRoomZonesSection(
            zones: _zones,
            selectedGroupZones: _selectedGroupZones,
            audioService: widget.audioService,
            zoneStatusText: _zoneStatusText,
            onDiscoverZones: _discoverZones,
            onGroupSelected: _groupSelected,
            onSyncAllZones: _syncAllZones,
            onToggleZoneSelection: (id, selected) {
              setState(() {
                if (selected) {
                  _selectedGroupZones.add(id);
                } else {
                  _selectedGroupZones.remove(id);
                }
              });
            },
            onToggleZone: _toggleZone,
            onCastZone: _castToZone,
            onVolumeChanged: _setZoneVolume,
          ),
        ],
      ),
    );
  }
}
