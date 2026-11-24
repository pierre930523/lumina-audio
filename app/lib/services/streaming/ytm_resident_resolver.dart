import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';
import 'pot_provider.dart';
import 'stream_resolver.dart';
import 'streaming_provider.dart';

/// Optional authenticated YouTube Music credentials supplied to
/// [YtmResidentResolver] for its final `WEB_REMIX` fallback leg.
@immutable
class YtmAuthCredentials {
  final String authMode;
  final String? cookie;
  final String? accessToken;
  final String? visitorData;

  const YtmAuthCredentials({
    this.authMode = 'cookie',
    this.cookie,
    this.accessToken,
    this.visitorData,
  });

  bool get hasUsableWebRemixAuth {
    if (authMode == 'oauth' || authMode == 'oauth_device') {
      return accessToken != null && accessToken!.trim().isNotEmpty;
    }
    final rawCookie = cookie?.trim() ?? '';
    if (rawCookie.isEmpty) return false;
    return YtmResidentResolver.extractSapisidFromCookie(rawCookie) != null;
  }

  /// Stable non-secret session binding key for Session-level GVS PO Tokens.
  String? get sessionBindingKey {
    if (authMode == 'oauth' || authMode == 'oauth_device') {
      final tok = accessToken?.trim();
      if (tok != null && tok.isNotEmpty) {
        return 'oauth:${sha256.convert(utf8.encode(tok)).toString().substring(0, 24)}';
      }
    }
    final rawCookie = cookie?.trim();
    if (rawCookie != null && rawCookie.isNotEmpty) {
      final sapisid = YtmResidentResolver.extractSapisidFromCookie(rawCookie);
      if (sapisid != null && sapisid.isNotEmpty) {
        return 'cookie:${sha256.convert(utf8.encode(sapisid)).toString().substring(0, 24)}';
      }
    }
    final vd = visitorData?.trim();
    if (vd != null && vd.isNotEmpty) {
      return vd;
    }
    return null;
  }
}

/// Raw HTTP response returned by an injected InnerTube transport handler.
@immutable
class YtmPlayerHttpResponse {
  final int statusCode;
  final String body;

  const YtmPlayerHttpResponse({
    required this.statusCode,
    required this.body,
  });
}

typedef YtmPlayerRequestHandler = Future<YtmPlayerHttpResponse> Function({
  required Uri uri,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
  CancellationToken? cancelToken,
});

/// Pluggable fallback resolver invoked only when resident InnerTube clients
/// fail or return cipher-protected (`signatureCipher` / `n`-parameter) formats.
///
/// Backed by bundled `yt-dlp` + `deno` JS Runtime in production (never fragile
/// hand-rolled regex scraping of `base.js`).
typedef YtmFallbackStreamResolver = Future<DirectRangeSpec?> Function({
  required StreamKey key,
  required String videoId,
  required YtmAuthCredentials? auth,
  required PoToken? gvsToken,
  required PoToken? playerToken,
  required String? visitorData,
  CancellationToken? cancelToken,
});

class _ResidentClientProfile {
  final String clientName;
  final String clientNameHeader;
  final String clientVersion;
  final String userAgent;
  final bool isWebRemix;
  final bool isAuthenticated;
  final bool supportsPlayerPoToken;
  final Map<String, dynamic> context;

  const _ResidentClientProfile({
    required this.clientName,
    required this.clientNameHeader,
    required this.clientVersion,
    required this.userAgent,
    this.isWebRemix = false,
    this.isAuthenticated = false,
    this.supportsPlayerPoToken = false,
    required this.context,
  });
}

/// Resident YouTube Music & YouTube Podcast InnerTube stream resolver.
///
/// Owns a single persistent keep-alive IPv4 `HttpClient` (`idleTimeout: 60s`,
/// `maxConnectionsPerHost: 4`) and queries `/youtubei/v1/player` directly
/// (`ANDROID_VR` with guest `visitorData` & ZERO web auth -> `VISIONOS` with
/// guest `visitorData` & ZERO web auth -> `WEB_REMIX` guest or authenticated
/// with optional PO Token -> mature `yt-dlp` + `deno` JS Runtime fallback for
/// `signatureCipher` / `n`-parameter decryption), preferring `itag 251`
/// (WebM/Opus 48 kHz) first and `itag 140` (M4A/AAC) second.
class YtmResidentResolver implements StreamResolver {
  static const String defaultWebOrigin = 'https://www.youtube.com';
  static const String defaultMusicOrigin = 'https://music.youtube.com';
  static const String _webRemixClientVersion = '1.20241120.01.00';
  static const String _desktopChromeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const String _androidVrClientVersion = '1.60.19';
  static const String _androidVrUserAgent =
      'com.google.android.apps.youtube.vr.oculus/1.60.19 '
      '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
  static const String _visionOsClientVersion = '0.1';
  static const String _visionOsUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.0 Safari/605.1.15';

  static final RegExp _validVideoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final RegExp _visitorDataPattern = RegExp(r'^Cg[A-Za-z0-9_%=-]{8,}$');

  /// Forbidden web-auth header names that MUST NEVER be sent on unauthenticated
  /// native clients (`ANDROID_VR`, `VISIONOS`).
  static const Set<String> _forbiddenAndroidVrHeaders = <String>{
    'cookie',
    'authorization',
    'origin',
    'x-origin',
    'referer',
    'x-goog-authuser',
  };

  static _ResidentClientProfile _buildAndroidVrProfile({String? visitorData}) {
    final vd = visitorData?.trim();
    return _ResidentClientProfile(
      clientName: 'ANDROID_VR',
      clientNameHeader: '28',
      clientVersion: _androidVrClientVersion,
      userAgent: _androidVrUserAgent,
      supportsPlayerPoToken: false,
      context: <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'ANDROID_VR',
          'clientVersion': _androidVrClientVersion,
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

  static _ResidentClientProfile _buildVisionOsProfile({String? visitorData}) {
    final vd = visitorData?.trim();
    return _ResidentClientProfile(
      clientName: 'VISIONOS',
      clientNameHeader: '101',
      clientVersion: _visionOsClientVersion,
      userAgent: _visionOsUserAgent,
      supportsPlayerPoToken: false,
      context: <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'VISIONOS',
          'clientVersion': _visionOsClientVersion,
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

  HttpClient _httpClient;
  final bool _ownsHttpClient;
  final YtmPlayerRequestHandler? requestHandler;
  final YtmAuthCredentials? Function()? authProvider;
  final YtmFallbackStreamResolver? fallbackResolver;
  final PotProvider? _potProvider;
  final bool _ownsPotProvider;
  final VoidCallback? _onHttp2Warmup;
  final String webBaseUrl;
  final String musicBaseUrl;
  final Duration requestTimeout;
  final Duration warmupTimeout;
  final DateTime Function() _clock;

  Future<void>? _warmupFuture;
  bool _warmedUp = false;
  int _warmupCount = 0;
  String? _cachedVisitorData;
  bool _disposed = false;

  YtmResidentResolver({
    HttpClient? httpClient,
    this.requestHandler,
    this.authProvider,
    this.fallbackResolver,
    PotProvider? potProvider,
    bool ownsPotProvider = false,
    this._onHttp2Warmup,
    this.webBaseUrl = defaultWebOrigin,
    this.musicBaseUrl = defaultMusicOrigin,
    this.requestTimeout = const Duration(seconds: 15),
    this.warmupTimeout = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _httpClient = httpClient ?? _createResidentHttpClient(),
       _ownsHttpClient = httpClient == null,
       _potProvider = potProvider,
       _ownsPotProvider = potProvider != null && ownsPotProvider,
       _clock = clock ?? DateTime.now;

  static HttpClient _createResidentHttpClient() {
    return createIpv4HttpClient(
      idleTimeout: const Duration(seconds: 60),
      maxConnectionsPerHost: 4,
      connectionTimeout: const Duration(seconds: 10),
    );
  }

  @override
  String get providerId => 'youtube_music';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.youtubeMusic;

  @visibleForTesting
  HttpClient get httpClient => _httpClient;

  @visibleForTesting
  bool get isWarmedUp => _warmedUp;

  @visibleForTesting
  int get warmupExecutionCount => _warmupCount;

  @visibleForTesting
  Future<void>? get activeWarmupFuture => _warmupFuture;

  @visibleForTesting
  String? get cachedVisitorData => _cachedVisitorData;

  /// Closes and recreates the owned resident [HttpClient] pool (used on NIC /
  /// network-epoch transitions so stale half-open sockets are dropped cleanly).
  void resetHttpClient() {
    if (_disposed || !_ownsHttpClient) return;
    try {
      _httpClient.close(force: true);
    } catch (_) {}
    _httpClient = _createResidentHttpClient();
  }

  /// Invalidates cached session state (`visitorData` and Session-level GVS PO
  /// Token) when authentication state or active account changes.
  void invalidateSession() {
    _cachedVisitorData = null;
    _warmedUp = false;
    _potProvider?.invalidateSession();
  }

  /// Async background warmup pre-warming TLS/HTTP2 connection pools, session
  /// `visitorData`, and Session-level GVS PO Token, wrapped in a `SharedFuture`
  /// so concurrent callers or cold-start [resolve] calls never duplicate init.
  Future<void> warmup({bool force = false}) {
    if (_disposed) return Future<void>.value();
    if (!force && _warmedUp) return Future<void>.value();
    final existing = _warmupFuture;
    if (!force && existing != null) return existing;

    final future = _doWarmup();
    _warmupFuture = future;
    return future.whenComplete(() {
      if (identical(_warmupFuture, future)) {
        _warmupFuture = null;
      }
    });
  }

  Future<void> _doWarmup() async {
    if (_disposed) return;
    _warmupCount++;

    // Trigger non-blocking Rust reqwest HTTP/2 TLS pool warmup when available.
    try {
      _onHttp2Warmup?.call();
    } catch (_) {}

    var anyNetworkSucceeded = false;

    if (requestHandler == null) {
      final results = await Future.wait<bool>(<Future<bool>>[
        _probeTlsEndpoint(_cleanOrigin(webBaseUrl), '/generate_204'),
        _probeVisitorDataFromMusicOrigin(),
      ]);
      anyNetworkSucceeded = results.any((ok) => ok);
    } else {
      anyNetworkSucceeded = true;
    }

    if (_disposed) return;

    final auth = authProvider?.call();
    final sessionBinding = _resolveSessionBinding(auth);
    if (_potProvider != null) {
      try {
        final gvs = await _potProvider
            .getGvsToken(sessionBinding: sessionBinding)
            .timeout(warmupTimeout, onTimeout: () => null);
        if (gvs != null) {
          anyNetworkSucceeded = true;
        }
      } catch (_) {}
    }

    if (!_disposed && anyNetworkSucceeded) {
      _warmedUp = true;
    }
  }

  Future<bool> _probeTlsEndpoint(String origin, String path) async {
    try {
      final uri = Uri.parse('$origin$path');
      final req = await _httpClient.openUrl('GET', uri).timeout(warmupTimeout);
      req.headers.set('User-Agent', _desktopChromeUserAgent);
      final resp = await req.close().timeout(warmupTimeout);
      await resp.drain<void>().timeout(warmupTimeout);
      return resp.statusCode >= 200 && resp.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _probeVisitorDataFromMusicOrigin() async {
    final authVisitor = authProvider?.call()?.visitorData?.trim();
    if (authVisitor != null && authVisitor.isNotEmpty) {
      _cachedVisitorData = authVisitor;
    }
    try {
      final uri = Uri.parse('${_cleanOrigin(musicBaseUrl)}/sw.js_data');
      final req = await _httpClient.openUrl('GET', uri).timeout(warmupTimeout);
      req.headers.set('User-Agent', _desktopChromeUserAgent);
      final resp = await req.close().timeout(warmupTimeout);
      final body = await utf8.decoder.bind(resp).join().timeout(warmupTimeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final extracted = _extractVisitorDataFromSwJsData(body);
        if (extracted != null && extracted.isNotEmpty) {
          _cachedVisitorData = extracted;
        }
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  String _resolveSessionBinding(YtmAuthCredentials? auth) {
    final authBinding = auth?.sessionBindingKey;
    if (authBinding != null && authBinding.isNotEmpty) {
      return authBinding;
    }
    final vd = _cachedVisitorData?.trim();
    if (vd != null && vd.isNotEmpty) {
      return vd;
    }
    return 'ytm_guest_session';
  }

  static String _cleanOrigin(String raw) =>
      raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;

  static String? _extractVisitorDataFromSwJsData(String rawBody) {
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
      return _findVisitorDataInDynamic(decoded);
    } catch (_) {
      return null;
    }
  }

  static String? _findVisitorDataInDynamic(dynamic node) {
    if (node is String) {
      final trimmed = node.trim();
      if (_visitorDataPattern.hasMatch(trimmed)) return trimmed;
      return null;
    }
    if (node is List) {
      for (final item in node) {
        final found = _findVisitorDataInDynamic(item);
        if (found != null) return found;
      }
    } else if (node is Map) {
      final direct = node['visitorData'];
      if (direct is String && direct.trim().isNotEmpty) return direct.trim();
      for (final val in node.values) {
        final found = _findVisitorDataInDynamic(val);
        if (found != null) return found;
      }
    }
    return null;
  }

  Future<void> _awaitSharedWarmupWithCancel(
    Future<void> sharedWarmup,
    CancellationToken? cancelToken,
  ) {
    if (cancelToken == null) return sharedWarmup;
    cancelToken.throwIfCancelled();

    final completer = Completer<void>();
    void onCancel() {
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancelToken.addListener(onCancel);
    sharedWarmup.then(
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_, _) {
        // Warmup failure is non-fatal for playback resolution.
        if (!completer.isCompleted) completer.complete();
      },
    );
    return completer.future.whenComplete(() {
      cancelToken.removeListener(onCancel);
    });
  }

  static String? extractSapisidFromCookie(String cookieHeader) {
    final map = <String, String>{};
    for (final part in cookieHeader.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final name = part.substring(0, idx).trim();
      var value = part.substring(idx + 1).trim();
      if (value.length >= 2 &&
          value.startsWith('"') &&
          value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (name.isNotEmpty && value.isNotEmpty) {
        map[name] = value;
      }
    }
    return map['SAPISID'] ??
        map['__Secure-3PAPISID'] ??
        map['__Secure-1PAPISID'];
  }

  static String computeSapisidHash(
    String sapisid, {
    required int timestampSeconds,
    String origin = defaultMusicOrigin,
  }) {
    final digest = sha1
        .convert(utf8.encode('$timestampSeconds $sapisid $origin'))
        .toString();
    return 'SAPISIDHASH ${timestampSeconds}_$digest';
  }

  static String extractCleanVideoId(String rawId) {
    var candidate = rawId.trim();
    for (final prefix in const <String>[
      'streaming:youtube_music:',
      'youtube_music:',
      'ytm:',
      'ytm_',
    ]) {
      if (candidate.startsWith(prefix)) {
        candidate = candidate.substring(prefix.length).trim();
      }
    }
    if (candidate.contains('youtube.com/') ||
        candidate.contains('youtu.be/') ||
        candidate.contains('music.youtube.com/')) {
      final uri = Uri.tryParse(candidate);
      final vParam = uri?.queryParameters['v']?.trim();
      if (vParam != null && vParam.isNotEmpty) {
        candidate = vParam;
      } else if (uri != null &&
          uri.host.toLowerCase().contains('youtu.be') &&
          uri.pathSegments.isNotEmpty) {
        candidate = uri.pathSegments.last.trim();
      }
    }
    if (!_validVideoIdPattern.hasMatch(candidate)) {
      throw StreamingException('無效的 YouTube Music 影片識別碼：$rawId');
    }
    return candidate;
  }

  @override
  Future<StreamSourceSpec> resolve(
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

    final videoId = extractCleanVideoId(key.trackId);
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
      final fetched = await _probeVisitorDataFromMusicOrigin();
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
      clientVersion: _webRemixClientVersion,
      userAgent: _desktopChromeUserAgent,
      isWebRemix: true,
      isAuthenticated: useWebAuth,
      supportsPlayerPoToken: true,
      context: <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'WEB_REMIX',
          'clientVersion': _webRemixClientVersion,
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

  static bool _hasQueryParam(String url, String name) {
    final value = Uri.tryParse(url)?.queryParameters[name];
    return value != null && value.trim().isNotEmpty;
  }

  static bool _hasUndecryptedNParamAudioFormats(
    Map<String, dynamic> playerJson,
  ) {
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

  static bool _hasCipheredAudioFormats(Map<String, dynamic> playerJson) {
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
            (item['signatureCipher'] ?? item['cipher'])?.toString().trim() ??
            '';
        if (sigCipher.isNotEmpty) return true;
      }
    }
    return false;
  }

  static void _assertNoWebAuthLeakage(
    Map<String, String> headers, {
    String clientName = 'ANDROID_VR',
  }) {
    for (final key in headers.keys) {
      if (_forbiddenAndroidVrHeaders.contains(key.toLowerCase())) {
        throw StateError(
          'Forbidden web auth header "$key" leaked into $clientName request',
        );
      }
    }
  }

  Future<YtmPlayerHttpResponse> _postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();

    if (requestHandler != null) {
      return _awaitWithCancel(
        () => requestHandler!(
          uri: uri,
          headers: headers,
          body: body,
          cancelToken: cancelToken,
        ),
        cancelToken: cancelToken,
      );
    }

    final encoded = utf8.encode(jsonEncode(body));
    HttpClientRequest? activeReq;
    final completer = Completer<YtmPlayerHttpResponse>();
    var aborted = false;

    void onCancel() {
      aborted = true;
      try {
        activeReq?.abort();
      } catch (_) {}
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancelToken?.addListener(onCancel);
    try {
      () async {
        try {
          final req = await _httpClient.openUrl('POST', uri).timeout(
            requestTimeout,
          );
          if (aborted || _disposed) {
            try {
              req.abort();
            } catch (_) {}
            return;
          }
          activeReq = req;
          headers.forEach((k, v) => req.headers.set(k, v));
          req.contentLength = encoded.length;
          req.add(encoded);

          final resp = await req.close().timeout(requestTimeout);
          if (aborted || _disposed) {
            unawaited(resp.drain<void>().catchError((_) {}));
            return;
          }
          final respBody = await utf8.decoder.bind(resp).join().timeout(
            requestTimeout,
          );
          if (!completer.isCompleted) {
            completer.complete(
              YtmPlayerHttpResponse(statusCode: resp.statusCode, body: respBody),
            );
          }
        } on TimeoutException {
          if (!completer.isCompleted) {
            completer.completeError(
              StreamingException('連線逾時（${uri.host}）'),
            );
          }
        } on SocketException catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(
              aborted
                  ? const StreamingException('操作已取消', isCancelled: true)
                  : StreamingException('網路連線失敗：${e.message}'),
            );
          }
        } on HttpException catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(
              aborted
                  ? const StreamingException('操作已取消', isCancelled: true)
                  : StreamingException('HTTP 通訊協定錯誤：${e.message}'),
            );
          }
        } catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(
              aborted
                  ? const StreamingException('操作已取消', isCancelled: true)
                  : StreamingException('網路請求失敗：$e'),
            );
          }
        }
      }();

      return await completer.future;
    } finally {
      cancelToken?.removeListener(onCancel);
    }
  }

  Future<T> _awaitWithCancel<T>(
    Future<T> Function() invoke, {
    CancellationToken? cancelToken,
  }) {
    cancelToken?.throwIfCancelled();
    final completer = Completer<T>();

    void onCancel() {
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancelToken?.addListener(onCancel);
    Future<T>.sync(invoke).then(
      (v) {
        if (!completer.isCompleted) completer.complete(v);
      },
      onError: (Object err, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(err, st);
      },
    );
    return completer.future.timeout(requestTimeout).whenComplete(() {
      cancelToken?.removeListener(onCancel);
    });
  }

  Map<String, String> _cleanClientHeaders(
    _ResidentClientProfile profile, {
    String? visitorData,
  }) {
    final vd = visitorData?.trim();
    final headers = <String, String>{
      'User-Agent': profile.userAgent,
      'X-YouTube-Client-Name': profile.clientNameHeader,
      'X-YouTube-Client-Version': profile.clientVersion,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
      if (vd != null && vd.isNotEmpty) 'X-Goog-Visitor-Id': vd,
    };
    _assertNoWebAuthLeakage(headers, clientName: profile.clientName);
    return headers;
  }

  Map<String, String> _guestWebRemixHeaders({String? visitorData}) {
    final vd = visitorData?.trim();
    return <String, String>{
      'User-Agent': _desktopChromeUserAgent,
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': _webRemixClientVersion,
      'Origin': defaultMusicOrigin,
      'Referer': '$defaultMusicOrigin/',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
      if (vd != null && vd.isNotEmpty) 'X-Goog-Visitor-Id': vd,
    };
  }

  Map<String, String> _webRemixHeaders(
    YtmAuthCredentials auth, {
    String? visitorDataOverride,
  }) {
    final headers = <String, String>{
      'User-Agent': _desktopChromeUserAgent,
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': _webRemixClientVersion,
      'Origin': defaultMusicOrigin,
      'Referer': '$defaultMusicOrigin/',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
    };
    final visitor = (visitorDataOverride ?? auth.visitorData)?.trim();
    if (visitor != null && visitor.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = visitor;
    }
    if ((auth.authMode == 'oauth' || auth.authMode == 'oauth_device') &&
        auth.accessToken != null &&
        auth.accessToken!.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${auth.accessToken!.trim()}';
    } else if (auth.cookie != null && auth.cookie!.trim().isNotEmpty) {
      final cookie = auth.cookie!.trim();
      headers['Cookie'] = cookie;
      final sapisid = extractSapisidFromCookie(cookie);
      if (sapisid != null) {
        final ts = _clock().millisecondsSinceEpoch ~/ 1000;
        headers['Authorization'] = computeSapisidHash(
          sapisid,
          timestampSeconds: ts,
          origin: defaultMusicOrigin,
        );
        headers['X-Origin'] = defaultMusicOrigin;
      }
    }
    return headers;
  }

  /// Format tier ranking: `itag 251` (WebM/Opus 48kHz) strictly preferred first,
  /// followed by `itag 140` (M4A/AAC), then other direct `audio/` formats.
  static int formatPreferenceTier(int itag, String lowerMime) {
    if (itag == 251) return 100;
    if (itag == 140) return 90;
    if (itag == 141) return 80;
    if (itag == 250) return 75;
    if (itag == 249) return 70;
    if (lowerMime.contains('opus') || lowerMime.contains('webm')) return 65;
    if (itag == 139) return 60;
    if (lowerMime.contains('audio/mp4') ||
        lowerMime.contains('mp4a') ||
        lowerMime.contains('aac')) {
      return 55;
    }
    if (lowerMime.contains('flac') ||
        lowerMime.contains('mp3') ||
        lowerMime.contains('mpeg') ||
        lowerMime.contains('vorbis') ||
        lowerMime.contains('wav') ||
        lowerMime.contains('alac')) {
      return 40;
    }
    return 10;
  }

  DirectRangeSpec? _extractPreferredDirectRangeSpec({
    required StreamKey key,
    required Map<String, dynamic> playerJson,
    required _ResidentClientProfile profile,
    PoToken? gvsToken,
  }) {
    final playability = playerJson['playabilityStatus'];
    if (playability is Map) {
      final status = playability['status']?.toString();
      if (status != null && status != 'OK') {
        return null;
      }
    }

    final streamingData = playerJson['streamingData'];
    if (streamingData is! Map) return null;

    final candidates = <Map<String, dynamic>>[];
    for (final listKey in const <String>['adaptiveFormats', 'formats']) {
      final rawList = streamingData[listKey];
      if (rawList is! List) continue;
      for (final item in rawList) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final mime = map['mimeType']?.toString().toLowerCase() ?? '';
        final url = map['url']?.toString().trim() ?? '';
        if (!mime.startsWith('audio/') || url.isEmpty) continue;
        final lowerUrl = url.toLowerCase();
        if (lowerUrl.contains('.m3u8') ||
            lowerUrl.contains('.mpd') ||
            lowerUrl.contains('/hls_playlist/') ||
            lowerUrl.contains('/dash/')) {
          continue;
        }
        // Reject undecrypted `n`-parameter URLs on WEB_REMIX so they never
        // cause CDN throttling or HTTP 403 and cleanly fall through to yt-dlp + deno.
        if (profile.isWebRemix && _hasQueryParam(url, 'n')) {
          continue;
        }
        candidates.add(map);
      }
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final itagA = _parseInt(a['itag']) ?? -1;
      final itagB = _parseInt(b['itag']) ?? -1;
      final mimeA = a['mimeType']?.toString().toLowerCase() ?? '';
      final mimeB = b['mimeType']?.toString().toLowerCase() ?? '';
      final tierA = formatPreferenceTier(itagA, mimeA);
      final tierB = formatPreferenceTier(itagB, mimeB);
      if (tierA != tierB) return tierB.compareTo(tierA);

      final bitA = _parseInt(a['bitrate']) ?? _parseInt(a['averageBitrate']) ?? 0;
      final bitB = _parseInt(b['bitrate']) ?? _parseInt(b['averageBitrate']) ?? 0;
      return bitB.compareTo(bitA);
    });

    final best = candidates.first;
    final url = best['url']!.toString().trim();
    final itag = _parseInt(best['itag']) ?? -1;
    final rawMime = best['mimeType']?.toString().trim() ?? '';
    final lowerMime = rawMime.toLowerCase();

    final AudioCodec codec;
    final String hintExt;
    if (itag == 251 ||
        itag == 250 ||
        itag == 249 ||
        lowerMime.contains('opus') ||
        lowerMime.contains('webm')) {
      codec = AudioCodec.opus;
      hintExt = 'webm';
    } else if (lowerMime.contains('flac')) {
      codec = AudioCodec.flac;
      hintExt = 'flac';
    } else if (lowerMime.contains('mp3') || lowerMime.contains('mpeg')) {
      codec = AudioCodec.mp3;
      hintExt = 'mp3';
    } else if (lowerMime.contains('vorbis') || lowerMime.contains('ogg')) {
      codec = AudioCodec.opus;
      hintExt = 'ogg';
    } else if (lowerMime.contains('wav')) {
      codec = AudioCodec.wav;
      hintExt = 'wav';
    } else {
      codec = AudioCodec.aac;
      hintExt = 'm4a';
    }

    final contentLength = _parseInt(best['contentLength']);
    final bitrateBps =
        _parseInt(best['bitrate']) ?? _parseInt(best['averageBitrate']);
    final sampleRate = _parseInt(best['audioSampleRate']) ??
        (codec == AudioCodec.opus ? 48000 : 44100);
    final channels = _parseInt(best['audioChannels']) ?? 2;

    final initRange = best['initRange'];
    final indexRange = best['indexRange'];
    final initRangeEnd =
        initRange is Map ? _parseInt(initRange['end']) : null;
    final indexRangeStart =
        indexRange is Map ? _parseInt(indexRange['start']) : null;
    final indexRangeEnd =
        indexRange is Map ? _parseInt(indexRange['end']) : null;

    var finalUrl = url;
    final parsedUri = Uri.tryParse(url);
    if (gvsToken != null && gvsToken.token.isNotEmpty) {
      finalUrl = appendPotQueryParam(finalUrl, gvsToken.token);
    }

    final urlExpire = _parseInt(parsedUri?.queryParameters['expire']);
    final expiresInSec = _parseInt(streamingData['expiresInSeconds']);
    final nowSec = _clock().millisecondsSinceEpoch ~/ 1000;
    final expireAt = urlExpire ??
        (expiresInSec != null && expiresInSec > 0 ? nowSec + expiresInSec : null);

    final playbackHeaders = <String, String>{
      'User-Agent': profile.userAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
      if (profile.isWebRemix) ...<String, String>{
        'Origin': defaultMusicOrigin,
        'Referer': '$defaultMusicOrigin/',
      },
    };

    NormalizedLoudness? loudness;
    final playerConfig = playerJson['playerConfig'];
    if (playerConfig is Map) {
      final audioConfig = playerConfig['audioConfig'];
      if (audioConfig is Map) {
        final rawLoudness = audioConfig['loudnessDb'];
        final parsedLoudness = rawLoudness is num
            ? rawLoudness.toDouble()
            : (rawLoudness is String
                  ? double.tryParse(rawLoudness.trim())
                  : null);
        if (parsedLoudness != null && parsedLoudness.isFinite) {
          loudness = NormalizedLoudness.fromYtmLoudnessDb(parsedLoudness);
        }
      }
    }

    final resolvedMime = rawMime.isNotEmpty
        ? rawMime
        : switch (hintExt) {
            'webm' => 'audio/webm; codecs="opus"',
            'mp3' => 'audio/mpeg',
            'ogg' => 'audio/ogg',
            'flac' => 'audio/flac',
            'wav' => 'audio/wav',
            _ => 'audio/mp4',
          };

    return DirectRangeSpec(
      key: key,
      url: finalUrl,
      headers: playbackHeaders,
      contentLength: contentLength,
      bitrateBps: bitrateBps,
      mimeType: resolvedMime,
      hintExtension: hintExt,
      expireAt: expireAt,
      initRangeEnd: initRangeEnd,
      indexRangeStart: indexRangeStart,
      indexRangeEnd: indexRangeEnd,
      loudness: loudness,
      audioFormat: AudioFormat(
        codec: codec,
        sampleRateHz: sampleRate,
        bitDepth: 16,
        channels: channels,
      ),
    );
  }

  /// Appends `pot=<token>` to [url] via raw-string concatenation so signed
  /// YouTube CDN query parameters are never re-encoded or reordered.
  static String appendPotQueryParam(String url, String potToken) {
    final trimmedUrl = url.trim();
    final trimmedPot = potToken.trim();
    if (trimmedUrl.isEmpty || trimmedPot.isEmpty) return trimmedUrl;
    final parsedUri = Uri.tryParse(trimmedUrl);
    if (parsedUri == null || parsedUri.queryParameters.containsKey('pot')) {
      return trimmedUrl;
    }
    final hashIdx = trimmedUrl.indexOf('#');
    final base = hashIdx >= 0 ? trimmedUrl.substring(0, hashIdx) : trimmedUrl;
    final fragment = hashIdx >= 0 ? trimmedUrl.substring(hashIdx) : '';
    final sep = base.contains('?')
        ? ((base.endsWith('?') || base.endsWith('&')) ? '' : '&')
        : '?';
    return '$base${sep}pot=${Uri.encodeQueryComponent(trimmedPot)}$fragment';
  }

  static int? _parseInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// Gracefully disposes the resident HTTP client and awaits PO Token sidecar
  /// shutdown (`SIGTERM` + grace timeout -> `SIGKILL`).
  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    _warmupFuture = null;
    if (_ownsPotProvider && _potProvider != null) {
      await _potProvider.dispose();
    }
    if (_ownsHttpClient) {
      try {
        _httpClient.close(force: true);
      } catch (_) {}
    }
  }

  void dispose() {
    unawaited(disposeAsync());
  }
}
