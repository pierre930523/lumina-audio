part of '../server_audio_service.dart';

mixin _ServerWsEventsMixin on _ServerAudioServiceBase {
  Future<void> _refreshLyricsForTrack(TrackInfo track) async {
    await _fetchLyrics(track.id, path: track.filePath);
    if (_disposed) return;
    if (_state.track?.id == track.id && !_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  void _applySnapshotMessage(Map<String, dynamic> msg) {
    final rawPayload = JsonReader.asMapOrNull(msg['payload']);
    if (rawPayload != null) {
      final snap = ProtocolSnapshot.fromJson(rawPayload);
      _queueState = snap.queue;
      _repeatMode = snap.playback.repeatMode;
      _shuffle = snap.playback.shuffle;
      _queue = snap.queue.toTrackInfoList().toList();
      _state = snap.playback.toLegacy(fallbackTrack: _state.track);
      if (snap.signalPath != null) {
        _signalPath = snap.signalPath!.toLegacy(
          dspBypassed: snap.playback.dspBypassed,
        );
        if (!_disposed && !_signalPathController.isClosed) {
          _signalPathController.add(_signalPath);
        }
      }
      if (!_disposed && !_stateController.isClosed) _stateController.add(_state);
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
  }

  @override
  void _handleWsMessage(Map<String, dynamic> msg) {
    final type = msg['type']?.toString();
    if (type == 'Snapshot') {
      _applySnapshotMessage(msg);
      return;
    } else if (type == 'QueueStateChanged') {
      final rawPayload = JsonReader.asMapOrNull(msg['payload']);
      if (rawPayload != null) {
        _queueState = QueueState.fromJson(rawPayload);
        _repeatMode = _queueState.repeatMode;
        _shuffle = _queueState.shuffle;
        _queue = _queueState.toTrackInfoList().toList();
        if (!_disposed && !_queueStateController.isClosed) {
          _queueStateController.add(_queueState);
        }
        if (!_disposed && !_queueUpdatedController.isClosed) {
          _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
        }
      }
      return;
    } else if (type == 'Error') {
      final rawPayload = JsonReader.asMapOrNull(msg['payload']);
      final err = LuminaError.tryParseJson(rawPayload);
      if (err != null) {
        _emitError(err);
      }
      return;
    } else if (type == 'PlaybackStateChanged') {
      final payload = msg['payload'] as Map<String, dynamic>? ?? const {};
      final msgEpoch = PlaybackState.parsePlaybackEpoch(payload);
      if (_activeEpoch > 0 && msgEpoch < _activeEpoch) {
        return;
      }
      final effectiveEpoch = msgEpoch > 0 ? msgEpoch : _activeEpoch;
      final status = _serverParsePlaybackStatus(payload['status']?.toString());
      final posMs = (payload['position_ms'] as num?)?.toInt() ?? 0;
      final durMs = (payload['duration_ms'] as num?)?.toInt() ?? 0;
      final seekEpoch =
          (payload['seek_epoch'] as num?)?.toInt() ?? _state.seekEpoch;
      final isSeeking = payload['is_seeking'] == true;
      final deviceLost = payload['device_lost'] == true;
      final lastErr = payload['last_error']?.toString();
      final clockSrc = payload['clock_source']?.toString() ?? _state.clockSource;
      final swapGen =
          (payload['swap_generation'] as num?)?.toInt() ??
          (payload['swapGeneration'] as num?)?.toInt() ??
          _state.swapGeneration;

      final hydratedTrack = _serverHydrateTrackFromPayload(
        payload,
        queue: _queue,
        currentTrack: _state.track,
        fallbackDurationMs: durMs,
      );
      final swapIncremented =
          swapGen > _lastObservedSwapGeneration && swapGen > 0;
      final trackIdChanged =
          hydratedTrack != null &&
          !_serverTracksReferToSame(_state.track, hydratedTrack);
      final trackChanged = swapIncremented || trackIdChanged;
      final hadPreviousTrack = _state.track != null;
      if (swapGen != _lastObservedSwapGeneration) {
        _lastObservedSwapGeneration = swapGen;
      }

      final nextPos = (hadPreviousTrack && trackChanged)
          ? Duration.zero
          : Duration(milliseconds: posMs < 0 ? 0 : posMs);

      if (trackChanged) {
        _currentLyrics = const [];
        if (hydratedTrack != null && status == PlaybackStatus.playing) {
          unawaited(_refreshLyricsForTrack(hydratedTrack));
        }
      }

      _state = _state.copyWith(
        status: status,
        track: hydratedTrack,
        position: nextPos,
        seekEpoch: seekEpoch,
        isSeeking: isSeeking,
        deviceLost: deviceLost,
        lastError: lastErr,
        clearLastError: lastErr == null || lastErr.isEmpty,
        clockSource: clockSrc,
        swapGeneration: swapGen,
        playbackEpoch: effectiveEpoch,
      );
      if (!_stateController.isClosed) _stateController.add(_state);
      if (!_positionController.isClosed) {
        _positionController.add(_state.position);
      }
    } else if (type == 'LibraryReloaded' || type == 'library_reloaded') {
      unawaited(
        _scheduleReloadTracksFromServer().whenComplete(() {
          if (!_disposed && !_libraryReloadedController.isClosed) {
            _libraryReloadedController.add(null);
          }
        }),
      );
      return;
    } else if (type == 'event') {
      _handleWsCustomEvent(msg);
    } else if (type == 'SignalPathUpdated') {
      final payload = msg['payload'] as Map<String, dynamic>? ?? const {};
      _signalPath = _parseSignalPath(payload);
      if (!_signalPathController.isClosed) {
        _signalPathController.add(_signalPath);
      }
    } else if (type == 'state_changed' && msg.containsKey('volume')) {
      final vol = (msg['volume'] as num?)?.toDouble();
      if (vol != null) {
        _state = _state.copyWith(volume: vol, isMuted: vol == 0.0);
        if (!_stateController.isClosed) _stateController.add(_state);
      }
    }
  }

  void _handleWsCustomEvent(Map<String, dynamic> msg) {
    final eventName = msg['event']?.toString();
    final rawPayload = msg['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : const <String, dynamic>{};
    if (eventName == 'track_changed') {
      final msgEpoch = PlaybackState.parsePlaybackEpoch(payload);
      if (_activeEpoch > 0 && msgEpoch < _activeEpoch) {
        return;
      }
      final effectiveEpoch = msgEpoch > 0 ? msgEpoch : _activeEpoch;
      final swapGen =
          (payload['swap_generation'] as num?)?.toInt() ??
          (payload['swapGeneration'] as num?)?.toInt() ??
          _state.swapGeneration;
      final durMs = (payload['duration_ms'] as num?)?.toInt() ?? 0;
      final hydratedTrack = _serverHydrateTrackFromPayload(
        payload,
        queue: _queue,
        currentTrack: _state.track,
        fallbackDurationMs: durMs,
      );
      final swapIncremented =
          swapGen > _lastObservedSwapGeneration && swapGen > 0;
      final trackIdChanged =
          hydratedTrack != null &&
          !_serverTracksReferToSame(_state.track, hydratedTrack);
      final trackChanged = swapIncremented || trackIdChanged;
      if (swapGen != _lastObservedSwapGeneration) {
        _lastObservedSwapGeneration = swapGen;
      }
      final statusStr = _serverNonEmptyString(payload['status']);
      final nextStatus = statusStr != null
          ? _serverParsePlaybackStatus(statusStr)
          : (_state.status == PlaybackStatus.paused
              ? PlaybackStatus.paused
              : PlaybackStatus.playing);

      if (trackChanged) {
        _currentLyrics = const [];
        if (hydratedTrack != null && nextStatus == PlaybackStatus.playing) {
          unawaited(_refreshLyricsForTrack(hydratedTrack));
        }
      }
      _state = _state.copyWith(
        status: nextStatus,
        track: hydratedTrack,
        position: Duration.zero,
        swapGeneration: swapGen,
        playbackEpoch: effectiveEpoch,
        clearLastError: true,
      );
      _tracker.updateActiveDeviceState(_state);
      if (!_stateController.isClosed) _stateController.add(_state);
      if (!_positionController.isClosed) {
        _positionController.add(Duration.zero);
      }
    } else if (eventName == 'queue_updated') {
      final msgEpoch = PlaybackState.parsePlaybackEpoch(payload);
      if (_activeEpoch > 0 && msgEpoch < _activeEpoch) {
        return;
      }
      final rawQueue = payload['queue'] ?? payload['tracks'];
      if (rawQueue is List) {
        _queue = rawQueue
            .whereType<Map>()
            .map(
              (item) => _serverParseTrackFromMap(
                Map<String, dynamic>.from(item),
              ),
            )
            .toList();
      }
      final swapGen =
          (payload['swap_generation'] as num?)?.toInt() ??
          (payload['swapGeneration'] as num?)?.toInt() ??
          _state.swapGeneration;
      if (swapGen > _lastObservedSwapGeneration) {
        _lastObservedSwapGeneration = swapGen;
      }
      final hydrated = _serverHydrateTrackFromPayload(
        payload,
        queue: _queue,
        currentTrack: _state.track,
      );
      final nextTrack =
          (hydrated != null && _serverTracksReferToSame(_state.track, hydrated))
              ? hydrated
              : _state.track;
      _state = _state.copyWith(
        track: nextTrack,
        swapGeneration: swapGen,
        playbackEpoch: msgEpoch > 0 ? msgEpoch : _activeEpoch,
      );
      if (!_stateController.isClosed) _stateController.add(_state);
    } else if (eventName == 'library.scan_progress') {
      try {
        final progress = ScanProgressEvent.fromJson(payload);
        if (progress.state == ScanLifecycleState.completed) {
          unawaited(
            _scheduleReloadTracksFromServer(scanId: progress.scanId)
                .whenComplete(() {
                  if (!_disposed && !_scanProgressController.isClosed) {
                    _scanProgressController.add(progress);
                  }
                }),
          );
          return;
        }
        if (!_scanProgressController.isClosed) {
          _scanProgressController.add(progress);
        }
      } catch (_) {}
    } else if (eventName == 'library_reloaded' ||
        eventName == 'LibraryReloaded' ||
        eventName == 'library.reloaded') {
      unawaited(
        _scheduleReloadTracksFromServer().whenComplete(() {
          if (!_disposed && !_libraryReloadedController.isClosed) {
            _libraryReloadedController.add(null);
          }
        }),
      );
    }
  }

  SignalPath _parseSignalPath(Map<String, dynamic> json) {
    SignalQuality parseQ(String? raw) => switch (raw?.toLowerCase()) {
          'lossless' => SignalQuality.lossless,
          'enhanced' => SignalQuality.enhanced,
          _ => SignalQuality.highQuality,
        };
    final qStr =
        json['quality']?.toString() ?? json['overall_quality']?.toString();
    final q = parseQ(qStr);
    final rawNodes = json['nodes'] as List<dynamic>? ?? const [];
    final nodes = rawNodes.whereType<Map<String, dynamic>>().map((n) {
      final stage = n['stage']?.toString() ?? 'Stage';
      return SignalPathNode(
        title: stage,
        subtitle: stage,
        detail: n['detail']?.toString() ?? '',
        quality: parseQ(n['quality']?.toString()),
      );
    }).toList();
    return SignalPath(
      overallQuality: q,
      description: q.description,
      nodes: nodes,
      dspBypassed: q == SignalQuality.lossless,
    );
  }
}
