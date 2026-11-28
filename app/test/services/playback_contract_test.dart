import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/protocol/json_reader.dart';
import 'package:lumina_app/models/protocol/lumina_error.dart';
import 'package:lumina_app/models/protocol/protocol_models.dart';
import 'package:lumina_app/models/protocol/result.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback/ffi_playback_backend.dart';
import 'package:lumina_app/services/playback/mock_playback_backend.dart';
import 'package:lumina_app/services/playback/playback_controller.dart';
import 'package:lumina_app/services/playback/remote_playback_backend.dart';

ProtocolTrackMetadata _sampleTrack(String id, {int durationMs = 180000}) {
  return ProtocolTrackMetadata(
    trackId: id,
    providerId: 'local',
    title: 'Track $id',
    artist: 'Artist $id',
    album: 'Album $id',
    durationMs: durationMs,
    audioQuality: const AudioQualityInfo(
      codec: 'FLAC',
      sampleRateHz: 96000,
      bitDepth: 24,
      channels: 2,
      outputMode: 'WASAPI Exclusive',
      isDsd: false,
      bitPerfect: true,
    ),
  );
}

File _locateGoldenFixture() {
  final candidates = <String>[
    '../crates/core-types/tests/protocol_golden.json',
    'crates/core-types/tests/protocol_golden.json',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  throw StateError(
    'Could not locate protocol_golden.json from cwd=${Directory.current.path}',
  );
}

void main() {
  group('Cross-language Golden JSON Fixture (Rust <-> Dart)', () {
    test('round-trips every canonical type in protocol_golden.json', () {
      final file = _locateGoldenFixture();
      final root = JsonReader.decodeObject(file.readAsStringSync());
      expect(root, isNotNull);
      final reader = JsonReader(root!);

      // 1. AudioDeviceInfo
      final deviceJson = reader.optionalMap('audio_device_info')!;
      final device = ProtocolAudioDeviceInfo.fromJson(deviceJson);
      expect(device.id, 'wasapi-excl::usb-dac-01');
      expect(device.backend, 'windows_wasapi_exclusive');
      expect(device.isActive, isTrue);
      expect(device.supportsDsd, isTrue);
      expect(device.supportedSampleRates, contains(384000));
      expect(ProtocolAudioDeviceInfo.fromJson(device.toJson()), equals(device));

      // 2. ZoneInfo (16 existing + 3 new fields)
      final zoneJson = reader.optionalMap('zone_info')!;
      final zone = ProtocolZoneInfo.fromJson(zoneJson);
      expect(zone.id, 'zone-local');
      expect(zone.clockSyncAddr, '127.0.0.1:49152');
      expect(zone.groupId, 'grp-living-desk');
      expect(zone.clockOffsetUs, -120);
      expect(zone.rttUs, 450);
      expect(zone.driftPpm, 0.25);
      expect(zone.isMuted, isFalse);
      expect(zone.activeDeviceId, 'wasapi-excl::usb-dac-01');
      expect(zone.playbackStatus, PlaybackLifecycleState.playing);
      expect(ProtocolZoneInfo.fromJson(zone.toJson()), equals(zone));

      // 3. LuminaError
      final errJson = reader.optionalMap('lumina_error')!;
      final err = LuminaError.fromJson(errJson);
      expect(err.code, LuminaErrorCode.streamAuthRequired);
      expect(err.retryable, isFalse);
      expect(err.provider, 'qobuz');
      expect(err.httpStatus, 401);
      expect(LuminaError.fromJson(err.toJson()), equals(err));

      // 4. PlaybackState
      final stateJson = reader.optionalMap('playback_state')!;
      final state = ProtocolPlaybackState.fromJson(stateJson);
      expect(state.status, PlaybackLifecycleState.playing);
      expect(state.stateCode, 2);
      expect(state.stateName, 'Playing');
      expect(state.track?.trackId, 'trk-qobuz-9901');
      expect(state.positionMs, 42500);
      expect(state.durationMs, 413000);
      expect(state.timestampMs, 1732610000123);
      expect(state.repeatMode, RepeatMode.all);
      expect(state.shuffle, isTrue);
      expect(state.audioQuality?.sampleRateHz, 96000);
      expect(state.activeDevice?.id, 'wasapi-excl::usb-dac-01');
      expect(state.activeZoneId, 'zone-local');
      expect(ProtocolPlaybackState.fromJson(state.toJson()), equals(state));

      // 5. QueueState
      final queueJson = reader.optionalMap('queue_state')!;
      final queue = QueueState.fromJson(queueJson);
      expect(queue.items.length, 2);
      expect(queue.currentIndex, 0);
      expect(queue.items[1].track.audioQuality?.isDsd, isTrue);
      expect(queue.items[1].track.audioQuality?.dsdRate, 'DSD64');
      expect(QueueState.fromJson(queue.toJson()), equals(queue));

      // 6. All 19 PlaybackCommand variants
      final cmdsRaw = reader.optionalList('playback_commands')!;
      expect(cmdsRaw.length, 19);
      for (final raw in cmdsRaw) {
        final map = JsonReader.asMapOrNull(raw)!;
        final cmd = PlaybackCommand.fromJson(map);
        final roundTripped = PlaybackCommand.fromJson(cmd.toJson());
        expect(roundTripped, equals(cmd));
      }

      // 7. ProtocolSnapshot
      final snapJson = reader.optionalMap('protocol_snapshot')!;
      final snap = ProtocolSnapshot.fromJson(snapJson);
      expect(snap.sequence, 42);
      expect(snap.signalPath?.overall, SignalQuality.lossless);
      expect(snap.signalPath?.nodes.length, 2);
      expect(snap.devices.length, 1);
      expect(snap.zones.length, 1);
      expect(ProtocolSnapshot.fromJson(snap.toJson()), equals(snap));

      // 8. All 7 WsServerEvent variants
      final eventsRaw = reader.optionalList('ws_server_events')!;
      expect(eventsRaw.length, 7);
      final parsedTypes = <String>[];
      for (final raw in eventsRaw) {
        final map = JsonReader.asMapOrNull(raw)!;
        final ev = WsServerEvent.tryFromJson(map);
        expect(ev, isNotNull);
        parsedTypes.add(ev!.eventType);
        expect(WsServerEvent.tryFromJson(ev.toJson()), equals(ev));
      }
      expect(
        parsedTypes,
        equals(<String>[
          'Snapshot',
          'PlaybackStateChanged',
          'QueueStateChanged',
          'SignalPathUpdated',
          'DevicesChanged',
          'ZonesChanged',
          'Error',
        ]),
      );
    });
  });

  group('Result<T, E> & LuminaError', () {
    test('Ok and Err helpers behave cleanly', () {
      const Result<int, LuminaError> ok = Ok<int, LuminaError>(42);
      const errObj = LuminaError(
        code: LuminaErrorCode.deviceLost,
        message: 'USB DAC unplugged',
        retryable: true,
      );
      const Result<int, LuminaError> err = Err<int, LuminaError>(errObj);

      expect(ok.isOk, isTrue);
      expect(ok.valueOrNull, 42);
      expect(ok.errorOrNull, isNull);
      expect(ok.when(ok: (v) => v + 1, err: (_) => -1), 43);

      expect(err.isErr, isTrue);
      expect(err.valueOrNull, isNull);
      expect(err.errorOrNull, errObj);
      expect(err.when(ok: (_) => 'ok', err: (e) => e.code.wireName), 'device_lost');
    });
  });

  group('MockPlaybackBackend Contract', () {
    test('supports full queue nav, repeat/shuffle, seek, volume, device/zone, errors', () async {
      final backend = MockPlaybackBackend();
      addTearDown(backend.dispose);

      expect((await backend.connect()).isOk, isTrue);

      final t1 = _sampleTrack('t1', durationMs: 200000);
      final t2 = _sampleTrack('t2', durationMs: 210000);
      final t3 = _sampleTrack('t3', durationMs: 220000);

      expect((await backend.loadQueue(<ProtocolTrackMetadata>[t1, t2])).isOk, isTrue);
      expect(backend.currentQueue.items.length, 2);
      expect(backend.currentState.track?.trackId, 't1');
      expect(backend.currentState.status, PlaybackLifecycleState.playing);

      expect((await backend.enqueue(<ProtocolTrackMetadata>[t3], playNext: true)).isOk, isTrue);
      expect(
        backend.currentQueue.items.map((e) => e.track.trackId).toList(),
        equals(<String>['t1', 't3', 't2']),
      );

      expect((await backend.next()).isOk, isTrue);
      expect(backend.currentState.track?.trackId, 't3');

      expect((await backend.setRepeatMode(RepeatMode.one)).isOk, isTrue);
      expect((await backend.next()).isOk, isTrue);
      expect(backend.currentState.track?.trackId, 't3');

      expect((await backend.setRepeatMode(RepeatMode.off)).isOk, isTrue);
      expect((await backend.setShuffle(true)).isOk, isTrue);
      expect(backend.currentState.shuffle, isTrue);

      expect((await backend.seek(const Duration(seconds: 45))).isOk, isTrue);
      expect(backend.currentState.positionMs, 45000);

      expect((await backend.setVolume(0.42)).isOk, isTrue);
      expect(backend.currentState.volume, closeTo(0.42, 0.001));
      expect((await backend.setMute(true)).isOk, isTrue);
      expect(backend.currentState.isMuted, isTrue);

      // Invalid device returns structured LuminaError
      final badDev = await backend.setOutputDevice('nonexistent-dac');
      expect(badDev.isErr, isTrue);
      expect(badDev.errorOrNull?.code, LuminaErrorCode.deviceNotFound);

      // Injectable error
      backend.nextError = const LuminaError(
        code: LuminaErrorCode.exclusiveModeConflict,
        message: 'Busy',
        retryable: true,
      );
      final injectedRes = await backend.pause();
      expect(injectedRes.isErr, isTrue);
      expect(injectedRes.errorOrNull?.code, LuminaErrorCode.exclusiveModeConflict);
    });
  });

  group('FfiPlaybackBackend Contract', () {
    test('dispatches canonical commands and maps native LuminaError JSON cleanly', () async {
      final dispatched = <String>[];
      var failNext = false;
      final snapPayload = ProtocolSnapshot(
        playback: ProtocolPlaybackState(
          status: PlaybackLifecycleState.playing,
          track: _sampleTrack('ffi-1'),
          positionMs: 12000,
          durationMs: 180000,
          timestampMs: 1700000000000,
          volume: 0.9,
        ),
        queue: QueueState(
          items: <QueueItem>[
            QueueItem(itemId: 'q1', track: _sampleTrack('ffi-1')),
          ],
          currentIndex: 0,
          repeatMode: RepeatMode.all,
          shuffle: false,
          queueEpoch: 3,
          timestampMs: 1700000000000,
        ),
        serverTimeMs: 1700000000000,
        sequence: 9,
      );

      final backend = FfiPlaybackBackend(
        nativeBridge: NativeProtocolBridge(
          isNativeBound: () => true,
          dispatchCommandJson: (cmdJson) {
            dispatched.add(cmdJson);
            return failNext ? -5 : 0;
          },
          getSnapshotJson: () => jsonEncode(snapPayload.toJson()),
          getQueueStateJson: () => jsonEncode(snapPayload.queue.toJson()),
          getLastErrorJson: () => jsonEncode(
            const LuminaError(
              code: LuminaErrorCode.deviceOpenFailed,
              message: 'WASAPI failed',
              retryable: true,
            ).toJson(),
          ),
        ),
      );
      addTearDown(backend.dispose);

      expect((await backend.connect()).isOk, isTrue);
      expect(backend.currentState.track?.trackId, 'ffi-1');
      expect(backend.currentQueue.repeatMode, RepeatMode.all);

      expect((await backend.pause()).isOk, isTrue);
      expect(dispatched.single, contains('"command":"pause"'));

      failNext = true;
      final errRes = await backend.resume();
      expect(errRes.isErr, isTrue);
      expect(errRes.errorOrNull?.code, LuminaErrorCode.deviceOpenFailed);
    });

    test('falls back gracefully when native library is unavailable (headless)', () async {
      final mockService = MockAudioService();
      addTearDown(mockService.dispose);

      final backend = FfiPlaybackBackend(audioService: mockService);
      addTearDown(backend.dispose);

      expect((await backend.connect()).isOk, isTrue);
      expect((await backend.setRepeatMode(RepeatMode.all)).isOk, isTrue);
      expect((await backend.setShuffle(true)).isOk, isTrue);
      expect(mockService.repeatMode, RepeatMode.all);
      expect(mockService.shuffle, isTrue);
    });
  });

  group('PlaybackController Interpolation, Debounce & Serialization', () {
    test('local progress interpolation advances smoothly, clamps, and re-anchors on seek/pause', () async {
      var fakeClockMs = 1000000;
      final backend = MockPlaybackBackend(nowMs: () => fakeClockMs);
      final controller = PlaybackController(
        backend: backend,
        nowMs: () => fakeClockMs,
        enableAutoTicker: false,
        seekDebounce: Duration.zero,
        volumeDebounce: Duration.zero,
        trackSwitchDebounce: Duration.zero,
      );
      addTearDown(() async {
        await controller.dispose();
        await backend.dispose();
      });

      final track = _sampleTrack('interp-1', durationMs: 10000);
      await controller.play(track, startPositionMs: 2000);
      expect(controller.currentPosition, const Duration(milliseconds: 2000));

      // Advance local clock by 3.5 seconds while playing
      fakeClockMs += 3500;
      expect(
        controller.tickInterpolation(),
        const Duration(milliseconds: 5500),
      );

      // Advance past duration -> clamped to 10000ms
      fakeClockMs += 20000;
      expect(
        controller.tickInterpolation(),
        const Duration(milliseconds: 10000),
      );

      // Seek re-anchors immediately to 4000ms
      await controller.seek(const Duration(milliseconds: 4000));
      expect(controller.currentPosition, const Duration(milliseconds: 4000));

      // Pause freezes interpolation even if clock advances
      await controller.pause();
      fakeClockMs += 5000;
      expect(
        controller.tickInterpolation(),
        const Duration(milliseconds: 4000),
      );
    });

    test('coalesces rapid seek/volume/play bursts and preserves FIFO ordering with barrier commands', () async {
      final backend = MockPlaybackBackend(
        commandLatency: const Duration(milliseconds: 5),
      );
      final controller = PlaybackController(
        backend: backend,
        enableAutoTicker: false,
        seekDebounce: const Duration(milliseconds: 25),
        volumeDebounce: const Duration(milliseconds: 25),
        trackSwitchDebounce: const Duration(milliseconds: 25),
      );
      addTearDown(() async {
        await controller.dispose();
        await backend.dispose();
      });

      final t1 = _sampleTrack('burst-1');
      final t2 = _sampleTrack('burst-2');
      final t3 = _sampleTrack('burst-3');

      // Fire 3 rapid plays, 5 rapid seeks, and 4 rapid volume drags
      final futures = <Future<Result<void, LuminaError>>>[
        controller.play(t1),
        controller.play(t2),
        controller.play(t3),
        controller.seek(const Duration(seconds: 10)),
        controller.seek(const Duration(seconds: 20)),
        controller.seek(const Duration(seconds: 30)),
        controller.seek(const Duration(seconds: 40)),
        controller.seek(const Duration(seconds: 55)),
        controller.setVolume(0.2),
        controller.setVolume(0.4),
        controller.setVolume(0.6),
        controller.setVolume(0.77),
      ];

      final results = await Future.wait(futures);
      expect(results.every((r) => r.isOk), isTrue);

      // Only the final coalesced value of each burst should have hit the backend!
      final playCmds = backend.commandHistory.whereType<PlayCommand>().toList();
      final seekCmds = backend.commandHistory.whereType<SeekCommand>().toList();
      final volCmds =
          backend.commandHistory.whereType<SetVolumeCommand>().toList();
      expect(playCmds.length, 1);
      expect(playCmds.single.track.trackId, 'burst-3');
      expect(seekCmds.length, 1);
      expect(seekCmds.single.positionMs, 55000);
      expect(volCmds.length, 1);
      expect(volCmds.single.volume, closeTo(0.77, 0.001));

      // Now fire a debounced seek followed immediately by a barrier Pause ->
      // Pause must flush seek first and end in paused state at 70000ms.
      final fSeek = controller.seek(const Duration(seconds: 70));
      final fPause = controller.pause();
      await Future.wait(<Future<Result<void, LuminaError>>>[fSeek, fPause]);

      expect(backend.currentState.status, PlaybackLifecycleState.paused);
      expect(backend.currentState.positionMs, 70000);
      expect(backend.commandHistory.last, isA<PauseCommand>());
    });
  });

  group('RemotePlaybackBackend Loopback WS Reconnect & Atomic Snapshot Resync', () {
    test('reconnects with exponential backoff and resets state atomically via GET /api/v1/snapshot', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final connectedSockets = <WebSocket>[];
      var snapshotCalls = 0;
      var currentTrackId = 'remote-initial';
      var currentPositionMs = 15000;
      var currentSequence = 1;
      final receivedCommands = <Map<String, Object?>>[];

      server.listen((HttpRequest req) async {
        if (req.uri.path == '/api/v1/ws') {
          final ws = await WebSocketTransformer.upgrade(req);
          connectedSockets.add(ws);
          ws.listen((_) {}, onError: (_) {}, onDone: () {});
          return;
        }
        if (req.uri.path == '/api/v1/snapshot' && req.method == 'GET') {
          snapshotCalls += 1;
          final snap = ProtocolSnapshot(
            playback: ProtocolPlaybackState(
              status: PlaybackLifecycleState.playing,
              track: _sampleTrack(currentTrackId, durationMs: 240000),
              positionMs: currentPositionMs,
              durationMs: 240000,
              timestampMs: DateTime.now().millisecondsSinceEpoch,
              volume: 0.8,
              repeatMode: RepeatMode.all,
              shuffle: true,
            ),
            queue: QueueState(
              items: <QueueItem>[
                QueueItem(
                  itemId: 'rem-1',
                  track: _sampleTrack(currentTrackId, durationMs: 240000),
                ),
              ],
              currentIndex: 0,
              repeatMode: RepeatMode.all,
              shuffle: true,
              queueEpoch: snapshotCalls,
              timestampMs: DateTime.now().millisecondsSinceEpoch,
            ),
            serverTimeMs: DateTime.now().millisecondsSinceEpoch,
            sequence: currentSequence++,
          );
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(snap.toJson()));
          await req.response.close();
          return;
        }
        if (req.uri.path == '/api/v1/playback/command' && req.method == 'POST') {
          final bodyText = await utf8.decoder.bind(req).join();
          final bodyMap = JsonReader.decodeObject(bodyText)!;
          receivedCommands.add(bodyMap);
          if (bodyMap['command'] == 'set_output_device' &&
              bodyMap['device_id'] == 'missing') {
            req.response
              ..statusCode = HttpStatus.notFound
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode(
                  const LuminaError(
                    code: LuminaErrorCode.deviceNotFound,
                    message: 'Unknown remote device',
                    retryable: false,
                    httpStatus: 404,
                  ).toJson(),
                ),
              );
            await req.response.close();
            return;
          }
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(const <String, Object?>{'status': 'ok'}));
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final backend = RemotePlaybackBackend(
        baseUrl: 'http://127.0.0.1:${server.port}',
        bearerToken: 'test-token',
        baseRetryDelay: const Duration(milliseconds: 25),
        maxRetryDelay: const Duration(milliseconds: 200),
        jitterRatio: 0.0,
        random: math.Random(1),
      );
      addTearDown(backend.dispose);

      final phases = <ConnectionPhase>[];
      final sub = backend.connectionStatusStream.listen((s) => phases.add(s.phase));
      addTearDown(sub.cancel);

      // 1. Initial connect fetches snapshot #1
      final connectRes = await backend.connect();
      expect(connectRes.isOk, isTrue);
      expect(snapshotCalls, 1);
      expect(backend.currentState.track?.trackId, 'remote-initial');
      expect(backend.currentState.positionMs, 15000);
      expect(backend.currentConnectionStatus.phase, ConnectionPhase.connected);

      // 2. Dispatch canonical command + verify structured error mapping
      expect((await backend.setVolume(0.65)).isOk, isTrue);
      expect(receivedCommands.last['command'], 'set_volume');

      final badCmd = await backend.setOutputDevice('missing');
      expect(badCmd.isErr, isTrue);
      expect(badCmd.errorOrNull?.code, LuminaErrorCode.deviceNotFound);

      // 3. Simulate server changing state while WS disconnects abruptly
      currentTrackId = 'remote-after-reconnect';
      currentPositionMs = 92000;

      final reconnected = Completer<void>();
      late StreamSubscription<ConnectionStatus> waitSub;
      var sawReconnecting = false;
      waitSub = backend.connectionStatusStream.listen((status) {
        if (status.phase == ConnectionPhase.reconnecting) {
          sawReconnecting = true;
        }
        if (sawReconnecting &&
            status.phase == ConnectionPhase.connected &&
            !reconnected.isCompleted) {
          reconnected.complete();
        }
      });
      addTearDown(waitSub.cancel);

      // Drop server-side socket
      await connectedSockets.first.close();

      await reconnected.future.timeout(const Duration(seconds: 3));

      expect(sawReconnecting, isTrue);
      expect(backend.recordedReconnectDelays, isNotEmpty);
      expect(backend.recordedReconnectDelays.first, const Duration(milliseconds: 25));
      expect(snapshotCalls, greaterThanOrEqualTo(2));
      expect(backend.currentState.track?.trackId, 'remote-after-reconnect');
      expect(backend.currentState.positionMs, 92000);
      expect(phases, contains(ConnectionPhase.reconnecting));
      expect(phases.last, ConnectionPhase.connected);
    });
  });
}
