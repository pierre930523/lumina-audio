import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/audio_format.dart';
import '../models/audio_output_info.dart';
import '../models/ingestion_models.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/protocol/lumina_error.dart';
import '../models/protocol/protocol_models.dart';
import '../models/signal_path.dart';
import '../models/stream_source_spec.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'per_device_playback_tracker.dart';
import 'playback/playback_backend.dart';
import 'playback/playback_controller.dart';
import 'playback_persistence_service.dart';
import 'server_audio_service.dart';
import 'streaming/autoplay_controller.dart';
import 'streaming/l1_stream_cache.dart';
import 'streaming/pot_sidecar_manager.dart';
import 'streaming/streaming_manager.dart';

part 'mock/mock_state_and_fixtures.dart';
part 'mock/mock_playback_mixin.dart';
part 'mock/mock_transport_mixin.dart';
part 'mock/mock_media_and_dsp_mixin.dart';
part 'mock/mock_library_mixin.dart';
part 'mock/mock_album_grouping_store.dart';
part 'mock/mock_album_grouping_mixin.dart';
part 'mock/mock_focus_tags_folders_store.dart';
part 'mock/mock_focus_tags_folders_mixin.dart';
part 'mock/mock_step4_mixin.dart';
part 'mock/mock_step4_listen_later_mixin.dart';
part 'mock/mock_step5_mixin.dart';
part 'mock/mock_step5_bulk_assets_mixin.dart';
part 'mock/mock_step5_backup_export_mixin.dart';
part 'mock/mock_track_actions_mixin.dart';
part 'mock/mock_devices_and_zones_mixin.dart';
part 'mock/mock_providers_and_profiles_mixin.dart';
part 'mock/mock_ingestion_and_queue_mixin.dart';
part 'mock/mock_maintenance_mixin.dart';

abstract class _MockAudioServiceBase
    implements AudioService, DualDeckAudioService {
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
  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffle = false;
  int _queueEpoch = 0;

  final List<WatchedRootRecord> _watchedRoots = <WatchedRootRecord>[];
  final List<SkippedFileRecord> _skippedFiles = <SkippedFileRecord>[];
  final Map<String, Map<String, MetadataOverrideRecord>> _metadataOverrides =
      <String, Map<String, MetadataOverrideRecord>>{};
  final List<ExternalCatalogIngestBatch> _ingestedExternalBatches =
      <ExternalCatalogIngestBatch>[];
  MetadataPolicy _defaultMetadataPolicy = MetadataPolicy.file;
  final Map<String, MetadataPolicy> _entityMetaPolicies =
      <String, MetadataPolicy>{};
  final Map<String, Map<String, dynamic>> _entityFileMeta =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _entityCloudMeta =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _entityUserEdits =
      <String, Map<String, dynamic>>{};
  LibraryCleanupPreview _mockCleanupPreview = const LibraryCleanupPreview();
  LibraryCleanupOptions? _lastCleanupOptions;
  int _mockScanSeq = 0;

  late PlaybackState _state;
  late SignalPath _signalPath;
  late final List<TrackInfo> _queue;
  late final List<LyricLine> _lyrics;
  int _currentIndex = 0;
  int _activeEpoch = 0;
  bool _lastPlayDebounced = false;
  StreamSourceSpec? _lastSourceSpec;
  TrackInfo? _standbyTrack;
  StreamSourceSpec? _standbySpec;
  int _standbyEpoch = 0;
  bool _standbyReady = false;

  final PerDevicePlaybackTracker _tracker = PerDevicePlaybackTracker();
  bool _dspBypassed;
  bool _strictBitPerfect = false;
  bool _savedNormalBypass = false;
  double _savedNormalVolume = 0.85;
  DsdOutputModeOption _dsdOutputMode = DsdOutputModeOption.auto;
  SignalQuality? _forcedQuality;
  ConnectionMode _connectionMode = ConnectionMode.localOrUsbDac;
  String? _activeServerUrl;
  String _activeProfileId = 'prof-default';
  bool _providersLoaded = false;
  bool _systemOutputActive = false;
  String? _lastError;
  int _preferredBufferFrames = 512;
  bool _needsLoadOnResume = false;
  StreamingTrackHandler? _streamingTrackHandler;
  VoidCallback? _playbackInterruptHandler;
  final Map<String, String> _userCovers = {};
  final Map<String, String> _userLyrics = {};
  final Map<String, int> _mockArtistPreferences = <String, int>{};

  final List<UserProfileInfo> _profiles = _createDefaultMockProfiles();
  DspPipelineConfigModel _dspConfig = _createDefaultMockDspConfig();
  final List<AudioDeviceInfo> _devices = _createDefaultMockDevices();
  final List<AudioZoneInfo> _zones = _createDefaultMockZones();
  final List<ProviderStatusInfo> _providers = _createDefaultMockProviders();

  final ValueNotifier<Float32List> _visualizerBandsNotifier =
      ValueNotifier<Float32List>(Float32List(64));
  bool _visualizerSettingEnabled = true;
  bool _nowPlayingVisible = false;
  bool _windowMinimized = false;
  bool _disposed = false;

  _MockAudioServiceBase({bool startBypassed = false})
      : _dspBypassed = startBypassed;

  void _clearStandby() {
    _standbyTrack = null;
    _standbySpec = null;
    _standbyEpoch = 0;
    _standbyReady = false;
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
  }

  void _emitSignalPath() {
    _signalPath = _buildMockSignalPath(
      track: _state.track ?? _queue.first,
      forcedQuality: _forcedQuality,
      dspBypassed: _dspBypassed,
    );
    if (!_signalPathController.isClosed) {
      _signalPathController.add(_signalPath);
    }
  }
}

class MockAudioService extends _MockAudioServiceBase
    with
        _MockPlaybackMixin,
        _MockTransportMixin,
        _MockMediaAndDspMixin,
        _MockAlbumGroupingMixin,
        _MockFocusTagsFoldersMixin,
        _MockStep4Mixin,
        _MockStep4ListenLaterMixin,
        _MockStep5Mixin,
        _MockStep5BulkAssetsMixin,
        _MockStep5BackupExportMixin,
        _MockTrackActionsMixin,
        _MockLibraryMixin,
        _MockDevicesAndZonesMixin,
        _MockProvidersAndProfilesMixin,
        _MockIngestionAndQueueMixin,
        _MockMaintenanceMixin {
  MockAudioService({super.startBypassed = false}) {
    _queue = _createDefaultMockQueue();
    _lyrics = _createDefaultMockLyrics();
    _state = PlaybackState(
      status: PlaybackStatus.paused,
      track: _queue[_currentIndex],
      position: const Duration(seconds: 3),
      volume: 0.85,
      isMuted: false,
    );
    _tracker.syncActiveFromDevices(_devices);
    _tracker.syncZones(_zones, activeLocalState: _state);
    _signalPath = _buildMockSignalPath(
      track: _state.track ?? _queue.first,
      forcedQuality: _forcedQuality,
      dspBypassed: _dspBypassed,
    );
  }

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  Stream<SignalPath> get signalPathStream => _signalPathController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  bool get isNativeBound => false;

  @override
  ConnectionMode get connectionMode => _connectionMode;

  @override
  String? get activeServerUrl => _activeServerUrl;

  @override
  PlaybackState get currentState => _state;

  @override
  SignalPath get currentSignalPath => _signalPath;

  @override
  List<TrackInfo> get queue => _queue;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  @override
  ConnectionStatus get currentConnectionStatus => ConnectionStatus(
        phase: ConnectionPhase.connected,
        mode: _connectionMode,
        endpointUrl: _activeServerUrl,
      );

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
  PlaybackBackend? get playbackBackend => null;

  @override
  PlaybackController? get playbackController => null;

  @override
  AutoplayController? get autoplayController => null;

  @override
  void Function(TrackInfo track)? get hoverPrefetchCallback => null;

  @override
  Future<void> get dbReadyFuture => Future<void>.value();

  @override
  L1StreamCachePersistence? createL1CachePersistence() => null;

  @override
  SidecarLifecycleBinder? createSidecarLifecycleBinder() => null;

  @override
  VoidCallback? get streamingHttp2WarmupCallback => null;

  @override
  void attachStreamingHooks(StreamingManager manager) {}

  @override
  void detachStreamingHooks() {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _visualizerBandsNotifier.dispose();
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
