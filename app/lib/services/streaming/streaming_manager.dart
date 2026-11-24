import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/podcast_models.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import 'auth_manager.dart';
import 'l1_stream_cache.dart';
import 'local_browser_auth_service.dart';
import 'pot_provider.dart';
import 'pot_sidecar_manager.dart';
import 'providers/apple_music_provider.dart';
import 'providers/deezer_provider.dart';
import 'providers/qobuz_provider.dart';
import 'providers/tidal_provider.dart';
import 'providers/youtube_music_provider.dart';
import 'secure_credential_store.dart';
import 'single_flight_resolver.dart';
import 'stream_resolver.dart';
import 'streaming_provider.dart';
import 'webview_auth_service.dart';
import 'yt_dlp_service.dart';

/// Central coordinator for all 5 real streaming providers, encrypted DPAPI
/// credential restoration, cancellable login lifecycles, and stream resolution.
class StreamingManager extends ChangeNotifier {
  static const List<String> providerOrder = <String>[
    'apple_music',
    'youtube_music',
    'qobuz',
    'tidal',
    'deezer',
  ];

  final SecureCredentialStore credentialStore;
  final Map<String, StreamingProvider> _providers;
  final StreamResolverRegistry resolverRegistry = StreamResolverRegistry();
  late final L1StreamCache l1Cache;
  late final SingleFlightResolver singleFlightResolver;
  late final AuthManager authManager;
  final Future<void> Function()? _waitDbReady;
  final VoidCallback? _onHttp2Warmup;
  final bool _enableLiveWarmup;
  final WebViewAuthService _webViewAuthService;
  final YtDlpService ytDlpService;
  final File? recommendationsCacheFile;
  final Duration recommendationsCacheTtl;
  final DateTime Function() _clock;
  final void Function(String message)? logSink;
  final Map<String, CancellationToken> _activeCancellations =
      <String, CancellationToken>{};
  final Set<String> _activeWebViewKinds = <String>{};
  final Map<String, String> _progressMessages = <String, String>{};

  final Map<String, StreamingRecommendations> _recommendations =
      <String, StreamingRecommendations>{};
  final Set<String> _loadingRecommendations = <String>{};
  final Map<String, String> _recommendationErrors = <String, String>{};
  final Map<String, bool> _recommendationTokenExpired = <String, bool>{};
  final Map<String, CancellationToken> _recommendationCancellations =
      <String, CancellationToken>{};
  final Map<String, int> _recommendationBatchIndex = <String, int>{};
  final Map<String, List<String>> _seenRecommendationAlbumIds =
      <String, List<String>>{};
  final Map<String, List<String>> _seenRecommendationTrackIds =
      <String, List<String>>{};
  static const int _maxSeenRecommendationIds = 120;

  bool _initialized = false;
  bool _warmedUp = false;
  Future<void>? _warmupFuture;
  bool _disposed = false;

  StreamingManager({
    SecureCredentialStore? credentialStore,
    Map<String, StreamingProvider>? providers,
    HttpClient Function()? httpClientFactory,
    WebViewAuthService? webViewAuthService,
    YtDlpService? ytDlpService,
    File? recommendationsCacheFile,
    this.recommendationsCacheTtl = const Duration(minutes: 20),
    DateTime Function()? clock,
    this.logSink,
    L1StreamCache? l1Cache,
    L1StreamCachePersistence? l1CachePersistence,
    this._waitDbReady,
    PotProvider? ytmPotProvider,
    SidecarLifecycleBinder? sidecarLifecycleBinder,
    this._onHttp2Warmup,
    bool? enableLiveWarmup,
  })  : credentialStore = credentialStore ?? WindowsDpapiCredentialStore(),
        _providers = <String, StreamingProvider>{},
        _enableLiveWarmup = enableLiveWarmup ??
            (!Platform.environment.containsKey('FLUTTER_TEST') ||
                ytmPotProvider != null),
        _webViewAuthService =
            webViewAuthService ?? LocalBrowserAuthService(),
        ytDlpService = ytDlpService ?? YtDlpService.instance,
        recommendationsCacheFile =
            recommendationsCacheFile ?? _defaultRecommendationsCacheFile(),
        _clock = clock ?? DateTime.now {
    this.l1Cache = l1Cache ??
        L1StreamCache(
          persistence: l1CachePersistence,
          clock: _clock,
        );
    singleFlightResolver = SingleFlightResolver(
      registry: resolverRegistry,
      l1Cache: this.l1Cache,
    );
    authManager = AuthManager(
      providerLookup: (id) => _providers[id],
      l1Cache: this.l1Cache,
      singleFlightResolver: singleFlightResolver,
      onStateChanged: _safeNotify,
    );
    singleFlightResolver.attachAuthManager(authManager);

    final store = this.credentialStore;
    final bool shouldCreateDefaultPot =
        ytmPotProvider == null &&
        (_enableLiveWarmup || sidecarLifecycleBinder != null);
    final PotProvider? resolvedYtmPotProvider = ytmPotProvider ??
        (shouldCreateDefaultPot
            ? HttpPotProvider(
                sidecarManager: PotSidecarManager(
                  lifecycleBinder: sidecarLifecycleBinder,
                  clock: _clock,
                ),
                ownsSidecarManager: true,
                clock: _clock,
              )
            : null);

    final defaults = <String, StreamingProvider>{
      'apple_music': AppleMusicProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
      ),
      'youtube_music': YouTubeMusicProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
        ytDlpService: this.ytDlpService,
        potProvider: resolvedYtmPotProvider,
        ownsPotProvider: ytmPotProvider == null && resolvedYtmPotProvider != null,
      ),
      'qobuz': QobuzProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
      ),
      'tidal': TidalProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
        ytDlpService: this.ytDlpService,
      ),
      'deezer': DeezerProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
      ),
    };

    for (final kind in providerOrder) {
      _providers[kind] = providers?[kind] ?? defaults[kind]!;
    }
    if (providers != null) {
      for (final entry in providers.entries) {
        _providers.putIfAbsent(entry.key, () => entry.value);
      }
    }

    // If caller supplied a custom youtube_music provider, ensure we don't leak
    // an unowned default YouTubeMusicProvider's resources.
    if (providers != null && providers.containsKey('youtube_music')) {
      final unusedDefaultYtm = defaults['youtube_music'];
      if (unusedDefaultYtm is YouTubeMusicProvider) {
        unusedDefaultYtm.dispose();
      }
    }

    _registerResolvers();
  }

  void _registerResolvers() {
    const prefixMappings = <String, List<String>>{
      'apple_music': <String>['apple:', 'streaming:apple_music:', 'apple_music:'],
      'youtube_music': <String>[
        'streaming:youtube_music:',
        'youtube_music:',
        'ytm:',
        'ytm_',
      ],
      'qobuz': <String>['qobuz:', 'streaming:qobuz:'],
      'tidal': <String>['tidal:', 'streaming:tidal:'],
      'deezer': <String>['deezer:', 'streaming:deezer:'],
    };
    const providerNameMappings = <String, List<String>>{
      'apple_music': <String>['apple music'],
      'youtube_music': <String>['youtube music', 'podcast'],
      'qobuz': <String>['qobuz', 'qobuz hi-res'],
      'tidal': <String>['tidal'],
      'deezer': <String>['deezer'],
    };

    for (final entry in _providers.entries) {
      final kind = entry.key;
      final provider = entry.value;
      final resolver = provider is StreamResolver
          ? (provider as StreamResolver)
          : LegacyStreamingProviderResolver(provider);

      String Function(TrackInfo track)? idExtractor;
      if (kind == 'youtube_music') {
        idExtractor = (track) {
          final clean = YouTubeMusicProvider.tryExtractCleanVideoId(
            track.id,
            filePath: track.filePath,
          );
          if (clean != null && clean.isNotEmpty) return clean;
          var raw = track.id.trim();
          for (final p in prefixMappings['youtube_music']!) {
            if (raw.startsWith(p)) {
              raw = raw.substring(p.length).trim();
              break;
            }
          }
          return raw;
        };
      }

      resolverRegistry.register(
        resolver,
        idPrefixes: prefixMappings[kind] ?? const <String>[],
        providerNames: providerNameMappings[kind] ?? <String>[provider.meta.name],
        trackIdExtractor: idExtractor,
      );
    }

    resolverRegistry.register(
      const ExternalPodcastRssResolver(),
      idPrefixes: const <String>[
        'streaming:podcast_rss:',
        'podcast_rss:',
        'rss:',
        'http://',
        'https://',
      ],
      stripMatchedPrefix: false,
      trackIdExtractor: (track) =>
          ExternalPodcastRssResolver.extractUrl(track.id),
    );
  }

  bool get isInitialized => _initialized;

  bool get isWarmedUp => _warmedUp;

  /// Idempotent startup warmup (`SharedFuture`): hydrates the SQLite WAL L1
  /// direct-URL / manifest cache into memory and asynchronously pre-warms
  /// Rust HTTP/2 + YouTube Music InnerTube session & GVS PO Token.
  Future<void> warmup({bool force = false}) {
    if (_disposed) return Future<void>.value();
    if (!force && _warmedUp) return Future<void>.value();
    final inFlight = _warmupFuture;
    if (!force && inFlight != null) return inFlight;

    final future = _doWarmup(force: force);
    _warmupFuture = future;
    return future.whenComplete(() {
      if (identical(_warmupFuture, future)) {
        _warmupFuture = null;
      }
    });
  }

  Future<void> _doWarmup({required bool force}) async {
    final waitDb = _waitDbReady;
    if (waitDb != null) {
      try {
        await waitDb();
      } catch (_) {}
    }

    try {
      await l1Cache.hydrate();
    } catch (_) {}

    if (_disposed) return;

    if (_enableLiveWarmup) {
      try {
        _onHttp2Warmup?.call();
      } catch (_) {}

      final ytm = youTubeMusicProvider;
      if (ytm != null) {
        try {
          await ytm.warmup(force: force);
        } catch (_) {}
      }
    }

    _warmedUp = true;
  }

  List<StreamingProvider> get providers =>
      List<StreamingProvider>.unmodifiable(_providers.values);

  List<StreamingProvider> get connectedProviders => _providers.values
      .where((p) => p.authState == StreamingAuthState.connected)
      .toList(growable: false);

  List<StreamingProvider> get browsableProviders => _providers.values
      .where(_isBrowsable)
      .toList(growable: false);

  bool _isBrowsable(StreamingProvider? provider) =>
      provider != null &&
      (provider.authState == StreamingAuthState.connected ||
          provider.supportsGuestMode);

  StreamingProvider? providerFor(String kind) => _providers[kind];

  bool isAuthenticating(String kind) =>
      _activeCancellations.containsKey(kind) ||
      _providers[kind]?.authState == StreamingAuthState.authenticating;

  bool isAuthRequired(String kind) => authManager.isAuthRequired(kind);

  bool isPlaybackAuthBlocked(String kind) =>
      authManager.isPlaybackAuthBlocked(kind);

  String? authErrorFor(String kind) => authManager.authErrorFor(kind);

  void addAuthRequiredListener(ProviderAuthRequiredCallback listener) =>
      authManager.addAuthRequiredListener(listener);

  void removeAuthRequiredListener(ProviderAuthRequiredCallback listener) =>
      authManager.removeAuthRequiredListener(listener);

  /// Handles a network interface / IP transition (`network_epoch` bump from
  /// Rust `NetworkMonitor`). Advances `L1StreamCache` epoch (invalidating only
  /// `needsNetworkEpochReset == true` providers like YouTube Music while
  /// preserving Qobuz/Tidal/Deezer), drops stale YTM resident sockets, clears
  /// YTM session `visitorData` & GVS PO Token, and triggers async re-warmup.
  void handleNetworkEpochChanged(int newEpoch) {
    if (_disposed) return;
    final previous = l1Cache.networkEpoch;
    final updated = l1Cache.syncNetworkEpoch(newEpoch);
    if (updated == previous) return;

    final ytm = youTubeMusicProvider;
    if (ytm != null) {
      ytm.handleNetworkEpochChanged();
      if (_enableLiveWarmup) {
        unawaited(ytm.warmup(force: true).catchError((_) {}));
      }
    }
  }

  /// Phase 3 HTTP 403/410 CAS URL recovery entry point.
  Future<RefreshAfter403Result> refreshAfter403(
    StreamKey key, {
    required String failedUrl,
    int? expectedContentLength,
    String? expectedMimeType,
    String? expectedStreamKind,
    AudioFormat? expectedAudioFormat,
    int? expectedInitRangeEnd,
    bool allowFormatChange = false,
    CancellationToken? cancelToken,
    TrackInfo? legacyTrack,
  }) {
    return singleFlightResolver.refreshAfter403(
      key,
      failedUrl: failedUrl,
      expectedContentLength: expectedContentLength,
      expectedMimeType: expectedMimeType,
      expectedStreamKind: expectedStreamKind,
      expectedAudioFormat: expectedAudioFormat,
      expectedInitRangeEnd: expectedInitRangeEnd,
      allowFormatChange: allowFormatChange,
      cancelToken: cancelToken,
      legacyTrack: legacyTrack,
    );
  }

  String? progressMessageFor(String kind) => _progressMessages[kind];

  StreamingRecommendations? recommendationsFor(String kind) =>
      _recommendations[kind];

  bool isLoadingRecommendations(String kind) =>
      _loadingRecommendations.contains(kind);

  bool hasManualRecommendationRefresh(String kind) =>
      (_recommendationBatchIndex[kind] ?? 0) > 0;

  bool get isAnyRecommendationLoading => _loadingRecommendations.isNotEmpty;

  String? recommendationErrorFor(String kind) =>
      _recommendationErrors[kind] ?? _recommendations[kind]?.errorMessage;

  bool isRecommendationTokenExpired(String kind) =>
      _recommendationTokenExpired[kind] == true ||
      (_recommendations[kind]?.isTokenExpired == true);

  Map<String, String> get recommendationErrors =>
      Map<String, String>.unmodifiable(_recommendationErrors);

  List<StreamingAlbum> allRecommendedAlbums({String? filterKind}) {
    if (filterKind != null &&
        filterKind.isNotEmpty &&
        filterKind != 'all') {
      return List<StreamingAlbum>.unmodifiable(
        _recommendations[filterKind]?.albums ?? const <StreamingAlbum>[],
      );
    }
    final lists = <List<StreamingAlbum>>[];
    for (final kind in providerOrder) {
      final p = _providers[kind];
      if (!_isBrowsable(p)) continue;
      final albums = _recommendations[kind]?.albums;
      if (albums != null && albums.isNotEmpty) {
        lists.add(albums);
      }
    }
    if (lists.isEmpty) return const <StreamingAlbum>[];
    final interleaved = <StreamingAlbum>[];
    var index = 0;
    while (true) {
      var added = false;
      for (final list in lists) {
        if (index < list.length) {
          interleaved.add(list[index]);
          added = true;
        }
      }
      if (!added) break;
      index++;
    }
    return interleaved;
  }

  List<TrackInfo> allRecommendedTracks({String? filterKind}) {
    if (filterKind != null &&
        filterKind.isNotEmpty &&
        filterKind != 'all') {
      return List<TrackInfo>.unmodifiable(
        _recommendations[filterKind]?.tracks ?? const <TrackInfo>[],
      );
    }
    final lists = <List<TrackInfo>>[];
    for (final kind in providerOrder) {
      final p = _providers[kind];
      if (!_isBrowsable(p)) continue;
      final tracks = _recommendations[kind]?.tracks;
      if (tracks != null && tracks.isNotEmpty) {
        lists.add(tracks);
      }
    }
    if (lists.isEmpty) return const <TrackInfo>[];
    final interleaved = <TrackInfo>[];
    var index = 0;
    while (true) {
      var added = false;
      for (final list in lists) {
        if (index < list.length) {
          interleaved.add(list[index]);
          added = true;
        }
      }
      if (!added) break;
      index++;
    }
    return interleaved;
  }

  static File? _defaultRecommendationsCacheFile() {
    if (!Platform.isWindows) return null;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) return null;
    return File(
      '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}streaming_recommendations_cache.json',
    );
  }

  static bool _hasAnyTrackCover(StreamingRecommendations rec) {
    if (rec.tracks.isEmpty) return true;
    return rec.tracks.any(
      (t) =>
          (t.coverUrl != null && t.coverUrl!.trim().isNotEmpty) ||
          (t.albumArtUrl != null && t.albumArtUrl!.trim().isNotEmpty),
    );
  }

  bool _isRecommendationCacheFresh(StreamingRecommendations? rec) {
    if (rec == null || rec.isEmpty || rec.hasError) return false;
    if (!_hasAnyTrackCover(rec)) return false;
    final age = _clock().difference(rec.fetchedAt);
    return !age.isNegative && age < recommendationsCacheTtl;
  }

  void _hydrateRecommendationsCacheSync() {
    final file = recommendationsCacheFile;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final providersMap = decoded['providers'] is Map
          ? Map<String, dynamic>.from(decoded['providers'] as Map)
          : Map<String, dynamic>.from(decoded);
      for (final kind in providerOrder) {
        final provider = _providers[kind];
        if (!_isBrowsable(provider)) continue;
        final entry = providersMap[kind];
        if (entry is Map) {
          final rec = StreamingRecommendations.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (_isRecommendationCacheFresh(rec)) {
            _recommendations[kind] = rec;
          }
        }
      }
    } catch (_) {
      // Ignore corrupted cache file and refresh from live API.
    }
  }

  void _persistRecommendationsCacheSync() {
    final file = recommendationsCacheFile;
    if (file == null) return;
    try {
      final providersJson = <String, dynamic>{};
      for (final entry in _recommendations.entries) {
        final p = _providers[entry.key];
        if (_isBrowsable(p) &&
            !entry.value.isEmpty &&
            !entry.value.hasError) {
          providersJson[entry.key] = entry.value.toJson();
        }
      }
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'updated_at': _clock().toUtc().toIso8601String(),
          'providers': providersJson,
        }),
      );
    } catch (_) {}
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Restores persisted DPAPI credentials across all providers in parallel and
  /// validates them live. Expired or revoked tokens gracefully enter `error` state.
  Future<void> initialize() async {
    await Future.wait(
      _providers.values.map((provider) async {
        try {
          await provider.restoreFromStorage();
        } catch (_) {
          // Provider already transitioned to StreamingAuthState.error with lastError.
        }
      }),
    );
    youTubeMusicProvider?.onAuthSessionRestored();
    _hydrateRecommendationsCacheSync();
    _initialized = true;
    _safeNotify();

    for (final provider in browsableProviders) {
      if (!_isRecommendationCacheFresh(_recommendations[provider.kind])) {
        unawaited(refreshRecommendationsFor(provider.kind, force: false));
      }
    }
  }

  Future<void> authenticateProvider(
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

  DetectedDefaultBrowser? detectLocalDefaultBrowser() {
    final svc = _webViewAuthService;
    if (svc is LocalBrowserAuthService) {
      return svc.resolveDetectedBrowser();
    }
    return null;
  }

  Future<bool> isLocalBrowserAuthAvailable() =>
      _webViewAuthService.isWebView2Available();

  Future<bool> isWebViewAuthAvailable() => isLocalBrowserAuthAvailable();

  Future<void> authenticateWithWebView(
    String kind, {
    bool clearSession = false,
    Map<String, dynamic>? fallbackParams,
    void Function(String statusMsg)? onProgress,
  }) =>
      authenticateWithLocalBrowser(
        kind,
        clearSession: clearSession,
        fallbackParams: fallbackParams,
        onProgress: onProgress,
      );

  Future<void> authenticateWithLocalBrowser(
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

  static bool _isBrowserLaunchOrUnavailableError(String msg) {
    return msg.contains('未偵測到可用的本地瀏覽器') ||
        msg.contains('無法啟動本地瀏覽器') ||
        msg.contains('CDP') ||
        msg.contains('WebView2Loader.dll not available') ||
        msg.contains('Failed to initialize WebView2 runtime');
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

  void cancelLogin(String kind) {
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

  Future<void> logoutProvider(String kind) async {
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

  void _recordSeenIds(
    Map<String, List<String>> store,
    String kind,
    Iterable<String> ids,
  ) {
    final list = store.putIfAbsent(kind, () => <String>[]);
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isEmpty) continue;
      list.remove(id);
      list.add(id);
    }
    if (list.length > _maxSeenRecommendationIds) {
      list.removeRange(0, list.length - _maxSeenRecommendationIds);
    }
  }

  Future<StreamingRecommendations> refreshRecommendationsFor(
    String kind, {
    bool force = false,
  }) async {
    final provider = _providers[kind];
    if (provider == null || !_isBrowsable(provider)) {
      return StreamingRecommendations.empty(kind);
    }
    if (!force && authManager.isAuthRequired(kind)) {
      return _recommendations[kind] ?? StreamingRecommendations.empty(kind);
    }

    if (!force && _isRecommendationCacheFresh(_recommendations[kind])) {
      return _recommendations[kind]!;
    }

    if (force) {
      final previous = _recommendations.remove(kind);
      if (previous != null) {
        _recordSeenIds(
          _seenRecommendationAlbumIds,
          kind,
          previous.albums.map((a) => a.id),
        );
        _recordSeenIds(
          _seenRecommendationTrackIds,
          kind,
          previous.tracks.map((t) => t.id),
        );
      }
      _recommendationBatchIndex[kind] =
          (_recommendationBatchIndex[kind] ?? 0) + 1;
      _persistRecommendationsCacheSync();
    }

    _recommendationCancellations[kind]?.cancel();
    final token = CancellationToken();
    _recommendationCancellations[kind] = token;
    _loadingRecommendations.add(kind);
    _recommendationErrors.remove(kind);
    _recommendationTokenExpired.remove(kind);
    _safeNotify();

    final batchIndex = _recommendationBatchIndex[kind] ?? 0;
    final excludeAlbumIds = Set<String>.unmodifiable(
      _seenRecommendationAlbumIds[kind] ?? const <String>[],
    );
    final excludeTrackIds = Set<String>.unmodifiable(
      _seenRecommendationTrackIds[kind] ?? const <String>[],
    );

    try {
      StreamingRecommendations rec;
      try {
        rec = await provider.fetchRecommendations(
          cancel: token,
          forceRefresh: force,
          batchIndex: batchIndex,
          excludeAlbumIds: excludeAlbumIds,
          excludeTrackIds: excludeTrackIds,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            await authManager.refreshTokenSingleFlight(kind)) {
          if (_disposed || token.isCancelled) {
            return _recommendations[kind] ??
                StreamingRecommendations.empty(kind);
          }
          rec = await provider.fetchRecommendations(
            cancel: token,
            forceRefresh: force,
            batchIndex: batchIndex,
            excludeAlbumIds: excludeAlbumIds,
            excludeTrackIds: excludeTrackIds,
          );
        } else {
          rethrow;
        }
      }
      if (_disposed || token.isCancelled) {
        return _recommendations[kind] ?? StreamingRecommendations.empty(kind);
      }
      final freshRec = StreamingRecommendations(
        providerKind: kind,
        albums: List<StreamingAlbum>.of(rec.albums),
        tracks: List<TrackInfo>.of(rec.tracks),
        fetchedAt: _clock(),
        errorMessage: rec.errorMessage,
        isTokenExpired: rec.isTokenExpired,
      );
      _recommendations[kind] = freshRec;
      _recommendationErrors.remove(kind);
      _recommendationTokenExpired[kind] = false;
      _persistRecommendationsCacheSync();
      return freshRec;
    } on StreamingException catch (e) {
      if (e.isCancelled) {
        return _recommendations[kind] ?? StreamingRecommendations.empty(kind);
      }
      final expired = e.isTokenExpired || e.statusCode == 401;
      _recommendationErrors[kind] = e.message;
      _recommendationTokenExpired[kind] = expired;
      final prev = _recommendations[kind];
      _recommendations[kind] =
          (prev ?? StreamingRecommendations.empty(kind)).copyWith(
            errorMessage: e.message,
            isTokenExpired: expired,
          );
      return _recommendations[kind]!;
    } catch (e) {
      final msg = e.toString();
      _recommendationErrors[kind] = msg;
      final prev = _recommendations[kind];
      _recommendations[kind] =
          (prev ?? StreamingRecommendations.empty(kind)).copyWith(
            errorMessage: msg,
          );
      return _recommendations[kind]!;
    } finally {
      if (identical(_recommendationCancellations[kind], token)) {
        _recommendationCancellations.remove(kind);
        _loadingRecommendations.remove(kind);
      }
      _safeNotify();
    }
  }

  Future<void> refreshAllRecommendations({bool force = false}) async {
    final browsable = browsableProviders;
    if (browsable.isEmpty) return;
    await Future.wait(
      browsable.map(
        (p) => refreshRecommendationsFor(p.kind, force: force),
      ),
    );
  }

  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String kind,
    String albumId, {
    CancellationToken? cancel,
  }) async {
    final provider = _providers[kind];
    if (provider == null) return null;
    return provider.fetchAlbumDetail(albumId, cancel: cancel);
  }

  Future<StreamingCatalog> syncProvider(
    String kind, {
    CancellationToken? cancel,
  }) async {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }
    var retriedAuth = false;
    while (true) {
      try {
        final catalog = await provider.syncLibrary(cancel: cancel);
        _safeNotify();
        return catalog;
      } on StreamingException catch (e) {
        if (!e.isCancelled && AuthManager.isUnauthorizedError(e)) {
          final refreshed = await authManager.handleUnauthorized(
            kind,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            continue;
          }
        }
        _safeNotify();
        rethrow;
      } catch (_) {
        _safeNotify();
        rethrow;
      }
    }
  }

  Future<List<TrackInfo>> fetchPlaylistTracks(
    String kind,
    String playlistId,
  ) {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }
    return provider.fetchPlaylistTracks(playlistId);
  }

  Future<StreamingCatalog> searchProvider(
    String kind,
    String query, {
    CancellationToken? cancel,
  }) {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }
    return provider.search(query, cancel: cancel);
  }

  StreamingProvider? resolveProviderForTrack(TrackInfo track) {
    for (final kind in providerOrder) {
      final meta = StreamingProviderMeta.byKind(kind);
      if (meta != null && meta.matchesTrackProvider(track.providerName)) {
        return _providers[kind];
      }
    }
    final id = track.id;
    if (id.startsWith('apple:')) return _providers['apple_music'];
    final isExternalRss = id.startsWith('podcast_rss:') ||
        id.startsWith('streaming:podcast_rss:') ||
        id.startsWith('rss:') ||
        id.startsWith('http://') ||
        id.startsWith('https://');
    if (isExternalRss) {
      return null;
    }
    if (id.startsWith('ytm:') ||
        id.startsWith('ytm_') ||
        id.startsWith('streaming:youtube_music:') ||
        id.startsWith('youtube_music:') ||
        track.providerName == 'Podcast') {
      return _providers['youtube_music'];
    }
    if (id.startsWith('qobuz:')) return _providers['qobuz'];
    if (id.startsWith('tidal:')) return _providers['tidal'];
    if (id.startsWith('deezer:')) return _providers['deezer'];
    return null;
  }

  // ─── Stage 4: YouTube Music Podcast Forwarding ─────────────────────────────

  bool get isYouTubeMusicConnected =>
      _providers['youtube_music']?.authState == StreamingAuthState.connected;

  YouTubeMusicProvider? get youTubeMusicProvider {
    final p = _providers['youtube_music'];
    return p is YouTubeMusicProvider ? p : null;
  }

  Future<PodcastLibraryResult> fetchMyPodcasts({
    CancellationToken? cancel,
  }) async {
    final ytm = youTubeMusicProvider;
    if (ytm == null) return const PodcastLibraryResult();
    return ytm.fetchMyPodcasts(cancel: cancel);
  }

  Future<PodcastExploreResult> fetchExplorePodcasts({
    String? continuation,
    CancellationToken? cancel,
  }) async {
    final ytm = youTubeMusicProvider;
    if (ytm == null) return const PodcastExploreResult();
    return ytm.fetchExplorePodcasts(
      continuation: continuation,
      cancel: cancel,
    );
  }

  Future<PodcastSearchResult> searchPodcasts(
    String query, {
    CancellationToken? cancel,
  }) async {
    final ytm = youTubeMusicProvider;
    if (ytm == null) return const PodcastSearchResult();
    return ytm.searchPodcasts(query, cancel: cancel);
  }

  Future<PodcastShowDetail> fetchPodcastShowDetail(
    String showBrowseId, {
    String? continuation,
    CancellationToken? cancel,
  }) async {
    final ytm = youTubeMusicProvider;
    if (ytm == null) {
      throw const StreamingException('YouTube Music 提供者尚未初始化');
    }
    return ytm.fetchPodcastShowDetail(
      showBrowseId,
      continuation: continuation,
      cancel: cancel,
    );
  }

  /// Clears any cached stream URL for [track] across the L1 cache, owning
  /// provider, and `YtDlpService` (used on HTTP 403 retry before re-resolving fresh).
  void clearStreamCache(TrackInfo track) {
    try {
      final key = resolverRegistry.deriveKey(track);
      l1Cache.evictTrack(key.providerId, key.trackId);
    } catch (_) {}
    final provider = resolveProviderForTrack(track);
    if (provider is YouTubeMusicProvider) {
      provider.clearStreamCache(track.id);
    }
    final vid = YouTubeMusicProvider.tryExtractCleanVideoId(
      track.id,
      filePath: track.filePath,
    );
    if (vid != null) {
      ytDlpService.clearCache(vid);
    }
  }

  /// Non-blocking O(1) lookup against the in-memory L1 direct-URL / manifest cache.
  StreamSourceSpec? peekCachedSpec(StreamKey key) =>
      singleFlightResolver.peekCached(key);

  /// Resolves [key] through the multi-platform L1 cache and cross-platform
  /// Single-Flight deduplicator.
  Future<StreamSourceSpec> resolveSourceSpec(
    StreamKey key, {
    CancellationToken? cancelToken,
    bool bypassCache = false,
    TrackInfo? legacyTrack,
  }) async {
    cancelToken?.throwIfCancelled();
    final provider = _providers[key.providerId];
    if (authManager.isPlaybackAuthBlocked(key.providerId)) {
      throw StreamingException(
        authManager.authErrorFor(key.providerId) ??
            '${provider?.meta.name ?? key.providerId} 授權已失效，請重新登入',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (provider != null && !_isBrowsable(provider)) {
      throw StreamingException(
        '${provider.meta.name} 尚未登入或授權已失效，無法解析串流',
      );
    }
    var retriedAuth = false;
    while (true) {
      try {
        return await singleFlightResolver.resolve(
          key,
          cancelToken: cancelToken,
          bypassCache: bypassCache || retriedAuth,
          legacyTrack: legacyTrack,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(key.providerId)) {
          final refreshed = await authManager.handleUnauthorized(
            key.providerId,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            cancelToken?.throwIfCancelled();
            continue;
          }
        }
        rethrow;
      }
    }
  }

  /// Background prefetch entry point routed through L1 cache & Single-Flight
  /// deduplication. Silently returns `null` when unavailable, in `AuthRequired`
  /// circuit-breaker state, cancelled, or unsupported (e.g. Apple Music, Local).
  Future<StreamSourceSpec?> prefetchSourceSpec(
    StreamKey key, {
    CancellationToken? cancelToken,
    TrackInfo? legacyTrack,
  }) async {
    if (_disposed || cancelToken?.isCancelled == true) return null;
    if (authManager.isPlaybackAuthBlocked(key.providerId)) return null;
    final provider = _providers[key.providerId];
    if (provider != null && !_isBrowsable(provider)) {
      return null;
    }
    var retriedAuth = false;
    while (true) {
      try {
        return await singleFlightResolver.prefetch(
          key,
          cancelToken: cancelToken,
          legacyTrack: legacyTrack,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(key.providerId)) {
          final refreshed = await authManager.handleUnauthorized(
            key.providerId,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed &&
              !retriedAuth &&
              !_disposed &&
              cancelToken?.isCancelled != true) {
            retriedAuth = true;
            continue;
          }
        }
        return null;
      } catch (_) {
        return null;
      }
    }
  }

  Future<ResolvedStreamResult> resolveStreamForTrack(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    bool bypassCache = false,
  }) async {
    cancel?.throwIfCancelled();
    final provider = resolveProviderForTrack(track);
    if (provider == null) {
      throw StreamingException(
        '找不到對應的串流服務提供者（${track.providerName}）',
      );
    }
    if (authManager.isPlaybackAuthBlocked(provider.kind)) {
      throw StreamingException(
        authManager.authErrorFor(provider.kind) ??
            '${provider.meta.name} 授權已失效，請重新登入',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (!_isBrowsable(provider)) {
      throw StreamingException(
        '${provider.meta.name} 尚未登入或授權已失效，無法解析串流',
      );
    }
    var retriedAuth = false;
    while (true) {
      try {
        if (provider is YouTubeMusicProvider) {
          return await provider.resolveStream(
            track,
            cancel: cancel,
            timeout: timeout ?? const Duration(seconds: 15),
            playRequestId: playRequestId,
            bypassCache: bypassCache || retriedAuth,
          );
        }
        return await provider.resolveStream(
          track,
          cancel: cancel,
          timeout: timeout ?? const Duration(seconds: 15),
          playRequestId: playRequestId,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(provider.kind)) {
          final refreshed = await authManager.handleUnauthorized(
            provider.kind,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            cancel?.throwIfCancelled();
            continue;
          }
        }
        rethrow;
      }
    }
  }

  Future<StreamSourceSpec> resolveSourceSpecForTrack(
    TrackInfo track, {
    String qualityKey = 'default',
    CancellationToken? cancel,
    bool bypassCache = false,
    bool useL1Cache = false,
  }) async {
    cancel?.throwIfCancelled();
    final key = resolverRegistry.deriveKey(track, qualityKey: qualityKey);
    if (useL1Cache) {
      return resolveSourceSpec(
        key,
        cancelToken: cancel,
        bypassCache: bypassCache,
        legacyTrack: track,
      );
    }
    final provider = _providers[key.providerId];
    if (authManager.isPlaybackAuthBlocked(key.providerId)) {
      throw StreamingException(
        authManager.authErrorFor(key.providerId) ??
            '${provider?.meta.name ?? key.providerId} 授權已失效，請重新登入',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (provider != null && !_isBrowsable(provider)) {
      throw StreamingException(
        '${provider.meta.name} 尚未登入或授權已失效，無法解析串流',
      );
    }
    var retriedAuth = false;
    while (true) {
      try {
        return await resolverRegistry.resolveTrack(
          track,
          qualityKey: qualityKey,
          cancelToken: cancel,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            !authManager.isGuestPlaybackCapable(key.providerId)) {
          final refreshed = await authManager.handleUnauthorized(
            key.providerId,
            e.message,
            alreadyRetried: retriedAuth,
          );
          if (refreshed && !retriedAuth) {
            retriedAuth = true;
            cancel?.throwIfCancelled();
            continue;
          }
        }
        rethrow;
      }
    }
  }

  /// Triggers low-priority background preloading for providers that support
  /// out-of-band stream warming (e.g. YouTube Music via `YtDlpService.preloadVideo`).
  Future<void> preloadTrackIfSupported(TrackInfo track) async {
    final provider = resolveProviderForTrack(track);
    if (provider == null ||
        !_isBrowsable(provider) ||
        authManager.isPlaybackAuthBlocked(provider.kind)) {
      return;
    }
    if (provider is YouTubeMusicProvider) {
      await provider.preloadTrack(track);
    }
  }

  /// Gracefully shuts down all in-flight stream resolutions, auth flows, and
  /// awaits PO Token sidecar process termination (`SIGTERM` -> `SIGKILL`).
  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    singleFlightResolver.cancelAll();
    for (final token in _activeCancellations.values) {
      token.cancel();
    }
    _activeCancellations.clear();
    if (_activeWebViewKinds.isNotEmpty) {
      _activeWebViewKinds.clear();
      try {
        await _webViewAuthService.closeAuthWindow();
      } catch (_) {}
    }
    for (final token in _recommendationCancellations.values) {
      token.cancel();
    }
    _recommendationCancellations.clear();
    for (final provider in _providers.values) {
      if (provider is YouTubeMusicProvider) {
        try {
          await provider.disposeAsync();
        } catch (_) {}
      }
    }
    super.dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    singleFlightResolver.cancelAll();
    for (final token in _activeCancellations.values) {
      token.cancel();
    }
    _activeCancellations.clear();
    if (_activeWebViewKinds.isNotEmpty) {
      _activeWebViewKinds.clear();
      unawaited(_webViewAuthService.closeAuthWindow());
    }
    for (final token in _recommendationCancellations.values) {
      token.cancel();
    }
    _recommendationCancellations.clear();
    for (final provider in _providers.values) {
      if (provider is YouTubeMusicProvider) {
        provider.dispose();
      }
    }
    super.dispose();
  }
}
