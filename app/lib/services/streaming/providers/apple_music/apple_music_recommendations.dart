part of '../apple_music_provider.dart';

extension _AppleMusicRecommendations on AppleMusicProvider {
  bool get _hasValidAuth =>
      authState == StreamingAuthState.connected &&
      (_developerToken?.trim().isNotEmpty ?? false) &&
      (_musicUserToken?.trim().isNotEmpty ?? false);

  void _requireRecAuth() {
    if (!_hasValidAuth) {
      throw RecError(
        kind: RecErrorKind.authRequired,
        message: lastError ?? 'Apple Music 尚未登入或授權已失效，請重新登入',
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

    final effectiveLimit = limit > 0 ? limit : 10;
    final rawOffset = int.tryParse(cursor?.trim() ?? '') ?? 0;
    final offset = rawOffset < 0 ? 0 : rawOffset;
    final term = seed.primaryArtist.trim().isNotEmpty
        ? seed.primaryArtist.trim()
        : seed.artist.trim();
    if (term.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'Apple Music Radio',
      );
    }

    final cleanSeedId = BaseStreamingProvider.stripTrackPrefix(
      BaseStreamingProvider.stripTrackPrefix(
        seed.trackId.trim(),
        'streaming:apple_music',
      ),
      'apple',
    );

    try {
      final json = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/catalog/$_storefront/search',
          <String, String>{
            'types': 'songs',
            'term': term,
            'limit': '$effectiveLimit',
            if (offset > 0) 'offset': '$offset',
          },
        ),
        headers: _authHeaders,
        cancel: cancel,
      );
      final results = json['results'] as Map?;
      final songsObj = results?['songs'] as Map?;
      final parsed = _parseSongs(songsObj?['data']);
      final tracks = parsed
          .where((t) {
            final tid = BaseStreamingProvider.stripTrackPrefix(t.id, 'apple');
            return cleanSeedId.isEmpty || tid != cleanSeedId;
          })
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);

      final nextCursor = parsed.length >= effectiveLimit
          ? '${offset + effectiveLimit}'
          : null;
      return RadioPage(
        tracks: tracks,
        nextCursor: nextCursor,
        sourceLabel: 'Apple Music Radio',
      );
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }

  Future<List<FeedSection>> _getPersonalizedFeedImpl({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (!_hasValidAuth) {
      return const <FeedSection>[];
    }

    try {
      final recJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/me/recommendations',
          const <String, String>{'limit': '10'},
        ),
        headers: _authHeaders,
        cancel: cancel,
      );

      final data = recJson['data'];
      if (data is! List) return const <FeedSection>[];

      final sections = <FeedSection>[];
      var idx = 0;
      for (final group in data) {
        if (group is! Map) continue;
        final groupMap = Map<String, dynamic>.from(group);
        final attrs = groupMap['attributes'] is Map
            ? Map<String, dynamic>.from(groupMap['attributes'] as Map)
            : const <String, dynamic>{};
        final titleObj = attrs['title'];
        final reasonObj = attrs['reason'];
        final title = (titleObj is Map
                ? titleObj['stringForDisplay']?.toString()
                : titleObj?.toString()) ??
            (reasonObj is Map
                ? reasonObj['stringForDisplay']?.toString()
                : reasonObj?.toString()) ??
            'Apple Music Recommendations';

        final rel = groupMap['relationships'] as Map?;
        final contents = rel?['contents'] as Map?;
        final rawItems = contents?['data'];
        if (rawItems is! List) continue;

        final songItems = <Map<String, dynamic>>[];
        final albumItems = <Map<String, dynamic>>[];
        for (final item in rawItems) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final type = map['type']?.toString() ?? '';
          if (type == 'songs' || type == 'library-songs' || type == 'tracks') {
            songItems.add(map);
          } else if (type == 'albums' || type == 'library-albums') {
            albumItems.add(map);
          }
        }

        final tracks = _parseSongs(songItems)
            .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
            .toList(growable: false);
        final albums = _parseAlbums(albumItems);
        if (tracks.isNotEmpty || albums.isNotEmpty) {
          final groupId = groupMap['id']?.toString().trim();
          sections.add(
            FeedSection(
              id: (groupId != null && groupId.isNotEmpty)
                  ? groupId
                  : 'apple_rec_${idx++}',
              title: title,
              providerId: kind,
              tracks: tracks,
              albums: albums,
            ),
          );
        }
      }

      return List<FeedSection>.unmodifiable(sections);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }

  Future<TrackMetadata?> _matchTrackImpl(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    _requireRecAuth();

    final normIsrc = TrackMatcher.normalizeIsrc(query.isrc);
    if (normIsrc != null) {
      try {
        final isrcJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/catalog/$_storefront/songs',
            <String, String>{'filter[isrc]': normIsrc},
          ),
          headers: _authHeaders,
          cancel: cancel,
        );
        final exactMatches = _parseSongs(isrcJson['data'])
            .map(
              (t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind),
            )
            .where((m) => TrackMatcher.normalizeIsrc(m.isrc) == normIsrc)
            .toList(growable: false);
        if (exactMatches.isNotEmpty) {
          return TrackMatcher.selectBestMatch(query, exactMatches);
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
          throw _mapRecError(e);
        }
      }
    }

    final term = '${query.artist.trim()} ${query.title.trim()}'.trim();
    if (term.isEmpty) return null;

    try {
      final json = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/catalog/$_storefront/search',
          <String, String>{'types': 'songs', 'term': term, 'limit': '10'},
        ),
        headers: _authHeaders,
        cancel: cancel,
      );
      final results = json['results'] as Map?;
      final songsObj = results?['songs'] as Map?;
      final candidates = _parseSongs(songsObj?['data'])
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      return TrackMatcher.selectBestMatch(query, candidates);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }
}
