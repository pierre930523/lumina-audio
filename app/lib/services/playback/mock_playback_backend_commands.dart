part of 'mock_playback_backend.dart';

mixin _MockPlaybackCommandsMixin on _MockPlaybackBackendBase {
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
