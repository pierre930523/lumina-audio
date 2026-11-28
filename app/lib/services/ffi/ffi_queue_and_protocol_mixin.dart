part of '../ffi_audio_service.dart';

mixin _FfiQueueAndProtocolMixin on _FfiAudioServiceBase {
  @override
  QueueState get currentQueueState {
    if (_isRemoteActive) return _remoteClient!.currentQueueState;
    if (!isNativeBound) return _delegate.currentQueueState;
    final raw = _queueGetStateJsonFn != null
        ? _takeRustString(_queueGetStateJsonFn!())
        : null;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          return QueueState.fromJson(decoded);
        }
      } catch (_) {}
    }
    return QueueState(
      items: <QueueItem>[
        for (var i = 0; i < _queue.length; i++)
          QueueItem(
            itemId: 'ffi-$i-${_queue[i].id}',
            track: ProtocolTrackMetadata.fromTrackInfo(_queue[i]),
            isUserQueued: true,
          ),
      ],
      currentIndex:
          _queue.isEmpty ? null : _currentIndex.clamp(0, _queue.length - 1),
      repeatMode: _repeatMode,
      shuffle: _shuffle,
      queueEpoch: _queueEpoch,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  RepeatMode get repeatMode {
    if (_isRemoteActive) return _remoteClient!.repeatMode;
    return isNativeBound ? _repeatMode : _delegate.repeatMode;
  }

  @override
  bool get shuffle {
    if (_isRemoteActive) return _remoteClient!.shuffle;
    return isNativeBound ? _shuffle : _delegate.shuffle;
  }

  @override
  Future<void> setRepeatMode(RepeatMode mode) async {
    if (_isRemoteActive) {
      await _remoteClient!.setRepeatMode(mode);
      return;
    }
    if (!isNativeBound) {
      await _delegate.setRepeatMode(mode);
      return;
    }
    _repeatMode = mode;
    _queueEpoch++;
    if (_playbackDispatchCommandFn != null) {
      final cmdJson = jsonEncode(SetRepeatModeCommand(mode: mode).toJson());
      _withNativeUtf8(cmdJson, (ptr) => _playbackDispatchCommandFn!(ptr));
    }
    _emitState(_state.copyWith(repeatMode: mode));
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(currentQueueState);
    }
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    if (_isRemoteActive) {
      await _remoteClient!.setShuffle(enabled);
      return;
    }
    if (!isNativeBound) {
      await _delegate.setShuffle(enabled);
      return;
    }
    _shuffle = enabled;
    _queueEpoch++;
    if (_playbackDispatchCommandFn != null) {
      final cmdJson = jsonEncode(SetShuffleCommand(enabled: enabled).toJson());
      _withNativeUtf8(cmdJson, (ptr) => _playbackDispatchCommandFn!(ptr));
    }
    _emitState(_state.copyWith(shuffle: enabled));
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(currentQueueState);
    }
  }

  @override
  proto_backend.PlaybackBackend? get playbackBackend {
    _protocolBackend ??= FfiPlaybackBackend(
      audioService: this,
      nativeBridge: NativeProtocolBridge(
        isNativeBound: () => isNativeBound,
        dispatchCommandJson: _playbackDispatchCommandFn != null
            ? (cmdJson) => _withNativeUtf8(
                  cmdJson,
                  (ptr) => _playbackDispatchCommandFn!(ptr),
                )
            : null,
        getSnapshotJson: _protocolSnapshotJsonFn != null
            ? () => _takeRustString(_protocolSnapshotJsonFn!())
            : null,
        getQueueStateJson: _queueGetStateJsonFn != null
            ? () => _takeRustString(_queueGetStateJsonFn!())
            : null,
        getLastErrorJson: _lastErrorJsonFn != null
            ? () => _takeRustString(_lastErrorJsonFn!())
            : null,
      ),
    );
    return _protocolBackend;
  }

  @override
  PlaybackController? get playbackController {
    _protocolController ??= PlaybackController(backend: playbackBackend!);
    return _protocolController;
  }

  @override
  AutoplayController? get autoplayController => null;

  @override
  void Function(TrackInfo track)? get hoverPrefetchCallback => null;

  @override
  Future<void> get dbReadyFuture => _dbReadyCompleter.future;

  @override
  L1StreamCachePersistence? createL1CachePersistence() =>
      FfiL1StreamCachePersistence(
        libraryProvider: () => _dylib,
        waitDbReady: () => _dbReadyCompleter.future,
      );

  @override
  SidecarLifecycleBinder? createSidecarLifecycleBinder() =>
      FfiSidecarLifecycleBinder(libraryProvider: () => _dylib);
}
