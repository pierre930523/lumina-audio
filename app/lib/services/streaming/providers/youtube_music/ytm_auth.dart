part of '../youtube_music_provider.dart';

extension _YtmAuth on YouTubeMusicProvider {
  Future<void> _restoreFromStorageImpl() async {
    try {
      final stored = await readCredentialsJson();
      if (stored == null) {
        resetState();
        return;
      }

      _authMode = stored['mode']?.toString() ?? 'cookie';
      _cookie = stored['cookie']?.toString();
      _clientId = stored['client_id']?.toString();
      _clientSecret = stored['client_secret']?.toString();
      _accessToken = stored['access_token']?.toString();
      _refreshToken = stored['refresh_token']?.toString();
      final expRaw = stored['expires_at']?.toString();
      _expiresAt = expRaw != null ? DateTime.tryParse(expRaw) : null;

      await refreshSessionIfNeeded();
      final account = await _verifyAccountLive();
      setConnected(account);
      _residentResolver.invalidateSession();
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(e);
    }
  }

  Future<void> _authenticateImpl(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    setAuthenticating();
    try {
      cancel?.throwIfCancelled();

      final requestedMode = params['mode']?.toString().trim();
      final cookieVal =
          (params['cookie'] ?? params['auth_cookie'])?.toString().trim();

      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : (cookieVal != null && cookieVal.isNotEmpty
                ? 'cookie'
                : 'oauth_device');

      if (mode == 'cookie') {
        if (cookieVal == null || cookieVal.isEmpty) {
          throw const StreamingException('請輸入包含 SAPISID 的 YouTube Music Cookie');
        }
        final sapisid = _ytmExtractSapisidFromCookie(cookieVal);
        if (sapisid == null || sapisid.isEmpty) {
          throw const StreamingException(
            'Cookie 缺少 SAPISID 或 __Secure-3PAPISID，無法驗證 YouTube Music 身分',
            statusCode: 401,
          );
        }

        _authMode = 'cookie';
        _cookie = cookieVal;
        _accessToken = null;
        _refreshToken = null;
        _expiresAt = null;

        onProgress?.call('正在向 YouTube Music 驗證 Cookie 工作階段...');
        final account = await _verifyAccountLive(cancel: cancel);
        setConnected(account);
        _residentResolver.invalidateSession();
        clearStreamCache();
        await _persistCredentials(account);
        return;
      }

      if (mode == 'oauth_device') {
        final clientId = params['client_id']?.toString().trim() ?? '';
        final clientSecret = params['client_secret']?.toString().trim() ?? '';
        if (clientId.isEmpty) {
          throw const StreamingException(
            'Google OAuth 裝置授權需要提供 client_id',
          );
        }

        _authMode = 'oauth_device';
        _clientId = clientId;
        _clientSecret = clientSecret;
        _cookie = null;

        onProgress?.call('正在向 Google OAuth 請求裝置授權碼...');
        final deviceUri =
            BaseStreamingProvider.buildUri(oauthBaseUrl, '/device/code');
        final deviceResp = await http.requestJson(
          method: 'POST',
          uri: deviceUri,
          formBody: BaseStreamingProvider.encodeForm(<String, String>{
            'client_id': clientId,
            'scope': YouTubeMusicProvider._youtubeScope,
          }),
          cancel: cancel,
        );

        final deviceCode = deviceResp['device_code']?.toString() ?? '';
        final userCode = deviceResp['user_code']?.toString() ?? '';
        final verificationUrl =
            (deviceResp['verification_url'] ?? deviceResp['verification_uri'])
                ?.toString() ??
            'https://www.google.com/device';
        final expiresIn = (deviceResp['expires_in'] as num?)?.toInt() ?? 1800;
        final intervalSec = (deviceResp['interval'] as num?)?.toInt() ?? 5;

        if (deviceCode.isEmpty || userCode.isEmpty) {
          throw const StreamingException(
            'Google OAuth 未回傳有效的 device_code 或 user_code',
          );
        }

        onProgress?.call('請開啟 $verificationUrl 並輸入代碼：$userCode');
        try {
          await openSystemBrowser(verificationUrl, urlOpener: urlOpener);
        } catch (_) {
          // Non-fatal: user already received verification URL and code in progress callback.
        }

        final deadline = clock().add(Duration(seconds: expiresIn));
        var pollDelay = intervalSec <= 0
            ? const Duration(milliseconds: 25)
            : Duration(seconds: intervalSec);
        final tokenUri =
            BaseStreamingProvider.buildUri(oauthBaseUrl, '/token');

        while (true) {
          cancel?.throwIfCancelled();
          if (clock().isAfter(deadline)) {
            throw const StreamingException(
              'Google 裝置授權碼已過期，請重新登入',
              isTokenExpired: true,
            );
          }

          await BaseStreamingProvider.cancellableDelay(pollDelay, cancel);

          final tokenForm = <String, String>{
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            'device_code': deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          };
          final res = await http.sendJsonRaw(
            method: 'POST',
            uri: tokenUri,
            formBody: BaseStreamingProvider.encodeForm(tokenForm),
            cancel: cancel,
          );

          if (res.statusCode >= 200 && res.statusCode < 300) {
            final access = res.json['access_token']?.toString().trim() ?? '';
            if (access.isEmpty) {
              throw const StreamingException('Google OAuth 未回傳 access_token');
            }
            _accessToken = access;
            final refresh = res.json['refresh_token']?.toString().trim();
            if (refresh != null && refresh.isNotEmpty) {
              _refreshToken = refresh;
            }
            final expSec = (res.json['expires_in'] as num?)?.toInt() ?? 3600;
            _expiresAt = clock().add(Duration(seconds: expSec));
            break;
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

        onProgress?.call('正在驗證 YouTube Music 帳號資訊...');
        final account = await _verifyAccountLive(cancel: cancel);
        setConnected(account);
        _residentResolver.invalidateSession();
        clearStreamCache();
        await _persistCredentials(account);
        return;
      }

      throw StreamingException('不支援的 YouTube Music 驗證模式：$mode');
    } catch (e) {
      throw failWithError(e);
    }
  }

  Future<void> _refreshSessionIfNeededImpl({bool force = false}) {
    final existing = _inFlightRefresh;
    if (existing != null) return existing;

    if (_authMode != 'oauth_device') {
      if (force) {
        return Future<void>.error(
          const StreamingException(
            'YouTube Music Cookie 登入不支援靜默續期，請重新登入',
            statusCode: 401,
            isTokenExpired: true,
          ),
        );
      }
      return Future<void>.value();
    }

    if (!force) {
      final exp = _expiresAt;
      if (exp == null) return Future<void>.value();
      if (clock().isBefore(exp.subtract(const Duration(seconds: 60)))) {
        return Future<void>.value();
      }
    }

    final future = _doRefreshOAuthSession();
    _inFlightRefresh = future;
    return future.whenComplete(() {
      if (identical(_inFlightRefresh, future)) {
        _inFlightRefresh = null;
      }
    });
  }

  Future<void> _doRefreshOAuthSession() async {
    final refresh = _refreshToken;
    final clientId = _clientId;
    if (refresh == null ||
        refresh.isEmpty ||
        clientId == null ||
        clientId.isEmpty) {
      throw failWithError(
        const StreamingException(
          'YouTube Music OAuth 權杖已過期且無法自動續期',
          statusCode: 401,
          isTokenExpired: true,
        ),
      );
    }

    try {
      final tokenUri = BaseStreamingProvider.buildUri(oauthBaseUrl, '/token');
      final res = await http.requestJson(
        method: 'POST',
        uri: tokenUri,
        formBody: BaseStreamingProvider.encodeForm(<String, String>{
          'client_id': clientId,
          if (_clientSecret != null && _clientSecret!.isNotEmpty)
            'client_secret': _clientSecret!,
          'refresh_token': refresh,
          'grant_type': 'refresh_token',
        }),
      );

      final nextAccess = res['access_token']?.toString().trim() ?? '';
      if (nextAccess.isEmpty) {
        throw const StreamingException(
          'Google OAuth 權杖更新失敗：未回傳新的 access_token',
          statusCode: 401,
          isTokenExpired: true,
        );
      }
      _accessToken = nextAccess;
      _residentResolver.invalidateSession();
      final nextRefresh = res['refresh_token']?.toString().trim();
      if (nextRefresh != null && nextRefresh.isNotEmpty) {
        _refreshToken = nextRefresh;
      }
      final expSec = (res['expires_in'] as num?)?.toInt() ?? 3600;
      _expiresAt = clock().add(Duration(seconds: expSec));

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
                'YouTube Music OAuth 權杖更新失敗：$e',
                statusCode: 401,
                isTokenExpired: true,
              ),
      );
    }
  }

  Future<void> _logoutImpl() async {
    _cookie = null;
    _accessToken = null;
    _refreshToken = null;
    _clientId = null;
    _clientSecret = null;
    _expiresAt = null;
    _visitorData = null;
    _nextHomeContinuation = null;
    _nextExploreContinuation = null;
    _recentSeedVideoIds.clear();
    clearStreamCache();
    _residentResolver.invalidateSession();
    await clearCredentials();
    resetState();
  }

  Future<StreamingAccountInfo> _verifyAccountLive({
    CancellationToken? cancel,
  }) async {
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/account/account_menu',
      const <String, String>{'prettyPrint': 'false'},
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildWebRemixHeaders(authenticated: true),
      jsonBody: <String, dynamic>{'context': _buildWebRemixContext()},
      cancel: cancel,
    );
    _captureVisitorData(json);

    final header = _findFirstMapByKey(json, 'activeAccountHeaderRenderer');
    if (header == null) {
      throw const StreamingException(
        'YouTube Music 未回傳登入帳號資訊，Cookie 或授權權杖可能已失效',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    final displayName = _extractInnerTubeText(header['accountName']);
    if (displayName == null || displayName.trim().isEmpty) {
      throw const StreamingException(
        'YouTube Music 回傳帳號名稱為空，拒絕假性登入狀態',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    final email = _extractInnerTubeText(header['email']) ??
        _extractInnerTubeText(header['channelHandle']);

    return StreamingAccountInfo(
      displayName: displayName.trim(),
      email: email?.trim(),
      planTier: _detectPlanTier(json),
      expiresAt: _expiresAt,
    );
  }

  String? _detectPlanTier(Map<String, dynamic> accountMenuJson) {
    final raw = jsonEncode(accountMenuJson).toLowerCase();
    if (raw.contains('youtube music premium') || raw.contains('premium')) {
      return 'YouTube Music Premium';
    }
    return null;
  }

  Future<void> _persistCredentials(StreamingAccountInfo account) {
    return saveCredentialsJson(<String, dynamic>{
      'mode': _authMode,
      if (_cookie != null) 'cookie': _cookie,
      if (_clientId != null) 'client_id': _clientId,
      if (_clientSecret != null && _clientSecret!.isNotEmpty)
        'client_secret': _clientSecret,
      if (_accessToken != null) 'access_token': _accessToken,
      if (_refreshToken != null) 'refresh_token': _refreshToken,
      if (_expiresAt != null) 'expires_at': _expiresAt!.toUtc().toIso8601String(),
      'account': account.toJson(),
    });
  }
}
