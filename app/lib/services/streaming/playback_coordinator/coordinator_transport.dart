part of '../streaming_playback_coordinator.dart';

extension _CoordinatorTransportExt on StreamingPlaybackCoordinator {
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
    final stopEpoch = _nextEpoch();
    _cancelPendingWork();
    _clearStandbyTracking();
    _resolvingRequestId = null;
    _loadingExternalState = null;
    _activeBackend = _nativeBackend;
    return previousExternal.stop(epoch: stopEpoch);
  }

  void _finalizeDeferredAutoplaySkip(TrackInfo settledTrack) {
    if (!_hasDeferredAutoplaySkip) return;
    final ap = autoplayController;
    final abandoned = _burstAbandonedTrack;
    final abandonedWasAuto = _burstAbandonedWasAuto;
    final abandonedPlayed = _burstAbandonedPlayed;
    _hasDeferredAutoplaySkip = false;
    _burstAbandonedTrack = null;
    _burstAbandonedWasAuto = false;
    _burstAbandonedPlayed = Duration.zero;
    ap?.finalizeSettledSkip(
      abandonedTrack: abandoned,
      abandonedWasAuto: abandonedWasAuto,
      abandonedPlayed: abandonedPlayed,
      settledTrack: settledTrack,
    );
  }

  Future<void> _playTrackImpl(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    bool debounce = false,
    bool adaptiveSkipDebounce = false,
    int? queueIndex,
    bool userInitiatedSkip = false,
  }) {
    if (_disposed) return Future.value();
    _pausedPendingTrack = null;
    _suppressStoppedAtEpoch = -1;

    final now = _clock();
    var isRapidBurst = false;
    if (adaptiveSkipDebounce) {
      final prevSkip = _lastSkipAt;
      isRapidBurst =
          prevSkip != null && now.difference(prevSkip) <= rapidSkipWindow;
      _lastSkipAt = now;
    } else if (userInitiatedSkip) {
      _lastSkipAt = now;
    }
    final shouldDebounce =
        (debounce || isRapidBurst) && debounceDelay > Duration.zero;

    final canTryStandbySkip =
        _useResolverPipeline &&
        !shouldDebounce &&
        _preparedStandbyTrackId == track.id &&
        _nativeBackend.isStandbyReady;
    final alreadyTransitionedFromEnded =
        _tracksReferToSame(_lastTransitionTrack, track);

    _setQueueContextInternal(
      queueContext,
      currentTrack: track,
      queueIndex: queueIndex,
      resetLookaheadOnChange: false,
      syncAutoplayCurrentTrack: false,
    );
    _pendingUserInitiatedSkipTrackId = userInitiatedSkip ? track.id : null;
    if (!alreadyTransitionedFromEnded) {
      final ap = autoplayController;
      if (ap != null) {
        if (shouldDebounce && !_hasDeferredAutoplaySkip) {
          _burstAbandonedTrack = ap.currentTrack;
          _burstAbandonedWasAuto = ap.isCurrentFromAutoQueue;
          _burstAbandonedPlayed = ap.currentTrackObservedPlayDuration;
          _hasDeferredAutoplaySkip = true;
        } else if (!shouldDebounce) {
          _hasDeferredAutoplaySkip = false;
          _burstAbandonedTrack = null;
        }
        ap.advanceToTrack(
          track,
          userInitiatedSkip: userInitiatedSkip,
          deferSideEffects: shouldDebounce,
        );
      }
      _lastActivePlayingTrack = null;
      _pendingSwapZeroPosTrack = null;
    }

    if (canTryStandbySkip) {
      _backendCancelSentForBurst = false;
      final fut = _executeStandbySkipOrFallback(
        track,
        queueContext: queueContext,
        queueIndex: queueIndex,
      );
      _activeTaskFuture = fut;
      return fut;
    }

    _clearStandbyTracking();
    final taskEpoch = _nextEpoch();
    _pendingOptimisticTrackId = track.id;
    _pendingOptimisticEpoch = taskEpoch;

    final incomingKey = _useResolverPipeline ? _tryDeriveKey(track) : null;
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    if (_inFlightLookaheadKey == null || _inFlightLookaheadKey != incomingKey) {
      _cancelLookaheadPrefetch();
    }
    if (_inFlightHoverKey == null || _inFlightHoverKey != incomingKey) {
      _cancelHoverPrefetch();
    }
    _cancelAllPreResolves();

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

    ytDlpService.cancelPlaybackProcesses(exceptRequestId: taskEpoch);
    _activeYtmAttempt = null;
    _activeTidalDashAttempt = null;

    final shouldSendBackendCancel =
        !shouldDebounce || !_backendCancelSentForBurst;
    if (shouldDebounce) {
      _backendCancelSentForBurst = true;
    } else {
      _backendCancelSentForBurst = false;
    }

    if (_useResolverPipeline) {
      final touchesNative = _shouldOptimisticallyTouchNativeAudio(track);
      _stopMismatchedActiveBackend(
        touchesNative ? _nativeBackend : _externalBackend,
        taskEpoch,
      );
      final PlaybackState optimisticState;
      if (touchesNative) {
        _loadingExternalState = null;
        if (shouldSendBackendCancel) {
          unawaited(audioService.cancelPendingPlaybackAtEpoch(taskEpoch));
        }
        audioService.beginOptimisticTrackLoadAtEpoch(
          track,
          queue: queueContext,
          epoch: taskEpoch,
        );
        optimisticState = currentState.copyWith(
          status: PlaybackStatus.loading,
          track: track,
          position: Duration.zero,
          playbackEpoch: taskEpoch,
          clearLastError: true,
        );
      } else {
        _loadingExternalState = _externalBackend.currentState.copyWith(
          status: PlaybackStatus.loading,
          track: track,
          position: Duration.zero,
          playbackEpoch: taskEpoch,
          clearLastError: true,
          clockSource: 'external_musickit',
        );
        optimisticState = _loadingExternalState!;
      }
      _latestCoordinatorState = optimisticState;
      if (!_stateController.isClosed) {
        _stateController.add(optimisticState);
      }
      if (!_positionController.isClosed) {
        _positionController.add(Duration.zero);
      }
    } else {
      if (shouldSendBackendCancel) {
        unawaited(audioService.cancelPendingPlaybackAtEpoch(taskEpoch));
      }
      audioService.beginOptimisticTrackLoadAtEpoch(
        track,
        queue: queueContext,
        epoch: taskEpoch,
      );
      final optimisticLegacy = currentState.copyWith(
        status: PlaybackStatus.loading,
        track: track,
        position: Duration.zero,
        playbackEpoch: taskEpoch,
        clearLastError: true,
      );
      _latestCoordinatorState = optimisticLegacy;
      if (!_stateController.isClosed) {
        _stateController.add(optimisticLegacy);
      }
      if (!_positionController.isClosed) {
        _positionController.add(Duration.zero);
      }
    }

    Future<void> launchTask({required bool debounced}) => _useResolverPipeline
        ? _executeResolveAndPlaySpec(
            track,
            taskEpoch,
            cancel,
            debounced: debounced,
          )
        : _executeResolveAndPlayLegacy(track, taskEpoch, cancel);

    if (shouldDebounce) {
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
        final fut = launchTask(debounced: true);
        _activeTaskFuture = fut;
        fut.whenComplete(() {
          if (!completer.isCompleted) completer.complete();
        });
      });
      _activeTaskFuture = completer.future;
      return completer.future;
    }

    final fut = launchTask(debounced: false);
    _activeTaskFuture = fut;
    return fut;
  }

  PlaybackBackend get _effectiveControlBackend =>
      _loadingExternalState != null
          ? _externalBackend
          : (_activeBackend ?? _nativeBackend);

  Future<void> _pauseImpl() => _pauseWithCancellationImpl();

  Future<void> _resumeImpl() {
    final pending = _pausedPendingTrack;
    if (pending != null) {
      final curTrack = currentState.track;
      _pausedPendingTrack = null;
      _suppressStoppedAtEpoch = -1;
      if (curTrack == null || _tracksReferToSame(curTrack, pending)) {
        _loadingExternalState = null;
        return playTrack(
          pending,
          queueContext: hasSharedQueue
              ? List<TrackInfo>.from(_sharedQueue)
              : null,
        );
      }
    }
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

  Future<void> _togglePlayPauseImpl() {
    if (_pausedPendingTrack != null &&
        currentState.status == PlaybackStatus.paused) {
      return resume();
    }
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
    if (currentState.status == PlaybackStatus.loading) {
      return pause();
    }
    return audioService.togglePlayPause();
  }

  Future<void> _seekImpl(Duration position) {
    final seekEpoch = _nextEpoch();
    _pendingSwapZeroPosTrack = null;
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

  Future<void> _setVolumeImpl(double volume) {
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

  Future<void> _toggleMuteImpl() {
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

  Future<void> _stopImpl() async {
    final stopEpoch = _nextEpoch();
    _cancelPendingWork();
    _clearStandbyTracking();
    _lastActivePlayingTrack = null;
    _lastTransitionTrack = null;
    _pendingSwapZeroPosTrack = null;
    _pendingOptimisticTrackId = null;
    _pendingOptimisticEpoch = -1;
    _pausedPendingTrack = null;
    _suppressStoppedAtEpoch = -1;
    _backendCancelSentForBurst = false;
    _hasDeferredAutoplaySkip = false;
    _burstAbandonedTrack = null;
    _latestCoordinatorState = null;
    final wasLoadingExternal = _loadingExternalState != null;
    _loadingExternalState = null;

    ytDlpService.cancelPlaybackProcesses();
    _activeYtmAttempt = null;
    _activeTidalDashAttempt = null;

    if (_useResolverPipeline) {
      final target =
          _activeBackend ??
          (wasLoadingExternal ? _externalBackend : _nativeBackend);
      await target.stop(epoch: stopEpoch);
      return;
    }

    await audioService.stop();
  }
}
