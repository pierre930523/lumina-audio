part of '../tidal_provider.dart';

String _normalizeBearerToken(String? raw) {
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

Map<String, dynamic>? _decodeJwtPayload(String token) {
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

DateTime? _extractJwtExpiryFromPayload(Map<String, dynamic>? payload) {
  if (payload == null) return null;
  final exp = payload['exp'];
  if (exp is num) {
    final expSec = exp.toInt();
    if (expSec > 0) {
      return DateTime.fromMillisecondsSinceEpoch(expSec * 1000, isUtc: true);
    }
  }
  return null;
}

extension _TidalAuth on TidalProvider {
  Future<void> _restoreFromStorageImpl() async {
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

  Future<({String clientId, String clientSecret})?>
      _readRememberedByokImpl() async {
    try {
      final raw =
          await credentialStore.read(TidalProvider.byokCredentialStorageKey);
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

  Future<void> _saveRememberedByokImpl({
    required String clientId,
    String? clientSecret,
  }) async {
    final cid = clientId.trim();
    final csec = clientSecret?.trim() ?? '';
    if (cid.isEmpty) return;
    await credentialStore.write(
      TidalProvider.byokCredentialStorageKey,
      jsonEncode(<String, dynamic>{
        'client_id': cid,
        if (csec.isNotEmpty) 'client_secret': csec,
      }),
    );
  }

  Future<void> _clearRememberedByokImpl() async {
    await credentialStore.delete(TidalProvider.byokCredentialStorageKey);
    if (authState != StreamingAuthState.connected) {
      _clientId = null;
      _clientSecret = null;
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

  Future<void> _refreshSessionIfNeededImpl({bool force = false}) {
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

  Future<void> _logoutImpl() async {
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
}
