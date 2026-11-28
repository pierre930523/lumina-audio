part of '../streaming_playback_coordinator.dart';

extension _CoordinatorStateHandlersExt on StreamingPlaybackCoordinator {
  void _initListenersImpl() {
    audioService.setStreamingTrackHandler(handleAudioServiceTrack);
    audioService.setPlaybackInterruptHandler(_handlePlaybackInterrupted);
    final native = _nativeBackend;
    if (native is NativePlaybackBackend) {
      native.shouldAllowStopAtEpoch = (stopEpoch) =>
          !_disposed && stopEpoch >= _epoch;
    }
    streamingManager.addAuthRequiredListener(_onProviderAuthRequired);
    _positionSub = audioService.positionStream.listen(_handlePositionTick);
    if (_useResolverPipeline) {
      _nativeStateSub = _nativeBackend.stateStream.listen(
        (s) => _handleBackendStateUpdateImpl(_nativeBackend, s),
      );
      _externalStateSub = _externalBackend.stateStream.listen(
        (s) => _handleBackendStateUpdateImpl(_externalBackend, s),
      );
    } else {
      _stateSub = audioService.stateStream.listen(_handleStateUpdate);
    }
    if (autoplayController != null) {
      _autoplayChangesSub = autoplayController!.changes.listen((_) {
        if (_disposed) return;
        final combined = autoplayController!.combinedQueue;
        if (combined.isNotEmpty) {
          _sharedQueue
            ..clear()
            ..addAll(combined);
          final curTrack = currentState.track;
          if (curTrack != null) {
            _sharedQueueIndex = _findTrackIndexInList(_sharedQueue, curTrack);
          }
        } else if (_sharedQueue.isNotEmpty) {
          _sharedQueue.clear();
          _sharedQueueIndex = -1;
        }
        if (!_suppressAutoplayChangeQueueEmit &&
            !_queueUpdatedController.isClosed) {
          _queueUpdatedController.add(List<TrackInfo>.unmodifiable(queue));
        }
        final cur = currentState;
        if (cur.status == PlaybackStatus.playing && cur.track != null) {
          _syncStablePlayTimer(cur);
          _maybePreResolveNext(cur, cur.position);
        }
      });
    }
  }

  PlaybackState _getCurrentStateImpl() {
    if (_loadingExternalState != null) return _loadingExternalState!;
    final raw = _activeBackend?.currentState ?? audioService.currentState;
    final latest = _latestCoordinatorState;
    final resolvingOptimistic =
        _debounceTimer != null || _resolvingRequestId == _epoch;
    if (latest != null &&
        _pendingOptimisticEpoch == _epoch &&
        _pendingOptimisticTrackId != null &&
        latest.playbackEpoch == _epoch &&
        (raw.playbackEpoch < _epoch ||
            (resolvingOptimistic && raw.status == PlaybackStatus.stopped))) {
      return latest;
    }
    if (latest != null &&
        latest.track != null &&
        raw.track != null &&
        _tracksReferToSame(latest.track, raw.track)) {
      final mergedTrack = _mergeRichTrack(raw.track!, latest.track);
      final effSwap = raw.swapGeneration > latest.swapGeneration
          ? raw.swapGeneration
          : latest.swapGeneration;
      final forceZero =
          _pendingSwapZeroPosTrack != null &&
          _tracksReferToSame(_pendingSwapZeroPosTrack, mergedTrack) &&
          (_pendingSwapZeroPosGen <= 0 || effSwap == _pendingSwapZeroPosGen);
      return raw.copyWith(
        track: mergedTrack,
        position: forceZero ? Duration.zero : raw.position,
        swapGeneration: effSwap,
      );
    }
    if (latest != null &&
        latest.track != null &&
        raw.track == null &&
        raw.status == latest.status) {
      return latest;
    }
    return raw;
  }

  Future<void> _handleAutoTrackRuntimeError(
    TrackInfo errTrack,
    int errorEpoch,
    String msg,
  ) async {
    final ap = autoplayController;
    if (_disposed || ap == null || errorEpoch != _epoch) return;
    final res = ap.handleAutoTrackUnplayable(errTrack, msg);
    if (res.reachedFailureLimit) {
      onError?.call(
        errTrack,
        '連續 ${AutoplayController.maxConsecutiveAutoFailures} 首自動推薦曲目無法播放，已停止自動推薦',
        false,
      );
      return;
    }
    var nextTrack = res.nextTrack;
    if (nextTrack == null && ap.enabled) {
      await ap.maybeTriggerRefill();
      if (_disposed || errorEpoch != _epoch) return;
      nextTrack = ap.peekNextTrack();
    }
    if (nextTrack != null) {
      await _playResolvedOrLocalTrack(nextTrack, debounce: false);
    }
  }

  bool _isStaleBackendState(PlaybackState state) {
    if (_epoch <= 0) return false;
    if (state.playbackEpoch > 0 && state.playbackEpoch < _epoch) {
      return true;
    }
    if (_suppressStoppedAtEpoch > 0 &&
        state.status == PlaybackStatus.stopped &&
        state.playbackEpoch == _suppressStoppedAtEpoch) {
      return true;
    }
    if (state.status != PlaybackStatus.stopped &&
        state.playbackEpoch >= _suppressStoppedAtEpoch) {
      _suppressStoppedAtEpoch = -1;
    }
    final pendingId = _pendingOptimisticTrackId;
    if (_pendingOptimisticEpoch == _epoch && pendingId != null) {
      final resolvingOptimistic =
          _debounceTimer != null || _resolvingRequestId == _epoch;
      if (resolvingOptimistic &&
          state.status == PlaybackStatus.stopped &&
          state.track == null) {
        return true;
      }
      final matchesPending =
          state.track != null &&
          _tracksReferToSame(state.track, _latestCoordinatorState?.track);
      if (!matchesPending && state.playbackEpoch < _epoch) {
        return true;
      }
      if (!matchesPending && state.playbackEpoch == 0 && resolvingOptimistic) {
        return true;
      }
    }
    final isBackendSwapAdvance =
        state.swapGeneration > 0 &&
        state.swapGeneration > _lastObservedBackendSwapGen;
    if (!isBackendSwapAdvance &&
        state.playbackEpoch == 0 &&
        state.track != null &&
        _latestCoordinatorState?.track != null &&
        !_tracksReferToSame(state.track, _latestCoordinatorState!.track)) {
      return true;
    }
    return false;
  }

  void _maybeClearPendingOptimistic(PlaybackState state) {
    if (state.status == PlaybackStatus.playing) {
      _pausedPendingTrack = null;
    }
    if (_pendingOptimisticTrackId == null) return;
    if (state.status == PlaybackStatus.playing ||
        state.status == PlaybackStatus.error) {
      final matchesPending =
          state.track != null &&
          _tracksReferToSame(state.track, _latestCoordinatorState?.track);
      if (matchesPending || state.playbackEpoch >= _epoch) {
        _pendingOptimisticTrackId = null;
        _pendingOptimisticEpoch = -1;
      }
    }
  }

  void _handleBackendStateUpdateImpl(
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
    if (_isStaleBackendState(state)) {
      return;
    }
    _maybeClearPendingOptimistic(state);

    final transitionHandled = _processStateTransitionOrEnd(state);
    if (transitionHandled) {
      return;
    }

    final ap = autoplayController;
    final enrichedState = _enrichStateFromCoordinator(state);
    if (ap != null) {
      if (enrichedState.status == PlaybackStatus.playing &&
          enrichedState.track != null) {
        final combined = ap.combinedQueue;
        if (combined.isNotEmpty) {
          _sharedQueue
            ..clear()
            ..addAll(combined);
          _sharedQueueIndex = _findTrackIndexInList(
            _sharedQueue,
            enrichedState.track!,
          );
        }
      }
    } else if (identical(source, _nativeBackend) &&
        enrichedState.status == PlaybackStatus.playing &&
        enrichedState.track != null &&
        _sharedQueue.isNotEmpty) {
      final idx = _findTrackIndexInList(_sharedQueue, enrichedState.track!);
      if (idx >= 0) {
        _sharedQueueIndex = idx;
      } else if (audioService.queue.isNotEmpty) {
        _sharedQueue
          ..clear()
          ..addAll(audioService.queue);
        _sharedQueueIndex = _findTrackIndexInList(
          _sharedQueue,
          enrichedState.track!,
        );
      } else {
        clearSharedQueue();
      }
    }
    if (!_stateController.isClosed) {
      _stateController.add(enrichedState);
    }
    if (identical(source, _externalBackend) && !_positionController.isClosed) {
      _positionController.add(enrichedState.position);
    }
    if (enrichedState.status == PlaybackStatus.error) {
      final errTrack = enrichedState.track;
      if (errTrack != null && _resolverRegistry.hasStreamingMapping(errTrack)) {
        _evictSpecCacheForTrack(errTrack);
        final rawErr = enrichedState.lastError?.trim();
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
        if (ap != null && ap.isAutoTrack(errTrack.id)) {
          if (_notifiedErrorForEpoch != _epoch) {
            _notifiedErrorForEpoch = _epoch;
            unawaited(_handleAutoTrackRuntimeError(errTrack, _epoch, msg));
          }
        } else if (_epoch > 0 && _notifiedErrorForEpoch != _epoch) {
          _notifiedErrorForEpoch = _epoch;
          onError?.call(errTrack, msg, false);
        }
      }
    }
    _syncStablePlayTimer(enrichedState);
    _maybePreResolveNext(enrichedState, enrichedState.position);
  }

  void _handleStateUpdateImpl(PlaybackState state) {
    if (_disposed) return;
    if (_isStaleBackendState(state)) return;
    _maybeClearPendingOptimistic(state);
    final transitionHandled = _processStateTransitionOrEnd(state);
    if (!transitionHandled) {
      final enrichedState = _enrichStateFromCoordinator(state);
      if (!_stateController.isClosed) {
        _stateController.add(enrichedState);
      }
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
      if (playingTrack != null &&
          !StreamingPlaybackCoordinator.isStreamingTrack(playingTrack)) {
        _activeYtmAttempt = null;
        _activeTidalDashAttempt = null;
        ytDlpService.stopFfmpegProxy();
      }
    }
    if (state.status == PlaybackStatus.error) {
      final errTrack = state.track;
      if (errTrack != null &&
          StreamingPlaybackCoordinator.isStreamingTrack(errTrack)) {
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
        final ap = autoplayController;
        if (ap != null && ap.isAutoTrack(errTrack.id)) {
          if (_notifiedErrorForEpoch != _epoch) {
            _notifiedErrorForEpoch = _epoch;
            unawaited(_handleAutoTrackRuntimeError(errTrack, _epoch, msg));
          }
        } else if (_epoch > 0 && _notifiedErrorForEpoch != _epoch) {
          _notifiedErrorForEpoch = _epoch;
          onError?.call(errTrack, msg, false);
        }
      }
    }
    if (!transitionHandled) {
      _maybePreResolveNext(currentState, state.position);
    }
  }

  void _handlePositionTickImpl(Duration position) {
    if (_disposed) return;
    if (isExternalBackendActive) return;
    if (_pendingSwapZeroPosTrack != null) {
      if (_pendingSwapInitialPos != null &&
          position == _pendingSwapInitialPos) {
        _pendingSwapInitialPos = null;
        return;
      }
      if (position > Duration.zero) {
        _pendingSwapZeroPosTrack = null;
        _pendingSwapZeroPosGen = -1;
        _pendingSwapInitialPos = null;
      }
    }
    if (!_positionController.isClosed) {
      _positionController.add(position);
    }
    final cur = currentState;
    if (cur.status == PlaybackStatus.playing && cur.track != null) {
      autoplayController?.onPlaybackProgress(cur.track!, position);
    }
    _maybePreResolveNext(cur, position);
  }

  void _disposeImpl() {
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
    _autoplayChangesSub?.cancel();
    _autoplayChangesSub = null;
    if (_ownsExternalBackend) _externalBackend.dispose();
    if (!_positionController.isClosed) unawaited(_positionController.close());
    if (!_stateController.isClosed) unawaited(_stateController.close());
    if (!_trackChangedController.isClosed) {
      unawaited(_trackChangedController.close());
    }
    if (!_queueUpdatedController.isClosed) {
      unawaited(_queueUpdatedController.close());
    }
    audioService.setStreamingTrackHandler(null);
    audioService.setPlaybackInterruptHandler(null);
    final native = _nativeBackend;
    if (native is NativePlaybackBackend) {
      native.shouldAllowStopAtEpoch = null;
    }
    streamingManager.removeAuthRequiredListener(_onProviderAuthRequired);
    if (!_useResolverPipeline) unawaited(ytDlpService.stopAll());
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
