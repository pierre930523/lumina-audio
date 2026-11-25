import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/lyric.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/recommendation_models.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/server_audio_service.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/playback_backend.dart';
import 'package:lumina_app/services/streaming/recommendation_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/artwork/streaming_cover_image.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/mini_player/quick_queue_popover.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

const AudioFormat _cdFlac = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
);

const AudioFormat _hiRes192 = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 192000,
  bitDepth: 24,
  channels: 2,
);

TrackInfo _makeTrack(
  String id, {
  String title = '',
  String artist = 'Test Artist',
  String album = 'Test Album',
  String providerName = '',
  String? coverUrl,
  Duration duration = const Duration(minutes: 3, seconds: 20),
  AudioFormat format = _cdFlac,
  String? filePath,
}) {
  final resolvedProvider = providerName.isNotEmpty
      ? providerName
      : switch (id.split(':').first) {
          'ytm' => 'YouTube Music',
          'tidal' => 'Tidal',
          'qobuz' => 'Qobuz',
          'deezer' => 'Deezer',
          'apple' => 'Apple Music',
          _ => 'Local Library',
        };
  return TrackInfo(
    id: id,
    title: title.isEmpty ? 'Title $id' : title,
    artist: artist,
    album: album,
    duration: duration,
    coverUrl: coverUrl,
    albumArtUrl: coverUrl,
    format: format,
    providerName: resolvedProvider,
    filePath: filePath,
  );
}

class _CountingStreamResolver implements StreamResolver {
  @override
  final String providerId;

  @override
  final ProviderCapabilities capabilities;

  final Future<StreamSourceSpec> Function(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) onResolve;

  final List<StreamKey> resolvedKeys = <StreamKey>[];

  _CountingStreamResolver({
    required this.providerId,
    required this.capabilities,
    required this.onResolve,
  });

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) {
    resolvedKeys.add(key);
    return onResolve(key, cancelToken: cancelToken);
  }
}

class _FakeRecProvider implements RecommendationProvider {
  @override
  final String recommendationProviderId;

  @override
  final ProviderCapabilities capabilities;

  int radioCalls = 0;
  Future<RadioPage> Function(
    TrackMetadata seed, {
    int limit,
    String? cursor,
    CancellationToken? cancel,
  })? onGetTrackRadio;

  _FakeRecProvider({
    required this.recommendationProviderId,
    required this.capabilities,
    this.onGetTrackRadio,
  });

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    radioCalls++;
    if (onGetTrackRadio != null) {
      return onGetTrackRadio!(seed, limit: limit, cursor: cursor, cancel: cancel);
    }
    return const RadioPage();
  }

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) async => const <FeedSection>[];

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async => null;
}

class _ControllableNativeAudioService extends MockAudioService {
  final StreamController<PlaybackState> _customStateCtrl =
      StreamController<PlaybackState>.broadcast();
  final StreamController<SignalPath> _customSignalCtrl =
      StreamController<SignalPath>.broadcast();
  final StreamController<Duration> _customPosCtrl =
      StreamController<Duration>.broadcast();

  final Map<String, List<LyricLine>> lyricsByTrackId = <String, List<LyricLine>>{};
  final List<String> lyricsLoadedForTrackIds = <String>[];
  int signalPathRefreshCount = 0;
  PlaybackState _customState = const PlaybackState(status: PlaybackStatus.stopped);
  SignalPath _customSignalPath = const SignalPath(
    overallQuality: SignalQuality.lossless,
    description: '44.1 kHz / 16-bit',
    nodes: <SignalPathNode>[],
    dspBypassed: true,
  );
  List<LyricLine> _activeLyrics = const <LyricLine>[];

  @override
  Stream<PlaybackState> get stateStream => _customStateCtrl.stream;

  @override
  Stream<SignalPath> get signalPathStream => _customSignalCtrl.stream;

  @override
  Stream<Duration> get positionStream => _customPosCtrl.stream;

  @override
  PlaybackState get currentState => _customState;

  @override
  SignalPath get currentSignalPath => _customSignalPath;

  @override
  List<LyricLine> get currentLyrics => _activeLyrics;

  void _loadLyricsAndSignalPath(TrackInfo? track, {SignalPath? signalPath}) {
    if (track != null) {
      lyricsLoadedForTrackIds.add(track.id);
      _activeLyrics = lyricsByTrackId[track.id] ?? const <LyricLine>[];
    } else {
      _activeLyrics = const <LyricLine>[];
    }
    signalPathRefreshCount++;
    if (signalPath != null) {
      _customSignalPath = signalPath;
    } else if (track != null) {
      _customSignalPath = SignalPath(
        overallQuality: track.format.sampleRateHz > 48000
            ? SignalQuality.lossless
            : SignalQuality.highQuality,
        description: track.format.label,
        nodes: const <SignalPathNode>[],
        dspBypassed: true,
      );
    }
    if (!_customSignalCtrl.isClosed) {
      _customSignalCtrl.add(_customSignalPath);
    }
  }

  void pushBackendSwap(
    PlaybackState nextState, {
    SignalPath? signalPath,
    bool reloadLyrics = true,
  }) {
    if (reloadLyrics) {
      _loadLyricsAndSignalPath(nextState.track, signalPath: signalPath);
    }
    _customState = nextState;
    if (!_customStateCtrl.isClosed) {
      _customStateCtrl.add(nextState);
    }
    if (!_customPosCtrl.isClosed) {
      _customPosCtrl.add(nextState.position);
    }
  }

  @override
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) async {
    _loadLyricsAndSignalPath(track);
    _customState = _customState.copyWith(
      status: PlaybackStatus.playing,
      track: track,
      position: Duration.zero,
      clearLastError: true,
    );
    if (!_customStateCtrl.isClosed) {
      _customStateCtrl.add(_customState);
    }
    if (!_customPosCtrl.isClosed) {
      _customPosCtrl.add(Duration.zero);
    }
  }

  @override
  Future<void> play({TrackInfo? track}) async {
    final target = track ?? _customState.track;
    if (target == null) return;
    _loadLyricsAndSignalPath(target);
    _customState = _customState.copyWith(
      status: PlaybackStatus.playing,
      track: target,
      position: Duration.zero,
      clearLastError: true,
    );
    if (!_customStateCtrl.isClosed) {
      _customStateCtrl.add(_customState);
    }
    if (!_customPosCtrl.isClosed) {
      _customPosCtrl.add(Duration.zero);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    _customState = _customState.copyWith(position: position);
    if (!_customStateCtrl.isClosed) {
      _customStateCtrl.add(_customState);
    }
    if (!_customPosCtrl.isClosed) {
      _customPosCtrl.add(position);
    }
  }

  @override
  Future<void> stop() async {
    _customState = _customState.copyWith(
      status: PlaybackStatus.stopped,
      position: Duration.zero,
    );
    if (!_customStateCtrl.isClosed) {
      _customStateCtrl.add(_customState);
    }
  }

  @override
  void dispose() {
    _customStateCtrl.close();
    _customSignalCtrl.close();
    _customPosCtrl.close();
    super.dispose();
  }
}

class _EventDrivenPlaybackBackend extends PlaybackBackend {
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  PlaybackState _state = const PlaybackState(status: PlaybackStatus.stopped);
  final List<TrackInfo> playCalls = <TrackInfo>[];

  @override
  PlaybackState get currentState => _state;

  @override
  Stream<PlaybackState> get stateStream => _controller.stream;

  void emit(PlaybackState next) {
    _state = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }

  @override
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    playCalls.add(track);
    emit(
      _state.copyWith(
        status: PlaybackStatus.playing,
        track: track,
        position: Duration.zero,
        clearLastError: true,
      ),
    );
  }

  @override
  Future<void> pause() async =>
      emit(_state.copyWith(status: PlaybackStatus.paused));

  @override
  Future<void> resume() async =>
      emit(_state.copyWith(status: PlaybackStatus.playing));

  @override
  Future<void> seek(Duration position, {required int epoch}) async =>
      emit(_state.copyWith(position: position, seekEpoch: epoch));

  @override
  Future<void> setVolume(double volume) async =>
      emit(_state.copyWith(volume: volume));

  @override
  Future<void> stop({required int epoch}) async =>
      emit(_state.copyWith(status: PlaybackStatus.stopped));

  @override
  void dispose() {
    _controller.close();
  }
}

StreamResolverRegistry _buildRegistry() {
  final registry = StreamResolverRegistry();
  registry.register(
    _CountingStreamResolver(
      providerId: 'youtube_music',
      capabilities: ProviderCapabilities.youtubeMusic,
      onResolve: (key, {cancelToken}) async => DirectRangeSpec(
        key: key,
        url: 'https://ytm.example/${key.trackId}.m4a',
        mimeType: 'audio/mp4',
        hintExtension: 'm4a',
      ),
    ),
    idPrefixes: const <String>['ytm:', 'streaming:youtube_music:'],
    providerNames: const <String>['youtube music'],
  );
  registry.register(
    _CountingStreamResolver(
      providerId: 'tidal',
      capabilities: ProviderCapabilities.tidal,
      onResolve: (key, {cancelToken}) async => DirectRangeSpec(
        key: key,
        url: 'https://tidal.example/${key.trackId}.flac',
        mimeType: 'audio/flac',
        hintExtension: 'flac',
        audioFormat: _hiRes192,
      ),
    ),
    idPrefixes: const <String>['tidal:', 'streaming:tidal:'],
    providerNames: const <String>['tidal'],
  );
  registry.register(
    _CountingStreamResolver(
      providerId: 'qobuz',
      capabilities: ProviderCapabilities.qobuz,
      onResolve: (key, {cancelToken}) async => DirectRangeSpec(
        key: key,
        url: 'https://qobuz.example/${key.trackId}.flac',
        mimeType: 'audio/flac',
        hintExtension: 'flac',
      ),
    ),
    idPrefixes: const <String>['qobuz:', 'streaming:qobuz:'],
    providerNames: const <String>['qobuz'],
  );
  registry.register(const LocalStreamResolver());
  return registry;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Model contracts & FfiAudioService state JSON hydration', () {
    test('TrackInfo.responsiveArtworkKey normalizes providerId:cleanTrackId across providers', () {
      expect(
        _makeTrack('ytm:abc123').responsiveArtworkKey,
        'youtube_music:abc123',
      );
      expect(
        _makeTrack('streaming:youtube_music:abc123').responsiveArtworkKey,
        'youtube_music:abc123',
      );
      expect(
        _makeTrack('tidal:999001').responsiveArtworkKey,
        'tidal:999001',
      );
      expect(
        _makeTrack('999001', providerName: 'Tidal').responsiveArtworkKey,
        'tidal:999001',
      );
      expect(
        _makeTrack('local_42', filePath: '/music/song.flac').responsiveArtworkKey,
        'local:local_42',
      );
    });

    test('DualDeckStatus parses swap_generation/swapGeneration and active_track/current_track', () {
      final status = DualDeckStatus.fromJson(const <String, dynamic>{
        'active_deck': 'deck_b',
        'deck_a_state': 'IDLE',
        'deck_b_state': 'PLAYING',
        'swap_generation': 4,
        'current_track': <String, dynamic>{
          'track_id': 'tidal:55',
          'provider_id': 'tidal',
          'title': 'Hi-Res Song',
        },
      });
      expect(status.swapGeneration, 4);
      expect(status.activeTrackJson?['track_id'], 'tidal:55');
      expect(status.toJson()['swap_generation'], 4);
      expect(status.copyWith(swapGeneration: 5).swapGeneration, 5);
      expect(
        status,
        DualDeckStatus.fromJson(const <String, dynamic>{
          'active_deck': 'deck_b',
          'deck_a_state': 'IDLE',
          'deck_b_state': 'PLAYING',
          'swapGeneration': 4,
          'active_track': <String, dynamic>{
            'track_id': 'tidal:55',
            'provider_id': 'tidal',
            'title': 'Hi-Res Song',
          },
        }),
      );
    });

    test('FfiAudioService encodes cover/provider payload and hydrates gapless swap_generation from state JSON', () async {
      final ffi = FfiAudioService(headless: true);
      addTearDown(ffi.dispose);

      final track1 = _makeTrack(
        'ytm:t1',
        title: 'First Track',
        artist: 'First Artist',
        album: 'First Album',
        coverUrl: 'https://i.ytimg.com/vi/t1/maxresdefault.jpg',
      );
      final encoded = jsonDecode(
        ffi.encodeStreamSpecPayloadForTest(
          track1,
          const DirectRangeSpec(
            key: StreamKey('youtube_music', 't1', 'default'),
            url: 'https://ytm.example/t1.m4a',
          ),
          epoch: 1,
        ),
      ) as Map<String, dynamic>;
      expect(encoded['track_id'], 'ytm:t1');
      expect(encoded['provider_id'], 'youtube_music');
      expect(encoded['cover_url'], 'https://i.ytimg.com/vi/t1/maxresdefault.jpg');
      expect(
        encoded['album_art_url'],
        'https://i.ytimg.com/vi/t1/maxresdefault.jpg',
      );

      // Prepare standby track 2 (NOT in _queue) so _standbyTracksById caches it.
      final autoTrack2 = _makeTrack(
        'tidal:auto_2',
        title: 'Auto Two Full',
        artist: 'Auto Artist Two',
        album: 'Auto Album Two',
        coverUrl: 'https://resources.tidal.com/images/auto2/1280x1280.jpg',
        duration: const Duration(seconds: 245),
        format: _hiRes192,
      );
      await ffi.prepareStandbySpecAsync(
        autoTrack2,
        const DirectRangeSpec(
          key: StreamKey('tidal', 'auto_2', 'default'),
          url: 'https://tidal.example/auto_2.flac',
        ),
        epoch: 2,
      );

      final states = <PlaybackState>[];
      final positions = <Duration>[];
      final sub1 = ffi.stateStream.listen(states.add);
      final sub2 = ffi.positionStream.listen(positions.add);
      addTearDown(() async {
        await sub1.cancel();
        await sub2.cancel();
      });

      // Simulate Gapless EOF swap (playing -> playing, swap_generation: 1) via test JSON.
      final accepted = ffi.processStateJsonForTest(const <String, dynamic>{
        'state_code': 2,
        'position_ms': 0,
        'duration_ms': 248000,
        'swap_generation': 1,
        'current_track_id': 'tidal:auto_2',
        'current_track': <String, dynamic>{
          'track_id': 'auto_2',
          'provider_id': 'tidal',
          'title': 'Auto Two Full',
          'artist': 'Auto Artist Two',
          'album': 'Auto Album Two',
          'cover_url': 'https://resources.tidal.com/images/auto2/1280x1280.jpg',
          'duration_ms': 248000,
        },
        'active_deck': 'deck_b',
        'deck_a_state': 'IDLE',
        'deck_b_state': 'PLAYING',
      });
      expect(accepted, isTrue);
      expect(ffi.currentState.swapGeneration, 1);
      expect(ffi.currentState.track?.id, 'tidal:auto_2');
      expect(ffi.currentState.track?.title, 'Auto Two Full');
      expect(ffi.currentState.track?.album, 'Auto Album Two');
      expect(
        ffi.currentState.track?.coverUrl,
        'https://resources.tidal.com/images/auto2/1280x1280.jpg',
      );
      expect(
        ffi.currentState.track?.duration,
        const Duration(milliseconds: 248000),
      );
      expect(ffi.currentState.track?.format.sampleRateHz, 192000);

      // Pure current_track JSON hydration (not in _queue or _standbyTracksById)
      final acceptedJsonOnly = ffi.processStateJsonForTest(const <String, dynamic>{
        'state_code': 2,
        'position_ms': 0,
        'duration_ms': 195000,
        'swap_generation': 2,
        'current_track_id': 'qobuz:json_only_3',
        'current_track': <String, dynamic>{
          'track_id': 'qobuz:json_only_3',
          'provider_id': 'qobuz',
          'title': 'JSON Only Track',
          'artist': 'JSON Artist',
          'album': 'JSON Album',
          'cover_url': 'https://static.qobuz.com/images/covers/3_max.jpg',
          'duration_ms': 195000,
        },
      });
      expect(acceptedJsonOnly, isTrue);
      expect(ffi.currentState.swapGeneration, 2);
      expect(ffi.currentState.track?.title, 'JSON Only Track');
      expect(ffi.currentState.track?.artist, 'JSON Artist');
      expect(ffi.currentState.track?.album, 'JSON Album');
      expect(
        ffi.currentState.track?.coverUrl,
        'https://static.qobuz.com/images/covers/3_max.jpg',
      );
      expect(ffi.currentState.track?.providerName, 'Qobuz');

      // stop() clears standby cache without resetting swap_generation tracking.
      await ffi.stop();
      final noSpuriousSwap = ffi.processStateJsonForTest(const <String, dynamic>{
        'state_code': 2,
        'position_ms': 100,
        'duration_ms': 195000,
        'swap_generation': 2,
        'current_track_id': 'qobuz:json_only_3',
      });
      expect(noSpuriousSwap, isTrue);
      expect(ffi.currentState.swapGeneration, 2);
    });
  });

  group('Unified Gapless, Cross-Rate, and Non-Dual-Deck EOF transitions', () {
    test('a) Same-rate Gapless EOF syncs user_queue & auto_queue, pops queues, refills <=2, reloads lyrics & signal path, and dedupes', () async {
      final audio = _ControllableNativeAudioService();
      final nativeBackend = NativePlaybackBackend(audio);
      final manager = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
        enableLiveWarmup: false,
      );
      final registry = _buildRegistry();

      final radioProvider = _FakeRecProvider(
        recommendationProviderId: 'youtube_music',
        capabilities: ProviderCapabilities.youtubeMusic,
        onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
          tracks: <TrackMetadata>[
            TrackMetadata(
              providerId: 'youtube_music',
              trackId: 'refill_1',
              title: 'Refill Song 1',
              artist: 'Refill Artist 1',
              album: 'Refill Album 1',
              durationMs: 210000,
              coverUrl: 'https://i.ytimg.com/vi/refill_1/maxresdefault.jpg',
              format: _cdFlac,
            ),
            TrackMetadata(
              providerId: 'youtube_music',
              trackId: 'refill_2',
              title: 'Refill Song 2',
              artist: 'Refill Artist 2',
              album: 'Refill Album 2',
              durationMs: 215000,
              coverUrl: 'https://i.ytimg.com/vi/refill_2/maxresdefault.jpg',
              format: _cdFlac,
            ),
          ],
        ),
      );

      final autoplay = AutoplayController(
        providerLookup: (pid) => pid == 'youtube_music' ? radioProvider : null,
        isGuestCapableLookup: (pid) => pid == 'youtube_music',
        refillTriggerRemaining: 2,
        refillTargetCount: 4,
      );
      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        autoplayController: autoplay,
        resolverRegistry: registry,
        nativeBackend: nativeBackend,
        debounceDelay: Duration.zero,
        lookaheadDelay: const Duration(seconds: 60),
      );
      final coordAudio = CoordinatingAudioService(
        inner: audio,
        coordinator: coordinator,
      );

      addTearDown(() {
        coordAudio.dispose();
        coordinator.dispose();
        autoplay.dispose();
        manager.dispose();
        nativeBackend.dispose();
        audio.dispose();
      });

      final u1 = _makeTrack(
        'ytm:u1',
        title: 'User Track 1',
        artist: 'Artist U1',
        album: 'User Album 1',
        coverUrl: 'https://i.ytimg.com/vi/u1/maxresdefault.jpg',
        duration: const Duration(seconds: 200),
      );
      final u2 = _makeTrack(
        'ytm:u2',
        title: 'User Track 2',
        artist: 'Artist U2',
        album: 'User Album 2',
        coverUrl: 'https://i.ytimg.com/vi/u2/maxresdefault.jpg',
        duration: const Duration(seconds: 220),
      );
      final a1 = _makeTrack(
        'ytm:a1',
        title: 'Auto Track 1',
        artist: 'Artist A1',
        album: 'Auto Album 1',
        coverUrl: 'https://i.ytimg.com/vi/a1/maxresdefault.jpg',
        duration: const Duration(seconds: 190),
      );
      final a2 = _makeTrack(
        'ytm:a2',
        title: 'Auto Track 2',
        artist: 'Artist A2',
        album: 'Auto Album 2',
        coverUrl: 'https://i.ytimg.com/vi/a2/maxresdefault.jpg',
        duration: const Duration(seconds: 195),
      );
      final a3 = _makeTrack(
        'ytm:a3',
        title: 'Auto Track 3',
        artist: 'Artist A3',
        album: 'Auto Album 3',
        coverUrl: 'https://i.ytimg.com/vi/a3/maxresdefault.jpg',
        duration: const Duration(seconds: 205),
      );

      audio.lyricsByTrackId['ytm:u2'] = const <LyricLine>[
        LyricLine(start: Duration.zero, end: Duration(seconds: 5), text: 'U2 Lyric Line'),
      ];
      audio.lyricsByTrackId['ytm:a1'] = const <LyricLine>[
        LyricLine(start: Duration.zero, end: Duration(seconds: 5), text: 'A1 Lyric Line'),
      ];

      final trackChanges = <TrackInfo>[];
      final queueUpdates = <List<TrackInfo>>[];
      final subTrack = coordAudio.trackChangedStream.listen(trackChanges.add);
      final subQueue = coordAudio.queueUpdatedStream.listen(queueUpdates.add);
      addTearDown(() async {
        await subTrack.cancel();
        await subQueue.cancel();
      });

      autoplay.setUserQueue(
        <TrackInfo>[u1, u2],
        currentTrack: u1,
        currentIndex: 0,
        bumpEpoch: false,
      );
      await autoplay.maybeTriggerRefill(seedOverride: TrackMetadata.fromTrackInfo(u1));
      // Seed exact autoQueue [a1, a2, a3] by replacing via promote/test setup or playing u1 with custom radio:
      autoplay.clearAutoQueue();
      // Directly set custom radio tracks once for u1 -> a1, a2, a3
      radioProvider.onGetTrackRadio = (seed, {limit = 10, cursor, cancel}) async {
        if (radioProvider.radioCalls <= 2) {
          return RadioPage(
            tracks: <TrackMetadata>[
              TrackMetadata.fromTrackInfo(a1),
              TrackMetadata.fromTrackInfo(a2),
              TrackMetadata.fromTrackInfo(a3),
            ],
          );
        }
        return RadioPage(
          tracks: <TrackMetadata>[
            TrackMetadata(
              providerId: 'youtube_music',
              trackId: 'refill_next',
              title: 'Refilled Next Track',
              artist: 'Refill Artist',
              album: 'Refill Album',
              durationMs: 210000,
              coverUrl: 'https://i.ytimg.com/vi/refill_next/maxresdefault.jpg',
              format: _cdFlac,
            ),
          ],
        );
      };
      await autoplay.maybeTriggerRefill(seedOverride: TrackMetadata.fromTrackInfo(u1));
      expect(autoplay.autoQueue.map((t) => t.id), <String>['ytm:a1', 'ytm:a2', 'ytm:a3']);

      await coordinator.playTrack(u1, queueContext: <TrackInfo>[u1, u2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      trackChanges.clear();
      queueUpdates.clear();
      final signalBefore = audio.signalPathRefreshCount;

      // 1. Backend-pushed Same-rate Gapless EOF: u1 -> u2 (playing -> playing, swapGeneration: 1).
      // Push partial metadata (missing coverUrl & album) to verify enrichment from user_queue.
      audio.pushBackendSwap(
        PlaybackState(
          status: PlaybackStatus.playing,
          track: _makeTrack(
            'ytm:u2',
            title: 'User Track 2',
            artist: 'Artist U2',
            album: '',
            coverUrl: null,
            duration: Duration.zero,
          ),
          position: const Duration(milliseconds: 80),
          swapGeneration: 1,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(coordAudio.currentState.status, PlaybackStatus.playing);
      expect(coordAudio.currentState.track?.id, 'ytm:u2');
      expect(
        coordAudio.currentState.track?.coverUrl,
        'https://i.ytimg.com/vi/u2/maxresdefault.jpg',
      );
      expect(coordAudio.currentState.track?.album, 'User Album 2');
      expect(coordAudio.currentState.track?.duration, const Duration(seconds: 220));
      expect(coordAudio.currentState.position, Duration.zero);
      expect(coordAudio.currentState.swapGeneration, 1);
      expect(autoplay.remainingUserQueueCount, 0);
      expect(autoplay.currentTrack?.id, 'ytm:u2');
      expect(trackChanges.map((t) => t.id), <String>['ytm:u2']);
      expect(queueUpdates, isNotEmpty);
      expect(coordAudio.currentLyrics.single.text, 'U2 Lyric Line');
      expect(audio.signalPathRefreshCount, greaterThan(signalBefore));

      // Subsequent poll with same (swapGeneration: 1, ytm:u2) must NOT double-pop or double-emit!
      audio.pushBackendSwap(
        PlaybackState(
          status: PlaybackStatus.playing,
          track: _makeTrack('ytm:u2', title: 'User Track 2', artist: 'Artist U2'),
          position: const Duration(seconds: 1),
          swapGeneration: 1,
        ),
        reloadLyrics: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(trackChanges, hasLength(1));
      expect(autoplay.autoQueue.map((t) => t.id), <String>['ytm:a1', 'ytm:a2', 'ytm:a3']);

      // 2. Backend-pushed Same-rate Gapless EOF: u2 -> a1 (auto_queue[0] pop + refill <= 2!).
      audio.pushBackendSwap(
        PlaybackState(
          status: PlaybackStatus.playing,
          track: _makeTrack(
            'ytm:a1',
            title: 'Auto Track 1',
            artist: 'Artist A1',
            album: '',
            coverUrl: null,
            duration: Duration.zero,
          ),
          position: Duration.zero,
          swapGeneration: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(coordAudio.currentState.track?.id, 'ytm:a1');
      expect(
        coordAudio.currentState.track?.coverUrl,
        'https://i.ytimg.com/vi/a1/maxresdefault.jpg',
      );
      expect(coordAudio.currentState.track?.album, 'Auto Album 1');
      expect(coordAudio.currentState.position, Duration.zero);
      expect(autoplay.isCurrentFromAutoQueue, isTrue);
      expect(autoplay.currentTrack?.id, 'ytm:a1');
      expect(trackChanges.map((t) => t.id), <String>['ytm:u2', 'ytm:a1']);
      expect(coordAudio.currentLyrics.single.text, 'A1 Lyric Line');
      // Refill was triggered since remaining after popping a1 was 2 (<= 2)!
      expect(autoplay.autoQueue.map((t) => t.id), contains('ytm:refill_next'));
    });

    test('b) Cross-rate Exclusive reopen transition hydrates Hi-Res metadata & pops queue', () async {
      final audio = _ControllableNativeAudioService();
      final nativeBackend = NativePlaybackBackend(audio);
      final manager = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
        enableLiveWarmup: false,
      );
      final registry = _buildRegistry();
      final autoplay = AutoplayController(
        providerLookup: (_) => null,
        allowBackgroundRefill: false,
      );
      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        autoplayController: autoplay,
        resolverRegistry: registry,
        nativeBackend: nativeBackend,
        debounceDelay: Duration.zero,
        lookaheadDelay: const Duration(seconds: 60),
      );
      final coordAudio = CoordinatingAudioService(
        inner: audio,
        coordinator: coordinator,
      );
      addTearDown(() {
        coordAudio.dispose();
        coordinator.dispose();
        autoplay.dispose();
        manager.dispose();
        nativeBackend.dispose();
        audio.dispose();
      });

      final q1 = _makeTrack(
        'qobuz:cd1',
        title: 'CD Track',
        artist: 'CD Artist',
        coverUrl: 'https://qobuz.example/cd1.jpg',
        format: _cdFlac,
      );
      final t2 = _makeTrack(
        'tidal:hires2',
        title: 'Master 192kHz',
        artist: 'Master Artist',
        album: 'Master Album',
        coverUrl: 'https://resources.tidal.com/images/hires2/1280x1280.jpg',
        duration: const Duration(seconds: 300),
        format: _hiRes192,
      );

      await coordinator.playTrack(q1, queueContext: <TrackInfo>[q1, t2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Exclusive reopen transition: buffering -> playing with swapGeneration: 1 & 192kHz format.
      audio.pushBackendSwap(
        PlaybackState(
          status: PlaybackStatus.playing,
          track: _makeTrack(
            'tidal:hires2',
            title: 'Master 192kHz',
            artist: 'Master Artist',
            album: '',
            coverUrl: null,
            duration: Duration.zero,
            format: _hiRes192,
          ),
          position: Duration.zero,
          swapGeneration: 1,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(coordAudio.currentState.track?.id, 'tidal:hires2');
      expect(
        coordAudio.currentState.track?.coverUrl,
        'https://resources.tidal.com/images/hires2/1280x1280.jpg',
      );
      expect(coordAudio.currentState.track?.album, 'Master Album');
      expect(coordAudio.currentState.track?.format.sampleRateHz, 192000);
      expect(coordAudio.currentState.position, Duration.zero);
      expect(autoplay.remainingUserQueueCount, 0);
      expect(autoplay.currentTrack?.id, 'tidal:hires2');
    });

    test('c) Non-dual-deck EOF (PlaybackStatus.ended) uses unified transition without double-pop', () async {
      final audio = MockAudioService();
      final fakeBackend = _EventDrivenPlaybackBackend();
      final manager = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
        enableLiveWarmup: false,
      );
      final registry = _buildRegistry();

      final ytmRec = _FakeRecProvider(
        recommendationProviderId: 'youtube_music',
        capabilities: ProviderCapabilities.youtubeMusic,
        onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
          tracks: <TrackMetadata>[
            TrackMetadata(
              providerId: 'youtube_music',
              trackId: 'eof_a1',
              title: 'EOF Next 1',
              artist: 'EOF Artist 1',
              album: 'EOF Album 1',
              durationMs: 180000,
              coverUrl: 'https://i.ytimg.com/vi/eof_a1/maxresdefault.jpg',
              format: _cdFlac,
            ),
            TrackMetadata(
              providerId: 'youtube_music',
              trackId: 'eof_a2',
              title: 'EOF Next 2',
              artist: 'EOF Artist 2',
              album: 'EOF Album 2',
              durationMs: 185000,
              coverUrl: 'https://i.ytimg.com/vi/eof_a2/maxresdefault.jpg',
              format: _cdFlac,
            ),
            TrackMetadata(
              providerId: 'youtube_music',
              trackId: 'eof_a3',
              title: 'EOF Next 3',
              artist: 'EOF Artist 3',
              album: 'EOF Album 3',
              durationMs: 190000,
              coverUrl: 'https://i.ytimg.com/vi/eof_a3/maxresdefault.jpg',
              format: _cdFlac,
            ),
          ],
        ),
      );
      final autoplay = AutoplayController(
        providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
        isGuestCapableLookup: (pid) => pid == 'youtube_music',
        refillTargetCount: 3,
      );
      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        autoplayController: autoplay,
        resolverRegistry: registry,
        nativeBackend: fakeBackend,
        externalBackend: _EventDrivenPlaybackBackend(),
        debounceDelay: Duration.zero,
        lookaheadDelay: const Duration(seconds: 60),
      );
      final coordAudio = CoordinatingAudioService(
        inner: audio,
        coordinator: coordinator,
      );
      addTearDown(() {
        coordAudio.dispose();
        coordinator.dispose();
        autoplay.dispose();
        manager.dispose();
        fakeBackend.dispose();
        audio.dispose();
      });

      final t0 = _makeTrack('ytm:eof_0', title: 'EOF Seed');
      await coordinator.playTrack(t0, queueContext: <TrackInfo>[t0]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        autoplay.autoQueue.map((t) => t.id),
        <String>['ytm:eof_a1', 'ytm:eof_a2', 'ytm:eof_a3'],
      );

      final trackChanges = <TrackInfo>[];
      final sub = coordAudio.trackChangedStream.listen(trackChanges.add);
      addTearDown(sub.cancel);

      // Emit ended twice in the same tick -> must advance ONLY once to eof_a1!
      fakeBackend.emit(PlaybackState(status: PlaybackStatus.ended, track: t0));
      fakeBackend.emit(PlaybackState(status: PlaybackStatus.ended, track: t0));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeBackend.playCalls.map((t) => t.id), <String>['ytm:eof_0', 'ytm:eof_a1']);
      expect(trackChanges.map((t) => t.id), <String>['ytm:eof_a1']);
      expect(autoplay.currentTrack?.id, 'ytm:eof_a1');
      expect(autoplay.autoQueue.first.id, 'ytm:eof_a2');
      expect(coordAudio.currentState.position, Duration.zero);
    });

    test('d) ServerAudioService handles track_changed, queue_updated, and PlaybackStateChanged WS events with lyrics reload', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? serverWs;
      final serverSub = server.listen((req) async {
        if (req.uri.path == '/api/v1/ws') {
          serverWs = await WebSocketTransformer.upgrade(req);
        } else if (req.uri.path.startsWith('/api/v1/lyrics/')) {
          final trackId = Uri.decodeComponent(
            req.uri.path.substring('/api/v1/lyrics/'.length),
          );
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'found': true,
              'lines': <Map<String, dynamic>>[
                <String, dynamic>{
                  'start_ms': 0,
                  'end_ms': 4000,
                  'text': 'Remote lyric for $trackId',
                },
              ],
            }),
          );
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      final client = ServerAudioService(
        baseUrl: 'http://127.0.0.1:${server.port}',
        bearerToken: 'test-token',
      );
      addTearDown(() async {
        client.dispose();
        await serverWs?.close();
        await serverSub.cancel();
        await server.close(force: true);
      });

      await client.connectWebSocket();
      final states = <PlaybackState>[];
      final positions = <Duration>[];
      final sub1 = client.stateStream.listen(states.add);
      final sub2 = client.positionStream.listen(positions.add);
      addTearDown(() async {
        await sub1.cancel();
        await sub2.cancel();
      });

      // 1. track_changed event over real WebSocket
      serverWs!.add(
        jsonEncode(<String, dynamic>{
          'type': 'event',
          'event': 'track_changed',
          'payload': <String, dynamic>{
            'swap_generation': 1,
            'position_ms': 0,
            'duration_ms': 240000,
            'track': <String, dynamic>{
              'track_id': 'tidal:ws_1',
              'provider_id': 'tidal',
              'title': 'WS Track One',
              'artist': 'WS Artist One',
              'album': 'WS Album One',
              'cover_url': 'https://resources.tidal.com/images/ws1/1280x1280.jpg',
              'duration_ms': 240000,
            },
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(client.currentState.status, PlaybackStatus.playing);
      expect(client.currentState.track?.id, 'tidal:ws_1');
      expect(client.currentState.track?.title, 'WS Track One');
      expect(
        client.currentState.track?.coverUrl,
        'https://resources.tidal.com/images/ws1/1280x1280.jpg',
      );
      expect(client.currentState.position, Duration.zero);
      expect(client.currentState.swapGeneration, 1);
      expect(client.currentLyrics.single.text, 'Remote lyric for tidal:ws_1');
      expect(positions, contains(Duration.zero));

      // 2. queue_updated event over real WebSocket
      serverWs!.add(
        jsonEncode(<String, dynamic>{
          'type': 'event',
          'event': 'queue_updated',
          'payload': <String, dynamic>{
            'swap_generation': 1,
            'queue': <Map<String, dynamic>>[
              <String, dynamic>{
                'track_id': 'qobuz:ws_2',
                'provider_id': 'qobuz',
                'title': 'WS Track Two',
                'artist': 'WS Artist Two',
                'album': 'WS Album Two',
                'cover_url': 'https://qobuz.example/ws2.jpg',
                'duration_ms': 195000,
              },
            ],
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.queue.map((t) => t.id), <String>['qobuz:ws_2']);

      // 3. PlaybackStateChanged transitions to ws_2, hydrates from queue, resets pos to 0, reloads lyrics
      serverWs!.add(
        jsonEncode(<String, dynamic>{
          'type': 'PlaybackStateChanged',
          'payload': <String, dynamic>{
            'status': 'playing',
            'current_track_id': 'qobuz:ws_2',
            'position_ms': 999,
            'duration_ms': 195000,
            'swap_generation': 2,
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(client.currentState.track?.id, 'qobuz:ws_2');
      expect(client.currentState.track?.title, 'WS Track Two');
      expect(client.currentState.track?.coverUrl, 'https://qobuz.example/ws2.jpg');
      expect(client.currentState.position, Duration.zero);
      expect(client.currentState.swapGeneration, 2);
      expect(client.currentLyrics.single.text, 'Remote lyric for qobuz:ws_2');
    });
  });

  group('Tray/SMTC hooks and Reactive UI updates on backend-pushed swap', () {
    test('DesktopWindowController.updateSystemMediaControls invokes trayUpdate & mediaUpdateMetadata safely', () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('lumina/window_test_smtc');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final ctrl = DesktopWindowController(
        channel: channel,
        isSupportedOverride: true,
        installMethodHandler: false,
      );
      await ctrl.updateSystemMediaControls(
        title: 'Song B',
        artist: 'Artist B',
        album: 'Album B',
        artworkUrl: 'https://example.com/b.jpg',
        duration: const Duration(seconds: 210),
        position: Duration.zero,
        isPlaying: true,
        tooltip: 'Lumina Audio — Song B - Artist B',
        nowPlayingLabel: '正在播放：Song B - Artist B',
      );

      expect(calls.map((c) => c.method), <String>['trayUpdate', 'mediaUpdateMetadata']);
      final mediaArgs = calls[1].arguments as Map;
      expect(mediaArgs['title'], 'Song B');
      expect(mediaArgs['artist'], 'Artist B');
      expect(mediaArgs['album'], 'Album B');
      expect(mediaArgs['artworkUrl'], 'https://example.com/b.jpg');
      expect(mediaArgs['durationMs'], 210000);
      expect(mediaArgs['isPlaying'], isTrue);
    });

    testWidgets(
      'e) FloatingCapsule, NowPlayingOverlay, QuickQueuePopover, AlbumArtworkView update & remount cover key on backend-pushed gapless swap',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 900);
        addTearDown(tester.view.reset);

        final audio = _ControllableNativeAudioService();
        final nativeBackend = NativePlaybackBackend(audio);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final registry = _buildRegistry();
        final autoplay = AutoplayController(
          providerLookup: (_) => null,
          allowBackgroundRefill: false,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        final coordAudio = CoordinatingAudioService(
          inner: audio,
          coordinator: coordinator,
        );
        final npCtrl = NowPlayingViewController()
          ..setMode(NowPlayingViewMode.split)
          ..setQueueDrawerOpen(true);
        final paletteSvc = ArtworkPaletteService(
          urlExtractorOverride: (_) async => null,
        );

        addTearDown(() {
          npCtrl.dispose();
          coordAudio.dispose();
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final t1 = _makeTrack(
          'ytm:track_1',
          title: 'First Gapless Song',
          artist: 'First Artist',
          album: 'First Album',
          coverUrl: 'https://i.ytimg.com/vi/track_1/maxresdefault.jpg',
          duration: const Duration(minutes: 3, seconds: 20),
        );
        final t2 = _makeTrack(
          'tidal:track_2',
          title: 'Second Gapless Song',
          artist: 'Second Artist',
          album: 'Second Album',
          coverUrl: 'https://resources.tidal.com/images/track_2/1280x1280.jpg',
          duration: const Duration(minutes: 4, seconds: 15),
          format: _hiRes192,
        );
        final t3 = _makeTrack(
          'qobuz:track_3',
          title: 'Third Track',
          artist: 'Third Artist',
          album: 'Third Album',
          duration: const Duration(minutes: 2, seconds: 50),
        );

        audio.lyricsByTrackId['ytm:track_1'] = const <LyricLine>[
          LyricLine(start: Duration.zero, end: Duration(seconds: 5), text: 'First Lyrics Line'),
        ];
        audio.lyricsByTrackId['tidal:track_2'] = const <LyricLine>[
          LyricLine(start: Duration.zero, end: Duration(seconds: 5), text: 'Second Lyrics Line'),
        ];

        autoplay.setUserQueue(
          <TrackInfo>[t1, t2, t3],
          currentTrack: t1,
          currentIndex: 0,
          bumpEpoch: false,
        );
        await coordinator.playTrack(t1, queueContext: <TrackInfo>[t1, t2, t3]);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: NowPlayingOverlay(
                            audioService: coordAudio,
                            controller: npCtrl,
                            paletteService: paletteSvc,
                            onCollapse: () {},
                          ),
                        ),
                        SizedBox(
                          width: 310,
                          child: QuickQueuePopover(
                            audioService: coordAudio,
                            onClose: () {},
                          ),
                        ),
                      ],
                    ),
                  ),
                  FloatingCapsuleMiniPlayer(
                    audioService: coordAudio,
                    showLyrics: false,
                    onToggleLyrics: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byKey(const ValueKey('mini_art_youtube_music:track_1')), findsOneWidget);
        expect(find.byKey(const ValueKey('hero_art_youtube_music:track_1')), findsOneWidget);
        expect(find.text('First Gapless Song'), findsAtLeastNWidgets(2));
        expect(find.text('03:20'), findsAtLeastNWidgets(1));
        expect(find.text('First Lyrics Line'), findsOneWidget);

        // Verify track-scoped art_img_* ValueKey + gaplessPlayback: true on initial render.
        final initialArtKey = ValueKey(
          'art_img_youtube_music:track_1_${t1.coverUrl}',
        );
        expect(find.byKey(initialArtKey), findsAtLeastNWidgets(1));
        final beforeMiniImageFinder = find.descendant(
          of: find.byKey(const ValueKey('mini_art_youtube_music:track_1')),
          matching: find.byType(Image),
        );
        expect(beforeMiniImageFinder, findsOneWidget);
        final beforeMiniImageElement = tester.element(beforeMiniImageFinder);
        expect(
          tester.widget<Image>(beforeMiniImageFinder).gaplessPlayback,
          isTrue,
        );

        // Push backend gapless swap from track_1 -> track_2 (status stays playing).
        audio.pushBackendSwap(
          PlaybackState(
            status: PlaybackStatus.playing,
            track: _makeTrack(
              'tidal:track_2',
              title: 'Second Gapless Song',
              artist: 'Second Artist',
              album: '',
              coverUrl: null,
              duration: Duration.zero,
            ),
            position: Duration.zero,
            swapGeneration: 1,
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        final nextArtKey = ValueKey(
          'art_img_tidal:track_2_${t2.coverUrl}',
        );
        expect(find.byKey(nextArtKey), findsAtLeastNWidgets(1));
        final afterMiniImageFinder = find.descendant(
          of: find.byKey(const ValueKey('mini_art_tidal:track_2')),
          matching: find.byType(Image),
        );
        expect(afterMiniImageFinder, findsOneWidget);
        final afterMiniImageElement = tester.element(afterMiniImageFinder);
        expect(identical(beforeMiniImageElement, afterMiniImageElement), isFalse);
        expect(
          tester.widget<Image>(afterMiniImageFinder).gaplessPlayback,
          isTrue,
        );

        await tester.pump(const Duration(milliseconds: 350));

        // Cover art widgets remounted with normalized ${provider_id}:${track_id} ValueKey!
        expect(find.byKey(const ValueKey('mini_art_youtube_music:track_1')), findsNothing);
        expect(find.byKey(const ValueKey('hero_art_youtube_music:track_1')), findsNothing);
        expect(find.byKey(const ValueKey('mini_art_tidal:track_2')), findsOneWidget);
        expect(find.byKey(const ValueKey('hero_art_tidal:track_2')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('mini_art_tidal:track_2')),
            matching: find.byKey(nextArtKey),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('hero_art_tidal:track_2')),
            matching: find.byKey(nextArtKey),
          ),
          findsOneWidget,
        );

        // Capsule, NowPlayingOverlay, LyricsView, and Queue updated cleanly!
        expect(find.text('Second Gapless Song'), findsAtLeastNWidgets(2));
        expect(find.text('04:15'), findsAtLeastNWidgets(1));
        expect(find.text('Second Lyrics Line'), findsOneWidget);
        final quickQueueRowT2 = find.ancestor(
          of: find.byKey(const Key('quick_queue_item_tidal:track_2')),
          matching: find.byType(Row),
        );
        expect(
          find.descendant(
            of: quickQueueRowT2.first,
            matching: find.byIcon(Icons.equalizer_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('now_playing_queue_item_tidal:track_2')),
            matching: find.byIcon(Icons.equalizer_rounded),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'StreamingCoverImage and AlbumArtworkView keep gaplessPlayback true while track ValueKey remounts Image element',
      (WidgetTester tester) async {
        const sharedCover = 'https://example.com/shared_cover.jpg';
        final trackA = _makeTrack('tidal:cover_a', coverUrl: sharedCover);
        final trackB = _makeTrack('qobuz:cover_b', coverUrl: sharedCover);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  StreamingCoverImage(
                    url: 'https://example.com/cover.jpg',
                    fallbackBuilder: (_) => const SizedBox.shrink(),
                  ),
                  AlbumArtworkView(
                    key: ValueKey('hero_art_${trackA.responsiveArtworkKey}'),
                    track: trackA,
                    size: 64,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        final imagesA = tester.widgetList<Image>(find.byType(Image)).toList();
        expect(imagesA.length, greaterThanOrEqualTo(2));
        for (final img in imagesA) {
          expect(img.gaplessPlayback, isTrue);
        }
        expect(
          find.byKey(const ValueKey('art_img_tidal:cover_a_https://example.com/shared_cover.jpg')),
          findsOneWidget,
        );
        final artImgElementA = tester.element(
          find.descendant(
            of: find.byKey(const ValueKey('hero_art_tidal:cover_a')),
            matching: find.byType(Image),
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  StreamingCoverImage(
                    url: 'https://example.com/cover.jpg',
                    fallbackBuilder: (_) => const SizedBox.shrink(),
                  ),
                  AlbumArtworkView(
                    key: ValueKey('hero_art_${trackB.responsiveArtworkKey}'),
                    track: trackB,
                    size: 64,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const ValueKey('hero_art_tidal:cover_a')), findsNothing);
        expect(find.byKey(const ValueKey('hero_art_qobuz:cover_b')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('art_img_qobuz:cover_b_https://example.com/shared_cover.jpg')),
          findsOneWidget,
        );
        final artImgFinderB = find.descendant(
          of: find.byKey(const ValueKey('hero_art_qobuz:cover_b')),
          matching: find.byType(Image),
        );
        final artImgElementB = tester.element(artImgFinderB);
        expect(identical(artImgElementA, artImgElementB), isFalse);
        expect(tester.widget<Image>(artImgFinderB).gaplessPlayback, isTrue);
      },
    );
  });
}
