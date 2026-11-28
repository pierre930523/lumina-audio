part of '../youtube_music_provider.dart';

extension _YtmPodcastsApi on YouTubeMusicProvider {
  Future<PodcastLibraryResult> _fetchMyPodcastsImpl({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState != StreamingAuthState.connected) {
      return const PodcastLibraryResult();
    }
    await refreshSessionIfNeeded();
    cancel?.throwIfCancelled();

    final shows = <PodcastShow>[];
    final episodes = <PodcastEpisode>[];
    final seenShowIds = <String>{};
    final seenVideoIds = <String>{};
    String? continuationToken;

    final libJson = await _browse(
      'FEmusic_library_non_music_audio_list',
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    for (final s in _parsePodcastShowsFromJson(
      libJson,
      allowAllShowItems: true,
    )) {
      if (seenShowIds.add(s.id)) {
        shows.add(s);
      }
    }
    for (final ep in _parsePodcastEpisodesFromJson(
      libJson,
      allowAllResponsiveItems: false,
    )) {
      if (seenVideoIds.add(ep.videoId)) {
        episodes.add(ep);
      }
    }
    continuationToken = _extractPodcastEpisodeContinuationToken(libJson);

    if (episodes.isEmpty) {
      try {
        final newEpsJson = await _browse('VLSE', cancel: cancel);
        for (final ep in _parsePodcastEpisodesFromJson(
          newEpsJson,
          allowAllResponsiveItems: true,
        )) {
          if (seenVideoIds.add(ep.videoId)) {
            episodes.add(ep);
          }
        }
        continuationToken ??=
            _extractPodcastEpisodeContinuationToken(newEpsJson);
      } on StreamingException catch (e) {
        if (e.isCancelled) rethrow;
      } catch (_) {}
    }

    return PodcastLibraryResult(
      shows: shows,
      episodes: episodes,
      continuationToken: continuationToken,
    );
  }

  Future<PodcastExploreResult> _fetchExplorePodcastsImpl({
    String? continuation,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
      cancel?.throwIfCancelled();
    }

    final shows = <PodcastShow>[];
    final episodes = <PodcastEpisode>[];
    final seenShowIds = <String>{};
    final seenVideoIds = <String>{};
    String? nextContinuation;

    void mergeFromJson(
      Map<String, dynamic> payload, {
      bool allowAllShows = false,
      bool allowAllEpisodes = false,
    }) {
      for (final s in _parsePodcastShowsFromJson(
        payload,
        allowAllShowItems: allowAllShows,
      )) {
        if (seenShowIds.add(s.id)) {
          shows.add(s);
        }
      }
      for (final ep in _parsePodcastEpisodesFromJson(
        payload,
        allowAllResponsiveItems: allowAllEpisodes,
      )) {
        if (seenVideoIds.add(ep.videoId)) {
          episodes.add(ep);
        }
      }
      nextContinuation ??= _extractPodcastEpisodeContinuationToken(payload);
    }

    if (continuation != null && continuation.trim().isNotEmpty) {
      final json = await _browse(
        'FEmusic_podcasts',
        continuation: continuation.trim(),
        cancel: cancel,
      );
      mergeFromJson(json, allowAllShows: true, allowAllEpisodes: true);
      return PodcastExploreResult(
        shows: shows,
        episodes: episodes,
        continuationToken: nextContinuation,
      );
    }

    // 1. Primary browse: FEmusic_podcasts
    try {
      final podcastsJson = await _browse('FEmusic_podcasts', cancel: cancel);
      mergeFromJson(podcastsJson, allowAllShows: true, allowAllEpisodes: true);
    } on StreamingException catch (e) {
      if (e.isCancelled || e.isTokenExpired || e.statusCode == 401) {
        rethrow;
      }
    }

    // 2. Secondary browse fallback: FEmusic_non_music_audio
    if (shows.isEmpty && episodes.isEmpty) {
      cancel?.throwIfCancelled();
      try {
        final nonMusicJson = await _browse(
          'FEmusic_non_music_audio',
          cancel: cancel,
        );
        mergeFromJson(
          nonMusicJson,
          allowAllShows: true,
          allowAllEpisodes: true,
        );
      } on StreamingException catch (e) {
        if (e.isCancelled || e.isTokenExpired || e.statusCode == 401) {
          rethrow;
        }
      }
    }

    // 3. Locale fallback (e.g. TW where FEmusic_podcasts returns 404):
    //    query real YouTube Music Podcast shows & episodes via /youtubei/v1/search.
    if (shows.isEmpty && episodes.isEmpty) {
      cancel?.throwIfCancelled();
      final searchFallback = await searchPodcasts('Podcast', cancel: cancel);
      for (final s in searchFallback.shows) {
        if (seenShowIds.add(s.id)) {
          shows.add(s);
        }
      }
      for (final ep in searchFallback.episodes) {
        if (seenVideoIds.add(ep.videoId)) {
          episodes.add(ep);
        }
      }
      nextContinuation ??= searchFallback.continuationToken;
    }

    return PodcastExploreResult(
      shows: shows,
      episodes: episodes,
      continuationToken: nextContinuation,
    );
  }

  Future<PodcastSearchResult> _searchPodcastsImpl(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
      cancel?.throwIfCancelled();
    }

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const PodcastSearchResult();
    }

    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/search',
      const <String, String>{'prettyPrint': 'false'},
    );
    final isConnected = authState == StreamingAuthState.connected;

    final shows = <PodcastShow>[];
    final episodes = <PodcastEpisode>[];
    final seenShowIds = <String>{};
    final seenVideoIds = <String>{};
    String? continuationToken;

    // 1. Search with Podcast Shows filter (also captures any episodes if a
    //    combined shelf or test fixture is returned).
    final showsJson = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildWebRemixHeaders(authenticated: isConnected),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'query': trimmed,
        'params': YouTubeMusicProvider.podcastShowsSearchParams,
      },
      cancel: cancel,
    );
    _captureVisitorData(showsJson);
    cancel?.throwIfCancelled();

    for (final s in _parsePodcastShowsFromJson(
      showsJson,
      allowAllShowItems: true,
    )) {
      if (seenShowIds.add(s.id)) {
        shows.add(s);
      }
    }
    for (final ep in _parsePodcastEpisodesFromJson(
      showsJson,
      allowAllResponsiveItems: false,
    )) {
      if (seenVideoIds.add(ep.videoId)) {
        episodes.add(ep);
      }
    }
    continuationToken = _extractPodcastEpisodeContinuationToken(showsJson);

    // 2. If no episodes were included in the show-filtered response, query
    //    with the Podcast Episodes filter to populate playable episodes.
    if (episodes.isEmpty) {
      try {
        final epsJson = await http.requestJson(
          method: 'POST',
          uri: uri,
          headers: _buildWebRemixHeaders(authenticated: isConnected),
          jsonBody: <String, dynamic>{
            'context': _buildWebRemixContext(),
            'query': trimmed,
            'params': YouTubeMusicProvider.podcastEpisodesSearchParams,
          },
          cancel: cancel,
        );
        _captureVisitorData(epsJson);
        for (final ep in _parsePodcastEpisodesFromJson(
          epsJson,
          allowAllResponsiveItems: true,
        )) {
          if (seenVideoIds.add(ep.videoId)) {
            episodes.add(ep);
          }
        }
        for (final s in _parsePodcastShowsFromJson(
          epsJson,
          allowAllShowItems: false,
        )) {
          if (seenShowIds.add(s.id)) {
            shows.add(s);
          }
        }
        continuationToken ??= _extractPodcastEpisodeContinuationToken(epsJson);
      } on StreamingException catch (e) {
        if (e.isCancelled) rethrow;
      } catch (_) {}
    }

    return PodcastSearchResult(
      shows: shows,
      episodes: episodes,
      continuationToken: continuationToken,
    );
  }

  Future<PodcastShowDetail> _fetchPodcastShowDetailImpl(
    String showBrowseId, {
    String? continuation,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
      cancel?.throwIfCancelled();
    }

    var cleanId = BaseStreamingProvider.stripTrackPrefix(
      showBrowseId.trim(),
      'streaming:$kind',
    );
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, kind);
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, 'ytm');
    if (cleanId.startsWith('PL') && !cleanId.startsWith('MPSP')) {
      cleanId = 'MPSP$cleanId';
    }
    if (cleanId.isEmpty) {
      throw const StreamingException('Podcast 節目缺少有效的 browseId');
    }

    final json = await _browse(
      cleanId,
      continuation: continuation,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    final header = _findFirstMapByKey(json, 'musicResponsiveHeaderRenderer') ??
        _findFirstMapByKey(json, 'musicDetailHeaderRenderer') ??
        (json['header'] is Map
            ? Map<String, dynamic>.from(json['header'] as Map)
            : <String, dynamic>{});

    final title = (_extractInnerTubeText(header['title']) ??
            _extractInnerTubeText(json['title']) ??
            'Podcast 節目')
        .trim();
    final author = (_extractInnerTubeText(header['straplineTextOne']) ??
            _extractInnerTubeText(header['subtitle']) ??
            _extractInnerTubeText(json['author']) ??
            '')
        .trim();
    final description = _extractPodcastDescription(header['description']) ??
        _extractPodcastDescription(json['description']);
    final artworkUrl = _extractThumbnailUrl(header['thumbnail']) ??
        _extractRootFallbackThumbnail(json);
    final secondSub = _extractInnerTubeText(header['secondSubtitle'])?.trim();

    final episodes = _parsePodcastEpisodesFromJson(
      json,
      fallbackShowId: cleanId,
      fallbackShowTitle: title,
      fallbackAuthor: author,
      fallbackArtworkUrl: artworkUrl,
      allowAllResponsiveItems: true,
    );

    final nextContinuation = _extractPodcastEpisodeContinuationToken(json);

    final show = PodcastShow(
      id: cleanId,
      title: title,
      author: author,
      artworkUrl: artworkUrl,
      description: description,
      episodeCountLabel: secondSub != null && secondSub.isNotEmpty
          ? secondSub
          : (episodes.isNotEmpty ? '${episodes.length} 集' : null),
      latestEpisodeTitle:
          episodes.isNotEmpty ? episodes.first.title : null,
    );

    return PodcastShowDetail(
      show: show,
      episodes: episodes,
      continuationToken: nextContinuation,
    );
  }
}
