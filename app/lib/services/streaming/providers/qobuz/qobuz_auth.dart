part of '../qobuz_provider.dart';

extension _QobuzAuth on QobuzProvider {
  Future<void> _restoreFromStorageImpl() async {
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

  Future<void> _authenticateImpl(
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
            'password': QobuzProvider.computePasswordMd5(passwordParam),
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
      drmNotice: hasAppSecret ? null : QobuzProvider.missingAppSecretNotice,
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

  Future<void> _logoutImpl() async {
    _userAuthToken = null;
    _appSecret = null;
    await clearCredentials();
    resetState();
  }
}
