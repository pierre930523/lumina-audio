part of '../deezer_provider.dart';

extension _DeezerRecommendations on DeezerProvider {
  Future<StreamingRecommendations> _fetchRecommendationsImpl({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    ensureAuthenticated();
    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      throw const StreamingException('Deezer 缺少 userId，無法載入推薦內容');
    }

    final albums = <StreamingAlbum>[];
    final tracks = <TrackInfo>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};
    final pageOffset = batchIndex * 10;

    void addAlbums(List<StreamingAlbum> items) {
      for (final a in items) {
        if (seenAlbumIds.add(a.id)) albums.add(a);
      }
    }

    void addTracks(List<TrackInfo> items) {
      for (final t in items) {
        if (seenTrackIds.add(t.id)) tracks.add(t);
      }
    }

    try {
      final recAlbumsJson = await _callPublicApi(
        '/user/$uid/recommendations/albums',
        query: <String, String>{
          'limit': '20',
          if (pageOffset > 0) 'index': '$pageOffset',
        },
        forceRefresh: forceRefresh,
        cancel: cancel,
      );
      addAlbums(_parseAlbums(recAlbumsJson['data']));
    } on StreamingException catch (e) {
      if (e.isTokenExpired ||
          e.isCancelled ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == null) {
        rethrow;
      }
    }

    try {
      final recTracksJson = await _callPublicApi(
        '/user/$uid/recommendations/tracks',
        query: <String, String>{
          'limit': '20',
          if (pageOffset > 0) 'index': '$pageOffset',
        },
        forceRefresh: forceRefresh,
        cancel: cancel,
      );
      addTracks(_parseTracks(recTracksJson['data']));
    } on StreamingException catch (e) {
      if (e.isTokenExpired ||
          e.isCancelled ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == null) {
        rethrow;
      }
    }

    if ((albums.isEmpty || tracks.isEmpty) &&
        _authMode == 'arl' &&
        _arl != null &&
        _arl!.isNotEmpty) {
      try {
        final gwUri = BaseStreamingProvider.buildUri(
          gwUrl,
          '',
          <String, String>{
            'method': 'page.get',
            'input': '3',
            'api_version': '1.0',
            'api_token': _apiToken ?? 'null',
          },
        );
        final gwJson = await http.requestJson(
          method: 'POST',
          uri: gwUri,
          headers: BaseStreamingProvider.withNoCacheHeaders(
            <String, String>{
              'Cookie': 'arl=$_arl',
              'Accept': 'application/json',
            },
            forceRefresh: forceRefresh,
          ),
          jsonBody: const <String, dynamic>{
            'PAGE': 'home',
            'VERSION': '2.3',
          },
          cancel: cancel,
        );
        _throwIfGatewayError(gwJson);
        final parsedGw = _parseGatewayHomeRecommendations(gwJson['results']);
        addAlbums(parsedGw.albums);
        addTracks(parsedGw.tracks);
      } on StreamingException catch (e) {
        if (e.isTokenExpired ||
            e.isCancelled ||
            e.statusCode == 401 ||
            e.statusCode == 403) {
          rethrow;
        }
      }
    }

    if (forceRefresh || batchIndex > 0 || albums.isEmpty) {
      try {
        final chartAlbumsJson = await _callPublicApi(
          '/chart/0/albums',
          query: <String, String>{
            'limit': '20',
            if (pageOffset > 0) 'index': '$pageOffset',
          },
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addAlbums(_parseAlbums(chartAlbumsJson['data']));
      } on StreamingException catch (e) {
        if (e.isTokenExpired ||
            e.isCancelled ||
            e.statusCode == 401 ||
            e.statusCode == 403 ||
            e.statusCode == null) {
          rethrow;
        }
      }
    }

    if (albums.isEmpty) {
      try {
        final favAlbumsJson = await _callPublicApi(
          '/user/$uid/albums',
          query: <String, String>{
            'limit': '20',
            if (pageOffset > 0) 'index': '$pageOffset',
          },
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addAlbums(_parseAlbums(favAlbumsJson['data']));
      } on StreamingException catch (e) {
        if (e.isTokenExpired ||
            e.isCancelled ||
            e.statusCode == 401 ||
            e.statusCode == 403 ||
            e.statusCode == null) {
          rethrow;
        }
      }
    }

    if (forceRefresh || batchIndex > 0 || tracks.isEmpty) {
      try {
        final flowJson = await _callPublicApi(
          '/user/$uid/flow',
          query: <String, String>{
            'limit': '20',
            if (pageOffset > 0) 'index': '$pageOffset',
          },
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addTracks(_parseTracks(flowJson['data']));
      } on StreamingException catch (e) {
        if (e.isTokenExpired ||
            e.isCancelled ||
            e.statusCode == 401 ||
            e.statusCode == 403 ||
            e.statusCode == null) {
          rethrow;
        }
      }
    }

    if ((forceRefresh || batchIndex > 0) &&
        tracks.every((t) => excludeTrackIds.contains(t.id))) {
      final seedTrack = [...tracks, ...catalog.tracks].firstOrNull;
      final rawSeedId = seedTrack != null
          ? BaseStreamingProvider.stripTrackPrefix(seedTrack.id, 'deezer')
          : '';
      if (rawSeedId.isNotEmpty) {
        try {
          final radioJson = await _callPublicApi(
            '/track/$rawSeedId/radio',
            query: const <String, String>{'limit': '20'},
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          addTracks(_parseTracks(radioJson['data']));
        } on StreamingException catch (e) {
          if (e.isTokenExpired ||
              e.isCancelled ||
              e.statusCode == 401 ||
              e.statusCode == 403 ||
              e.statusCode == null) {
            rethrow;
          }
        }
      }
    }

    if (tracks.isEmpty) {
      try {
        final favTracksJson = await _callPublicApi(
          '/user/$uid/tracks',
          query: const <String, String>{'limit': '20'},
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addTracks(_parseTracks(favTracksJson['data']));
      } on StreamingException catch (e) {
        if (e.isTokenExpired ||
            e.isCancelled ||
            e.statusCode == 401 ||
            e.statusCode == 403 ||
            e.statusCode == null) {
          rethrow;
        }
      }
    }

    return StreamingRecommendations(
      providerKind: kind,
      albums: BaseStreamingProvider.selectFreshBatch<StreamingAlbum>(
        albums,
        idOf: (a) => a.id,
        excludeIds: excludeAlbumIds,
        batchIndex: batchIndex,
        maxCount: 16,
      ),
      tracks: BaseStreamingProvider.selectFreshBatch<TrackInfo>(
        tracks,
        idOf: (t) => t.id,
        excludeIds: excludeTrackIds,
        batchIndex: batchIndex,
        maxCount: 16,
      ),
      fetchedAt: clock(),
    );
  }
}
