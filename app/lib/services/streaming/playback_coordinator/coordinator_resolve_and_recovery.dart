part of '../streaming_playback_coordinator.dart';

extension _CoordinatorResolveSpecExt on StreamingPlaybackCoordinator {
  Future<void> _executeStandbySkipOrFallback(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    int? queueIndex,
  }) async {
    final skipEpoch = _nextEpoch();
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
      final cur = currentState;
      final resetCur = cur.copyWith(position: Duration.zero);
      if (!_positionController.isClosed) {
        _positionController.add(Duration.zero);
      }
      if (resetCur.status == PlaybackStatus.playing &&
          resetCur.track != null) {
        onTrackTransitioned(
          resolvedTrack,
          backendInitiated: false,
          userInitiatedSkip: true,
          swapGeneration: resetCur.swapGeneration,
          sourceState: resetCur,
        );
      } else {
        _latestCoordinatorState = resetCur;
        if (!_stateController.isClosed) {
          _stateController.add(resetCur);
        }
        _syncStablePlayTimer(resetCur);
      }
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
      audioService.beginOptimisticTrackLoadAtEpoch(
        track,
        queue: queueContext,
        epoch: skipEpoch,
      );
      final optimistic = currentState.copyWith(
        status: PlaybackStatus.loading,
        track: track,
        position: Duration.zero,
        playbackEpoch: skipEpoch,
        clearLastError: true,
      );
      _pendingOptimisticTrackId = track.id;
      _pendingOptimisticEpoch = skipEpoch;
      _latestCoordinatorState = optimistic;
      if (!_stateController.isClosed) {
        _stateController.add(optimistic);
      }
      if (!_positionController.isClosed) {
        _positionController.add(Duration.zero);
      }
    }
    await _executeResolveAndPlaySpec(track, skipEpoch, fallbackCancel);
  }

  Future<void> _executeResolveAndPlaySpec(
    TrackInfo track,
    int taskEpoch,
    CancellationToken cancel, {
    bool debounced = false,
  }) async {
    bool isStale() => _disposed || taskEpoch != _epoch || cancel.isCancelled;
    if (isStale()) return;

    _backendCancelSentForBurst = false;
    _finalizeDeferredAutoplaySkip(track);

    final resolveGen = ++_resolvingGeneration;
    _resolvingRequestId = taskEpoch;
    StreamSourceSpec? resolvedSpec;

    try {
      if (_isLocalTrack(track)) {
        final fp = track.filePath!.trim();
        final localKey =
            _tryDeriveKey(track) ?? StreamKey('local', fp, 'default');
        resolvedSpec = LocalFileSpec(key: localKey, path: fp);
      } else {
        final resolveSw = Stopwatch()..start();
        final key = _resolverRegistry.deriveKey(track);
        final useLegacySpecCache = _usesLegacyCoordinatorSpecCache(key);
        final cachedSpec = _peekCachedSpec(key);
        if (cachedSpec != null) {
          resolvedSpec = cachedSpec;
        } else {
          resolvedSpec =
              await _awaitWithCancellationAndTimeout<StreamSourceSpec>(
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
      }

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

      await targetBackend.playWithDebounced(
        spec,
        resolvedTrack,
        epoch: taskEpoch,
        debounced: debounced,
      );
      if (!isStale()) {
        _syncStablePlayTimer(currentState);
      }
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      await _handleAutoOrRegularSpecFailure(
        track,
        taskEpoch,
        e.message,
        resolvedSpec: resolvedSpec,
        isDrmRestricted: e.isDrmRestricted,
      );
    } on TimeoutException {
      if (isStale()) return;
      cancel.cancel();
      ytDlpService.cancelRequest(taskEpoch);
      await _handleAutoOrRegularSpecFailure(
        track,
        taskEpoch,
        '串流解析逾時，請稍後再試',
        resolvedSpec: resolvedSpec,
      );
    } catch (e) {
      if (isStale()) return;
      await _handleAutoOrRegularSpecFailure(
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

  Future<void> _handleAutoOrRegularSpecFailure(
    TrackInfo track,
    int taskEpoch,
    String message, {
    StreamSourceSpec? resolvedSpec,
    bool isDrmRestricted = false,
  }) async {
    final ap = autoplayController;
    if (ap == null || !ap.isAutoTrack(track.id)) {
      _handleResolveSpecFailure(
        track,
        taskEpoch,
        message,
        resolvedSpec: resolvedSpec,
        isDrmRestricted: isDrmRestricted,
      );
      return;
    }

    _loadingExternalState = null;
    _evictSpecCacheForTrack(track);

    final res = ap.handleAutoTrackUnplayable(track, message);
    if (res.reachedFailureLimit) {
      const limitMsg =
          '連續 ${AutoplayController.maxConsecutiveAutoFailures} 首自動推薦曲目無法播放，已停止自動推薦';
      _notifiedErrorForEpoch = taskEpoch;
      if (resolvedSpec is! ExternalBackendSpec &&
          _shouldOptimisticallyTouchNativeAudio(track)) {
        audioService.failOptimisticTrackLoad(track, limitMsg);
      } else if (!_stateController.isClosed) {
        _stateController.add(
          currentState.copyWith(
            status: PlaybackStatus.error,
            track: track,
            lastError: limitMsg,
          ),
        );
      }
      onError?.call(track, limitMsg, isDrmRestricted);
      return;
    }

    var nextTrack = res.nextTrack;
    if (nextTrack == null && ap.enabled) {
      await ap.maybeTriggerRefill();
      if (_disposed || taskEpoch != _epoch) return;
      nextTrack = ap.peekNextTrack();
    }
    if (nextTrack != null) {
      await _playResolvedOrLocalTrack(nextTrack, debounce: false);
      return;
    }

    if (resolvedSpec is! ExternalBackendSpec &&
        _shouldOptimisticallyTouchNativeAudio(track)) {
      audioService.failOptimisticTrackLoad(track, message);
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

  void _stopMismatchedActiveBackend(
    PlaybackBackend targetBackend,
    int taskEpoch,
  ) {
    final prev = _activeBackend;
    if (prev == null || identical(prev, targetBackend)) {
      _activeBackend = targetBackend;
      return;
    }
    _activeBackend = targetBackend;
    unawaited(prev.stop(epoch: taskEpoch));
  }

  Future<void> _pauseWithCancellationImpl() async {
    _cancelStablePlayTimer();
    final curBeforeCancel = currentState;
    final hasPendingLoad =
        _debounceTimer != null ||
        _resolvingRequestId != null ||
        _pendingOptimisticTrackId != null ||
        curBeforeCancel.status == PlaybackStatus.loading;
    if (hasPendingLoad) {
      final pendingTrack =
          curBeforeCancel.track ?? _latestCoordinatorState?.track;
      _cancelPendingWork();
      _pendingOptimisticTrackId = null;
      _pendingOptimisticEpoch = -1;
      _resolvingRequestId = null;
      _backendCancelSentForBurst = false;
      final pauseEpoch = _nextEpoch();
      ytDlpService.cancelPlaybackProcesses();
      ytDlpService.stopFfmpegProxy();
      if (_loadingExternalState != null) {
        _pausedPendingTrack = _loadingExternalState!.track ?? pendingTrack;
        _loadingExternalState = _loadingExternalState!.copyWith(
          status: PlaybackStatus.paused,
          position: Duration.zero,
          playbackEpoch: pauseEpoch,
        );
        _latestCoordinatorState = _loadingExternalState;
        if (!_stateController.isClosed) {
          _stateController.add(_loadingExternalState!);
        }
        await _externalBackend.pause();
        return;
      }
      _pausedPendingTrack = pendingTrack;
      _suppressStoppedAtEpoch = pauseEpoch;
      final pausedState = (curBeforeCancel.track != null
              ? curBeforeCancel
              : (_latestCoordinatorState ?? curBeforeCancel))
          .copyWith(
            status: PlaybackStatus.paused,
            position: Duration.zero,
            playbackEpoch: pauseEpoch,
            clearLastError: true,
          );
      _latestCoordinatorState = pausedState;
      if (!_stateController.isClosed) {
        _stateController.add(pausedState);
      }
      await audioService.cancelPendingPlaybackAtEpoch(pauseEpoch);
      if (_disposed || pauseEpoch != _epoch) return;
      if (_useResolverPipeline) {
        await _effectiveControlBackend.pause();
      } else {
        await audioService.pause();
      }
      return;
    }

    ytDlpService.stopFfmpegProxy();
    if (_useResolverPipeline) {
      if (_loadingExternalState != null) {
        _loadingExternalState = _loadingExternalState!.copyWith(
          status: PlaybackStatus.paused,
        );
        if (!_stateController.isClosed) {
          _stateController.add(_loadingExternalState!);
        }
      }
      await _effectiveControlBackend.pause();
      return;
    }
    await audioService.pause();
  }
}
