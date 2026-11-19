import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/ui_scale_controller.dart';
import '../theme/lumina_tokens.dart';

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
        child: Container(
          key: const Key('quick_output_popover'),
          width: resolvedMaxWidth,
          decoration: BoxDecoration(
            color: LuminaTokens.cardElevatedBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
            border: Border.all(
              color: LuminaTokens.borderControl.withValues(alpha: 0.7),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0xAA000000),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
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
                            hoverColor: LuminaTokens.cardHoverBg,
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
                                  color: LuminaTokens.accentBlue,
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
                    color: LuminaTokens.canvasBg,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(color: LuminaTokens.borderSubtle),
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
              const Divider(color: LuminaTokens.borderSubtle, height: 1),

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
                            return SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                vertical: LuminaTokens.space2xs,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final dev in visible)
                                    _buildDeviceRow(dev),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),

              const Divider(color: LuminaTokens.borderSubtle, height: 1),

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
                      activeTrackColor: LuminaTokens.accentBlueStrong,
                      activeThumbColor: LuminaTokens.textPrimary,
                      inactiveThumbColor: LuminaTokens.textSecondary,
                      inactiveTrackColor: LuminaTokens.canvasBg,
                      trackOutlineColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.focused)
                            ? LuminaTokens.focusRing
                            : LuminaTokens.borderControl,
                      ),
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

  Widget _buildDeviceRow(AudioDeviceInfo dev) {
    final isSelected = _selectedId == dev.id;
    final devState = widget.audioService.devicePlaybackStates[dev.id];
    final isPlaying = devState?.status == PlaybackStatus.playing;
    final devVol = (devState?.volume ?? 0.85).clamp(0.0, 1.0);
    final subtitle = _deviceSubtitle(dev.id);

    return InkWell(
      key: Key('quick_output_dev_${dev.id}'),
      onTap: () => _selectDevice(dev),
      mouseCursor: SystemMouseCursors.click,
      hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.72),
      focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
      child: Container(
        color: isSelected
            ? LuminaTokens.accentBlueStrong.withValues(alpha: 0.14)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.volume_up_outlined,
                  size: 16,
                  color: isSelected
                      ? LuminaTokens.accentBlue
                      : LuminaTokens.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dev.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected
                              ? LuminaTokens.accentBlue
                              : LuminaTokens.textPrimary,
                          fontSize: 13,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          key: Key('quick_output_state_${dev.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('quick_output_play_${dev.id}'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: isSelected
                        ? LuminaTokens.accentBlue
                        : LuminaTokens.textSecondary,
                    hoverColor: LuminaTokens.cardHoverBg,
                    focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
                  ).copyWith(
                    mouseCursor: const WidgetStatePropertyAll(
                      SystemMouseCursors.click,
                    ),
                    side: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.focused)
                          ? const BorderSide(
                              color: LuminaTokens.focusRing,
                              width: 1.5,
                            )
                          : const BorderSide(
                              color: Colors.transparent,
                              width: 1.5,
                            ),
                    ),
                  ),
                  tooltip: isPlaying ? '暫停' : '播放',
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  onPressed: () async {
                    await widget.audioService.toggleDevicePlayPause(dev.id);
                    widget.scaleController?.setLastOutputDeviceId(dev.id);
                    if (mounted) {
                      setState(
                        () => _selectedId =
                            widget.audioService.activeDeviceId ?? dev.id,
                      );
                    }
                  },
                ),
                if (isSelected)
                  const ExcludeSemantics(
                    child: Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: LuminaTokens.accentBlue,
                    ),
                  ),
              ],
            ),
            if (isSelected || devState != null)
              SizedBox(
                height: 22,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    overlayColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: LuminaTokens.spaceLg),
                      Expanded(
                        child: Semantics(
                          label: '${dev.name} 音量',
                          slider: true,
                          value: '${(devVol * 100).round()}%',
                          child: Slider(
                            key: Key('quick_output_vol_${dev.id}'),
                            value: devVol,
                            activeColor: LuminaTokens.accentBlue,
                            inactiveColor: LuminaTokens.borderControl,
                            mouseCursor: SystemMouseCursors.click,
                            onChanged: (v) async {
                              await widget.audioService.setDeviceVolume(
                                dev.id,
                                v,
                              );
                              if (mounted) {
                                setState(() {});
                              }
                            },
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${(devVol * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DriverSegmentButton extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DriverSegmentButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_DriverSegmentButton> createState() => _DriverSegmentButtonState();
}

class _DriverSegmentButtonState extends State<_DriverSegmentButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.label} 驅動程式',
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        onFocusChange: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        mouseCursor: SystemMouseCursors.click,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: LuminaTokens.focusDuration,
          curve: LuminaTokens.motionCurve,
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? LuminaTokens.cardHoverBg
                : (_hovered
                      ? LuminaTokens.cardBg
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused
                  ? LuminaTokens.focusRing
                  : (widget.selected
                        ? LuminaTokens.borderControl
                        : Colors.transparent),
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: widget.selected
                  ? LuminaTokens.textPrimary
                  : LuminaTokens.textSecondary,
              fontSize: 12.5,
              fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

