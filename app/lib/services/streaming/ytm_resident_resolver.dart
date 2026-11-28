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

part 'ytm_resident/models.dart';
part 'ytm_resident/warmup.dart';
part 'ytm_resident/resolve_flow.dart';
part 'ytm_resident/transport.dart';
part 'ytm_resident/format_selector.dart';

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

  static String? extractSapisidFromCookie(String cookieHeader) =>
      _extractSapisidFromCookie(cookieHeader);

  static String computeSapisidHash(
    String sapisid, {
    required int timestampSeconds,
    String origin = defaultMusicOrigin,
  }) =>
      _computeSapisidHash(
        sapisid,
        timestampSeconds: timestampSeconds,
        origin: origin,
      );

  static String extractCleanVideoId(String rawId) =>
      _extractCleanVideoId(rawId);

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) =>
      _resolveImpl(key, cancelToken: cancelToken);

  /// Format tier ranking: `itag 251` (WebM/Opus 48kHz) strictly preferred first,
  /// followed by `itag 140` (M4A/AAC), then other direct `audio/` formats.
  static int formatPreferenceTier(int itag, String lowerMime) =>
      _formatPreferenceTier(itag, lowerMime);

  /// Appends `pot=<token>` to [url] via raw-string concatenation so signed
  /// YouTube CDN query parameters are never re-encoded or reordered.
  static String appendPotQueryParam(String url, String potToken) =>
      _appendPotQueryParam(url, potToken);

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
