part of '../tidal_provider.dart';

extension _TidalRadioMatch on TidalProvider {
  void _requireRecAuth() {
    if (authState != StreamingAuthState.connected ||
        (_accessToken?.trim().isEmpty ?? true)) {
      throw RecError(
        kind: RecErrorKind.authRequired,
        message: lastError ?? 'Tidal 尚未登入或授權已失效，請重新登入',
        statusCode: 401,
        providerId: kind,
      );
    }
  }

  RecError _mapRecError(Object e) {
    if (e is RecError) return e;
    if (e is StreamingException) {
      if (e.isCancelled) {
        return RecError(
          kind: RecErrorKind.cancelled,
          message: e.message,
          statusCode: e.statusCode,
          providerId: kind,
        );
      }
      if (e.statusCode == 401 || e.isTokenExpired) {
        return RecError(
          kind: RecErrorKind.authRequired,
          message: e.message,
          statusCode: 401,
          providerId: kind,
        );
      }
      if (e.statusCode == 429) {
        return RecError(
          kind: RecErrorKind.rateLimited,
          message: e.message,
          statusCode: 429,
          providerId: kind,
        );
      }
      if (e.statusCode == 404) {
        return RecError(
          kind: RecErrorKind.notFound,
          message: e.message,
          statusCode: 404,
          providerId: kind,
        );
      }
      return RecError(
        kind: RecErrorKind.network,
        message: e.message,
        statusCode: e.statusCode,
        providerId: kind,
      );
    }
    return RecError(
      kind: RecErrorKind.unknown,
      message: e.toString(),
      providerId: kind,
    );
  }

  Future<RadioPage> _getTrackRadioImpl(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    _requireRecAuth();

    String cleanId;
    final lowerTrackId = seed.trackId.trim().toLowerCase();
    if (seed.providerId == kind ||
        lowerTrackId.startsWith('tidal:') ||
        lowerTrackId.startsWith('streaming:tidal:')) {
      cleanId = _stripTidalPrefix(seed.trackId);
    } else {
      final matched = await matchTrack(
        TrackMatchQuery.fromTrackMetadata(seed),
        cancel: cancel,
      );
      cleanId = matched != null ? _stripTidalPrefix(matched.trackId) : '';
    }

    if (cleanId.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'Tidal Track Radio',
      );
    }

    final effectiveLimit = limit > 0 ? limit : 10;
    final rawOffset = int.tryParse(cursor?.trim() ?? '') ?? 0;
    final offset = rawOffset < 0 ? 0 : rawOffset;

    List<dynamic> rawItems = const <dynamic>[];
    try {
      final json = await _requestTidalGet(
        '/tracks/$cleanId/radio',
        <String, String>{
          'limit': '$effectiveLimit',
          if (offset > 0) 'offset': '$offset',
        },
        cancel: cancel,
      );
      final items = json['items'] ?? json['data'];
      if (items is List) {
        rawItems = items;
      }
    } on StreamingException catch (e) {
      if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
        throw _mapRecError(e);
      }
      if (e.statusCode != 404 && e.statusCode != 400) {
        throw _mapRecError(e);
      }
    }

    if (rawItems.isEmpty) {
      try {
        final mixJson = await _tryTidalGet(
          '/tracks/$cleanId/mix',
          const <String, String>{},
          cancel: cancel,
        );
        final mixId = mixJson?['id']?.toString().trim() ?? '';
        if (mixId.isNotEmpty) {
          final mixItemsJson = await _tryTidalGet(
            '/mixes/$mixId/items',
            <String, String>{
              'limit': '$effectiveLimit',
              if (offset > 0) 'offset': '$offset',
            },
            cancel: cancel,
          );
          final mixItems = mixItemsJson?['items'] ?? mixItemsJson?['data'];
          if (mixItems is List) {
            rawItems = mixItems;
          }
        }
      } on StreamingException catch (e) {
        throw _mapRecError(e);
      }
    }

    if (rawItems.isEmpty) {
      try {
        final feedJson = await _tryTidalGet(
          '/home/feed/static',
          const <String, String>{
            'deviceType': 'BROWSER',
            'locale': 'en_US',
            'platform': 'WEB',
          },
          v2: true,
          cancel: cancel,
        );
        if (feedJson != null) {
          final ext = _extractHomeRecommendations(
            feedJson,
            coverSize: 1280,
          );
          if (ext.mixIds.isNotEmpty) {
            final mixItemsJson = await _tryTidalGet(
              '/mixes/${ext.mixIds.first}/items',
              <String, String>{
                'limit': '$effectiveLimit',
                if (offset > 0) 'offset': '$offset',
              },
              cancel: cancel,
            );
            final mixItems = mixItemsJson?['items'] ?? mixItemsJson?['data'];
            if (mixItems is List) {
              rawItems = mixItems;
            }
          }
        }
      } on StreamingException catch (e) {
        throw _mapRecError(e);
      }
    }

    final parsed = _parseTrackList(rawItems, coverSize: 1280);
    final tracks = <TrackMetadata>[];
    final seenIds = <String>{};
    for (final t in parsed) {
      final tid = _stripTidalPrefix(t.id);
      if (tid.isEmpty || tid == cleanId) continue;
      if (seenIds.add(tid)) {
        tracks.add(TrackMetadata.fromTrackInfo(t, providerIdOverride: kind));
      }
    }

    final nextCursor = rawItems.length >= effectiveLimit
        ? '${offset + effectiveLimit}'
        : null;

    return RadioPage(
      tracks: tracks,
      nextCursor: nextCursor,
      sourceLabel: 'Tidal Track Radio',
    );
  }

  Future<TrackMetadata?> _matchTrackImpl(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    _requireRecAuth();

    final normIsrc = TrackMatcher.normalizeIsrc(query.isrc);
    if (normIsrc != null) {
      final isrcCandidates = <TrackMetadata>[];
      try {
        final searchJson = await _requestTidalGet(
          '/search/tracks',
          <String, String>{'query': normIsrc, 'limit': '25'},
          cancel: cancel,
        );
        for (final t in _parseTrackList(searchJson['items'], coverSize: 1280)) {
          final meta = TrackMetadata.fromTrackInfo(t, providerIdOverride: kind);
          if (TrackMatcher.normalizeIsrc(meta.isrc) == normIsrc) {
            isrcCandidates.add(meta);
          }
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
          throw _mapRecError(e);
        }
      }

      if (isrcCandidates.isEmpty) {
        try {
          final tracksJson = await _requestTidalGet(
            '/tracks',
            <String, String>{'isrc': normIsrc, 'limit': '25'},
            cancel: cancel,
          );
          for (final t in _parseTrackList(
            tracksJson['items'] ?? tracksJson['data'],
            coverSize: 1280,
          )) {
            final meta = TrackMetadata.fromTrackInfo(
              t,
              providerIdOverride: kind,
            );
            if (TrackMatcher.normalizeIsrc(meta.isrc) == normIsrc) {
              isrcCandidates.add(meta);
            }
          }
        } on StreamingException catch (e) {
          if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
            throw _mapRecError(e);
          }
        }
      }

      if (isrcCandidates.isNotEmpty) {
        return TrackMatcher.selectBestMatch(query, isrcCandidates);
      }
    }

    final searchText = '${query.artist.trim()} ${query.title.trim()}'.trim();
    if (searchText.isEmpty) return null;

    try {
      final json = await _requestTidalGet(
        '/search/tracks',
        <String, String>{'query': searchText, 'limit': '25'},
        cancel: cancel,
      );
      final candidates = _parseTrackList(json['items'], coverSize: 1280)
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      return TrackMatcher.selectBestMatch(query, candidates);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }
}
