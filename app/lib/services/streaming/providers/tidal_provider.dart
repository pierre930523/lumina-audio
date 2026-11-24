import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';
import '../yt_dlp_service.dart';

/// Real Tidal OAuth 2.0 (PKCE + Device Flow) and Hi-Res FLAC streaming provider.
class TidalProvider extends BaseStreamingProvider implements StreamResolver {
  static const String defaultScopes = 'r_usr w_usr w_sub';
  static const String byokCredentialStorageKey = 'streaming:tidal:byok';

  final String authBaseUrl;
  final String tokenBaseUrl;
  final String apiBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;
  final YtDlpService? _ytDlpService;

  String? _clientId;
  String? _clientSecret;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  String? _userId;
  String _countryCode = 'US';
  int _fallbackRequestCounter = -1;
  Future<void>? _inFlightRefresh;
  final List<String> _recentRecAlbumIds = <String>[];
  final List<String> _recentRecTrackIds = <String>[];

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
    YtDlpService? ytDlpService,
    // ignore: prefer_initializing_formals
  }) : _ytDlpService = ytDlpService;

  @override
  String get kind => 'tidal';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.tidal;

  @override
  bool get supportsSilentRefresh =>
      _refreshToken != null && _refreshToken!.trim().isNotEmpty;

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded(force: true);

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
      final storedCc = stored['country_code']?.toString().trim().toUpperCase();
      _countryCode =
          (storedCc != null && storedCc.isNotEmpty) ? storedCc : 'US';
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

  static String _normalizeBearerToken(String? raw) {
    var token = raw?.trim() ?? '';
    if (token.isEmpty) return '';
    token = token
        .replaceFirst(
          RegExp(r'^authorization\s*:\s*', caseSensitive: false),
          '',
        )
        .trim();
    token = token
        .replaceFirst(RegExp(r'^bearer\s+', caseSensitive: false), '')
        .trim();
    return token;
  }

  static Map<String, dynamic>? _decodeJwtPayload(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final payload = jsonDecode(decoded);
      if (payload is Map<String, dynamic>) return payload;
      if (payload is Map) return Map<String, dynamic>.from(payload);
    } catch (_) {
      return null;
    }
    return null;
  }

  static DateTime? _extractJwtExpiryFromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final exp = payload['exp'];
    if (exp is num) {
      final expSec = exp.toInt();
      if (expSec > 0) {
        return DateTime.fromMillisecondsSinceEpoch(
          expSec * 1000,
          isUtc: true,
        );
      }
    }
    return null;
  }

  /// Reads user-supplied BYOK Client ID / Secret persisted locally via DPAPI.
  Future<({String clientId, String clientSecret})?> readRememberedByok() async {
    try {
      final raw = await credentialStore.read(byokCredentialStorageKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final cid = decoded['client_id']?.toString().trim() ?? '';
          final csec = decoded['client_secret']?.toString().trim() ?? '';
          if (cid.isNotEmpty) {
            return (clientId: cid, clientSecret: csec);
          }
        }
      }
    } catch (_) {}

    try {
      final stored = await readCredentialsJson();
      final cid = stored?['client_id']?.toString().trim() ?? '';
      final csec = stored?['client_secret']?.toString().trim() ?? '';
      if (cid.isNotEmpty) {
        return (clientId: cid, clientSecret: csec);
      }
    } catch (_) {}

    return null;
  }

  Future<void> saveRememberedByok({
    required String clientId,
    String? clientSecret,
  }) async {
    final cid = clientId.trim();
    final csec = clientSecret?.trim() ?? '';
    if (cid.isEmpty) return;
    await credentialStore.write(
      byokCredentialStorageKey,
      jsonEncode(<String, dynamic>{
        'client_id': cid,
        if (csec.isNotEmpty) 'client_secret': csec,
      }),
    );
  }

  Future<void> clearRememberedByok() async {
    await credentialStore.delete(byokCredentialStorageKey);
    if (authState != StreamingAuthState.connected) {
      _clientId = null;
      _clientSecret = null;
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
      final directToken = _normalizeBearerToken(
        params['access_token']?.toString(),
      );
      final rawRefresh = params['refresh_token']?.toString().trim() ?? '';
      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : ((directToken.isNotEmpty || rawRefresh.isNotEmpty)
                ? 'access_token'
                : 'pkce');

      _clientId = params['client_id']?.toString().trim();
      _clientSecret = params['client_secret']?.toString().trim();

      if (mode == 'access_token' || mode == 'refresh_token') {
        final directPayload =
            directToken.isNotEmpty ? _decodeJwtPayload(directToken) : null;
        final directType =
            directPayload?['type']?.toString().trim().toLowerCase() ?? '';
        final isDirectRefreshJwt = directType == 'o2_refresh';

        if (directToken.isEmpty && rawRefresh.isEmpty) {
          throw const StreamingException(
            '請輸入 Tidal Access Token 或 Refresh Token',
          );
        }

        if (!params.containsKey('client_id') &&
            (_clientId == null || _clientId!.isEmpty) &&
            (mode == 'refresh_token' ||
                directToken.isEmpty ||
                isDirectRefreshJwt ||
                rawRefresh.isNotEmpty)) {
          final remembered = await readRememberedByok();
          if (remembered != null) {
            _clientId = remembered.clientId;
            if ((_clientSecret == null || _clientSecret!.isEmpty) &&
                remembered.clientSecret.isNotEmpty) {
              _clientSecret = remembered.clientSecret;
            }
          }
        }

        if (mode == 'refresh_token' ||
            directToken.isEmpty ||
            isDirectRefreshJwt) {
          final effectiveRefresh = rawRefresh.isNotEmpty
              ? rawRefresh
              : (isDirectRefreshJwt ? directToken : '');
          if (effectiveRefresh.isEmpty) {
            throw const StreamingException('請輸入 Tidal Refresh Token');
          }
          if (_clientId == null || _clientId!.isEmpty) {
            final cid =
                _decodeJwtPayload(effectiveRefresh)?['cid']?.toString().trim();
            final cidHint =
                (cid != null && cid.isNotEmpty) ? '（cid=$cid）' : '';
            if (isDirectRefreshJwt) {
              throw StreamingException(
                '偵測到此權杖為 TIDAL Refresh Token$cidHint，無法直接作為 Access Token 驗證；'
                '請改貼 Access Token，或展開下方「進階 / 自訂 Client ID (BYOK)」填入對應的 Client ID 與 Client Secret 後登入',
                statusCode: 401,
              );
            }
            throw StreamingException(
              '使用 Refresh Token 登入需要提供對應的 Client ID$cidHint'
              '（請展開下方「進階 / 自訂 Client ID (BYOK)」填入 Client ID 與 Client Secret）',
            );
          }
          _refreshToken = effectiveRefresh;
          onProgress?.call('正在使用 Refresh Token 向 Tidal 換發 Access Token...');
          await _exchangeRefreshToken(effectiveRefresh, cancel: cancel);
        } else {
          _accessToken = directToken;
          _refreshToken = rawRefresh.isNotEmpty ? rawRefresh : null;
          final expiresIn = (params['expires_in'] as num?)?.toInt();
          if (expiresIn != null) {
            _expiresAt = clock().add(Duration(seconds: expiresIn));
          } else {
            final jwtExp = _extractJwtExpiryFromPayload(directPayload);
            if (_refreshToken != null) {
              _expiresAt = jwtExp;
              if (_expiresAt != null) {
                await refreshSessionIfNeeded();
              }
            } else {
              _expiresAt = (jwtExp != null &&
                      jwtExp.isAfter(clock().add(const Duration(seconds: 60))))
                  ? jwtExp
                  : null;
            }
          }
        }
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
      if (params['remember_byok'] == true &&
          _clientId != null &&
          _clientId!.isNotEmpty) {
        await saveRememberedByok(
          clientId: _clientId!,
          clientSecret: _clientSecret,
        );
      } else if (params['remember_byok'] == false) {
        await clearRememberedByok();
      }
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
    final sessionCc =
        sessionJson['countryCode']?.toString().trim().toUpperCase() ?? '';
    if (sessionCc.isNotEmpty) {
      _countryCode = sessionCc;
    }

    final userUri =
        BaseStreamingProvider.buildUri(apiBaseUrl, '/users/$uid');
    final userJson = await http.requestJson(
      method: 'GET',
      uri: userUri,
      headers: _authHeaders,
      cancel: cancel,
    );

    if (sessionCc.isEmpty) {
      final userCc =
          userJson['countryCode']?.toString().trim().toUpperCase() ?? '';
      _countryCode = userCc.isNotEmpty ? userCc : 'US';
    }

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

  Future<void> _exchangeRefreshToken(
    String refreshToken, {
    CancellationToken? cancel,
  }) async {
    final tokenUri =
        BaseStreamingProvider.buildUri(tokenBaseUrl, '/v1/oauth2/token');
    final res = await http.requestJson(
      method: 'POST',
      uri: tokenUri,
      formBody: BaseStreamingProvider.encodeForm(<String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        if (_clientId != null && _clientId!.isNotEmpty) 'client_id': _clientId!,
        if (_clientSecret != null && _clientSecret!.isNotEmpty)
          'client_secret': _clientSecret!,
      }),
      cancel: cancel,
    );
    _applyTokenResponse(res);
  }

  @override
  Future<void> refreshSessionIfNeeded({bool force = false}) {
    final existing = _inFlightRefresh;
    if (existing != null) return existing;

    if (!force) {
      final exp = _expiresAt;
      if (exp == null) return Future<void>.value();
      if (clock().isBefore(exp.subtract(const Duration(seconds: 60)))) {
        return Future<void>.value();
      }
    }

    final future = _doRefreshSession();
    _inFlightRefresh = future;
    return future.whenComplete(() {
      if (identical(_inFlightRefresh, future)) {
        _inFlightRefresh = null;
      }
    });
  }

  Future<void> _doRefreshSession() async {
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
      await _exchangeRefreshToken(refresh);
      if ((authState == StreamingAuthState.connected ||
              authState == StreamingAuthState.authRequired) &&
          accountInfo != null) {
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
    _clientId = null;
    _clientSecret = null;
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _userId = null;
    _countryCode = 'US';
    _recentRecAlbumIds.clear();
    _recentRecTrackIds.clear();
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

  static String _stripTidalPrefix(String raw) {
    var clean = BaseStreamingProvider.stripTrackPrefix(
      raw.trim(),
      'streaming:tidal',
    );
    clean = BaseStreamingProvider.stripTrackPrefix(clean, 'tidal');
    return clean.trim();
  }

  static List<String> _dedupeSeedIds(Iterable<String> rawIds) {
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

  static void _rememberRecentIds(
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

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final albums = <StreamingAlbum>[];
    final tracks = <TrackInfo>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};

    void mergeExtracted(
      ({List<StreamingAlbum> albums, List<TrackInfo> tracks, List<String> mixIds}) ext,
    ) {
      for (final a in ext.albums) {
        if (seenAlbumIds.add(a.id)) albums.add(a);
      }
      for (final t in ext.tracks) {
        if (seenTrackIds.add(t.id)) tracks.add(t);
      }
    }

    Future<void> fetchFeedOrPage(
      String path, {
      Map<String, String> query = const <String, String>{},
      bool v2 = false,
      bool albumsOnly = false,
      bool tracksOnly = false,
      List<String>? collectedMixIds,
    }) async {
      final json = await _tryTidalGet(
        path,
        <String, String>{'countryCode': _countryCode, ...query},
        forceRefresh: forceRefresh,
        v2: v2,
        cancel: cancel,
      );
      if (json == null) return;
      final items = json['items'];
      if (albumsOnly && items is List && items.isNotEmpty) {
        for (final a in _parseAlbumList(items)) {
          if (seenAlbumIds.add(a.id)) albums.add(a);
        }
        return;
      }
      if (tracksOnly && items is List && items.isNotEmpty) {
        for (final t in _parseTrackList(items)) {
          if (seenTrackIds.add(t.id)) tracks.add(t);
        }
        return;
      }
      final ext = _extractHomeRecommendations(json);
      mergeExtracted(ext);
      if (collectedMixIds != null) {
        for (final id in ext.mixIds) {
          if (!collectedMixIds.contains(id)) {
            collectedMixIds.add(id);
          }
        }
      }
    }

    final uid = _userId;

    if (!forceRefresh && batchIndex == 0) {
      final mixIds = <String>[];
      await fetchFeedOrPage(
        '/home/feed/static',
        v2: true,
        query: const <String, String>{
          'deviceType': 'BROWSER',
          'locale': 'en_US',
          'platform': 'WEB',
        },
        collectedMixIds: mixIds,
      );
      if (tracks.length < 4 && mixIds.isNotEmpty) {
        await fetchFeedOrPage(
          '/mixes/${mixIds.first}/items',
          query: const <String, String>{'limit': '20'},
        );
      }
      if (albums.isEmpty || tracks.isEmpty) {
        await fetchFeedOrPage(
          '/pages/home',
          query: const <String, String>{'deviceType': 'BROWSER'},
        );
      }
      if (albums.length < 4) {
        await fetchFeedOrPage(
          '/pages/explore',
          query: const <String, String>{'deviceType': 'BROWSER'},
        );
        await fetchFeedOrPage(
          '/featured/recommended/albums',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
        await fetchFeedOrPage(
          '/featured/new/albums',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
      }
      if (tracks.length < 4) {
        await fetchFeedOrPage(
          '/featured/top/tracks',
          query: const <String, String>{'limit': '20'},
          tracksOnly: true,
        );
      }
      if (uid != null && uid.isNotEmpty) {
        if (albums.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/albums',
            query: const <String, String>{'limit': '20'},
            albumsOnly: true,
          );
        }
        if (tracks.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/tracks',
            query: const <String, String>{'limit': '20'},
            tracksOnly: true,
          );
        }
      }
    } else {
      final cycleOffset = (batchIndex ~/ 4) * 15;
      final offsetQuery = cycleOffset > 0
          ? <String, String>{'offset': '$cycleOffset'}
          : const <String, String>{};
      switch (batchIndex % 4) {
        case 1:
          await fetchFeedOrPage(
            '/pages/explore_new_music',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/new/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          await fetchFeedOrPage(
            '/featured/top/tracks',
            query: <String, String>{'limit': '20', ...offsetQuery},
            tracksOnly: true,
          );
          break;
        case 2:
          await fetchFeedOrPage(
            '/featured/recommended/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          await fetchFeedOrPage(
            '/pages/explore_top_music',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/top/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          break;
        case 3:
          await fetchFeedOrPage(
            '/pages/explore',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/top/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          await fetchFeedOrPage(
            '/featured/new/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          break;
        default:
          await fetchFeedOrPage(
            '/home/feed/static',
            v2: true,
            query: const <String, String>{
              'deviceType': 'BROWSER',
              'locale': 'en_US',
              'platform': 'WEB',
            },
          );
          await fetchFeedOrPage(
            '/pages/home',
            query: <String, String>{'deviceType': 'BROWSER', ...offsetQuery},
          );
          await fetchFeedOrPage(
            '/featured/recommended/albums',
            query: <String, String>{'limit': '20', ...offsetQuery},
            albumsOnly: true,
          );
          break;
      }

      final albumSeeds = _dedupeSeedIds(<String>[
        ...excludeAlbumIds,
        ..._recentRecAlbumIds,
        ...albums.map((a) => a.id),
        ...catalog.albums.map((a) => a.id),
      ]);
      if (albumSeeds.isNotEmpty) {
        final idx = batchIndex > 0 ? (batchIndex - 1) % albumSeeds.length : 0;
        final seedAlbumId = albumSeeds[idx];
        await fetchFeedOrPage(
          '/albums/$seedAlbumId/similar',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
      }

      final trackSeeds = _dedupeSeedIds(<String>[
        ...excludeTrackIds,
        ..._recentRecTrackIds,
        ...tracks.map((t) => t.id),
        ...catalog.tracks.map((t) => t.id),
      ]);
      if (trackSeeds.isNotEmpty) {
        final idx = batchIndex > 0 ? (batchIndex - 1) % trackSeeds.length : 0;
        final seedTrackId = trackSeeds[idx];
        await fetchFeedOrPage(
          '/tracks/$seedTrackId/radio',
          query: const <String, String>{'limit': '20'},
          tracksOnly: true,
        );
      }

      if (albums.isEmpty || tracks.isEmpty) {
        await fetchFeedOrPage(
          '/pages/home',
          query: const <String, String>{'deviceType': 'BROWSER'},
        );
      }
      if (albums.isEmpty) {
        await fetchFeedOrPage(
          '/featured/recommended/albums',
          query: const <String, String>{'limit': '20'},
          albumsOnly: true,
        );
      }
      if (tracks.isEmpty) {
        await fetchFeedOrPage(
          '/featured/top/tracks',
          query: const <String, String>{'limit': '20'},
          tracksOnly: true,
        );
      }
      if (uid != null && uid.isNotEmpty) {
        final favOffset = batchIndex > 0 ? (batchIndex * 10) % 40 : 0;
        if (albums.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/albums',
            query: <String, String>{
              'limit': '20',
              if (favOffset > 0) 'offset': '$favOffset',
            },
            albumsOnly: true,
          );
        }
        if (tracks.isEmpty) {
          await fetchFeedOrPage(
            '/users/$uid/favorites/tracks',
            query: <String, String>{
              'limit': '20',
              if (favOffset > 0) 'offset': '$favOffset',
            },
            tracksOnly: true,
          );
        }
      }
    }

    final selectedAlbums = BaseStreamingProvider.selectFreshBatch<StreamingAlbum>(
      albums,
      idOf: (a) => a.id,
      excludeIds: excludeAlbumIds,
      batchIndex: batchIndex,
      maxCount: 16,
    );
    final selectedTracks = BaseStreamingProvider.selectFreshBatch<TrackInfo>(
      tracks,
      idOf: (t) => t.id,
      excludeIds: excludeTrackIds,
      batchIndex: batchIndex,
      maxCount: 16,
    );

    _rememberRecentIds(_recentRecAlbumIds, selectedAlbums.map((a) => a.id));
    _rememberRecentIds(_recentRecTrackIds, selectedTracks.map((t) => t.id));

    return StreamingRecommendations(
      providerKind: kind,
      albums: selectedAlbums,
      tracks: selectedTracks,
      fetchedAt: clock(),
    );
  }

  static bool _isExcludedRecommendationType(String upperType) {
    if (upperType.isEmpty) return false;
    for (final excluded in const <String>[
      'ARTIST',
      'VIDEO',
      'PLAYLIST',
      'MIX',
      'LINK',
      'HEADER',
    ]) {
      if (upperType == excluded ||
          upperType == '${excluded}_LIST' ||
          upperType == '${excluded}S') {
        return true;
      }
    }
    return false;
  }

  ({List<StreamingAlbum> albums, List<TrackInfo> tracks, List<String> mixIds})
      _extractHomeRecommendations(Map<String, dynamic> root) {
    final rawAlbums = <Map<String, dynamic>>[];
    final rawTracks = <Map<String, dynamic>>[];
    final mixIds = <String>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};
    final seenMixIds = <String>{};

    void considerItem(
      Map<String, dynamic> rawMap, {
      String? hintType,
      String? parentCover,
      String? parentAlbumTitle,
    }) {
      final wrapperType = rawMap['type']?.toString().trim().toUpperCase() ?? '';
      final map = rawMap['data'] is Map
          ? Map<String, dynamic>.from(rawMap['data'] as Map)
          : (rawMap['item'] is Map
                ? Map<String, dynamic>.from(rawMap['item'] as Map)
                : rawMap);
      final mapType = map['type']?.toString().trim().toUpperCase() ?? '';
      final explicitType = mapType.isNotEmpty ? mapType : wrapperType;
      final upperHint = explicitType.isNotEmpty
          ? explicitType
          : (hintType?.trim().toUpperCase() ?? '');

      if (explicitType == 'MIX' ||
          (explicitType.isEmpty &&
              (upperHint == 'MIX' || upperHint == 'MIX_LIST'))) {
        final mixId = map['id']?.toString().trim() ?? '';
        if (mixId.isNotEmpty && seenMixIds.add(mixId)) {
          mixIds.add(mixId);
        }
        return;
      }
      if (_isExcludedRecommendationType(explicitType) ||
          (explicitType.isEmpty && _isExcludedRecommendationType(upperHint))) {
        return;
      }

      final id = map['id']?.toString().trim() ?? '';
      if (id.isEmpty || map['uuid'] != null) return;
      if (map['items'] is List ||
          map['modules'] is List ||
          map['rows'] is List ||
          map['pagedList'] is Map) {
        return;
      }
      if (map['title'] == null) return;

      final isAlbum = upperHint.contains('ALBUM') ||
          map['numberOfTracks'] != null ||
          map['releaseDate'] != null ||
          map['upc'] != null;
      final isTrack = !isAlbum &&
          (upperHint.contains('TRACK') ||
              map['album'] is Map ||
              map['trackNumber'] != null ||
              map['duration'] != null);

      if (isTrack) {
        if (seenTrackIds.add(id)) {
          final enriched = Map<String, dynamic>.from(map);
          if (_extractTidalCoverFromMap(enriched) == null) {
            final fallbackCover =
                _extractTidalCoverFromMap(rawMap) ?? parentCover;
            if (fallbackCover != null) {
              enriched['cover'] = fallbackCover;
            }
          }
          if (parentAlbumTitle != null &&
              parentAlbumTitle.isNotEmpty &&
              enriched['album'] == null) {
            enriched['album'] = <String, dynamic>{'title': parentAlbumTitle};
          }
          rawTracks.add(enriched);
        }
      } else if (isAlbum) {
        if (seenAlbumIds.add(id)) {
          final enriched = Map<String, dynamic>.from(map);
          if (_extractTidalCoverFromMap(enriched) == null) {
            final fallbackCover =
                _extractTidalCoverFromMap(rawMap) ?? parentCover;
            if (fallbackCover != null) {
              enriched['cover'] = fallbackCover;
            }
          }
          rawAlbums.add(enriched);
        }
      }
    }

    void walk(
      dynamic node, {
      String? hintType,
      String? parentCover,
      String? parentAlbumTitle,
    }) {
      if (node is Map) {
        final map = Map<String, dynamic>.from(node);
        final nextHint = map['type']?.toString() ?? hintType;
        final nodeCover = _extractTidalCoverFromMap(map) ?? parentCover;
        final isContainer = map['items'] is List ||
            map['modules'] is List ||
            map['rows'] is List ||
            map['pagedList'] is Map;
        final nextHintUpper = (nextHint ?? '').trim().toUpperCase();
        final nodeAlbumTitle = (!isContainer &&
                (map['numberOfTracks'] != null ||
                    nextHintUpper.contains('ALBUM')))
            ? (map['title']?.toString() ?? parentAlbumTitle)
            : parentAlbumTitle;

        if (map['albums'] is List) {
          for (final item in map['albums'] as List) {
            if (item is Map) {
              considerItem(
                Map<String, dynamic>.from(item),
                hintType: 'ALBUM',
                parentCover: nodeCover,
                parentAlbumTitle: nodeAlbumTitle,
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
                parentCover: nodeCover,
                parentAlbumTitle: nodeAlbumTitle,
              );
            }
          }
        }

        final innerCandidate = map['data'] is Map
            ? map['data'] as Map
            : (map['item'] is Map ? map['item'] as Map : null);
        final hasDirectItem = map['id'] != null && map['title'] != null;
        final hasWrappedItem = innerCandidate != null &&
            innerCandidate['id'] != null &&
            innerCandidate['title'] != null &&
            innerCandidate['items'] is! List &&
            innerCandidate['modules'] is! List &&
            innerCandidate['rows'] is! List &&
            innerCandidate['pagedList'] is! Map;

        if (!isContainer && (hasDirectItem || hasWrappedItem)) {
          considerItem(
            map,
            hintType: nextHint,
            parentCover: parentCover,
            parentAlbumTitle: parentAlbumTitle,
          );
          if (map['tracks'] == null &&
              map['items'] == null &&
              (innerCandidate == null ||
                  (innerCandidate['tracks'] == null &&
                      innerCandidate['items'] == null))) {
            return;
          }
        }

        for (final entry in map.entries) {
          if (entry.key == 'albums' || entry.key == 'tracks') continue;
          walk(
            entry.value,
            hintType: nextHint,
            parentCover: nodeCover,
            parentAlbumTitle: nodeAlbumTitle,
          );
        }
      } else if (node is List) {
        for (final item in node) {
          walk(
            item,
            hintType: hintType,
            parentCover: parentCover,
            parentAlbumTitle: parentAlbumTitle,
          );
        }
      }
    }

    walk(root);
    final parsedAlbums = _parseAlbumList(rawAlbums);
    final coverByAlbumId = <String, String>{};
    for (final a in parsedAlbums) {
      if (a.coverUrl != null && a.coverUrl!.isNotEmpty) {
        coverByAlbumId[a.id] = a.coverUrl!;
      }
    }
    if (coverByAlbumId.isNotEmpty) {
      for (final tMap in rawTracks) {
        final albumObj = tMap['album'];
        if (albumObj is Map) {
          final albId = albumObj['id']?.toString();
          final existing = _extractTidalCoverFromMap(tMap);
          if (existing == null &&
              albId != null &&
              coverByAlbumId.containsKey(albId)) {
            tMap['cover'] = coverByAlbumId[albId];
          }
        }
      }
    }
    return (
      albums: parsedAlbums,
      tracks: _parseTrackList(rawTracks),
      mixIds: mixIds,
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
  Future<StreamingCatalog> search(
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

  /// Checks whether a Tidal DASH MPD manifest contains any `<ContentProtection`
  /// element indicating Widevine/PlayReady/CENC DRM protection.
  static bool isDashMpdDrmProtected(String mpdXml) {
    return RegExp(
      r'<(?:[A-Za-z0-9_.-]+:)?ContentProtection\b',
      caseSensitive: false,
    ).hasMatch(mpdXml);
  }

  static bool _hasDashMediaSegments(String mpdXml) {
    final hasMpd = RegExp(
      r'<(?:[A-Za-z0-9_.-]+:)?MPD\b',
      caseSensitive: false,
    ).hasMatch(mpdXml);
    if (!hasMpd) return false;
    return RegExp(
      r'<(?:[A-Za-z0-9_.-]+:)?(?:SegmentTemplate|SegmentList|SegmentBase|BaseURL)\b',
      caseSensitive: false,
    ).hasMatch(mpdXml);
  }

  static String _decodeBase64Utf8(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'\s+'), '');
    return utf8.decode(base64Decode(base64.normalize(cleaned)));
  }

  static String _maxQualityForQualityKey(String qualityKey) {
    final normalized = qualityKey.trim().toUpperCase();
    return switch (normalized) {
      '' || 'DEFAULT' => 'HI_RES_LOSSLESS',
      'HI_RES_LOSSLESS' || 'LOSSLESS' || 'HIGH' || 'LOW' => normalized,
      'HI_RES' => 'HI_RES_LOSSLESS',
      'CD' => 'LOSSLESS',
      _ => normalized,
    };
  }

  Future<T> _resolveTiers<T>({
    required String rawTrackId,
    required String maxQuality,
    required Future<T?> Function({
      required String tier,
      required String mpdXml,
      required bool isFlac,
      required String audioQuality,
      required int sampleRate,
      required int bitDepth,
      NormalizedLoudness? loudness,
      NormalizedLoudness? albumLoudness,
    }) onDashManifest,
    required Future<T?> Function({
      required String tier,
      required String streamUrl,
      required String manifestMime,
      required bool isFlac,
      required String audioQuality,
      required int sampleRate,
      required int bitDepth,
      NormalizedLoudness? loudness,
      NormalizedLoudness? albumLoudness,
    }) onBtsStream,
    required void Function(String tier, String message) onTierFailed,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    await refreshSessionIfNeeded();
    cancel?.throwIfCancelled();

    final trackId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'tidal');
    const qualityChain = <String>['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH'];
    final normalizedMax = maxQuality.trim().toUpperCase();
    final startIndex = qualityChain.indexOf(normalizedMax);
    final tiers =
        startIndex >= 0 ? qualityChain.sublist(startIndex) : qualityChain;

    String? lastError;
    int? lastStatusCode;
    var sawDrm = false;
    var retriedAuth = false;

    void failTier(String tier, String message, {int? statusCode}) {
      lastError = message;
      if (statusCode != null) {
        lastStatusCode = statusCode;
      }
      onTierFailed(tier, message);
      debugPrint(
        '[Tidal Play] track=$trackId tier=$tier failed ($message); trying next tier',
      );
    }

    for (final tier in tiers) {
      cancel?.throwIfCancelled();

      final uri = BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/tracks/$trackId/playbackinfopostpaywall',
        <String, String>{
          'audioquality': tier,
          'playbackmode': 'STREAM',
          'assetpresentation': 'FULL',
          'countryCode': _countryCode,
        },
      );

      late final Map<String, dynamic> json;
      try {
        json = await http.requestJson(
          method: 'GET',
          uri: uri,
          headers: _authHeaders,
          cancel: cancel,
          timeout: timeout,
        );
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == null) {
          rethrow;
        }
        if (e.isTokenExpired || e.statusCode == 401) {
          if (!retriedAuth && supportsSilentRefresh) {
            retriedAuth = true;
            await refreshSessionIfNeeded(force: true);
            cancel?.throwIfCancelled();
            json = await http.requestJson(
              method: 'GET',
              uri: uri,
              headers: _authHeaders,
              cancel: cancel,
              timeout: timeout,
            );
          } else {
            rethrow;
          }
        } else {
          failTier(tier, e.message, statusCode: e.statusCode);
          continue;
        }
      }

      final trackGain = (json['trackReplayGain'] as num?)?.toDouble();
      final trackPeak = (json['trackPeakAmplitude'] as num?)?.toDouble();
      final albumGain = (json['albumReplayGain'] as num?)?.toDouble();
      final albumPeak = (json['albumPeakAmplitude'] as num?)?.toDouble();
      final loudness = trackGain != null
          ? NormalizedLoudness.fromReplayGain(trackGain, peak: trackPeak)
          : null;
      final albumLoudness = albumGain != null
          ? NormalizedLoudness.fromReplayGain(albumGain, peak: albumPeak)
          : null;

      final mimeType =
          json['manifestMimeType']?.toString().trim().toLowerCase() ?? '';
      final manifestB64 = json['manifest']?.toString().trim() ?? '';
      final rawAudioQuality =
          json['audioQuality']?.toString().trim().toUpperCase() ?? '';
      final audioQuality = rawAudioQuality.isNotEmpty ? rawAudioQuality : tier;

      if (manifestB64.isEmpty) {
        if (mimeType.contains('drm')) sawDrm = true;
        failTier(tier, 'Tidal 串流清單為空（$tier）');
        continue;
      }

      if (mimeType == 'application/dash+xml') {
        final String mpdXml;
        try {
          mpdXml = _decodeBase64Utf8(manifestB64);
        } catch (e) {
          failTier(tier, '解析 Tidal DASH manifest 失敗：$e');
          continue;
        }

        if (isDashMpdDrmProtected(mpdXml)) {
          sawDrm = true;
          failTier(tier, 'Tidal 此曲目使用受保護的 DASH DRM 封裝格式（$tier）');
          continue;
        }
        if (!_hasDashMediaSegments(mpdXml)) {
          failTier(tier, 'Tidal DASH MPD 缺少有效的媒體片段資訊（$tier）');
          continue;
        }

        final codecsMatch = RegExp(
          r'''codecs\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(mpdXml);
        final mpdCodecs = codecsMatch?.group(1)?.trim().toLowerCase() ?? '';

        final sampleRateMatch = RegExp(
          r'''audioSamplingRate\s*=\s*["'](\d+)["']''',
          caseSensitive: false,
        ).firstMatch(mpdXml);
        final mpdSampleRate =
            int.tryParse(sampleRateMatch?.group(1) ?? '');

        final isFlac = mpdCodecs.contains('flac') ||
            (!mpdCodecs.contains('mp4a') &&
                !mpdCodecs.contains('aac') &&
                (audioQuality.contains('LOSSLESS') ||
                    audioQuality.contains('HI_RES')));
        final jsonSr = (json['sampleRate'] as num?)?.toInt();
        final sampleRate = (jsonSr != null && jsonSr > 0)
            ? jsonSr
            : ((mpdSampleRate != null && mpdSampleRate > 0)
                  ? mpdSampleRate
                  : (audioQuality.contains('HI_RES') ? 96000 : 44100));
        final jsonBd = (json['bitDepth'] as num?)?.toInt();
        final bitDepth = (jsonBd != null && jsonBd > 0)
            ? jsonBd
            : (audioQuality.contains('HI_RES') ? 24 : 16);

        final handled = await onDashManifest(
          tier: tier,
          mpdXml: mpdXml,
          isFlac: isFlac,
          audioQuality: audioQuality,
          sampleRate: sampleRate,
          bitDepth: bitDepth,
          loudness: loudness,
          albumLoudness: albumLoudness,
        );
        if (handled != null) return handled;
        lastError ??= 'Tidal DASH 解析失敗（$tier）';
        continue;
      }

      if (mimeType == 'application/vnd.tidal.bts') {
        final Map<String, dynamic> decodedManifest;
        try {
          final rawManifest = _decodeBase64Utf8(manifestB64);
          final parsed = jsonDecode(rawManifest);
          if (parsed is Map<String, dynamic>) {
            decodedManifest = parsed;
          } else if (parsed is Map) {
            decodedManifest = Map<String, dynamic>.from(parsed);
          } else {
            throw const FormatException('Manifest is not a JSON object');
          }
        } catch (e) {
          failTier(tier, '解析 Tidal Base64 manifest 失敗：$e');
          continue;
        }

        final encType =
            decodedManifest['encryptionType']?.toString().trim() ?? '';
        if (encType.isNotEmpty && encType.toUpperCase() != 'NONE') {
          sawDrm = true;
          failTier(
            tier,
            'Tidal 音訊串流受加密保護（$encType），拒絕輸出加密雜訊至 DAC',
          );
          continue;
        }

        final urls = decodedManifest['urls'];
        final streamUrl = (urls is List && urls.isNotEmpty)
            ? urls.first?.toString().trim() ?? ''
            : '';
        if (streamUrl.isEmpty) {
          failTier(tier, 'Tidal manifest 未包含任何可用的串流 URL（$tier）');
          continue;
        }

        final manifestMime =
            decodedManifest['mimeType']?.toString().toLowerCase() ?? '';
        final codecs =
            decodedManifest['codecs']?.toString().toLowerCase() ?? '';
        final isFlac = manifestMime.contains('flac') || codecs.contains('flac');

        final bitDepth = (decodedManifest['bitDepth'] as num?)?.toInt() ??
            (json['bitDepth'] as num?)?.toInt() ??
            (audioQuality.contains('HI_RES') ? 24 : 16);
        final sampleRate = (decodedManifest['sampleRate'] as num?)?.toInt() ??
            (json['sampleRate'] as num?)?.toInt() ??
            (audioQuality.contains('HI_RES') ? 96000 : 44100);

        final handled = await onBtsStream(
          tier: tier,
          streamUrl: streamUrl,
          manifestMime: manifestMime,
          isFlac: isFlac,
          audioQuality: audioQuality,
          sampleRate: sampleRate,
          bitDepth: bitDepth,
          loudness: loudness,
          albumLoudness: albumLoudness,
        );
        if (handled != null) return handled;
        continue;
      }

      if (mimeType.contains('drm')) {
        sawDrm = true;
      }
      failTier(tier, '不支援的 Tidal 串流清單格式：$mimeType');
    }

    throw StreamingException(
      lastError ?? 'Tidal 此曲目所有音質層級皆受保護或無法播放',
      statusCode: lastStatusCode,
      isDrmRestricted: sawDrm,
    );
  }

  /// Extracts a Unix epoch expiry timestamp (seconds) from signed CDN URLs
  /// (e.g. CloudFront `Expires`, Akamai `exp`, or generic `expire` query params).
  @visibleForTesting
  static int? extractUrlExpireAt(String rawUrl) {
    final cleaned = rawUrl.trim().replaceAll('&amp;', '&');
    if (cleaned.isEmpty) return null;
    final uri = Uri.tryParse(cleaned);
    if (uri == null || uri.queryParameters.isEmpty) return null;

    for (final entry in uri.queryParameters.entries) {
      final keyLower = entry.key.trim().toLowerCase();
      if (keyLower == 'expires' || keyLower == 'expire' || keyLower == 'exp') {
        final parsed = int.tryParse(entry.value.trim());
        if (parsed == null) continue;
        if (parsed >= 1000000000000) {
          return parsed ~/ 1000;
        }
        if (parsed >= 1000000000) {
          return parsed;
        }
      }
    }
    return null;
  }

  /// Extracts the earliest signed CDN expiry timestamp (Unix seconds) embedded
  /// in `<BaseURL>`, `initialization="..."`, or `media="..."` URLs of a Tidal
  /// DASH MPD XML manifest.
  @visibleForTesting
  static int? extractDashMpdExpireAt(String mpdXml) {
    if (mpdXml.trim().isEmpty) return null;
    int? earliest;

    void inspectCandidate(String raw) {
      final exp = extractUrlExpireAt(raw);
      if (exp == null) return;
      if (earliest == null || exp < earliest!) {
        earliest = exp;
      }
    }

    final baseUrlRe = RegExp(
      r'<BaseURL[^>]*>([^<]+)</BaseURL>',
      caseSensitive: false,
    );
    for (final m in baseUrlRe.allMatches(mpdXml)) {
      final val = m.group(1);
      if (val != null) inspectCandidate(val);
    }

    final attrRe = RegExp(
      r'''(?:initialization|media)\s*=\s*(?:"([^"]+)"|'([^']+)')''',
      caseSensitive: false,
    );
    for (final m in attrRe.allMatches(mpdXml)) {
      final val = m.group(1) ?? m.group(2);
      if (val != null) inspectCandidate(val);
    }

    if (earliest == null) {
      final urlRe = RegExp(r'''https?://[^\s"'<>]+''');
      for (final m in urlRe.allMatches(mpdXml)) {
        final val = m.group(0);
        if (val != null) inspectCandidate(val);
      }
    }

    return earliest;
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    return _resolveTiers<StreamSourceSpec>(
      rawTrackId: key.trackId,
      maxQuality: _maxQualityForQualityKey(key.qualityKey),
      cancel: cancelToken,
      onTierFailed: (_, _) {},
      onDashManifest: ({
        required tier,
        required mpdXml,
        required isFlac,
        required audioQuality,
        required sampleRate,
        required bitDepth,
        loudness,
        albumLoudness,
      }) async {
        // Direct MPD XML handoff to Rust native DASH streaming (zero FfmpegAudioProxy).
        return SegmentedManifestSpec(
          key: key,
          manifestUrlOrXml: mpdXml,
          format: ManifestFormat.dash,
          mimeType: isFlac ? 'audio/flac' : 'audio/mp4',
          expireAt: extractDashMpdExpireAt(mpdXml),
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: AudioFormat(
            codec: isFlac ? AudioCodec.flac : AudioCodec.aac,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
          ),
        );
      },
      onBtsStream: ({
        required tier,
        required streamUrl,
        required manifestMime,
        required isFlac,
        required audioQuality,
        required sampleRate,
        required bitDepth,
        loudness,
        albumLoudness,
      }) async {
        return DirectRangeSpec(
          key: key,
          url: streamUrl,
          mimeType: manifestMime.isNotEmpty
              ? manifestMime
              : (isFlac ? 'audio/flac' : 'audio/mp4'),
          hintExtension: isFlac ? 'flac' : 'm4a',
          expireAt: extractUrlExpireAt(streamUrl),
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: AudioFormat(
            codec: isFlac ? AudioCodec.flac : AudioCodec.aac,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
          ),
        );
      },
    );
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    String maxQuality = 'HI_RES_LOSSLESS',
  }) async {
    final trackId = BaseStreamingProvider.stripTrackPrefix(track.id, 'tidal');
    return _resolveTiers<ResolvedStreamResult>(
      rawTrackId: track.id,
      maxQuality: maxQuality,
      cancel: cancel,
      timeout: timeout,
      onTierFailed: (_, _) {},
      onDashManifest: ({
        required tier,
        required mpdXml,
        required isFlac,
        required audioQuality,
        required sampleRate,
        required bitDepth,
        loudness,
        albumLoudness,
      }) async {
        final String proxyUrl;
        try {
          final ytDlp = _ytDlpService ?? YtDlpService.instance;
          proxyUrl = await ytDlp.openDashMpdUrl(
            mpdXml: mpdXml,
            playRequestId: playRequestId ?? (--_fallbackRequestCounter),
            copyFlac: isFlac,
          );
        } catch (e) {
          if (e is StreamingException && e.isCancelled) rethrow;
          if (e is YtDlpException && e.isCancelled) {
            throw const StreamingException('操作已取消', isCancelled: true);
          }
          final msg = e is YtDlpException ? e.message : e.toString();
          debugPrint(
            '[Tidal Play] track=$trackId tier=$tier failed ($msg); trying next tier',
          );
          return null;
        }
        cancel?.throwIfCancelled();

        final engineRoute = isFlac
            ? 'Tidal DASH FLAC ($audioQuality, ffmpeg remux)'
            : 'Tidal DASH PCM ($audioQuality, ffmpeg)';
        debugPrint(
          '[Tidal Play] track=$trackId requested=$tier actual=$audioQuality mime=application/dash+xml codec=${isFlac ? 'FLAC' : 'AAC'} ${sampleRate}Hz/${bitDepth}bit route=$engineRoute',
        );

        return ResolvedStreamResult(
          url: proxyUrl,
          hintExtension: isFlac ? 'flac' : 'wav',
          format: AudioFormat(
            codec: isFlac ? AudioCodec.flac : AudioCodec.aac,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
          ),
          engineRoute: engineRoute,
        );
      },
      onBtsStream: ({
        required tier,
        required streamUrl,
        required manifestMime,
        required isFlac,
        required audioQuality,
        required sampleRate,
        required bitDepth,
        loudness,
        albumLoudness,
      }) async {
        final codec = isFlac ? AudioCodec.flac : AudioCodec.aac;
        final engineRoute = isFlac
            ? 'Tidal Direct FLAC ($audioQuality)'
            : 'Tidal Direct AAC ($audioQuality)';
        debugPrint(
          '[Tidal Play] track=$trackId requested=$tier actual=$audioQuality mime=application/vnd.tidal.bts codec=${isFlac ? 'FLAC' : 'AAC'} ${sampleRate}Hz/${bitDepth}bit route=$engineRoute',
        );

        return ResolvedStreamResult(
          url: streamUrl,
          hintExtension: isFlac ? 'flac' : 'm4a',
          format: AudioFormat(
            codec: codec,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
          ),
          engineRoute: engineRoute,
        );
      },
    );
  }

  List<TrackInfo> _parseTrackList(
    dynamic rawItems, {
    String? fallbackCoverUrl,
    String? fallbackAlbumTitle,
  }) {
    if (rawItems is! List) return const [];
    final normalizedFallbackCover = _tidalCoverUrl(fallbackCoverUrl);
    final tracks = <TrackInfo>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final wrapperType = entry['type']?.toString().trim().toUpperCase() ?? '';
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : (entry['data'] is Map
                ? Map<String, dynamic>.from(entry['data'] as Map)
                : Map<String, dynamic>.from(entry));
      final itemType = map['type']?.toString().trim().toUpperCase() ?? '';
      final effectiveType = itemType.isNotEmpty ? itemType : wrapperType;
      if (_isExcludedRecommendationType(effectiveType)) continue;

      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final artistObj = map['artist'] is Map
          ? map['artist'] as Map
          : (map['artists'] is List && (map['artists'] as List).isNotEmpty
                ? (map['artists'] as List).first as Map?
                : null);
      final albumObj = map['album'] is Map
          ? Map<String, dynamic>.from(map['album'] as Map)
          : null;
      final coverUrl = (albumObj != null
              ? _extractTidalCoverFromMap(albumObj)
              : null) ??
          _extractTidalCoverFromMap(map) ??
          normalizedFallbackCover;
      final rawAlbTitle = albumObj?['title']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Tidal');
      final durationSec = (map['duration'] as num?)?.toInt() ?? 0;
      final quality = _resolveEffectiveTidalQuality(map);

      tracks.add(
        TrackInfo(
          id: 'tidal:$id',
          title: map['title']?.toString() ?? '未命名曲目',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          album: albumTitle,
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
      final wrapperType = entry['type']?.toString().trim().toUpperCase() ?? '';
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : (entry['data'] is Map
                ? Map<String, dynamic>.from(entry['data'] as Map)
                : Map<String, dynamic>.from(entry));
      final itemType = map['type']?.toString().trim().toUpperCase() ?? '';
      final effectiveType = itemType.isNotEmpty ? itemType : wrapperType;
      if (_isExcludedRecommendationType(effectiveType)) continue;

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
      final effectiveQuality = _resolveEffectiveTidalQuality(map);

      albums.add(
        StreamingAlbum(
          id: id,
          title: map['title']?.toString() ?? '未命名專輯',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _extractTidalCoverFromMap(map),
          providerKind: kind,
          trackCount: (map['numberOfTracks'] as num?)?.toInt(),
          qualityLabel: effectiveQuality.isNotEmpty ? effectiveQuality : null,
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
          : (entry['data'] is Map
                ? Map<String, dynamic>.from(entry['data'] as Map)
                : Map<String, dynamic>.from(entry));
      final id = map['uuid']?.toString() ?? map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      playlists.add(
        StreamingPlaylist(
          id: id,
          title: map['title']?.toString() ?? '未命名歌單',
          description: map['description']?.toString(),
          trackCount: (map['numberOfTracks'] as num?)?.toInt() ?? 0,
          coverUrl: _extractTidalCoverFromValue(map['squareImage']) ??
              _extractTidalCoverFromValue(map['image']) ??
              _extractTidalCoverFromValue(map['images']),
          providerKind: kind,
        ),
      );
    }
    return playlists;
  }

  static String _resolveEffectiveTidalQuality(Map<String, dynamic> map) {
    final rawQuality =
        map['audioQuality']?.toString().trim().toUpperCase() ?? '';
    if (rawQuality == 'HI_RES_LOSSLESS' || rawQuality == 'HI_RES') {
      return rawQuality;
    }
    final mediaMeta = map['mediaMetadata'];
    if (mediaMeta is Map) {
      final tags = mediaMeta['tags'];
      if (tags is List) {
        var hasLossless = false;
        for (final tag in tags) {
          final upperTag = tag?.toString().trim().toUpperCase() ?? '';
          if (upperTag == 'HIRES_LOSSLESS' || upperTag == 'HI_RES_LOSSLESS') {
            return 'HI_RES_LOSSLESS';
          }
          if (upperTag == 'LOSSLESS') {
            hasLossless = true;
          }
        }
        if (rawQuality.isEmpty && hasLossless) {
          return 'LOSSLESS';
        }
      }
    }
    return rawQuality;
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

  static String? _extractTidalCoverFromMap(
    Map<dynamic, dynamic> map, {
    int size = 640,
  }) {
    for (final key in const <String>[
      'cover',
      'imageCover',
      'imageId',
      'squareImage',
      'image',
      'images',
    ]) {
      final candidate = _extractTidalCoverFromValue(map[key], size: size);
      if (candidate != null) return candidate;
    }
    final album = map['album'];
    if (album is Map) {
      return _extractTidalCoverFromMap(album, size: size);
    }
    return null;
  }

  static String? _extractTidalCoverFromValue(dynamic value, {int size = 640}) {
    if (value == null) return null;
    if (value is String) {
      return _tidalCoverUrl(value, size: size);
    }
    if (value is Map) {
      final directUrl = _tidalCoverUrl(value['url']?.toString(), size: size);
      if (directUrl != null) return directUrl;

      final preferredKeys = size >= 1000
          ? const <String>[
              '1280x1280',
              'EXTRALARGE',
              'XLARGE',
              'LARGE',
              'large',
              '640x640',
              'MEDIUM',
              'medium',
              'SMALL',
              'small',
              'default',
              'thumbnail',
            ]
          : const <String>[
              'LARGE',
              'large',
              '640x640',
              'EXTRALARGE',
              '1280x1280',
              'MEDIUM',
              'medium',
              '320x320',
              'SMALL',
              'small',
              'default',
              'thumbnail',
            ];
      for (final key in preferredKeys) {
        if (value.containsKey(key)) {
          final candidate =
              _extractTidalCoverFromValue(value[key], size: size);
          if (candidate != null) return candidate;
        }
      }
      for (final entryVal in value.values) {
        final candidate = _extractTidalCoverFromValue(entryVal, size: size);
        if (candidate != null) return candidate;
      }
      return null;
    }
    if (value is List) {
      String? bestUrl;
      var bestWidth = -1;
      for (final item in value) {
        String? candidateUrl;
        var width = 0;
        if (item is Map) {
          candidateUrl = _tidalCoverUrl(item['url']?.toString(), size: size);
          width = (item['width'] as num?)?.toInt() ?? 0;
        } else if (item is String) {
          candidateUrl = _tidalCoverUrl(item, size: size);
        }
        if (candidateUrl == null) continue;
        if (width <= 0) {
          bestUrl ??= candidateUrl;
          continue;
        }
        if (bestUrl == null ||
            bestWidth <= 0 ||
            (size >= 1000 && width > bestWidth) ||
            (size < 1000 &&
                ((bestWidth < size && width > bestWidth) ||
                    (width >= size &&
                        (bestWidth < size || width < bestWidth))))) {
          bestUrl = candidateUrl;
          bestWidth = width;
        }
      }
      return bestUrl;
    }
    return null;
  }

  static String? _tidalCoverUrl(String? rawCover, {int size = 640}) {
    if (rawCover == null) return null;
    final trimmed = rawCover.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('//')) {
      return BaseStreamingProvider.normalizeCoverUrl(trimmed);
    }
    if (!RegExp(r'^[A-Za-z0-9_/-]+$').hasMatch(trimmed)) {
      return null;
    }
    return BaseStreamingProvider.normalizeCoverUrl(
      'https://resources.tidal.com/images/${trimmed.replaceAll('-', '/')}/${size}x$size.jpg',
    );
  }
}
