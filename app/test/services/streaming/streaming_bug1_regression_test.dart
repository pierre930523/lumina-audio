import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';

TrackInfo _buildTrack(String id, {String? filePath, String? providerName}) {
  final isLocal = filePath != null;
  final resolvedProvider = providerName ??
      (isLocal
          ? 'Local Library'
          : switch (id.split(':').first) {
              'ytm' => 'YouTube Music',
              'tidal' => 'Tidal',
              'apple' => 'Apple Music',
              _ => 'Streaming',
            });
  return TrackInfo(
    id: id,
    title: 'Track $id',
    artist: 'Artist $id',
    album: 'Album $id',
    duration: const Duration(minutes: 3),
    filePath: filePath,
    providerName: resolvedProvider,
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
  );
}

class _DelayedResolver implements StreamResolver {
  @override
  final String providerId;
  @override
  final ProviderCapabilities capabilities;
  final Future<StreamSourceSpec> Function(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) handler;
  final List<StreamKey> resolvedKeys = <StreamKey>[];
  final List<CancellationToken> tokens = <CancellationToken>[];

  _DelayedResolver({
    required this.providerId,
    required this.capabilities,
    required this.handler,
  });

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    if (cancelToken != null) tokens.add(cancelToken);
    resolvedKeys.add(key);
    return handler(key, cancelToken: cancelToken);
  }
}

class _SpyYtDlp extends YtDlpService {
  final List<int?> cancelProcessCalls = <int?>[];

  @override
  void cancelPlaybackProcesses({int? exceptRequestId}) {
    cancelProcessCalls.add(exceptRequestId);
    super.cancelPlaybackProcesses(exceptRequestId: exceptRequestId);
  }
}

StreamResolverRegistry _registryFor({
  required _DelayedResolver ytm,
  required _DelayedResolver tidal,
}) {
  final reg = StreamResolverRegistry();
  reg.register(
    ytm,
    idPrefixes: const <String>['ytm:', 'youtube_music:'],
    providerNames: const <String>['youtube music'],
  );
  reg.register(
    tidal,
    idPrefixes: const <String>['tidal:'],
    providerNames: const <String>['tidal'],
  );
  return reg;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Bug #1 Cross-Source Switching & Pause-During-Resolve Regressions', () {
    test(
      'pause during debounced YTM resolve emits paused immediately without stopped flicker, cancels resolve, and resume restarts playback',
      () async {
        final audio = MockAudioService();
        final ytDlp = _SpyYtDlp();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          ytDlpService: ytDlp,
          enableLiveWarmup: false,
        );
        final ytm = _DelayedResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          handler: (key, {cancelToken}) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            cancelToken?.throwIfCancelled();
            return DirectRangeSpec(
              key: key,
              url: 'https://ytm.example/${key.trackId}.opus',
              hintExtension: 'opus',
            );
          },
        );
        final tidal = _DelayedResolver(
          providerId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          handler: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://tidal.example/${key.trackId}.flac',
            hintExtension: 'flac',
          ),
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          ytDlpService: ytDlp,
          resolverRegistry: _registryFor(ytm: ytm, tidal: tidal),
          debounceDelay: const Duration(milliseconds: 140),
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          audio.dispose();
        });

        final observedStatuses = <PlaybackStatus>[];
        final sub = coordinator.stateStream.listen(
          (s) => observedStatuses.add(s.status),
        );
        addTearDown(sub.cancel);

        final ytmTrack = _buildTrack('ytm:debounce_pause_1');
        final playFuture = coordinator.playTrack(ytmTrack, debounce: true);

        expect(coordinator.currentState.status, PlaybackStatus.loading);
        expect(coordinator.currentState.position, Duration.zero);
        expect(ytm.resolvedKeys, isEmpty);

        // Pause immediately while debounce timer is still pending.
        await coordinator.pause();
        await playFuture;

        expect(coordinator.currentState.status, PlaybackStatus.paused);
        expect(coordinator.currentState.track?.id, ytmTrack.id);
        expect(observedStatuses, isNot(contains(PlaybackStatus.stopped)));

        // Even past the 140ms debounce window, cancelled track must NOT resolve.
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(ytm.resolvedKeys, isEmpty);
        expect(coordinator.currentState.status, PlaybackStatus.paused);

        // Resuming starts resolution cleanly and settles into Playing.
        await coordinator.resume();
        expect(ytm.resolvedKeys, hasLength(1));
        expect(coordinator.currentState.status, PlaybackStatus.playing);
        expect(coordinator.currentState.track?.id, ytmTrack.id);
      },
    );

    test(
      'pause during in-flight YTM HTTP resolve cancels CancellationToken and emits paused without leaking stale ready',
      () async {
        final audio = MockAudioService();
        final ytDlp = _SpyYtDlp();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          ytDlpService: ytDlp,
          enableLiveWarmup: false,
        );
        final firstStarted = Completer<void>();
        final stalledFirst = Completer<StreamSourceSpec>();
        var callCount = 0;

        final ytm = _DelayedResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          handler: (key, {cancelToken}) async {
            callCount++;
            if (callCount == 1) {
              if (!firstStarted.isCompleted) firstStarted.complete();
              return stalledFirst.future;
            }
            return DirectRangeSpec(
              key: key,
              url: 'https://ytm.example/${key.trackId}.opus',
              hintExtension: 'opus',
            );
          },
        );
        final tidal = _DelayedResolver(
          providerId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          handler: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://tidal.example/${key.trackId}.flac',
            hintExtension: 'flac',
          ),
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          ytDlpService: ytDlp,
          resolverRegistry: _registryFor(ytm: ytm, tidal: tidal),
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          audio.dispose();
        });

        final ytmTrack = _buildTrack('ytm:inflight_pause_1');
        final playFuture = coordinator.playTrack(ytmTrack);
        await firstStarted.future;
        expect(coordinator.currentState.status, PlaybackStatus.loading);
        expect(ytm.tokens, hasLength(1));

        ytDlp.cancelProcessCalls.clear();
        await coordinator.pause();
        await playFuture;

        expect(ytm.tokens.single.isCancelled, isTrue);
        expect(ytDlp.cancelProcessCalls, contains(null));
        expect(coordinator.currentState.status, PlaybackStatus.paused);

        // Stale resolve completing afterward must NOT restart playback.
        stalledFirst.complete(
          DirectRangeSpec(
            key: const StreamKey('youtube_music', 'inflight_pause_1', 'default'),
            url: 'https://ytm.example/stale.opus',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(coordinator.currentState.status, PlaybackStatus.paused);

        // togglePlayPause / resume re-resolves and finishes playing cleanly.
        await coordinator.togglePlayPause();
        expect(callCount, 2);
        expect(coordinator.currentState.status, PlaybackStatus.playing);
        expect(coordinator.currentState.track?.id, ytmTrack.id);
      },
    );

    test(
      '5x spaced cross-source switches (YTM <-> Tidal <-> Local) immediately reset loading + Duration.zero and clear empty Autoplay queue',
      () async {
        final audio = MockAudioService();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytm = _DelayedResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          handler: (key, {cancelToken}) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return DirectRangeSpec(
              key: key,
              url: 'https://ytm.example/${key.trackId}.opus',
              hintExtension: 'opus',
            );
          },
        );
        final tidal = _DelayedResolver(
          providerId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          handler: (key, {cancelToken}) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return DirectRangeSpec(
              key: key,
              url: 'https://tidal.example/${key.trackId}.flac',
              hintExtension: 'flac',
            );
          },
        );
        final autoplay = AutoplayController(
          providerLookup: (_) => null,
          allowBackgroundRefill: false,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: _registryFor(ytm: ytm, tidal: tidal),
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          audio.dispose();
        });

        final tracks = <TrackInfo>[
          _buildTrack('ytm:cross_1'),
          _buildTrack('tidal:cross_2'),
          _buildTrack('local_3', filePath: 'C:/Music/cross_3.flac'),
          _buildTrack('tidal:cross_4'),
          _buildTrack('ytm:cross_5'),
        ];

        final stateEvents = <PlaybackState>[];
        final posEvents = <Duration>[];
        final stateSub = coordinator.stateStream.listen(stateEvents.add);
        final posSub = coordinator.positionStream.listen(posEvents.add);
        addTearDown(() async {
          await stateSub.cancel();
          await posSub.cancel();
        });

        // Start on a baseline local track and seek to 45s before running 5x cross-source switches.
        final baseline = _buildTrack(
          'local_baseline',
          filePath: 'C:/Music/baseline.flac',
        );
        await coordinator.playTrack(baseline, queueContext: tracks);
        await coordinator.seek(const Duration(seconds: 45));
        await Future<void>.delayed(Duration.zero);
        expect(coordinator.currentState.position, const Duration(seconds: 45));

        for (final t in tracks) {
          await coordinator.seek(const Duration(seconds: 45));
          await Future<void>.delayed(Duration.zero);
          stateEvents.clear();
          posEvents.clear();
          final fut = coordinator.playTrack(t, queueContext: tracks);
          if (t.filePath == null) {
            // Streaming tracks remain in loading + Duration.zero synchronously while resolving.
            expect(coordinator.currentState.track?.id, t.id);
            expect(coordinator.currentState.status, PlaybackStatus.loading);
            expect(coordinator.currentState.position, Duration.zero);
          }
          await fut;
          await Future<void>.delayed(Duration.zero);

          expect(stateEvents, isNotEmpty);
          expect(stateEvents.first.track?.id, t.id);
          expect(stateEvents.first.status, PlaybackStatus.loading);
          expect(stateEvents.first.position, Duration.zero);
          expect(posEvents.first, Duration.zero);
          expect(coordinator.currentState.status, PlaybackStatus.playing);
          expect(coordinator.currentState.track?.id, t.id);
        }

        // Clearing AutoplayController must also clear coordinator shared queue.
        expect(coordinator.hasSharedQueue, isTrue);
        autoplay.clearAll();
        await Future<void>.delayed(Duration.zero);
        expect(autoplay.combinedQueue, isEmpty);
        expect(coordinator.hasSharedQueue, isFalse);
      },
    );
  });
}
