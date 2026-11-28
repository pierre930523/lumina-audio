part of '../ffi_audio_service.dart';

abstract class _FfiAudioServiceBase
    implements
        AudioService,
        DualDeckAudioService,
        LibraryTracksAudioService,
        EpochAwareSeekAudioService {
  static const int _libraryTracksReloadLimit = 10000;
  final MockAudioService _delegate;
  final PerDevicePlaybackTracker _tracker = PerDevicePlaybackTracker();
  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<SignalPath> _signalPathController =
      StreamController<SignalPath>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<ScanProgressEvent> _scanProgressController =
      StreamController<ScanProgressEvent>.broadcast();
  final StreamController<void> _libraryReloadedController =
      StreamController<void>.broadcast();

  ffi.DynamicLibrary? _dylib;
  String? _dylibPath;
  _FfiWorkerClient? _readWorker;
  _FfiWorkerClient? _writeWorker;
  Future<void>? _reloadTracksInFlight;
  int _lyricsLoadSeq = 0;
  final Set<String> _reloadedScanIds = <String>{};
  final Completer<void> _dbReadyCompleter = Completer<void>();
  _LuminaVoidIntDart? _initFn;
  _LuminaVoidIntDart? _initHeadlessFn;
  _LuminaVoidIntDart? _shutdownFn;
  _LuminaBytesAllocDart? _bytesAllocFn;
  _LuminaBytesFreeDart? _bytesFreeFn;
  _LuminaStringFreeDart? _stringFreeFn;
  _LuminaStrIntDart? _libInitFn;
  _LuminaLimitPtrDart? _libGetTracksFn;
  _LuminaStrIntDart? _playFn;
  _LuminaVoidIntDart? _pauseFn;
  _LuminaVoidIntDart? _stopFn;
  _LuminaSeekDart? _seekFn;
  _LuminaSetVolumeDart? _setVolumeFn;
  _LuminaVoidIntDart? _getStateFn;
  _LuminaVoidU64Dart? _getPositionFn;
  _LuminaVoidU64Dart? _getDurationFn;
  _LuminaVoidPtrDart? _signalPathGetFn;
  _LuminaVoidIntDart? _toggleBypassFn;
  _LuminaVoidPtrDart? _lastErrorMsgFn;

  // Extended M7c–M10 optional C-ABI bindings
  _LuminaLimitPtrDart? _getAlbumsFn;
  _LuminaStrPtrDart? _getAlbumDetailFn;
  _LuminaStrPtrDart? _getArtistDetailFn;
  _LuminaStrPtrDart? _enrichCreditsFn;
  _LuminaVoidPtrDart? _deduplicateFn;
  _LuminaVoidPtrDart? _profileListFn;
  _LuminaStrPtrDart? _profileCreateFn;
  _LuminaStrStrIntDart? _profileUpdateFn;
  _LuminaStrIntDart? _profileDeleteFn;
  _LuminaStrIntDart? _profileSwitchFn;
  _LuminaVoidPtrDart? _audioListDevicesFn;
  _LuminaStrI32IntDart? _audioSelectDeviceFn;
  _LuminaVoidPtrDart? _audioGetOutputInfoFn;
  _LuminaVoidPtrDart? _audioListDeviceCapsFn;
  _LuminaIntToIntDart? _audioSetStrictModeFn;
  _LuminaIntToIntDart? _audioSetDsdModeFn;
  _LuminaU32ToIntDart? _audioSetBufferFramesFn;
  _LuminaVoidPtrDart? _dspGetConfigFn;
  _LuminaStrIntDart? _dspSetConfigFn;
  _LuminaStrPtrDart? _dspImportAutoeqFn;
  _LuminaStrStrIntDart? _providerConfigureFn;
  _LuminaStrPtrDart? _providerSyncFn;
  _LuminaVoidPtrDart? _tidalPkceStartFn;
  _LuminaStrPtrDart? _tidalPkceCompleteFn;
  _LuminaVoidPtrDart? _zoneListFn;
  _LuminaVoidPtrDart? _zoneDiscoverFn;
  _LuminaStrIntDart? _zoneGroupFn;
  _LuminaStrFloatIntDart? _zoneSetVolumeFn;
  _LuminaStrPtrDart? _zoneSyncStatusFn;
  _LuminaServerStartDart? _serverStartFn;
  _LuminaVoidU16Dart? _serverGetPortFn;

  // Features F11-F13 FFI function pointers
  _LuminaVoidIntDart? _playbackResumeFn;
  _LuminaVoidPtrDart? _playbackGetStateJsonFn;
  _LuminaVoidIntDart? _playbackReconnectDeviceFn;
  _LuminaPlayAsyncDart? _playbackPlayAsyncFn;
  _LuminaCancelPendingDart? _playbackCancelPendingFn;
  _LuminaVoidU64Dart? _playbackGetActiveRequestIdFn;
  _LuminaArtworkGetDart? _artworkGetFn;
  _LuminaStrStrIntDart? _artworkSetUserCoverFn;
  _LuminaStrIntDart? _artworkClearUserCoverFn;
  _LuminaLibraryRescanTagsDart? _libraryRescanTagsFn;
  _LuminaStrPtrDart? _lyricsGetFn;
  _LuminaStrStrIntDart? _lyricsSetUserFileFn;
  _LuminaStrIntDart? _lyricsClearUserFileFn;

  // Real-time Visualizer FFI function pointers
  LuminaVisualizerSetEnabledDart? _visualizerSetEnabledFn;
  LuminaVisualizerIsEnabledDart? _visualizerIsEnabledFn;
  LuminaVisualizerGetBandsDart? _visualizerGetBandsFn;

  // Phase 2 Streaming Warmup FFI function pointer
  _LuminaVoidIntDart? _streamingWarmupH2Fn;

  // Phase 3 Streaming Refresh, Network Epoch & Auth Cancellation FFI pointers
  _LuminaStreamSetRefreshCbDart? _streamSetRefreshCbFn;
  _LuminaStreamCompleteRefreshDart? _streamCompleteRefreshFn;
  _LuminaVoidU64Dart? _networkGetEpochFn;
  _LuminaNetworkSetEpochCbDart? _networkSetEpochCbFn;
  _LuminaStrIntDart? _streamingCancelProviderFn;
  _LuminaStrIntDart? _l1CacheClearProviderFn;

  // Phase 4 Dual-Deck & L2 Cache FFI pointers (optional / null-safe lookup)
  _LuminaPlayAsyncDart? _playbackPrepareStandbyAsyncFn;
  _LuminaVoidIntDart? _playbackSkipToStandbyFn;
  _LuminaSkipToStandbyAtEpochDart? _playbackSkipToStandbyAtEpochFn;
  _LuminaSeekAtEpochDart? _playbackSeekAtEpochFn;
  _LuminaL2CacheInitDart? _l2CacheInitFn;
  _LuminaL2TotalBytesDart? _l2CacheTotalBytesFn;
  _LuminaVoidIntDart? _l2CacheEvictNowFn;
  _LuminaVoidIntDart? _l2CacheFlushAccessFn;
  _LuminaVoidIntDart? _l2CacheRunOrphanSweepFn;

  // Layer 1 Ingestion optional FFI handles
  _LuminaSetScanProgressCbDart? _libSetScanProgressCbFn;
  _LuminaLibraryRescanTagsDart? _libScanStartFn;
  _LuminaLibraryRescanTagsDart? _libRescanStartFn;
  _LuminaLibraryRescanTagsDart? _libForceRebuildStartFn;
  _LuminaWatchAddDart? _libWatchAddFn;
  _LuminaStrIntDart? _libWatchRemoveFn;
  _LuminaVoidPtrDart? _libWatchListFn;
  _LuminaIntToPtrDart? _libGetSkippedFilesFn;
  _LuminaStrIntDart? _libDismissSkippedFileFn;
  _LuminaStrPtrDart? _libRetrySkippedFileFn;
  _LuminaStr4IntDart? _libSetMetadataOverrideFn;
  _LuminaStr3IntDart? _libClearMetadataOverrideFn;
  _LuminaStr2PtrDart? _libGetMetadataOverridesFn;
  _LuminaStrPtrDart? _libIngestExternalCatalogFn;
  _LuminaVoidPtrDart? _providerListFn;

  // Library Foundation Step 1 optional FFI handles
  _LuminaVoidPtrDart? _settingsGetDefaultMetaPolicyFn;
  _LuminaStrIntDart? _settingsSetDefaultMetaPolicyFn;
  _LuminaStr3IntDart? _libSetEntityMetaPolicyFn;
  _LuminaStr3IntDart? _libSetEntityUserEditsFn;
  _LuminaStrStrIntDart? _libRevertEntityToFileMetaFn;
  _LuminaVoidPtrDart? _libRescanAllSkippedFilesFn;
  _LuminaVoidPtrDart? _libPreviewCleanupFn;
  _LuminaStrPtrDart? _libExecuteCleanupFn;

  void _bindLibraryMaintenanceSymbols(ffi.DynamicLibrary dylib);
  void _bindAlbumGroupingSymbols(ffi.DynamicLibrary dylib);
  void _bindFocusTagsFoldersSymbols(ffi.DynamicLibrary dylib);
  void _bindStep4Symbols(ffi.DynamicLibrary dylib);
  void _bindStep5Symbols(ffi.DynamicLibrary dylib);

  // Canonical cross-mode protocol optional FFI handles (Wave 2A)
  _LuminaStrIntDart? _playbackDispatchCommandFn;
  _LuminaVoidPtrDart? _protocolSnapshotJsonFn;
  _LuminaVoidPtrDart? _queueGetStateJsonFn;
  _LuminaVoidPtrDart? _lastErrorJsonFn;

  ffi.NativeCallable<_LuminaScanProgressCbNative>? _scanProgressCallable;
  StreamSubscription<ScanProgressEvent>? _delegateScanProgressSub;
  StreamSubscription<void>? _delegateLibraryReloadedSub;
  StreamSubscription<ScanProgressEvent>? _remoteScanProgressSub;
  StreamSubscription<void>? _remoteLibraryReloadedSub;
  StreamSubscription<PlaybackState>? _remoteStateSub;
  StreamSubscription<SignalPath>? _remoteSignalPathSub;
  StreamSubscription<Duration>? _remotePositionSub;
  StreamSubscription<QueueState>? _remoteQueueStateSub;
  StreamSubscription<ConnectionStatus>? _remoteConnectionStatusSub;
  StreamSubscription<LuminaError>? _remoteErrorSub;

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
  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffle = false;
  int _queueEpoch = 0;
  FfiPlaybackBackend? _protocolBackend;
  PlaybackController? _protocolController;

  StreamingManager? _attachedStreamingManager;
  ProviderAuthRequiredCallback? _authRequiredListener;
  ffi.NativeCallable<_LuminaStreamRefreshCbNative>? _streamRefreshCallable;
  ffi.NativeCallable<_LuminaNetworkEpochCbNative>? _networkEpochCallable;
  String? _lastDispatchedAuthErrorKey;
  DualDeckStatus? _lastDualDeckSnapshot;
  TrackInfo? _pendingStandbyTrack;
  int _lastObservedSwapGeneration = 0;
  final Map<String, TrackInfo> _standbyTracksById = <String, TrackInfo>{};

  VisualizerLifecycleCoordinator? _visualizerCoordinator;
  bool _visualizerSettingEnabled = true;
  bool _isNowPlayingVisible = false;
  bool _isWindowMinimized = false;

  List<LyricLine> _currentLyrics = const [];
  ServerAudioService? _remoteClient;
  ConnectionMode _connectionMode = ConnectionMode.localOrUsbDac;

  late PlaybackState _state;
  late SignalPath _signalPath;
  List<TrackInfo> _queue = [];
  List<TrackInfo> _libraryTracks = const [];
  bool _hasLoadedLibraryTracks = false;
  int _currentIndex = 0;
  Timer? _positionTimer;
  String? _lastError;
  bool _isReroutingDevice = false;
  bool _hasRestoredSession = false;
  bool _needsLoadOnResume = false;
  bool _disposed = false;
  Duration? _pendingResumePosition;
  bool _strictBitPerfect = false;
  double _savedNormalVolume = 0.85;
  DsdOutputModeOption _dsdOutputMode = DsdOutputModeOption.auto;
  bool _systemOutputActive = true;
  int _preferredBufferFrames = 512;
  StreamingTrackHandler? _streamingTrackHandler;
  VoidCallback? _playbackInterruptHandler;
  bool _activeStreamIsLocalProxy = false;
  int _activeRequestId = 0;
  int _activeEpoch = 0;
  int _lastCancelledEpoch = 0;

  _FfiAudioServiceBase({MockAudioService? fallback})
      : _delegate = fallback ?? MockAudioService();

  bool get _isRemoteActive =>
      _remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac;

  R _withNativeUtf8<R>(String value, R Function(ffi.Pointer<ffi.Uint8>) fn) {
    final encoded = utf8.encode(value);
    final ptr = _bytesAllocFn!(encoded.length);
    try {
      final view = ptr.asTypedList(encoded.length + 1);
      view.setAll(0, encoded);
      view[encoded.length] = 0;
      return fn(ptr);
    } finally {
      _bytesFreeFn!(ptr, encoded.length);
    }
  }

  String? _takeRustString(ffi.Pointer<ffi.Uint8> ptr) =>
      _ffiDecodeAndFreeRustString(ptr, _stringFreeFn);

  void _rememberStandbyTrack(TrackInfo track) {
    if (track.id.isEmpty) return;
    _standbyTracksById.remove(track.id);
    while (_standbyTracksById.length >= 8) {
      _standbyTracksById.remove(_standbyTracksById.keys.first);
    }
    _standbyTracksById[track.id] = track;
  }

  Future<T?> _callReadWorker<T>(
    String op, [
    Map<String, Object?> args = const {},
  ]) async {
    if (!_dbReadyCompleter.isCompleted) {
      await _dbReadyCompleter.future;
    }
    final worker = _readWorker;
    if (worker == null || _disposed) return null;
    try {
      return await worker.call(op, args) as T?;
    } catch (_) {
      if (_disposed) return null;
      rethrow;
    }
  }

  Future<T?> _callWriteWorker<T>(
    String op, [
    Map<String, Object?> args = const {},
    bool waitDbReady = true,
  ]) async {
    if (waitDbReady && !_dbReadyCompleter.isCompleted) {
      await _dbReadyCompleter.future;
    }
    final worker = _writeWorker;
    if (worker == null || _disposed) return null;
    try {
      return await worker.call(op, args) as T?;
    } catch (_) {
      if (_disposed) return null;
      rethrow;
    }
  }

  void _emitState(PlaybackState nextState) {
    _state = nextState;
    _tracker.updateActiveDeviceState(_state, queueIndex: _currentIndex);
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
    if (!_positionController.isClosed) {
      _positionController.add(_state.position);
    }
    _visualizerCoordinator?.setPlaying(_state.status == PlaybackStatus.playing);
  }

  void _refreshSignalPath() {
    if (!isNativeBound) return;
    final raw = _takeRustString(_signalPathGetFn!());
    if (raw == null) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return;

    final overall = _ffiParseQuality(decoded['overall_quality']?.toString());
    final bypassed = decoded['dsp_bypassed'] == true;
    final rawNodes = decoded['nodes'] as List<dynamic>? ?? const [];
    final nodes = <SignalPathNode>[];
    for (final n in rawNodes) {
      if (n is Map<String, dynamic>) {
        final stage = n['stage']?.toString() ?? 'Stage';
        final detail = n['detail']?.toString() ?? '';
        final q = _ffiParseQuality(n['quality']?.toString());
        nodes.add(
          SignalPathNode(
            title: stage,
            subtitle: stage,
            detail: detail,
            quality: q,
          ),
        );
      }
    }

    _signalPath = SignalPath(
      overallQuality: overall,
      description: overall.description,
      nodes: nodes,
      dspBypassed: bypassed,
    );
    if (!_signalPathController.isClosed) {
      _signalPathController.add(_signalPath);
    }
  }

  void _loadLyricsForTrack(TrackInfo target) {
    _currentLyrics = const [];
    if (!isNativeBound) {
      _currentLyrics = _delegate.currentLyrics;
      return;
    }
    if (_lyricsGetFn == null) return;
    unawaited(_loadLyricsForTrackAsync(target));
  }

  Future<void> _loadLyricsForTrackAsync(TrackInfo target) async {
    if (!isNativeBound || _disposed || _lyricsGetFn == null) return;
    final seq = ++_lyricsLoadSeq;
    final targetPayload = jsonEncode({
      'track_id': target.id,
      'file_path': ?target.filePath,
    });
    final raw = await _callReadWorker<String>('get_lyrics', {
      'payload': targetPayload,
    });
    if (_disposed || seq != _lyricsLoadSeq) return;
    if (_state.track?.id != target.id) return;
    if (raw != null) {
      _currentLyrics = _ffiParseLyricsJson(raw);
      if (!_stateController.isClosed) {
        _stateController.add(_state);
      }
    }
  }

  void _updateDualDeckSnapshotFromJson(Map<String, dynamic> json) {
    if (_ffiHasDualDeckFields(json)) {
      _lastDualDeckSnapshot = DualDeckStatus.fromJson(json);
    }
  }

  void _applyReloadedTracksRaw(String? raw) {
    final parsed = _ffiParseTrackListJson(raw);
    _libraryTracks = List<TrackInfo>.unmodifiable(parsed);
    _hasLoadedLibraryTracks = true;
    final playable = parsed
        .where((t) => t.preference != -1)
        .toList(growable: true);
    if (parsed.isNotEmpty) {
      if (_hasRestoredSession && _state.track != null) {
        final active = _state.track!;
        final nextQueue = List<TrackInfo>.from(playable);
        final idx = PlaybackPersistenceService.findTrackIndex(nextQueue, active);
        if (idx >= 0) {
          final matched = nextQueue[idx].duration <= Duration.zero &&
                  active.duration > Duration.zero
              ? nextQueue[idx].copyWith(duration: active.duration)
              : nextQueue[idx];
          nextQueue[idx] = matched;
          _queue = nextQueue;
          _currentIndex = idx;
          _state = _state.copyWith(track: matched);
        } else {
          nextQueue.insert(0, active);
          _queue = nextQueue;
          _currentIndex = 0;
        }
      } else {
        _queue = playable;
        if (_queue.isNotEmpty) {
          if (_currentIndex >= _queue.length) _currentIndex = 0;
          _state = _state.copyWith(track: _queue[_currentIndex]);
        } else {
          _currentIndex = 0;
        }
      }
    }
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
  }

  void _reloadTracksFromNative() {
    if (!isNativeBound) return;
    final ptr = _libGetTracksFn!(_libraryTracksReloadLimit);
    final raw = _takeRustString(ptr);
    _applyReloadedTracksRaw(raw);
  }

  Future<void> _reloadTracksFromNativeAsync({String? scanId}) {
    if (!isNativeBound || _disposed) return Future<void>.value();
    final trimmedScanId = scanId?.trim() ?? '';
    if (trimmedScanId.isNotEmpty && _reloadedScanIds.contains(trimmedScanId)) {
      return _reloadTracksInFlight ?? Future<void>.value();
    }
    if (trimmedScanId.isNotEmpty) {
      if (_reloadedScanIds.length >= 64) {
        _reloadedScanIds.remove(_reloadedScanIds.first);
      }
      _reloadedScanIds.add(trimmedScanId);
    }
    final inFlight = _reloadTracksInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = () async {
      final raw = await _callReadWorker<String>(
        'get_tracks',
        const {'limit': _libraryTracksReloadLimit},
      );
      if (_disposed) return;
      _applyReloadedTracksRaw(raw);
    }().whenComplete(() {
      _reloadTracksInFlight = null;
    });
    _reloadTracksInFlight = future;
    return future;
  }

  void _startPositionTimer();
  Future<void> _playInternal({
    TrackInfo? track,
    String? streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  });
  void _attachRemoteScanProgress(ServerAudioService remote);
  void _detachRemoteClientStreams();
  Future<String> handleStreamRefreshRequestJson(String requestJson);
  Future<void> handlePolledPlaybackStateError({
    required PlaybackStatus status,
    String? lastErrorCode,
    String? lastErrorProvider,
    String? lastError,
    int epoch = 0,
  });
}
