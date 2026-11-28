import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../models/audio_format.dart';
import '../models/audio_output_info.dart';
import '../models/ingestion_models.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/protocol/lumina_error.dart';
import '../models/protocol/protocol_models.dart';
import '../models/recommendation_models.dart';
import '../models/signal_path.dart';
import '../models/stream_source_spec.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'mock_audio_service.dart';
import 'per_device_playback_tracker.dart';
import 'playback/ffi_playback_backend.dart';
import 'playback/playback_backend.dart' as proto_backend;
import 'playback/playback_controller.dart';
import 'playback_persistence_service.dart';
import 'platform_asset_opener.dart';
import 'server_audio_service.dart';
import 'streaming/auth_manager.dart';
import 'streaming/autoplay_controller.dart';
import 'streaming/l1_stream_cache.dart';
import 'streaming/playback_backend.dart';
import 'streaming/pot_sidecar_manager.dart';
import 'streaming/single_flight_resolver.dart';
import 'streaming/streaming_manager.dart';
import 'visualizer_lifecycle_coordinator.dart';

part 'ffi/ffi_typedefs.dart';
part 'ffi/ffi_worker_ops.dart';
part 'ffi/ffi_worker_album_ops.dart';
part 'ffi/ffi_worker_focus_ops.dart';
part 'ffi/ffi_worker_step4_ops.dart';
part 'ffi/ffi_worker_step5_ops.dart';
part 'ffi/ffi_worker_isolate.dart';
part 'ffi/ffi_path_helpers.dart';
part 'ffi/ffi_track_parsing_helpers.dart';
part 'ffi/ffi_service_base.dart';
part 'ffi/ffi_native_binding_mixin.dart';
part 'ffi/ffi_streaming_and_l2_mixin.dart';
part 'ffi/ffi_state_sync_mixin.dart';
part 'ffi/ffi_playback_mixin.dart';
part 'ffi/ffi_session_and_transport_mixin.dart';
part 'ffi/ffi_media_and_library_mixin.dart';
part 'ffi/ffi_devices_and_zones_mixin.dart';
part 'ffi/ffi_providers_and_output_mixin.dart';
part 'ffi/ffi_ingestion_mixin.dart';
part 'ffi/ffi_library_maintenance_mixin.dart';
part 'ffi/ffi_album_grouping_mixin.dart';
part 'ffi/ffi_focus_tags_folders_mixin.dart';
part 'ffi/ffi_step4_bindings.dart';
part 'ffi/ffi_step4_mixin.dart';
part 'ffi/ffi_step4_listen_later_mixin.dart';
part 'ffi/ffi_step5_bindings.dart';
part 'ffi/ffi_step5_mixin.dart';
part 'ffi/ffi_step5_backup_export_mixin.dart';
part 'ffi/ffi_track_actions_mixin.dart';
part 'ffi/ffi_queue_and_protocol_mixin.dart';

class FfiAudioService extends _FfiAudioServiceBase
    with
        _FfiNativeBindingMixin,
        _FfiStreamingAndL2Mixin,
        _FfiStateSyncMixin,
        _FfiPlaybackMixin,
        _FfiSessionAndTransportMixin,
        _FfiMediaAndLibraryMixin,
        _FfiDevicesAndZonesMixin,
        _FfiProvidersAndOutputMixin,
        _FfiIngestionMixin,
        _FfiLibraryMaintenanceMixin,
        _FfiAlbumGroupingMixin,
        _FfiFocusTagsFoldersMixin,
        _FfiStep4BindingsMixin,
        _FfiStep4Mixin,
        _FfiStep4ListenLaterMixin,
        _FfiStep5BindingsMixin,
        _FfiStep5Mixin,
        _FfiStep5BackupExportMixin,
        _FfiTrackActionsMixin,
        _FfiQueueAndProtocolMixin {
  FfiAudioService({
    super.fallback,
    bool headless = false,
    String? databasePath,
  }) {
    _state = _delegate.currentState;
    _signalPath = _delegate.currentSignalPath;
    _queue = List<TrackInfo>.from(_delegate.queue);
    _setupVisualizerCoordinator();
    _tryLoadNativeLibrary(headless: headless, databasePath: databasePath);
  }

  void _setupVisualizerCoordinator() {
    _visualizerCoordinator = VisualizerLifecycleCoordinator(
      enabled: _visualizerSettingEnabled,
      isPlaying: _state.status == PlaybackStatus.playing,
      isVisible: _isNowPlayingVisible,
      isMinimized: _isWindowMinimized,
      bridge: _FfiVisualizerEngineBridge(this),
    );
    _delegate.stateStream.listen((state) {
      if (!isNativeBound) {
        _visualizerCoordinator?.setPlaying(
          state.status == PlaybackStatus.playing,
        );
      }
    });
  }

  /// Resolves the SQLite library DB path (defaults to %LOCALAPPDATA%\LuminaAudio\lumina_desktop_library.db),
  /// migrating any legacy temp-directory DB on first run while keeping FLUTTER_TEST isolated.
  @visibleForTesting
  static String resolveDatabasePath({
    String? databasePathOverride,
    String? localAppDataOverride,
    String? tempDirOverride,
    bool? isFlutterTestOverride,
  }) =>
      _resolveFfiDatabasePath(
        databasePathOverride: databasePathOverride,
        localAppDataOverride: localAppDataOverride,
        tempDirOverride: tempDirOverride,
        isFlutterTestOverride: isFlutterTestOverride,
      );

  /// Resolves the persistent L2 audio head cache root directory alongside the
  /// SQLite database while keeping `FLUTTER_TEST` isolated.
  @visibleForTesting
  static String resolveL2CacheRootDir({
    String? rootDirOverride,
    String? databasePathOverride,
    String? localAppDataOverride,
    String? tempDirOverride,
    bool? isFlutterTestOverride,
  }) =>
      _resolveFfiL2CacheRootDir(
        rootDirOverride: rootDirOverride,
        databasePathOverride: databasePathOverride,
        localAppDataOverride: localAppDataOverride,
        tempDirOverride: tempDirOverride,
        isFlutterTestOverride: isFlutterTestOverride,
      );

  /// Latest Dual-Deck status snapshot parsed from `lumina_playback_get_state_json`.
  DualDeckStatus? get lastDualDeckSnapshot => _lastDualDeckSnapshot;

  @override
  bool get isStandbyDeckReady {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.isStandbyDeckReady;
    }
    if (!isNativeBound) {
      return _lastDualDeckSnapshot?.isStandbyReady ??
          _delegate.isStandbyDeckReady;
    }
    return _lastDualDeckSnapshot?.isStandbyReady ?? false;
  }

  /// Loaded native `core_ffi` library handle, or `null` when running in
  /// fallback/test mode without the native shared library.
  ffi.DynamicLibrary? get nativeLibrary => _dylib;

  /// Resolves once `lumina_library_init` has completed (or immediately when the
  /// native library is unavailable).
  Future<void> get dbReady => _dbReadyCompleter.future;

  /// Current native network epoch reported by Rust `NetworkMonitor` (`>= 1`).
  int get nativeNetworkEpoch =>
      isNativeBound ? (_networkGetEpochFn?.call() ?? 1) : 1;

  VisualizerLifecycleCoordinator? get visualizerCoordinator =>
      _visualizerCoordinator;
  LuminaVisualizerSetEnabledDart? get visualizerSetEnabledFn =>
      _visualizerSetEnabledFn;
  LuminaVisualizerIsEnabledDart? get visualizerIsEnabledFn =>
      _visualizerIsEnabledFn;
  LuminaVisualizerGetBandsDart? get visualizerGetBandsFn =>
      _visualizerGetBandsFn;

  @override
  ValueListenable<Float32List> get visualizerBandsNotifier =>
      _visualizerCoordinator?.bandsNotifier ??
      AudioServiceVisualizerExt.defaultVisualizerNotifier;

  @override
  void setVisualizerSettingEnabled(bool enabled) {
    _visualizerSettingEnabled = enabled;
    _visualizerCoordinator?.setSettingEnabled(enabled);
  }

  @override
  void setNowPlayingVisible(bool visible) {
    _isNowPlayingVisible = visible;
    _visualizerCoordinator?.setVisible(visible);
  }

  @override
  void setWindowMinimized(bool minimized) {
    _isWindowMinimized = minimized;
    _visualizerCoordinator?.setMinimized(minimized);
  }

  @visibleForTesting
  int get activeEpoch => _activeEpoch;

  @visibleForTesting
  void setActiveEpochForTest(int epoch) {
    _activeEpoch = epoch;
    _activeRequestId = epoch;
  }

  @visibleForTesting
  void applyReloadedTracksRawForTest(String? raw) =>
      _applyReloadedTracksRaw(raw);

  @visibleForTesting
  void setRestoredSessionForTest(TrackInfo track) {
    _hasRestoredSession = true;
    _state = _state.copyWith(track: track);
  }

  @override
  String? get lastError => _lastError;

  int get nativeActiveRequestId => isNativeBound
      ? (_playbackGetActiveRequestIdFn?.call() ?? _activeRequestId)
      : _activeRequestId;

  @override
  bool get isSystemOutputActive {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.isSystemOutputActive;
    }
    if (!isNativeBound) return _delegate.isSystemOutputActive;
    return _systemOutputActive;
  }

  @override
  int get preferredBufferFrames =>
      !isNativeBound ? _delegate.preferredBufferFrames : _preferredBufferFrames;

  @override
  String? get activeDeviceId {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.activeDeviceId;
    }
    if (!isNativeBound) return _delegate.activeDeviceId;
    return _tracker.activeDeviceId;
  }

  @override
  Map<String, PlaybackState> get devicePlaybackStates {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.devicePlaybackStates;
    }
    if (!isNativeBound) return _delegate.devicePlaybackStates;
    return _tracker.snapshotDevices(_state);
  }

  @override
  Map<String, PlaybackState> get zonePlaybackStates {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.zonePlaybackStates;
    }
    if (!isNativeBound) return _delegate.zonePlaybackStates;
    return _tracker.snapshotZones(activeLocalState: _state);
  }

  @override
  bool get isNativeBound => _dylib != null;

  @override
  ConnectionMode get connectionMode => _connectionMode;

  @override
  String? get activeServerUrl => _remoteClient?.activeServerUrl;

  @override
  Stream<PlaybackState> get stateStream =>
      (isNativeBound || _isRemoteActive)
          ? _stateController.stream
          : _delegate.stateStream;

  @override
  Stream<SignalPath> get signalPathStream => (isNativeBound || _isRemoteActive)
      ? _signalPathController.stream
      : _delegate.signalPathStream;

  @override
  Stream<Duration> get positionStream => (isNativeBound || _isRemoteActive)
      ? _positionController.stream
      : _delegate.positionStream;

  @override
  Stream<QueueState> get queueStateStream => _queueStateController.stream;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  @override
  ConnectionStatus get currentConnectionStatus {
    if (_isRemoteActive) return _remoteClient!.currentConnectionStatus;
    return ConnectionStatus(
      phase: ConnectionPhase.connected,
      mode: _connectionMode,
      endpointUrl: activeServerUrl,
    );
  }

  @override
  Stream<LuminaError> get errorStream => _errorController.stream;

  @override
  Stream<TrackInfo> get trackChangedStream => _trackChangedController.stream;

  @override
  Stream<List<TrackInfo>> get queueUpdatedStream =>
      _queueUpdatedController.stream;

  @override
  Stream<void> get libraryReloadedStream => _libraryReloadedController.stream;

  @override
  PlaybackState get currentState {
    if (_isRemoteActive) return _remoteClient!.currentState;
    return isNativeBound ? _state : _delegate.currentState;
  }

  @override
  SignalPath get currentSignalPath {
    if (_isRemoteActive) return _remoteClient!.currentSignalPath;
    return isNativeBound ? _signalPath : _delegate.currentSignalPath;
  }

  @override
  List<LyricLine> get currentLyrics {
    if (_isRemoteActive) return _remoteClient!.currentLyrics;
    if (_currentLyrics.isNotEmpty) return _currentLyrics;
    if (!isNativeBound) return _delegate.currentLyrics;
    return const [];
  }

  @override
  List<TrackInfo> get queue {
    if (_isRemoteActive) return _remoteClient!.queue;
    return isNativeBound ? _queue : _delegate.queue;
  }

  @override
  List<TrackInfo> get libraryTracks {
    if (_isRemoteActive) return _remoteClient!.libraryTracks;
    if (!isNativeBound) return _delegate.libraryTracks;
    return _hasLoadedLibraryTracks ? _libraryTracks : _queue;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detachStreamingManager();
    _delegateScanProgressSub?.cancel();
    _delegateScanProgressSub = null;
    _delegateLibraryReloadedSub?.cancel();
    _delegateLibraryReloadedSub = null;
    _detachRemoteClientStreams();
    _protocolController?.dispose();
    _protocolController = null;
    _protocolBackend?.dispose();
    _protocolBackend = null;
    _visualizerCoordinator?.dispose();
    _visualizerCoordinator = null;
    _positionTimer?.cancel();
    _remoteClient?.dispose();
    _readWorker?.dispose();
    _readWorker = null;
    _writeWorker?.dispose();
    _writeWorker = null;
    if (isNativeBound) {
      try {
        _libSetScanProgressCbFn?.call(ffi.nullptr);
      } catch (_) {}
      try {
        _l2CacheFlushAccessFn?.call();
      } catch (_) {}
      _shutdownFn?.call();
      _dylib = null;
      _dylibPath = null;
    }
    _scanProgressCallable?.close();
    _scanProgressCallable = null;
    _stateController.close();
    _signalPathController.close();
    _positionController.close();
    _queueStateController.close();
    _connectionStatusController.close();
    _errorController.close();
    _trackChangedController.close();
    _queueUpdatedController.close();
    _scanProgressController.close();
    _libraryReloadedController.close();
    _delegate.dispose();
  }
}
