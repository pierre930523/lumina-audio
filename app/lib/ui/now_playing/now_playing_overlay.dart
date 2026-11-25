import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/audio_quality_tier.dart';
import '../../models/lyric.dart';
import '../../models/playback_state.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/desktop_window_controller.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/library_index_cache.dart';
import '../../services/now_playing_view_controller.dart';
import '../../services/podcast_store.dart';
import '../../services/recommendation_settings_controller.dart';
import '../../services/streaming/autoplay_controller.dart';
import '../../services/streaming/streaming_playback_coordinator.dart';
import '../artwork/album_artwork_view.dart';
import '../common/ambient_dynamic_background.dart';
import '../common/audio_info_popover.dart';
import '../common/audio_quality_badge.dart';
import '../common/desktop_window_caption.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_hover_prefetch.dart';
import '../common/window_drag_bar.dart';
import '../lyrics/lyrics_view.dart';
import '../mini_player/playback_controls.dart';
import '../mini_player/progress_bar.dart';
import '../signal_path/signal_path_modal.dart';
import '../theme/lumina_tokens.dart';
import 'now_playing_layout.dart';

class NowPlayingOverlay extends StatefulWidget {
  final AudioService audioService;
  final VoidCallback onCollapse;
  final LibraryIndexCache? libraryCache;
  final NowPlayingViewController? controller;
  final DesktopWindowController? windowController;
  final ArtworkPaletteService? paletteService;
  final ui.FragmentProgram? meshFluidProgram;
  final bool isVisible;
  final bool isTransitionSettled;
  final bool? enableAmbientMotion;
  final double bottomClearance;
  final bool hasHostControls;
  final VoidCallback? onOpenDsp;
  final RecommendationSettingsController? recommendationSettings;

  const NowPlayingOverlay({
    super.key,
    required this.audioService,
    required this.onCollapse,
    this.libraryCache,
    this.controller,
    this.windowController,
    this.paletteService,
    this.meshFluidProgram,
    this.isVisible = true,
    this.isTransitionSettled = true,
    this.enableAmbientMotion,
    this.bottomClearance = 0.0,
    this.hasHostControls = false,
    this.onOpenDsp,
    this.recommendationSettings,
  });

  @override
  State<NowPlayingOverlay> createState() => NowPlayingOverlayState();
}

class NowPlayingOverlayState extends State<NowPlayingOverlay>
    with TickerProviderStateMixin {
  late NowPlayingViewController _controller;
  late bool _ownsController;
  late NowPlayingViewMode _lastMode;
  late bool _lastQueueDrawerOpen;
  late ArtworkPaletteService _paletteService;

  late final AnimationController _modeAnimController;
  late final Animation<double> _modeAnim;
  late final AnimationController _queueDrawerAnimController;
  late final Animation<Offset> _queueDrawerSlideAnim;
  late final Animation<double> _queueDrawerOpacityAnim;
  late final ScrollController _queueScrollController;

  late final bool Function() _queueEscapeHandler = _handleQueueEscape;

  AnimationController get modeAnimController => _modeAnimController;
  AnimationController get transitionController => _modeAnimController;

  Widget? _cachedHeroWidget;
  String? _cachedHeroTrackKey;
  double? _cachedHeroCoverSide;
  double? _cachedHeroMaxCoverSide;
  double? _cachedHeroStageInnerH;
  double? _cachedHeroGap;
  double? _cachedHeroCoverRadius;
  double? _cachedHeroTitleFontSize;
  double? _cachedHeroSubtitleFontSize;
  double? _cachedHeroMetaTitleGap;
  double? _cachedHeroMetaPillGap;
  double? _cachedHeroMaxMetaHeight;
  double? _cachedHeroShadowBlur;
  bool? _cachedHeroCompactMetadata;

  String? _artworkCallbackTrackKey;
  void Function(String?, String?)? _artworkResolvedCallback;

  String? _resolvedCoverPath;
  String? _resolvedCoverUrl;
  String? _resolvedArtworkTrackKey;

  final math.Random _random = math.Random();
  bool _isShuffleEnabled = false;
  LuminaRepeatMode _repeatMode = LuminaRepeatMode.off;
  final AudioInfoPopoverController _standaloneQualityPopoverController =
      AudioInfoPopoverController();

  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<TrackInfo>? _trackChangedSub;

  void Function(String?, String?) _artworkResolvedCallbackFor(TrackInfo? track) {
    final key = _trackIdentityKey(track);
    if (_artworkResolvedCallback == null || _artworkCallbackTrackKey != key) {
      _artworkCallbackTrackKey = key;
      _artworkResolvedCallback = (cachePath, coverUrl) =>
          _handleArtworkResolved(track, cachePath, coverUrl);
    }
    return _artworkResolvedCallback!;
  }

  Widget _getPersistentHeroWidget({
    required TrackInfo? track,
    required double baseCoverSide,
    required double maxCoverSide,
    required double stageInnerH,
    required double gap,
    required double coverBorderRadius,
    required double titleFontSize,
    required double subtitleFontSize,
    required double metaTitleGap,
    required double metaPillGap,
    required double maxMetaHeight,
    required double shadowBlur,
    required double shadowSpread,
    required double shadowOffsetY,
    required bool compactMetadata,
  }) {
    final trackKey = _trackIdentityKey(track);
    if (_cachedHeroWidget != null &&
        _cachedHeroTrackKey == trackKey &&
        _cachedHeroCoverSide == baseCoverSide &&
        _cachedHeroMaxCoverSide == maxCoverSide &&
        _cachedHeroStageInnerH == stageInnerH &&
        _cachedHeroGap == gap &&
        _cachedHeroCoverRadius == coverBorderRadius &&
        _cachedHeroTitleFontSize == titleFontSize &&
        _cachedHeroSubtitleFontSize == subtitleFontSize &&
        _cachedHeroMetaTitleGap == metaTitleGap &&
        _cachedHeroMetaPillGap == metaPillGap &&
        _cachedHeroMaxMetaHeight == maxMetaHeight &&
        _cachedHeroShadowBlur == shadowBlur &&
        _cachedHeroCompactMetadata == compactMetadata) {
      return _cachedHeroWidget!;
    }
    _cachedHeroTrackKey = trackKey;
    _cachedHeroCoverSide = baseCoverSide;
    _cachedHeroMaxCoverSide = maxCoverSide;
    _cachedHeroStageInnerH = stageInnerH;
    _cachedHeroGap = gap;
    _cachedHeroCoverRadius = coverBorderRadius;
    _cachedHeroTitleFontSize = titleFontSize;
    _cachedHeroSubtitleFontSize = subtitleFontSize;
    _cachedHeroMetaTitleGap = metaTitleGap;
    _cachedHeroMetaPillGap = metaPillGap;
    _cachedHeroMaxMetaHeight = maxMetaHeight;
    _cachedHeroShadowBlur = shadowBlur;
    _cachedHeroCompactMetadata = compactMetadata;

    _cachedHeroWidget = RepaintBoundary(
      key: const Key('now_playing_cover_repaint_boundary'),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: baseCoverSide, end: baseCoverSide),
        duration: const Duration(milliseconds: 250),
        curve: Curves.ease,
        builder: (context, animatedSide, _) {
          final safeSide = math.max(
            0.0,
            math.min(animatedSide, maxCoverSide),
          );
          final safeRadius = baseCoverSide > 0
              ? (coverBorderRadius * (safeSide / baseCoverSide))
                  .clamp(0.0, 22.0)
                  .toDouble()
              : coverBorderRadius;
          final frameMaxMetaHeight = math.min(
            maxMetaHeight,
            math.max(0.0, stageInnerH - safeSide - gap),
          );
          return SizedBox(
            width: safeSide,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeroCoverCard(
                  track,
                  maxSide: safeSide,
                  borderRadius: safeRadius,
                  shadowBlur: shadowBlur,
                  shadowSpread: shadowSpread,
                  shadowOffsetY: shadowOffsetY,
                ),
                SizedBox(height: gap),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: safeSide,
                    maxHeight: frameMaxMetaHeight,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: safeSide),
                      child: _buildTrackMetadata(
                        track,
                        centered: true,
                        showPills: true,
                        titleFontSize: titleFontSize,
                        subtitleFontSize: subtitleFontSize,
                        metaTitleGap: metaTitleGap,
                        metaPillGap: metaPillGap,
                        compact: compactMetadata,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    return _cachedHeroWidget!;
  }

  static String _trackIdentityKey(TrackInfo? track) {
    if (track == null) return 'none';
    return '${track.responsiveArtworkKey}|'
        '${track.id}|'
        '${track.artworkCacheKey ?? ''}|'
        '${track.coverUrl ?? ''}|'
        '${track.albumArtUrl ?? ''}|'
        '${track.filePath ?? ''}|'
        '${track.album}|'
        '${track.title}|'
        '${track.artist}|'
        '${track.providerName}|'
        '${track.format.label}|'
        '${track.format.bitrateKbps ?? ''}|'
        '${getAudioQualityTier(track).code}';
  }

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? NowPlayingViewController();
    _lastMode = _controller.mode;
    _lastQueueDrawerOpen = _controller.queueDrawerOpen;
    _controller.addListener(_onControllerChanged);

    _paletteService = widget.paletteService ?? ArtworkPaletteService();
    _resolvedArtworkTrackKey = _trackIdentityKey(
      widget.audioService.currentState.track,
    );

    widget.audioService.setNowPlayingVisible(
      widget.isVisible && widget.isTransitionSettled,
    );

    _modeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: _controller.mode == NowPlayingViewMode.cover ? 0.0 : 1.0,
    );
    _modeAnim = CurvedAnimation(
      parent: _modeAnimController,
      curve: Curves.easeInOutCubic,
    );

    _queueDrawerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: _controller.queueDrawerOpen ? 1.0 : 0.0,
    )..addStatusListener(_onQueueDrawerAnimStatus);
    _queueDrawerSlideAnim = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _queueDrawerAnimController,
        curve: Curves.easeOutCubic,
      ),
    );
    _queueDrawerOpacityAnim = CurvedAnimation(
      parent: _queueDrawerAnimController,
      curve: Curves.easeOutCubic,
    );

    _queueScrollController = ScrollController(
      initialScrollOffset: _controller.queueScrollOffset,
    )..addListener(_onQueueScroll);

    _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
    if (widget.audioService is CoordinatingAudioService) {
      _trackChangedSub =
          (widget.audioService as CoordinatingAudioService).trackChangedStream
              .listen(_onTrackChanged);
    }
    _syncQueueEscapeRegistration();
  }

  @override
  void didUpdateWidget(covariant NowPlayingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onControllerChanged);
      _controller.removeListener(_onControllerChanged);
      if (_ownsController) {
        _controller.dispose();
      }
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? NowPlayingViewController();
      _lastMode = _controller.mode;
      _lastQueueDrawerOpen = _controller.queueDrawerOpen;
      _controller.addListener(_onControllerChanged);
      if (_controller.mode == NowPlayingViewMode.cover) {
        _modeAnimController.value = 0.0;
      } else if (_controller.mode == NowPlayingViewMode.split) {
        _modeAnimController.value = 1.0;
      }
      if (_lastQueueDrawerOpen) {
        _queueDrawerAnimController.forward();
      } else {
        _queueDrawerAnimController.reverse();
      }
    }

    if (oldWidget.paletteService != widget.paletteService) {
      _paletteService = widget.paletteService ?? ArtworkPaletteService();
    }

    if (oldWidget.audioService != widget.audioService) {
      _stateSub?.cancel();
      _trackChangedSub?.cancel();
      _trackChangedSub = null;
      _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
      if (widget.audioService is CoordinatingAudioService) {
        _trackChangedSub =
            (widget.audioService as CoordinatingAudioService).trackChangedStream
                .listen(_onTrackChanged);
      }
      _onPlaybackState(widget.audioService.currentState);
    }

    final wasVisiblySettled =
        oldWidget.isVisible && oldWidget.isTransitionSettled;
    final isVisiblySettled = widget.isVisible && widget.isTransitionSettled;
    if (wasVisiblySettled != isVisiblySettled ||
        oldWidget.audioService != widget.audioService) {
      if (oldWidget.audioService != widget.audioService) {
        oldWidget.audioService.setNowPlayingVisible(false);
      }
      widget.audioService.setNowPlayingVisible(isVisiblySettled);
    }

    if (oldWidget.isVisible != widget.isVisible ||
        oldWidget.controller != widget.controller) {
      _syncQueueEscapeRegistration();
    }
    if ((oldWidget.isVisible && !widget.isVisible) ||
        (!oldWidget.hasHostControls && widget.hasHostControls)) {
      _standaloneQualityPopoverController.close();
    }
  }

  @override
  void dispose() {
    _standaloneQualityPopoverController.dispose();
    EscapeDismissRegistry.instance.unregister(_queueEscapeHandler);
    widget.audioService.setNowPlayingVisible(false);
    _stateSub?.cancel();
    _trackChangedSub?.cancel();
    _trackChangedSub = null;
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    _queueDrawerAnimController.removeStatusListener(_onQueueDrawerAnimStatus);
    _queueDrawerAnimController.dispose();
    _queueScrollController.removeListener(_onQueueScroll);
    _queueScrollController.dispose();
    _modeAnimController.dispose();
    super.dispose();
  }

  void _onQueueScroll() {
    if (!_queueScrollController.hasClients) return;
    _controller.saveQueueScrollOffset(_queueScrollController.offset);
  }

  void _onQueueDrawerAnimStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() {});
    }
  }

  bool _handleQueueEscape() {
    if (!_controller.queueDrawerOpen || !widget.isVisible) {
      EscapeDismissRegistry.instance.unregister(_queueEscapeHandler);
      return false;
    }
    _controller.setQueueDrawerOpen(false);
    return true;
  }

  void _syncQueueEscapeRegistration() {
    if (widget.isVisible && _controller.queueDrawerOpen) {
      EscapeDismissRegistry.instance.register(_queueEscapeHandler);
    } else {
      EscapeDismissRegistry.instance.unregister(_queueEscapeHandler);
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    var needsSetState = false;
    if (_controller.mode != _lastMode) {
      _lastMode = _controller.mode;
      if (_controller.mode == NowPlayingViewMode.cover) {
        _modeAnimController.reverse();
      } else if (_controller.mode == NowPlayingViewMode.split) {
        _modeAnimController.forward();
      }
      needsSetState = true;
    }
    if (_controller.queueDrawerOpen != _lastQueueDrawerOpen) {
      _lastQueueDrawerOpen = _controller.queueDrawerOpen;
      if (_lastQueueDrawerOpen) {
        _queueDrawerAnimController.forward();
      } else {
        _queueDrawerAnimController.reverse();
      }
      _syncQueueEscapeRegistration();
      needsSetState = true;
    }
    if (needsSetState) {
      setState(() {});
    }
  }

  void _toggleCoverSplitMode() {
    final isHeadingToSplit =
        _modeAnimController.status == AnimationStatus.forward ||
        (_modeAnimController.value > 0.5 &&
            _modeAnimController.status != AnimationStatus.reverse);
    if (isHeadingToSplit) {
      _modeAnimController.reverse();
      _controller.setMode(NowPlayingViewMode.cover);
    } else {
      _modeAnimController.forward();
      _controller.setMode(NowPlayingViewMode.split);
    }
  }

  void _onTrackChanged(TrackInfo track) {
    if (!mounted) return;
    final cur = widget.audioService.currentState;
    _onPlaybackState(cur.track?.id == track.id ? cur : cur.copyWith(track: track));
  }

  void _onPlaybackState(PlaybackState state) {
    final nextKey = _trackIdentityKey(state.track);
    if (nextKey != _resolvedArtworkTrackKey) {
      _resolvedArtworkTrackKey = nextKey;
      if (_resolvedCoverPath != null || _resolvedCoverUrl != null) {
        if (mounted) {
          setState(() {
            _resolvedCoverPath = null;
            _resolvedCoverUrl = null;
          });
        } else {
          _resolvedCoverPath = null;
          _resolvedCoverUrl = null;
        }
      }
    }
  }

  void _handleArtworkResolved(
    TrackInfo? track,
    String? cachePath,
    String? coverUrl,
  ) {
    if (!mounted) return;
    if (_trackIdentityKey(track) != _resolvedArtworkTrackKey) return;
    final nextPath =
        (cachePath != null && cachePath.isNotEmpty) ? cachePath : null;
    final nextUrl =
        (coverUrl != null && coverUrl.isNotEmpty) ? coverUrl : null;
    if (nextPath == _resolvedCoverPath && nextUrl == _resolvedCoverUrl) {
      return;
    }
    setState(() {
      _resolvedCoverPath = nextPath;
      _resolvedCoverUrl = nextUrl;
    });
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
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: widget.isVisible,
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AmbientDynamicBackground(
              repaintBoundaryKey: const Key('now_playing_bg_repaint_boundary'),
              meshPainterKey: const Key('now_playing_ambient_bg'),
              audioService: widget.audioService,
              libraryCache: widget.libraryCache,
              paletteService: _paletteService,
              meshFluidProgram: widget.meshFluidProgram,
              enabled: widget.isVisible,
              externalArtworkCachePath: _resolvedCoverPath,
              externalArtworkUrl: _resolvedCoverUrl,
            ),
            StreamBuilder<PlaybackState>(
              stream: widget.audioService.stateStream,
              initialData: widget.audioService.currentState,
              builder: (context, snapshot) {
                final state = snapshot.data ?? widget.audioService.currentState;
                final track = state.track;
                final lyrics = List<LyricLine>.from(
                  widget.audioService.currentLyrics,
                );
                final mode = _controller.mode;

                return LayoutBuilder(
                  builder: (context, outerConstraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          bottom: widget.bottomClearance,
                          child: Material(
                            key: const Key('now_playing_overlay'),
                            type: MaterialType.transparency,
                            child: Column(
                              children: [
                                _buildTopBar(mode, track),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final metrics =
                                          NowPlayingLayoutMetrics.compute(
                                        width: constraints.maxWidth,
                                        height: constraints.maxHeight,
                                        mode: mode,
                                        viewportWidth: outerConstraints.maxWidth,
                                        viewportHeight:
                                            outerConstraints.maxHeight,
                                      );
                                      final stageWidget = _buildStage(
                                        key: const Key(
                                          'now_playing_stage_content',
                                        ),
                                        metrics: metrics,
                                        maxWidth: constraints.maxWidth,
                                        maxHeight: constraints.maxHeight,
                                        viewportWidth: outerConstraints.maxWidth,
                                        viewportHeight:
                                            outerConstraints.maxHeight,
                                        state: state,
                                        track: track,
                                        lyrics: lyrics,
                                      );
                                      final stageKey =
                                          mode == NowPlayingViewMode.lyrics
                                              ? 'lyrics'
                                              : 'main';
                                      return AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 350),
                                        switchInCurve: Curves.easeInOutCubic,
                                        switchOutCurve: Curves.easeInOutCubic,
                                        transitionBuilder: (child, animation) {
                                          return FadeTransition(
                                            opacity: animation,
                                            child: child,
                                          );
                                        },
                                        child: KeyedSubtree(
                                          key: ValueKey('stage_$stageKey'),
                                          child: stageWidget,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                if (!widget.hasHostControls)
                                  _buildStandaloneBottomControls(
                                    state: state,
                                    track: track,
                                    maxWidth: outerConstraints.maxWidth,
                                    compact: outerConstraints.maxHeight < 280,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        _buildQueueDrawer(
                          state: state,
                          maxWidth: outerConstraints.maxWidth,
                          maxHeight: outerConstraints.maxHeight,
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(NowPlayingViewMode mode, TrackInfo? track) {
    final isPodcast = PodcastPlaybackTracker.isPodcastTrack(track);
    return WindowDragBar(
      controller: widget.windowController,
      height: 48.0,
      padding: const EdgeInsets.symmetric(horizontal: LuminaTokens.spaceMd),
      child: Row(
        children: [
          FrostedGlassIconButton(
            key: const Key('btn_collapse_now_playing'),
            icon: Icons.keyboard_arrow_down_rounded,
            tooltip: '收合播放畫面',
            size: 36,
            iconSize: 22,
            borderRadius: 10,
            enableBackdropBlur: false,
            iconColor: LuminaTokens.glassTextPrimary,
            onTap: widget.onCollapse,
          ),
          if (isPodcast) ...[
            const SizedBox(width: LuminaTokens.spaceSm),
            FrostedGlassContainer(
              height: 36,
              enableBackdropBlur: false,
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: LuminaTokens.glassPillBorder,
                width: 1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('btn_now_playing_skip_back_15s'),
                    tooltip: '倒退 15 秒 (-15s)',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    icon: const Icon(
                      Icons.replay_10_rounded,
                      size: 18,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                    onPressed: () => PodcastPlaybackTracker.seekRelative(
                      widget.audioService,
                      PodcastPlaybackTracker.skipBackwardDelta,
                    ),
                  ),
                  IconButton(
                    key: const Key('btn_now_playing_skip_forward_30s'),
                    tooltip: '快轉 30 秒 (+30s)',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    icon: const Icon(
                      Icons.forward_30_rounded,
                      size: 18,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                    onPressed: () => PodcastPlaybackTracker.seekRelative(
                      widget.audioService,
                      PodcastPlaybackTracker.skipForwardDelta,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_queue'),
                      icon: Icons.queue_music_rounded,
                      tooltip: '待播佇列',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: _controller.queueDrawerOpen,
                      enableBackdropBlur: false,
                      onTap: _controller.toggleQueueDrawer,
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_mode_split'),
                      icon: Icons.vertical_split_rounded,
                      tooltip: '封面與逐字歌詞',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: mode == NowPlayingViewMode.split,
                      enableBackdropBlur: false,
                      onTap: () {
                        _controller.setQueueDrawerOpen(false);
                        _modeAnimController.forward();
                        _controller.setMode(NowPlayingViewMode.split);
                      },
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_mode_lyrics'),
                      icon: Icons.lyrics_rounded,
                      tooltip: '純逐字歌詞',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: mode == NowPlayingViewMode.lyrics,
                      enableBackdropBlur: false,
                      onTap: () {
                        _controller.setQueueDrawerOpen(false);
                        _controller.setMode(NowPlayingViewMode.lyrics);
                      },
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_mode_cover'),
                      icon: Icons.album_outlined,
                      tooltip: '純封面檢視',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: mode == NowPlayingViewMode.cover,
                      enableBackdropBlur: false,
                      onTap: () {
                        _controller.setQueueDrawerOpen(false);
                        _modeAnimController.reverse();
                        _controller.setMode(NowPlayingViewMode.cover);
                      },
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_output_dsp'),
                      icon: Icons.graphic_eq_rounded,
                      tooltip: '音訊輸出與 DSP 狀態',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      enableBackdropBlur: false,
                      onTap: () =>
                          SignalPathModal.show(context, widget.audioService),
                    ),
                    const SizedBox(width: LuminaTokens.spaceSm),
                    DesktopWindowCaptionButtons(
                      controller: widget.windowController,
                      color: Colors.white70,
                      height: 48.0,
                      audioService: widget.audioService,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required double maxHeight,
    required double viewportWidth,
    required double viewportHeight,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    if (metrics.arrangement == NowPlayingStageArrangement.lyricsFull) {
      return _buildLyricsFullStage(
        key: key,
        metrics: metrics,
        state: state,
        track: track,
        lyrics: lyrics,
      );
    }

    if (metrics.arrangement == NowPlayingStageArrangement.lyricsCompactHeader ||
        metrics.arrangement == NowPlayingStageArrangement.splitCompactHeader) {
      return _buildCompactHeaderStage(
        key: key,
        metrics: metrics,
        state: state,
        track: track,
        lyrics: lyrics,
      );
    }

    if (metrics.arrangement == NowPlayingStageArrangement.splitNarrowStacked) {
      return _buildNarrowStackedStage(
        key: key,
        metrics: metrics,
        maxWidth: maxWidth,
        state: state,
        track: track,
        lyrics: lyrics,
      );
    }

    if (metrics.arrangement == NowPlayingStageArrangement.coverLandscapeRow) {
      return _buildLandscapeRowStage(
        key: key,
        metrics: metrics,
        maxWidth: maxWidth,
        track: track,
      );
    }

    return _buildDesktopTransitionStage(
      key: key,
      metrics: metrics,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      state: state,
      track: track,
      lyrics: lyrics,
    );
  }

  Widget _buildDesktopTransitionStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required double maxHeight,
    required double viewportWidth,
    required double viewportHeight,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    final rawCoverMetrics = NowPlayingLayoutMetrics.compute(
      width: maxWidth,
      height: maxHeight,
      mode: NowPlayingViewMode.cover,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    final coverMetrics =
        rawCoverMetrics.arrangement ==
            NowPlayingStageArrangement.coverLandscapeRow
        ? metrics
        : rawCoverMetrics;
    final baseCoverSide = coverMetrics.coverSide;
    final maxCoverSide = coverMetrics.maxCoverSide;
    final stageInnerH = math.max(
      0.0,
      maxHeight - coverMetrics.padTop - coverMetrics.padBottom,
    );
    final gap = coverMetrics.gap;
    final coverBorderRadius = coverMetrics.coverBorderRadius;
    final titleFontSize = coverMetrics.titleFontSize;
    final subtitleFontSize = coverMetrics.subtitleFontSize;
    final metaTitleGap = coverMetrics.metaTitleGap;
    final metaPillGap = coverMetrics.metaPillGap;
    final maxMetaHeight = coverMetrics.maxMetaHeight;
    final shadowBlur = coverMetrics.shadowBlur;
    final shadowSpread = coverMetrics.shadowSpread;
    final shadowOffsetY = coverMetrics.shadowOffsetY;
    final compactMetadata = coverMetrics.compactMetadata;

    final persistentHero = _getPersistentHeroWidget(
      track: track,
      baseCoverSide: baseCoverSide,
      maxCoverSide: maxCoverSide,
      stageInnerH: stageInnerH,
      gap: gap,
      coverBorderRadius: coverBorderRadius,
      titleFontSize: titleFontSize,
      subtitleFontSize: subtitleFontSize,
      metaTitleGap: metaTitleGap,
      metaPillGap: metaPillGap,
      maxMetaHeight: maxMetaHeight,
      shadowBlur: shadowBlur,
      shadowSpread: shadowSpread,
      shadowOffsetY: shadowOffsetY,
      compactMetadata: compactMetadata,
    );

    final leftPad = math.max(
      16.0,
      math.min(metrics.stagePadH, maxWidth * 0.06),
    );
    const interColumnGap = 24.0;
    final lyricsLeft = maxWidth * 0.48;
    final maxLeftVisualWidth = math.max(
      120.0,
      lyricsLeft - leftPad - interColumnGap,
    );
    final splitScale = baseCoverSide > 0
        ? math.min(0.88, maxLeftVisualWidth / baseCoverSide).clamp(0.35, 0.88)
        : 0.88;
    final scaledCoverHalfWidth = baseCoverSide * splitScale * 0.5;
    final minLeftCenter = scaledCoverHalfWidth + leftPad;
    final maxLeftCenter = lyricsLeft - interColumnGap - scaledCoverHalfWidth;
    final targetLeftCenterX = maxLeftCenter >= minLeftCenter
        ? (maxWidth * 0.26).clamp(minLeftCenter, maxLeftCenter).toDouble()
        : minLeftCenter;
    final dx = targetLeftCenterX - (maxWidth / 2.0);
    final centerOffset = Offset.zero;
    final leftOffset = Offset(dx, 0.0);

    return Stack(
      key: key,
      fit: StackFit.expand,
      children: [
        Positioned(
          left: lyricsLeft,
          right: math.max(16.0, metrics.stagePadH),
          top: metrics.padTop,
          bottom: metrics.padBottom,
          child: RepaintBoundary(
            key: const Key('now_playing_lyrics_repaint_boundary'),
            child: AnimatedBuilder(
              animation: _modeAnimController,
              child: LyricsView(
                lyrics: lyrics,
                currentPosition: state.position,
                onSeek: widget.audioService.seek,
                centered: true,
                isPlaying: state.status == PlaybackStatus.playing && widget.isVisible,
                trackId: track?.id,
                audioService: widget.audioService,
                viewController: _controller,
                isTransitionSettled: widget.isTransitionSettled,
              ),
              builder: (context, lyricsChild) {
                final t = _modeAnimController.value;
                final lyricsT = const Interval(
                  0.28,
                  1.0,
                  curve: Curves.easeOutCubic,
                ).transform(t);
                final slideX = (1.0 - lyricsT) * 24.0;

                return IgnorePointer(
                  key: const Key('now_playing_lyrics_ignore_pointer'),
                  ignoring: t < 0.05,
                  child: Visibility(
                    key: const Key('now_playing_lyrics_visibility'),
                    visible: t > 0.01,
                    maintainState: true,
                    child: Opacity(
                      opacity: lyricsT.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(slideX, 0.0),
                        child: lyricsChild,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Center(
          child: AnimatedBuilder(
            animation: _modeAnimController,
            child: persistentHero,
            builder: (context, child) {
              final t = _modeAnimController.value;
              final slideT = Curves.easeInOutCubic.transform(t);
              final currentOffset =
                  Offset.lerp(centerOffset, leftOffset, slideT)!;
              final currentScale = ui.lerpDouble(1.0, splitScale, slideT)!;

              return Transform.translate(
                offset: currentOffset,
                child: Transform.scale(
                  scale: currentScale,
                  alignment: Alignment.center,
                  child: child,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeRowStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required TrackInfo? track,
  }) {
    final maxRowWidth = math.min(960.0, math.max(120.0, maxWidth));
    final innerRowWidth = math.max(
      0.0,
      maxRowWidth - metrics.stagePadH * 2,
    );
    final maxMetaWidth = math.max(
      100.0,
      innerRowWidth - metrics.coverSide - metrics.gap,
    );
    return Padding(
      key: key,
      padding: EdgeInsets.fromLTRB(
        metrics.stagePadH,
        metrics.padTop,
        metrics.stagePadH,
        metrics.padBottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxRowWidth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildHeroCoverCard(
                track,
                maxSide: metrics.coverSide,
                borderRadius: metrics.coverBorderRadius,
                shadowBlur: metrics.shadowBlur,
                shadowSpread: metrics.shadowSpread,
                shadowOffsetY: metrics.shadowOffsetY,
              ),
              SizedBox(width: metrics.gap),
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: metrics.maxMetaHeight,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxMetaWidth),
                      child: _buildTrackMetadata(
                        track,
                        centered: false,
                        showPills: true,
                        titleFontSize: metrics.titleFontSize,
                        subtitleFontSize: metrics.subtitleFontSize,
                        metaTitleGap: metrics.metaTitleGap,
                        metaPillGap: metrics.metaPillGap,
                        compact: metrics.compactMetadata,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLyricsFullStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    return Padding(
      key: key,
      padding: EdgeInsets.fromLTRB(
        metrics.stagePadH,
        metrics.padTop,
        metrics.stagePadH,
        metrics.padBottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: LyricsView(
            lyrics: lyrics,
            currentPosition: state.position,
            onSeek: widget.audioService.seek,
            centered: true,
            isPlaying: state.status == PlaybackStatus.playing && widget.isVisible,
            trackId: track?.id,
            audioService: widget.audioService,
            viewController: _controller,
            isTransitionSettled: widget.isTransitionSettled,
          ),
        ),
      ),
    );
  }

  Widget _buildCompactHeaderStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    return Column(
      key: key,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.stagePadH,
            metrics.padTop,
            metrics.stagePadH,
            metrics.padBottom,
          ),
          child: Row(
            children: [
              _buildHeroCoverCard(
                track,
                maxSide: metrics.coverSide,
                borderRadius: metrics.coverBorderRadius,
                compact: true,
              ),
              SizedBox(width: metrics.gap),
              Expanded(
                child: _buildTrackMetadata(
                  track,
                  centered: false,
                  showPills: false,
                  titleFontSize: metrics.titleFontSize,
                  subtitleFontSize: metrics.subtitleFontSize,
                  metaTitleGap: metrics.metaTitleGap,
                  metaPillGap: metrics.metaPillGap,
                  compact: metrics.compactMetadata,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: FadeTransition(
                opacity: _modeAnim,
                child: LyricsView(
                  lyrics: lyrics,
                  currentPosition: state.position,
                  onSeek: widget.audioService.seek,
                  centered: true,
                  isPlaying: state.status == PlaybackStatus.playing && widget.isVisible,
                  trackId: track?.id,
                  audioService: widget.audioService,
                  viewController: _controller,
                  isTransitionSettled: widget.isTransitionSettled,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowStackedStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    final innerW = math.max(120.0, maxWidth - metrics.stagePadH * 2);
    final useHorizontalHero = maxWidth >= 440;
    return Column(
      key: key,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.stagePadH,
            metrics.padTop,
            metrics.stagePadH,
            metrics.padBottom,
          ),
          child: useHorizontalHero
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildHeroCoverCard(
                      track,
                      maxSide: metrics.coverSide,
                      borderRadius: metrics.coverBorderRadius,
                      shadowBlur: metrics.shadowBlur,
                      shadowSpread: metrics.shadowSpread,
                      shadowOffsetY: metrics.shadowOffsetY,
                    ),
                    SizedBox(width: metrics.gap),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, metaConstraints) {
                          final metaW = math.max(
                            80.0,
                            metaConstraints.maxWidth,
                          );
                          return ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: metrics.maxMetaHeight,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: metaW),
                                child: _buildTrackMetadata(
                                  track,
                                  centered: false,
                                  showPills: true,
                                  titleFontSize: metrics.titleFontSize,
                                  subtitleFontSize: metrics.subtitleFontSize,
                                  metaTitleGap: metrics.metaTitleGap,
                                  metaPillGap: metrics.metaPillGap,
                                  compact: metrics.compactMetadata,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeroCoverCard(
                      track,
                      maxSide: metrics.coverSide,
                      borderRadius: metrics.coverBorderRadius,
                      shadowBlur: metrics.shadowBlur,
                      shadowSpread: metrics.shadowSpread,
                      shadowOffsetY: metrics.shadowOffsetY,
                    ),
                    const SizedBox(height: LuminaTokens.spaceXs),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: innerW,
                        maxHeight: metrics.maxMetaHeight,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: innerW),
                          child: _buildTrackMetadata(
                            track,
                            centered: true,
                            showPills: true,
                            titleFontSize: metrics.titleFontSize,
                            subtitleFontSize: metrics.subtitleFontSize,
                            metaTitleGap: metrics.metaTitleGap,
                            metaPillGap: metrics.metaPillGap,
                            compact: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: FadeTransition(
                opacity: _modeAnim,
                child: LyricsView(
                  lyrics: lyrics,
                  currentPosition: state.position,
                  onSeek: widget.audioService.seek,
                  centered: true,
                  isPlaying: state.status == PlaybackStatus.playing && widget.isVisible,
                  trackId: track?.id,
                  audioService: widget.audioService,
                  viewController: _controller,
                  isTransitionSettled: widget.isTransitionSettled,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeroCoverCard(
    TrackInfo? track, {
    required double maxSide,
    double? borderRadius,
    bool compact = false,
    double shadowBlur = 48,
    double shadowSpread = 0,
    double shadowOffsetY = 20,
  }) {
    final resolvedRadius = borderRadius ?? (compact ? 8.0 : 16.0);
    Widget card = ConstrainedBox(
      key: const ValueKey('now_playing_hero_cover_card'),
      constraints: BoxConstraints(maxWidth: maxSide, maxHeight: maxSide),
      child: AspectRatio(
        aspectRatio: 1,
        child: AlbumArtworkView(
          key: ValueKey('hero_art_${track?.responsiveArtworkKey ?? 'none'}'),
          track: track,
          size: maxSide,
          fit: BoxFit.cover,
          fullResolution: !compact,
          coverTargetSize: compact ? 300 : 1200,
          audioService: widget.audioService,
          libraryCache: widget.libraryCache,
          onArtworkResolved: _artworkResolvedCallbackFor(track),
          borderRadius: BorderRadius.circular(resolvedRadius),
          border: Border.all(
            color: LuminaTokens.glassCoverRim,
            width: 1,
          ),
          boxShadow: compact
              ? null
              : [
                  BoxShadow(
                    color: const Color(0x73000000),
                    blurRadius: shadowBlur,
                    spreadRadius: shadowSpread,
                    offset: Offset(0, shadowOffsetY),
                  ),
                ],
        ),
      ),
    );

    if (!compact) {
      card = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _toggleCoverSplitMode,
          child: card,
        ),
      );
    }
    return card;
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

  Widget _buildTrackMetadata(
    TrackInfo? track, {
    required bool centered,
    bool showPills = false,
    double? titleFontSize,
    double? subtitleFontSize,
    double? metaTitleGap,
    double? metaPillGap,
    bool compact = false,
  }) {
    final crossAxis =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final align = centered ? TextAlign.center : TextAlign.start;
    final effectiveSubtitleSize = subtitleFontSize ?? (compact ? 12.5 : 14.0);
    final effectiveTitleGap =
        metaTitleGap ?? (compact ? 2.0 : LuminaTokens.space2xs);
    final effectivePillGap =
        metaPillGap ?? (compact ? 6.0 : LuminaTokens.spaceSm);
    final badgeBoxSize =
        compact ? 15.0 : (effectiveSubtitleSize + 2.0).clamp(16.0, 20.0);

    final artistLabel = track == null
        ? ''
        : (track.hasDistinctAlbumArtist
              ? '${track.artist} (${track.albumArtist})'
              : track.artist);
    final sourceLabel = track == null
        ? ''
        : (track.providerName.trim().isNotEmpty
              ? track.providerName.trim()
              : track.album.trim());
    final metaSubtitle = track == null
        ? ''
        : (sourceLabel.isNotEmpty
              ? '• $artistLabel · $sourceLabel'
              : '• $artistLabel');
    final streamingMeta = _resolveStreamingMeta(track);

    return Column(
      key: const ValueKey('now_playing_hero_metadata'),
      crossAxisAlignment: crossAxis,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track?.title ?? '尚未選擇曲目',
          textAlign: align,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: LuminaTokens.glassTextPrimary,
            fontSize: titleFontSize ?? (centered ? 25.0 : 16.0),
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: effectiveTitleGap),
        if (streamingMeta != null)
          Row(
            mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
            mainAxisAlignment:
                centered ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Tooltip(
                message: streamingMeta.name,
                child: KeyedSubtree(
                  key: Key('now_playing_provider_badge_${streamingMeta.kind}'),
                  child: streamingMeta.buildBadge(
                    boxSize: badgeBoxSize,
                    borderRadius: 4,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  metaSubtitle,
                  textAlign: align,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: effectiveSubtitleSize,
                  ),
                ),
              ),
            ],
          )
        else
          Text(
            metaSubtitle,
            textAlign: align,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: effectiveSubtitleSize,
            ),
          ),
        if (showPills && track != null) ...[
          SizedBox(height: effectivePillGap),
          _buildFormatSpecCapsule(track),
        ],
      ],
    );
  }

  Widget _buildFormatSpecCapsule(TrackInfo track) {
    final tier = getAudioQualityTier(track);
    final style = AudioQualityBadgeStyle.forTier(tier);
    return AnimatedContainer(
      key: const Key('now_playing_format_spec_capsule'),
      duration: LuminaTokens.qualityBadgeTransitionDuration,
      curve: Curves.ease,
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: style.backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: style.borderColor,
          width: 1,
        ),
        boxShadow: style.boxShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            key: const Key('now_playing_format_spec_dot'),
            duration: LuminaTokens.qualityBadgeTransitionDuration,
            curve: Curves.ease,
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
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              track.format.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: style.textColor,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStandaloneBottomControls({
    required PlaybackState state,
    required TrackInfo? track,
    required double maxWidth,
    required bool compact,
  }) {
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
    final trackDuration = track?.duration ?? const Duration(minutes: 4);
    final barWidth = math.min(
      math.max(160.0, maxWidth - 32.0),
      (maxWidth * 0.50).clamp(280.0, 680.0),
    );
    final badge = AudioQualityBadgeWithPopover(
      audioService: widget.audioService,
      track: track,
      controller: _standaloneQualityPopoverController,
      onOpenSignalPath: () =>
          SignalPathModal.show(context, widget.audioService),
    );

    return Padding(
      key: const Key('now_playing_standalone_controls'),
      padding: EdgeInsets.fromLTRB(
        16,
        compact ? 2 : 6,
        16,
        compact ? 6 : 14,
      ),
      child: Center(
        child: SizedBox(
          width: barWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: PlaybackControls(
                    status: state.status,
                    compact: compact || maxWidth < 680,
                    isShuffleEnabled: _isShuffleEnabled,
                    onToggleShuffle: _toggleShuffle,
                    repeatMode: _repeatMode,
                    onCycleRepeat: _cycleRepeat,
                    onPrevious: _handlePrevious,
                    onPlayPause: widget.audioService.togglePlayPause,
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
    );
  }

  Widget _buildQueueDrawer({
    required PlaybackState state,
    required double maxWidth,
    required double maxHeight,
  }) {
    if (!_controller.queueDrawerOpen &&
        _queueDrawerAnimController.isDismissed) {
      return const SizedBox.shrink();
    }

    final ap = widget.audioService is CoordinatingAudioService
        ? (widget.audioService as CoordinatingAudioService).autoplayController
        : null;
    final drawerWidth = math.max(180.0, math.min(340.0, maxWidth - 32.0));
    final desiredBottom = widget.hasHostControls
        ? widget.bottomClearance + 12.0
        : math.min(96.0, math.max(12.0, maxHeight * 0.25));
    final maxAllowedBottom = math.max(0.0, maxHeight - 56.0 - 120.0);
    final resolvedBottom = math.min(desiredBottom, maxAllowedBottom);

    Widget buildDrawerFrame({required Widget child}) {
      return Positioned(
        top: 56.0,
        right: 16.0,
        bottom: resolvedBottom,
        width: drawerWidth,
        child: IgnorePointer(
          ignoring: !_controller.queueDrawerOpen,
          child: SlideTransition(
            position: _queueDrawerSlideAnim,
            child: FadeTransition(
              opacity: _queueDrawerOpacityAnim,
              child: Material(
                type: MaterialType.transparency,
                child: FrostedGlassContainer(
                  key: const Key('now_playing_queue_drawer'),
                  color: LuminaTokens.glassDrawerBg,
                  enableBackdropBlur: false,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: LuminaTokens.glassPillBorder,
                    width: 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x88000000),
                      blurRadius: 32,
                      offset: Offset(0, 12),
                    ),
                  ],
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    }

    bool isCurrentQueueTrack(TrackInfo? active, TrackInfo item) {
      if (active == null) return false;
      if (item.id == active.id) return true;
      if (item.id.trim().isNotEmpty && active.id.trim().isNotEmpty) {
        return item.responsiveArtworkKey == active.responsiveArtworkKey;
      }
      return false;
    }

    if (ap == null) {
      Widget buildLegacyDrawer(List<TrackInfo> tracks) {
        return buildDrawerFrame(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '待播佇列（${tracks.length} 首）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _buildCloseQueueDrawerButton(),
                  ],
                ),
              ),
              const Divider(
                color: LuminaTokens.glassSidebarBorder,
                height: 1,
              ),
              Expanded(
                child: tracks.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            '目前待播佇列為空',
                            style: TextStyle(
                              color: LuminaTokens.glassTextTertiary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const PageStorageKey<String>(
                          'now_playing_queue_drawer_list',
                        ),
                        controller: _queueScrollController,
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 8,
                        ),
                        itemCount: tracks.length,
                        itemBuilder: (context, index) {
                          final item = tracks[index];
                          final isCurrent =
                              isCurrentQueueTrack(state.track, item);
                          return _buildQueueDrawerRow(
                            item: item,
                            isCurrent: isCurrent,
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      }

      if (widget.audioService is CoordinatingAudioService) {
        final coord = widget.audioService as CoordinatingAudioService;
        return StreamBuilder<List<TrackInfo>>(
          stream: coord.queueUpdatedStream,
          initialData: widget.audioService.queue,
          builder: (context, qSnap) =>
              buildLegacyDrawer(qSnap.data ?? widget.audioService.queue),
        );
      }
      return buildLegacyDrawer(widget.audioService.queue);
    }

    Widget buildStreamDualBody() => StreamBuilder<void>(
      stream: ap.changes,
      builder: (context, _) {
        final combined = ap.combinedQueue;
        final autoTracks = ap.autoQueue;
        final useLegacyFallback =
            combined.isEmpty && widget.audioService.queue.isNotEmpty;
        final userTracks = useLegacyFallback
            ? widget.audioService.queue
            : combined.sublist(0, combined.length - autoTracks.length);
        final totalCount = userTracks.length + autoTracks.length;
        final showAutoSection = ap.enabled || autoTracks.isNotEmpty;

        void ensureSeededBeforeReorder() {
          if (useLegacyFallback) {
            ap.setUserQueue(
              userTracks,
              currentTrack: state.track,
              bumpEpoch: false,
            );
          }
        }

        final entries = <_DrawerQueueEntry>[
          const _DrawerQueueEntry(kind: _DrawerQueueEntryKind.userHeader),
          if (userTracks.isEmpty)
            const _DrawerQueueEntry(
              kind: _DrawerQueueEntryKind.userEmptyPlaceholder,
            )
          else
            for (var i = 0; i < userTracks.length; i++)
              _DrawerQueueEntry(
                kind: _DrawerQueueEntryKind.userTrack,
                track: userTracks[i],
                combinedIndex: i,
                isLockedPlayingAuto: !useLegacyFallback &&
                    ap.isCurrentFromAutoQueue &&
                    ap.currentTrack?.id == userTracks[i].id,
              ),
          if (showAutoSection) ...[
            const _DrawerQueueEntry(kind: _DrawerQueueEntryKind.autoHeader),
            if (autoTracks.isEmpty)
              const _DrawerQueueEntry(kind: _DrawerQueueEntryKind.autoEmptyHint)
            else
              for (var j = 0; j < autoTracks.length; j++)
                _DrawerQueueEntry(
                  kind: _DrawerQueueEntryKind.autoTrack,
                  track: autoTracks[j],
                  combinedIndex: userTracks.length + j,
                ),
          ],
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '待播佇列（$totalCount 首）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '無限自動接播（開啟／關閉）',
                    child: Semantics(
                      button: true,
                      toggled: ap.enabled,
                      label: '無限自動接播（開啟／關閉）',
                      child: InkWell(
                        key: const Key('btn_drawer_autoplay_toggle'),
                        borderRadius: BorderRadius.circular(8),
                        mouseCursor: SystemMouseCursors.click,
                        hoverColor: LuminaTokens.glassPillHoverBg,
                        focusColor: LuminaTokens.focusRing.withValues(
                          alpha: 0.25,
                        ),
                        onTap: () {
                          final next = !ap.enabled;
                          ap.setEnabled(next);
                          final rec = widget.recommendationSettings;
                          if (rec != null && rec.autoplayEnabled != next) {
                            unawaited(rec.setAutoplayEnabled(next));
                          }
                        },
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: ap.enabled
                                ? LuminaTokens.glassNavActiveBg
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: ap.enabled
                                  ? LuminaTokens.glassPillBorder
                                  : Colors.transparent,
                            ),
                          ),
                          child: Icon(
                            Icons.all_inclusive_rounded,
                            size: 16,
                            color: ap.enabled
                                ? LuminaTokens.glassTextPrimary
                                : LuminaTokens.glassTextTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _buildCloseQueueDrawerButton(),
                ],
              ),
            ),
            const Divider(
              color: LuminaTokens.glassSidebarBorder,
              height: 1,
            ),
            Expanded(
              child: totalCount == 0 && !showAutoSection
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '目前待播佇列為空',
                          style: TextStyle(
                            color: LuminaTokens.glassTextTertiary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const PageStorageKey<String>(
                        'now_playing_queue_drawer_list',
                      ),
                      controller: _queueScrollController,
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 8,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return switch (entry.kind) {
                          _DrawerQueueEntryKind.userHeader =>
                            _buildDrawerUserHeader(
                              ap: ap,
                              userCount: userTracks.length,
                              ensureSeededBeforeReorder:
                                  ensureSeededBeforeReorder,
                            ),
                          _DrawerQueueEntryKind.userEmptyPlaceholder =>
                            _buildDrawerEmptyUserDropZone(ap: ap),
                          _DrawerQueueEntryKind.userTrack =>
                            _buildDualQueueDrawerRow(
                              drawerWidth: drawerWidth,
                              item: entry.track!,
                              combinedIndex: entry.combinedIndex,
                              isCurrent: isCurrentQueueTrack(
                                state.track,
                                entry.track!,
                              ),
                              isAuto: false,
                              isLockedPlayingAuto: entry.isLockedPlayingAuto,
                              ap: ap,
                              ensureSeededBeforeReorder:
                                  ensureSeededBeforeReorder,
                            ),
                          _DrawerQueueEntryKind.autoHeader =>
                            _buildDrawerAutoHeader(ap: ap),
                          _DrawerQueueEntryKind.autoEmptyHint => Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                            child: Text(
                              ap.isRefilling
                                  ? '正在探索相似推薦曲目...'
                                  : '待播佇列即將播畢時將自動接續推薦',
                              style: const TextStyle(
                                color: LuminaTokens.glassTextTertiary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          _DrawerQueueEntryKind.autoTrack =>
                            _buildDualQueueDrawerRow(
                              drawerWidth: drawerWidth,
                              item: entry.track!,
                              combinedIndex: entry.combinedIndex,
                              isCurrent: isCurrentQueueTrack(
                                state.track,
                                entry.track!,
                              ),
                              isAuto: true,
                              isLockedPlayingAuto: false,
                              ap: ap,
                              ensureSeededBeforeReorder:
                                  ensureSeededBeforeReorder,
                            ),
                        };
                      },
                    ),
            ),
          ],
        );
      },
    );

    final Widget drawerChild = widget.recommendationSettings != null
        ? ListenableBuilder(
            listenable: widget.recommendationSettings!,
            builder: (context, _) => buildStreamDualBody(),
          )
        : buildStreamDualBody();

    return buildDrawerFrame(child: drawerChild);
  }

  Widget _buildCloseQueueDrawerButton() {
    return IconButton(
      key: const Key('btn_close_now_playing_queue'),
      tooltip: '關閉待播佇列',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: 32,
        minHeight: 32,
      ),
      style: IconButton.styleFrom(
        foregroundColor: LuminaTokens.glassTextSecondary,
        hoverColor: LuminaTokens.glassPillHoverBg,
        focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      icon: const Icon(Icons.close_rounded, size: 18),
      onPressed: () => _controller.setQueueDrawerOpen(false),
    );
  }

  Widget _buildDrawerUserHeader({
    required AutoplayController ap,
    required int userCount,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    return DragTarget<_DrawerQueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.promoteAutoTrackToUserQueue(
          details.data.track.id,
          targetUserIndex: 0,
        );
      },
      builder: (context, candidateData, _) {
        final hovered = candidateData.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            color: hovered
                ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.45)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '待播佇列',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$userCount 首',
                style: const TextStyle(
                  color: LuminaTokens.glassTextTertiary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDrawerEmptyUserDropZone({required AutoplayController ap}) {
    return DragTarget<_DrawerQueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ap.promoteAutoTrackToUserQueue(details.data.track.id);
      },
      builder: (context, candidateData, _) {
        final hovered = candidateData.isNotEmpty;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: hovered
                ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.5)
                : LuminaTokens.glassCardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hovered
                  ? LuminaTokens.focusRing
                  : LuminaTokens.glassCardBorder,
            ),
          ),
          child: const Text(
            '目前無手動待播曲目，可拖曳推薦曲目至此',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: LuminaTokens.glassTextTertiary,
              fontSize: 11.5,
            ),
          ),
        );
      },
    );
  }

  Widget _buildDrawerAutoHeader({required AutoplayController ap}) {
    final hasAutoTracks = ap.autoQueue.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 6, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '接下來自動推薦（Autoplay）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (ap.isRefilling) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: LuminaTokens.glassTextSecondary,
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (hasAutoTracks)
            Tooltip(
              message: '清空自動推薦佇列',
              child: InkWell(
                key: const Key('btn_drawer_clear_auto_queue'),
                borderRadius: BorderRadius.circular(6),
                mouseCursor: SystemMouseCursors.click,
                hoverColor: LuminaTokens.glassRowHoverBg,
                onTap: ap.clearAutoQueue,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.clear_all_rounded,
                        size: 14,
                        color: LuminaTokens.glassTextSecondary,
                      ),
                      SizedBox(width: 3),
                      Text(
                        '清空',
                        style: TextStyle(
                          color: LuminaTokens.glassTextSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDualQueueDrawerRow({
    required double drawerWidth,
    required TrackInfo item,
    required int combinedIndex,
    required bool isCurrent,
    required bool isAuto,
    required bool isLockedPlayingAuto,
    required AutoplayController ap,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    Widget buildDragProxyContent() {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: isCurrent
              ? LuminaTokens.glassNavActiveBg
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            AlbumArtworkView(
              track: item,
              size: 36,
              fullResolution: false,
              coverTargetSize: 300,
              audioService: widget.audioService,
              libraryCache: widget.libraryCache,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: LuminaTokens.glassPillBorder,
                width: 1,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent
                          ? LuminaTokens.glassTextPrimary
                          : LuminaTokens.glassTextSecondary,
                      fontSize: 13,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    item.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextTertiary,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final payload = _DrawerQueueDragPayload(
      track: item,
      combinedIndex: combinedIndex,
      isAuto: isAuto,
    );

    Widget buildFeedback() => Material(
      color: Colors.transparent,
      child: SizedBox(
        width: math.max(150.0, drawerWidth - 20.0),
        child: FrostedGlassContainer(
          blurSigma: 0,
          enableBackdropBlur: false,
          color: LuminaTokens.glassDrawerBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: LuminaTokens.glassPillBorder),
          child: buildDragProxyContent(),
        ),
      ),
    );

    Widget buildDraggableRow() {
      final Widget grip = isLockedPlayingAuto
          ? const Icon(
              Icons.all_inclusive_rounded,
              size: 14,
              color: LuminaTokens.glassTextTertiary,
            )
          : MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Draggable<_DrawerQueueDragPayload>(
                key: Key('drawer_queue_drag_handle_${item.id}'),
                data: payload,
                feedback: buildFeedback(),
                childWhenDragging: const Opacity(
                  opacity: 0.35,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 15,
                    color: LuminaTokens.glassTextTertiary,
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 15,
                    color: LuminaTokens.glassTextTertiary,
                  ),
                ),
              ),
            );

      final Widget rowInner = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        decoration: BoxDecoration(
          color: isCurrent
              ? LuminaTokens.glassNavActiveBg
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            grip,
            const SizedBox(width: 4),
            Expanded(
              child: InkWell(
                key: Key('now_playing_queue_item_${item.id}'),
                onTap: () => widget.audioService.play(track: item),
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(8),
                hoverColor: LuminaTokens.glassRowHoverBg,
                focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
                child: Row(
                  children: [
                    AlbumArtworkView(
                      track: item,
                      size: 36,
                      fullResolution: false,
                      coverTargetSize: 300,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: LuminaTokens.glassPillBorder,
                        width: 1,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCurrent
                                  ? LuminaTokens.glassTextPrimary
                                  : LuminaTokens.glassTextSecondary,
                              fontSize: 13,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            item.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.glassTextTertiary,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (isCurrent) ...[
                      const Icon(
                        Icons.equalizer_rounded,
                        size: 16,
                        color: LuminaTokens.glassTextPrimary,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (!isAuto && drawerWidth >= 260) ...[
                      Text(
                        TrackProgressBar.formatDuration(item.duration),
                        style: const TextStyle(
                          color: LuminaTokens.glassTextTertiary,
                          fontSize: 11,
                          fontFeatures: [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (isAuto) ...[
              const SizedBox(width: 2),
              Tooltip(
                message: '移至待播佇列',
                child: InkWell(
                  key: Key('btn_drawer_promote_auto_track_${item.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.promoteAutoTrackToUserQueue(item.id),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.playlist_add_rounded,
                      size: 16,
                      color: LuminaTokens.glassTextSecondary,
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: '移除此推薦曲目',
                child: InkWell(
                  key: Key('btn_drawer_remove_auto_track_${item.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.removeAutoTrack(item.id),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: LuminaTokens.glassTextTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );

      final Widget prefetched = TrackHoverPrefetch(
        track: item,
        child: rowInner,
      );

      if (isLockedPlayingAuto) return prefetched;
      return LongPressDraggable<_DrawerQueueDragPayload>(
        data: payload,
        feedback: buildFeedback(),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: buildDragProxyContent(),
        ),
        child: prefetched,
      );
    }

    final Widget rowWidget = buildDraggableRow();

    return DragTarget<_DrawerQueueDragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.combinedIndex != combinedIndex,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.reorderDualQueue(details.data.combinedIndex, combinedIndex);
      },
      builder: (context, candidateData, _) {
        final isTarget = candidateData.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: isTarget
                ? const Border(
                    top: BorderSide(color: LuminaTokens.focusRing, width: 2),
                  )
                : null,
          ),
          child: rowWidget,
        );
      },
    );
  }

  Widget _buildQueueDrawerRow({
    required TrackInfo item,
    required bool isCurrent,
  }) {
    return TrackHoverPrefetch(
      track: item,
      child: InkWell(
        key: Key('now_playing_queue_item_${item.id}'),
        onTap: () => widget.audioService.play(track: item),
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(10),
        hoverColor: LuminaTokens.glassRowHoverBg,
        focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: isCurrent
                ? LuminaTokens.glassNavActiveBg
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              AlbumArtworkView(
                track: item,
                size: 36,
                fullResolution: false,
                coverTargetSize: 300,
                audioService: widget.audioService,
                libraryCache: widget.libraryCache,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: LuminaTokens.glassPillBorder,
                  width: 1,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent
                            ? LuminaTokens.glassTextPrimary
                            : LuminaTokens.glassTextSecondary,
                        fontSize: 13,
                        fontWeight:
                            isCurrent ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextTertiary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isCurrent) ...[
                const Icon(
                  Icons.equalizer_rounded,
                  size: 16,
                  color: LuminaTokens.glassTextPrimary,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                TrackProgressBar.formatDuration(item.duration),
                style: const TextStyle(
                  color: LuminaTokens.glassTextTertiary,
                  fontSize: 11,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerQueueDragPayload {
  final TrackInfo track;
  final int combinedIndex;
  final bool isAuto;

  const _DrawerQueueDragPayload({
    required this.track,
    required this.combinedIndex,
    required this.isAuto,
  });
}

enum _DrawerQueueEntryKind {
  userHeader,
  userEmptyPlaceholder,
  userTrack,
  autoHeader,
  autoEmptyHint,
  autoTrack,
}

class _DrawerQueueEntry {
  final _DrawerQueueEntryKind kind;
  final TrackInfo? track;
  final int combinedIndex;
  final bool isLockedPlayingAuto;

  const _DrawerQueueEntry({
    required this.kind,
    this.track,
    this.combinedIndex = -1,
    this.isLockedPlayingAuto = false,
  });
}
