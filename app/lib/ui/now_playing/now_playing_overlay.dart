import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/lyric.dart';
import '../../models/playback_state.dart';
import '../../models/signal_path.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/now_playing_view_controller.dart';
import '../../shaders/mesh_fluid_painter.dart';
import '../artwork/album_artwork_view.dart';
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
  final ArtworkPaletteService? paletteService;
  final ui.FragmentProgram? meshFluidProgram;
  final bool isVisible;
  final bool? enableAmbientMotion;

  const NowPlayingOverlay({
    super.key,
    required this.audioService,
    required this.onCollapse,
    this.libraryCache,
    this.controller,
    this.paletteService,
    this.meshFluidProgram,
    this.isVisible = true,
    this.enableAmbientMotion,
  });

  @override
  State<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<NowPlayingOverlay>
    with TickerProviderStateMixin {
  late NowPlayingViewController _controller;
  late bool _ownsController;
  late NowPlayingViewMode _lastMode;
  late ArtworkPaletteService _paletteService;
  ui.FragmentShader? _meshShader;

  late final AnimationController _paletteAnimController;
  late final Animation<double> _paletteCurvedAnim;
  late final AnimationController _fluidAnimController;

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

  bool get _shouldAnimateFluid {
    final motionEnabled =
        widget.enableAmbientMotion ??
        !Platform.environment.containsKey('FLUTTER_TEST');
    return widget.isVisible && motionEnabled && _lastIsPlaying;
  }

  static String _trackIdentityKey(TrackInfo? track) {
    if (track == null) return 'none';
    return '${track.id}|'
        '${track.artworkCacheKey ?? ''}|'
        '${track.coverUrl ?? ''}|'
        '${track.albumArtUrl ?? ''}|'
        '${track.filePath ?? ''}|'
        '${track.album}|'
        '${track.title}';
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
      duration: const Duration(milliseconds: 650),
      value: 1.0,
    );
    _paletteCurvedAnim = CurvedAnimation(
      parent: _paletteAnimController,
      curve: Curves.easeInOutCubic,
    );

    _fluidAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    _syncAmbientMotion();

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

    if (oldWidget.isVisible != widget.isVisible ||
        oldWidget.enableAmbientMotion != widget.enableAmbientMotion) {
      if (!widget.isVisible && _paletteAnimController.isAnimating) {
        _paletteAnimController.stop();
        _fromPalette = _toPalette;
        _paletteAnimController.value = 1.0;
      }
      _syncAmbientMotion();
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    _paletteAnimController.dispose();
    _fluidAnimController.dispose();
    _meshShader?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_controller.mode != _lastMode) {
      _lastMode = _controller.mode;
      setState(() {});
    }
  }

  void _syncAmbientMotion() {
    if (_shouldAnimateFluid) {
      if (!_fluidAnimController.isAnimating) {
        _fluidAnimController.repeat();
      }
    } else {
      if (_fluidAnimController.isAnimating) {
        _fluidAnimController.stop();
      }
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
      _syncAmbientMotion();
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
    return SizedBox.expand(
      key: const Key('now_playing_overlay'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _paletteAnimController,
                _fluidAnimController,
              ]),
              builder: (context, _) {
                final palette = _currentPalette;
                return CustomPaint(
                  key: const Key('now_playing_ambient_bg'),
                  painter: MeshFluidBgPainter(
                    shader: _meshShader,
                    time: _fluidAnimController.value * 24.0,
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

              return Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    _buildTopBar(mode),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final metrics = NowPlayingLayoutMetrics.compute(
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            mode: mode,
                          );
                          return AnimatedSwitcher(
                            duration: const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: _buildStage(
                              key: ValueKey(
                                '${mode.name}-${metrics.arrangement.name}',
                              ),
                              metrics: metrics,
                              maxWidth: constraints.maxWidth,
                              maxHeight: constraints.maxHeight,
                              state: state,
                              track: track,
                              lyrics: lyrics,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(NowPlayingViewMode mode) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LuminaTokens.spaceMd,
        LuminaTokens.spaceSm,
        LuminaTokens.spaceMd + 2,
        LuminaTokens.space2xs,
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('btn_collapse_now_playing'),
            tooltip: '收合播放畫面',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            style: IconButton.styleFrom(
              foregroundColor: LuminaTokens.textSecondary,
              hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.7),
              focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              ),
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
                    : const BorderSide(color: Colors.transparent, width: 1.5),
              ),
            ),
            onPressed: widget.onCollapse,
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 26,
            ),
          ),
          const Spacer(),
          _ModeIconButton(
            key: const Key('btn_now_playing_mode_split'),
            icon: Icons.vertical_split_rounded,
            tooltip: '封面與逐字歌詞',
            selected: mode == NowPlayingViewMode.split,
            onTap: () => _controller.setMode(NowPlayingViewMode.split),
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
            onTap: () => _controller.setMode(NowPlayingViewMode.cover),
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
    switch (metrics.arrangement) {
      case NowPlayingStageArrangement.coverLandscapeRow:
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

      case NowPlayingStageArrangement.coverVertical:
        final innerW = math.max(120.0, maxWidth - metrics.stagePadH * 2);
        return Padding(
          key: key,
          padding: EdgeInsets.fromLTRB(
            metrics.stagePadH,
            metrics.padTop,
            metrics.stagePadH,
            metrics.padBottom,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: LayoutBuilder(
                    builder: (context, coverConstraints) {
                      final availSide = math.min(
                        coverConstraints.maxWidth,
                        coverConstraints.maxHeight,
                      );
                      final side = availSide.isFinite
                          ? math.min(metrics.coverSide, availSide).floorToDouble()
                          : metrics.coverSide;
                      return _buildHeroCoverCard(
                        track,
                        maxSide: math.max(0.0, side),
                        shadowBlur: metrics.shadowBlur,
                        shadowSpread: metrics.shadowSpread,
                        shadowOffsetY: metrics.shadowOffsetY,
                      );
                    },
                  ),
                ),
                SizedBox(height: metrics.gap),
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
                        compact: metrics.compactMetadata,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

      case NowPlayingStageArrangement.lyricsFull:
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
                isPlaying: state.status == PlaybackStatus.playing,
                trackId: track?.id,
                audioService: widget.audioService,
                viewController: _controller,
              ),
            ),
          ),
        );

      case NowPlayingStageArrangement.lyricsCompactHeader:
      case NowPlayingStageArrangement.splitCompactHeader:
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
                  child: LyricsView(
                    lyrics: lyrics,
                    currentPosition: state.position,
                    onSeek: widget.audioService.seek,
                    centered: true,
                    isPlaying: state.status == PlaybackStatus.playing,
                    trackId: track?.id,
                    audioService: widget.audioService,
                    viewController: _controller,
                  ),
                ),
              ),
            ),
          ],
        );

      case NowPlayingStageArrangement.splitNarrowStacked:
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
                  child: LyricsView(
                    lyrics: lyrics,
                    currentPosition: state.position,
                    onSeek: widget.audioService.seek,
                    centered: true,
                    isPlaying: state.status == PlaybackStatus.playing,
                    trackId: track?.id,
                    audioService: widget.audioService,
                    viewController: _controller,
                  ),
                ),
              ),
            ),
          ],
        );

      case NowPlayingStageArrangement.splitTwoColumn:
        return Padding(
          key: key,
          padding: EdgeInsets.only(right: metrics.stagePadH),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: metrics.leftFlex,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    metrics.stagePadH,
                    metrics.padTop,
                    metrics.stagePadH,
                    metrics.padBottom,
                  ),
                  child: LayoutBuilder(
                    builder: (context, leftConstraints) {
                      final leftInnerW = math.max(
                        120.0,
                        leftConstraints.maxWidth,
                      );
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: LayoutBuilder(
                                builder: (context, coverConstraints) {
                                  final availSide = math.min(
                                    coverConstraints.maxWidth,
                                    coverConstraints.maxHeight,
                                  );
                                  final side = availSide.isFinite
                                      ? math
                                            .min(metrics.coverSide, availSide)
                                            .floorToDouble()
                                      : metrics.coverSide;
                                  return _buildHeroCoverCard(
                                    track,
                                    maxSide: math.max(0.0, side),
                                    shadowBlur: metrics.shadowBlur,
                                    shadowSpread: metrics.shadowSpread,
                                    shadowOffsetY: metrics.shadowOffsetY,
                                  );
                                },
                              ),
                            ),
                            SizedBox(height: metrics.gap),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: leftInnerW,
                                maxHeight: metrics.maxMetaHeight,
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.center,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: leftInnerW,
                                  ),
                                  child: _buildTrackMetadata(
                                    track,
                                    centered: true,
                                    showPills: true,
                                    titleFontSize: metrics.titleFontSize,
                                    compact: metrics.compactMetadata,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceMd),
              Expanded(
                flex: metrics.rightFlex,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: metrics.compactMetadata
                        ? LuminaTokens.spaceXs
                        : LuminaTokens.spaceMd,
                  ),
                  child: LyricsView(
                    lyrics: lyrics,
                    currentPosition: state.position,
                    onSeek: widget.audioService.seek,
                    centered: true,
                    isPlaying: state.status == PlaybackStatus.playing,
                    trackId: track?.id,
                    audioService: widget.audioService,
                    viewController: _controller,
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildHeroCoverCard(
    TrackInfo? track, {
    required double maxSide,
    bool compact = false,
    double shadowBlur = 36,
    double shadowSpread = 2,
    double shadowOffsetY = 14,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxSide, maxHeight: maxSide),
      child: AspectRatio(
        aspectRatio: 1,
        child: AlbumArtworkView(
          track: track,
          size: maxSide,
          audioService: widget.audioService,
          libraryCache: widget.libraryCache,
          onArtworkResolved: (cachePath, coverUrl) =>
              _handleArtworkResolved(track, cachePath, coverUrl),
          borderRadius: BorderRadius.circular(compact ? 6 : 12),
          boxShadow: compact
              ? null
              : [
                  BoxShadow(
                    color: const Color(0x88000000),
                    blurRadius: shadowBlur,
                    spreadRadius: shadowSpread,
                    offset: Offset(0, shadowOffsetY),
                  ),
                ],
        ),
      ),
    );
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

    return Column(
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
                    ? LuminaTokens.cardElevatedBg.withValues(alpha: 0.92)
                    : (_hovered
                          ? LuminaTokens.cardHoverBg.withValues(alpha: 0.72)
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : (widget.selected
                            ? LuminaTokens.borderControl
                            : Colors.transparent),
                  width: 1.5,
                ),
              ),
              child: Icon(
                widget.icon,
                size: 19,
                color: widget.selected
                    ? LuminaTokens.textPrimary
                    : LuminaTokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
