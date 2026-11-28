part of '../ffi_audio_service.dart';

mixin _FfiPlaybackMixin on _FfiAudioServiceBase {
  @override
  void setStreamingTrackHandler(StreamingTrackHandler? handler) {
    _streamingTrackHandler = handler;
    _delegate.setStreamingTrackHandler(handler);
  }

  @override
  void setPlaybackInterruptHandler(VoidCallback? handler) {
    _playbackInterruptHandler = handler;
    _delegate.setPlaybackInterruptHandler(handler);
  }

  @override
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      _remoteClient!.beginOptimisticTrackLoad(track, queue: queue);
      return;
    }
    if (!isNativeBound) {
      _delegate.beginOptimisticTrackLoad(track, queue: queue);
      return;
    }
    _positionTimer?.cancel();
    _currentLyrics = const [];
    _needsLoadOnResume = false;
    _pendingResumePosition = null;
    _lastError = null;
    if (queue != null && queue.isNotEmpty) {
      _queue = List<TrackInfo>.from(queue);
    }
    final idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
    if (idx < 0) {
      _queue.insert(0, track);
      _currentIndex = 0;
    } else {
      _currentIndex = idx;
    }
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
      _activeRequestId = epoch;
    }
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      _remoteClient!.beginOptimisticTrackLoadAtEpoch(
        track,
        queue: queue,
        epoch: epoch,
      );
      return;
    }
    if (!isNativeBound) {
      _delegate.beginOptimisticTrackLoadAtEpoch(
        track,
        queue: queue,
        epoch: epoch,
      );
      return;
    }
    beginOptimisticTrackLoad(track, queue: queue);
  }

  @override
  void failOptimisticTrackLoad(TrackInfo track, String message) {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      _remoteClient!.failOptimisticTrackLoad(track, message);
      return;
    }
    if (!isNativeBound) {
      _delegate.failOptimisticTrackLoad(track, message);
      return;
    }
    _positionTimer?.cancel();
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
  Future<void> cancelPendingPlayback({int epoch = 0}) async {
    _positionTimer?.cancel();
    _pendingStandbyTrack = null;
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
      _activeRequestId = epoch;
    }
    if (epoch > 0) {
      _lastCancelledEpoch = _activeEpoch;
    }
    final effectiveEpoch = epoch > 0 ? epoch : _activeEpoch;
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.cancelPendingPlayback(epoch: effectiveEpoch);
      return;
    }
    if (!isNativeBound) {
      await _delegate.cancelPendingPlaybackAtEpoch(effectiveEpoch);
      return;
    }
    _playbackCancelPendingFn?.call(effectiveEpoch);
  }

  @override
  Future<void> cancelPendingPlaybackAtEpoch(int epoch) =>
      cancelPendingPlayback(epoch: epoch);

  @override
  Future<void> play({TrackInfo? track}) {
    if (_streamingTrackHandler != null) {
      final candidate =
          track ?? _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
      if (candidate != null && AudioService.isStreamingTrackId(candidate.id)) {
        final bool needsFreshLoad;
        if (track != null) {
          needsFreshLoad = true;
        } else if (!isNativeBound) {
          needsFreshLoad = _needsLoadOnResume ||
              _state.status == PlaybackStatus.stopped ||
              _state.status == PlaybackStatus.error ||
              _state.status == PlaybackStatus.ended;
        } else {
          final nativeCode = _getStateFn?.call() ?? 1;
          needsFreshLoad = _needsLoadOnResume ||
              _state.status == PlaybackStatus.stopped ||
              _state.status == PlaybackStatus.error ||
              _state.status == PlaybackStatus.ended ||
              nativeCode == 0 ||
              nativeCode == 1 ||
              nativeCode == 4;
        }
        if (needsFreshLoad) {
          return _streamingTrackHandler!(
            candidate,
            queueContext: null,
            debounce: false,
          );
        }
      } else if (candidate != null) {
        _playbackInterruptHandler?.call();
      }
    }
    return _playInternal(track: track);
  }

  @override
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) =>
      _playInternal(
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
  }) async {
    if (requestId > 0 && requestId < _activeEpoch) return;
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.playStreamUrlAsync(
        track: track,
        streamUrl: streamUrl,
        headers: headers,
        hintExtension: hintExtension,
        requestId: requestId,
      );
    }
    if (!isNativeBound) {
      return _delegate.playStreamUrlAsync(
        track: track,
        streamUrl: streamUrl,
        headers: headers,
        hintExtension: hintExtension,
        requestId: requestId,
      );
    }
    if (_playbackPlayAsyncFn == null) {
      return _playInternal(
        track: track,
        streamUrl: streamUrl,
        headers: headers,
        hintExtension: hintExtension,
      );
    }

    final payload = _ffiEncodeTrackPayload(
      track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      epoch: requestId,
    );
    _dispatchNativeAsyncPayload(
      track: track,
      payload: payload,
      epoch: requestId,
      isLocalProxy: _ffiIsLoopbackUrl(streamUrl),
    );
  }

  @override
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) =>
      playStreamSpecWithOptions(track, spec, epoch: epoch, debounced: false);

  @override
  Future<void> playStreamSpecWithOptions(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) async {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter FfiAudioService',
      );
    }

    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.playStreamSpecWithOptions(
        track,
        spec,
        epoch: epoch,
        debounced: debounced,
      );
    }
    if (!isNativeBound) {
      return _delegate.playStreamSpecWithOptions(
        track,
        spec,
        epoch: epoch,
        debounced: debounced,
      );
    }
    if (epoch < _activeEpoch) return;

    if (epoch > _activeEpoch) {
      await cancelPendingPlayback(epoch: epoch);
    }
    if (epoch < _activeEpoch) return;
    _lastCancelledEpoch = 0;

    final resolvedFields = _ffiLegacyFieldsForSpec(spec);
    if (_playbackPlayAsyncFn == null) {
      return _playInternal(
        track: spec is LocalFileSpec
            ? track.copyWith(filePath: spec.path)
            : track,
        streamUrl: resolvedFields.streamUrl,
        headers: resolvedFields.headers,
        hintExtension: resolvedFields.hintExtension,
      );
    }

    final payload = _ffiEncodeTrackPayload(
      track,
      streamUrl: resolvedFields.streamUrl,
      filePathOverride: resolvedFields.filePath,
      headers: resolvedFields.headers,
      hintExtension: resolvedFields.hintExtension,
      sourceSpec: spec,
      epoch: epoch,
      debounced: debounced,
    );
    _dispatchNativeAsyncPayload(
      track: track,
      payload: payload,
      epoch: epoch,
      isLocalProxy: _ffiIsLoopbackUrl(resolvedFields.streamUrl),
    );
  }

  void _dispatchNativeAsyncPayload({
    required TrackInfo track,
    required String payload,
    required int epoch,
    required bool isLocalProxy,
  }) {
    _activeEpoch = epoch;
    _activeRequestId = epoch;
    _activeStreamIsLocalProxy = isLocalProxy;
    _currentLyrics = const [];
    _needsLoadOnResume = false;
    _pendingResumePosition = null;
    _pendingStandbyTrack = null;
    _lastDualDeckSnapshot = null;
    final idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
    if (idx >= 0) {
      _currentIndex = idx;
      _queue[idx] = track;
    }

    final rc = _withNativeUtf8(payload, (p) => _playbackPlayAsyncFn!(p, epoch));
    if (rc != 0) {
      final errMsg = _lastErrorMsgFn != null
          ? _takeRustString(_lastErrorMsgFn!())
          : null;
      final msg = (errMsg != null && errMsg.isNotEmpty)
          ? errMsg
          : 'Playback failed (code $rc)';
      _lastError = msg;
      _positionTimer?.cancel();
      _emitState(
        _state.copyWith(
          status: PlaybackStatus.error,
          track: track,
          position: Duration.zero,
          playbackEpoch: epoch,
          lastError: msg,
        ),
      );
      return;
    }

    _lastError = null;
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.loading,
        track: track,
        position: Duration.zero,
        playbackEpoch: epoch,
        clearLastError: true,
      ),
    );
    _startPositionTimer();
  }

  @visibleForTesting
  String encodeStreamSpecPayloadForTest(
    TrackInfo target,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) {
    final fields = _ffiLegacyFieldsForSpec(spec);
    return _ffiEncodeTrackPayload(
      target,
      streamUrl: fields.streamUrl,
      filePathOverride: fields.filePath,
      headers: fields.headers,
      hintExtension: fields.hintExtension,
      sourceSpec: spec,
      epoch: epoch,
      debounced: debounced,
    );
  }
}
