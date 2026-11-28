part of '../apple_music_provider.dart';

extension _AppleMusicCatalog on AppleMusicProvider {
  Future<StreamingCatalog> _syncLibraryImpl({CancellationToken? cancel}) async {
    ensureAuthenticated();

    final songsJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/v1/me/library/songs',
        const <String, String>{'limit': '100'},
      ),
      headers: _authHeaders,
      cancel: cancel,
    );

    final albumsJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/v1/me/library/albums',
        const <String, String>{'limit': '50'},
      ),
      headers: _authHeaders,
      cancel: cancel,
    );

    final playlistsJson = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/v1/me/library/playlists',
        const <String, String>{'limit': '50'},
      ),
      headers: _authHeaders,
      cancel: cancel,
    );

    final nextCatalog = StreamingCatalog(
      tracks: _parseSongs(songsJson['data']),
      albums: _parseAlbums(albumsJson['data']),
      playlists: _parsePlaylists(playlistsJson['data']),
      syncedAt: clock(),
    );
    setCatalog(nextCatalog);
    return nextCatalog;
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
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, 'apple');
    if (cleanId.isEmpty) return null;

    final primaryPath = cleanId.startsWith('l.')
        ? '/v1/me/library/albums/$cleanId'
        : '/v1/catalog/$_storefront/albums/$cleanId';
    final fallbackPath = cleanId.startsWith('l.')
        ? '/v1/catalog/$_storefront/albums/$cleanId'
        : '/v1/me/library/albums/$cleanId';

    Map<String, dynamic> json;
    try {
      json = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          primaryPath,
          const <String, String>{'include': 'tracks'},
        ),
        headers: _authHeaders,
        cancel: cancel,
      );
    } on StreamingException catch (e) {
      if (e.statusCode == 404) {
        json = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            fallbackPath,
            const <String, String>{'include': 'tracks'},
          ),
          headers: _authHeaders,
          cancel: cancel,
        );
      } else {
        rethrow;
      }
    }

    final dataList = json['data'];
    final albumObj = (dataList is List &&
            dataList.isNotEmpty &&
            dataList.first is Map)
        ? Map<String, dynamic>.from(dataList.first as Map)
        : json;
    final attrs = albumObj['attributes'] is Map
        ? Map<String, dynamic>.from(albumObj['attributes'] as Map)
        : albumObj;

    final title = attrs['name']?.toString() ??
        attrs['title']?.toString() ??
        'Apple Music Album';
    final artistName = attrs['artistName']?.toString() ?? '未知藝術家';
    final releaseDate = attrs['releaseDate']?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4
        ? int.tryParse(releaseDate.substring(0, 4))
        : null;
    final editorialNotes = attrs['editorialNotes'];
    final bio = editorialNotes is Map
        ? (editorialNotes['standard']?.toString() ??
              editorialNotes['short']?.toString())
        : editorialNotes?.toString();
    final coverUrl = _expandArtworkUrl(attrs['artwork']);

    final rel = albumObj['relationships'] as Map?;
    final tracksRel = rel?['tracks'] as Map?;
    final rawTracks = tracksRel?['data'] ??
        (albumObj['tracks'] is Map
            ? (albumObj['tracks'] as Map)['data']
            : albumObj['tracks']);

    final parsedTracks = _parseSongs(
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
          codec: 'aac',
          sampleRateHz: 44100,
          bitDepth: 16,
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
          id: 'ver_apple_$cleanId',
          provider: kind,
          externalAlbumId: cleanId,
          editionLabel: 'Apple Music AAC',
          codec: 'aac',
          sampleRateHz: 44100,
          bitDepth: 16,
          tracks: versionTracks,
        ),
      ],
    );
  }

  Future<List<TrackInfo>> _fetchPlaylistTracksImpl(String playlistId) async {
    ensureAuthenticated();
    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'apple');
    final json = await http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/v1/me/library/playlists/$cleanId/tracks',
        const <String, String>{'limit': '100'},
      ),
      headers: _authHeaders,
    );
    return _parseSongs(json['data']);
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
        apiBaseUrl,
        '/v1/catalog/$_storefront/search',
        <String, String>{
          'types': 'songs,albums',
          'term': trimmed,
          'limit': '25',
        },
      ),
      headers: _authHeaders,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    final results = json['results'] as Map?;
    final songsObj = results?['songs'] as Map?;
    final albumsObj = results?['albums'] as Map?;

    return StreamingCatalog(
      tracks: _parseSongs(songsObj?['data']),
      albums: _parseAlbums(albumsObj?['data']),
      syncedAt: clock(),
    );
  }
}
