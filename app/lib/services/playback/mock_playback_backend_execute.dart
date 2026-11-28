part of 'mock_playback_backend.dart';

mixin _MockPlaybackExecuteMixin on _MockPlaybackBackendBase {
  @override
  Future<Result<void, LuminaError>> execute(PlaybackCommand command) async {
    if (_disposed) {
      return const Err<void, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.invalidState,
          message: 'Backend has been disposed',
        ),
      );
    }
    if (commandLatency > Duration.zero) {
      await Future<void>.delayed(commandLatency);
    }
    if (_disposed) {
      return const Err<void, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.invalidState,
          message: 'Backend has been disposed',
        ),
      );
    }
    final injected = _takeInjectedError();
    if (injected != null) {
      _emitError(injected);
      _state = _state.copyWith(
        status: PlaybackLifecycleState.error,
        error: injected,
        timestampMs: _nowMs(),
      );
      _emitState(_state);
      return Err<void, LuminaError>(injected);
    }

    commandHistory.add(command);
    final now = _nowMs();

    switch (command) {
      case PlayCommand(:final track, :final startPositionMs, :final playbackEpoch):
        final nextEpoch =
            (playbackEpoch != null && playbackEpoch > _state.playbackEpoch)
                ? playbackEpoch
                : _state.playbackEpoch + 1;
        final pos = (startPositionMs ?? 0).clamp(
          0,
          track.durationMs > 0 ? track.durationMs : 1 << 30,
        );
        final nextSwap = _state.track?.trackId != track.trackId
            ? _state.swapGeneration + 1
            : _state.swapGeneration;
        _state = _state.copyWith(
          status: PlaybackLifecycleState.playing,
          track: track,
          positionMs: pos,
          durationMs: track.durationMs,
          timestampMs: now,
          audioQuality: track.audioQuality ?? _state.audioQuality,
          playbackEpoch: nextEpoch,
          swapGeneration: nextSwap,
          isSeeking: false,
          clearError: true,
        );
        _syncQueueIndexForTrack(track.trackId, now);
        _emitState(_state);

      case PauseCommand():
        _state = _state.copyWith(
          status: PlaybackLifecycleState.paused,
          timestampMs: now,
          isSeeking: false,
        );
        _emitState(_state);

      case ResumeCommand():
        if (_state.track == null && _queue.items.isNotEmpty) {
          final targetIdx = _queue.currentIndex ?? 0;
          final targetTrack = _queue.items[targetIdx].track;
          _state = _state.copyWith(
            status: PlaybackLifecycleState.playing,
            track: targetTrack,
            durationMs: targetTrack.durationMs,
            audioQuality: targetTrack.audioQuality ?? _state.audioQuality,
            timestampMs: now,
            playbackEpoch: _state.playbackEpoch + 1,
            clearError: true,
          );
        } else {
          _state = _state.copyWith(
            status: PlaybackLifecycleState.playing,
            timestampMs: now,
            isSeeking: false,
            clearError: true,
          );
        }
        _emitState(_state);

      case StopCommand():
        _state = _state.copyWith(
          status: PlaybackLifecycleState.stopped,
          positionMs: 0,
          timestampMs: now,
          isSeeking: false,
          clearError: true,
        );
        _emitState(_state);

      case SeekCommand(:final positionMs):
        final maxMs = _state.durationMs > 0 ? _state.durationMs : (1 << 30);
        final clamped = positionMs.clamp(0, maxMs);
        _state = _state.copyWith(
          positionMs: clamped,
          timestampMs: now,
          seekEpoch: _state.seekEpoch + 1,
          isSeeking: false,
        );
        _emitState(_state);

      case NextCommand():
        _advanceQueue(forward: true, now: now);

      case PreviousCommand():
        _advanceQueue(forward: false, now: now);

      case SetVolumeCommand(:final volume):
        final clamped = volume.clamp(0.0, 1.0);
        _state = _state.copyWith(
          volume: clamped,
          isMuted: clamped == 0.0,
          timestampMs: now,
        );
        _emitState(_state);

      case SetMuteCommand(:final muted):
        _state = _state.copyWith(isMuted: muted, timestampMs: now);
        _emitState(_state);

      case SetRepeatModeCommand(:final mode):
        _queue = _queue.copyWith(
          repeatMode: mode,
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _state = _state.copyWith(repeatMode: mode, timestampMs: now);
        _emitQueue(_queue);
        _emitState(_state);

      case SetShuffleCommand(:final enabled):
        _queue = _queue.copyWith(
          shuffle: enabled,
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _state = _state.copyWith(shuffle: enabled, timestampMs: now);
        _emitQueue(_queue);
        _emitState(_state);

      case SetOutputDeviceCommand(:final deviceId):
        final matchedIndex = _devices.indexWhere((d) => d.id == deviceId);
        if (matchedIndex < 0) {
          final err = LuminaError(
            code: LuminaErrorCode.deviceNotFound,
            message: 'Audio device not found: $deviceId',
          );
          _emitError(err);
          return Err<void, LuminaError>(err);
        }
        _devices = List<ProtocolAudioDeviceInfo>.unmodifiable(
          _devices.map((d) => d.copyWith(isActive: d.id == deviceId)),
        );
        final active = _devices[matchedIndex];
        _state = _state.copyWith(
          activeDevice: active,
          deviceLost: false,
          timestampMs: now,
        );
        _emitDevices(_devices);
        _emitState(_state);

      case SetActiveZoneCommand(:final zoneId):
        final matchedIndex = _zones.indexWhere((z) => z.id == zoneId);
        if (matchedIndex < 0) {
          final err = LuminaError(
            code: LuminaErrorCode.invalidCommand,
            message: 'Audio zone not found: $zoneId',
          );
          _emitError(err);
          return Err<void, LuminaError>(err);
        }
        _zones = List<ProtocolZoneInfo>.unmodifiable(
          _zones.map((z) => z.copyWith(isActive: z.id == zoneId)),
        );
        _state = _state.copyWith(activeZoneId: zoneId, timestampMs: now);
        _emitZones(_zones);
        _emitState(_state);

      case LoadQueueCommand(:final items, :final startIndex, :final autoPlay):
        final queueItems = items
            .map(
              (t) => QueueItem(
                itemId: 'q-${++_itemIdCounter}',
                track: t,
                isUserQueued: true,
              ),
            )
            .toList(growable: false);
        final resolvedIdx = queueItems.isEmpty
            ? null
            : startIndex.clamp(0, queueItems.length - 1);
        _queue = _queue.copyWith(
          items: queueItems,
          currentIndex: resolvedIdx,
          clearCurrentIndex: resolvedIdx == null,
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _emitQueue(_queue);
        if (resolvedIdx != null) {
          final selected = queueItems[resolvedIdx].track;
          _state = _state.copyWith(
            status: autoPlay
                ? PlaybackLifecycleState.playing
                : PlaybackLifecycleState.paused,
            track: selected,
            positionMs: 0,
            durationMs: selected.durationMs,
            audioQuality: selected.audioQuality ?? _state.audioQuality,
            timestampMs: now,
            playbackEpoch: _state.playbackEpoch + 1,
            swapGeneration: _state.swapGeneration + 1,
            clearError: true,
          );
          _emitState(_state);
        }

      case EnqueueCommand(:final items, :final playNext):
        if (items.isEmpty) break;
        final newItems = items
            .map(
              (t) => QueueItem(
                itemId: 'q-${++_itemIdCounter}',
                track: t,
                isUserQueued: true,
              ),
            )
            .toList(growable: false);
        final updated = List<QueueItem>.of(_queue.items);
        if (playNext && _queue.currentIndex != null) {
          final insertAt = (_queue.currentIndex! + 1).clamp(0, updated.length);
          updated.insertAll(insertAt, newItems);
        } else {
          updated.addAll(newItems);
        }
        _queue = _queue.copyWith(
          items: updated,
          currentIndex: _queue.currentIndex ?? (updated.isNotEmpty ? 0 : null),
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _emitQueue(_queue);

      case RemoveQueueItemCommand(:final index):
        if (index < 0 || index >= _queue.items.length) {
          const err = LuminaError(
            code: LuminaErrorCode.invalidCommand,
            message: 'Queue index out of bounds',
          );
          _emitError(err);
          return const Err<void, LuminaError>(err);
        }
        final updated = List<QueueItem>.of(_queue.items)..removeAt(index);
        int? nextIdx = _queue.currentIndex;
        if (updated.isEmpty) {
          nextIdx = null;
        } else if (nextIdx != null) {
          if (index < nextIdx) {
            nextIdx -= 1;
          } else if (nextIdx >= updated.length) {
            nextIdx = updated.length - 1;
          }
        }
        _queue = _queue.copyWith(
          items: updated,
          currentIndex: nextIdx,
          clearCurrentIndex: nextIdx == null,
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _emitQueue(_queue);

      case ReorderQueueCommand(:final fromIndex, :final toIndex):
        if (fromIndex < 0 ||
            fromIndex >= _queue.items.length ||
            toIndex < 0 ||
            toIndex >= _queue.items.length) {
          const err = LuminaError(
            code: LuminaErrorCode.invalidCommand,
            message: 'Reorder index out of bounds',
          );
          _emitError(err);
          return const Err<void, LuminaError>(err);
        }
        final updated = List<QueueItem>.of(_queue.items);
        final moved = updated.removeAt(fromIndex);
        updated.insert(toIndex, moved);
        int? nextIdx = _queue.currentIndex;
        if (nextIdx != null) {
          if (nextIdx == fromIndex) {
            nextIdx = toIndex;
          } else if (fromIndex < nextIdx && toIndex >= nextIdx) {
            nextIdx -= 1;
          } else if (fromIndex > nextIdx && toIndex <= nextIdx) {
            nextIdx += 1;
          }
        }
        _queue = _queue.copyWith(
          items: updated,
          currentIndex: nextIdx,
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _emitQueue(_queue);

      case ClearQueueCommand():
        _queue = _queue.copyWith(
          items: const <QueueItem>[],
          clearCurrentIndex: true,
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _emitQueue(_queue);

      case ClearUpcomingQueueCommand():
        final curIdx = _queue.currentIndex;
        final List<QueueItem> truncated;
        int? nextIdx = curIdx;
        if (curIdx != null && curIdx >= 0 && curIdx < _queue.items.length) {
          truncated = List<QueueItem>.unmodifiable(
            _queue.items.sublist(0, curIdx + 1),
          );
        } else {
          truncated = const <QueueItem>[];
          nextIdx = null;
        }
        _queue = _queue.copyWith(
          items: truncated,
          currentIndex: nextIdx,
          clearCurrentIndex: nextIdx == null,
          queueEpoch: _queue.queueEpoch + 1,
          timestampMs: now,
        );
        _emitQueue(_queue);

      case ReconnectDeviceCommand():
        _state = _state.copyWith(
          deviceLost: false,
          clearError: true,
          timestampMs: now,
        );
        _emitState(_state);
    }

    return const Ok<void, LuminaError>(null);
  }

  void _syncQueueIndexForTrack(String trackId, int now) {
    final idx = _queue.items.indexWhere((i) => i.track.trackId == trackId);
    if (idx >= 0 && idx != _queue.currentIndex) {
      _queue = _queue.copyWith(
        currentIndex: idx,
        queueEpoch: _queue.queueEpoch + 1,
        timestampMs: now,
      );
      _emitQueue(_queue);
    }
  }

  void _advanceQueue({required bool forward, required int now}) {
    if (_queue.items.isEmpty) return;
    final len = _queue.items.length;
    final currentIdx = _queue.currentIndex ?? 0;

    int targetIdx;
    if (_queue.repeatMode == RepeatMode.one && forward) {
      targetIdx = currentIdx;
    } else if (_queue.shuffle && len > 1 && forward) {
      final candidates = <int>[
        for (var i = 0; i < len; i++)
          if (i != currentIdx) i,
      ];
      targetIdx = candidates[_random.nextInt(candidates.length)];
    } else if (forward) {
      if (currentIdx + 1 < len) {
        targetIdx = currentIdx + 1;
      } else if (_queue.repeatMode == RepeatMode.all) {
        targetIdx = 0;
      } else {
        _state = _state.copyWith(
          status: PlaybackLifecycleState.ended,
          positionMs: _state.durationMs,
          timestampMs: now,
        );
        _emitState(_state);
        return;
      }
    } else {
      if (currentIdx > 0) {
        targetIdx = currentIdx - 1;
      } else if (_queue.repeatMode == RepeatMode.all) {
        targetIdx = len - 1;
      } else {
        targetIdx = 0;
      }
    }

    final nextTrack = _queue.items[targetIdx].track;
    _queue = _queue.copyWith(
      currentIndex: targetIdx,
      queueEpoch: _queue.queueEpoch + 1,
      timestampMs: now,
    );
    _state = _state.copyWith(
      status: PlaybackLifecycleState.playing,
      track: nextTrack,
      positionMs: 0,
      durationMs: nextTrack.durationMs,
      audioQuality: nextTrack.audioQuality ?? _state.audioQuality,
      timestampMs: now,
      playbackEpoch: _state.playbackEpoch + 1,
      swapGeneration: _state.swapGeneration + 1,
      isSeeking: false,
      clearError: true,
    );
    _emitQueue(_queue);
    _emitState(_state);
  }

  LuminaError? _takeInjectedError() {
    if (nextError != null) {
      final err = nextError;
      nextError = null;
      return err;
    }
    return persistentError;
  }
}
