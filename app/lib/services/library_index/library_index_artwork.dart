part of '../library_index_cache.dart';

extension _LibraryIndexArtwork on LibraryIndexCache {
  Future<String?> _resolveArtworkPathImpl(
    AudioService audioService,
    String targetId, {
    String? path,
    int revision = 0,
    int maxDim = 0,
  }) {
    final cacheKey = (targetId, revision);
    if (_artworkPathCache.containsKey(cacheKey)) {
      return Future.value(_artworkPathCache[cacheKey]);
    }
    final inFlight = _inFlightArtwork[cacheKey];
    if (inFlight != null) return inFlight;

    final future = _fetchAndVerifyArtwork(
      audioService,
      targetId,
      path: path,
      revision: revision,
      maxDim: maxDim,
    ).whenComplete(() {
      _inFlightArtwork.remove(cacheKey);
    });
    _inFlightArtwork[cacheKey] = future;
    return future;
  }

  Future<void> _acquireArtworkSlot(AudioService audioService) async {
    if (_activeArtworkRequests < LibraryIndexCache._maxConcurrentArtworkRequests) {
      _activeArtworkRequests++;
      return;
    }
    final completer = Completer<void>();
    _artworkWaitQueue.addLast(completer);
    await completer.future;
    if (audioService.isNativeBound) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  void _releaseArtworkSlot() {
    while (_artworkWaitQueue.isNotEmpty) {
      final next = _artworkWaitQueue.removeFirst();
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    if (_activeArtworkRequests > 0) {
      _activeArtworkRequests--;
    }
  }

  Future<String?> _fetchAndVerifyArtwork(
    AudioService audioService,
    String targetId, {
    String? path,
    required int revision,
    required int maxDim,
  }) async {
    final epoch = _artworkCacheEpoch;
    // Yield the current build frame before invoking artwork extraction, and
    // yield an inter-frame timer on native FFI builds so transitions stay smooth.
    await Future<void>.microtask(() {});
    if (audioService.isNativeBound) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    if (epoch != _artworkCacheEpoch) return null;

    final cacheKey = (targetId, revision);
    if (_artworkPathCache.containsKey(cacheKey)) {
      return _artworkPathCache[cacheKey];
    }

    await _acquireArtworkSlot(audioService);
    try {
      if (epoch != _artworkCacheEpoch) return null;
      if (_artworkPathCache.containsKey(cacheKey)) {
        return _artworkPathCache[cacheKey];
      }
      final res = await audioService.getArtwork(
        targetId,
        path: path,
        maxDim: maxDim,
      );
      if (epoch != _artworkCacheEpoch) return null;
      if (res != null && res['found'] == true) {
        final cp = res['cache_path']?.toString();
        if (cp != null && cp.isNotEmpty) {
          _artworkPathCache[cacheKey] = cp;
          return cp;
        }
      }
      _artworkPathCache[cacheKey] = null;
      return null;
    } catch (_) {
      return null;
    } finally {
      _releaseArtworkSlot();
    }
  }

  void _evictArtworkImageCache(Iterable<String> paths) {
    if (paths.isEmpty) return;
    try {
      final imageCache = PaintingBinding.instance.imageCache;
      for (final path in paths) {
        if (path.isNotEmpty) {
          imageCache.evict(FileImage(File(path)), includeLive: true);
        }
      }
      imageCache.clear();
      imageCache.clearLiveImages();
    } catch (_) {
      // Safe no-op in pure Dart tests where PaintingBinding is uninitialized.
    }
  }

  void _invalidateArtworkImpl(String targetId) {
    final keysToRemove = _artworkPathCache.keys
        .where((k) => k.$1 == targetId)
        .toList();
    final stalePaths = <String>[];
    for (final k in keysToRemove) {
      final path = _artworkPathCache.remove(k);
      if (path != null && path.isNotEmpty) {
        stalePaths.add(path);
      }
    }
    final flightToRemove = _inFlightArtwork.keys
        .where((k) => k.$1 == targetId)
        .toList();
    for (final k in flightToRemove) {
      _inFlightArtwork.remove(k);
    }
    _artworkCacheEpoch++;
    _evictArtworkImageCache(stalePaths);
  }
}
