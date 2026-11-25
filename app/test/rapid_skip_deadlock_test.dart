import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/server_audio_service.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/playback_backend.dart';
import 'package:lumina_app/services/streaming/pot_provider.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';
import 'package:lumina_app/services/streaming/ytm_resident_resolver.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:material_ui/material_ui.dart';

class _DirectHttpOverrides extends HttpOverrides {}

class _TrackingResolver implements StreamResolver {
  @override
  final String providerId;
  @override
  final ProviderCapabilities capabilities;

  final List<StreamKey> resolvedKeys = <StreamKey>[];
  final List<CancellationToken> observedTokens = <CancellationToken>[];
  final Duration resolveDelay;
  final StreamSourceSpec Function(StreamKey key) specBuilder;

  _TrackingResolver({
    required this.providerId,
    required this.capabilities,
    required this.specBuilder,
    this.resolveDelay = const Duration(milliseconds: 25),
  });

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    if (cancelToken != null) {
      observedTokens.add(cancelToken);
    }
    resolvedKeys.add(key);

    if (resolveDelay > Duration.zero) {
      final completer = Completer<void>();
      final timer = Timer(resolveDelay, () {
        if (!completer.isCompleted) completer.complete();
      });
      void onCancel() {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(
            const StreamingException('操作已取消', isCancelled: true),
          );
        }
      }

      cancelToken?.addListener(onCancel);
      try {
        await completer.future;
      } finally {
        timer.cancel();
        cancelToken?.removeListener(onCancel);
      }
    }
    cancelToken?.throwIfCancelled();
    return specBuilder(key);
  }
}

class _SpySkipAudioService extends MockAudioService {
  final List<({TrackInfo track, StreamSourceSpec spec, int epoch, bool debounced})>
      specPlays =
      <({TrackInfo track, StreamSourceSpec spec, int epoch, bool debounced})>[];
  final List<int> cancelEpochs = <int>[];
  final List<({String trackId, int epoch})> optimisticLoads =
      <({String trackId, int epoch})>[];
  int rawPlayCalls = 0;

  final StreamController<PlaybackState> _rawOverrideController =
      StreamController<PlaybackState>.broadcast();
  StreamSubscription<PlaybackState>? _superSub;
  bool _wired = false;

  @override
  Stream<PlaybackState> get stateStream {
    if (!_wired) {
      _wired = true;
      _superSub = super.stateStream.listen((s) {
        if (!_rawOverrideController.isClosed) {
          _rawOverrideController.add(s);
        }
      });
    }
    return _rawOverrideController.stream;
  }

  void injectBackendState(PlaybackState state) {
    if (!_rawOverrideController.isClosed) {
      _rawOverrideController.add(state);
    }
  }

  @override
  void beginOptimisticTrackLoadAtEpoch(
    TrackInfo track, {
    List<TrackInfo>? queue,
    required int epoch,
  }) {
    optimisticLoads.add((trackId: track.id, epoch: epoch));
    super.beginOptimisticTrackLoadAtEpoch(track, queue: queue, epoch: epoch);
  }

  @override
  Future<void> cancelPendingPlaybackAtEpoch(int epoch) async {
    cancelEpochs.add(epoch);
    await super.cancelPendingPlaybackAtEpoch(epoch);
  }

  @override
  Future<void> play({TrackInfo? track}) {
    rawPlayCalls++;
    return super.play(track: track);
  }

  @override
  Future<void> playStreamSpecWithOptions(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) async {
    specPlays.add((
      track: track,
      spec: spec,
      epoch: epoch,
      debounced: debounced,
    ));
    await super.playStreamSpecWithOptions(
      track,
      spec,
      epoch: epoch,
      debounced: debounced,
    );
  }

  @override
  void dispose() {
    unawaited(_superSub?.cancel());
    unawaited(_rawOverrideController.close());
    super.dispose();
  }
}

class _SpyYtDlpService extends YtDlpService {
  final List<int?> cancelExceptIds = <int?>[];
  int stopFfmpegCalls = 0;

  @override
  void cancelPlaybackProcesses({int? exceptRequestId}) {
    cancelExceptIds.add(exceptRequestId);
    super.cancelPlaybackProcesses(exceptRequestId: exceptRequestId);
  }

  @override
  void stopFfmpegProxy({int? exceptRequestId}) {
    stopFfmpegCalls++;
    super.stopFfmpegProxy(exceptRequestId: exceptRequestId);
  }
}

List<TrackInfo> _buildMixedQueue(int count) {
  const rates = <int>[44100, 48000, 96000];
  return List<TrackInfo>.generate(count, (i) {
    final sr = rates[i % rates.length];
    final mod = i % 3;
    if (mod == 0) {
      final vid = 'vid${i.toString().padLeft(8, '0')}';
      return TrackInfo(
        id: 'ytm:$vid',
        title: 'YTM Track #$i',
        artist: 'YTM Artist $i',
        album: 'YTM Album',
        duration: const Duration(minutes: 3, seconds: 30),
        coverUrl: 'https://i.ytimg.com/vi/$vid/hqdefault.jpg',
        providerName: 'YouTube Music',
        format: AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (mod == 1) {
      return TrackInfo(
        id: 'tidal:${1000 + i}',
        title: 'Tidal Hi-Res #$i',
        artist: 'Tidal Artist $i',
        album: 'Tidal Master',
        duration: const Duration(minutes: 4, seconds: 10),
        coverUrl: 'https://resources.tidal.com/images/$i/1280x1280.jpg',
        providerName: 'Tidal',
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: sr,
          bitDepth: sr >= 96000 ? 24 : 16,
          channels: 2,
        ),
      );
    }
    return TrackInfo(
      id: 'local:$i',
      title: 'Local FLAC #$i (${sr ~/ 1000}kHz)',
      artist: 'Local Artist $i',
      album: 'Lossless Archive',
      duration: const Duration(minutes: 5),
      filePath: 'C:/Music/lossless_${i}_${sr}hz.flac',
      coverUrl: 'file:///C:/Music/cover_$i.jpg',
      providerName: 'Local Library',
      format: AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: sr,
        bitDepth: sr >= 96000 ? 24 : 16,
        channels: 2,
      ),
    );
  });
}

StreamResolverRegistry _buildMixedRegistry({
  required _TrackingResolver ytm,
  required _TrackingResolver tidal,
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
  group('Rapid Skip Deadlock Prevention (30 clicks in 3s across mixed sources)', () {
    test(
      '30 rapid next/prev clicks update optimistic UI 30x immediately, coalesce to 1 final settled play (debounced: true), and leak 0 tokens/processes',
      () async {
        var now = DateTime.utc(2026, 11, 25, 12, 0, 0);
        final audio = _SpySkipAudioService();
        final ytDlp = _SpyYtDlpService();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          ytDlpService: ytDlp,
          enableLiveWarmup: false,
        );
        final ytmResolver = _TrackingResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          resolveDelay: const Duration(milliseconds: 40),
          specBuilder: (key) => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/videoplayback?id=${key.trackId}',
            hintExtension: 'webm',
            audioFormat: const AudioFormat(
              codec: AudioCodec.opus,
              sampleRateHz: 48000,
              bitDepth: 16,
              channels: 2,
            ),
          ),
        );
        final tidalResolver = _TrackingResolver(
          providerId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          resolveDelay: const Duration(milliseconds: 40),
          specBuilder: (key) => SegmentedManifestSpec(
            key: key,
            manifestUrlOrXml:
                '<MPD><Period><AdaptationSet><Representation codecs="flac"/></AdaptationSet></Period></MPD>',
            format: ManifestFormat.dash,
            mimeType: 'audio/flac',
            audioFormat: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 96000,
              bitDepth: 24,
              channels: 2,
            ),
          ),
        );
        final registry = _buildMixedRegistry(
          ytm: ytmResolver,
          tidal: tidalResolver,
        );
        final nativeBackend = NativePlaybackBackend(audio);
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          ytDlpService: ytDlp,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          debounceDelay: const Duration(milliseconds: 130),
          rapidSkipWindow: const Duration(milliseconds: 300),
          lookaheadDelay: const Duration(seconds: 60),
          clock: () => now,
        );
        addTearDown(() {
          coordinator.dispose();
          nativeBackend.dispose();
          manager.dispose();
          ytDlp.dispose();
          audio.dispose();
        });

        final queue = _buildMixedQueue(35);
        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(audio.specPlays, hasLength(1));
        expect(audio.specPlays.single.debounced, isFalse);

        // Single spaced click (>300ms later) executes IMMEDIATELY (0ms debounce).
        now = now.add(const Duration(seconds: 2));
        final singleSw = Stopwatch()..start();
        await coordinator.next(); // -> queue[1] (Tidal HI_RES)
        singleSw.stop();
        expect(singleSw.elapsedMilliseconds, lessThan(120));
        expect(coordinator.currentState.track?.id, queue[1].id);
        expect(audio.specPlays, hasLength(2));
        expect(audio.specPlays.last.track.id, queue[1].id);
        expect(audio.specPlays.last.debounced, isFalse);

        // Reset counters before 30 rapid clicks inside a 3s burst (each <= 90ms apart,
        // starting 80ms after the previous skip so all 30 clicks are in rapid mode).
        audio.specPlays.clear();
        audio.cancelEpochs.clear();
        audio.optimisticLoads.clear();
        ytmResolver.resolvedKeys.clear();
        tidalResolver.resolvedKeys.clear();
        ytDlp.cancelExceptIds.clear();

        final observedOptimisticTitles = <String>[];
        final expectedFinalIdx = 1 + 25 - 5; // 25 next, 5 prev -> index 21 (YTM)

        Future<void>? lastFuture;
        for (var i = 0; i < 30; i++) {
          now = now.add(const Duration(milliseconds: 90));
          final clickSw = Stopwatch()..start();
          lastFuture = i < 25 ? coordinator.next() : coordinator.previous();
          clickSw.stop();

          // Every click updates optimistic UI synchronously (<10ms) with zero block!
          expect(clickSw.elapsedMilliseconds, lessThan(50));
          final cur = coordinator.currentState;
          expect(cur.status, PlaybackStatus.loading);
          expect(cur.playbackEpoch, equals(coordinator.currentEpoch));
          observedOptimisticTitles.add(cur.track!.title);
        }

        // All 30 clicks immediately updated optimistic UI metadata!
        expect(observedOptimisticTitles, hasLength(30));
        expect(observedOptimisticTitles.last, queue[expectedFinalIdx].title);
        expect(audio.optimisticLoads, hasLength(30));

        // During the rapid burst, ZERO stream resolves & ZERO backend plays fired!
        expect(ytmResolver.resolvedKeys, isEmpty);
        expect(tidalResolver.resolvedKeys, isEmpty);
        expect(audio.specPlays, isEmpty);

        // Backend FFI cancel was coalesced to AT MOST ONCE for the entire 30-click burst!
        expect(audio.cancelEpochs.length, 1);

        // Pipeline mode cancelled yt-dlp/ffmpeg processes immediately on every skip!
        expect(ytDlp.cancelExceptIds.length, 30);

        // Wait for adaptive 130ms debounce to settle.
        await lastFuture;

        // ONLY the final settled track (#30 -> index 21, YTM) resolved & played!
        expect(ytmResolver.resolvedKeys, hasLength(1));
        expect(tidalResolver.resolvedKeys, isEmpty);
        expect(audio.specPlays, hasLength(1));
        expect(audio.specPlays.single.track.id, queue[expectedFinalIdx].id);
        expect(audio.specPlays.single.debounced, isTrue);
        expect(audio.lastPlayDebounced, isTrue);
        expect(coordinator.currentState.status, PlaybackStatus.playing);
        expect(coordinator.currentState.track?.id, queue[expectedFinalIdx].id);
        expect(coordinator.inFlightResolutionCount, 0);
      },
    );

    test(
      'mixed YTM -> Local lossless skip cancels pending YTM debounce and dispatches LocalFileSpec asynchronously with monotonic epoch',
      () async {
        var now = DateTime.utc(2026, 11, 25, 13, 0, 0);
        final audio = _SpySkipAudioService();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytmResolver = _TrackingResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          resolveDelay: const Duration(milliseconds: 50),
          specBuilder: (key) => DirectRangeSpec(
            key: key,
            url: 'https://rr1.googlevideo.com/videoplayback?id=${key.trackId}',
          ),
        );
        final tidalResolver = _TrackingResolver(
          providerId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          specBuilder: (key) => DirectRangeSpec(
            key: key,
            url: 'https://tidal.example/${key.trackId}.flac',
          ),
        );
        final registry = _buildMixedRegistry(
          ytm: ytmResolver,
          tidal: tidalResolver,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: registry,
          debounceDelay: const Duration(milliseconds: 120),
          rapidSkipWindow: const Duration(milliseconds: 300),
          lookaheadDelay: const Duration(seconds: 60),
          clock: () => now,
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          audio.dispose();
        });

        final queue = _buildMixedQueue(6);
        // queue[0]=YTM, queue[1]=Tidal, queue[2]=Local(96k), queue[3]=YTM, queue[4]=Tidal, queue[5]=Local(96k)
        await coordinator.playTrack(queue[0], queueContext: queue);
        final epochAfterInitial = coordinator.currentEpoch;
        audio.specPlays.clear();
        ytmResolver.resolvedKeys.clear();

        // Click 1 (spaced) -> queue[1] Tidal (sets _lastSkipAt)
        now = now.add(const Duration(seconds: 1));
        unawaited(coordinator.next());
        // Click 2 (40ms later, rapid!) -> queue[2] Local 96kHz
        now = now.add(const Duration(milliseconds: 40));
        unawaited(coordinator.next());
        // Click 3 (40ms later, rapid!) -> queue[3] YTM
        now = now.add(const Duration(milliseconds: 40));
        unawaited(coordinator.next());
        // Click 4 (40ms later, rapid!) -> queue[4] Tidal
        now = now.add(const Duration(milliseconds: 40));
        unawaited(coordinator.next());
        // Click 5 (40ms later, rapid!) -> queue[5] Local lossless!
        now = now.add(const Duration(milliseconds: 40));
        final settled = coordinator.next();

        expect(coordinator.currentState.track?.id, queue[5].id);
        expect(coordinator.currentEpoch, greaterThan(epochAfterInitial));

        await settled;
        await Future<void>.delayed(const Duration(milliseconds: 160));

        // Stale YTM never resolved or hijacked Local!
        expect(ytmResolver.resolvedKeys, isEmpty);
        // Final settled track is LocalFileSpec dispatched via playStreamSpecWithOptions(debounced: true)!
        expect(audio.specPlays.last.track.id, queue[5].id);
        expect(audio.specPlays.last.spec, isA<LocalFileSpec>());
        expect(audio.specPlays.last.debounced, isTrue);
        expect(coordinator.currentState.track?.id, queue[5].id);
        expect(coordinator.currentState.status, PlaybackStatus.playing);
      },
    );

    test(
      'FfiAudioService, ServerAudioService, and StreamingPlaybackCoordinator drop stale epoch < currentEpoch and epoch == 0 events with zero flash-back',
      () async {
        // 1. FfiAudioService epoch filtering & payload encoding
        final ffi = FfiAudioService(headless: true);
        addTearDown(ffi.dispose);

        final trackOld = _buildMixedQueue(3)[0];
        final trackNew = _buildMixedQueue(3)[1];
        final encoded = jsonDecode(
          ffi.encodeStreamSpecPayloadForTest(
            trackNew,
            DirectRangeSpec(
              key: StreamKey('tidal', '1001', 'default'),
              url: 'https://tidal.example/1001.flac',
            ),
            epoch: 12,
            debounced: true,
          ),
        ) as Map<String, dynamic>;
        expect(encoded['playback_epoch'], 12);
        expect(encoded['epoch'], 12);
        expect(encoded['debounced'], isTrue);

        ffi.beginOptimisticTrackLoadAtEpoch(trackNew, epoch: 12);
        expect(ffi.activeEpoch, 12);
        expect(ffi.currentState.playbackEpoch, 12);
        expect(ffi.currentState.track?.id, trackNew.id);

        // Stale epoch < 12 is rejected.
        expect(
          ffi.processStateJsonForTest(<String, dynamic>{
            'state_code': 2,
            'playback_epoch': 11,
            'current_track_id': trackOld.id,
            'position_ms': 42000,
          }),
          isFalse,
        );
        // Missing / zero epoch while activeEpoch > 0 is ALSO rejected (no stateEpoch==0 bypass!).
        expect(
          ffi.processStateJsonForTest(<String, dynamic>{
            'state_code': 2,
            'playback_epoch': 0,
            'current_track_id': trackOld.id,
            'position_ms': 43000,
          }),
          isFalse,
        );
        expect(
          ffi.processStateJsonForTest(<String, dynamic>{
            'state_code': 2,
            'current_track_id': trackOld.id,
            'position_ms': 44000,
          }),
          isFalse,
        );
        expect(ffi.currentState.track?.id, trackNew.id);

        // Current epoch == 12 is accepted.
        expect(
          ffi.processStateJsonForTest(<String, dynamic>{
            'state_code': 2,
            'playback_epoch': 12,
            'play_request_id': 12,
            'loaded_request_id': 12,
            'current_track_id': trackNew.id,
            'position_ms': 1000,
          }),
          isTrue,
        );
        expect(ffi.currentState.status, PlaybackStatus.playing);
        expect(ffi.currentState.playbackEpoch, 12);
        expect(ffi.currentState.track?.id, trackNew.id);

        // 2. ServerAudioService WS stale epoch filtering + HTTP payload/abort
        final receivedPlayBodies = <Map<String, dynamic>>[];
        final slowFirstRequest = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serverSub = server.listen((req) async {
          if (req.uri.path == '/api/v1/playback/play') {
            final text = await utf8.decoder.bind(req).join();
            final body = jsonDecode(text) as Map<String, dynamic>;
            receivedPlayBodies.add(body);
            if (receivedPlayBodies.length == 1) {
              await slowFirstRequest.future.timeout(
                const Duration(seconds: 2),
                onTimeout: () {},
              );
            }
            try {
              req.response.statusCode = 200;
              final reqEpoch = (body['playback_epoch'] as num?)?.toInt() ?? 0;
              if (reqEpoch == 13) {
                req.response.write(
                  '{"status":"loading","playback_epoch":13}',
                );
              } else if (reqEpoch == 14) {
                req.response.write(
                  '{"status":"ignored","playback_epoch":14}',
                );
              } else {
                req.response.write('{"ok":true}');
              }
              await req.response.close();
            } catch (_) {}
          } else {
            req.response.statusCode = 200;
            req.response.write('{}');
            await req.response.close();
          }
        });
        final remote = ServerAudioService(
          baseUrl: 'http://127.0.0.1:${server.port}',
          bearerToken: 'tok',
        );
        addTearDown(() async {
          if (!slowFirstRequest.isCompleted) slowFirstRequest.complete();
          remote.dispose();
          await serverSub.cancel();
          await server.close(force: true);
        });

        remote.beginOptimisticTrackLoadAtEpoch(trackNew, epoch: 10);
        expect(remote.currentState.track?.id, trackNew.id);
        expect(remote.currentState.playbackEpoch, 10);

        // Stale WS events (epoch 9 and epoch 0) must be dropped!
        remote.handleWsMessageForTest(<String, dynamic>{
          'type': 'PlaybackStateChanged',
          'payload': <String, dynamic>{
            'status': 'playing',
            'playback_epoch': 9,
            'current_track_id': trackOld.id,
            'current_track': <String, dynamic>{
              'track_id': trackOld.id,
              'title': trackOld.title,
              'artist': trackOld.artist,
            },
          },
        });
        remote.handleWsMessageForTest(<String, dynamic>{
          'type': 'event',
          'event': 'track_changed',
          'payload': <String, dynamic>{
            'playback_epoch': 0,
            'track': <String, dynamic>{
              'track_id': trackOld.id,
              'title': trackOld.title,
              'artist': trackOld.artist,
            },
          },
        });
        expect(remote.currentState.track?.id, trackNew.id);
        expect(remote.currentState.status, PlaybackStatus.loading);

        // Epoch-less queue_updated (msgEpoch == 0) while _activeEpoch > 0 must be dropped!
        remote.handleWsMessageForTest(<String, dynamic>{
          'type': 'event',
          'event': 'queue_updated',
          'payload': <String, dynamic>{
            'queue': <Map<String, dynamic>>[
              <String, dynamic>{
                'track_id': trackOld.id,
                'title': trackOld.title,
                'artist': trackOld.artist,
              },
            ],
          },
        });
        expect(remote.queue.map((t) => t.id), isNot(contains(trackOld.id)));

        // Superseded HTTP play is aborted immediately; newer play sends playback_epoch & debounced: true.
        final req1 = remote.playStreamSpecWithOptions(
          trackOld,
          DirectRangeSpec(
            key: StreamKey('youtube_music', 'vid00000000', 'default'),
            url: 'https://ytm.example/old.m4a',
          ),
          epoch: 11,
          debounced: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final req2 = remote.playStreamSpecWithOptions(
          trackNew,
          DirectRangeSpec(
            key: StreamKey('tidal', '1001', 'default'),
            url: 'https://tidal.example/new.flac',
          ),
          epoch: 12,
          debounced: true,
        );
        await Future.wait(<Future<void>>[req1, req2]);
        expect(remote.currentState.track?.id, trackNew.id);
        expect(remote.currentState.playbackEpoch, 12);
        expect(receivedPlayBodies.last['playback_epoch'], 12);
        expect(receivedPlayBodies.last['epoch'], 12);
        expect(receivedPlayBodies.last['debounced'], isTrue);

        // Async server response status=="loading" must NOT prematurely flip to playing.
        await remote.playStreamSpecWithOptions(
          trackNew,
          DirectRangeSpec(
            key: StreamKey('tidal', '1001', 'default'),
            url: 'https://tidal.example/new.flac',
          ),
          epoch: 13,
          debounced: true,
        );
        expect(remote.currentState.status, PlaybackStatus.loading);
        expect(remote.currentState.playbackEpoch, 13);

        // Async server response status=="ignored" must NOT flip status to playing.
        await remote.playStreamSpecWithOptions(
          trackOld,
          DirectRangeSpec(
            key: StreamKey('youtube_music', 'vid00000000', 'default'),
            url: 'https://ytm.example/old.m4a',
          ),
          epoch: 14,
          debounced: true,
        );
        expect(remote.currentState.status, PlaybackStatus.loading);

        // 3. Coordinator drops stale old-track playing event during pending optimistic load
        //    AND recovers cleanly without epoch drift after coordinator.stop() and direct audioService.stop().
        final spyAudio = _SpySkipAudioService();
        final mgr = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytmRes = _TrackingResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          resolveDelay: const Duration(milliseconds: 80),
          specBuilder: (key) => DirectRangeSpec(
            key: key,
            url: 'https://ytm.example/${key.trackId}.m4a',
          ),
        );
        final tidalRes = _TrackingResolver(
          providerId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          resolveDelay: const Duration(milliseconds: 80),
          specBuilder: (key) => DirectRangeSpec(
            key: key,
            url: 'https://tidal.example/${key.trackId}.flac',
          ),
        );
        final coord = StreamingPlaybackCoordinator(
          audioService: spyAudio,
          streamingManager: mgr,
          resolverRegistry: _buildMixedRegistry(ytm: ytmRes, tidal: tidalRes),
          debounceDelay: const Duration(milliseconds: 100),
        );
        addTearDown(() {
          coord.dispose();
          mgr.dispose();
          spyAudio.dispose();
        });

        final emittedIds = <String?>[];
        final sub = coord.stateStream.listen((s) => emittedIds.add(s.track?.id));
        addTearDown(sub.cancel);

        final pendingPlay = coord.playTrack(
          trackNew,
          queueContext: <TrackInfo>[trackOld, trackNew],
          debounce: true,
        );
        final curEpoch = coord.currentEpoch;
        emittedIds.clear();

        // Inject stale playing states for trackOld (both epoch < curEpoch and epoch == 0).
        spyAudio.injectBackendState(
          PlaybackState(
            status: PlaybackStatus.playing,
            track: trackOld,
            position: const Duration(seconds: 12),
            playbackEpoch: curEpoch - 1,
          ),
        );
        spyAudio.injectBackendState(
          PlaybackState(
            status: PlaybackStatus.playing,
            track: trackOld,
            position: const Duration(seconds: 13),
            playbackEpoch: 0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(emittedIds, isNot(contains(trackOld.id)));
        expect(coord.currentState.track?.id, trackNew.id);

        await pendingPlay;
        expect(coord.currentState.track?.id, trackNew.id);
        expect(coord.currentState.status, PlaybackStatus.playing);

        // Verify coordinator.stop() + playTrack() has zero epoch drift and never silently drops play.
        await coord.stop();
        expect(spyAudio.currentState.playbackEpoch, coord.currentEpoch);
        final playCallsBefore = spyAudio.specPlays.length;
        await coord.playTrack(trackOld, queueContext: <TrackInfo>[trackOld, trackNew]);
        expect(spyAudio.specPlays.length, playCallsBefore + 1);
        expect(coord.currentState.track?.id, trackOld.id);
        expect(coord.currentState.status, PlaybackStatus.playing);

        // Even if the underlying AudioService advances its epoch ahead of the coordinator
        // (e.g. direct FfiAudioService.stop() / ServerAudioService.stop()), coordinator._nextEpoch()
        // catches up monotonically so the next playTrack() still commits.
        final jumpedEpoch = coord.currentEpoch + 3;
        await spyAudio.cancelPendingPlaybackAtEpoch(jumpedEpoch);
        await spyAudio.stop();
        expect(spyAudio.currentState.playbackEpoch, jumpedEpoch);
        final playCallsBeforeDirect = spyAudio.specPlays.length;
        await coord.playTrack(trackNew, queueContext: <TrackInfo>[trackOld, trackNew]);
        expect(spyAudio.specPlays.length, playCallsBeforeDirect + 1);
        expect(coord.currentEpoch, jumpedEpoch + 1);
        expect(spyAudio.currentState.playbackEpoch, jumpedEpoch + 1);
        expect(coord.currentState.track?.id, trackNew.id);
        expect(coord.currentState.status, PlaybackStatus.playing);

        // Verify ServerAudioService.stop() after cancelPendingPlaybackAtEpoch does NOT double-increment,
        // while direct stop() increments monotonically by 1.
        await remote.cancelPendingPlaybackAtEpoch(15);
        await remote.stop();
        expect(remote.currentState.playbackEpoch, 15);
        await remote.stop();
        expect(remote.currentState.playbackEpoch, 16);
      },
    );

    test(
      'HttpPotProvider and YtmResidentResolver abort sockets cleanly on cancellation',
      () async {
        var potRequestsSeen = 0;
        var ytmRequestsSeen = 0;
        final potArrived = Completer<void>();
        final ytmArrived = Completer<void>();
        final hangForever = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sub = server.listen((req) async {
          if (req.uri.path == '/get_pot') {
            potRequestsSeen++;
            if (!potArrived.isCompleted) potArrived.complete();
          } else {
            ytmRequestsSeen++;
            if (!ytmArrived.isCompleted) ytmArrived.complete();
          }
          // Flush headers and stall body to verify client-side abort on cancel.
          req.response.statusCode = 200;
          req.response.bufferOutput = false;
          req.response.write('{"partial":');
          await req.response.flush();
          await hangForever.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () {},
          );
          try {
            await req.response.close();
          } catch (_) {}
        });
        addTearDown(() async {
          if (!hangForever.isCompleted) hangForever.complete();
          await sub.cancel();
          await server.close(force: true);
        });

        final directClient1 = _DirectHttpOverrides().createHttpClient(null);
        final directClient2 = _DirectHttpOverrides().createHttpClient(null);
        final baseUrl = 'http://127.0.0.1:${server.port}';
        final pot = HttpPotProvider(
          endpointUri: Uri.parse(baseUrl),
          httpClient: directClient1,
          requestTimeout: const Duration(seconds: 10),
        );
        final resolver = YtmResidentResolver(
          httpClient: directClient2,
          webBaseUrl: baseUrl,
          musicBaseUrl: baseUrl,
          requestTimeout: const Duration(seconds: 10),
        );
        addTearDown(() async {
          await pot.dispose();
          await resolver.disposeAsync();
          directClient1.close(force: true);
          directClient2.close(force: true);
        });

        // 1. Cancel HttpPotProvider.getPlayerToken mid-flight -> returns null fast (<400ms)
        final potCancel = CancellationToken();
        final potFuture = pot.getPlayerToken(
          videoId: 'dQw4w9WgXcQ',
          cancelToken: potCancel,
        );
        await potArrived.future.timeout(const Duration(seconds: 2));
        final potSw = Stopwatch()..start();
        potCancel.cancel();
        final token = await potFuture;
        potSw.stop();
        expect(token, isNull);
        expect(potRequestsSeen, 1);
        expect(potSw.elapsedMilliseconds, lessThan(400));

        // 2. Cancel YtmResidentResolver.resolve mid-response -> throws cancelled fast (<400ms)
        final ytmCancel = CancellationToken();
        final ytmFuture = resolver.resolve(
          const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
          cancelToken: ytmCancel,
        );
        await ytmArrived.future.timeout(const Duration(seconds: 2));
        final ytmSw = Stopwatch()..start();
        ytmCancel.cancel();
        await expectLater(
          ytmFuture,
          throwsA(
            isA<StreamingException>().having(
              (e) => e.isCancelled,
              'isCancelled',
              isTrue,
            ),
          ),
        );
        ytmSw.stop();
        expect(ytmRequestsSeen, greaterThanOrEqualTo(1));
        expect(ytmSw.elapsedMilliseconds, lessThan(400));
      },
    );

    testWidgets(
      'UI FloatingCapsuleMiniPlayer btn_next / btn_previous never lock across 30 rapid taps and update displayed title optimistically',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        var now = DateTime.utc(2026, 11, 25, 14, 0, 0);
        final innerAudio = _SpySkipAudioService();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final ytmRes = _TrackingResolver(
          providerId: 'youtube_music',
          capabilities: ProviderCapabilities.youtubeMusic,
          resolveDelay: Duration.zero,
          specBuilder: (key) => DirectRangeSpec(
            key: key,
            url: 'https://ytm.example/${key.trackId}.m4a',
          ),
        );
        final tidalRes = _TrackingResolver(
          providerId: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          resolveDelay: Duration.zero,
          specBuilder: (key) => DirectRangeSpec(
            key: key,
            url: 'https://tidal.example/${key.trackId}.flac',
          ),
        );
        final autoplay = AutoplayController(
          providerLookup: (_) => null,
          allowBackgroundRefill: false,
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: innerAudio,
          streamingManager: manager,
          autoplayController: autoplay,
          resolverRegistry: _buildMixedRegistry(ytm: ytmRes, tidal: tidalRes),
          debounceDelay: const Duration(milliseconds: 130),
          rapidSkipWindow: const Duration(milliseconds: 300),
          lookaheadDelay: const Duration(seconds: 60),
          clock: () => now,
        );
        final coordinatingAudio = CoordinatingAudioService(
          inner: innerAudio,
          coordinator: coordinator,
        );
        addTearDown(() {
          coordinatingAudio.dispose();
          coordinator.dispose();
          autoplay.dispose();
          manager.dispose();
          innerAudio.dispose();
        });

        final queue = _buildMixedQueue(35);
        await coordinator.playTrack(queue[0], queueContext: queue);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: FloatingCapsuleMiniPlayer(
                  audioService: coordinatingAudio,
                  showLyrics: false,
                  onToggleLyrics: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text(queue[0].title), findsOneWidget);

        // Prime rapid skip window with 1 spaced tap, then 29 rapid taps (30 total).
        innerAudio.specPlays.clear();
        ytmRes.resolvedKeys.clear();
        tidalRes.resolvedKeys.clear();

        final nextBtn = find.byKey(const Key('btn_next'));
        final prevBtn = find.byKey(const Key('btn_previous'));
        expect(nextBtn, findsOneWidget);
        expect(prevBtn, findsOneWidget);

        // 25 next + 5 prev = index 20 (local lossless)
        for (var i = 0; i < 30; i++) {
          now = now.add(const Duration(milliseconds: 80));
          await tester.tap(i < 25 ? nextBtn : prevBtn);
          await tester.pump();
        }

        // UI optimistically displays final track #20 immediately!
        expect(find.text(queue[20].title), findsOneWidget);

        // Advance fake async clock past adaptive 130ms debounce to settle.
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pump();

        expect(coordinatingAudio.currentState.track?.id, queue[20].id);
        expect(coordinatingAudio.currentState.status, PlaybackStatus.playing);
        // At most the first spaced click + final settled track played;
        // intermediate 28 rapid taps produced ZERO plays!
        expect(innerAudio.specPlays.length, lessThanOrEqualTo(2));
        expect(innerAudio.specPlays.last.track.id, queue[20].id);
        expect(innerAudio.specPlays.last.debounced, isTrue);
      },
    );
  });
}
