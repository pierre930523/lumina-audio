import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/ui_scale_controller.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'quick_output_popover_widgets.dart';

class QuickOutputPopover extends StatefulWidget {
  final AudioService audioService;
  final UiScaleController? scaleController;
  final VoidCallback onClose;
  final VoidCallback? onOpenFullZones;
  final double? maxWidth;
  final double? maxHeight;

  const QuickOutputPopover({
    super.key,
    required this.audioService,
    this.scaleController,
    required this.onClose,
    this.onOpenFullZones,
    this.maxWidth,
    this.maxHeight,
  });

  @override
  State<QuickOutputPopover> createState() => _QuickOutputPopoverState();
}

class _QuickOutputPopoverState extends State<QuickOutputPopover> {
  final GlideScrollController _scrollController = GlideScrollController();
  List<AudioDeviceInfo> _devices = const [];
  String? _selectedId;
  bool _asioSelected = false;
  bool _loading = true;
  bool _restoreOnStartup = true;

  @override
  void initState() {
    super.initState();
    _restoreOnStartup = widget.scaleController?.restoreOutputOnStartup ?? true;
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final devs = await widget.audioService.listAudioDevices();
    if (!mounted) return;
    final savedId = widget.scaleController?.lastOutputDeviceId;
    final activeDev = devs.where((d) => d.id == savedId).firstOrNull ??
        devs.where((d) => d.isDefault).firstOrNull ??
        devs.firstOrNull;
    final hasAsio = devs.any((d) => d.backend.toLowerCase().contains('asio'));
    setState(() {
      _devices = devs;
      _selectedId = activeDev?.id;
      _asioSelected = activeDev != null
          ? activeDev.backend.toLowerCase().contains('asio')
          : hasAsio;
      _loading = false;
    });
  }

  List<AudioDeviceInfo> get _filteredDevices {
    if (_asioSelected) {
      return _devices
          .where((d) => d.backend.toLowerCase().contains('asio'))
          .toList();
    }
    return _devices
        .where((d) => !d.backend.toLowerCase().contains('asio'))
        .toList();
  }

  String? _deviceSubtitle(String deviceId) {
    final s = widget.audioService.devicePlaybackStates[deviceId];
    final track = s?.track;
    if (s == null || track == null) return null;
    final label = switch (s.status) {
      PlaybackStatus.playing => '播放中',
      PlaybackStatus.paused => '已暫停',
      PlaybackStatus.loading => '載入中',
      PlaybackStatus.seeking => '搜尋中',
      PlaybackStatus.buffering => '緩衝中',
      PlaybackStatus.error => '錯誤',
      _ => '已停止',
    };
    return '$label · ${track.title}';
  }

  Future<void> _selectDevice(AudioDeviceInfo dev) async {
    await widget.audioService.selectAudioDevice(dev.id);
    widget.scaleController?.setLastOutputDeviceId(dev.id);
    if (!mounted) return;
    setState(() => _selectedId = dev.id);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _filteredDevices;
    final resolvedMaxWidth = widget.maxWidth != null
        ? math.min(286.0, widget.maxWidth!)
        : 286.0;
    final resolvedMaxHeight = widget.maxHeight;
    final listMinHeight =
        (resolvedMaxHeight == null || resolvedMaxHeight >= 240.0) ? 88.0 : 0.0;

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: resolvedMaxWidth,
          maxHeight: resolvedMaxHeight ?? double.infinity,
        ),
        child: FrostedGlassContainer(
          key: const Key('quick_output_popover'),
          width: resolvedMaxWidth,
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0xAA000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header row + Settings Zone shortcut
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LuminaTokens.spaceMd,
                  LuminaTokens.spaceSm,
                  10,
                  LuminaTokens.spaceXs,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        '輸出',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.onOpenFullZones != null)
                      Flexible(
                        child: Semantics(
                          button: true,
                          label: '開啟多房間與音區設定',
                          child: InkWell(
                            key: const Key('btn_popover_open_zones'),
                            borderRadius: BorderRadius.circular(6),
                            mouseCursor: SystemMouseCursors.click,
                            hoverColor: LuminaTokens.glassRowHoverBg,
                            focusColor:
                                LuminaTokens.focusRing.withValues(alpha: 0.25),
                            onTap: () {
                              widget.onClose();
                              widget.onOpenFullZones!();
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Text(
                                '多房間與音區設定 >',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: LuminaTokens.glassTextPrimary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Segmented Driver Switcher (ASIO | WASAPI)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: LuminaTokens.glassSegmentTrackBg,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(
                      color: LuminaTokens.glassSegmentTrackBorder,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _DriverSegmentButton(
                          key: const Key('output_tab_asio'),
                          label: 'ASIO',
                          selected: _asioSelected,
                          onTap: () => setState(() => _asioSelected = true),
                        ),
                      ),
                      Expanded(
                        child: _DriverSegmentButton(
                          key: const Key('output_tab_wasapi'),
                          label: 'WASAPI',
                          selected: !_asioSelected,
                          onTap: () => setState(() => _asioSelected = false),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(color: LuminaTokens.glassCardDivider, height: 1),

              // Device List (bounded container)
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: listMinHeight,
                    maxHeight: 240,
                  ),
                  child: _loading
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : visible.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: LuminaTokens.spaceMd,
                            vertical: LuminaTokens.spaceLg,
                          ),
                          child: Text(
                            _asioSelected
                                ? '目前未偵測到 ASIO 驅動裝置'
                                : '目前未偵測到 WASAPI 輸出裝置',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        )
                      : StreamBuilder<PlaybackState>(
                          stream: widget.audioService.stateStream,
                          initialData: widget.audioService.currentState,
                          builder: (context, _) {
                            return SmoothScrollWrapper(
                              controller: _scrollController,
                              child: SingleChildScrollView(
                                controller: _scrollController,
                                padding: const EdgeInsets.symmetric(
                                  vertical: LuminaTokens.space2xs,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (final dev in visible)
                                      _QuickOutputDeviceRow(
                                        dev: dev,
                                        isSelected: _selectedId == dev.id,
                                        devState: widget.audioService
                                            .devicePlaybackStates[dev.id],
                                        subtitle: _deviceSubtitle(dev.id),
                                        onSelect: () => _selectDevice(dev),
                                        onTogglePlayPause: () async {
                                          await widget.audioService
                                              .toggleDevicePlayPause(dev.id);
                                          widget.scaleController
                                              ?.setLastOutputDeviceId(dev.id);
                                          if (mounted) {
                                            setState(
                                              () => _selectedId =
                                                  widget.audioService
                                                      .activeDeviceId ??
                                                  dev.id,
                                            );
                                          }
                                        },
                                        onVolumeChanged: (v) async {
                                          await widget.audioService
                                              .setDeviceVolume(dev.id, v);
                                          if (mounted) {
                                            setState(() {});
                                          }
                                        },
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),

              const Divider(color: LuminaTokens.glassCardDivider, height: 1),

              // Footer Toggle: Restore on startup ("啟動時恢復")
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LuminaTokens.spaceMd,
                  LuminaTokens.spaceXs,
                  LuminaTokens.spaceSm,
                  LuminaTokens.spaceXs,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        '啟動時恢復',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Switch(
                      key: const Key('switch_restore_output_startup'),
                      value: _restoreOnStartup,
                      mouseCursor: SystemMouseCursors.click,
                      onChanged: (val) {
                        setState(() => _restoreOnStartup = val);
                        widget.scaleController?.setRestoreOutputOnStartup(val);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
