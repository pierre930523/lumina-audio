import 'dart:async';
import 'dart:math' as math;

import '../../models/protocol/lumina_error.dart';
import '../../models/protocol/protocol_models.dart';
import '../../models/protocol/result.dart';
import '../../models/signal_path.dart';
import '../../models/studio_models.dart';
import 'playback_backend.dart';

part 'mock_playback_backend_execute.dart';
part 'mock_playback_backend_commands.dart';

abstract class _MockPlaybackBackendBase implements PlaybackBackend {
  final int Function() _nowMs;
  final math.Random _random;
  final List<PlaybackCommand> commandHistory = <PlaybackCommand>[];

  Duration commandLatency;
  LuminaError? nextError;
  LuminaError? persistentError;

  final StreamController<ProtocolPlaybackState> _stateController =
      StreamController<ProtocolPlaybackState>.broadcast();
  final StreamController<QueueState> _queueController =
      StreamController<QueueState>.broadcast();
  final StreamController<ConnectionStatus> _connectionController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<LuminaError> _errorController =
      StreamController<LuminaError>.broadcast();
  final StreamController<ProtocolSignalPath> _signalPathController =
      StreamController<ProtocolSignalPath>.broadcast();
  final StreamController<List<ProtocolAudioDeviceInfo>> _devicesController =
      StreamController<List<ProtocolAudioDeviceInfo>>.broadcast();
  final StreamController<List<ProtocolZoneInfo>> _zonesController =
      StreamController<List<ProtocolZoneInfo>>.broadcast();

  late ProtocolPlaybackState _state;
  late QueueState _queue;
  late ConnectionStatus _connectionStatus;
  late ProtocolSignalPath _signalPath;
  late List<ProtocolAudioDeviceInfo> _devices;
  late List<ProtocolZoneInfo> _zones;

  int _sequence = 0;
  int _itemIdCounter = 0;
  bool _disposed = false;

  _MockPlaybackBackendBase({
    int Function()? nowMs,
    math.Random? random,
    this.commandLatency = Duration.zero,
  })  : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? math.Random(42);

  void _emitState(ProtocolPlaybackState state) {
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  void _emitQueue(QueueState queue) {
    if (!_disposed && !_queueController.isClosed) {
      _queueController.add(queue);
    }
  }

  void _setConnection(ConnectionStatus status) {
    _connectionStatus = status;
    if (!_disposed && !_connectionController.isClosed) {
      _connectionController.add(status);
    }
  }

  void _emitError(LuminaError error) {
    if (!_disposed && !_errorController.isClosed) {
      _errorController.add(error);
    }
  }

  void _emitSignalPath(ProtocolSignalPath path) {
    if (!_disposed && !_signalPathController.isClosed) {
      _signalPathController.add(path);
    }
  }

  void _emitDevices(List<ProtocolAudioDeviceInfo> devices) {
    if (!_disposed && !_devicesController.isClosed) {
      _devicesController.add(devices);
    }
  }

  void _emitZones(List<ProtocolZoneInfo> zones) {
    if (!_disposed && !_zonesController.isClosed) {
      _zonesController.add(zones);
    }
  }
}

/// Deterministic in-memory [PlaybackBackend] supporting full queue navigation,
/// repeat/shuffle, seek/volume/mute, device/zone switching, injectable latency &
/// errors, and simulated disconnect/reconnect with atomic snapshot reset.
class MockPlaybackBackend extends _MockPlaybackBackendBase
    with _MockPlaybackExecuteMixin, _MockPlaybackCommandsMixin {
  MockPlaybackBackend({
    super.nowMs,
    super.random,
    super.commandLatency,
    ConnectionMode mode = ConnectionMode.localOrUsbDac,
    List<ProtocolAudioDeviceInfo>? initialDevices,
    List<ProtocolZoneInfo>? initialZones,
  }) {
    _devices = List<ProtocolAudioDeviceInfo>.unmodifiable(
      initialDevices ??
          const <ProtocolAudioDeviceInfo>[
            ProtocolAudioDeviceInfo(
              id: 'mock-wasapi-excl',
              name: 'Mock Reference DAC (WASAPI Exclusive)',
              backend: 'windows_wasapi_exclusive',
              isDefault: true,
              isActive: true,
              supportsExclusive: true,
              supportsDsd: true,
              supportsDop: true,
              supportedSampleRates: <int>[44100, 48000, 96000, 192000, 384000],
              maxChannels: 2,
              bufferSizeSupported: true,
              minBufferFrames: 128,
              maxBufferFrames: 4096,
              defaultBufferFrames: 512,
              bufferGranularity: 64,
            ),
          ],
    );
    _zones = List<ProtocolZoneInfo>.unmodifiable(
      initialZones ??
          const <ProtocolZoneInfo>[
            ProtocolZoneInfo(
              id: 'zone-local',
              name: 'Local Reference Zone',
              backend: 'windows_wasapi_exclusive',
              deviceId: 'mock-wasapi-excl',
              exclusiveMode: true,
              dspBypass: true,
              volume: 0.85,
              isActive: true,
              activeDeviceId: 'mock-wasapi-excl',
              playbackStatus: PlaybackLifecycleState.stopped,
            ),
          ],
    );
    _signalPath = const ProtocolSignalPath(
      overall: SignalQuality.lossless,
      nodes: <ProtocolSignalPathNode>[
        ProtocolSignalPathNode(
          stage: 'Source',
          detail: 'FLAC 96 kHz / 24-bit',
          quality: SignalQuality.lossless,
        ),
        ProtocolSignalPathNode(
          stage: 'Output',
          detail: 'Mock Reference DAC (WASAPI Exclusive)',
          quality: SignalQuality.lossless,
        ),
      ],
    );
    _queue = QueueState.empty;
    _connectionStatus = ConnectionStatus(
      phase: ConnectionPhase.connected,
      mode: mode,
    );
    _state = const ProtocolPlaybackState(
      status: PlaybackLifecycleState.stopped,
      volume: 0.85,
      isMuted: false,
      activeZoneId: 'zone-local',
    );
    if (_devices.isNotEmpty) {
      final activeDev = _devices.firstWhere(
        (d) => d.isActive,
        orElse: () => _devices.first,
      );
      _state = _state.copyWith(activeDevice: activeDev);
    }
  }

  @override
  Stream<ProtocolPlaybackState> get stateStream => _stateController.stream;

  @override
  Stream<QueueState> get queueStream => _queueController.stream;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionController.stream;

  @override
  Stream<LuminaError> get errorStream => _errorController.stream;

  @override
  Stream<ProtocolSignalPath> get signalPathStream =>
      _signalPathController.stream;

  @override
  Stream<List<ProtocolAudioDeviceInfo>> get devicesStream =>
      _devicesController.stream;

  @override
  Stream<List<ProtocolZoneInfo>> get zonesStream => _zonesController.stream;

  @override
  ProtocolPlaybackState get currentState => _state;

  @override
  QueueState get currentQueue => _queue;

  @override
  ConnectionStatus get currentConnectionStatus => _connectionStatus;

  @override
  ProtocolSignalPath? get currentSignalPath => _signalPath;

  @override
  List<ProtocolAudioDeviceInfo> get currentDevices => _devices;

  @override
  List<ProtocolZoneInfo> get currentZones => _zones;

  @override
  Future<Result<void, LuminaError>> connect() async {
    if (_disposed) {
      return const Err<void, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.invalidState,
          message: 'Backend has been disposed',
        ),
      );
    }
    _setConnection(
      _connectionStatus.copyWith(
        phase: ConnectionPhase.connected,
        reconnectAttempt: 0,
        lastConnectedAtMs: _nowMs(),
        clearNextRetryDelay: true,
        clearLastError: true,
      ),
    );
    return const Ok<void, LuminaError>(null);
  }

  /// Simulates a connection drop for contract & reconnect tests.
  void simulateDisconnect({LuminaError? error}) {
    final err = error ??
        const LuminaError(
          code: LuminaErrorCode.networkDisconnected,
          message: 'Simulated disconnect',
          retryable: true,
        );
    _setConnection(
      _connectionStatus.copyWith(
        phase: ConnectionPhase.reconnecting,
        reconnectAttempt: _connectionStatus.reconnectAttempt + 1,
        lastError: err,
      ),
    );
    _emitError(err);
  }

  /// Simulates reconnection and emits an atomic snapshot reset.
  Future<Result<ProtocolSnapshot, LuminaError>> simulateReconnect({
    ProtocolSnapshot? overrideSnapshot,
  }) async {
    _setConnection(
      _connectionStatus.copyWith(
        phase: ConnectionPhase.connected,
        reconnectAttempt: 0,
        lastConnectedAtMs: _nowMs(),
        clearNextRetryDelay: true,
        clearLastError: true,
      ),
    );
    if (overrideSnapshot != null) {
      applySnapshot(overrideSnapshot);
      return Ok<ProtocolSnapshot, LuminaError>(overrideSnapshot);
    }
    return fetchSnapshot();
  }

  /// Replaces internal state atomically from a snapshot (useful in tests).
  void applySnapshot(ProtocolSnapshot snapshot) {
    _state = snapshot.playback;
    _queue = snapshot.queue;
    if (snapshot.signalPath != null) {
      _signalPath = snapshot.signalPath!;
    }
    _devices = List<ProtocolAudioDeviceInfo>.unmodifiable(snapshot.devices);
    _zones = List<ProtocolZoneInfo>.unmodifiable(snapshot.zones);
    _sequence = snapshot.sequence;
    _emitState(_state);
    _emitQueue(_queue);
    _emitSignalPath(_signalPath);
    _emitDevices(_devices);
    _emitZones(_zones);
  }

  /// Pushes an arbitrary backend state event directly (for interpolation/sync tests).
  void pushState(ProtocolPlaybackState state) {
    _state = state;
    _emitState(_state);
  }

  @override
  Future<Result<ProtocolSnapshot, LuminaError>> fetchSnapshot() async {
    if (commandLatency > Duration.zero) {
      await Future<void>.delayed(commandLatency);
    }
    final injected = _takeInjectedError();
    if (injected != null) {
      _emitError(injected);
      return Err<ProtocolSnapshot, LuminaError>(injected);
    }
    final snapshot = ProtocolSnapshot(
      playback: _state,
      queue: _queue,
      signalPath: _signalPath,
      devices: _devices,
      zones: _zones,
      serverTimeMs: _nowMs(),
      sequence: ++_sequence,
    );
    return Ok<ProtocolSnapshot, LuminaError>(snapshot);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stateController.close();
    await _queueController.close();
    await _connectionController.close();
    await _errorController.close();
    await _signalPathController.close();
    await _devicesController.close();
    await _zonesController.close();
  }
}
