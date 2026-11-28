part of 'streaming_login_dialog.dart';

extension _StreamingLoginAuthActionsExt on _StreamingLoginDialogState {
  Future<void> _loadRememberedTidalByok(TidalProvider tidal) async {
    final byok = await tidal.readRememberedByok();
    if (!mounted || byok == null) return;
    _updateState(() {
      _hasRememberedTidalByok = true;
      if (_tidalClientIdCtrl.text.trim().isEmpty &&
          _tidalClientSecretCtrl.text.trim().isEmpty) {
        _tidalClientIdCtrl.text = byok.clientId;
        _tidalClientSecretCtrl.text = byok.clientSecret;
        _tidalByokFromMemoryOnly = true;
      }
    });
  }

  Future<void> _clearRememberedTidalByok() async {
    final p = widget.provider;
    if (p is TidalProvider) {
      await p.clearRememberedByok();
    }
    if (!mounted) return;
    _updateState(() {
      _hasRememberedTidalByok = false;
      _tidalByokFromMemoryOnly = false;
      _tidalClientIdCtrl.clear();
      _tidalClientSecretCtrl.clear();
    });
  }

  Future<void> _authenticateWithParams(Map<String, dynamic> params) async {
    if (_submitting) return;
    _updateState(() {
      _submitting = true;
      _errorMessage = null;
      _progressMessage = '正在連線至 ${widget.provider.meta.name} 伺服器驗證...';
    });

    try {
      await widget.streamingManager.authenticateProvider(
        _kind,
        params,
        onProgress: (msg) {
          if (!mounted) return;
          _updateState(() {
            _progressMessage = msg;
          });
        },
      );
      if (!mounted) return;
      if (widget.provider.authState == StreamingAuthState.connected) {
        Navigator.of(context).pop(true);
      } else {
        _updateState(() {
          _submitting = false;
          _errorMessage = widget.provider.lastError ?? '驗證未完成';
        });
      }
    } on StreamingException catch (e) {
      if (!mounted) return;
      _updateState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        _errorMessage = e.isCancelled ? null : e.message;
        if (!e.isCancelled &&
            _kind == 'tidal' &&
            !_showByokAdvanced &&
            e.message.contains('Client ID')) {
          _showByokAdvanced = true;
        }
      });
    } catch (e) {
      if (!mounted) return;
      _updateState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        _errorMessage = e.toString();
      });
    }
  }

  Map<String, dynamic>? _collectPlanBFallbackParams() {
    switch (_kind) {
      case 'youtube_music':
        final clientId = _ytClientIdCtrl.text.trim();
        if (clientId.isEmpty) return null;
        final clientSecret = _ytClientSecretCtrl.text.trim();
        return <String, dynamic>{
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        };
      case 'tidal':
        if (_tidalByokFromMemoryOnly && !_showByokAdvanced) return null;
        final clientId = _tidalClientIdCtrl.text.trim();
        if (clientId.isEmpty) return null;
        final clientSecret = _tidalClientSecretCtrl.text.trim();
        return <String, dynamic>{
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        };
      case 'deezer':
        final appId = _deezerAppIdCtrl.text.trim();
        final appSecret = _deezerAppSecretCtrl.text.trim();
        if (appId.isEmpty || appSecret.isEmpty) return null;
        return <String, dynamic>{
          'app_id': appId,
          'app_secret': appSecret,
        };
      case 'apple_music':
        final devToken = _appleDevTokenCtrl.text.trim();
        if (devToken.isEmpty) return null;
        return <String, dynamic>{'developer_token': devToken};
      default:
        return null;
    }
  }

  Future<void> _submitWebViewLogin() async {
    if (_submitting) return;
    final detectedName = _detectedBrowser?.displayName;
    _updateState(() {
      _submitting = true;
      _submittingWebView = true;
      _errorMessage = null;
      _nonChromiumBrowserNotice = null;
      _progressMessage = detectedName != null
          ? '正在啟動 $detectedName 登入視窗...'
          : '正在啟動本地系統瀏覽器登入視窗...';
    });

    try {
      await widget.streamingManager.authenticateWithLocalBrowser(
        _kind,
        clearSession:
            widget.provider.authState == StreamingAuthState.error ||
            widget.provider.authState == StreamingAuthState.authRequired,
        fallbackParams: _collectPlanBFallbackParams(),
        onProgress: (msg) {
          if (!mounted) return;
          _updateState(() {
            _progressMessage = msg;
          });
        },
      );
      if (!mounted) return;
      if (widget.provider.authState == StreamingAuthState.connected) {
        Navigator.of(context).pop(true);
      } else {
        _updateState(() {
          _submitting = false;
          _submittingWebView = false;
          _progressMessage = null;
          _errorMessage = widget.provider.lastError ?? '驗證未完成';
        });
      }
    } on StreamingException catch (e) {
      if (!mounted) return;
      final isNonChromiumMsg =
          e.message.contains('非 Chromium') ||
          (_detectedBrowser != null && !_detectedBrowser!.isChromium);
      _updateState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        if (e.isCancelled) {
          _errorMessage = null;
          _nonChromiumBrowserNotice = null;
        } else {
          if (e.isWebViewUnavailable) {
            _showManualTokenSection = true;
          }
          if (e.isWebViewUnavailable && isNonChromiumMsg) {
            _nonChromiumBrowserNotice = e.message;
            _errorMessage = null;
          } else {
            _errorMessage = e.message;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      _updateState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _submitPrimary() async {
    switch (_kind) {
      case 'youtube_music':
        if (_selectedTab == 0) {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'cookie',
            'cookie': _ytCookieCtrl.text.trim(),
          });
        } else {
          final secret = _ytClientSecretCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'oauth_device',
            'client_id': _ytClientIdCtrl.text.trim(),
            if (secret.isNotEmpty) 'client_secret': secret,
          });
        }
        return;
      case 'tidal':
        final clientId = _tidalClientIdCtrl.text.trim();
        final clientSecret = _tidalClientSecretCtrl.text.trim();
        if (_selectedTab == 0) {
          final refreshToken = _tidalRefreshTokenCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'access_token',
            'access_token': _tidalAccessTokenCtrl.text.trim(),
            if (refreshToken.isNotEmpty) 'refresh_token': refreshToken,
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            'remember_byok': _rememberTidalByok,
          });
          return;
        }
        if (clientId.isEmpty && !_showByokAdvanced) {
          _updateState(() {
            _showByokAdvanced = true;
          });
        }
        if (_selectedTab == 1) {
          final code = _tidalManualCodeCtrl.text.trim();
          final verifier = _tidalManualVerifierCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'pkce',
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            if (code.isNotEmpty) 'code': code,
            if (verifier.isNotEmpty) 'code_verifier': verifier,
            'remember_byok': _rememberTidalByok,
          });
        } else {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'device_code',
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            'remember_byok': _rememberTidalByok,
          });
        }
        return;
      case 'qobuz':
        final appId = _qobuzAppIdCtrl.text.trim();
        final appSecret = _qobuzAppSecretCtrl.text.trim();
        if (appId.isEmpty && !_showByokAdvanced) {
          _updateState(() {
            _showByokAdvanced = true;
          });
        }
        if (_selectedTab == 0) {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'credentials',
            'email': _qobuzEmailCtrl.text.trim(),
            'password': _qobuzPasswordCtrl.text,
            'app_id': appId,
            if (appSecret.isNotEmpty) 'app_secret': appSecret,
          });
        } else {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'token',
            'user_auth_token': _qobuzTokenCtrl.text.trim(),
            'app_id': appId,
            if (appSecret.isNotEmpty) 'app_secret': appSecret,
          });
        }
        return;
      case 'deezer':
        if (_selectedTab == 0) {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'arl',
            'arl': _deezerArlCtrl.text.trim(),
          });
        } else {
          final code = _deezerCodeCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'oauth',
            'app_id': _deezerAppIdCtrl.text.trim(),
            'app_secret': _deezerAppSecretCtrl.text.trim(),
            if (code.isNotEmpty) 'code': code,
          });
        }
        return;
      case 'apple_music':
        await _authenticateWithParams(<String, dynamic>{
          'mode': 'musickit_tokens',
          'developer_token': _appleDevTokenCtrl.text.trim(),
          'music_user_token': _appleUserTokenCtrl.text.trim(),
        });
        return;
      default:
        return;
    }
  }

  void _handleCancelPressed() {
    if (_submitting || widget.streamingManager.isAuthenticating(_kind)) {
      widget.streamingManager.cancelLogin(_kind);
      return;
    }
    Navigator.of(context).pop(false);
  }

  void _handleCloseDialog() {
    if (_submitting || widget.streamingManager.isAuthenticating(_kind)) {
      widget.streamingManager.cancelLogin(_kind);
    }
    Navigator.of(context).pop(false);
  }

  ({String? url, String? code}) _parseDeviceCodeProgress(String? msg) {
    if (msg == null || msg.isEmpty) return (url: null, code: null);
    final urlMatch = RegExp(r'https?://[^\s]+').firstMatch(msg);
    final codeMatch = RegExp(r'(?:代碼|驗證碼)：([^\s]+)').firstMatch(msg);
    return (url: urlMatch?.group(0), code: codeMatch?.group(1));
  }
}
