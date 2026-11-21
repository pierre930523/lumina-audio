import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/ui/mini_player/playback_controls.dart';
import 'package:material_ui/material_ui.dart';

class _FakeStreamingProvider implements StreamingProvider {
  @override
  final String kind;

  @override
  final StreamingProviderMeta meta;

  @override
  StreamingAuthState authState = StreamingAuthState.connected;

  @override
  StreamingAccountInfo? accountInfo;

  @override
  String? lastError;

  @override
  StreamingCatalog catalog = StreamingCatalog.empty();

  final List<String> resolvedIds = [];
  final List<CancellationToken?> seenTokens = [];
  Future<ResolvedStreamResult> Function(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
  })? onResolve;

  _FakeStreamingProvider(this.kind)
      : meta = StreamingProviderMeta.byKind(kind)!;

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
  }) async =>
      StreamingRecommendations.empty(kind);

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) async =>
      null;

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      const [];

  @override
  Future<StreamingCatalog> search(String query) async => catalog;

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    resolvedIds.add(track.id);
    seenTokens.add(cancel);
    if (onResolve != null) {
      return onResolve!(track, cancel: cancel, timeout: timeout);
    }
    return ResolvedStreamResult(
      url: 'https://cdn.example.com/${track.id}.flac',
      hintExtension: 'flac',
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 96000,
        bitDepth: 24,
        channels: 2,
      ),
    );
  }
}

class _SpyAudioService extends MockAudioService {
  final List<(String trackId, int requestId)> asyncPlayCalls = [];
  int cancelPendingCalls = 0;

  @override
  Future<void> cancelPendingPlayback() async {
    cancelPendingCalls++;
    await super.cancelPendingPlayback();
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) async {
    asyncPlayCalls.add((track.id, requestId));
    await super.playStreamUrlAsync(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      requestId: requestId,
    );
  }
}

class _RealTestHttpOverrides extends HttpOverrides {}

TrackInfo _track(
  String id, {
  String? providerName,
  Duration duration = const Duration(minutes: 3),
}) {
  final inferredProvider = providerName ??
      switch (id.split(':').first) {
        'ytm' => 'YouTube Music',
        'tidal' => 'Tidal',
        'qobuz' => 'Qobuz',
        'deezer' => 'Deezer',
        'apple' => 'Apple Music',
        _ => 'Qobuz',
      };
  return TrackInfo(
    id: id,
    title: 'Title $id',
    artist: 'Artist $id',
    album: 'Album $id',
    duration: duration,
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    providerName: inferredProvider,
  );
}

void main() {
  group('StreamingPlaybackCoordinator', () {
    test(
      'emits optimistic loading state immediately and supersedes hung request cleanly',
      () async {
        final audio = _SpyAudioService();
        final qobuz = _FakeStreamingProvider('qobuz');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'qobuz': qobuz},
        );
        final slowCompleter = Completer<ResolvedStreamResult>();
        qobuz.onResolve = (track, {cancel, timeout}) {
          if (track.id == 'qobuz:slow') {
            return slowCompleter.future;
          }
          return Future.value(
            ResolvedStreamResult(
              url: 'https://cdn.example.com/fast.flac',
              hintExtension: 'flac',
              format: const AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 96000,
                bitDepth: 24,
                channels: 2,
              ),
            ),
          );
        };

        final statuses = <PlaybackStatus>[];
        final sub = audio.stateStream.listen((s) => statuses.add(s.status));

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
        );

        final slowFuture = coordinator.playTrack(_track('qobuz:slow'));
        expect(audio.currentState.status, PlaybackStatus.loading);
        expect(audio.currentState.track?.id, 'qobuz:slow');

        // Immediately switch to fast track while slow is stalled.
        await coordinator.playTrack(_track('qobuz:fast'));
        expect(qobuz.seenTokens.first?.isCancelled, isTrue);
        expect(audio.cancelPendingCalls, greaterThanOrEqualTo(2));
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(audio.currentState.track?.id, 'qobuz:fast');
        expect(audio.asyncPlayCalls, [('qobuz:fast', 2)]);

        // Late resolution of slow track must be discarded silently.
        slowCompleter.complete(
          ResolvedStreamResult(
            url: 'https://cdn.example.com/slow.flac',
            hintExtension: 'flac',
            format: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 44100,
              bitDepth: 16,
              channels: 2,
            ),
          ),
        );
        await slowFuture;
        expect(audio.currentState.track?.id, 'qobuz:fast');
        expect(audio.asyncPlayCalls.length, 1);
        expect(statuses, contains(PlaybackStatus.loading));

        await sub.cancel();
        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'debounces rapid next() skipping so only the final track resolves over network',
      () async {
        final audio = _SpyAudioService();
        final tidal = _FakeStreamingProvider('tidal');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'tidal': tidal},
        );
        final queue = [
          _track('tidal:1', providerName: 'Tidal'),
          _track('tidal:2', providerName: 'Tidal'),
          _track('tidal:3', providerName: 'Tidal'),
          _track('tidal:4', providerName: 'Tidal'),
        ];

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          debounceDelay: const Duration(milliseconds: 60),
        );

        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(tidal.resolvedIds, ['tidal:1']);

        // 3 rapid skips within debounce window.
        unawaited(audio.next());
        unawaited(audio.next());
        final lastSkip = audio.next();

        // UI tracks the final track optimistically right away in Loading state.
        expect(audio.currentState.track?.id, 'tidal:4');
        expect(audio.currentState.status, PlaybackStatus.loading);

        await lastSkip;
        expect(tidal.resolvedIds, ['tidal:1', 'tidal:4']);
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(audio.currentState.track?.id, 'tidal:4');

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'enforces per-provider cache TTL (YTM expire-60s / 15m, Tidal/Qobuz/Deezer 10m, Apple 30m)',
      () async {
        var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
        final ytm = _FakeStreamingProvider('youtube_music');
        final tidal = _FakeStreamingProvider('tidal');
        final apple = _FakeStreamingProvider('apple_music');
        final expireEpoch =
            now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;

        ytm.onResolve = (track, {cancel, timeout}) async => ResolvedStreamResult(
              url: track.id == 'ytm:exp'
                  ? 'https://rr1.googlevideo.com/videoplayback?expire=$expireEpoch'
                  : 'https://rr1.googlevideo.com/videoplayback?id=noexp',
              hintExtension: 'm4a',
              format: const AudioFormat(
                codec: AudioCodec.aac,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
              ),
            );

        final audio = _SpyAudioService();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {
            'youtube_music': ytm,
            'tidal': tidal,
            'apple_music': apple,
          },
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          clock: () => now,
        );

        // YTM with expire=5m -> cached for 4m (expire - 60s).
        await coordinator.playTrack(_track('ytm:exp'));
        await coordinator.playTrack(_track('ytm:exp'));
        expect(ytm.resolvedIds, ['ytm:exp']);

        now = now.add(const Duration(minutes: 4, seconds: 1));
        await coordinator.playTrack(_track('ytm:exp'));
        expect(ytm.resolvedIds, ['ytm:exp', 'ytm:exp']);

        // YTM without expire= -> fallback 15m.
        await coordinator.playTrack(_track('ytm:fallback'));
        now = now.add(const Duration(minutes: 14));
        await coordinator.playTrack(_track('ytm:fallback'));
        expect(ytm.resolvedIds.where((id) => id == 'ytm:fallback').length, 1);
        now = now.add(const Duration(minutes: 2));
        await coordinator.playTrack(_track('ytm:fallback'));
        expect(ytm.resolvedIds.where((id) => id == 'ytm:fallback').length, 2);

        // Tidal -> 10m TTL.
        await coordinator.playTrack(_track('tidal:t1'));
        now = now.add(const Duration(minutes: 9));
        await coordinator.playTrack(_track('tidal:t1'));
        expect(tidal.resolvedIds.length, 1);
        now = now.add(const Duration(minutes: 2));
        await coordinator.playTrack(_track('tidal:t1'));
        expect(tidal.resolvedIds.length, 2);

        // Apple -> 30m TTL.
        await coordinator.playTrack(_track('apple:a1'));
        now = now.add(const Duration(minutes: 29));
        await coordinator.playTrack(_track('apple:a1'));
        expect(apple.resolvedIds.length, 1);
        now = now.add(const Duration(minutes: 2));
        await coordinator.playTrack(_track('apple:a1'));
        expect(apple.resolvedIds.length, 2);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'pre-resolves next queue track silently within 15s of track end without spamming',
      () async {
        final audio = _SpyAudioService();
        final deezer = _FakeStreamingProvider('deezer');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'deezer': deezer},
        );
        final queue = [
          _track(
            'deezer:1',
            providerName: 'Deezer',
            duration: const Duration(seconds: 120),
          ),
          _track(
            'deezer:2',
            providerName: 'Deezer',
            duration: const Duration(seconds: 180),
          ),
        ];

        var errorCalls = 0;
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          onError: (_, _, _) => errorCalls++,
        );

        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(deezer.resolvedIds, ['deezer:1']);

        // Seeking before the 15s threshold does not pre-resolve yet.
        await audio.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(deezer.resolvedIds, ['deezer:1']);

        // Entering last 15s pre-resolves deezer:2 silently once.
        await audio.seek(const Duration(seconds: 106));
        await audio.seek(const Duration(seconds: 110));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(deezer.resolvedIds, ['deezer:1', 'deezer:2']);
        expect(errorCalls, 0);

        // Transitioning to deezer:2 reuses warm pre-resolved cache immediately.
        await coordinator.playTrack(queue[1]);
        expect(deezer.resolvedIds, ['deezer:1', 'deezer:2']);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'fails optimistically on timeout and clears error on subsequent track load',
      () async {
        final audio = _SpyAudioService();
        final qobuz = _FakeStreamingProvider('qobuz');
        qobuz.onResolve = (track, {cancel, timeout}) async {
          if (track.id == 'qobuz:hang') {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          return ResolvedStreamResult(
            url: 'https://cdn.example.com/${track.id}.flac',
            hintExtension: 'flac',
            format: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 44100,
              bitDepth: 16,
              channels: 2,
            ),
          );
        };
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'qobuz': qobuz},
        );
        final errors = <String>[];

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolveTimeout: const Duration(milliseconds: 50),
          onError: (_, msg, _) => errors.add(msg),
        );

        await coordinator.playTrack(_track('qobuz:hang'));
        expect(audio.currentState.status, PlaybackStatus.error);
        expect(errors.length, 1);

        await coordinator.playTrack(_track('qobuz:ok'));
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(audio.currentState.lastError, isNull);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'evicts cached URL and fires onError once when async native playback emits PlaybackStatus.error',
      () async {
        final audio = _SpyAudioService();
        final qobuz = _FakeStreamingProvider('qobuz');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'qobuz': qobuz},
        );
        final errors = <String>[];
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          onError: (_, msg, _) => errors.add(msg),
        );

        final track = _track('qobuz:badurl');
        await coordinator.playTrack(track);
        expect(qobuz.resolvedIds, ['qobuz:badurl']);
        expect(coordinator.getCachedStream('qobuz:badurl'), isNotNull);

        // Simulate Rust failing asynchronously after accepting the URL.
        audio.failOptimisticTrackLoad(track, 'HTTP 403 Forbidden');
        await Future<void>.delayed(Duration.zero);

        expect(coordinator.getCachedStream('qobuz:badurl'), isNull);
        expect(errors, ['HTTP 403 Forbidden']);

        // Retrying must resolve freshly instead of reusing the evicted URL.
        await coordinator.playTrack(track);
        expect(qobuz.resolvedIds, ['qobuz:badurl', 'qobuz:badurl']);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'routes play(track: null) and togglePlayPause() to streaming handler after stop or restorePlaybackSession',
      () async {
        final audio = _SpyAudioService();
        final tidal = _FakeStreamingProvider('tidal');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'tidal': tidal},
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
        );

        final track = _track('tidal:99', providerName: 'Tidal');
        await audio.restorePlaybackSession(
          track: track,
          position: const Duration(seconds: 42),
          queue: [track],
          queueIndex: 0,
        );

        await audio.togglePlayPause();
        expect(tidal.resolvedIds, ['tidal:99']);
        expect(audio.asyncPlayCalls, [('tidal:99', 1)]);
        expect(audio.currentState.status, PlaybackStatus.playing);

        await audio.stop();
        await audio.play();
        expect(audio.asyncPlayCalls, [('tidal:99', 1), ('tidal:99', 2)]);
        expect(audio.currentState.status, PlaybackStatus.playing);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'StreamingHttpClient cancels stalled HTTP request via CancellationToken',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final client = StreamingHttpClient(
            timeout: const Duration(seconds: 5),
          );
          final cancel = CancellationToken();

          final sub = server.listen((req) {
            // Hold response open indefinitely without replying.
          });

          final future = client.requestJson(
            method: 'GET',
            uri: Uri.parse('http://127.0.0.1:${server.port}/hung'),
            cancel: cancel,
          );
          Timer(const Duration(milliseconds: 30), cancel.cancel);

          await expectLater(
            future,
            throwsA(
              isA<StreamingException>().having(
                (e) => e.isCancelled,
                'isCancelled',
                isTrue,
              ),
            ),
          );

          await sub.cancel();
          await server.close(force: true);
        }, _RealTestHttpOverrides());
      },
    );
  });

  group('PlaybackControls loading/buffering spinner', () {
    for (final busyStatus in const [
      PlaybackStatus.loading,
      PlaybackStatus.buffering,
    ]) {
      testWidgets(
        'renders btn_play_pause_loading inside btn_play_pause while keeping skip buttons clickable (${busyStatus.name})',
        (tester) async {
          var prevTaps = 0;
          var nextTaps = 0;

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: PlaybackControls(
                    status: busyStatus,
                    onPrevious: () => prevTaps++,
                    onPlayPause: () {},
                    onNext: () => nextTaps++,
                  ),
                ),
              ),
            ),
          );

          expect(find.byKey(const Key('btn_play_pause')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const Key('btn_play_pause')),
              matching: find.byKey(const Key('btn_play_pause_loading')),
            ),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('btn_previous')));
          await tester.tap(find.byKey(const Key('btn_next')));
          expect(prevTaps, 1);
          expect(nextTaps, 1);
        },
      );
    }
  });
}
