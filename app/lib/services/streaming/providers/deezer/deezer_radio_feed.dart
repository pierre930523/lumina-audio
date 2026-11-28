part of '../deezer_provider.dart';

extension _DeezerRadioFeed on DeezerProvider {
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

    final effectiveLimit = limit > 0 ? limit : 10;
    final rawOffset = int.tryParse(cursor?.trim() ?? '') ?? 0;
    final offset = rawOffset < 0 ? 0 : rawOffset;

    final lowerId = seed.trackId.trim().toLowerCase();
    final isDeezerSeed = seed.providerId == kind ||
        lowerId.startsWith('deezer:') ||
        lowerId.startsWith('streaming:deezer:');
    final cleanSeedTrackId = isDeezerSeed
        ? BaseStreamingProvider.stripTrackPrefix(
            BaseStreamingProvider.stripTrackPrefix(
              seed.trackId.trim(),
              'streaming:deezer',
            ),
            'deezer',
          )
        : '';

    var artistId = seed.artistId?.trim() ?? '';
    if (artistId.isEmpty && cleanSeedTrackId.isNotEmpty) {
      try {
        final trackJson = await _callPublicApi(
          '/track/$cleanSeedTrackId',
          cancel: cancel,
        );
        final artObj = trackJson['artist'];
        if (artObj is Map) {
          artistId = artObj['id']?.toString().trim() ?? '';
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || cancel?.isCancelled == true) {
          throw _mapRecError(e);
        }
      }
    }

    if (artistId.isEmpty) {
      final artistQuery = seed.primaryArtist.trim().isNotEmpty
          ? seed.primaryArtist.trim()
          : seed.artist.trim();
      if (artistQuery.isNotEmpty) {
        try {
          final searchArtistJson = await _callPublicApi(
            '/search/artist',
            query: <String, String>{'q': artistQuery, 'limit': '5'},
            cancel: cancel,
          );
          final data = searchArtistJson['data'];
          if (data is List && data.isNotEmpty && data.first is Map) {
            artistId = (data.first as Map)['id']?.toString().trim() ?? '';
          }
        } on StreamingException catch (e) {
          if (e.isCancelled || cancel?.isCancelled == true) {
            throw _mapRecError(e);
          }
        }
      }
    }

    final pools = <List<TrackMetadata>>[];

    if (artistId.isNotEmpty) {
      try {
        final radioJson = await _callPublicApi(
          '/artist/$artistId/radio',
          query: const <String, String>{'limit': '40'},
          cancel: cancel,
        );
        final radioTracks = _parseTracks(
              radioJson['data'],
              md5FallbackSize: 1000,
            )
            .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
            .toList(growable: false);
        if (radioTracks.isNotEmpty) {
          pools.add(radioTracks);
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || cancel?.isCancelled == true) {
          throw _mapRecError(e);
        }
      }

      try {
        final relatedJson = await _callPublicApi(
          '/artist/$artistId/related',
          query: const <String, String>{'limit': '5'},
          cancel: cancel,
        );
        final relData = relatedJson['data'];
        if (relData is List) {
          final relIds = <String>[];
          for (final item in relData) {
            if (item is Map) {
              final rid = item['id']?.toString().trim() ?? '';
              if (rid.isNotEmpty && rid != artistId) {
                relIds.add(rid);
              }
            }
            if (relIds.length >= 3) break;
          }
          for (final relId in relIds) {
            try {
              final topJson = await _callPublicApi(
                '/artist/$relId/top',
                query: const <String, String>{'limit': '15'},
                cancel: cancel,
              );
              final topTracks = _parseTracks(
                    topJson['data'],
                    md5FallbackSize: 1000,
                  )
                  .map(
                    (t) => TrackMetadata.fromTrackInfo(
                      t,
                      providerIdOverride: kind,
                    ),
                  )
                  .toList(growable: false);
              if (topTracks.isNotEmpty) {
                pools.add(topTracks);
              }
            } on StreamingException catch (e) {
              if (e.isCancelled || cancel?.isCancelled == true) {
                throw _mapRecError(e);
              }
            }
          }
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || cancel?.isCancelled == true) {
          throw _mapRecError(e);
        }
      }
    }

    if (authState == StreamingAuthState.connected) {
      try {
        final personalJson = await _callPublicApi(
          '/user/me/recommendations/tracks',
          query: const <String, String>{'limit': '20'},
          cancel: cancel,
        );
        final personalTracks = _parseTracks(
              personalJson['data'],
              md5FallbackSize: 1000,
            )
            .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
            .toList(growable: false);
        if (personalTracks.isNotEmpty) {
          pools.add(personalTracks);
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || cancel?.isCancelled == true) {
          throw _mapRecError(e);
        }
      } catch (_) {}
    }

    final blended = <TrackMetadata>[];
    final seenIds = <String>{};
    var idx = 0;
    while (true) {
      var progressed = false;
      for (final pool in pools) {
        if (idx < pool.length) {
          progressed = true;
          final item = pool[idx];
          if (cleanSeedTrackId.isNotEmpty && item.trackId == cleanSeedTrackId) {
            continue;
          }
          if (seenIds.add(item.trackId)) {
            blended.add(item);
          }
        }
      }
      if (!progressed) break;
      idx++;
    }

    final pageTracks = blended
        .skip(offset)
        .take(effectiveLimit)
        .toList(growable: false);
    final nextCursor = blended.length > offset + effectiveLimit
        ? '${offset + effectiveLimit}'
        : null;

    return RadioPage(
      tracks: pageTracks,
      nextCursor: nextCursor,
      sourceLabel: 'Deezer Artist Radio',
    );
  }

  Future<List<FeedSection>> _getPersonalizedFeedImpl({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState != StreamingAuthState.connected) {
      return const <FeedSection>[];
    }

    final sections = <FeedSection>[];
    final uid = _userId?.trim();

    Future<Map<String, dynamic>?> fetchWithFallback(
      String mePath,
      String? uidPath,
    ) async {
      try {
        return await _callPublicApi(
          mePath,
          query: const <String, String>{'limit': '20'},
          cancel: cancel,
        );
      } on StreamingException catch (e) {
        if (e.isCancelled) throw _mapRecError(e);
        if (uidPath == null) {
          if (e.statusCode == 401 || e.isTokenExpired) throw _mapRecError(e);
          return null;
        }
        try {
          return await _callPublicApi(
            uidPath,
            query: const <String, String>{'limit': '20'},
            cancel: cancel,
          );
        } on StreamingException catch (e2) {
          if (e2.isCancelled || e2.statusCode == 401 || e2.isTokenExpired) {
            throw _mapRecError(e2);
          }
          return null;
        }
      }
    }

    final tracksJson = await fetchWithFallback(
      '/user/me/recommendations/tracks',
      (uid != null && uid.isNotEmpty)
          ? '/user/$uid/recommendations/tracks'
          : null,
    );
    if (tracksJson != null) {
      final tracks = _parseTracks(
            tracksJson['data'],
            md5FallbackSize: 1000,
          )
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      if (tracks.isNotEmpty) {
        sections.add(
          FeedSection(
            id: 'deezer_rec_tracks',
            title: 'Deezer Recommended Tracks',
            providerId: kind,
            tracks: tracks,
          ),
        );
      }
    }

    final albumsJson = await fetchWithFallback(
      '/user/me/recommendations/albums',
      (uid != null && uid.isNotEmpty)
          ? '/user/$uid/recommendations/albums'
          : null,
    );
    if (albumsJson != null) {
      final albums = _parseAlbums(albumsJson['data']);
      if (albums.isNotEmpty) {
        sections.add(
          FeedSection(
            id: 'deezer_rec_albums',
            title: 'Deezer Recommended Albums',
            providerId: kind,
            albums: albums,
          ),
        );
      }
    }

    return List<FeedSection>.unmodifiable(sections);
  }

  Future<TrackMetadata?> _matchTrackImpl(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();

    final normIsrc = TrackMatcher.normalizeIsrc(query.isrc);
    if (normIsrc != null) {
      try {
        final isrcJson = await _callPublicApi(
          '/track/isrc:$normIsrc',
          cancel: cancel,
        );
        if (isrcJson['id'] != null) {
          final parsed = _parseTracks(
                <dynamic>[isrcJson],
                md5FallbackSize: 1000,
              )
              .map(
                (t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind),
              )
              .toList(growable: false);
          if (parsed.isNotEmpty) {
            return parsed.first;
          }
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || cancel?.isCancelled == true) {
          throw _mapRecError(e);
        }
      }
    }

    final artist = query.artist.trim();
    final title = query.title.trim();
    if (title.isEmpty && artist.isEmpty) return null;

    final queries = <String>[
      if (artist.isNotEmpty && title.isNotEmpty)
        'artist:"$artist" track:"$title"',
      '$artist $title'.trim(),
    ];

    for (final q in queries) {
      if (q.isEmpty) continue;
      try {
        final searchJson = await _callPublicApi(
          '/search/track',
          query: <String, String>{'q': q, 'limit': '15'},
          cancel: cancel,
        );
        final candidates = _parseTracks(
              searchJson['data'],
              md5FallbackSize: 1000,
            )
            .map(
              (t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind),
            )
            .toList(growable: false);
        final best = TrackMatcher.selectBestMatch(query, candidates);
        if (best != null) return best;
      } on StreamingException catch (e) {
        if (e.isCancelled || cancel?.isCancelled == true) {
          throw _mapRecError(e);
        }
        throw _mapRecError(e);
      }
    }

    return null;
  }
}
