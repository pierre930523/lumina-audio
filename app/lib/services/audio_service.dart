import 'package:flutter/foundation.dart';

import '../models/audio_output_info.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/signal_path.dart';
import '../models/studio_models.dart';

typedef StreamingTrackHandler = Future<void> Function(
  TrackInfo track, {
  List<TrackInfo>? queueContext,
  bool debounce,
});

abstract class AudioService {
  static const String systemOutputId = '__system_output__';

  static bool isStreamingTrackId(String id) {
    return id.startsWith('apple:') ||
        id.startsWith('ytm:') ||
        id.startsWith('qobuz:') ||
        id.startsWith('tidal:') ||
        id.startsWith('deezer:');
  }

  Stream<PlaybackState> get stateStream;
  Stream<SignalPath> get signalPathStream;
  Stream<Duration> get positionStream;

  bool get isNativeBound;
  ConnectionMode get connectionMode;
  String? get activeServerUrl;
  PlaybackState get currentState;
  SignalPath get currentSignalPath;
  List<LyricLine> get currentLyrics;
  List<TrackInfo> get queue;

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
  void setStreamingTrackHandler(StreamingTrackHandler? handler) {}
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) {}
  void failOptimisticTrackLoad(TrackInfo track, String message) {}
  Future<void> cancelPendingPlayback() async {}
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

  // Albums, Canonical Versions & Credits Graph (R1 / M8)
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100});
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId);
  Future<ArtistDetailInfo?> getArtistDetail(String artistId);
  Future<int> deduplicateLibrary();
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  });

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

/// Real-time 64-band audio spectrum extension for [AudioService].
/// Provides seamless access across all audio service implementations
/// without breaking mock or server service contracts.
extension AudioServiceVisualizerExt on AudioService {
  static final Float32List zeroBands64 = Float32List(64);
  static final ValueNotifier<Float32List> defaultVisualizerNotifier =
      ValueNotifier<Float32List>(zeroBands64);

  ValueListenable<Float32List> get visualizerBandsNotifier {
    try {
      final dynamic self = this;
      final notifier = self.visualizerBandsNotifier;
      if (notifier is ValueListenable<Float32List>) {
        return notifier;
      }
    } catch (_) {}
    return defaultVisualizerNotifier;
  }

  void setVisualizerSettingEnabled(bool enabled) {
    try {
      (this as dynamic).setVisualizerSettingEnabled(enabled);
    } catch (_) {}
  }

  void setNowPlayingVisible(bool visible) {
    try {
      (this as dynamic).setNowPlayingVisible(visible);
    } catch (_) {}
  }

  void setWindowMinimized(bool minimized) {
    try {
      (this as dynamic).setWindowMinimized(minimized);
    } catch (_) {}
  }
}

