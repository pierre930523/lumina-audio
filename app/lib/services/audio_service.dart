import 'package:flutter/foundation.dart';

import '../models/audio_output_info.dart';
import '../models/ingestion_models.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/protocol/lumina_error.dart';
import '../models/protocol/protocol_models.dart';
import '../models/signal_path.dart';
import '../models/stream_source_spec.dart';
import '../models/studio_models.dart';
import 'playback/playback_backend.dart';
import 'playback/playback_controller.dart';
import 'platform_asset_opener.dart';
import 'streaming/autoplay_controller.dart';
import 'streaming/l1_stream_cache.dart';
import 'streaming/pot_sidecar_manager.dart';
import 'streaming/streaming_manager.dart';

part 'audio_service_extensions.dart';
part 'audio_service_focus_tags_folders.dart';
part 'audio_service_step4.dart';
part 'audio_service_step5.dart';

typedef StreamingTrackHandler = Future<void> Function(
  TrackInfo track, {
  List<TrackInfo>? queueContext,
  bool debounce,
});

abstract class AudioService
    with
        AudioServiceFocusTagsFoldersMixin,
        AudioServiceStep4Mixin,
        AudioServiceStep5Mixin {
  static const String systemOutputId = '__system_output__';

  static bool isStreamingTrackId(String id) {
    return id.startsWith('apple:') ||
        id.startsWith('ytm:') ||
        id.startsWith('ytm_') ||
        id.startsWith('streaming:') ||
        id.startsWith('youtube_music:') ||
        id.startsWith('podcast_rss:') ||
        id.startsWith('rss:') ||
        id.startsWith('http://') ||
        id.startsWith('https://') ||
        id.startsWith('qobuz:') ||
        id.startsWith('tidal:') ||
        id.startsWith('deezer:');
  }

  Stream<PlaybackState> get stateStream;
  Stream<SignalPath> get signalPathStream;
  Stream<Duration> get positionStream;
  Stream<QueueState> get queueStateStream => const Stream<QueueState>.empty();
  Stream<ConnectionStatus> get connectionStatusStream =>
      const Stream<ConnectionStatus>.empty();
  Stream<LuminaError> get errorStream => const Stream<LuminaError>.empty();
  Stream<TrackInfo> get trackChangedStream => const Stream<TrackInfo>.empty();
  Stream<List<TrackInfo>> get queueUpdatedStream =>
      const Stream<List<TrackInfo>>.empty();

  bool get isNativeBound;
  ConnectionMode get connectionMode;
  String? get activeServerUrl;
  PlaybackState get currentState;
  QueueState get currentQueueState => QueueState.empty;
  ConnectionStatus get currentConnectionStatus => ConnectionStatus(
        phase: ConnectionPhase.connected,
        mode: connectionMode,
        endpointUrl: activeServerUrl,
      );
  SignalPath get currentSignalPath;
  List<LyricLine> get currentLyrics;
  List<TrackInfo> get queue;
  RepeatMode get repeatMode => currentState.repeatMode;
  bool get shuffle => currentState.shuffle;
  Future<void> setRepeatMode(RepeatMode mode) async {}
  Future<void> setShuffle(bool enabled) async {}

  /// Typed cross-mode playback controller / backend accessors.
  PlaybackBackend? get playbackBackend => null;
  PlaybackController? get playbackController => null;

  /// Optional coordinator/autoplay/prefetch accessors (eliminating UI downcasts).
  AutoplayController? get autoplayController => null;
  void Function(TrackInfo track)? get hoverPrefetchCallback => null;

  /// Capability hooks for native/streaming bootstrap wiring (eliminating UI downcasts).
  Future<void> get dbReadyFuture => Future<void>.value();
  L1StreamCachePersistence? createL1CachePersistence() => null;
  SidecarLifecycleBinder? createSidecarLifecycleBinder() => null;
  VoidCallback? get streamingHttp2WarmupCallback => null;
  void attachStreamingHooks(StreamingManager manager) {}
  void detachStreamingHooks() {}

  /// Typed visualizer controls (replaces `(this as dynamic)` reflection).
  ValueListenable<Float32List> get visualizerBandsNotifier =>
      AudioServiceVisualizerExt.defaultVisualizerNotifier;
  void setVisualizerSettingEnabled(bool enabled) {}
  void setNowPlayingVisible(bool visible) {}
  void setWindowMinimized(bool minimized) {}

  /// R4: 各輸出設備與音區獨立播放狀態（deviceId/zoneId -> 狀態）。
  Map<String, PlaybackState> get devicePlaybackStates => const {};
  Map<String, PlaybackState> get zonePlaybackStates => const {};
  String? get activeDeviceId => null;
  bool get isSystemOutputActive => false;
  String? get lastError => null;
  int get preferredBufferFrames => 512;
  Future<bool> setBufferFrames(int frames) async => false;
  Future<void> setDeviceVolume(String deviceId, double volume);
  Future<void> toggleDevicePlayPause(String deviceId);
  Future<void> toggleZonePlayPause(String zoneId);

  Future<int> scanDirectory(String path);
  Future<List<TrackInfo>> searchLibrary(String query);
  Future<void> play({TrackInfo? track});
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) => play(track: track);
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) => playStreamUrl(
    track: track,
    streamUrl: streamUrl,
    headers: headers,
    hintExtension: hintExtension,
  );
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) async {
    switch (spec) {
      case DirectRangeSpec():
        await playStreamUrlAsync(
          track: track,
          streamUrl: spec.url,
          headers: spec.headers,
          hintExtension: spec.hintExtension,
          requestId: epoch,
        );
      case EncryptedRangeSpec():
        await playStreamUrlAsync(
          track: track,
          streamUrl: spec.url,
          headers: spec.headers,
          hintExtension: spec.hintExtension,
          requestId: epoch,
        );
      case SegmentedManifestSpec():
        await playStreamUrlAsync(
          track: track,
          streamUrl: spec.manifestUrlOrXml,
          headers: spec.headers,
          hintExtension: spec.format == ManifestFormat.dash ? 'mpd' : 'm3u8',
          requestId: epoch,
        );
      case LocalFileSpec():
        await play(track: track.copyWith(filePath: spec.path));
      case ExternalBackendSpec():
        throw StateError(
          'ExternalBackendSpec (${spec.providerId}) cannot enter native AudioService',
        );
    }
  }
  Future<void> playStreamSpecWithOptions(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) => playStreamSpecAsync(track, spec, epoch: epoch);
  void setStreamingTrackHandler(StreamingTrackHandler? handler) {}
  void setPlaybackInterruptHandler(VoidCallback? handler) {}
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) {}
  void beginOptimisticTrackLoadAtEpoch(
    TrackInfo track, {
    List<TrackInfo>? queue,
    required int epoch,
  }) => beginOptimisticTrackLoad(track, queue: queue);
  void failOptimisticTrackLoad(TrackInfo track, String message) {}
  Future<void> cancelPendingPlayback() async {}
  Future<void> cancelPendingPlaybackAtEpoch(int epoch) =>
      cancelPendingPlayback();
  Future<void> skipToTrack(TrackInfo track, {List<TrackInfo>? queueContext}) =>
      play(track: track);
  Future<void> restorePlaybackSession({
    required TrackInfo track,
    required Duration position,
    List<TrackInfo>? queue,
    int? queueIndex,
    double? volume,
    bool? isMuted,
  });
  Future<void> pause();
  Future<void> resume();
  Future<void> togglePlayPause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> toggleMute();
  Future<void> next();
  Future<void> previous();
  Future<void> toggleDspBypass();
  void setSimulatedQuality(SignalQuality quality);

  // Playback Lifecycle & Device Reconnect (F13 / Contract #1)
  Future<void> reconnectDevice();
  Future<Map<String, dynamic>?> getPlaybackState();

  // Artwork & Cover Overrides (F11 / Contract #2)
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  });
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  });
  Future<bool> clearUserCover(
    String trackId, {
    String? path,
  });
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  });

  // Lyrics Engine & Overrides (F12 / Contract #3)
  Future<Map<String, dynamic>?> getLyrics(
    String trackId, {
    String? path,
  });
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  });
  Future<bool> clearUserLyrics(
    String trackId, {
    String? path,
  });

  // Albums, Canonical Versions & Credits Graph (R1 / M8 / Step 2 Grouping)
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  });
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId);
  Future<ArtistDetailInfo?> getArtistDetail(String artistId);
  Future<int> deduplicateLibrary();
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  });

  // Library Foundation Step 2: Album Groups, Versions, Merge/Split & Primary Locking
  Future<AlbumVersionOpResult> setPrimaryVersion(
    String groupId,
    String versionId,
  ) async => const AlbumVersionOpResult();

  Future<AlbumVersionOpResult> resetPrimaryVersion(String groupId) async =>
      const AlbumVersionOpResult();

  Future<AlbumVersionOpResult> mergeAlbumVersions({
    required String targetVersionId,
    required List<String> sourceVersionIds,
    String? newEditionLabel,
    List<DiscMappingEntry> discMapping = const <DiscMappingEntry>[],
  }) async => const AlbumVersionOpResult();

  Future<AlbumVersionOpResult> splitAlbumVersion({
    required String versionId,
    required List<SplitTrackGroup> trackGroups,
    SplitTargetMode targetMode = SplitTargetMode.sameGroup,
  }) async => const AlbumVersionOpResult();

  Future<AlbumVersionOpResult> groupAsAlternateVersions({
    required List<String> versionIds,
    String? targetGroupId,
    String? primaryVersionId,
  }) async => const AlbumVersionOpResult();

  Future<AlbumVersionOpResult> ungroupVersion(String versionId) async =>
      const AlbumVersionOpResult();

  Future<AlbumVersionOpResult> setVersionHidden(
    String versionId, {
    required bool isHidden,
  }) async => const AlbumVersionOpResult();

  Future<AlbumVersionOpResult> resetAlbumGrouping(String versionId) async =>
      const AlbumVersionOpResult();

  // DSP Control Panel (R1 / M8)
  Future<DspPipelineConfigModel> getDspConfig();
  Future<void> setDspConfig(DspPipelineConfigModel config);
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt);

  // Audio Devices & Phase 4 Multi-Room Zones (R1, R3 / M8, M10)
  Future<List<AudioDeviceInfo>> listAudioDevices();
  Future<void> selectAudioDevice(String? deviceId, {int backendIndex = -1});

  // Hi-Fi Bit-Perfect Strict Mode, DSD Mode & Phase 10 Verification Telemetry
  bool get isStrictBitPerfect => false;
  DsdOutputModeOption get dsdOutputMode => DsdOutputModeOption.auto;
  Future<AudioEngineOutputInfoModel> getOutputInfo();
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities();
  Future<void> setStrictBitPerfect(bool enabled);
  Future<void> setDsdOutputMode(DsdOutputModeOption mode);
  Future<List<AudioZoneInfo>> listZones();
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  });
  Future<void> groupZones(String groupId, List<String> zoneIds);
  Future<void> setZoneVolume(String zoneId, double volume);
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  });
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  });

  // Streaming & Network Share Providers (R1 / M8)
  Future<List<ProviderStatusInfo>> listProviders();
  Future<bool> configureProvider(String kind, Map<String, dynamic> config);
  Future<TidalPkceStartInfo?> startTidalPkce();
  Future<bool> completeTidalPkce(String code, String codeVerifier);
  Future<Map<String, dynamic>> syncProvider(String kind);

  // Profiles (R1 / M8)
  Future<List<UserProfileInfo>> listProfiles();
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  });
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  });
  Future<void> switchProfile(String profileId);
  Future<bool> deleteProfile(String profileId);

  // Layer 1 Ingestion: Scan Progress, Watched Roots, Quarantine, Overrides & External Catalog Handoff
  Stream<ScanProgressEvent> get scanProgressStream =>
      const Stream<ScanProgressEvent>.empty();

  Future<String?> startDirectoryScan(String path, {bool force = false}) async {
    await scanDirectory(path);
    return null;
  }

  Future<String> startTagRescan({String? directory, bool force = false}) async {
    await rescanTags(directory: directory, force: force);
    return '';
  }

  Future<Map<String, dynamic>> forceRebuildLibrary({String? directory}) async {
    final scanId = await startTagRescan(directory: directory, force: true);
    return <String, dynamic>{
      if (scanId.isNotEmpty) 'scan_id': scanId,
    };
  }

  Future<List<WatchedRootRecord>> listWatchedRoots() async => const [];

  Future<WatchedRootRecord?> addWatchedRoot(
    String rootPath, {
    WatchMode watchMode = WatchMode.nativeOs,
    int pollIntervalSec = 300,
  }) async => null;

  Future<bool> removeWatchedRoot(String rootPath) async => false;

  Future<List<SkippedFileRecord>> getSkippedFiles({
    bool includeDismissed = false,
  }) async => const [];

  Future<bool> dismissSkippedFile(String skippedId) async => false;

  Future<Map<String, dynamic>> retrySkippedFile(String skippedId) async =>
      const <String, dynamic>{
        'status': 'not_found',
        'detail': 'Not supported',
      };

  Future<bool> setMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
    dynamic value,
  ) async => false;

  Future<bool> clearMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
  ) async => false;

  Future<List<MetadataOverrideRecord>> getMetadataOverrides(
    String entityType,
    String entityId,
  ) async => const [];

  Future<Map<String, int>> ingestExternalCatalog(
    ExternalCatalogIngestBatch batch,
  ) async => const <String, int>{'albums_ingested': 0, 'tracks_ingested': 0};

  // Library Foundation Step 1: 3-Layer Metadata Policy, Batch Skipped Rescan & Cleanup
  Future<MetadataPolicy> getDefaultMetadataPolicy() async =>
      MetadataPolicy.file;

  Future<bool> setDefaultMetadataPolicy(MetadataPolicy policy) async => false;

  Future<bool> setEntityMetaPolicy(
    String entityType,
    String entityId,
    MetadataPolicy policy,
  ) async => false;

  Future<bool> setEntityUserEdits(
    String entityType,
    String entityId,
    Map<String, dynamic> edits,
  ) async => false;

  Future<bool> revertEntityToFileMeta(
    String entityType,
    String entityId,
  ) async => false;

  Future<BatchRescanSkippedResult> rescanAllSkippedFiles() async =>
      const BatchRescanSkippedResult();

  Future<LibraryCleanupPreview> previewLibraryCleanup() async =>
      const LibraryCleanupPreview();

  Future<LibraryCleanupResult> executeLibraryCleanup(
    LibraryCleanupOptions options,
  ) async => const LibraryCleanupResult();

  // Pairing & Phase 3 Mobile / Remote Dual-Mode (R2 / M9)
  Future<PairingInitiateInfo?> initiateHostPairing();
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  });
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  });
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  });
  Future<void> switchToLocalMode();

  void dispose();
}

