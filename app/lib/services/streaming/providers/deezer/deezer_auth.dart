part of '../deezer_provider.dart';

extension _DeezerAuth on DeezerProvider {
  Future<void> _restoreFromStorageImpl() async {
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

  Future<void> _authenticateImpl(
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

  Future<void> _refreshSessionIfNeededImpl({bool force = false}) {
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

  Future<void> _logoutImpl() async {
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
}
