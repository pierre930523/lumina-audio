part of 'audio_info_popover.dart';

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
  ValueListenable<double>? _bottomClearanceListenable;
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

    _bottomClearanceListenable = BottomPlayerBarScope.listenableOf(context);
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
    final listenable = _bottomClearanceListenable;
    if (listenable == null) {
      return _buildClampedOverlay(overlayContext, 0.0);
    }
    return ValueListenableBuilder<double>(
      valueListenable: listenable,
      builder: (ctx, clearance, _) => _buildClampedOverlay(ctx, clearance),
    );
  }

  Widget _buildClampedOverlay(
    BuildContext overlayContext,
    double bottomClearance,
  ) {
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
    final topInset = MediaQuery.paddingOf(overlayContext).top;
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

    final effectiveBottomInset =
        (targetRect != null &&
                targetRect.bottom > overlaySize.height - bottomClearance - 1.0)
            ? 0.0
            : bottomClearance;
    final usableTop = math.min(topInset + edgeMargin, overlaySize.height);
    final usableBottom = math.max(
      usableTop,
      overlaySize.height - effectiveBottomInset - edgeMargin,
    );
    final usableHeight = math.max(0.0, usableBottom - usableTop);

    Widget positionedPopover;
    if (targetRect != null) {
      final rawLeft = targetRect.center.dx - popoverWidth / 2;
      final maxLeft = math.max(
        edgeMargin,
        overlaySize.width - popoverWidth - edgeMargin,
      );
      final clampedLeft = rawLeft.clamp(edgeMargin, maxLeft).toDouble();

      final spaceAbove = (targetRect.top - anchorGap) - usableTop;
      final spaceBelow = usableBottom - (targetRect.bottom + anchorGap);
      final placeAbove = widget.preferAbove
          ? (spaceAbove >= 160.0 || spaceAbove >= spaceBelow)
          : (spaceBelow < 160.0 && spaceAbove > spaceBelow);

      final minHeight = math.min(120.0, usableHeight);

      if (placeAbove) {
        final rawBottom = targetRect.top - anchorGap;
        final maxBottom = usableBottom;
        final minBottom = math.min(maxBottom, usableTop + minHeight);
        final clampedBottom = rawBottom.clamp(minBottom, maxBottom).toDouble();
        final maxHeight = math.min(
          preferredMaxHeight,
          math.max(0.0, clampedBottom - usableTop),
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
        final maxTop = math.max(usableTop, usableBottom - minHeight);
        final clampedTop = rawTop.clamp(usableTop, maxTop).toDouble();
        final maxHeight = math.min(
          preferredMaxHeight,
          math.max(0.0, usableBottom - clampedTop),
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
        math.max(120.0, usableHeight),
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
