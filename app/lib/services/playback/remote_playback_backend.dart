import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../models/protocol/json_reader.dart';
import '../../models/protocol/lumina_error.dart';
import '../../models/protocol/protocol_models.dart';
import '../../models/protocol/result.dart';
import '../../models/studio_models.dart';
import 'playback_backend.dart';

part 'remote_playback_backend_ws.dart';

class _DirectHttpOverrides extends HttpOverrides {}

abstract class _RemotePlaybackBackendBase implements PlaybackBackend {
  final String baseUrl;
  final String? bearerToken;
  final bool allowSelfSignedTls;
  final ConnectionMode connectionMode;
  final Duration requestTimeout;
  final Duration baseRetryDelay;
  final Duration maxRetryDelay;
  final double jitterRatio;
  final int maxReconnectAttempts;
  final bool autoReconnect;
  final math.Random _random;
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

  ProtocolPlaybackState _state = ProtocolPlaybackState.initial;
  QueueState _queue = QueueState.empty;
  late ConnectionStatus _connectionStatus;
  ProtocolSignalPath? _signalPath;
  List<ProtocolAudioDeviceInfo> _devices = const <ProtocolAudioDeviceInfo>[];
  List<ProtocolZoneInfo> _zones = const <ProtocolZoneInfo>[];

  WebSocket? _ws;
  StreamSubscription<Object?>? _wsSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  int _lastSequence = 0;
  int _connectionGeneration = 0;
  bool _intentionalDisconnect = false;
  bool _disposed = false;

  /// Recorded reconnect delays (useful for deterministic backoff verification in tests).
  final List<Duration> recordedReconnectDelays = <Duration>[];

  _RemotePlaybackBackendBase({
    required String baseUrl,
    this.bearerToken,
    this.allowSelfSignedTls = false,
    ConnectionMode? mode,
    this.requestTimeout = const Duration(seconds: 10),
    this.baseRetryDelay = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 30),
    this.jitterRatio = 0.2,
    this.maxReconnectAttempts = 0, // 0 = unlimited
    this.autoReconnect = true,
    math.Random? random,
    int Function()? nowMs,
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        connectionMode = mode ??
            (_normalizeBaseUrl(baseUrl).startsWith('https://')
                ? ConnectionMode.wanRemote
                : ConnectionMode.lanRemote),
        _random = random ?? math.Random(),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _connectionStatus = ConnectionStatus(
      phase: ConnectionPhase.disconnected,
      mode: connectionMode,
      endpointUrl: this.baseUrl,
    );
  }

  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  HttpClient _buildHttpClient();
  Duration computeBackoffDelay(int attempt);

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

  void _emitError(LuminaError error) {
    if (!_disposed && !_errorController.isClosed) {
      _errorController.add(error);
    }
  }
}

/// Unified remote [PlaybackBackend] communicating with `core-server` over REST
/// (`/api/v1/snapshot`, `/api/v1/playback/command`, `/api/v1/queue/*`) and
/// WebSocket (`/api/v1/ws?snapshot=true&token=...`).
///
/// Features:
/// - Exponential backoff + jitter WebSocket reconnection.
/// - Atomic `GET /api/v1/snapshot` resynchronization after every reconnect.
/// - Reactive [ConnectionStatus] and structured [LuminaError] reporting.
/// - Zero `dynamic` in public API or internal state.
class RemotePlaybackBackend extends _RemotePlaybackBackendBase
    with _RemotePlaybackWsMixin {
  static final HttpOverrides _directHttpOverrides = _DirectHttpOverrides();

  RemotePlaybackBackend({
    required super.baseUrl,
    super.bearerToken,
    super.allowSelfSignedTls,
    super.mode,
    super.requestTimeout,
    super.baseRetryDelay,
    super.maxRetryDelay,
    super.jitterRatio,
    super.maxReconnectAttempts,
    super.autoReconnect,
    super.random,
    super.nowMs,
  });

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
  HttpClient _buildHttpClient() {
    final client = _directHttpOverrides.createHttpClient(null);
    client.connectionTimeout = const Duration(seconds: 5);
    if (allowSelfSignedTls) {
      client.badCertificateCallback = (_, _, _) => true;
    }
    return client;
  }

  /// Computes bounded exponential backoff with jitter:
  /// `base * 2^(attempt-1)` clamped to `maxRetryDelay`, then perturbed by `±jitterRatio`.
  @override
  Duration computeBackoffDelay(int attempt) {
    final safeAttempt = attempt < 1 ? 1 : attempt;
    final expShift = math.min(safeAttempt - 1, 20);
    final rawMs = baseRetryDelay.inMilliseconds * (1 << expShift);
    final cappedMs = math.min(rawMs, maxRetryDelay.inMilliseconds);
    if (jitterRatio <= 0.0 || cappedMs <= 1) {
      return Duration(milliseconds: math.max(1, cappedMs));
    }
    final spread = (cappedMs * jitterRatio).round();
    final delta = spread > 0 ? (_random.nextInt(spread * 2 + 1) - spread) : 0;
    final jittered = math.max(1, math.min(maxRetryDelay.inMilliseconds, cappedMs + delta));
    return Duration(milliseconds: jittered);
  }

  @override
  Future<Result<void, LuminaError>> connect() async {
    if (_disposed) {
      return const Err<void, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.invalidState,
          message: 'RemotePlaybackBackend has been disposed',
        ),
      );
    }
    _intentionalDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;

    return _openConnection(isReconnect: false);
  }

  @override
  Future<Result<ProtocolSnapshot, LuminaError>> fetchSnapshot() async {
    final res = await _requestJsonObject('GET', '/api/v1/snapshot');
    return res.map((json) => ProtocolSnapshot.fromJson(json));
  }

  @override
  Future<Result<void, LuminaError>> execute(PlaybackCommand command) async {
    if (_disposed) {
      return const Err<void, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.invalidState,
          message: 'RemotePlaybackBackend has been disposed',
        ),
      );
    }

    final res = await _requestJsonObject(
      'POST',
      '/api/v1/playback/command',
      body: command.toJson(),
    );
    switch (res) {
      case Ok<Map<String, Object?>, LuminaError>(value: final payload):
        final r = JsonReader(payload);
        final playbackMap = r.optionalMap('playback') ??
            (r.containsKey('status') && r.containsKey('position_ms')
                ? payload
                : null);
        if (playbackMap != null) {
          _state = ProtocolPlaybackState.fromJson(playbackMap);
          _emitState(_state);
        }
        final queueMap = r.optionalMap('queue');
        if (queueMap != null) {
          _queue = QueueState.fromJson(queueMap);
          _emitQueue(_queue);
        }
        return const Ok<void, LuminaError>(null);
      case Err<Map<String, Object?>, LuminaError>(error: final err):
        _emitError(err);
        return Err<void, LuminaError>(err);
    }
  }

  Future<Result<Map<String, Object?>, LuminaError>> _requestJsonObject(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final client = _buildHttpClient();
    try {
      final uri = Uri.parse('$baseUrl$path');
      final req = await client.openUrl(method, uri).timeout(requestTimeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (bearerToken != null && bearerToken!.isNotEmpty) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $bearerToken',
        );
      }
      if (body != null) {
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(requestTimeout);
      final text = await utf8.decodeStream(resp).timeout(requestTimeout);
      Map<String, Object?>? decodedMap;
      if (text.trim().isNotEmpty) {
        try {
          decodedMap = JsonReader.decodeObject(text);
        } catch (_) {
          decodedMap = null;
        }
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return Ok<Map<String, Object?>, LuminaError>(
          decodedMap ?? const <String, Object?>{},
        );
      }
      final parsedErr = LuminaError.tryParseJson(
            decodedMap,
            fallbackHttpStatus: resp.statusCode,
          ) ??
          LuminaError(
            code: resp.statusCode == 401 || resp.statusCode == 403
                ? LuminaErrorCode.streamAuthRequired
                : LuminaErrorCode.httpError,
            message: 'HTTP ${resp.statusCode} on $method $path',
            retryable: resp.statusCode >= 500 || resp.statusCode == 429,
            httpStatus: resp.statusCode,
            details: text.trim().isEmpty ? null : text.trim(),
          );
      return Err<Map<String, Object?>, LuminaError>(parsedErr);
    } on TimeoutException catch (e) {
      return Err<Map<String, Object?>, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.streamResolveTimeout,
          message: 'Request $method $path timed out: $e',
          retryable: true,
        ),
      );
    } on SocketException catch (e) {
      return Err<Map<String, Object?>, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.networkDisconnected,
          message: 'Network error on $method $path: ${e.message}',
          retryable: true,
        ),
      );
    } catch (e) {
      return Err<Map<String, Object?>, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.internal,
          message: 'Unexpected HTTP error on $method $path: $e',
          retryable: false,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocketOnly();
    await _stateController.close();
    await _queueController.close();
    await _connectionController.close();
    await _errorController.close();
    await _signalPathController.close();
    await _devicesController.close();
    await _zonesController.close();
  }
}
