part of '../streaming_playback_coordinator.dart';

extension _CoordinatorStep4QueueOps on StreamingPlaybackCoordinator {
  /// Adds [tracks] to the active user queue (or [_sharedQueue] when no
  /// [AutoplayController] is attached) without duplicating existing track IDs.
  int _enqueueTracksImpl(List<TrackInfo> tracks, {bool playNext = false}) {
    if (_disposed || tracks.isEmpty) return 0;
    final ap = autoplayController;
    if (ap != null) {
      final added = ap.appendToUserQueue(tracks, playNext: playNext);
      if (added > 0) {
        _sharedQueue
          ..clear()
          ..addAll(ap.combinedQueue);
        final cur = currentState.track;
        if (cur != null) {
          _sharedQueueIndex = _findTrackIndexInList(_sharedQueue, cur);
        }
        if (!_queueUpdatedController.isClosed) {
          _queueUpdatedController.add(List<TrackInfo>.unmodifiable(queue));
        }
      }
      return added;
    }

    if (_sharedQueue.isEmpty && audioService.queue.isNotEmpty) {
      _sharedQueue.addAll(audioService.queue);
    }
    final cur = currentState.track;
    final activeIdx = cur != null ? _findTrackIndexInList(_sharedQueue, cur) : -1;
    var insertAt = playNext
        ? (activeIdx >= 0 ? activeIdx + 1 : 0).clamp(0, _sharedQueue.length)
        : _sharedQueue.length;
    var added = 0;
    for (final t in tracks) {
      if (!_sharedQueue.any((e) => e.id == t.id)) {
        if (playNext) {
          _sharedQueue.insert(insertAt, t);
          insertAt++;
        } else {
          _sharedQueue.add(t);
        }
        added++;
      }
    }
    if (added > 0) {
      if (cur != null) {
        _sharedQueueIndex = _findTrackIndexInList(_sharedQueue, cur);
      }
      if (!_queueUpdatedController.isClosed) {
        _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_sharedQueue));
      }
    }
    return added;
  }

  /// Clears all upcoming tracks strictly after the currently playing track
  /// across [AutoplayController], [_sharedQueue], lookahead/standby buffers,
  /// and the inner [AudioService], without stopping or reloading active playback.
  Future<int> _clearUpcomingQueueImpl() async {
    if (_disposed) return 0;

    _cancelLookaheadPrefetch();
    _resetLookaheadCompleted();
    _cancelAllPreResolves();
    _clearStandbyTracking();

    final cur = currentState.track;
    final ap = autoplayController;
    final wasUsingAutoplayQueue = ap != null && ap.combinedQueue.isNotEmpty;
    var removedCoordinator = 0;

    if (ap != null) {
      removedCoordinator = ap.clearUpcoming();
      final combined = ap.combinedQueue;
      if (combined.isNotEmpty) {
        _sharedQueue
          ..clear()
          ..addAll(combined);
        _sharedQueueIndex = cur != null
            ? _findTrackIndexInList(_sharedQueue, cur)
            : -1;
      } else {
        final removedShared = _truncateSharedQueueAfter(cur);
        if (removedCoordinator == 0) {
          removedCoordinator = removedShared;
        }
      }
    } else {
      removedCoordinator = _truncateSharedQueueAfter(cur);
    }

    final removedInner = await audioService.clearUpcomingQueue();
    final totalRemoved = wasUsingAutoplayQueue
        ? removedCoordinator
        : (removedCoordinator > removedInner
              ? removedCoordinator
              : removedInner);

    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(queue));
    }
    return totalRemoved;
  }

  int _truncateSharedQueueAfter(TrackInfo? activeTrack) {
    if (_sharedQueue.isEmpty) {
      _sharedQueueIndex = -1;
      return 0;
    }
    final activeIdx = activeTrack != null
        ? _findTrackIndexInList(_sharedQueue, activeTrack)
        : -1;
    final keepCount = activeIdx >= 0 ? activeIdx + 1 : 0;
    final removed = _sharedQueue.length - keepCount;
    if (removed > 0) {
      _sharedQueue.length = keepCount;
    }
    _sharedQueueIndex = keepCount > 0 ? activeIdx : -1;
    return removed;
  }

  /// Synchronizes an updated tri-state [preference] for [trackId] into the
  /// coordinator's shared queue, [AutoplayController], and [AutoplayFilter].
  void _syncTrackPreferenceImpl(String trackId, int preference) {
    if (_disposed || trackId.isEmpty) return;
    for (var i = 0; i < _sharedQueue.length; i++) {
      if (_sharedQueue[i].id == trackId) {
        _sharedQueue[i] = _sharedQueue[i].copyWith(preference: preference);
      }
    }
    autoplayController?.syncTrackPreference(trackId, preference);
    if (preference == -1 && _preparedStandbyTrackId == trackId) {
      _clearStandbyTracking();
    }
  }

  /// Synchronizes an updated tri-state [preference] for an artist name/key into
  /// [AutoplayFilter] so banned artists are excluded from autoplay refills.
  void _syncArtistPreferenceImpl(String artistNameOrId, int preference) {
    if (_disposed || artistNameOrId.trim().isEmpty) return;
    autoplayController?.syncArtistPreference(artistNameOrId, preference);
  }

  /// Steps from [currentIdx] in [activeQueue] by [delta] (`+1` or `-1`),
  /// skipping tracks marked as banned (`preference == -1`).
  /// Returns `-1` if no non-banned track exists in [activeQueue].
  int _findNextPlayableQueueIndex(
    List<TrackInfo> activeQueue,
    int currentIdx,
    int delta,
  ) {
    final len = activeQueue.length;
    if (len == 0) return -1;
    final step = delta >= 0 ? 1 : -1;
    final startIdx = currentIdx >= 0
        ? (currentIdx + step + len) % len
        : (step > 0 ? 0 : len - 1);
    for (var checked = 0; checked < len; checked++) {
      final candidateIdx = (startIdx + checked * step + len * 2) % len;
      if (activeQueue[candidateIdx].preference != -1) {
        return candidateIdx;
      }
    }
    return -1;
  }

  Future<void> _playResolvedOrLocalTrack(
    TrackInfo target, {
    bool debounce = false,
    bool adaptiveSkipDebounce = false,
    bool userInitiatedSkip = false,
  }) async {
    if (_disposed) return;
    final ap = autoplayController;
    final snapshot = (ap != null && ap.combinedQueue.isNotEmpty)
        ? List<TrackInfo>.from(ap.combinedQueue)
        : List<TrackInfo>.from(queue);

    await playTrack(
      target,
      queueContext: snapshot.isNotEmpty ? snapshot : null,
      debounce: debounce,
      adaptiveSkipDebounce: adaptiveSkipDebounce,
      userInitiatedSkip: userInitiatedSkip,
    );
  }

  Future<void> _stepQueue({required int delta}) async {
    final ap = autoplayController;
    if (ap != null && ap.enabled && delta > 0) {
      var nextTrack = ap.peekNextTrack();
      if (nextTrack == null) {
        final refillGuardEpoch = _epoch;
        await ap.maybeTriggerRefill();
        if (_disposed || _epoch != refillGuardEpoch) return;
        nextTrack = ap.peekNextTrack();
      }
      if (nextTrack == null) {
        return;
      }
      await _playResolvedOrLocalTrack(
        nextTrack,
        adaptiveSkipDebounce: true,
        userInitiatedSkip: true,
      );
      return;
    }

    final activeQueue = queue;
    if (activeQueue.isEmpty) {
      return delta >= 0 ? audioService.next() : audioService.previous();
    }

    final curTrack = currentState.track;
    int currentIdx = -1;
    if (_sharedQueue.isNotEmpty &&
        _sharedQueueIndex >= 0 &&
        _sharedQueueIndex < activeQueue.length) {
      if (curTrack == null ||
          PlaybackPersistenceService.findTrackIndex(
                <TrackInfo>[activeQueue[_sharedQueueIndex]],
                curTrack,
              ) ==
              0) {
        currentIdx = _sharedQueueIndex;
      }
    }
    if (currentIdx < 0 && curTrack != null) {
      currentIdx = PlaybackPersistenceService.findTrackIndex(
        activeQueue,
        curTrack,
      );
    }

    final targetIdx = _findNextPlayableQueueIndex(activeQueue, currentIdx, delta);
    if (targetIdx < 0) return;

    final snapshot = List<TrackInfo>.from(activeQueue);
    final target = snapshot[targetIdx];
    if (_sharedQueue.isNotEmpty) {
      _sharedQueueIndex = targetIdx;
    }

    await playTrack(
      target,
      queueContext: snapshot,
      adaptiveSkipDebounce: true,
      queueIndex: targetIdx,
      userInitiatedSkip: delta > 0,
    );
  }
}
