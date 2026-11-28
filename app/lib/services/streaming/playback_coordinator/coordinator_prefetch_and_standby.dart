part of '../streaming_playback_coordinator.dart';

bool _shouldTriggerPreDecodeImpl(Duration position, Duration duration) {
  if (duration <= Duration.zero || position < Duration.zero) return false;
  final remaining = duration - position;
  if (remaining < Duration.zero) return false;
  final progress = position.inMilliseconds / duration.inMilliseconds;
  if (duration <= StreamingPlaybackCoordinator._shortTrackThreshold) {
    return progress > StreamingPlaybackCoordinator._preDecodeProgressRatio;
  }
  return remaining <= StreamingPlaybackCoordinator._preResolveThreshold ||
      progress > StreamingPlaybackCoordinator._preDecodeProgressRatio;
}

extension _CoordinatorPrefetchExt on StreamingPlaybackCoordinator {
  Future<void> _prefetchTrackInternal(
    TrackInfo track, {
    CancellationToken? cancelToken,
    void Function(Object error)? onFailure,
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

      if (_disposed || localCancel.isCancelled) return;
      if (spec != null && useLegacySpecCache) {
        _storeSpecCache(track, spec);
      } else if (spec == null &&
          onFailure != null &&
          !streamingManager.isPlaybackAuthBlocked(key.providerId)) {
        final provider = streamingManager.providerFor(key.providerId);
        final providerPlayable =
            provider == null ||
            provider.supportsGuestMode ||
            provider.authState == StreamingAuthState.connected;
        if (providerPlayable) {
          onFailure(StreamingException('串流預載失敗：${track.id}'));
        }
      }
    } catch (e) {
      if (!_disposed &&
          !localCancel.isCancelled &&
          !(e is StreamingException && e.isCancelled)) {
        onFailure?.call(e);
      }
    } finally {
      timeoutTimer?.cancel();
      cancelToken?.removeListener(forwardCancel);
    }
  }

  void _requestHoverPrefetchImpl(TrackInfo track) {
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

    final ap = autoplayController;
    final List<TrackInfo> candidates;
    if (ap != null && ap.enabled) {
      final upcoming = <TrackInfo>[];
      final combined = ap.combinedQueue;
      final curIdx = PlaybackPersistenceService.findTrackIndex(
        combined,
        curState.track!,
      );
      if (curIdx >= 0) {
        for (var i = curIdx + 1; i < combined.length; i++) {
          final c = combined[i];
          if (c.id != currentTrackId && c.preference != -1) {
            upcoming.add(c);
          }
        }
      } else {
        final next = ap.peekNextTrack();
        if (next != null && next.id != currentTrackId) {
          upcoming.add(next);
        }
      }
      candidates = upcoming;
    } else {
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

      candidates = <TrackInfo>[];
      for (var offset = 1; offset <= lookaheadCount; offset++) {
        final nextIdx = currentIdx + offset;
        if (nextIdx >= activeQueue.length) break;
        final candidate = activeQueue[nextIdx];
        if (candidate.id == currentTrackId || candidate.preference == -1) {
          continue;
        }
        if (canPrefetchTrack(candidate)) {
          candidates.add(candidate);
        }
      }
    }
    if (candidates.isEmpty) return;

    _cancelLookaheadPrefetch();
    final cancel = CancellationToken();
    _lookaheadCancelToken = cancel;

    try {
      var prefetchedCount = 0;
      var attemptIdx = 0;
      var failureHandledCount = 0;
      final visitedIds = <String>{};

      while (prefetchedCount < lookaheadCount &&
          failureHandledCount < AutoplayController.maxConsecutiveAutoFailures) {
        if (_disposed || expectedEpoch != _epoch || cancel.isCancelled) {
          return;
        }
        TrackInfo? candidate;
        if (ap != null && ap.enabled) {
          final combined = ap.combinedQueue;
          final curIdx = PlaybackPersistenceService.findTrackIndex(
            combined,
            curState.track!,
          );
          final startIdx = curIdx >= 0 ? curIdx + 1 : 0;
          for (var i = startIdx; i < combined.length; i++) {
            final item = combined[i];
            if (item.id == currentTrackId ||
                item.preference == -1 ||
                visitedIds.contains(item.id)) {
              continue;
            }
            candidate = item;
            break;
          }
        } else {
          if (attemptIdx >= candidates.length) break;
          candidate = candidates[attemptIdx++];
        }
        if (candidate == null) break;
        visitedIds.add(candidate.id);
        if (!canPrefetchTrack(candidate)) {
          prefetchedCount++;
          continue;
        }

        final key = _tryDeriveKey(candidate);
        if (key == null) {
          prefetchedCount++;
          continue;
        }
        if (_peekCachedSpec(key) != null) {
          prefetchedCount++;
          continue;
        }

        _inFlightLookaheadKey = key;
        var failed = false;
        await _prefetchTrackInternal(
          candidate,
          cancelToken: cancel,
          onFailure: (ap != null && ap.isAutoTrack(candidate.id))
              ? (err) {
                  failed = true;
                  if (_disposed ||
                      expectedEpoch != _epoch ||
                      cancel.isCancelled) {
                    return;
                  }
                  failureHandledCount++;
                  final res = ap.handleAutoTrackUnplayable(
                    candidate!,
                    '$err',
                  );
                  if (res.reachedFailureLimit) {
                    _notifiedErrorForEpoch = expectedEpoch;
                    onError?.call(
                      candidate,
                      '連續 ${AutoplayController.maxConsecutiveAutoFailures} 首自動推薦曲目無法播放，已停止自動推薦',
                      false,
                    );
                  }
                }
              : null,
        );
        if (identical(_lookaheadCancelToken, cancel) &&
            _inFlightLookaheadKey == key) {
          _inFlightLookaheadKey = null;
        }
        if (!failed) {
          prefetchedCount++;
        } else if (ap != null &&
            ap.consecutiveAutoFailures >=
                AutoplayController.maxConsecutiveAutoFailures) {
          break;
        }
      }
    } finally {
      if (identical(_lookaheadCancelToken, cancel)) {
        _lookaheadCancelToken = null;
        _inFlightLookaheadKey = null;
      }
    }
  }
}
