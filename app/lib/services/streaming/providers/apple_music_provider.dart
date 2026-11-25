import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../recommendation_provider.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';
import '../track_matcher.dart';

/// Real Apple Music API + MusicKit JS v3 provider with honest Windows FairPlay DRM handling.
class AppleMusicProvider extends BaseStreamingProvider
    implements StreamResolver, RecommendationProvider {
  static const String windowsFairPlayDrmNotice =
      'Windows 平台受 Apple FairPlay DRM 保護，無法直接將完整無損 ALAC PCM 串流送入原生 WASAPI/ASIO 管線。'
      'Lumina Audio 支援真實同步個人曲庫、歌單、高解析封面與搜尋，播放時將提供官方 AAC 試聽片段或開啟網頁播放器。';

  final String apiBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;

  String? _developerToken;
  String? _musicUserToken;
  String _storefront = 'us';
  String? _nextRecommendationsPath;

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

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.appleMusic;

  String? get developerToken => _developerToken;
  String? get musicUserToken => _musicUserToken;
  String get storefront => _storefront;

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
  Future<void> refreshSessionIfNeeded({bool force = false}) async {
    // MusicKit Developer / User tokens are validated live on restore and requests.
  }

  @override
  Future<void> logout() async {
    _developerToken = null;
    _musicUserToken = null;
    _storefront = 'us';
    _nextRecommendationsPath = null;
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
  Future<StreamingCatalog> search(
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

  Future<({String rawId, String? catalogId, String previewUrl, String webUrl})>
  _lookupTrackPlaybackInfo({
    required String rawTrackId,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();

    final rawId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'apple');
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
            final msg = StreamingHttpClient.extractApiErrorMessage(
              catRes.json,
              catRes.rawBody,
              catRes.statusCode,
            );
            throw StreamingException(
              msg,
              statusCode: catRes.statusCode,
              isTokenExpired: catRes.statusCode == 401,
              kind: catRes.statusCode == 401
                  ? StreamingErrorKind.authExpired
                  : StreamingException.classifyKind(
                      statusCode: catRes.statusCode,
                      message: msg,
                    ),
            );
          }
          if (catRes.statusCode == 451) {
            final msg = StreamingHttpClient.extractApiErrorMessage(
              catRes.json,
              catRes.rawBody,
              451,
            );
            throw StreamingException(
              msg,
              statusCode: 451,
              kind: StreamingErrorKind.regionRestricted,
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
          final msg = StreamingHttpClient.extractApiErrorMessage(
            songRes.json,
            songRes.rawBody,
            songRes.statusCode,
          );
          throw StreamingException(
            msg,
            statusCode: songRes.statusCode,
            isTokenExpired: songRes.statusCode == 401,
            kind: songRes.statusCode == 401
                ? StreamingErrorKind.authExpired
                : StreamingException.classifyKind(
                    statusCode: songRes.statusCode,
                    message: msg,
                  ),
          );
        }
        if (songRes.statusCode == 451 ||
            songRes.statusCode == 404 ||
            songRes.statusCode == 410) {
          final msg = StreamingHttpClient.extractApiErrorMessage(
            songRes.json,
            songRes.rawBody,
            songRes.statusCode,
          );
          throw StreamingException(
            msg,
            statusCode: songRes.statusCode,
            kind: StreamingException.classifyKind(
              statusCode: songRes.statusCode,
              message: msg,
            ),
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

    if (previewUrl.isNotEmpty) {
      _previewUrlByTrackId[rawId] = previewUrl;
    }
    if (catalogId != null && catalogId.isNotEmpty) {
      _catalogIdByTrackId[rawId] = catalogId;
    }
    final resolvedWebUrl = webUrl ??
        (catalogId != null && catalogId.isNotEmpty
            ? 'https://music.apple.com/$_storefront/song/$catalogId'
            : 'https://music.apple.com/$_storefront');
    if (webUrl != null) {
      _externalWebUrlByTrackId[rawId] = webUrl;
    }

    return (
      rawId: rawId,
      catalogId: catalogId,
      previewUrl: previewUrl,
      webUrl: resolvedWebUrl,
    );
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    final info = await _lookupTrackPlaybackInfo(
      rawTrackId: key.trackId,
      cancel: cancelToken,
    );
    final effectiveSongId =
        (info.catalogId != null && info.catalogId!.isNotEmpty)
            ? info.catalogId!
            : info.rawId;

    return ExternalBackendSpec(
      key: key,
      providerId: providerId,
      trackUri: 'apple:$effectiveSongId',
      externalWebUrl: info.webUrl,
      previewUrl: info.previewUrl.isNotEmpty ? info.previewUrl : null,
      notice: windowsFairPlayDrmNotice,
      audioFormat: const AudioFormat(
        codec: AudioCodec.aac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
    );
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    final info = await _lookupTrackPlaybackInfo(
      rawTrackId: track.id,
      cancel: cancel,
      timeout: timeout,
    );

    if (info.previewUrl.isEmpty) {
      throw const StreamingException(
        '此 Apple Music 曲目無官方試聽片段，且 Windows 受 Apple FairPlay DRM 保護無法直接擷取完整無損 ALAC 串流，請改用 Apple Music 網頁播放器開啟。',
        isDrmRestricted: true,
      );
    }

    return ResolvedStreamResult(
      url: info.previewUrl,
      hintExtension: 'm4a',
      format: const AudioFormat(
        codec: AudioCodec.aac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      isPreviewOnly: true,
      drmNotice: windowsFairPlayDrmNotice,
      externalWebUrl: info.webUrl,
    );
  }

  List<TrackInfo> _parseSongs(
    dynamic rawData, {
    String? fallbackCoverUrl,
    String? fallbackAlbumTitle,
  }) {
    if (rawData is! List) return const [];
    final normalizedFallbackCover = _expandArtworkUrl(fallbackCoverUrl);
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

      final coverUrl =
          _expandArtworkUrl(attrs['artwork']) ?? normalizedFallbackCover;
      final rawAlbTitle = attrs['albumName']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Apple Music');
      final durationMs = (attrs['durationInMillis'] as num?)?.toInt() ?? 0;
      final rawIsrc = attrs['isrc']?.toString().trim();
      final isrc = (rawIsrc != null && rawIsrc.isNotEmpty) ? rawIsrc : null;

      list.add(
        TrackInfo(
          id: 'apple:$rawId',
          title: attrs['name']?.toString() ?? '未命名曲目',
          artist: attrs['artistName']?.toString() ?? '未知藝術家',
          album: albumTitle,
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
          isrc: isrc,
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
    final String? raw;
    if (artwork is String) {
      raw = artwork.trim();
    } else if (artwork is Map) {
      raw = artwork['url']?.toString().trim();
    } else {
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    final expanded = raw
        .replaceAll('{w}', '600')
        .replaceAll('{h}', '600')
        .replaceAll('{f}', 'jpg');
    return BaseStreamingProvider.normalizeCoverUrl(expanded);
  }

  // ─── RecommendationProvider ────────────────────────────────────────────────

  @override
  String get recommendationProviderId => kind;

  bool get _hasValidAuth =>
      authState == StreamingAuthState.connected &&
      (_developerToken?.trim().isNotEmpty ?? false) &&
      (_musicUserToken?.trim().isNotEmpty ?? false);

  void _requireRecAuth() {
    if (!_hasValidAuth) {
      throw RecError(
        kind: RecErrorKind.authRequired,
        message: lastError ?? 'Apple Music 尚未登入或授權已失效，請重新登入',
        statusCode: 401,
        providerId: kind,
      );
    }
  }

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

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    _requireRecAuth();

    final effectiveLimit = limit > 0 ? limit : 10;
    final rawOffset = int.tryParse(cursor?.trim() ?? '') ?? 0;
    final offset = rawOffset < 0 ? 0 : rawOffset;
    final term = seed.primaryArtist.trim().isNotEmpty
        ? seed.primaryArtist.trim()
        : seed.artist.trim();
    if (term.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'Apple Music Radio',
      );
    }

    final cleanSeedId = BaseStreamingProvider.stripTrackPrefix(
      BaseStreamingProvider.stripTrackPrefix(
        seed.trackId.trim(),
        'streaming:apple_music',
      ),
      'apple',
    );

    try {
      final json = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/catalog/$_storefront/search',
          <String, String>{
            'types': 'songs',
            'term': term,
            'limit': '$effectiveLimit',
            if (offset > 0) 'offset': '$offset',
          },
        ),
        headers: _authHeaders,
        cancel: cancel,
      );
      final results = json['results'] as Map?;
      final songsObj = results?['songs'] as Map?;
      final parsed = _parseSongs(songsObj?['data']);
      final tracks = parsed
          .where((t) {
            final tid = BaseStreamingProvider.stripTrackPrefix(t.id, 'apple');
            return cleanSeedId.isEmpty || tid != cleanSeedId;
          })
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);

      final nextCursor = parsed.length >= effectiveLimit
          ? '${offset + effectiveLimit}'
          : null;
      return RadioPage(
        tracks: tracks,
        nextCursor: nextCursor,
        sourceLabel: 'Apple Music Radio',
      );
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (!_hasValidAuth) {
      return const <FeedSection>[];
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
      if (data is! List) return const <FeedSection>[];

      final sections = <FeedSection>[];
      var idx = 0;
      for (final group in data) {
        if (group is! Map) continue;
        final groupMap = Map<String, dynamic>.from(group);
        final attrs = groupMap['attributes'] is Map
            ? Map<String, dynamic>.from(groupMap['attributes'] as Map)
            : const <String, dynamic>{};
        final titleObj = attrs['title'];
        final reasonObj = attrs['reason'];
        final title = (titleObj is Map
                ? titleObj['stringForDisplay']?.toString()
                : titleObj?.toString()) ??
            (reasonObj is Map
                ? reasonObj['stringForDisplay']?.toString()
                : reasonObj?.toString()) ??
            'Apple Music Recommendations';

        final rel = groupMap['relationships'] as Map?;
        final contents = rel?['contents'] as Map?;
        final rawItems = contents?['data'];
        if (rawItems is! List) continue;

        final songItems = <Map<String, dynamic>>[];
        final albumItems = <Map<String, dynamic>>[];
        for (final item in rawItems) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final type = map['type']?.toString() ?? '';
          if (type == 'songs' || type == 'library-songs' || type == 'tracks') {
            songItems.add(map);
          } else if (type == 'albums' || type == 'library-albums') {
            albumItems.add(map);
          }
        }

        final tracks = _parseSongs(songItems)
            .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
            .toList(growable: false);
        final albums = _parseAlbums(albumItems);
        if (tracks.isNotEmpty || albums.isNotEmpty) {
          final groupId = groupMap['id']?.toString().trim();
          sections.add(
            FeedSection(
              id: (groupId != null && groupId.isNotEmpty)
                  ? groupId
                  : 'apple_rec_${idx++}',
              title: title,
              providerId: kind,
              tracks: tracks,
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

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    _requireRecAuth();

    final normIsrc = TrackMatcher.normalizeIsrc(query.isrc);
    if (normIsrc != null) {
      try {
        final isrcJson = await http.requestJson(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/catalog/$_storefront/songs',
            <String, String>{'filter[isrc]': normIsrc},
          ),
          headers: _authHeaders,
          cancel: cancel,
        );
        final exactMatches = _parseSongs(isrcJson['data'])
            .map(
              (t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind),
            )
            .where((m) => TrackMatcher.normalizeIsrc(m.isrc) == normIsrc)
            .toList(growable: false);
        if (exactMatches.isNotEmpty) {
          return TrackMatcher.selectBestMatch(query, exactMatches);
        }
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == 401 || e.isTokenExpired) {
          throw _mapRecError(e);
        }
      }
    }

    final term = '${query.artist.trim()} ${query.title.trim()}'.trim();
    if (term.isEmpty) return null;

    try {
      final json = await http.requestJson(
        method: 'GET',
        uri: BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/v1/catalog/$_storefront/search',
          <String, String>{'types': 'songs', 'term': term, 'limit': '10'},
        ),
        headers: _authHeaders,
        cancel: cancel,
      );
      final results = json['results'] as Map?;
      final songsObj = results?['songs'] as Map?;
      final candidates = _parseSongs(songsObj?['data'])
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      return TrackMatcher.selectBestMatch(query, candidates);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }
}
