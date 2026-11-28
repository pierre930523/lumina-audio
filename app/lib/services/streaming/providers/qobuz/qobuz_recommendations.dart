part of '../qobuz_provider.dart';

extension _QobuzRecommendations on QobuzProvider {
  void _requireRecAuth() {
    if (authState != StreamingAuthState.connected ||
        (_appId?.trim().isEmpty ?? true) ||
        (_userAuthToken?.trim().isEmpty ?? true)) {
      throw RecError(
        kind: RecErrorKind.authRequired,
        message: lastError ?? 'Qobuz 尚未登入或授權已失效，請重新登入',
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

    final lowerId = seed.trackId.trim().toLowerCase();
    final isQobuzSeed = seed.providerId == kind ||
        lowerId.startsWith('qobuz:') ||
        lowerId.startsWith('streaming:qobuz:');
    final cleanSeedId = isQobuzSeed
        ? BaseStreamingProvider.stripTrackPrefix(
            BaseStreamingProvider.stripTrackPrefix(
              seed.trackId.trim(),
              'streaming:qobuz',
            ),
            'qobuz',
          )
        : '';

    var artistQuery = seed.primaryArtist.trim().isNotEmpty
        ? seed.primaryArtist.trim()
        : seed.artist.trim();

    if (cleanSeedId.isNotEmpty) {
      try {
        final trackJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            baseUrl,
            '/track/get',
            <String, String>{'track_id': cleanSeedId},
          ),
          headers: _authHeaders(),
          cancel: cancel,
        );
        final performer = trackJson['performer'] as Map?;
        final albumArtist = (trackJson['album'] as Map?)?['artist'] as Map?;
        final resolvedArtist =
            performer?['name']?.toString().trim() ??
            albumArtist?['name']?.toString().trim();
        if (resolvedArtist != null && resolvedArtist.isNotEmpty) {
          artistQuery = resolvedArtist;
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
          throw _mapRecError(e);
        }
        if (e.statusCode != 403 && e.statusCode != 404) {
          throw _mapRecError(e);
        }
      }
    }

    final tracks = <TrackMetadata>[];
    final seenIds = <String>{};

    void addParsedTracks(List<TrackInfo> parsed) {
      for (final t in parsed) {
        final tid = BaseStreamingProvider.stripTrackPrefix(t.id, 'qobuz');
        if (tid.isEmpty || (cleanSeedId.isNotEmpty && tid == cleanSeedId)) {
          continue;
        }
        if (seenIds.add(tid)) {
          tracks.add(TrackMetadata.fromTrackInfo(t, providerIdOverride: kind));
        }
      }
    }

    if (artistQuery.isNotEmpty) {
      try {
        final searchJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            baseUrl,
            '/catalog/search',
            <String, String>{
              'query': artistQuery,
              'limit': '$effectiveLimit',
              if (offset > 0) 'offset': '$offset',
            },
          ),
          headers: _authHeaders(),
          cancel: cancel,
        );
        final tracksObj = searchJson['tracks'] as Map?;
        addParsedTracks(_parseTracks(tracksObj?['items']));
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
          throw _mapRecError(e);
        }
        if (e.statusCode != 403 && e.statusCode != 404) {
          throw _mapRecError(e);
        }
      }
    }

    if (tracks.isEmpty) {
      try {
        final featuredJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            baseUrl,
            '/album/getFeatured',
            <String, String>{
              'type': 'ideal-discography',
              'limit': '$effectiveLimit',
              if (offset > 0) 'offset': '$offset',
            },
          ),
          headers: _authHeaders(),
          cancel: cancel,
        );
        final featuredTracksObj = featuredJson['tracks'] as Map?;
        addParsedTracks(_parseTracks(featuredTracksObj?['items']));
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
          throw _mapRecError(e);
        }
        if (e.statusCode != 403 && e.statusCode != 404) {
          throw _mapRecError(e);
        }
      }
    }

    final pageTracks = tracks.take(effectiveLimit).toList(growable: false);
    final nextCursor = tracks.length >= effectiveLimit
        ? '${offset + effectiveLimit}'
        : null;

    return RadioPage(
      tracks: pageTracks,
      nextCursor: nextCursor,
      sourceLabel: 'Qobuz Track Radio',
    );
  }

  Future<List<FeedSection>> _getPersonalizedFeedImpl({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState != StreamingAuthState.connected ||
        (_appId?.trim().isEmpty ?? true) ||
        (_userAuthToken?.trim().isEmpty ?? true)) {
      return const <FeedSection>[];
    }

    final sections = <FeedSection>[];

    try {
      final featuredJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          baseUrl,
          '/album/getFeatured',
          const <String, String>{'type': 'new-releases-full', 'limit': '16'},
        ),
        headers: _authHeaders(),
        cancel: cancel,
      );
      final albumsObj = featuredJson['albums'] as Map?;
      final albums = _parseAlbums(
        albumsObj?['items'] ?? featuredJson['items'],
      );
      final tracksObj = featuredJson['tracks'] as Map?;
      final tracks = _parseTracks(tracksObj?['items'])
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      if (albums.isNotEmpty || tracks.isNotEmpty) {
        sections.add(
          FeedSection(
            id: 'qobuz_featured',
            title: 'Qobuz Featured Releases',
            providerId: kind,
            tracks: tracks,
            albums: albums,
          ),
        );
      }
    } on StreamingException catch (e) {
      if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
        throw _mapRecError(e);
      }
    }

    try {
      final favJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          baseUrl,
          '/favorite/getUserFavorites',
          const <String, String>{'limit': '20'},
        ),
        headers: _authHeaders(),
        cancel: cancel,
      );
      final tracksObj = favJson['tracks'] as Map?;
      final albumsObj = favJson['albums'] as Map?;
      final tracks = _parseTracks(tracksObj?['items'])
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      final albums = _parseAlbums(albumsObj?['items']);
      if (tracks.isNotEmpty || albums.isNotEmpty) {
        sections.add(
          FeedSection(
            id: 'qobuz_favorites',
            title: 'Qobuz Favorites',
            providerId: kind,
            tracks: tracks,
            albums: albums,
          ),
        );
      }
    } on StreamingException catch (e) {
      if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
        throw _mapRecError(e);
      }
    }

    return List<FeedSection>.unmodifiable(sections);
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
            baseUrl,
            '/catalog/search',
            <String, String>{'query': normIsrc, 'limit': '10'},
          ),
          headers: _authHeaders(),
          cancel: cancel,
        );
        final tracksObj = isrcJson['tracks'] as Map?;
        final exactMatches = _parseTracks(tracksObj?['items'])
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

    final searchText = '${query.artist.trim()} ${query.title.trim()}'.trim();
    if (searchText.isEmpty) return null;

    try {
      final json = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          baseUrl,
          '/catalog/search',
          <String, String>{'query': searchText, 'limit': '15'},
        ),
        headers: _authHeaders(),
        cancel: cancel,
      );
      final tracksObj = json['tracks'] as Map?;
      final candidates = _parseTracks(tracksObj?['items'])
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      return TrackMatcher.selectBestMatch(query, candidates);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }
}
