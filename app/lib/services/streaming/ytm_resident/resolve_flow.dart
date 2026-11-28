part of '../ytm_resident_resolver.dart';

extension _YtmResolveFlowExt on YtmResidentResolver {
  Future<StreamSourceSpec> _resolveImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    if (_disposed) {
      throw const StreamingException('YtmResidentResolver 已釋放');
    }
    cancelToken?.throwIfCancelled();
    final resolveTimer = Stopwatch()..start();

    void logResolve(String leg) {
      debugPrint(
        '[StreamResolve] key=${key.providerId}:${key.trackId} '
        'leg=$leg resolve_ms=${resolveTimer.elapsedMilliseconds}',
      );
    }

    // If startup cold warmup is still in flight, share/await that exact
    // SharedFuture without duplicating initialization.
    final inFlightWarmup = _warmupFuture;
    if (inFlightWarmup != null && !_warmedUp) {
      await _awaitSharedWarmupWithCancel(inFlightWarmup, cancelToken);
      cancelToken?.throwIfCancelled();
    }

    final videoId = YtmResidentResolver.extractCleanVideoId(key.trackId);
    final auth = authProvider?.call();
    final diagnostics = <String>[];

    // Fetch Session-level GVS Token (O(1) cached hit w/ <15% background refresh)
    // and dynamic per-track Player Token concurrently when PotProvider exists.
    PoToken? gvsToken;
    PoToken? playerToken;
    final potProvider = _potProvider;
    if (potProvider != null) {
      final sessionBinding = _resolveSessionBinding(auth);
      final tokens = await Future.wait<PoToken?>(<Future<PoToken?>>[
        potProvider.getGvsToken(
          sessionBinding: sessionBinding,
          cancelToken: cancelToken,
        ),
        potProvider.getPlayerToken(
          videoId: videoId,
          cancelToken: cancelToken,
        ),
      ]);
      cancelToken?.throwIfCancelled();
      gvsToken = tokens[0];
      playerToken = tokens[1];
    }

    // 1: Clean unauthenticated ANDROID_VR (strictly ZERO web cookies / auth).
    final initialGuestVisitor = _cachedVisitorData?.trim();
    final vrProfile = _buildAndroidVrProfile(visitorData: initialGuestVisitor);
    final vrSpec = await _queryPlayerProfile(
      key: key,
      videoId: videoId,
      baseOrigin: webBaseUrl,
      profile: vrProfile,
      headers: _cleanClientHeaders(vrProfile, visitorData: initialGuestVisitor),
      gvsToken: gvsToken,
      playerToken: playerToken,
      cancelToken: cancelToken,
      diagnostics: diagnostics,
    );
    if (vrSpec != null) {
      logResolve('android_vr');
      return vrSpec;
    }

    // Cold-start guest resilience: if ANDROID_VR failed before warmup populated
    // guest visitorData, fetch guest visitorData from /sw.js_data, re-bind GVS
    // PO Token to it, and retry ANDROID_VR once cleanly.
    if (requestHandler == null &&
        (initialGuestVisitor == null || initialGuestVisitor.isEmpty)) {
      cancelToken?.throwIfCancelled();
      final fetched = await _probeVisitorDataFromMusicOrigin(
        cancelToken: cancelToken,
      );
      cancelToken?.throwIfCancelled();
      final refreshedVisitor = _cachedVisitorData?.trim();
      if (fetched &&
          refreshedVisitor != null &&
          refreshedVisitor.isNotEmpty &&
          refreshedVisitor != initialGuestVisitor) {
        if (potProvider != null &&
            (gvsToken == null || auth?.sessionBindingKey == null)) {
          final reboundGvs = await potProvider.getGvsToken(
            sessionBinding: _resolveSessionBinding(auth),
            cancelToken: cancelToken,
          );
          cancelToken?.throwIfCancelled();
          if (reboundGvs != null) {
            gvsToken = reboundGvs;
          }
        }
        final retryProfile = _buildAndroidVrProfile(
          visitorData: refreshedVisitor,
        );
        final retrySpec = await _queryPlayerProfile(
          key: key,
          videoId: videoId,
          baseOrigin: webBaseUrl,
          profile: retryProfile,
          headers: _cleanClientHeaders(
            retryProfile,
            visitorData: refreshedVisitor,
          ),
          gvsToken: gvsToken,
          playerToken: playerToken,
          cancelToken: cancelToken,
          diagnostics: diagnostics,
        );
        if (retrySpec != null) {
          logResolve('android_vr_retry');
          return retrySpec;
        }
      }
    }

    // 2: Clean unauthenticated VISIONOS (fast-path for YouTube Podcasts and
    // tracks where ANDROID_VR returns LOGIN_REQUIRED; strictly ZERO web auth).
    cancelToken?.throwIfCancelled();
    final visionVisitor = _cachedVisitorData?.trim();
    final visionProfile = _buildVisionOsProfile(visitorData: visionVisitor);
    final visionSpec = await _queryPlayerProfile(
      key: key,
      videoId: videoId,
      baseOrigin: webBaseUrl,
      profile: visionProfile,
      headers: _cleanClientHeaders(visionProfile, visitorData: visionVisitor),
      gvsToken: gvsToken,
      playerToken: playerToken,
      cancelToken: cancelToken,
      diagnostics: diagnostics,
    );
    if (visionSpec != null) {
      logResolve('visionos');
      return visionSpec;
    }

    // 3: WEB_REMIX (authenticated when usable creds exist, otherwise clean
    // Guest WEB_REMIX with visitorData + Player PO Token).
    cancelToken?.throwIfCancelled();
    final useWebAuth = auth != null && auth.hasUsableWebRemixAuth;
    final effectiveVisitor =
        (auth?.visitorData?.trim().isNotEmpty == true)
            ? auth!.visitorData!.trim()
            : _cachedVisitorData?.trim();
    final webRemixProfile = _ResidentClientProfile(
      clientName: 'WEB_REMIX',
      clientNameHeader: '67',
      clientVersion: YtmResidentResolver._webRemixClientVersion,
      userAgent: YtmResidentResolver._desktopChromeUserAgent,
      isWebRemix: true,
      isAuthenticated: useWebAuth,
      supportsPlayerPoToken: true,
      context: <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'WEB_REMIX',
          'clientVersion': YtmResidentResolver._webRemixClientVersion,
          'hl': 'zh-TW',
          'gl': 'TW',
          if (effectiveVisitor != null && effectiveVisitor.isNotEmpty)
            'visitorData': effectiveVisitor,
        },
      },
    );
    final webRemixHeaders = useWebAuth
        ? _webRemixHeaders(auth, visitorDataOverride: effectiveVisitor)
        : _guestWebRemixHeaders(visitorData: effectiveVisitor);
    final webSpec = await _queryPlayerProfile(
      key: key,
      videoId: videoId,
      baseOrigin: musicBaseUrl,
      profile: webRemixProfile,
      headers: webRemixHeaders,
      gvsToken: gvsToken,
      playerToken: playerToken,
      cancelToken: cancelToken,
      diagnostics: diagnostics,
    );
    if (webSpec != null) {
      logResolve('web_remix');
      return webSpec;
    }

    // 4: Mature JS Runtime fallback (bundled yt-dlp + deno + ejs) for
    // signatureCipher / n-parameter decryption or IP-gated LOGIN_REQUIRED.
    final fallback = fallbackResolver;
    if (fallback != null) {
      cancelToken?.throwIfCancelled();
      try {
        final fallbackSpec = await fallback(
          key: key,
          videoId: videoId,
          auth: auth,
          gvsToken: gvsToken,
          playerToken: playerToken,
          visitorData: effectiveVisitor,
          cancelToken: cancelToken,
        );
        cancelToken?.throwIfCancelled();
        if (fallbackSpec != null) {
          logResolve('yt_dlp');
          return fallbackSpec;
        }
        diagnostics.add('yt-dlp/deno fallback returned no stream');
      } on StreamingException catch (e) {
        if (e.isCancelled) rethrow;
        diagnostics.add('yt-dlp/deno ${e.message}');
      } catch (e) {
        diagnostics.add('yt-dlp/deno $e');
      }
    }

    logResolve('failed');
    throw StreamingException(
      'YouTube Music 未能解析可播放音訊（${diagnostics.join(' | ')}）',
    );
  }

  Future<DirectRangeSpec?> _queryPlayerProfile({
    required StreamKey key,
    required String videoId,
    required String baseOrigin,
    required _ResidentClientProfile profile,
    required Map<String, String> headers,
    required PoToken? gvsToken,
    required PoToken? playerToken,
    required CancellationToken? cancelToken,
    required List<String> diagnostics,
  }) async {
    if (profile.clientName == 'ANDROID_VR' ||
        profile.clientName == 'VISIONOS') {
      _assertNoWebAuthLeakage(headers, clientName: profile.clientName);
    }
    final cleanOrigin = _cleanOrigin(baseOrigin);
    final uri = Uri.parse('$cleanOrigin/youtubei/v1/player?prettyPrint=false');
    final payload = <String, dynamic>{
      'context': profile.context,
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
      if (profile.supportsPlayerPoToken &&
          playerToken != null &&
          playerToken.token.isNotEmpty)
        'serviceIntegrityDimensions': <String, dynamic>{
          'poToken': playerToken.token,
        },
    };

    try {
      final resp = await _postJson(
        uri: uri,
        headers: headers,
        body: payload,
        cancelToken: cancelToken,
      );
      cancelToken?.throwIfCancelled();

      if (resp.statusCode == 401 &&
          profile.isWebRemix &&
          profile.isAuthenticated) {
        if (fallbackResolver == null) {
          throw const StreamingException(
            'YouTube Music 授權憑證已失效（HTTP 401），請重新登入',
            statusCode: 401,
            isTokenExpired: true,
          );
        }
        diagnostics.add('WEB_REMIX HTTP 401 (fallback to guest/JS resolver)');
        return null;
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        diagnostics.add('${profile.clientName} HTTP ${resp.statusCode}');
        return null;
      }

      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) {
        diagnostics.add('${profile.clientName} invalid JSON');
        return null;
      }
      final json = Map<String, dynamic>.from(decoded);
      final rc = json['responseContext'];
      if (rc is Map) {
        final vd = rc['visitorData']?.toString().trim();
        if (vd != null && vd.isNotEmpty) {
          _cachedVisitorData = vd;
        }
      }
      final spec = _extractPreferredDirectRangeSpec(
        key: key,
        playerJson: json,
        profile: profile,
        gvsToken: gvsToken,
      );
      if (spec != null) {
        return spec;
      }
      final playability = json['playabilityStatus'];
      final status = playability is Map ? playability['status'] : null;
      final reason = playability is Map ? playability['reason'] : null;
      final hasCipherOnly = _hasCipheredAudioFormats(json);
      final hasUndecryptedN =
          profile.isWebRemix && _hasUndecryptedNParamAudioFormats(json);
      diagnostics.add(
        '${profile.clientName} status=${status ?? 'OK'}'
        '${reason != null ? ' ($reason)' : (hasCipherOnly ? ' (signatureCipher requires JS decryption)' : (hasUndecryptedN ? ' (undecrypted n-parameter requires JS decryption)' : ' (no direct audio)'))}',
      );
      return null;
    } on StreamingException catch (e) {
      if (e.isCancelled || e.isTokenExpired || e.statusCode == 401) rethrow;
      diagnostics.add('${profile.clientName} ${e.message}');
      return null;
    } catch (e) {
      diagnostics.add('${profile.clientName} $e');
      return null;
    }
  }
}

_ResidentClientProfile _buildAndroidVrProfile({String? visitorData}) {
  final vd = visitorData?.trim();
  return _ResidentClientProfile(
    clientName: 'ANDROID_VR',
    clientNameHeader: '28',
    clientVersion: YtmResidentResolver._androidVrClientVersion,
    userAgent: YtmResidentResolver._androidVrUserAgent,
    supportsPlayerPoToken: false,
    context: <String, dynamic>{
      'client': <String, dynamic>{
        'clientName': 'ANDROID_VR',
        'clientVersion': YtmResidentResolver._androidVrClientVersion,
        'deviceMake': 'Oculus',
        'deviceModel': 'Quest 3',
        'osName': 'Android',
        'osVersion': '12L',
        'androidSdkVersion': 32,
        'hl': 'zh-TW',
        'gl': 'TW',
        if (vd != null && vd.isNotEmpty) 'visitorData': vd,
      },
    },
  );
}

_ResidentClientProfile _buildVisionOsProfile({String? visitorData}) {
  final vd = visitorData?.trim();
  return _ResidentClientProfile(
    clientName: 'VISIONOS',
    clientNameHeader: '101',
    clientVersion: YtmResidentResolver._visionOsClientVersion,
    userAgent: YtmResidentResolver._visionOsUserAgent,
    supportsPlayerPoToken: false,
    context: <String, dynamic>{
      'client': <String, dynamic>{
        'clientName': 'VISIONOS',
        'clientVersion': YtmResidentResolver._visionOsClientVersion,
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice14,1',
        'osName': 'visionOS',
        'osVersion': '1.3.21O771',
        'hl': 'en',
        'gl': 'US',
        if (vd != null && vd.isNotEmpty) 'visitorData': vd,
      },
    },
  );
}

bool _hasQueryParam(String url, String name) {
  final value = Uri.tryParse(url)?.queryParameters[name];
  return value != null && value.trim().isNotEmpty;
}

bool _hasUndecryptedNParamAudioFormats(Map<String, dynamic> playerJson) {
  final streamingData = playerJson['streamingData'];
  if (streamingData is! Map) return false;
  for (final listKey in const <String>['adaptiveFormats', 'formats']) {
    final rawList = streamingData[listKey];
    if (rawList is! List) continue;
    for (final item in rawList) {
      if (item is! Map) continue;
      final mime = item['mimeType']?.toString().toLowerCase() ?? '';
      if (!mime.startsWith('audio/')) continue;
      final url = item['url']?.toString().trim() ?? '';
      if (url.isNotEmpty && _hasQueryParam(url, 'n')) return true;
    }
  }
  return false;
}

bool _hasCipheredAudioFormats(Map<String, dynamic> playerJson) {
  final streamingData = playerJson['streamingData'];
  if (streamingData is! Map) return false;
  for (final listKey in const <String>['adaptiveFormats', 'formats']) {
    final rawList = streamingData[listKey];
    if (rawList is! List) continue;
    for (final item in rawList) {
      if (item is! Map) continue;
      final mime = item['mimeType']?.toString().toLowerCase() ?? '';
      if (!mime.startsWith('audio/')) continue;
      final sigCipher =
          (item['signatureCipher'] ?? item['cipher'])?.toString().trim() ?? '';
      if (sigCipher.isNotEmpty) return true;
    }
  }
  return false;
}

void _assertNoWebAuthLeakage(
  Map<String, String> headers, {
  String clientName = 'ANDROID_VR',
}) {
  for (final key in headers.keys) {
    if (YtmResidentResolver._forbiddenAndroidVrHeaders
        .contains(key.toLowerCase())) {
      throw StateError(
        'Forbidden web auth header "$key" leaked into $clientName request',
      );
    }
  }
}
