import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/streaming/playback_backend.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/unified_search_controller.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/common/track_hover_prefetch.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/progress_bar.dart';
import 'package:lumina_app/ui/mini_player/quick_queue_popover.dart';
import 'package:lumina_app/ui/search/unified_search_results_view.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:material_ui/material_ui.dart';

TrackInfo _makeTrack(
  String id, {
  String title = '',
  String artist = 'Test Artist',
  String album = 'Test Album',
  String providerName = '',
  String? filePath,
  Duration duration = const Duration(minutes: 4),
}) {
  return TrackInfo(
    id: id,
    title: title.isEmpty ? 'Track $id' : title,
    artist: artist,
    album: album,
    duration: duration,
    filePath: filePath,
    providerName: providerName,
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
  );
}

class _TestStreamResolver implements StreamResolver {
  @override
  final String providerId;

  @override
  final ProviderCapabilities capabilities;

  final Future<StreamSourceSpec> Function(
    StreamKey key, {
    CancellationToken? cancelToken,
  })
  onResolve;

  final List<StreamKey> resolvedKeys = <StreamKey>[];
  final List<CancellationToken?> receivedTokens = <CancellationToken?>[];

  _TestStreamResolver({
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
    receivedTokens.add(cancelToken);
    return onResolve(key, cancelToken: cancelToken);
  }
}

class _FakeBackend implements PlaybackBackend {
  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  PlaybackState _state = const PlaybackState(status: PlaybackStatus.stopped);
  final List<(StreamSourceSpec, TrackInfo, int)> playCalls = [];
  final List<(Duration, int)> seekCalls = [];
  final List<int> stopEpochs = [];

  @override
  PlaybackState get currentState => _state;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  void emitState(PlaybackState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  @override
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    playCalls.add((spec, track, epoch));
    emitState(
      _state.copyWith(
        status: PlaybackStatus.playing,
        track: track,
        position: Duration.zero,
        clearLastError: true,
      ),
    );
  }

  @override
  Future<void> pause() async {
    emitState(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> resume() async {
    emitState(_state.copyWith(status: PlaybackStatus.playing));
  }

  @override
  Future<void> seek(Duration position, {required int epoch}) async {
    seekCalls.add((position, epoch));
    emitState(_state.copyWith(position: position, seekEpoch: epoch));
  }

  @override
  Future<void> setVolume(double volume) async {
    emitState(_state.copyWith(volume: volume.clamp(0.0, 1.0)));
  }

  @override
  Future<void> stop({required int epoch}) async {
    stopEpochs.add(epoch);
    emitState(
      _state.copyWith(
        status: PlaybackStatus.stopped,
        position: Duration.zero,
      ),
    );
  }

  @override
  void dispose() {
    if (!_stateController.isClosed) {
      unawaited(_stateController.close());
    }
  }
}

class _FakeCatalogProvider extends StreamingProvider {
  final String _kind;
  final List<TrackInfo> tracks;

  _FakeCatalogProvider(this._kind, {this.tracks = const <TrackInfo>[]});

  @override
  String get kind => _kind;

  @override
  StreamingProviderMeta get meta => StreamingProviderMeta.byKind(_kind)!;

  @override
  StreamingAuthState get authState => StreamingAuthState.connected;

  @override
  StreamingAccountInfo? get accountInfo =>
      const StreamingAccountInfo(displayName: 'Tester');

  @override
  String? get lastError => null;

  @override
  StreamingCatalog get catalog => StreamingCatalog(tracks: tracks);

  @override
  bool get supportsGuestMode => _kind == 'youtube_music';

  @override
  Future<void> restoreFromStorage() async {}

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {}

  @override
  Future<void> refreshSessionIfNeeded() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async =>
      catalog;

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    return StreamingRecommendations(providerKind: _kind, tracks: tracks);
  }

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) async => null;

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      tracks;

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async {
    return StreamingCatalog(tracks: tracks);
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    return ResolvedStreamResult(
      url: 'https://cdn.example.com/${track.id}.m4a',
      hintExtension: 'm4a',
      format: track.format,
    );
  }
}

class _SpyWarmupStreamingManager extends StreamingManager {
  int warmupCalls = 0;
  int disposeCalls = 0;

  _SpyWarmupStreamingManager()
    : super(
        credentialStore: MemorySecureCredentialStore(),
        enableLiveWarmup: false,
      );

  @override
  Future<void> warmup({bool force = false}) {
    warmupCalls++;
    return super.warmup(force: force);
  }

  @override
  void dispose() {
    disposeCalls++;
    super.dispose();
  }
}

class _FakeAlbumAudioService extends MockAudioService {
  final CanonicalAlbumDetail albumDetail;

  _FakeAlbumAudioService(this.albumDetail);

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    return albumId == albumDetail.id ? albumDetail : null;
  }
}

StreamResolverRegistry _buildPhase2Registry({
  required _TestStreamResolver ytm,
  required _TestStreamResolver qobuz,
  required _TestStreamResolver apple,
}) {
  final registry = StreamResolverRegistry();
  registry.register(
    ytm,
    idPrefixes: const <String>['ytm:', 'streaming:youtube_music:'],
    providerNames: const <String>['youtube music'],
  );
  registry.register(
    qobuz,
    idPrefixes: const <String>['qobuz:', 'streaming:qobuz:'],
    providerNames: const <String>['qobuz'],
  );
  registry.register(
    apple,
    idPrefixes: const <String>['apple:', 'streaming:apple_music:'],
    providerNames: const <String>['apple music'],
  );
  return registry;
}

void main() {
  group('Phase 2: Sliding Lookahead Prefetch (5s stable play)', () {
    testWidgets(
      '5s stable playback resolves ONLY next 1-2 cacheable tracks in a 10-track playlist and slides cleanly',
      (tester) async {
        final audio = MockAudioService();
        final nativeBackend = _FakeBackend();
        final externalBackend = _FakeBackend();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );

        final ytm = _TestStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/${key.trackId}.webm',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 6))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        final qobuz = _TestStreamResolver(
          providerId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://qobuz.cdn.example/${key.trackId}.flac',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        final apple = _TestStreamResolver(
          providerId: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          onResolve: (key, {cancelToken}) async => ExternalBackendSpec(
            key: key,
            providerId: 'apple_music',
            trackUri: 'apple:${key.trackId}',
          ),
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: _buildPhase2Registry(
            ytm: ytm,
            qobuz: qobuz,
            apple: apple,
          ),
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 5),
          lookaheadCount: 2,
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          nativeBackend.dispose();
          externalBackend.dispose();
          audio.dispose();
        });

        final playlist = List<TrackInfo>.generate(
          10,
          (i) => _makeTrack('ytm:song_$i', providerName: 'YouTube Music'),
        );

        await coordinator.playTrack(playlist[0], queueContext: playlist);
        await tester.pump();

        // Only track 0 resolved immediately.
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['song_0']));

        // At 4.9s, lookahead has NOT fired yet.
        await tester.pump(const Duration(milliseconds: 4900));
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['song_0']));

        // Crossing 5.0s resolves ONLY song_1 and song_2 (never song_3..song_9).
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          ytm.resolvedKeys.map((k) => k.trackId),
          equals(['song_0', 'song_1', 'song_2']),
        );

        // Even after 30s more on track 0, playlist tracks 3..9 are NEVER resolved.
        await tester.pump(const Duration(seconds: 30));
        expect(
          ytm.resolvedKeys.map((k) => k.trackId),
          equals(['song_0', 'song_1', 'song_2']),
        );

        // Advancing to song_1 hits warm L1 cache (0 new calls immediately).
        await coordinator.playTrack(playlist[1], queueContext: playlist);
        await tester.pump();
        expect(
          ytm.resolvedKeys.map((k) => k.trackId),
          equals(['song_0', 'song_1', 'song_2']),
        );

        // After 5s stable playback on song_1, sliding window resolves ONLY song_3
        // (song_2 is already warm in L1 cache).
        await tester.pump(const Duration(seconds: 5));
        expect(
          ytm.resolvedKeys.map((k) => k.trackId),
          equals(['song_0', 'song_1', 'song_2', 'song_3']),
        );
      },
    );

    testWidgets(
      'skips Apple Music (supportsL1UrlCache == false) and Local tracks during lookahead',
      (tester) async {
        final audio = MockAudioService();
        final nativeBackend = _FakeBackend();
        final externalBackend = _FakeBackend();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );

        final ytm = _TestStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/${key.trackId}.webm',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 6))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        final qobuz = _TestStreamResolver(
          providerId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://qobuz.cdn.example/${key.trackId}.flac',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        final apple = _TestStreamResolver(
          providerId: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          onResolve: (key, {cancelToken}) async => ExternalBackendSpec(
            key: key,
            providerId: 'apple_music',
            trackUri: 'apple:${key.trackId}',
          ),
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: _buildPhase2Registry(
            ytm: ytm,
            qobuz: qobuz,
            apple: apple,
          ),
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          nativeBackend.dispose();
          externalBackend.dispose();
          audio.dispose();
        });

        final mixedQueue = <TrackInfo>[
          _makeTrack('ytm:t0', providerName: 'YouTube Music'),
          _makeTrack('apple:drm_1', providerName: 'Apple Music'),
          _makeTrack('qobuz:hi_2', providerName: 'Qobuz'),
          _makeTrack(
            'local_3',
            filePath: 'C:/music/local_3.flac',
            providerName: 'Local',
          ),
          _makeTrack('ytm:t4', providerName: 'YouTube Music'),
        ];

        expect(coordinator.canPrefetchTrack(mixedQueue[0]), isTrue);
        expect(coordinator.canPrefetchTrack(mixedQueue[1]), isFalse);
        expect(coordinator.canPrefetchTrack(mixedQueue[2]), isTrue);
        expect(coordinator.canPrefetchTrack(mixedQueue[3]), isFalse);

        await coordinator.playTrack(mixedQueue[0], queueContext: mixedQueue);
        await tester.pump(const Duration(seconds: 5));

        // Apple Music at +1 MUST NOT be resolved; Qobuz at +2 IS prefetched;
        // ytm:t4 at +4 is outside the 2-track window.
        expect(apple.resolvedKeys, isEmpty);
        expect(qobuz.resolvedKeys.map((k) => k.trackId), equals(['hi_2']));
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['t0']));
      },
    );

    testWidgets(
      'pause cancels 5s timer and resume restarts a full 5s countdown',
      (tester) async {
        final audio = MockAudioService();
        final nativeBackend = _FakeBackend();
        final externalBackend = _FakeBackend();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytm = _TestStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/${key.trackId}.webm',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 6))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        final qobuz = _TestStreamResolver(
          providerId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://qobuz.cdn.example/${key.trackId}.flac',
          ),
        );
        final apple = _TestStreamResolver(
          providerId: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          onResolve: (key, {cancelToken}) async => ExternalBackendSpec(
            key: key,
            providerId: 'apple_music',
            trackUri: 'apple:${key.trackId}',
          ),
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: _buildPhase2Registry(
            ytm: ytm,
            qobuz: qobuz,
            apple: apple,
          ),
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          nativeBackend.dispose();
          externalBackend.dispose();
          audio.dispose();
        });

        final queue = <TrackInfo>[
          _makeTrack('ytm:a'),
          _makeTrack('ytm:b'),
          _makeTrack('ytm:c'),
        ];

        await coordinator.playTrack(queue[0], queueContext: queue);
        await tester.pump();

        // Pause at 3s -> timer cancelled; waiting 10s while paused triggers nothing.
        await tester.pump(const Duration(seconds: 3));
        await coordinator.pause();
        await tester.pump(const Duration(seconds: 10));
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['a']));

        // Resume -> restarts full 5s countdown (still 0 prefetch at 4.5s).
        await coordinator.resume();
        await tester.pump(const Duration(milliseconds: 4500));
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['a']));

        // Crossing 5s after resume triggers lookahead for b & c.
        await tester.pump(const Duration(milliseconds: 600));
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['a', 'b', 'c']));
      },
    );

    testWidgets('seek resets the 5s stable-play countdown cleanly', (
      tester,
    ) async {
      final audio = MockAudioService();
      final nativeBackend = _FakeBackend();
      final externalBackend = _FakeBackend();
      final manager = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
        enableLiveWarmup: false,
      );
      final ytm = _TestStreamResolver(
        providerId: 'youtube_music',
        capabilities: ProviderCapabilities.youtubeMusic,
        onResolve: (key, {cancelToken}) async => DirectRangeSpec(
          key: key,
          url: 'https://rr1.googlevideo.com/${key.trackId}.webm',
          expireAt:
              DateTime.now()
                  .add(const Duration(hours: 6))
                  .millisecondsSinceEpoch ~/
              1000,
        ),
      );
      final qobuz = _TestStreamResolver(
        providerId: 'qobuz',
        capabilities: ProviderCapabilities.qobuz,
        onResolve: (key, {cancelToken}) async => DirectRangeSpec(
          key: key,
          url: 'https://qobuz.cdn.example/${key.trackId}.flac',
        ),
      );
      final apple = _TestStreamResolver(
        providerId: 'apple_music',
        capabilities: ProviderCapabilities.appleMusic,
        onResolve: (key, {cancelToken}) async => ExternalBackendSpec(
          key: key,
          providerId: 'apple_music',
          trackUri: 'apple:${key.trackId}',
        ),
      );

      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        resolverRegistry: _buildPhase2Registry(
          ytm: ytm,
          qobuz: qobuz,
          apple: apple,
        ),
        nativeBackend: nativeBackend,
        externalBackend: externalBackend,
        debounceDelay: Duration.zero,
      );
      addTearDown(() {
        coordinator.dispose();
        manager.dispose();
        nativeBackend.dispose();
        externalBackend.dispose();
        audio.dispose();
      });

      final queue = <TrackInfo>[_makeTrack('ytm:s0'), _makeTrack('ytm:s1')];
      await coordinator.playTrack(queue[0], queueContext: queue);
      await tester.pump();

      // Seek at 3s resets the 5s timer.
      await tester.pump(const Duration(seconds: 3));
      await coordinator.seek(const Duration(seconds: 40));
      await tester.pump();

      // 3s after seek (6s total) -> still NOT fired yet.
      await tester.pump(const Duration(seconds: 3));
      expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['s0']));

      // 5s after seek -> now fires.
      await tester.pump(const Duration(seconds: 2));
      expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['s0', 's1']));
    });

    testWidgets(
      'Single-Flight isolation: cancelling prefetch waiter NEVER cancels foreground playback, and clicking mid-prefetch shares the exact 1 flight',
      (tester) async {
        final audio = MockAudioService();
        final nativeBackend = _FakeBackend();
        final externalBackend = _FakeBackend();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );

        final completers = <String, Completer<StreamSourceSpec>>{};
        final resolveCounts = <String, int>{};

        final ytm = _TestStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) {
            resolveCounts[key.trackId] = (resolveCounts[key.trackId] ?? 0) + 1;
            if (key.trackId == 'track_0') {
              return Future<StreamSourceSpec>.value(
                DirectRangeSpec(
                  key: key,
                  url: 'https://rr1.googlevideo.com/track_0.webm',
                  expireAt:
                      DateTime.now()
                          .add(const Duration(hours: 6))
                          .millisecondsSinceEpoch ~/
                      1000,
                ),
              );
            }
            final comp = Completer<StreamSourceSpec>();
            completers[key.trackId] = comp;
            return comp.future;
          },
        );
        final qobuz = _TestStreamResolver(
          providerId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://qobuz.cdn.example/${key.trackId}.flac',
          ),
        );
        final apple = _TestStreamResolver(
          providerId: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          onResolve: (key, {cancelToken}) async => ExternalBackendSpec(
            key: key,
            providerId: 'apple_music',
            trackUri: 'apple:${key.trackId}',
          ),
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: _buildPhase2Registry(
            ytm: ytm,
            qobuz: qobuz,
            apple: apple,
          ),
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          nativeBackend.dispose();
          externalBackend.dispose();
          audio.dispose();
        });

        final queue = <TrackInfo>[
          _makeTrack('ytm:track_0'),
          _makeTrack('ytm:track_1'),
          _makeTrack('ytm:track_2'),
        ];

        // Part A: Start foreground playback of track_1 + concurrent prefetch of track_1.
        // Cancelling the prefetch waiter MUST NOT cancel foreground playback!
        final foregroundFuture = coordinator.playTrack(
          queue[1],
          queueContext: queue,
        );
        final prefetchToken = CancellationToken();
        final prefetchFuture = coordinator.prefetchTrack(
          queue[1],
          cancelToken: prefetchToken,
        );
        await tester.pump();

        expect(resolveCounts['track_1'], equals(1));
        prefetchToken.cancel();
        await tester.pump();

        // Underlying task token MUST still be uncancelled because foreground waiter is active!
        expect(ytm.receivedTokens.last?.isCancelled, isFalse);
        expect(coordinator.inFlightResolutionCount, equals(1));

        completers['track_1']!.complete(
          DirectRangeSpec(
            key: const StreamKey('youtube_music', 'track_1', 'default'),
            url: 'https://rr1.googlevideo.com/track_1.webm',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 6))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        await foregroundFuture;
        await prefetchFuture;
        await tester.pump();

        expect(nativeBackend.playCalls.last.$2.id, equals('ytm:track_1'));
        expect(coordinator.inFlightResolutionCount, equals(0));

        // Part B: 5s stable playback on track_1 starts lookahead prefetch of track_2.
        // Clicking track_2 mid-prefetch shares the EXACT same Single-Flight task (1 call total).
        await tester.pump(const Duration(seconds: 5));
        expect(resolveCounts['track_2'], equals(1));
        expect(coordinator.inFlightResolutionCount, equals(1));

        final play2Future = coordinator.playTrack(queue[2], queueContext: queue);
        await tester.pump();
        expect(resolveCounts['track_2'], equals(1));
        expect(ytm.receivedTokens.last?.isCancelled, isFalse);

        completers['track_2']!.complete(
          DirectRangeSpec(
            key: const StreamKey('youtube_music', 'track_2', 'default'),
            url: 'https://rr1.googlevideo.com/track_2.webm',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 6))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        await play2Future;
        await tester.pump();

        expect(nativeBackend.playCalls.last.$2.id, equals('ytm:track_2'));
        expect(resolveCounts['track_2'], equals(1));
        expect(coordinator.inFlightResolutionCount, equals(0));

        // Part C: stop() cancels any armed timer and active in-flight lookahead cleanly.
        await coordinator.stop();
        await tester.pump();
        expect(coordinator.inFlightResolutionCount, equals(0));
      },
    );
  });

  group('Phase 2: Desktop Track List 300ms Hover Debounce Prefetch', () {
    testWidgets(
      'TrackHoverPrefetch cancels <300ms exit, fires once at >=300ms, skips local & touch, and cancels on unmount',
      (tester) async {
        final prefetched = <String>[];
        final streamTrack = _makeTrack(
          'ytm:hover_1',
          providerName: 'YouTube Music',
        );
        final localTrack = _makeTrack(
          'local_1',
          filePath: 'C:/music/song.flac',
          providerName: 'Local',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrackPrefetchScope(
                onPrefetchTrack: (t) => prefetched.add(t.id),
                child: Column(
                  children: [
                    TrackHoverPrefetch(
                      track: streamTrack,
                      child: const SizedBox(
                        key: Key('stream_row'),
                        width: 200,
                        height: 40,
                      ),
                    ),
                    TrackHoverPrefetch(
                      track: localTrack,
                      child: const SizedBox(
                        key: Key('local_row'),
                        width: 200,
                        height: 40,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await tester.pump();

        // 1. Hover streaming row for 200ms (<300ms) then exit -> 0 calls.
        final streamCenter = tester.getCenter(
          find.byKey(const Key('stream_row')),
        );
        await mouse.moveTo(streamCenter);
        await tester.pump(const Duration(milliseconds: 200));
        await mouse.moveTo(const Offset(500, 500));
        await tester.pump(const Duration(milliseconds: 300));
        expect(prefetched, isEmpty);

        // 2. Hover streaming row for 300ms -> fires once.
        await mouse.moveTo(streamCenter);
        await tester.pump(const Duration(milliseconds: 299));
        expect(prefetched, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        expect(prefetched, equals(['ytm:hover_1']));

        // Staying hovered does NOT spam additional calls.
        await tester.pump(const Duration(seconds: 2));
        expect(prefetched, equals(['ytm:hover_1']));

        // 3. Hovering local row for 500ms -> skipped (0 calls).
        final localCenter = tester.getCenter(find.byKey(const Key('local_row')));
        await mouse.moveTo(localCenter);
        await tester.pump(const Duration(milliseconds: 500));
        expect(prefetched, equals(['ytm:hover_1']));

        // 4. Touch pointer is ignored (does not trigger desktop hover prefetch).
        await mouse.moveTo(const Offset(500, 500));
        await tester.pump();
        final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
        await touch.down(streamCenter);
        await tester.pump(const Duration(milliseconds: 400));
        await touch.up();
        expect(prefetched, equals(['ytm:hover_1']));

        // 5. Unmounting while timer is pending cancels cleanly without firing.
        await mouse.moveTo(streamCenter);
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 400));
        expect(prefetched, equals(['ytm:hover_1']));
      },
    );

    testWidgets(
      'QuickQueuePopover with CoordinatingAudioService prefetches streaming rows after 300ms hover (even without TrackPrefetchScope) and skips Apple Music / local / cached',
      (tester) async {
        final innerAudio = MockAudioService();
        final nativeBackend = _FakeBackend();
        final externalBackend = _FakeBackend();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );

        final ytm = _TestStreamResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/${key.trackId}.webm',
            expireAt:
                DateTime.now()
                    .add(const Duration(hours: 6))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        );
        final qobuz = _TestStreamResolver(
          providerId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onResolve: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://qobuz.cdn.example/${key.trackId}.flac',
          ),
        );
        final apple = _TestStreamResolver(
          providerId: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          onResolve: (key, {cancelToken}) async => ExternalBackendSpec(
            key: key,
            providerId: 'apple_music',
            trackUri: 'apple:${key.trackId}',
          ),
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: innerAudio,
          streamingManager: manager,
          resolverRegistry: _buildPhase2Registry(
            ytm: ytm,
            qobuz: qobuz,
            apple: apple,
          ),
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
        );
        final coordAudio = CoordinatingAudioService(
          inner: innerAudio,
          coordinator: coordinator,
        );

        final queue = <TrackInfo>[
          _makeTrack('ytm:qq_1', title: 'YTM Queue Track'),
          _makeTrack('apple:qq_2', title: 'Apple Queue Track'),
          _makeTrack(
            'local_qq_3',
            title: 'Local Queue Track',
            filePath: 'C:/music/local.flac',
          ),
        ];
        coordinator.setQueueContext(queue);

        addTearDown(() {
          coordAudio.dispose();
          coordinator.dispose();
          manager.dispose();
          nativeBackend.dispose();
          externalBackend.dispose();
          innerAudio.dispose();
        });

        // No TrackPrefetchScope ancestor: simulates root OverlayEntry!
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: QuickQueuePopover(
                  audioService: coordAudio,
                  onClose: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await tester.pump();

        // Hover YTM row for 300ms -> warms L1 cache once.
        final ytmRow = find.byKey(const Key('quick_queue_item_ytm:qq_1'));
        expect(ytmRow, findsOneWidget);
        await mouse.moveTo(tester.getCenter(ytmRow));
        await tester.pump(const Duration(milliseconds: 320));
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['qq_1']));

        // Leave and re-hover already-cached YTM row -> 0 extra resolver calls.
        await mouse.moveTo(Offset.zero);
        await tester.pump();
        await mouse.moveTo(tester.getCenter(ytmRow));
        await tester.pump(const Duration(milliseconds: 350));
        expect(ytm.resolvedKeys.map((k) => k.trackId), equals(['qq_1']));

        // Hover Apple Music row for 400ms -> 0 resolver calls (supportsL1UrlCache == false).
        final appleRow = find.byKey(const Key('quick_queue_item_apple:qq_2'));
        await mouse.moveTo(tester.getCenter(appleRow));
        await tester.pump(const Duration(milliseconds: 400));
        expect(apple.resolvedKeys, isEmpty);

        // Hover Local row for 400ms -> 0 resolver calls.
        final localRow = find.byKey(const Key('quick_queue_item_local_qq_3'));
        await mouse.moveTo(tester.getCenter(localRow));
        await tester.pump(const Duration(milliseconds: 400));
        expect(ytm.resolvedKeys.length, equals(1));
        expect(apple.resolvedKeys, isEmpty);
      },
    );

    testWidgets(
      'StreamingServiceView, UnifiedSearchResultsView, and AlbumDetailPage wire 300ms hover prefetch via TrackPrefetchScope',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefetched = <String>[];
        final ytmTrack = _makeTrack(
          'ytm:svc_1',
          title: 'Starlight Drive',
          artist: 'Synth Wave',
          providerName: 'YouTube Music',
        );
        final provider = _FakeCatalogProvider(
          'youtube_music',
          tracks: <TrackInfo>[ytmTrack],
        );
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: <String, StreamingProvider>{'youtube_music': provider},
          enableLiveWarmup: false,
        );
        final audio = MockAudioService();
        addTearDown(() {
          manager.dispose();
          audio.dispose();
        });

        // 1. StreamingServiceView
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrackPrefetchScope(
                onPrefetchTrack: (t) => prefetched.add(t.id),
                child: StreamingServiceView(
                  audioService: audio,
                  provider: StreamingProviderMeta.byKind('youtube_music')!,
                  streamingManager: manager,
                  onOpenProviderSettings: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await tester.pump();

        final svcRow = find.text('Starlight Drive');
        expect(svcRow, findsOneWidget);
        await mouse.moveTo(tester.getCenter(svcRow));
        await tester.pump(const Duration(milliseconds: 320));
        expect(prefetched, equals(['ytm:svc_1']));

        // 2. UnifiedSearchResultsView
        prefetched.clear();
        final libraryCache = LibraryIndexCache();
        final librarySettings = LibrarySettingsController();
        final searchController = UnifiedSearchController(
          audioService: audio,
          libraryCache: libraryCache,
          streamingManager: manager,
          librarySettings: librarySettings,
        );
        addTearDown(() {
          searchController.dispose();
          libraryCache.dispose();
          librarySettings.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrackPrefetchScope(
                onPrefetchTrack: (t) => prefetched.add(t.id),
                child: UnifiedSearchResultsView(
                  controller: searchController,
                  audioService: audio,
                  libraryCache: libraryCache,
                  streamingManager: manager,
                  onOpenLocalAlbum: (_) {},
                  onOpenStreamingAlbum: (_) {},
                  onOpenArtist: (_) {},
                  onPlayStreamingTrack: (_, {queueContext}) async {},
                ),
              ),
            ),
          ),
        );
        searchController.updateQuery('Starlight', immediate: true);
        await tester.pumpAndSettle();

        await mouse.moveTo(Offset.zero);
        await tester.pump();
        final searchRow = find.text('Starlight Drive').first;
        await mouse.moveTo(tester.getCenter(searchRow));
        await tester.pump(const Duration(milliseconds: 320));
        expect(prefetched, equals(['ytm:svc_1']));

        // 3. AlbumDetailPage with streaming version track
        prefetched.clear();
        final albumDetail = CanonicalAlbumDetail(
          id: 'alb_stream_1',
          title: 'Neon Horizon',
          artistName: 'Synth Wave',
          versions: const <AlbumVersionInfo>[
            AlbumVersionInfo(
              id: 'ver_qobuz_1',
              provider: 'qobuz',
              externalAlbumId: 'qobuz_alb_1',
              editionLabel: 'Hi-Res Studio Master',
              codec: 'flac',
              sampleRateHz: 96000,
              bitDepth: 24,
              tracks: <AlbumVersionTrackInfo>[
                AlbumVersionTrackInfo(
                  id: 'qobuz:alb_trk_1',
                  title: 'Midnight Pulse',
                  discNumber: 1,
                  trackNumber: 1,
                  durationMs: 210000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'alb_trk_1',
                ),
              ],
            ),
          ],
        );
        final albumAudio = _FakeAlbumAudioService(albumDetail);
        addTearDown(albumAudio.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrackPrefetchScope(
                onPrefetchTrack: (t) => prefetched.add(t.id),
                child: AlbumDetailPage(
                  albumId: albumDetail.id,
                  audioService: albumAudio,
                  streamingManager: manager,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await mouse.moveTo(Offset.zero);
        await tester.pump();
        final albumRow = find.text('Midnight Pulse');
        expect(albumRow, findsOneWidget);
        await mouse.moveTo(tester.getCenter(albumRow));
        await tester.pump(const Duration(milliseconds: 320));
        expect(prefetched, equals(['qobuz:alb_trk_1']));
      },
    );
  });

  group('Phase 2: Seek Drag 100ms Throttle + Exact Final Commit', () {
    testWidgets(
      'continuous 550ms drag dispatches onSeek at most once per 100ms, never snaps back, and commits exact final drop position',
      (tester) async {
        final dispatchedSeeks = <Duration>[];
        final committedFinal = <Duration>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: TrackProgressBar(
                    position: const Duration(seconds: 10),
                    duration: const Duration(seconds: 200),
                    onSeek: dispatchedSeeks.add,
                    onChangeEnd: committedFinal.add,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final slider = find.byKey(const Key('track_progress_slider'));
        final rect = tester.getRect(slider);

        // Start drag near 20% and scrub smoothly for ~550ms (11 steps of 50ms).
        final gesture = await tester.startGesture(
          Offset(rect.left + rect.width * 0.2, rect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 50));

        for (var i = 1; i <= 10; i++) {
          final frac = 0.2 + i * 0.06; // reaches 0.80
          await gesture.moveTo(
            Offset(rect.left + rect.width * frac, rect.center.dy),
          );
          await tester.pump(const Duration(milliseconds: 50));

          // While dragging, displayed time must NOT snap back to stale 00:10.
          if (i >= 3) {
            expect(find.text('00:10'), findsNothing);
          }
        }

        // Before release: 550ms of scrubbing with 100ms throttle => at most 6 live seeks.
        expect(dispatchedSeeks.length, greaterThanOrEqualTo(3));
        expect(dispatchedSeeks.length, lessThanOrEqualTo(6));

        // Final micro-move right before drop (within current 100ms window) then release.
        await gesture.moveTo(
          Offset(rect.left + rect.width * 0.85, rect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.up();
        await tester.pump();

        // Exact final drop position MUST be committed and equal to last dispatched seek.
        expect(committedFinal, hasLength(1));
        expect(dispatchedSeeks.last, equals(committedFinal.single));
        // No duplicate trailing dispatch if final equals last.
        expect(
          dispatchedSeeks.length >= 2 &&
              dispatchedSeeks.last ==
                  dispatchedSeeks[dispatchedSeeks.length - 2],
          isFalse,
        );
      },
    );

    testWidgets(
      'quick <100ms drag still dispatches exact final seek once on release',
      (tester) async {
        final dispatchedSeeks = <Duration>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: TrackProgressBar(
                    position: Duration.zero,
                    duration: const Duration(seconds: 200),
                    onSeek: dispatchedSeeks.add,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final slider = find.byKey(const Key('track_progress_slider'));
        final rect = tester.getRect(slider);

        final gesture = await tester.startGesture(
          Offset(rect.left + rect.width * 0.1, rect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveTo(
          Offset(rect.left + rect.width * 0.6, rect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.up();
        await tester.pump();

        // Only 1 seek dispatched on release (no 100ms timer ever fired before drop).
        expect(dispatchedSeeks, hasLength(1));
        expect(dispatchedSeeks.single.inSeconds, greaterThan(90));
      },
    );
  });

  group('Phase 2: Startup Warmup Trigger & TrackPrefetchScope Wiring', () {
    testWidgets(
      'HomeScreen triggers StreamingManager.warmup() post-first-frame and exposes TrackPrefetchScope',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final audio = MockAudioService();
        final spyManager = _SpyWarmupStreamingManager();
        final persistence = PlaybackPersistenceService();
        addTearDown(() {
          spyManager.dispose();
          persistence.dispose();
          audio.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: HomeScreen(
              audioService: audio,
              streamingManager: spyManager,
              playbackPersistenceService: persistence,
            ),
          ),
        );

        // Post-frame callback fires right after first frame renders.
        expect(spyManager.warmupCalls, equals(1));

        // Descendant widgets inside HomeScreen receive a live TrackPrefetchScope.
        final scaffoldFinder = find.byType(Scaffold).first;
        final ctx = tester.element(scaffoldFinder);
        expect(TrackPrefetchScope.maybeOf(ctx), isNotNull);

        // Tear down cleanly without leaking timers or disposing injected manager.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(spyManager.disposeCalls, equals(0));
      },
    );
  });
}
