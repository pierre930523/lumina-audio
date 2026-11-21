import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import 'providers/apple_music_provider.dart';
import 'providers/deezer_provider.dart';
import 'providers/qobuz_provider.dart';
import 'providers/tidal_provider.dart';
import 'providers/youtube_music_provider.dart';
import 'secure_credential_store.dart';
import 'streaming_provider.dart';
import 'webview_auth_service.dart';

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
  final WebViewAuthService _webViewAuthService;
  final File? recommendationsCacheFile;
  final Duration recommendationsCacheTtl;
  final DateTime Function() _clock;
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

  bool _initialized = false;
  bool _disposed = false;

  StreamingManager({
    SecureCredentialStore? credentialStore,
    Map<String, StreamingProvider>? providers,
    HttpClient Function()? httpClientFactory,
    WebViewAuthService? webViewAuthService,
    File? recommendationsCacheFile,
    this.recommendationsCacheTtl = const Duration(minutes: 20),
    DateTime Function()? clock,
  })  : credentialStore = credentialStore ?? WindowsDpapiCredentialStore(),
        _providers = <String, StreamingProvider>{},
        _webViewAuthService =
            webViewAuthService ?? DesktopWebViewAuthService(),
        recommendationsCacheFile =
            recommendationsCacheFile ?? _defaultRecommendationsCacheFile(),
        _clock = clock ?? DateTime.now {
    final store = this.credentialStore;
    final defaults = <String, StreamingProvider>{
      'apple_music': AppleMusicProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
      ),
      'youtube_music': YouTubeMusicProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
      ),
      'qobuz': QobuzProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
      ),
      'tidal': TidalProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
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
  }

  bool get isInitialized => _initialized;

  List<StreamingProvider> get providers =>
      List<StreamingProvider>.unmodifiable(_providers.values);

  List<StreamingProvider> get connectedProviders => _providers.values
      .where((p) => p.authState == StreamingAuthState.connected)
      .toList(growable: false);

  StreamingProvider? providerFor(String kind) => _providers[kind];

  bool isAuthenticating(String kind) =>
      _activeCancellations.containsKey(kind) ||
      _providers[kind]?.authState == StreamingAuthState.authenticating;

  String? progressMessageFor(String kind) => _progressMessages[kind];

  StreamingRecommendations? recommendationsFor(String kind) =>
      _recommendations[kind];

  bool isLoadingRecommendations(String kind) =>
      _loadingRecommendations.contains(kind);

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
      if (p?.authState != StreamingAuthState.connected) continue;
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
      if (p?.authState != StreamingAuthState.connected) continue;
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

  bool _isRecommendationCacheFresh(StreamingRecommendations? rec) {
    if (rec == null || rec.isEmpty || rec.hasError) return false;
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
        if (provider?.authState != StreamingAuthState.connected) continue;
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
        if (p?.authState == StreamingAuthState.connected &&
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

  /// Restores persisted DPAPI credentials across all providers and validates
  /// them live. Expired or revoked tokens gracefully enter `error` state.
  Future<void> initialize() async {
    for (final provider in _providers.values) {
      try {
        await provider.restoreFromStorage();
      } catch (_) {
        // Provider already transitioned to StreamingAuthState.error with lastError.
      }
    }
    _hydrateRecommendationsCacheSync();
    _initialized = true;
    _safeNotify();

    for (final provider in connectedProviders) {
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
        unawaited(refreshRecommendationsFor(kind, force: true));
      }
    } finally {
      if (identical(_activeCancellations[kind], token)) {
        _activeCancellations.remove(kind);
      }
      _safeNotify();
    }
  }

  Future<bool> isWebViewAuthAvailable() =>
      _webViewAuthService.isWebView2Available();

  Future<void> authenticateWithWebView(
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

    if (provider is BaseStreamingProvider) {
      provider.setAuthenticating();
    }
    _safeNotify();

    try {
      final webViewOk = await _webViewAuthService.isWebView2Available();
      token.throwIfCancelled();

      if (!webViewOk) {
        final planB = _buildPlanBFallbackParams(kind, fallbackParams);
        if (planB != null) {
          onProgress?.call('未偵測到 WebView2，已改用系統瀏覽器授權...');
          await provider.authenticate(
            planB,
            cancel: token,
            onProgress: (msg) {
              _progressMessages[kind] = msg;
              _safeNotify();
              onProgress?.call(msg);
            },
          );
          _progressMessages.remove(kind);
          if (provider.authState == StreamingAuthState.connected) {
            unawaited(refreshRecommendationsFor(kind, force: true));
          }
          return;
        }
        restorePreviousOnCancel();
        throw const StreamingException(
          '系統目前無法使用內嵌 WebView2 登入（缺少 WebView2 執行階段或環境不支援），請於下方展開手動憑證或 OAuth 設定。',
          isWebViewUnavailable: true,
        );
      }

      _activeWebViewKinds.add(kind);
      final startMsg = '正在開啟 ${provider.meta.name} 內嵌登入視窗...';
      _progressMessages[kind] = startMsg;
      _safeNotify();
      onProgress?.call(startMsg);

      final capture = await _webViewAuthService.openAuthWindow(
        WebViewAuthRequest.presetFor(kind, clearSession: clearSession),
      );
      _activeWebViewKinds.remove(kind);

      if (capture.cancelled || token.isCancelled) {
        restorePreviousOnCancel();
        throw const StreamingException('登入已取消', isCancelled: true);
      }

      if (!capture.captured) {
        final msg = capture.error?.trim().isNotEmpty == true
            ? capture.error!.trim()
            : '未能擷取 ${provider.meta.name} 登入憑證';
        if (msg.contains('WebView2Loader.dll not available') ||
            msg.contains('Failed to initialize WebView2 runtime')) {
          restorePreviousOnCancel();
          throw StreamingException(
            'WebView2 執行階段無法啟動（$msg），請改用下方手動憑證或系統瀏覽器授權。',
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
      const verifyMsg = '已擷取登入憑證，正在向平台即時驗證帳號...';
      _progressMessages[kind] = verifyMsg;
      _safeNotify();
      onProgress?.call(verifyMsg);

      await provider.authenticate(
        authParams,
        cancel: token,
        onProgress: (msg) {
          _progressMessages[kind] = msg;
          _safeNotify();
          onProgress?.call(msg);
        },
      );
      _progressMessages.remove(kind);
      if (provider.authState == StreamingAuthState.connected) {
        unawaited(refreshRecommendationsFor(kind, force: true));
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

  Map<String, dynamic>? _buildPlanBFallbackParams(
    String kind,
    Map<String, dynamic>? params,
  ) {
    if (params == null || params.isEmpty) return null;
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
    _recommendationCancellations.remove(kind)?.cancel();
    _loadingRecommendations.remove(kind);
    _recommendations.remove(kind);
    _recommendationErrors.remove(kind);
    _recommendationTokenExpired.remove(kind);
    _progressMessages.remove(kind);
    await provider.logout();
    _persistRecommendationsCacheSync();
    _safeNotify();
  }

  Future<StreamingRecommendations> refreshRecommendationsFor(
    String kind, {
    bool force = false,
  }) async {
    final provider = _providers[kind];
    if (provider == null ||
        provider.authState != StreamingAuthState.connected) {
      return StreamingRecommendations.empty(kind);
    }

    if (!force && _isRecommendationCacheFresh(_recommendations[kind])) {
      return _recommendations[kind]!;
    }

    _recommendationCancellations[kind]?.cancel();
    final token = CancellationToken();
    _recommendationCancellations[kind] = token;
    _loadingRecommendations.add(kind);
    _recommendationErrors.remove(kind);
    _recommendationTokenExpired.remove(kind);
    _safeNotify();

    try {
      final rec = await provider.fetchRecommendations(cancel: token);
      if (_disposed || token.isCancelled) {
        return _recommendations[kind] ?? StreamingRecommendations.empty(kind);
      }
      _recommendations[kind] = rec;
      _recommendationErrors.remove(kind);
      _recommendationTokenExpired[kind] = false;
      _persistRecommendationsCacheSync();
      return rec;
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
    final connected = connectedProviders;
    if (connected.isEmpty) return;
    await Future.wait(
      connected.map(
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
    try {
      final catalog = await provider.syncLibrary(cancel: cancel);
      _safeNotify();
      return catalog;
    } catch (_) {
      _safeNotify();
      rethrow;
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

  Future<StreamingCatalog> searchProvider(String kind, String query) {
    final provider = _providers[kind];
    if (provider == null) {
      throw StreamingException('未知的串流服務：$kind');
    }
    return provider.search(query);
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
    if (id.startsWith('ytm:')) return _providers['youtube_music'];
    if (id.startsWith('qobuz:')) return _providers['qobuz'];
    if (id.startsWith('tidal:')) return _providers['tidal'];
    if (id.startsWith('deezer:')) return _providers['deezer'];
    return null;
  }

  Future<ResolvedStreamResult> resolveStreamForTrack(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    final provider = resolveProviderForTrack(track);
    if (provider == null) {
      throw StreamingException(
        '找不到對應的串流服務提供者（${track.providerName}）',
      );
    }
    if (provider.authState != StreamingAuthState.connected) {
      throw StreamingException(
        '${provider.meta.name} 尚未登入或授權已失效，無法解析串流',
      );
    }
    return provider.resolveStream(
      track,
      cancel: cancel,
      timeout: timeout ?? const Duration(seconds: 9),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final token in _activeCancellations.values) {
      token.cancel();
    }
    _activeCancellations.clear();
    for (final token in _recommendationCancellations.values) {
      token.cancel();
    }
    _recommendationCancellations.clear();
    super.dispose();
  }
}
