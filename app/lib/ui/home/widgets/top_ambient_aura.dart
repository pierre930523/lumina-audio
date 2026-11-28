import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../../models/playback_state.dart';
import '../../../services/artwork_palette_service.dart';
import '../../../services/audio_service.dart';
import '../../../services/library_index_cache.dart';
import '../../common/noise_grain_overlay.dart';
import '../../theme/lumina_glass_theme.dart';

/// Soft, low-saturation ambient gradient anchored along the top edge of
/// [HomeLayoutAJ], feathering smoothly into transparency with zero steady-state
/// animation tickers when idle. When [height] is `null`, fills the entire
/// viewport behind both the top bar and scrollable content to eliminate seams.
class TopAmbientAura extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final ArtworkPaletteService? paletteService;
  final bool followCover;
  final double? height;

  const TopAmbientAura({
    super.key,
    required this.audioService,
    this.libraryCache,
    this.paletteService,
    this.followCover = true,
    this.height,
  });

  @override
  State<TopAmbientAura> createState() => _TopAmbientAuraState();
}

class _TopAmbientAuraState extends State<TopAmbientAura> {
  static const Duration _transitionDuration = Duration(milliseconds: 700);
  static const Curve _transitionCurve = Curves.easeInOutCubic;

  late ArtworkPaletteService _paletteService;
  ui.ImageShader? _noiseShader;
  AmbientPalette? _resolvedPalette;
  String? _lastTrackKey;
  int _resolveSeq = 0;

  StreamSubscription<TrackInfo>? _trackChangedSub;
  StreamSubscription<PlaybackState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _paletteService = widget.paletteService ?? ArtworkPaletteService();
    _noiseShader = NoiseTextureCache.getOrCreateSync();
    _subscribe();
    _refreshForTrack(widget.audioService.currentState.track, force: true);
  }

  @override
  void didUpdateWidget(covariant TopAmbientAura oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paletteService != widget.paletteService) {
      _paletteService = widget.paletteService ?? ArtworkPaletteService();
    }
    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      if (widget.followCover) {
        widget.libraryCache?.addListener(_onLibraryCacheChanged);
      }
    }
    if (oldWidget.audioService != widget.audioService ||
        oldWidget.followCover != widget.followCover) {
      _unsubscribe();
      _subscribe();
      _refreshForTrack(widget.audioService.currentState.track, force: true);
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    if (!widget.followCover) return;
    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _trackChangedSub = widget.audioService.trackChangedStream.listen(
      (track) => _refreshForTrack(track),
    );
    _stateSub = widget.audioService.stateStream.listen(
      (state) => _refreshForTrack(state.track),
    );
  }

  void _unsubscribe() {
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    _trackChangedSub?.cancel();
    _trackChangedSub = null;
    _stateSub?.cancel();
    _stateSub = null;
  }

  void _onLibraryCacheChanged() {
    if (!mounted || !widget.followCover) return;
    _refreshForTrack(widget.audioService.currentState.track, force: true);
  }

  static String _trackKey(TrackInfo? track) {
    if (track == null) return 'none';
    return '${track.responsiveArtworkKey}|'
        '${track.id}|'
        '${track.artworkCacheKey ?? ''}|'
        '${track.coverUrl ?? ''}|'
        '${track.albumArtUrl ?? ''}|'
        '${track.album}';
  }

  void _refreshForTrack(TrackInfo? track, {bool force = false}) {
    if (!widget.followCover || track == null) {
      _lastTrackKey = track == null ? 'none' : _trackKey(track);
      _resolveSeq++;
      if (_resolvedPalette != null && mounted) {
        setState(() => _resolvedPalette = null);
      }
      return;
    }

    final key = _trackKey(track);
    if (!force && key == _lastTrackKey) return;
    _lastTrackKey = key;

    final cached = _lookupCachedSync(track);
    if (cached != null) {
      _resolveSeq++;
      if (_resolvedPalette != cached && mounted) {
        setState(() => _resolvedPalette = cached);
      }
      return;
    }

    final seq = ++_resolveSeq;
    unawaited(
      _paletteService
          .resolvePalette(
            track: track,
            audioService: widget.audioService,
            libraryCache: widget.libraryCache,
          )
          .then((palette) {
            if (!mounted || seq != _resolveSeq || !widget.followCover) return;
            if (_resolvedPalette != palette) {
              setState(() => _resolvedPalette = palette);
            }
          }),
    );
  }

  AmbientPalette? _lookupCachedSync(TrackInfo track) {
    final primary = _paletteService.getCachedSync(
      _paletteService.cacheKeyFor(track: track),
    );
    if (primary != null) return primary;
    final cache = widget.libraryCache;
    if (cache == null) return null;
    if (track.id.isNotEmpty) {
      final path = cache.getArtworkPathSync(track.id);
      if (path != null && path.isNotEmpty) {
        final hit = _paletteService.getCachedSync(
          _paletteService.cacheKeyFor(resolvedCachePath: path),
        );
        if (hit != null) return hit;
      }
    }
    final albumId = cache.resolveAlbumIdForTrack(track);
    if (albumId != null && albumId.isNotEmpty) {
      final hit = _paletteService.getCachedSync('canonical_album:$albumId');
      if (hit != null) return hit;
    }
    return null;
  }

  static Color _softenTint(Color source, {required bool isDark}) {
    final hsl = HSLColor.fromColor(source);
    if (isDark) {
      return hsl
          .withSaturation((hsl.saturation * 0.68).clamp(0.18, 0.45))
          .withLightness((hsl.lightness * 1.9).clamp(0.24, 0.40))
          .toColor();
    }
    return hsl
        .withSaturation((hsl.saturation * 0.65).clamp(0.20, 0.48))
        .withLightness(0.79)
        .toColor();
  }

  (Color primary, Color secondary) _resolveColors(LuminaGlassTheme glass) {
    final palette = widget.followCover ? _resolvedPalette : null;
    if (palette == null) {
      return (glass.auraDefaultPrimary, glass.auraDefaultSecondary);
    }
    return (
      _softenTint(palette.colorA, isDark: glass.isDark),
      _softenTint(palette.colorB, isDark: glass.isDark),
    );
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final (primary, secondary) = _resolveColors(glass);
    final primaryAlpha = glass.isDark ? 0.42 : 0.56;
    final secondaryAlpha = glass.isDark ? 0.34 : 0.48;
    final topWashAlpha = glass.isDark ? 0.16 : 0.24;

    final content = Stack(
      fit: StackFit.expand,
      children: [
        AnimatedContainer(
          duration: _transitionDuration,
          curve: _transitionCurve,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.22, 0.44, 0.64, 1.0],
              colors: [
                primary.withValues(alpha: topWashAlpha),
                secondary.withValues(alpha: topWashAlpha * 0.48),
                primary.withValues(alpha: topWashAlpha * 0.14),
                Colors.transparent,
                Colors.transparent,
              ],
            ),
          ),
        ),
        AnimatedContainer(
          duration: _transitionDuration,
          curve: _transitionCurve,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.46, -0.92),
              radius: 1.05,
              colors: [
                primary.withValues(alpha: primaryAlpha),
                primary.withValues(alpha: primaryAlpha * 0.56),
                primary.withValues(alpha: primaryAlpha * 0.16),
                Colors.transparent,
                Colors.transparent,
              ],
              stops: const [0.0, 0.24, 0.52, 0.72, 1.0],
            ),
          ),
        ),
        AnimatedContainer(
          duration: _transitionDuration,
          curve: _transitionCurve,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.50, -0.84),
              radius: 1.02,
              colors: [
                secondary.withValues(alpha: secondaryAlpha),
                secondary.withValues(alpha: secondaryAlpha * 0.52),
                secondary.withValues(alpha: secondaryAlpha * 0.14),
                Colors.transparent,
                Colors.transparent,
              ],
              stops: const [0.0, 0.22, 0.48, 0.68, 1.0],
            ),
          ),
        ),
        if (_noiseShader != null)
          Positioned.fill(
            child: CustomPaint(
              painter: NoiseGrainPainter(
                shader: _noiseShader!,
                opacity: glass.isDark ? 0.02 : 0.01,
              ),
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );

    return IgnorePointer(
      child: RepaintBoundary(
        child: widget.height != null
            ? SizedBox(
                height: widget.height,
                width: double.infinity,
                child: content,
              )
            : SizedBox.expand(child: content),
      ),
    );
  }
}
