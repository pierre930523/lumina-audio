part of '../streaming_manager.dart';

bool _isBrowserLaunchOrUnavailableError(String msg) {
  return msg.contains('未偵測到可用的本地瀏覽器') ||
      msg.contains('無法啟動本地瀏覽器') ||
      msg.contains('CDP') ||
      msg.contains('WebView2Loader.dll not available') ||
      msg.contains('Failed to initialize WebView2 runtime');
}

extension _StreamingManagerAuthExt on StreamingManager {
  Future<void> _authenticateProviderImpl(
    String kind,
    Map<String, dynamic> params, {
    void Function(String statusMsg)? onProgress,
  }) async {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }

    _activeCancellations[kind]?.cancel();
    final token = CancellationToken();
    _activeCancellations[kind] = token;
    _progressMessages.remove(kind);
    if (provider is BaseStreamingProvider) {
      provider.setAuthenticating();
    }
    _safeNotify();

    try {
      await provider.authenticate(
        params,
        cancel: token,
        onProgress: (msg) {
          _progressMessages[kind] = msg;
          _safeNotify();
          onProgress?.call(msg);
        },
      );
      _progressMessages.remove(kind);
      if (provider.authState == StreamingAuthState.connected) {
        authManager.clearAuthRequired(kind);
        l1Cache.clearProvider(kind);
        unawaited(refreshRecommendationsFor(kind, force: false));
      }
    } finally {
      if (identical(_activeCancellations[kind], token)) {
        _activeCancellations.remove(kind);
      }
      _safeNotify();
    }
  }

  void _logBrowserAuth(String message) {
    final sink = logSink;
    if (sink != null) {
      sink(message);
    } else {
      debugPrint(message);
    }
  }

  Future<void> _authenticateWithLocalBrowserImpl(
    String kind, {
    bool clearSession = false,
    Map<String, dynamic>? fallbackParams,
    void Function(String statusMsg)? onProgress,
  }) async {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }

    _activeCancellations[kind]?.cancel();
    final token = CancellationToken();
    _activeCancellations[kind] = token;
    _progressMessages.remove(kind);

    final prevState = provider.authState;
    final prevAccount = provider.accountInfo;
    void restorePreviousOnCancel() {
      if (provider is BaseStreamingProvider) {
        if (prevState == StreamingAuthState.connected && prevAccount != null) {
          provider.setConnected(prevAccount);
        } else {
          provider.resetState();
        }
      }
    }

    void emitProgress(String msg) {
      _progressMessages[kind] = msg;
      _safeNotify();
      onProgress?.call(msg);
    }

    if (provider is BaseStreamingProvider) {
      provider.setAuthenticating();
    }
    _safeNotify();

    try {
      // Path A: Loopback OAuth 2.0 / MusicKit in default system browser first
      // when OAuth client credentials / developer token are supplied.
      final pathAOAuth = _buildPathAOAuthParams(kind, fallbackParams);
      if (pathAOAuth != null) {
        emitProgress('正在開啟系統預設瀏覽器進行 ${provider.meta.name} OAuth 授權...');
        await provider.authenticate(
          pathAOAuth,
          cancel: token,
          onProgress: emitProgress,
        );
        _progressMessages.remove(kind);
        if (provider.authState == StreamingAuthState.connected) {
          authManager.clearAuthRequired(kind);
          l1Cache.clearProvider(kind);
          _logBrowserAuth(
            '[BrowserAuth] Captured ${provider.meta.name} OAuth session -> Verified OK -> DPAPI saved',
          );
          unawaited(refreshRecommendationsFor(kind, force: false));
        }
        return;
      }

      // Path B: Registry-detected default local Chromium browser + CDP credential capture
      // (or non-Chromium real browser launch with assisted guidance).
      final browserAvailable = await _webViewAuthService.isWebView2Available();
      token.throwIfCancelled();

      if (!browserAvailable) {
        final planB = _buildPlanBFallbackParams(kind, fallbackParams);
        if (planB != null) {
          emitProgress('未偵測到可用的本地除錯瀏覽器，已改用系統瀏覽器授權...');
          await provider.authenticate(
            planB,
            cancel: token,
            onProgress: emitProgress,
          );
          _progressMessages.remove(kind);
          if (provider.authState == StreamingAuthState.connected) {
            authManager.clearAuthRequired(kind);
            l1Cache.clearProvider(kind);
            _logBrowserAuth(
              '[BrowserAuth] Captured ${provider.meta.name} OAuth session -> Verified OK -> DPAPI saved',
            );
            unawaited(refreshRecommendationsFor(kind, force: false));
          }
          return;
        }
        restorePreviousOnCancel();
        throw const StreamingException(
          '系統目前未偵測到可用的本地瀏覽器（Brave / Google Chrome / Microsoft Edge），無法啟動自動擷取登入。請於下方展開手動憑證或系統瀏覽器 OAuth 設定。',
          isWebViewUnavailable: true,
        );
      }

      final detected = detectLocalDefaultBrowser();
      final browserLabel = detected?.displayName ?? '本地系統瀏覽器';
      _activeWebViewKinds.add(kind);
      emitProgress('正在啟動 $browserLabel 前往 ${provider.meta.name} 官方登入頁...');

      final capture = await _webViewAuthService.openAuthWindow(
        WebViewAuthRequest.presetFor(kind, clearSession: clearSession),
      );
      _activeWebViewKinds.remove(kind);

      if (capture.cancelled || token.isCancelled) {
        restorePreviousOnCancel();
        throw const StreamingException('登入已取消', isCancelled: true);
      }

      if (capture.isBlockedByPlatform) {
        if (kind == 'youtube_music') {
          final ytmOAuth = _buildPlanBFallbackParams(kind, fallbackParams);
          if (ytmOAuth != null) {
            emitProgress('Google 安全性機制阻擋了除錯瀏覽器登入，已自動切換為系統瀏覽器 OAuth 裝置授權...');
            await provider.authenticate(
              ytmOAuth,
              cancel: token,
              onProgress: emitProgress,
            );
            _progressMessages.remove(kind);
            if (provider.authState == StreamingAuthState.connected) {
              authManager.clearAuthRequired(kind);
              l1Cache.clearProvider(kind);
              _logBrowserAuth(
                '[BrowserAuth] Captured ${provider.meta.name} OAuth device token -> Verified OK -> DPAPI saved',
              );
              unawaited(refreshRecommendationsFor(kind, force: false));
            }
            return;
          }
        }
        restorePreviousOnCancel();
        throw StreamingException(
          kind == 'youtube_music'
              ? 'Google 安全性機制阻擋了除錯瀏覽器登入（此瀏覽器或應用程式可能不安全）。請於下方展開「進階／手動輸入 Token」貼上瀏覽器 Cookie（SAPISID），或填入 Google OAuth Client ID 後改用系統預設瀏覽器授權。'
              : '${provider.meta.name} 阻擋了本地除錯瀏覽器登入，請改用下方系統瀏覽器 OAuth 或手動輸入 Token 完成授權。',
          isWebViewUnavailable: true,
        );
      }

      if (capture.isNonChromiumDefault && !capture.captured) {
        restorePreviousOnCancel();
        final nonChromName =
            capture.detectedBrowserName ?? detected?.displayName ?? '系統預設瀏覽器';
        final msg = capture.error?.trim().isNotEmpty == true
            ? capture.error!.trim()
            : '已於您的系統預設瀏覽器（$nonChromName）開啟 ${provider.meta.name} 官方登入頁。因 $nonChromName 非 Chromium 核心，無法自動透過 CDP 擷取憑證；請於瀏覽器完成登入後，依下方指引貼上憑證完成驗證。';
        throw StreamingException(
          msg,
          isWebViewUnavailable: true,
        );
      }

      if (!capture.captured) {
        final msg = capture.error?.trim().isNotEmpty == true
            ? capture.error!.trim()
            : '未能擷取 ${provider.meta.name} 登入憑證';
        if (_isBrowserLaunchOrUnavailableError(msg)) {
          restorePreviousOnCancel();
          throw StreamingException(
            '本地瀏覽器登入無法啟動（$msg），請改用下方手動憑證或系統瀏覽器 OAuth 授權。',
            isWebViewUnavailable: true,
          );
        }
        final err = StreamingException(msg);
        if (provider is BaseStreamingProvider) {
          provider.failWithError(err);
        }
        throw err;
      }

      final authParams = buildAuthParamsFromWebViewResult(kind, capture);
      emitProgress('已擷取登入憑證，正在向平台即時驗證帳號...');

      await provider.authenticate(
        authParams,
        cancel: token,
        onProgress: emitProgress,
      );
      _progressMessages.remove(kind);
      if (provider.authState == StreamingAuthState.connected) {
        authManager.clearAuthRequired(kind);
        l1Cache.clearProvider(kind);
        final primarySecret = (authParams['cookie'] ??
                authParams['arl'] ??
                authParams['access_token'] ??
                authParams['user_auth_token'] ??
                authParams['music_user_token'] ??
                '')
            .toString();
        _logBrowserAuth(
          '[BrowserAuth] Captured ${provider.meta.name} token '
          '(${maskSecretForLog(primarySecret)}) -> Verified OK -> DPAPI saved',
        );
        unawaited(refreshRecommendationsFor(kind, force: false));
      }
    } on StreamingException catch (e) {
      if (e.isCancelled) {
        restorePreviousOnCancel();
      }
      rethrow;
    } finally {
      _activeWebViewKinds.remove(kind);
      if (identical(_activeCancellations[kind], token)) {
        _activeCancellations.remove(kind);
      }
      _safeNotify();
    }
  }

  Map<String, dynamic>? _buildPathAOAuthParams(
    String kind,
    Map<String, dynamic>? params,
  ) {
    if (params == null || params.isEmpty) return null;
    if (kind == 'tidal' || kind == 'deezer') {
      return _buildPlanBFallbackParams(kind, params);
    }
    if (kind == 'apple_music') {
      if (params['use_musickit_browser'] == false) return null;
      return _buildPlanBFallbackParams(kind, params);
    }
    return null;
  }

  Map<String, dynamic>? _buildPlanBFallbackParams(
    String kind,
    Map<String, dynamic>? params,
  ) {
    if (params == null || params.isEmpty) return null;
    if (kind == 'youtube_music') {
      final clientId = params['client_id']?.toString().trim() ?? '';
      if (clientId.isEmpty) return null;
      final clientSecret = params['client_secret']?.toString().trim() ?? '';
      return <String, dynamic>{
        'mode': 'oauth_device',
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
      };
    }
    if (kind == 'tidal') {
      final clientId = params['client_id']?.toString().trim() ?? '';
      if (clientId.isEmpty) return null;
      final clientSecret = params['client_secret']?.toString().trim() ?? '';
      return <String, dynamic>{
        'mode': 'pkce',
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
      };
    }
    if (kind == 'deezer') {
      final appId = params['app_id']?.toString().trim() ?? '';
      final appSecret = params['app_secret']?.toString().trim() ?? '';
      if (appId.isEmpty || appSecret.isEmpty) return null;
      return <String, dynamic>{
        'mode': 'oauth',
        'app_id': appId,
        'app_secret': appSecret,
      };
    }
    if (kind == 'apple_music') {
      final devToken = params['developer_token']?.toString().trim() ?? '';
      if (devToken.isEmpty) return null;
      return <String, dynamic>{
        'mode': 'musickit_browser',
        'developer_token': devToken,
      };
    }
    return null;
  }

  void _cancelLoginImpl(String kind) {
    final token = _activeCancellations[kind];
    if (token != null) {
      token.cancel();
      _progressMessages[kind] = '登入已取消';
      _safeNotify();
    }
    if (_activeWebViewKinds.remove(kind)) {
      unawaited(_webViewAuthService.closeAuthWindow());
    }
  }

  Future<void> _logoutProviderImpl(String kind) async {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }
    _activeCancellations.remove(kind)?.cancel();
    if (_activeWebViewKinds.remove(kind)) {
      unawaited(_webViewAuthService.closeAuthWindow());
    }
    _recommendationCancellations.remove(kind)?.cancel();
    _loadingRecommendations.remove(kind);
    _recommendations.remove(kind);
    _recommendationErrors.remove(kind);
    _recommendationTokenExpired.remove(kind);
    _recommendationBatchIndex.remove(kind);
    _seenRecommendationAlbumIds.remove(kind);
    _seenRecommendationTrackIds.remove(kind);
    _progressMessages.remove(kind);
    singleFlightResolver.cancelProvider(kind);
    l1Cache.clearProvider(kind);
    await provider.logout();
    authManager.clearAuthRequired(kind);
    _persistRecommendationsCacheSync();
    _safeNotify();
  }
}
