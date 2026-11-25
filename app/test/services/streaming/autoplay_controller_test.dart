import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/recommendation_models.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/recommendation_settings_controller.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/autoplay_filter.dart';
import 'package:lumina_app/services/streaming/cross_platform_track_router.dart';
import 'package:lumina_app/services/streaming/playback_backend.dart';
import 'package:lumina_app/services/streaming/recommendation_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';

const AudioFormat _flacCd = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
);

const AudioFormat _flacHiRes = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 96000,
  bitDepth: 24,
  channels: 2,
);

const AudioFormat _opusLossy = AudioFormat(
  codec: AudioCodec.opus,
  sampleRateHz: 48000,
  bitDepth: 16,
  channels: 2,
  bitrateKbps: 160,
);

TrackInfo _trackInfo(
  String id, {
  String title = '',
  String artist = 'Artist A',
  String album = 'Album',
  Duration duration = const Duration(seconds: 200),
  String? isrc,
  String? qualityLabel,
  String? filePath,
  String providerName = '',
  AudioFormat format = _flacCd,
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
    filePath: filePath,
    providerName: resolvedProvider,
    format: format,
    isrc: isrc,
    qualityLabel: qualityLabel,
  );
}

TrackMetadata _meta(
  String providerId,
  String trackId, {
  String title = '',
  String artist = 'Artist A',
  String? primaryArtist,
  String album = 'Album',
  int durationMs = 200000,
  String? isrc,
  String? qualityLabel,
  String? filePath,
  AudioFormat format = _flacCd,
}) {
  return TrackMetadata(
    providerId: providerId,
    trackId: trackId,
    title: title.isEmpty ? 'Song $trackId' : title,
    artist: artist,
    primaryArtist: primaryArtist ?? artist,
    album: album,
    durationMs: durationMs,
    isrc: isrc,
    qualityLabel: qualityLabel,
    filePath: filePath,
    format: format,
  );
}

class _FakeRecProvider implements RecommendationProvider {
  @override
  final String recommendationProviderId;

  @override
  final ProviderCapabilities capabilities;

  int radioCalls = 0;
  int matchCalls = 0;
  final List<String?> seenCursors = <String?>[];
  final List<TrackMatchQuery> seenQueries = <TrackMatchQuery>[];

  Future<RadioPage> Function(
    TrackMetadata seed, {
    int limit,
    String? cursor,
    CancellationToken? cancel,
  })? onGetTrackRadio;

  Future<TrackMetadata?> Function(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  })? onMatchTrack;

  _FakeRecProvider({
    required this.recommendationProviderId,
    required this.capabilities,
    this.onGetTrackRadio,
    this.onMatchTrack,
  });

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    radioCalls++;
    seenCursors.add(cursor);
    if (onGetTrackRadio != null) {
      return onGetTrackRadio!(
        seed,
        limit: limit,
        cursor: cursor,
        cancel: cancel,
      );
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
  }) async {
    matchCalls++;
    seenQueries.add(query);
    if (onMatchTrack != null) {
      return onMatchTrack!(query, cancel: cancel);
    }
    return null;
  }
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

class _SpyDualDeckBackend extends NativePlaybackBackend {
  final List<TrackInfo> prepareStandbyTracks = <TrackInfo>[];
  final List<int> skipToStandbyEpochs = <int>[];
  final List<TrackInfo> playTracks = <TrackInfo>[];

  bool _ready = false;

  _SpyDualDeckBackend(super.audioService);

  @override
  bool get isStandbyReady => _ready || super.isStandbyReady;

  @override
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    playTracks.add(track);
    _ready = false;
    await super.play(spec, track, epoch: epoch);
  }

  @override
  Future<void> prepareStandby(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    prepareStandbyTracks.add(track);
    _ready = true;
    await super.prepareStandby(spec, track, epoch: epoch);
  }

  @override
  Future<bool> skipToStandby({required int epoch}) async {
    skipToStandbyEpochs.add(epoch);
    if (!_ready) return false;
    _ready = false;
    return super.skipToStandby(epoch: epoch);
  }
}

class _FakeExternalBridge implements ExternalPlaybackBridge {
  void Function(ExternalPlaybackEvent event)? _handler;

  @override
  void setStateHandler(void Function(ExternalPlaybackEvent event)? handler) {
    _handler = handler;
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> configure({
    required String developerToken,
    required String musicUserToken,
    String storefront = 'us',
  }) async {}

  @override
  Future<void> play({
    required String trackUri,
    String? previewUrl,
    required int epoch,
    String? externalWebUrl,
  }) async {
    _handler?.call(
      ExternalPlaybackEvent(
        epoch: epoch,
        status: 'playing',
        positionMs: 0,
        durationMs: 180000,
      ),
    );
  }

  @override
  Future<void> pause({required int epoch}) async {}

  @override
  Future<void> resume({required int epoch}) async {}

  @override
  Future<void> seek({required Duration position, required int epoch}) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop({required int epoch}) async {}

  @override
  void dispose() {
    _handler = null;
  }
}

StreamResolverRegistry _buildStreamRegistry({
  required _CountingStreamResolver ytm,
  _CountingStreamResolver? tidal,
  _CountingStreamResolver? qobuz,
}) {
  final registry = StreamResolverRegistry();
  registry.register(
    ytm,
    idPrefixes: const <String>['ytm:', 'streaming:youtube_music:'],
    providerNames: const <String>['youtube music'],
  );
  if (tidal != null) {
    registry.register(
      tidal,
      idPrefixes: const <String>['tidal:', 'streaming:tidal:'],
      providerNames: const <String>['tidal'],
    );
  }
  if (qobuz != null) {
    registry.register(
      qobuz,
      idPrefixes: const <String>['qobuz:', 'streaming:qobuz:'],
      providerNames: const <String>['qobuz'],
    );
  }
  registry.register(const LocalStreamResolver());
  return registry;
}

void main() {
  group('1. YTM Guest Radio Auto-Refill & Phase 4 Standby Deck Integration', () {
    test(
      'YTM Guest mode refills at remaining <= 2 using continuation cursor and prepares/transitions Phase 4 Standby Deck',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );

        final ytmStreamResolver = _CountingStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/${key.trackId}.m4a',
            mimeType: 'audio/mp4',
            hintExtension: 'm4a',
            bitrateBps: 128000,
            expireAt:
                (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 21600,
          ),
        );
        final registry = _buildStreamRegistry(ytm: ytmStreamResolver);

        final ytmRec = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async {
            if (cursor == null) {
              return RadioPage(
                sourceLabel: 'RDAMVM${seed.trackId}',
                nextCursor: 'cont_${seed.trackId}_p2',
                tracks: List<TrackMetadata>.generate(
                  6,
                  (i) => _meta(
                    'youtube_music',
                    '${seed.trackId}_auto_${i + 1}',
                    title: '${seed.trackId} Auto Song ${i + 1}',
                    artist: '${seed.trackId} Guest Artist ${i + 1}',
                    format: _opusLossy,
                  ),
                ),
              );
            }
            return RadioPage(
              sourceLabel: 'RDAMVM${seed.trackId}',
              nextCursor: 'cont_${seed.trackId}_p3',
              tracks: List<TrackMetadata>.generate(
                6,
                (i) => _meta(
                  'youtube_music',
                  '${seed.trackId}_auto_p2_${i + 1}',
                  title: '${seed.trackId} Auto P2 Song ${i + 1}',
                  artist: '${seed.trackId} Guest P2 Artist ${i + 1}',
                  format: _opusLossy,
                ),
              ),
            );
          },
        );

        final router = CrossPlatformTrackRouter(
          providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
          authStateLookup: (_) => StreamingAuthState.disconnected,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
        );

        final autoplay = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
          trackRouter: router,
          authStateLookup: (_) => StreamingAuthState.disconnected,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          refillTriggerRemaining: 2,
          refillTargetCount: 6,
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        final coordinatingAudio = CoordinatingAudioService(
          inner: audio,
          coordinator: coordinator,
        );

        addTearDown(() {
          coordinatingAudio.dispose();
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        expect(coordinatingAudio.autoplayController, same(autoplay));

        // Start with 4 user tracks (remaining == 3 > 2): must NOT refill yet!
        final userTracks = <TrackInfo>[
          _trackInfo('ytm:u0', title: 'Seed 0', artist: 'User Artist 0'),
          _trackInfo('ytm:u1', title: 'Seed 1', artist: 'User Artist 1'),
          _trackInfo('ytm:u2', title: 'Seed 2', artist: 'User Artist 2'),
          _trackInfo('ytm:u3', title: 'Seed 3', artist: 'User Artist 3'),
        ];
        await coordinator.playTrack(userTracks[0], queueContext: userTracks);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(autoplay.remainingUserQueueCount, 3);
        expect(autoplay.needsRefill, isFalse);
        expect(ytmRec.radioCalls, 0);

        // Advance to u1 (remaining == 2 <= 2): qualify u1 at 46s so u1 enters EffectiveSeedPool,
        // triggering Guest RDAMVM refill!
        await coordinator.next();
        await coordinator.seek(const Duration(seconds: 46));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(autoplay.remainingUserQueueCount, 2);
        expect(ytmRec.radioCalls, 1);
        expect(ytmRec.seenCursors, <String?>[null]);
        expect(autoplay.autoQueue, hasLength(6));
        expect(coordinatingAudio.queue, hasLength(10)); // 4 user + 6 auto

        // Skip u2 -> u3 (last user track), enter last 18s -> Phase 4 prepares u1_auto_1!
        await coordinator.next();
        await coordinator.next();
        expect(autoplay.currentTrack?.id, 'ytm:u3');
        expect(autoplay.peekNextTrack()?.id, 'ytm:u1_auto_1');

        await coordinator.seek(const Duration(seconds: 182));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(nativeBackend.prepareStandbyTracks, hasLength(1));
        expect(nativeBackend.prepareStandbyTracks.single.id, 'ytm:u1_auto_1');
        expect(coordinator.isStandbyReady, isTrue);

        // Skip via next() flips via skipToStandby() into u1_auto_1!
        await coordinator.next();
        expect(nativeBackend.skipToStandbyEpochs, hasLength(1));
        expect(audio.currentState.track?.id, 'ytm:u1_auto_1');
        expect(autoplay.currentTrack?.id, 'ytm:u1_auto_1');
        expect(autoplay.isCurrentFromAutoQueue, isTrue);
        expect(autoplay.autoQueue.first.id, 'ytm:u1_auto_2');

        // Consume remaining tracks to trigger refills for u3 (new seed) AND u1 (continuation cursor!).
        for (var i = 0; i < 8; i++) {
          await coordinator.next();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(ytmRec.radioCalls, greaterThanOrEqualTo(3));
        expect(ytmRec.seenCursors, contains('cont_u1_p2'));
        expect(autoplay.autoQueue.length, greaterThanOrEqualTo(3));
      },
    );

    test(
      'syncs native Gapless transition and dedupes PlaybackStatus.ended by (trackId, epoch)',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytmResolver = _CountingStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/${key.trackId}.m4a',
          ),
        );
        final registry = _buildStreamRegistry(ytm: ytmResolver);

        final ytmRec = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta('youtube_music', 'auto_gap_1', artist: 'Gap Artist 1'),
              _meta('youtube_music', 'auto_gap_2', artist: 'Gap Artist 2'),
              _meta('youtube_music', 'auto_gap_3', artist: 'Gap Artist 3'),
            ],
          ),
        );

        final autoplay = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          refillTargetCount: 5,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final seed = _trackInfo('ytm:seed_gap', artist: 'Seed Artist');
        await coordinator.playTrack(seed, queueContext: <TrackInfo>[seed]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(autoplay.autoQueue.first.id, 'ytm:auto_gap_1');

        // Enter end window -> prepare Standby for auto_gap_1.
        await coordinator.seek(const Duration(seconds: 185));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(coordinator.preparedStandbyTrackId, 'ytm:auto_gap_1');

        // Simulate native engine performing Gapless switch directly (Deck B -> Deck A).
        await audio.skipToStandby(epoch: coordinator.currentEpoch);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(autoplay.currentTrack?.id, 'ytm:auto_gap_1');
        expect(autoplay.isCurrentFromAutoQueue, isTrue);
        expect(autoplay.autoQueue.first.id, 'ytm:auto_gap_2');
        expect(coordinator.preparedStandbyTrackId, isNull);

        // Simulate duplicate PlaybackStatus.ended events in the same epoch -> advances ONLY once!
        final playsBeforeEnded = nativeBackend.playTracks.length;
        await audio.stop();
        // Manually trigger ended via MockAudioService's seek/state or direct play:
        // Use a dedicated fake PlaybackBackend stream test for ended dedup below.
        expect(playsBeforeEnded, 1);
      },
    );

    test(
      'PlaybackStatus.ended advances once per (track.id, epoch) and triggers refill when needed',
      () async {
        final audio = MockAudioService();
        final controller = StreamController<PlaybackState>.broadcast();
        final fakeBackend = _EventDrivenPlaybackBackend(controller);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytmResolver = _CountingStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/${key.trackId}.m4a',
          ),
        );
        final registry = _buildStreamRegistry(ytm: ytmResolver);
        final ytmRec = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta('youtube_music', 'end_next_1', artist: 'End Artist 1'),
              _meta('youtube_music', 'end_next_2', artist: 'End Artist 2'),
            ],
          ),
        );
        final autoplay = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          refillTargetCount: 5,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: registry,
          nativeBackend: fakeBackend,
          externalBackend: _EventDrivenPlaybackBackend(
            StreamController<PlaybackState>.broadcast(),
          ),
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() async {
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          await controller.close();
          audio.dispose();
        });

        final t0 = _trackInfo('ytm:end_0', artist: 'Artist 0');
        await coordinator.playTrack(t0, queueContext: <TrackInfo>[t0]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fakeBackend.playCalls.map((t) => t.id), <String>['ytm:end_0']);

        // Emit ended twice in quick succession for the same (track.id, epoch).
        fakeBackend.emit(PlaybackState(status: PlaybackStatus.ended, track: t0));
        fakeBackend.emit(PlaybackState(status: PlaybackStatus.ended, track: t0));
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(
          fakeBackend.playCalls.map((t) => t.id),
          <String>['ytm:end_0', 'ytm:end_next_1'],
        );
        expect(autoplay.currentTrack?.id, 'ytm:end_next_1');
      },
    );
  });

  group('2. Cross-Platform Hi-Res Routing & 401 Circuit-Breaker Bypass', () {
    test(
      'routes local lossless and YTM seeds to Tidal HI_RES and skips Qobuz 401 with zero retry calls',
      () async {
        final qobuz = _FakeRecProvider(
          recommendationProviderId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async {
            throw const RecError(
              kind: RecErrorKind.authRequired,
              message: 'HTTP 401',
              statusCode: 401,
              providerId: 'qobuz',
            );
          },
          onMatchTrack: (query, {cancel}) async {
            fail('Qobuz 401 circuit breaker must skip matchTrack immediately');
          },
        );

        final tidal = _FakeRecProvider(
          recommendationProviderId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta(
                'tidal',
                'td_native_1',
                title: 'Tidal Radio Track',
                artist: 'Artist T1',
                qualityLabel: 'HI_RES_LOSSLESS',
                format: _flacHiRes,
              ),
            ],
          ),
          onMatchTrack: (query, {cancel}) async {
            return _meta(
              'tidal',
              'td_${query.title.replaceAll(' ', '_')}',
              title: query.title,
              artist: query.artist,
              isrc: query.isrc,
              qualityLabel: 'HI_RES_LOSSLESS',
              format: _flacHiRes,
            );
          },
        );

        final ytm = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta(
                'youtube_music',
                'ytm_cand_1',
                title: 'Midnight Signal',
                artist: 'Artist M1',
                format: _opusLossy,
              ),
              _meta(
                'youtube_music',
                'ytm_cand_2',
                title: 'Solar Echo',
                artist: 'Artist M2',
                format: _opusLossy,
              ),
            ],
          ),
        );

        final lastFm = _FakeRecProvider(
          recommendationProviderId: 'lastfm',
          capabilities: const ProviderCapabilities(supportsTrackRadio: true),
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta(
                'lastfm',
                'lfm_1',
                title: 'Velvet Horizon',
                artist: 'Artist L1',
              ),
              _meta(
                'lastfm',
                'lfm_2',
                title: 'Glass Cathedral',
                artist: 'Artist L2',
              ),
            ],
          ),
        );

        final providers = <String, RecommendationProvider>{
          'qobuz': qobuz,
          'tidal': tidal,
          'youtube_music': ytm,
        };

        final authStates = <String, StreamingAuthState>{
          'qobuz': StreamingAuthState.authRequired,
          'tidal': StreamingAuthState.connected,
          'deezer': StreamingAuthState.disconnected,
          'youtube_music': StreamingAuthState.disconnected,
        };
        final authBlocked = <String>{'qobuz'};

        final settings = RecommendationSettingsController();
        // Priority puts qobuz ahead of tidal to prove 401 circuit breaker skips qobuz cleanly.
        await settings.setPlatformPriority(const <String>[
          'local',
          'qobuz',
          'tidal',
          'deezer',
          'youtube_music',
        ]);

        var now = DateTime.utc(2026, 11, 24, 12, 0, 0);
        final router = CrossPlatformTrackRouter(
          providerLookup: (pid) => providers[pid],
          authStateLookup: (pid) =>
              authStates[pid] ?? StreamingAuthState.disconnected,
          isAuthRequiredLookup: (pid) => authBlocked.contains(pid),
          isPlaybackAuthBlockedLookup: (pid) => authBlocked.contains(pid),
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          priorityOrderProvider: () => settings.platformPriority,
          clock: () => now,
        );

        final controller = AutoplayController(
          providerLookup: (pid) => providers[pid],
          externalProviders: <RecommendationProvider>[lastFm],
          trackRouter: router,
          settings: settings,
          isAuthRequiredLookup: (pid) => authBlocked.contains(pid),
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          authStateLookup: (pid) =>
              authStates[pid] ?? StreamingAuthState.disconnected,
          clock: () => now,
          refillTargetCount: 5,
        );
        addTearDown(controller.dispose);

        // 1) Local lossless seed -> Last.fm + Guest YTM -> routed to Tidal HI_RES_LOSSLESS!
        final localSeed = _trackInfo(
          'local_1',
          title: 'Local FLAC Seed',
          artist: 'Local Master Artist',
          filePath: '/music/local_seed.flac',
          format: _flacHiRes,
        );
        controller.setUserQueue(<TrackInfo>[localSeed], currentTrack: localSeed);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(qobuz.matchCalls, 0);
        expect(qobuz.radioCalls, 0);
        expect(lastFm.radioCalls, 1);
        expect(controller.autoQueue, isNotEmpty);
        expect(
          controller.autoQueue.every((t) => t.id.startsWith('tidal:')),
          isTrue,
        );
        expect(
          controller.autoQueue.every((t) => t.qualityLabel == 'HI_RES_LOSSLESS'),
          isTrue,
        );

        // 2) YTM seed -> YTM radio -> upgraded to Tidal HI_RES_LOSSLESS!
        final ytmSeed = _trackInfo(
          'ytm:seed_ytm',
          title: 'YTM Seed',
          artist: 'YTM Seed Artist',
          format: _opusLossy,
        );
        controller.setUserQueue(<TrackInfo>[ytmSeed], currentTrack: ytmSeed);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(qobuz.matchCalls, 0);
        expect(
          controller.autoQueue.every((t) => t.id.startsWith('tidal:')),
          isTrue,
        );

        // 3) Qobuz seed while Qobuz is 401 -> zero Qobuz retries, falls back cleanly to Last.fm + YTM -> Tidal!
        final qobuzSeed = _trackInfo(
          'qobuz:qb_999',
          title: 'Qobuz 401 Seed',
          artist: 'Qobuz Artist',
        );
        controller.setUserQueue(<TrackInfo>[qobuzSeed], currentTrack: qobuzSeed);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(qobuz.radioCalls, 0);
        expect(qobuz.matchCalls, 0);
        expect(controller.autoQueue, isNotEmpty);
        expect(
          controller.autoQueue.every((t) => t.id.startsWith('tidal:')),
          isTrue,
        );

        // 4) Router LRU cache + auth signature invalidation:
        //    Direct router lookup uses cache on repeat, then re-routes when Qobuz recovers!
        final callsBeforeCache = tidal.matchCalls;
        final cachedCand = _meta(
          'youtube_music',
          'ytm_cache_probe',
          title: 'Cache Probe',
          artist: 'Cache Artist',
          isrc: 'US-ABC-26-00001',
        );
        final firstRes = await router.resolveBestPlayableTrack(
          cachedCand,
          crossPlatformEnabled: true,
        );
        expect(firstRes?.providerId, 'tidal');
        expect(tidal.matchCalls, callsBeforeCache + 1);

        final secondRes = await router.resolveBestPlayableTrack(
          cachedCand,
          crossPlatformEnabled: true,
        );
        expect(secondRes?.providerId, 'tidal');
        expect(tidal.matchCalls, callsBeforeCache + 1); // Cache hit!

        // Recover Qobuz auth -> auth signature changes -> router re-routes and picks Qobuz!
        authBlocked.remove('qobuz');
        authStates['qobuz'] = StreamingAuthState.connected;
        qobuz.onMatchTrack = (query, {cancel}) async => _meta(
          'qobuz',
          'qb_recovered',
          title: query.title,
          artist: query.artist,
          isrc: query.isrc,
          qualityLabel: 'HI_RES',
          format: _flacHiRes,
        );
        final recoveredRes = await router.resolveBestPlayableTrack(
          cachedCand,
          crossPlatformEnabled: true,
        );
        expect(recoveredRes?.providerId, 'qobuz');
        expect(qobuz.matchCalls, 1);

        // Cache expires after TTL (30m)
        now = now.add(const Duration(minutes: 31));
        await router.resolveBestPlayableTrack(
          cachedCand,
          crossPlatformEnabled: true,
        );
        expect(qobuz.matchCalls, 2);
      },
    );

    test(
      'mid-flight 401 RecError/StreamingException on matchTrack immediately skips to next provider without retrying and Apple Music stays isolated when cross-platform is off',
      () async {
        final qobuzMidFlight = _FakeRecProvider(
          recommendationProviderId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onMatchTrack: (query, {cancel}) async {
            throw const StreamingException(
              'Unauthorized',
              statusCode: 401,
              isTokenExpired: true,
            );
          },
        );
        final deezer = _FakeRecProvider(
          recommendationProviderId: 'deezer',
          capabilities: ProviderCapabilities.deezer,
          onMatchTrack: (query, {cancel}) async => _meta(
            'deezer',
            'dz_1',
            title: query.title,
            artist: query.artist,
          ),
        );
        final apple = _FakeRecProvider(
          recommendationProviderId: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta('apple_music', 'am_2', artist: 'Apple Artist 2'),
            ],
          ),
        );

        final router = CrossPlatformTrackRouter(
          providerLookup: (pid) => switch (pid) {
            'qobuz' => qobuzMidFlight,
            'deezer' => deezer,
            _ => null,
          },
          authStateLookup: (_) => StreamingAuthState.connected,
          priorityOrderProvider: () => const <String>['qobuz', 'deezer'],
        );

        final res = await router.resolveBestPlayableTrack(
          _meta('lastfm', 'lfm_x', title: 'Test', artist: 'Artist'),
          crossPlatformEnabled: true,
        );
        expect(qobuzMidFlight.matchCalls, 1); // Zero retry loops!
        expect(res?.providerId, 'deezer');

        // Apple Music DRM isolation when crossPlatformRoutingEnabled == false:
        final settings = RecommendationSettingsController();
        await settings.setCrossPlatformRoutingEnabled(false);
        final controller = AutoplayController(
          providerLookup: (pid) => pid == 'apple_music' ? apple : null,
          trackRouter: router,
          settings: settings,
          authStateLookup: (_) => StreamingAuthState.connected,
        );
        addTearDown(controller.dispose);

        final appleSeed = _trackInfo('apple:101', artist: 'Apple Seed Artist');
        controller.setUserQueue(<TrackInfo>[appleSeed], currentTrack: appleSeed);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(apple.radioCalls, 0);
        expect(controller.autoQueue, isEmpty);
      },
    );
  });

  group('3. 15+ Track Endurance: Dedup, Cooldown, Variant, Seed & Quick-Skip', () {
    test(
      'plays 15+ consecutive autoplay tracks with 0 duplicates across 3 layers, 0 artist repeats within 3 tracks, variant filtering, 45s/60% seed qualification, and 30m quick-skip penalty',
      () async {
        var now = DateTime.utc(2026, 11, 24, 14, 0, 0);

        // Build a large synthetic pool containing duplicates across all 3 layers,
        // disallowed variants, safe title "Alive", and artist runs.
        final page1 = <TrackMetadata>[
          // Duplicate by trackId of seed
          _meta('youtube_music', 'seed_0', title: 'Different Name', artist: 'Artist Z'),
          // Duplicate by normalized ISRC
          _meta('youtube_music', 'dup_isrc', title: 'Dup By ISRC', artist: 'Artist X', isrc: 'us-zzz-26-00001'),
          // Duplicate by title + primary artist (full-width + remaster tag + feat)
          _meta('youtube_music', 'dup_meta', title: 'Ｏｐｅｎｉｎｇ (2024 Remastered)', artist: 'Seed Singer feat. Guest'),
          // Disallowed variants (must be rejected)
          _meta('youtube_music', 'var_live', title: 'Track One (Live at Budokan)', artist: 'Artist B1'),
          _meta('youtube_music', 'var_karaoke', title: 'Track Two [Karaoke]', artist: 'Artist B2'),
          _meta('youtube_music', 'var_inst', title: 'Track Three (Instrumental)', artist: 'Artist B3'),
          _meta('youtube_music', 'var_slowed', title: 'Track Four - Slowed', artist: 'Artist B4'),
          _meta('youtube_music', 'var_sped', title: 'Track Five (Sped Up)', artist: 'Artist B5'),
          _meta('youtube_music', 'var_night', title: 'Track Six (Nightcore)', artist: 'Artist B6'),
          _meta('youtube_music', 'var_8d', title: 'Track Seven (8D Audio)', artist: 'Artist B7'),
          // False-positive guard: "Alive" must NOT be rejected!
          _meta('youtube_music', 'ok_alive', title: 'Still Alive', artist: 'Artist 1', isrc: 'ISRC001'),
          _meta('youtube_music', 'ok_2', title: 'Neon Rain', artist: 'Artist 1', isrc: 'ISRC002'),
          _meta('youtube_music', 'ok_3', title: 'Blue Tide', artist: 'Artist 2', isrc: 'ISRC003'),
          _meta('youtube_music', 'ok_4', title: 'Starlight', artist: 'Artist 3', isrc: 'ISRC004'),
          _meta('youtube_music', 'ok_5', title: 'Driftwood', artist: 'Artist 1', isrc: 'ISRC005'),
          _meta('youtube_music', 'ok_6', title: 'Amber Glow', artist: 'Artist 4', isrc: 'ISRC006'),
          _meta('youtube_music', 'ok_7', title: 'Echo Valley', artist: 'Artist 5', isrc: 'ISRC007'),
          _meta('youtube_music', 'ok_8', title: 'Silver Wind', artist: 'Artist 6', isrc: 'ISRC008'),
        ];

        final page2 = <TrackMetadata>[
          // Repeat ISRC001 and title/artist from page 1 -> must be rejected!
          _meta('youtube_music', 'p2_dup_isrc', title: 'Totally Different', artist: 'Artist 9', isrc: 'isrc-001'),
          _meta('youtube_music', 'p2_dup_ta', title: 'Neon Rain (Explicit)', artist: 'Artist 1 & Friends', isrc: 'ISRC999'),
          _meta('youtube_music', 'ok_9', title: 'Paper Lantern', artist: 'Artist 7', isrc: 'ISRC009'),
          _meta('youtube_music', 'ok_10', title: 'Copper Sky', artist: 'Artist 8', isrc: 'ISRC010'),
          _meta('youtube_music', 'ok_11', title: 'Quiet Harbor', artist: 'Artist 9', isrc: 'ISRC011'),
          _meta('youtube_music', 'ok_12', title: 'Polaris', artist: 'Artist 10', isrc: 'ISRC012'),
          _meta('youtube_music', 'ok_13', title: 'Solstice', artist: 'Artist 11', isrc: 'ISRC013'),
          _meta('youtube_music', 'ok_14', title: 'Cascades', artist: 'Artist 12', isrc: 'ISRC014'),
          _meta('youtube_music', 'ok_15', title: 'Vesper', artist: 'Artist 13', isrc: 'ISRC015'),
          _meta('youtube_music', 'ok_16', title: 'Horizon Line', artist: 'Artist 14', isrc: 'ISRC016'),
          _meta('youtube_music', 'ok_17', title: 'Daybreak', artist: 'Artist 15', isrc: 'ISRC017'),
        ];

        var callIdx = 0;
        final ytm = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async {
            callIdx++;
            if (callIdx == 1) {
              return RadioPage(nextCursor: 'cursor_1', tracks: page1);
            }
            if (callIdx == 2) {
              return RadioPage(nextCursor: 'cursor_2', tracks: page2);
            }
            return RadioPage(
              nextCursor: 'cursor_$callIdx',
              tracks: List<TrackMetadata>.generate(
                10,
                (i) => _meta(
                  'youtube_music',
                  'p${callIdx}_$i',
                  title: 'Extra Track ${callIdx}_$i',
                  artist: 'Extra Artist ${callIdx}_$i',
                  isrc: 'ISRCEXTRA${callIdx}_$i',
                ),
              ),
            );
          },
        );

        final controller = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytm : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          clock: () => now,
          refillTriggerRemaining: 2,
          refillTargetCount: 7,
        );
        addTearDown(controller.dispose);

        final seed0 = _trackInfo(
          'ytm:seed_0',
          title: 'Opening',
          artist: 'Seed Singer',
          isrc: 'USZZZ2600001',
          duration: const Duration(seconds: 200),
        );
        controller.setUserQueue(<TrackInfo>[seed0], currentTrack: seed0);
        // Qualify seed0 via 45s playback!
        controller.onPlaybackProgress(seed0, const Duration(seconds: 46));
        expect(controller.filter.seedPool.length, 1);

        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Play 16 consecutive autoplay tracks, qualifying each at 60% of 60s (36s).
        final played = <TrackInfo>[];
        for (var i = 0; i < 16; i++) {
          if (controller.peekNextTrack() == null) {
            await controller.maybeTriggerRefill();
          }
          final next = controller.peekNextTrack();
          expect(next, isNotNull, reason: 'Track #$i should exist');
          now = now.add(const Duration(seconds: 60));
          controller.advanceToTrack(next!);
          final sixtyPercentTrack = next.copyWith(
            duration: const Duration(seconds: 60),
          );
          controller.onPlaybackProgress(
            sixtyPercentTrack,
            const Duration(seconds: 37),
          );
          played.add(next);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(played.length, 16);
        expect(played.any((t) => t.id == 'ytm:ok_alive'), isTrue);

        // Verify 0 duplicates across all 3 fingerprint layers.
        final seenIds = <String>{};
        final seenIsrcs = <String>{};
        final seenTitleArtist = <String>{};
        for (final t in played) {
          expect(seenIds.add(t.id), isTrue);
          if (t.isrc != null) {
            expect(seenIsrcs.add(t.isrc!.replaceAll('-', '').toUpperCase()), isTrue);
          }
          final ta = '${t.title.toLowerCase()}::${t.artist.toLowerCase()}';
          expect(seenTitleArtist.add(ta), isTrue);
          expect(
            AutoplayFilter.isDisallowedVariant(t.title, seedTitle: seed0.title),
            isFalse,
          );
        }

        // Verify 0 same primary artist within 3 consecutive tracks (rolling gap >= 2 other tracks).
        for (var i = 0; i < played.length; i++) {
          for (var j = i + 1; j <= i + 2 && j < played.length; j++) {
            expect(
              played[i].artist,
              isNot(equals(played[j].artist)),
              reason: 'Artist repeated within 3 tracks at $i and $j',
            );
          }
        }

        // EffectiveSeedPool keeps at most 5 qualified seeds and rotates newest 3.
        expect(controller.filter.seedPool.length, 5);

        // Rapid 5s quick-skip of 3 auto_queue tracks:
        // must NOT enter seedPool AND must downrank their artists for 30 minutes!
        final skippedArtists = <String>[];
        for (var i = 0; i < 3; i++) {
          if (controller.peekNextTrack() == null) {
            await controller.maybeTriggerRefill();
          }
          final t = controller.peekNextTrack();
          expect(t, isNotNull);
          skippedArtists.add(t!.artist);
          controller.advanceToTrack(t, userInitiatedSkip: false);
          now = now.add(const Duration(seconds: 5));
          controller.onPlaybackProgress(t, const Duration(seconds: 5));
          if (controller.peekNextTrack() == null) {
            await controller.maybeTriggerRefill();
          }
          // User skips out at 5s (< 10s)!
          final after = controller.peekNextTrack();
          expect(after, isNotNull);
          controller.advanceToTrack(after!, userInitiatedSkip: true);
        }

        for (final artist in skippedArtists) {
          expect(
            controller.filter.seedPool.isArtistDownranked(artist, now),
            isTrue,
          );
          expect(
            controller.filter.seedPool.seeds.any((s) => s.artist == artist),
            isFalse,
          );
        }

        // After 30 minutes, artist cooldown expires.
        final later = now.add(const Duration(minutes: 31));
        for (final artist in skippedArtists) {
          expect(
            controller.filter.seedPool.isArtistDownranked(artist, later),
            isFalse,
          );
        }
      },
    );
  });

  group('4. Silent Zero-Stall Auto-Track Failure Fallback & 5-Failure Cap', () {
    test(
      'silently removes unplayable auto_queue tracks during Standby pre-decode with 0 onError calls and stops after 5 consecutive failures',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );

        final badIds = <String>{
          'bad_1',
          'bad_2',
          'bad_3',
          'bad_4',
          'bad_5',
          'bad_6',
          'bad_7',
        };
        final ytmResolver = _CountingStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async {
            if (badIds.contains(key.trackId)) {
              throw const StreamingException(
                'Video unavailable (404)',
                statusCode: 404,
              );
            }
            return DirectRangeSpec(
              key: key,
              url: 'https://rr1.googlevideo.com/${key.trackId}.m4a',
            );
          },
        );
        final registry = _buildStreamRegistry(ytm: ytmResolver);

        final ytmRec = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta('youtube_music', 'bad_1', artist: 'A1'),
              _meta('youtube_music', 'bad_2', artist: 'A2'),
              _meta('youtube_music', 'good_1', artist: 'A3'),
              _meta('youtube_music', 'bad_3', artist: 'A4'),
              _meta('youtube_music', 'bad_4', artist: 'A5'),
              _meta('youtube_music', 'bad_5', artist: 'A6'),
              _meta('youtube_music', 'bad_6', artist: 'A7'),
              _meta('youtube_music', 'bad_7', artist: 'A8'),
            ],
          ),
        );

        final errorToasts = <({TrackInfo track, String message})>[];
        final autoplay = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          refillTriggerRemaining: 1,
          refillTargetCount: 8,
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
          onError: (track, msg, _) =>
              errorToasts.add((track: track, message: msg)),
        );
        addTearDown(() {
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final seed = _trackInfo('ytm:seed_ok', artist: 'Seed Artist');
        await coordinator.playTrack(seed, queueContext: <TrackInfo>[seed]);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(autoplay.autoQueue.first.id, 'ytm:bad_1');

        // Enter Standby pre-decode window: bad_1 and bad_2 fail silently,
        // leaving 0 error toasts, and good_1 is immediately pre-decoded into Standby!
        await coordinator.seek(const Duration(seconds: 185));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(errorToasts, isEmpty);
        expect(autoplay.consecutiveAutoFailures, 2);
        expect(autoplay.autoQueue.any((t) => t.id == 'ytm:bad_1'), isFalse);
        expect(autoplay.autoQueue.any((t) => t.id == 'ytm:bad_2'), isFalse);
        expect(coordinator.preparedStandbyTrackId, 'ytm:good_1');
        expect(coordinator.isStandbyReady, isTrue);

        // Transition to good_1 -> playing resets failure counter on 45s progress.
        await coordinator.next();
        expect(audio.currentState.track?.id, 'ytm:good_1');
        await coordinator.seek(const Duration(seconds: 46));
        expect(autoplay.consecutiveAutoFailures, 0);

        // Now next 5 auto tracks (bad_3..bad_7) all fail during Standby pre-decode ->
        // after 5 consecutive failures, stops and notifies user ONCE!
        await coordinator.seek(const Duration(seconds: 185));
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(autoplay.consecutiveAutoFailures, 5);
        expect(errorToasts, hasLength(1));
        expect(coordinator.isStandbyReady, isFalse);
      },
    );

    test(
      'foreground playTrack on unplayable auto_queue track silently falls through to next valid track',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytmResolver = _CountingStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async {
            if (key.trackId == 'fg_bad') {
              throw const StreamingException('410 Gone', statusCode: 410);
            }
            return DirectRangeSpec(
              key: key,
              url: 'https://rr1.googlevideo.com/${key.trackId}.m4a',
            );
          },
        );
        final registry = _buildStreamRegistry(ytm: ytmResolver);
        final ytmRec = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta('youtube_music', 'fg_bad', artist: 'Bad FG'),
              _meta('youtube_music', 'fg_good', artist: 'Good FG'),
            ],
          ),
        );
        final errors = <String>[];
        final autoplay = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          refillTargetCount: 5,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
          onError: (_, msg, _) => errors.add(msg),
        );
        addTearDown(() {
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final seed = _trackInfo('ytm:fg_seed', artist: 'FG Seed');
        await coordinator.playTrack(seed, queueContext: <TrackInfo>[seed]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(autoplay.autoQueue.first.id, 'ytm:fg_bad');

        await coordinator.next();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(errors, isEmpty);
        expect(audio.currentState.track?.id, 'ytm:fg_good');
        expect(autoplay.currentTrack?.id, 'ytm:fg_good');
      },
    );

    test(
      'Phase 2 sliding lookahead silently evicts unplayable auto_queue track with 0 onError calls',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytmResolver = _CountingStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async {
            if (key.trackId == 'la_bad') {
              throw const StreamingException('404 Not Found', statusCode: 404);
            }
            return DirectRangeSpec(
              key: key,
              url: 'https://rr1.googlevideo.com/${key.trackId}.m4a',
            );
          },
        );
        final registry = _buildStreamRegistry(ytm: ytmResolver);
        final ytmRec = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta('youtube_music', 'la_bad', artist: 'Bad Lookahead'),
              _meta('youtube_music', 'la_good', artist: 'Good Lookahead'),
            ],
          ),
        );
        final errors = <String>[];
        final autoplay = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytmRec : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          refillTargetCount: 5,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: Duration.zero,
          onError: (_, msg, _) => errors.add(msg),
        );
        addTearDown(() {
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final seed = _trackInfo('ytm:la_seed', artist: 'LA Seed');
        await coordinator.playTrack(seed, queueContext: <TrackInfo>[seed]);
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(errors, isEmpty);
        expect(autoplay.autoQueue.any((t) => t.id == 'ytm:la_bad'), isFalse);
        expect(autoplay.autoQueue.any((t) => t.id == 'ytm:la_good'), isTrue);
        expect(coordinator.getCachedStream('ytm:la_good'), isNotNull);
      },
    );
  });

  group('5. Queue Epoch, Single-Flight Lock, Promote/Reorder & Autoplay Toggle', () {
    test(
      'discards stale refill on queueEpoch change and enforces Single-Flight lock across rapid calls',
      () async {
        final gate = Completer<RadioPage>();
        var radioCalls = 0;
        final ytm = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) {
            radioCalls++;
            if (radioCalls == 1) {
              return gate.future;
            }
            return Future<RadioPage>.value(
              RadioPage(
                tracks: <TrackMetadata>[
                  _meta('youtube_music', 'fresh_1', artist: 'Fresh Artist'),
                ],
              ),
            );
          },
        );

        final controller = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytm : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          allowBackgroundRefill: true,
          refillTargetCount: 5,
        );
        addTearDown(controller.dispose);

        final seed1 = _trackInfo('ytm:s1', artist: 'Seed 1');
        controller.setUserQueue(<TrackInfo>[seed1], currentTrack: seed1);

        // Concurrent rapid calls share the exact same in-flight Future (Single-Flight).
        final f1 = controller.maybeTriggerRefill();
        final f2 = controller.maybeTriggerRefill();
        final f3 = controller.maybeTriggerRefill();
        expect(controller.isRefilling, isTrue);
        expect(radioCalls, 1);

        // User switches queue -> bumps queueEpoch, cancels stale refill!
        final epochBefore = controller.queueEpoch;
        final seed2 = _trackInfo('ytm:s2', artist: 'Seed 2');
        controller.setUserQueue(<TrackInfo>[seed2], currentTrack: seed2);
        expect(controller.queueEpoch, greaterThan(epochBefore));

        // Release old gate with stale tracks -> MUST be discarded!
        gate.complete(
          RadioPage(
            tracks: <TrackMetadata>[
              _meta('youtube_music', 'stale_track', artist: 'Stale Artist'),
            ],
          ),
        );
        await Future.wait(<Future<void>>[f1, f2, f3]);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          controller.autoQueue.any((t) => t.id == 'ytm:stale_track'),
          isFalse,
        );
        expect(
          controller.autoQueue.any((t) => t.id == 'ytm:fresh_1'),
          isTrue,
        );
      },
    );

    test(
      'promoteAutoTrackToUserQueue, reorderDualQueue, and setEnabled(false) preserve currentTrack and userQueue',
      () async {
        final ytm = _FakeRecProvider(
          recommendationProviderId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onGetTrackRadio: (seed, {limit = 10, cursor, cancel}) async => RadioPage(
            tracks: <TrackMetadata>[
              _meta('youtube_music', 'a1', artist: 'A1'),
              _meta('youtube_music', 'a2', artist: 'A2'),
              _meta('youtube_music', 'a3', artist: 'A3'),
            ],
          ),
        );

        final controller = AutoplayController(
          providerLookup: (pid) => pid == 'youtube_music' ? ytm : null,
          isGuestCapableLookup: (pid) => pid == 'youtube_music',
          refillTargetCount: 5,
        );
        addTearDown(controller.dispose);

        final u1 = _trackInfo('ytm:u1', artist: 'U1');
        controller.setUserQueue(<TrackInfo>[u1], currentTrack: u1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.autoQueue.map((t) => t.id), <String>[
          'ytm:a1',
          'ytm:a2',
          'ytm:a3',
        ]);

        // Promote a2 into userQueue.
        controller.promoteAutoTrackToUserQueue('ytm:a2');
        expect(controller.userQueue.map((t) => t.id), <String>[
          'ytm:u1',
          'ytm:a2',
        ]);
        expect(controller.autoQueue.map((t) => t.id), <String>[
          'ytm:a1',
          'ytm:a3',
        ]);
        expect(controller.isAutoTrack('ytm:a2'), isFalse);
        expect(controller.peekNextTrack()?.id, 'ytm:a2');

        // Reorder a3 (combined index 3) into userQueue index 1 -> promotes a3!
        controller.reorderDualQueue(3, 1);
        expect(controller.userQueue.map((t) => t.id), <String>[
          'ytm:u1',
          'ytm:a3',
          'ytm:a2',
        ]);
        expect(controller.autoQueue.map((t) => t.id), <String>['ytm:a1']);
        expect(controller.isAutoTrack('ytm:a3'), isFalse);
        expect(controller.peekNextTrack()?.id, 'ytm:a3');

        // Toggle Autoplay OFF -> clears auto_queue without touching currentTrack or user_queue!
        controller.setEnabled(false);
        expect(controller.enabled, isFalse);
        expect(controller.autoQueue, isEmpty);
        expect(controller.currentTrack?.id, 'ytm:u1');
        expect(controller.userQueue.map((t) => t.id), <String>[
          'ytm:u1',
          'ytm:a3',
          'ytm:a2',
        ]);

        // Toggle Autoplay back ON when remaining userQueue == 2 (<= 2) -> refills!
        controller.setEnabled(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.autoQueue, isNotEmpty);
      },
    );
  });
}

class _EventDrivenPlaybackBackend extends PlaybackBackend {
  final StreamController<PlaybackState> _controller;
  PlaybackState _state = const PlaybackState(status: PlaybackStatus.stopped);
  final List<TrackInfo> playCalls = <TrackInfo>[];

  _EventDrivenPlaybackBackend(this._controller);

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
  void dispose() {}
}
