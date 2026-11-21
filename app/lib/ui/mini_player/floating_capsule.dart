import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/signal_path.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/audio_service.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/library_index_cache.dart';
import '../../services/ui_scale_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../signal_path/quality_badge.dart';
import '../signal_path/signal_path_modal.dart';
import '../theme/lumina_tokens.dart';
import '../theme/responsive_layout.dart';
import 'playback_controls.dart';
import 'progress_bar.dart';
import 'quick_output_popover.dart';
import 'quick_queue_popover.dart';
import 'volume_control.dart';

class FloatingCapsuleMiniPlayer extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool showLyrics;
  final bool isNowPlayingExpanded;
  final VoidCallback onToggleLyrics;
  final VoidCallback? onToggleNowPlaying;
  final VoidCallback? onOpenZones;
  final VoidCallback? onOpenLibrary;
  final UiScaleController? uiScaleController;
  final ui.FragmentShader? glassShader;
  final ui.Image? backdropImage;

  const FloatingCapsuleMiniPlayer({
    super.key,
    required this.audioService,
    this.libraryCache,
    required this.showLyrics,
    required this.onToggleLyrics,
    this.isNowPlayingExpanded = false,
    this.onToggleNowPlaying,
    this.onOpenZones,
    this.onOpenLibrary,
    this.uiScaleController,
    this.glassShader,
    this.backdropImage,
  });

  @override
  State<FloatingCapsuleMiniPlayer> createState() =>
      _FloatingCapsuleMiniPlayerState();
}

class _FloatingCapsuleMiniPlayerState extends State<FloatingCapsuleMiniPlayer>
    with WidgetsBindingObserver {
  final LayerLink _outputLayerLink = LayerLink();
  final LayerLink _queueLayerLink = LayerLink();
  final GlobalKey _outputAnchorKey = GlobalKey();
  final GlobalKey _queueAnchorKey = GlobalKey();
  OverlayEntry? _outputOverlay;
  OverlayEntry? _queueOverlay;
  bool _metricsUpdateScheduled = false;
  late final bool Function() _escapeDismissHandler = _handleEscapeDismiss;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleOpenPopoverRebuild();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _scheduleOpenPopoverRebuild();
  }

  void _scheduleOpenPopoverRebuild() {
    if (_outputOverlay == null && _queueOverlay == null) return;
    if (_metricsUpdateScheduled) return;
    _metricsUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsUpdateScheduled = false;
      if (!mounted) return;
      _outputOverlay?.markNeedsBuild();
      _queueOverlay?.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closeAllOverlays(markState: false);
    super.dispose();
  }

  bool _handleEscapeDismiss() {
    if (_outputOverlay == null && _queueOverlay == null) {
      EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
      return false;
    }
    _closeAllOverlays();
    return true;
  }

  void _closeAllOverlays({bool markState = true}) {
    EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
    var changed = false;
    if (_outputOverlay != null) {
      _outputOverlay!.remove();
      _outputOverlay!.dispose();
      _outputOverlay = null;
      changed = true;
    }
    if (_queueOverlay != null) {
      _queueOverlay!.remove();
      _queueOverlay!.dispose();
      _queueOverlay = null;
      changed = true;
    }
    if (changed && markState && mounted) {
      setState(() {});
    }
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
      if (mounted) setState(() {});
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
    setState(() => _outputOverlay = entry);
    EscapeDismissRegistry.instance.register(_escapeDismissHandler);
  }

  void _toggleQueuePopover() {
    final wasOpen = _queueOverlay != null;
    _closeAllOverlays(markState: false);
    if (wasOpen) {
      if (mounted) setState(() {});
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
        ),
      ),
    );
    overlay.insert(entry);
    setState(() => _queueOverlay = entry);
    EscapeDismissRegistry.instance.register(_escapeDismissHandler);
  }

  Widget _buildAlbumArt(TrackInfo? track, double size, double iconSize) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AlbumArtworkView(
            track: track,
            size: size,
            audioService: widget.audioService,
            libraryCache: widget.libraryCache,
            borderRadius: BorderRadius.circular(LuminaTokens.space2xs),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: LuminaTokens.canvasBg.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: LuminaTokens.textPrimary,
                  size: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingTrigger({
    required TrackInfo? track,
    required double artSize,
    required double iconSize,
    required double gap,
  }) {
    final triggerCallback = widget.onToggleNowPlaying ?? widget.onToggleLyrics;
    final tooltipText =
        widget.isNowPlayingExpanded ? '收合播放與歌詞畫面' : '展開播放與逐字歌詞';
    return Tooltip(
      message: tooltipText,
      child: Semantics(
        button: true,
        label: tooltipText,
        child: InkWell(
          key: const Key('btn_expand_now_playing'),
          onTap: triggerCallback,
          mouseCursor: SystemMouseCursors.click,
          hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.72),
          focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: LuminaTokens.motionCurve,
                  child: widget.isNowPlayingExpanded
                      ? const SizedBox.shrink()
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildAlbumArt(track, artSize, iconSize),
                            SizedBox(width: gap),
                          ],
                        ),
                ),
                Expanded(
                  child: widget.isNowPlayingExpanded
                      ? const SizedBox.shrink()
                      : _buildTrackTitles(track),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  StreamingProviderMeta? _resolveStreamingMeta(TrackInfo? track) {
    if (track == null || track.providerName.trim().isEmpty) return null;
    for (final meta in StreamingProviderMeta.streamingServices) {
      if (meta.matchesTrackProvider(track.providerName)) {
        return meta;
      }
    }
    return null;
  }

  Widget _buildTrackTitles(TrackInfo? track) {
    final artistSubtitle = track == null
        ? ''
        : (track.hasDistinctAlbumArtist
            ? '${track.artist} (${track.albumArtist})'
            : track.artist);
    final streamingMeta = _resolveStreamingMeta(track);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track?.title ?? '尚未選擇曲目',
          key: const Key('capsule_track_title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: LuminaTokens.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13.5,
          ),
        ),
        if (streamingMeta != null)
          Row(
            children: [
              Tooltip(
                message: streamingMeta.name,
                child: KeyedSubtree(
                  key: Key('capsule_provider_badge_${streamingMeta.kind}'),
                  child: streamingMeta.buildBadge(
                    boxSize: 16,
                    borderRadius: 4,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  artistSubtitle,
                  key: const Key('capsule_track_artist'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          )
        else
          Text(
            artistSubtitle,
            key: const Key('capsule_track_artist'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 11.5,
            ),
          ),
      ],
    );
  }

  Widget _buildLyricsToggleButton() {
    return Semantics(
      button: true,
      toggled: widget.showLyrics,
      label: '切換歌詞顯示',
      child: IconButton(
        key: const Key('btn_toggle_lyrics'),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        style: IconButton.styleFrom(
          foregroundColor: widget.showLyrics
              ? LuminaTokens.accentBlue
              : LuminaTokens.textSecondary,
          backgroundColor: widget.showLyrics
              ? LuminaTokens.accentBlue.withValues(alpha: 0.16)
              : Colors.transparent,
          hoverColor: LuminaTokens.cardHoverBg,
          focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          ),
        ).copyWith(
          mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? const BorderSide(color: LuminaTokens.focusRing, width: 1.5)
                : const BorderSide(color: Colors.transparent, width: 1.5),
          ),
        ),
        icon: const Icon(Icons.lyrics_rounded, size: 18),
        tooltip: '切換歌詞顯示',
        onPressed: widget.onToggleLyrics,
      ),
    );
  }

  Widget _buildFooterIconTrigger({
    required Key buttonKey,
    required GlobalKey anchorKey,
    required LayerLink link,
    required bool isOpen,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return CompositedTransformTarget(
      key: anchorKey,
      link: link,
      child: _FooterIconTrigger(
        buttonKey: buttonKey,
        isOpen: isOpen,
        icon: icon,
        tooltip: tooltip,
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.audioService.stateStream,
      initialData: widget.audioService.currentState,
      builder: (context, stateSnap) {
        final state = stateSnap.data ?? widget.audioService.currentState;
        final track = state.track;

        return StreamBuilder<SignalPath>(
          stream: widget.audioService.signalPathStream,
          initialData: widget.audioService.currentSignalPath,
          builder: (context, signalSnap) {
            final signalPath =
                signalSnap.data ?? widget.audioService.currentSignalPath;
            final trackDuration =
                track?.duration ?? const Duration(minutes: 4);

            return LayoutBuilder(
              builder: (context, constraints) {
                final maxWidth = constraints.maxWidth;
                final isWide = maxWidth >= 740;
                final isMedium = !isWide && maxWidth >= 480;

                final showQualityBadge = !widget.isNowPlayingExpanded;
                final badge = QualityBadge(
                  quality: signalPath.overallQuality,
                  onTap: () =>
                      SignalPathModal.show(context, widget.audioService),
                );

                final queueBtn = _buildFooterIconTrigger(
                  buttonKey: const Key('btn_quick_queue_popover'),
                  anchorKey: _queueAnchorKey,
                  link: _queueLayerLink,
                  isOpen: _queueOverlay != null,
                  icon: Icons.queue_music_rounded,
                  tooltip: '播放佇列',
                  onTap: _toggleQueuePopover,
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

                final Widget content;
                if (isWide) {
                  // Equal symmetric side widths guarantee the Expanded center column
                  // (and Play/Pause + waveform progress bar inside it) sits
                  // dead-center horizontally across the entire bottom bar.
                  final sideWidth =
                      (maxWidth * 0.24).clamp(188.0, 260.0).floorToDouble();
                  final wideSliderWidth =
                      (sideWidth - 118.0).clamp(56.0, 92.0).floorToDouble();
                  content = Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: sideWidth,
                        child: _buildNowPlayingTrigger(
                          track: track,
                          artSize: 44,
                          iconSize: 24,
                          gap: LuminaTokens.spaceSm,
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Center(
                              child: PlaybackControls(
                                status: state.status,
                                compact: maxWidth < 900,
                                onPrevious: widget.audioService.previous,
                                onPlayPause:
                                    widget.audioService.togglePlayPause,
                                onNext: widget.audioService.next,
                              ),
                            ),
                            const SizedBox(height: 2),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 680),
                              child: TrackProgressBar(
                                position: state.position,
                                duration: trackDuration,
                                expand: true,
                                showWaveform: true,
                                onSeek: widget.audioService.seek,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      SizedBox(
                        width: sideWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (showQualityBadge) ...[
                                    badge,
                                    const SizedBox(width: 6),
                                  ],
                                  _buildLyricsToggleButton(),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  queueBtn,
                                  const SizedBox(width: LuminaTokens.space2xs),
                                  outputBtn,
                                  const SizedBox(width: LuminaTokens.space2xs),
                                  VolumeControl(
                                    volume: state.volume,
                                    isMuted: state.isMuted,
                                    lockedUnity:
                                        widget.audioService.isStrictBitPerfect,
                                    sliderWidth: wideSliderWidth,
                                    onVolumeChanged:
                                        widget.audioService.setVolume,
                                    onToggleMute:
                                        widget.audioService.toggleMute,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                } else if (isMedium) {
                  final mediumSliderWidth =
                      (maxWidth * 0.1).clamp(44.0, 68.0).floorToDouble();
                  content = Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: _buildNowPlayingTrigger(
                              track: track,
                              artSize: 40,
                              iconSize: 22,
                              gap: 10,
                            ),
                          ),
                          const SizedBox(width: LuminaTokens.spaceXs),
                          PlaybackControls(
                            status: state.status,
                            compact: true,
                            onPrevious: widget.audioService.previous,
                            onPlayPause: widget.audioService.togglePlayPause,
                            onNext: widget.audioService.next,
                          ),
                          const SizedBox(width: LuminaTokens.spaceXs),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: showQualityBadge
                                  ? FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: badge,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: TrackProgressBar(
                              position: state.position,
                              duration: trackDuration,
                              expand: true,
                              showWaveform: true,
                              onSeek: widget.audioService.seek,
                            ),
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.max(120.0, maxWidth - 176.0),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  queueBtn,
                                  outputBtn,
                                  VolumeControl(
                                    volume: state.volume,
                                    isMuted: state.isMuted,
                                    lockedUnity:
                                        widget.audioService.isStrictBitPerfect,
                                    sliderWidth: mediumSliderWidth,
                                    onVolumeChanged:
                                        widget.audioService.setVolume,
                                    onToggleMute:
                                        widget.audioService.toggleMute,
                                  ),
                                  _buildLyricsToggleButton(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                } else {
                  final innerW = math.max(120.0, maxWidth - 28.0);
                  final narrowSliderWidth =
                      (maxWidth - 266).clamp(40.0, 82.0).toDouble();
                  final narrowControls = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      queueBtn,
                      outputBtn,
                      VolumeControl(
                        volume: state.volume,
                        isMuted: state.isMuted,
                        lockedUnity: widget.audioService.isStrictBitPerfect,
                        sliderWidth: narrowSliderWidth,
                        onVolumeChanged: widget.audioService.setVolume,
                        onToggleMute: widget.audioService.toggleMute,
                      ),
                    ],
                  );
                  content = Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: _buildNowPlayingTrigger(
                              track: track,
                              artSize: 36,
                              iconSize: 20,
                              gap: LuminaTokens.spaceXs,
                            ),
                          ),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: innerW * 0.62,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PlaybackControls(
                                    status: state.status,
                                    compact: true,
                                    onPrevious: widget.audioService.previous,
                                    onPlayPause:
                                        widget.audioService.togglePlayPause,
                                    onNext: widget.audioService.next,
                                  ),
                                  _buildLyricsToggleButton(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: LuminaTokens.space2xs),
                      TrackProgressBar(
                        position: state.position,
                        duration: trackDuration,
                        expand: true,
                        showWaveform: true,
                        onSeek: widget.audioService.seek,
                      ),
                      const SizedBox(height: LuminaTokens.space2xs),
                      Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: showQualityBadge
                                  ? FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: badge,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.max(
                                100.0,
                                innerW - (showQualityBadge ? 72.0 : 0.0),
                              ),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: narrowControls,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                }

                final isExpanded = widget.isNowPlayingExpanded;
                return Container(
                  key: const Key('liquid_glass_capsule'),
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    horizontal: isWide ? 20.0 : 14.0,
                    vertical: LuminaTokens.spaceXs,
                  ),
                  decoration: BoxDecoration(
                    color: isExpanded
                        ? Colors.transparent
                        : LuminaTokens.cardElevatedBg,
                    border: isExpanded
                        ? null
                        : const Border(
                            top: BorderSide(
                              color: LuminaTokens.borderSubtle,
                              width: 1,
                            ),
                          ),
                  ),
                  child: content,
                );
              },
            );
          },
        );
      },
    );
  }
}

class _FooterIconTrigger extends StatefulWidget {
  final Key buttonKey;
  final bool isOpen;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _FooterIconTrigger({
    required this.buttonKey,
    required this.isOpen,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_FooterIconTrigger> createState() => _FooterIconTriggerState();
}

class _FooterIconTriggerState extends State<_FooterIconTrigger> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        toggled: widget.isOpen,
        label: widget.tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: widget.buttonKey,
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
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: widget.isOpen
                    ? LuminaTokens.accentBlueStrong.withValues(alpha: 0.16)
                    : (_hovered
                          ? LuminaTokens.cardHoverBg
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : (widget.isOpen
                            ? LuminaTokens.accentBlueStrong
                            : Colors.transparent),
                  width: 1.5,
                ),
              ),
              child: Icon(
                widget.icon,
                size: 18,
                color: widget.isOpen
                    ? LuminaTokens.accentBlue
                    : LuminaTokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
