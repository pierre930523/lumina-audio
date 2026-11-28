part of '../youtube_music_provider.dart';

extension _YtmRecommendations on YouTubeMusicProvider {
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

  Future<StreamingCatalog> _searchWithGuestFallback(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return StreamingCatalog(syncedAt: clock());

    Future<StreamingCatalog> postSearch({required bool authenticated}) async {
      final uri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/youtubei/v1/search',
        const <String, String>{'prettyPrint': 'false'},
      );
      final json = await http.requestJson(
        method: 'POST',
        uri: uri,
        headers: _buildWebRemixHeaders(authenticated: authenticated),
        jsonBody: <String, dynamic>{
          'context': _buildWebRemixContext(),
          'query': trimmed,
        },
        cancel: cancel,
      );
      _captureVisitorData(json);
      return StreamingCatalog(
        tracks: _parseTracksFromJson(json),
        playlists: _parsePlaylistsFromJson(json),
        albums: _parseAlbumsFromJson(json),
        syncedAt: clock(),
      );
    }

    final isConnected = authState == StreamingAuthState.connected;
    if (!isConnected) {
      return postSearch(authenticated: false);
    }
    try {
      await refreshSessionIfNeeded();
      return await postSearch(authenticated: true);
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
      if (e.statusCode == 401 || e.isTokenExpired) {
        return postSearch(authenticated: false);
      }
      rethrow;
    }
  }

  Future<RadioPage> _getTrackRadioImpl(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();

    String? videoId;
    final rawTrackId = seed.trackId.trim();
    final lowerTrackId = rawTrackId.toLowerCase();
    final rawFilePath = seed.filePath?.trim();
    final lowerFilePath = rawFilePath?.toLowerCase() ?? '';
    final isExplicitYtmSeed = seed.providerId == kind ||
        seed.providerId.isEmpty ||
        lowerTrackId.startsWith('ytm:') ||
        lowerTrackId.startsWith('ytm_') ||
        lowerTrackId.startsWith('youtube_music:') ||
        lowerTrackId.startsWith('streaming:youtube_music:') ||
        lowerTrackId.contains('youtube.com') ||
        lowerTrackId.contains('youtu.be') ||
        lowerFilePath.contains('youtube.com') ||
        lowerFilePath.contains('youtu.be');

    if (isExplicitYtmSeed) {
      videoId = _ytmTryExtractCleanVideoId(rawTrackId, filePath: rawFilePath);
    }

    if (videoId == null || videoId.isEmpty) {
      final queryText = '${seed.artist.trim()} ${seed.title.trim()}'.trim();
      if (queryText.isNotEmpty) {
        try {
          final catalog = await _searchWithGuestFallback(
            queryText,
            cancel: cancel,
          );
          final candidates = catalog.tracks
              .where((t) => _ytmTryExtractCleanVideoId(t.id) != null)
              .map(
                (t) => TrackMetadata.fromTrackInfo(
                  t,
                  providerIdOverride: kind,
                ),
              )
              .toList(growable: false);
          if (candidates.isNotEmpty) {
            final best = TrackMatcher.selectBestMatch(
                  TrackMatchQuery.fromTrackMetadata(seed),
                  candidates,
                ) ??
                candidates.first;
            videoId = _ytmTryExtractCleanVideoId(
              best.trackId,
              filePath: best.filePath,
            );
          }
        } on StreamingException catch (e) {
          throw _mapRecError(e);
        }
      }
    }

    if (videoId == null || videoId.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'YouTube Music Radio',
      );
    }

    try {
      Map<String, dynamic> nextJson;
      try {
        nextJson = await _fetchWatchNextRadio(
          videoId,
          continuation: cursor,
          cancel: cancel,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            authState == StreamingAuthState.connected &&
            (e.statusCode == 401 || e.isTokenExpired)) {
          // Fallback to unauthenticated Guest request if session cookies expired.
          final trimmedCont = cursor?.trim();
          final hasCont = trimmedCont != null && trimmedCont.isNotEmpty;
          final uri = BaseStreamingProvider.buildUri(
            baseUrl,
            '/youtubei/v1/next',
            <String, String>{
              'prettyPrint': 'false',
              if (hasCont) ...<String, String>{
                'ctoken': trimmedCont,
                'continuation': trimmedCont,
              },
            },
          );
          nextJson = await http.requestJson(
            method: 'POST',
            uri: uri,
            headers: _buildWebRemixHeaders(authenticated: false),
            jsonBody: <String, dynamic>{
              'context': _buildWebRemixContext(),
              'videoId': videoId,
              'playlistId': 'RDAMVM$videoId',
              'isAudioOnly': true,
              if (hasCont) 'continuation': trimmedCont,
            },
            cancel: cancel,
          );
          _captureVisitorData(nextJson);
        } else {
          rethrow;
        }
      }

      final tracks = <TrackMetadata>[];
      final seenIds = <String>{};

      void addCandidateTracks(List<TrackInfo> parsed) {
        for (final t in parsed) {
          final clean = _ytmTryExtractCleanVideoId(t.id, filePath: t.filePath);
          if (clean == null || clean == videoId) continue;
          if (seenIds.add(clean)) {
            tracks.add(
              TrackMetadata.fromTrackInfo(t, providerIdOverride: kind),
            );
          }
        }
      }

      addCandidateTracks(_parsePlaylistPanelTracks(nextJson));
      addCandidateTracks(_parseTracksFromJson(nextJson));

      final effectiveLimit = limit > 0 ? limit : tracks.length;
      final limitedTracks = tracks.length > effectiveLimit
          ? tracks.take(effectiveLimit).toList(growable: false)
          : tracks;
      final nextCursor = _extractContinuationToken(nextJson);

      return RadioPage(
        tracks: limitedTracks,
        nextCursor: nextCursor,
        sourceLabel: 'YouTube Music Radio',
      );
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }

  List<TrackInfo> _parseTwoRowVideoTracks(Map<String, dynamic> root) {
    final tracks = <TrackInfo>[];
    final seenIds = <String>{};
    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final nav = item['navigationEndpoint'];
      if (nav is! Map) continue;
      final watch = nav['watchEndpoint'];
      if (watch is! Map) continue;
      final rawVid = watch['videoId']?.toString().trim() ?? '';
      final videoId = _ytmTryExtractCleanVideoId(rawVid);
      if (videoId == null || !seenIds.add(videoId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名曲目';
      final subtitle = _extractInnerTubeText(item['subtitle']) ?? '';
      final parts = subtitle
          .split(RegExp(r'\s*[•·]\s*'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      final artist = parts.isNotEmpty ? parts.first : '未知藝術家';
      final album = (parts.length >= 2 &&
              !parts[1].toLowerCase().contains('play') &&
              !parts[1].toLowerCase().contains('view'))
          ? parts[1]
          : 'YouTube Music';
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']) ??
          _extractThumbnailUrl(item['thumbnail']);

      tracks.add(
        TrackInfo(
          id: 'ytm:$videoId',
          title: title,
          artist: artist,
          album: album,
          duration: Duration.zero,
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          format: const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'YouTube Music',
        ),
      );
    }
    return tracks;
  }

  Future<List<FeedSection>> _getPersonalizedFeedImpl({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState != StreamingAuthState.connected) {
      return const <FeedSection>[];
    }

    try {
      await refreshSessionIfNeeded();
      final homeJson = await _browse('FEmusic_home', cancel: cancel);

      final sections = <FeedSection>[];
      var idx = 0;

      void collectShelf(Map<String, dynamic> shelf, {required bool isCarousel}) {
        String? title;
        String? subtitle;
        if (isCarousel) {
          final header = shelf['header'];
          final basicHeader = header is Map
              ? (header['musicCarouselShelfBasicHeaderRenderer'] is Map
                    ? header['musicCarouselShelfBasicHeaderRenderer'] as Map
                    : header)
              : null;
          title = _extractInnerTubeText(basicHeader?['title']);
          subtitle = _extractInnerTubeText(basicHeader?['strapline']);
        } else {
          title = _extractInnerTubeText(shelf['title']);
          subtitle = _extractInnerTubeText(shelf['subtitle']);
        }

        final mergedTracks = <TrackMetadata>[];
        final seenTrackIds = <String>{};
        for (final t in <TrackInfo>[
          ..._parseTracksFromJson(shelf),
          ..._parseTwoRowVideoTracks(shelf),
        ]) {
          final meta = TrackMetadata.fromTrackInfo(
            t,
            providerIdOverride: kind,
          );
          if (seenTrackIds.add(meta.trackId)) {
            mergedTracks.add(meta);
          }
        }
        final albums = _parseAlbumsFromJson(shelf);
        if (mergedTracks.isNotEmpty || albums.isNotEmpty) {
          sections.add(
            FeedSection(
              id: 'ytm_home_${idx++}',
              title: (title != null && title.trim().isNotEmpty)
                  ? title.trim()
                  : 'YouTube Music',
              subtitle: (subtitle != null && subtitle.trim().isNotEmpty)
                  ? subtitle.trim()
                  : null,
              providerId: kind,
              tracks: mergedTracks,
              albums: albums,
            ),
          );
        }
      }

      for (final carousel
          in _collectMapsByKey(homeJson, 'musicCarouselShelfRenderer')) {
        collectShelf(carousel, isCarousel: true);
      }
      for (final shelf in _collectMapsByKey(homeJson, 'musicShelfRenderer')) {
        collectShelf(shelf, isCarousel: false);
      }

      if (sections.isEmpty) {
        final mergedTracks = <TrackMetadata>[];
        final seenTrackIds = <String>{};
        for (final t in <TrackInfo>[
          ..._parseTracksFromJson(homeJson),
          ..._parseTwoRowVideoTracks(homeJson),
        ]) {
          final meta = TrackMetadata.fromTrackInfo(
            t,
            providerIdOverride: kind,
          );
          if (seenTrackIds.add(meta.trackId)) {
            mergedTracks.add(meta);
          }
        }
        final albums = _parseAlbumsFromJson(homeJson);
        if (mergedTracks.isNotEmpty || albums.isNotEmpty) {
          sections.add(
            FeedSection(
              id: 'ytm_home_0',
              title: 'YouTube Music Home',
              providerId: kind,
              tracks: mergedTracks,
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
    final searchText = '${query.artist.trim()} ${query.title.trim()}'.trim();
    if (searchText.isEmpty) return null;

    try {
      final catalog = await _searchWithGuestFallback(
        searchText,
        cancel: cancel,
      );
      final candidates = catalog.tracks
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      return TrackMatcher.selectBestMatch(query, candidates);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }
}
