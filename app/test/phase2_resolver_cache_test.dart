import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/streaming/l1_stream_cache.dart';
import 'package:lumina_app/services/streaming/pot_provider.dart';
import 'package:lumina_app/services/streaming/pot_sidecar_manager.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/single_flight_resolver.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/ytm_resident_resolver.dart';

class _TrackingSink implements IOSink {
  bool closed = false;
  final Completer<void> _done = Completer<void>();

  @override
  Encoding encoding = utf8;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      if (!_done.isCompleted) _done.complete();
    }
  }

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {}
}

class _FakeSidecarProcess implements Process {
  @override
  final int pid;
  final Completer<int> exitCompleter = Completer<int>();
  final _TrackingSink stdinSink = _TrackingSink();
  final StreamController<List<int>> _stdoutCtrl =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _stderrCtrl =
      StreamController<List<int>>.broadcast();
  bool killed = false;

  _FakeSidecarProcess(this.pid);

  @override
  Future<int> get exitCode => exitCompleter.future;

  @override
  IOSink get stdin => stdinSink;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  void crash([int code = 1]) {
    if (!exitCompleter.isCompleted) {
      exitCompleter.complete(code);
    }
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exitCompleter.isCompleted) {
      exitCompleter.complete(0);
    }
    return true;
  }
}

class _RecordingLifecycleBinder implements SidecarLifecycleBinder {
  final List<int> boundPids = <int>[];

  @override
  bool bindChildProcess(int pid) {
    boundPids.add(pid);
    return true;
  }
}

class _FakePotProvider implements PotProvider {
  int gvsCalls = 0;
  int playerCalls = 0;
  int invalidations = 0;
  bool disposed = false;
  final List<String> seenGvsBindings = <String>[];
  PoToken? gvsToken;
  PoToken? Function(String videoId)? playerTokenFactory;

  @override
  Future<PoToken?> getGvsToken({
    required String sessionBinding,
    CancellationToken? cancelToken,
  }) async {
    gvsCalls++;
    seenGvsBindings.add(sessionBinding);
    return gvsToken;
  }

  @override
  Future<PoToken?> getPlayerToken({
    required String videoId,
    CancellationToken? cancelToken,
  }) async {
    playerCalls++;
    return playerTokenFactory?.call(videoId);
  }

  @override
  void invalidateSession() {
    invalidations++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _ControllableStreamResolver implements StreamResolver {
  @override
  final String providerId;
  @override
  final ProviderCapabilities capabilities;
  final Future<StreamSourceSpec> Function(
    StreamKey key,
    CancellationToken? cancelToken,
  ) onResolve;

  int resolveCalls = 0;
  final List<CancellationToken?> seenTokens = <CancellationToken?>[];

  _ControllableStreamResolver({
    required this.providerId,
    required this.capabilities,
    required this.onResolve,
  });

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) {
    resolveCalls++;
    seenTokens.add(cancelToken);
    return onResolve(key, cancelToken);
  }
}

class _ParallelRestoreProvider extends BaseStreamingProvider
    implements StreamResolver {
  @override
  final String kind;
  @override
  final ProviderCapabilities capabilities;
  final Future<void> Function() onRestore;
  final Future<StreamSourceSpec> Function(
    StreamKey key,
    CancellationToken? cancelToken,
  )? onResolve;
  final bool _guestMode;

  _ParallelRestoreProvider({
    required this.kind,
    required this.capabilities,
    required super.credentialStore,
    required this.onRestore,
    this.onResolve,
    bool guestMode = true,
    // ignore: prefer_initializing_formals
  }) : _guestMode = guestMode;

  @override
  String get providerId => kind;

  @override
  bool get supportsGuestMode => _guestMode;

  @override
  Future<void> restoreFromStorage() async {
    await onRestore();
    setConnected(
      StreamingAccountInfo(displayName: '$kind-user', userId: 'u-$kind'),
    );
  }

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    setConnected(
      StreamingAccountInfo(displayName: '$kind-user', userId: 'u-$kind'),
    );
  }

  @override
  Future<void> logout() async {
    resetState();
  }

  @override
  Future<void> refreshSessionIfNeeded() async {}

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async =>
      StreamingCatalog(syncedAt: DateTime.now());

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      const <TrackInfo>[];

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async => StreamingCatalog(syncedAt: DateTime.now());

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    return ResolvedStreamResult(
      url: 'https://cdn.example.com/$kind/${track.id}.flac',
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
    );
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    final handler = onResolve;
    if (handler != null) {
      return handler(key, cancelToken);
    }
    return DirectRangeSpec(
      key: key,
      url: 'https://cdn.example.com/${key.providerId}/${key.trackId}.flac',
      expireAt: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600,
    );
  }
}

Map<String, dynamic> _ytmPlayerPayload({
  required String videoId,
  required int expireAt,
  String? extraQuery,
  int initEnd = 740,
  int indexStart = 741,
  int indexEnd = 1984,
}) {
  final suffix = extraQuery == null ? '' : '&$extraQuery';
  return <String, dynamic>{
    'playabilityStatus': <String, dynamic>{'status': 'OK'},
    'responseContext': <String, dynamic>{
      'visitorData': 'CgVisitorFromPlayer12345',
    },
    'streamingData': <String, dynamic>{
      'adaptiveFormats': <Map<String, dynamic>>[
        <String, dynamic>{
          'itag': 251,
          'url':
              'https://rr1---sn.googlevideo.com/videoplayback?id=$videoId&itag=251&expire=$expireAt$suffix',
          'mimeType': 'audio/webm; codecs="opus"',
          'bitrate': 158000,
          'contentLength': '3456789',
          'audioSampleRate': '48000',
          'audioChannels': 2,
          'initRange': <String, String>{'start': '0', 'end': '$initEnd'},
          'indexRange': <String, String>{
            'start': '$indexStart',
            'end': '$indexEnd',
          },
        },
      ],
    },
  };
}

void main() {
  group('Phase 2.1: YtmResidentResolver warmup SharedFuture & InnerTube ranges', () {
    test(
      'concurrent warmup() and cold-start resolve() share one SharedFuture without duplicate init',
      () async {
        final warmupGate = Completer<void>();
        var gen204Hits = 0;
        var swJsHits = 0;
        var h2WarmupHits = 0;
        var playerHits = 0;
        final fixedNow = DateTime.utc(2026, 11, 23, 12, 0, 0);
        final expireAt = (fixedNow.millisecondsSinceEpoch ~/ 1000) + 21600;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          if (req.uri.path == '/generate_204') {
            gen204Hits++;
            await warmupGate.future;
            req.response.statusCode = 204;
            await req.response.close();
          } else if (req.uri.path == '/sw.js_data') {
            swJsHits++;
            await warmupGate.future;
            req.response.statusCode = 200;
            req.response.write(
              ")]}'\n${jsonEncode(<String, dynamic>{'visitorData': 'CgWarmupVisitor99999'})}",
            );
            await req.response.close();
          } else if (req.uri.path == '/youtubei/v1/player') {
            playerHits++;
            req.response.statusCode = 200;
            req.response.write(
              jsonEncode(
                _ytmPlayerPayload(
                  videoId: 'dQw4w9WgXcQ',
                  expireAt: expireAt,
                  initEnd: 740,
                  indexStart: 741,
                  indexEnd: 1984,
                ),
              ),
            );
            await req.response.close();
          } else {
            req.response.statusCode = 404;
            await req.response.close();
          }
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final fakePot = _FakePotProvider()
          ..gvsToken = PoToken(
            token: 'GVS_SESSION_TOK_123',
            scope: PoTokenScope.gvs,
            bindingKey: 'CgWarmupVisitor99999',
            mintedAt: fixedNow,
            expiresAt: fixedNow.add(const Duration(hours: 6)),
          );

        final resolver = YtmResidentResolver(
          webBaseUrl: baseUrl,
          musicBaseUrl: baseUrl,
          potProvider: fakePot,
          onHttp2Warmup: () => h2WarmupHits++,
          clock: () => fixedNow,
        );
        addTearDown(resolver.dispose);

        // Kick off two concurrent warmup() calls plus a cold-start resolve().
        final w1 = resolver.warmup();
        final w2 = resolver.warmup();
        final cancelEarly = CancellationToken();
        final cancelledResolve = resolver.resolve(
          const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
          cancelToken: cancelEarly,
        );
        final activeResolve = resolver.resolve(
          const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
        );

        // Cancelling the first early waiter must NOT abort the shared warmup.
        cancelEarly.cancel();
        await expectLater(
          cancelledResolve,
          throwsA(
            isA<StreamingException>().having((e) => e.isCancelled, 'isCancelled', true),
          ),
        );

        // Release warmup responses.
        warmupGate.complete();
        await Future.wait(<Future<void>>[w1, w2]);

        final spec = await activeResolve;
        expect(resolver.isWarmedUp, isTrue);
        expect(resolver.warmupExecutionCount, equals(1));
        expect(gen204Hits, equals(1));
        expect(swJsHits, equals(1));
        expect(h2WarmupHits, equals(1));
        expect(playerHits, equals(1));
        // Warmup captured visitorData from /sw.js_data and bound GVS token to it,
        // then /player updated cachedVisitorData from responseContext.
        expect(fakePot.seenGvsBindings, contains('CgWarmupVisitor99999'));
        expect(resolver.cachedVisitorData, equals('CgVisitorFromPlayer12345'));
        expect(fakePot.gvsCalls, greaterThanOrEqualTo(1));

        expect(spec, isA<DirectRangeSpec>());
        final direct = spec as DirectRangeSpec;
        expect(direct.initRangeEnd, equals(740));
        expect(direct.indexRangeStart, equals(741));
        expect(direct.indexRangeEnd, equals(1984));
        expect(Uri.parse(direct.url).queryParameters['pot'], equals('GVS_SESSION_TOK_123'));

        // JSON round-trip preserves initRangeEnd / indexRangeStart / indexRangeEnd.
        final roundTripped =
            StreamSourceSpec.fromJson(direct.toJson()) as DirectRangeSpec;
        expect(roundTripped.initRangeEnd, equals(740));
        expect(roundTripped.indexRangeStart, equals(741));
        expect(roundTripped.indexRangeEnd, equals(1984));
      },
    );

    test('transient warmup failure stays retryable on next warmup()', () async {
      var failWarmup = true;
      var swCalls = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        if (req.uri.path == '/generate_204') {
          req.response.statusCode = failWarmup ? 503 : 204;
          await req.response.close();
        } else if (req.uri.path == '/sw.js_data') {
          swCalls++;
          if (failWarmup) {
            req.response.statusCode = 503;
          } else {
            req.response.statusCode = 200;
            req.response.write(
              ")]}'\n${jsonEncode(<String, dynamic>{'visitorData': 'CgRecoveredVisitor1234'})}",
            );
          }
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      final baseUrl = 'http://127.0.0.1:${server.port}';
      final resolver = YtmResidentResolver(
        webBaseUrl: baseUrl,
        musicBaseUrl: baseUrl,
      );
      addTearDown(resolver.dispose);

      await resolver.warmup();
      expect(resolver.isWarmedUp, isFalse);
      expect(swCalls, equals(1));

      failWarmup = false;
      await resolver.warmup();
      expect(resolver.isWarmedUp, isTrue);
      expect(resolver.cachedVisitorData, equals('CgRecoveredVisitor1234'));
      expect(swCalls, equals(2));
    });
  });

  group('Phase 2.1: PotProvider (GVS <15% background refresh + Player token + fallback)', () {
    test('enforces strict 127.0.0.1 endpoint validation', () {
      expect(
        () => HttpPotProvider(endpointUri: Uri.parse('http://0.0.0.0:4416')),
        throwsArgumentError,
      );
      expect(
        () => HttpPotProvider(endpointUri: Uri.parse('http://192.168.1.5:4416')),
        throwsArgumentError,
      );
      expect(
        () => HttpPotProvider(endpointUri: Uri.parse('http://127.0.0.1:4416')),
        returnsNormally,
      );
    });

    test(
      'Session GVS token refreshes in background when remaining lifetime < 15% while returning cached immediately',
      () async {
        var now = DateTime.utc(2026, 11, 23, 10, 0, 0);
        var mintCount = 0;
        final refreshGate = Completer<void>();

        final provider = HttpPotProvider(
          endpointUri: Uri.parse('http://127.0.0.1:4416'),
          clock: () => now,
          requester: ({required uri, required body, required timeout}) async {
            mintCount++;
            if (mintCount == 2) {
              await refreshGate.future;
            }
            return (
              statusCode: 200,
              body: jsonEncode(<String, dynamic>{
                'poToken': 'GVS_V$mintCount',
                'expiresAt': now
                    .add(const Duration(seconds: 1000))
                    .toUtc()
                    .toIso8601String(),
              }),
            );
          },
        );
        addTearDown(provider.dispose);

        // 1. Initial mint at t=0 (TTL = 1000s, expires at t=1000s).
        final t1 = await provider.getGvsToken(sessionBinding: 'session-A');
        expect(t1?.token, equals('GVS_V1'));
        expect(t1?.scope, equals(PoTokenScope.gvs));
        expect(mintCount, equals(1));

        // 2. At t=500s (50% remaining): cached hit, zero refresh.
        now = now.add(const Duration(seconds: 500));
        final t2 = await provider.getGvsToken(sessionBinding: 'session-A');
        expect(t2?.token, equals('GVS_V1'));
        expect(mintCount, equals(1));

        // 3. At t=860s (140s remaining = 14% < 15%): returns GVS_V1 IMMEDIATELY
        // and triggers exactly ONE deduplicated background refresh.
        now = now.add(const Duration(seconds: 360));
        expect(t1!.needsProactiveRefreshAt(now), isTrue);

        final t3a = await provider.getGvsToken(sessionBinding: 'session-A');
        final t3b = await provider.getGvsToken(sessionBinding: 'session-A');
        expect(t3a?.token, equals('GVS_V1'));
        expect(t3b?.token, equals('GVS_V1'));
        expect(mintCount, equals(2));

        // Release background refresh and wait microtask turn.
        refreshGate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final t4 = await provider.getGvsToken(sessionBinding: 'session-A');
        expect(t4?.token, equals('GVS_V2'));
        expect(mintCount, equals(2));

        // 4. Session invalidation forces a new mint on next call.
        provider.invalidateSession();
        final t5 = await provider.getGvsToken(sessionBinding: 'session-B');
        expect(t5?.token, equals('GVS_V3'));
        expect(mintCount, equals(3));
      },
    );

    test(
      'Player token minted dynamically per video_id, injected into WEB_REMIX payload (never deprecated TVHTML5), and degrades gracefully on error',
      () async {
        final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
        final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 21600;
        final requestedPayloads = <Map<String, dynamic>>[];

        final potProvider = HttpPotProvider(
          endpointUri: Uri.parse('http://127.0.0.1:4416'),
          clock: () => now,
          requester: ({required uri, required body, required timeout}) async {
            final contentBinding = body['content_binding']?.toString() ?? '';
            if (contentBinding == 'FAIL_VID_11') {
              return (statusCode: 500, body: 'internal error');
            }
            return (
              statusCode: 200,
              body: jsonEncode(<String, dynamic>{
                'poToken': 'POT_FOR_$contentBinding',
                'expiresIn': 3600,
              }),
            );
          },
        );
        addTearDown(potProvider.dispose);

        final resolver = YtmResidentResolver(
          potProvider: potProvider,
          clock: () => now,
          requestHandler: ({
            required uri,
            required headers,
            required body,
            cancelToken,
          }) async {
            requestedPayloads.add(body);
            final clientName =
                headers['X-YouTube-Client-Name'] ?? headers['X-Youtube-Client-Name'];
            // Fail ANDROID_VR (28) and VISIONOS (101) so resolver advances to
            // Guest WEB_REMIX (67) which supports serviceIntegrityDimensions.poToken.
            if (clientName == '28' || clientName == '101') {
              return const YtmPlayerHttpResponse(
                statusCode: 200,
                body: '{"playabilityStatus":{"status":"UNPLAYABLE"}}',
              );
            }
            final vid = body['videoId']?.toString() ?? 'dQw4w9WgXcQ';
            return YtmPlayerHttpResponse(
              statusCode: 200,
              body: jsonEncode(_ytmPlayerPayload(videoId: vid, expireAt: expireAt)),
            );
          },
        );
        addTearDown(resolver.dispose);

        final spec = await resolver.resolve(
          const StreamKey('youtube_music', 'AbCdEfGhIjK', 'default'),
        );
        expect(spec, isA<DirectRangeSpec>());
        final webPayload = requestedPayloads.last;
        expect(
          ((webPayload['context'] as Map)['client'] as Map)['clientName'],
          equals('WEB_REMIX'),
        );
        expect(
          requestedPayloads.any(
            (p) =>
                ((p['context'] as Map)['client'] as Map)['clientName'] ==
                'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
          ),
          isFalse,
        );
        expect(
          (webPayload['serviceIntegrityDimensions'] as Map?)?['poToken'],
          equals('POT_FOR_AbCdEfGhIjK'),
        );
        // Session GVS token appended as &pot= (guest session before visitorData,
        // then visitorData-bound on subsequent resolves).
        expect(
          Uri.parse((spec as DirectRangeSpec).url).queryParameters['pot'],
          equals('POT_FOR_ytm_guest_session'),
        );

        // Second track resolve binds GVS token to captured visitorData and
        // mints a distinct dynamic per-track Player token.
        final spec2 = await resolver.resolve(
          const StreamKey('youtube_music', 'ZyXwVuTsRqP', 'default'),
        );
        expect(
          (requestedPayloads.last['serviceIntegrityDimensions'] as Map?)?['poToken'],
          equals('POT_FOR_ZyXwVuTsRqP'),
        );
        expect(
          Uri.parse((spec2 as DirectRangeSpec).url).queryParameters['pot'],
          equals('POT_FOR_CgVisitorFromPlayer12345'),
        );

        // Graceful degradation: when PotProvider returns HTTP 500 for a video,
        // resolve() still succeeds cleanly without serviceIntegrityDimensions.
        requestedPayloads.clear();
        final degradedSpec = await resolver.resolve(
          const StreamKey('youtube_music', 'FAIL_VID_11', 'default'),
        );
        expect(degradedSpec, isA<DirectRangeSpec>());
        expect(requestedPayloads.last.containsKey('serviceIntegrityDimensions'), isFalse);
      },
    );
  });

  group('Phase 2.1: PotSidecarManager (127.0.0.1, Job Object / stdin EOF, 1s->3s->10s backoff)', () {
    test('rejects non-127.0.0.1 bindHost strictly', () {
      for (final bad in const <String>['0.0.0.0', 'localhost', '::', '10.0.0.1']) {
        expect(
          () => PotSidecarManager(bindHost: bad),
          throwsArgumentError,
          reason: 'Expected $bad to be rejected',
        );
      }
      expect(PotSidecarManager.defaultBackoffDelays, const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 3),
        Duration(seconds: 10),
      ]);
    });

    test(
      'binds child PID via SidecarLifecycleBinder, holds stdin pipe open for EOF, and executes 1s->3s->10s exponential backoff watchdog',
      () async {
        final spawned = <_FakeSidecarProcess>[];
        final spawnTimes = <DateTime>[];
        final seenArgs = <List<String>>[];
        final binder = _RecordingLifecycleBinder();

        final manager = PotSidecarManager(
          executablePath: '/fake/bgutil-pot',
          fixedPort: 44160,
          backoffDelays: const <Duration>[
            Duration(milliseconds: 20),
            Duration(milliseconds: 60),
            Duration(milliseconds: 120),
          ],
          lifecycleBinder: binder,
          healthChecker: (_) async => true,
          processStarter: (
            exe,
            args, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            mode = ProcessStartMode.normal,
          }) async {
            final proc = _FakeSidecarProcess(5000 + spawned.length);
            spawned.add(proc);
            spawnTimes.add(DateTime.now());
            seenArgs.add(List<String>.from(args));
            return proc;
          },
        );

        final uri = await manager.ensureRunning();
        expect(uri, equals(Uri.parse('http://127.0.0.1:44160')));
        expect(spawned.length, equals(1));
        expect(seenArgs.first, containsAllInOrder(<String>['--host', '127.0.0.1', '--port', '44160']));
        expect(binder.boundPids, equals(<int>[5000]));
        // Anonymous stdin pipe remains open while process is alive (macOS EOF contract).
        expect(spawned.first.stdinSink.closed, isFalse);

        // Simulate 2 unexpected crashes and verify exponential backoff restarts.
        spawned[0].crash(1);
        await Future<void>.delayed(const Duration(milliseconds: 45));
        expect(spawned.length, equals(2));
        expect(binder.boundPids, equals(<int>[5000, 5001]));
        expect(manager.restartCount, equals(1));

        spawned[1].crash(1);
        // Should NOT restart yet before the 60ms second backoff elapses.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(spawned.length, equals(2));
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(spawned.length, equals(3));
        expect(manager.restartCount, equals(2));

        // Explicit dispose closes stdin pipe (EOF) and cancels watchdog cleanly.
        await manager.dispose();
        expect(spawned[2].stdinSink.closed, isTrue);
        expect(spawned[2].killed, isTrue);

        // No further restarts after dispose.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(spawned.length, equals(3));
      },
    );

    test('returns null gracefully when sidecar binary is unavailable', () async {
      final manager = PotSidecarManager(executableResolver: () => null);
      addTearDown(manager.dispose);

      final uri = await manager.ensureRunning();
      expect(uri, isNull);
      expect(manager.isRunning, isFalse);
    });
  });

  group('Phase 2.2: Multi-platform L1StreamCache & Tidal expiry parsing', () {
    test(
      'hydrates unexpired SQLite/persistence entries on startup, subtracts platform safety margins, skips Apple Music/Local, and respects networkEpoch',
      () async {
        var now = DateTime.utc(2026, 11, 23, 12, 0, 0);
        int nowSec() => now.millisecondsSinceEpoch ~/ 1000;
        final persistence = InMemoryL1StreamCachePersistence();

        final cache1 = L1StreamCache(persistence: persistence, clock: () => now);

        final rawExpire = nowSec() + 3600; // +1 hour

        // 1. YTM: safety margin = 1800s (30 min) -> stored expireAt = now + 1800s.
        const ytmKey = StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default');
        final ytmSpec = DirectRangeSpec(
          key: ytmKey,
          url: 'https://rr1.googlevideo.com/videoplayback?itag=251',
          headers: const <String, String>{'User-Agent': 'LuminaTest'},
          contentLength: 3456789,
          bitrateBps: 160000,
          mimeType: 'audio/webm; codecs="opus"',
          hintExtension: 'webm',
          expireAt: rawExpire,
          initRangeEnd: 740,
          indexRangeStart: 741,
          indexRangeEnd: 1984,
        );
        cache1.put(ytmSpec, ProviderCapabilities.youtubeMusic);

        // 2. Tidal DASH: safety margin = 60s -> stored expireAt = now + 3540s.
        const tidalKey = StreamKey('tidal', '998877', 'HI_RES_LOSSLESS');
        final mpdXml = '''
<MPD>
  <AdaptationSet>
    <Representation>
      <SegmentTemplate
        initialization="https://sp-pr-cf.audio.tidal.com/init.mp4?Expires=${nowSec() + 3600}&amp;Signature=abc"
        media="https://sp-pr-cf.audio.tidal.com/seg\$Number\$.m4s?Expires=${nowSec() + 3500}&amp;Signature=def" />
    </Representation>
  </AdaptationSet>
</MPD>''';
        final parsedTidalExpire = TidalProvider.extractDashMpdExpireAt(mpdXml);
        expect(parsedTidalExpire, equals(nowSec() + 3500));

        final tidalSpec = SegmentedManifestSpec(
          key: tidalKey,
          manifestUrlOrXml: mpdXml,
          format: ManifestFormat.dash,
          mimeType: 'audio/flac',
          expireAt: parsedTidalExpire,
        );
        cache1.put(tidalSpec, ProviderCapabilities.tidal);

        // 3. Deezer encrypted: safety margin = 120s.
        const deezerKey = StreamKey('deezer', '445566', 'FLAC');
        final deezerSpec = EncryptedRangeSpec(
          key: deezerKey,
          url: 'https://e-cdns-proxy-a.dzcdn.net/mobile/1/abc',
          mimeType: 'audio/flac',
          hintExtension: 'flac',
          cipher: const DeezerBlowfishCipher(trackId: '445566'),
          expireAt: rawExpire,
        );
        cache1.put(deezerSpec, ProviderCapabilities.deezer);

        // 4. Apple Music & Local (supportsL1UrlCache == false): MUST be skipped.
        const appleKey = StreamKey('apple_music', 'am-1', 'default');
        cache1.put(
          const ExternalBackendSpec(
            key: appleKey,
            providerId: 'apple_music',
            trackUri: 'apple_music:am-1',
          ),
          ProviderCapabilities.appleMusic,
        );
        cache1.put(
          const DirectRangeSpec(
            key: appleKey,
            url: 'https://audio-ssl.itunes.apple.com/preview.m4a',
          ),
          ProviderCapabilities.appleMusic,
        );
        const localKey = StreamKey('local', '/music/test.flac', 'default');
        cache1.put(
          const LocalFileSpec(key: localKey, path: '/music/test.flac'),
          ProviderCapabilities.local,
        );

        await Future<void>.delayed(Duration.zero);
        expect(persistence.debugRows.length, equals(3));
        expect(cache1.get(appleKey, ProviderCapabilities.appleMusic), isNull);
        expect(cache1.get(localKey, ProviderCapabilities.local), isNull);

        // Simulate cold restart: brand new L1StreamCache hydrated from persistence.
        final cache2 = L1StreamCache(persistence: persistence, clock: () => now);
        expect(cache2.length, equals(0));
        await cache2.hydrate();
        expect(cache2.isHydrated, isTrue);
        expect(cache2.length, equals(3));

        final hydratedYtm =
            cache2.get(ytmKey, ProviderCapabilities.youtubeMusic) as DirectRangeSpec?;
        expect(hydratedYtm, isNotNull);
        expect(hydratedYtm!.initRangeEnd, equals(740));
        expect(hydratedYtm.indexRangeStart, equals(741));
        expect(hydratedYtm.indexRangeEnd, equals(1984));
        expect(hydratedYtm.expireAt, equals(rawExpire - 1800));

        final hydratedTidal =
            cache2.get(tidalKey, ProviderCapabilities.tidal) as SegmentedManifestSpec?;
        expect(hydratedTidal, isNotNull);
        expect(hydratedTidal!.manifestUrlOrXml, equals(mpdXml));
        expect(hydratedTidal.expireAt, equals(parsedTidalExpire! - 60));

        final hydratedDeezer =
            cache2.get(deezerKey, ProviderCapabilities.deezer) as EncryptedRangeSpec?;
        expect(hydratedDeezer, isNotNull);
        expect(hydratedDeezer!.cipher, isA<DeezerBlowfishCipher>());
        expect(hydratedDeezer.expireAt, equals(rawExpire - 120));

        // Advance clock past YTM safety-margin-adjusted expiry (now + 1800s):
        // YTM expires, while Deezer (now + 3480s) remains valid.
        now = now.add(const Duration(seconds: 1800));
        expect(cache2.get(ytmKey, ProviderCapabilities.youtubeMusic), isNull);
        expect(cache2.get(deezerKey, ProviderCapabilities.deezer), isNotNull);

        // Bumping network_epoch invalidates ONLY platforms declaring
        // needsNetworkEpochReset == true (e.g. YouTube Music), while
        // non-IP-bound platforms (Deezer/Qobuz/Tidal) survive without wiping DB.
        const freshYtmKey = StreamKey('youtube_music', 'dQw4w9WgXc2', 'default');
        cache2.put(
          DirectRangeSpec(
            key: freshYtmKey,
            url: 'https://rr1---sn-test.googlevideo.com/videoplayback?id=2',
            expireAt: (now.millisecondsSinceEpoch ~/ 1000) + 7200,
          ),
          ProviderCapabilities.youtubeMusic,
        );
        expect(cache2.get(freshYtmKey, ProviderCapabilities.youtubeMusic), isNotNull);

        expect(cache2.bumpNetworkEpoch(), equals(2));
        expect(cache2.get(freshYtmKey, ProviderCapabilities.youtubeMusic), isNull);
        expect(cache2.get(deezerKey, ProviderCapabilities.deezer), isNotNull);
      },
    );
  });

  group('Phase 2.2: SingleFlightResolver detached broadcast & cancellation isolation', () {
    test(
      'deduplicates concurrent playback + prefetch and cancelling prefetch NEVER cancels active playback',
      () async {
        final gate = Completer<void>();
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final resolver = _ControllableStreamResolver(
          providerId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          onResolve: (key, cancelToken) async {
            await gate.future;
            cancelToken?.throwIfCancelled();
            return DirectRangeSpec(
              key: key,
              url: 'https://streaming-qobuz-std.akamaized.net/file/${key.trackId}.flac',
              expireAt: nowSec + 3600,
            );
          },
        );
        final registry = StreamResolverRegistry(includeLocalDefault: false)
          ..register(resolver);
        final cache = L1StreamCache();
        final singleFlight = SingleFlightResolver(
          registry: registry,
          l1Cache: cache,
        );

        const key = StreamKey('qobuz', 'track-42', '27');
        final prefetchCancel = CancellationToken();
        final playbackCancel = CancellationToken();

        final prefetchFuture = singleFlight.prefetch(
          key,
          cancelToken: prefetchCancel,
        );
        final playbackFuture = singleFlight.resolve(
          key,
          cancelToken: playbackCancel,
        );

        // Underlying resolver invoked strictly ONCE for both waiters.
        expect(resolver.resolveCalls, equals(1));
        expect(singleFlight.inFlightCount, equals(1));

        // Cancel prefetch waiter (e.g. user moved mouse off row).
        prefetchCancel.cancel();
        await expectLater(
          prefetchFuture,
          throwsA(
            isA<StreamingException>().having((e) => e.isCancelled, 'isCancelled', true),
          ),
        );

        // Underlying task token MUST still be active for playback waiter!
        expect(resolver.seenTokens.single!.isCancelled, isFalse);
        expect(singleFlight.inFlightCount, equals(1));

        gate.complete();
        final resolved = await playbackFuture;
        expect(resolved, isA<DirectRangeSpec>());
        expect(
          (resolved as DirectRangeSpec).url,
          contains('track-42.flac'),
        );
        expect(singleFlight.inFlightCount, equals(0));

        // L1 cache is now populated -> O(1) hit with zero extra resolver calls.
        final cached = singleFlight.peekCached(key);
        expect(cached, isNotNull);
        final secondRead = await singleFlight.resolve(key);
        expect(secondRead, equals(resolved));
        expect(resolver.resolveCalls, equals(1));
      },
    );

    test('cancelling ALL waiters cancels the underlying detached task', () async {
      final gate = Completer<void>();
      final resolver = _ControllableStreamResolver(
        providerId: 'tidal',
        capabilities: ProviderCapabilities.tidal,
        onResolve: (key, cancelToken) async {
          await gate.future;
          cancelToken?.throwIfCancelled();
          return DirectRangeSpec(key: key, url: 'https://cdn.tidal.com/1.flac');
        },
      );
      final registry = StreamResolverRegistry(includeLocalDefault: false)
        ..register(resolver);
      final singleFlight = SingleFlightResolver(
        registry: registry,
        l1Cache: L1StreamCache(),
      );

      const key = StreamKey('tidal', '100', 'HI_RES_LOSSLESS');
      final c1 = CancellationToken();
      final c2 = CancellationToken();

      final f1 = singleFlight.resolve(key, cancelToken: c1);
      final f2 = singleFlight.resolve(key, cancelToken: c2);
      expect(resolver.resolveCalls, equals(1));

      c1.cancel();
      await expectLater(f1, throwsA(isA<StreamingException>()));
      expect(resolver.seenTokens.single!.isCancelled, isFalse);

      c2.cancel();
      await expectLater(f2, throwsA(isA<StreamingException>()));
      expect(resolver.seenTokens.single!.isCancelled, isTrue);
      expect(singleFlight.inFlightCount, equals(0));
      gate.complete();
    });

    test('prefetch skips Apple Music and Local automatically', () async {
      var appleCalls = 0;
      final appleResolver = _ControllableStreamResolver(
        providerId: 'apple_music',
        capabilities: ProviderCapabilities.appleMusic,
        onResolve: (key, _) async {
          appleCalls++;
          return ExternalBackendSpec(
            key: key,
            providerId: 'apple_music',
            trackUri: 'apple_music:${key.trackId}',
          );
        },
      );
      final registry = StreamResolverRegistry(includeLocalDefault: true)
        ..register(appleResolver);
      final singleFlight = SingleFlightResolver(
        registry: registry,
        l1Cache: L1StreamCache(),
      );

      expect(
        await singleFlight.prefetch(
          const StreamKey('apple_music', 'am-99', 'default'),
        ),
        isNull,
      );
      expect(
        await singleFlight.prefetch(
          const StreamKey('local', '/tmp/a.flac', 'default'),
        ),
        isNull,
      );
      expect(appleCalls, equals(0));
    });
  });

  group('Phase 2.3: StreamingManager warmup, parallel initialize, L1 & Single-Flight', () {
    test(
      'initialize() restores providers in parallel; warmup() hydrates L1 and runs YTM warmup once; resolveSourceSpec/prefetchSourceSpec deduplicate',
      () async {
        final store = MemorySecureCredentialStore();
        final persistence = InMemoryL1StreamCachePersistence();
        final now = DateTime.utc(2026, 11, 23, 14, 0, 0);
        final nowSec = now.millisecondsSinceEpoch ~/ 1000;

        // Pre-populate persistence as if from previous run.
        await persistence.upsert(
          L1StreamCacheRecord(
            providerId: 'qobuz',
            trackId: 'prewarmed-1',
            qualityKey: '27',
            streamType: 'direct_range',
            urlOrManifest: 'https://qobuz.cdn.example/prewarmed-1.flac',
            headersJson: '{}',
            expireAt: nowSec + 1800,
            networkEpoch: 1,
            updatedAt: nowSec - 10,
          ),
        );

        // Barrier proving two providers enter restoreFromStorage() concurrently.
        var inRestoreCount = 0;
        final bothEnteredRestore = Completer<void>();
        Future<void> parallelBarrier() async {
          inRestoreCount++;
          if (inRestoreCount >= 2 && !bothEnteredRestore.isCompleted) {
            bothEnteredRestore.complete();
          }
          await bothEnteredRestore.future.timeout(const Duration(seconds: 2));
        }

        var qobuzResolves = 0;
        final resolveGate = Completer<void>();

        final qobuz = _ParallelRestoreProvider(
          kind: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          credentialStore: store,
          onRestore: parallelBarrier,
          onResolve: (key, cancelToken) async {
            qobuzResolves++;
            await resolveGate.future;
            cancelToken?.throwIfCancelled();
            return DirectRangeSpec(
              key: key,
              url: 'https://qobuz.cdn.example/${key.trackId}.flac',
              expireAt: nowSec + 3600,
            );
          },
        );
        final tidal = _ParallelRestoreProvider(
          kind: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          credentialStore: store,
          onRestore: parallelBarrier,
        );
        final apple = _ParallelRestoreProvider(
          kind: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          credentialStore: store,
          onRestore: () async {},
        );
        final deezer = _ParallelRestoreProvider(
          kind: 'deezer',
          capabilities: ProviderCapabilities.deezer,
          credentialStore: store,
          onRestore: () async {},
        );

        final fakePot = _FakePotProvider();
        var h2WarmupCount = 0;
        var dbReadyWaited = false;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          if (req.uri.path == '/generate_204') {
            req.response.statusCode = 204;
          } else if (req.uri.path == '/sw.js_data') {
            req.response.statusCode = 200;
            req.response.write(
              ")]}'\n${jsonEncode(<String, dynamic>{'visitorData': 'CgManagerWarmup12345'})}",
            );
          } else {
            req.response.statusCode = 404;
          }
          await req.response.close();
        });

        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          baseUrl: 'http://127.0.0.1:${server.port}',
          potProvider: fakePot,
          ownsPotProvider: true,
          clock: () => now,
        );

        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{
            'qobuz': qobuz,
            'tidal': tidal,
            'apple_music': apple,
            'deezer': deezer,
            'youtube_music': ytm,
          },
          l1CachePersistence: persistence,
          waitDbReady: () async {
            dbReadyWaited = true;
          },
          onHttp2Warmup: () => h2WarmupCount++,
          enableLiveWarmup: true,
          clock: () => now,
        );

        // 1. Parallel initialize() completes across barrier without deadlock.
        await manager.initialize();
        expect(manager.isInitialized, isTrue);

        // 2. Concurrent warmup() calls share one SharedFuture.
        await Future.wait(<Future<void>>[manager.warmup(), manager.warmup()]);
        expect(dbReadyWaited, isTrue);
        expect(manager.isWarmedUp, isTrue);
        expect(h2WarmupCount, equals(1));
        expect(ytm.residentResolver.warmupExecutionCount, equals(1));

        // Hydrated L1 entry is immediately available via peekCachedSpec (O(1)).
        const preKey = StreamKey('qobuz', 'prewarmed-1', '27');
        final preHit = manager.peekCachedSpec(preKey);
        expect(preHit, isA<DirectRangeSpec>());
        expect(
          (preHit as DirectRangeSpec).url,
          equals('https://qobuz.cdn.example/prewarmed-1.flac'),
        );

        // 3. Prefetch + playback deduplicate via SingleFlight; cancelling
        // prefetch never cancels playback.
        const liveKey = StreamKey('qobuz', 'live-77', '27');
        final prefetchCancel = CancellationToken();
        final pFut = manager.prefetchSourceSpec(
          liveKey,
          cancelToken: prefetchCancel,
        );
        final rFut = manager.resolveSourceSpec(liveKey);
        expect(qobuzResolves, equals(1));

        prefetchCancel.cancel();
        expect(await pFut, isNull);

        resolveGate.complete();
        final resolved = await rFut;
        expect((resolved as DirectRangeSpec).url, contains('live-77.flac'));
        expect(manager.peekCachedSpec(liveKey), equals(resolved));

        // 4. Apple Music prefetch returns null silently.
        expect(
          await manager.prefetchSourceSpec(
            const StreamKey('apple_music', 'am-1', 'default'),
          ),
          isNull,
        );

        // 5. Logout clears provider's L1 cache entries.
        await manager.logoutProvider('qobuz');
        expect(manager.peekCachedSpec(preKey), isNull);
        expect(manager.peekCachedSpec(liveKey), isNull);

        // 6. Dispose tears down YouTubeMusicProvider + owned PotProvider cleanly.
        manager.dispose();
        expect(fakePot.disposed, isTrue);
      },
    );
  });
}
