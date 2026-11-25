import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/audio_quality_tier.dart';
import '../../models/playback_state.dart';
import '../../models/signal_path.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/ui_scale_controller.dart';
import '../theme/lumina_tokens.dart';
import 'audio_quality_badge.dart';
import 'frosted_glass_container.dart';

/// Formats a raw backend identifier (e.g. `windows_asio`,
/// `windows_wasapi_exclusive`) into a crisp user-facing label.
String formatAudioBackendLabel(String rawBackend) {
  final normalized = rawBackend.trim().toLowerCase();
  if (normalized.isEmpty) return '';
  if (normalized == 'windows_asio' || normalized.contains('asio')) {
    return 'ASIO';
  }
  if (normalized == 'windows_wasapi_exclusive' ||
      normalized.contains('wasapi_exclusive') ||
      normalized.contains('wasapi exclusive')) {
    return 'WASAPI Exclusive';
  }
  if (normalized == 'windows_wasapi_shared' ||
      normalized.contains('wasapi_shared') ||
      normalized.contains('wasapi shared')) {
    return 'WASAPI Shared';
  }
  if (normalized.contains('wasapi')) {
    return 'WASAPI';
  }
  if (normalized == 'macos_core_audio_hog' ||
      normalized.contains('core_audio')) {
    return 'CoreAudio Exclusive';
  }
  if (normalized == 'mobile_direct') {
    return 'Direct USB DAC';
  }
  if (normalized == 'network_dlna' || normalized.contains('dlna')) {
    return 'DLNA';
  }
  if (normalized == 'network_airplay' || normalized.contains('airplay')) {
    return 'AirPlay';
  }
  return rawBackend.trim();
}

/// Formats an output backend and hardware device name as `<backend>: <name>`.
String formatAudioOutputDeviceLabel({
  required String backend,
  required String deviceName,
}) {
  final cleanName = deviceName.trim();
  final cleanBackend = formatAudioBackendLabel(backend);
  if (cleanName.isEmpty) {
    return cleanBackend.isNotEmpty ? cleanBackend : '系統預設輸出';
  }
  if (cleanBackend.isEmpty) return cleanName;
  return '$cleanBackend: $cleanName';
}

/// Controller allowing a parent container (such as `FloatingCapsuleMiniPlayer`)
/// to coordinate closing [AudioQualityBadgeWithPopover] alongside sibling
/// popovers.
class AudioInfoPopoverController extends ChangeNotifier {
  VoidCallback? _toggleCallback;
  VoidCallback? _closeCallback;
  bool _isOpen = false;

  bool get isOpen => _isOpen;

  void _attach({
    required VoidCallback toggle,
    required VoidCallback close,
    required bool isOpen,
  }) {
    _toggleCallback = toggle;
    _closeCallback = close;
    _isOpen = isOpen;
  }

  void _detach(VoidCallback close) {
    if (_closeCallback == close) {
      _toggleCallback = null;
      _closeCallback = null;
      _isOpen = false;
    }
  }

  void _setOpen(bool open) {
    if (_isOpen == open) return;
    _isOpen = open;
    notifyListeners();
  }

  void toggle() => _toggleCallback?.call();

  void close() => _closeCallback?.call();
}

/// Compact frosted-glass technical readout overlay triggered from
/// [AudioQualityBadge].
class AudioInfoPopover extends StatefulWidget {
  final AudioService audioService;
  final TrackInfo? track;
  final AudioQualityTier? tierOverride;
  final int? overrideBitrateKbps;
  final UiScaleController? scaleController;
  final VoidCallback? onClose;
  final VoidCallback? onOpenSignalPath;
  final double? maxWidth;
  final double? maxHeight;

  const AudioInfoPopover({
    super.key,
    required this.audioService,
    this.track,
    this.tierOverride,
    this.overrideBitrateKbps,
    this.scaleController,
    this.onClose,
    this.onOpenSignalPath,
    this.maxWidth,
    this.maxHeight,
  });

  @override
  State<AudioInfoPopover> createState() => _AudioInfoPopoverState();
}

class _AudioInfoPopoverState extends State<AudioInfoPopover> {
  String _outputDeviceLabel = '';
  bool _loadingDevice = false;
  StreamSubscription<SignalPath>? _signalPathSub;

  @override
  void initState() {
    super.initState();
    _outputDeviceLabel = _resolveFallbackOutputDevice();
    _loadOutputDevice();
    _signalPathSub = widget.audioService.signalPathStream.listen((_) {
      _loadOutputDevice();
    });
  }

  @override
  void didUpdateWidget(covariant AudioInfoPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioService != widget.audioService ||
        oldWidget.scaleController != widget.scaleController) {
      _signalPathSub?.cancel();
      _outputDeviceLabel = _resolveFallbackOutputDevice();
      _loadOutputDevice();
      _signalPathSub = widget.audioService.signalPathStream.listen((_) {
        _loadOutputDevice();
      });
    }
  }

  @override
  void dispose() {
    _signalPathSub?.cancel();
    super.dispose();
  }

  String _resolveFallbackOutputDevice() {
    if (widget.audioService.isSystemOutputActive) {
      return '系統預設輸出';
    }
    final nodes = widget.audioService.currentSignalPath.nodes;
    if (nodes.isNotEmpty) {
      final last = nodes.last;
      if (last.subtitle.trim().isNotEmpty) {
        return last.subtitle.trim();
      }
    }
    return widget.audioService.connectionMode.label;
  }

  Future<void> _loadOutputDevice() async {
    if (_loadingDevice || !mounted) return;
    _loadingDevice = true;
    try {
      if (widget.audioService.isSystemOutputActive) {
        if (!mounted) return;
        setState(() => _outputDeviceLabel = '系統預設輸出');
        return;
      }

      List<AudioDeviceInfo> devices = const [];
      try {
        devices = await widget.audioService.listAudioDevices();
      } catch (_) {}

      final activeId =
          widget.audioService.activeDeviceId ??
          widget.scaleController?.lastOutputDeviceId;
      final activeDev =
          devices.where((d) => d.id == activeId).firstOrNull ??
          devices.where((d) => d.isDefault).firstOrNull ??
          devices.firstOrNull;

      String? resolved;
      if (activeDev != null && activeDev.name.trim().isNotEmpty) {
        resolved = formatAudioOutputDeviceLabel(
          backend: activeDev.backend,
          deviceName: activeDev.name,
        );
      }

      if (resolved == null) {
        try {
          final info = await widget.audioService.getOutputInfo();
          final out = info.output;
          if (out.selectedDevice.trim().isNotEmpty) {
            resolved = formatAudioOutputDeviceLabel(
              backend: out.audioApi.isNotEmpty ? out.audioApi : out.outputMode,
              deviceName: out.selectedDevice,
            );
          }
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _outputDeviceLabel = resolved ?? _resolveFallbackOutputDevice();
      });
    } finally {
      _loadingDevice = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolvedWidth = widget.maxWidth != null
        ? math.min(284.0, widget.maxWidth!)
        : 284.0;
    final resolvedMaxHeight = widget.maxHeight;

    return StreamBuilder<PlaybackState>(
      stream: widget.audioService.stateStream,
      initialData: widget.audioService.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.audioService.currentState;
        final track = widget.track ?? state.track;
        final tier = widget.tierOverride ?? getAudioQualityTier(track);
        final style = AudioQualityBadgeStyle.forTier(tier);

        final codecText = track != null
            ? formatAudioCodecName(track.format)
            : '—';
        final sampleSpecText = track != null
            ? formatAudioSampleSpec(track.format)
            : '—';
        final bitrateText = track != null
            ? formatAudioBitrateLabel(
                track,
                overrideBitrateKbps: widget.overrideBitrateKbps,
              )
            : '—';
        final tierValueColor = tier == AudioQualityTier.hiRes
            ? style.textColor
            : LuminaTokens.glassTextPrimary;

        final body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: style.textColor,
                    boxShadow: style.glowColor != null
                        ? [
                            BoxShadow(
                              color: style.glowColor!,
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '音訊品質詳情',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: LuminaTokens.glassTextSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AudioQualityBadge(
                  tier: tier,
                  buttonKey: const Key('audio_info_popover_tier_badge'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            const SizedBox(height: 9),
            _SpecRow(
              label: '等級',
              value: tier.displayName,
              valueColor: tierValueColor,
            ),
            const SizedBox(height: 6),
            _SpecRow(label: '格式', value: codecText),
            const SizedBox(height: 6),
            _SpecRow(label: '取樣規格', value: sampleSpecText),
            const SizedBox(height: 6),
            _SpecRow(label: '即時串流率', value: bitrateText),
            const SizedBox(height: 6),
            _SpecRow(
              label: '當前輸出裝置',
              value: _outputDeviceLabel,
              maxLines: 2,
            ),
            if (widget.onOpenSignalPath != null) ...[
              const SizedBox(height: 10),
              const Divider(color: LuminaTokens.glassCardDivider, height: 1),
              const SizedBox(height: 6),
              _SignalPathActionButton(
                onTap: () {
                  widget.onClose?.call();
                  widget.onOpenSignalPath!();
                },
              ),
            ],
          ],
        );

        return Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: resolvedWidth,
              maxHeight: resolvedMaxHeight ?? double.infinity,
            ),
            child: FrostedGlassContainer(
              key: const Key('audio_info_popover'),
              width: resolvedWidth,
              blurSigma: LuminaTokens.audioInfoPopoverBlur,
              color: LuminaTokens.audioInfoPopoverBg,
              borderRadius: BorderRadius.circular(
                LuminaTokens.audioInfoPopoverRadius,
              ),
              border: Border.all(
                color: LuminaTokens.audioInfoPopoverBorder,
                width: 1,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x88000000),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ],
              child: resolvedMaxHeight != null
                  ? SingleChildScrollView(child: body)
                  : body,
            ),
          ),
        );
      },
    );
  }
}

class _SpecRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final int maxLines;

  const _SpecRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: LuminaTokens.glassTextTertiary,
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? LuminaTokens.glassTextPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.3,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _SignalPathActionButton extends StatefulWidget {
  final VoidCallback onTap;

  const _SignalPathActionButton({required this.onTap});

  @override
  State<_SignalPathActionButton> createState() =>
      _SignalPathActionButtonState();
}

class _SignalPathActionButtonState extends State<_SignalPathActionButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '檢視完整訊號路徑',
      child: InkWell(
        key: const Key('btn_open_signal_path_from_popover'),
        onTap: widget.onTap,
        onHover: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        onFocusChange: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(6),
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: AnimatedContainer(
          duration: LuminaTokens.focusDuration,
          curve: LuminaTokens.motionCurve,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered
                ? LuminaTokens.glassRowHoverBg
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? LuminaTokens.focusRing : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '檢視完整訊號路徑',
                style: TextStyle(
                  color: _hovered
                      ? LuminaTokens.glassTextPrimary
                      : LuminaTokens.glassTextSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 15,
                color: _hovered
                    ? LuminaTokens.glassTextPrimary
                    : LuminaTokens.glassTextTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stateful anchor widget that pairs [AudioQualityBadge] (or a custom anchor
/// via [anchorBuilder]) with a viewport-clamped [AudioInfoPopover] overlay.
///
/// Automatically integrates with [EscapeDismissRegistry], outside-tap dismiss,
/// and window metric changes so both Bottom Bar and Now Playing can attach
/// [AudioInfoPopover] without duplicating overlay boilerplate.
class AudioQualityBadgeWithPopover extends StatefulWidget {
  final AudioService audioService;
  final TrackInfo? track;
  final AudioQualityTier? tier;
  final int? overrideBitrateKbps;
  final UiScaleController? scaleController;
  final AudioInfoPopoverController? controller;
  final VoidCallback? onBeforeOpen;
  final VoidCallback? onOpenSignalPath;
  final Key? buttonKey;
  final bool preferAbove;
  final Widget Function(BuildContext context, VoidCallback toggle, bool isOpen)?
      anchorBuilder;

  const AudioQualityBadgeWithPopover({
    super.key,
    required this.audioService,
    this.track,
    this.tier,
    this.overrideBitrateKbps,
    this.scaleController,
    this.controller,
    this.onBeforeOpen,
    this.onOpenSignalPath,
    this.buttonKey = const Key('quality_badge_button'),
    this.preferAbove = true,
    this.anchorBuilder,
  });

  @override
  State<AudioQualityBadgeWithPopover> createState() =>
      _AudioQualityBadgeWithPopoverState();
}

class _AudioQualityBadgeWithPopoverState
    extends State<AudioQualityBadgeWithPopover>
    with WidgetsBindingObserver {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _overlayEntry;
  bool _metricsUpdateScheduled = false;
  late final bool Function() _escapeDismissHandler = _handleEscapeDismiss;
  late final VoidCallback _closeCallback = _closeOverlay;

  bool get _isOpen => _overlayEntry != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachController(widget.controller);
  }

  @override
  void didUpdateWidget(covariant AudioQualityBadgeWithPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(_closeCallback);
      _attachController(widget.controller);
    }
    if (_overlayEntry != null) {
      _scheduleOverlayRebuild();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleOverlayRebuild();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _scheduleOverlayRebuild();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?._detach(_closeCallback);
    _closeOverlay(markState: false);
    super.dispose();
  }

  void _attachController(AudioInfoPopoverController? controller) {
    controller?._attach(
      toggle: _toggleOverlay,
      close: _closeCallback,
      isOpen: _isOpen,
    );
  }

  void _scheduleOverlayRebuild() {
    if (_overlayEntry == null || _metricsUpdateScheduled) return;
    _metricsUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsUpdateScheduled = false;
      if (!mounted) return;
      _overlayEntry?.markNeedsBuild();
    });
  }

  bool _handleEscapeDismiss() {
    if (_overlayEntry == null) {
      EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
      return false;
    }
    _closeOverlay();
    return true;
  }

  void _closeOverlay({bool markState = true}) {
    EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
    final entry = _overlayEntry;
    if (entry == null) return;
    entry.remove();
    entry.dispose();
    _overlayEntry = null;
    widget.controller?._setOpen(false);
    if (markState && mounted) {
      setState(() {});
    }
  }

  void _toggleOverlay() {
    if (_overlayEntry != null) {
      _closeOverlay();
      return;
    }

    widget.onBeforeOpen?.call();
    if (!mounted) return;

    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(entry);
    _overlayEntry = entry;
    widget.controller?._setOpen(true);
    EscapeDismissRegistry.instance.register(_escapeDismissHandler);
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    const preferredWidth = 284.0;
    const preferredMaxHeight = 320.0;
    const edgeMargin = 12.0;
    const anchorGap = 8.0;

    final targetRender = _anchorKey.currentContext?.findRenderObject();
    final overlayRender =
        Overlay.of(context, rootOverlay: true).context.findRenderObject();

    final targetBox = targetRender is RenderBox &&
            targetRender.attached &&
            targetRender.hasSize
        ? targetRender
        : null;
    final overlayBox = overlayRender is RenderBox &&
            overlayRender.attached &&
            overlayRender.hasSize
        ? overlayRender
        : null;

    final overlaySize = overlayBox?.size ?? MediaQuery.sizeOf(overlayContext);
    final maxAllowedWidth = math.max(
      180.0,
      overlaySize.width - edgeMargin * 2,
    );
    final popoverWidth = math.min(preferredWidth, maxAllowedWidth);

    Rect? targetRect;
    if (targetBox != null && overlayBox != null) {
      final topLeft = targetBox.localToGlobal(
        Offset.zero,
        ancestor: overlayBox,
      );
      final bottomRight = targetBox.localToGlobal(
        targetBox.size.bottomRight(Offset.zero),
        ancestor: overlayBox,
      );
      targetRect = Rect.fromPoints(topLeft, bottomRight);
    }

    Widget positionedPopover;
    if (targetRect != null) {
      final rawLeft = targetRect.center.dx - popoverWidth / 2;
      final maxLeft = math.max(
        edgeMargin,
        overlaySize.width - popoverWidth - edgeMargin,
      );
      final clampedLeft = rawLeft.clamp(edgeMargin, maxLeft).toDouble();

      final spaceAbove = (targetRect.top - anchorGap) - edgeMargin;
      final spaceBelow =
          overlaySize.height - (targetRect.bottom + anchorGap) - edgeMargin;
      final placeAbove = widget.preferAbove
          ? (spaceAbove >= 160.0 || spaceAbove >= spaceBelow)
          : (spaceBelow < 160.0 && spaceAbove > spaceBelow);

      final minHeight = math.min(
        120.0,
        math.max(0.0, overlaySize.height - edgeMargin * 2),
      );

      if (placeAbove) {
        final rawBottom = targetRect.top - anchorGap;
        final maxBottom = math.max(edgeMargin, overlaySize.height - edgeMargin);
        final minBottom = math.min(maxBottom, edgeMargin + minHeight);
        final clampedBottom = rawBottom.clamp(minBottom, maxBottom).toDouble();
        final maxHeight = math.min(
          preferredMaxHeight,
          math.max(0.0, clampedBottom - edgeMargin),
        );
        positionedPopover = Positioned(
          left: clampedLeft,
          bottom: overlaySize.height - clampedBottom,
          child: _buildPopoverContent(
            maxWidth: popoverWidth,
            maxHeight: maxHeight,
          ),
        );
      } else {
        final rawTop = targetRect.bottom + anchorGap;
        final maxTop = math.max(
          edgeMargin,
          overlaySize.height - edgeMargin - minHeight,
        );
        final clampedTop = rawTop.clamp(edgeMargin, maxTop).toDouble();
        final maxHeight = math.min(
          preferredMaxHeight,
          math.max(0.0, overlaySize.height - clampedTop - edgeMargin),
        );
        positionedPopover = Positioned(
          left: clampedLeft,
          top: clampedTop,
          child: _buildPopoverContent(
            maxWidth: popoverWidth,
            maxHeight: maxHeight,
          ),
        );
      }
    } else {
      final fallbackMaxHeight = math.min(
        preferredMaxHeight,
        math.max(120.0, overlaySize.height - edgeMargin * 2),
      );
      positionedPopover = CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        targetAnchor:
            widget.preferAbove ? Alignment.topCenter : Alignment.bottomCenter,
        followerAnchor:
            widget.preferAbove ? Alignment.bottomCenter : Alignment.topCenter,
        offset: Offset(0, widget.preferAbove ? -anchorGap : anchorGap),
        child: _buildPopoverContent(
          maxWidth: popoverWidth,
          maxHeight: fallbackMaxHeight,
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeOverlay,
          ),
        ),
        positionedPopover,
      ],
    );
  }

  Widget _buildPopoverContent({
    required double maxWidth,
    required double maxHeight,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: AudioInfoPopover(
        audioService: widget.audioService,
        track: widget.track,
        tierOverride: widget.tier,
        overrideBitrateKbps: widget.overrideBitrateKbps,
        scaleController: widget.scaleController,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        onClose: _closeOverlay,
        onOpenSignalPath: widget.onOpenSignalPath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget anchor;
    if (widget.anchorBuilder != null) {
      anchor = widget.anchorBuilder!(context, _toggleOverlay, _isOpen);
    } else if (widget.track != null || widget.tier != null) {
      anchor = AudioQualityBadge(
        tier: widget.tier,
        track: widget.track,
        isActive: _isOpen,
        buttonKey: widget.buttonKey,
        onTap: _toggleOverlay,
      );
    } else {
      anchor = StreamBuilder<PlaybackState>(
        stream: widget.audioService.stateStream,
        initialData: widget.audioService.currentState,
        builder: (context, snapshot) {
          final liveTrack =
              (snapshot.data ?? widget.audioService.currentState).track;
          return AudioQualityBadge(
            track: liveTrack,
            isActive: _isOpen,
            buttonKey: widget.buttonKey,
            onTap: _toggleOverlay,
          );
        },
      );
    }

    return CompositedTransformTarget(
      link: _layerLink,
      child: KeyedSubtree(
        key: _anchorKey,
        child: anchor,
      ),
    );
  }
}
