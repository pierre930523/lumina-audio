part of 'remote_playback_backend.dart';

mixin _RemotePlaybackWsMixin on _RemotePlaybackBackendBase {
  String _buildWsUrl() {
    final uri = Uri.parse(baseUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final hostPort = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final token = bearerToken;
    if (token != null && token.isNotEmpty) {
      final encoded = Uri.encodeQueryComponent(token);
      return '$wsScheme://$hostPort/api/v1/ws?snapshot=true&token=$encoded';
    }
    return '$wsScheme://$hostPort/api/v1/ws?snapshot=true';
  }

  Future<Result<void, LuminaError>> _openConnection({
    required bool isReconnect,
  }) async {
    if (_disposed || _intentionalDisconnect) {
      return const Err<void, LuminaError>(
        LuminaError(
          code: LuminaErrorCode.invalidState,
          message: 'Connection cancelled',
        ),
      );
    }

    final gen = ++_connectionGeneration;
    _setConnectionStatus(
      _connectionStatus.copyWith(
        phase: isReconnect
            ? ConnectionPhase.reconnecting
            : ConnectionPhase.connecting,
        reconnectAttempt: _reconnectAttempt,
      ),
    );

    await _closeSocketOnly();

    final client = _buildHttpClient();
    try {
      final headers = <String, Object>{
        if (bearerToken != null && bearerToken!.isNotEmpty)
          HttpHeaders.authorizationHeader: 'Bearer $bearerToken',
      };
      final ws = await WebSocket.connect(
        _buildWsUrl(),
        headers: headers.isEmpty ? null : headers,
        customClient: client,
      ).timeout(requestTimeout);

      if (_disposed || _intentionalDisconnect || gen != _connectionGeneration) {
        await ws.close();
        return const Ok<void, LuminaError>(null);
      }

      ws.pingInterval = const Duration(seconds: 15);
      _ws = ws;
      _reconnectAttempt = 0;

      _wsSub = ws.listen(
        (Object? raw) {
          if (_disposed || gen != _connectionGeneration) return;
          if (raw is String) {
            _handleWsTextMessage(raw);
          }
        },
        onError: (Object err) {
          if (_disposed || _intentionalDisconnect || gen != _connectionGeneration) {
            return;
          }
          _handleSocketClosed(
            LuminaError(
              code: LuminaErrorCode.networkDisconnected,
              message: 'WebSocket stream error: $err',
              retryable: true,
            ),
          );
        },
        onDone: () {
          if (_disposed || _intentionalDisconnect || gen != _connectionGeneration) {
            return;
          }
          _handleSocketClosed(
            const LuminaError(
              code: LuminaErrorCode.networkDisconnected,
              message: 'WebSocket connection closed by remote host',
              retryable: true,
            ),
          );
        },
        cancelOnError: true,
      );

      // Atomic snapshot fetch guarantees complete state alignment on initial
      // connect AND on every reconnect even if WS events were dropped.
      final snapResult = await fetchSnapshot();
      if (_disposed || _intentionalDisconnect || gen != _connectionGeneration) {
        return const Ok<void, LuminaError>(null);
      }

      if (snapResult case Ok<ProtocolSnapshot, LuminaError>(value: final snap)) {
        _applySnapshot(snap);
      }

      _setConnectionStatus(
        _connectionStatus.copyWith(
          phase: ConnectionPhase.connected,
          reconnectAttempt: 0,
          lastConnectedAtMs: _nowMs(),
          clearNextRetryDelay: true,
          clearLastError: true,
        ),
      );

      return const Ok<void, LuminaError>(null);
    } on TimeoutException catch (e) {
      final err = LuminaError(
        code: LuminaErrorCode.streamResolveTimeout,
        message: 'WebSocket connection timed out: $e',
        retryable: true,
      );
      _emitError(err);
      if (isReconnect || autoReconnect) {
        _scheduleReconnect(err);
      } else {
        _setConnectionStatus(
          _connectionStatus.copyWith(
            phase: ConnectionPhase.failed,
            lastError: err,
          ),
        );
      }
      return Err<void, LuminaError>(err);
    } catch (e) {
      final err = LuminaError(
        code: LuminaErrorCode.networkDisconnected,
        message: 'WebSocket connection failed: $e',
        retryable: true,
      );
      _emitError(err);
      if (isReconnect || autoReconnect) {
        _scheduleReconnect(err);
      } else {
        _setConnectionStatus(
          _connectionStatus.copyWith(
            phase: ConnectionPhase.failed,
            lastError: err,
          ),
        );
      }
      return Err<void, LuminaError>(err);
    } finally {
      client.close(force: false);
    }
  }

  void _handleSocketClosed(LuminaError reason) {
    _emitError(reason);
    if (!autoReconnect || _intentionalDisconnect || _disposed) {
      _setConnectionStatus(
        _connectionStatus.copyWith(
          phase: ConnectionPhase.disconnected,
          lastError: reason,
          clearNextRetryDelay: true,
        ),
      );
      return;
    }
    _scheduleReconnect(reason);
  }

  void _scheduleReconnect(LuminaError reason) {
    if (_disposed || _intentionalDisconnect) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt += 1;

    if (maxReconnectAttempts > 0 && _reconnectAttempt > maxReconnectAttempts) {
      _setConnectionStatus(
        _connectionStatus.copyWith(
          phase: ConnectionPhase.failed,
          reconnectAttempt: _reconnectAttempt - 1,
          lastError: reason,
          clearNextRetryDelay: true,
        ),
      );
      return;
    }

    final delay = computeBackoffDelay(_reconnectAttempt);
    recordedReconnectDelays.add(delay);
    _setConnectionStatus(
      _connectionStatus.copyWith(
        phase: ConnectionPhase.reconnecting,
        reconnectAttempt: _reconnectAttempt,
        nextRetryDelay: delay,
        lastError: reason,
      ),
    );

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || _intentionalDisconnect) return;
      unawaited(_openConnection(isReconnect: true));
    });
  }

  void _handleWsTextMessage(String raw) {
    Map<String, Object?>? decoded;
    try {
      decoded = JsonReader.decodeObject(raw);
    } catch (_) {
      return;
    }
    if (decoded == null) return;

    final event = WsServerEvent.tryFromJson(decoded);
    if (event != null) {
      _applyWsEvent(event);
      return;
    }

    // Legacy compatibility: handle unmigrated `state_changed {volume}` events.
    final r = JsonReader(decoded);
    if (r.optionalString('type') == 'state_changed' && r.containsKey('volume')) {
      final vol = r.optionalDouble('volume');
      if (vol != null) {
        final clamped = vol.clamp(0.0, 1.0);
        _state = _state.copyWith(
          volume: clamped,
          isMuted: clamped == 0.0,
          timestampMs: _nowMs(),
        );
        _emitState(_state);
      }
    }
  }

  void _applyWsEvent(WsServerEvent event) {
    switch (event) {
      case SnapshotEvent(:final snapshot):
        _applySnapshot(snapshot);
      case PlaybackStateChangedEvent(:final state):
        if (_state.playbackEpoch > 0 &&
            state.playbackEpoch > 0 &&
            state.playbackEpoch < _state.playbackEpoch) {
          return;
        }
        _state = state;
        _emitState(_state);
        if (state.error != null) {
          _emitError(state.error!);
        }
      case QueueStateChangedEvent(:final queue):
        _queue = queue;
        _emitQueue(_queue);
      case SignalPathUpdatedEvent(:final signalPath):
        _signalPath = signalPath;
        _emitSignalPath(signalPath);
      case DevicesChangedEvent(:final devices):
        _devices = List<ProtocolAudioDeviceInfo>.unmodifiable(devices);
        _emitDevices(_devices);
      case ZonesChangedEvent(:final zones):
        _zones = List<ProtocolZoneInfo>.unmodifiable(zones);
        _emitZones(_zones);
      case ErrorEvent(:final error):
        _emitError(error);
    }
  }

  void _applySnapshot(ProtocolSnapshot snapshot) {
    if (snapshot.sequence > 0 && snapshot.sequence < _lastSequence) {
      // Allow reset if sequence restarted (e.g., server restarted with sequence=1).
      if (snapshot.sequence > 1) {
        return;
      }
    }
    _lastSequence = snapshot.sequence;
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

  Future<void> _closeSocketOnly() async {
    final sub = _wsSub;
    _wsSub = null;
    await sub?.cancel();
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        await ws.close();
      } catch (_) {}
    }
  }

  void _setConnectionStatus(ConnectionStatus status) {
    _connectionStatus = status;
    if (!_disposed && !_connectionController.isClosed) {
      _connectionController.add(status);
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
