part of '../deezer_provider.dart';

extension _DeezerCatalog on DeezerProvider {
  Future<StreamingCatalog> _syncLibraryImpl({CancellationToken? cancel}) async {
    ensureAuthenticated();
    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      throw const StreamingException('Deezer 缺少 userId，無法同步曲庫');
    }

    final tracksJson = await _callPublicApi(
      '/user/$uid/tracks',
      query: const <String, String>{'limit': '100'},
      cancel: cancel,
    );
    final albumsJson = await _callPublicApi(
      '/user/$uid/albums',
      query: const <String, String>{'limit': '50'},
      cancel: cancel,
    );
    final playlistsJson = await _callPublicApi(
      '/user/$uid/playlists',
      query: const <String, String>{'limit': '50'},
      cancel: cancel,
    );

    final nextCatalog = StreamingCatalog(
      tracks: _parseTracks(tracksJson['data']),
      albums: _parseAlbums(albumsJson['data']),
      playlists: _parsePlaylists(playlistsJson['data']),
      syncedAt: clock(),
    );
    setCatalog(nextCatalog);
    return nextCatalog;
  }

  ({List<StreamingAlbum> albums, List<TrackInfo> tracks})
      _parseGatewayHomeRecommendations(dynamic results) {
    final albums = <StreamingAlbum>[];
    final tracks = <TrackInfo>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};

    void walk(dynamic node) {
      if (node is Map) {
        final albId = node['ALB_ID']?.toString();
        final sngId = node['SNG_ID']?.toString();
        if (sngId != null && sngId.isNotEmpty) {
          if (seenTrackIds.add(sngId)) {
            final cover = _extractDeezerCover(node);
            tracks.add(
              TrackInfo(
                id: 'deezer:$sngId',
                title: node['SNG_TITLE']?.toString() ?? '未命名曲目',
                artist: node['ART_NAME']?.toString() ?? '未知藝術家',
                album: node['ALB_TITLE']?.toString() ?? 'Deezer',
                duration: Duration(
                  seconds: int.tryParse(node['DURATION']?.toString() ?? '') ?? 0,
                ),
                albumArtUrl: cover,
                coverUrl: cover,
                format: _catalogTrackFormat,
                providerName: 'Deezer',
              ),
            );
          }
        } else if (albId != null && albId.isNotEmpty) {
          if (seenAlbumIds.add(albId)) {
            final cover = _extractDeezerCover(node);
            albums.add(
              StreamingAlbum(
                id: albId,
                title: node['ALB_TITLE']?.toString() ?? '未命名專輯',
                artist: node['ART_NAME']?.toString() ?? '未知藝術家',
                coverUrl: cover,
                providerKind: kind,
                qualityLabel: _webLossless ? 'FLAC 16-bit / 44.1 kHz' : null,
              ),
            );
          }
        }
        for (final val in node.values) {
          walk(val);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(results);
    return (albums: albums, tracks: tracks);
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

    final json = await _callPublicApi('/album/$cleanId', cancel: cancel);
    final title = json['title']?.toString() ?? 'Deezer Album';
    final artistObj = json['artist'] as Map?;
    final artistName = artistObj?['name']?.toString() ?? '未知藝術家';
    final releaseDate = json['release_date']?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4
        ? int.tryParse(releaseDate.substring(0, 4))
        : null;
    final coverUrl = _extractDeezerCover(json);

    dynamic rawTracks = (json['tracks'] is Map)
        ? (json['tracks'] as Map)['data']
        : null;
    if (rawTracks is! List || rawTracks.isEmpty) {
      try {
        final tracksResp = await _callPublicApi(
          '/album/$cleanId/tracks',
          query: const <String, String>{'limit': '100'},
          cancel: cancel,
        );
        rawTracks = tracksResp['data'];
      } catch (_) {}
    }

    final parsedTracks = _parseTracks(
      rawTracks,
      fallbackCoverUrl: coverUrl,
      fallbackAlbumTitle: title,
    );
    final fmt = _catalogTrackFormat;
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
          codec: fmt.codec.name,
          sampleRateHz: fmt.sampleRateHz,
          bitDepth: fmt.bitDepth,
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
          id: 'ver_deezer_$cleanId',
          provider: kind,
          externalAlbumId: cleanId,
          editionLabel: _webLossless ? 'Deezer HiFi' : 'Deezer',
          codec: fmt.codec.name,
          sampleRateHz: fmt.sampleRateHz,
          bitDepth: fmt.bitDepth,
          tracks: versionTracks,
        ),
      ],
    );
  }

  Future<List<TrackInfo>> _fetchPlaylistTracksImpl(String playlistId) async {
    ensureAuthenticated();
    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'deezer');
    final json = await _callPublicApi(
      '/playlist/$cleanId/tracks',
      query: const <String, String>{'limit': '100'},
    );
    return _parseTracks(json['data']);
  }

  Future<StreamingCatalog> _searchImpl(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return StreamingCatalog(syncedAt: clock());

    final tracksJson = await _callPublicApi(
      '/search/track',
      query: <String, String>{'q': trimmed, 'limit': '25'},
      cancel: cancel,
    );
    final albumsJson = await _callPublicApi(
      '/search/album',
      query: <String, String>{'q': trimmed, 'limit': '25'},
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    return StreamingCatalog(
      tracks: _parseTracks(tracksJson['data']),
      albums: _parseAlbums(albumsJson['data']),
      syncedAt: clock(),
    );
  }
}
