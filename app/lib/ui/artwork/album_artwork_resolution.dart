part of 'album_artwork_view.dart';

extension _AlbumArtworkResolution on _AlbumArtworkViewState {
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
        _setState(() {
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
      _setState(() {
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
      final normalizedNetUrl = BaseStreamingProvider.normalizeCoverUrl(directUrl);
      if (normalizedNetUrl != null) {
        _resolvedCoverUrl = normalizedNetUrl;
        _scheduleArtworkResolvedPostFrame(token);
      } else if (!directUrl.startsWith('/api/') &&
          !directUrl.startsWith('http://') &&
          !directUrl.startsWith('https://') &&
          !directUrl.startsWith('//')) {
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
              _setState(() {
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
      final canTryAlbumFirst =
          hasValidAlbId && (trk == null || !_hasDistinctTrackUrl);
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
            _setState(() {
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
        _setState(() {
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
            _setState(() {
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
}
