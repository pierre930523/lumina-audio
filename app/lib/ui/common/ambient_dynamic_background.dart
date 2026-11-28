import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../shaders/mesh_fluid_painter.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';
import 'noise_grain_overlay.dart';

part 'ambient_dynamic_background_artwork.dart';
part 'ambient_dynamic_background_painters.dart';

/// Shared multi-layer ambient background:
/// 1. Base 4-color fluid mesh gradient (animated strictly on track/artwork change).
/// 2. Low-res decoded album cover painted inside [CustomPaint] (zero [Image] widgets)
///    with 1.2x scale, 1.35x saturation (softened in Light mode), sigma-80 mirror
///    blur, and 800ms crossfade.
/// 3. Scrim layer (`LuminaTokens.ambientScrimColor` in dark mode or
///    `glass.scrimColor` when [adaptToTheme] is true in light mode) for WCAG AA contrast.
/// 4. Static deterministic 128x128 film grain noise overlay (zero tickers).
class AmbientDynamicBackground extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final ArtworkPaletteService? paletteService;
  final ui.FragmentProgram? meshFluidProgram;
  final Key? repaintBoundaryKey;
  final Key? meshPainterKey;
  final bool enabled;
  final String? externalArtworkCachePath;
  final String? externalArtworkUrl;
  final double ambientTintStrength;
  final bool adaptToTheme;

  const AmbientDynamicBackground({
    super.key,
    required this.audioService,
    this.libraryCache,
    this.paletteService,
    this.meshFluidProgram,
    this.repaintBoundaryKey,
    this.meshPainterKey,
    this.enabled = true,
    this.externalArtworkCachePath,
    this.externalArtworkUrl,
    this.ambientTintStrength = 1.0,
    this.adaptToTheme = false,
  });

  @override
  State<AmbientDynamicBackground> createState() =>
      _AmbientDynamicBackgroundState();
}

class _AmbientDynamicBackgroundState extends State<AmbientDynamicBackground>
    with TickerProviderStateMixin {
  static const int _coverDecodeTargetWidth = 96;

  late ArtworkPaletteService _paletteService;
  ui.FragmentShader? _meshShader;
  ui.ImageShader? _noiseShader;

  late final AnimationController _paletteController;
  late final CurvedAnimation _paletteCurve;
  late final AnimationController _coverFadeController;
  late final CurvedAnimation _coverFadeAnim;

  final _CoverFrameModel _coverModel = _CoverFrameModel();
  late final Listenable _coverPaintRepaint = Listenable.merge([
    _coverModel,
    _coverFadeAnim,
  ]);

  late AmbientPalette _fromPalette;
  late AmbientPalette _toPalette;
  int _paletteRequestSeq = 0;

  int _artworkRequestSeq = 0;
  String? _currArtworkSourceKey;
  String? _lastTrackKey;
  String? _lastTriggerKey;

  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<TrackInfo>? _trackChangedSub;
  ImageStream? _activeImageStream;
  ImageStreamListener? _activeImageListener;
  Completer<ui.Image?>? _activeImageCompleter;

  AmbientPalette get _currentPalette => AmbientPalette.lerp(
    _fromPalette,
    _toPalette,
    _paletteCurve.value,
  );

  static String _trackIdentityKey(TrackInfo? track) {
    if (track == null) return 'none';
    return '${track.responsiveArtworkKey}|'
        '${track.id}|'
        '${track.artworkCacheKey ?? ''}|'
        '${track.artworkUrl ?? ''}|'
        '${track.coverUrl ?? ''}|'
        '${track.albumArtUrl ?? ''}|'
        '${track.filePath ?? ''}|'
        '${track.album}|'
        '${track.title}|'
        '${track.providerName}|'
        '${track.format.label}';
  }

  String _computeTriggerKey(TrackInfo? track) {
    return '${_trackIdentityKey(track)}|'
        '${widget.externalArtworkCachePath?.trim() ?? ''}|'
        '${widget.externalArtworkUrl?.trim() ?? ''}';
  }

  @override
  void initState() {
    super.initState();
    _paletteService = widget.paletteService ?? ArtworkPaletteService();
    _meshShader = widget.meshFluidProgram?.fragmentShader();
    _noiseShader = NoiseTextureCache.getOrCreateSync();

    _paletteController = AnimationController(
      vsync: this,
      duration: LuminaTokens.ambientTransitionDuration,
      value: 1.0,
    );
    _paletteCurve = CurvedAnimation(
      parent: _paletteController,
      curve: Curves.ease,
    );

    _coverFadeController = AnimationController(
      vsync: this,
      duration: LuminaTokens.ambientTransitionDuration,
      value: 1.0,
    )..addStatusListener(_onCoverFadeStatus);
    _coverFadeAnim = CurvedAnimation(
      parent: _coverFadeController,
      curve: Curves.ease,
    );

    final initialTrack = widget.audioService.currentState.track;
    _lastTrackKey = _trackIdentityKey(initialTrack);
    _lastTriggerKey = _computeTriggerKey(initialTrack);

    final initialCached = _lookupCachedPaletteSync(initialTrack);
    final initialPalette =
        initialCached ?? AmbientPalette.fallbackFor(initialTrack);
    _fromPalette = initialPalette;
    _toPalette = initialPalette;

    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
    _trackChangedSub = widget.audioService.trackChangedStream.listen(
      _onTrackChanged,
    );

    _resolvePaletteIfNeeded(initialTrack, cached: initialCached);
    if (!_tryHydrateCachedCoverSync(initialTrack)) {
      _resolveAndLoadArtwork(initialTrack);
    }
  }

  @override
  void didUpdateWidget(covariant AmbientDynamicBackground oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.paletteService != widget.paletteService) {
      _paletteService = widget.paletteService ?? ArtworkPaletteService();
    }

    if (oldWidget.meshFluidProgram != widget.meshFluidProgram) {
      _meshShader?.dispose();
      _meshShader = widget.meshFluidProgram?.fragmentShader();
    }

    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      widget.libraryCache?.addListener(_onLibraryCacheChanged);
    }

    bool needsRefresh = false;

    if (oldWidget.audioService != widget.audioService) {
      _stateSub?.cancel();
      _trackChangedSub?.cancel();
      _trackChangedSub = null;
      _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
      _trackChangedSub = widget.audioService.trackChangedStream.listen(
        _onTrackChanged,
      );
      needsRefresh = true;
    }

    if (oldWidget.externalArtworkCachePath != widget.externalArtworkCachePath ||
        oldWidget.externalArtworkUrl != widget.externalArtworkUrl ||
        oldWidget.libraryCache != widget.libraryCache ||
        oldWidget.paletteService != widget.paletteService) {
      needsRefresh = true;
    }

    if (oldWidget.enabled != widget.enabled) {
      if (!widget.enabled) {
        _stopAndSnapAnimations();
      } else {
        needsRefresh = true;
      }
    }

    if (needsRefresh) {
      final track = widget.audioService.currentState.track;
      _handleTrackOrArtworkChange(track, forceArtworkCheck: true);
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _trackChangedSub?.cancel();
    _trackChangedSub = null;
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    _cancelActiveImageStream();
    _coverFadeController.removeStatusListener(_onCoverFadeStatus);
    _paletteCurve.dispose();
    _paletteController.dispose();
    _coverFadeAnim.dispose();
    _coverFadeController.dispose();
    _coverModel.disposeAll();
    _meshShader?.dispose();
    super.dispose();
  }

  void _onCoverFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _coverModel.clearPrevious();
    }
  }

  void _stopAndSnapAnimations() {
    if (_paletteController.isAnimating) {
      _paletteController.stop();
    }
    _fromPalette = _toPalette;
    _paletteController.value = 1.0;

    if (_coverFadeController.isAnimating) {
      _coverFadeController.stop();
    }
    _coverFadeController.value = 1.0;
    _coverModel.clearPrevious();
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final track = widget.audioService.currentState.track;
    _handleTrackOrArtworkChange(track, forceArtworkCheck: true);
  }

  void _onTrackChanged(TrackInfo track) {
    if (!mounted) return;
    _handleTrackOrArtworkChange(track, forceArtworkCheck: true);
  }

  void _onPlaybackState(PlaybackState state) {
    if (!mounted) return;
    _handleTrackOrArtworkChange(state.track);
  }

  void _handleTrackOrArtworkChange(
    TrackInfo? track, {
    bool forceArtworkCheck = false,
  }) {
    final nextTrackKey = _trackIdentityKey(track);
    final nextTriggerKey = _computeTriggerKey(track);
    final triggerChanged = nextTriggerKey != _lastTriggerKey;
    final trackChanged = nextTrackKey != _lastTrackKey;

    if (!triggerChanged && !forceArtworkCheck) return;

    _lastTrackKey = nextTrackKey;
    _lastTriggerKey = nextTriggerKey;

    if (trackChanged || triggerChanged || forceArtworkCheck) {
      final cached = _lookupCachedPaletteSync(track);
      if (cached != null) {
        ++_paletteRequestSeq;
        _animateToPalette(cached);
      } else {
        _resolvePaletteIfNeeded(track, cached: null);
      }
      _resolveAndLoadArtwork(track);
    }
  }

  void _resolvePaletteIfNeeded(TrackInfo? track, {AmbientPalette? cached}) {
    if (cached != null) {
      _animateToPalette(cached);
      return;
    }
    final extPath = widget.externalArtworkCachePath?.trim();
    final extUrl = widget.externalArtworkUrl?.trim();
    final hasExtPath = extPath != null && extPath.isNotEmpty;
    final hasExtUrl = extUrl != null && extUrl.isNotEmpty;
    if (track == null && !hasExtPath && !hasExtUrl) {
      _animateToPalette(AmbientPalette.defaultFallback);
      return;
    }
    _resolvePaletteForTrack(
      track,
      resolvedCachePath: hasExtPath ? extPath : null,
      resolvedCoverUrl: hasExtUrl ? extUrl : null,
    );
  }

  AmbientPalette? _lookupCachedPaletteSync(TrackInfo? track) {
    final extPath = widget.externalArtworkCachePath?.trim();
    if (extPath != null && extPath.isNotEmpty) {
      final hit = _paletteService.getCachedSync(
        _paletteService.cacheKeyFor(resolvedCachePath: extPath),
      );
      if (hit != null) return hit;
    }

    final extUrl = widget.externalArtworkUrl?.trim();
    if (extUrl != null && extUrl.isNotEmpty) {
      final hit = _paletteService.getCachedSync(
        _paletteService.cacheKeyFor(resolvedCoverUrl: extUrl),
      );
      if (hit != null) return hit;
    }

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

  void _animateToPalette(AmbientPalette target) {
    if (target == _toPalette) return;
    if (!widget.enabled) {
      _paletteController.stop();
      _fromPalette = target;
      _toPalette = target;
      _paletteController.value = 1.0;
      return;
    }
    _fromPalette = _currentPalette;
    _toPalette = target;
    _paletteController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final glass =
        widget.adaptToTheme ? LuminaGlassTheme.of(context) : LuminaGlassTheme.dark;
    final isDark = glass.isDark;
    final tint = widget.ambientTintStrength.clamp(0.0, 1.0).toDouble();

    return TickerMode(
      enabled: widget.enabled,
      child: RepaintBoundary(
        key: widget.repaintBoundaryKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Layer 0: Solid opaque backing guarantees alpha == 1.0 on frame 0.
            Positioned.fill(
              child: ColoredBox(
                color: isDark ? LuminaTokens.canvasBg : glass.canvasBg,
              ),
            ),
            // Layer 1: 4-color fluid mesh fallback / base gradient.
            _buildMeshLayer(glass, isDark, tint),
            // Layer 2: Blurred saturated low-res album cover (CustomPaint only).
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _AmbientCoverPainter(
                    model: _coverModel,
                    progress: _coverFadeAnim,
                    repaint: _coverPaintRepaint,
                    coverOpacity: isDark ? tint : (0.22 * tint).clamp(0.0, 1.0),
                    lightMode: !isDark,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // Layer 3: Scrim for WCAG AA contrast.
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color:
                      isDark ? LuminaTokens.ambientScrimColor : glass.scrimColor,
                ),
              ),
            ),
            // Layer 4: Subtle deterministic 128x128 film grain noise overlay.
            if (_noiseShader != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: NoiseGrainPainter(
                      shader: _noiseShader!,
                      opacity: isDark
                          ? LuminaTokens.ambientNoiseOpacity
                          : LuminaTokens.ambientNoiseOpacity * 0.45,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
