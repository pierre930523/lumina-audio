import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/audio_format.dart';
import '../models/audio_output_info.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/signal_path.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'per_device_playback_tracker.dart';
import 'server_audio_service.dart';

class MockAudioService implements AudioService {
  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<SignalPath> _signalPathController =
      StreamController<SignalPath>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  late PlaybackState _state;
  late SignalPath _signalPath;
  late final List<TrackInfo> _queue;
  late final List<LyricLine> _lyrics;
  int _currentIndex = 0;
  final PerDevicePlaybackTracker _tracker = PerDevicePlaybackTracker();
  bool _dspBypassed = false;
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
  final Map<String, String> _userCovers = {};
  final Map<String, String> _userLyrics = {};

  final List<UserProfileInfo> _profiles = [
    const UserProfileInfo(
      id: 'prof-default',
      name: 'Pierre (Default)',
      avatarColor: '#007AFF',
      isDefault: true,
    ),
    const UserProfileInfo(
      id: 'prof-studio',
      name: 'Studio Reference',
      avatarColor: '#A259FF',
      isDefault: false,
    ),
  ];

  DspPipelineConfigModel _dspConfig = DspPipelineConfigModel(
    bypass: false,
    peqBands: DspPipelineConfigModel.defaultTenBandIso(),
    crossfeedEnabled: true,
    crossfeedCutoffHz: 700.0,
    crossfeedFeedLevelDb: -6.0,
    replayGainMode: ReplayGainModeOption.album,
    replayGainPreampDb: 0.0,
  );

  final List<AudioDeviceInfo> _devices = [
    const AudioDeviceInfo(
      id: 'asio-fiio-k9',
      name: 'FiiO K9 Pro USB ASIO',
      backend: 'windows_asio',
      isDefault: true,
      isExclusive: true,
      supportedSampleRates: [44100, 48000, 96000, 192000, 384000],
    ),
    const AudioDeviceInfo(
      id: 'usb-dac-mobile',
      name: 'Direct USB DAC (Bit-Perfect)',
      backend: 'mobile_direct',
      isDefault: false,
      isExclusive: true,
      supportedSampleRates: [44100, 96000, 192000],
    ),
  ];

  final List<AudioZoneInfo> _zones = [
    const AudioZoneInfo(
      id: 'zone-local',
      name: 'Desktop DAC (FiiO K9 Pro)',
      backend: 'windows_asio',
      isActive: true,
      volume: 0.8,
      clockOffsetUs: 0,
      rttUs: 0,
      driftPpm: 0.0,
    ),
    const AudioZoneInfo(
      id: 'dlna-living-room',
      name: 'Living Room DLNA Renderer',
      backend: 'network_dlna',
      isActive: false,
      volume: 0.55,
      clockOffsetUs: 1200,
      rttUs: 840,
      driftPpm: 1.5,
    ),
  ];

  final List<ProviderStatusInfo> _providers = [
    const ProviderStatusInfo(kind: 'local', isConfigured: true, isOnline: true),
    const ProviderStatusInfo(kind: 'apple_music', isConfigured: false, isOnline: false),
    const ProviderStatusInfo(kind: 'youtube_music', isConfigured: false, isOnline: false),
    const ProviderStatusInfo(kind: 'qobuz', isConfigured: false, isOnline: false),
    const ProviderStatusInfo(kind: 'tidal', isConfigured: false, isOnline: false),
    const ProviderStatusInfo(kind: 'deezer', isConfigured: false, isOnline: false),
    const ProviderStatusInfo(kind: 'web_dav', isConfigured: false, isOnline: false),
    const ProviderStatusInfo(kind: 'smb', isConfigured: false, isOnline: false),
  ];

  MockAudioService({bool startBypassed = false}) : _dspBypassed = startBypassed {
    _queue = [
      TrackInfo(
        id: 'trk-001',
        title: 'Time',
        artist: 'Pink Floyd',
        album: 'The Dark Side of the Moon (50th Anniversary Remaster)',
        duration: Duration(minutes: 4, seconds: 5),
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'Qobuz Hi-Res',
      ),
      TrackInfo(
        id: 'trk-002',
        title: 'Money',
        artist: 'Pink Floyd',
        album: 'The Dark Side of the Moon (50th Anniversary Remaster)',
        duration: Duration(minutes: 3, seconds: 52),
        format: AudioFormat(
          codec: AudioCodec.dsf,
          sampleRateHz: 2822400,
          bitDepth: 1,
          channels: 2,
          isDsd: true,
        ),
        providerName: 'Local NAS (DSD64)',
      ),
      TrackInfo(
        id: 'trk-003',
        title: 'Comfortably Numb',
        artist: 'Pink Floyd',
        album: 'The Wall',
        duration: Duration(minutes: 6, seconds: 22),
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 192000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'Tidal Max',
      ),
    ];

    _lyrics = const [
      LyricLine(
        start: Duration(seconds: 0),
        end: Duration(seconds: 6),
        text: 'Ticking away the moments that make up a dull day',
        words: [
          LyricWord(
            text: 'Ticking ',
            start: Duration(seconds: 0),
            end: Duration(seconds: 1),
          ),
          LyricWord(
            text: 'away ',
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
          ),
          LyricWord(
            text: 'the ',
            start: Duration(seconds: 2),
            end: Duration(seconds: 3),
          ),
          LyricWord(
            text: 'moments ',
            start: Duration(seconds: 3),
            end: Duration(seconds: 4),
          ),
          LyricWord(
            text: 'that make up a dull day',
            start: Duration(seconds: 4),
            end: Duration(seconds: 6),
          ),
        ],
      ),
      LyricLine(
        start: Duration(seconds: 6),
        end: Duration(seconds: 12),
        text: 'Fritter and waste the hours in an offhand way',
        words: [
          LyricWord(
            text: 'Fritter ',
            start: Duration(seconds: 6),
            end: Duration(seconds: 8),
          ),
          LyricWord(
            text: 'and waste ',
            start: Duration(seconds: 8),
            end: Duration(seconds: 10),
          ),
          LyricWord(
            text: 'the hours in an offhand way',
            start: Duration(seconds: 10),
            end: Duration(seconds: 12),
          ),
        ],
      ),
      LyricLine(
        start: Duration(seconds: 12),
        end: Duration(seconds: 18),
        text: 'Kicking around on a piece of ground in your home town',
        words: [
          LyricWord(
            text: 'Kicking ',
            start: Duration(seconds: 12),
            end: Duration(seconds: 14),
          ),
          LyricWord(
            text: 'around on a piece of ground ',
            start: Duration(seconds: 14),
            end: Duration(seconds: 16),
          ),
          LyricWord(
            text: 'in your home town',
            start: Duration(seconds: 16),
            end: Duration(seconds: 18),
          ),
        ],
      ),
      LyricLine(
        start: Duration(seconds: 18),
        end: Duration(seconds: 24),
        text: 'Waiting for someone or something to show you the way',
        words: [
          LyricWord(
            text: 'Waiting ',
            start: Duration(seconds: 18),
            end: Duration(seconds: 20),
          ),
          LyricWord(
            text: 'for someone or something ',
            start: Duration(seconds: 20),
            end: Duration(seconds: 22),
          ),
          LyricWord(
            text: 'to show you the way',
            start: Duration(seconds: 22),
            end: Duration(seconds: 24),
          ),
        ],
      ),
    ];

    _state = PlaybackState(
      status: PlaybackStatus.paused,
      track: _queue[_currentIndex],
      position: const Duration(seconds: 3),
      volume: 0.85,
      isMuted: false,
    );

    _tracker.syncActiveFromDevices(_devices);
    _tracker.syncZones(_zones, activeLocalState: _state);

    _signalPath = _buildSignalPath();
  }

  SignalPath _buildSignalPath() {
    final track = _state.track ?? _queue.first;
    final forced = _forcedQuality;

    if (forced == SignalQuality.highQuality) {
      return SignalPath(
        overallQuality: SignalQuality.highQuality,
        description: SignalQuality.highQuality.description,
        dspBypassed: _dspBypassed,
        nodes: [
          SignalPathNode(
            title: '音訊來源',
            subtitle: track.providerName,
            detail: track.format.label,
            quality: SignalQuality.lossless,
          ),
          const SignalPathNode(
            title: '系統混音器',
            subtitle: 'WASAPI 共用模式',
            detail: '經系統音訊混音器重新取樣為 48.0 kHz',
            quality: SignalQuality.highQuality,
          ),
          const SignalPathNode(
            title: '音訊輸出',
            subtitle: '系統預設輸出裝置',
            detail: '共用模式 48.0 kHz / 32-bit 浮點',
            quality: SignalQuality.highQuality,
          ),
        ],
      );
    }

    if (_dspBypassed || forced == SignalQuality.lossless) {
      return SignalPath(
        overallQuality: SignalQuality.lossless,
        description: SignalQuality.lossless.description,
        dspBypassed: true,
        nodes: [
          SignalPathNode(
            title: '音訊來源',
            subtitle: track.providerName,
            detail: track.format.label,
            quality: SignalQuality.lossless,
          ),
          const SignalPathNode(
            title: 'DSP 處理管線',
            subtitle: '已啟用位元精準旁通',
            detail: '零損耗直接路由至硬體裝置',
            quality: SignalQuality.lossless,
          ),
          const SignalPathNode(
            title: '音訊輸出',
            subtitle: 'Windows ASIO 獨佔模式',
            detail: 'FiiO K9 Pro USB ASIO (96.0 kHz / 24-bit)',
            quality: SignalQuality.lossless,
          ),
        ],
      );
    }

    return SignalPath(
      overallQuality: SignalQuality.enhanced,
      description: SignalQuality.enhanced.description,
      dspBypassed: false,
      nodes: [
        SignalPathNode(
          title: '音訊來源',
          subtitle: track.providerName,
          detail: track.format.label,
          quality: SignalQuality.lossless,
        ),
        const SignalPathNode(
          title: '64 位元浮點 DSP',
          subtitle: '參數等化器 + Bauer 聲學交叉饋送',
          detail: 'AutoEQ Sennheiser HD650（10 段參數等化，64 位元浮點運算）',
          quality: SignalQuality.enhanced,
        ),
        const SignalPathNode(
          title: '音訊輸出',
          subtitle: 'Windows ASIO 獨佔模式',
          detail: 'FiiO K9 Pro USB ASIO (96.0 kHz / 24-bit)',
          quality: SignalQuality.lossless,
        ),
      ],
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
  List<LyricLine> get currentLyrics {
    final trk = _state.track;
    if (trk == null) return const [];
    if (_userLyrics.containsKey(trk.id)) {
      return [
        LyricLine(
          start: Duration.zero,
          end: const Duration(seconds: 30),
          text: _userLyrics[trk.id]!,
        )
      ];
    }
    if (trk.id == 'trk-001') {
      return _lyrics;
    }
    return const [];
  }

  @override
  List<TrackInfo> get queue => _queue;

  @override
  Future<int> scanDirectory(String path) async => _queue.length;

  @override
  Future<List<TrackInfo>> searchLibrary(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return List<TrackInfo>.from(_queue);
    }
    return _queue
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q) ||
              t.album.toLowerCase().contains(q),
        )
        .toList();
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
    _signalPath = _buildSignalPath();
    if (!_signalPathController.isClosed) {
      _signalPathController.add(_signalPath);
    }
  }

  @override
  Future<void> play({TrackInfo? track}) async {
    if (track != null) {
      final idx = _queue.indexWhere((t) => t.id == track.id);
      if (idx >= 0) {
        _currentIndex = idx;
      }
      _emitState(
        _state.copyWith(
          status: PlaybackStatus.playing,
          track: track,
          position: Duration.zero,
        ),
      );
      _emitSignalPath();
    } else {
      _emitState(_state.copyWith(status: PlaybackStatus.playing));
    }
  }

  @override
  Future<void> pause() async {
    _emitState(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> resume() async {
    _emitState(_state.copyWith(status: PlaybackStatus.playing));
  }

  @override
  Future<void> togglePlayPause() async {
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else if (_state.status == PlaybackStatus.paused) {
      await resume();
    } else {
      await play();
    }
  }

  @override
  Future<void> reconnectDevice() async {
    _emitState(_state.copyWith(deviceLost: false));
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    return {
      'state_code': _state.status.code,
      'state_name': _state.status.name,
      'position_ms': _state.position.inMilliseconds,
      'duration_ms': _state.track?.duration.inMilliseconds ?? 0,
      'clock_source': _state.clockSource,
      'seek_epoch': _state.seekEpoch,
      'is_seeking': _state.isSeeking,
      'dsp_bypassed': _dspBypassed,
      'strict_bit_perfect': _strictBitPerfect,
      'volume': _state.volume,
      'last_error': _state.lastError,
      'device_lost': _state.deviceLost,
      'current_track_id': _state.track?.id,
    };
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    if (_userCovers.containsKey(trackId)) {
      return {
        'found': true,
        'cache_path': _userCovers[trackId],
        'mime_type': 'image/jpeg',
        'source_kind': 'user',
        'width': maxDim,
        'height': maxDim,
      };
    }
    return {
      'found': false,
      'source_kind': 'placeholder',
      'cache_path': null,
    };
  }

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) async {
    _userCovers[trackId] = imagePath;
    return true;
  }

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) async {
    _userCovers.remove(trackId);
    return true;
  }

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) async {
    return {
      'rescanned_count': _queue.length,
      'updated_count': _queue.length,
      'status': 'ok',
    };
  }

  @override
  Future<Map<String, dynamic>?> getLyrics(
    String trackId, {
    String? path,
  }) async {
    if (_userLyrics.containsKey(trackId)) {
      return {
        'found': true,
        'kind': 'synced',
        'source': 'user_file',
        'format': 'plain',
        'offset_ms': 0,
        'lines': [
          {
            'start_ms': 0,
            'end_ms': 30000,
            'text': _userLyrics[trackId]!,
            'words': [],
          }
        ],
      };
    }
    if (trackId == 'trk-001') {
      return {
        'found': true,
        'kind': 'synced',
        'source': 'embedded_synced',
        'format': 'enhanced_lrc',
        'offset_ms': 0,
        'lines': _lyrics
            .map(
              (l) => {
                'start_ms': l.start.inMilliseconds,
                'end_ms': l.end.inMilliseconds,
                'text': l.text,
                'words': l.words
                    .map(
                      (w) => {
                        'text': w.text,
                        'start_ms': w.start.inMilliseconds,
                        'end_ms': w.end.inMilliseconds,
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      };
    }
    return {
      'found': false,
      'kind': 'none',
      'source': 'none',
      'format': 'plain',
      'offset_ms': 0,
      'lines': [],
    };
  }

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) async {
    _userLyrics[trackId] = filePath;
    return true;
  }

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) async {
    _userLyrics.remove(trackId);
    return true;
  }

  @override
  Future<void> stop() async {
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.stopped,
        position: Duration.zero,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    final maxDur = _state.track?.duration ?? const Duration(minutes: 4);
    final clamped = position < Duration.zero
        ? Duration.zero
        : (position > maxDur ? maxDur : position);
    _emitState(_state.copyWith(position: clamped));
  }

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    _savedNormalVolume = clamped;
    if (_strictBitPerfect) {
      _emitState(_state.copyWith(volume: 1.0, isMuted: false));
      return;
    }
    _emitState(
      _state.copyWith(
        volume: clamped,
        isMuted: clamped == 0.0,
      ),
    );
  }

  @override
  Future<void> toggleMute() async {
    if (_strictBitPerfect) return;
    _emitState(_state.copyWith(isMuted: !_state.isMuted));
  }

  @override
  Future<void> next() async {
    _currentIndex = (_currentIndex + 1) % _queue.length;
    _emitState(
      _state.copyWith(
        track: _queue[_currentIndex],
        position: Duration.zero,
      ),
    );
    _emitSignalPath();
  }

  @override
  Future<void> previous() async {
    _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
    _emitState(
      _state.copyWith(
        track: _queue[_currentIndex],
        position: Duration.zero,
      ),
    );
    _emitSignalPath();
  }

  @override
  Future<void> toggleDspBypass() async {
    if (_strictBitPerfect) {
      _dspBypassed = true;
      _emitSignalPath();
      return;
    }
    _forcedQuality = null;
    _dspBypassed = !_dspBypassed;
    _savedNormalBypass = _dspBypassed;
    _emitSignalPath();
  }

  @override
  void setSimulatedQuality(SignalQuality quality) {
    _forcedQuality = quality;
    if (quality == SignalQuality.lossless) {
      _dspBypassed = true;
    } else if (quality == SignalQuality.enhanced) {
      _dspBypassed = false;
    }
    _emitSignalPath();
  }

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100}) async => [
    const CanonicalAlbumSummary(
      id: 'alb-dsotm',
      title: 'The Dark Side of the Moon',
      artist: 'Pink Floyd',
      year: 1973,
      availableProviders: ['qobuz', 'local'],
    ),
    const CanonicalAlbumSummary(
      id: 'alb-wall',
      title: 'The Wall',
      artist: 'Pink Floyd',
      year: 1979,
      availableProviders: ['tidal'],
    ),
  ];

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    return CanonicalAlbumDetail(
      id: albumId,
      title: albumId == 'alb-wall' ? 'The Wall' : 'The Dark Side of the Moon',
      artistName: 'Pink Floyd',
      releaseYear: albumId == 'alb-wall' ? 1979 : 1973,
      editorialBio: '跨平台母帶高解析認證標準版本。',
      versions: const [
        AlbumVersionInfo(
          id: 'ver-qobuz',
          provider: 'qobuz',
          externalAlbumId: 'qb-001',
          editionLabel: '24-bit 高解析錄音室母帶',
          codec: 'flac',
          sampleRateHz: 96000,
          bitDepth: 24,
          tracks: [
            AlbumVersionTrackInfo(
              id: 'trk-001',
              title: 'Time',
              discNumber: 1,
              trackNumber: 1,
              durationMs: 245000,
              codec: 'flac',
              sampleRateHz: 96000,
              bitDepth: 24,
              externalTrackId: 'qb-trk-001',
            ),
          ],
        ),
        AlbumVersionInfo(
          id: 'ver-local',
          provider: 'local',
          externalAlbumId: 'loc-001',
          editionLabel: 'SACD DSD64 Rip',
          codec: 'dsf',
          sampleRateHz: 2822400,
          bitDepth: 1,
          isDsd: true,
          tracks: [
            AlbumVersionTrackInfo(
              id: 'trk-002',
              title: 'Money',
              discNumber: 1,
              trackNumber: 2,
              durationMs: 232000,
              codec: 'dsf',
              sampleRateHz: 2822400,
              bitDepth: 1,
              externalTrackId: 'loc-trk-002',
            ),
          ],
        ),
      ],
      credits: const [
        AlbumCreditInfo(
          artistId: 'art-pf',
          artistName: 'Pink Floyd',
          role: '主創藝術家',
          albumId: 'alb-dsotm',
          albumTitle: 'The Dark Side of the Moon',
        ),
        AlbumCreditInfo(
          artistId: 'art-ap',
          artistName: 'Alan Parsons',
          role: '錄音工程師',
          albumId: 'alb-dsotm',
          albumTitle: 'The Dark Side of the Moon',
        ),
        AlbumCreditInfo(
          artistId: 'art-dg',
          artistName: 'David Gilmour',
          role: '吉他 / 製作人',
          albumId: 'alb-dsotm',
          albumTitle: 'The Dark Side of the Moon',
        ),
      ],
    );
  }

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) async {
    return ArtistDetailInfo(
      id: artistId,
      name: artistId == 'art-ap' ? 'Alan Parsons' : 'Pink Floyd',
      sortName: artistId == 'art-ap' ? 'Parsons, Alan' : 'Pink Floyd',
      biography: '前衛搖滾傳奇與錄音室先驅。',
      albums: await getAlbums(),
      credits: const [
        AlbumCreditInfo(
          artistId: 'art-ap',
          artistName: 'Alan Parsons',
          role: '錄音工程師',
          albumId: 'alb-dsotm',
          albumTitle: 'The Dark Side of the Moon',
        ),
      ],
    );
  }

  @override
  Future<int> deduplicateLibrary() async => 1;

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) async => {
    'albums_processed': 2,
    'albums_enriched': 2,
    'credits_added': 3,
  };

  @override
  Future<DspPipelineConfigModel> getDspConfig() async => _dspConfig;

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) async {
    _savedNormalBypass = config.bypass;
    if (_strictBitPerfect) {
      _dspConfig = config.copyWith(bypass: true);
      _dspBypassed = true;
    } else {
      _dspConfig = config;
      _dspBypassed = config.bypass;
    }
    _emitSignalPath();
  }

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) async {
    final parsed = <PeqBandModel>[];
    final re = RegExp(
      r'Filter\s+\d+:\s+ON\s+(\w+)\s+Fc\s+([\d.]+)\s+Hz\s+Gain\s+([+-]?[\d.]+)\s+dB\s+Q\s+([\d.]+)',
      caseSensitive: false,
    );
    for (final m in re.allMatches(autoEqTxt)) {
      parsed.add(
        PeqBandModel(
          filterType: m.group(1)!.toUpperCase() == 'LSC'
              ? 'low_shelf'
              : (m.group(1)!.toUpperCase() == 'HSC' ? 'high_shelf' : 'peaking'),
          frequencyHz: double.tryParse(m.group(2)!) ?? 1000.0,
          gainDb: double.tryParse(m.group(3)!) ?? 0.0,
          qFactor: double.tryParse(m.group(4)!) ?? 1.414,
        ),
      );
    }
    if (parsed.isNotEmpty) {
      _dspConfig = _dspConfig.copyWith(peqBands: parsed, bypass: false);
      _dspBypassed = false;
      _emitSignalPath();
    }
    return parsed;
  }

  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async {
    _tracker.syncActiveFromDevices(_devices);
    return _devices;
  }

  @override
  String? get activeDeviceId => _tracker.activeDeviceId;

  @override
  bool get isSystemOutputActive => _systemOutputActive;

  @override
  String? get lastError => _lastError;

  @override
  int get preferredBufferFrames => _preferredBufferFrames;

  @override
  Future<bool> setBufferFrames(int frames) async {
    _preferredBufferFrames = frames.clamp(32, 32768);
    return true;
  }

  @override
  Map<String, PlaybackState> get devicePlaybackStates =>
      _tracker.snapshotDevices(_state);

  @override
  Map<String, PlaybackState> get zonePlaybackStates =>
      _tracker.snapshotZones(activeLocalState: _state);

  @override
  Future<void> setDeviceVolume(String deviceId, double volume) async {
    if (deviceId == activeDeviceId) {
      await setVolume(volume);
      return;
    }
    _tracker.setDeviceVolume(deviceId, volume);
  }

  @override
  Future<void> toggleDevicePlayPause(String deviceId) async {
    if (deviceId == activeDeviceId) {
      await togglePlayPause();
      return;
    }
    await selectAudioDevice(deviceId);
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else {
      await play(track: _state.track ?? _queue.firstOrNull);
    }
  }

  @override
  Future<void> toggleZonePlayPause(String zoneId) async {
    final z = _zones.where((item) => item.id == zoneId).firstOrNull;
    final zoneState = zonePlaybackStates[zoneId];
    final isPlaying = zoneState?.status == PlaybackStatus.playing;
    if (z == null || !z.backend.startsWith('network_')) {
      await togglePlayPause();
      _tracker.updateZoneAction(
        zoneId,
        _state.status == PlaybackStatus.playing ? 'play' : 'pause',
        track: _state.track,
      );
      return;
    }
    await castToZone(zoneId, isPlaying ? 'pause' : 'play');
  }

  @override
  Future<void> selectAudioDevice(String? deviceId, {int backendIndex = -1}) async {
    final trimmed = deviceId?.trim();
    if (trimmed == null ||
        trimmed.isEmpty ||
        trimmed == AudioService.systemOutputId) {
      _lastError = null;
      _systemOutputActive = true;
      return;
    }
    _systemOutputActive = false;
    _lastError = null;
    final result = _tracker.switchDevice(
      nextDeviceId: trimmed,
      currentState: _state,
      currentQueueIndex: _currentIndex,
    );
    if (result.switched) {
      _currentIndex = result.queueIndex.clamp(
        0,
        _queue.isEmpty ? 0 : _queue.length - 1,
      );
      _emitState(result.restoredState);
    }
    for (var i = 0; i < _devices.length; i++) {
      final d = _devices[i];
      _devices[i] = AudioDeviceInfo(
        id: d.id,
        name: d.name,
        backend: d.backend,
        isDefault: d.id == trimmed,
        isExclusive: d.isExclusive,
        supportedSampleRates: d.supportedSampleRates,
      );
    }
  }

  @override
  Future<List<AudioZoneInfo>> listZones() async {
    _tracker.syncZones(_zones, activeLocalState: _state);
    return List.unmodifiable(_zones);
  }

  @override
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  }) async {
    if (!_zones.any((z) => z.backend == 'network_airplay')) {
      _zones.add(
        const AudioZoneInfo(
          id: 'airplay-bedroom',
          name: 'Bedroom AirPlay Receiver',
          backend: 'network_airplay',
          volume: 0.6,
          clockOffsetUs: -420,
          rttUs: 610,
          driftPpm: -0.8,
        ),
      );
    }
    _tracker.syncZones(_zones, activeLocalState: _state);
    return List.unmodifiable(_zones);
  }

  @override
  Future<void> groupZones(String groupId, List<String> zoneIds) async {
    for (var i = 0; i < _zones.length; i++) {
      final z = _zones[i];
      if (zoneIds.contains(z.id)) {
        _zones[i] = AudioZoneInfo(
          id: z.id,
          name: z.name,
          backend: z.backend,
          groupId: groupId,
          volume: z.volume,
          isActive: z.isActive,
          clockOffsetUs: z.clockOffsetUs,
          rttUs: z.rttUs,
          driftPpm: z.driftPpm,
        );
      }
    }
  }

  @override
  Future<void> setZoneVolume(String zoneId, double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    for (var i = 0; i < _zones.length; i++) {
      final z = _zones[i];
      if (z.id == zoneId) {
        _zones[i] = AudioZoneInfo(
          id: z.id,
          name: z.name,
          backend: z.backend,
          groupId: z.groupId,
          volume: clamped,
          isActive: z.isActive,
          clockOffsetUs: z.clockOffsetUs,
          rttUs: z.rttUs,
          driftPpm: z.driftPpm,
        );
      }
    }
    _tracker.setZoneVolume(zoneId, clamped);
    if (zoneId == 'zone-local') {
      await setVolume(clamped);
    }
  }

  @override
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  }) async {
    return ClockSyncMeasurementModel(
      zoneId: zoneId,
      offsetUs: 120,
      rttUs: 450,
      driftPpm: 0.4,
      sampleCount: 5,
    );
  }

  @override
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  }) async {
    _tracker.updateZoneAction(
      zoneId,
      action,
      track: _state.track ?? _queue.firstOrNull,
    );
    return {
      'zone_id': zoneId,
      'action': action,
      'status': 'ok',
    };
  }

  File _providerPrefsFile() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return File(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}provider_prefs.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_provider_prefs.json',
    );
  }

  Future<void> _ensureProvidersLoaded() async {
    if (_providersLoaded) return;
    _providersLoaded = true;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final file = _providerPrefsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      final activeKinds = decoded.map((e) => e.toString()).toSet();
      for (var i = 0; i < _providers.length; i++) {
        final k = _providers[i].kind;
        if (k == 'local') continue;
        final loggedIn = activeKinds.contains(k);
        _providers[i] = ProviderStatusInfo(
          kind: k,
          isConfigured: loggedIn,
          isOnline: loggedIn,
        );
      }
    } catch (_) {
      // Keep default provider states on unreadable prefs.
    }
  }

  Future<void> _saveProviderPrefs() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final file = _providerPrefsFile();
      await file.parent.create(recursive: true);
      final active = _providers
          .where((p) => p.kind != 'local' && (p.isOnline || p.isConfigured))
          .map((p) => p.kind)
          .toList();
      await file.writeAsString(jsonEncode(active));
    } catch (_) {
      // Ignore write failures gracefully.
    }
  }

  @override
  Future<List<ProviderStatusInfo>> listProviders() async {
    await _ensureProvidersLoaded();
    return List.unmodifiable(_providers);
  }

  @override
  Future<bool> configureProvider(String kind, Map<String, dynamic> config) async {
    await _ensureProvidersLoaded();
    final isDisconnect = config['disconnect'] == true;
    final idx = _providers.indexWhere((p) => p.kind == kind);
    final nextStatus = ProviderStatusInfo(
      kind: kind,
      isConfigured: !isDisconnect,
      isOnline: !isDisconnect,
    );
    if (idx >= 0) {
      _providers[idx] = nextStatus;
    } else {
      _providers.add(nextStatus);
    }
    await _saveProviderPrefs();
    return true;
  }

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() async => const TidalPkceStartInfo(
    authUrl: 'https://login.tidal.com/authorize?response_type=code&code_challenge=demo',
    verifier: 'demo_verifier_1234567890_abcdefghijklmnopqrstuvwxyz',
    challenge: 'demo_challenge',
  );

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) async {
    await configureProvider('tidal', {'code': code});
    return true;
  }

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) async {
    final samples = <String, TrackInfo>{
      'apple_music': const TrackInfo(
        id: 'am-001',
        title: '群青（ALAC Studio Master）',
        artist: 'YOASOBI',
        album: 'THE BOOK 2',
        duration: Duration(minutes: 4, seconds: 8),
        format: AudioFormat(
          codec: AudioCodec.alac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'Apple Music Lossless',
      ),
      'youtube_music': const TrackInfo(
        id: 'ytm-001',
        title: '偶像 Idol (Studio Live)',
        artist: 'YOASOBI',
        album: 'YOASOBI 5th Anniversary Live',
        duration: Duration(minutes: 3, seconds: 42),
        format: AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'YouTube Music',
      ),
      'deezer': const TrackInfo(
        id: 'dz-001',
        title: 'Get Lucky (Studio Edition)',
        artist: 'Daft Punk',
        album: 'Random Access Memories',
        duration: Duration(minutes: 6, seconds: 9),
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
        providerName: 'Deezer HiFi',
      ),
    };
    final sample = samples[kind];
    if (sample != null && !_queue.any((t) => t.id == sample.id)) {
      _queue.add(sample);
    }
    return {
      'provider': kind,
      'tracks_count': _queue.length,
    };
  }

  @override
  Future<List<UserProfileInfo>> listProfiles() async =>
      List.unmodifiable(_profiles);

  String get activeProfileId => _activeProfileId;

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) async {
    final created = UserProfileInfo(
      id: 'prof-${_profiles.length + 1}',
      name: name,
      avatarColor: avatarColor,
      isDefault: false,
    );
    _profiles.add(created);
    return created;
  }

  @override
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  }) async {
    final idx = _profiles.indexWhere((p) => p.id == profileId);
    if (idx < 0) return false;
    final cur = _profiles[idx];
    _profiles[idx] = UserProfileInfo(
      id: cur.id,
      name: name ?? cur.name,
      avatarColor: avatarColor ?? cur.avatarColor,
      isDefault: isDefault ?? cur.isDefault,
    );
    return true;
  }

  @override
  Future<void> switchProfile(String profileId) async {
    _activeProfileId = profileId;
  }

  @override
  Future<bool> deleteProfile(String profileId) async {
    final idx = _profiles.indexWhere((p) => p.id == profileId && !p.isDefault);
    if (idx < 0) return false;
    _profiles.removeAt(idx);
    if (_activeProfileId == profileId) {
      _activeProfileId = _profiles.first.id;
    }
    return true;
  }

  @override
  bool get isStrictBitPerfect => _strictBitPerfect;

  @override
  DsdOutputModeOption get dsdOutputMode => _dsdOutputMode;

  @override
  Future<void> setStrictBitPerfect(bool enabled) async {
    if (_strictBitPerfect == enabled) return;
    _strictBitPerfect = enabled;
    if (enabled) {
      _savedNormalBypass = _dspBypassed;
      _savedNormalVolume = _state.volume;
      _dspBypassed = true;
      _dspConfig = _dspConfig.copyWith(bypass: true);
      _forcedQuality = SignalQuality.lossless;
      _emitState(_state.copyWith(volume: 1.0, isMuted: false));
    } else {
      _dspBypassed = _savedNormalBypass;
      _dspConfig = _dspConfig.copyWith(bypass: _savedNormalBypass);
      _forcedQuality = null;
      _emitState(
        _state.copyWith(
          volume: _savedNormalVolume,
          isMuted: _savedNormalVolume == 0.0,
        ),
      );
    }
    _emitSignalPath();
  }

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) async {
    _dsdOutputMode = mode;
    _emitSignalPath();
  }

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() async {
    final devs = await listAudioDevices();
    return devs.map((d) {
      final isAsio = d.backend == 'windows_asio';
      final isShared = d.backend == 'windows_wasapi_shared';
      final isExcl = d.backend == 'windows_wasapi_exclusive' ||
          d.backend == 'mobile_direct' ||
          d.isExclusive;
      final modes = <String>[
        if (isAsio) ...[
          'asio_pcm',
          'asio_native_dsd',
          'dop_over_asio',
        ] else if (isShared) ...[
          'wasapi_shared',
          'dsd_to_pcm',
        ] else ...[
          'wasapi_exclusive',
          if (d.supportedSampleRates.contains(176400) ||
              d.supportedSampleRates.contains(192000))
            'dop_over_wasapi_exclusive',
        ],
      ];
      return AudioDeviceCapabilitiesModel(
        deviceId: d.id,
        name: d.name,
        backend: d.backend,
        transport: isAsio ? 'asio' : (isShared ? 'speakers' : 'usb_dac'),
        isDefault: d.isDefault,
        isOsDefault: d.isDefault,
        isExclusive: !isShared && d.isExclusive,
        hardwareSupportsExclusive: isExcl,
        supportedSampleRates: d.supportedSampleRates,
        supportedBitDepths: isShared ? const [32] : const [16, 24, 32],
        supportedContainerBits: isShared ? const [32] : const [16, 24, 32],
        supportedChannels: const [2],
        supportedOutputModes: modes,
        supportsNativeDsd: isAsio,
        supportsDop: !isShared && d.isExclusive,
        supportsFloat32: isShared || isAsio,
        asioAvailable: isAsio,
        exclusiveAvailable: !isShared && d.isExclusive,
        bufferSizeSupported: !isShared,
        minBufferFrames: isShared ? null : 64,
        maxBufferFrames: isShared ? null : 2048,
        defaultBufferFrames: isShared ? null : 512,
      );
    }).toList();
  }

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() async {
    final trk = _state.track;
    final fmt = trk?.format;
    final dev = (await listAudioDevices()).firstWhere(
      (d) => d.id == activeDeviceId,
      orElse: () => const AudioDeviceInfo(
        id: 'mock',
        name: 'Virtual DAC',
        backend: 'windows_wasapi_shared',
      ),
    );
    return AudioEngineOutputInfoModel(
      source: AudioSourceInfoModel(
        codec: fmt?.codec.displayName ?? 'FLAC',
        sampleRateHz: fmt?.sampleRateHz ?? 96000,
        bitDepth: fmt?.bitDepth ?? 24,
        channels: fmt?.channels ?? 2,
        channelLayout: (fmt?.channels ?? 2) == 1 ? 'Mono (1.0)' : 'Stereo (L/R)',
        sourceFormat: fmt?.label ?? 'FLAC 96 kHz / 24-bit',
        title: trk?.title,
        artist: trk?.artist,
        album: trk?.album,
      ),
      decoder: AudioDecoderInfoModel(
        decoderType: 'Mock UI Preview Decoder (未連結原生 Rust 引擎)',
        decodedPcmFormat: 'Preview Mode',
        sampleRateHz: fmt?.sampleRateHz ?? 96000,
        containerBits: fmt?.bitDepth ?? 24,
        validBits: fmt?.bitDepth ?? 24,
        integerPreserved: _strictBitPerfect,
      ),
      output: AudioOutputInfoModel(
        selectedDevice: dev.name,
        transportKind: dev.backend == 'windows_asio' ? 'ASIO 驅動' : '虛擬預覽',
        audioApi: dev.backend,
        outputMode: dev.backend == 'windows_wasapi_shared'
            ? 'WASAPI Shared'
            : (_strictBitPerfect ? 'Strict Mode (Preview)' : 'Mock Output'),
        sampleRateHz: fmt?.sampleRateHz ?? 96000,
        containerBits: 32,
        validBits: fmt?.bitDepth ?? 24,
        channels: fmt?.channels ?? 2,
        bufferSizeFrames: _preferredBufferFrames,
        dspStatus: _dspBypassed ? 'Bypassed' : 'Enabled',
        softwareVolumeStatus: _strictBitPerfect
            ? 'Disabled (Unity 1.0x)'
            : (_state.volume == 1.0 ? 'Unity (1.0x)' : 'Active Attenuated'),
        strictMode: dev.backend != 'windows_wasapi_shared' && _strictBitPerfect,
        hardwareVolumeRecommended:
            dev.backend != 'windows_wasapi_shared' && _strictBitPerfect,
        degradationReason: '目前為預覽模式（MockService），未進行原生硬體樣本驗證',
      ),
      verification: const AudioVerificationInfoModel(
        pcmSampleCheck: 'Not Active (Preview Service)',
        sampleHashMatch: false,
        formatMatch: false,
        outputPath: 'Preview (Unverified)',
        verificationLevel: 'Mock Preview Only — Native FFI Engine Not Loaded',
        status: 'NOT VERIFIED',
      ),
    );
  }

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() async {
    return const PairingInitiateInfo(
      pin: '849201',
      qrPayload: 'lumina://pair?pin=849201&host=127.0.0.1&port=9888',
      expiresInSec: 60,
    );
  }

  @override
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    if (port != 5353) {
      return MdnsDiscoveryClient.discover(
        targetHost: multicastHost,
        port: port,
        timeout: timeout,
      );
    }
    return const [
      DiscoveredServerInfo(
        serverName: 'Lumina-Desktop',
        host: '127.0.0.1',
        port: 9888,
        txtRecords: {'version': '0.1.0', 'api_version': '1'},
      ),
    ];
  }

  @override
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  }) async {
    _connectionMode = baseUrl.startsWith('https://')
        ? ConnectionMode.wanRemote
        : ConnectionMode.lanRemote;
    _activeServerUrl = baseUrl;
    return 'lum_sec_mock_token_$pin';
  }

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) async {
    _connectionMode = ConnectionMode.wanRemote;
    _activeServerUrl = httpsBaseUrl;
    return true;
  }

  @override
  Future<void> switchToLocalMode() async {
    _connectionMode = ConnectionMode.localOrUsbDac;
    _activeServerUrl = null;
  }

  @override
  void dispose() {
    _stateController.close();
    _signalPathController.close();
    _positionController.close();
  }
}

