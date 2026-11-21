import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';

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
  final bool circular;
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
    this.circular = false,
    this.uiScale,
    this.onArtworkResolved,
  });

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

  void _emitArtworkResolved({bool forceIfCleared = false}) {
    final cb = widget.onArtworkResolved;
    if (cb == null) return;
    final cp = _resolvedCachePath;
    final cu = _resolvedCoverUrl;
    if (_hasNotifiedArtwork &&
        cp == _lastNotifiedCachePath &&
        cu == _lastNotifiedCoverUrl) {
      return;
    }
    if (!_hasNotifiedArtwork && cp == null && cu == null && !forceIfCleared) {
      return;
    }
    _hasNotifiedArtwork = true;
    _lastNotifiedCachePath = cp;
    _lastNotifiedCoverUrl = cu;
    cb(cp, cu);
  }

  void _scheduleArtworkResolvedPostFrame(
    int token, {
    bool forceIfCleared = false,
  }) {
    if (widget.onArtworkResolved == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _resolveToken) return;
      _emitArtworkResolved(forceIfCleared: forceIfCleared);
    });
  }

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
    return '${trk?.artworkCacheKey ?? ''}|'
        '${trk?.coverUrl ?? ''}|'
        '${trk?.albumArtUrl ?? ''}|'
        '${trk?.filePath ?? ''}|'
        '${trk?.id ?? ''}|'
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
      _hasNotifiedArtwork = false;
      _lastNotifiedCachePath = null;
      _lastNotifiedCoverUrl = null;
      _initAndResolve(notifyIfCleared: hadResolved);
    } else if (oldWidget.onArtworkResolved != widget.onArtworkResolved &&
        widget.onArtworkResolved != null &&
        (_resolvedCachePath != null || _resolvedCoverUrl != null)) {
      _hasNotifiedArtwork = false;
      _scheduleArtworkResolvedPostFrame(_resolveToken);
    }
  }

  @override
  void dispose() {
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    super.dispose();
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final cache = widget.libraryCache;
    if (cache == null) return;
    final id = _targetId;
    final albId = widget.album?.id;
    final canCheckAlbumFallback =
        widget.track != null &&
        albId != null &&
        albId.isNotEmpty &&
        !_hasDistinctTrackUrl;

    String? cachedPath;
    String? sourceId;
    if (id != null) {
      final p = cache.getArtworkPathSync(id, revision: widget.revision);
      if (p != null && p.isNotEmpty) {
        cachedPath = p;
        sourceId = id;
      }
    }
    if (cachedPath == null && canCheckAlbumFallback) {
      final p = cache.getArtworkPathSync(albId, revision: widget.revision);
      if (p != null && p.isNotEmpty) {
        cachedPath = p;
        sourceId = albId;
      }
    }

    if (cachedPath != null) {
      if (cachedPath != _resolvedCachePath) {
        setState(() {
          _resolvedCachePath = cachedPath;
          _resolvedSourceId = sourceId;
          _resolvedCoverUrl = null;
        });
        _emitArtworkResolved(forceIfCleared: true);
      }
      return;
    }

    final checkId = _resolvedSourceId ?? id;
    if (_resolvedCachePath != null &&
        checkId != null &&
        !cache.hasArtworkCached(checkId, revision: widget.revision)) {
      setState(() {
        _resolvedCachePath = null;
        _resolvedSourceId = null;
      });
      _emitArtworkResolved(forceIfCleared: true);
      _initAndResolve();
    }
  }

  void _initAndResolve({bool notifyIfCleared = false}) {
    final token = ++_resolveToken;
    final trk = widget.track;
    final alb = widget.album;
    final albId = alb?.id;
    final hasValidAlbId = albId != null && albId.isNotEmpty;
    final targetId = _targetId;
    final cache = widget.libraryCache;

    // 1. Synchronous in-memory cache hit for frame-0 rendering.
    if (cache != null) {
      if (targetId != null) {
        final cachedPath = cache.getArtworkPathSync(
          targetId,
          revision: widget.revision,
        );
        if (cachedPath != null && cachedPath.isNotEmpty) {
          _resolvedCachePath = cachedPath;
          _resolvedSourceId = targetId;
          _resolvedCoverUrl = null;
          _scheduleArtworkResolvedPostFrame(token);
          return;
        }
      }
      if (trk != null && hasValidAlbId && !_hasDistinctTrackUrl) {
        final albumCachedPath = cache.getArtworkPathSync(
          albId,
          revision: widget.revision,
        );
        if (albumCachedPath != null && albumCachedPath.isNotEmpty) {
          _resolvedCachePath = albumCachedPath;
          _resolvedSourceId = albId;
          _resolvedCoverUrl = null;
          _scheduleArtworkResolvedPostFrame(token);
          return;
        }
      }
    }

    // 2. Direct HTTP/HTTPS URL or local file path candidate.
    final directUrl = _firstNonEmpty([
      trk?.coverUrl,
      trk?.albumArtUrl,
      alb?.coverUrl,
    ]);
    if (directUrl != null) {
      if (directUrl.startsWith('http://') || directUrl.startsWith('https://')) {
        _resolvedCoverUrl = directUrl;
        _scheduleArtworkResolvedPostFrame(token);
      } else if (!directUrl.startsWith('/api/')) {
        // Verify local file path off the build() path via microtask.
        Future.microtask(() {
          if (!mounted || token != _resolveToken) return;
          if (File(directUrl).existsSync()) {
            if (targetId != null && cache != null) {
              cache.setArtworkPathSync(
                targetId,
                directUrl,
                revision: widget.revision,
              );
            }
            if (directUrl != _resolvedCachePath) {
              setState(() {
                _resolvedCachePath = directUrl;
                _resolvedSourceId = targetId;
                _resolvedCoverUrl = null;
              });
              _emitArtworkResolved(forceIfCleared: true);
            }
          }
        });
      }
    }

    if (notifyIfCleared &&
        _resolvedCachePath == null &&
        _resolvedCoverUrl == null) {
      _scheduleArtworkResolvedPostFrame(token, forceIfCleared: true);
    }

    // 3. Asynchronous artwork resolution via LibraryIndexCache (deduplicated)
    // or AudioService fallback scheduled after frame 0.
    final svc = widget.audioService;
    if (svc != null) {
      final canTryAlbumFirst = hasValidAlbId && (trk == null || !_hasDistinctTrackUrl);
      if (cache != null) {
        if (canTryAlbumFirst) {
          _resolveViaAlbumThenTrack(
            svc: svc,
            cache: cache,
            albumId: albId,
            track: trk,
            token: token,
          );
        } else if (targetId != null &&
            !cache.hasArtworkCached(targetId, revision: widget.revision)) {
          _resolveCachedTarget(
            svc: svc,
            cache: cache,
            resolveId: targetId,
            filePath: trk?.filePath,
            token: token,
          );
        }
      } else {
        if (canTryAlbumFirst) {
          _resolveWithoutCacheAlbumThenTrack(
            svc: svc,
            albumId: albId,
            track: trk,
            token: token,
          );
        } else if (targetId != null) {
          _resolveWithoutCache(
            svc: svc,
            resolveId: targetId,
            filePath: trk?.filePath,
            token: token,
          );
        }
      }
    }
  }

  Future<void> _resolveViaAlbumThenTrack({
    required AudioService svc,
    required LibraryIndexCache cache,
    required String albumId,
    required TrackInfo? track,
    required int token,
  }) async {
    if (!cache.hasArtworkCached(albumId, revision: widget.revision)) {
      try {
        final albumPath = await cache.resolveArtworkPath(
          svc,
          albumId,
          revision: widget.revision,
          maxDim: 0,
        );
        if (!mounted || token != _resolveToken) return;
        if (albumPath != null && albumPath.isNotEmpty) {
          if (albumPath != _resolvedCachePath) {
            setState(() {
              _resolvedCachePath = albumPath;
              _resolvedSourceId = albumId;
              _resolvedCoverUrl = null;
            });
            _emitArtworkResolved(forceIfCleared: true);
          }
          return;
        }
      } catch (_) {}
    }

    if (track != null &&
        track.id.isNotEmpty &&
        !cache.hasArtworkCached(track.id, revision: widget.revision)) {
      await _resolveCachedTarget(
        svc: svc,
        cache: cache,
        resolveId: track.id,
        filePath: track.filePath,
        token: token,
      );
    }
  }

  Future<void> _resolveCachedTarget({
    required AudioService svc,
    required LibraryIndexCache cache,
    required String resolveId,
    String? filePath,
    required int token,
  }) async {
    try {
      final cp = await cache.resolveArtworkPath(
        svc,
        resolveId,
        path: filePath,
        revision: widget.revision,
        maxDim: 0,
      );
      if (!mounted || token != _resolveToken) return;
      if (cp != null && cp.isNotEmpty && cp != _resolvedCachePath) {
        setState(() {
          _resolvedCachePath = cp;
          _resolvedSourceId = resolveId;
          _resolvedCoverUrl = null;
        });
        _emitArtworkResolved(forceIfCleared: true);
      }
    } catch (_) {}
  }

  Future<void> _resolveWithoutCacheAlbumThenTrack({
    required AudioService svc,
    required String albumId,
    required TrackInfo? track,
    required int token,
  }) async {
    await Future<void>.microtask(() {});
    if (svc.isNativeBound) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    if (!mounted || token != _resolveToken) return;
    final foundFromAlbum = await _fetchUncachedArtwork(
      svc: svc,
      resolveId: albumId,
      token: token,
    );
    if (foundFromAlbum || !mounted || token != _resolveToken) return;
    if (track != null && track.id.isNotEmpty) {
      await _fetchUncachedArtwork(
        svc: svc,
        resolveId: track.id,
        filePath: track.filePath,
        token: token,
      );
    }
  }

  Future<void> _resolveWithoutCache({
    required AudioService svc,
    required String resolveId,
    String? filePath,
    required int token,
  }) async {
    await Future<void>.microtask(() {});
    if (svc.isNativeBound) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    if (!mounted || token != _resolveToken) return;
    await _fetchUncachedArtwork(
      svc: svc,
      resolveId: resolveId,
      filePath: filePath,
      token: token,
    );
  }

  Future<bool> _fetchUncachedArtwork({
    required AudioService svc,
    required String resolveId,
    String? filePath,
    required int token,
  }) async {
    try {
      final res = await svc.getArtwork(
        resolveId,
        path: filePath,
        maxDim: 0,
      );
      if (!mounted || token != _resolveToken) return false;
      if (res != null && res['found'] == true) {
        final cp = res['cache_path']?.toString();
        if (cp != null && cp.isNotEmpty && File(cp).existsSync()) {
          if (cp != _resolvedCachePath) {
            setState(() {
              _resolvedCachePath = cp;
              _resolvedSourceId = resolveId;
              _resolvedCoverUrl = null;
            });
            _emitArtworkResolved(forceIfCleared: true);
          }
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Widget _buildPlaceholder(BorderRadius radius) {
    if (widget.placeholder != null) {
      return widget.circular
          ? ClipOval(child: widget.placeholder!)
          : widget.placeholder!;
    }
    final iconSize = (widget.size * 0.44).clamp(16.0, 120.0).toDouble();

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circular ? null : radius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF1F4B6E),
            Color(0xFF4F46E5),
            Color(0xFF0F172A),
          ],
        ),
      ),
      child: widget.showPlaceholderIcon
          ? Center(
              child: Icon(
                widget.circular ? Icons.person_rounded : Icons.album_rounded,
                size: iconSize,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final radius =
        widget.borderRadius ?? BorderRadius.circular(widget.size > 80 ? 12 : 6);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final double effectiveScale =
        (widget.uiScale == null && UiScaleScope.isAppliedToMediaQuery(context))
            ? 1.0
            : (widget.uiScale ?? UiScaleScope.maybeOf(context));
    final int? targetCacheWidth = widget.fullResolution
        ? null
        : (widget.size * dpr * effectiveScale).ceil().clamp(128, 2048);

    Widget imageContent;
    if (_resolvedCachePath != null && _resolvedCachePath!.isNotEmpty) {
      imageContent = Image.file(
        File(_resolvedCachePath!),
        key: ValueKey('cover_file_${_resolvedCachePath!}'),
        width: widget.size,
        height: widget.size,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        cacheWidth: targetCacheWidth,
        errorBuilder: (_, _, _) => _buildPlaceholder(radius),
      );
    } else if (_resolvedCoverUrl != null && _resolvedCoverUrl!.isNotEmpty) {
      imageContent = Image.network(
        _resolvedCoverUrl!,
        key: ValueKey('cover_net_${_resolvedCoverUrl!}'),
        width: widget.size,
        height: widget.size,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        cacheWidth: targetCacheWidth,
        errorBuilder: (_, _, _) => _buildPlaceholder(radius),
      );
    } else {
      imageContent = _buildPlaceholder(radius);
    }

    final wrappedContent = AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: KeyedSubtree(
        key: ValueKey(
          'art_img_${_resolvedCachePath ?? _resolvedCoverUrl ?? "placeholder"}',
        ),
        child: imageContent,
      ),
    );

    return Container(
      key: ValueKey('artwork_container_$_currentKey'),
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circular ? null : radius,
        border: widget.border ??
            Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
        boxShadow: widget.boxShadow ??
            (widget.size > 80
                ? const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 28,
                      offset: Offset(0, 10),
                    ),
                  ]
                : null),
      ),
      child: widget.circular
          ? ClipOval(child: wrappedContent)
          : ClipRRect(
              borderRadius: radius,
              child: wrappedContent,
            ),
    );
  }
}
