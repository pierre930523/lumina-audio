part of '../apple_music_provider.dart';

extension _AppleMusicDiscover on AppleMusicProvider {
  Future<StreamingRecommendations> _fetchRecommendationsImpl({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    ensureAuthenticated();

    final albumMaps = <Map<String, dynamic>>[];
    final songMaps = <Map<String, dynamic>>[];
    final seenAlbumIds = <String>{};
    final seenSongIds = <String>{};
    final headers = BaseStreamingProvider.withNoCacheHeaders(
      _authHeaders,
      forceRefresh: forceRefresh,
    );

    void collectAppleResource(
      Map<String, dynamic> item, {
      dynamic fallbackArtwork,
      String? fallbackAlbumName,
    }) {
      final type = item['type']?.toString() ?? '';
      final id = item['id']?.toString() ?? '';
      final attrs = item['attributes'] is Map
          ? Map<String, dynamic>.from(item['attributes'] as Map)
          : null;
      final itemArtwork = attrs?['artwork'];
      final hasOwnArtwork = _expandArtworkUrl(itemArtwork) != null;
      final effectiveArtwork = hasOwnArtwork ? itemArtwork : fallbackArtwork;
      final itemAlbumName = (type == 'albums' || type == 'library-albums')
          ? (attrs?['name']?.toString() ?? fallbackAlbumName)
          : fallbackAlbumName;

      if (id.isNotEmpty &&
          (type == 'albums' || type == 'library-albums')) {
        if (seenAlbumIds.add(id)) {
          albumMaps.add(item);
        }
      } else if (id.isNotEmpty &&
          (type == 'songs' || type == 'library-songs' || type == 'tracks')) {
        if (seenSongIds.add(id)) {
          var effectiveItem = item;
          if (!hasOwnArtwork &&
              fallbackArtwork != null &&
              _expandArtworkUrl(fallbackArtwork) != null) {
            final nextAttrs = Map<String, dynamic>.from(
              attrs ?? const <String, dynamic>{},
            );
            nextAttrs['artwork'] = fallbackArtwork;
            if ((nextAttrs['albumName']?.toString().trim() ?? '').isEmpty &&
                fallbackAlbumName != null &&
                fallbackAlbumName.isNotEmpty) {
              nextAttrs['albumName'] = fallbackAlbumName;
            }
            effectiveItem = <String, dynamic>{
              ...item,
              'attributes': nextAttrs,
            };
          }
          songMaps.add(effectiveItem);
        }
      }
      final rel = item['relationships'];
      if (rel is Map) {
        final contents = rel['contents'];
        if (contents is Map && contents['data'] is List) {
          for (final child in contents['data'] as List) {
            if (child is Map) {
              collectAppleResource(
                Map<String, dynamic>.from(child),
                fallbackArtwork: effectiveArtwork,
                fallbackAlbumName: itemAlbumName,
              );
            }
          }
        }
        final tracksRel = rel['tracks'];
        if (tracksRel is Map && tracksRel['data'] is List) {
          for (final child in tracksRel['data'] as List) {
            if (child is Map) {
              collectAppleResource(
                Map<String, dynamic>.from(child),
                fallbackArtwork: effectiveArtwork,
                fallbackAlbumName: itemAlbumName,
              );
            }
          }
        }
      }
    }

    void collectDataArray(dynamic data) {
      if (data is! List) return;
      for (final entry in data) {
        if (entry is Map) {
          collectAppleResource(Map<String, dynamic>.from(entry));
        }
      }
    }

    final recOffset = batchIndex * 10;
    try {
      final Uri recUri;
      final nextPath = (forceRefresh || batchIndex > 0)
          ? _nextRecommendationsPath
          : null;
      if (nextPath != null && nextPath.isNotEmpty) {
        final parsedNext = Uri.tryParse(nextPath);
        recUri = (parsedNext != null && parsedNext.hasScheme)
            ? parsedNext
            : BaseStreamingProvider.buildUri(
                apiBaseUrl,
                nextPath,
              );
      } else {
        recUri = BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/me/recommendations',
          <String, String>{
            'limit': '10',
            if (recOffset > 0) 'offset': '$recOffset',
          },
        );
      }
      final recJson = await http.requestJson(
        method: 'GET',
        uri: recUri,
        headers: headers,
        cancel: cancel,
      );
      _nextRecommendationsPath = recJson['next']?.toString().trim();
      collectDataArray(recJson['data']);
    } on StreamingException catch (e) {
      if (e.isTokenExpired ||
          e.isCancelled ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == null) {
        rethrow;
      }
      _nextRecommendationsPath = null;
    }

    final recentOffset = (batchIndex * 10) % 40;
    try {
      final recentJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/me/recent/played/tracks',
          <String, String>{
            'limit': '15',
            if (recentOffset > 0) 'offset': '$recentOffset',
          },
        ),
        headers: headers,
        cancel: cancel,
      );
      final data = recentJson['data'];
      if (data is List) {
        for (final entry in data) {
          if (entry is Map) {
            final map = Map<String, dynamic>.from(entry);
            final id = map['id']?.toString() ?? '';
            if (id.isNotEmpty && seenSongIds.add(id)) {
              songMaps.add(map);
            }
          }
        }
      }
    } on StreamingException catch (e) {
      if (e.isTokenExpired ||
          e.isCancelled ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == null) {
        rethrow;
      }
    }

    if (forceRefresh || batchIndex > 0) {
      try {
        final addedJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/me/library/recently-added',
            <String, String>{
              'limit': '15',
              if (recOffset > 0) 'offset': '$recOffset',
            },
          ),
          headers: headers,
          cancel: cancel,
        );
        collectDataArray(addedJson['data']);
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
        final chartsJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/catalog/$_storefront/charts',
            <String, String>{
              'types': 'songs,albums',
              'limit': '15',
              if (recOffset > 0) 'offset': '$recOffset',
            },
          ),
          headers: headers,
          cancel: cancel,
        );
        final results = chartsJson['results'];
        if (results is Map) {
          for (final bucket in const ['albums', 'songs']) {
            final groups = results[bucket];
            if (groups is List) {
              for (final group in groups) {
                if (group is Map) {
                  collectDataArray(group['data']);
                }
              }
            }
          }
        }
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

    if (albumMaps.isEmpty) {
      try {
        final libAlbumsJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/me/library/albums',
            const <String, String>{'limit': '15'},
          ),
          headers: headers,
          cancel: cancel,
        );
        final data = libAlbumsJson['data'];
        if (data is List) {
          for (final entry in data) {
            if (entry is Map) {
              final map = Map<String, dynamic>.from(entry);
              final id = map['id']?.toString() ?? '';
              if (id.isNotEmpty && seenAlbumIds.add(id)) {
                albumMaps.add(map);
              }
            }
          }
        }
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

    if (songMaps.isEmpty) {
      try {
        final libSongsJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/me/library/songs',
            const <String, String>{'limit': '15'},
          ),
          headers: headers,
          cancel: cancel,
        );
        final data = libSongsJson['data'];
        if (data is List) {
          for (final entry in data) {
            if (entry is Map) {
              final map = Map<String, dynamic>.from(entry);
              final id = map['id']?.toString() ?? '';
              if (id.isNotEmpty && seenSongIds.add(id)) {
                songMaps.add(map);
              }
            }
          }
        }
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
        _parseAlbums(albumMaps),
        idOf: (a) => a.id,
        excludeIds: excludeAlbumIds,
        batchIndex: batchIndex,
        maxCount: 16,
      ),
      tracks: BaseStreamingProvider.selectFreshBatch<TrackInfo>(
        _parseSongs(songMaps),
        idOf: (t) => t.id,
        excludeIds: excludeTrackIds,
        batchIndex: batchIndex,
        maxCount: 16,
      ),
      fetchedAt: clock(),
    );
  }
}
