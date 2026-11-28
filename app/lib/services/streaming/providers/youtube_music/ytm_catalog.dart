part of '../youtube_music_provider.dart';

extension _YtmCatalog on YouTubeMusicProvider {
  Future<StreamingCatalog> _syncLibraryImpl({
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final tracksJson = await _browse('FEmusic_liked_videos', cancel: cancel);
    final playlistsJson =
        await _browse('FEmusic_liked_playlists', cancel: cancel);
    final albumsJson = await _browse('FEmusic_liked_albums', cancel: cancel);

    final tracks = _parseTracksFromJson(tracksJson);
    final playlists = _parsePlaylistsFromJson(playlistsJson);
    final albums = _parseAlbumsFromJson(albumsJson);

    final nextCatalog = StreamingCatalog(
      tracks: tracks,
      playlists: playlists,
      albums: albums,
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
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }

    final albums = <StreamingAlbum>[];
    final tracks = <TrackInfo>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};

    void mergePayload(Map<String, dynamic> payload) {
      for (final a in _parseAlbumsFromJson(payload)) {
        if (seenAlbumIds.add(a.id)) {
          albums.add(a);
        }
      }
      for (final t in _parseTracksFromJson(payload)) {
        if (seenTrackIds.add(t.id)) {
          tracks.add(t);
        }
      }
    }

    if (!forceRefresh && batchIndex == 0) {
      final homeJson = await _browse(
        'FEmusic_home',
        forceRefresh: false,
        cancel: cancel,
      );
      _nextHomeContinuation = _extractContinuationToken(homeJson);
      mergePayload(homeJson);

      if (albums.isEmpty && tracks.isEmpty) {
        final exploreJson = await _browse(
          'FEmusic_explore',
          forceRefresh: false,
          cancel: cancel,
        );
        _nextExploreContinuation = _extractContinuationToken(exploreJson);
        mergePayload(exploreJson);
      }
    } else {
      final useExplorePrimary = batchIndex % 2 == 1;
      if (useExplorePrimary) {
        final exploreCont = _nextExploreContinuation;
        try {
          final exploreJson = await _browse(
            'FEmusic_explore',
            continuation: exploreCont,
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          _nextExploreContinuation = _extractContinuationToken(exploreJson);
          mergePayload(exploreJson);
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

      if (albums.isEmpty ||
          tracks.isEmpty ||
          albums.every((a) => excludeAlbumIds.contains(a.id))) {
        final homeCont = _nextHomeContinuation;
        try {
          final homeJson = await _browse(
            'FEmusic_home',
            continuation: homeCont,
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          _nextHomeContinuation = _extractContinuationToken(homeJson);
          mergePayload(homeJson);
        } on StreamingException catch (e) {
          if (homeCont == null ||
              e.isTokenExpired ||
              e.isCancelled ||
              e.statusCode == 401 ||
              e.statusCode == 403 ||
              e.statusCode == null) {
            rethrow;
          }
          // Continuation expired; retry root home page cleanly.
          _nextHomeContinuation = null;
          final homeJson = await _browse(
            'FEmusic_home',
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          _nextHomeContinuation = _extractContinuationToken(homeJson);
          mergePayload(homeJson);
        }
      }

      if (albums.isEmpty && tracks.isEmpty) {
        final homeJson = await _browse(
          'FEmusic_home',
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        _nextHomeContinuation = _extractContinuationToken(homeJson);
        mergePayload(homeJson);
      }

      if (tracks.isEmpty ||
          tracks.every((t) => excludeTrackIds.contains(t.id))) {
        final directSeeds = [...tracks, ...catalog.tracks]
            .map(_extractSeedVideoId)
            .where((id) => id.isNotEmpty)
            .toList(growable: false);
        final pool = directSeeds.isNotEmpty ? directSeeds : _recentSeedVideoIds;
        final seedVideoId = pool.isNotEmpty
            ? pool[batchIndex % pool.length]
            : '';
        if (seedVideoId.isNotEmpty) {
          try {
            final nextJson = await _fetchWatchNextRadio(
              seedVideoId,
              forceRefresh: forceRefresh,
              cancel: cancel,
            );
            mergePayload(nextJson);
            for (final t in _parsePlaylistPanelTracks(nextJson)) {
              if (seenTrackIds.add(t.id)) {
                tracks.add(t);
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
      }
    }

    for (final t in tracks) {
      final vid = _extractSeedVideoId(t);
      if (vid.isNotEmpty && !_recentSeedVideoIds.contains(vid)) {
        _recentSeedVideoIds.add(vid);
        if (_recentSeedVideoIds.length > 20) {
          _recentSeedVideoIds.removeAt(0);
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

  Future<CanonicalAlbumDetail?> _fetchAlbumDetailImpl(
    String albumId, {
    CancellationToken? cancel,
  }) async {
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }

    var cleanId = BaseStreamingProvider.stripTrackPrefix(
      albumId,
      'streaming:$kind',
    );
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, kind);
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, 'ytm');
    if (cleanId.isEmpty) return null;

    final json = await _browse(cleanId, cancel: cancel);
    final header = _findFirstMapByKey(json, 'musicResponsiveHeaderRenderer') ??
        _findFirstMapByKey(json, 'musicDetailHeaderRenderer') ??
        (json['header'] is Map
            ? Map<String, dynamic>.from(json['header'] as Map)
            : <String, dynamic>{});

    final title = _extractInnerTubeText(header['title']) ??
        _extractInnerTubeText(json['title']) ??
        'YouTube Music Album';
    final artist = _extractInnerTubeText(header['straplineTextOne']) ??
        _extractInnerTubeText(header['subtitle']) ??
        _extractInnerTubeText(json['artist']) ??
        '未知藝術家';
    final bio = _extractInnerTubeText(header['description']) ??
        _extractInnerTubeText(json['description']);
    final coverUrl = _extractThumbnailUrl(header['thumbnail']) ??
        _extractThumbnailUrl(json['thumbnail']) ??
        BaseStreamingProvider.upgradeCoverUrl(
          json['cover_url']?.toString(),
          targetSize: 1200,
        );

    int? releaseYear = (json['year'] as num?)?.toInt();
    final subText = _extractInnerTubeText(header['subtitle']) ?? '';
    if (releaseYear == null && subText.isNotEmpty) {
      final match = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(subText);
      if (match != null) {
        releaseYear = int.tryParse(match.group(1)!);
      }
    }

    final parsedTracks = _parseTracksFromJson(
      json,
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
          codec: t.format.codec.name,
          sampleRateHz: t.format.sampleRateHz,
          bitDepth: t.format.bitDepth,
          externalTrackId: t.id,
        ),
      );
    }

    return CanonicalAlbumDetail(
      id: 'streaming:$kind:$cleanId',
      title: title,
      artistName: artist.split(RegExp(r'\s*[•·]\s*')).first.trim(),
      releaseYear: releaseYear,
      editorialBio: bio,
      coverUrl: coverUrl,
      versions: <AlbumVersionInfo>[
        AlbumVersionInfo(
          id: 'ver_ytm_$cleanId',
          provider: kind,
          externalAlbumId: cleanId,
          editionLabel: 'YouTube Music',
          codec: 'opus',
          sampleRateHz: 48000,
          bitDepth: 16,
          tracks: versionTracks,
        ),
      ],
    );
  }

  Future<List<TrackInfo>> _fetchPlaylistTracksImpl(String playlistId) async {
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }

    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'ytm');
    final json = await _browse(cleanId);
    return _parseTracksFromJson(json);
  }

  Future<StreamingCatalog> _searchImpl(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }
    cancel?.throwIfCancelled();

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return StreamingCatalog(syncedAt: clock());
    }

    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/search',
      const <String, String>{'prettyPrint': 'false'},
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildWebRemixHeaders(
        authenticated: authState == StreamingAuthState.connected,
      ),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'query': trimmed,
      },
      cancel: cancel,
    );
    _captureVisitorData(json);
    cancel?.throwIfCancelled();

    final tracks = _parseTracksFromJson(json);
    final albums = _parseAlbumsFromJson(json);
    final playlists = _parsePlaylistsFromJson(json);

    return StreamingCatalog(
      tracks: tracks,
      playlists: playlists,
      albums: albums,
      syncedAt: clock(),
    );
  }
}
