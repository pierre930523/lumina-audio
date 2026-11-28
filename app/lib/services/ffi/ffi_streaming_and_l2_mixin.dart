part of '../ffi_audio_service.dart';

mixin _FfiStreamingAndL2Mixin on _FfiAudioServiceBase {
  /// Attaches [StreamingManager] to Rust's Phase 3 FFI streaming bridge:
  /// - registers `NativeCallable.listener` for HTTP 403/410 URL refreshes
  /// - registers `NativeCallable.listener` for `NetworkMonitor` epoch updates
  /// - subscribes to `AuthRequired` events to cancel Rust playback/downloads &
  ///   clear persisted SQLite L1 cache rows for that provider.
  void attachStreamingManager(StreamingManager manager) {
    if (_disposed) return;
    if (identical(_attachedStreamingManager, manager)) return;
    detachStreamingManager();

    _attachedStreamingManager = manager;
    manager.onCatalogSynced = (providerId, catalog) async {
      await ingestExternalCatalog(
        ExternalCatalogIngestBatch.fromStreamingCatalog(providerId, catalog),
      );
    };
    _authRequiredListener = (String providerId, String reason) {
      cancelStreamingProvider(providerId);
    };
    manager.addAuthRequiredListener(_authRequiredListener!);

    if (!isNativeBound) return;

    final epochFn = _networkGetEpochFn;
    if (epochFn != null) {
      try {
        manager.handleNetworkEpochChanged(epochFn());
      } catch (_) {}
    }

    final setRefreshCb = _streamSetRefreshCbFn;
    if (setRefreshCb != null) {
      try {
        final callable =
            ffi.NativeCallable<_LuminaStreamRefreshCbNative>.listener(
          _onNativeStreamRefreshRequest,
        );
        _streamRefreshCallable = callable;
        setRefreshCb(callable.nativeFunction);
      } catch (_) {
        _streamRefreshCallable?.close();
        _streamRefreshCallable = null;
      }
    }

    final setEpochCb = _networkSetEpochCbFn;
    if (setEpochCb != null) {
      try {
        final callable =
            ffi.NativeCallable<_LuminaNetworkEpochCbNative>.listener(
          _onNativeNetworkEpochChanged,
        );
        _networkEpochCallable = callable;
        setEpochCb(callable.nativeFunction);
      } catch (_) {
        _networkEpochCallable?.close();
        _networkEpochCallable = null;
      }
    }
  }

  /// Unregisters all Rust Phase 3 FFI streaming callbacks, closes
  /// `NativeCallable` handles, and detaches the [StreamingManager] listener.
  void detachStreamingManager() {
    final manager = _attachedStreamingManager;
    final listener = _authRequiredListener;
    if (manager != null) {
      if (listener != null) {
        manager.removeAuthRequiredListener(listener);
      }
      manager.onCatalogSynced = null;
    }
    _attachedStreamingManager = null;
    _authRequiredListener = null;
    _lastDispatchedAuthErrorKey = null;

    if (isNativeBound) {
      try {
        _streamSetRefreshCbFn?.call(ffi.nullptr);
      } catch (_) {}
      try {
        _networkSetEpochCbFn?.call(ffi.nullptr);
      } catch (_) {}
    }

    _streamRefreshCallable?.close();
    _streamRefreshCallable = null;
    _networkEpochCallable?.close();
    _networkEpochCallable = null;
  }

  /// Cancels active Rust streaming playback/refreshes and clears SQLite L1
  /// cache entries for [providerId].
  void cancelStreamingProvider(String providerId) {
    final trimmed = providerId.trim();
    if (trimmed.isEmpty || !isNativeBound) return;
    final cancelFn = _streamingCancelProviderFn;
    if (cancelFn != null) {
      try {
        _withNativeUtf8(trimmed, cancelFn);
      } catch (_) {}
    }
    final clearL1Fn = _l1CacheClearProviderFn;
    if (clearL1Fn != null) {
      try {
        _withNativeUtf8(trimmed, clearL1Fn);
      } catch (_) {}
    }
  }

  void _onNativeStreamRefreshRequest(
    int requestId,
    ffi.Pointer<ffi.Uint8> requestJsonPtr,
  ) {
    // Ownership contract (streaming_bridge.rs): ALWAYS free requestJsonPtr via
    // lumina_string_free inside _takeRustString before any early return/await.
    String? rawJson;
    try {
      rawJson = _takeRustString(requestJsonPtr);
    } catch (_) {
      rawJson = null;
    }

    if (_disposed) {
      _completeNativeStreamRefresh(
        requestId,
        jsonEncode(const <String, dynamic>{'status': 'cancelled'}),
      );
      return;
    }

    if (rawJson == null || rawJson.trim().isEmpty) {
      _completeNativeStreamRefresh(
        requestId,
        jsonEncode(const <String, dynamic>{
          'status': 'error',
          'message': 'Empty stream refresh request payload',
        }),
      );
      return;
    }

    unawaited(_dispatchNativeStreamRefresh(requestId, rawJson));
  }

  Future<void> _dispatchNativeStreamRefresh(
    int requestId,
    String requestJson,
  ) async {
    final replyJson = await handleStreamRefreshRequestJson(requestJson);
    _completeNativeStreamRefresh(requestId, replyJson);
  }

  void _completeNativeStreamRefresh(int requestId, String replyJson) {
    final completeFn = _streamCompleteRefreshFn;
    if (completeFn == null || !isNativeBound || requestId <= 0) return;
    try {
      _withNativeUtf8(replyJson, (ptr) => completeFn(requestId, ptr));
    } catch (_) {}
  }

  void _onNativeNetworkEpochChanged(int epoch) {
    if (_disposed) return;
    _attachedStreamingManager?.handleNetworkEpochChanged(epoch);
  }

  @override
  void _attachRemoteScanProgress(ServerAudioService remote) {
    _detachRemoteClientStreams();
    _remoteScanProgressSub = remote.scanProgressStream.listen((ev) {
      if (!_disposed && !_scanProgressController.isClosed) {
        _scanProgressController.add(ev);
      }
    });
    _remoteLibraryReloadedSub = remote.libraryReloadedStream.listen((_) {
      if (!_disposed && !_libraryReloadedController.isClosed) {
        _libraryReloadedController.add(null);
      }
    });
    _remoteStateSub = remote.stateStream.listen((st) {
      if (_disposed) return;
      _state = st;
      if (!_stateController.isClosed) _stateController.add(st);
    });
    _remoteSignalPathSub = remote.signalPathStream.listen((sp) {
      if (_disposed) return;
      _signalPath = sp;
      if (!_signalPathController.isClosed) _signalPathController.add(sp);
    });
    _remotePositionSub = remote.positionStream.listen((pos) {
      if (!_disposed && !_positionController.isClosed) {
        _positionController.add(pos);
      }
    });
    _remoteQueueStateSub = remote.queueStateStream.listen((qs) {
      if (!_disposed && !_queueStateController.isClosed) {
        _queueStateController.add(qs);
      }
    });
    _remoteConnectionStatusSub = remote.connectionStatusStream.listen((cs) {
      if (!_disposed && !_connectionStatusController.isClosed) {
        _connectionStatusController.add(cs);
      }
    });
    _remoteErrorSub = remote.errorStream.listen((err) {
      if (!_disposed && !_errorController.isClosed) {
        _errorController.add(err);
      }
    });
  }

  @override
  void _detachRemoteClientStreams() {
    _remoteScanProgressSub?.cancel();
    _remoteScanProgressSub = null;
    _remoteLibraryReloadedSub?.cancel();
    _remoteLibraryReloadedSub = null;
    _remoteStateSub?.cancel();
    _remoteStateSub = null;
    _remoteSignalPathSub?.cancel();
    _remoteSignalPathSub = null;
    _remotePositionSub?.cancel();
    _remotePositionSub = null;
    _remoteQueueStateSub?.cancel();
    _remoteQueueStateSub = null;
    _remoteConnectionStatusSub?.cancel();
    _remoteConnectionStatusSub = null;
    _remoteErrorSub?.cancel();
    _remoteErrorSub = null;
  }

  /// Pure testable JSON handler bridging Rust `StreamRefreshRequest` JSON to
  /// `StreamingManager.refreshAfter403(...)` and encoding the exact reply JSON
  /// schema expected by `core-ffi/src/streaming_bridge.rs`.
  @override
  Future<String> handleStreamRefreshRequestJson(String requestJson) async {
    final manager = _attachedStreamingManager;
    if (manager == null) {
      return jsonEncode(const <String, dynamic>{
        'status': 'error',
        'message': 'StreamingManager not attached',
      });
    }

    try {
      final decoded = jsonDecode(requestJson);
      if (decoded is! Map) {
        return jsonEncode(const <String, dynamic>{
          'status': 'error',
          'message': 'Stream refresh request JSON must be an object',
        });
      }

      var providerId = decoded['provider_id']?.toString().trim() ?? '';
      final trackId = decoded['track_id']?.toString().trim() ?? '';
      final qualityKey = decoded['quality_key']?.toString().trim();
      final failedUrl = decoded['failed_url']?.toString() ?? '';
      if (providerId.isEmpty || trackId.isEmpty) {
        return jsonEncode(const <String, dynamic>{
          'status': 'error',
          'message': 'Stream refresh request missing provider_id or track_id',
        });
      }
      if (providerId.toLowerCase() == 'podcast') {
        providerId = trackId.startsWith('http://') ||
                trackId.startsWith('https://')
            ? 'podcast_rss'
            : 'youtube_music';
      }

      final key = StreamKey(
        providerId,
        trackId,
        (qualityKey != null && qualityKey.isNotEmpty) ? qualityKey : 'default',
      );
      final expectedContentLength =
          (decoded['expected_content_length'] as num?)?.toInt();
      final expectedMimeType = decoded['expected_mime_type']?.toString();
      final expectedKind = decoded['expected_kind']?.toString();
      final allowFormatChange =
          decoded['is_initial_probe'] == true ||
          decoded['allow_format_change'] == true;

      final outcome = await manager.refreshAfter403(
        key,
        failedUrl: failedUrl,
        expectedContentLength: expectedContentLength,
        expectedMimeType: expectedMimeType,
        expectedStreamKind: expectedKind,
        allowFormatChange: allowFormatChange,
      );

      return switch (outcome) {
        RefreshAfter403Updated(:final spec) => jsonEncode(<String, dynamic>{
            'status': 'refreshed',
            'spec': spec.toJson(),
          }),
        RefreshAfter403FormatChanged(:final spec, :final reason) => jsonEncode(
            <String, dynamic>{
              'status': 'format_changed',
              'spec': spec.toJson(),
              'reason': reason,
            },
          ),
        RefreshAfter403AuthRequired(:final providerId, :final message) =>
          jsonEncode(<String, dynamic>{
            'status': 'auth_required',
            'provider_id': providerId,
            'message': message,
          }),
        RefreshAfter403Failed(:final isCancelled, :final message) =>
          isCancelled
              ? jsonEncode(const <String, dynamic>{'status': 'cancelled'})
              : jsonEncode(<String, dynamic>{
                  'status': 'error',
                  'message': message,
                }),
      };
    } catch (e) {
      return jsonEncode(<String, dynamic>{
        'status': 'error',
        'message': e.toString(),
      });
    }
  }

  /// Handles structured error codes polled from `lumina_playback_get_state_json`
  /// (`AUTH_REQUIRED`, `DEVICE_LOST`, `FORMAT_SWITCH_FAILED`), deduplicating
  /// `AUTH_REQUIRED` dispatches per error event so 200ms polling never spams.
  @override
  Future<void> handlePolledPlaybackStateError({
    required PlaybackStatus status,
    String? lastErrorCode,
    String? lastErrorProvider,
    String? lastError,
    int epoch = 0,
  }) async {
    if (status != PlaybackStatus.error) {
      if (status == PlaybackStatus.playing ||
          status == PlaybackStatus.loading ||
          status == PlaybackStatus.stopped) {
        _lastDispatchedAuthErrorKey = null;
      }
      return;
    }

    final code = lastErrorCode?.trim().toUpperCase() ?? '';
    final providerId = lastErrorProvider?.trim() ?? '';
    if (code != 'AUTH_REQUIRED' || providerId.isEmpty) {
      return;
    }

    final message = (lastError != null && lastError.trim().isNotEmpty)
        ? lastError.trim()
        : '授權已失效（AUTH_REQUIRED），請重新登入';
    final dedupKey = '$epoch|$providerId|$code|$message';
    if (_lastDispatchedAuthErrorKey == dedupKey) {
      return;
    }
    _lastDispatchedAuthErrorKey = dedupKey;

    final manager = _attachedStreamingManager;
    if (manager != null &&
        !manager.authManager.isGuestPlaybackCapable(providerId)) {
      await manager.authManager.handleUnauthorized(
        providerId,
        message,
        alreadyRetried: true,
      );
    }
  }

  /// Triggers non-blocking HTTP/2 TLS pool warmup on Rust `core-audio`'s
  /// shared `reqwest` client when native FFI is bound.
  bool triggerStreamingHttp2Warmup() {
    final fn = _streamingWarmupH2Fn;
    if (fn == null) return false;
    try {
      return fn() == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  VoidCallback? get streamingHttp2WarmupCallback => triggerStreamingHttp2Warmup;

  @override
  void attachStreamingHooks(StreamingManager manager) =>
      attachStreamingManager(manager);

  @override
  void detachStreamingHooks() => detachStreamingManager();

  /// Initializes the Rust L2 head cache directory and watermark bounds.
  Future<bool> initL2Cache({
    String? rootDir,
    int highWatermarkBytes = 1024 * 1024 * 1024,
    int lowWatermarkBytes = 800 * 1024 * 1024,
  }) async {
    if (!isNativeBound || _l2CacheInitFn == null) return false;
    final dir = _resolveFfiL2CacheRootDir(rootDirOverride: rootDir);
    try {
      return _withNativeUtf8(
            dir,
            (ptr) => _l2CacheInitFn!(
              ptr,
              highWatermarkBytes,
              lowWatermarkBytes,
            ),
          ) ==
          0;
    } catch (_) {
      return false;
    }
  }

  /// Queries total disk bytes currently occupied by the L2 head cache.
  Future<int?> getL2CacheTotalBytes() async {
    if (!isNativeBound ||
        _l2CacheTotalBytesFn == null ||
        _bytesAllocFn == null ||
        _bytesFreeFn == null) {
      return null;
    }
    final outPtr = _bytesAllocFn!(ffi.sizeOf<ffi.Uint64>()).cast<ffi.Uint64>();
    try {
      outPtr.value = 0;
      final rc = _l2CacheTotalBytesFn!(outPtr);
      if (rc == 0) {
        return outPtr.value;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      _bytesFreeFn!(outPtr.cast<ffi.Uint8>(), ffi.sizeOf<ffi.Uint64>());
    }
  }

  /// Triggers an immediate LRU watermark eviction pass on the Rust L2 cache.
  Future<bool> evictL2CacheNow() async {
    if (!isNativeBound || _l2CacheEvictNowFn == null) return false;
    try {
      return _l2CacheEvictNowFn!() == 0;
    } catch (_) {
      return false;
    }
  }

  /// Flushes debounced L2 access timestamps to SQLite in a single transaction.
  Future<bool> flushL2CacheAccess() async {
    if (!isNativeBound || _l2CacheFlushAccessFn == null) return false;
    try {
      return _l2CacheFlushAccessFn!() == 0;
    } catch (_) {
      return false;
    }
  }

  /// Sweeps orphaned L2 cache files/rows left behind by interrupted writes.
  Future<bool> runL2CacheOrphanSweep() async {
    if (!isNativeBound || _l2CacheRunOrphanSweepFn == null) return false;
    try {
      return _l2CacheRunOrphanSweepFn!() == 0;
    } catch (_) {
      return false;
    }
  }
}
