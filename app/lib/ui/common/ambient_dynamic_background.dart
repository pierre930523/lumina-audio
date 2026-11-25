import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/streaming/streaming_playback_coordinator.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../shaders/mesh_fluid_painter.dart';
import '../theme/lumina_tokens.dart';

/// Shared multi-layer ambient background:
/// 1. Base 4-color fluid mesh gradient (animated strictly on track/artwork change).
/// 2. Low-res decoded album cover painted inside [CustomPaint] (zero [Image] widgets)
///    with 1.2x scale, 1.35x saturation, sigma-80 mirror blur, and 800ms crossfade.
/// 3. Deep charcoal scrim (`LuminaTokens.ambientScrimColor`) for WCAG AA contrast.
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
    _noiseShader = _NoiseTextureCache.getOrCreateSync();

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
    if (widget.audioService is CoordinatingAudioService) {
      _trackChangedSub =
          (widget.audioService as CoordinatingAudioService).trackChangedStream
              .listen(_onTrackChanged);
    }

    _resolvePaletteIfNeeded(initialTrack, cached: initialCached);
    _resolveAndLoadArtwork(initialTrack);
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
      if (widget.audioService is CoordinatingAudioService) {
        _trackChangedSub =
            (widget.audioService as CoordinatingAudioService).trackChangedStream
                .listen(_onTrackChanged);
      }
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

  static bool _isLikelyLocalFilePath(String raw) {
    return !raw.startsWith('/api/') &&
        !raw.startsWith('http://') &&
        !raw.startsWith('https://') &&
        !raw.startsWith('//');
  }

  void _cancelActiveImageStream() {
    final stream = _activeImageStream;
    final listener = _activeImageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _activeImageStream = null;
    _activeImageListener = null;
    final completer = _activeImageCompleter;
    _activeImageCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  Future<void> _resolveAndLoadArtwork(TrackInfo? track) async {
    final seq = ++_artworkRequestSeq;
    _cancelActiveImageStream();

    // 1. Explicit external local cache path.
    final extPath = widget.externalArtworkCachePath?.trim();
    if (extPath != null && extPath.isNotEmpty) {
      final sourceKey = 'file:$extPath';
      if (sourceKey == _currArtworkSourceKey && _coverModel.currImage != null) {
        return;
      }
      final img = await _decodeFileImage(extPath);
      if (!mounted || seq != _artworkRequestSeq) {
        img?.dispose();
        return;
      }
      if (img != null) {
        _applyDecodedCover(img, sourceKey);
        return;
      }
    }

    // 2. Explicit external URL or file path.
    final extUrl = widget.externalArtworkUrl?.trim();
    if (extUrl != null && extUrl.isNotEmpty) {
      final normalizedUrl = BaseStreamingProvider.normalizeCoverUrl(extUrl);
      if (normalizedUrl != null) {
        final sourceKey = 'url:$normalizedUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        final img = await _resolveNetworkImage(normalizedUrl, seq);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      } else if (_isLikelyLocalFilePath(extUrl)) {
        final sourceKey = 'file:$extUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        final img = await _decodeFileImage(extUrl);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      }
    }

    if (track == null) {
      _clearCoverIfPresent();
      return;
    }

    // 3. Synchronous LibraryIndexCache lookup.
    final cache = widget.libraryCache;
    if (cache != null) {
      final canonicalAlbumId = cache.resolveAlbumIdForTrack(track);
      final syncCandidates = <String?>[
        if (track.id.isNotEmpty) cache.getArtworkPathSync(track.id),
        if (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty)
          cache.getArtworkPathSync(canonicalAlbumId),
      ];
      for (final candidate in syncCandidates) {
        final p = candidate?.trim();
        if (p != null && p.isNotEmpty) {
          final sourceKey = 'file:$p';
          if (sourceKey == _currArtworkSourceKey &&
              _coverModel.currImage != null) {
            return;
          }
          final img = await _decodeFileImage(p);
          if (!mounted || seq != _artworkRequestSeq) {
            img?.dispose();
            return;
          }
          if (img != null) {
            _applyDecodedCover(img, sourceKey);
            return;
          }
        }
      }
    }

    // 4. Track artworkUrl (network URL via ImageStream or local file path).
    final trackArtUrl = track.artworkUrl?.trim();
    if (trackArtUrl != null && trackArtUrl.isNotEmpty) {
      final normalizedUrl = BaseStreamingProvider.normalizeCoverUrl(
        trackArtUrl,
      );
      if (normalizedUrl != null) {
        final sourceKey = 'url:$normalizedUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        final img = await _resolveNetworkImage(normalizedUrl, seq);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      } else if (_isLikelyLocalFilePath(trackArtUrl)) {
        final sourceKey = 'file:$trackArtUrl';
        if (sourceKey == _currArtworkSourceKey &&
            _coverModel.currImage != null) {
          return;
        }
        final img = await _decodeFileImage(trackArtUrl);
        if (!mounted || seq != _artworkRequestSeq) {
          img?.dispose();
          return;
        }
        if (img != null) {
          _applyDecodedCover(img, sourceKey);
          return;
        }
      }
    }

    // 5. Async resolution via LibraryIndexCache or AudioService.getArtwork.
    String? fetchedPath;
    if (cache != null) {
      final canonicalAlbumId = cache.resolveAlbumIdForTrack(track);
      if (canonicalAlbumId != null &&
          canonicalAlbumId.isNotEmpty &&
          !cache.hasArtworkCached(canonicalAlbumId)) {
        try {
          fetchedPath = await cache.resolveArtworkPath(
            widget.audioService,
            canonicalAlbumId,
            maxDim: 0,
          );
        } catch (_) {}
      }
      if (!mounted || seq != _artworkRequestSeq) return;
      if ((fetchedPath == null || fetchedPath.isEmpty) &&
          track.id.isNotEmpty &&
          !cache.hasArtworkCached(track.id)) {
        try {
          fetchedPath = await cache.resolveArtworkPath(
            widget.audioService,
            track.id,
            path: track.filePath,
            maxDim: 0,
          );
        } catch (_) {}
      }
    } else if (track.id.isNotEmpty) {
      try {
        final res = await widget.audioService.getArtwork(
          track.id,
          path: track.filePath,
          maxDim: 0,
        );
        if (res != null && res['found'] == true) {
          final candidate = res['cache_path']?.toString().trim();
          if (candidate != null && candidate.isNotEmpty) {
            fetchedPath = candidate;
          }
        }
      } catch (_) {}
    }

    if (!mounted || seq != _artworkRequestSeq) return;
    if (fetchedPath != null && fetchedPath.isNotEmpty) {
      final sourceKey = 'file:$fetchedPath';
      if (sourceKey == _currArtworkSourceKey && _coverModel.currImage != null) {
        return;
      }
      final img = await _decodeFileImage(fetchedPath);
      if (!mounted || seq != _artworkRequestSeq) {
        img?.dispose();
        return;
      }
      if (img != null) {
        _applyDecodedCover(img, sourceKey);
        return;
      }
    }

    _clearCoverIfPresent();
  }

  Future<ui.Image?> _decodeFileImage(String filePath) async {
    ui.Codec? codec;
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _coverDecodeTargetWidth,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
    }
  }

  Future<ui.Image?> _resolveNetworkImage(String url, int seq) async {
    if (!mounted || seq != _artworkRequestSeq) return null;
    try {
      final provider = ResizeImage(
        NetworkImage(
          url,
          headers: BaseStreamingProvider.defaultImageHttpHeaders,
        ),
        width: _coverDecodeTargetWidth,
      );
      final stream = provider.resolve(
        const ImageConfiguration(
          size: Size(
            _coverDecodeTargetWidth * 1.0,
            _coverDecodeTargetWidth * 1.0,
          ),
        ),
      );
      final completer = Completer<ui.Image?>();
      late final ImageStreamListener listener;

      void finish(ui.Image? image) {
        if (identical(_activeImageStream, stream)) {
          _activeImageStream = null;
          _activeImageListener = null;
          _activeImageCompleter = null;
        }
        stream.removeListener(listener);
        if (!completer.isCompleted) {
          completer.complete(image);
        } else {
          image?.dispose();
        }
      }

      listener = ImageStreamListener(
        (ImageInfo info, bool synchronousCall) {
          ui.Image? cloned;
          try {
            cloned = info.image.clone();
          } catch (_) {
            cloned = null;
          } finally {
            info.dispose();
          }
          finish(cloned);
        },
        onError: (Object error, StackTrace? stackTrace) {
          // Safely ignore network errors (including mock HTTP 400 in FLUTTER_TEST).
          finish(null);
        },
      );

      _activeImageStream = stream;
      _activeImageListener = listener;
      _activeImageCompleter = completer;
      stream.addListener(listener);
      return await completer.future;
    } catch (_) {
      return null;
    }
  }

  void _applyDecodedCover(ui.Image nextImage, String sourceKey) {
    if (!mounted) {
      nextImage.dispose();
      return;
    }
    _currArtworkSourceKey = sourceKey;
    if (!widget.enabled) {
      _coverFadeController.stop();
      _coverFadeController.value = 1.0;
      _coverModel.setImmediate(nextImage);
      return;
    }
    _coverModel.beginTransition(nextImage);
    _coverFadeController.forward(from: 0.0);
  }

  void _clearCoverIfPresent() {
    _currArtworkSourceKey = null;
    if (_coverModel.currImage == null && _coverModel.prevImage == null) {
      return;
    }
    if (!widget.enabled) {
      _coverFadeController.stop();
      _coverFadeController.value = 1.0;
      _coverModel.setImmediate(null);
      return;
    }
    if (_coverModel.currImage != null) {
      _coverModel.beginTransition(null);
      _coverFadeController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: widget.enabled,
      child: RepaintBoundary(
        key: widget.repaintBoundaryKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Layer 1: 4-color fluid mesh fallback / base gradient.
            AnimatedBuilder(
              animation: _paletteCurve,
              builder: (context, _) {
                final palette = _currentPalette;
                return CustomPaint(
                  key: widget.meshPainterKey,
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
            // Layer 2: Blurred saturated low-res album cover (CustomPaint only).
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _AmbientCoverPainter(
                    model: _coverModel,
                    progress: _coverFadeAnim,
                    repaint: _coverPaintRepaint,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // Layer 3: Deep charcoal scrim for WCAG AA contrast.
            const Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: LuminaTokens.ambientScrimColor),
              ),
            ),
            // Layer 4: Subtle deterministic 128x128 film grain noise overlay.
            if (_noiseShader != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _NoiseGrainPainter(
                      shader: _noiseShader!,
                      opacity: LuminaTokens.ambientNoiseOpacity,
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

class _CoverFrameModel extends ChangeNotifier {
  ui.Image? prevImage;
  ui.Image? currImage;
  bool _disposed = false;

  void beginTransition(ui.Image? nextImage) {
    if (_disposed) {
      nextImage?.dispose();
      return;
    }
    if (identical(currImage, nextImage) && nextImage != null) {
      return;
    }
    prevImage?.dispose();
    prevImage = currImage;
    currImage = nextImage;
    notifyListeners();
  }

  void setImmediate(ui.Image? nextImage) {
    if (_disposed) {
      nextImage?.dispose();
      return;
    }
    prevImage?.dispose();
    prevImage = null;
    if (!identical(currImage, nextImage)) {
      currImage?.dispose();
      currImage = nextImage;
    }
    notifyListeners();
  }

  void clearPrevious() {
    if (prevImage == null) return;
    prevImage?.dispose();
    prevImage = null;
  }

  void disposeAll() {
    _disposed = true;
    prevImage?.dispose();
    prevImage = null;
    currImage?.dispose();
    currImage = null;
    dispose();
  }
}

class _AmbientCoverPainter extends CustomPainter {
  static const double _sat = LuminaTokens.ambientCoverSaturation;
  static const double _invSat = 1.0 - _sat;
  static const double _lumR = 0.2126;
  static const double _lumG = 0.7152;
  static const double _lumB = 0.0722;

  static const ColorFilter _saturationFilter = ColorFilter.matrix(<double>[
    _invSat * _lumR + _sat,
    _invSat * _lumG,
    _invSat * _lumB,
    0.0,
    0.0,
    _invSat * _lumR,
    _invSat * _lumG + _sat,
    _invSat * _lumB,
    0.0,
    0.0,
    _invSat * _lumR,
    _invSat * _lumG,
    _invSat * _lumB + _sat,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
  ]);

  static final ui.ImageFilter _blurFilter = ui.ImageFilter.blur(
    sigmaX: LuminaTokens.ambientBlurSigma,
    sigmaY: LuminaTokens.ambientBlurSigma,
    tileMode: TileMode.mirror,
  );

  final _CoverFrameModel model;
  final Animation<double> progress;

  _AmbientCoverPainter({
    required this.model,
    required this.progress,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final prev = model.prevImage;
    final curr = model.currImage;
    if (prev == null && curr == null) return;

    final t = progress.value.clamp(0.0, 1.0).toDouble();
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    if (prev != null && t < 1.0) {
      _drawCover(canvas, size, prev, 1.0 - t);
    }
    if (curr != null && t > 0.0) {
      _drawCover(canvas, size, curr, t);
    }

    canvas.restore();
  }

  void _drawCover(Canvas canvas, Size size, ui.Image image, double opacity) {
    final alpha = opacity.clamp(0.0, 1.0).toDouble();
    if (alpha <= 0.001) return;
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    if (imgW <= 0.0 || imgH <= 0.0) return;

    final coverScale =
        math.max(size.width / imgW, size.height / imgH) *
        LuminaTokens.ambientCoverScale;
    final dstW = imgW * coverScale;
    final dstH = imgH * coverScale;
    final dstRect = Rect.fromLTWH(
      (size.width - dstW) / 2.0,
      (size.height - dstH) / 2.0,
      dstW,
      dstH,
    );
    final srcRect = Rect.fromLTWH(0.0, 0.0, imgW, imgH);

    final paint = Paint()
      ..color = Colors.white.withValues(alpha: alpha)
      ..colorFilter = _saturationFilter
      ..imageFilter = _blurFilter
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true;

    canvas.drawImageRect(image, srcRect, dstRect, paint);
  }

  @override
  bool shouldRepaint(covariant _AmbientCoverPainter oldDelegate) {
    return oldDelegate.model != model || oldDelegate.progress != progress;
  }
}

class _NoiseTextureCache {
  static const int _tileSize = 128;
  static final Float64List _identityMatrix = Float64List.fromList(
    const <double>[
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0,
    ],
  );

  static ui.Image? _image;
  static ui.ImageShader? _shader;
  static bool _initialized = false;

  static ui.ImageShader? getOrCreateSync() {
    if (_initialized) return _shader;
    _initialized = true;
    try {
      const bucketCount = 16;
      final buckets = List<List<Offset>>.generate(
        bucketCount,
        (_) => <Offset>[],
      );
      var seed = 0x6A09E667;
      for (var y = 0; y < _tileSize; y++) {
        for (var x = 0; x < _tileSize; x++) {
          seed ^= (seed << 13) & 0xFFFFFFFF;
          seed ^= (seed >> 17);
          seed ^= (seed << 5) & 0xFFFFFFFF;
          final bucket = (seed >> 28) & 0xF;
          buckets[bucket].add(Offset(x + 0.5, y + 0.5));
        }
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()
        ..strokeWidth = 1.0
        ..strokeCap = StrokeCap.square
        ..isAntiAlias = false;

      for (var b = 0; b < bucketCount; b++) {
        final points = buckets[b];
        if (points.isEmpty) continue;
        final shade = (b * 17).clamp(0, 255);
        paint.color = Color.fromARGB(255, shade, shade, shade);
        canvas.drawPoints(ui.PointMode.points, points, paint);
      }

      final picture = recorder.endRecording();
      try {
        final img = picture.toImageSync(_tileSize, _tileSize);
        _image = img;
        _shader = ui.ImageShader(
          img,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          _identityMatrix,
        );
      } finally {
        picture.dispose();
      }
    } catch (_) {
      _image?.dispose();
      _image = null;
      _shader = null;
    }
    return _shader;
  }
}

class _NoiseGrainPainter extends CustomPainter {
  final ui.ImageShader shader;
  final double opacity;

  const _NoiseGrainPainter({
    required this.shader,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..shader = shader
      ..color = Colors.white.withValues(alpha: opacity);
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _NoiseGrainPainter oldDelegate) {
    return oldDelegate.shader != shader || oldDelegate.opacity != opacity;
  }
}
