import 'dart:convert';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../streaming_provider.dart';

/// Real Tidal OAuth 2.0 (PKCE + Device Flow) and Hi-Res FLAC streaming provider.
class TidalProvider extends BaseStreamingProvider {
  static const String defaultScopes = 'r_usr w_usr w_sub';

  final String authBaseUrl;
  final String tokenBaseUrl;
  final String apiBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;

  String? _clientId;
  String? _clientSecret;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  String? _userId;
  String _countryCode = 'US';

  TidalProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.authBaseUrl = 'https://login.tidal.com',
    this.tokenBaseUrl = 'https://auth.tidal.com',
    this.apiBaseUrl = 'https://api.tidal.com/v1',
    this.oauthCallbackPort = 0,
    this.urlOpener,
  });

  @override
  String get kind => 'tidal';

  Map<String, String> get _authHeaders => <String, String>{
    'Authorization': 'Bearer ${_accessToken ?? ''}',
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

      _clientId = stored['client_id']?.toString();
      _clientSecret = stored['client_secret']?.toString();
      _accessToken = stored['access_token']?.toString();
      _refreshToken = stored['refresh_token']?.toString();
      _userId = stored['user_id']?.toString();
      _countryCode = stored['country_code']?.toString() ?? 'US';
      final expRaw = stored['expires_at']?.toString();
      _expiresAt = expRaw != null ? DateTime.tryParse(expRaw) : null;

      if (_accessToken == null || _accessToken!.isEmpty) {
        resetState();
        return;
      }

      await refreshSessionIfNeeded();
      final account = await _verifySessionLive();
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

      final requestedMode = params['mode']?.toString().trim();
      final directToken = params['access_token']?.toString().trim();
      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : (directToken != null && directToken.isNotEmpty
                ? 'access_token'
                : 'pkce');

      _clientId = params['client_id']?.toString().trim();
      _clientSecret = params['client_secret']?.toString().trim();

      if (mode == 'access_token') {
        if (directToken == null || directToken.isEmpty) {
          throw const StreamingException('請輸入 Tidal Access Token');
        }
        _accessToken = directToken;
        final refresh = params['refresh_token']?.toString().trim();
        _refreshToken = (refresh != null && refresh.isNotEmpty) ? refresh : null;
        final expiresIn = (params['expires_in'] as num?)?.toInt();
        _expiresAt = expiresIn != null
            ? clock().add(Duration(seconds: expiresIn))
            : null;
      } else if (mode == 'pkce') {
        await _authenticatePkce(
          params,
          cancel: cancel,
          onProgress: onProgress,
        );
      } else if (mode == 'device_code') {
        await _authenticateDeviceCode(
          params,
          cancel: cancel,
          onProgress: onProgress,
        );
      } else {
        throw StreamingException('不支援的 Tidal 驗證模式：$mode');
      }

      onProgress?.call('正在驗證 Tidal 會員身分與訂閱音質...');
      final account = await _verifySessionLive(cancel: cancel);
      setConnected(account);
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(e);
    }
  }

  Future<void> _authenticatePkce(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    final clientId = _clientId ?? '';
    if (clientId.isEmpty) {
      throw const StreamingException('Tidal PKCE 登入需要提供 client_id');
    }
    final scope = params['scope']?.toString().trim().isNotEmpty == true
        ? params['scope'].toString().trim()
        : defaultScopes;

    final suppliedCode = params['code']?.toString().trim();
    final suppliedVerifier =
        (params['verifier'] ?? params['code_verifier'])?.toString().trim();

    String code;
    String verifier;
    String redirectUri;

    if (suppliedCode != null &&
        suppliedCode.isNotEmpty &&
        suppliedVerifier != null &&
        suppliedVerifier.isNotEmpty) {
      code = suppliedCode;
      verifier = suppliedVerifier;
      redirectUri = params['redirect_uri']?.toString().trim() ??
          'http://127.0.0.1:9888/callback';
    } else {
      final server = LoopbackOAuthServer();
      await server.start(port: oauthCallbackPort);
      try {
        redirectUri = params['redirect_uri']?.toString().trim().isNotEmpty == true
            ? params['redirect_uri'].toString().trim()
            : server.callbackUrl('/callback');
        final pkce = generatePkcePair();
        final state = generateOAuthState();
        verifier = pkce.verifier;
        server.setExpectedState(state);

        final authUri = BaseStreamingProvider.buildUri(
          authBaseUrl,
          '/authorize',
          <String, String>{
            'response_type': 'code',
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'code_challenge': pkce.challenge,
            'code_challenge_method': 'S256',
            'scope': scope,
            'state': state,
          },
        );

        onProgress?.call('正在開啟瀏覽器進行 Tidal OAuth 登入...');
        await openSystemBrowser(authUri.toString(), urlOpener: urlOpener);

        final callback = await server.waitForCallback(
          expectedState: state,
          cancel: cancel,
        );
        code = callback.code ?? '';
        if (code.isEmpty) {
          throw const StreamingException('Tidal OAuth 未回傳授權碼');
        }
      } finally {
        await server.close();
      }
    }

    onProgress?.call('正在向 Tidal 交換 OAuth 權杖...');
    final tokenUri =
        BaseStreamingProvider.buildUri(tokenBaseUrl, '/v1/oauth2/token');
    final form = <String, String>{
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': verifier,
      if (_clientSecret != null && _clientSecret!.isNotEmpty)
        'client_secret': _clientSecret!,
    };
    final tokenResp = await http.requestJson(
      method: 'POST',
      uri: tokenUri,
      formBody: BaseStreamingProvider.encodeForm(form),
      cancel: cancel,
    );
    _applyTokenResponse(tokenResp);
  }

  Future<void> _authenticateDeviceCode(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    final clientId = _clientId ?? '';
    if (clientId.isEmpty) {
      throw const StreamingException('Tidal 裝置授權需要提供 client_id');
    }
    final scope = params['scope']?.toString().trim().isNotEmpty == true
        ? params['scope'].toString().trim()
        : defaultScopes;

    onProgress?.call('正在向 Tidal 請求裝置授權碼...');
    final deviceUri = BaseStreamingProvider.buildUri(
      tokenBaseUrl,
      '/v1/oauth2/device_authorization',
    );
    final deviceResp = await http.requestJson(
      method: 'POST',
      uri: deviceUri,
      formBody: BaseStreamingProvider.encodeForm(<String, String>{
        'client_id': clientId,
        'scope': scope,
      }),
      cancel: cancel,
    );

    final deviceCode = deviceResp['deviceCode']?.toString() ??
        deviceResp['device_code']?.toString() ??
        '';
    final userCode = deviceResp['userCode']?.toString() ??
        deviceResp['user_code']?.toString() ??
        '';
    var verifyUrl = (deviceResp['verificationUriComplete'] ??
                deviceResp['verification_uri_complete'] ??
                deviceResp['verificationUri'] ??
                deviceResp['verification_uri'])
            ?.toString()
            .trim() ??
        'https://link.tidal.com';
    if (!verifyUrl.startsWith('http://') && !verifyUrl.startsWith('https://')) {
      verifyUrl = 'https://$verifyUrl';
    }
    final expiresIn = (deviceResp['expiresIn'] as num?)?.toInt() ??
        (deviceResp['expires_in'] as num?)?.toInt() ??
        300;
    final intervalSec = (deviceResp['interval'] as num?)?.toInt() ?? 2;

    if (deviceCode.isEmpty || userCode.isEmpty) {
      throw const StreamingException('Tidal 未回傳有效的 deviceCode 或 userCode');
    }

    onProgress?.call('請開啟 $verifyUrl 並輸入驗證碼：$userCode');
    try {
      await openSystemBrowser(verifyUrl, urlOpener: urlOpener);
    } catch (_) {}

    final deadline = clock().add(Duration(seconds: expiresIn));
    var pollDelay = intervalSec <= 0
        ? const Duration(milliseconds: 25)
        : Duration(seconds: intervalSec);
    final tokenUri =
        BaseStreamingProvider.buildUri(tokenBaseUrl, '/v1/oauth2/token');

    while (true) {
      cancel?.throwIfCancelled();
      if (clock().isAfter(deadline)) {
        throw const StreamingException(
          'Tidal 裝置授權碼已過期，請重新登入',
          isTokenExpired: true,
        );
      }

      await BaseStreamingProvider.cancellableDelay(pollDelay, cancel);

      final res = await http.sendJsonRaw(
        method: 'POST',
        uri: tokenUri,
        formBody: BaseStreamingProvider.encodeForm(<String, String>{
          'client_id': clientId,
          if (_clientSecret != null && _clientSecret!.isNotEmpty)
            'client_secret': _clientSecret!,
          'device_code': deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'scope': scope,
        }),
        cancel: cancel,
      );

      if (res.statusCode >= 200 && res.statusCode < 300) {
        _applyTokenResponse(res.json);
        return;
      }

      final errCode = res.json['error']?.toString() ?? '';
      if (errCode == 'authorization_pending') {
        continue;
      }
      if (errCode == 'slow_down') {
        pollDelay += intervalSec <= 0
            ? const Duration(milliseconds: 25)
            : const Duration(seconds: 5);
        continue;
      }

      throw StreamingException(
        StreamingHttpClient.extractApiErrorMessage(
          res.json,
          res.rawBody,
          res.statusCode,
        ),
        statusCode: res.statusCode,
        isTokenExpired: errCode == 'expired_token' || res.statusCode == 401,
      );
    }
  }

  void _applyTokenResponse(Map<String, dynamic> json) {
    final access = json['access_token']?.toString().trim() ?? '';
    if (access.isEmpty) {
      throw const StreamingException('Tidal OAuth 回應缺少 access_token');
    }
    _accessToken = access;
    final refresh = json['refresh_token']?.toString().trim();
    if (refresh != null && refresh.isNotEmpty) {
      _refreshToken = refresh;
    }
    final expSec = (json['expires_in'] as num?)?.toInt() ?? 3600;
    _expiresAt = clock().add(Duration(seconds: expSec));
    if (json['user_id'] != null) {
      _userId = json['user_id'].toString();
    }
  }

  Future<StreamingAccountInfo> _verifySessionLive({
    CancellationToken? cancel,
  }) async {
    final sessionUri = BaseStreamingProvider.buildUri(apiBaseUrl, '/sessions');
    final sessionJson = await http.requestJson(
      method: 'GET',
      uri: sessionUri,
      headers: _authHeaders,
      cancel: cancel,
    );

    final uid = sessionJson['userId']?.toString().trim() ?? '';
    if (uid.isEmpty || uid == '0') {
      throw const StreamingException(
        'Tidal /sessions 未回傳有效 userId',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    _userId = uid;
    final cc = sessionJson['countryCode']?.toString().trim();
    if (cc != null && cc.isNotEmpty) {
      _countryCode = cc;
    }

    final userUri =
        BaseStreamingProvider.buildUri(apiBaseUrl, '/users/$uid');
    final userJson = await http.requestJson(
      method: 'GET',
      uri: userUri,
      headers: _authHeaders,
      cancel: cancel,
    );

    final firstName = userJson['firstName']?.toString().trim() ?? '';
    final lastName = userJson['lastName']?.toString().trim() ?? '';
    final fullName = '$firstName $lastName'.trim();
    final username = userJson['username']?.toString().trim() ?? '';
    final email = userJson['email']?.toString().trim();
    final displayName = fullName.isNotEmpty
        ? fullName
        : (username.isNotEmpty ? username : (email ?? 'Tidal User #$uid'));

    String? planTier;
    final subUri = BaseStreamingProvider.buildUri(
      apiBaseUrl,
      '/users/$uid/subscription',
    );
    final subRes = await http.sendJsonRaw(
      method: 'GET',
      uri: subUri,
      headers: _authHeaders,
      cancel: cancel,
    );
    if (subRes.statusCode >= 200 && subRes.statusCode < 300) {
      final subObj = subRes.json['subscription'];
      final type = (subObj is Map ? subObj['type'] : null)?.toString();
      final quality = subRes.json['highestSoundQuality']?.toString();
      if (type != null && quality != null) {
        planTier = '$type ($quality)';
      } else {
        planTier = type ?? quality;
      }
    } else if (subRes.statusCode == 401 || subRes.statusCode == 403) {
      throw StreamingException(
        StreamingHttpClient.extractApiErrorMessage(
          subRes.json,
          subRes.rawBody,
          subRes.statusCode,
        ),
        statusCode: subRes.statusCode,
        isTokenExpired: subRes.statusCode == 401,
      );
    }

    return StreamingAccountInfo(
      displayName: displayName,
      planTier: planTier,
      userId: uid,
      email: email,
      countryCode: _countryCode,
      expiresAt: _expiresAt,
    );
  }

  @override
  Future<void> refreshSessionIfNeeded() async {
    final exp = _expiresAt;
    if (exp == null) return;
    if (clock().isBefore(exp.subtract(const Duration(seconds: 60)))) {
      return;
    }

    final refresh = _refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw failWithError(
        const StreamingException(
          'Tidal 存取權杖已過期且無 refresh_token，請重新登入',
          statusCode: 401,
          isTokenExpired: true,
        ),
      );
    }

    try {
      final tokenUri =
          BaseStreamingProvider.buildUri(tokenBaseUrl, '/v1/oauth2/token');
      final res = await http.requestJson(
        method: 'POST',
        uri: tokenUri,
        formBody: BaseStreamingProvider.encodeForm(<String, String>{
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
          if (_clientId != null && _clientId!.isNotEmpty)
            'client_id': _clientId!,
          if (_clientSecret != null && _clientSecret!.isNotEmpty)
            'client_secret': _clientSecret!,
        }),
      );
      _applyTokenResponse(res);
      if (accountInfo != null) {
        final updated = accountInfo!.copyWith(expiresAt: _expiresAt);
        setConnected(updated);
        await _persistCredentials(updated);
      }
    } catch (e) {
      throw failWithError(
        e is StreamingException
            ? e
            : StreamingException(
                'Tidal 權杖自動更新失敗：$e',
                statusCode: 401,
                isTokenExpired: true,
              ),
      );
    }
  }

  @override
  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _userId = null;
    await clearCredentials();
    resetState();
  }

  Future<void> _persistCredentials(StreamingAccountInfo account) {
    return saveCredentialsJson(<String, dynamic>{
      if (_clientId != null && _clientId!.isNotEmpty) 'client_id': _clientId,
      if (_clientSecret != null && _clientSecret!.isNotEmpty)
        'client_secret': _clientSecret,
      if (_accessToken != null) 'access_token': _accessToken,
      if (_refreshToken != null) 'refresh_token': _refreshToken,
      if (_expiresAt != null) 'expires_at': _expiresAt!.toUtc().toIso8601String(),
      if (_userId != null) 'user_id': _userId,
      'country_code': _countryCode,
      'account': account.toJson(),
    });
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async {
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

  Future<Map<String, dynamic>> _requestTidalGet(
    String path,
    Map<String, String> query, {
    CancellationToken? cancel,
  }) {
    return http.requestJson(
      method: 'GET',
      uri: BaseStreamingProvider.buildUri(apiBaseUrl, path, query),
      headers: _authHeaders,
      cancel: cancel,
    );
  }

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    var albums = <StreamingAlbum>[];
    var tracks = <TrackInfo>[];

    try {
      final homeJson = await _requestTidalGet(
        '/pages/home',
        <String, String>{
          'countryCode': _countryCode,
          'deviceType': 'BROWSER',
        },
        cancel: cancel,
      );
      final extracted = _extractHomeRecommendations(homeJson);
      albums = extracted.albums;
      tracks = extracted.tracks;
    } on StreamingException catch (e) {
      if (e.isTokenExpired ||
          e.isCancelled ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == null) {
        rethrow;
      }
    }

    final uid = _userId;
    if (uid != null && uid.isNotEmpty) {
      if (albums.isEmpty) {
        try {
          final favAlbumsJson = await _requestTidalGet(
            '/users/$uid/favorites/albums',
            <String, String>{'countryCode': _countryCode, 'limit': '20'},
            cancel: cancel,
          );
          albums = _parseAlbumList(favAlbumsJson['items']);
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
      if (tracks.isEmpty) {
        try {
          final favTracksJson = await _requestTidalGet(
            '/users/$uid/favorites/tracks',
            <String, String>{'countryCode': _countryCode, 'limit': '20'},
            cancel: cancel,
          );
          tracks = _parseTrackList(favTracksJson['items']);
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

    return StreamingRecommendations(
      providerKind: kind,
      albums: albums,
      tracks: tracks,
      fetchedAt: clock(),
    );
  }

  ({List<StreamingAlbum> albums, List<TrackInfo> tracks})
      _extractHomeRecommendations(Map<String, dynamic> root) {
    final rawAlbums = <Map<String, dynamic>>[];
    final rawTracks = <Map<String, dynamic>>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};

    void considerItem(Map<String, dynamic> rawMap, {String? hintType}) {
      final map = rawMap['item'] is Map
          ? Map<String, dynamic>.from(rawMap['item'] as Map)
          : rawMap;
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty || map['uuid'] != null) return;
      final upperHint = (hintType ?? map['type']?.toString() ?? '').toUpperCase();
      final isTrack = upperHint.contains('TRACK') ||
          map['album'] is Map ||
          map['trackNumber'] != null ||
          (map['duration'] != null && map['numberOfTracks'] == null);
      final isAlbum = !isTrack &&
          (upperHint.contains('ALBUM') ||
              map['numberOfTracks'] != null ||
              map['releaseDate'] != null ||
              map['cover'] != null);
      if (isTrack) {
        if (seenTrackIds.add(id)) {
          rawTracks.add(map);
        }
      } else if (isAlbum) {
        if (seenAlbumIds.add(id)) {
          rawAlbums.add(map);
        }
      }
    }

    void walk(dynamic node, {String? hintType}) {
      if (node is Map) {
        final map = Map<String, dynamic>.from(node);
        final nextHint = map['type']?.toString() ?? hintType;
        if (map['albums'] is List) {
          for (final item in map['albums'] as List) {
            if (item is Map) {
              considerItem(
                Map<String, dynamic>.from(item),
                hintType: 'ALBUM',
              );
            }
          }
        }
        if (map['tracks'] is List) {
          for (final item in map['tracks'] as List) {
            if (item is Map) {
              considerItem(
                Map<String, dynamic>.from(item),
                hintType: 'TRACK',
              );
            }
          }
        }
        if (map['id'] != null && map['title'] != null) {
          considerItem(map, hintType: nextHint);
          return;
        }
        for (final entry in map.entries) {
          if (entry.key == 'albums' || entry.key == 'tracks') continue;
          walk(entry.value, hintType: nextHint);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item, hintType: hintType);
        }
      }
    }

    walk(root);
    return (
      albums: _parseAlbumList(rawAlbums),
      tracks: _parseTrackList(rawTracks),
    );
  }

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
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
    final coverUrl = _tidalCoverUrl(albumJson['cover']?.toString());
    final quality = albumJson['audioQuality']?.toString().toUpperCase() ?? 'LOSSLESS';
    final albumFmt = _formatForTidalQuality(quality);

    final parsedTracks = _parseTrackList(rawTracks);
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

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async {
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

  @override
  Future<StreamingCatalog> search(String query) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

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
    );

    return StreamingCatalog(
      tracks: _parseTrackList(tracksJson['items']),
      albums: _parseAlbumList(albumsJson['items']),
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
    await refreshSessionIfNeeded();
    cancel?.throwIfCancelled();

    final trackId = BaseStreamingProvider.stripTrackPrefix(track.id, 'tidal');
    final uri = BaseStreamingProvider.buildUri(
      apiBaseUrl,
      '/tracks/$trackId/playbackinfopostpaywall',
      <String, String>{
        'audioquality': 'HI_RES_LOSSLESS',
        'playbackmode': 'STREAM',
        'assetpresentation': 'FULL',
        'countryCode': _countryCode,
      },
    );

    final json = await http.requestJson(
      method: 'GET',
      uri: uri,
      headers: _authHeaders,
      cancel: cancel,
      timeout: timeout,
    );

    final mimeType = json['manifestMimeType']?.toString() ?? '';
    final manifestB64 = json['manifest']?.toString() ?? '';
    if (mimeType == 'application/dash+xml' || manifestB64.isEmpty) {
      throw StreamingException(
        'Tidal 此曲目使用受保護的串流封裝格式（$mimeType），目前無法於原生無加密管線直接播放',
        isDrmRestricted: true,
      );
    }

    if (mimeType != 'application/vnd.tidal.bts') {
      throw StreamingException(
        '不支援的 Tidal 串流清單格式：$mimeType',
        isDrmRestricted: mimeType.toLowerCase().contains('drm') ||
            mimeType.toLowerCase().contains('dash'),
      );
    }

    final Map<String, dynamic> decodedManifest;
    try {
      final rawManifest = utf8.decode(base64Decode(manifestB64));
      final parsed = jsonDecode(rawManifest);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('Manifest is not a JSON object');
      }
      decodedManifest = parsed;
    } catch (e) {
      throw StreamingException('解析 Tidal Base64 manifest 失敗：$e');
    }

    final encType = decodedManifest['encryptionType']?.toString().trim() ?? '';
    if (encType.isNotEmpty && encType.toUpperCase() != 'NONE') {
      throw StreamingException(
        'Tidal 音訊串流受加密保護（$encType），拒絕輸出加密雜訊至 DAC',
        isDrmRestricted: true,
      );
    }

    final urls = decodedManifest['urls'];
    final streamUrl = (urls is List && urls.isNotEmpty)
        ? urls.first?.toString().trim() ?? ''
        : '';
    if (streamUrl.isEmpty) {
      throw const StreamingException('Tidal manifest 未包含任何可用的串流 URL');
    }

    final manifestMime =
        decodedManifest['mimeType']?.toString().toLowerCase() ?? '';
    final codecs = decodedManifest['codecs']?.toString().toLowerCase() ?? '';
    final audioQuality = json['audioQuality']?.toString().toUpperCase() ?? '';

    final isFlac = manifestMime.contains('flac') || codecs.contains('flac');
    final codec = isFlac ? AudioCodec.flac : AudioCodec.aac;

    final bitDepth = (decodedManifest['bitDepth'] as num?)?.toInt() ??
        (json['bitDepth'] as num?)?.toInt() ??
        (audioQuality.contains('HI_RES') ? 24 : 16);
    final sampleRate = (decodedManifest['sampleRate'] as num?)?.toInt() ??
        (json['sampleRate'] as num?)?.toInt() ??
        (audioQuality.contains('HI_RES') ? 96000 : 44100);

    return ResolvedStreamResult(
      url: streamUrl,
      hintExtension: isFlac ? 'flac' : 'm4a',
      format: AudioFormat(
        codec: codec,
        sampleRateHz: sampleRate,
        bitDepth: bitDepth,
        channels: 2,
      ),
    );
  }

  List<TrackInfo> _parseTrackList(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final tracks = <TrackInfo>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : Map<String, dynamic>.from(entry);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final artistObj = map['artist'] is Map
          ? map['artist'] as Map
          : (map['artists'] is List && (map['artists'] as List).isNotEmpty
                ? (map['artists'] as List).first as Map?
                : null);
      final albumObj = map['album'] is Map ? map['album'] as Map : null;
      final coverUrl = _tidalCoverUrl(albumObj?['cover']?.toString());
      final durationSec = (map['duration'] as num?)?.toInt() ?? 0;
      final quality = map['audioQuality']?.toString().toUpperCase() ?? '';

      tracks.add(
        TrackInfo(
          id: 'tidal:$id',
          title: map['title']?.toString() ?? '未命名曲目',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          album: albumObj?['title']?.toString() ?? 'Tidal',
          duration: Duration(seconds: durationSec),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (map['trackNumber'] as num?)?.toInt(),
          discNumber: (map['volumeNumber'] as num?)?.toInt(),
          format: _formatForTidalQuality(quality),
          providerName: 'Tidal',
        ),
      );
    }
    return tracks;
  }

  List<StreamingAlbum> _parseAlbumList(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final albums = <StreamingAlbum>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : Map<String, dynamic>.from(entry);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final artistObj = map['artist'] is Map
          ? map['artist'] as Map
          : (map['artists'] is List && (map['artists'] as List).isNotEmpty
                ? (map['artists'] as List).first as Map?
                : null);
      final releaseDate = map['releaseDate']?.toString() ?? '';
      final year = releaseDate.length >= 4
          ? int.tryParse(releaseDate.substring(0, 4))
          : null;

      albums.add(
        StreamingAlbum(
          id: id,
          title: map['title']?.toString() ?? '未命名專輯',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _tidalCoverUrl(map['cover']?.toString()),
          providerKind: kind,
          trackCount: (map['numberOfTracks'] as num?)?.toInt(),
          qualityLabel: map['audioQuality']?.toString(),
        ),
      );
    }
    return albums;
  }

  List<StreamingPlaylist> _parsePlaylistList(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final playlists = <StreamingPlaylist>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : Map<String, dynamic>.from(entry);
      final id = map['uuid']?.toString() ?? map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      playlists.add(
        StreamingPlaylist(
          id: id,
          title: map['title']?.toString() ?? '未命名歌單',
          description: map['description']?.toString(),
          trackCount: (map['numberOfTracks'] as num?)?.toInt() ?? 0,
          coverUrl: _tidalCoverUrl(
            map['squareImage']?.toString() ?? map['image']?.toString(),
          ),
          providerKind: kind,
        ),
      );
    }
    return playlists;
  }

  static AudioFormat _formatForTidalQuality(String quality) {
    if (quality == 'HI_RES_LOSSLESS' || quality == 'HI_RES') {
      return const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 96000,
        bitDepth: 24,
        channels: 2,
      );
    }
    if (quality == 'LOSSLESS') {
      return const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      );
    }
    return const AudioFormat(
      codec: AudioCodec.aac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    );
  }

  static String? _tidalCoverUrl(String? rawCover) {
    if (rawCover == null || rawCover.trim().isEmpty) return null;
    final trimmed = rawCover.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return 'https://resources.tidal.com/images/${trimmed.replaceAll('-', '/')}/640x640.jpg';
  }
}
