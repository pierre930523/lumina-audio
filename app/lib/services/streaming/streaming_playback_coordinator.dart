import 'dart:async';

import '../../models/audio_output_info.dart';
import '../../models/lyric.dart';
import '../../models/signal_path.dart';
import '../../models/studio_models.dart';

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';
import '../audio_service.dart';
import '../playback_persistence_service.dart';
import 'l1_stream_cache.dart';
import 'playback_backend.dart';
import 'providers/apple_music_provider.dart';
import 'providers/tidal_provider.dart';
import 'providers/youtube_music_provider.dart';
import 'single_flight_resolver.dart';
import 'stream_resolver.dart';
import 'streaming_manager.dart';
import 'yt_dlp_service.dart';

enum _YtmPlaybackStage {
  directInitial,
  directFreshRetry,
  ffmpegFallback,
}

class _YtmPlaybackAttempt {
  final int requestId;
  final TrackInfo track;
  final String videoId;
  final CancellationToken cancel;
  _YtmPlaybackStage stage;
  String activeUrl;
  Map<String, String> activeHeaders;
  String? hintExtension;
  AudioFormat format;
  bool recovering = false;

  _YtmPlaybackAttempt({
    required this.requestId,
    required this.track,
    required this.videoId,
    required this.cancel,
    required this.stage,
    required this.activeUrl,
    required this.activeHeaders,
    required this.hintExtension,
    required this.format,
  });
}

class _TidalDashPlaybackAttempt {
  final int requestId;
  final TrackInfo track;
  final CancellationToken cancel;
  final List<String> remainingTiers;
  String? initialError;
  bool recovering = false;

  _TidalDashPlaybackAttempt({
    required this.requestId,
    required this.track,
    required this.cancel,
    required this.remainingTiers,
  });
}

class _CachedResolvedStream {
  final ResolvedStreamResult result;
  final DateTime expiresAt;

  const _CachedResolvedStream({
    required this.result,
    required this.expiresAt,
  });
}

class _CachedSpecEntry {
  final String trackId;
  final StreamSourceSpec spec;
  final DateTime expiresAt;

  const _CachedSpecEntry({
    required this.trackId,
    required this.spec,
    required this.expiresAt,
  });
}

/// Coordinates optimistic UI updates, monotonic epoch + `CancellationToken`
/// superseding, debounced rapid skipping, composite [StreamKey] L1 caching,
/// Single-Flight deduplication, 5-second stable-play sliding lookahead
/// prefetch, desktop hover prefetch, and Native vs External [PlaybackBackend]
/// routing across all streaming providers.
class StreamingPlaybackCoordinator {
  static const int _maxCacheEntries = 64;
  static const Duration _preResolveThreshold = Duration(seconds: 20);
  static const Duration _shortTrackThreshold = Duration(seconds: 25);
  static const double _preDecodeProgressRatio = 0.75;
  static const Duration _ytmStablePlayPreloadPosition = Duration(seconds: 8);
  static const int maxLookaheadTracks = 2;
  static const Duration defaultLookaheadDelay = Duration(seconds: 5);

  final AudioService audioService;
  final StreamingManager streamingManager;
  final YtDlpService ytDlpService;
  final StreamResolverRegistry _resolverRegistry;
  final bool _useCustomResolverRegistry;
  final bool _hasCustomClock;
  late final L1StreamCache _l1Cache;
  late final SingleFlightResolver _singleFlight;
  final PlaybackBackend _nativeBackend;
  final PlaybackBackend _externalBackend;
  final bool _ownsExternalBackend;
  final bool _useResolverPipeline;
  final Duration resolveTimeout;
  final Duration debounceDelay;
  final Duration lookaheadDelay;
  final int lookaheadCount;
  final DateTime Function() _clock;
  final void Function(String message)? logSink;
  final void Function(TrackInfo track, ResolvedStreamResult result)? onNotice;
  final void Function(TrackInfo track, String message, bool isDrmRestricted)?
      onError;

  final Map<String, _CachedResolvedStream> _cache = {};
  final Map<StreamKey, _CachedSpecEntry> _specCache = {};
  final Set<String> _inFlightPreResolves = {};
  final Map<String, ({String providerId, CancellationToken token})>
      _preResolveCancelTokens =
      <String, ({String providerId, CancellationToken token})>{};
  final Set<String> _preloadedTransitionKeys = {};

  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  final List<TrackInfo> _sharedQueue = <TrackInfo>[];
  int _sharedQueueIndex = -1;
  PlaybackState? _loadingExternalState;
  bool _switchingBackends = false;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<PlaybackState>? _nativeStateSub;
  StreamSubscription<PlaybackState>? _externalStateSub;

  PlaybackBackend? _activeBackend;
  int _epoch = 0;
  int? _resolvingRequestId;
  int _resolvingGeneration = 0;
  int _notifiedErrorForEpoch = -1;
  CancellationToken? _activeCancelToken;
  _YtmPlaybackAttempt? _activeYtmAttempt;
  _TidalDashPlaybackAttempt? _activeTidalDashAttempt;
  Timer? _debounceTimer;
  Completer<void>? _pendingDebounceCompleter;
  Future<void>? _activeTaskFuture;
  Future<void>? _recoveryFuture;
  Timer? _stablePlayTimer;
  String? _stablePlayTrackId;
  int _stablePlayEpoch = -1;
  String? _lookaheadCompletedTrackId;
  int _lookaheadCompletedEpoch = -1;
  CancellationToken? _lookaheadCancelToken;
  StreamKey? _inFlightLookaheadKey;
  CancellationToken? _hoverCancelToken;
  StreamKey? _inFlightHoverKey;
  String? _preparedStandbyTrackId;
  int _preparedStandbyEpoch = -1;
  StreamSourceSpec? _preparedStandbySpec;
  String? _attemptedStandbyTrackId;
  int _attemptedStandbyEpoch = -1;
  String? _preparedExternalHandoffTrackId;
  int _preparedExternalHandoffEpoch = -1;
  bool _disposed = false;

  StreamingPlaybackCoordinator({
    required this.audioService,
    required this.streamingManager,
    YtDlpService? ytDlpService,
    StreamResolverRegistry? resolverRegistry,
    PlaybackBackend? nativeBackend,
    PlaybackBackend? externalBackend,
    ExternalPlaybackBridge? externalPlaybackBridge,
    bool? useResolverPipeline,
    this.resolveTimeout = const Duration(seconds: 15),
    this.debounceDelay = const Duration(milliseconds: 120),
    this.lookaheadDelay = defaultLookaheadDelay,
    int lookaheadCount = maxLookaheadTracks,
    DateTime Function()? clock,
    this.logSink,
    this.onNotice,
    this.onError,
  }) : ytDlpService = ytDlpService ?? streamingManager.ytDlpService,
       _resolverRegistry = resolverRegistry ?? streamingManager.resolverRegistry,
       _useCustomResolverRegistry = resolverRegistry != null,
       _hasCustomClock = clock != null,
       lookaheadCount = lookaheadCount < 1
           ? 1
           : (lookaheadCount > maxLookaheadTracks
               ? maxLookaheadTracks
               : lookaheadCount),
       _nativeBackend = nativeBackend ?? NativePlaybackBackend(audioService),
       _externalBackend =
           externalBackend ??
           AppleMusicPlaybackBackend(
             bridge: externalPlaybackBridge,
             credentialsProvider: () => _appleCredentialsFor(streamingManager),
           ),
       _ownsExternalBackend = externalBackend == null,
       _useResolverPipeline =
           useResolverPipeline ??
           (resolverRegistry != null ||
               nativeBackend != null ||
               externalBackend != null ||
               externalPlaybackBridge != null ||
               (ytDlpService == null &&
                   streamingManager.runtimeType == StreamingManager)),
       _clock = clock ?? DateTime.now {
    if (_useCustomResolverRegistry) {
      _l1Cache = L1StreamCache(clock: _clock);
      _singleFlight = SingleFlightResolver(
        registry: _resolverRegistry,
        l1Cache: _l1Cache,
      );
    } else {
      _l1Cache = streamingManager.l1Cache;
      _singleFlight = streamingManager.singleFlightResolver;
    }
    audioService.setStreamingTrackHandler(handleAudioServiceTrack);
    audioService.setPlaybackInterruptHandler(_handlePlaybackInterrupted);
    streamingManager.addAuthRequiredListener(_onProviderAuthRequired);
    _positionSub = audioService.positionStream.listen(_handlePositionTick);
    if (_useResolverPipeline) {
      _nativeStateSub = _nativeBackend.stateStream.listen(
        (s) => _handleBackendStateUpdate(_nativeBackend, s),
      );
      _externalStateSub = _externalBackend.stateStream.listen(
        (s) => _handleBackendStateUpdate(_externalBackend, s),
      );
    } else {
      _stateSub = audioService.stateStream.listen(_handleStateUpdate);
    }
  }

  static AppleMusicCredentials? _appleCredentialsFor(StreamingManager manager) {
    final provider = manager.providerFor('apple_music');
    if (provider is AppleMusicProvider &&
        provider.developerToken != null &&
        provider.developerToken!.isNotEmpty &&
        provider.musicUserToken != null &&
        provider.musicUserToken!.isNotEmpty) {
      return AppleMusicCredentials(
        developerToken: provider.developerToken!,
        musicUserToken: provider.musicUserToken!,
        storefront: provider.storefront,
      );
    }
    return null;
  }

  int get activeRequestId => _epoch;
  int get currentEpoch => _epoch;
  PlaybackBackend? get activeBackend => _activeBackend;
  String? get preparedStandbyTrackId => _preparedStandbyTrackId;
  bool get isStandbyReady =>
      _preparedStandbyTrackId != null && _nativeBackend.isStandbyReady;
  String? get preparedExternalHandoffTrackId =>
      _preparedExternalHandoffTrackId;
  bool get isExternalHandoffPrepared => _preparedExternalHandoffTrackId != null;
  bool get isExternalBackendActive =>
      _useResolverPipeline &&
      (_loadingExternalState != null ||
          (_activeBackend != null &&
              !identical(_activeBackend, _nativeBackend)));
  bool get hasSharedQueue => _sharedQueue.isNotEmpty;
  List<TrackInfo> get queue =>
      _sharedQueue.isNotEmpty ? _sharedQueue : audioService.queue;
  Stream<PlaybackState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  PlaybackState get currentState =>
      _loadingExternalState ??
      _activeBackend?.currentState ??
      audioService.currentState;

  bool shouldInterceptTrack(TrackInfo track) {
    if (track.filePath != null && track.filePath!.trim().isNotEmpty) {
      return false;
    }
    if (_useResolverPipeline) {
      return AudioService.isStreamingTrackId(track.id) ||
          _resolverRegistry.hasPrefixStreamingMapping(track);
    }
    return isStreamingTrack(track);
  }

  void setQueueContext(
    List<TrackInfo>? queueContext, {
    TrackInfo? currentTrack,
    int? queueIndex,
    bool resetLookaheadOnChange = true,
  }) {
    if (queueContext != null && queueContext.isNotEmpty) {
      var queueChanged = _sharedQueue.length != queueContext.length;
      if (!queueChanged) {
        for (var i = 0; i < queueContext.length; i++) {
          if (_sharedQueue[i].id != queueContext[i].id) {
            queueChanged = true;
            break;
          }
        }
      }
      _sharedQueue
        ..clear()
        ..addAll(queueContext);
      if (queueIndex != null &&
          queueIndex >= 0 &&
          queueIndex < _sharedQueue.length) {
        _sharedQueueIndex = queueIndex;
      } else if (currentTrack != null) {
        _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          currentTrack,
        );
      } else {
        _sharedQueueIndex = -1;
      }
      if (queueChanged && resetLookaheadOnChange) {
        _cancelStablePlayTimer();
        _resetLookaheadCompleted();
        _cancelLookaheadPrefetch();
        _clearStandbyTracking();
        _syncStablePlayTimer(currentState);
      }
      return;
    }

    if (currentTrack != null) {
      if (_sharedQueue.isNotEmpty) {
        final idx = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          currentTrack,
        );
        if (idx >= 0) {
          _sharedQueueIndex = idx;
          return;
        }
      }
      if (audioService.queue.isNotEmpty &&
          PlaybackPersistenceService.findTrackIndex(
                audioService.queue,
                currentTrack,
              ) >=
              0) {
        _sharedQueue
          ..clear()
          ..addAll(audioService.queue);
        _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          currentTrack,
        );
        return;
      }
      if (_sharedQueue.isNotEmpty) {
        _sharedQueue
          ..clear()
          ..add(currentTrack);
        _sharedQueueIndex = 0;
      }
    }
  }

  void clearSharedQueue() {
    _sharedQueue.clear();
    _sharedQueueIndex = -1;
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();
    _clearStandbyTracking();
  }

  void _clearStandbyTracking({bool clearPrepared = true}) {
    _attemptedStandbyTrackId = null;
    _attemptedStandbyEpoch = -1;
    if (clearPrepared) {
      _preparedStandbyTrackId = null;
      _preparedStandbyEpoch = -1;
      _preparedStandbySpec = null;
      _preparedExternalHandoffTrackId = null;
      _preparedExternalHandoffEpoch = -1;
    }
  }

  void _cancelStablePlayTimer() {
    _stablePlayTimer?.cancel();
    _stablePlayTimer = null;
    _stablePlayTrackId = null;
    _stablePlayEpoch = -1;
  }

  void _resetLookaheadCompleted() {
    _lookaheadCompletedTrackId = null;
    _lookaheadCompletedEpoch = -1;
  }

  void _cancelLookaheadPrefetch() {
    _lookaheadCancelToken?.cancel();
    _lookaheadCancelToken = null;
    _inFlightLookaheadKey = null;
  }

  void _cancelHoverPrefetch() {
    _hoverCancelToken?.cancel();
    _hoverCancelToken = null;
    _inFlightHoverKey = null;
  }

  void _cancelAllPreResolves() {
    for (final entry in _preResolveCancelTokens.values) {
      entry.token.cancel();
    }
    _preResolveCancelTokens.clear();
  }

  void _onProviderAuthRequired(String providerId, String reason) {
    if (_disposed) return;
    cancelPrefetchForProvider(providerId);
  }

  /// Immediately cancels all pending lookahead, hover, and end-window
  /// prefetches belonging to [providerId] and evicts its local spec cache.
  void cancelPrefetchForProvider(String providerId) {
    if (_inFlightLookaheadKey?.providerId == providerId) {
      _cancelLookaheadPrefetch();
    }
    if (_inFlightHoverKey?.providerId == providerId) {
      _cancelHoverPrefetch();
    }
    final matchingPreResolves = _preResolveCancelTokens.entries
        .where((e) => e.value.providerId == providerId)
        .toList(growable: false);
    for (final entry in matchingPreResolves) {
      entry.value.token.cancel();
      _preResolveCancelTokens.remove(entry.key);
      _inFlightPreResolves.remove(entry.key);
    }
    _specCache.removeWhere((k, _) => k.providerId == providerId);
    if (_preparedStandbySpec?.key.providerId == providerId ||
        (_preparedExternalHandoffTrackId != null &&
            providerId == 'apple_music')) {
      _clearStandbyTracking();
    }
    if (_useCustomResolverRegistry) {
      _singleFlight.cancelProvider(providerId);
      _l1Cache.clearProvider(providerId);
    }
  }

  void _cancelPendingWork() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingDebounceCompleter != null &&
        !_pendingDebounceCompleter!.isCompleted) {
      _pendingDebounceCompleter!.complete();
    }
    _pendingDebounceCompleter = null;
    _activeCancelToken?.cancel();
    _activeCancelToken = null;
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();
    _cancelHoverPrefetch();
    _cancelAllPreResolves();
  }

  Future<void>? _interruptExternalBackendIfActive() {
    if (_disposed || !_useResolverPipeline) return null;
    final hasExternalActive =
        (_activeBackend != null &&
            !identical(_activeBackend, _nativeBackend)) ||
        _loadingExternalState != null;
    if (!hasExternalActive) return null;

    final previousExternal =
        (_activeBackend != null &&
                !identical(_activeBackend, _nativeBackend))
            ? _activeBackend!
            : _externalBackend;
    final stopEpoch = ++_epoch;
    _cancelPendingWork();
    _clearStandbyTracking();
    _resolvingRequestId = null;
    _loadingExternalState = null;
    _activeBackend = _nativeBackend;
    return previousExternal.stop(epoch: stopEpoch);
  }

  Future<void> stopExternalIfActive() async {
    final fut = _interruptExternalBackendIfActive();
    if (fut != null) {
      await fut;
    }
  }

  @visibleForTesting
  Future<void>? get activeTaskFuture => _recoveryFuture ?? _activeTaskFuture;

  @visibleForTesting
  int get cacheLength => _useResolverPipeline
      ? (_specCache.isNotEmpty ? _specCache.length : _l1Cache.length)
      : _cache.length;

  @visibleForTesting
  int get inFlightResolutionCount => _singleFlight.inFlightCount;

  void _logRoute(String message) {
    final sink = logSink;
    if (sink != null) {
      sink(message);
    } else {
      debugPrint(message);
    }
  }

  void _handlePlaybackInterrupted() {
    if (_disposed || _switchingBackends) return;
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();
    if (_useResolverPipeline) {
      final fut = _interruptExternalBackendIfActive();
      if (fut != null) {
        unawaited(fut);
      }
      return;
    }
    ytDlpService.stopFfmpegProxy();
  }

  static bool isStreamingTrack(TrackInfo track) =>
      AudioService.isStreamingTrackId(track.id) || _isYouTubeMusicTrack(track);

  static bool _isYouTubeMusicTrack(TrackInfo track) {
    final id = track.id;
    return id.startsWith('ytm:') ||
        id.startsWith('ytm_') ||
        id.startsWith('streaming:youtube_music:') ||
        id.startsWith('youtube_music:') ||
        track.providerName == 'YouTube Music' ||
        track.providerName == 'Podcast';
  }

  static bool _isTidalTrack(TrackInfo track) =>
      track.id.startsWith('tidal:') || track.providerName == 'Tidal';

  static List<String> _remainingTidalTiersForRoute(String? engineRoute) {
    final route = (engineRoute ?? '').toUpperCase();
    if (route.contains('HI_RES_LOSSLESS')) {
      return <String>['LOSSLESS', 'HIGH'];
    }
    if (route.contains('LOSSLESS')) {
      return <String>['HIGH'];
    }
    if (route.contains('HIGH')) {
      return <String>[];
    }
    return <String>['LOSSLESS', 'HIGH'];
  }

  static bool _isLocalhostProxyUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    final host = uri?.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  bool _isFfmpegProxyUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final isLoopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
    if (!isLoopback) return false;
    final proxyPort = ytDlpService.ffmpegProxy.port;
    if (proxyPort != null && uri.port == proxyPort) return true;
    return uri.path.startsWith('/stream/') &&
        (uri.path.endsWith('.wav') || uri.path.endsWith('.flac'));
  }

  static bool _isHttp403Error(String message) {
    return RegExp(
      r'HTTP\s*403\b|status(?:\s*code)?\s*[:=]?\s*403\b|\b403\s+Forbidden\b',
      caseSensitive: false,
    ).hasMatch(message);
  }

  static bool _isAuthRequiredError(String message) {
    return RegExp(
      r'\bAUTH_REQUIRED\b|HTTP\s*401\b|status(?:\s*code)?\s*[:=]?\s*401\b|\b401\s+Unauthorized\b',
      caseSensitive: false,
    ).hasMatch(message);
  }

  static String _resolveYtmVideoIdForTrack(
    TrackInfo track, {
    ResolvedStreamResult? result,
  }) {
    final fromResult = result?.videoId?.trim();
    if (fromResult != null && fromResult.isNotEmpty) {
      return fromResult;
    }
    final clean = YouTubeMusicProvider.tryExtractCleanVideoId(
      track.id,
      filePath: track.filePath,
    );
    if (clean != null && clean.isNotEmpty) {
      return clean;
    }
    var raw = track.id.trim();
    for (final prefix in const <String>[
      'streaming:youtube_music:',
      'youtube_music:',
      'ytm:',
      'ytm_',
    ]) {
      if (raw.startsWith(prefix)) {
        raw = raw.substring(prefix.length).trim();
        break;
      }
    }
    return raw.isEmpty ? track.id : raw;
  }

  static String _formatEngineLabel(
    ResolvedStreamResult result, {
    required bool isFfmpegProxy,
  }) {
    final explicit = result.engineRoute?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    if (isFfmpegProxy) {
      return 'bundled yt-dlp + ffmpeg fallback';
    }
    final ext = result.hintExtension?.trim().toLowerCase() ?? '';
    if (ext == 'm4a' ||
        ext == 'aac' ||
        ext == 'mp4' ||
        result.format.codec == AudioCodec.aac) {
      return 'bundled yt-dlp (direct M4A)';
    }
    if (ext.isNotEmpty) {
      return 'bundled yt-dlp (direct ${ext.toUpperCase()})';
    }
    return 'bundled yt-dlp (direct ${result.format.codec.name.toUpperCase()})';
  }

  @visibleForTesting
  static Duration computeCacheTtl(
    TrackInfo track,
    String resolvedUrl,
    DateTime now,
  ) {
    if (_isLocalhostProxyUrl(resolvedUrl)) {
      return Duration.zero;
    }
    final id = track.id;
    if (_isYouTubeMusicTrack(track)) {
      final uri = Uri.tryParse(resolvedUrl);
      final expireRaw = uri?.queryParameters['expire'];
      final expireSec = expireRaw != null ? int.tryParse(expireRaw) : null;
      if (expireSec != null && expireSec > 0) {
        final expireAt =
            DateTime.fromMillisecondsSinceEpoch(expireSec * 1000);
        final usableFor =
            expireAt.difference(now) - const Duration(seconds: 60);
        if (usableFor > const Duration(seconds: 5)) {
          return usableFor;
        }
        return Duration.zero;
      }
      return const Duration(minutes: 45);
    }
    if (id.startsWith('apple:')) {
      return const Duration(minutes: 30);
    }
    return const Duration(minutes: 10);
  }

  ResolvedStreamResult? getCachedStream(String trackId) {
    if (_useResolverPipeline) {
      final now = _clock();
      StreamKey? matchKey;
      _CachedSpecEntry? matchEntry;
      for (final entry in _specCache.entries) {
        if (entry.value.trackId == trackId ||
            entry.key.trackId == trackId) {
          matchKey = entry.key;
          matchEntry = entry.value;
          break;
        }
      }
      if (matchKey != null && matchEntry != null) {
        if (!now.isBefore(matchEntry.expiresAt)) {
          _specCache.remove(matchKey);
          return null;
        }
        return _toResolvedResultForCache(matchEntry.spec);
      }

      try {
        final probe = TrackInfo(
          id: trackId,
          title: '',
          artist: '',
          album: '',
          duration: Duration.zero,
          format: const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
        );
        final key = _resolverRegistry.deriveKey(probe);
        if (_usesLegacyCoordinatorSpecCache(key)) return null;
        final cached = _singleFlight.peekCached(key);
        if (cached != null) {
          return _toResolvedResultForCache(cached);
        }
      } catch (_) {}
      return null;
    }

    final entry = _cache[trackId];
    if (entry == null) return null;
    if (!_clock().isBefore(entry.expiresAt)) {
      _cache.remove(trackId);
      return null;
    }
    return entry.result;
  }

  static ResolvedStreamResult? _toResolvedResultForCache(StreamSourceSpec spec) {
    final fallbackFmt = spec.audioFormat ??
        const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        );
    return switch (spec) {
      DirectRangeSpec() => ResolvedStreamResult(
        url: spec.url,
        headers: spec.headers,
        hintExtension: spec.hintExtension,
        format: fallbackFmt,
        isPreviewOnly: spec.isPreviewOnly,
        drmNotice: spec.notice,
        externalWebUrl: spec.externalWebUrl,
      ),
      EncryptedRangeSpec() => ResolvedStreamResult(
        url: spec.url,
        headers: spec.headers,
        hintExtension: spec.hintExtension,
        format: fallbackFmt,
      ),
      SegmentedManifestSpec() => ResolvedStreamResult(
        url: spec.manifestUrlOrXml,
        headers: spec.headers,
        hintExtension: spec.format == ManifestFormat.dash ? 'mpd' : 'm3u8',
        format: fallbackFmt,
      ),
      LocalFileSpec() => ResolvedStreamResult(
        url: spec.path,
        format: fallbackFmt,
      ),
      ExternalBackendSpec() => null,
    };
  }

  void _storeCache(TrackInfo track, ResolvedStreamResult result) {
    if (_isLocalhostProxyUrl(result.url)) return;
    final now = _clock();
    final ttl = computeCacheTtl(track, result.url, now);
    if (ttl <= Duration.zero) return;

    if (!_cache.containsKey(track.id) && _cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[track.id] = _CachedResolvedStream(
      result: result,
      expiresAt: now.add(ttl),
    );
  }

  StreamSourceSpec? _getCachedSpec(StreamKey key) {
    final entry = _specCache[key];
    if (entry == null) return null;
    if (!_clock().isBefore(entry.expiresAt)) {
      _specCache.remove(key);
      return null;
    }
    return entry.spec;
  }

  void _storeSpecCache(TrackInfo track, StreamSourceSpec spec) {
    final resolver = _resolverRegistry.resolverFor(spec.key.providerId);
    final caps = resolver?.capabilities;
    if (caps == null || !caps.supportsL1UrlCache) return;

    final now = _clock();
    final Duration ttl;
    if (resolver is LegacyStreamingProviderResolver &&
        spec is DirectRangeSpec) {
      ttl = computeCacheTtl(track, spec.url, now);
    } else {
      final url = switch (spec) {
        DirectRangeSpec() => spec.url,
        EncryptedRangeSpec() => spec.url,
        _ => null,
      };
      if (url != null && _isLocalhostProxyUrl(url)) return;

      final int? expireAt = switch (spec) {
        DirectRangeSpec() => spec.expireAt,
        SegmentedManifestSpec() => spec.expireAt,
        EncryptedRangeSpec() => spec.expireAt,
        _ => null,
      };
      if (expireAt != null && expireAt > 0) {
        final expireDt = DateTime.fromMillisecondsSinceEpoch(expireAt * 1000);
        final usable =
            expireDt.difference(now) -
            Duration(seconds: caps.defaultL1SafetyMarginSec);
        ttl = usable > const Duration(seconds: 5) ? usable : Duration.zero;
      } else {
        ttl = const Duration(minutes: 10);
      }
    }

    if (ttl <= Duration.zero) return;

    if (!_specCache.containsKey(spec.key) &&
        _specCache.length >= _maxCacheEntries) {
      _specCache.remove(_specCache.keys.first);
    }
    _specCache[spec.key] = _CachedSpecEntry(
      trackId: track.id,
      spec: spec,
      expiresAt: now.add(ttl),
    );
  }

  StreamKey? _tryDeriveKey(TrackInfo track) {
    try {
      return _resolverRegistry.deriveKey(track);
    } catch (_) {
      return null;
    }
  }

  bool _usesLegacyCoordinatorSpecCache(StreamKey key) {
    if (!_hasCustomClock || _useCustomResolverRegistry) return false;
    final resolver = _resolverRegistry.resolverFor(key.providerId);
    return resolver is LegacyStreamingProviderResolver;
  }

  StreamSourceSpec? _peekCachedSpec(StreamKey key) {
    if (_usesLegacyCoordinatorSpecCache(key)) {
      return _getCachedSpec(key);
    }
    return _singleFlight.peekCached(key);
  }

  void _evictSpecCacheForTrack(TrackInfo track) {
    final key = _tryDeriveKey(track);
    if (key != null) {
      _specCache.remove(key);
      _l1Cache.evict(key);
      _l1Cache.evictTrack(key.providerId, key.trackId);
    }
    _specCache.removeWhere(
      (k, v) => v.trackId == track.id || k.trackId == track.id,
    );
  }

  /// Returns `true` iff [track] is eligible for background L1 URL/manifest
  /// prefetching (`supportsL1UrlCache == true`, non-local, registered, and
  /// provider is NOT in `AuthRequired` circuit-breaker state).
  bool canPrefetchTrack(TrackInfo track) {
    if (_disposed || !_useResolverPipeline) return false;
    if (track.filePath != null && track.filePath!.trim().isNotEmpty) {
      return false;
    }
    if (!shouldInterceptTrack(track)) return false;
    final key = _tryDeriveKey(track);
    if (key == null) return false;
    if (streamingManager.isPlaybackAuthBlocked(key.providerId)) return false;
    final resolver = _resolverRegistry.resolverFor(key.providerId);
    if (resolver == null) return false;
    return resolver.capabilities.supportsL1UrlCache;
  }

  /// Silently pre-resolves [track] into the L1 cache via [SingleFlightResolver].
  ///
  /// Strictly restricted to platforms with `supportsL1UrlCache == true`.
  /// Never mutates playback state or surfaces errors to UI callbacks, and
  /// cancelling [cancelToken] only detaches this prefetch waiter without
  /// cancelling an active foreground playback waiter sharing the same flight.
  Future<void> prefetchTrack(
    TrackInfo track, {
    CancellationToken? cancelToken,
  }) async {
    if (_disposed || !_useResolverPipeline) return;
    if (cancelToken?.isCancelled == true) return;
    if (!canPrefetchTrack(track)) return;

    final key = _tryDeriveKey(track);
    if (key == null) return;
    if (_peekCachedSpec(key) != null) return;

    final useLegacySpecCache = _usesLegacyCoordinatorSpecCache(key);
    final localCancel = CancellationToken();
    void forwardCancel() => localCancel.cancel();
    cancelToken?.addListener(forwardCancel);
    if (cancelToken?.isCancelled == true) {
      localCancel.cancel();
    }

    Timer? timeoutTimer;
    if (resolveTimeout > Duration.zero) {
      timeoutTimer = Timer(resolveTimeout, localCancel.cancel);
    }

    try {
      final StreamSourceSpec? spec;
      if (_useCustomResolverRegistry) {
        spec = await _singleFlight.prefetch(
          key,
          cancelToken: localCancel,
          legacyTrack: track,
        );
      } else if (useLegacySpecCache) {
        spec = await streamingManager.resolveSourceSpec(
          key,
          cancelToken: localCancel,
          bypassCache: true,
          legacyTrack: track,
        );
      } else {
        spec = await streamingManager.prefetchSourceSpec(
          key,
          cancelToken: localCancel,
          legacyTrack: track,
        );
      }

      if (!_disposed &&
          !localCancel.isCancelled &&
          spec != null &&
          useLegacySpecCache) {
        _storeSpecCache(track, spec);
      }
    } catch (_) {
      // Prefetch failures and cancellations are strictly silent.
    } finally {
      timeoutTimer?.cancel();
      cancelToken?.removeListener(forwardCancel);
    }
  }

  /// Triggers a best-effort background prefetch for a desktop track-list hover.
  ///
  /// Deduplicates via L1 cache + Single-Flight and cancels any superseded
  /// hover waiter for a different track without affecting foreground playback.
  void requestHoverPrefetch(TrackInfo track) {
    if (_disposed || !_useResolverPipeline) return;
    if (!canPrefetchTrack(track)) return;

    final key = _tryDeriveKey(track);
    if (key == null) return;
    if (_peekCachedSpec(key) != null) return;
    if (_inFlightHoverKey == key &&
        _hoverCancelToken != null &&
        !_hoverCancelToken!.isCancelled) {
      return;
    }

    _cancelHoverPrefetch();
    final cancel = CancellationToken();
    _hoverCancelToken = cancel;
    _inFlightHoverKey = key;

    unawaited(
      prefetchTrack(track, cancelToken: cancel).whenComplete(() {
        if (identical(_hoverCancelToken, cancel)) {
          _hoverCancelToken = null;
          _inFlightHoverKey = null;
        }
      }),
    );
  }

  void _syncStablePlayTimer(PlaybackState state) {
    if (_disposed || !_useResolverPipeline) return;

    final track = state.track;
    if (state.status != PlaybackStatus.playing || track == null) {
      _cancelStablePlayTimer();
      if (state.status == PlaybackStatus.stopped ||
          state.status == PlaybackStatus.ended ||
          state.status == PlaybackStatus.error ||
          state.status == PlaybackStatus.uninitialized) {
        _resetLookaheadCompleted();
        _cancelLookaheadPrefetch();
      }
      return;
    }

    // Detect track change (e.g. native backend auto-advanced).
    if (_stablePlayTrackId != null && _stablePlayTrackId != track.id) {
      _cancelStablePlayTimer();
      _resetLookaheadCompleted();
      _cancelLookaheadPrefetch();
    }
    if (_lookaheadCompletedTrackId != null &&
        _lookaheadCompletedTrackId != track.id) {
      _resetLookaheadCompleted();
      _cancelLookaheadPrefetch();
    }

    if (_lookaheadCompletedTrackId == track.id &&
        _lookaheadCompletedEpoch == _epoch) {
      return;
    }

    if (_stablePlayTimer != null &&
        _stablePlayTrackId == track.id &&
        _stablePlayEpoch == _epoch) {
      return;
    }

    _cancelStablePlayTimer();
    final expectedTrackId = track.id;
    final expectedEpoch = _epoch;
    _stablePlayTrackId = expectedTrackId;
    _stablePlayEpoch = expectedEpoch;

    if (lookaheadDelay <= Duration.zero) {
      _lookaheadCompletedTrackId = expectedTrackId;
      _lookaheadCompletedEpoch = expectedEpoch;
      unawaited(_triggerSlidingLookahead(expectedTrackId, expectedEpoch));
      return;
    }

    _stablePlayTimer = Timer(lookaheadDelay, () {
      _stablePlayTimer = null;
      if (_disposed) return;
      final cur = currentState;
      if (cur.status != PlaybackStatus.playing ||
          cur.track?.id != expectedTrackId ||
          _epoch != expectedEpoch) {
        return;
      }
      _lookaheadCompletedTrackId = expectedTrackId;
      _lookaheadCompletedEpoch = expectedEpoch;
      unawaited(_triggerSlidingLookahead(expectedTrackId, expectedEpoch));
    });
  }

  Future<void> _triggerSlidingLookahead(
    String currentTrackId,
    int expectedEpoch,
  ) async {
    if (_disposed || !_useResolverPipeline) return;
    if (expectedEpoch != _epoch) return;

    final curState = currentState;
    if (curState.status != PlaybackStatus.playing ||
        curState.track?.id != currentTrackId) {
      return;
    }

    final activeQueue = queue;
    if (activeQueue.length <= 1) return;

    int currentIdx = -1;
    if (_sharedQueue.isNotEmpty &&
        _sharedQueueIndex >= 0 &&
        _sharedQueueIndex < activeQueue.length &&
        activeQueue[_sharedQueueIndex].id == currentTrackId) {
      currentIdx = _sharedQueueIndex;
    }
    if (currentIdx < 0) {
      currentIdx = PlaybackPersistenceService.findTrackIndex(
        activeQueue,
        curState.track!,
      );
    }
    if (currentIdx < 0) return;

    // Strictly bounded to at most lookaheadCount (1..2) tracks ahead;
    // NEVER resolves an entire playlist at once.
    final candidates = <TrackInfo>[];
    for (var offset = 1; offset <= lookaheadCount; offset++) {
      final nextIdx = currentIdx + offset;
      if (nextIdx >= activeQueue.length) break;
      final candidate = activeQueue[nextIdx];
      if (candidate.id == currentTrackId) continue;
      if (canPrefetchTrack(candidate)) {
        candidates.add(candidate);
      }
    }
    if (candidates.isEmpty) return;

    _cancelLookaheadPrefetch();
    final cancel = CancellationToken();
    _lookaheadCancelToken = cancel;

    try {
      for (final candidate in candidates) {
        if (_disposed || expectedEpoch != _epoch || cancel.isCancelled) {
          return;
        }
        final key = _tryDeriveKey(candidate);
        if (key == null) continue;
        if (_peekCachedSpec(key) != null) continue;

        _inFlightLookaheadKey = key;
        await prefetchTrack(candidate, cancelToken: cancel);
        if (identical(_lookaheadCancelToken, cancel) &&
            _inFlightLookaheadKey == key) {
          _inFlightLookaheadKey = null;
        }
      }
    } finally {
      if (identical(_lookaheadCancelToken, cancel)) {
        _lookaheadCancelToken = null;
        _inFlightLookaheadKey = null;
      }
    }
  }

  Future<void> handleAudioServiceTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    bool debounce = false,
  }) {
    return playTrack(
      track,
      queueContext: queueContext,
      debounce: debounce,
    );
  }

  bool _shouldOptimisticallyTouchNativeAudio(TrackInfo track) {
    try {
      final key = _resolverRegistry.deriveKey(track);
      final resolver = _resolverRegistry.resolverFor(key.providerId);
      if (resolver == null) return true;
      if (resolver is LocalStreamResolver) return true;
      final caps = resolver.capabilities;
      return caps.supportsL1UrlCache || caps.requiresRangeChunking;
    } catch (_) {
      return true;
    }
  }

  Future<void> playTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    bool debounce = false,
    int? queueIndex,
  }) {
    if (_disposed) return Future.value();

    final canTryStandbySkip =
        _useResolverPipeline &&
        _preparedStandbyTrackId == track.id &&
        _nativeBackend.isStandbyReady;

    setQueueContext(
      queueContext,
      currentTrack: track,
      queueIndex: queueIndex,
      resetLookaheadOnChange: false,
    );

    if (canTryStandbySkip) {
      final fut = _executeStandbySkipOrFallback(
        track,
        queueContext: queueContext,
        queueIndex: queueIndex,
      );
      _activeTaskFuture = fut;
      return fut;
    }

    _clearStandbyTracking();
    final taskEpoch = ++_epoch;

    final incomingKey = _useResolverPipeline ? _tryDeriveKey(track) : null;
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    if (_inFlightLookaheadKey == null || _inFlightLookaheadKey != incomingKey) {
      _cancelLookaheadPrefetch();
    }
    if (_inFlightHoverKey == null || _inFlightHoverKey != incomingKey) {
      _cancelHoverPrefetch();
    }

    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingDebounceCompleter != null &&
        !_pendingDebounceCompleter!.isCompleted) {
      _pendingDebounceCompleter!.complete();
    }
    _pendingDebounceCompleter = null;

    _activeCancelToken?.cancel();
    final cancel = CancellationToken();
    _activeCancelToken = cancel;

    if (_useResolverPipeline) {
      final touchesNative = _shouldOptimisticallyTouchNativeAudio(track);
      if (touchesNative) {
        _loadingExternalState = null;
        unawaited(audioService.cancelPendingPlaybackAtEpoch(taskEpoch));
        audioService.beginOptimisticTrackLoad(track, queue: queueContext);
      } else {
        _loadingExternalState = _externalBackend.currentState.copyWith(
          status: PlaybackStatus.loading,
          track: track,
          position: Duration.zero,
          clearLastError: true,
          clockSource: 'external_musickit',
        );
      }
      if (!_stateController.isClosed) {
        _stateController.add(
          (_loadingExternalState ?? currentState).copyWith(
            status: PlaybackStatus.loading,
            track: track,
            position: Duration.zero,
            clearLastError: true,
          ),
        );
      }
    } else {
      // Legacy mode: immediately kill stale yt-dlp.exe / ffmpeg.exe BEFORE
      // debounce or resolve so rapid track switching leaves zero lingering processes.
      ytDlpService.cancelPlaybackProcesses(exceptRequestId: taskEpoch);
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
      unawaited(audioService.cancelPendingPlayback());
      audioService.beginOptimisticTrackLoad(track, queue: queueContext);
    }

    Future<void> launchTask() => _useResolverPipeline
        ? _executeResolveAndPlaySpec(track, taskEpoch, cancel)
        : _executeResolveAndPlayLegacy(track, taskEpoch, cancel);

    if (debounce && debounceDelay > Duration.zero) {
      final completer = Completer<void>();
      _pendingDebounceCompleter = completer;
      _debounceTimer = Timer(debounceDelay, () {
        _debounceTimer = null;
        if (identical(_pendingDebounceCompleter, completer)) {
          _pendingDebounceCompleter = null;
        }
        if (_disposed || taskEpoch != _epoch || cancel.isCancelled) {
          if (!completer.isCompleted) completer.complete();
          return;
        }
        final fut = launchTask();
        _activeTaskFuture = fut;
        fut.whenComplete(() {
          if (!completer.isCompleted) completer.complete();
        });
      });
      _activeTaskFuture = completer.future;
      return completer.future;
    }

    final fut = launchTask();
    _activeTaskFuture = fut;
    return fut;
  }

  PlaybackBackend get _effectiveControlBackend =>
      _loadingExternalState != null
          ? _externalBackend
          : (_activeBackend ?? _nativeBackend);

  Future<void> pause() {
    _cancelStablePlayTimer();
    if (_useResolverPipeline) {
      if (_loadingExternalState != null) {
        _loadingExternalState = _loadingExternalState!.copyWith(
          status: PlaybackStatus.paused,
        );
        if (!_stateController.isClosed) {
          _stateController.add(_loadingExternalState!);
        }
      }
      return _effectiveControlBackend.pause();
    }
    ytDlpService.stopFfmpegProxy();
    return audioService.pause();
  }

  Future<void> resume() {
    if (_useResolverPipeline) {
      if (_loadingExternalState != null) {
        _loadingExternalState = _loadingExternalState!.copyWith(
          status: PlaybackStatus.playing,
        );
        if (!_stateController.isClosed) {
          _stateController.add(_loadingExternalState!);
        }
      }
      return _effectiveControlBackend.resume();
    }
    return audioService.resume();
  }

  Future<void> togglePlayPause() {
    if (_useResolverPipeline && isExternalBackendActive) {
      final cur = currentState;
      if (cur.status == PlaybackStatus.playing ||
          cur.status == PlaybackStatus.buffering) {
        return pause();
      }
      if ((cur.status == PlaybackStatus.stopped ||
              cur.status == PlaybackStatus.ended) &&
          cur.track != null) {
        return playTrack(
          cur.track!,
          queueContext: hasSharedQueue ? List<TrackInfo>.from(_sharedQueue) : null,
        );
      }
      return resume();
    }
    return audioService.togglePlayPause();
  }

  Future<void> seek(Duration position) {
    final seekEpoch = ++_epoch;
    _activeCancelToken?.cancel();
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();
    if (_useResolverPipeline) {
      if (_loadingExternalState != null) {
        _loadingExternalState = _loadingExternalState!.copyWith(
          position: position,
        );
        if (!_stateController.isClosed) {
          _stateController.add(_loadingExternalState!);
        }
      }
      final fut = _effectiveControlBackend.seek(
        position,
        epoch: seekEpoch,
      );
      _syncStablePlayTimer(currentState);
      return fut;
    }
    return audioService.seek(position);
  }

  Future<void> setVolume(double volume) {
    if (_useResolverPipeline) {
      if (_loadingExternalState != null) {
        final clamped = volume.clamp(0.0, 1.0);
        _loadingExternalState = _loadingExternalState!.copyWith(
          volume: clamped,
          isMuted: clamped == 0.0,
        );
        if (!_stateController.isClosed) {
          _stateController.add(_loadingExternalState!);
        }
      }
      return _effectiveControlBackend.setVolume(volume);
    }
    return audioService.setVolume(volume);
  }

  Future<void> toggleMute() {
    if (_useResolverPipeline && isExternalBackendActive) {
      final target = _effectiveControlBackend;
      if (_loadingExternalState != null) {
        final nextMuted = !_loadingExternalState!.isMuted;
        final nextVol = nextMuted ? 0.0 : 0.85;
        _loadingExternalState = _loadingExternalState!.copyWith(
          volume: nextVol,
          isMuted: nextMuted,
        );
        if (!_stateController.isClosed) {
          _stateController.add(_loadingExternalState!);
        }
      }
      if (target is AppleMusicPlaybackBackend) {
        return target.toggleMute();
      }
      return target.setVolume(currentState.isMuted ? 0.85 : 0.0);
    }
    return audioService.toggleMute();
  }

  Future<void> stop() async {
    final stopEpoch = ++_epoch;
    _cancelPendingWork();
    _clearStandbyTracking();
    final wasLoadingExternal = _loadingExternalState != null;
    _loadingExternalState = null;

    if (_useResolverPipeline) {
      final target =
          _activeBackend ??
          (wasLoadingExternal ? _externalBackend : _nativeBackend);
      await target.stop(epoch: stopEpoch);
      return;
    }

    ytDlpService.cancelPlaybackProcesses();
    _activeYtmAttempt = null;
    _activeTidalDashAttempt = null;
    await audioService.stop();
  }

  Future<void> next() => _stepQueue(delta: 1);

  Future<void> playNext() => next();

  Future<void> previous() => _stepQueue(delta: -1);

  Future<void> _stepQueue({required int delta}) async {
    if (!_useResolverPipeline) {
      return delta >= 0 ? audioService.next() : audioService.previous();
    }
    final activeQueue = queue;
    if (activeQueue.isEmpty) {
      return delta >= 0 ? audioService.next() : audioService.previous();
    }

    final curTrack = currentState.track;
    int currentIdx = -1;
    if (_sharedQueue.isNotEmpty &&
        _sharedQueueIndex >= 0 &&
        _sharedQueueIndex < activeQueue.length) {
      if (curTrack == null ||
          PlaybackPersistenceService.findTrackIndex(
                <TrackInfo>[activeQueue[_sharedQueueIndex]],
                curTrack,
              ) ==
              0) {
        currentIdx = _sharedQueueIndex;
      }
    }
    if (currentIdx < 0 && curTrack != null) {
      currentIdx = PlaybackPersistenceService.findTrackIndex(
        activeQueue,
        curTrack,
      );
    }

    final targetIdx = currentIdx >= 0
        ? (currentIdx + delta + activeQueue.length) % activeQueue.length
        : (delta >= 0 ? 0 : activeQueue.length - 1);

    final snapshot = List<TrackInfo>.from(activeQueue);
    final target = snapshot[targetIdx];
    if (_sharedQueue.isNotEmpty) {
      _sharedQueueIndex = targetIdx;
    }

    final useZeroLatencyStandby =
        delta > 0 &&
        _preparedStandbyTrackId == target.id &&
        _nativeBackend.isStandbyReady;

    if (shouldInterceptTrack(target) || useZeroLatencyStandby) {
      await playTrack(
        target,
        queueContext: snapshot,
        debounce: !useZeroLatencyStandby,
        queueIndex: targetIdx,
      );
      return;
    }

    await stopExternalIfActive();
    _loadingExternalState = null;
    _activeBackend = _nativeBackend;
    await audioService.play(track: target);
  }

  Future<void> _executeStandbySkipOrFallback(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    int? queueIndex,
  }) async {
    final skipEpoch = ++_epoch;
    final incomingKey = _tryDeriveKey(track);
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    if (_inFlightLookaheadKey == null || _inFlightLookaheadKey != incomingKey) {
      _cancelLookaheadPrefetch();
    }
    if (_inFlightHoverKey == null || _inFlightHoverKey != incomingKey) {
      _cancelHoverPrefetch();
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingDebounceCompleter != null &&
        !_pendingDebounceCompleter!.isCompleted) {
      _pendingDebounceCompleter!.complete();
    }
    _pendingDebounceCompleter = null;
    _activeCancelToken?.cancel();
    _activeCancelToken = null;
    _cancelAllPreResolves();

    final preparedSpec = _preparedStandbySpec;
    _clearStandbyTracking();

    bool isStale() => _disposed || skipEpoch != _epoch;
    if (isStale()) return;

    if (_activeBackend != null && !identical(_activeBackend, _nativeBackend)) {
      final previousBackend = _activeBackend!;
      _activeBackend = _nativeBackend;
      _switchingBackends = true;
      try {
        await previousBackend.stop(epoch: skipEpoch);
      } finally {
        _switchingBackends = false;
      }
      if (isStale()) return;
    } else {
      _activeBackend = _nativeBackend;
    }
    _loadingExternalState = null;

    var switched = false;
    try {
      switched = await _nativeBackend.skipToStandby(epoch: skipEpoch);
    } catch (_) {
      switched = false;
    }
    if (isStale()) return;

    if (switched) {
      final resolvedTrack = preparedSpec?.audioFormat != null
          ? track.copyWith(format: preparedSpec!.audioFormat)
          : track;
      if (preparedSpec is DirectRangeSpec &&
          (preparedSpec.isPreviewOnly || preparedSpec.notice != null)) {
        onNotice?.call(
          resolvedTrack,
          ResolvedStreamResult(
            url: preparedSpec.url,
            headers: preparedSpec.headers,
            hintExtension: preparedSpec.hintExtension,
            format: resolvedTrack.format,
            isPreviewOnly: preparedSpec.isPreviewOnly,
            drmNotice: preparedSpec.notice,
            externalWebUrl: preparedSpec.externalWebUrl,
          ),
        );
      }
      _syncStablePlayTimer(currentState);
      return;
    }

    if (!shouldInterceptTrack(track) && _tryDeriveKey(track) == null) {
      await audioService.play(track: track);
      if (!isStale()) {
        _syncStablePlayTimer(currentState);
      }
      return;
    }

    final fallbackCancel = CancellationToken();
    _activeCancelToken = fallbackCancel;
    if (_shouldOptimisticallyTouchNativeAudio(track)) {
      unawaited(audioService.cancelPendingPlaybackAtEpoch(skipEpoch));
      audioService.beginOptimisticTrackLoad(track, queue: queueContext);
      if (!_stateController.isClosed) {
        _stateController.add(
          currentState.copyWith(
            status: PlaybackStatus.loading,
            track: track,
            position: Duration.zero,
            clearLastError: true,
          ),
        );
      }
    }
    await _executeResolveAndPlaySpec(track, skipEpoch, fallbackCancel);
  }

  Future<void> _executeResolveAndPlaySpec(
    TrackInfo track,
    int taskEpoch,
    CancellationToken cancel,
  ) async {
    bool isStale() => _disposed || taskEpoch != _epoch || cancel.isCancelled;
    if (isStale()) return;

    final resolveGen = ++_resolvingGeneration;
    _resolvingRequestId = taskEpoch;
    StreamSourceSpec? resolvedSpec;

    try {
      final resolveSw = Stopwatch()..start();
      final key = _resolverRegistry.deriveKey(track);
      final useLegacySpecCache = _usesLegacyCoordinatorSpecCache(key);
      final cachedSpec = _peekCachedSpec(key);
      if (cachedSpec != null) {
        resolvedSpec = cachedSpec;
      } else {
        resolvedSpec = await _awaitWithCancellationAndTimeout<StreamSourceSpec>(
          () => _useCustomResolverRegistry
              ? _singleFlight.resolve(
                  key,
                  cancelToken: cancel,
                  bypassCache: useLegacySpecCache,
                  legacyTrack: track,
                )
              : streamingManager.resolveSourceSpec(
                  key,
                  cancelToken: cancel,
                  bypassCache: useLegacySpecCache,
                  legacyTrack: track,
                ),
          cancel,
        );
        if (!isStale() && useLegacySpecCache) {
          _storeSpecCache(track, resolvedSpec);
        }
      }
      debugPrint(
        '[StreamResolve] key=${key.providerId}:${key.trackId} '
        'leg=${cachedSpec != null ? 'l1_cache' : key.providerId} '
        'resolve_ms=${resolveSw.elapsedMilliseconds}',
      );

      if (isStale()) return;

      final spec = resolvedSpec;
      final PlaybackBackend targetBackend = spec is ExternalBackendSpec
          ? _externalBackend
          : _nativeBackend;

      if (_activeBackend != null && !identical(_activeBackend, targetBackend)) {
        final previousBackend = _activeBackend!;
        _activeBackend = targetBackend;
        _switchingBackends = true;
        try {
          await previousBackend.stop(epoch: taskEpoch);
        } finally {
          _switchingBackends = false;
        }
        if (isStale()) return;
      } else {
        _activeBackend = targetBackend;
      }
      _loadingExternalState = null;

      final resolvedTrack = spec.audioFormat != null
          ? track.copyWith(format: spec.audioFormat)
          : track;

      if (spec is ExternalBackendSpec && spec.notice != null) {
        onNotice?.call(
          resolvedTrack,
          ResolvedStreamResult(
            url: spec.previewUrl ?? spec.trackUri,
            format: resolvedTrack.format,
            isPreviewOnly: spec.previewUrl != null,
            drmNotice: spec.notice,
            externalWebUrl: spec.externalWebUrl,
          ),
        );
      } else if (spec is DirectRangeSpec &&
          (spec.isPreviewOnly || spec.notice != null)) {
        onNotice?.call(
          resolvedTrack,
          ResolvedStreamResult(
            url: spec.url,
            headers: spec.headers,
            hintExtension: spec.hintExtension,
            format: resolvedTrack.format,
            isPreviewOnly: spec.isPreviewOnly,
            drmNotice: spec.notice,
            externalWebUrl: spec.externalWebUrl,
          ),
        );
      }

      await targetBackend.play(spec, resolvedTrack, epoch: taskEpoch);
      if (!isStale()) {
        _syncStablePlayTimer(currentState);
      }
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      _handleResolveSpecFailure(
        track,
        taskEpoch,
        e.message,
        resolvedSpec: resolvedSpec,
        isDrmRestricted: e.isDrmRestricted,
      );
    } on TimeoutException {
      if (isStale()) return;
      cancel.cancel();
      _handleResolveSpecFailure(
        track,
        taskEpoch,
        '串流解析逾時，請稍後再試',
        resolvedSpec: resolvedSpec,
      );
    } catch (e) {
      if (isStale()) return;
      _handleResolveSpecFailure(
        track,
        taskEpoch,
        '串流播放失敗：$e',
        resolvedSpec: resolvedSpec,
      );
    } finally {
      if (_resolvingGeneration == resolveGen &&
          _resolvingRequestId == taskEpoch) {
        _resolvingRequestId = null;
      }
    }
  }

  void _handleResolveSpecFailure(
    TrackInfo track,
    int taskEpoch,
    String message, {
    StreamSourceSpec? resolvedSpec,
    bool isDrmRestricted = false,
  }) {
    _loadingExternalState = null;
    _evictSpecCacheForTrack(track);
    _notifiedErrorForEpoch = taskEpoch;
    if (resolvedSpec is! ExternalBackendSpec &&
        _shouldOptimisticallyTouchNativeAudio(track)) {
      audioService.failOptimisticTrackLoad(track, message);
    } else if (!_stateController.isClosed) {
      _stateController.add(
        currentState.copyWith(
          status: PlaybackStatus.error,
          track: track,
          lastError: message,
        ),
      );
    }
    onError?.call(track, message, isDrmRestricted);
  }

  Future<void> _executeResolveAndPlayLegacy(
    TrackInfo track,
    int requestId,
    CancellationToken cancel,
  ) async {
    bool isStale() =>
        _disposed || requestId != _epoch || cancel.isCancelled;

    if (isStale()) return;

    final resolveGen = ++_resolvingGeneration;
    _resolvingRequestId = requestId;
    try {
      final cached = getCachedStream(track.id);
      final ResolvedStreamResult result;
      if (cached != null) {
        result = cached;
      } else {
        result = await _resolveWithCancellationAndTimeout(
          track,
          requestId,
          cancel,
        );
        if (!isStale()) {
          _storeCache(track, result);
        }
      }

      if (isStale()) return;

      if (result.isPreviewOnly || result.drmNotice != null) {
        onNotice?.call(track, result);
      }

      final resolvedTrack = track.copyWith(format: result.format);
      if (_isYouTubeMusicTrack(track)) {
        final isProxy = _isFfmpegProxyUrl(result.url);
        final videoId = _resolveYtmVideoIdForTrack(track, result: result);
        final engineLabel = _formatEngineLabel(result, isFfmpegProxy: isProxy);
        _activeYtmAttempt = _YtmPlaybackAttempt(
          requestId: requestId,
          track: resolvedTrack,
          videoId: videoId,
          cancel: cancel,
          stage: isProxy
              ? _YtmPlaybackStage.ffmpegFallback
              : _YtmPlaybackStage.directInitial,
          activeUrl: result.url,
          activeHeaders: result.headers,
          hintExtension: result.hintExtension,
          format: result.format,
        );
        _activeTidalDashAttempt = null;
        _logRoute('[YTM Play] videoId=$videoId -> Engine: $engineLabel');
      } else {
        _activeYtmAttempt = null;
        _activeTidalDashAttempt =
            (_isTidalTrack(track) && _isFfmpegProxyUrl(result.url))
                ? _TidalDashPlaybackAttempt(
                    requestId: requestId,
                    track: resolvedTrack,
                    cancel: cancel,
                    remainingTiers:
                        _remainingTidalTiersForRoute(result.engineRoute),
                  )
                : null;
      }

      await audioService.playStreamUrlAsync(
        track: resolvedTrack,
        streamUrl: result.url,
        headers: result.headers,
        hintExtension: result.hintExtension,
        requestId: requestId,
      );
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
      _cache.remove(track.id);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, e.message);
      onError?.call(track, e.message, e.isDrmRestricted);
    } on TimeoutException {
      if (isStale()) return;
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
      ytDlpService.cancelPlaybackProcesses();
      _cache.remove(track.id);
      const msg = '串流解析逾時，請稍後再試';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    } catch (e) {
      if (isStale()) return;
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
      _cache.remove(track.id);
      final msg = '串流播放失敗：$e';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    } finally {
      if (_resolvingGeneration == resolveGen &&
          _resolvingRequestId == requestId) {
        _resolvingRequestId = null;
      }
    }
  }

  Future<T> _awaitWithCancellationAndTimeout<T>(
    Future<T> Function() invoke,
    CancellationToken cancel,
  ) {
    cancel.throwIfCancelled();

    final completer = Completer<T>();

    void onCancel() {
      if (!_useResolverPipeline) {
        ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
      }
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancel.addListener(onCancel);

    Future<T>.sync(invoke).then(
      (res) {
        if (!completer.isCompleted) {
          completer.complete(res);
        }
      },
      onError: (Object err, StackTrace st) {
        if (!completer.isCompleted) {
          completer.completeError(err, st);
        }
      },
    );

    return completer.future.timeout(resolveTimeout).whenComplete(() {
      cancel.removeListener(onCancel);
    });
  }

  Future<ResolvedStreamResult> _resolveWithCancellationAndTimeout(
    TrackInfo track,
    int requestId,
    CancellationToken cancel, {
    bool bypassCache = false,
  }) {
    return _awaitWithCancellationAndTimeout<ResolvedStreamResult>(
      () => streamingManager.resolveStreamForTrack(
        track,
        cancel: cancel,
        timeout: resolveTimeout,
        playRequestId: requestId,
        bypassCache: bypassCache,
      ),
      cancel,
    );
  }

  void _clearAllYtmCaches(TrackInfo track, String videoId) {
    _cache.remove(track.id);
    streamingManager.clearStreamCache(track);
    ytDlpService.clearCache(videoId);
    if (track.id != videoId) {
      ytDlpService.clearCache(track.id);
    }
  }

  bool _canAttempt403Recovery(
    _YtmPlaybackAttempt attempt,
    TrackInfo errTrack,
    String errMessage,
  ) {
    if (_disposed || attempt.recovering || attempt.cancel.isCancelled) {
      return false;
    }
    if (attempt.requestId != _epoch) return false;
    if (attempt.track.id != errTrack.id) return false;
    if (attempt.stage == _YtmPlaybackStage.ffmpegFallback) return false;
    if (_isFfmpegProxyUrl(attempt.activeUrl)) return false;
    final uri = Uri.tryParse(attempt.activeUrl.trim());
    final scheme = uri?.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    return _isHttp403Error(errMessage);
  }

  Future<void> _recoverFromYtm403(_YtmPlaybackAttempt attempt) {
    final future = _runYtm403Recovery(attempt);
    _recoveryFuture = future;
    future.whenComplete(() {
      if (identical(_recoveryFuture, future)) {
        _recoveryFuture = null;
      }
    });
    return future;
  }

  Future<void> _runYtm403Recovery(_YtmPlaybackAttempt attempt) async {
    bool isStale() =>
        _disposed ||
        attempt.requestId != _epoch ||
        attempt.cancel.isCancelled ||
        !identical(_activeYtmAttempt, attempt);

    if (isStale()) return;

    final track = attempt.track;
    final videoId = attempt.videoId;
    final requestId = attempt.requestId;

    try {
      if (attempt.stage == _YtmPlaybackStage.directInitial) {
        _clearAllYtmCaches(track, videoId);
        _logRoute(
          '[YTM Play] videoId=$videoId -> HTTP 403 detected; clearing cache and retrying fresh yt-dlp',
        );
        audioService.beginOptimisticTrackLoad(track);

        final freshResult = await _resolveWithCancellationAndTimeout(
          track,
          requestId,
          attempt.cancel,
          bypassCache: true,
        );
        if (isStale()) {
          ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
          return;
        }

        _storeCache(track, freshResult);
        final resolvedTrack = track.copyWith(format: freshResult.format);
        final isProxy = _isFfmpegProxyUrl(freshResult.url);
        final engineLabel = _formatEngineLabel(
          freshResult,
          isFfmpegProxy: isProxy,
        );

        attempt.stage = isProxy
            ? _YtmPlaybackStage.ffmpegFallback
            : _YtmPlaybackStage.directFreshRetry;
        attempt.activeUrl = freshResult.url;
        attempt.activeHeaders = freshResult.headers;
        attempt.hintExtension = freshResult.hintExtension;
        attempt.format = freshResult.format;
        attempt.recovering = false;

        _logRoute('[YTM Play] videoId=$videoId -> Engine: $engineLabel');
        await audioService.playStreamUrlAsync(
          track: resolvedTrack,
          streamUrl: freshResult.url,
          headers: freshResult.headers,
          hintExtension: freshResult.hintExtension,
          requestId: requestId,
        );
        return;
      }

      if (attempt.stage == _YtmPlaybackStage.directFreshRetry) {
        _clearAllYtmCaches(track, videoId);
        _logRoute(
          '[YTM Play] videoId=$videoId -> HTTP 403 persisted after fresh retry; switching to bundled ffmpeg fallback',
        );
        audioService.beginOptimisticTrackLoad(track);

        final wavUrl = await ytDlpService.openTranscodedWavUrl(
          sourceUrl: attempt.activeUrl,
          headers: attempt.activeHeaders,
          playRequestId: requestId,
        );
        if (isStale()) {
          ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
          return;
        }

        attempt.stage = _YtmPlaybackStage.ffmpegFallback;
        attempt.activeUrl = wavUrl;
        attempt.activeHeaders = const <String, String>{};
        attempt.hintExtension = 'wav';
        attempt.recovering = false;

        _logRoute(
          '[YTM Play] videoId=$videoId -> Engine: bundled yt-dlp + ffmpeg fallback',
        );
        await audioService.playStreamUrlAsync(
          track: track.copyWith(format: attempt.format),
          streamUrl: wavUrl,
          headers: const <String, String>{},
          hintExtension: 'wav',
          requestId: requestId,
        );
      }
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      _activeYtmAttempt = null;
      _clearAllYtmCaches(track, videoId);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, e.message);
      onError?.call(track, e.message, e.isDrmRestricted);
    } on YtDlpException catch (e) {
      if (e.isCancelled || isStale()) return;
      _activeYtmAttempt = null;
      _clearAllYtmCaches(track, videoId);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, e.message);
      onError?.call(track, e.message, false);
    } on TimeoutException {
      if (isStale()) return;
      _activeYtmAttempt = null;
      ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
      _clearAllYtmCaches(track, videoId);
      const msg = '串流解析逾時，請稍後再試';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    } catch (e) {
      if (isStale()) return;
      _activeYtmAttempt = null;
      ytDlpService.stopFfmpegProxy();
      _clearAllYtmCaches(track, videoId);
      final msg = '串流播放失敗：$e';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    }
  }

  Future<void> _recoverTidalDashPlayback(
    _TidalDashPlaybackAttempt attempt, {
    required String runtimeError,
  }) {
    final future = _runTidalDashRecovery(attempt, runtimeError: runtimeError);
    _recoveryFuture = future;
    future.whenComplete(() {
      if (identical(_recoveryFuture, future)) {
        _recoveryFuture = null;
      }
    });
    return future;
  }

  Future<void> _runTidalDashRecovery(
    _TidalDashPlaybackAttempt attempt, {
    required String runtimeError,
  }) async {
    bool isStale() =>
        _disposed ||
        attempt.requestId != _epoch ||
        attempt.cancel.isCancelled ||
        !identical(_activeTidalDashAttempt, attempt);

    if (isStale() || attempt.remainingTiers.isEmpty) return;

    final track = attempt.track;
    final requestId = attempt.requestId;
    attempt.initialError ??= runtimeError;
    final nextTier = attempt.remainingTiers.removeAt(0);

    String formatFailure(String detail) {
      final init = attempt.initialError?.trim();
      if (init == null || init.isEmpty || detail.contains(init)) return detail;
      return '$detail（原始錯誤：$init）';
    }

    void notifyFailure(String msg, {bool isDrmRestricted = false}) {
      _activeTidalDashAttempt = null;
      _cache.remove(track.id);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, isDrmRestricted);
    }

    final resolveGen = ++_resolvingGeneration;
    _resolvingRequestId = requestId;
    try {
      final provider = streamingManager.resolveProviderForTrack(track);
      if (provider is! TidalProvider) {
        throw const StreamingException('找不到 Tidal 串流提供者');
      }

      _logRoute(
        '[Tidal Play] track=${track.id} -> runtime error ($runtimeError); auto-downgrading to $nextTier (DASH enabled)',
      );
      audioService.beginOptimisticTrackLoad(track);

      final fallback = await _awaitWithCancellationAndTimeout<ResolvedStreamResult>(
        () => provider.resolveStream(
          track,
          cancel: attempt.cancel,
          timeout: resolveTimeout,
          playRequestId: requestId,
          maxQuality: nextTier,
        ),
        attempt.cancel,
      );
      if (isStale()) return;

      _storeCache(track, fallback);
      final resolvedTrack = track.copyWith(format: fallback.format);
      if (_isFfmpegProxyUrl(fallback.url)) {
        final route = (fallback.engineRoute ?? '').toUpperCase();
        if (route.isNotEmpty &&
            !route.contains('LOSSLESS') &&
            !route.contains('HI_RES_LOSSLESS')) {
          attempt.remainingTiers.clear();
        } else if (!route.contains('HI_RES_LOSSLESS')) {
          attempt.remainingTiers.remove('LOSSLESS');
        }
        attempt.recovering = false;
        _activeTidalDashAttempt = attempt;
      } else {
        _activeTidalDashAttempt = null;
      }

      await audioService.playStreamUrlAsync(
        track: resolvedTrack,
        streamUrl: fallback.url,
        headers: fallback.headers,
        hintExtension: fallback.hintExtension,
        requestId: requestId,
      );
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      notifyFailure(
        formatFailure(e.message),
        isDrmRestricted: e.isDrmRestricted,
      );
    } on TimeoutException {
      if (isStale()) return;
      notifyFailure(formatFailure('串流解析逾時，請稍後再試'));
    } catch (e) {
      if (isStale()) return;
      notifyFailure(formatFailure('串流播放失敗：$e'));
    } finally {
      if (_resolvingGeneration == resolveGen &&
          _resolvingRequestId == requestId) {
        _resolvingRequestId = null;
      }
    }
  }

  void _handleBackendStateUpdate(
    PlaybackBackend source,
    PlaybackState state,
  ) {
    if (_disposed) return;
    if (_loadingExternalState != null && identical(source, _nativeBackend)) {
      return;
    }
    if (_activeBackend != null && !identical(_activeBackend, source)) {
      return;
    }
    if (identical(source, _nativeBackend) &&
        state.status == PlaybackStatus.playing &&
        state.track != null &&
        _sharedQueue.isNotEmpty) {
      final idx = PlaybackPersistenceService.findTrackIndex(
        _sharedQueue,
        state.track!,
      );
      if (idx >= 0) {
        _sharedQueueIndex = idx;
      } else if (audioService.queue.isNotEmpty) {
        _sharedQueue
          ..clear()
          ..addAll(audioService.queue);
        _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          state.track!,
        );
      } else {
        clearSharedQueue();
      }
    }
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
    if (identical(source, _externalBackend) && !_positionController.isClosed) {
      _positionController.add(state.position);
    }
    if (state.status == PlaybackStatus.error) {
      final errTrack = state.track;
      if (errTrack != null && _resolverRegistry.hasStreamingMapping(errTrack)) {
        _evictSpecCacheForTrack(errTrack);
        final rawErr = state.lastError?.trim();
        final svcErr = audioService.lastError?.trim();
        final msg = (rawErr != null && rawErr.isNotEmpty)
            ? rawErr
            : ((svcErr != null && svcErr.isNotEmpty)
                ? svcErr
                : '串流播放失敗，請重試');
        if (_isAuthRequiredError(msg)) {
          final errKey = _tryDeriveKey(errTrack);
          if (errKey != null &&
              !streamingManager.authManager.isGuestPlaybackCapable(
                errKey.providerId,
              )) {
            streamingManager.authManager.tripAuthRequired(
              errKey.providerId,
              msg,
            );
          }
        }
        if (_epoch > 0 && _notifiedErrorForEpoch != _epoch) {
          _notifiedErrorForEpoch = _epoch;
          onError?.call(errTrack, msg, false);
        }
      }
    }
    _syncStablePlayTimer(state);
    _maybePreResolveNext(state, state.position);
  }

  void _handleStateUpdate(PlaybackState state) {
    if (_disposed) return;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
    if (state.status == PlaybackStatus.paused ||
        state.status == PlaybackStatus.stopped ||
        state.status == PlaybackStatus.uninitialized) {
      ytDlpService.stopFfmpegProxy(exceptRequestId: _resolvingRequestId);
    } else if (state.status == PlaybackStatus.ended ||
        state.status == PlaybackStatus.error) {
      ytDlpService.stopFfmpegProxy();
    }
    if (state.status == PlaybackStatus.ended) {
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
    }
    if (state.status == PlaybackStatus.playing) {
      final playingTrack = state.track;
      if (playingTrack != null && !isStreamingTrack(playingTrack)) {
        _activeYtmAttempt = null;
        _activeTidalDashAttempt = null;
        ytDlpService.stopFfmpegProxy();
      }
    }
    if (state.status == PlaybackStatus.error) {
      final errTrack = state.track;
      if (errTrack != null && isStreamingTrack(errTrack)) {
        _cache.remove(errTrack.id);
        final rawErr = state.lastError?.trim();
        final svcErr = audioService.lastError?.trim();
        final msg = (rawErr != null && rawErr.isNotEmpty)
            ? rawErr
            : ((svcErr != null && svcErr.isNotEmpty)
                ? svcErr
                : '串流播放失敗，請重試');

        final attempt = _activeYtmAttempt;
        if (attempt != null && _canAttempt403Recovery(attempt, errTrack, msg)) {
          attempt.recovering = true;
          unawaited(_recoverFromYtm403(attempt));
          return;
        }

        final tidalAttempt = _activeTidalDashAttempt;
        if (tidalAttempt != null &&
            !_disposed &&
            !tidalAttempt.cancel.isCancelled &&
            tidalAttempt.requestId == _epoch &&
            tidalAttempt.track.id == errTrack.id) {
          if (tidalAttempt.recovering) return;
          if (tidalAttempt.remainingTiers.isNotEmpty) {
            tidalAttempt.recovering = true;
            unawaited(
              _recoverTidalDashPlayback(tidalAttempt, runtimeError: msg),
            );
            return;
          }
        }

        _activeYtmAttempt = null;
        _activeTidalDashAttempt = null;
        if (_epoch > 0 && _notifiedErrorForEpoch != _epoch) {
          _notifiedErrorForEpoch = _epoch;
          onError?.call(errTrack, msg, false);
        }
      }
    }
    _maybePreResolveNext(state, state.position);
  }

  void _handlePositionTick(Duration position) {
    if (_disposed) return;
    if (isExternalBackendActive) return;
    if (!_positionController.isClosed) {
      _positionController.add(position);
    }
    _maybePreResolveNext(currentState, position);
  }

  String? _tryExtractYtmVideoId(TrackInfo track) =>
      YouTubeMusicProvider.tryExtractCleanVideoId(
        track.id,
        filePath: track.filePath,
      );

  @visibleForTesting
  static bool shouldTriggerPreDecode(Duration position, Duration duration) {
    if (duration <= Duration.zero || position < Duration.zero) return false;
    final remaining = duration - position;
    if (remaining < Duration.zero) return false;
    final progress = position.inMilliseconds / duration.inMilliseconds;
    if (duration <= _shortTrackThreshold) {
      return progress > _preDecodeProgressRatio;
    }
    return remaining <= _preResolveThreshold ||
        progress > _preDecodeProgressRatio;
  }

  @visibleForTesting
  bool isExternalTrackForTesting(TrackInfo track) => _isExternalTrack(track);

  bool _isExternalTrack(TrackInfo track) {
    if (track.filePath != null && track.filePath!.trim().isNotEmpty) {
      return false;
    }
    final key = _tryDeriveKey(track);
    if (key != null) {
      if (key.providerId == 'apple_music') {
        final resolver = _resolverRegistry.resolverFor(key.providerId);
        return resolver is! LegacyStreamingProviderResolver;
      }
      final resolver = _resolverRegistry.resolverFor(key.providerId);
      if (resolver != null &&
          resolver is! LocalStreamResolver &&
          !resolver.capabilities.supportsL1UrlCache &&
          !resolver.capabilities.supportsL2HeadCache &&
          !resolver.capabilities.requiresRangeChunking) {
        return true;
      }
    }
    return false;
  }

  void _prepareExternalHandoffForNext(
    TrackInfo nextTrack, {
    required int expectedEpoch,
  }) {
    if (_preparedExternalHandoffTrackId == nextTrack.id &&
        _preparedExternalHandoffEpoch == expectedEpoch) {
      return;
    }
    _preparedExternalHandoffTrackId = nextTrack.id;
    _preparedExternalHandoffEpoch = expectedEpoch;
    _preparedStandbyTrackId = null;
    _preparedStandbyEpoch = -1;
    _preparedStandbySpec = null;
    if (_externalBackend is AppleMusicPlaybackBackend) {
      unawaited(
        _externalBackend.prepareExternalHandoff(
          nextTrack,
          epoch: expectedEpoch,
        ),
      );
    }
  }

  void _prepareNativeStandbyForNext(
    TrackInfo nextTrack, {
    required int expectedEpoch,
  }) {
    if (_preparedStandbyTrackId == nextTrack.id &&
        _nativeBackend.isStandbyReady) {
      return;
    }
    if (_attemptedStandbyTrackId == nextTrack.id &&
        _attemptedStandbyEpoch == expectedEpoch) {
      return;
    }

    final fp = nextTrack.filePath?.trim();
    if (fp != null && fp.isNotEmpty) {
      _attemptedStandbyTrackId = nextTrack.id;
      _attemptedStandbyEpoch = expectedEpoch;
      final key = _tryDeriveKey(nextTrack) ?? StreamKey('local', fp, 'default');
      final localSpec = LocalFileSpec(key: key, path: fp);
      _preparedStandbyTrackId = nextTrack.id;
      _preparedStandbyEpoch = expectedEpoch;
      _preparedStandbySpec = localSpec;
      unawaited(_prepareNativeBackendStandby(localSpec, nextTrack, expectedEpoch));
      return;
    }

    final nextKey = _tryDeriveKey(nextTrack);
    if (nextKey == null) return;
    if (streamingManager.isPlaybackAuthBlocked(nextKey.providerId)) return;
    final resolver = _resolverRegistry.resolverFor(nextKey.providerId);
    if (resolver == null) return;

    _attemptedStandbyTrackId = nextTrack.id;
    _attemptedStandbyEpoch = expectedEpoch;
    unawaited(_runNativeStandbyPreDecode(nextTrack, nextKey, expectedEpoch));
  }

  Future<void> _runNativeStandbyPreDecode(
    TrackInfo nextTrack,
    StreamKey nextKey,
    int expectedEpoch,
  ) async {
    if (_disposed || expectedEpoch != _epoch) return;

    final cachedSpec = _peekCachedSpec(nextKey);
    if (cachedSpec != null) {
      if (cachedSpec is ExternalBackendSpec) {
        _prepareExternalHandoffForNext(nextTrack, expectedEpoch: expectedEpoch);
        return;
      }
      final resolvedTrack = cachedSpec.audioFormat != null
          ? nextTrack.copyWith(format: cachedSpec.audioFormat)
          : nextTrack;
      _preparedStandbyTrackId = nextTrack.id;
      _preparedStandbyEpoch = expectedEpoch;
      _preparedStandbySpec = cachedSpec;
      await _prepareNativeBackendStandby(cachedSpec, resolvedTrack, expectedEpoch);
      return;
    }

    if (_inFlightPreResolves.contains(nextTrack.id)) return;

    final useLegacySpecCache = _usesLegacyCoordinatorSpecCache(nextKey);
    final cancel = CancellationToken();
    Timer? timeoutTimer;
    if (resolveTimeout > Duration.zero) {
      timeoutTimer = Timer(resolveTimeout, cancel.cancel);
    }

    _inFlightPreResolves.add(nextTrack.id);
    _preResolveCancelTokens[nextTrack.id] = (
      providerId: nextKey.providerId,
      token: cancel,
    );

    try {
      final StreamSourceSpec spec;
      if (_useCustomResolverRegistry) {
        spec = await _singleFlight.resolve(
          nextKey,
          cancelToken: cancel,
          bypassCache: useLegacySpecCache,
          legacyTrack: nextTrack,
        );
      } else {
        spec = await streamingManager.resolveSourceSpec(
          nextKey,
          cancelToken: cancel,
          bypassCache: useLegacySpecCache,
          legacyTrack: nextTrack,
        );
      }

      if (_disposed || cancel.isCancelled || expectedEpoch != _epoch) {
        return;
      }
      if (spec is ExternalBackendSpec) {
        _prepareExternalHandoffForNext(nextTrack, expectedEpoch: expectedEpoch);
        return;
      }
      if (useLegacySpecCache) {
        _storeSpecCache(nextTrack, spec);
      }
      final resolvedTrack = spec.audioFormat != null
          ? nextTrack.copyWith(format: spec.audioFormat)
          : nextTrack;
      _preparedStandbyTrackId = nextTrack.id;
      _preparedStandbyEpoch = expectedEpoch;
      _preparedStandbySpec = spec;
      await _prepareNativeBackendStandby(spec, resolvedTrack, expectedEpoch);
    } catch (_) {
      // Pre-decode failures and cancellations are silent; manual skip falls back.
    } finally {
      timeoutTimer?.cancel();
      _inFlightPreResolves.remove(nextTrack.id);
      final current = _preResolveCancelTokens[nextTrack.id];
      if (current != null && identical(current.token, cancel)) {
        _preResolveCancelTokens.remove(nextTrack.id);
      }
    }
  }

  Future<void> _prepareNativeBackendStandby(
    StreamSourceSpec spec,
    TrackInfo track,
    int expectedEpoch,
  ) async {
    if (_disposed || expectedEpoch != _epoch) return;
    try {
      await _nativeBackend.prepareStandby(spec, track, epoch: expectedEpoch);
    } catch (_) {
      if (_preparedStandbyTrackId == track.id &&
          _preparedStandbyEpoch == expectedEpoch) {
        _preparedStandbyTrackId = null;
        _preparedStandbyEpoch = -1;
        _preparedStandbySpec = null;
      }
    }
  }

  void _maybePreResolveNext(PlaybackState state, Duration position) {
    if (_disposed) return;
    if (state.status != PlaybackStatus.playing) return;
    final currentTrack = state.track;
    if (currentTrack == null) return;
    if (position < Duration.zero) return;

    final activeQueue = queue;
    if (activeQueue.length <= 1) return;

    int idx = -1;
    if (_sharedQueue.isNotEmpty &&
        _sharedQueueIndex >= 0 &&
        _sharedQueueIndex < activeQueue.length &&
        activeQueue[_sharedQueueIndex].id == currentTrack.id) {
      idx = _sharedQueueIndex;
    }
    if (idx < 0) {
      idx = PlaybackPersistenceService.findTrackIndex(
        activeQueue,
        currentTrack,
      );
    }
    if (idx < 0) return;

    final nextTrack = activeQueue[(idx + 1) % activeQueue.length];
    final withinEndWindow = shouldTriggerPreDecode(
      position,
      currentTrack.duration,
    );

    if (_useResolverPipeline) {
      if (!withinEndWindow) return;
      if (_isExternalTrack(nextTrack)) {
        _prepareExternalHandoffForNext(nextTrack, expectedEpoch: _epoch);
        return;
      }
      _prepareNativeStandbyForNext(nextTrack, expectedEpoch: _epoch);
      return;
    }

    if (!isStreamingTrack(nextTrack)) return;
    final nextProvider = streamingManager.resolveProviderForTrack(nextTrack);
    if (nextProvider != null &&
        streamingManager.isPlaybackAuthBlocked(nextProvider.kind)) {
      return;
    }

    if (_isYouTubeMusicTrack(nextTrack)) {
      final stablyPlaying = position >= _ytmStablePlayPreloadPosition;
      if (!withinEndWindow && !stablyPlaying) return;

      final videoId = _tryExtractYtmVideoId(nextTrack);
      if (videoId == null) return;
      if (ytDlpService.getCachedStream(videoId) != null) return;
      if (getCachedStream(nextTrack.id) != null) return;
      if (_inFlightPreResolves.contains(nextTrack.id)) return;

      final transitionKey = '${currentTrack.id}->${nextTrack.id}';
      if (!_preloadedTransitionKeys.add(transitionKey)) return;
      if (_preloadedTransitionKeys.length > _maxCacheEntries) {
        _preloadedTransitionKeys.remove(_preloadedTransitionKeys.first);
      }

      _inFlightPreResolves.add(nextTrack.id);
      unawaited(_preloadYtmTrackSilently(nextTrack, videoId));
      return;
    }

    // Tidal DASH proxy is single-session; skip background pre-resolve so it never
    // touches or cancels FfmpegAudioProxy while a track is playing.
    if (_isTidalTrack(nextTrack)) return;

    if (!withinEndWindow) return;
    if (getCachedStream(nextTrack.id) != null) return;
    if (_inFlightPreResolves.contains(nextTrack.id)) return;

    _inFlightPreResolves.add(nextTrack.id);
    unawaited(_preResolveTrackSilently(nextTrack));
  }

  Future<void> _preloadYtmTrackSilently(TrackInfo track, String videoId) async {
    try {
      await ytDlpService.preloadVideo(videoId);
    } catch (_) {
      // Preload failures are silent; foreground playback will retry with UI feedback.
    } finally {
      _inFlightPreResolves.remove(track.id);
    }
  }

  Future<void> _preResolveTrackSilently(TrackInfo track) async {
    try {
      final result = await streamingManager
          .resolveStreamForTrack(track, timeout: resolveTimeout)
          .timeout(resolveTimeout);
      if (!_disposed) {
        _storeCache(track, result);
      }
    } catch (_) {
      // Pre-resolution failures are silent; foreground playback will retry with UI feedback.
    } finally {
      _inFlightPreResolves.remove(track.id);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelPendingWork();
    _loadingExternalState = null;
    _resolvingRequestId = null;
    _activeYtmAttempt = null;
    _activeTidalDashAttempt = null;
    _recoveryFuture = null;
    _positionSub?.cancel();
    _positionSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _nativeStateSub?.cancel();
    _nativeStateSub = null;
    _externalStateSub?.cancel();
    _externalStateSub = null;
    if (_ownsExternalBackend) {
      _externalBackend.dispose();
    }
    if (!_positionController.isClosed) {
      unawaited(_positionController.close());
    }
    if (!_stateController.isClosed) {
      unawaited(_stateController.close());
    }
    audioService.setStreamingTrackHandler(null);
    audioService.setPlaybackInterruptHandler(null);
    streamingManager.removeAuthRequiredListener(_onProviderAuthRequired);
    if (!_useResolverPipeline) {
      unawaited(ytDlpService.stopAll());
    }
    _cache.clear();
    _specCache.clear();
    if (_useCustomResolverRegistry) {
      _singleFlight.cancelAll();
      _l1Cache.clearMemory();
    }
    _inFlightPreResolves.clear();
    _preResolveCancelTokens.clear();
    _preloadedTransitionKeys.clear();
    _clearStandbyTracking();
    _sharedQueue.clear();
  }
}

/// Unified [AudioService] facade passed to UI views so transport controls,
/// shared queues, state, position, and SignalPath route transparently between
/// native Rust playback and the external Apple Music backend while keeping
/// Apple Music strictly isolated from native `AudioService.playStream*`.
class CoordinatingAudioService
    implements AudioService, DualDeckAudioService {
  final AudioService inner;
  final StreamingPlaybackCoordinator coordinator;
  final bool disposeInner;

  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<SignalPath> _signalPathController =
      StreamController<SignalPath>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  StreamSubscription<PlaybackState>? _coordinatorStateSub;
  StreamSubscription<SignalPath>? _innerSignalPathSub;
  StreamSubscription<Duration>? _coordinatorPositionSub;
  bool _wasExternalActive = false;
  bool _disposed = false;

  CoordinatingAudioService({
    required this.inner,
    required this.coordinator,
    this.disposeInner = false,
  }) {
    _wasExternalActive = coordinator.isExternalBackendActive;
    _coordinatorStateSub = coordinator.stateStream.listen((state) {
      if (_disposed) return;
      if (!_stateController.isClosed) {
        _stateController.add(state);
      }
      final isExternal = coordinator.isExternalBackendActive;
      if (isExternal && !_signalPathController.isClosed) {
        _signalPathController.add(_externalSignalPath(state.track));
      } else if (!isExternal &&
          _wasExternalActive &&
          !_signalPathController.isClosed) {
        _signalPathController.add(inner.currentSignalPath);
      }
      _wasExternalActive = isExternal;
    });
    _innerSignalPathSub = inner.signalPathStream.listen((path) {
      if (_disposed || coordinator.isExternalBackendActive) return;
      if (!_signalPathController.isClosed) {
        _signalPathController.add(path);
      }
    });
    _coordinatorPositionSub = coordinator.positionStream.listen((pos) {
      if (_disposed) return;
      if (!_positionController.isClosed) {
        _positionController.add(pos);
      }
    });
  }

  static SignalPath _externalSignalPath(TrackInfo? track) {
    final trackTitle = track?.title.trim();
    final detailTitle = (trackTitle != null && trackTitle.isNotEmpty)
        ? 'MusicKit JS · $trackTitle'
        : 'MusicKit JS';
    return SignalPath(
      overallQuality: SignalQuality.highQuality,
      description: 'Apple Music（MusicKit JS 外部播放器，系統輸出）',
      dspBypassed: true,
      nodes: <SignalPathNode>[
        SignalPathNode(
          title: '來源',
          subtitle: 'Apple Music（DRM 受保護串流）',
          detail: detailTitle,
          quality: SignalQuality.highQuality,
        ),
        const SignalPathNode(
          title: '輸出',
          subtitle: '外部播放宿主（WebView2 / 系統音訊）',
          detail: '繞過本地 ByteStreamSource 與 DSP 管線',
          quality: SignalQuality.highQuality,
        ),
      ],
    );
  }

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  Stream<SignalPath> get signalPathStream => _signalPathController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  bool get isNativeBound => inner.isNativeBound;

  @override
  ConnectionMode get connectionMode => inner.connectionMode;

  @override
  String? get activeServerUrl => inner.activeServerUrl;

  @override
  PlaybackState get currentState => coordinator.currentState;

  @override
  SignalPath get currentSignalPath => coordinator.isExternalBackendActive
      ? _externalSignalPath(coordinator.currentState.track)
      : inner.currentSignalPath;

  @override
  List<LyricLine> get currentLyrics => inner.currentLyrics;

  @override
  List<TrackInfo> get queue => coordinator.queue;

  @override
  Map<String, PlaybackState> get devicePlaybackStates =>
      inner.devicePlaybackStates;

  @override
  Map<String, PlaybackState> get zonePlaybackStates => inner.zonePlaybackStates;

  @override
  String? get activeDeviceId => inner.activeDeviceId;

  @override
  bool get isSystemOutputActive => inner.isSystemOutputActive;

  @override
  String? get lastError => coordinator.isExternalBackendActive
      ? coordinator.currentState.lastError
      : inner.lastError;

  @override
  int get preferredBufferFrames => inner.preferredBufferFrames;

  @override
  bool get isStrictBitPerfect => inner.isStrictBitPerfect;

  @override
  DsdOutputModeOption get dsdOutputMode => inner.dsdOutputMode;

  ValueListenable<Float32List> get visualizerBandsNotifier =>
      inner.visualizerBandsNotifier;

  void setVisualizerSettingEnabled(bool enabled) =>
      inner.setVisualizerSettingEnabled(enabled);

  void setNowPlayingVisible(bool visible) =>
      inner.setNowPlayingVisible(visible);

  void setWindowMinimized(bool minimized) => inner.setWindowMinimized(minimized);

  @override
  Future<bool> setBufferFrames(int frames) => inner.setBufferFrames(frames);

  @override
  Future<void> setDeviceVolume(String deviceId, double volume) =>
      inner.setDeviceVolume(deviceId, volume);

  @override
  Future<void> toggleDevicePlayPause(String deviceId) =>
      inner.toggleDevicePlayPause(deviceId);

  @override
  Future<void> toggleZonePlayPause(String zoneId) =>
      inner.toggleZonePlayPause(zoneId);

  @override
  Future<int> scanDirectory(String path) => inner.scanDirectory(path);

  @override
  Future<List<TrackInfo>> searchLibrary(String query) =>
      inner.searchLibrary(query);

  @override
  Future<void> play({TrackInfo? track}) async {
    if (track != null) {
      if (coordinator.shouldInterceptTrack(track)) {
        final inQueue =
            coordinator.hasSharedQueue &&
            PlaybackPersistenceService.findTrackIndex(
                  coordinator.queue,
                  track,
                ) >=
                0;
        return coordinator.playTrack(
          track,
          queueContext: inQueue ? List<TrackInfo>.from(coordinator.queue) : null,
        );
      }
      await coordinator.stopExternalIfActive();
      if (coordinator.hasSharedQueue &&
          PlaybackPersistenceService.findTrackIndex(
                coordinator.queue,
                track,
              ) <
              0) {
        coordinator.clearSharedQueue();
      }
      return inner.play(track: track);
    }
    if (coordinator.isExternalBackendActive) {
      return coordinator.resume();
    }
    return inner.play();
  }

  @override
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) => inner.playStreamUrl(
    track: track,
    streamUrl: streamUrl,
    headers: headers,
    hintExtension: hintExtension,
  );

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) => inner.playStreamUrlAsync(
    track: track,
    streamUrl: streamUrl,
    headers: headers,
    hintExtension: hintExtension,
    requestId: requestId,
  );

  @override
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter Native AudioService',
      );
    }
    return inner.playStreamSpecAsync(track, spec, epoch: epoch);
  }

  @override
  Future<void> prepareStandbySpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    int? epoch,
  }) {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter Native AudioService',
      );
    }
    return inner.prepareStandbySpecAsync(track, spec, epoch: epoch);
  }

  @override
  Future<bool> skipToStandby({int? epoch}) {
    if (coordinator.isExternalBackendActive) {
      return Future<bool>.value(false);
    }
    return inner.skipToStandby(epoch: epoch);
  }

  @override
  bool get isStandbyDeckReady =>
      coordinator.isExternalBackendActive ? false : inner.isStandbyDeckReady;

  @override
  void setStreamingTrackHandler(StreamingTrackHandler? handler) =>
      inner.setStreamingTrackHandler(handler);

  @override
  void setPlaybackInterruptHandler(VoidCallback? handler) =>
      inner.setPlaybackInterruptHandler(handler);

  @override
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) =>
      inner.beginOptimisticTrackLoad(track, queue: queue);

  @override
  void failOptimisticTrackLoad(TrackInfo track, String message) =>
      inner.failOptimisticTrackLoad(track, message);

  @override
  Future<void> cancelPendingPlayback() => inner.cancelPendingPlayback();

  @override
  Future<void> cancelPendingPlaybackAtEpoch(int epoch) =>
      inner.cancelPendingPlaybackAtEpoch(epoch);

  @override
  Future<void> restorePlaybackSession({
    required TrackInfo track,
    required Duration position,
    List<TrackInfo>? queue,
    int? queueIndex,
    double? volume,
    bool? isMuted,
  }) => inner.restorePlaybackSession(
    track: track,
    position: position,
    queue: queue,
    queueIndex: queueIndex,
    volume: volume,
    isMuted: isMuted,
  );

  @override
  Future<void> pause() => coordinator.pause();

  @override
  Future<void> resume() => coordinator.resume();

  @override
  Future<void> togglePlayPause() => coordinator.togglePlayPause();

  @override
  Future<void> stop() => coordinator.stop();

  @override
  Future<void> seek(Duration position) => coordinator.seek(position);

  @override
  Future<void> setVolume(double volume) => coordinator.setVolume(volume);

  @override
  Future<void> toggleMute() => coordinator.toggleMute();

  @override
  Future<void> next() => coordinator.next();

  @override
  Future<void> previous() => coordinator.previous();

  @override
  Future<void> toggleDspBypass() => inner.toggleDspBypass();

  @override
  void setSimulatedQuality(SignalQuality quality) =>
      inner.setSimulatedQuality(quality);

  @override
  Future<void> reconnectDevice() => inner.reconnectDevice();

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    if (coordinator.isExternalBackendActive) {
      final state = coordinator.currentState;
      return <String, dynamic>{
        'state_code': state.status.code,
        'state_name': state.status.name,
        'position_ms': state.position.inMilliseconds,
        'duration_ms': state.track?.duration.inMilliseconds ?? 0,
        'clock_source': state.clockSource,
        'seek_epoch': state.seekEpoch,
        'is_seeking': state.isSeeking,
        'volume': state.volume,
        'is_muted': state.isMuted,
      };
    }
    return inner.getPlaybackState();
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) => inner.getArtwork(trackId, path: path, maxDim: maxDim);

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) => inner.setUserCover(trackId, imagePath, path: path);

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) =>
      inner.clearUserCover(trackId, path: path);

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) => inner.rescanTags(directory: directory, force: force);

  @override
  Future<Map<String, dynamic>?> getLyrics(String trackId, {String? path}) =>
      inner.getLyrics(trackId, path: path);

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) => inner.setUserLyrics(trackId, filePath, path: path);

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) =>
      inner.clearUserLyrics(trackId, path: path);

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100}) =>
      inner.getAlbums(limit: limit);

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) =>
      inner.getAlbumDetail(albumId);

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) =>
      inner.getArtistDetail(artistId);

  @override
  Future<int> deduplicateLibrary() => inner.deduplicateLibrary();

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) => inner.enrichLibraryCredits(
    musicBrainzBaseUrl: musicBrainzBaseUrl,
    discogsBaseUrl: discogsBaseUrl,
  );

  @override
  Future<DspPipelineConfigModel> getDspConfig() => inner.getDspConfig();

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) =>
      inner.setDspConfig(config);

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) =>
      inner.importAutoEqProfile(autoEqTxt);

  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() => inner.listAudioDevices();

  @override
  Future<void> selectAudioDevice(String? deviceId, {int backendIndex = -1}) =>
      inner.selectAudioDevice(deviceId, backendIndex: backendIndex);

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() => inner.getOutputInfo();

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() =>
      inner.listDeviceCapabilities();

  @override
  Future<void> setStrictBitPerfect(bool enabled) =>
      inner.setStrictBitPerfect(enabled);

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) =>
      inner.setDsdOutputMode(mode);

  @override
  Future<List<AudioZoneInfo>> listZones() => inner.listZones();

  @override
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  }) => inner.discoverZones(
    ssdpAddr: ssdpAddr,
    airplayAddrs: airplayAddrs,
    clockSyncAddr: clockSyncAddr,
  );

  @override
  Future<void> groupZones(String groupId, List<String> zoneIds) =>
      inner.groupZones(groupId, zoneIds);

  @override
  Future<void> setZoneVolume(String zoneId, double volume) =>
      inner.setZoneVolume(zoneId, volume);

  @override
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  }) => inner.syncZoneClock(zoneId, clockAddr: clockAddr);

  @override
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  }) => inner.castToZone(zoneId, action, mediaUri: mediaUri);

  @override
  Future<List<ProviderStatusInfo>> listProviders() => inner.listProviders();

  @override
  Future<bool> configureProvider(String kind, Map<String, dynamic> config) =>
      inner.configureProvider(kind, config);

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() => inner.startTidalPkce();

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) =>
      inner.completeTidalPkce(code, codeVerifier);

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) =>
      inner.syncProvider(kind);

  @override
  Future<List<UserProfileInfo>> listProfiles() => inner.listProfiles();

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) => inner.createProfile(name, avatarColor: avatarColor);

  @override
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  }) => inner.updateProfile(
    profileId,
    name: name,
    avatarColor: avatarColor,
    isDefault: isDefault,
  );

  @override
  Future<void> switchProfile(String profileId) =>
      inner.switchProfile(profileId);

  @override
  Future<bool> deleteProfile(String profileId) =>
      inner.deleteProfile(profileId);

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() =>
      inner.initiateHostPairing();

  @override
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) => inner.discoverLanServers(
    multicastHost: multicastHost,
    port: port,
    timeout: timeout,
  );

  @override
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  }) => inner.pairAndConnectRemote(
    baseUrl: baseUrl,
    pin: pin,
    deviceName: deviceName,
    allowSelfSignedTls: allowSelfSignedTls,
  );

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) => inner.connectWanDirect(
    httpsBaseUrl: httpsBaseUrl,
    bearerToken: bearerToken,
    pin: pin,
    allowSelfSignedTls: allowSelfSignedTls,
  );

  @override
  Future<void> switchToLocalMode() => inner.switchToLocalMode();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _coordinatorStateSub?.cancel();
    _coordinatorStateSub = null;
    _innerSignalPathSub?.cancel();
    _innerSignalPathSub = null;
    _coordinatorPositionSub?.cancel();
    _coordinatorPositionSub = null;
    if (!_positionController.isClosed) {
      unawaited(_positionController.close());
    }
    if (!_signalPathController.isClosed) {
      unawaited(_signalPathController.close());
    }
    if (!_stateController.isClosed) {
      unawaited(_stateController.close());
    }
    if (disposeInner) {
      inner.dispose();
    }
  }
}
