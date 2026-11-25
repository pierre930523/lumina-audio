import 'package:flutter/foundation.dart';

import '../../models/recommendation_models.dart';
import '../../models/streaming_models.dart';
import '../recommendation_settings_controller.dart';
import 'recommendation_provider.dart';
import 'track_matcher.dart';

class _CachedRouteEntry {
  final TrackMetadata track;
  final DateTime expiresAt;

  const _CachedRouteEntry({
    required this.track,
    required this.expiresAt,
  });
}

/// Routes candidate tracks across local library and streaming providers by
/// user-configured priority order, enforcing strict HTTP 401 circuit-breaker
/// skipping and short-TTL LRU caching.
class CrossPlatformTrackRouter {
  static const Set<String> _playableProviderIds = <String>{
    'local',
    'youtube_music',
    'tidal',
    'qobuz',
    'deezer',
    'apple_music',
  };

  final RecommendationProvider? Function(String providerId) providerLookup;
  final StreamingAuthState Function(String providerId) authStateLookup;
  final bool Function(String providerId) isAuthRequiredLookup;
  final bool Function(String providerId) isPlaybackAuthBlockedLookup;
  final bool Function(String providerId) isGuestCapableLookup;
  final Future<TrackMetadata?> Function(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  })? localMatcher;
  final List<String> Function() priorityOrderProvider;
  final DateTime Function() _clock;
  final Duration cacheTtl;
  final int maxCacheEntries;

  // Dart's default Map preserves insertion order; we remove & re-insert on hit
  // so the oldest entry (`_cache.keys.first`) is always the LRU entry.
  final Map<String, _CachedRouteEntry> _cache = <String, _CachedRouteEntry>{};

  CrossPlatformTrackRouter({
    required this.providerLookup,
    StreamingAuthState Function(String providerId)? authStateLookup,
    bool Function(String providerId)? isAuthRequiredLookup,
    bool Function(String providerId)? isPlaybackAuthBlockedLookup,
    bool Function(String providerId)? isGuestCapableLookup,
    this.localMatcher,
    List<String> Function()? priorityOrderProvider,
    DateTime Function()? clock,
    this.cacheTtl = const Duration(minutes: 30),
    this.maxCacheEntries = 500,
  }) : authStateLookup =
           authStateLookup ?? ((_) => StreamingAuthState.disconnected),
       isAuthRequiredLookup = isAuthRequiredLookup ?? ((_) => false),
       isPlaybackAuthBlockedLookup =
           isPlaybackAuthBlockedLookup ?? ((_) => false),
       isGuestCapableLookup =
           isGuestCapableLookup ?? ((pid) => pid == 'youtube_music'),
       priorityOrderProvider =
           priorityOrderProvider ??
           (() => RecommendationSettingsController.defaultPlatformPriority),
       _clock = clock ?? DateTime.now;

  void clearCache() => _cache.clear();

  @visibleForTesting
  int get cacheLength => _cache.length;

  static bool isPlayableProviderId(String providerId) =>
      _playableProviderIds.contains(providerId.trim().toLowerCase());

  bool _isProviderUnblockedAndEligible(String providerId) {
    final pid = providerId.trim().toLowerCase();
    if (!isPlayableProviderId(pid)) return false;
    if (isAuthRequiredLookup(pid) || isPlaybackAuthBlockedLookup(pid)) {
      return false;
    }
    if (pid == 'local') return true;
    if (isGuestCapableLookup(pid)) return true;
    return authStateLookup(pid) == StreamingAuthState.connected;
  }

  static bool _isCancellation(Object error, CancellationToken? cancel) {
    if (cancel?.isCancelled == true) return true;
    if (error is RecError && error.kind == RecErrorKind.cancelled) return true;
    if (error is StreamingException && error.isCancelled) return true;
    return false;
  }

  static bool _isUnauthorizedFailure(Object error) {
    if (error is RecError && error.kind == RecErrorKind.authRequired) {
      return true;
    }
    if (error is StreamingException &&
        !error.isCancelled &&
        (error.statusCode == 401 || error.isTokenExpired)) {
      return true;
    }
    return false;
  }

  String _buildCacheKey(
    TrackMetadata candidate,
    List<String> priorityOrder, {
    required bool crossPlatformEnabled,
  }) {
    final normIsrc = TrackMatcher.normalizeIsrc(candidate.isrc);
    final String identityKey;
    if (normIsrc != null) {
      identityKey = 'isrc:$normIsrc';
    } else {
      final normTitle = TrackMatcher.normalizeTitleForMatching(candidate.title);
      final rawPrimary = candidate.primaryArtist.trim().isNotEmpty
          ? candidate.primaryArtist
          : TrackMatcher.extractPrimaryArtist(candidate.artist);
      final normArtist = TrackMatcher.normalizeArtistForMatching(rawPrimary);
      final durationBucket = candidate.durationMs > 0
          ? candidate.durationMs ~/ 2000
          : 0;
      if (normTitle.isNotEmpty || normArtist.isNotEmpty) {
        identityKey = 'meta:$normTitle|$normArtist|$durationBucket';
      } else {
        identityKey = 'raw:${candidate.providerId}:${candidate.trackId}';
      }
    }

    final signatureIds = <String>{
      ...priorityOrder.map((e) => e.trim().toLowerCase()),
      candidate.providerId.trim().toLowerCase(),
    }..removeWhere((e) => e.isEmpty);

    final authSig = (signatureIds.toList()..sort())
        .map((pid) {
          final auth = authStateLookup(pid).name;
          final ar = isAuthRequiredLookup(pid) ? 1 : 0;
          final pb = isPlaybackAuthBlockedLookup(pid) ? 1 : 0;
          final gc = isGuestCapableLookup(pid) ? 1 : 0;
          return '$pid:$auth:$ar:$pb:$gc';
        })
        .join(';');

    final mode = crossPlatformEnabled ? 'cross' : 'direct';
    return '$mode|$identityKey|${priorityOrder.join(",")}|$authSig';
  }

  TrackMetadata? _getCached(String cacheKey) {
    if (cacheTtl <= Duration.zero || maxCacheEntries <= 0) return null;
    final entry = _cache[cacheKey];
    if (entry == null) return null;
    if (!_clock().isBefore(entry.expiresAt)) {
      _cache.remove(cacheKey);
      return null;
    }
    // Refresh LRU order.
    _cache.remove(cacheKey);
    _cache[cacheKey] = entry;
    return entry.track;
  }

  void _putCached(String cacheKey, TrackMetadata resolved) {
    if (cacheTtl <= Duration.zero || maxCacheEntries <= 0) return;
    if (_cache.containsKey(cacheKey)) {
      _cache.remove(cacheKey);
    } else {
      while (_cache.length >= maxCacheEntries) {
        _cache.remove(_cache.keys.first);
      }
    }
    _cache[cacheKey] = _CachedRouteEntry(
      track: resolved,
      expiresAt: _clock().add(cacheTtl),
    );
  }

  static TrackMetadata _enrichMatchedMetadata(
    TrackMetadata matched,
    TrackMetadata candidate,
  ) {
    final matchedCover = matched.coverUrl?.trim();
    final candidateCover = candidate.coverUrl?.trim();
    final needsCover = (matchedCover == null || matchedCover.isEmpty) &&
        candidateCover != null &&
        candidateCover.isNotEmpty;

    final matchedAlbum = matched.album.trim();
    final candidateAlbum = candidate.album.trim();
    final needsAlbum = matchedAlbum.isEmpty && candidateAlbum.isNotEmpty;

    if (!needsCover && !needsAlbum) return matched;
    return matched.copyWith(
      coverUrl: needsCover ? candidateCover : null,
      album: needsAlbum ? candidateAlbum : null,
    );
  }

  /// Resolves [candidate] to the highest-priority playable [TrackMetadata].
  ///
  /// When [crossPlatformEnabled] is `false`, returns [candidate] directly if its
  /// own provider is playable and unblocked; otherwise falls back to priority
  /// routing.
  Future<TrackMetadata?> resolveBestPlayableTrack(
    TrackMetadata candidate, {
    required bool crossPlatformEnabled,
    CancellationToken? cancel,
  }) async {
    if (cancel?.isCancelled == true) return null;

    final candidatePid = candidate.providerId.trim().toLowerCase();
    if (!crossPlatformEnabled && _isProviderUnblockedAndEligible(candidatePid)) {
      return candidate;
    }

    final order = priorityOrderProvider();
    final cacheKey = _buildCacheKey(
      candidate,
      order,
      crossPlatformEnabled: crossPlatformEnabled,
    );
    if (crossPlatformEnabled) {
      final cached = _getCached(cacheKey);
      if (cached != null) return _enrichMatchedMetadata(cached, candidate);
    }

    final query = TrackMatchQuery.fromTrackMetadata(candidate);

    for (final rawPid in order) {
      if (cancel?.isCancelled == true) return null;
      final pid = rawPid.trim().toLowerCase();
      if (pid.isEmpty) continue;

      if (pid == 'local') {
        if (candidatePid == 'local' &&
            candidate.filePath != null &&
            candidate.filePath!.trim().isNotEmpty) {
          if (crossPlatformEnabled) _putCached(cacheKey, candidate);
          return candidate;
        }
        final matcher = localMatcher;
        if (matcher != null) {
          try {
            final localHit = await matcher(query, cancel: cancel);
            if (cancel?.isCancelled == true) return null;
            if (localHit != null) {
              final enriched = _enrichMatchedMetadata(localHit, candidate);
              if (crossPlatformEnabled) _putCached(cacheKey, enriched);
              return enriched;
            }
          } catch (e) {
            if (_isCancellation(e, cancel)) return null;
          }
        }
        continue;
      }

      // Strict 401 circuit-breaker skip: never invoke matchTrack on blocked providers.
      if (isAuthRequiredLookup(pid) || isPlaybackAuthBlockedLookup(pid)) {
        continue;
      }
      if (!isGuestCapableLookup(pid) &&
          authStateLookup(pid) != StreamingAuthState.connected) {
        continue;
      }

      if (candidatePid == pid) {
        if (crossPlatformEnabled) _putCached(cacheKey, candidate);
        return candidate;
      }

      final provider = providerLookup(pid);
      if (provider == null) continue;

      try {
        final matched = await provider.matchTrack(query, cancel: cancel);
        if (cancel?.isCancelled == true) return null;
        if (matched != null) {
          final enriched = _enrichMatchedMetadata(matched, candidate);
          if (crossPlatformEnabled) _putCached(cacheKey, enriched);
          return enriched;
        }
      } catch (e) {
        if (_isCancellation(e, cancel)) return null;
        if (_isUnauthorizedFailure(e)) {
          // Immediately skip to next provider without retrying on 401/authRequired.
          continue;
        }
        // Best-effort cross-platform routing continues to the next provider on transient errors.
      }
    }

    return null;
  }
}
