import 'dart:convert';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';

/// Real Deezer ARL (`gw-light.php` + `media.deezer.com`) & OAuth 2.0 provider.
class DeezerProvider extends BaseStreamingProvider implements StreamResolver {
  static const String _previewNotice =
      '目前僅提供 Deezer 官方 30 秒 MP3 試聽片段；完整無損串流需有效付費 ARL 工作階段與授權金鑰。';

  final String gwUrl;
  final String oauthBaseUrl;
  final String apiBaseUrl;
  final String mediaBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;

  String _authMode = 'arl';
  String? _arl;
  String? _accessToken;
  String? _userId;
  String? _apiToken;
  String? _licenseToken;
  bool _webLossless = false;
  bool _webHq = false;
  Future<void>? _inFlightRefresh;

  final Map<String, String> _previewUrlCache = <String, String>{};

  DeezerProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.gwUrl = 'https://www.deezer.com/ajax/gw-light.php',
    this.oauthBaseUrl = 'https://connect.deezer.com',
    this.apiBaseUrl = 'https://api.deezer.com',
    this.mediaBaseUrl = 'https://media.deezer.com/v1/get_url',
    this.oauthCallbackPort = 0,
    this.urlOpener,
  });

  @override
  String get kind => 'deezer';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.deezer;

  @override
  bool get supportsSilentRefresh =>
      _authMode == 'arl' && (_arl?.trim().isNotEmpty ?? false);

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded(force: true);

  @override
  Future<void> restoreFromStorage() async {
    try {
      final stored = await readCredentialsJson();
      if (stored == null) {
        resetState();
        return;
      }

      _authMode = stored['mode']?.toString() ?? 'arl';
      _arl = stored['arl']?.toString().trim();
      _accessToken = stored['access_token']?.toString().trim();
      _userId = stored['user_id']?.toString().trim();
      _apiToken = stored['api_token']?.toString().trim();
      _licenseToken = stored['license_token']?.toString().trim();
      _webLossless = stored['web_lossless'] == true;
      _webHq = stored['web_hq'] == true;

      if (_authMode == 'arl') {
        if (_arl == null || _arl!.isEmpty) {
          resetState();
          return;
        }
        final account = await _verifyArlLive();
        setConnected(account);
        await _persistCredentials(account);
      } else {
        if (_accessToken == null || _accessToken!.isEmpty) {
          resetState();
          return;
        }
        final account = await _verifyOAuthLive();
        setConnected(account);
        await _persistCredentials(account);
      }
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

      final requestedMode = params['mode']?.toString().trim();
      final arlParam = params['arl']?.toString().trim();
      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : (arlParam != null && arlParam.isNotEmpty ? 'arl' : 'oauth');

      if (mode == 'arl') {
        if (arlParam == null || arlParam.isEmpty) {
          throw const StreamingException('請輸入 Deezer ARL Cookie 金鑰');
        }
        _authMode = 'arl';
        _arl = arlParam;
        _accessToken = null;

        onProgress?.call('正在向 Deezer 驗證 ARL 工作階段...');
        final account = await _verifyArlLive(cancel: cancel);
        setConnected(account);
        await _persistCredentials(account);
        return;
      }

      if (mode == 'oauth') {
        await _authenticateOAuth(
          params,
          cancel: cancel,
          onProgress: onProgress,
        );
        return;
      }

      throw StreamingException('不支援的 Deezer 驗證模式：$mode');
    } catch (e) {
      throw failWithError(e);
    }
  }

  Future<void> _authenticateOAuth(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    final appId = params['app_id']?.toString().trim() ?? '';
    final appSecret = params['app_secret']?.toString().trim() ?? '';
    if (appId.isEmpty || appSecret.isEmpty) {
      throw const StreamingException(
        'Deezer OAuth 登入需要提供 app_id 與 app_secret',
      );
    }

    String code = params['code']?.toString().trim() ?? '';
    if (code.isEmpty) {
      final server = LoopbackOAuthServer();
      await server.start(port: oauthCallbackPort);
      try {
        final redirectUri =
            params['redirect_uri']?.toString().trim().isNotEmpty == true
                ? params['redirect_uri'].toString().trim()
                : server.callbackUrl('/callback');
        final state = generateOAuthState();
        server.setExpectedState(state);
        final authUri = BaseStreamingProvider.buildUri(
          oauthBaseUrl,
          '/oauth/auth.php',
          <String, String>{
            'app_id': appId,
            'redirect_uri': redirectUri,
            'perms':
                'basic_access,email,offline_access,manage_library,listening_history',
            'state': state,
          },
        );
        onProgress?.call('正在開啟瀏覽器進行 Deezer OAuth 授權...');
        await openSystemBrowser(authUri.toString(), urlOpener: urlOpener);
        final callback = await server.waitForCallback(
          expectedState: state,
          cancel: cancel,
        );
        code = callback.code ?? '';
        if (code.isEmpty) {
          throw const StreamingException('Deezer OAuth 未回傳 code');
        }
      } finally {
        await server.close();
      }
    }

    onProgress?.call('正在向 Deezer 交換存取權杖...');
    final tokenUri = BaseStreamingProvider.buildUri(
      oauthBaseUrl,
      '/oauth/access_token.php',
      <String, String>{
        'app_id': appId,
        'secret': appSecret,
        'code': code,
        'output': 'json',
      },
    );
    final tokenResp = await http.send(
      method: 'GET',
      uri: tokenUri,
      cancel: cancel,
    );
    if (!tokenResp.isSuccess) {
      throw StreamingException(
        'Deezer OAuth 權杖交換失敗（HTTP ${tokenResp.statusCode}）',
        statusCode: tokenResp.statusCode,
      );
    }

    String? access;
    int? expiresSec;
    final bodyTrimmed = tokenResp.body.trim();
    if (bodyTrimmed.startsWith('{')) {
      final decoded = jsonDecode(bodyTrimmed) as Map<String, dynamic>;
      if (decoded['error_reason'] != null || decoded['error'] != null) {
        throw StreamingException(
          'Deezer OAuth 失敗：${decoded['error_reason'] ?? decoded['error']}',
          statusCode: 401,
        );
      }
      access = decoded['access_token']?.toString().trim();
      expiresSec = (decoded['expires'] as num?)?.toInt();
    } else if (bodyTrimmed.contains('access_token=')) {
      final qp = Uri.splitQueryString(bodyTrimmed);
      access = qp['access_token']?.trim();
      expiresSec = int.tryParse(qp['expires'] ?? '');
    } else if (bodyTrimmed.toLowerCase().contains('wrong code') ||
        bodyTrimmed.toLowerCase().contains('error')) {
      throw StreamingException('Deezer OAuth 錯誤：$bodyTrimmed', statusCode: 401);
    }

    if (access == null || access.isEmpty) {
      throw const StreamingException('Deezer OAuth 未回傳有效的 access_token');
    }

    _authMode = 'oauth';
    _accessToken = access;
    _arl = null;
    _apiToken = null;
    _licenseToken = null;
    _webLossless = false;
    _webHq = false;

    onProgress?.call('正在驗證 Deezer 使用者帳號...');
    final account = await _verifyOAuthLive(
      cancel: cancel,
      expiresInSec: expiresSec,
    );
    setConnected(account);
    await _persistCredentials(account);
  }

  Future<StreamingAccountInfo> _verifyArlLive({
    CancellationToken? cancel,
  }) async {
    final uri = BaseStreamingProvider.buildUri(
      gwUrl,
      '',
      const <String, String>{
        'method': 'deezer.getUserData',
        'input': '3',
        'api_version': '1.0',
        'api_token': '',
      },
    );

    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: <String, String>{
        'Cookie': 'arl=${_arl ?? ''}',
        'Accept': 'application/json',
      },
      jsonBody: const <String, dynamic>{},
      cancel: cancel,
    );

    _throwIfGatewayError(json);

    final results = json['results'];
    if (results is! Map) {
      throw const StreamingException(
        'Deezer getUserData 未回傳 results 欄位',
        statusCode: 401,
      );
    }

    final user = results['USER'];
    if (user is! Map) {
      throw const StreamingException(
        'Deezer getUserData 未回傳 USER 資料',
        statusCode: 401,
      );
    }

    final rawUid = user['USER_ID'];
    final uid = rawUid is num ? rawUid.toInt() : int.tryParse('$rawUid') ?? 0;
    if (uid == 0) {
      throw const StreamingException(
        'Deezer ARL Cookie 無效或已過期（USER_ID == 0，未登入任何帳號）',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    _userId = uid.toString();
    _apiToken = results['checkForm']?.toString();

    final options = user['OPTIONS'] ?? results['OPTIONS'];
    if (options is Map) {
      _licenseToken = options['license_token']?.toString().trim();
      _webLossless = options['web_lossless'] == true;
      _webHq = options['web_hq'] == true;
    } else {
      _licenseToken = null;
      _webLossless = false;
      _webHq = false;
    }

    final blogName = user['BLOG_NAME']?.toString().trim();
    final inscription = user['INSCRIPTION'] is Map
        ? (user['INSCRIPTION'] as Map)['FULL_NAME']?.toString().trim()
        : null;
    final displayName = (blogName != null && blogName.isNotEmpty)
        ? blogName
        : ((inscription != null && inscription.isNotEmpty)
              ? inscription
              : 'Deezer #$uid');

    final offerName = results['OFFER_NAME']?.toString().trim() ??
        user['OFFER_NAME']?.toString().trim();
    final planTier = (offerName != null && offerName.isNotEmpty)
        ? offerName
        : (_webLossless
              ? 'Deezer HiFi (Lossless)'
              : (_webHq ? 'Deezer Premium' : 'Deezer Free'));

    return StreamingAccountInfo(
      displayName: displayName,
      planTier: planTier,
      userId: _userId,
      email: user['EMAIL']?.toString(),
      countryCode:
          results['COUNTRY']?.toString() ?? user['COUNTRY']?.toString(),
    );
  }

  Future<StreamingAccountInfo> _verifyOAuthLive({
    CancellationToken? cancel,
    int? expiresInSec,
  }) async {
    final json = await _callPublicApi(
      '/user/me',
      cancel: cancel,
    );
    final uid = json['id']?.toString().trim() ?? '';
    if (uid.isEmpty || uid == '0') {
      throw const StreamingException(
        'Deezer /user/me 未回傳有效帳號 ID',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    _userId = uid;

    final name = json['name']?.toString().trim();
    return StreamingAccountInfo(
      displayName: (name != null && name.isNotEmpty) ? name : 'Deezer #$uid',
      planTier: 'Deezer OAuth (Preview)',
      userId: uid,
      email: json['email']?.toString(),
      countryCode: json['country']?.toString(),
      expiresAt: expiresInSec != null && expiresInSec > 0
          ? clock().add(Duration(seconds: expiresInSec))
          : null,
    );
  }

  Future<Map<String, dynamic>> _callPublicApi(
    String path, {
    Map<String, String> query = const {},
    bool forceRefresh = false,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final qp = <String, String>{
      ...query,
      if (_authMode == 'oauth' &&
          _accessToken != null &&
          _accessToken!.isNotEmpty)
        'access_token': _accessToken!,
    };
    final uri = BaseStreamingProvider.buildUri(apiBaseUrl, path, qp);
    final json = await http.requestJson(
      method: 'GET',
      uri: uri,
      headers: BaseStreamingProvider.withNoCacheHeaders(
        const <String, String>{'Accept': 'application/json'},
        forceRefresh: forceRefresh,
      ),
      cancel: cancel,
      timeout: timeout,
    );

    final err = json['error'];
    if (err is Map) {
      final code = (err['code'] as num?)?.toInt();
      final msg = err['message']?.toString() ?? 'Deezer API 錯誤';
      throw StreamingException(
        'Deezer API 錯誤：$msg',
        statusCode: code == 300 || code == 200 ? 401 : 400,
        isTokenExpired: code == 300 || msg.toLowerCase().contains('token'),
      );
    }
    return json;
  }

  static void _throwIfGatewayError(Map<String, dynamic> json) {
    final err = json['error'];
    if (err is Map && err.isNotEmpty) {
      throw StreamingException(
        'Deezer Gateway 錯誤：${err.entries.map((e) => '${e.key}: ${e.value}').join(', ')}',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (err is List && err.isNotEmpty) {
      throw StreamingException(
        'Deezer Gateway 錯誤：${err.join(', ')}',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
  }

  Future<void> _persistCredentials(StreamingAccountInfo account) {
    return saveCredentialsJson(<String, dynamic>{
      'mode': _authMode,
      if (_arl != null) 'arl': _arl,
      if (_accessToken != null) 'access_token': _accessToken,
      if (_userId != null) 'user_id': _userId,
      if (_apiToken != null) 'api_token': _apiToken,
      if (_licenseToken != null) 'license_token': _licenseToken,
      'web_lossless': _webLossless,
      'web_hq': _webHq,
      'account': account.toJson(),
    });
  }

  @override
  Future<void> refreshSessionIfNeeded({bool force = false}) {
    // Deezer ARL sessions are verified on restore; OAuth offline_access tokens
    // are long-lived. When [force] is true in ARL mode, single-flight refresh
    // re-queries deezer.getUserData to mint fresh api_token & license_token.
    if (!force) return Future<void>.value();
    final existing = _inFlightRefresh;
    if (existing != null) return existing;

    if (!supportsSilentRefresh) {
      return Future<void>.error(
        const StreamingException(
          'Deezer 目前登入方式不支援靜默續期，請重新登入',
          statusCode: 401,
          isTokenExpired: true,
        ),
      );
    }

    final future = _doRefreshArlSession();
    _inFlightRefresh = future;
    return future.whenComplete(() {
      if (identical(_inFlightRefresh, future)) {
        _inFlightRefresh = null;
      }
    });
  }

  Future<void> _doRefreshArlSession() async {
    try {
      final account = await _verifyArlLive();
      setConnected(account);
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(
        e is StreamingException
            ? StreamingException(
                e.message,
                statusCode: e.statusCode ?? 401,
                isTokenExpired: true,
              )
            : StreamingException(
                'Deezer ARL 工作階段更新失敗：$e',
                statusCode: 401,
                isTokenExpired: true,
              ),
      );
    }
  }

  @override
  Future<void> logout() async {
    _arl = null;
    _accessToken = null;
    _userId = null;
    _apiToken = null;
    _licenseToken = null;
    _webLossless = false;
    _webHq = false;
    _previewUrlCache.clear();
    await clearCredentials();
    resetState();
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async {
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

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    ensureAuthenticated();
    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      throw const StreamingException('Deezer 缺少 userId，無法載入推薦內容');
    }

    final albums = <StreamingAlbum>[];
    final tracks = <TrackInfo>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};
    final pageOffset = batchIndex * 10;

    void addAlbums(List<StreamingAlbum> items) {
      for (final a in items) {
        if (seenAlbumIds.add(a.id)) albums.add(a);
      }
    }

    void addTracks(List<TrackInfo> items) {
      for (final t in items) {
        if (seenTrackIds.add(t.id)) tracks.add(t);
      }
    }

    try {
      final recAlbumsJson = await _callPublicApi(
        '/user/$uid/recommendations/albums',
        query: <String, String>{
          'limit': '20',
          if (pageOffset > 0) 'index': '$pageOffset',
        },
        forceRefresh: forceRefresh,
        cancel: cancel,
      );
      addAlbums(_parseAlbums(recAlbumsJson['data']));
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
      final recTracksJson = await _callPublicApi(
        '/user/$uid/recommendations/tracks',
        query: <String, String>{
          'limit': '20',
          if (pageOffset > 0) 'index': '$pageOffset',
        },
        forceRefresh: forceRefresh,
        cancel: cancel,
      );
      addTracks(_parseTracks(recTracksJson['data']));
    } on StreamingException catch (e) {
      if (e.isTokenExpired ||
          e.isCancelled ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == null) {
        rethrow;
      }
    }

    if ((albums.isEmpty || tracks.isEmpty) &&
        _authMode == 'arl' &&
        _arl != null &&
        _arl!.isNotEmpty) {
      try {
        final gwUri = BaseStreamingProvider.buildUri(
          gwUrl,
          '',
          <String, String>{
            'method': 'page.get',
            'input': '3',
            'api_version': '1.0',
            'api_token': _apiToken ?? 'null',
          },
        );
        final gwJson = await http.requestJson(
          method: 'POST',
          uri: gwUri,
          headers: BaseStreamingProvider.withNoCacheHeaders(
            <String, String>{
              'Cookie': 'arl=$_arl',
              'Accept': 'application/json',
            },
            forceRefresh: forceRefresh,
          ),
          jsonBody: const <String, dynamic>{
            'PAGE': 'home',
            'VERSION': '2.3',
          },
          cancel: cancel,
        );
        _throwIfGatewayError(gwJson);
        final parsedGw = _parseGatewayHomeRecommendations(gwJson['results']);
        addAlbums(parsedGw.albums);
        addTracks(parsedGw.tracks);
      } on StreamingException catch (e) {
        if (e.isTokenExpired ||
            e.isCancelled ||
            e.statusCode == 401 ||
            e.statusCode == 403) {
          rethrow;
        }
      }
    }

    if (forceRefresh || batchIndex > 0 || albums.isEmpty) {
      try {
        final chartAlbumsJson = await _callPublicApi(
          '/chart/0/albums',
          query: <String, String>{
            'limit': '20',
            if (pageOffset > 0) 'index': '$pageOffset',
          },
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addAlbums(_parseAlbums(chartAlbumsJson['data']));
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

    if (albums.isEmpty) {
      try {
        final favAlbumsJson = await _callPublicApi(
          '/user/$uid/albums',
          query: <String, String>{
            'limit': '20',
            if (pageOffset > 0) 'index': '$pageOffset',
          },
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addAlbums(_parseAlbums(favAlbumsJson['data']));
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

    if (forceRefresh || batchIndex > 0 || tracks.isEmpty) {
      try {
        final flowJson = await _callPublicApi(
          '/user/$uid/flow',
          query: <String, String>{
            'limit': '20',
            if (pageOffset > 0) 'index': '$pageOffset',
          },
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addTracks(_parseTracks(flowJson['data']));
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

    if ((forceRefresh || batchIndex > 0) &&
        tracks.every((t) => excludeTrackIds.contains(t.id))) {
      final seedTrack = [...tracks, ...catalog.tracks].firstOrNull;
      final rawSeedId = seedTrack != null
          ? BaseStreamingProvider.stripTrackPrefix(seedTrack.id, 'deezer')
          : '';
      if (rawSeedId.isNotEmpty) {
        try {
          final radioJson = await _callPublicApi(
            '/track/$rawSeedId/radio',
            query: const <String, String>{'limit': '20'},
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          addTracks(_parseTracks(radioJson['data']));
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

    if (tracks.isEmpty) {
      try {
        final favTracksJson = await _callPublicApi(
          '/user/$uid/tracks',
          query: const <String, String>{'limit': '20'},
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        addTracks(_parseTracks(favTracksJson['data']));
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

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async {
    ensureAuthenticated();
    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'deezer');
    final json = await _callPublicApi(
      '/playlist/$cleanId/tracks',
      query: const <String, String>{'limit': '100'},
    );
    return _parseTracks(json['data']);
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

  List<Map<String, String>> _requestedFormatsForQuality(String qualityKey) {
    final q = qualityKey.trim().toUpperCase();
    final allFormats = <Map<String, String>>[
      if (_webLossless)
        const <String, String>{
          'cipher': 'BF_CBC_STRIPE',
          'format': 'FLAC',
        },
      const <String, String>{
        'cipher': 'BF_CBC_STRIPE',
        'format': 'MP3_320',
      },
      const <String, String>{
        'cipher': 'BF_CBC_STRIPE',
        'format': 'MP3_128',
      },
    ];
    if (q == 'MP3_320') {
      return allFormats.where((f) => f['format'] != 'FLAC').toList();
    }
    if (q == 'MP3_128') {
      return allFormats.where((f) => f['format'] == 'MP3_128').toList();
    }
    return allFormats;
  }

  static double? _parseFiniteDouble(dynamic raw) {
    final value = raw is num
        ? raw.toDouble()
        : (raw is String ? double.tryParse(raw.trim()) : null);
    if (value == null || !value.isFinite) return null;
    return value;
  }

  Future<
    ({
      String cleanTrackId,
      String url,
      String mediaFormat,
      bool isEncryptedFull,
      bool isPreviewOnly,
      String? mimeType,
      String hintExtension,
      int? bitrateBps,
      int? expireAt,
      AudioFormat format,
      NormalizedLoudness? loudness,
    })
  > _resolveMediaInternal({
    required String rawTrackId,
    String qualityKey = 'default',
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    final trackId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'deezer');
    if (trackId.isEmpty) {
      throw const StreamingException('曲目缺少有效的 Deezer trackId');
    }

    NormalizedLoudness? loudness;
    var retriedAuth = false;

    while (true) {
      final canRequestFullStream = _authMode == 'arl' &&
          _arl != null &&
          _arl!.isNotEmpty &&
          _licenseToken != null &&
          _licenseToken!.isNotEmpty &&
          (_webLossless || _webHq);

      if (!canRequestFullStream) break;

      final Map<String, dynamic> songJson;
      try {
        final songUri = BaseStreamingProvider.buildUri(
          gwUrl,
          '',
          <String, String>{
            'method': 'song.getData',
            'input': '3',
            'api_version': '1.0',
            'api_token': _apiToken ?? '',
          },
        );
        songJson = await http.requestJson(
          method: 'POST',
          uri: songUri,
          headers: <String, String>{
            'Cookie': 'arl=${_arl!}',
            'Accept': 'application/json',
          },
          jsonBody: <String, dynamic>{'sng_id': trackId},
          cancel: cancel,
          timeout: timeout,
        );
        _throwIfGatewayError(songJson);
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            (e.statusCode == 401 || e.isTokenExpired) &&
            !retriedAuth &&
            supportsSilentRefresh) {
          retriedAuth = true;
          await refreshSessionIfNeeded(force: true);
          cancel?.throwIfCancelled();
          continue;
        }
        rethrow;
      }

      final results = songJson['results'];
      final trackToken = results is Map
          ? results['TRACK_TOKEN']?.toString().trim() ?? ''
          : '';
      if (results is Map) {
        final gainDb = _parseFiniteDouble(results['GAIN']);
        if (gainDb != null) {
          loudness = NormalizedLoudness.fromDeezerGain(gainDb);
        }
      }

      if (trackToken.isNotEmpty) {
        final requestedFormats = _requestedFormatsForQuality(qualityKey);

        final mediaRes = await http.sendJsonRaw(
          method: 'POST',
          uri: Uri.parse(mediaBaseUrl),
          headers: const <String, String>{'Accept': 'application/json'},
          jsonBody: <String, dynamic>{
            'license_token': _licenseToken,
            'media': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'FULL',
                'formats': requestedFormats,
              },
            ],
            'track_tokens': <String>[trackToken],
          },
          cancel: cancel,
          timeout: timeout,
        );

        if (mediaRes.statusCode == 401) {
          if (!retriedAuth && supportsSilentRefresh) {
            retriedAuth = true;
            await refreshSessionIfNeeded(force: true);
            cancel?.throwIfCancelled();
            continue;
          }
          throw StreamingException(
            StreamingHttpClient.extractApiErrorMessage(
              mediaRes.json,
              mediaRes.rawBody,
              401,
            ),
            statusCode: 401,
            isTokenExpired: true,
          );
        }

        if (mediaRes.statusCode == 403) {
          throw StreamingException(
            StreamingHttpClient.extractApiErrorMessage(
              mediaRes.json,
              mediaRes.rawBody,
              403,
            ),
            statusCode: 403,
            isTokenExpired: false,
          );
        }

        if (mediaRes.statusCode >= 200 && mediaRes.statusCode < 300) {
          final extracted = _extractMediaUrl(mediaRes.json);
          if (extracted != null) {
            final upperFmt = extracted.format.toUpperCase();
            final isFlac = upperFmt == 'FLAC';
            final bitrate = isFlac
                ? null
                : (upperFmt == 'MP3_320' ? 320000 : 128000);
            return (
              cleanTrackId: trackId,
              url: extracted.url,
              mediaFormat: upperFmt,
              isEncryptedFull: true,
              isPreviewOnly: false,
              mimeType: isFlac ? 'audio/flac' : 'audio/mpeg',
              hintExtension: isFlac ? 'flac' : 'mp3',
              bitrateBps: bitrate,
              expireAt: extracted.expireAt,
              format: AudioFormat(
                codec: isFlac ? AudioCodec.flac : AudioCodec.mp3,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
              ),
              loudness: loudness,
            );
          }
        }
      }
      break;
    }

    // Honest fallback to Deezer official 30s MP3 preview when full stream is unavailable.
    var previewUrl = _previewUrlCache[trackId] ?? '';
    if (previewUrl.isEmpty) {
      final trackJson = await _callPublicApi(
        '/track/$trackId',
        cancel: cancel,
        timeout: timeout,
      );
      previewUrl = trackJson['preview']?.toString().trim() ?? '';
      if (loudness == null) {
        final gainDb = _parseFiniteDouble(trackJson['gain']);
        if (gainDb != null) {
          loudness = NormalizedLoudness.fromDeezerGain(gainDb);
        }
      }
      if (previewUrl.isNotEmpty) {
        _previewUrlCache[trackId] = previewUrl;
      }
    }

    if (previewUrl.isEmpty) {
      throw const StreamingException(
        'Deezer 無法取得完整串流網址，且此曲目亦無官方試聽連結',
      );
    }

    return (
      cleanTrackId: trackId,
      url: previewUrl,
      mediaFormat: 'PREVIEW_MP3',
      isEncryptedFull: false,
      isPreviewOnly: true,
      mimeType: 'audio/mpeg',
      hintExtension: 'mp3',
      bitrateBps: 128000,
      expireAt: null,
      format: const AudioFormat(
        codec: AudioCodec.mp3,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      loudness: loudness,
    );
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    final resolved = await _resolveMediaInternal(
      rawTrackId: key.trackId,
      qualityKey: key.qualityKey,
      cancel: cancelToken,
    );
    if (resolved.isEncryptedFull) {
      return EncryptedRangeSpec(
        key: key,
        url: resolved.url,
        bitrateBps: resolved.bitrateBps,
        mimeType: resolved.mimeType,
        hintExtension: resolved.hintExtension,
        cipher: DeezerBlowfishCipher(
          trackId: resolved.cleanTrackId,
          blockSize: 2048,
          stride: 3,
        ),
        expireAt: resolved.expireAt,
        loudness: resolved.loudness,
        audioFormat: resolved.format,
      );
    }
    return DirectRangeSpec(
      key: key,
      url: resolved.url,
      bitrateBps: resolved.bitrateBps,
      mimeType: resolved.mimeType,
      hintExtension: resolved.hintExtension,
      expireAt: resolved.expireAt,
      loudness: resolved.loudness,
      audioFormat: resolved.format,
      isPreviewOnly: true,
      notice: _previewNotice,
      externalWebUrl: 'https://www.deezer.com/track/${resolved.cleanTrackId}',
    );
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    final resolved = await _resolveMediaInternal(
      rawTrackId: track.id,
      cancel: cancel,
      timeout: timeout,
    );
    return ResolvedStreamResult(
      url: resolved.url,
      hintExtension: resolved.hintExtension,
      format: resolved.format,
      isPreviewOnly: resolved.isPreviewOnly,
      drmNotice: resolved.isPreviewOnly ? _previewNotice : null,
      externalWebUrl: resolved.isPreviewOnly
          ? 'https://www.deezer.com/track/${resolved.cleanTrackId}'
          : null,
    );
  }

  static ({String url, String format, int? expireAt})? _extractMediaUrl(
    Map<String, dynamic> json,
  ) {
    final data = json['data'];
    if (data is! List || data.isEmpty) return null;
    final first = data.first;
    if (first is! Map) return null;
    final media = first['media'];
    if (media is! List || media.isEmpty) return null;
    for (final item in media) {
      if (item is! Map) continue;
      final fmt = item['format']?.toString() ?? 'MP3_128';
      final expRaw = item['exp'] ?? first['exp'];
      final itemExp = (expRaw is num)
          ? expRaw.toInt()
          : int.tryParse(expRaw?.toString() ?? '');
      final sources = item['sources'];
      if (sources is List && sources.isNotEmpty) {
        for (final src in sources) {
          if (src is Map) {
            final url = src['url']?.toString().trim() ?? '';
            if (url.isNotEmpty) {
              final uriExp = int.tryParse(
                Uri.tryParse(url)?.queryParameters['exp'] ?? '',
              );
              return (url: url, format: fmt, expireAt: itemExp ?? uriExp);
            }
          }
        }
      }
    }
    return null;
  }

  AudioFormat get _catalogTrackFormat {
    if (_authMode == 'arl' && _webLossless) {
      return const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      );
    }
    return const AudioFormat(
      codec: AudioCodec.mp3,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    );
  }

  static String? _extractDeezerCover(Map? obj, {Map? trackMap}) {
    const keys = <String>[
      'cover_xl',
      'cover_big',
      'cover_medium',
      'cover',
      'cover_small',
      'picture_xl',
      'picture_big',
      'picture_medium',
      'picture',
    ];
    for (final source in <Map?>[obj, trackMap]) {
      if (source == null) continue;
      for (final key in keys) {
        final url = BaseStreamingProvider.normalizeCoverUrl(
          source[key]?.toString(),
        );
        if (url != null) return url;
      }
    }
    for (final source in <Map?>[obj, trackMap]) {
      if (source == null) continue;
      final rawPic = source['ALB_PICTURE']?.toString().trim();
      final picUrl = BaseStreamingProvider.normalizeCoverUrl(rawPic);
      if (picUrl != null) return picUrl;
      final md5 =
          (source['md5_image'] ?? source['ALB_PICTURE'])?.toString().trim();
      if (md5 != null &&
          md5.isNotEmpty &&
          RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(md5)) {
        return BaseStreamingProvider.normalizeCoverUrl(
          'https://e-cdns-images.dzcdn.net/images/cover/$md5/500x500-000000-80-0-0.jpg',
        );
      }
    }
    return null;
  }

  List<TrackInfo> _parseTracks(
    dynamic rawData, {
    String? fallbackCoverUrl,
    String? fallbackAlbumTitle,
  }) {
    if (rawData is! List) return const [];
    final normalizedFallbackCover =
        BaseStreamingProvider.normalizeCoverUrl(fallbackCoverUrl);
    final tracks = <TrackInfo>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final artistObj = map['artist'] as Map?;
      final albumObj = map['album'] as Map?;
      final coverUrl = _extractDeezerCover(albumObj, trackMap: map) ??
          normalizedFallbackCover;
      final rawAlbTitle = albumObj?['title']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Deezer');
      final preview = map['preview']?.toString().trim();
      if (preview != null && preview.isNotEmpty) {
        _previewUrlCache[id] = preview;
      }

      tracks.add(
        TrackInfo(
          id: 'deezer:$id',
          title: map['title']?.toString() ?? '未命名曲目',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          album: albumTitle,
          duration: Duration(seconds: (map['duration'] as num?)?.toInt() ?? 0),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (map['track_position'] as num?)?.toInt(),
          discNumber: (map['disk_number'] as num?)?.toInt(),
          format: _catalogTrackFormat,
          providerName: 'Deezer',
        ),
      );
    }
    return tracks;
  }

  List<StreamingAlbum> _parseAlbums(dynamic rawData) {
    if (rawData is! List) return const [];
    final albums = <StreamingAlbum>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final artistObj = map['artist'] as Map?;
      final releaseDate = map['release_date']?.toString() ?? '';
      final year = releaseDate.length >= 4
          ? int.tryParse(releaseDate.substring(0, 4))
          : null;
      albums.add(
        StreamingAlbum(
          id: id,
          title: map['title']?.toString() ?? '未命名專輯',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _extractDeezerCover(map),
          providerKind: kind,
          trackCount: (map['nb_tracks'] as num?)?.toInt(),
          qualityLabel: _webLossless ? 'FLAC 16-bit / 44.1 kHz' : null,
        ),
      );
    }
    return albums;
  }

  List<StreamingPlaylist> _parsePlaylists(dynamic rawData) {
    if (rawData is! List) return const [];
    final playlists = <StreamingPlaylist>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      playlists.add(
        StreamingPlaylist(
          id: id,
          title: map['title']?.toString() ?? '未命名歌單',
          description: map['description']?.toString(),
          trackCount: (map['nb_tracks'] as num?)?.toInt() ?? 0,
          coverUrl: _extractDeezerCover(map),
          providerKind: kind,
        ),
      );
    }
    return playlists;
  }
}
