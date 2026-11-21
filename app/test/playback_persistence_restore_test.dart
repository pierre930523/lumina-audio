import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';

void _writeSyntheticWav(
  File file, {
  int sampleRate = 8000,
  int channels = 1,
  int durationSeconds = 110,
}) {
  final numFrames = sampleRate * durationSeconds;
  final blockAlign = channels * 2;
  final byteRate = sampleRate * blockAlign;
  final dataLen = numFrames * blockAlign;
  final byteData = ByteData(44 + dataLen);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      byteData.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  byteData.setUint32(4, 36 + dataLen, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  byteData.setUint32(16, 16, Endian.little);
  byteData.setUint16(20, 1, Endian.little);
  byteData.setUint16(22, channels, Endian.little);
  byteData.setUint32(24, sampleRate, Endian.little);
  byteData.setUint32(28, byteRate, Endian.little);
  byteData.setUint16(32, blockAlign, Endian.little);
  byteData.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  byteData.setUint32(40, dataLen, Endian.little);

  var pos = 44;
  for (var n = 0; n < numFrames; n++) {
    final t = n / sampleRate;
    final sample = ((math.sin(2.0 * math.pi * 440.0 * t)) * 12000).round();
    for (var ch = 0; ch < channels; ch++) {
      byteData.setInt16(pos, sample, Endian.little);
      pos += 2;
    }
  }

  file.writeAsBytesSync(byteData.buffer.asUint8List());
}

class _RaceSimulatingMockAudioService extends MockAudioService {
  final Completer<void> gate = Completer<void>();
  bool restoreStarted = false;
  late final PlaybackPersistenceService persistence;
  bool observedIsRestoringDuringCall = false;

  @override
  Future<void> restorePlaybackSession({
    required TrackInfo track,
    required Duration position,
    List<TrackInfo>? queue,
    int? queueIndex,
    double? volume,
    bool? isMuted,
  }) async {
    restoreStarted = true;
    observedIsRestoringDuringCall = persistence.isRestoring;

    // Simulate startup race: default empty/0ms snapshots emitted while restore is in flight.
    final raceSnapZero = persistence.buildSnapshot(
      state: PlaybackState(
        status: PlaybackStatus.paused,
        track: queue?.firstOrNull ?? track,
        position: Duration.zero,
        volume: 0.85,
      ),
      queue: queue ?? const [],
    );
    persistence.saveThrottled(raceSnapZero);
    await persistence.saveImmediate(raceSnapZero);

    await gate.future;
    await super.restorePlaybackSession(
      track: track,
      position: position,
      queue: queue,
      queueIndex: queueIndex,
      volume: volume,
      isMuted: isMuted,
    );
  }
}

void main() {
  group('PlaybackPersistence full exit & restore', () {
    late Directory tempDir;
    late File stateFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lumina_persist_restore_');
      stateFile = File(
        '${tempDir.path}${Platform.pathSeparator}playback_state.json',
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test(
      'saves track #2 at 01:30 + queue + volume 0.65 via saveAndFlushForExit and restores in paused standby',
      () async {
        const track1 = TrackInfo(
          id: 't-1',
          title: 'First Track',
          artist: 'Artist One',
          album: 'Album One',
          duration: Duration(minutes: 4),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
          providerName: 'Local Library',
          filePath: r'C:\Music\01_first.flac',
        );
        const track2 = TrackInfo(
          id: 't-2',
          title: 'Second Track',
          artist: 'Artist Two',
          album: 'Album One',
          duration: Duration(minutes: 5),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 192000,
            bitDepth: 24,
            channels: 2,
          ),
          providerName: 'Local Library',
          filePath: r'C:\Music\02_second.flac',
        );
        const track3 = TrackInfo(
          id: 't-3',
          title: 'Third Track',
          artist: 'Artist Three',
          album: 'Album One',
          duration: Duration(minutes: 3, seconds: 30),
          format: AudioFormat(
            codec: AudioCodec.wav,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'Local Library',
          filePath: r'C:\Music\03_third.wav',
        );

        final svc1 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        final snap = svc1.buildSnapshot(
          state: const PlaybackState(
            status: PlaybackStatus.playing,
            track: track2,
            position: Duration(seconds: 90),
            volume: 0.65,
            isMuted: false,
          ),
          queue: const [track1, track2, track3],
          queueIndex: 1,
        );
        expect(snap['version'], 2);
        expect(snap['queue_index'], 1);
        expect((snap['queue_tracks'] as List).length, 3);

        await svc1.saveAndFlushForExit(snap);
        svc1.dispose();

        expect(stateFile.existsSync(), isTrue);
        expect(File('${stateFile.path}.tmp').existsSync(), isFalse);

        // Fresh restart with a brand new MockAudioService and PersistenceService
        final audio2 = MockAudioService();
        addTearDown(audio2.dispose);
        final svc2 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        addTearDown(svc2.dispose);

        final restored = await svc2.restoreSession(audio2);
        expect(restored, isTrue);
        expect(audio2.currentState.track?.id, 't-2');
        expect(audio2.currentState.track?.title, 'Second Track');
        expect(audio2.currentState.status, PlaybackStatus.paused);
        expect(audio2.currentState.position, const Duration(seconds: 90));
        expect(audio2.currentState.volume, closeTo(0.65, 0.001));
        expect(audio2.queue.map((t) => t.id).toList(), ['t-1', 't-2', 't-3']);
      },
    );

    test(
      'startup empty-state & isRestoring race guards prevent overwriting saved session',
      () async {
        const savedTrack = TrackInfo(
          id: 'saved-1',
          title: 'Persisted Track',
          artist: 'Persisted Artist',
          album: 'Persisted Album',
          duration: Duration(minutes: 4),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
          filePath: r'C:\Music\persisted.flac',
        );

        final writer = PlaybackPersistenceService(prefsFileOverride: stateFile);
        await writer.saveAndFlushForExit(
          writer.buildSnapshot(
            state: const PlaybackState(
              status: PlaybackStatus.paused,
              track: savedTrack,
              position: Duration(seconds: 90),
              volume: 0.72,
            ),
            queue: const [savedTrack],
          ),
        );
        writer.dispose();

        final raceAudio = _RaceSimulatingMockAudioService();
        addTearDown(raceAudio.dispose);
        final restorer = PlaybackPersistenceService(
          prefsFileOverride: stateFile,
          throttleDuration: const Duration(milliseconds: 20),
        );
        addTearDown(restorer.dispose);
        raceAudio.persistence = restorer;

        final restoreFuture = restorer.restoreSession(raceAudio);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(raceAudio.restoreStarted, isTrue);
        expect(raceAudio.observedIsRestoringDuringCall, isTrue);
        expect(restorer.isRestoring, isTrue);

        // Attempt another overwrite while isRestoring == true
        await restorer.saveImmediate(
          restorer.buildSnapshot(
            state: const PlaybackState(
              status: PlaybackStatus.stopped,
              track: null,
              position: Duration.zero,
              volume: 1.0,
            ),
            queue: const [],
          ),
          allowEmptyTrack: true,
        );

        raceAudio.gate.complete();
        final ok = await restoreFuture;
        expect(ok, isTrue);
        expect(restorer.isRestoring, isFalse);

        // Disk file MUST still contain 90000ms and saved-1!
        final afterRace = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
        expect(afterRace['position_ms'], 90000);
        expect(afterRace['track']['id'], 'saved-1');

        // Also after restore completes, empty track == null snapshot must NOT overwrite unless allowEmptyTrack: true
        final emptySnap = restorer.buildSnapshot(
          state: const PlaybackState(
            status: PlaybackStatus.stopped,
            track: null,
            position: Duration.zero,
          ),
          queue: const [],
        );
        restorer.saveThrottled(emptySnap);
        await restorer.flush();
        await restorer.saveImmediate(emptySnap);

        final afterEmptyAttempt =
            jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
        expect(afterEmptyAttempt['track']['id'], 'saved-1');
        expect(afterEmptyAttempt['position_ms'], 90000);

        // Explicitly passing allowEmptyTrack: true DOES clear it
        await restorer.saveImmediate(emptySnap, allowEmptyTrack: true);
        final afterExplicitEmpty =
            jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
        expect(afterExplicitEmpty['track'], isNull);
      },
    );

    test(
      'track ID change across rescan matches by normalized filePath and restores position',
      () async {
        expect(
          PlaybackPersistenceService.normalizeTrackPath(r'  C:\Music\song.flac '),
          PlaybackPersistenceService.normalizeTrackPath('c:/music/song.flac'),
        );

        const oldSavedTrack = TrackInfo(
          id: 'old-uuid-123',
          title: 'Rescanned Song',
          artist: 'Artist',
          album: 'Album',
          duration: Duration(minutes: 4),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
          filePath: r'C:\Music\song.flac',
        );

        final svc1 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        await svc1.saveAndFlushForExit(
          svc1.buildSnapshot(
            state: const PlaybackState(
              status: PlaybackStatus.paused,
              track: oldSavedTrack,
              position: Duration(seconds: 90),
              volume: 0.8,
            ),
            queue: const [oldSavedTrack],
          ),
        );
        svc1.dispose();

        // Simulate new library where song received a brand-new UUID and forward-slash lowercase path
        final audio2 = MockAudioService();
        addTearDown(audio2.dispose);
        audio2.queue
          ..clear()
          ..addAll(const [
            TrackInfo(
              id: 'other-uuid-111',
              title: 'Another Song',
              artist: 'Artist',
              album: 'Album',
              duration: Duration(minutes: 3),
              format: AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
              ),
              filePath: 'c:/music/other.flac',
            ),
            TrackInfo(
              id: 'new-uuid-999',
              title: 'Rescanned Song',
              artist: 'Artist',
              album: 'Album',
              duration: Duration(minutes: 4),
              format: AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 96000,
                bitDepth: 24,
                channels: 2,
              ),
              filePath: 'c:/music/song.flac',
            ),
          ]);

        final svc2 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        addTearDown(svc2.dispose);
        final ok = await svc2.restoreSession(audio2);
        expect(ok, isTrue);
        expect(audio2.currentState.track?.id, 'new-uuid-999');
        expect(audio2.currentState.position, const Duration(seconds: 90));
        expect(audio2.currentState.status, PlaybackStatus.paused);
      },
    );

    test(
      'seek while paused standby updates position and togglePlayPause resumes from restored position',
      () async {
        const track = TrackInfo(
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
        );

        final svc1 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        await svc1.saveAndFlushForExit(
          svc1.buildSnapshot(
            state: const PlaybackState(
              status: PlaybackStatus.paused,
              track: track,
              position: Duration(seconds: 90),
              volume: 0.75,
            ),
            queue: MockAudioService().queue,
            queueIndex: 1,
          ),
        );
        svc1.dispose();

        final audio2 = MockAudioService();
        addTearDown(audio2.dispose);
        final svc2 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        addTearDown(svc2.dispose);

        expect(await svc2.restoreSession(audio2), isTrue);
        expect(audio2.currentState.status, PlaybackStatus.paused);
        expect(audio2.currentState.position, const Duration(seconds: 90));

        // Seek while still in paused standby
        await audio2.seek(const Duration(seconds: 105));
        expect(audio2.currentState.status, PlaybackStatus.paused);
        expect(audio2.currentState.position, const Duration(seconds: 105));

        // Resume via togglePlayPause -> starts playing from 105s (not 00:00)
        await audio2.togglePlayPause();
        expect(audio2.currentState.status, PlaybackStatus.playing);
        expect(audio2.currentState.position, const Duration(seconds: 105));
      },
    );

    test(
      'rememberPlaybackPosition == false skips position/track restore while restoring volume',
      () async {
        const track2 = TrackInfo(
          id: 'trk-002',
          title: 'Money',
          artist: 'Pink Floyd',
          album: 'The Dark Side of the Moon',
          duration: Duration(minutes: 3, seconds: 52),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
        );

        final svc1 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        await svc1.saveAndFlushForExit(
          svc1.buildSnapshot(
            state: const PlaybackState(
              status: PlaybackStatus.paused,
              track: track2,
              position: Duration(seconds: 90),
              volume: 0.42,
            ),
            queue: [track2],
          ),
        );
        svc1.dispose();

        final audio2 = MockAudioService();
        addTearDown(audio2.dispose);
        final initialTrackId = audio2.currentState.track?.id;
        final initialPos = audio2.currentState.position;

        final svc2 = PlaybackPersistenceService(prefsFileOverride: stateFile);
        addTearDown(svc2.dispose);
        final restored = await svc2.restoreSession(
          audio2,
          rememberPosition: false,
        );

        expect(restored, isFalse);
        expect(audio2.currentState.volume, closeTo(0.42, 0.001));
        expect(audio2.currentState.track?.id, initialTrackId);
        expect(audio2.currentState.position, initialPos);
      },
    );

    test(
      'unawaited flush() followed immediately by dispose() still commits pending snapshot atomically',
      () async {
        const track = TrackInfo(
          id: 'trk-flush',
          title: 'Flush Safe Track',
          artist: 'Artist',
          album: 'Album',
          duration: Duration(minutes: 4),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 48000,
            bitDepth: 24,
            channels: 2,
          ),
        );

        final svc = PlaybackPersistenceService(
          prefsFileOverride: stateFile,
          throttleDuration: const Duration(seconds: 10),
        );
        svc.saveThrottled(
          svc.buildSnapshot(
            state: const PlaybackState(
              status: PlaybackStatus.playing,
              track: track,
              position: Duration(seconds: 77),
              volume: 0.6,
            ),
            queue: const [track],
          ),
        );

        // Simulate HomeScreen.dispose() calling unawaited flush() then dispose() synchronously
        unawaited(svc.flush());
        svc.dispose();

        expect(stateFile.existsSync(), isTrue);
        final decoded = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
        expect(decoded['position_ms'], 77000);
        expect(decoded['track']['id'], 'trk-flush');
      },
    );

    test(
      'FfiAudioService resolves %LOCALAPPDATA% DB path with legacy migration and handles paused standby + resume + no fake provider tracks',
      () async {
        final fakeLocalAppData = Directory(
          '${tempDir.path}${Platform.pathSeparator}local_app_data',
        )..createSync();
        final fakeTempDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}legacy_temp',
        )..createSync();
        final legacyDb = File(
          '${fakeTempDir.path}${Platform.pathSeparator}lumina_desktop_library.db',
        )..writeAsStringSync('legacy-sqlite-bytes');

        final resolvedDbPath = FfiAudioService.resolveDatabasePath(
          localAppDataOverride: fakeLocalAppData.path,
          tempDirOverride: fakeTempDir.path,
          isFlutterTestOverride: false,
        );
        final expectedDbPath =
            '${fakeLocalAppData.path}${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}lumina_desktop_library.db';
        expect(resolvedDbPath, expectedDbPath);
        expect(File(expectedDbPath).existsSync(), isTrue);
        expect(File(expectedDbPath).readAsStringSync(), 'legacy-sqlite-bytes');
        expect(legacyDb.existsSync(), isTrue);

        // Also test real FfiAudioService(headless: true) end-to-end persistence & resume
        final musicDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}music',
        )..createSync(recursive: true);
        final wav1 = File('${musicDir.path}${Platform.pathSeparator}01 - Alpha.wav');
        final wav2 = File('${musicDir.path}${Platform.pathSeparator}02 - Beta.wav');
        _writeSyntheticWav(wav1);
        _writeSyntheticWav(wav2);
        final dbPath = '${tempDir.path}${Platform.pathSeparator}ffi_persist.db';

        late final TrackInfo targetTrack;
        final ffi1 = FfiAudioService(headless: true, databasePath: dbPath);
        try {
          expect(ffi1.isNativeBound, isTrue);

          // Verify syncProvider does NOT inject fake MockAudioService tracks (am-001/ytm-001/dz-001)
          await ffi1.syncProvider('apple_music');
          expect(ffi1.queue.any((t) => t.id == 'am-001'), isFalse);

          final scanned = await ffi1.scanDirectory(musicDir.path);
          expect(scanned, 2);
          expect(ffi1.queue.length, 2);

          targetTrack = ffi1.queue[1];
          await ffi1.play(track: targetTrack);
          await ffi1.seek(const Duration(seconds: 90));
          await ffi1.setVolume(0.65);
          await ffi1.pause();

          final persist1 = PlaybackPersistenceService(prefsFileOverride: stateFile);
          await persist1.saveAndFlushForExit(
            persist1.buildSnapshot(
              state: PlaybackState(
                status: PlaybackStatus.paused,
                track: targetTrack,
                position: const Duration(seconds: 90),
                volume: 0.65,
              ),
              queue: ffi1.queue,
              queueIndex: 1,
            ),
          );
          persist1.dispose();
        } finally {
          ffi1.dispose();
        }

        // Cold restart on a fresh FfiAudioService
        final ffi2 = FfiAudioService(headless: true, databasePath: dbPath);
        try {
          expect(ffi2.isNativeBound, isTrue);
          expect(ffi2.queue.length, 2);

          final persist2 = PlaybackPersistenceService(prefsFileOverride: stateFile);
          addTearDown(persist2.dispose);
          final restored = await persist2.restoreSession(ffi2);
          expect(restored, isTrue);

          expect(ffi2.currentState.track?.filePath, targetTrack.filePath);
          expect(ffi2.currentState.status, PlaybackStatus.paused);
          expect(ffi2.currentState.position, const Duration(seconds: 90));
          expect(ffi2.currentState.volume, closeTo(0.65, 0.01));

          // Library rescan while restored MUST NOT clobber track back to queue[0]
          await ffi2.rescanTags();
          expect(ffi2.currentState.track?.filePath, targetTrack.filePath);
          expect(ffi2.currentState.position, const Duration(seconds: 90));

          // Seek while in paused standby, then togglePlayPause -> opens stream & seeks to 90s!
          await ffi2.seek(const Duration(seconds: 90));
          await ffi2.togglePlayPause();
          expect(ffi2.currentState.status, PlaybackStatus.playing);
          expect(
            ffi2.currentState.position.inSeconds,
            greaterThanOrEqualTo(89),
          );
          await ffi2.stop();
        } finally {
          ffi2.dispose();
        }
      },
    );

    test(
      'FfiAudioService.playStreamUrl passes stream_url, headers, and hint_extension to Rust FFI',
      () async {
        final tmpWav = File(
          '${tempDir.path}${Platform.pathSeparator}stream_source.wav',
        );
        _writeSyntheticWav(tmpWav, durationSeconds: 5);
        final wavBytes = Uint8List.fromList(tmpWav.readAsBytesSync());

        final readyPort = ReceivePort();
        final authPort = ReceivePort();
        final isolate = await Isolate.spawn(_runBackgroundWavServer, (
          readyPort.sendPort,
          authPort.sendPort,
          TransferableTypedData.fromList([wavBytes]),
        ));
        final readyInfo = await readyPort.first as (int, SendPort);
        final serverPort = readyInfo.$1;
        final stopPort = readyInfo.$2;
        readyPort.close();

        addTearDown(() {
          stopPort.send(null);
          authPort.close();
          isolate.kill(priority: Isolate.immediate);
        });

        final dbPath = '${tempDir.path}${Platform.pathSeparator}stream_test.db';
        final ffi = FfiAudioService(headless: true, databasePath: dbPath);
        try {
          expect(ffi.isNativeBound, isTrue);
          const streamTrack = TrackInfo(
            id: 'qobuz-stream-1',
            title: 'Streamed Track',
            artist: 'Stream Artist',
            album: 'Stream Album',
            duration: Duration(seconds: 5),
            format: AudioFormat(
              codec: AudioCodec.wav,
              sampleRateHz: 8000,
              bitDepth: 16,
              channels: 1,
            ),
            providerName: 'Qobuz',
          );

          await ffi.playStreamUrl(
            track: streamTrack,
            streamUrl: 'http://127.0.0.1:$serverPort/audio_blob',
            headers: const {'x-lumina-auth': 'secret-bearer-token'},
            hintExtension: 'wav',
          );

          final receivedAuth = await authPort.first as String?;
          expect(ffi.lastError, isNull);
          expect(ffi.currentState.status, PlaybackStatus.playing);
          expect(receivedAuth, 'secret-bearer-token');
          await ffi.stop();
        } finally {
          ffi.dispose();
        }
      },
    );
  });
}

Future<void> _runBackgroundWavServer(
  (SendPort, SendPort, TransferableTypedData) args,
) async {
  final (readyPort, authPort, transferable) = args;
  final wavBytes = transferable.materialize().asUint8List();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final stopPort = ReceivePort();
  var reportedAuth = false;

  server.listen((req) async {
    final auth = req.headers.value('x-lumina-auth');
    if (!reportedAuth && auth != null) {
      reportedAuth = true;
      authPort.send(auth);
    }
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    req.response.headers.contentType = ContentType('audio', 'wav');

    if (req.method == 'HEAD') {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentLength = wavBytes.length;
      await req.response.close();
      return;
    }

    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6).split('-');
      final start = int.tryParse(spec[0]) ?? 0;
      final end = (spec.length > 1 && spec[1].isNotEmpty)
          ? (int.tryParse(spec[1]) ?? (wavBytes.length - 1))
          : (wavBytes.length - 1);
      final clampedEnd = end.clamp(start, wavBytes.length - 1);
      final slice = wavBytes.sublist(start, clampedEnd + 1);
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$clampedEnd/${wavBytes.length}',
      );
      req.response.headers.contentLength = slice.length;
      req.response.add(slice);
      await req.response.close();
      return;
    }

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentLength = wavBytes.length;
    req.response.add(wavBytes);
    await req.response.close();
  });

  readyPort.send((server.port, stopPort.sendPort));
  await stopPort.first;
  stopPort.close();
  await server.close(force: true);
}
