part of '../tidal_provider.dart';

String _stripTidalPrefix(String raw) {
  var clean = BaseStreamingProvider.stripTrackPrefix(
    raw.trim(),
    'streaming:tidal',
  );
  clean = BaseStreamingProvider.stripTrackPrefix(clean, 'tidal');
  return clean.trim();
}

List<String> _dedupeSeedIds(Iterable<String> rawIds) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in rawIds) {
    final clean = _stripTidalPrefix(raw);
    if (clean.isNotEmpty && seen.add(clean)) {
      result.add(clean);
    }
  }
  return result;
}

void _rememberRecentIds(
  List<String> target,
  Iterable<String> ids, {
  int maxCount = 32,
}) {
  for (final raw in ids) {
    final id = raw.trim();
    if (id.isEmpty) continue;
    target.remove(id);
    target.add(id);
  }
  if (target.length > maxCount) {
    target.removeRange(0, target.length - maxCount);
  }
}

extension _TidalCatalog on TidalProvider {
  Future<StreamingCatalog> _syncLibraryImpl({CancellationToken? cancel}) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      throw const StreamingException('Tidal 缺少 userId，無法同步曲庫');
    }

    final tracksJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/users/$uid/favorites/tracks',
        <String, String>{'countryCode': _countryCode, 'limit': '100'},
      ),
      headers: _authHeaders,
      cancel: cancel,
    );

    final albumsJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/users/$uid/favorites/albums',
        <String, String>{'countryCode': _countryCode, 'limit': '50'},
      ),
      headers: _authHeaders,
      cancel: cancel,
    );

    final playlistsJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/users/$uid/playlists',
        <String, String>{'countryCode': _countryCode, 'limit': '50'},
      ),
      headers: _authHeaders,
      cancel: cancel,
    );

    final nextCatalog = StreamingCatalog(
      tracks: _parseTrackList(tracksJson['items']),
      albums: _parseAlbumList(albumsJson['items']),
      playlists: _parsePlaylistList(playlistsJson['items']),
      syncedAt: clock(),
    );
    setCatalog(nextCatalog);
    return nextCatalog;
  }

  String get _apiV2BaseUrl {
    final normalized = BaseStreamingProvider.normalizeBaseUrl(apiBaseUrl);
    if (normalized.endsWith('/v1')) {
      return '${normalized.substring(0, normalized.length - 3)}/v2';
    }
    return '$normalized/v2';
  }

  Future<Map<String, dynamic>> _requestTidalGet(
    String path,
    Map<String, String> query, {
    bool forceRefresh = false,
    CancellationToken? cancel,
  }) {
    final effectiveQuery = <String, String>{
      'countryCode': _countryCode,
      ...query,
    };
    return http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(apiBaseUrl, path, effectiveQuery),
      headers: BaseStreamingProvider.withNoCacheHeaders(
        _authHeaders,
        forceRefresh: forceRefresh,
      ),
      cancel: cancel,
    );
  }

  Future<Map<String, dynamic>> _requestTidalV2Get(
    String path,
    Map<String, String> query, {
    bool forceRefresh = false,
    CancellationToken? cancel,
  }) {
    final effectiveQuery = <String, String>{
      'countryCode': _countryCode,
      ...query,
    };
    return http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        _apiV2BaseUrl,
        path,
        effectiveQuery,
      ),
      headers: BaseStreamingProvider.withNoCacheHeaders(
        _authHeaders,
        forceRefresh: forceRefresh,
      ),
      cancel: cancel,
    );
  }

  Future<Map<String, dynamic>?> _tryTidalGet(
    String path,
    Map<String, String> query, {
    bool forceRefresh = false,
    bool v2 = false,
    CancellationToken? cancel,
  }) async {
    try {
      return await (v2
          ? _requestTidalV2Get(
              path,
              query,
              forceRefresh: forceRefresh,
              cancel: cancel,
            )
          : _requestTidalGet(
              path,
              query,
              forceRefresh: forceRefresh,
              cancel: cancel,
            ));
    } on StreamingException catch (e) {
      if (e.isTokenExpired ||
          e.isCancelled ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == null) {
        rethrow;
      }
      return null;
    }
  }

  Future<CanonicalAlbumDetail?> _fetchAlbumDetailImpl(
    String albumId, {
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    var cleanId = BaseStreamingProvider.stripTrackPrefix(
      albumId,
      'streaming:$kind',
    );
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, kind);
    if (cleanId.isEmpty) return null;

    final albumJson = await _requestTidalGet(
      '/albums/$cleanId',
      <String, String>{'countryCode': _countryCode},
      cancel: cancel,
    );

    dynamic rawTracks = albumJson['items'] ??
        (albumJson['tracks'] is Map
            ? (albumJson['tracks'] as Map)['items']
            : albumJson['tracks']);
    if (rawTracks is! List || rawTracks.isEmpty) {
      try {
        final tracksJson = await _requestTidalGet(
          '/albums/$cleanId/tracks',
          <String, String>{'countryCode': _countryCode, 'limit': '100'},
          cancel: cancel,
        );
        rawTracks = tracksJson['items'];
      } catch (_) {}
    }

    final title = albumJson['title']?.toString() ?? 'Tidal Album';
    final artistObj = albumJson['artist'] is Map
        ? albumJson['artist'] as Map
        : (albumJson['artists'] is List &&
                  (albumJson['artists'] as List).isNotEmpty
              ? (albumJson['artists'] as List).first as Map?
              : null);
    final artistName = artistObj?['name']?.toString() ?? '未知藝術家';
    final releaseDate = albumJson['releaseDate']?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4
        ? int.tryParse(releaseDate.substring(0, 4))
        : null;
    final coverUrl = _extractTidalCoverFromMap(albumJson, size: 1280);
    final resolvedQuality = _resolveEffectiveTidalQuality(albumJson);
    final quality = resolvedQuality.isNotEmpty ? resolvedQuality : 'LOSSLESS';
    final albumFmt = _formatForTidalQuality(quality);

    final parsedTracks = _parseTrackList(
      rawTracks,
      fallbackCoverUrl: coverUrl,
      fallbackAlbumTitle: title,
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
      artistName: artistName,
      releaseYear: releaseYear,
      coverUrl: coverUrl,
      versions: <AlbumVersionInfo>[
        AlbumVersionInfo(
          id: 'ver_tidal_$cleanId',
          provider: kind,
          externalAlbumId: cleanId,
          editionLabel: quality.contains('HI_RES')
              ? 'Tidal HiRes FLAC'
              : 'Tidal FLAC',
          codec: albumFmt.codec.name,
          sampleRateHz: albumFmt.sampleRateHz,
          bitDepth: albumFmt.bitDepth,
          tracks: versionTracks,
        ),
      ],
    );
  }

  Future<List<TrackInfo>> _fetchPlaylistTracksImpl(String playlistId) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'tidal');
    final json = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/playlists/$cleanId/tracks',
        <String, String>{'countryCode': _countryCode, 'limit': '100'},
      ),
      headers: _authHeaders,
    );
    return _parseTrackList(json['items']);
  }

  Future<StreamingCatalog> _searchImpl(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    await refreshSessionIfNeeded();
    cancel?.throwIfCancelled();

    final trimmed = query.trim();
    if (trimmed.isEmpty) return StreamingCatalog(syncedAt: clock());

    final tracksJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/search/tracks',
        <String, String>{
          'query': trimmed,
          'countryCode': _countryCode,
          'limit': '25',
        },
      ),
      headers: _authHeaders,
      cancel: cancel,
    );

    final albumsJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/search/albums',
        <String, String>{
          'query': trimmed,
          'countryCode': _countryCode,
          'limit': '25',
        },
      ),
      headers: _authHeaders,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    return StreamingCatalog(
      tracks: _parseTrackList(tracksJson['items']),
      albums: _parseAlbumList(albumsJson['items']),
      syncedAt: clock(),
    );
  }
}
