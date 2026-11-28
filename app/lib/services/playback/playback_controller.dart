import 'dart:async';

import '../../models/protocol/lumina_error.dart';
import '../../models/protocol/protocol_models.dart';
import '../../models/protocol/result.dart';
import 'playback_backend.dart';

part 'playback_controller_commands.dart';

abstract class _PlaybackControllerBase {
  final PlaybackBackend backend;
  final int Function() _nowMs;
  final Duration interpolationInterval;
  final Duration seekDebounce;
  final Duration volumeDebounce;
  final Duration trackSwitchDebounce;
  final bool enableAutoTicker;

  final StreamController<ProtocolPlaybackState> _stateController =
      StreamController<ProtocolPlaybackState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
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

  StreamSubscription<ProtocolPlaybackState>? _stateSub;
  StreamSubscription<QueueState>? _queueSub;
  StreamSubscription<ConnectionStatus>? _connectionSub;
  StreamSubscription<LuminaError>? _errorSub;
  StreamSubscription<ProtocolSignalPath>? _signalPathSub;
  StreamSubscription<List<ProtocolAudioDeviceInfo>>? _devicesSub;
  StreamSubscription<List<ProtocolZoneInfo>>? _zonesSub;

  late ProtocolPlaybackState _state;
  late QueueState _queue;
  late ConnectionStatus _connectionStatus;

  // Interpolation anchor
  int _anchorPositionMs = 0;
  int _anchorLocalTimeMs = 0;
  int _anchorDurationMs = 0;
  int _lastInterpolatedMs = 0;
  Timer? _interpolationTimer;

  // Coalescing slots + serialized FIFO execution chain
  final _CoalescedSlot _seekSlot = _CoalescedSlot();
  final _CoalescedSlot _volumeSlot = _CoalescedSlot();
  final _CoalescedSlot _trackSwitchSlot = _CoalescedSlot();
  Future<void> _serialChain = Future<void>.value();

  bool _disposed = false;

  _PlaybackControllerBase({
    required this.backend,
    int Function()? nowMs,
    this.interpolationInterval = const Duration(milliseconds: 50),
    this.seekDebounce = const Duration(milliseconds: 80),
    this.volumeDebounce = const Duration(milliseconds: 80),
    this.trackSwitchDebounce = const Duration(milliseconds: 130),
    this.enableAutoTicker = true,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  Future<Result<void, LuminaError>> dispatch(PlaybackCommand command);
}

/// Unified cross-mode playback state machine wrapping any [PlaybackBackend]
/// (FFI / Remote Server / Mock).
///
/// Guarantees:
/// 1. **Local Progress Interpolation**: Anchors on `(positionMs, timestampMs,
///    durationMs, status)` from backend events and interpolates smoothly via a
///    local clock/ticker while `playing && !isSeeking`, clamped to `[0, durationMs]`,
///    re-anchoring immediately on Seek, Pause, Stop, Track change, or Snapshot.
/// 2. **Debounce & Serialized Command Queue**: Serializes all backend command
///    dispatches in strict FIFO order while coalescing rapid `Seek`, `SetVolume`,
///    and rapid track-switch (`Play`/`Next`/`Previous`) bursts (latest-wins,
///    guaranteed final value flush with zero races).
/// 3. **Reconnect & Snapshot Alignment**: Forwards [ConnectionStatus], resets
///    interpolation anchor atomically on Snapshot/state updates, and exposes
///    unified reactive streams (`stateStream`, `positionStream`, `queueStream`,
///    `connectionStatusStream`, `errorStream`).
class PlaybackController extends _PlaybackControllerBase
    with _PlaybackControllerCommandsMixin {
  PlaybackController({
    required super.backend,
    super.nowMs,
    super.interpolationInterval,
    super.seekDebounce,
    super.volumeDebounce,
    super.trackSwitchDebounce,
    super.enableAutoTicker,
  }) {
    _state = backend.currentState;
    _queue = backend.currentQueue;
    _connectionStatus = backend.currentConnectionStatus;
    _reanchorFromState(_state, emitPosition: false);
    _stateSub = backend.stateStream.listen(_onBackendState);
    _queueSub = backend.queueStream.listen((q) {
      if (_disposed) return;
      _queue = q;
      if (!_queueController.isClosed) {
        _queueController.add(q);
      }
    });
    _connectionSub = backend.connectionStatusStream.listen((c) {
      if (_disposed) return;
      _connectionStatus = c;
      if (!_connectionController.isClosed) {
        _connectionController.add(c);
      }
    });
    _errorSub = backend.errorStream.listen((e) {
      if (_disposed) return;
      if (!_errorController.isClosed) {
        _errorController.add(e);
      }
    });
    _signalPathSub = backend.signalPathStream.listen((sp) {
      if (_disposed) return;
      if (!_signalPathController.isClosed) {
        _signalPathController.add(sp);
      }
    });
    _devicesSub = backend.devicesStream.listen((d) {
      if (_disposed) return;
      if (!_devicesController.isClosed) {
        _devicesController.add(d);
      }
    });
    _zonesSub = backend.zonesStream.listen((z) {
      if (_disposed) return;
      if (!_zonesController.isClosed) {
        _zonesController.add(z);
      }
    });
    _syncInterpolationTicker();
  }

  Stream<ProtocolPlaybackState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<QueueState> get queueStream => _queueController.stream;
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionController.stream;
  Stream<LuminaError> get errorStream => _errorController.stream;
  Stream<ProtocolSignalPath> get signalPathStream =>
      _signalPathController.stream;
  Stream<List<ProtocolAudioDeviceInfo>> get devicesStream =>
      _devicesController.stream;
  Stream<List<ProtocolZoneInfo>> get zonesStream => _zonesController.stream;

  ProtocolPlaybackState get currentState => _state;
  QueueState get currentQueue => _queue;
  ConnectionStatus get currentConnectionStatus => _connectionStatus;

  /// Computes the current interpolated playback position using the local clock.
  Duration get currentPosition =>
      Duration(milliseconds: computeInterpolatedPositionMs());

  int computeInterpolatedPositionMs() {
    if (_state.status != PlaybackLifecycleState.playing || _state.isSeeking) {
      return _clampPosition(_anchorPositionMs, _anchorDurationMs);
    }
    final elapsed = _nowMs() - _anchorLocalTimeMs;
    final safeElapsed = elapsed > 0 ? elapsed : 0;
    return _clampPosition(_anchorPositionMs + safeElapsed, _anchorDurationMs);
  }

  int _clampPosition(int posMs, int durationMs) {
    if (posMs < 0) return 0;
    if (durationMs > 0 && posMs > durationMs) return durationMs;
    return posMs;
  }

  /// Manually advances interpolation once (deterministic hook for unit tests
  /// with custom clocks or `enableAutoTicker: false`).
  Duration tickInterpolation() {
    final posMs = computeInterpolatedPositionMs();
    _lastInterpolatedMs = posMs;
    final dur = Duration(milliseconds: posMs);
    if (!_disposed && !_positionController.isClosed) {
      _positionController.add(dur);
    }
    return dur;
  }

  Future<Result<void, LuminaError>> connect() async {
    final res = await backend.connect();
    if (res.isOk) {
      _state = backend.currentState;
      _queue = backend.currentQueue;
      _reanchorFromState(_state, emitPosition: true);
    }
    return res;
  }

  /// Fetches an atomic snapshot from the backend and resets local state +
  /// interpolation anchor cleanly.
  Future<Result<ProtocolSnapshot, LuminaError>> syncSnapshot() async {
    final res = await backend.fetchSnapshot();
    if (res case Ok<ProtocolSnapshot, LuminaError>(value: final snap)) {
      applySnapshot(snap);
    }
    return res;
  }

  void applySnapshot(ProtocolSnapshot snapshot) {
    if (_disposed) return;
    _state = snapshot.playback;
    _queue = snapshot.queue;
    _reanchorFromState(_state, emitPosition: true);
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
    if (!_queueController.isClosed) {
      _queueController.add(_queue);
    }
    if (snapshot.signalPath != null && !_signalPathController.isClosed) {
      _signalPathController.add(snapshot.signalPath!);
    }
    if (!_devicesController.isClosed) {
      _devicesController.add(snapshot.devices);
    }
    if (!_zonesController.isClosed) {
      _zonesController.add(snapshot.zones);
    }
  }

  /// Dispatches any [PlaybackCommand] through the serialized + debounced pipeline.
  @override
  Future<Result<void, LuminaError>> dispatch(PlaybackCommand command) {
    if (_disposed) {
      return Future<Result<void, LuminaError>>.value(
        const Err<void, LuminaError>(
          LuminaError(
            code: LuminaErrorCode.invalidState,
            message: 'PlaybackController has been disposed',
          ),
        ),
      );
    }

    switch (command) {
      case SeekCommand(:final positionMs):
        // Immediately re-anchor optimistic position so scrubbing never snaps back.
        _anchorPositionMs = _clampPosition(positionMs, _anchorDurationMs);
        _anchorLocalTimeMs = _nowMs();
        _lastInterpolatedMs = _anchorPositionMs;
        if (!_positionController.isClosed) {
          _positionController.add(Duration(milliseconds: _anchorPositionMs));
        }
        return _enqueueCoalesced(_seekSlot, command, seekDebounce);

      case SetVolumeCommand():
        return _enqueueCoalesced(_volumeSlot, command, volumeDebounce);

      case PlayCommand() || NextCommand() || PreviousCommand():
        return _enqueueCoalesced(
          _trackSwitchSlot,
          command,
          trackSwitchDebounce,
        );

      default:
        // Flush any pending coalesced commands before executing barrier commands
        // (e.g. Pause/Stop/LoadQueue) so FIFO order is strictly preserved.
        _flushSlotNow(_trackSwitchSlot);
        _flushSlotNow(_seekSlot);
        _flushSlotNow(_volumeSlot);
        return _enqueueSerialized(command);
    }
  }

  /// Immediately flushes all pending debounced commands and waits for the
  /// serialized FIFO queue to drain.
  Future<void> flush() async {
    _flushSlotNow(_trackSwitchSlot);
    _flushSlotNow(_seekSlot);
    _flushSlotNow(_volumeSlot);
    await _serialChain;
  }

  Future<Result<void, LuminaError>> _enqueueCoalesced(
    _CoalescedSlot slot,
    PlaybackCommand command,
    Duration delay,
  ) {
    final completer = Completer<Result<void, LuminaError>>();
    slot.pendingCommand = command;
    slot.waiters.add(completer);

    if (delay <= Duration.zero) {
      _flushSlotNow(slot);
      return completer.future;
    }

    slot.timer?.cancel();
    slot.timer = Timer(delay, () => _flushSlotNow(slot));
    return completer.future;
  }

  void _flushSlotNow(_CoalescedSlot slot) {
    slot.timer?.cancel();
    slot.timer = null;
    final command = slot.pendingCommand;
    if (command == null) return;
    slot.pendingCommand = null;

    final waiters = List<Completer<Result<void, LuminaError>>>.of(slot.waiters);
    slot.waiters.clear();

    _enqueueSerialized(command).then((result) {
      for (final w in waiters) {
        if (!w.isCompleted) {
          w.complete(result);
        }
      }
    });
  }

  Future<Result<void, LuminaError>> _enqueueSerialized(PlaybackCommand command) {
    final completer = Completer<Result<void, LuminaError>>();
    _serialChain = _serialChain.then((_) async {
      if (_disposed) {
        if (!completer.isCompleted) {
          completer.complete(
            const Err<void, LuminaError>(
              LuminaError(
                code: LuminaErrorCode.invalidState,
                message: 'PlaybackController has been disposed',
              ),
            ),
          );
        }
        return;
      }
      final result = await backend.execute(command);
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    });
    return completer.future;
  }

  void _onBackendState(ProtocolPlaybackState incoming) {
    if (_disposed) return;
    _state = incoming;
    _reanchorFromState(incoming, emitPosition: true);
    if (!_stateController.isClosed) {
      _stateController.add(incoming);
    }
  }

  void _reanchorFromState(
    ProtocolPlaybackState state, {
    required bool emitPosition,
  }) {
    final now = _nowMs();
    final durMs = state.durationMs > 0
        ? state.durationMs
        : (state.track?.durationMs ?? 0);
    // If backend included a recent epoch timestamp while playing, account for
    // bounded transit latency (clamped to [0, 5000ms] to guard against clock skew).
    var compensatedPosMs = state.positionMs < 0 ? 0 : state.positionMs;
    if (state.status == PlaybackLifecycleState.playing &&
        !state.isSeeking &&
        state.timestampMs > 0) {
      final transitMs = now - state.timestampMs;
      if (transitMs > 0 && transitMs <= 5000) {
        compensatedPosMs += transitMs;
      }
    }
    _anchorDurationMs = durMs;
    _anchorPositionMs = _clampPosition(compensatedPosMs, durMs);
    _anchorLocalTimeMs = now;
    _lastInterpolatedMs = _anchorPositionMs;

    _syncInterpolationTicker();

    if (emitPosition && !_disposed && !_positionController.isClosed) {
      _positionController.add(Duration(milliseconds: _anchorPositionMs));
    }
  }

  void _syncInterpolationTicker() {
    final shouldTick = enableAutoTicker &&
        !_disposed &&
        _state.status == PlaybackLifecycleState.playing &&
        !_state.isSeeking;
    if (!shouldTick) {
      _interpolationTimer?.cancel();
      _interpolationTimer = null;
      return;
    }
    if (_interpolationTimer != null) return;
    _interpolationTimer = Timer.periodic(interpolationInterval, (_) {
      if (_disposed ||
          _state.status != PlaybackLifecycleState.playing ||
          _state.isSeeking) {
        _interpolationTimer?.cancel();
        _interpolationTimer = null;
        return;
      }
      final nextMs = computeInterpolatedPositionMs();
      if (nextMs != _lastInterpolatedMs) {
        _lastInterpolatedMs = nextMs;
        if (!_positionController.isClosed) {
          _positionController.add(Duration(milliseconds: nextMs));
        }
      }
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _interpolationTimer?.cancel();
    _interpolationTimer = null;

    const disposedErr = Err<void, LuminaError>(
      LuminaError(
        code: LuminaErrorCode.invalidState,
        message: 'PlaybackController disposed before command flushed',
      ),
    );
    _seekSlot.timer?.cancel();
    _seekSlot.pendingCommand = null;
    _seekSlot.completeAll(disposedErr);
    _volumeSlot.timer?.cancel();
    _volumeSlot.pendingCommand = null;
    _volumeSlot.completeAll(disposedErr);
    _trackSwitchSlot.timer?.cancel();
    _trackSwitchSlot.pendingCommand = null;
    _trackSwitchSlot.completeAll(disposedErr);

    await _stateSub?.cancel();
    await _queueSub?.cancel();
    await _connectionSub?.cancel();
    await _errorSub?.cancel();
    await _signalPathSub?.cancel();
    await _devicesSub?.cancel();
    await _zonesSub?.cancel();

    await _stateController.close();
    await _positionController.close();
    await _queueController.close();
    await _connectionController.close();
    await _errorController.close();
    await _signalPathController.close();
    await _devicesController.close();
    await _zonesController.close();
  }
}
