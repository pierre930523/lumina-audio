import '../../models/protocol/lumina_error.dart';
import '../../models/protocol/protocol_models.dart';
import '../../models/protocol/result.dart';

/// Unified cross-mode playback backend contract implemented identically by:
/// - `FfiPlaybackBackend` (Local native Rust engine via `core_ffi.dll`)
/// - `RemotePlaybackBackend` (LAN/WAN `core-server` via REST + WebSocket)
/// - `MockPlaybackBackend` (Deterministic in-memory backend for tests & headless UI)
///
/// Strictly typed: zero `dynamic` or untyped `Map<String, dynamic>` in public API.
abstract interface class PlaybackBackend {
  Stream<ProtocolPlaybackState> get stateStream;
  Stream<QueueState> get queueStream;
  Stream<ConnectionStatus> get connectionStatusStream;
  Stream<LuminaError> get errorStream;
  Stream<ProtocolSignalPath> get signalPathStream;
  Stream<List<ProtocolAudioDeviceInfo>> get devicesStream;
  Stream<List<ProtocolZoneInfo>> get zonesStream;

  ProtocolPlaybackState get currentState;
  QueueState get currentQueue;
  ConnectionStatus get currentConnectionStatus;
  ProtocolSignalPath? get currentSignalPath;
  List<ProtocolAudioDeviceInfo> get currentDevices;
  List<ProtocolZoneInfo> get currentZones;

  Future<Result<void, LuminaError>> connect();

  Future<Result<ProtocolSnapshot, LuminaError>> fetchSnapshot();

  Future<Result<void, LuminaError>> execute(PlaybackCommand command);

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

  Future<Result<void, LuminaError>> pause() => execute(const PauseCommand());

  Future<Result<void, LuminaError>> resume() => execute(const ResumeCommand());

  Future<Result<void, LuminaError>> stop() => execute(const StopCommand());

  Future<Result<void, LuminaError>> seek(Duration position) =>
      execute(SeekCommand(positionMs: position.inMilliseconds < 0 ? 0 : position.inMilliseconds));

  Future<Result<void, LuminaError>> next() => execute(const NextCommand());

  Future<Result<void, LuminaError>> previous() =>
      execute(const PreviousCommand());

  Future<Result<void, LuminaError>> setVolume(double volume) =>
      execute(SetVolumeCommand(volume: volume.clamp(0.0, 1.0)));

  Future<Result<void, LuminaError>> setMute(bool muted) =>
      execute(SetMuteCommand(muted: muted));

  Future<Result<void, LuminaError>> setRepeatMode(RepeatMode mode) =>
      execute(SetRepeatModeCommand(mode: mode));

  Future<Result<void, LuminaError>> setShuffle(bool enabled) =>
      execute(SetShuffleCommand(enabled: enabled));

  Future<Result<void, LuminaError>> setOutputDevice(
    String deviceId, {
    String? backend,
  }) =>
      execute(SetOutputDeviceCommand(deviceId: deviceId, backend: backend));

  Future<Result<void, LuminaError>> setActiveZone(String zoneId) =>
      execute(SetActiveZoneCommand(zoneId: zoneId));

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

  Future<Result<void, LuminaError>> enqueue(
    List<ProtocolTrackMetadata> items, {
    bool playNext = false,
  }) =>
      execute(EnqueueCommand(items: items, playNext: playNext));

  Future<Result<void, LuminaError>> removeQueueItem(int index) =>
      execute(RemoveQueueItemCommand(index: index));

  Future<Result<void, LuminaError>> reorderQueue(int fromIndex, int toIndex) =>
      execute(ReorderQueueCommand(fromIndex: fromIndex, toIndex: toIndex));

  Future<Result<void, LuminaError>> clearQueue() =>
      execute(const ClearQueueCommand());

  Future<Result<void, LuminaError>> clearUpcomingQueue() =>
      execute(const ClearUpcomingQueueCommand());

  Future<Result<void, LuminaError>> reconnectDevice() =>
      execute(const ReconnectDeviceCommand());

  Future<void> dispose();
}
