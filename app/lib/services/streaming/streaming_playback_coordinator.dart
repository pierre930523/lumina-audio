import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/audio_output_info.dart';
import '../../models/ingestion_models.dart';
import '../../models/lyric.dart';
import '../../models/playback_state.dart';
import '../../models/protocol/lumina_error.dart';
import '../../models/protocol/protocol_models.dart';
import '../../models/recommendation_models.dart';
import '../../models/signal_path.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';
import '../../models/studio_models.dart';
import '../audio_service.dart';
import '../playback/playback_backend.dart' as proto_backend;
import '../playback/playback_controller.dart';
import '../playback_persistence_service.dart';
import 'autoplay_controller.dart';
import 'l1_stream_cache.dart';
import 'playback_backend.dart';
import 'pot_sidecar_manager.dart';
import 'providers/apple_music_provider.dart';
import 'providers/tidal_provider.dart';
import 'providers/youtube_music_provider.dart';
import 'single_flight_resolver.dart';
import 'stream_resolver.dart';
import 'streaming_manager.dart';
import 'yt_dlp_service.dart';

part 'playback_coordinator/coordinating_audio_service.dart';
part 'playback_coordinator/coordinating_audio_service_delegates.dart';
part 'playback_coordinator/coordinating_audio_service_focus_delegates.dart';
part 'playback_coordinator/coordinating_audio_service_grouping_delegates.dart';
part 'playback_coordinator/coordinating_audio_service_step4_delegates.dart';
part 'playback_coordinator/coordinating_audio_service_step5_delegates.dart';
part 'playback_coordinator/coordinator_legacy_recovery.dart';
part 'playback_coordinator/coordinator_models.dart';
part 'playback_coordinator/coordinator_prefetch_and_standby.dart';
part 'playback_coordinator/coordinator_queue_and_cache.dart';
part 'playback_coordinator/coordinator_resolve_and_recovery.dart';
part 'playback_coordinator/coordinator_resolve_legacy.dart';
part 'playback_coordinator/coordinator_standby.dart';
part 'playback_coordinator/coordinator_state_events.dart';
part 'playback_coordinator/coordinator_state_handlers.dart';
part 'playback_coordinator/coordinator_step4_queue_ops.dart';
part 'playback_coordinator/coordinator_transport.dart';

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
  static const Duration defaultRapidSkipWindow = Duration(milliseconds: 300);

  final AudioService audioService;
  final StreamingManager streamingManager;
  final YtDlpService ytDlpService;
  final AutoplayController? autoplayController;
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
  final Duration rapidSkipWindow;
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
  final StreamController<TrackInfo> _trackChangedController =
      StreamController<TrackInfo>.broadcast();
  final StreamController<List<TrackInfo>> _queueUpdatedController =
      StreamController<List<TrackInfo>>.broadcast();

  final List<TrackInfo> _sharedQueue = <TrackInfo>[];
  int _sharedQueueIndex = -1;
  PlaybackState? _loadingExternalState;
  PlaybackState? _latestCoordinatorState;
  TrackInfo? _pausedPendingTrack;
  int _suppressStoppedAtEpoch = -1;
  bool _switchingBackends = false;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<PlaybackState>? _nativeStateSub;
  StreamSubscription<PlaybackState>? _externalStateSub;
  StreamSubscription<void>? _autoplayChangesSub;

  PlaybackBackend? _activeBackend;
  int _epoch = 0;
  int? _resolvingRequestId;
  int _resolvingGeneration = 0;
  int _notifiedErrorForEpoch = -1;
  TrackInfo? _lastActivePlayingTrack;
  TrackInfo? _lastTransitionTrack;
  int _lastTransitionSwapGen = 0;
  int _lastObservedBackendSwapGen = 0;
  bool _hadPreviousTransition = false;
  bool _suppressAutoplayChangeQueueEmit = false;
  String? _pendingUserInitiatedSkipTrackId;
  TrackInfo? _pendingSwapZeroPosTrack;
  int _pendingSwapZeroPosGen = -1;
  Duration? _pendingSwapInitialPos;
  String? _handledEndedTrackId;
  int _handledEndedEpoch = -1;
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
  DateTime? _lastSkipAt;
  bool _backendCancelSentForBurst = false;
  String? _pendingOptimisticTrackId;
  int _pendingOptimisticEpoch = -1;
  TrackInfo? _burstAbandonedTrack;
  bool _burstAbandonedWasAuto = false;
  Duration _burstAbandonedPlayed = Duration.zero;
  bool _hasDeferredAutoplaySkip = false;
  bool _disposed = false;

  StreamingPlaybackCoordinator({
    required this.audioService,
    required this.streamingManager,
    YtDlpService? ytDlpService,
    this.autoplayController,
    StreamResolverRegistry? resolverRegistry,
    PlaybackBackend? nativeBackend,
    PlaybackBackend? externalBackend,
    ExternalPlaybackBridge? externalPlaybackBridge,
    bool? useResolverPipeline,
    this.resolveTimeout = const Duration(seconds: 15),
    this.debounceDelay = const Duration(milliseconds: 130),
    this.rapidSkipWindow = defaultRapidSkipWindow,
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
    _initListenersImpl();
  }

  static AppleMusicCredentials? _appleCredentialsFor(StreamingManager manager) =>
      _appleCredentialsForImpl(manager);

  int get activeRequestId => _epoch;
  int get currentEpoch => _epoch;

  int _nextEpoch() {
    final serviceEpoch = audioService.currentState.playbackEpoch;
    if (serviceEpoch > _epoch) _epoch = serviceEpoch;
    return ++_epoch;
  }

  PlaybackBackend? get activeBackend => _activeBackend;
  String? get preparedStandbyTrackId => _preparedStandbyTrackId;
  bool get isStandbyReady =>
      _preparedStandbyTrackId != null && _nativeBackend.isStandbyReady;
  String? get preparedExternalHandoffTrackId => _preparedExternalHandoffTrackId;
  bool get isExternalHandoffPrepared => _preparedExternalHandoffTrackId != null;
  bool get isExternalBackendActive =>
      _useResolverPipeline &&
      (_loadingExternalState != null ||
          (_activeBackend != null &&
              !identical(_activeBackend, _nativeBackend)));
  bool get hasSharedQueue =>
      (autoplayController?.combinedQueue.isNotEmpty ?? false) ||
      _sharedQueue.isNotEmpty;
  List<TrackInfo> get queue {
    final ap = autoplayController;
    if (ap != null && ap.combinedQueue.isNotEmpty) return ap.combinedQueue;
    return _sharedQueue.isNotEmpty ? _sharedQueue : audioService.queue;
  }

  Stream<PlaybackState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<TrackInfo> get trackChangedStream => _trackChangedController.stream;
  Stream<List<TrackInfo>> get queueUpdatedStream =>
      _queueUpdatedController.stream;

  PlaybackState get currentState => _getCurrentStateImpl();

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
  }) => _setQueueContextInternal(
    queueContext,
    currentTrack: currentTrack,
    queueIndex: queueIndex,
    resetLookaheadOnChange: resetLookaheadOnChange,
    syncAutoplayCurrentTrack: true,
  );

  void clearSharedQueue() => _clearSharedQueueImpl();
  int enqueueTracks(List<TrackInfo> tracks) => _enqueueTracksImpl(tracks);
  void syncTrackPreference(String trackId, int preference) =>
      _syncTrackPreferenceImpl(trackId, preference);
  void syncArtistPreference(String artist, int preference) =>
      _syncArtistPreferenceImpl(artist, preference);
  void _onProviderAuthRequired(String providerId, String reason) {
    if (!_disposed) cancelPrefetchForProvider(providerId);
  }
  void cancelPrefetchForProvider(String providerId) =>
      _cancelPrefetchForProviderImpl(providerId);
  Future<void> stopExternalIfActive() async =>
      await _interruptExternalBackendIfActive();

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
    final native = _nativeBackend;
    if (_disposed ||
        _switchingBackends ||
        (native is NativePlaybackBackend && native.isInvokingStop)) {
      return;
    }
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();
    if (_useResolverPipeline) {
      final fut = _interruptExternalBackendIfActive();
      if (fut != null) unawaited(fut);
      return;
    }
    ytDlpService.stopFfmpegProxy();
  }

  static bool isStreamingTrack(TrackInfo track) =>
      AudioService.isStreamingTrackId(track.id) || _isYouTubeMusicTrack(track);

  bool _isFfmpegProxyUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
      return false;
    }
    final proxyPort = ytDlpService.ffmpegProxy.port;
    if (proxyPort != null && uri.port == proxyPort) return true;
    return uri.path.startsWith('/stream/') &&
        (uri.path.endsWith('.wav') || uri.path.endsWith('.flac'));
  }

  @visibleForTesting
  static Duration computeCacheTtl(
    TrackInfo track,
    String resolvedUrl,
    DateTime now,
  ) => _computeCacheTtlImpl(track, resolvedUrl, now);

  ResolvedStreamResult? getCachedStream(String trackId) =>
      _getCachedStreamImpl(trackId);

  bool canPrefetchTrack(TrackInfo track) {
    if (_disposed || !_useResolverPipeline) return false;
    if (track.filePath != null && track.filePath!.trim().isNotEmpty) {
      return false;
    }
    if (!shouldInterceptTrack(track)) return false;
    final key = _tryDeriveKey(track);
    if (key == null) return false;
    if (streamingManager.isPlaybackAuthBlocked(key.providerId)) return false;
    return _resolverRegistry.resolverFor(key.providerId)?.capabilities.supportsL1UrlCache ??
        false;
  }

  Future<void> prefetchTrack(
    TrackInfo track, {
    CancellationToken? cancelToken,
  }) => _prefetchTrackInternal(track, cancelToken: cancelToken);

  void requestHoverPrefetch(TrackInfo track) => _requestHoverPrefetchImpl(track);

  Future<void> handleAudioServiceTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    bool debounce = false,
  }) => playTrack(track, queueContext: queueContext, debounce: debounce);

  bool _shouldOptimisticallyTouchNativeAudio(TrackInfo track) {
    if (_isLocalTrack(track)) return true;
    try {
      final key = _resolverRegistry.deriveKey(track);
      final resolver = _resolverRegistry.resolverFor(key.providerId);
      if (resolver == null || resolver is LocalStreamResolver) return true;
      return resolver.capabilities.supportsL1UrlCache ||
          resolver.capabilities.requiresRangeChunking;
    } catch (_) {
      return true;
    }
  }

  Future<void> playTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    bool debounce = false,
    bool adaptiveSkipDebounce = false,
    int? queueIndex,
    bool userInitiatedSkip = false,
  }) => _playTrackImpl(
    track,
    queueContext: queueContext,
    debounce: debounce,
    adaptiveSkipDebounce: adaptiveSkipDebounce,
    queueIndex: queueIndex,
    userInitiatedSkip: userInitiatedSkip,
  );

  Future<void> pause() => _pauseImpl();
  Future<void> resume() => _resumeImpl();
  Future<void> togglePlayPause() => _togglePlayPauseImpl();
  Future<void> seek(Duration position) => _seekImpl(position);
  Future<void> setVolume(double volume) => _setVolumeImpl(volume);
  Future<void> toggleMute() => _toggleMuteImpl();
  Future<void> stop() => _stopImpl();
  Future<void> next() => _stepQueue(delta: 1);
  Future<void> playNext() => next();
  Future<void> previous() => _stepQueue(delta: -1);

  TrackInfo onTrackTransitioned(
    TrackInfo newTrack, {
    bool backendInitiated = true,
    bool userInitiatedSkip = false,
    int? swapGeneration,
    PlaybackState? sourceState,
  }) => _onTrackTransitionedImpl(
    newTrack,
    backendInitiated: backendInitiated,
    userInitiatedSkip: userInitiatedSkip,
    swapGeneration: swapGeneration,
    sourceState: sourceState,
  );

  void _handleStateUpdate(PlaybackState state) => _handleStateUpdateImpl(state);
  void _handlePositionTick(Duration position) =>
      _handlePositionTickImpl(position);

  String? _tryExtractYtmVideoId(TrackInfo track) =>
      YouTubeMusicProvider.tryExtractCleanVideoId(
        track.id,
        filePath: track.filePath,
      );

  @visibleForTesting
  static bool shouldTriggerPreDecode(Duration position, Duration duration) =>
      _shouldTriggerPreDecodeImpl(position, duration);

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

  void dispose() => _disposeImpl();
}
