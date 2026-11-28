part of '../streaming_manager.dart';

extension _StreamingManagerResolutionExt on StreamingManager {
  void _handleNetworkEpochChangedImpl(int newEpoch) {
    if (_disposed) return;
    final previous = l1Cache.networkEpoch;
    final updated = l1Cache.syncNetworkEpoch(newEpoch);
    if (updated == previous) return;

    final ytm = youTubeMusicProvider;
    if (ytm != null) {
      ytm.handleNetworkEpochChanged();
      if (_enableLiveWarmup) {
        unawaited(ytm.warmup(force: true).catchError((_) {}));
      }
    }
  }

  Future<StreamingCatalog> _syncProviderImpl(
    String kind, {
    CancellationToken? cancel,
  }) async {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }
    var retriedAuth = false;
    while (true) {
      try {
        final catalog = await provider.syncLibrary(cancel: cancel);
        _safeNotify();
        final hook = onCatalogSynced;
        if (hook != null && !catalog.isEmpty) {
          unawaited(
            Future<void>.sync(() => hook(kind, catalog)).catchError((_) {}),
          );
        }
        return catalog;
      } on StreamingException catch (e) {
        if (!e.isCancelled && AuthManager.isUnauthorizedError(e)) {
          final refreshed = await authManager.handleUnauthorized(
            kind,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            continue;
          }
        }
        _safeNotify();
        rethrow;
      } catch (_) {
        _safeNotify();
        rethrow;
      }
    }
  }

  StreamingProvider? _resolveProviderForTrackImpl(TrackInfo track) {
    for (final kind in StreamingManager.providerOrder) {
      final meta = StreamingProviderMeta.byKind(kind);
      if (meta != null && meta.matchesTrackProvider(track.providerName)) {
        return _providers[kind];
      }
    }
    final id = track.id;
    if (id.startsWith('apple:')) return _providers['apple_music'];
    final isExternalRss = id.startsWith('podcast_rss:') ||
        id.startsWith('streaming:podcast_rss:') ||
        id.startsWith('rss:') ||
        id.startsWith('http://') ||
        id.startsWith('https://');
    if (isExternalRss) {
      return null;
    }
    if (id.startsWith('ytm:') ||
        id.startsWith('ytm_') ||
        id.startsWith('streaming:youtube_music:') ||
        id.startsWith('youtube_music:') ||
        track.providerName == 'Podcast') {
      return _providers['youtube_music'];
    }
    if (id.startsWith('qobuz:')) return _providers['qobuz'];
    if (id.startsWith('tidal:')) return _providers['tidal'];
    if (id.startsWith('deezer:')) return _providers['deezer'];
    return null;
  }

  void _clearStreamCacheImpl(TrackInfo track) {
    try {
      final key = resolverRegistry.deriveKey(track);
      l1Cache.evictTrack(key.providerId, key.trackId);
    } catch (_) {}
    final provider = resolveProviderForTrack(track);
    if (provider is YouTubeMusicProvider) {
      provider.clearStreamCache(track.id);
    }
    final vid = YouTubeMusicProvider.tryExtractCleanVideoId(
      track.id,
      filePath: track.filePath,
    );
    if (vid != null) {
      ytDlpService.clearCache(vid);
    }
  }

  Future<StreamSourceSpec> _resolveSourceSpecImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
    bool bypassCache = false,
    TrackInfo? legacyTrack,
  }) async {
    cancelToken?.throwIfCancelled();
    final provider = _providers[key.providerId];
    if (authManager.isPlaybackAuthBlocked(key.providerId)) {
      throw StreamingException(
        authManager.authErrorFor(key.providerId) ??
            '${provider?.meta.name ?? key.providerId} 授權已失效，請重新登入',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (provider != null && !_isBrowsable(provider)) {
      throw StreamingException(
        '${provider.meta.name} 尚未登入或授權已失效，無法解析串流',
      );
    }
    var retriedAuth = false;
    while (true) {
      try {
        return await singleFlightResolver.resolve(
          key,
          cancelToken: cancelToken,
          bypassCache: bypassCache || retriedAuth,
          legacyTrack: legacyTrack,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(key.providerId)) {
          final refreshed = await authManager.handleUnauthorized(
            key.providerId,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            cancelToken?.throwIfCancelled();
            continue;
          }
        }
        rethrow;
      }
    }
  }

  Future<StreamSourceSpec?> _prefetchSourceSpecImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
    TrackInfo? legacyTrack,
  }) async {
    if (_disposed || cancelToken?.isCancelled == true) return null;
    if (authManager.isPlaybackAuthBlocked(key.providerId)) return null;
    final provider = _providers[key.providerId];
    if (provider != null && !_isBrowsable(provider)) {
      return null;
    }
    var retriedAuth = false;
    while (true) {
      try {
        return await singleFlightResolver.prefetch(
          key,
          cancelToken: cancelToken,
          legacyTrack: legacyTrack,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(key.providerId)) {
          final refreshed = await authManager.handleUnauthorized(
            key.providerId,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed &&
              !retriedAuth &&
              !_disposed &&
              cancelToken?.isCancelled != true) {
            retriedAuth = true;
            continue;
          }
        }
        return null;
      } catch (_) {
        return null;
      }
    }
  }

  Future<ResolvedStreamResult> _resolveStreamForTrackImpl(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    bool bypassCache = false,
  }) async {
    cancel?.throwIfCancelled();
    final provider = resolveProviderForTrack(track);
    if (provider == null) {
      throw StreamingException(
        '找不到對應的串流服務提供者（${track.providerName}）',
      );
    }
    if (authManager.isPlaybackAuthBlocked(provider.kind)) {
      throw StreamingException(
        authManager.authErrorFor(provider.kind) ??
            '${provider.meta.name} 授權已失效，請重新登入',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (!_isBrowsable(provider)) {
      throw StreamingException(
        '${provider.meta.name} 尚未登入或授權已失效，無法解析串流',
      );
    }
    var retriedAuth = false;
    while (true) {
      try {
        if (provider is YouTubeMusicProvider) {
          return await provider.resolveStream(
            track,
            cancel: cancel,
            timeout: timeout ?? const Duration(seconds: 15),
            playRequestId: playRequestId,
            bypassCache: bypassCache || retriedAuth,
          );
        }
        return await provider.resolveStream(
          track,
          cancel: cancel,
          timeout: timeout ?? const Duration(seconds: 15),
          playRequestId: playRequestId,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(provider.kind)) {
          final refreshed = await authManager.handleUnauthorized(
            provider.kind,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            cancel?.throwIfCancelled();
            continue;
          }
        }
        rethrow;
      }
    }
  }

  Future<StreamSourceSpec> _resolveSourceSpecForTrackImpl(
    TrackInfo track, {
    String qualityKey = 'default',
    CancellationToken? cancel,
    bool bypassCache = false,
    bool useL1Cache = false,
  }) async {
    cancel?.throwIfCancelled();
    final key = resolverRegistry.deriveKey(track, qualityKey: qualityKey);
    if (useL1Cache) {
      return resolveSourceSpec(
        key,
        cancelToken: cancel,
        bypassCache: bypassCache,
        legacyTrack: track,
      );
    }
    final provider = _providers[key.providerId];
    if (authManager.isPlaybackAuthBlocked(key.providerId)) {
      throw StreamingException(
        authManager.authErrorFor(key.providerId) ??
            '${provider?.meta.name ?? key.providerId} 授權已失效，請重新登入',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (provider != null && !_isBrowsable(provider)) {
      throw StreamingException(
        '${provider.meta.name} 尚未登入或授權已失效，無法解析串流',
      );
    }
    var retriedAuth = false;
    while (true) {
      try {
        return await resolverRegistry.resolveTrack(
          track,
          qualityKey: qualityKey,
          cancelToken: cancel,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(key.providerId)) {
          final refreshed = await authManager.handleUnauthorized(
            key.providerId,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            cancel?.throwIfCancelled();
            continue;
          }
        }
        rethrow;
      }
    }
  }
}
