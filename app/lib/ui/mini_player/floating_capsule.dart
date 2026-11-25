import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/audio_service.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/library_index_cache.dart';
import '../../services/podcast_store.dart';
import '../../services/recommendation_settings_controller.dart';
import '../../services/streaming/autoplay_controller.dart';
import '../../services/streaming/streaming_playback_coordinator.dart';
import '../../services/ui_scale_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../common/audio_info_popover.dart';
import '../common/frosted_glass_container.dart';
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
  final bool isQueueDrawerOpen;
  final VoidCallback onToggleLyrics;
  final VoidCallback? onToggleNowPlaying;
  final VoidCallback? onToggleNowPlayingQueue;
  final VoidCallback? onToggleNowPlayingLyrics;
  final VoidCallback? onOpenZones;
  final VoidCallback? onOpenLibrary;
  final UiScaleController? uiScaleController;
  final RecommendationSettingsController? recommendationSettings;
  final ui.FragmentShader? glassShader;
  final ui.Image? backdropImage;

  const FloatingCapsuleMiniPlayer({
    super.key,
    required this.audioService,
    this.libraryCache,
    required this.showLyrics,
    required this.onToggleLyrics,
    this.isNowPlayingExpanded = false,
    this.isQueueDrawerOpen = false,
    this.onToggleNowPlaying,
    this.onToggleNowPlayingQueue,
    this.onToggleNowPlayingLyrics,
    this.onOpenZones,
    this.onOpenLibrary,
    this.uiScaleController,
    this.recommendationSettings,
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
  final AudioInfoPopoverController _qualityPopoverController =
      AudioInfoPopoverController();
  OverlayEntry? _outputOverlay;
  OverlayEntry? _queueOverlay;
  bool _metricsUpdateScheduled = false;
  bool _isShuffleEnabled = false;
  LuminaRepeatMode _repeatMode = LuminaRepeatMode.off;
  final math.Random _random = math.Random();
  late final bool Function() _escapeDismissHandler = _handleEscapeDismiss;
  StreamSubscription<void>? _autoplayChangesSub;

  AutoplayController? get _autoplayController =>
      widget.audioService is CoordinatingAudioService
          ? (widget.audioService as CoordinatingAudioService).autoplayController
          : null;

  void _onAutoplayChanged(void _) {
    if (mounted) {
      setState(() {});
    }
  }

  void _onRecommendationSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _subscribeAutoplay() {
    _autoplayChangesSub?.cancel();
    _autoplayChangesSub = _autoplayController?.changes.listen(_onAutoplayChanged);
  }

  void _toggleAutoplay(bool currentlyEnabled) {
    final next = !currentlyEnabled;
    _autoplayController?.setEnabled(next);
    final rec = widget.recommendationSettings;
    if (rec != null && rec.autoplayEnabled != next) {
      unawaited(rec.setAutoplayEnabled(next));
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribeAutoplay();
    widget.recommendationSettings?.addListener(_onRecommendationSettingsChanged);
  }

  @override
  void didUpdateWidget(covariant FloatingCapsuleMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      _subscribeAutoplay();
    }
    if (!identical(
      oldWidget.recommendationSettings,
      widget.recommendationSettings,
    )) {
      oldWidget.recommendationSettings?.removeListener(
        _onRecommendationSettingsChanged,
      );
      widget.recommendationSettings?.addListener(
        _onRecommendationSettingsChanged,
      );
    }
    if (!oldWidget.isNowPlayingExpanded &&
        widget.isNowPlayingExpanded &&
        _queueOverlay != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeAllOverlays();
      });
    }
  }

  void _toggleShuffle() {
    setState(() => _isShuffleEnabled = !_isShuffleEnabled);
  }

  void _cycleRepeat() {
    setState(() {
      _repeatMode = switch (_repeatMode) {
        LuminaRepeatMode.off => LuminaRepeatMode.all,
        LuminaRepeatMode.all => LuminaRepeatMode.one,
        LuminaRepeatMode.one => LuminaRepeatMode.off,
      };
    });
  }

  void _handlePrevious() {
    unawaited(widget.audioService.previous());
  }

  Future<void> _handleNext() async {
    if (_repeatMode == LuminaRepeatMode.one) {
      await widget.audioService.seek(Duration.zero);
      if (widget.audioService.currentState.status != PlaybackStatus.playing) {
        await widget.audioService.play();
      }
      return;
    }
    final queue = widget.audioService.queue;
    if (_isShuffleEnabled && queue.length > 1) {
      final currentId = widget.audioService.currentState.track?.id;
      final candidates = queue.where((t) => t.id != currentId).toList();
      if (candidates.isNotEmpty) {
        final chosen = candidates[_random.nextInt(candidates.length)];
        unawaited(widget.audioService.skipToTrack(chosen, queueContext: queue));
        return;
      }
    }
    unawaited(widget.audioService.next());
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
    _autoplayChangesSub?.cancel();
    _autoplayChangesSub = null;
    widget.recommendationSettings?.removeListener(
      _onRecommendationSettingsChanged,
    );
    _closeAllOverlays(markState: false);
    _qualityPopoverController.dispose();
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
    _qualityPopoverController.close();
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
          recommendationSettings: widget.recommendationSettings,
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
            key: ValueKey('mini_art_${track?.responsiveArtworkKey ?? 'none'}'),
            track: track,
            size: size,
            fullResolution: false,
            coverTargetSize: 300,
            audioService: widget.audioService,
            libraryCache: widget.libraryCache,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: LuminaTokens.glassCoverRim, width: 1),
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
                  color: LuminaTokens.glassTextPrimary,
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
          hoverColor: LuminaTokens.glassRowHoverBg,
          focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                _buildAlbumArt(track, artSize, iconSize),
                SizedBox(width: gap),
                Expanded(child: _buildTrackTitles(track)),
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
    final isPodcast = PodcastPlaybackTracker.isPodcastTrack(track);
    final artistSubtitle = track == null
        ? ''
        : (isPodcast && track.album.trim().isNotEmpty
            ? (track.artist.trim().isNotEmpty &&
                    track.artist.trim() != track.album.trim()
                ? '${track.album} · ${track.artist}'
                : track.album)
            : (track.hasDistinctAlbumArtist
                ? '${track.artist} (${track.albumArtist})'
                : track.artist));
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
            color: LuminaTokens.glassTextPrimary,
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
                    color: LuminaTokens.glassTextSecondary,
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
              color: LuminaTokens.glassTextSecondary,
              fontSize: 11.5,
            ),
          ),
      ],
    );
  }

  Widget _buildLyricsToggleButton() {
    final onPressed = widget.isNowPlayingExpanded
        ? (widget.onToggleNowPlayingLyrics ?? widget.onToggleLyrics)
        : widget.onToggleLyrics;
    return _LyricsPillButton(
      isActive: widget.showLyrics,
      onTap: onPressed,
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
        final trackDuration = track?.duration ?? const Duration(minutes: 4);

        return LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth;
            final isWide = maxWidth >= 740;
            final isMedium = !isWide && maxWidth >= 480;
            final isExpanded = widget.isNowPlayingExpanded;

            final badge = AudioQualityBadgeWithPopover(
              audioService: widget.audioService,
              track: track,
              scaleController: widget.uiScaleController,
              controller: _qualityPopoverController,
              onBeforeOpen: _closeAllOverlays,
              onOpenSignalPath: () =>
                  SignalPathModal.show(context, widget.audioService),
            );

                final queueBtn = _buildFooterIconTrigger(
                  buttonKey: const Key('btn_quick_queue_popover'),
                  anchorKey: _queueAnchorKey,
                  link: _queueLayerLink,
                  isOpen: isExpanded
                      ? widget.isQueueDrawerOpen
                      : (_queueOverlay != null),
                  icon: Icons.queue_music_rounded,
                  tooltip: '播放佇列',
                  onTap: isExpanded
                      ? (widget.onToggleNowPlayingQueue ??
                            _toggleQueuePopover)
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
                final showAutoplayToggle = autoplayController != null ||
                    widget.recommendationSettings != null;
                final isAutoplayEnabled = autoplayController?.enabled ??
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

                final isPodcast = PodcastPlaybackTracker.isPodcastTrack(track);
                final VoidCallback? onSkipBack15s = isPodcast
                    ? () => PodcastPlaybackTracker.seekRelative(
                        widget.audioService,
                        PodcastPlaybackTracker.skipBackwardDelta,
                      )
                    : null;
                final VoidCallback? onSkipForward30s = isPodcast
                    ? () => PodcastPlaybackTracker.seekRelative(
                        widget.audioService,
                        PodcastPlaybackTracker.skipForwardDelta,
                      )
                    : null;

                final Widget content;
                if (isWide) {
                  // Equal symmetric side widths guarantee the Expanded center column
                  // (and Play/Pause + linear progress bar inside it) sits
                  // dead-center horizontally across the entire bottom bar.
                  final sideWidth =
                      (maxWidth * 0.24).clamp(188.0, 260.0).floorToDouble();
                  final wideSliderWidth =
                      (sideWidth - 140.0).clamp(48.0, 88.0).floorToDouble();
                  final centerMaxWidth = isExpanded
                      ? (maxWidth * 0.50).clamp(280.0, 680.0)
                      : 680.0;
                  content = Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: sideWidth,
                        child: isExpanded
                            ? const SizedBox.shrink()
                            : _buildNowPlayingTrigger(
                                track: track,
                                artSize: 48,
                                iconSize: 24,
                                gap: LuminaTokens.spaceSm,
                              ),
                      ),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: centerMaxWidth,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Center(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: PlaybackControls(
                                      status: state.status,
                                      compact: maxWidth < 900,
                                      isShuffleEnabled: _isShuffleEnabled,
                                      onToggleShuffle: _toggleShuffle,
                                      repeatMode: _repeatMode,
                                      onCycleRepeat: _cycleRepeat,
                                      onPrevious: _handlePrevious,
                                      onPlayPause:
                                          widget.audioService.togglePlayPause,
                                      onNext: () => unawaited(_handleNext()),
                                      onSkipBackward15s: onSkipBack15s,
                                      onSkipForward30s: onSkipForward30s,
                                      trailingBadge: badge,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                TrackProgressBar(
                                  position: state.position,
                                  duration: trackDuration,
                                  expand: true,
                                  onSeek: widget.audioService.seek,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      SizedBox(
                        width: sideWidth,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                lyricsBtn,
                                const SizedBox(width: 4),
                                if (autoplayBtn != null) ...[
                                  autoplayBtn,
                                  const SizedBox(width: 2),
                                ],
                                queueBtn,
                                const SizedBox(width: 2),
                                outputBtn,
                                const SizedBox(width: 4),
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
                            child: isExpanded
                                ? const SizedBox.shrink()
                                : _buildNowPlayingTrigger(
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
                            isShuffleEnabled: _isShuffleEnabled,
                            onToggleShuffle: _toggleShuffle,
                            repeatMode: _repeatMode,
                            onCycleRepeat: _cycleRepeat,
                            onPrevious: _handlePrevious,
                            onPlayPause: widget.audioService.togglePlayPause,
                            onNext: () => unawaited(_handleNext()),
                            onSkipBackward15s: onSkipBack15s,
                            onSkipForward30s: onSkipForward30s,
                          ),
                          const SizedBox(width: LuminaTokens.spaceXs),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: badge,
                              ),
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
                                  lyricsBtn,
                                  const SizedBox(width: 2),
                                  if (autoplayBtn != null) ...[
                                    autoplayBtn,
                                    const SizedBox(width: 2),
                                  ],
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
                      if (autoplayBtn != null) ...[
                        autoplayBtn,
                        const SizedBox(width: 2),
                      ],
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
                            child: isExpanded
                                ? const SizedBox.shrink()
                                : _buildNowPlayingTrigger(
                                    track: track,
                                    artSize: 36,
                                    iconSize: 20,
                                    gap: LuminaTokens.spaceXs,
                                  ),
                          ),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: isExpanded ? innerW : innerW * 0.64,
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
                                    isShuffleEnabled: _isShuffleEnabled,
                                    onToggleShuffle: _toggleShuffle,
                                    repeatMode: _repeatMode,
                                    onCycleRepeat: _cycleRepeat,
                                    onPrevious: _handlePrevious,
                                    onPlayPause:
                                        widget.audioService.togglePlayPause,
                                    onNext: () => unawaited(_handleNext()),
                                  ),
                                  const SizedBox(width: 2),
                                  lyricsBtn,
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
                        onSeek: widget.audioService.seek,
                      ),
                      const SizedBox(height: LuminaTokens.space2xs),
                      Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: badge,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.max(100.0, innerW - 72.0),
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

                final capsuleContainer = Container(
                  key: const Key('liquid_glass_capsule'),
                  width: double.infinity,
                  constraints: isWide
                      ? const BoxConstraints(minHeight: 84.0)
                      : null,
                  padding: EdgeInsets.symmetric(
                    horizontal: isWide ? 20.0 : 14.0,
                    vertical: isWide ? 8.0 : LuminaTokens.spaceXs,
                  ),
                  decoration: BoxDecoration(
                    color: isExpanded
                        ? Colors.transparent
                        : LuminaTokens.glassPlayerBarBg,
                    border: isExpanded
                        ? null
                        : const Border(
                            top: BorderSide(
                              color: LuminaTokens.glassPlayerBarBorder,
                              width: 1,
                            ),
                          ),
                  ),
                  alignment: isWide ? Alignment.center : null,
                  child: content,
                );

                if (isExpanded) {
                  return capsuleContainer;
                }

                return FrostedGlassContainer(
                  blurSigma: LuminaTokens.glassPlayerBarBlur,
                  color: Colors.transparent,
                  enableBackdropBlur: true,
                  child: capsuleContainer,
                );
              },
            );
      },
    );
  }
}

class _LyricsPillButton extends StatefulWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _LyricsPillButton({
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_LyricsPillButton> createState() => _LyricsPillButtonState();
}

class _LyricsPillButtonState extends State<_LyricsPillButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '切換歌詞顯示',
      child: Semantics(
        button: true,
        toggled: widget.isActive,
        label: '切換歌詞顯示',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('btn_toggle_lyrics'),
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
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: widget.isActive
                    ? LuminaTokens.glassNavActiveBg
                    : (_hovered
                          ? LuminaTokens.glassPillHoverBg
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : (widget.isActive
                            ? LuminaTokens.glassPillBorder
                            : Colors.transparent),
                  width: 1.2,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '詞',
                style: TextStyle(
                  color: widget.isActive || _hovered
                      ? LuminaTokens.glassTextPrimary
                      : LuminaTokens.glassTextSecondary,
                  fontSize: 13,
                  fontWeight:
                      widget.isActive ? FontWeight.w700 : FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ),
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
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: widget.isOpen
                    ? LuminaTokens.glassNavActiveBg
                    : (_hovered
                          ? LuminaTokens.glassPillHoverBg
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : (widget.isOpen
                            ? LuminaTokens.glassPillBorder
                            : Colors.transparent),
                  width: 1.2,
                ),
              ),
              child: Icon(
                widget.icon,
                size: 18,
                color: widget.isOpen || _hovered
                    ? LuminaTokens.glassTextPrimary
                    : LuminaTokens.glassTextSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
