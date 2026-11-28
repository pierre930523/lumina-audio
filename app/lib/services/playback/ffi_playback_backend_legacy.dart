part of 'ffi_playback_backend.dart';

mixin _FfiPlaybackLegacyMixin on _FfiPlaybackBackendBase {
  void _onAudioServiceState(PlaybackState legacy) {
    if (_disposed) return;
    final next = ProtocolPlaybackState.fromLegacy(
      legacy,
      timestampMs: legacy.timestampMs > 0 ? legacy.timestampMs : _nowMs(),
      dspBypassed: _audioService?.currentSignalPath.dspBypassed ?? true,
      strictBitPerfect: _audioService?.isStrictBitPerfect ?? false,
    );
    _state = next;
    _emitState(next);
    if (next.error != null) {
      _emitError(next.error!);
    }
  }

  void _syncQueueFromAudioService() {
    final svc = _audioService;
    if (svc == null) return;
    final tracks = svc.queue;
    final currentId = svc.currentState.track?.id;
    int? currentIdx;
    final items = <QueueItem>[];
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      if (currentId != null && t.id == currentId && currentIdx == null) {
        currentIdx = i;
      }
      items.add(
        QueueItem(
          itemId: 'local-$i-${t.id}',
          track: ProtocolTrackMetadata.fromTrackInfo(t),
          isUserQueued: true,
        ),
      );
    }
    _queue = _queue.copyWith(
      items: items,
      currentIndex: currentIdx,
      clearCurrentIndex: currentIdx == null,
      repeatMode: svc.repeatMode,
      shuffle: svc.shuffle,
      timestampMs: _nowMs(),
    );
  }

  Future<Result<void, LuminaError>> _executeViaAudioService(
    AudioService svc,
    PlaybackCommand command,
  ) async {
    try {
      switch (command) {
        case PlayCommand(:final track, :final startPositionMs):
          await svc.play(track: track.toTrackInfo());
          if (startPositionMs != null && startPositionMs > 0) {
            await svc.seek(Duration(milliseconds: startPositionMs));
          }
        case PauseCommand():
          await svc.pause();
        case ResumeCommand():
          await svc.resume();
        case StopCommand():
          await svc.stop();
        case SeekCommand(:final positionMs):
          await svc.seek(Duration(milliseconds: positionMs));
        case NextCommand():
          await svc.next();
        case PreviousCommand():
          await svc.previous();
        case SetVolumeCommand(:final volume):
          await svc.setVolume(volume);
        case SetMuteCommand(:final muted):
          if (svc.currentState.isMuted != muted) {
            await svc.toggleMute();
          }
        case SetRepeatModeCommand(:final mode):
          await svc.setRepeatMode(mode);
          _queue = _queue.copyWith(
            repeatMode: mode,
            queueEpoch: _queue.queueEpoch + 1,
            timestampMs: _nowMs(),
          );
          _emitQueue(_queue);
        case SetShuffleCommand(:final enabled):
          await svc.setShuffle(enabled);
          _queue = _queue.copyWith(
            shuffle: enabled,
            queueEpoch: _queue.queueEpoch + 1,
            timestampMs: _nowMs(),
          );
          _emitQueue(_queue);
        case SetOutputDeviceCommand(:final deviceId):
          await svc.selectAudioDevice(deviceId);
        case SetActiveZoneCommand(:final zoneId):
          await svc.castToZone(zoneId, 'activate');
        case LoadQueueCommand(:final items, :final startIndex, :final autoPlay):
          final tracks = items.map((e) => e.toTrackInfo()).toList(growable: false);
          final safeIdx = tracks.isEmpty ? 0 : startIndex.clamp(0, tracks.length - 1);
          if (tracks.isNotEmpty) {
            if (autoPlay) {
              await svc.skipToTrack(tracks[safeIdx], queueContext: tracks);
            } else {
              await svc.restorePlaybackSession(
                track: tracks[safeIdx],
                position: Duration.zero,
                queue: tracks,
                queueIndex: safeIdx,
              );
            }
          }
          _queue = _queue.copyWith(
            items: <QueueItem>[
              for (var i = 0; i < items.length; i++)
                QueueItem(
                  itemId: 'ffi-$i-${items[i].trackId}',
                  track: items[i],
                  isUserQueued: true,
                ),
            ],
            currentIndex: items.isEmpty ? null : safeIdx,
            clearCurrentIndex: items.isEmpty,
            queueEpoch: _queue.queueEpoch + 1,
            timestampMs: _nowMs(),
          );
          _emitQueue(_queue);
        case EnqueueCommand(:final items, :final playNext):
          final updated = List<QueueItem>.of(_queue.items);
          final added = <QueueItem>[
            for (var i = 0; i < items.length; i++)
              QueueItem(
                itemId: 'ffi-enq-${_nowMs()}-$i-${items[i].trackId}',
                track: items[i],
                isUserQueued: true,
              ),
          ];
          if (playNext && _queue.currentIndex != null) {
            final idx = (_queue.currentIndex! + 1).clamp(0, updated.length);
            updated.insertAll(idx, added);
          } else {
            updated.addAll(added);
          }
          _queue = _queue.copyWith(
            items: updated,
            queueEpoch: _queue.queueEpoch + 1,
            timestampMs: _nowMs(),
          );
          _emitQueue(_queue);
        case RemoveQueueItemCommand(:final index):
          if (index >= 0 && index < _queue.items.length) {
            final updated = List<QueueItem>.of(_queue.items)..removeAt(index);
            _queue = _queue.copyWith(
              items: updated,
              queueEpoch: _queue.queueEpoch + 1,
              timestampMs: _nowMs(),
            );
            _emitQueue(_queue);
          }
        case ReorderQueueCommand(:final fromIndex, :final toIndex):
          if (fromIndex >= 0 &&
              fromIndex < _queue.items.length &&
              toIndex >= 0 &&
              toIndex < _queue.items.length) {
            final updated = List<QueueItem>.of(_queue.items);
            final moved = updated.removeAt(fromIndex);
            updated.insert(toIndex, moved);
            _queue = _queue.copyWith(
              items: updated,
              queueEpoch: _queue.queueEpoch + 1,
              timestampMs: _nowMs(),
            );
            _emitQueue(_queue);
          }
        case ClearQueueCommand():
          _queue = _queue.copyWith(
            items: const <QueueItem>[],
            clearCurrentIndex: true,
            queueEpoch: _queue.queueEpoch + 1,
            timestampMs: _nowMs(),
          );
          _emitQueue(_queue);
        case ClearUpcomingQueueCommand():
          await svc.clearUpcomingQueue();
          _syncQueueFromAudioService();
          _emitQueue(_queue);
        case ReconnectDeviceCommand():
          await svc.reconnectDevice();
      }
      return const Ok<void, LuminaError>(null);
    } catch (e) {
      final err = LuminaError(
        code: LuminaErrorCode.internal,
        message: 'Local playback command failed (${command.commandName}): $e',
      );
      _emitError(err);
      return Err<void, LuminaError>(err);
    }
  }

  void _refreshNativeQueueIfAvailable() {
    final getter = _nativeBridge?.getQueueStateJson;
    if (getter == null || !(_nativeBridge?.isNativeBound() ?? false)) return;
    final raw = getter();
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final map = JsonReader.decodeObject(raw);
      if (map != null) {
        _queue = QueueState.fromJson(map);
        _emitQueue(_queue);
      }
    } catch (_) {}
  }

  @override
  Future<Result<void, LuminaError>> play(
    ProtocolTrackMetadata track, {
    int? startPositionMs,
    int? playbackEpoch,
  }) =>
      execute(
        PlayCommand(
          track: track,
          startPositionMs: startPositionMs,
          playbackEpoch: playbackEpoch,
        ),
      );

  @override
  Future<Result<void, LuminaError>> pause() => execute(const PauseCommand());

  @override
  Future<Result<void, LuminaError>> resume() => execute(const ResumeCommand());

  @override
  Future<Result<void, LuminaError>> stop() => execute(const StopCommand());

  @override
  Future<Result<void, LuminaError>> seek(Duration position) => execute(
        SeekCommand(
          positionMs: position.inMilliseconds < 0 ? 0 : position.inMilliseconds,
        ),
      );

  @override
  Future<Result<void, LuminaError>> next() => execute(const NextCommand());

  @override
  Future<Result<void, LuminaError>> previous() =>
      execute(const PreviousCommand());

  @override
  Future<Result<void, LuminaError>> setVolume(double volume) =>
      execute(SetVolumeCommand(volume: volume.clamp(0.0, 1.0)));

  @override
  Future<Result<void, LuminaError>> setMute(bool muted) =>
      execute(SetMuteCommand(muted: muted));

  @override
  Future<Result<void, LuminaError>> setRepeatMode(RepeatMode mode) =>
      execute(SetRepeatModeCommand(mode: mode));

  @override
  Future<Result<void, LuminaError>> setShuffle(bool enabled) =>
      execute(SetShuffleCommand(enabled: enabled));

  @override
  Future<Result<void, LuminaError>> setOutputDevice(
    String deviceId, {
    String? backend,
  }) =>
      execute(SetOutputDeviceCommand(deviceId: deviceId, backend: backend));

  @override
  Future<Result<void, LuminaError>> setActiveZone(String zoneId) =>
      execute(SetActiveZoneCommand(zoneId: zoneId));

  @override
  Future<Result<void, LuminaError>> loadQueue(
    List<ProtocolTrackMetadata> items, {
    int startIndex = 0,
    bool autoPlay = true,
  }) =>
      execute(
        LoadQueueCommand(
          items: items,
          startIndex: startIndex,
          autoPlay: autoPlay,
        ),
      );

  @override
  Future<Result<void, LuminaError>> enqueue(
    List<ProtocolTrackMetadata> items, {
    bool playNext = false,
  }) =>
      execute(EnqueueCommand(items: items, playNext: playNext));

  @override
  Future<Result<void, LuminaError>> removeQueueItem(int index) =>
      execute(RemoveQueueItemCommand(index: index));

  @override
  Future<Result<void, LuminaError>> reorderQueue(int fromIndex, int toIndex) =>
      execute(ReorderQueueCommand(fromIndex: fromIndex, toIndex: toIndex));

  @override
  Future<Result<void, LuminaError>> clearQueue() =>
      execute(const ClearQueueCommand());

  @override
  Future<Result<void, LuminaError>> clearUpcomingQueue() =>
      execute(const ClearUpcomingQueueCommand());

  @override
  Future<Result<void, LuminaError>> reconnectDevice() =>
      execute(const ReconnectDeviceCommand());
}
