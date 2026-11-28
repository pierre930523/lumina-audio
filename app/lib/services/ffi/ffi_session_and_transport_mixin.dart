part of '../ffi_audio_service.dart';

mixin _FfiSessionAndTransportMixin on _FfiAudioServiceBase {
  @override
  Future<void> restorePlaybackSession({
    required TrackInfo track,
    required Duration position,
    List<TrackInfo>? queue,
    int? queueIndex,
    double? volume,
    bool? isMuted,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.restorePlaybackSession(
        track: track,
        position: position,
        queue: queue,
        queueIndex: queueIndex,
        volume: volume,
        isMuted: isMuted,
      );
      return;
    }
    if (!isNativeBound) {
      await _delegate.restorePlaybackSession(
        track: track,
        position: position,
        queue: queue,
        queueIndex: queueIndex,
        volume: volume,
        isMuted: isMuted,
      );
      _state = _delegate.currentState;
      _queue = List<TrackInfo>.from(_delegate.queue);
      return;
    }

    _positionTimer?.cancel();
    if (_state.status == PlaybackStatus.playing) {
      _stopFn?.call();
    }

    if (queue != null && queue.isNotEmpty) {
      _queue = List<TrackInfo>.from(queue);
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
    final clampedPos = resolvedTrack.duration > Duration.zero
        ? (position < Duration.zero
            ? Duration.zero
            : (position > resolvedTrack.duration
                ? resolvedTrack.duration
                : position))
        : (position < Duration.zero ? Duration.zero : position);

    _hasRestoredSession = true;
    _needsLoadOnResume = true;
    _pendingResumePosition = clampedPos;

    final targetVol = (volume ?? _state.volume).clamp(0.0, 1.0);
    _savedNormalVolume = targetVol;
    final muted = _strictBitPerfect
        ? false
        : (isMuted ?? (targetVol == 0.0));
    final effectiveVol = _strictBitPerfect ? 1.0 : targetVol;
    _setVolumeFn?.call(muted ? 0.0 : effectiveVol);

    _loadLyricsForTrack(resolvedTrack);

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
    _refreshSignalPath();
  }

  @override
  Future<void> _playInternal({
    TrackInfo? track,
    String? streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) async {
    _currentLyrics = const [];
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      if (streamUrl != null) {
        return _remoteClient!.playStreamUrl(
          track: track!,
          streamUrl: streamUrl,
          headers: headers,
          hintExtension: hintExtension,
        );
      }
      return _remoteClient!.play(track: track);
    }
    if (!isNativeBound) {
      if (streamUrl != null) {
        return _delegate.playStreamUrl(
          track: track!,
          streamUrl: streamUrl,
          headers: headers,
          hintExtension: hintExtension,
        );
      }
      return _delegate.play(track: track);
    }
    final target =
        track ?? _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
    if (target == null) return;

    final idx = PlaybackPersistenceService.findTrackIndex(_queue, target);
    if (idx >= 0) {
      _currentIndex = idx;
    }

    final isResumingRestored = track == null ||
        (_needsLoadOnResume &&
            _state.track != null &&
            PlaybackPersistenceService.tracksMatch(_state.track!, target));
    final resumePos = isResumingRestored ? _pendingResumePosition : null;
    _pendingResumePosition = null;
    _needsLoadOnResume = false;

    final nextEpoch = _activeEpoch + 1;
    _activeEpoch = nextEpoch;
    _activeRequestId = nextEpoch;
    _activeStreamIsLocalProxy = _ffiIsLoopbackUrl(streamUrl);
    _pendingStandbyTrack = null;
    _lastDualDeckSnapshot = null;
    final payload = _ffiEncodeTrackPayload(
      target,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      epoch: nextEpoch,
    );
    final rc = _withNativeUtf8(payload, (p) => _playFn!(p));
    if (rc != 0) {
      final errMsg = _lastErrorMsgFn != null
          ? _takeRustString(_lastErrorMsgFn!())
          : null;
      _lastError = (errMsg != null && errMsg.isNotEmpty)
          ? errMsg
          : 'Playback failed (code $rc)';
      _positionTimer?.cancel();
      _emitState(
        _state.copyWith(
          status: streamUrl != null
              ? PlaybackStatus.error
              : PlaybackStatus.stopped,
          track: target,
          position: Duration.zero,
          playbackEpoch: nextEpoch,
          lastError: streamUrl != null ? _lastError : null,
        ),
      );
      return;
    }

    if (resumePos != null && resumePos > Duration.zero) {
      _seekFn!(resumePos.inMilliseconds);
    }

    _lastError = null;
    final durMs = _getDurationFn!();
    final syncedTrack = durMs > 0
        ? target.copyWith(duration: Duration(milliseconds: durMs))
        : target;

    final initialPos = (resumePos != null && resumePos > Duration.zero)
        ? resumePos
        : Duration(milliseconds: _getPositionFn!());

    _emitState(
      _state.copyWith(
        status: PlaybackStatus.playing,
        track: syncedTrack,
        position: initialPos,
        playbackEpoch: nextEpoch,
      ),
    );
    _refreshSignalPath();
    _loadLyricsForTrack(syncedTrack);
    _startPositionTimer();
  }

  @override
  Future<void> pause() async {
    _playbackInterruptHandler?.call();
    _positionTimer?.cancel();
    if (!isNativeBound) {
      return _delegate.pause();
    }
    _pauseFn!();
    if (_activeStreamIsLocalProxy || _state.status == PlaybackStatus.loading) {
      _needsLoadOnResume = true;
      _activeStreamIsLocalProxy = false;
    }
    _emitState(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> resume() async {
    if (!isNativeBound) {
      return _delegate.resume();
    }
    final nativeState = _getStateFn?.call() ?? 1;
    if (_needsLoadOnResume ||
        ((nativeState == 1 || nativeState == 4 || nativeState == 0) &&
            _state.track != null)) {
      await play(track: null);
      return;
    }
    if (_playbackResumeFn != null) {
      _playbackResumeFn!();
    } else {
      _playFn!(ffi.nullptr);
    }
    _emitState(_state.copyWith(status: PlaybackStatus.playing));
    _startPositionTimer();
  }

  @override
  Future<void> togglePlayPause() async {
    if (!isNativeBound) {
      return _delegate.togglePlayPause();
    }
    if (currentState.status == PlaybackStatus.playing) {
      await pause();
    } else if (currentState.status == PlaybackStatus.paused) {
      final nativeState = _getStateFn?.call() ?? 1;
      if (_needsLoadOnResume ||
          ((nativeState == 1 || nativeState == 4 || nativeState == 0) &&
              _state.track != null)) {
        await play(track: null);
      } else {
        await resume();
      }
    } else {
      await play();
    }
  }

  @override
  Future<void> reconnectDevice() async {
    if (!isNativeBound) {
      return _delegate.reconnectDevice();
    }
    if (_playbackReconnectDeviceFn != null) {
      _playbackReconnectDeviceFn!();
    }
    _emitState(_state.copyWith(deviceLost: false));
  }

  @override
  Future<void> stop() async {
    _playbackInterruptHandler?.call();
    _positionTimer?.cancel();
    _pendingResumePosition = null;
    _needsLoadOnResume = false;
    _activeStreamIsLocalProxy = false;
    _pendingStandbyTrack = null;
    _standbyTracksById.clear();
    _lastDualDeckSnapshot = null;
    if (!isNativeBound) {
      _lastCancelledEpoch = 0;
      return _delegate.stop();
    }
    if (_activeEpoch > 0 && _activeEpoch != _lastCancelledEpoch) {
      _activeEpoch++;
      _activeRequestId = _activeEpoch;
    }
    _lastCancelledEpoch = 0;
    _stopFn!();
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.stopped,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) =>
      seekAtEpoch(position, epoch: _activeEpoch);

  @override
  Future<void> seekAtEpoch(Duration position, {required int epoch}) async {
    if (_isRemoteActive) {
      return _remoteClient!.seek(position);
    }
    if (!isNativeBound) {
      return _delegate.seek(position);
    }
    if (epoch > 0 && epoch < _activeEpoch) {
      return;
    }
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
    }
    final maxMs = _state.track != null && _state.track!.duration > Duration.zero
        ? _state.track!.duration.inMilliseconds
        : (1 << 30);
    final ms = position.inMilliseconds.clamp(0, maxMs);
    final clamped = Duration(milliseconds: ms);
    if (_needsLoadOnResume) {
      _pendingResumePosition = clamped;
      _emitState(
        _state.copyWith(position: clamped, playbackEpoch: _activeEpoch),
      );
      return;
    }
    final seekAtEpochFn = _playbackSeekAtEpochFn;
    if (seekAtEpochFn != null && _activeEpoch > 0) {
      seekAtEpochFn(ms, _activeEpoch);
    } else {
      _seekFn!(ms);
    }
    _emitState(
      _state.copyWith(position: clamped, playbackEpoch: _activeEpoch),
    );
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_isRemoteActive) {
      return _remoteClient!.setVolume(volume);
    }
    if (!isNativeBound) {
      return _delegate.setVolume(volume);
    }
    final clamped = volume.clamp(0.0, 1.0);
    _savedNormalVolume = clamped;
    if (_strictBitPerfect) {
      _setVolumeFn!(1.0);
      _emitState(_state.copyWith(volume: 1.0, isMuted: false));
      return;
    }
    _setVolumeFn!(clamped);
    _emitState(_state.copyWith(volume: clamped, isMuted: clamped == 0.0));
  }

  @override
  Future<void> toggleMute() async {
    if (_isRemoteActive) {
      return _remoteClient!.toggleMute();
    }
    if (!isNativeBound) {
      return _delegate.toggleMute();
    }
    if (_strictBitPerfect) {
      return;
    }
    final nextMuted = !_state.isMuted;
    _setVolumeFn!(nextMuted ? 0.0 : _state.volume);
    _emitState(_state.copyWith(isMuted: nextMuted));
  }

  @override
  Future<void> skipToTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.skipToTrack(track, queueContext: queueContext);
    }
    if (!isNativeBound) {
      return _delegate.skipToTrack(track, queueContext: queueContext);
    }
    if (_streamingTrackHandler != null &&
        AudioService.isStreamingTrackId(track.id)) {
      await _streamingTrackHandler!(
        track,
        queueContext: queueContext,
        debounce: true,
      );
      return;
    }
    final fp = track.filePath?.trim();
    if (_playbackPlayAsyncFn != null &&
        fp != null &&
        fp.isNotEmpty &&
        !AudioService.isStreamingTrackId(track.id) &&
        !AudioService.isStreamingTrackId(fp)) {
      final nextEpoch = _activeEpoch + 1;
      await playStreamSpecWithOptions(
        track,
        LocalFileSpec(key: StreamKey('local', fp, 'default'), path: fp),
        epoch: nextEpoch,
      );
      return;
    }
    await play(track: track);
  }

  int _findPlayableStepIndex(int delta) {
    if (_queue.isEmpty) return -1;
    final len = _queue.length;
    for (var step = 1; step <= len; step++) {
      final idx = (_currentIndex + delta * step) % len;
      final normalized = idx < 0 ? idx + len : idx;
      if (_queue[normalized].preference != -1) {
        return normalized;
      }
    }
    return -1;
  }

  @override
  Future<void> next() async {
    if (_isRemoteActive) {
      return _remoteClient!.next();
    }
    if (!isNativeBound) {
      return _delegate.next();
    }
    final nextIdx = _findPlayableStepIndex(1);
    if (nextIdx < 0) return;
    _needsLoadOnResume = false;
    _pendingResumePosition = null;
    _currentIndex = nextIdx;
    await skipToTrack(_queue[_currentIndex]);
  }

  @override
  Future<void> previous() async {
    if (_isRemoteActive) {
      return _remoteClient!.previous();
    }
    if (!isNativeBound) {
      return _delegate.previous();
    }
    final prevIdx = _findPlayableStepIndex(-1);
    if (prevIdx < 0) return;
    _needsLoadOnResume = false;
    _pendingResumePosition = null;
    _currentIndex = prevIdx;
    await skipToTrack(_queue[_currentIndex]);
  }

  @override
  Future<void> toggleDspBypass() async {
    if (_isRemoteActive) {
      return _remoteClient!.toggleDspBypass();
    }
    if (!isNativeBound) {
      return _delegate.toggleDspBypass();
    }
    _toggleBypassFn!();
    _refreshSignalPath();
  }

  @override
  void setSimulatedQuality(SignalQuality quality) {
    if (!isNativeBound) {
      _delegate.setSimulatedQuality(quality);
      return;
    }
    final nextSignalPath = SignalPath(
      overallQuality: quality,
      description: quality.description,
      nodes: _signalPath.nodes,
      dspBypassed: quality == SignalQuality.lossless,
    );
    _signalPath = nextSignalPath;
    if (!_signalPathController.isClosed) {
      _signalPathController.add(_signalPath);
    }
  }
}
