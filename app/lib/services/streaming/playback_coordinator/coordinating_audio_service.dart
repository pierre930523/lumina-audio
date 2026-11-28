part of '../streaming_playback_coordinator.dart';

/// Unified [AudioService] facade passed to UI views so transport controls,
/// shared queues, state, position, and SignalPath route transparently between
/// native Rust playback and the external Apple Music backend while keeping
/// Apple Music strictly isolated from native `AudioService.playStream*`.
class CoordinatingAudioService
    with
        _CoordinatingAudioServiceDelegatesMixin,
        _CoordinatingAudioServiceGroupingDelegatesMixin,
        _CoordinatingAudioServiceFocusDelegatesMixin,
        _CoordinatingAudioServiceStep4DelegatesMixin,
        _CoordinatingAudioServiceStep5DelegatesMixin
    implements AudioService, DualDeckAudioService, LibraryTracksAudioService {
  @override
  final AudioService inner;
  @override
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
    coordinator.streamingManager.onCatalogSynced ??= (providerId, catalog) async {
      await inner.ingestExternalCatalog(
        ExternalCatalogIngestBatch.fromStreamingCatalog(providerId, catalog),
      );
    };
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
  Stream<TrackInfo> get trackChangedStream => coordinator.trackChangedStream;

  @override
  Stream<List<TrackInfo>> get queueUpdatedStream =>
      coordinator.queueUpdatedStream;

  @override
  void Function(TrackInfo track)? get hoverPrefetchCallback =>
      coordinator.requestHoverPrefetch;

  @override
  PlaybackState get currentState => coordinator.currentState;

  @override
  SignalPath get currentSignalPath => coordinator.isExternalBackendActive
      ? _externalSignalPath(coordinator.currentState.track)
      : inner.currentSignalPath;

  @override
  List<TrackInfo> get queue => coordinator.queue;

  @override
  AutoplayController? get autoplayController => coordinator.autoplayController;

  @override
  String? get lastError => coordinator.isExternalBackendActive
      ? coordinator.currentState.lastError
      : inner.lastError;

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
          adaptiveSkipDebounce: true,
        );
      }
      await coordinator.stopExternalIfActive();
      final ap = coordinator.autoplayController;
      if (ap != null) {
        if (PlaybackPersistenceService.findTrackIndex(
              ap.combinedQueue,
              track,
            ) >=
            0) {
          ap.advanceToTrack(track);
        } else {
          ap.setUserQueue(
            <TrackInfo>[track],
            currentTrack: track,
            currentIndex: 0,
            bumpEpoch: true,
          );
          if (ap.needsRefill) {
            unawaited(ap.maybeTriggerRefill());
          }
        }
      } else if (coordinator.hasSharedQueue &&
          PlaybackPersistenceService.findTrackIndex(
                coordinator.queue,
                track,
              ) <
              0) {
        coordinator.clearSharedQueue();
      }
      if (_isLocalTrack(track)) {
        final effectiveQueue = coordinator.queue.isNotEmpty
            ? List<TrackInfo>.from(coordinator.queue)
            : null;
        return coordinator.playTrack(
          track,
          queueContext: effectiveQueue,
          adaptiveSkipDebounce: true,
        );
      }
      return inner.play(track: track);
    }
    if (coordinator.isExternalBackendActive) {
      return coordinator.resume();
    }
    return inner.play();
  }

  @override
  Future<void> skipToTrack(TrackInfo track, {List<TrackInfo>? queueContext}) {
    final effectiveQueue = queueContext ??
        (coordinator.queue.isNotEmpty
            ? List<TrackInfo>.from(coordinator.queue)
            : null);
    return coordinator.playTrack(
      track,
      queueContext: effectiveQueue,
      adaptiveSkipDebounce: true,
      userInitiatedSkip: true,
    );
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
  Future<void> playStreamSpecWithOptions(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter Native AudioService',
      );
    }
    return inner.playStreamSpecWithOptions(
      track,
      spec,
      epoch: epoch,
      debounced: debounced,
    );
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
  void beginOptimisticTrackLoadAtEpoch(
    TrackInfo track, {
    List<TrackInfo>? queue,
    required int epoch,
  }) => inner.beginOptimisticTrackLoadAtEpoch(track, queue: queue, epoch: epoch);

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
