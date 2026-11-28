part of '../mock_audio_service.dart';

mixin _MockPlaybackMixin on _MockAudioServiceBase {
  @visibleForTesting
  int get activeEpoch => _activeEpoch;

  @visibleForTesting
  bool get lastPlayDebounced => _lastPlayDebounced;

  @visibleForTesting
  StreamSourceSpec? get lastSourceSpec => _lastSourceSpec;

  @visibleForTesting
  TrackInfo? get standbyTrack => _standbyTrack;

  @visibleForTesting
  StreamSourceSpec? get standbySpec => _standbySpec;

  @visibleForTesting
  int get standbyEpoch => _standbyEpoch;

  @override
  void setStreamingTrackHandler(StreamingTrackHandler? handler) {
    _streamingTrackHandler = handler;
  }

  @override
  void setPlaybackInterruptHandler(VoidCallback? handler) {
    _playbackInterruptHandler = handler;
  }

  @override
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) {
    if (queue != null && queue.isNotEmpty) {
      _queue
        ..clear()
        ..addAll(queue);
    }
    final idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
    if (idx < 0) {
      _queue.insert(0, track);
      _currentIndex = 0;
    } else {
      _currentIndex = idx;
    }
    _needsLoadOnResume = false;
    _lastError = null;
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.loading,
        track: track,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
        clearLastError: true,
      ),
    );
  }

  @override
  void beginOptimisticTrackLoadAtEpoch(
    TrackInfo track, {
    List<TrackInfo>? queue,
    required int epoch,
  }) {
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
    }
    beginOptimisticTrackLoad(track, queue: queue);
  }

  @override
  void failOptimisticTrackLoad(TrackInfo track, String message) {
    _lastError = message;
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.error,
        track: track,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
        lastError: message,
      ),
    );
  }

  @override
  Future<void> cancelPendingPlayback() async {
    _clearStandby();
    if (_state.status == PlaybackStatus.loading) {
      _emitState(
        _state.copyWith(
          status: PlaybackStatus.stopped,
          position: Duration.zero,
        ),
      );
    }
  }

  @override
  Future<void> play({TrackInfo? track}) async {
    if (_streamingTrackHandler != null) {
      final candidate =
          track ?? _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
      final needsFreshLoad = track != null ||
          _needsLoadOnResume ||
          _state.status == PlaybackStatus.stopped ||
          _state.status == PlaybackStatus.error ||
          _state.status == PlaybackStatus.ended;
      if (candidate != null &&
          needsFreshLoad &&
          AudioService.isStreamingTrackId(candidate.id)) {
        await _streamingTrackHandler!(
          candidate,
          queueContext: null,
          debounce: false,
        );
        return;
      }
    }
    _clearStandby();
    _needsLoadOnResume = false;
    if (track != null) {
      if (!AudioService.isStreamingTrackId(track.id)) {
        _playbackInterruptHandler?.call();
      }
      final idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
      if (idx >= 0) {
        _currentIndex = idx;
      }
      if (track.format.isDsd) {
        _visualizerBandsNotifier.value = Float32List(64);
      }
      _lastError = null;
      _emitState(
        _state.copyWith(
          status: PlaybackStatus.playing,
          track: track,
          position: Duration.zero,
          playbackEpoch: _activeEpoch,
          clearLastError: true,
        ),
      );
      _emitSignalPath();
    } else {
      _emitState(
        _state.copyWith(
          status: PlaybackStatus.playing,
          playbackEpoch: _activeEpoch,
        ),
      );
    }
  }

  @override
  Future<void> skipToTrack(TrackInfo track, {List<TrackInfo>? queueContext}) =>
      play(track: track);

  @override
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) async {
    _clearStandby();
    final idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
    if (idx >= 0) {
      _currentIndex = idx;
    }
    if (track.format.isDsd) {
      _visualizerBandsNotifier.value = Float32List(64);
    }
    _needsLoadOnResume = false;
    _lastError = null;
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.playing,
        track: track,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
        clearLastError: true,
      ),
    );
    _emitSignalPath();
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) {
    if (requestId > 0 && requestId < _activeEpoch) {
      return Future<void>.value();
    }
    if (requestId > _activeEpoch) {
      _activeEpoch = requestId;
    }
    return playStreamUrl(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
    );
  }

  @override
  Future<void> playStreamSpecWithOptions(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) {
    _lastPlayDebounced = debounced;
    return playStreamSpecAsync(track, spec, epoch: epoch);
  }

  @override
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) async {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter MockAudioService',
      );
    }
    if (epoch < _activeEpoch) return;
    _activeEpoch = epoch;
    _lastSourceSpec = spec;
    switch (spec) {
      case DirectRangeSpec():
        await playStreamUrlAsync(
          track: track,
          streamUrl: spec.url,
          headers: spec.headers,
          hintExtension: spec.hintExtension,
          requestId: epoch,
        );
      case EncryptedRangeSpec():
        await playStreamUrlAsync(
          track: track,
          streamUrl: spec.url,
          headers: spec.headers,
          hintExtension: spec.hintExtension,
          requestId: epoch,
        );
      case SegmentedManifestSpec():
        await playStreamUrlAsync(
          track: track,
          streamUrl: spec.manifestUrlOrXml,
          headers: spec.headers,
          hintExtension: spec.format == ManifestFormat.dash ? 'mpd' : 'm3u8',
          requestId: epoch,
        );
      case LocalFileSpec():
        await play(track: track.copyWith(filePath: spec.path));
      case ExternalBackendSpec():
        throw StateError(
          'ExternalBackendSpec (${spec.providerId}) cannot enter MockAudioService',
        );
    }
  }

  @override
  bool get isStandbyDeckReady =>
      _standbyReady && _standbyTrack != null && _standbySpec != null;

  @override
  Future<void> prepareStandbySpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    int? epoch,
  }) async {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter MockAudioService',
      );
    }
    final targetEpoch = epoch ?? _activeEpoch;
    if (targetEpoch < _activeEpoch) return;
    _standbyTrack = track;
    _standbySpec = spec;
    _standbyEpoch = targetEpoch;
    _standbyReady = true;
  }

  @override
  Future<bool> skipToStandby({int? epoch}) async {
    if (!isStandbyDeckReady) return false;
    if (epoch != null && epoch < _standbyEpoch) return false;

    final nextTrack = _standbyTrack!;
    final nextSpec = _standbySpec!;
    final nextEpoch = epoch ??
        (_standbyEpoch > _activeEpoch ? _standbyEpoch : _activeEpoch);
    _clearStandby();

    _activeEpoch = nextEpoch;
    _lastSourceSpec = nextSpec;
    final idx = PlaybackPersistenceService.findTrackIndex(_queue, nextTrack);
    if (idx >= 0) {
      _currentIndex = idx;
    }
    if (nextTrack.format.isDsd) {
      _visualizerBandsNotifier.value = Float32List(64);
    }
    _needsLoadOnResume = false;
    _lastError = null;
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.playing,
        track: nextTrack,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
        clearLastError: true,
      ),
    );
    _emitSignalPath();
    return true;
  }

  @override
  Future<void> cancelPendingPlaybackAtEpoch(int epoch) {
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
    }
    return cancelPendingPlayback();
  }

  @override
  Future<void> restorePlaybackSession({
    required TrackInfo track,
    required Duration position,
    List<TrackInfo>? queue,
    int? queueIndex,
    double? volume,
    bool? isMuted,
  }) async {
    _clearStandby();
    if (queue != null && queue.isNotEmpty) {
      _queue
        ..clear()
        ..addAll(queue);
    }
    var idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
    if (idx < 0) {
      _queue.insert(0, track);
      idx = 0;
    }
    _currentIndex = (queueIndex != null &&
            queueIndex >= 0 &&
            queueIndex < _queue.length &&
            PlaybackPersistenceService.tracksMatch(_queue[queueIndex], track))
        ? queueIndex
        : idx;

    final resolvedTrack = _queue[_currentIndex];
    final maxDur = resolvedTrack.duration > Duration.zero
        ? resolvedTrack.duration
        : const Duration(hours: 24);
    final clampedPos = position < Duration.zero
        ? Duration.zero
        : (position > maxDur ? maxDur : position);

    final targetVol = (volume ?? _state.volume).clamp(0.0, 1.0);
    _savedNormalVolume = targetVol;
    final muted = _strictBitPerfect
        ? false
        : (isMuted ?? (targetVol == 0.0));
    final effectiveVol = _strictBitPerfect ? 1.0 : targetVol;

    _needsLoadOnResume = true;
    _emitState(
      PlaybackState(
        status: PlaybackStatus.paused,
        track: resolvedTrack,
        position: clampedPos,
        volume: effectiveVol,
        isMuted: muted,
        seekEpoch: _state.seekEpoch,
        isSeeking: false,
        lastError: null,
        deviceLost: _state.deviceLost,
        clockSource: _state.clockSource,
      ),
    );
    _emitSignalPath();
  }
}
