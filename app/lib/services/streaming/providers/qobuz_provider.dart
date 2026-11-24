import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';

/// Real Qobuz API v0.2 provider supporting MD5 credential login, token
/// verification, Hi-Res catalog sync, and MD5 `request_sig` stream signing.
class QobuzProvider extends BaseStreamingProvider implements StreamResolver {
  static const List<int> _preferredFormatIds = <int>[27, 7, 6, 5];

  final String baseUrl;

  String? _appId;
  String? _appSecret;
  String? _userAuthToken;

  QobuzProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.baseUrl = 'https://www.qobuz.com/api.json/0.2',
  });

  static const String missingAppSecretNotice =
      '目前以網頁／權杖授權登入（未含 app_secret），帳戶驗證與歌單同步已就緒；若需解析 Hi-Res 串流播放簽章，請於「進階／手動輸入 Token」補填 App Secret 或改用帳號密碼登入。';

  @override
  String get kind => 'qobuz';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.qobuz;

  bool get hasAppSecret =>
      _appSecret != null && _appSecret!.trim().isNotEmpty;

  Map<String, String> _authHeaders({bool includeToken = true}) =>
      <String, String>{
        if (_appId != null && _appId!.isNotEmpty) 'X-App-Id': _appId!,
        if (includeToken &&
            _userAuthToken != null &&
            _userAuthToken!.isNotEmpty)
          'X-User-Auth-Token': _userAuthToken!,
        'Accept': 'application/json',
      };

  static String computePasswordMd5(String password) =>
      md5.convert(utf8.encode(password)).toString();

  static String computeRequestSignature({
    required int formatId,
    required String trackId,
    required String timestampSec,
    required String appSecret,
  }) {
    final payload =
        'trackgetFileUrlformat_id${formatId}intentstreamtrack_id$trackId$timestampSec$appSecret';
    return md5.convert(utf8.encode(payload)).toString();
  }

  @override
  Future<void> restoreFromStorage() async {
    try {
      final stored = await readCredentialsJson();
      if (stored == null) {
        resetState();
        return;
      }

      _appId = stored['app_id']?.toString().trim();
      _appSecret = stored['app_secret']?.toString().trim();
      _userAuthToken = stored['user_auth_token']?.toString().trim();

      if (_appId == null ||
          _appId!.isEmpty ||
          _userAuthToken == null ||
          _userAuthToken!.isEmpty) {
        resetState();
        return;
      }

      final account = await _verifyTokenLive();
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

      final appId = params['app_id']?.toString().trim() ?? '';
      if (appId.isEmpty) {
        throw const StreamingException('Qobuz 驗證需要提供 app_id');
      }
      _appId = appId;
      final secret = params['app_secret']?.toString().trim();
      _appSecret = (secret != null && secret.isNotEmpty) ? secret : null;

      final requestedMode = params['mode']?.toString().trim();
      final tokenParam = params['user_auth_token']?.toString().trim();
      final emailParam =
          (params['email'] ?? params['username'])?.toString().trim();
      final passwordParam = params['password']?.toString();

      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : (emailParam != null &&
                    emailParam.isNotEmpty &&
                    passwordParam != null &&
                    passwordParam.isNotEmpty
                ? 'credentials'
                : 'token');

      late final StreamingAccountInfo account;

      if (mode == 'credentials') {
        if (emailParam == null ||
            emailParam.isEmpty ||
            passwordParam == null ||
            passwordParam.isEmpty) {
          throw const StreamingException('請輸入 Qobuz 電子郵件與密碼');
        }
        onProgress?.call('正在以 MD5 雜湊安全驗證 Qobuz 帳號...');
        final loginUri = BaseStreamingProvider.buildUri(baseUrl, '/user/login');
        final loginJson = await http.requestJson(
          method: 'POST',
          uri: loginUri,
          headers: _authHeaders(includeToken: false),
          formBody: BaseStreamingProvider.encodeForm(<String, String>{
            'email': emailParam,
            'password': computePasswordMd5(passwordParam),
            'app_id': appId,
          }),
          cancel: cancel,
        );
        if (loginJson['status'] == 'error') {
          throw StreamingException(
            loginJson['message']?.toString() ?? 'Qobuz 帳號或密碼驗證失敗',
            statusCode: 401,
          );
        }

        final userMap = _extractUserMap(loginJson);
        final token = (loginJson['user_auth_token'] ??
                userMap?['user_auth_token'] ??
                userMap?['auth_token'])
            ?.toString()
            .trim();
        if (token == null || token.isEmpty) {
          throw const StreamingException(
            'Qobuz 登入回應缺少 user_auth_token',
            statusCode: 401,
          );
        }
        _userAuthToken = token;
        account = _parseAccountInfo(
          userMap,
          fallbackDisplayName: emailParam,
        );
      } else if (mode == 'token') {
        if (tokenParam == null || tokenParam.isEmpty) {
          throw const StreamingException('請輸入 Qobuz user_auth_token');
        }
        _userAuthToken = tokenParam;
        onProgress?.call('正在向 Qobuz 伺服器即時驗證授權權杖...');
        account = await _verifyTokenLive(cancel: cancel);
      } else {
        throw StreamingException('不支援的 Qobuz 驗證模式：$mode');
      }

      setConnected(account);
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(e);
    }
  }

  Future<StreamingAccountInfo> _verifyTokenLive({
    CancellationToken? cancel,
  }) async {
    final userGetUri = BaseStreamingProvider.buildUri(baseUrl, '/user/get');
    final res = await http.sendJsonRaw(
      method: 'GET',
      uri: userGetUri,
      headers: _authHeaders(),
      cancel: cancel,
    );

    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.json['status'] == 'error') {
        throw StreamingException(
          res.json['message']?.toString() ?? 'Qobuz 權杖無效',
          statusCode: 401,
          isTokenExpired: true,
        );
      }
      final userMap = _extractUserMap(res.json);
      if (userMap == null) {
        throw const StreamingException(
          'Qobuz /user/get 未回傳有效使用者資料',
          statusCode: 401,
          isTokenExpired: true,
        );
      }
      return _parseAccountInfo(userMap);
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw StreamingException(
        StreamingHttpClient.extractApiErrorMessage(
          res.json,
          res.rawBody,
          res.statusCode,
        ),
        statusCode: res.statusCode,
        isTokenExpired: res.statusCode == 401,
      );
    }

    // Fallback when /user/get endpoint rejects with 400/404 for certain app_id configs.
    if (res.statusCode == 400 || res.statusCode == 404) {
      final favUri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/favorite/getUserFavorites',
        const <String, String>{'limit': '1'},
      );
      final favJson = await http.requestJson(
        method: 'GET',
        uri: favUri,
        headers: _authHeaders(),
        cancel: cancel,
      );
      if (favJson['status'] == 'error') {
        throw StreamingException(
          favJson['message']?.toString() ?? 'Qobuz 權杖驗證失敗',
          statusCode: 401,
          isTokenExpired: true,
        );
      }
      final userMap = _extractUserMap(favJson);
      return _parseAccountInfo(
        userMap,
        fallbackDisplayName: 'Qobuz 會員',
      );
    }

    throw StreamingException(
      StreamingHttpClient.extractApiErrorMessage(
        res.json,
        res.rawBody,
        res.statusCode,
      ),
      statusCode: res.statusCode,
    );
  }

  Map<String, dynamic>? _extractUserMap(Map<String, dynamic> json) {
    final u = json['user'];
    if (u is Map) return Map<String, dynamic>.from(u);
    if (json.containsKey('id') &&
        (json.containsKey('login') || json.containsKey('display_name'))) {
      return json;
    }
    return null;
  }

  StreamingAccountInfo _parseAccountInfo(
    Map<String, dynamic>? userMap, {
    String fallbackDisplayName = 'Qobuz Subscriber',
  }) {
    final displayName = userMap?['display_name']?.toString().trim();
    final login = userMap?['login']?.toString().trim();
    final name = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : ((login != null && login.isNotEmpty) ? login : fallbackDisplayName);

    final cred = userMap?['credential'];
    String? planTier;
    if (cred is Map) {
      final label = cred['label']?.toString().trim();
      final desc = cred['description']?.toString().trim();
      planTier = (label != null && label.isNotEmpty)
          ? label
          : (desc != null && desc.isNotEmpty ? desc : null);
    }

    return StreamingAccountInfo(
      displayName: name,
      planTier: planTier,
      userId: userMap?['id']?.toString(),
      email: userMap?['email']?.toString(),
      countryCode:
          userMap?['country_code']?.toString() ?? userMap?['zone']?.toString(),
      drmNotice: hasAppSecret ? null : missingAppSecretNotice,
    );
  }

  Future<void> _persistCredentials(StreamingAccountInfo account) {
    return saveCredentialsJson(<String, dynamic>{
      if (_appId != null) 'app_id': _appId,
      if (_appSecret != null && _appSecret!.isNotEmpty)
        'app_secret': _appSecret,
      if (_userAuthToken != null) 'user_auth_token': _userAuthToken,
      'account': account.toJson(),
    });
  }

  @override
  Future<void> refreshSessionIfNeeded({bool force = false}) async {
    // Qobuz user_auth_token does not use OAuth refresh tokens.
  }

  @override
  Future<void> logout() async {
    _userAuthToken = null;
    _appSecret = null;
    await clearCredentials();
    resetState();
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async {
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

  static const List<String> _featuredRecommendationTypes = <String>[
    'new-releases-full',
    'ideal-discography',
    'press-awards',
    'most-streamed',
    'best-sellers',
    'new-releases',
    'qobuzissims',
  ];

  @override
  Future<StreamingRecommendations> fetchRecommendations({
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

    final featuredType = _featuredRecommendationTypes[
        batchIndex % _featuredRecommendationTypes.length];
    final featuredOffset =
        (batchIndex ~/ _featuredRecommendationTypes.length) * 16;

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

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async {
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

  static List<int> _formatIdsForQualityKey(String qualityKey) {
    final normalized = qualityKey.trim().toLowerCase();
    return switch (normalized) {
      '27' || 'hi_res_192' || '24_192' => const <int>[27, 7, 6, 5],
      '7' || 'hi_res_96' || '24_96' => const <int>[7, 6, 5],
      '6' || 'lossless' || 'flac' => const <int>[6, 5],
      '5' || 'mp3_320' || 'mp3' => const <int>[5],
      _ => _preferredFormatIds,
    };
  }

  Future<
    ({
      String url,
      Map<String, String> headers,
      String mimeType,
      String hintExtension,
      AudioFormat format,
      int? bitrateBps,
      int? expireAt,
    })
  > _resolveSignedFileUrl({
    required String rawTrackId,
    required List<int> formatIds,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();

    final secret = _appSecret?.trim() ?? '';
    if (secret.isEmpty) {
      throw const StreamingException(
        'Qobuz 串流需要提供 app_secret 以計算 MD5 request_sig 簽章',
      );
    }

    final trackId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'qobuz');
    if (trackId.isEmpty) {
      throw const StreamingException('曲目缺少有效的 Qobuz track_id');
    }

    StreamingException? lastFailure;
    for (final fmtId in formatIds) {
      cancel?.throwIfCancelled();
      final ts = (clock().millisecondsSinceEpoch ~/ 1000).toString();
      final sig = computeRequestSignature(
        formatId: fmtId,
        trackId: trackId,
        timestampSec: ts,
        appSecret: secret,
      );

      final uri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/track/getFileUrl',
        <String, String>{
          'track_id': trackId,
          'format_id': fmtId.toString(),
          'intent': 'stream',
          'request_ts': ts,
          'request_sig': sig,
        },
      );

      final res = await http.sendJsonRaw(
        method: 'GET',
        uri: uri,
        headers: _authHeaders(),
        cancel: cancel,
        timeout: timeout,
      );

      if (res.statusCode == 401 || res.statusCode == 403) {
        throw StreamingException(
          StreamingHttpClient.extractApiErrorMessage(
            res.json,
            res.rawBody,
            res.statusCode,
          ),
          statusCode: res.statusCode,
          isTokenExpired: res.statusCode == 401,
        );
      }

      if (res.statusCode < 200 || res.statusCode >= 300) {
        lastFailure = StreamingException(
          StreamingHttpClient.extractApiErrorMessage(
            res.json,
            res.rawBody,
            res.statusCode,
          ),
          statusCode: res.statusCode,
        );
        continue;
      }

      if (res.json['status'] == 'error') {
        final msg = res.json['message']?.toString() ?? 'Qobuz 無法取得串流網址';
        final code = (res.json['code'] as num?)?.toInt();
        final lower = msg.toLowerCase();
        if (code == 401 ||
            lower.contains('authentication is required') ||
            lower.contains('invalid user_auth_token')) {
          throw StreamingException(
            msg,
            statusCode: 401,
            isTokenExpired: true,
          );
        }
        lastFailure = StreamingException(msg, statusCode: code);
        continue;
      }

      final restrictions = res.json['restrictions'];
      if (restrictions is List && restrictions.isNotEmpty) {
        lastFailure = StreamingException(
          'Qobuz 曲目受權限限制：${restrictions.first}',
          isDrmRestricted: true,
        );
        continue;
      }

      final streamUrl = res.json['url']?.toString().trim() ?? '';
      if (streamUrl.isEmpty) {
        lastFailure = const StreamingException('Qobuz track/getFileUrl 回傳空白 URL');
        continue;
      }

      final effectiveFormatId =
          (res.json['format_id'] as num?)?.toInt() ?? fmtId;
      final defaultSpec = _formatDefaults(effectiveFormatId);

      final rawRate = res.json['sampling_rate'];
      final int sampleRateHz;
      if (rawRate is num) {
        sampleRateHz = rawRate <= 1000
            ? (rawRate.toDouble() * 1000).round()
            : rawRate.round();
      } else {
        sampleRateHz = defaultSpec.sampleRateHz;
      }

      final bitDepth =
          (res.json['bit_depth'] as num?)?.toInt() ?? defaultSpec.bitDepth;
      final rawMime = res.json['mime_type']?.toString().trim() ?? '';
      final mime = rawMime.toLowerCase();
      final codec = mime.contains('mpeg') || effectiveFormatId == 5
          ? AudioCodec.mp3
          : AudioCodec.flac;

      final uriExp = Uri.tryParse(streamUrl)?.queryParameters;
      final expireAt =
          int.tryParse(uriExp?['exp'] ?? uriExp?['expire'] ?? uriExp?['expires'] ?? '');
      final rawBitrate = (res.json['bitrate'] as num?)?.toInt();
      final bitrateBps = rawBitrate != null && rawBitrate > 0
          ? (rawBitrate < 10000 ? rawBitrate * 1000 : rawBitrate)
          : (codec == AudioCodec.mp3 ? 320000 : null);

      return (
        url: streamUrl,
        headers: _authHeaders(),
        mimeType: rawMime.isNotEmpty
            ? rawMime
            : (codec == AudioCodec.mp3 ? 'audio/mpeg' : 'audio/flac'),
        hintExtension: codec == AudioCodec.mp3 ? 'mp3' : 'flac',
        format: AudioFormat(
          codec: codec,
          sampleRateHz: sampleRateHz,
          bitDepth: bitDepth,
          channels: 2,
        ),
        bitrateBps: bitrateBps,
        expireAt: expireAt,
      );
    }

    throw lastFailure ??
        const StreamingException('Qobuz 無法解析任何可用音質的串流網址');
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    final resolved = await _resolveSignedFileUrl(
      rawTrackId: key.trackId,
      formatIds: _formatIdsForQualityKey(key.qualityKey),
      cancel: cancelToken,
    );
    return DirectRangeSpec(
      key: key,
      url: resolved.url,
      headers: resolved.headers,
      bitrateBps: resolved.bitrateBps,
      mimeType: resolved.mimeType,
      hintExtension: resolved.hintExtension,
      expireAt: resolved.expireAt,
      audioFormat: resolved.format,
    );
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    final resolved = await _resolveSignedFileUrl(
      rawTrackId: track.id,
      formatIds: _preferredFormatIds,
      cancel: cancel,
      timeout: timeout,
    );
    return ResolvedStreamResult(
      url: resolved.url,
      headers: resolved.headers,
      hintExtension: resolved.hintExtension,
      format: resolved.format,
    );
  }

  static ({int sampleRateHz, int bitDepth}) _formatDefaults(int formatId) =>
      switch (formatId) {
        27 => (sampleRateHz: 192000, bitDepth: 24),
        7 => (sampleRateHz: 96000, bitDepth: 24),
        6 => (sampleRateHz: 44100, bitDepth: 16),
        _ => (sampleRateHz: 44100, bitDepth: 16),
      };

  List<TrackInfo> _parseTracks(
    dynamic rawItems, {
    String? fallbackAlbumTitle,
    String? fallbackArtistName,
    String? fallbackCoverUrl,
  }) {
    if (rawItems is! List) return const [];
    final normalizedFallbackCover =
        BaseStreamingProvider.normalizeCoverUrl(fallbackCoverUrl);
    final list = <TrackInfo>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final performer = map['performer'] as Map?;
      final albumObj = map['album'] as Map?;
      final albumArtist = albumObj?['artist'] as Map?;
      final performerName = performer?['name']?.toString().trim();
      final albArtistName = albumArtist?['name']?.toString().trim();
      final fbArtistName = fallbackArtistName?.trim();
      final artistName =
          (performerName != null && performerName.isNotEmpty)
              ? performerName
              : ((albArtistName != null && albArtistName.isNotEmpty)
                    ? albArtistName
                    : ((fbArtistName != null && fbArtistName.isNotEmpty)
                          ? fbArtistName
                          : '未知藝術家'));
      final rawAlbTitle = albumObj?['title']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Qobuz');
      final coverUrl = _extractCoverUrl(albumObj?['image']) ??
          _extractCoverUrl(map['image']) ??
          normalizedFallbackCover;

      final rawSr = map['maximum_sampling_rate'];
      final srHz = rawSr is num
          ? (rawSr <= 1000 ? (rawSr.toDouble() * 1000).round() : rawSr.round())
          : 44100;
      final bitDepth = (map['maximum_bit_depth'] as num?)?.toInt() ?? 16;

      list.add(
        TrackInfo(
          id: 'qobuz:$id',
          title: map['title']?.toString() ?? '未命名曲目',
          artist: artistName,
          album: albumTitle,
          duration: Duration(seconds: (map['duration'] as num?)?.toInt() ?? 0),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (map['track_number'] as num?)?.toInt(),
          discNumber: (map['media_number'] as num?)?.toInt(),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: srHz,
            bitDepth: bitDepth,
            channels: 2,
          ),
          providerName: 'Qobuz',
        ),
      );
    }
    return list;
  }

  List<StreamingAlbum> _parseAlbums(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final list = <StreamingAlbum>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final artistObj = map['artist'] as Map?;
      final rawSr = map['maximum_sampling_rate'];
      final bitDepth = (map['maximum_bit_depth'] as num?)?.toInt();
      String? qualityLabel;
      if (rawSr is num && bitDepth != null) {
        final srHz = rawSr <= 1000 ? (rawSr * 1000).round() : rawSr.round();
        qualityLabel = AudioFormat.formatLabel(
          codec: 'flac',
          sampleRateHz: srHz,
          bitDepth: bitDepth,
        );
      }
      final origDate = map['release_date_original']?.toString() ?? '';
      final year = origDate.length >= 4
          ? int.tryParse(origDate.substring(0, 4))
          : null;

      list.add(
        StreamingAlbum(
          id: id,
          title: map['title']?.toString() ?? '未命名專輯',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _extractCoverUrl(map['image']),
          providerKind: kind,
          trackCount: (map['tracks_count'] as num?)?.toInt(),
          qualityLabel: qualityLabel,
        ),
      );
    }
    return list;
  }

  List<StreamingPlaylist> _parsePlaylists(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final list = <StreamingPlaylist>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final images = map['images300'] ?? map['images150'] ?? map['images'];
      final coverUrl = BaseStreamingProvider.normalizeCoverUrl(
        (images is List && images.isNotEmpty) ? images.first?.toString() : null,
      );
      list.add(
        StreamingPlaylist(
          id: id,
          title: map['name']?.toString() ?? '未命名歌單',
          description: map['description']?.toString(),
          trackCount: (map['tracks_count'] as num?)?.toInt() ?? 0,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }
    return list;
  }

  static String? _extractCoverUrl(dynamic imageObj) {
    if (imageObj is String) {
      return BaseStreamingProvider.normalizeCoverUrl(imageObj);
    }
    if (imageObj is! Map) return null;
    for (final key in const [
      'large',
      'extralarge',
      'small',
      'thumbnail',
      'medium',
      'mega',
      'back',
    ]) {
      final url = BaseStreamingProvider.normalizeCoverUrl(
        imageObj[key]?.toString(),
      );
      if (url != null) return url;
    }
    return null;
  }
}
