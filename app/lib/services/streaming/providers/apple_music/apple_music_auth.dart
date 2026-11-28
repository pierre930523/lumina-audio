part of '../apple_music_provider.dart';

extension _AppleMusicAuth on AppleMusicProvider {
  Future<void> _restoreFromStorageImpl() async {
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

  Future<void> _authenticateImpl(
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
      drmNotice: AppleMusicProvider.windowsFairPlayDrmNotice,
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

  Future<void> _logoutImpl() async {
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
}
