part of '../streaming_playback_coordinator.dart';

extension _CoordinatorTransitionsExt on StreamingPlaybackCoordinator {
  TrackInfo _onTrackTransitionedImpl(
    TrackInfo newTrack, {
    bool backendInitiated = true,
    bool userInitiatedSkip = false,
    int? swapGeneration,
    PlaybackState? sourceState,
  }) {
    if (_disposed) return newTrack;

    final baseState = sourceState ?? currentState;
    final effectiveSwapGen =
        swapGeneration ?? sourceState?.swapGeneration ?? baseState.swapGeneration;
    if (effectiveSwapGen < _lastObservedBackendSwapGen) {
      _lastObservedBackendSwapGen = effectiveSwapGen;
      _lastTransitionSwapGen = effectiveSwapGen;
    }

    final sameTrack = _tracksReferToSame(_lastTransitionTrack, newTrack);
    final swapDidAdvance =
        effectiveSwapGen > 0 && effectiveSwapGen > _lastTransitionSwapGen;
    if (sameTrack && !swapDidAdvance) {
      return _lastTransitionTrack ?? baseState.track ?? newTrack;
    }

    final effectiveUserSkip =
        userInitiatedSkip ||
        (_pendingUserInitiatedSkipTrackId != null &&
            _tracksReferToSame(
              TrackInfo(
                id: _pendingUserInitiatedSkipTrackId!,
                title: '',
                artist: '',
                album: '',
                duration: Duration.zero,
                format: newTrack.format,
                providerName: newTrack.providerName,
              ),
              newTrack,
            ));
    if (effectiveUserSkip) {
      _pendingUserInitiatedSkipTrackId = null;
    }

    if (effectiveSwapGen > _lastTransitionSwapGen) {
      _lastTransitionSwapGen = effectiveSwapGen;
    }
    if (effectiveSwapGen > _lastObservedBackendSwapGen) {
      _lastObservedBackendSwapGen = effectiveSwapGen;
    }

    TrackInfo effectiveTrack = newTrack;
    final ap = autoplayController;
    if (ap != null) {
      _suppressAutoplayChangeQueueEmit = true;
      try {
        effectiveTrack = ap.consumeTransitionedTrack(
          newTrack,
          userInitiatedSkip: effectiveUserSkip,
          forceAdvance: swapDidAdvance,
        );
      } finally {
        _suppressAutoplayChangeQueueEmit = false;
      }
      final combined = ap.combinedQueue;
      if (combined.isNotEmpty) {
        _sharedQueue
          ..clear()
          ..addAll(combined);
        _sharedQueueIndex = _findTrackIndexInList(_sharedQueue, effectiveTrack);
      }
    } else {
      if (_sharedQueue.isEmpty && audioService.queue.isNotEmpty) {
        _sharedQueue
          ..clear()
          ..addAll(audioService.queue);
      }
      final idx = _findTrackIndexInList(_sharedQueue, newTrack);
      if (idx >= 0) {
        effectiveTrack = _mergeRichTrack(newTrack, _sharedQueue[idx]);
        _sharedQueue[idx] = effectiveTrack;
        _sharedQueueIndex = idx;
      } else if (audioService.queue.isNotEmpty) {
        final svcIdx = _findTrackIndexInList(audioService.queue, newTrack);
        if (svcIdx >= 0) {
          effectiveTrack = _mergeRichTrack(
            newTrack,
            audioService.queue[svcIdx],
          );
        }
      }
    }

    _lastTransitionTrack = effectiveTrack;
    _lastActivePlayingTrack = effectiveTrack;

    if (sourceState?.status == PlaybackStatus.playing) {
      _handledEndedTrackId = null;
      _handledEndedEpoch = -1;
    }
    _clearStandbyTracking();
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();

    final shouldResetPos =
        !backendInitiated ||
        swapDidAdvance ||
        (backendInitiated && _hadPreviousTransition) ||
        baseState.position <= const Duration(milliseconds: 500);
    _hadPreviousTransition = true;
    final nextPos = shouldResetPos ? Duration.zero : baseState.position;
    if (shouldResetPos) {
      _pendingSwapZeroPosTrack = effectiveTrack;
      _pendingSwapZeroPosGen = effectiveSwapGen;
      _pendingSwapInitialPos =
          (baseState.position > Duration.zero &&
              baseState.position <= const Duration(milliseconds: 500))
          ? baseState.position
          : null;
    } else {
      _pendingSwapZeroPosTrack = null;
      _pendingSwapZeroPosGen = -1;
      _pendingSwapInitialPos = null;
    }

    final emittedState = baseState.copyWith(
      track: effectiveTrack,
      position: nextPos,
      swapGeneration: effectiveSwapGen,
      clearLastError: baseState.status != PlaybackStatus.error,
    );
    _latestCoordinatorState = emittedState;

    if (!_stateController.isClosed) {
      _stateController.add(emittedState);
    }
    if (!_positionController.isClosed) {
      _positionController.add(nextPos);
    }
    if (!_trackChangedController.isClosed) {
      _trackChangedController.add(effectiveTrack);
    }
    if (!_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(queue));
    }

    if (ap != null) {
      ap.onPlaybackProgress(effectiveTrack, nextPos);
      if (ap.needsRefill) {
        unawaited(ap.maybeTriggerRefill());
      }
    }
    _syncStablePlayTimer(emittedState);
    _maybePreResolveNext(emittedState, nextPos);

    return effectiveTrack;
  }

  bool _processStateTransitionOrEnd(PlaybackState state) {
    if (_disposed) return false;
    final ap = autoplayController;

    if (state.swapGeneration < _lastObservedBackendSwapGen) {
      _lastObservedBackendSwapGen = state.swapGeneration;
      _lastTransitionSwapGen = state.swapGeneration;
    }

    final track = state.track;
    final swapIncremented =
        state.swapGeneration > 0 &&
        state.swapGeneration > _lastObservedBackendSwapGen;
    final playingTrackChanged =
        state.status == PlaybackStatus.playing &&
        track != null &&
        !_tracksReferToSame(_lastActivePlayingTrack, track);

    if (track != null &&
        ((state.status == PlaybackStatus.playing &&
                (swapIncremented || playingTrackChanged)) ||
            (swapIncremented &&
                state.status != PlaybackStatus.stopped &&
                state.status != PlaybackStatus.error &&
                state.status != PlaybackStatus.uninitialized))) {
      onTrackTransitioned(
        track,
        backendInitiated: true,
        swapGeneration: state.swapGeneration,
        sourceState: state,
      );
      return true;
    }

    if (state.status == PlaybackStatus.playing && track != null) {
      _handledEndedTrackId = null;
      _handledEndedEpoch = -1;
      if (_pendingSwapZeroPosTrack != null && state.position > Duration.zero) {
        _pendingSwapZeroPosTrack = null;
        _pendingSwapZeroPosGen = -1;
      }
      ap?.onPlaybackProgress(track, state.position);
      return false;
    }

    if (state.status == PlaybackStatus.stopped ||
        state.status == PlaybackStatus.uninitialized) {
      _lastActivePlayingTrack = null;
      _lastTransitionTrack = null;
      _pendingSwapZeroPosTrack = null;
      _pendingSwapZeroPosGen = -1;
      return false;
    }

    if (state.status == PlaybackStatus.ended && ap != null) {
      final endedTrack = track ?? ap.currentTrack ?? currentState.track;
      if (endedTrack != null) {
        final activeTrack = ap.currentTrack;
        final isStaleEndedTrack =
            activeTrack != null && !_tracksReferToSame(activeTrack, endedTrack);
        final isAlreadyHandled =
            _handledEndedTrackId == endedTrack.id &&
            (_handledEndedEpoch == _epoch || _resolvingRequestId != null);
        if (!isStaleEndedTrack && !isAlreadyHandled) {
          _handledEndedTrackId = endedTrack.id;
          _handledEndedEpoch = _epoch;
          _lastActivePlayingTrack = null;
          unawaited(_advanceAfterTrackEnded(endedTrack, _epoch));
        }
      }
    }
    return false;
  }

  PlaybackState _enrichStateFromCoordinator(PlaybackState state) {
    final track = state.track;
    final latest = _latestCoordinatorState;
    if (track == null ||
        latest?.track == null ||
        !_tracksReferToSame(track, latest!.track)) {
      _latestCoordinatorState = state;
      return state;
    }
    final mergedTrack = _mergeRichTrack(track, latest.track);
    final effSwap = state.swapGeneration > latest.swapGeneration
        ? state.swapGeneration
        : latest.swapGeneration;
    final enriched = state.copyWith(
      track: mergedTrack,
      swapGeneration: effSwap,
    );
    _latestCoordinatorState = enriched;
    return enriched;
  }

  Future<void> _advanceAfterTrackEnded(
    TrackInfo endedTrack,
    int endedEpoch,
  ) async {
    final ap = autoplayController;
    if (_disposed || ap == null || endedEpoch != _epoch) return;
    var nextTrack = ap.peekNextTrack();
    if (nextTrack == null && ap.enabled) {
      await ap.maybeTriggerRefill(
        seedOverride: TrackMetadata.fromTrackInfo(endedTrack),
      );
      if (_disposed || endedEpoch != _epoch) return;
      nextTrack = ap.peekNextTrack();
    }
    if (nextTrack == null || nextTrack.preference == -1) return;
    final effectiveNext = onTrackTransitioned(
      nextTrack,
      backendInitiated: true,
      userInitiatedSkip: false,
      sourceState: currentState.copyWith(
        status: PlaybackStatus.loading,
        track: nextTrack,
        position: Duration.zero,
        clearLastError: true,
      ),
    );
    await _playResolvedOrLocalTrack(effectiveNext, debounce: false);
  }
}
