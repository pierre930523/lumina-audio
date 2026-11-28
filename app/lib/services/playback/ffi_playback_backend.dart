import 'dart:async';
import 'dart:convert';

import '../../models/playback_state.dart';
import '../../models/protocol/json_reader.dart';
import '../../models/protocol/lumina_error.dart';
import '../../models/protocol/protocol_models.dart';
import '../../models/protocol/result.dart';
import '../../models/signal_path.dart';
import '../../models/studio_models.dart';
import '../audio_service.dart';
import 'mock_playback_backend.dart';
import 'playback_backend.dart';

part 'ffi_playback_backend_legacy.dart';

/// Optional native C-ABI protocol bridge hooks supplied by `FfiAudioService`
/// when `core_ffi.dll` exports the unified Wave 1C symbols:
/// - `lumina_playback_dispatch_command`
/// - `lumina_protocol_snapshot_json`
/// - `lumina_queue_get_state_json`
/// - `lumina_last_error_json`
class NativeProtocolBridge {
  final bool Function() isNativeBound;
  final int Function(String commandJson)? dispatchCommandJson;
  final String? Function()? getSnapshotJson;
  final String? Function()? getQueueStateJson;
  final String? Function()? getLastErrorJson;

  const NativeProtocolBridge({
    required this.isNativeBound,
    this.dispatchCommandJson,
    this.getSnapshotJson,
    this.getQueueStateJson,
    this.getLastErrorJson,
  });

  bool get supportsCanonicalDispatch =>
      isNativeBound() && dispatchCommandJson != null;

  bool get supportsCanonicalSnapshot =>
      isNativeBound() && getSnapshotJson != null;
}

abstract class _FfiPlaybackBackendBase implements PlaybackBackend {
  final AudioService? _audioService;
  final NativeProtocolBridge? _nativeBridge;
  final MockPlaybackBackend? _fallback;
  final int Function() _nowMs;

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

  StreamSubscription<PlaybackState>? _serviceStateSub;
  StreamSubscription<SignalPath>? _serviceSignalSub;
  StreamSubscription<ProtocolPlaybackState>? _fallbackStateSub;
  StreamSubscription<QueueState>? _fallbackQueueSub;
  StreamSubscription<LuminaError>? _fallbackErrorSub;

  ProtocolPlaybackState _state = ProtocolPlaybackState.initial;
  QueueState _queue = QueueState.empty;
  ConnectionStatus _connectionStatus = const ConnectionStatus.localConnected();
  ProtocolSignalPath? _signalPath;
  List<ProtocolAudioDeviceInfo> _devices = const <ProtocolAudioDeviceInfo>[];
  List<ProtocolZoneInfo> _zones = const <ProtocolZoneInfo>[];
  int _sequence = 0;
  bool _disposed = false;

  _FfiPlaybackBackendBase({
    AudioService? audioService,
    NativeProtocolBridge? nativeBridge,
    MockPlaybackBackend? fallbackBackend,
    int Function()? nowMs,
  })  : _audioService = audioService,
        _nativeBridge = nativeBridge,
        _fallback = (audioService == null && nativeBridge == null)
            ? (fallbackBackend ?? MockPlaybackBackend(nowMs: nowMs))
            : fallbackBackend,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

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

  void _emitConnection(ConnectionStatus status) {
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

/// Local FFI [PlaybackBackend] implementing the canonical cross-mode contract.
///
/// When native Wave 1C symbols (`lumina_playback_dispatch_command`,
/// `lumina_protocol_snapshot_json`, `lumina_queue_get_state_json`,
/// `lumina_last_error_json`) are present in `core_ffi.dll`, commands and
/// snapshots execute directly against the Rust core engine.
///
/// When running headless / in widget tests without `core_ffi.dll`, gracefully
/// falls back to the supplied [AudioService] or an internal [MockPlaybackBackend].
class FfiPlaybackBackend extends _FfiPlaybackBackendBase
    with _FfiPlaybackLegacyMixin {
  FfiPlaybackBackend({
    super.audioService,
    super.nativeBridge,
    super.fallbackBackend,
    super.nowMs,
  }) {
    if (_audioService != null) {
      _state = ProtocolPlaybackState.fromLegacy(
        _audioService.currentState,
        timestampMs: _nowMs(),
      );
      _signalPath = ProtocolSignalPath.fromLegacy(_audioService.currentSignalPath);
      _syncQueueFromAudioService();
      _serviceStateSub = _audioService.stateStream.listen(_onAudioServiceState);
      _serviceSignalSub = _audioService.signalPathStream.listen((sp) {
        final proto = ProtocolSignalPath.fromLegacy(sp);
        _signalPath = proto;
        _emitSignalPath(proto);
      });
    } else if (_fallback != null) {
      _state = _fallback.currentState;
      _queue = _fallback.currentQueue;
      _signalPath = _fallback.currentSignalPath;
      _devices = _fallback.currentDevices;
      _zones = _fallback.currentZones;
      _fallbackStateSub = _fallback.stateStream.listen((s) {
        _state = s;
        _emitState(s);
      });
      _fallbackQueueSub = _fallback.queueStream.listen((q) {
        _queue = q;
        _emitQueue(q);
      });
      _fallbackErrorSub = _fallback.errorStream.listen(_emitError);
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
          message: 'FfiPlaybackBackend has been disposed',
        ),
      );
    }
    _connectionStatus = ConnectionStatus(
      phase: ConnectionPhase.connected,
      mode: _audioService?.connectionMode ?? ConnectionMode.localOrUsbDac,
      endpointUrl: _audioService?.activeServerUrl,
      lastConnectedAtMs: _nowMs(),
    );
    _emitConnection(_connectionStatus);
    final snap = await fetchSnapshot();
    if (snap case Ok<ProtocolSnapshot, LuminaError>(value: final s)) {
      _applySnapshot(s);
    }
    return const Ok<void, LuminaError>(null);
  }

  @override
  Future<Result<ProtocolSnapshot, LuminaError>> fetchSnapshot() async {
    final bridge = _nativeBridge;
    if (bridge != null && bridge.supportsCanonicalSnapshot) {
      final raw = bridge.getSnapshotJson!();
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final map = JsonReader.decodeObject(raw);
          if (map != null) {
            final snap = ProtocolSnapshot.fromJson(map);
            _applySnapshot(snap);
            return Ok<ProtocolSnapshot, LuminaError>(snap);
          }
        } catch (e) {
          final err = LuminaError(
            code: LuminaErrorCode.internal,
            message: 'Failed to decode native protocol snapshot: $e',
          );
          _emitError(err);
          return Err<ProtocolSnapshot, LuminaError>(err);
        }
      }
      final nativeErr = _readLastNativeError();
      if (nativeErr != null) {
        _emitError(nativeErr);
        return Err<ProtocolSnapshot, LuminaError>(nativeErr);
      }
    }

    if (_audioService != null) {
      _syncQueueFromAudioService();
      final devices = await _audioService.listAudioDevices();
      final zones = await _audioService.listZones();
      final activeDevId = _audioService.activeDeviceId;
      _devices = List<ProtocolAudioDeviceInfo>.unmodifiable(
        devices.map(
          (d) => ProtocolAudioDeviceInfo.fromLegacy(
            d,
            isActive: activeDevId != null ? d.id == activeDevId : d.isDefault,
          ),
        ),
      );
      _zones = List<ProtocolZoneInfo>.unmodifiable(
        zones.map(ProtocolZoneInfo.fromLegacy),
      );
      _signalPath = ProtocolSignalPath.fromLegacy(_audioService.currentSignalPath);
      _state = ProtocolPlaybackState.fromLegacy(
        _audioService.currentState,
        timestampMs: _nowMs(),
        dspBypassed: _audioService.currentSignalPath.dspBypassed,
        strictBitPerfect: _audioService.isStrictBitPerfect,
      );
      final snap = ProtocolSnapshot(
        playback: _state,
        queue: _queue,
        signalPath: _signalPath,
        devices: _devices,
        zones: _zones,
        serverTimeMs: _nowMs(),
        sequence: ++_sequence,
      );
      return Ok<ProtocolSnapshot, LuminaError>(snap);
    }

    if (_fallback != null) {
      return _fallback.fetchSnapshot();
    }

    return Ok<ProtocolSnapshot, LuminaError>(
      ProtocolSnapshot(
        playback: _state,
        queue: _queue,
        signalPath: _signalPath,
        devices: _devices,
        zones: _zones,
        serverTimeMs: _nowMs(),
        sequence: ++_sequence,
      ),
    );
  }

  @override
  Future<Result<void, LuminaError>> execute(PlaybackCommand command) async {
    if (_disposed) {
      return const Err<void, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.invalidState,
          message: 'FfiPlaybackBackend has been disposed',
        ),
      );
    }

    final bridge = _nativeBridge;
    if (bridge != null && bridge.supportsCanonicalDispatch) {
      try {
        final code = bridge.dispatchCommandJson!(jsonEncode(command.toJson()));
        if (code != 0) {
          final err = _readLastNativeError() ??
              LuminaError(
                code: LuminaErrorCode.internal,
                message:
                    'Native dispatch returned error code $code for ${command.commandName}',
              );
          _emitError(err);
          return Err<void, LuminaError>(err);
        }
        if (bridge.supportsCanonicalSnapshot) {
          final rawSnap = bridge.getSnapshotJson!();
          if (rawSnap != null && rawSnap.trim().isNotEmpty) {
            final snapMap = JsonReader.decodeObject(rawSnap);
            if (snapMap != null) {
              _applySnapshot(ProtocolSnapshot.fromJson(snapMap));
              return const Ok<void, LuminaError>(null);
            }
          }
        }
        _refreshNativeQueueIfAvailable();
        return const Ok<void, LuminaError>(null);
      } catch (e) {
        final err = LuminaError(
          code: LuminaErrorCode.internal,
          message: 'FFI command dispatch failed (${command.commandName}): $e',
        );
        _emitError(err);
        return Err<void, LuminaError>(err);
      }
    }

    final svc = _audioService;
    if (svc != null) {
      return _executeViaAudioService(svc, command);
    }

    if (_fallback != null) {
      return _fallback.execute(command);
    }

    return const Err<void, LuminaError>(
      LuminaError(
        code: LuminaErrorCode.notInitialized,
        message: 'No native FFI engine or fallback service attached',
      ),
    );
  }

  LuminaError? _readLastNativeError() {
    final getter = _nativeBridge?.getLastErrorJson;
    if (getter == null || !(_nativeBridge?.isNativeBound() ?? false)) {
      return null;
    }
    final raw = getter();
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = JsonReader.decodeObject(raw);
      return LuminaError.tryParseJson(map);
    } catch (_) {
      return LuminaError(code: LuminaErrorCode.internal, message: raw.trim());
    }
  }

  void _applySnapshot(ProtocolSnapshot snapshot) {
    _state = snapshot.playback;
    _queue = snapshot.queue;
    if (snapshot.signalPath != null) {
      _signalPath = snapshot.signalPath;
      _emitSignalPath(snapshot.signalPath!);
    }
    _devices = List<ProtocolAudioDeviceInfo>.unmodifiable(snapshot.devices);
    _zones = List<ProtocolZoneInfo>.unmodifiable(snapshot.zones);
    _emitState(_state);
    _emitQueue(_queue);
    _emitDevices(_devices);
    _emitZones(_zones);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _serviceStateSub?.cancel();
    await _serviceSignalSub?.cancel();
    await _fallbackStateSub?.cancel();
    await _fallbackQueueSub?.cancel();
    await _fallbackErrorSub?.cancel();
    await _stateController.close();
    await _queueController.close();
    await _connectionController.close();
    await _errorController.close();
    await _signalPathController.close();
    await _devicesController.close();
    await _zonesController.close();
  }
}
