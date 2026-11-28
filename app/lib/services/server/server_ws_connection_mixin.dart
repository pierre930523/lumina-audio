part of '../server_audio_service.dart';

mixin _ServerWsConnectionMixin on _ServerAudioServiceBase {
  String _wsUrl() {
    final uri = Uri.parse(_baseUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final hostPort = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final encodedTok = Uri.encodeQueryComponent(_bearerToken ?? '');
    return '$wsScheme://$hostPort/api/v1/ws?snapshot=true&token=$encodedTok';
  }

  Duration _computeWsBackoffDelay(int attempt) {
    final safe = attempt < 1 ? 1 : attempt;
    final exp = math.min(safe - 1, 20);
    final rawMs = _wsBaseRetryDelay.inMilliseconds * (1 << exp);
    final cappedMs = math.min(rawMs, _wsMaxRetryDelay.inMilliseconds);
    final spread = (cappedMs * 0.2).round();
    final delta = spread > 0 ? (_wsRandom.nextInt(spread * 2 + 1) - spread) : 0;
    final jittered = math.max(
      1,
      math.min(_wsMaxRetryDelay.inMilliseconds, cappedMs + delta),
    );
    return Duration(milliseconds: jittered);
  }

  @override
  Future<void> connectWebSocket({bool isReconnect = false}) async {
    if (_disposed) return;
    _wsIntentionalClose = false;
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;

    _setConnectionStatus(
      _connectionStatus.copyWith(
        phase: isReconnect
            ? ConnectionPhase.reconnecting
            : ConnectionPhase.connecting,
        mode: _mode,
        endpointUrl: _baseUrl,
        reconnectAttempt: _wsReconnectAttempt,
      ),
    );

    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;

    final client = _buildHttpClient();
    try {
      _ws = await WebSocket.connect(
        _wsUrl(),
        headers: _bearerToken != null
            ? {'Authorization': 'Bearer $_bearerToken'}
            : null,
        customClient: client,
      );
      _ws!.pingInterval = const Duration(seconds: 15);
      _wsReconnectAttempt = 0;
      _setConnectionStatus(
        _connectionStatus.copyWith(
          phase: ConnectionPhase.connected,
          mode: _mode,
          endpointUrl: _baseUrl,
          reconnectAttempt: 0,
          lastConnectedAtMs: DateTime.now().millisecondsSinceEpoch,
          clearNextRetryDelay: true,
          clearLastError: true,
        ),
      );

      _wsSub = _ws!.listen(
        (raw) {
          if (raw is! String) return;
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) {
              _handleWsMessage(decoded);
            }
          } catch (_) {}
        },
        onError: (Object err) {
          final luminaErr = LuminaError(
            code: LuminaErrorCode.networkDisconnected,
            message: 'WebSocket error: $err',
            retryable: true,
          );
          _emitError(luminaErr);
          _scheduleWsReconnect(luminaErr);
        },
        onDone: () {
          if (_disposed || _wsIntentionalClose) return;
          const luminaErr = LuminaError(
            code: LuminaErrorCode.networkDisconnected,
            message: 'WebSocket disconnected',
            retryable: true,
          );
          _emitError(luminaErr);
          _scheduleWsReconnect(luminaErr);
        },
        cancelOnError: true,
      );

      if (isReconnect) {
        unawaited(_resyncFromSnapshotAfterReconnect());
      }
    } catch (e) {
      final luminaErr = LuminaError(
        code: LuminaErrorCode.networkDisconnected,
        message: 'WebSocket connect failed: $e',
        retryable: true,
      );
      _emitError(luminaErr);
      if (isReconnect) {
        _scheduleWsReconnect(luminaErr);
      } else {
        _setConnectionStatus(
          _connectionStatus.copyWith(
            phase: ConnectionPhase.failed,
            lastError: luminaErr,
          ),
        );
        rethrow;
      }
    }
  }

  void _scheduleWsReconnect(LuminaError reason) {
    if (_disposed || _wsIntentionalClose || !_wsAutoReconnect) {
      _setConnectionStatus(
        _connectionStatus.copyWith(
          phase: ConnectionPhase.disconnected,
          lastError: reason,
          clearNextRetryDelay: true,
        ),
      );
      return;
    }
    _wsReconnectTimer?.cancel();
    _wsReconnectAttempt += 1;
    final delay = _computeWsBackoffDelay(_wsReconnectAttempt);
    _setConnectionStatus(
      _connectionStatus.copyWith(
        phase: ConnectionPhase.reconnecting,
        reconnectAttempt: _wsReconnectAttempt,
        nextRetryDelay: delay,
        lastError: reason,
      ),
    );
    _wsReconnectTimer = Timer(delay, () {
      _wsReconnectTimer = null;
      if (_disposed || _wsIntentionalClose) return;
      unawaited(connectWebSocket(isReconnect: true));
    });
  }

  Future<void> _resyncFromSnapshotAfterReconnect() async {
    try {
      final (code, data) = await _requestJson('GET', '/api/v1/snapshot');
      if (code == 200 && data is Map) {
        final snapMap = JsonReader.asMapOrNull(data);
        if (snapMap != null) {
          _applyProtocolSnapshot(ProtocolSnapshot.fromJson(snapMap));
          return;
        }
      }
      await syncInitialState();
    } catch (_) {}
  }

  void _applyProtocolSnapshot(ProtocolSnapshot snapshot) {
    _queueState = snapshot.queue;
    _repeatMode = snapshot.playback.repeatMode;
    _shuffle = snapshot.playback.shuffle;
    _queue = snapshot.queue.toTrackInfoList().toList();
    _state = snapshot.playback.toLegacy(fallbackTrack: _state.track);
    if (snapshot.signalPath != null) {
      _signalPath = snapshot.signalPath!.toLegacy(
        dspBypassed: snapshot.playback.dspBypassed,
      );
      if (!_disposed && !_signalPathController.isClosed) {
        _signalPathController.add(_signalPath);
      }
    }
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(_state);
    }
    if (!_disposed && !_positionController.isClosed) {
      _positionController.add(_state.position);
    }
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(_queueState);
    }
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
  }

  @visibleForTesting
  void handleWsMessageForTest(Map<String, dynamic> msg) =>
      _handleWsMessage(msg);

  @override
  Future<bool> checkHealth() async {
    try {
      final (code, data) = await _requestJson(
        'GET',
        '/api/v1/health',
        authenticated: false,
      );
      return code == 200 && data is Map && data['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> _scheduleReloadTracksFromServer({String? scanId}) {
    if (_disposed) return Future<void>.value();
    final trimmed = scanId?.trim() ?? '';
    if (trimmed.isNotEmpty && _reloadedScanIds.contains(trimmed)) {
      return _reloadTracksFuture ?? Future<void>.value();
    }
    if (trimmed.isNotEmpty) {
      if (_reloadedScanIds.length >= 64) {
        _reloadedScanIds.remove(_reloadedScanIds.first);
      }
      _reloadedScanIds.add(trimmed);
    }
    final inFlight = _reloadTracksFuture;
    if (inFlight != null) return inFlight;
    final future = _reloadTracksFromServer().whenComplete(() {
      _reloadTracksFuture = null;
    });
    _reloadTracksFuture = future;
    return future;
  }

  Future<void> _reloadTracksFromServer() async {
    try {
      final (trkCode, trkData) =
          await _requestJson('GET', '/api/v1/library/tracks');
      if (_disposed) return;
      if (trkCode == 200 && trkData is List) {
        _queue = trkData
            .whereType<Map<String, dynamic>>()
            .map((item) => _serverParseTrackFromMap(item))
            .toList();
        if (!_stateController.isClosed) {
          _stateController.add(_state);
        }
      }
    } catch (_) {}
  }

  @override
  Future<void> syncInitialState() async {
    final (stCode, stData) = await _requestJson('GET', '/api/v1/playback/state');
    if (stCode == 200 && stData is Map<String, dynamic>) {
      _handleWsMessage({'type': 'PlaybackStateChanged', 'payload': stData});
    }
    final (spCode, spData) = await _requestJson('GET', '/api/v1/signal-path');
    if (spCode == 200 && spData is Map<String, dynamic>) {
      _handleWsMessage({'type': 'SignalPathUpdated', 'payload': spData});
    }
    final (trkCode, trkData) =
        await _requestJson('GET', '/api/v1/library/tracks');
    if (trkCode == 200 && trkData is List) {
      _queue = trkData
          .whereType<Map<String, dynamic>>()
          .map((item) => _serverParseTrackFromMap(item))
          .toList();
    }
  }
}
