import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/lyric.dart';
import '../../models/playback_state.dart';
import '../../models/signal_path.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/desktop_window_controller.dart';
import '../../services/library_index_cache.dart';
import '../../services/now_playing_view_controller.dart';
import '../../services/podcast_store.dart';
import '../../shaders/mesh_fluid_painter.dart';
import '../artwork/album_artwork_view.dart';
import '../common/desktop_window_caption.dart';
import '../common/window_drag_bar.dart';
import '../lyrics/lyrics_view.dart';
import '../signal_path/quality_badge.dart';
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
  });

  @override
  State<NowPlayingOverlay> createState() => NowPlayingOverlayState();
}

class NowPlayingOverlayState extends State<NowPlayingOverlay>
    with TickerProviderStateMixin {
  late NowPlayingViewController _controller;
  late bool _ownsController;
  late NowPlayingViewMode _lastMode;
  late ArtworkPaletteService _paletteService;
  ui.FragmentShader? _meshShader;

  late final AnimationController _paletteAnimController;
  late final Animation<double> _paletteCurvedAnim;
  late final AnimationController _modeAnimController;
  late final Animation<double> _modeAnim;

  AnimationController get modeAnimController => _modeAnimController;
  AnimationController get transitionController => _modeAnimController;

  Widget? _cachedHeroWidget;
  String? _cachedHeroTrackKey;
  double? _cachedHeroCoverSide;

  Widget _getPersistentHeroWidget({
    required TrackInfo? track,
    required double baseCoverSide,
    required double gap,
    required double titleFontSize,
    required double maxMetaHeight,
    required double shadowBlur,
    required double shadowSpread,
    required double shadowOffsetY,
    required bool compactMetadata,
  }) {
    final trackKey = _trackIdentityKey(track);
    if (_cachedHeroWidget != null &&
        _cachedHeroTrackKey == trackKey &&
        _cachedHeroCoverSide == baseCoverSide) {
      return _cachedHeroWidget!;
    }
    _cachedHeroTrackKey = trackKey;
    _cachedHeroCoverSide = baseCoverSide;

    _cachedHeroWidget = RepaintBoundary(
      key: const Key('now_playing_cover_repaint_boundary'),
      child: SizedBox(
        width: baseCoverSide,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeroCoverCard(
              track,
              maxSide: baseCoverSide,
              shadowBlur: shadowBlur,
              shadowSpread: shadowSpread,
              shadowOffsetY: shadowOffsetY,
            ),
            SizedBox(height: gap),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: baseCoverSide,
                maxHeight: maxMetaHeight,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: baseCoverSide),
                  child: _buildTrackMetadata(
                    track,
                    centered: true,
                    showPills: true,
                    titleFontSize: titleFontSize,
                    compact: compactMetadata,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return _cachedHeroWidget!;
  }

  late AmbientPalette _fromPalette;
  late AmbientPalette _toPalette;
  int _paletteRequestSeq = 0;
  String? _lastPaletteTrackKey;
  bool _lastIsPlaying = false;
  StreamSubscription<PlaybackState>? _stateSub;

  AmbientPalette get _currentPalette => AmbientPalette.lerp(
    _fromPalette,
    _toPalette,
    _paletteCurvedAnim.value,
  );

  static String _trackIdentityKey(TrackInfo? track) {
    if (track == null) return 'none';
    return '${track.id}|'
        '${track.artworkCacheKey ?? ''}|'
        '${track.coverUrl ?? ''}|'
        '${track.albumArtUrl ?? ''}|'
        '${track.filePath ?? ''}|'
        '${track.album}|'
        '${track.title}|'
        '${track.providerName}|'
        '${track.format.label}';
  }

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? NowPlayingViewController();
    _lastMode = _controller.mode;
    _controller.addListener(_onControllerChanged);

    _paletteService = widget.paletteService ?? ArtworkPaletteService();
    _meshShader = widget.meshFluidProgram?.fragmentShader();

    final initialState = widget.audioService.currentState;
    final initialTrack = initialState.track;
    _lastIsPlaying = initialState.status == PlaybackStatus.playing;
    _lastPaletteTrackKey = _trackIdentityKey(initialTrack);

    final initialCached = _lookupCachedPaletteSync(initialTrack);
    final initialPalette =
        initialCached ?? AmbientPalette.fallbackFor(initialTrack);
    _fromPalette = initialPalette;
    _toPalette = initialPalette;

    _paletteAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      value: 1.0,
    );
    _paletteCurvedAnim = CurvedAnimation(
      parent: _paletteAnimController,
      curve: Curves.easeInOutCubic,
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

    _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
    if (initialCached == null && initialTrack != null) {
      _resolvePaletteForTrack(initialTrack);
    }
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
      _controller.addListener(_onControllerChanged);
    }

    if (oldWidget.paletteService != widget.paletteService) {
      _paletteService = widget.paletteService ?? ArtworkPaletteService();
    }

    if (oldWidget.meshFluidProgram != widget.meshFluidProgram) {
      _meshShader?.dispose();
      _meshShader = widget.meshFluidProgram?.fragmentShader();
    }

    if (oldWidget.audioService != widget.audioService) {
      _stateSub?.cancel();
      _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
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

    if (oldWidget.isVisible != widget.isVisible &&
        !widget.isVisible &&
        _paletteAnimController.isAnimating) {
      _paletteAnimController.stop();
      _fromPalette = _toPalette;
      _paletteAnimController.value = 1.0;
    }
  }

  @override
  void dispose() {
    widget.audioService.setNowPlayingVisible(false);
    _stateSub?.cancel();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    _paletteAnimController.dispose();
    _modeAnimController.dispose();
    _meshShader?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_controller.mode != _lastMode) {
      _lastMode = _controller.mode;
      if (_controller.mode == NowPlayingViewMode.cover) {
        _modeAnimController.reverse();
      } else if (_controller.mode == NowPlayingViewMode.split) {
        _modeAnimController.forward();
      }
      setState(() {});
    }
  }

  void _toggleCoverSplitMode() {
    final isHeadingToSplit = _modeAnimController.status == AnimationStatus.forward ||
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

  AmbientPalette? _lookupCachedPaletteSync(TrackInfo? track) {
    if (track == null) return null;
    final primaryKey = _paletteService.cacheKeyFor(track: track);
    final directHit = _paletteService.getCachedSync(primaryKey);
    if (directHit != null) return directHit;

    final cache = widget.libraryCache;
    if (cache != null) {
      if (track.id.isNotEmpty) {
        final trackPath = cache.getArtworkPathSync(track.id);
        if (trackPath != null && trackPath.isNotEmpty) {
          final hit = _paletteService.getCachedSync(
            _paletteService.cacheKeyFor(resolvedCachePath: trackPath),
          );
          if (hit != null) return hit;
        }
      }
      final albumId = cache.resolveAlbumIdForTrack(track);
      if (albumId != null && albumId.isNotEmpty) {
        final albumHit = _paletteService.getCachedSync(
          'canonical_album:$albumId',
        );
        if (albumHit != null) return albumHit;
        final albumPath = cache.getArtworkPathSync(albumId);
        if (albumPath != null && albumPath.isNotEmpty) {
          final hit = _paletteService.getCachedSync(
            _paletteService.cacheKeyFor(resolvedCachePath: albumPath),
          );
          if (hit != null) return hit;
        }
      }
    }
    return null;
  }

  void _onPlaybackState(PlaybackState state) {
    final nextPlaying = state.status == PlaybackStatus.playing;
    if (nextPlaying != _lastIsPlaying) {
      _lastIsPlaying = nextPlaying;
    }

    final nextKey = _trackIdentityKey(state.track);
    if (nextKey != _lastPaletteTrackKey) {
      _lastPaletteTrackKey = nextKey;
      final cached = _lookupCachedPaletteSync(state.track);
      if (cached != null) {
        ++_paletteRequestSeq;
        _animateToPalette(cached);
      } else {
        _resolvePaletteForTrack(state.track);
      }
    }
  }

  Future<void> _resolvePaletteForTrack(
    TrackInfo? track, {
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) async {
    final seq = ++_paletteRequestSeq;
    final target = await _paletteService.resolvePalette(
      track: track,
      audioService: widget.audioService,
      libraryCache: widget.libraryCache,
      resolvedCachePath: resolvedCachePath,
      resolvedCoverUrl: resolvedCoverUrl,
    );
    if (!mounted || seq != _paletteRequestSeq) return;
    _animateToPalette(target);
  }

  void _handleArtworkResolved(
    TrackInfo? track,
    String? cachePath,
    String? coverUrl,
  ) {
    if (!mounted) return;
    if (_trackIdentityKey(track) != _lastPaletteTrackKey) return;
    if ((cachePath == null || cachePath.isEmpty) &&
        (coverUrl == null || coverUrl.isEmpty)) {
      return;
    }
    _resolvePaletteForTrack(
      track,
      resolvedCachePath: cachePath,
      resolvedCoverUrl: coverUrl,
    );
  }

  void _animateToPalette(AmbientPalette target) {
    if (target == _toPalette) return;
    if (!widget.isVisible) {
      _paletteAnimController.stop();
      _fromPalette = target;
      _toPalette = target;
      _paletteAnimController.value = 1.0;
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _fromPalette = _currentPalette;
    _toPalette = target;
    _paletteAnimController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: widget.isVisible,
      child: SizedBox.expand(
        child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: const Key('now_playing_bg_repaint_boundary'),
            child: AnimatedBuilder(
              animation: _paletteAnimController,
              builder: (context, _) {
                final palette = _currentPalette;
                return CustomPaint(
                  key: const Key('now_playing_ambient_bg'),
                  painter: MeshFluidBgPainter(
                    shader: _meshShader,
                    time: 0.0,
                    colorA: palette.colorA,
                    colorB: palette.colorB,
                    colorC: palette.colorC,
                    colorD: palette.colorD,
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
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

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Layer 2: Translucent modern glass highlight & subtle depth
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.12),
                              Colors.white.withValues(alpha: 0.02),
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.05),
                            ],
                            stops: const [0.0, 0.16, 0.52, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
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
                                final metrics = NowPlayingLayoutMetrics.compute(
                                  width: constraints.maxWidth,
                                  height: constraints.maxHeight,
                                  mode: mode,
                                );
                                final stageWidget = _buildStage(
                                  key: const Key('now_playing_stage_content'),
                                  metrics: metrics,
                                  maxWidth: constraints.maxWidth,
                                  maxHeight: constraints.maxHeight,
                                  state: state,
                                  track: track,
                                  lyrics: lyrics,
                                );
                                final stageKey = mode == NowPlayingViewMode.lyrics
                                    ? 'lyrics'
                                    : 'main';
                                return AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 350),
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
                        ],
                      ),
                    ),
                  ),
                ],
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
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.36),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
                width: 1.2,
              ),
            ),
            child: IconButton(
              key: const Key('btn_collapse_now_playing'),
              tooltip: '收合播放畫面',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                hoverColor: Colors.white.withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: widget.onCollapse,
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 26,
              ),
            ),
          ),
          if (isPodcast) ...[
            const SizedBox(width: LuminaTokens.spaceSm),
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.36),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('btn_now_playing_skip_back_15s'),
                    tooltip: '倒退 15 秒 (-15s)',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 38,
                      minHeight: 38,
                    ),
                    icon: const Icon(
                      Icons.replay_10_rounded,
                      size: 20,
                      color: Colors.white,
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
                      minWidth: 38,
                      minHeight: 38,
                    ),
                    icon: const Icon(
                      Icons.forward_30_rounded,
                      size: 20,
                      color: Colors.white,
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
          const Spacer(),
          _ModeIconButton(
            key: const Key('btn_now_playing_mode_split'),
            icon: Icons.vertical_split_rounded,
            tooltip: '封面與逐字歌詞',
            selected: mode == NowPlayingViewMode.split,
            onTap: () {
              _modeAnimController.forward();
              _controller.setMode(NowPlayingViewMode.split);
            },
          ),
          const SizedBox(width: LuminaTokens.space2xs),
          _ModeIconButton(
            key: const Key('btn_now_playing_mode_lyrics'),
            icon: Icons.lyrics_rounded,
            tooltip: '純逐字歌詞',
            selected: mode == NowPlayingViewMode.lyrics,
            onTap: () => _controller.setMode(NowPlayingViewMode.lyrics),
          ),
          const SizedBox(width: LuminaTokens.space2xs),
          _ModeIconButton(
            key: const Key('btn_now_playing_mode_cover'),
            icon: Icons.album_outlined,
            tooltip: '純封面檢視',
            selected: mode == NowPlayingViewMode.cover,
            onTap: () {
              _modeAnimController.reverse();
              _controller.setMode(NowPlayingViewMode.cover);
            },
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
    );
  }

  Widget _buildStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required double maxHeight,
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
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    final rawCoverMetrics = NowPlayingLayoutMetrics.compute(
      width: maxWidth,
      height: maxHeight,
      mode: NowPlayingViewMode.cover,
    );
    final coverMetrics =
        rawCoverMetrics.arrangement ==
            NowPlayingStageArrangement.coverLandscapeRow
        ? metrics
        : rawCoverMetrics;
    final baseCoverSide = coverMetrics.coverSide;
    final gap = coverMetrics.gap;
    final titleFontSize = coverMetrics.titleFontSize;
    final maxMetaHeight = coverMetrics.maxMetaHeight;
    final shadowBlur = coverMetrics.shadowBlur;
    final shadowSpread = coverMetrics.shadowSpread;
    final shadowOffsetY = coverMetrics.shadowOffsetY;
    final compactMetadata = coverMetrics.compactMetadata;

    final persistentHero = _getPersistentHeroWidget(
      track: track,
      baseCoverSide: baseCoverSide,
      gap: gap,
      titleFontSize: titleFontSize,
      maxMetaHeight: maxMetaHeight,
      shadowBlur: shadowBlur,
      shadowSpread: shadowSpread,
      shadowOffsetY: shadowOffsetY,
      compactMetadata: compactMetadata,
    );

    final scaledCoverHalfWidth = baseCoverSide * 0.88 * 0.5;
    final targetLeftCenterX = math.max(
      scaledCoverHalfWidth + math.max(16.0, metrics.stagePadH),
      maxWidth * 0.26,
    );
    final dx = targetLeftCenterX - (maxWidth / 2.0);
    final centerOffset = Offset.zero;
    final leftOffset = Offset(dx, 0.0);

    return Stack(
      key: key,
      fit: StackFit.expand,
      children: [
        Positioned(
          left: maxWidth * 0.48,
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
              final currentScale = ui.lerpDouble(1.0, 0.88, slideT)!;

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
                compact: true,
              ),
              SizedBox(width: metrics.gap),
              Expanded(
                child: _buildTrackMetadata(
                  track,
                  centered: false,
                  showPills: false,
                  titleFontSize: metrics.titleFontSize,
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
    bool compact = false,
    double shadowBlur = 36,
    double shadowSpread = 2,
    double shadowOffsetY = 14,
  }) {
    Widget card = ConstrainedBox(
      key: const ValueKey('now_playing_hero_cover_card'),
      constraints: BoxConstraints(maxWidth: maxSide, maxHeight: maxSide),
      child: AspectRatio(
        aspectRatio: 1,
        child: AlbumArtworkView(
          track: track,
          size: maxSide,
          fullResolution: !compact,
          coverTargetSize: compact ? 300 : 1200,
          audioService: widget.audioService,
          libraryCache: widget.libraryCache,
          onArtworkResolved: (cachePath, coverUrl) =>
              _handleArtworkResolved(track, cachePath, coverUrl),
          borderRadius: BorderRadius.circular(compact ? 6 : 14),
          boxShadow: compact
              ? null
              : [
                  BoxShadow(
                    color: const Color(0x66000000),
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
    bool compact = false,
  }) {
    final crossAxis =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final align = centered ? TextAlign.center : TextAlign.start;

    final metaSubtitle = track == null
        ? ''
        : (track.hasDistinctAlbumArtist
            ? '${track.artist} (專輯演出者: ${track.albumArtist})  •  ${track.album}'
            : '${track.artist}  •  ${track.album}');
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
            color: LuminaTokens.textPrimary,
            fontSize: titleFontSize ?? (centered ? 22 : 16),
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: compact ? 2 : LuminaTokens.space2xs),
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
                    boxSize: 16,
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
                    color: LuminaTokens.textSecondary,
                    fontSize: compact ? 12.5 : 13.5,
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
              color: LuminaTokens.textSecondary,
              fontSize: compact ? 12.5 : 13.5,
            ),
          ),
        if (showPills && track != null) ...[
          SizedBox(height: compact ? 6 : LuminaTokens.spaceSm),
          StreamBuilder<SignalPath>(
            stream: widget.audioService.signalPathStream,
            initialData: widget.audioService.currentSignalPath,
            builder: (context, sigSnap) {
              final sp = sigSnap.data ?? widget.audioService.currentSignalPath;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Wrap(
                  alignment: centered ? WrapAlignment.center : WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: LuminaTokens.spaceXs,
                  runSpacing: 6,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.cardElevatedBg.withValues(
                            alpha: 0.85,
                          ),
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusPill,
                          ),
                          border: Border.all(
                            color: LuminaTokens.borderControl,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          track.format.label,
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ),
                    QualityBadge(
                      quality: sp.overallQuality,
                      onTap: () =>
                          SignalPathModal.show(context, widget.audioService),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _ModeIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  const _ModeIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ModeIconButton> createState() => _ModeIconButtonState();
}

class _ModeIconButtonState extends State<_ModeIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.tooltip,
        child: Material(
          color: Colors.transparent,
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
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: widget.selected
                    ? Colors.white.withValues(alpha: 0.22)
                    : (_hovered
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.black.withValues(alpha: 0.36)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : (widget.selected
                          ? Colors.white.withValues(alpha: 0.38)
                          : Colors.white.withValues(
                              alpha: _hovered ? 0.24 : 0.14,
                            )),
                  width: 1.2,
                ),
              ),
              child: Icon(
                widget.icon,
                size: 19,
                color: widget.selected
                    ? Colors.white
                    : LuminaTokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
