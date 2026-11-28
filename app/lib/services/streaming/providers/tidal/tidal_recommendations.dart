part of '../tidal_provider.dart';

extension _TidalRecommendations on TidalProvider {
  Future<StreamingRecommendations> _fetchRecommendationsImpl({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final albums = <StreamingAlbum>[];
    final tracks = <TrackInfo>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};

    void mergeExtracted(
      ({List<StreamingAlbum> albums, List<TrackInfo> tracks, List<String> mixIds})
          ext,
    ) {
      for (final a in ext.albums) {
        if (seenAlbumIds.add(a.id)) albums.add(a);
      }
      for (final t in ext.tracks) {
        if (seenTrackIds.add(t.id)) tracks.add(t);
      }
    }

    Future<void> fetchFeedOrPage(
      String path, {
      Map<String, String> query = const <String, String>{},
      bool v2 = false,
      bool albumsOnly = false,
      bool tracksOnly = false,
      List<String>? collectedMixIds,
    }) async {
      final json = await _tryTidalGet(
        path,
        <String, String>{'countryCode': _countryCode, ...query},
        forceRefresh: forceRefresh,
        v2: v2,
        cancel: cancel,
      );
      if (json == null) return;
      final items = json['items'];
      if (albumsOnly && items is List && items.isNotEmpty) {
        for (final a in _parseAlbumList(items)) {
          if (seenAlbumIds.add(a.id)) albums.add(a);
        }
        return;
      }
      if (tracksOnly && items is List && items.isNotEmpty) {
        for (final t in _parseTrackList(items)) {
          if (seenTrackIds.add(t.id)) tracks.add(t);
        }
        return;
      }
      final ext = _extractHomeRecommendations(json);
      mergeExtracted(ext);
      if (collectedMixIds != null) {
        for (final id in ext.mixIds) {
          if (!collectedMixIds.contains(id)) {
            collectedMixIds.add(id);
          }
        }
      }
    }

    final uid = _userId;

    if (!forceRefresh && batchIndex == 0) {
      final mixIds = <String>[];
      await fetchFeedOrPage(
        '/home/feed/static',
        v2: true,
        query: const <String, String>{
          'deviceType': 'BROWSER',
          'locale': 'en_US',
          'platform': 'WEB',
        },
        collectedMixIds: mixIds,
      );
      if (tracks.length < 4 && mixIds.isNotEmpty) {
        await fetchFeedOrPage(
          '/mixes/${mixIds.first}/items',
          query: const <String, String>{'limit': '20'},
        );
      }
      if (albums.isEmpty || tracks.isEmpty) {
        await fetchFeedOrPage(
          '/pages/home',
          query: const <String, String>{'deviceType': 'BROWSER'},
        );
      }
      if (albums.length < 4) {
        await fetchFeedOrPage(
          '/pages/explore',
          query: const <String, String>{'deviceType': 'BROWSER'},
        );
        await fetchFeedOrPage(
          '/featured/recommended/albums',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
        await fetchFeedOrPage(
          '/featured/new/albums',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
      }
      if (tracks.length < 4) {
        await fetchFeedOrPage(
          '/featured/top/tracks',
          query: const <String, String>{'limit': '20'},
          tracksOnly: true,
        );
      }
      if (uid != null && uid.isNotEmpty) {
        if (albums.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/albums',
            query: const <String, String>{'limit': '20'},
            albumsOnly: true,
          );
        }
        if (tracks.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/tracks',
            query: const <String, String>{'limit': '20'},
            tracksOnly: true,
          );
        }
      }
    } else {
      final cycleOffset = (batchIndex ~/ 4) * 15;
      final offsetQuery = cycleOffset > 0
          ? <String, String>{'offset': '$cycleOffset'}
          : const <String, String>{};
      switch (batchIndex % 4) {
        case 1:
          await fetchFeedOrPage(
            '/pages/explore_new_music',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/new/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          await fetchFeedOrPage(
            '/featured/top/tracks',
            query: <String, String>{'limit': '20', ...offsetQuery},
            tracksOnly: true,
          );
          break;
        case 2:
          await fetchFeedOrPage(
            '/featured/recommended/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          await fetchFeedOrPage(
            '/pages/explore_top_music',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/top/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          break;
        case 3:
          await fetchFeedOrPage(
            '/pages/explore',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/top/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          await fetchFeedOrPage(
            '/featured/new/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          break;
        default:
          await fetchFeedOrPage(
            '/home/feed/static',
            v2: true,
            query: const <String, String>{
              'deviceType': 'BROWSER',
              'locale': 'en_US',
              'platform': 'WEB',
            },
          );
          await fetchFeedOrPage(
            '/pages/home',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/recommended/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          break;
      }

      final albumSeeds = _dedupeSeedIds(<String>[
        ...excludeAlbumIds,
        ..._recentRecAlbumIds,
        ...albums.map((a) => a.id),
        ...catalog.albums.map((a) => a.id),
      ]);
      if (albumSeeds.isNotEmpty) {
        final idx = batchIndex > 0 ? (batchIndex - 1) % albumSeeds.length : 0;
        final seedAlbumId = albumSeeds[idx];
        await fetchFeedOrPage(
          '/albums/$seedAlbumId/similar',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
      }

      final trackSeeds = _dedupeSeedIds(<String>[
        ...excludeTrackIds,
        ..._recentRecTrackIds,
        ...tracks.map((t) => t.id),
        ...catalog.tracks.map((t) => t.id),
      ]);
      if (trackSeeds.isNotEmpty) {
        final idx = batchIndex > 0 ? (batchIndex - 1) % trackSeeds.length : 0;
        final seedTrackId = trackSeeds[idx];
        await fetchFeedOrPage(
          '/tracks/$seedTrackId/radio',
          query: const <String, String>{'limit': '20'},
          tracksOnly: true,
        );
      }

      if (albums.isEmpty || tracks.isEmpty) {
        await fetchFeedOrPage(
          '/pages/home',
          query: const <String, String>{'deviceType': 'BROWSER'},
        );
      }
      if (albums.isEmpty) {
        await fetchFeedOrPage(
          '/featured/recommended/albums',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
      }
      if (tracks.isEmpty) {
        await fetchFeedOrPage(
          '/featured/top/tracks',
          query: const <String, String>{'limit': '20'},
          tracksOnly: true,
        );
      }
      if (uid != null && uid.isNotEmpty) {
        final favOffset = batchIndex > 0 ? (batchIndex * 10) % 40 : 0;
        if (albums.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/albums',
            query: <String, String>{
              'limit': '20',
              if (favOffset > 0) 'offset': '$favOffset',
            },
            albumsOnly: true,
          );
        }
        if (tracks.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/tracks',
            query: <String, String>{
              'limit': '20',
              if (favOffset > 0) 'offset': '$favOffset',
            },
            tracksOnly: true,
          );
        }
      }
    }

    final selectedAlbums = BaseStreamingProvider.selectFreshBatch<StreamingAlbum>(
      albums,
      idOf: (a) => a.id,
      excludeIds: excludeAlbumIds,
      batchIndex: batchIndex,
      maxCount: 16,
    );
    final selectedTracks = BaseStreamingProvider.selectFreshBatch<TrackInfo>(
      tracks,
      idOf: (t) => t.id,
      excludeIds: excludeTrackIds,
      batchIndex: batchIndex,
      maxCount: 16,
    );

    _rememberRecentIds(_recentRecAlbumIds, selectedAlbums.map((a) => a.id));
    _rememberRecentIds(_recentRecTrackIds, selectedTracks.map((t) => t.id));

    return StreamingRecommendations(
      providerKind: kind,
      albums: selectedAlbums,
      tracks: selectedTracks,
      fetchedAt: clock(),
    );
  }
}
