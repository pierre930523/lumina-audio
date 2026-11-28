part of 'floating_capsule.dart';

extension _FloatingCapsuleOverlays on _FloatingCapsuleMiniPlayerState {
  ({
    Widget badge,
    Widget queueBtn,
    Widget outputBtn,
    Widget lyricsBtn,
    Widget? autoplayBtn,
  })
  _buildFooterControls(BuildContext context, TrackInfo? track) {
    final nowPlayingMode = widget.isNowPlayingExpanded;
    final badge = AudioQualityBadgeWithPopover(
      audioService: widget.audioService,
      track: track,
      scaleController: widget.uiScaleController,
      controller: _qualityPopoverController,
      onBeforeOpen: _closeAllOverlays,
      onOpenSignalPath: () => SignalPathModal.show(context, widget.audioService),
    );
    final queueBtn = _buildFooterIconTrigger(
      buttonKey: const Key('btn_quick_queue_popover'),
      anchorKey: _queueAnchorKey,
      link: _queueLayerLink,
      isOpen: nowPlayingMode
          ? widget.isQueueDrawerOpen
          : (_queueOverlay != null),
      icon: Icons.queue_music_rounded,
      tooltip: '播放佇列',
      onTap: nowPlayingMode
          ? (widget.onToggleNowPlayingQueue ?? _toggleQueuePopover)
          : _toggleQueuePopover,
    );
    final outputBtn = _buildFooterIconTrigger(
      buttonKey: const Key('btn_quick_output_popover'),
      anchorKey: _outputAnchorKey,
      link: _outputLayerLink,
      isOpen: _outputOverlay != null,
      icon: Icons.speaker_outlined,
      tooltip: '切換音訊輸出裝置（ASIO / WASAPI）',
      onTap: _toggleOutputPopover,
    );
    final lyricsBtn = _buildLyricsToggleButton();
    final autoplayController = _autoplayController;
    final showAutoplayToggle =
        autoplayController != null || widget.recommendationSettings != null;
    final isAutoplayEnabled =
        autoplayController?.enabled ??
        widget.recommendationSettings?.autoplayEnabled ??
        true;
    final autoplayBtn = showAutoplayToggle
        ? _FooterIconTrigger(
            buttonKey: const Key('btn_autoplay_toggle'),
            isOpen: isAutoplayEnabled,
            icon: Icons.all_inclusive_rounded,
            tooltip: '無限自動接播（開啟／關閉）',
            onTap: () => _toggleAutoplay(isAutoplayEnabled),
          )
        : null;
    return (
      badge: badge,
      queueBtn: queueBtn,
      outputBtn: outputBtn,
      lyricsBtn: lyricsBtn,
      autoplayBtn: autoplayBtn,
    );
  }

  Widget _buildClampedPopoverOverlay({
    required BuildContext overlayContext,
    required GlobalKey anchorKey,
    required LayerLink link,
    required double preferredWidth,
    required Widget Function(PopoverClampResult clamp) builder,
  }) {
    final targetRender = anchorKey.currentContext?.findRenderObject();
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
    final targetTopLeft = (targetBox != null && overlayBox != null)
        ? targetBox.localToGlobal(Offset.zero, ancestor: overlayBox)
        : null;

    final clamp = LuminaResponsive.computeClampedPopover(
      overlaySize: overlaySize,
      targetTopLeft: targetTopLeft,
      targetSize: targetBox?.size,
      preferredWidth: preferredWidth,
      preferredMaxHeight: 420.0,
      preferAbove: true,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _closeAllOverlays(),
          ),
        ),
        CompositedTransformFollower(
          link: link,
          showWhenUnlinked: false,
          targetAnchor: clamp.targetAnchor,
          followerAnchor: clamp.followerAnchor,
          offset: clamp.offset,
          child: builder(clamp),
        ),
      ],
    );
  }

  void _toggleOutputPopover() {
    final wasOpen = _outputOverlay != null;
    _closeAllOverlays(markState: false);
    if (wasOpen) {
      _refreshState();
      return;
    }

    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (overlayContext) => _buildClampedPopoverOverlay(
        overlayContext: overlayContext,
        anchorKey: _outputAnchorKey,
        link: _outputLayerLink,
        preferredWidth: 286.0,
        builder: (clamp) => QuickOutputPopover(
          audioService: widget.audioService,
          scaleController: widget.uiScaleController,
          maxWidth: clamp.width,
          maxHeight: clamp.maxHeight,
          onClose: () => _closeAllOverlays(),
          onOpenFullZones: widget.onOpenZones,
        ),
      ),
    );
    overlay.insert(entry);
    _setOutputOverlay(entry);
    EscapeDismissRegistry.instance.register(_escapeDismissHandler);
  }

  void _toggleQueuePopover() {
    final wasOpen = _queueOverlay != null;
    _closeAllOverlays(markState: false);
    if (wasOpen) {
      _refreshState();
      return;
    }

    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (overlayContext) => _buildClampedPopoverOverlay(
        overlayContext: overlayContext,
        anchorKey: _queueAnchorKey,
        link: _queueLayerLink,
        preferredWidth: 308.0,
        builder: (clamp) => QuickQueuePopover(
          audioService: widget.audioService,
          maxWidth: clamp.width,
          maxHeight: clamp.maxHeight,
          onClose: () => _closeAllOverlays(),
          onOpenLibrary: widget.onOpenLibrary,
          recommendationSettings: widget.recommendationSettings,
        ),
      ),
    );
    overlay.insert(entry);
    _setQueueOverlay(entry);
    EscapeDismissRegistry.instance.register(_escapeDismissHandler);
  }
}
