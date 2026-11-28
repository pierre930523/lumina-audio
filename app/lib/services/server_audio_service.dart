import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/audio_format.dart';
import '../models/audio_output_info.dart';
import '../models/ingestion_models.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/protocol/json_reader.dart';
import '../models/protocol/lumina_error.dart';
import '../models/protocol/protocol_models.dart';
import '../models/recommendation_models.dart';
import '../models/signal_path.dart';
import '../models/stream_source_spec.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'per_device_playback_tracker.dart';
import 'playback/playback_backend.dart';
import 'playback/playback_controller.dart';
import 'playback/remote_playback_backend.dart';
import 'playback_persistence_service.dart';
import 'platform_asset_opener.dart';
import 'streaming/autoplay_controller.dart';
import 'streaming/l1_stream_cache.dart';
import 'streaming/pot_sidecar_manager.dart';
import 'streaming/streaming_manager.dart';

part 'server/mdns_discovery_client.dart';
part 'server/server_track_hydration.dart';
part 'server/server_ws_connection_mixin.dart';
part 'server/server_ws_events_mixin.dart';
part 'server/server_playback_mixin.dart';
part 'server/server_transport_and_media_mixin.dart';
part 'server/server_library_and_devices_mixin.dart';
part 'server/server_providers_and_pairing_mixin.dart';
part 'server/server_ingestion_mixin.dart';
part 'server/server_album_grouping_mixin.dart';
part 'server/server_focus_tags_folders_mixin.dart';
part 'server/server_step4_mixin.dart';
part 'server/server_step5_mixin.dart';
part 'server/server_step5_backup_export_mixin.dart';
part 'server/server_track_actions_mixin.dart';

class _DirectHttpOverrides extends HttpOverrides {}

abstract class _ServerAudioServiceBase implements AudioService {
  final PerDevicePlaybackTracker _tracker = PerDevicePlaybackTracker();

  String _baseUrl;
  String? _bearerToken;
  bool _allowSelfSignedTls;
  ConnectionMode _mode;

  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<SignalPath> _signalPathController =
      StreamController<SignalPath>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<ScanProgressEvent> _scanProgressController =
      StreamController<ScanProgressEvent>.broadcast();
  final StreamController<QueueState> _queueStateController =
      StreamController<QueueState>.broadcast();
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<LuminaError> _errorController =
      StreamController<LuminaError>.broadcast();
  final StreamController<TrackInfo> _trackChangedController =
      StreamController<TrackInfo>.broadcast();
  final StreamController<List<TrackInfo>> _queueUpdatedController =
      StreamController<List<TrackInfo>>.broadcast();
  final StreamController<void> _libraryReloadedController =
      StreamController<void>.broadcast();

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _wsReconnectTimer;
  int _wsReconnectAttempt = 0;
  bool _wsIntentionalClose = false;
  final Duration _wsBaseRetryDelay;
  final Duration _wsMaxRetryDelay;
  final bool _wsAutoReconnect;
  final math.Random _wsRandom = math.Random();
  ConnectionStatus _connectionStatus;
  QueueState _queueState = QueueState.empty;
  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffle = false;
  RemotePlaybackBackend? _protocolBackend;
  PlaybackController? _protocolController;
  PlaybackState _state = PlaybackState(
    status: PlaybackStatus.stopped,
    position: Duration.zero,
    volume: 1.0,
    isMuted: false,
    track: null,
  );
  SignalPath _signalPath = const SignalPath(
    overallQuality: SignalQuality.lossless,
    description: '遠端核心伺服器',
    nodes: [],
    dspBypassed: true,
  );
  List<TrackInfo> _queue = [];
  List<LyricLine> _currentLyrics = const [];
  StreamingTrackHandler? _streamingTrackHandler;
  void Function()? _playbackInterruptHandler;
  String? _lastError;
  bool _needsLoadOnResume = false;
  int _activeEpoch = 0;
  int _lastCancelledEpoch = 0;
  int _lastObservedSwapGeneration = 0;
  HttpClient? _activePlayHttpClient;
  Future<void>? _reloadTracksFuture;
  final Set<String> _reloadedScanIds = <String>{};
  bool _disposed = false;

  static final HttpOverrides _directHttpOverrides = _DirectHttpOverrides();

  _ServerAudioServiceBase(
    this._baseUrl,
    this._bearerToken,
    this._allowSelfSignedTls,
    this._mode,
    this._wsBaseRetryDelay,
    this._wsMaxRetryDelay,
    this._wsAutoReconnect,
  ) : _connectionStatus = ConnectionStatus(
          phase: ConnectionPhase.disconnected,
          mode: _mode,
          endpointUrl: _baseUrl,
        );

  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  void _abortActivePlayRequest() {
    final active = _activePlayHttpClient;
    _activePlayHttpClient = null;
    if (active != null) {
      try {
        active.close(force: true);
      } catch (_) {}
    }
  }

  HttpClient _buildHttpClient() {
    // Bypass TestWidgetsFlutterBinding's mock HTTP 400 override when run inside widget test suites.
    final client = _directHttpOverrides.createHttpClient(null);
    client.connectionTimeout = const Duration(seconds: 5);
    if (_allowSelfSignedTls) {
      client.badCertificateCallback = (_, _, _) => true;
    }
    return client;
  }

  Future<(int, dynamic)> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
    bool trackAsPlayRequest = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (trackAsPlayRequest) {
      _abortActivePlayRequest();
    }
    final client = _buildHttpClient();
    if (trackAsPlayRequest) {
      _activePlayHttpClient = client;
    }
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (authenticated && _bearerToken != null) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_bearerToken',
        );
      }
      if (body != null) {
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(timeout);
      final text = await utf8.decodeStream(resp).timeout(timeout);
      dynamic parsed;
      if (text.trim().isNotEmpty) {
        try {
          parsed = jsonDecode(text);
        } catch (_) {
          parsed = text;
        }
      }
      return (resp.statusCode, parsed);
    } finally {
      if (identical(_activePlayHttpClient, client)) {
        _activePlayHttpClient = null;
      }
      client.close(force: true);
    }
  }

  Future<(int, Uint8List?)> _requestBytes(
    String method,
    String path, {
    bool authenticated = true,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final client = _buildHttpClient();
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final req = await client.openUrl(method, uri).timeout(timeout);
      if (authenticated && _bearerToken != null) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_bearerToken',
        );
      }
      final resp = await req.close().timeout(timeout);
      final chunks = await resp.toList().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      for (final chunk in chunks) {
        builder.add(chunk);
      }
      return (resp.statusCode, builder.takeBytes());
    } finally {
      client.close(force: true);
    }
  }

  void _setConnectionStatus(ConnectionStatus next) {
    _connectionStatus = next;
    if (!_disposed && !_connectionStatusController.isClosed) {
      _connectionStatusController.add(next);
    }
  }

  void _emitError(LuminaError err) {
    _lastError = err.message;
    if (!_disposed && !_errorController.isClosed) {
      _errorController.add(err);
    }
  }

  Future<void> _fetchLyrics(String trackId, {String? path}) async {
    try {
      final res = await getLyrics(trackId, path: path);
      if (res != null && res['found'] == true && res['lines'] is List) {
        final rawLines = res['lines'] as List;
        final parsed = <LyricLine>[];
        for (final l in rawLines) {
          if (l is Map<String, dynamic>) {
            final words = <LyricWord>[];
            if (l['words'] is List) {
              for (final w in l['words']) {
                if (w is Map<String, dynamic>) {
                  words.add(
                    LyricWord(
                      text: w['text']?.toString() ?? '',
                      start: Duration(
                        milliseconds: (w['start_ms'] as num?)?.toInt() ?? 0,
                      ),
                      end: Duration(
                        milliseconds: (w['end_ms'] as num?)?.toInt() ?? 0,
                      ),
                    ),
                  );
                }
              }
            }
            parsed.add(
              LyricLine(
                start: Duration(
                  milliseconds: (l['start_ms'] as num?)?.toInt() ?? 0,
                ),
                end: Duration(
                  milliseconds: (l['end_ms'] as num?)?.toInt() ?? 0,
                ),
                text: l['text']?.toString() ?? '',
                words: words,
                isSynced: l['start_ms'] != null || words.isNotEmpty,
              ),
            );
          }
        }
        _currentLyrics = parsed;
      } else {
        _currentLyrics = const [];
      }
    } catch (_) {
      _currentLyrics = const [];
    }
  }

  void _handleWsMessage(Map<String, dynamic> msg);
  Future<void> _scheduleReloadTracksFromServer({String? scanId});
  Future<void> connectWebSocket({bool isReconnect = false});
  Future<bool> checkHealth();
  Future<void> syncInitialState();
}

class ServerAudioService extends _ServerAudioServiceBase
    with
        _ServerWsConnectionMixin,
        _ServerWsEventsMixin,
        _ServerPlaybackMixin,
        _ServerTransportAndMediaMixin,
        _ServerLibraryAndDevicesMixin,
        _ServerProvidersAndPairingMixin,
        _ServerIngestionMixin,
        _ServerAlbumGroupingMixin,
        _ServerFocusTagsFoldersMixin,
        _ServerStep4Mixin,
        _ServerStep5Mixin,
        _ServerStep5BackupExportMixin,
        _ServerTrackActionsMixin {
  ServerAudioService({
    String baseUrl = 'http://127.0.0.1:9888',
    String? bearerToken,
    bool allowSelfSignedTls = false,
    ConnectionMode mode = ConnectionMode.lanRemote,
    Duration wsBaseRetryDelay = const Duration(milliseconds: 500),
    Duration wsMaxRetryDelay = const Duration(seconds: 30),
    bool wsAutoReconnect = true,
  }) : super(
          _ServerAudioServiceBase._normalizeBaseUrl(baseUrl),
          bearerToken,
          allowSelfSignedTls,
          mode,
          wsBaseRetryDelay,
          wsMaxRetryDelay,
          wsAutoReconnect,
        );

  @override
  Map<String, PlaybackState> get devicePlaybackStates =>
      _tracker.snapshotDevices(_state);

  @override
  Map<String, PlaybackState> get zonePlaybackStates =>
      _tracker.snapshotZones(activeLocalState: _state);

  @override
  String? get activeDeviceId => _tracker.activeDeviceId;

  @override
  bool get isNativeBound => false;

  @override
  ConnectionMode get connectionMode => _mode;

  @override
  String? get activeServerUrl => _baseUrl;

  String? get bearerToken => _bearerToken;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  Stream<SignalPath> get signalPathStream => _signalPathController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<void> get libraryReloadedStream => _libraryReloadedController.stream;

  @override
  PlaybackState get currentState => _state;

  @override
  SignalPath get currentSignalPath => _signalPath;

  @override
  List<LyricLine> get currentLyrics => _currentLyrics;

  @override
  List<TrackInfo> get queue => _queue;

  @override
  void dispose() {
    _disposed = true;
    _wsIntentionalClose = true;
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;
    _protocolController?.dispose();
    _protocolController = null;
    _protocolBackend?.dispose();
    _protocolBackend = null;
    _abortActivePlayRequest();
    _wsSub?.cancel();
    _ws?.close();
    _stateController.close();
    _signalPathController.close();
    _positionController.close();
    _scanProgressController.close();
    _queueStateController.close();
    _connectionStatusController.close();
    _errorController.close();
    _trackChangedController.close();
    _queueUpdatedController.close();
    _libraryReloadedController.close();
  }
}
