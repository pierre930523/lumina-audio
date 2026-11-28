part of '../tidal_provider.dart';

extension _TidalAuthFlows on TidalProvider {
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
        : TidalProvider.defaultScopes;

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
        : TidalProvider.defaultScopes;

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
}
