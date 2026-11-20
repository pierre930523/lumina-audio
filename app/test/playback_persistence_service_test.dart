import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';

void main() {
  group('PlaybackPersistenceService', () {
    late Directory tempDir;
    late File testFile;
    late PlaybackPersistenceService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lumina_playback_test_');
      testFile = File('${tempDir.path}${Platform.pathSeparator}state.json');
      service = PlaybackPersistenceService(
        prefsFileOverride: testFile,
        throttleDuration: const Duration(milliseconds: 50),
      );
    });

    tearDown(() async {
      service.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('saves snapshot immediately and restores session onto audioService',
        () async {
      const sampleTrack = TrackInfo(
        id: 'track_test_1',
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        album: 'A Night at the Opera',
        duration: Duration(seconds: 354),
        coverUrl: 'https://example.com/cover.jpg',
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
        ),
      );

      final state = const PlaybackState(
        status: PlaybackStatus.paused,
        track: sampleTrack,
        position: Duration(seconds: 125),
        volume: 0.85,
        isMuted: false,
      );

      final snapshot = service.buildSnapshot(
        state: state,
        queue: [sampleTrack],
        queueIndex: 0,
      );

      await service.saveImmediate(snapshot);
      expect(testFile.existsSync(), isTrue);

      final loaded = await service.load();
      expect(loaded, isNotNull);
      expect(loaded!['position_ms'], 125000);
      expect(loaded['volume'], 0.85);
      expect(loaded['track']['id'], 'track_test_1');

      final mockAudio = MockAudioService();
      final restored = await service.restoreSession(mockAudio);
      expect(restored, isTrue);
      expect(mockAudio.currentState.volume, closeTo(0.85, 0.01));
      expect(mockAudio.currentState.position, const Duration(seconds: 125));
      expect(mockAudio.currentState.status, isNot(PlaybackStatus.playing));
    });

    test('recovers gracefully from empty or corrupt JSON file', () async {
      testFile.writeAsStringSync('{corrupt json');
      final loaded = await service.load();
      expect(loaded, isNull);

      final mockAudio = MockAudioService();
      final restored = await service.restoreSession(mockAudio);
      expect(restored, isFalse);
    });

    test('throttles rapid consecutive saves and flushes pending data',
        () async {
      const trackA = TrackInfo(
        id: 'track_a',
        title: 'Song A',
        artist: 'Artist A',
        album: 'Album A',
        duration: Duration(seconds: 200),
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );

      final snapshot1 = service.buildSnapshot(
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          track: trackA,
          position: Duration(seconds: 10),
          volume: 0.5,
          isMuted: false,
        ),
        queue: [trackA],
      );

      final snapshot2 = service.buildSnapshot(
        state: const PlaybackState(
          status: PlaybackStatus.playing,
          track: trackA,
          position: Duration(seconds: 20),
          volume: 0.7,
          isMuted: false,
        ),
        queue: [trackA],
      );

      service.saveThrottled(snapshot1);
      service.saveThrottled(snapshot2);

      await service.flush();
      expect(testFile.existsSync(), isTrue);

      final loaded = await service.load();
      expect(loaded!['position_ms'], 20000);
      expect(loaded['volume'], 0.7);
    });
  });
}
