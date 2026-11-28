part of 'playback_controller.dart';

class _CoalescedSlot {
  Timer? timer;
  PlaybackCommand? pendingCommand;
  final List<Completer<Result<void, LuminaError>>> waiters =
      <Completer<Result<void, LuminaError>>>[];

  void completeAll(Result<void, LuminaError> result) {
    final pending = List<Completer<Result<void, LuminaError>>>.of(waiters);
    waiters.clear();
    for (final c in pending) {
      if (!c.isCompleted) {
        c.complete(result);
      }
    }
  }
}

mixin _PlaybackControllerCommandsMixin on _PlaybackControllerBase {
  // Convenience typed command wrappers
  Future<Result<void, LuminaError>> play(
    ProtocolTrackMetadata track, {
    int? startPositionMs,
    int? playbackEpoch,
  }) =>
      dispatch(
        PlayCommand(
          track: track,
          startPositionMs: startPositionMs,
          playbackEpoch: playbackEpoch,
        ),
      );

  Future<Result<void, LuminaError>> pause() => dispatch(const PauseCommand());
  Future<Result<void, LuminaError>> resume() => dispatch(const ResumeCommand());
  Future<Result<void, LuminaError>> stop() => dispatch(const StopCommand());
  Future<Result<void, LuminaError>> seek(Duration position) => dispatch(
        SeekCommand(
          positionMs: position.inMilliseconds < 0 ? 0 : position.inMilliseconds,
        ),
      );
  Future<Result<void, LuminaError>> next() => dispatch(const NextCommand());
  Future<Result<void, LuminaError>> previous() =>
      dispatch(const PreviousCommand());
  Future<Result<void, LuminaError>> setVolume(double volume) =>
      dispatch(SetVolumeCommand(volume: volume.clamp(0.0, 1.0)));
  Future<Result<void, LuminaError>> setMute(bool muted) =>
      dispatch(SetMuteCommand(muted: muted));
  Future<Result<void, LuminaError>> setRepeatMode(RepeatMode mode) =>
      dispatch(SetRepeatModeCommand(mode: mode));
  Future<Result<void, LuminaError>> setShuffle(bool enabled) =>
      dispatch(SetShuffleCommand(enabled: enabled));
  Future<Result<void, LuminaError>> setOutputDevice(
    String deviceId, {
    String? backend,
  }) =>
      dispatch(SetOutputDeviceCommand(deviceId: deviceId, backend: backend));
  Future<Result<void, LuminaError>> setActiveZone(String zoneId) =>
      dispatch(SetActiveZoneCommand(zoneId: zoneId));
  Future<Result<void, LuminaError>> loadQueue(
    List<ProtocolTrackMetadata> items, {
    int startIndex = 0,
    bool autoPlay = true,
  }) =>
      dispatch(
        LoadQueueCommand(
          items: items,
          startIndex: startIndex,
          autoPlay: autoPlay,
        ),
      );
  Future<Result<void, LuminaError>> enqueue(
    List<ProtocolTrackMetadata> items, {
    bool playNext = false,
  }) =>
      dispatch(EnqueueCommand(items: items, playNext: playNext));
  Future<Result<void, LuminaError>> removeQueueItem(int index) =>
      dispatch(RemoveQueueItemCommand(index: index));
  Future<Result<void, LuminaError>> reorderQueue(int fromIndex, int toIndex) =>
      dispatch(ReorderQueueCommand(fromIndex: fromIndex, toIndex: toIndex));
  Future<Result<void, LuminaError>> clearQueue() =>
      dispatch(const ClearQueueCommand());
  Future<Result<void, LuminaError>> clearUpcomingQueue() =>
      dispatch(const ClearUpcomingQueueCommand());
  Future<Result<void, LuminaError>> reconnectDevice() =>
      dispatch(const ReconnectDeviceCommand());
}
