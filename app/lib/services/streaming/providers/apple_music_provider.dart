import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../streaming_provider.dart';

/// Real Apple Music API + MusicKit JS v3 provider with honest Windows FairPlay DRM handling.
class AppleMusicProvider extends BaseStreamingProvider {
  static const String windowsFairPlayDrmNotice =
      'Windows 平台受 Apple FairPlay DRM 保護，無法直接將完整無損 ALAC PCM 串流送入原生 WASAPI/ASIO 管線。'
      'Lumina Audio 支援真實同步個人曲庫、歌單、高解析封面與搜尋，播放時將提供官方 AAC 試聽片段或開啟網頁播放器。';

  final String apiBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;

  String? _developerToken;
  String? _musicUserToken;
  String _storefront = 'us';

  final Map<String, String> _catalogIdByTrackId = <String, String>{};
  final Map<String, String> _previewUrlByTrackId = <String, String>{};
  final Map<String, String> _externalWebUrlByTrackId = <String, String>{};

  AppleMusicProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.apiBaseUrl = 'https://api.music.apple.com',
    this.oauthCallbackPort = 0,
    this.urlOpener,
  });

  @override
  String get kind => 'apple_music';

  Map<String, String> get _authHeaders => <String, String>{
    'Authorization': 'Bearer ${_developerToken ?? ''}',
    'Music-User-Token': _musicUserToken ?? '',
    'Accept': 'application/json',
  };

  @override
  Future<void> restoreFromStorage() async {
    try {
      final stored = await readCredentialsJson();
      if (stored == null) {
        resetState();
        return;
      }

      _developerToken = stored['developer_token']?.toString().trim();
      _musicUserToken = stored['music_user_token']?.toString().trim();
      final sf = stored['storefront']?.toString().trim();
      if (sf != null && sf.isNotEmpty) {
        _storefront = sf;
      }

      if (_developerToken == null ||
          _developerToken!.isEmpty ||
          _musicUserToken == null ||
          _musicUserToken!.isEmpty) {
        resetState();
        return;
      }

      final account = await _verifyStorefrontLive();
      setConnected(account);
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(e);
    }
  }

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    setAuthenticating();
    try {
      cancel?.throwIfCancelled();

      final devToken = params['developer_token']?.toString().trim() ?? '';
      if (devToken.isEmpty) {
        throw const StreamingException(
          'Apple Music 驗證需要提供開發者 JWT 權杖（developer_token）',
        );
      }
      _developerToken = devToken;

      final requestedMode = params['mode']?.toString().trim();
      final userTokenParam =
          (params['music_user_token'] ?? params['media_user_token'])
              ?.toString()
              .trim();

      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : (userTokenParam != null && userTokenParam.isNotEmpty
                ? 'musickit_tokens'
                : 'musickit_browser');

      if (mode == 'musickit_tokens') {
        if (userTokenParam == null || userTokenParam.isEmpty) {
          throw const StreamingException(
            '請提供 Apple Music-User-Token（music_user_token）',
          );
        }
        _musicUserToken = userTokenParam;
      } else if (mode == 'musickit_browser') {
        final server = LoopbackOAuthServer();
        await server.start(port: oauthCallbackPort);
        try {
          final callbackUrl = server.callbackUrl('/musickit-callback');
          server.setMusicKitHtml(
            buildMusicKitAuthHtml(devToken, callbackUrl),
          );
          final authPageUrl = server.callbackUrl('/musickit-auth');
          onProgress?.call('正在開啟瀏覽器進行 Apple MusicKit 授權...');
          await openSystemBrowser(authPageUrl, urlOpener: urlOpener);

          final payload = await server.waitForCallback(cancel: cancel);
          final token = payload.musicUserToken?.trim() ?? '';
          if (token.isEmpty) {
            throw const StreamingException(
              'Apple MusicKit 未回傳有效的 musicUserToken',
            );
          }
          _musicUserToken = token;
        } finally {
          await server.close();
        }
      } else {
        throw StreamingException('不支援的 Apple Music 驗證模式：$mode');
      }

      onProgress?.call('正在向 Apple Music 驗證 Storefront 與帳號授權...');
      final account = await _verifyStorefrontLive(cancel: cancel);
      setConnected(account);
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(e);
    }
  }

  Future<StreamingAccountInfo> _verifyStorefrontLive({
    CancellationToken? cancel,
  }) async {
    final uri =
        BaseStreamingProvider.buildUri(apiBaseUrl, '/v1/me/storefront');
    final json = await http.requestJson(
      method: 'GET',
      uri: uri,
      headers: _authHeaders,
      cancel: cancel,
    );

    final data = json['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const StreamingException(
        'Apple Music /v1/me/storefront 未回傳有效的區域資料',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    final first = Map<String, dynamic>.from(data.first as Map);
    final sfId = first['id']?.toString().trim() ?? '';
    if (sfId.isEmpty) {
      throw const StreamingException(
        'Apple Music storefront ID 為空',
        statusCode: 401,
      );
    }
    _storefront = sfId;

    final attrs = first['attributes'] is Map
        ? Map<String, dynamic>.from(first['attributes'] as Map)
        : const <String, dynamic>{};
    final sfName = attrs['name']?.toString().trim();
    final label = (sfName != null && sfName.isNotEmpty)
        ? 'Apple Music ($sfName)'
        : 'Apple Music (${sfId.toUpperCase()})';

    return StreamingAccountInfo(
      displayName: label,
      planTier: 'Apple Music (FairPlay DRM)',
      countryCode: sfId.toUpperCase(),
      drmNotice: windowsFairPlayDrmNotice,
    );
  }

  Future<void> _persistCredentials(StreamingAccountInfo account) {
    return saveCredentialsJson(<String, dynamic>{
      if (_developerToken != null) 'developer_token': _developerToken,
      if (_musicUserToken != null) 'music_user_token': _musicUserToken,
      'storefront': _storefront,
      'account': account.toJson(),
    });
  }

  @override
  Future<void> refreshSessionIfNeeded() async {
    // MusicKit Developer / User tokens are validated live on restore and requests.
  }

  @override
  Future<void> logout() async {
    _developerToken = null;
    _musicUserToken = null;
    _storefront = 'us';
    _catalogIdByTrackId.clear();
    _previewUrlByTrackId.clear();
    _externalWebUrlByTrackId.clear();
    await clearCredentials();
    resetState();
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async {
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

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();

    final albumMaps = <Map<String, dynamic>>[];
    final songMaps = <Map<String, dynamic>>[];
    final seenAlbumIds = <String>{};
    final seenSongIds = <String>{};

    void collectAppleResource(Map<String, dynamic> item) {
      final type = item['type']?.toString() ?? '';
      final id = item['id']?.toString() ?? '';
      if (id.isNotEmpty &&
          (type == 'albums' || type == 'library-albums')) {
        if (seenAlbumIds.add(id)) {
          albumMaps.add(item);
        }
      } else if (id.isNotEmpty &&
          (type == 'songs' || type == 'library-songs' || type == 'tracks')) {
        if (seenSongIds.add(id)) {
          songMaps.add(item);
        }
      }
      final rel = item['relationships'];
      if (rel is Map) {
        final contents = rel['contents'];
        if (contents is Map && contents['data'] is List) {
          for (final child in contents['data'] as List) {
            if (child is Map) {
              collectAppleResource(Map<String, dynamic>.from(child));
            }
          }
        }
        final tracksRel = rel['tracks'];
        if (tracksRel is Map && tracksRel['data'] is List) {
          for (final child in tracksRel['data'] as List) {
            if (child is Map) {
              collectAppleResource(Map<String, dynamic>.from(child));
            }
          }
        }
      }
    }

    try {
      final recJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/me/recommendations',
          const <String, String>{'limit': '10'},
        ),
        headers: _authHeaders,
        cancel: cancel,
      );
      final data = recJson['data'];
      if (data is List) {
        for (final entry in data) {
          if (entry is Map) {
            collectAppleResource(Map<String, dynamic>.from(entry));
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

    try {
      final recentJson = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/me/recent/played/tracks',
          const <String, String>{'limit': '15'},
        ),
        headers: _authHeaders,
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

    if (albumMaps.isEmpty) {
      try {
        final libAlbumsJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/me/library/albums',
            const <String, String>{'limit': '15'},
          ),
          headers: _authHeaders,
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
          headers: _authHeaders,
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
      albums: _parseAlbums(albumMaps),
      tracks: _parseSongs(songMaps),
      fetchedAt: clock(),
    );
  }

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
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

    final parsedTracks = _parseSongs(rawTracks);
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

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async {
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

  @override
  Future<StreamingCatalog> search(String query) async {
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
    );

    final results = json['results'] as Map?;
    final songsObj = results?['songs'] as Map?;
    final albumsObj = results?['albums'] as Map?;

    return StreamingCatalog(
      tracks: _parseSongs(songsObj?['data']),
      albums: _parseAlbums(albumsObj?['data']),
      syncedAt: clock(),
    );
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();

    final rawId = BaseStreamingProvider.stripTrackPrefix(track.id, 'apple');
    if (rawId.isEmpty) {
      throw const StreamingException('曲目缺少有效的 Apple Music ID');
    }

    var previewUrl = _previewUrlByTrackId[rawId] ?? '';
    var webUrl = _externalWebUrlByTrackId[rawId];
    var catalogId = _catalogIdByTrackId[rawId];

    if (previewUrl.isEmpty) {
      if (catalogId == null || catalogId.isEmpty) {
        if (rawId.startsWith('i.')) {
          final catRes = await http.sendJsonRaw(
            method: 'GET',
            uri: BaseStreamingProvider.buildUri(
              apiBaseUrl,
              '/v1/me/library/songs/$rawId/catalog',
            ),
            headers: _authHeaders,
            cancel: cancel,
            timeout: timeout,
          );
          if (catRes.statusCode == 401 || catRes.statusCode == 403) {
            throw StreamingException(
              StreamingHttpClient.extractApiErrorMessage(
                catRes.json,
                catRes.rawBody,
                catRes.statusCode,
              ),
              statusCode: catRes.statusCode,
              isTokenExpired: catRes.statusCode == 401,
            );
          }
          if (catRes.statusCode >= 200 && catRes.statusCode < 300) {
            final data = catRes.json['data'];
            if (data is List && data.isNotEmpty && data.first is Map) {
              final songMap = Map<String, dynamic>.from(data.first as Map);
              catalogId = songMap['id']?.toString();
              final extracted = _extractPreviewAndWebUrl(songMap);
              previewUrl = extracted.previewUrl ?? '';
              webUrl ??= extracted.webUrl;
            }
          }
        } else {
          catalogId = rawId;
        }
      }

      if (previewUrl.isEmpty && catalogId != null && catalogId.isNotEmpty) {
        final songRes = await http.sendJsonRaw(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/catalog/$_storefront/songs/$catalogId',
          ),
          headers: _authHeaders,
          cancel: cancel,
          timeout: timeout,
        );
        if (songRes.statusCode == 401 || songRes.statusCode == 403) {
          throw StreamingException(
            StreamingHttpClient.extractApiErrorMessage(
              songRes.json,
              songRes.rawBody,
              songRes.statusCode,
            ),
            statusCode: songRes.statusCode,
            isTokenExpired: songRes.statusCode == 401,
          );
        }
        if (songRes.statusCode >= 200 && songRes.statusCode < 300) {
          final data = songRes.json['data'];
          if (data is List && data.isNotEmpty && data.first is Map) {
            final songMap = Map<String, dynamic>.from(data.first as Map);
            final extracted = _extractPreviewAndWebUrl(songMap);
            previewUrl = extracted.previewUrl ?? '';
            webUrl ??= extracted.webUrl;
          }
        }
      }
    }

    if (previewUrl.isEmpty) {
      throw const StreamingException(
        '此 Apple Music 曲目無官方試聽片段，且 Windows 受 Apple FairPlay DRM 保護無法直接擷取完整無損 ALAC 串流，請改用 Apple Music 網頁播放器開啟。',
        isDrmRestricted: true,
      );
    }

    _previewUrlByTrackId[rawId] = previewUrl;
    if (webUrl != null) {
      _externalWebUrlByTrackId[rawId] = webUrl;
    }

    return ResolvedStreamResult(
      url: previewUrl,
      hintExtension: 'm4a',
      format: const AudioFormat(
        codec: AudioCodec.aac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      isPreviewOnly: true,
      drmNotice: windowsFairPlayDrmNotice,
      externalWebUrl: webUrl ??
          (catalogId != null && catalogId.isNotEmpty
              ? 'https://music.apple.com/$_storefront/song/$catalogId'
              : 'https://music.apple.com/$_storefront'),
    );
  }

  List<TrackInfo> _parseSongs(dynamic rawData) {
    if (rawData is! List) return const [];
    final list = <TrackInfo>[];
    for (final entry in rawData) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final rawId = map['id']?.toString() ?? '';
      if (rawId.isEmpty) continue;

      final attrs = map['attributes'] is Map
          ? Map<String, dynamic>.from(map['attributes'] as Map)
          : const <String, dynamic>{};
      final playParams = attrs['playParams'] is Map
          ? Map<String, dynamic>.from(attrs['playParams'] as Map)
          : const <String, dynamic>{};

      final catalogId = playParams['catalogId']?.toString().trim();
      if (catalogId != null && catalogId.isNotEmpty) {
        _catalogIdByTrackId[rawId] = catalogId;
      }

      final extracted = _extractPreviewAndWebUrl(map);
      if (extracted.previewUrl != null && extracted.previewUrl!.isNotEmpty) {
        _previewUrlByTrackId[rawId] = extracted.previewUrl!;
      }
      if (extracted.webUrl != null && extracted.webUrl!.isNotEmpty) {
        _externalWebUrlByTrackId[rawId] = extracted.webUrl!;
      }

      final coverUrl = _expandArtworkUrl(attrs['artwork']);
      final durationMs = (attrs['durationInMillis'] as num?)?.toInt() ?? 0;

      list.add(
        TrackInfo(
          id: 'apple:$rawId',
          title: attrs['name']?.toString() ?? '未命名曲目',
          artist: attrs['artistName']?.toString() ?? '未知藝術家',
          album: attrs['albumName']?.toString() ?? 'Apple Music',
          duration: Duration(milliseconds: durationMs),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (attrs['trackNumber'] as num?)?.toInt(),
          discNumber: (attrs['discNumber'] as num?)?.toInt(),
          format: const AudioFormat(
            codec: AudioCodec.aac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'Apple Music',
        ),
      );
    }
    return list;
  }

  List<StreamingAlbum> _parseAlbums(dynamic rawData) {
    if (rawData is! List) return const [];
    final list = <StreamingAlbum>[];
    for (final entry in rawData) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final attrs = map['attributes'] is Map
          ? Map<String, dynamic>.from(map['attributes'] as Map)
          : const <String, dynamic>{};
      final releaseDate = attrs['releaseDate']?.toString() ?? '';
      final year = releaseDate.length >= 4
          ? int.tryParse(releaseDate.substring(0, 4))
          : null;
      list.add(
        StreamingAlbum(
          id: id,
          title: attrs['name']?.toString() ?? '未命名專輯',
          artist: attrs['artistName']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _expandArtworkUrl(attrs['artwork']),
          providerKind: kind,
          trackCount: (attrs['trackCount'] as num?)?.toInt(),
          qualityLabel: 'AAC / FairPlay DRM',
        ),
      );
    }
    return list;
  }

  List<StreamingPlaylist> _parsePlaylists(dynamic rawData) {
    if (rawData is! List) return const [];
    final list = <StreamingPlaylist>[];
    for (final entry in rawData) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final attrs = map['attributes'] is Map
          ? Map<String, dynamic>.from(map['attributes'] as Map)
          : const <String, dynamic>{};
      final descObj = attrs['description'];
      final description = descObj is Map
          ? descObj['standard']?.toString()
          : descObj?.toString();
      list.add(
        StreamingPlaylist(
          id: id,
          title: attrs['name']?.toString() ?? '未命名歌單',
          description: description,
          coverUrl: _expandArtworkUrl(attrs['artwork']),
          providerKind: kind,
        ),
      );
    }
    return list;
  }

  static ({String? previewUrl, String? webUrl}) _extractPreviewAndWebUrl(
    Map<String, dynamic> songMap,
  ) {
    final attrs = songMap['attributes'] is Map
        ? songMap['attributes'] as Map
        : null;
    if (attrs == null) return (previewUrl: null, webUrl: null);
    final previews = attrs['previews'];
    String? previewUrl;
    if (previews is List && previews.isNotEmpty && previews.first is Map) {
      previewUrl = (previews.first as Map)['url']?.toString().trim();
    }
    final webUrl = attrs['url']?.toString().trim();
    return (previewUrl: previewUrl, webUrl: webUrl);
  }

  static String? _expandArtworkUrl(dynamic artwork) {
    if (artwork is! Map) return null;
    final raw = artwork['url']?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    return raw
        .replaceAll('{w}', '600')
        .replaceAll('{h}', '600')
        .replaceAll('{f}', 'jpg');
  }
}
