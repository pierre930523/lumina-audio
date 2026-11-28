part of '../streaming_playback_coordinator.dart';

mixin _CoordinatingAudioServiceDelegatesMixin
    implements AudioService, DualDeckAudioService, LibraryTracksAudioService {
  AudioService get inner;

  @override
  List<TrackInfo> get libraryTracks => inner.libraryTracks;

  @override
  Future<List<TrackInfo>> getLibraryTracks({int limit = 10000}) =>
      inner.getLibraryTracks(limit: limit);

  @override
  Stream<QueueState> get queueStateStream => inner.queueStateStream;

  @override
  QueueState get currentQueueState => inner.currentQueueState;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      inner.connectionStatusStream;

  @override
  ConnectionStatus get currentConnectionStatus => inner.currentConnectionStatus;

  @override
  Stream<LuminaError> get errorStream => inner.errorStream;

  @override
  RepeatMode get repeatMode => inner.repeatMode;

  @override
  bool get shuffle => inner.shuffle;

  @override
  Future<void> setRepeatMode(RepeatMode mode) => inner.setRepeatMode(mode);

  @override
  Future<void> setShuffle(bool enabled) => inner.setShuffle(enabled);

  @override
  proto_backend.PlaybackBackend? get playbackBackend => inner.playbackBackend;

  @override
  PlaybackController? get playbackController => inner.playbackController;

  @override
  Future<void> get dbReadyFuture => inner.dbReadyFuture;

  @override
  L1StreamCachePersistence? createL1CachePersistence() =>
      inner.createL1CachePersistence();

  @override
  SidecarLifecycleBinder? createSidecarLifecycleBinder() =>
      inner.createSidecarLifecycleBinder();

  @override
  VoidCallback? get streamingHttp2WarmupCallback =>
      inner.streamingHttp2WarmupCallback;

  @override
  void attachStreamingHooks(StreamingManager manager) =>
      inner.attachStreamingHooks(manager);

  @override
  void detachStreamingHooks() => inner.detachStreamingHooks();

  @override
  bool get isNativeBound => inner.isNativeBound;

  @override
  ConnectionMode get connectionMode => inner.connectionMode;

  @override
  String? get activeServerUrl => inner.activeServerUrl;

  @override
  List<LyricLine> get currentLyrics => inner.currentLyrics;

  @override
  Map<String, PlaybackState> get devicePlaybackStates =>
      inner.devicePlaybackStates;

  @override
  Map<String, PlaybackState> get zonePlaybackStates => inner.zonePlaybackStates;

  @override
  String? get activeDeviceId => inner.activeDeviceId;

  @override
  bool get isSystemOutputActive => inner.isSystemOutputActive;

  @override
  int get preferredBufferFrames => inner.preferredBufferFrames;

  @override
  bool get isStrictBitPerfect => inner.isStrictBitPerfect;

  @override
  DsdOutputModeOption get dsdOutputMode => inner.dsdOutputMode;

  @override
  ValueListenable<Float32List> get visualizerBandsNotifier =>
      inner.visualizerBandsNotifier;

  @override
  void setVisualizerSettingEnabled(bool enabled) =>
      inner.setVisualizerSettingEnabled(enabled);

  @override
  void setNowPlayingVisible(bool visible) =>
      inner.setNowPlayingVisible(visible);

  @override
  void setWindowMinimized(bool minimized) => inner.setWindowMinimized(minimized);

  @override
  Future<bool> setBufferFrames(int frames) => inner.setBufferFrames(frames);

  @override
  Future<void> setDeviceVolume(String deviceId, double volume) =>
      inner.setDeviceVolume(deviceId, volume);

  @override
  Future<void> toggleDevicePlayPause(String deviceId) =>
      inner.toggleDevicePlayPause(deviceId);

  @override
  Future<void> toggleZonePlayPause(String zoneId) =>
      inner.toggleZonePlayPause(zoneId);

  @override
  Future<int> scanDirectory(String path) => inner.scanDirectory(path);

  @override
  Future<List<TrackInfo>> searchLibrary(String query) =>
      inner.searchLibrary(query);

  @override
  Future<void> toggleDspBypass() => inner.toggleDspBypass();

  @override
  void setSimulatedQuality(SignalQuality quality) =>
      inner.setSimulatedQuality(quality);

  @override
  Future<void> reconnectDevice() => inner.reconnectDevice();

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) => inner.getArtwork(trackId, path: path, maxDim: maxDim);

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) => inner.setUserCover(trackId, imagePath, path: path);

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) =>
      inner.clearUserCover(trackId, path: path);

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) => inner.rescanTags(directory: directory, force: force);

  @override
  Future<Map<String, dynamic>?> getLyrics(String trackId, {String? path}) =>
      inner.getLyrics(trackId, path: path);

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) => inner.setUserLyrics(trackId, filePath, path: path);

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) =>
      inner.clearUserLyrics(trackId, path: path);

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) =>
      inner.getAlbumDetail(albumId);

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) =>
      inner.getArtistDetail(artistId);

  @override
  Future<int> deduplicateLibrary() => inner.deduplicateLibrary();

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) => inner.enrichLibraryCredits(
    musicBrainzBaseUrl: musicBrainzBaseUrl,
    discogsBaseUrl: discogsBaseUrl,
  );

  @override
  Future<DspPipelineConfigModel> getDspConfig() => inner.getDspConfig();

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) =>
      inner.setDspConfig(config);

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) =>
      inner.importAutoEqProfile(autoEqTxt);

  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() => inner.listAudioDevices();

  @override
  Future<void> selectAudioDevice(String? deviceId, {int backendIndex = -1}) =>
      inner.selectAudioDevice(deviceId, backendIndex: backendIndex);

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() => inner.getOutputInfo();

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() =>
      inner.listDeviceCapabilities();

  @override
  Future<void> setStrictBitPerfect(bool enabled) =>
      inner.setStrictBitPerfect(enabled);

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) =>
      inner.setDsdOutputMode(mode);

  @override
  Future<List<AudioZoneInfo>> listZones() => inner.listZones();

  @override
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  }) => inner.discoverZones(
    ssdpAddr: ssdpAddr,
    airplayAddrs: airplayAddrs,
    clockSyncAddr: clockSyncAddr,
  );

  @override
  Future<void> groupZones(String groupId, List<String> zoneIds) =>
      inner.groupZones(groupId, zoneIds);

  @override
  Future<void> setZoneVolume(String zoneId, double volume) =>
      inner.setZoneVolume(zoneId, volume);

  @override
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  }) => inner.syncZoneClock(zoneId, clockAddr: clockAddr);

  @override
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  }) => inner.castToZone(zoneId, action, mediaUri: mediaUri);

  @override
  Future<List<ProviderStatusInfo>> listProviders() => inner.listProviders();

  @override
  Future<bool> configureProvider(String kind, Map<String, dynamic> config) =>
      inner.configureProvider(kind, config);

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() => inner.startTidalPkce();

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) =>
      inner.completeTidalPkce(code, codeVerifier);

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) =>
      inner.syncProvider(kind);

  @override
  Future<List<UserProfileInfo>> listProfiles() => inner.listProfiles();

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) => inner.createProfile(name, avatarColor: avatarColor);

  @override
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  }) => inner.updateProfile(
    profileId,
    name: name,
    avatarColor: avatarColor,
    isDefault: isDefault,
  );

  @override
  Future<void> switchProfile(String profileId) =>
      inner.switchProfile(profileId);

  @override
  Future<bool> deleteProfile(String profileId) =>
      inner.deleteProfile(profileId);

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() =>
      inner.initiateHostPairing();

  @override
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) => inner.discoverLanServers(
    multicastHost: multicastHost,
    port: port,
    timeout: timeout,
  );

  @override
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  }) => inner.pairAndConnectRemote(
    baseUrl: baseUrl,
    pin: pin,
    deviceName: deviceName,
    allowSelfSignedTls: allowSelfSignedTls,
  );

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) => inner.connectWanDirect(
    httpsBaseUrl: httpsBaseUrl,
    bearerToken: bearerToken,
    pin: pin,
    allowSelfSignedTls: allowSelfSignedTls,
  );

  @override
  Stream<ScanProgressEvent> get scanProgressStream => inner.scanProgressStream;

  @override
  Future<String?> startDirectoryScan(String path, {bool force = false}) =>
      inner.startDirectoryScan(path, force: force);

  @override
  Future<String> startTagRescan({String? directory, bool force = false}) =>
      inner.startTagRescan(directory: directory, force: force);

  @override
  Future<Map<String, dynamic>> forceRebuildLibrary({String? directory}) =>
      inner.forceRebuildLibrary(directory: directory);

  @override
  Future<List<WatchedRootRecord>> listWatchedRoots() =>
      inner.listWatchedRoots();

  @override
  Future<WatchedRootRecord?> addWatchedRoot(
    String rootPath, {
    WatchMode watchMode = WatchMode.nativeOs,
    int pollIntervalSec = 300,
  }) => inner.addWatchedRoot(
    rootPath,
    watchMode: watchMode,
    pollIntervalSec: pollIntervalSec,
  );

  @override
  Future<bool> removeWatchedRoot(String rootPath) =>
      inner.removeWatchedRoot(rootPath);

  @override
  Future<List<SkippedFileRecord>> getSkippedFiles({
    bool includeDismissed = false,
  }) => inner.getSkippedFiles(includeDismissed: includeDismissed);

  @override
  Future<bool> dismissSkippedFile(String skippedId) =>
      inner.dismissSkippedFile(skippedId);

  @override
  Future<Map<String, dynamic>> retrySkippedFile(String skippedId) =>
      inner.retrySkippedFile(skippedId);

  @override
  Future<bool> setMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
    dynamic value,
  ) => inner.setMetadataOverride(entityType, entityId, fieldName, value);

  @override
  Future<bool> clearMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
  ) => inner.clearMetadataOverride(entityType, entityId, fieldName);

  @override
  Future<List<MetadataOverrideRecord>> getMetadataOverrides(
    String entityType,
    String entityId,
  ) => inner.getMetadataOverrides(entityType, entityId);

  @override
  Future<Map<String, int>> ingestExternalCatalog(
    ExternalCatalogIngestBatch batch,
  ) => inner.ingestExternalCatalog(batch);

  @override
  Future<MetadataPolicy> getDefaultMetadataPolicy() =>
      inner.getDefaultMetadataPolicy();

  @override
  Future<bool> setDefaultMetadataPolicy(MetadataPolicy policy) =>
      inner.setDefaultMetadataPolicy(policy);

  @override
  Future<bool> setEntityMetaPolicy(
    String entityType,
    String entityId,
    MetadataPolicy policy,
  ) => inner.setEntityMetaPolicy(entityType, entityId, policy);

  @override
  Future<bool> setEntityUserEdits(
    String entityType,
    String entityId,
    Map<String, dynamic> edits,
  ) => inner.setEntityUserEdits(entityType, entityId, edits);

  @override
  Future<bool> revertEntityToFileMeta(
    String entityType,
    String entityId,
  ) => inner.revertEntityToFileMeta(entityType, entityId);

  @override
  Future<BatchRescanSkippedResult> rescanAllSkippedFiles() =>
      inner.rescanAllSkippedFiles();

  @override
  Future<LibraryCleanupPreview> previewLibraryCleanup() =>
      inner.previewLibraryCleanup();

  @override
  Future<LibraryCleanupResult> executeLibraryCleanup(
    LibraryCleanupOptions options,
  ) => inner.executeLibraryCleanup(options);

  @override
  Future<void> switchToLocalMode() => inner.switchToLocalMode();
}
