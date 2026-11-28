part of '../qobuz_provider.dart';

const List<String> _qobuzFeaturedRecommendationTypes = <String>[
  'new-releases-full',
  'ideal-discography',
  'press-awards',
  'most-streamed',
  'best-sellers',
  'new-releases',
  'qobuzissims',
];

extension _QobuzCatalog on QobuzProvider {
  Future<StreamingCatalog> _syncLibraryImpl({CancellationToken? cancel}) async {
    ensureAuthenticated();

    final favJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        baseUrl,
        '/favorite/getUserFavorites',
        const <String, String>{'limit': '100'},
      ),
      headers: _authHeaders(),
      cancel: cancel,
    );

    final playlistsJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        baseUrl,
        '/playlist/getUserPlaylists',
        const <String, String>{'limit': '50'},
      ),
      headers: _authHeaders(),
      cancel: cancel,
    );

    final tracksContainer = favJson['tracks'] as Map?;
    final albumsContainer = favJson['albums'] as Map?;
    final playlistsContainer = playlistsJson['playlists'] as Map?;

    final nextCatalog = StreamingCatalog(
      tracks: _parseTracks(tracksContainer?['items']),
      albums: _parseAlbums(albumsContainer?['items']),
      playlists: _parsePlaylists(playlistsContainer?['items']),
      syncedAt: clock(),
    );
    setCatalog(nextCatalog);
    return nextCatalog;
  }

  Future<StreamingRecommendations> _fetchRecommendationsImpl({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    ensureAuthenticated();

    final mergedAlbums = <StreamingAlbum>[];
    final seenAlbumIds = <String>{};
    var tracks = <TrackInfo>[];
    final headers = BaseStreamingProvider.withNoCacheHeaders(
      _authHeaders(),
      forceRefresh: forceRefresh,
    );

    final featuredType = _qobuzFeaturedRecommendationTypes[
        batchIndex % _qobuzFeaturedRecommendationTypes.length];
    final featuredOffset =
        (batchIndex ~/ _qobuzFeaturedRecommendationTypes.length) * 16;

    try {
      final featuredJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          baseUrl,
          '/album/getFeatured',
          <String, String>{
            'type': featuredType,
            'limit': '16',
            if (featuredOffset > 0) 'offset': '$featuredOffset',
          },
        ),
        headers: headers,
        cancel: cancel,
      );
      final featuredAlbumsObj = featuredJson['albums'] as Map?;
      final featuredAlbums = _parseAlbums(
        featuredAlbumsObj?['items'] ?? featuredJson['items'],
      );
      for (final a in featuredAlbums) {
        if (seenAlbumIds.add(a.id)) {
          mergedAlbums.add(a);
        }
      }
      final featuredTracksObj = featuredJson['tracks'] as Map?;
      if (featuredTracksObj != null) {
        tracks = _parseTracks(featuredTracksObj['items']);
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

    final favOffset = batchIndex > 0 ? (batchIndex * 10) % 40 : 0;
    try {
      final favJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          baseUrl,
          '/favorite/getUserFavorites',
          <String, String>{
            'limit': '20',
            if (favOffset > 0) 'offset': '$favOffset',
          },
        ),
        headers: headers,
        cancel: cancel,
      );
      final favAlbumsObj = favJson['albums'] as Map?;
      final favAlbums = _parseAlbums(favAlbumsObj?['items']);
      for (final a in favAlbums) {
        if (seenAlbumIds.add(a.id)) {
          mergedAlbums.add(a);
        }
      }
      final favTracksObj = favJson['tracks'] as Map?;
      final favTracks = _parseTracks(favTracksObj?['items']);
      if (favTracks.isNotEmpty) {
        final seenTrackIds = tracks.map((t) => t.id).toSet();
        for (final t in favTracks) {
          if (seenTrackIds.add(t.id)) {
            tracks = <TrackInfo>[...tracks, t];
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

    final needsAlbumSeedTracks = mergedAlbums.isNotEmpty &&
        (tracks.isEmpty ||
            ((forceRefresh || batchIndex > 0) &&
                tracks.every((t) => excludeTrackIds.contains(t.id))));
    if (needsAlbumSeedTracks) {
      final seedAlbum = mergedAlbums.firstWhere(
        (a) => !excludeAlbumIds.contains(a.id),
        orElse: () => mergedAlbums.first,
      );
      try {
        final albJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            baseUrl,
            '/album/get',
            <String, String>{'album_id': seedAlbum.id},
          ),
          headers: headers,
          cancel: cancel,
        );
        final albumTitle = albJson['title']?.toString() ?? seedAlbum.title;
        final albArtistObj = albJson['artist'] as Map?;
        final albumArtist =
            albArtistObj?['name']?.toString() ?? seedAlbum.artist;
        final albumCover =
            _extractCoverUrl(albJson['image']) ?? seedAlbum.coverUrl;
        final albTracksObj = albJson['tracks'] as Map?;
        final seedTracks = _parseTracks(
          albTracksObj?['items'],
          fallbackAlbumTitle: albumTitle,
          fallbackArtistName: albumArtist,
          fallbackCoverUrl: albumCover,
        );
        if (seedTracks.isNotEmpty) {
          final seenTrackIds = tracks.map((t) => t.id).toSet();
          for (final t in seedTracks) {
            if (seenTrackIds.add(t.id)) {
              tracks = <TrackInfo>[...tracks, t];
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

    if (tracks.isNotEmpty && mergedAlbums.isNotEmpty) {
      final coverByAlbumTitle = <String, String>{};
      for (final a in mergedAlbums) {
        final key = a.title.trim().toLowerCase();
        if (key.isNotEmpty && a.coverUrl != null && a.coverUrl!.isNotEmpty) {
          coverByAlbumTitle.putIfAbsent(key, () => a.coverUrl!);
        }
      }
      if (coverByAlbumTitle.isNotEmpty) {
        tracks = tracks
            .map((t) {
              if ((t.coverUrl != null && t.coverUrl!.isNotEmpty) ||
                  (t.albumArtUrl != null && t.albumArtUrl!.isNotEmpty)) {
                return t;
              }
              final inherited = coverByAlbumTitle[t.album.trim().toLowerCase()];
              if (inherited == null) return t;
              return t.copyWith(coverUrl: inherited, albumArtUrl: inherited);
            })
            .toList(growable: false);
      }
    }

    return StreamingRecommendations(
      providerKind: kind,
      albums: BaseStreamingProvider.selectFreshBatch<StreamingAlbum>(
        mergedAlbums,
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

  Future<CanonicalAlbumDetail?> _fetchAlbumDetailImpl(
    String albumId, {
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();
    var cleanId = BaseStreamingProvider.stripTrackPrefix(
      albumId,
      'streaming:$kind',
    );
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, kind);
    if (cleanId.isEmpty) return null;

    final json = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        baseUrl,
        '/album/get',
        <String, String>{'album_id': cleanId},
      ),
      headers: _authHeaders(),
      cancel: cancel,
    );

    final title = json['title']?.toString() ?? 'Qobuz Album';
    final artistObj = json['artist'] as Map?;
    final artistName = artistObj?['name']?.toString() ?? '未知藝術家';
    final origDate = json['release_date_original']?.toString() ?? '';
    final releaseYear = origDate.length >= 4
        ? int.tryParse(origDate.substring(0, 4))
        : null;
    final bio = json['description']?.toString();
    final coverUrl = _extractCoverUrl(json['image']);

    final rawSr = json['maximum_sampling_rate'];
    final srHz = rawSr is num
        ? (rawSr <= 1000 ? (rawSr.toDouble() * 1000).round() : rawSr.round())
        : 44100;
    final bitDepth = (json['maximum_bit_depth'] as num?)?.toInt() ?? 16;

    final tracksContainer = json['tracks'] as Map?;
    final parsedTracks = _parseTracks(
      tracksContainer?['items'] ?? json['tracks'],
      fallbackAlbumTitle: title,
      fallbackArtistName: artistName,
      fallbackCoverUrl: coverUrl,
    );
    final versionTracks = <AlbumVersionTrackInfo>[];
    for (var i = 0; i < parsedTracks.length; i++) {
      final t = parsedTracks[i];
      versionTracks.add(
        AlbumVersionTrackInfo(
          id: t.id,
          title: t.title,
          discNumber: t.discNumber ?? 1,
          trackNumber: t.trackNumber ?? (i + 1),
          durationMs: t.duration.inMilliseconds,
          codec: 'flac',
          sampleRateHz: t.format.sampleRateHz > 0 ? t.format.sampleRateHz : srHz,
          bitDepth: t.format.bitDepth > 0 ? t.format.bitDepth : bitDepth,
          externalTrackId: t.id,
        ),
      );
    }

    return CanonicalAlbumDetail(
      id: 'streaming:$kind:$cleanId',
      title: title,
      artistName: artistName,
      releaseYear: releaseYear,
      editorialBio: bio,
      coverUrl: coverUrl,
      versions: <AlbumVersionInfo>[
        AlbumVersionInfo(
          id: 'ver_qobuz_$cleanId',
          provider: kind,
          externalAlbumId: cleanId,
          editionLabel: bitDepth > 16 ? 'Qobuz Hi-Res' : 'Qobuz CD Quality',
          codec: 'flac',
          sampleRateHz: srHz,
          bitDepth: bitDepth,
          tracks: versionTracks,
        ),
      ],
    );
  }

  Future<List<TrackInfo>> _fetchPlaylistTracksImpl(String playlistId) async {
    ensureAuthenticated();
    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'qobuz');
    final json = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        baseUrl,
        '/playlist/get',
        <String, String>{
          'playlist_id': cleanId,
          'extra': 'tracks',
          'limit': '100',
        },
      ),
      headers: _authHeaders(),
    );
    final tracksObj = json['tracks'] as Map?;
    return _parseTracks(tracksObj?['items']);
  }

  Future<StreamingCatalog> _searchImpl(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return StreamingCatalog(syncedAt: clock());

    final json = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        baseUrl,
        '/catalog/search',
        <String, String>{'query': trimmed, 'limit': '25'},
      ),
      headers: _authHeaders(),
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    final tracksObj = json['tracks'] as Map?;
    final albumsObj = json['albums'] as Map?;
    final playlistsObj = json['playlists'] as Map?;

    return StreamingCatalog(
      tracks: _parseTracks(tracksObj?['items']),
      albums: _parseAlbums(albumsObj?['items']),
      playlists: _parsePlaylists(playlistsObj?['items']),
      syncedAt: clock(),
    );
  }
}
