import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/streaming/streaming_provider.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/smooth_scroll.dart';

part 'album_artwork_resolution.dart';
part 'album_artwork_renderer.dart';

/// Reusable Album Artwork View with strict Artwork Cache keying, zero-flash
/// synchronous [LibraryIndexCache] lookups, gapless image decoding, HiDPI
/// decode sizing, and non-blocking asynchronous artwork verification.
class AlbumArtworkView extends StatefulWidget {
  final TrackInfo? track;
  final CanonicalAlbumSummary? album;
  final double size;
  final BorderRadius? borderRadius;
  final BoxFit fit;
  final AudioService? audioService;
  final LibraryIndexCache? libraryCache;
  final bool showPlaceholderIcon;
  final Widget? placeholder;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;
  final int revision;
  final bool fullResolution;
  final int? coverTargetSize;
  final bool circular;
  final bool frameless;
  final double? uiScale;
  final void Function(String? cachePath, String? coverUrl)? onArtworkResolved;

  const AlbumArtworkView({
    super.key,
    this.track,
    this.album,
    this.size = 48.0,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.audioService,
    this.libraryCache,
    this.showPlaceholderIcon = true,
    this.placeholder,
    this.border,
    this.boxShadow,
    this.revision = 0,
    this.fullResolution = true,
    this.coverTargetSize,
    this.circular = false,
    this.frameless = false,
    this.uiScale,
    this.onArtworkResolved,
  });

  /// Resolves the scene-tiered streaming cover pixel target size.
  static int resolveCoverTargetSize({
    required double size,
    required bool fullResolution,
    int? explicitTargetSize,
  }) {
    if (explicitTargetSize != null && explicitTargetSize > 0) {
      return explicitTargetSize;
    }
    if (fullResolution && size >= 120) {
      return 1200;
    }
    if (size >= 100) {
      return 600;
    }
    return 300;
  }

  static final RegExp _tidalCoverSizeRegex = RegExp(
    r'^(https?://resources\.tidal\.com/images/.+/)(?:80x80|160x160|320x320|640x640)(\.jpg(?:\?.*)?)$',
    caseSensitive: false,
  );

  /// Upgrades smaller Tidal cover URLs to 1280x1280 for large full-resolution views.
  static String maybeUpgradeTidalLargeCoverUrl(
    String url, {
    required double size,
    required bool fullResolution,
  }) {
    if (!fullResolution || size < 160) return url;
    return url.replaceFirstMapped(
      _tidalCoverSizeRegex,
      (match) => '${match.group(1)}1280x1280${match.group(2)}',
    );
  }

  @override
  State<AlbumArtworkView> createState() => _AlbumArtworkViewState();
}

class _AlbumArtworkViewState extends State<AlbumArtworkView> {
  String? _resolvedCachePath;
  String? _resolvedCoverUrl;
  String? _resolvedSourceId;
  int _resolveToken = 0;
  String? _lastNotifiedCachePath;
  String? _lastNotifiedCoverUrl;
  bool _hasNotifiedArtwork = false;
  bool _highResFallbackActive = false;

  void _setState(VoidCallback fn) => setState(fn);

  String? get _targetId {
    final trk = widget.track;
    if (trk != null && trk.id.isNotEmpty) return trk.id;
    final albId = widget.album?.id;
    if (albId != null && albId.isNotEmpty) return albId;
    return null;
  }

  bool get _hasDistinctTrackUrl {
    final trk = widget.track;
    if (trk == null) return false;
    final albUrl = widget.album?.coverUrl?.trim();
    for (final candidate in [trk.coverUrl, trk.albumArtUrl]) {
      final url = candidate?.trim();
      if (url != null && url.isNotEmpty && url != albUrl) {
        return true;
      }
    }
    return false;
  }

  String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  String get _currentKey {
    final trk = widget.track;
    final alb = widget.album;
    return trk?.artworkCacheKey ??
        trk?.responsiveArtworkKey ??
        trk?.coverUrl ??
        trk?.albumArtUrl ??
        trk?.filePath ??
        trk?.id ??
        alb?.coverUrl ??
        alb?.id ??
        'placeholder';
  }

  String _resolveSignature(AlbumArtworkView w) {
    final trk = w.track;
    final alb = w.album;
    return '${trk?.responsiveArtworkKey ?? ''}|'
        '${trk?.artworkCacheKey ?? ''}|'
        '${trk?.coverUrl ?? ''}|'
        '${trk?.albumArtUrl ?? ''}|'
        '${trk?.filePath ?? ''}|'
        '${trk?.id ?? ''}|'
        '${trk?.providerName ?? ''}|'
        '${trk?.title ?? ''}|'
        '${alb?.coverUrl ?? ''}|'
        '${alb?.id ?? ''}|'
        '${w.audioService?.hashCode ?? 0}|'
        '${w.libraryCache?.hashCode ?? 0}|'
        '${w.revision}';
  }

  @override
  void initState() {
    super.initState();
    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _initAndResolve();
  }

  @override
  void didUpdateWidget(covariant AlbumArtworkView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      widget.libraryCache?.addListener(_onLibraryCacheChanged);
    }
    if (_resolveSignature(oldWidget) != _resolveSignature(widget)) {
      final hadResolved =
          _resolvedCachePath != null || _resolvedCoverUrl != null;
      _resolvedCachePath = null;
      _resolvedCoverUrl = null;
      _resolvedSourceId = null;
      _highResFallbackActive = false;
      _hasNotifiedArtwork = false;
      _lastNotifiedCachePath = null;
      _lastNotifiedCoverUrl = null;
      _initAndResolve(notifyIfCleared: hadResolved);
    } else {
      if (oldWidget.coverTargetSize != widget.coverTargetSize ||
          oldWidget.fullResolution != widget.fullResolution ||
          AlbumArtworkView.resolveCoverTargetSize(
                size: oldWidget.size,
                fullResolution: oldWidget.fullResolution,
                explicitTargetSize: oldWidget.coverTargetSize,
              ) !=
              AlbumArtworkView.resolveCoverTargetSize(
                size: widget.size,
                fullResolution: widget.fullResolution,
                explicitTargetSize: widget.coverTargetSize,
              )) {
        _highResFallbackActive = false;
      }
      if (oldWidget.onArtworkResolved != widget.onArtworkResolved &&
          widget.onArtworkResolved != null &&
          (_resolvedCachePath != null || _resolvedCoverUrl != null)) {
        _hasNotifiedArtwork = false;
        _scheduleArtworkResolvedPostFrame(_resolveToken);
      }
    }
  }

  @override
  void dispose() {
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildArtworkWidget(context);
}
