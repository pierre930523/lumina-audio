part of '../streaming_manager.dart';

File? _defaultRecommendationsCacheFileImpl() {
  if (!Platform.isWindows) return null;
  if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.trim().isEmpty) return null;
  return File(
    '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}streaming_recommendations_cache.json',
  );
}

extension _StreamingManagerInitExt on StreamingManager {
  void _initProvidersAndResolvers({
    required Map<String, StreamingProvider>? customProviders,
    required HttpClient Function()? httpClientFactory,
    required PotProvider? ytmPotProvider,
    required SidecarLifecycleBinder? sidecarLifecycleBinder,
  }) {
    final store = credentialStore;
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
        ytDlpService: ytDlpService,
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
        ytDlpService: ytDlpService,
      ),
      'deezer': DeezerProvider(
        credentialStore: store,
        httpClientFactory: httpClientFactory,
      ),
    };

    for (final kind in StreamingManager.providerOrder) {
      _providers[kind] = customProviders?[kind] ?? defaults[kind]!;
    }
    if (customProviders != null) {
      for (final entry in customProviders.entries) {
        _providers.putIfAbsent(entry.key, () => entry.value);
      }
      if (customProviders.containsKey('youtube_music')) {
        final unusedDefaultYtm = defaults['youtube_music'];
        if (unusedDefaultYtm is YouTubeMusicProvider) {
          unusedDefaultYtm.dispose();
        }
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

  Future<void> _warmupImpl({bool force = false}) {
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

  Future<void> _initializeImpl() async {
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

  Future<void> _disposeAsyncImpl() async {
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
  }

  void _disposeSyncImpl() {
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
  }
}
