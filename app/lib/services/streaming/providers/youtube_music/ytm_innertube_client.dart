part of '../youtube_music_provider.dart';

final RegExp _visitorDataPattern = RegExp(r'^Cg[A-Za-z0-9_%=-]{8,}$');

class _InnerTubeClientProfile {
  final String clientName;
  final String clientNameHeader;
  final String clientVersion;
  final String userAgent;
  final Map<String, dynamic> context;

  const _InnerTubeClientProfile({
    required this.clientName,
    required this.clientNameHeader,
    required this.clientVersion,
    required this.userAgent,
    required this.context,
  });
}

const List<_InnerTubeClientProfile> _cleanFallbackProfiles =
    <_InnerTubeClientProfile>[
      _InnerTubeClientProfile(
        clientName: 'ANDROID_VR',
        clientNameHeader: '28',
        clientVersion: '1.60.19',
        userAgent:
            'com.google.android.apps.youtube.vr.oculus/1.60.19 '
            '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
        context: <String, dynamic>{
          'client': <String, dynamic>{
            'clientName': 'ANDROID_VR',
            'clientVersion': '1.60.19',
            'deviceMake': 'Oculus',
            'deviceModel': 'Quest 3',
            'osName': 'Android',
            'osVersion': '12L',
            'androidSdkVersion': 32,
            'hl': 'zh-TW',
            'gl': 'TW',
          },
        },
      ),
    ];

String? _extractVisitorDataFromSwJsData(String rawBody) {
  var trimmed = rawBody.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith(")]}'")) {
    final newlineIdx = trimmed.indexOf('\n');
    trimmed = newlineIdx >= 0
        ? trimmed.substring(newlineIdx + 1).trim()
        : trimmed.substring(4).trim();
  }
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final direct = decoded['visitorData']?.toString().trim();
      if (direct != null && direct.isNotEmpty) return direct;
      final rc = decoded['responseContext'];
      if (rc is Map) {
        final nested = rc['visitorData']?.toString().trim();
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return _findVisitorDataInDynamic(decoded);
  } catch (_) {
    return null;
  }
}

String? _findVisitorDataInDynamic(dynamic node) {
  if (node is String) {
    final trimmed = node.trim();
    if (_visitorDataPattern.hasMatch(trimmed)) {
      return trimmed;
    }
    return null;
  }
  if (node is List) {
    for (final item in node) {
      final found = _findVisitorDataInDynamic(item);
      if (found != null) return found;
    }
  } else if (node is Map) {
    final direct = node['visitorData'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct.trim();
    }
    for (final val in node.values) {
      final found = _findVisitorDataInDynamic(val);
      if (found != null) return found;
    }
  }
  return null;
}

String? _extractContinuationToken(Map<String, dynamic> root) {
  final nextData = _findFirstMapByKey(root, 'nextContinuationData') ??
      _findFirstMapByKey(root, 'nextRadioContinuationData');
  final tok1 = nextData?['continuation']?.toString().trim();
  if (tok1 != null && tok1.isNotEmpty) return tok1;
  final cmd = _findFirstMapByKey(root, 'continuationCommand');
  final tok2 = cmd?['token']?.toString().trim();
  if (tok2 != null && tok2.isNotEmpty) return tok2;
  return null;
}

extension _YtmInnerTubeClient on YouTubeMusicProvider {
  YtmAuthCredentials? _currentResidentAuthImpl() {
    if (authState != StreamingAuthState.connected) return null;
    return YtmAuthCredentials(
      authMode: _authMode,
      cookie: _cookie,
      accessToken: _accessToken,
      visitorData: _visitorData,
    );
  }

  Map<String, dynamic> _buildWebRemixContext() {
    final vd = _visitorData?.trim();
    return <String, dynamic>{
      'client': <String, dynamic>{
        'clientName': 'WEB_REMIX',
        'clientVersion': YouTubeMusicProvider._webRemixClientVersion,
        'hl': 'zh-TW',
        'gl': 'TW',
        if (vd != null && vd.isNotEmpty) 'visitorData': vd,
      },
    };
  }

  Map<String, String> _buildWebRemixHeaders({bool authenticated = true}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Origin': YouTubeMusicProvider._ytMusicOrigin,
      'X-Origin': YouTubeMusicProvider._ytMusicOrigin,
      'Referer': '${YouTubeMusicProvider._ytMusicOrigin}/',
      'X-Youtube-Client-Name':
          YouTubeMusicProvider._webRemixClientNameHeader,
      'X-Youtube-Client-Version':
          YouTubeMusicProvider._webRemixClientVersion,
      'User-Agent': YouTubeMusicProvider._desktopChromeUserAgent,
    };

    final vd = _visitorData?.trim();
    if (vd != null && vd.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = vd;
    }

    if (authenticated) {
      if (_authMode == 'cookie' && _cookie != null && _cookie!.isNotEmpty) {
        final sapisid = _ytmExtractSapisidFromCookie(_cookie!);
        if (sapisid == null || sapisid.isEmpty) {
          throw const StreamingException(
            'Cookie 缺少 SAPISID 或 __Secure-3PAPISID，無法產生授權簽章',
            statusCode: 401,
          );
        }
        final ts = clock().millisecondsSinceEpoch ~/ 1000;
        headers['X-Goog-AuthUser'] = '0';
        headers['Cookie'] = _cookie!;
        headers['Authorization'] = _ytmComputeSapisidHash(
          sapisid,
          timestampSeconds: ts,
        );
      } else if (_accessToken != null && _accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $_accessToken';
      }
    }
    return headers;
  }

  /// Builds strictly isolated headers for unauthenticated fallback
  /// InnerTube clients (`ANDROID_VR`) with ZERO Web Cookie / SAPISIDHASH /
  /// Bearer / Client-Name 67 / Origin / X-Origin / Referer / X-Goog-AuthUser
  /// leakage.
  Map<String, String> _buildCleanClientHeaders(
    _InnerTubeClientProfile profile,
  ) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent': profile.userAgent,
      'X-Youtube-Client-Name': profile.clientNameHeader,
      'X-Youtube-Client-Version': profile.clientVersion,
    };
    const forbidden = <String>{
      'cookie',
      'authorization',
      'origin',
      'x-origin',
      'referer',
      'x-goog-authuser',
    };
    assert(
      headers.keys.every((k) => !forbidden.contains(k.toLowerCase())),
      'Clean InnerTube client must never include web auth headers',
    );
    return headers;
  }

  void _captureVisitorData(Map<String, dynamic> json) {
    final rc = json['responseContext'];
    if (rc is Map) {
      final vd = rc['visitorData']?.toString().trim();
      if (vd != null && vd.isNotEmpty) {
        _visitorData = vd;
      }
    }
  }

  Future<void> _ensureVisitorData({
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    if (_visitorData != null && _visitorData!.trim().isNotEmpty) return;
    cancel?.throwIfCancelled();

    final effectiveTimeout =
        (timeout != null && timeout < const Duration(seconds: 4))
            ? timeout
            : const Duration(seconds: 4);

    // 1. Lightweight GET /sw.js_data (no auth cookies).
    try {
      final swUri = BaseStreamingProvider.buildUri(baseUrl, '/sw.js_data');
      final resp = await http.send(
        method: 'GET',
        uri: swUri,
        headers: const <String, String>{
          'User-Agent': YouTubeMusicProvider._desktopChromeUserAgent,
        },
        cancel: cancel,
        timeout: effectiveTimeout,
      );
      if (resp.isSuccess) {
        final extracted = _extractVisitorDataFromSwJsData(resp.body);
        if (extracted != null && extracted.isNotEmpty) {
          _visitorData = extracted;
          return;
        }
      }
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
    } catch (_) {}

    cancel?.throwIfCancelled();
    if (_visitorData != null && _visitorData!.trim().isNotEmpty) return;

    // 2. Fallback: unauthenticated WEB_REMIX /youtubei/v1/browse.
    try {
      final browseUri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/youtubei/v1/browse',
        const <String, String>{'prettyPrint': 'false'},
      );
      final res = await http.sendJsonRaw(
        method: 'POST',
        uri: browseUri,
        headers: _buildWebRemixHeaders(authenticated: false),
        jsonBody: <String, dynamic>{
          'context': _buildWebRemixContext(),
          'browseId': 'FEmusic_home',
        },
        cancel: cancel,
        timeout: effectiveTimeout,
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _captureVisitorData(res.json);
      }
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _browse(
    String browseId, {
    String? continuation,
    bool forceRefresh = false,
    CancellationToken? cancel,
  }) async {
    final qp = <String, String>{
      'prettyPrint': 'false',
      if (continuation != null && continuation.isNotEmpty) ...<String, String>{
        'ctoken': continuation,
        'continuation': continuation,
      },
    };
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/browse',
      qp,
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: BaseStreamingProvider.withNoCacheHeaders(
        _buildWebRemixHeaders(
          authenticated: authState == StreamingAuthState.connected,
        ),
        forceRefresh: forceRefresh,
      ),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'browseId': browseId,
        if (continuation != null && continuation.isNotEmpty)
          'continuation': continuation,
      },
      cancel: cancel,
    );
    _captureVisitorData(json);
    return json;
  }

  Future<Map<String, dynamic>> _fetchWatchNextRadio(
    String videoId, {
    String? continuation,
    bool forceRefresh = false,
    CancellationToken? cancel,
  }) async {
    final trimmedCont = continuation?.trim();
    final hasCont = trimmedCont != null && trimmedCont.isNotEmpty;
    final qp = <String, String>{
      'prettyPrint': 'false',
      if (hasCont) ...<String, String>{
        'ctoken': trimmedCont,
        'continuation': trimmedCont,
      },
    };
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/next',
      qp,
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: BaseStreamingProvider.withNoCacheHeaders(
        _buildWebRemixHeaders(
          authenticated: authState == StreamingAuthState.connected,
        ),
        forceRefresh: forceRefresh,
      ),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'videoId': videoId,
        'playlistId': 'RDAMVM$videoId',
        'isAudioOnly': true,
        if (hasCont) 'continuation': trimmedCont,
      },
      cancel: cancel,
    );
    _captureVisitorData(json);
    return json;
  }
}
