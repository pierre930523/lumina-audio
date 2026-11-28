import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/podcast_models.dart';
import '../../models/recommendation_models.dart';
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
import 'recommendation_provider.dart';
import 'secure_credential_store.dart';
import 'single_flight_resolver.dart';
import 'stream_resolver.dart';
import 'streaming_provider.dart';
import 'webview_auth_service.dart';
import 'yt_dlp_service.dart';

part 'manager/streaming_manager_auth.dart';
part 'manager/streaming_manager_init.dart';
part 'manager/streaming_manager_recommendations.dart';
part 'manager/streaming_manager_resolution.dart';

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
            recommendationsCacheFile ?? _defaultRecommendationsCacheFileImpl(),
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
    _initProvidersAndResolvers(
      customProviders: providers,
      httpClientFactory: httpClientFactory,
      ytmPotProvider: ytmPotProvider,
      sidecarLifecycleBinder: sidecarLifecycleBinder,
    );
  }

  bool get isInitialized => _initialized;
  bool get isWarmedUp => _warmedUp;

  Future<void> warmup({bool force = false}) => _warmupImpl(force: force);

  List<StreamingProvider> get providers =>
      List<StreamingProvider>.unmodifiable(_providers.values);

  List<StreamingProvider> get connectedProviders => _providers.values
      .where((p) => p.authState == StreamingAuthState.connected)
      .toList(growable: false);

  List<StreamingProvider> get browsableProviders => _providers.values
      .where(_isBrowsable)
      .toList(growable: false);

  Future<void> Function(String providerId, StreamingCatalog catalog)?
      onCatalogSynced;

  bool _isBrowsable(StreamingProvider? provider) =>
      provider != null &&
      (provider.authState == StreamingAuthState.connected ||
          provider.supportsGuestMode);

  StreamingProvider? providerFor(String kind) => _providers[kind];

  RecommendationProvider? recommendationProviderFor(String kind) {
    final provider = _providers[kind];
    return provider is RecommendationProvider
        ? provider as RecommendationProvider
        : null;
  }

  Map<String, RecommendationProvider> get recommendationProviders {
    final map = <String, RecommendationProvider>{};
    for (final kind in providerOrder) {
      final rec = recommendationProviderFor(kind);
      if (rec != null) map[kind] = rec;
    }
    for (final entry in _providers.entries) {
      final rec = entry.value;
      if (!map.containsKey(entry.key) && rec is RecommendationProvider) {
        map[entry.key] = rec as RecommendationProvider;
      }
    }
    return Map<String, RecommendationProvider>.unmodifiable(map);
  }

  Future<List<FeedSection>> fetchPersonalizedFeeds({
    CancellationToken? cancel,
  }) => _fetchPersonalizedFeedsImpl(cancel: cancel);

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

  void handleNetworkEpochChanged(int newEpoch) =>
      _handleNetworkEpochChangedImpl(newEpoch);

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
  }) => singleFlightResolver.refreshAfter403(
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

  List<StreamingAlbum> allRecommendedAlbums({String? filterKind}) =>
      _allRecommendedAlbumsImpl(filterKind: filterKind);

  List<TrackInfo> allRecommendedTracks({String? filterKind}) =>
      _allRecommendedTracksImpl(filterKind: filterKind);

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializeImpl();

  Future<void> authenticateProvider(
    String kind,
    Map<String, dynamic> params, {
    void Function(String statusMsg)? onProgress,
  }) => _authenticateProviderImpl(kind, params, onProgress: onProgress);

  DetectedDefaultBrowser? detectLocalDefaultBrowser() {
    final svc = _webViewAuthService;
    return svc is LocalBrowserAuthService ? svc.resolveDetectedBrowser() : null;
  }

  Future<bool> isLocalBrowserAuthAvailable() =>
      _webViewAuthService.isWebView2Available();
  Future<bool> isWebViewAuthAvailable() => isLocalBrowserAuthAvailable();

  Future<void> authenticateWithWebView(
    String kind, {
    bool clearSession = false,
    Map<String, dynamic>? fallbackParams,
    void Function(String statusMsg)? onProgress,
  }) => authenticateWithLocalBrowser(
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
  }) => _authenticateWithLocalBrowserImpl(
    kind,
    clearSession: clearSession,
    fallbackParams: fallbackParams,
    onProgress: onProgress,
  );

  void cancelLogin(String kind) => _cancelLoginImpl(kind);
  Future<void> logoutProvider(String kind) => _logoutProviderImpl(kind);

  Future<StreamingRecommendations> refreshRecommendationsFor(
    String kind, {
    bool force = false,
  }) => _refreshRecommendationsForImpl(kind, force: force);

  Future<void> refreshAllRecommendations({bool force = false}) async {
    final browsable = browsableProviders;
    if (browsable.isEmpty) return;
    await Future.wait(
      browsable.map((p) => refreshRecommendationsFor(p.kind, force: force)),
    );
  }

  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String kind,
    String albumId, {
    CancellationToken? cancel,
  }) async => _providers[kind]?.fetchAlbumDetail(albumId, cancel: cancel);

  Future<StreamingCatalog> syncProvider(
    String kind, {
    CancellationToken? cancel,
  }) => _syncProviderImpl(kind, cancel: cancel);

  Future<List<TrackInfo>> fetchPlaylistTracks(String kind, String playlistId) {
    final provider = _providers[kind];
    if (provider == null) throw StreamingException('未知的串流服務：$kind');
    return provider.fetchPlaylistTracks(playlistId);
  }

  Future<StreamingCatalog> searchProvider(
    String kind,
    String query, {
    CancellationToken? cancel,
  }) {
    final provider = _providers[kind];
    if (provider == null) throw StreamingException('未知的串流服務：$kind');
    return provider.search(query, cancel: cancel);
  }

  StreamingProvider? resolveProviderForTrack(TrackInfo track) =>
      _resolveProviderForTrackImpl(track);

  bool get isYouTubeMusicConnected =>
      _providers['youtube_music']?.authState == StreamingAuthState.connected;

  YouTubeMusicProvider? get youTubeMusicProvider {
    final p = _providers['youtube_music'];
    return p is YouTubeMusicProvider ? p : null;
  }

  Future<PodcastLibraryResult> fetchMyPodcasts({CancellationToken? cancel}) async =>
      youTubeMusicProvider?.fetchMyPodcasts(cancel: cancel) ??
      const PodcastLibraryResult();

  Future<PodcastExploreResult> fetchExplorePodcasts({
    String? continuation,
    CancellationToken? cancel,
  }) async =>
      youTubeMusicProvider?.fetchExplorePodcasts(
        continuation: continuation,
        cancel: cancel,
      ) ??
      const PodcastExploreResult();

  Future<PodcastSearchResult> searchPodcasts(
    String query, {
    CancellationToken? cancel,
  }) async =>
      youTubeMusicProvider?.searchPodcasts(query, cancel: cancel) ??
      const PodcastSearchResult();

  Future<PodcastShowDetail> fetchPodcastShowDetail(
    String showBrowseId, {
    String? continuation,
    CancellationToken? cancel,
  }) async {
    final ytm = youTubeMusicProvider;
    if (ytm == null) throw const StreamingException('YouTube Music 提供者尚未初始化');
    return ytm.fetchPodcastShowDetail(
      showBrowseId,
      continuation: continuation,
      cancel: cancel,
    );
  }

  void clearStreamCache(TrackInfo track) => _clearStreamCacheImpl(track);

  StreamSourceSpec? peekCachedSpec(StreamKey key) =>
      singleFlightResolver.peekCached(key);

  Future<StreamSourceSpec> resolveSourceSpec(
    StreamKey key, {
    CancellationToken? cancelToken,
    bool bypassCache = false,
    TrackInfo? legacyTrack,
  }) => _resolveSourceSpecImpl(
    key,
    cancelToken: cancelToken,
    bypassCache: bypassCache,
    legacyTrack: legacyTrack,
  );

  Future<StreamSourceSpec?> prefetchSourceSpec(
    StreamKey key, {
    CancellationToken? cancelToken,
    TrackInfo? legacyTrack,
  }) => _prefetchSourceSpecImpl(
    key,
    cancelToken: cancelToken,
    legacyTrack: legacyTrack,
  );

  Future<ResolvedStreamResult> resolveStreamForTrack(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    bool bypassCache = false,
  }) => _resolveStreamForTrackImpl(
    track,
    cancel: cancel,
    timeout: timeout,
    playRequestId: playRequestId,
    bypassCache: bypassCache,
  );

  Future<StreamSourceSpec> resolveSourceSpecForTrack(
    TrackInfo track, {
    String qualityKey = 'default',
    CancellationToken? cancel,
    bool bypassCache = false,
    bool useL1Cache = false,
  }) => _resolveSourceSpecForTrackImpl(
    track,
    qualityKey: qualityKey,
    cancel: cancel,
    bypassCache: bypassCache,
    useL1Cache: useL1Cache,
  );

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

  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    await _disposeAsyncImpl();
    super.dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposeSyncImpl();
    super.dispose();
  }
}
